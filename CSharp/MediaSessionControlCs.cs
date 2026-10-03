using Godot;
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using global::Windows.Media;
using global::Windows.Storage.Streams;

namespace TouhouMixCommunityEdition;

/// <summary>
/// Windows 系统媒体控制（SMTC）桥接（autoload，全局名 MediaSessionControlCs）。
///
/// 音频由 miniaudio 原生设备直接输出、不经过 Godot AudioServer，引擎侧无媒体集成，
/// 需自行注册 SMTC 才能出现在 Windows 11 控制中心 / 媒体浮层，并接收硬件媒体键。
///
/// 取会话不能走 SystemMediaTransportControls.GetForCurrentView()——那是给 UWP 用的，
/// 桌面应用会返回 "Invalid window handle"。必须用 ISystemMediaTransportControlsInterop
/// 的 GetForWindow 按 HWND 取。该接口是 internal 的 CsWinRT 投影，故手搓 vtable 调用，
/// 再用 SystemMediaTransportControls.FromAbi 包装回投影对象。
///
/// COM 线程模型：事件回调来自任意 COM 线程，不能直接 emit Godot 信号
/// （Godot 信号需在主线程触发）。故回调只记录为 _pending_command，
/// 由 _Process 每帧 pump 一次转成 command_received 信号。
/// </summary>
public partial class MediaSessionControlCs : Node
{
	[Signal]
	public delegate void CommandReceivedEventHandler(string action, double positionMs);

	private const string SmtcClassName = "Windows.Media.SystemMediaTransportControls";

	// ISystemMediaTransportControlsInterop
	private static readonly Guid IidSmtcInterop = new("ddb0472d-c911-4a1f-86d9-dc3d71a95f5a");
	// ISystemMediaTransportControls
	private static readonly Guid IidSmtc = new("99FA3FF4-1742-42A6-902E-087D41F965EC");

	[DllImport("api-ms-win-core-winrt-l1-1-0.dll", ExactSpelling = true)]
	private static extern int RoGetActivationFactory(IntPtr activatableClassId, ref Guid iid, out IntPtr factory);

	[DllImport("api-ms-win-core-winrt-l1-1-0.dll", ExactSpelling = true)]
	private static extern int WindowsCreateString([MarshalAs(UnmanagedType.LPWStr)] string sourceString, int length, out IntPtr hstring);

	[UnmanagedFunctionPointer(CallingConvention.StdCall)]
	private delegate int GetForWindowFn(IntPtr self, IntPtr hwnd, ref Guid riid, out IntPtr result);

	private enum SmtcButton
	{
		Play = 0,
		Pause = 1,
		Stop = 2,
		Next = 6,
		Previous = 7,
	}

	private SystemMediaTransportControls? _smtc;
	private string _lastTitle = "";
	private string _lastAlbum = "";
	private byte[]? _lastCoverPng;

	// 待派发的系统命令（COM 线程写入，主线程读取并 emit）
	private string? _pendingAction;
	private double _pendingPositionMs = -1.0;

	public override void _Ready()
	{
		// 非 Windows 或初始化失败时 _smtc 为 null，SystemMediaSession.gd 侧会跳过
		if (!OperatingSystem.IsWindows())
		{
			return;
		}
		if (!TryInit())
		{
			GD.PrintErr("[MediaSessionControlCs] SMTC init failed; system media controls unavailable");
		}
	}

	public override void _ExitTree()
	{
		Detach();
	}

	public override void _Process(double delta)
	{
		// SMTC 事件在 COM 线程到达，信号必须在主线程发
		string? action = _pendingAction;
		if (action == null)
		{
			return;
		}
		_pendingAction = null;
		double positionMs = _pendingPositionMs;
		_pendingPositionMs = -1.0;
		EmitSignal(SignalName.CommandReceived, action, positionMs);
	}

	/// <summary>向系统下发播放状态与元数据。由 SystemMediaSession 调用。</summary>
	public void UpdateState(bool playing, double positionMs, double durationMs, string title, string album,
		byte[] coverPng)
	{
		if (_smtc == null)
		{
			return;
		}
		try
		{
			_smtc.PlaybackStatus = playing
				? Windows.Media.MediaPlaybackStatus.Playing
				: (positionMs > 0.0 ? Windows.Media.MediaPlaybackStatus.Paused
					: Windows.Media.MediaPlaybackStatus.Stopped);
			// 播放时给 1.0，系统侧据此自行外推进度条，无需高频刷新
			_smtc.PlaybackRate = playing ? 1.0 : 0.0;

			_smtc.IsPlayEnabled = true;
			_smtc.IsPauseEnabled = true;
			_smtc.IsStopEnabled = true;
			// 曲目页无上一首/下一首语义，上层把两者都映射为"从头重播"
			_smtc.IsNextEnabled = true;
			_smtc.IsPreviousEnabled = true;

			if (title != _lastTitle || album != _lastAlbum || !CoverEquals(coverPng))
			{
				_lastTitle = title;
				_lastAlbum = album;
				_lastCoverPng = coverPng;
				var updater = _smtc.DisplayUpdater;
				updater.Type = Windows.Media.MediaPlaybackType.Music;
				updater.MusicProperties.Title = title;
				updater.MusicProperties.AlbumArtist = album;
				// 封面需以流形式给 SMTC 卡片（CsWinRT 无 CreateFromBitmap，用 CreateFromStream）
				updater.Thumbnail = null;
				if (coverPng != null && coverPng.Length > 0)
				{
					var stream = CreateStreamFromPng(coverPng);
					if (stream != null)
					{
						updater.Thumbnail =
							Windows.Storage.Streams.RandomAccessStreamReference.CreateFromStream(stream);
					}
				}
				updater.Update();
			}

			// 时长未知时只报位置，避免系统显示 0:00 进度条
			var end = durationMs > 0.0 ? TimeSpan.FromMilliseconds(durationMs) : TimeSpan.Zero;
			_smtc.UpdateTimelineProperties(new SystemMediaTransportControlsTimelineProperties
			{
				StartTime = TimeSpan.Zero,
				EndTime = end,
				Position = TimeSpan.FromMilliseconds(Math.Max(0.0, positionMs)),
				MinSeekTime = TimeSpan.Zero,
				MaxSeekTime = end,
			});
		}
		catch (Exception e)
		{
			GD.PrintErr($"[MediaSessionControlCs] UpdateState failed: {e.Message}");
		}
	}

	/// <summary>封面字节是否与上次一致（避免每次位置刷新都重解码）</summary>
	private bool CoverEquals(byte[]? png)
	{
		if (_lastCoverPng == null || png == null)
		{
			return _lastCoverPng == null && png == null;
		}
		return _lastCoverPng.AsSpan().SequenceEqual(png);
	}

	/// <summary>PNG 字节写入内存流（SMTC 卡片封面）；失败返回 null</summary>
	private static IRandomAccessStream? CreateStreamFromPng(byte[] png)
	{
		try
		{
			var stream = new InMemoryRandomAccessStream();
			using (var writer = new DataWriter(stream.GetOutputStreamAt(0)))
			{
				writer.WriteBytes(png);
				writer.StoreAsync().AsTask().Wait();
			}
			stream.Seek(0);
			return stream;
		}
		catch (Exception e)
		{
			GD.PrintErr($"[MediaSessionControlCs] cover stream failed: {e.Message}");
			return null;
		}
	}

	/// <summary>隐藏媒体卡片（页面注销时调用）</summary>
	public void Clear()
	{
		if (_smtc == null)
		{
			return;
		}
		try
		{
			_smtc.PlaybackStatus = Windows.Media.MediaPlaybackStatus.Stopped;
			_smtc.PlaybackRate = 0.0;
			_smtc.IsEnabled = false;
			_lastTitle = "";
			_lastAlbum = "";
		}
		catch (Exception e)
		{
			GD.PrintErr($"[MediaSessionControlCs] Clear failed: {e.Message}");
		}
	}

	private bool TryInit()
	{
		try
		{
			IntPtr hwnd = (IntPtr)DisplayServer.WindowGetNativeHandle(
				DisplayServer.HandleType.WindowHandle,
				(int)DisplayServer.MainWindowId);
			if (hwnd == IntPtr.Zero)
			{
				GD.PrintErr("[MediaSessionControlCs] main window handle unavailable");
				return false;
			}

			IntPtr hstr;
			if (WindowsCreateString(SmtcClassName, SmtcClassName.Length, out hstr) != 0)
			{
				return false;
			}

			IntPtr factory;
			// ref/out 不能取 static readonly 字段，复制到局部再用
			Guid interopIid = IidSmtcInterop;
			int hr = RoGetActivationFactory(hstr, ref interopIid, out factory);
			if (hr != 0 || factory == IntPtr.Zero)
			{
				GD.PrintErr($"[MediaSessionControlCs] RoGetActivationFactory failed: 0x{hr:X8}");
				return false;
			}

			// IInspectable 占 vtable slot 0..5，GetForWindow 是 ISystemMediaTransportControlsInterop 的第一项
			IntPtr vtbl = Marshal.ReadIntPtr(factory);
			var getForWindow = Marshal.GetDelegateForFunctionPointer<GetForWindowFn>(
				Marshal.ReadIntPtr(vtbl, 6 * IntPtr.Size));

			Guid iid = IidSmtc;
			IntPtr smtcPtr;
			hr = getForWindow(factory, hwnd, ref iid, out smtcPtr);
			if (hr != 0 || smtcPtr == IntPtr.Zero)
			{
				GD.PrintErr($"[MediaSessionControlCs] GetForWindow failed: 0x{hr:X8}");
				return false;
			}

			_smtc = SystemMediaTransportControls.FromAbi(smtcPtr);
			if (_smtc == null)
			{
				return false;
			}

			_smtc.ButtonPressed += OnButtonPressed;
			_smtc.IsEnabled = true;
			GD.Print("[MediaSessionControlCs] SMTC registered");
			return true;
		}
		catch (Exception e)
		{
			GD.PrintErr($"[MediaSessionControlCs] init failed: {e.Message}");
			return false;
		}
	}

	private void Detach()
	{
		if (_smtc == null)
		{
			return;
		}
		try
		{
			_smtc.ButtonPressed -= OnButtonPressed;
			_smtc.IsEnabled = false;
		}
		catch (Exception e)
		{
			GD.PrintErr($"[MediaSessionControlCs] detach failed: {e.Message}");
		}
		_smtc = null;
	}

	/// <summary>COM 线程回调：只记录命令，由 _Process 在主线程转成信号</summary>
	private void OnButtonPressed(SystemMediaTransportControls sender,
		SystemMediaTransportControlsButtonPressedEventArgs args)
	{
		switch ((SmtcButton)args.Button)
		{
			case SmtcButton.Play:
				// 播放键语义为"确保在播放"，暂停中才需要恢复
				if (_smtc?.PlaybackStatus == Windows.Media.MediaPlaybackStatus.Paused)
				{
					_pendingAction = "play";
				}
				break;
			case SmtcButton.Pause:
				if (_smtc?.PlaybackStatus == Windows.Media.MediaPlaybackStatus.Playing)
				{
					_pendingAction = "pause";
				}
				break;
			case SmtcButton.Stop:
				_pendingAction = "stop";
				break;
			case SmtcButton.Next:
				_pendingAction = "next";
				break;
			case SmtcButton.Previous:
				_pendingAction = "prev";
				break;
			default:
				break;
		}
	}
}

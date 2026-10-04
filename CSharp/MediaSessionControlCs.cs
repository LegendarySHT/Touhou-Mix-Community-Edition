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
		GD.Print($"[MediaSessionControlCs] emit command_received: {action} {positionMs}");
		EmitSignal(SignalName.CommandReceived, action, positionMs);
	}

	/// <summary>向系统下发播放状态与元数据。由 SystemMediaSession 调用。</summary>
	// 方法名用 snake_case：Godot C# 没有 PascalCase→snake_case 的映射（无 MethodName
	// attribute），方法按 C# 名原样暴露。两侧后端契约靠这个名字对齐（Java 侧同为
	// snake_case）；写成 PascalCase 会让 GDScript 静默失败（Nonexistent function）。
	public void update_state(bool playing, double positionMs, double durationMs, string title, string album,
		byte[] coverPng)
	{
		if (_smtc == null)
		{
			return;
		}
		try
		{
			// clear() 会把 IsEnabled 置 false，但会话对象与事件订阅仍保留。
			// 再次进入播放页时若不重新启用，卡片可能因系统缓存仍在、但按钮不再响应，
			// 表现为「有卡片却按不动」。
			if (!_smtc.IsEnabled)
			{
				_smtc.IsEnabled = true;
			}
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
	public void clear()
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

	[DllImport("shell32.dll", CharSet = CharSet.Unicode)]
	private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

	[DllImport("shell32.dll", CharSet = CharSet.Unicode)]
	private static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid riid, out IntPtr propStore);

	[System.Runtime.InteropServices.DllImport("ole32.dll")]
	private static extern IntPtr CoTaskMemAlloc(int cb);

	[StructLayout(LayoutKind.Explicit)]
	private struct PropVariant
	{
		[FieldOffset(0)] public ushort vt;
		[FieldOffset(8)] public IntPtr pointer;
	}

	[ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"),
		InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
	private interface IPropertyStore
	{
		void GetCount(out uint c);
		void GetAt(uint i, out PropVariant p);
		void GetValue(ref Guid key, out PropVariant v);
		void SetValue(ref Guid key, ref PropVariant v);
		void Commit();
	}

	// VT_LPWSTR
	private const ushort VtLpwstr = 31;
	// PKEY_AppUserModel_ID
	private static readonly Guid PkeyAppUserModelId = new("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
	private static readonly Guid IidPropertyStore = new("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99");

	/// <summary>
	/// 给已创建的窗口补设 AppUserModelID。
	/// SetCurrentProcessExplicitAppUserModelID 是进程级的，对已存在的 HWND 无效；
	/// 必须走窗口的 IPropertyStore 写 PKEY_AppUserModel_ID（Godot 自己的文件对话框
	/// 也是这么做的），否则系统媒体浮层显示「未知应用」且不路由媒体按键。
	/// </summary>
	private static void ApplyWindowAppUserModelId(IntPtr hwnd, string appId)
	{
		IntPtr store;
		Guid iid = IidPropertyStore;
		if (SHGetPropertyStoreForWindow(hwnd, ref iid, out store) != 0 || store == IntPtr.Zero)
		{
			return;
		}
		int bytes = (appId.Length + 1) * 2;
		IntPtr mem = CoTaskMemAlloc(bytes);
		Marshal.Copy(appId.ToCharArray(), 0, mem, appId.Length);
		Marshal.WriteInt16(mem, bytes - 2, 0);
		var pv = new PropVariant { vt = VtLpwstr, pointer = mem };
		try
		{
			var store2 = (IPropertyStore)Marshal.GetObjectForIUnknown(store);
			Guid key = PkeyAppUserModelId;
			store2.SetValue(ref key, ref pv);
			store2.Commit();
			Marshal.Release(store);
		}
		finally
		{
			Marshal.FreeCoTaskMem(mem);
		}
	}

	private bool TryInit()
	{
		try
		{
			// Godot 在窗口创建之后才调 SetCurrentProcessExplicitAppUserModelID
			// （display_server_windows.cpp: 主窗口 CreateWindowEx 在前，设置 AUMID 在后），
			// 于是 HWND 创建时没有应用身份，系统媒体浮层显示「未知应用」且不路由媒体按键。
			// 这里补设一次，让 shell 之后按 AUMID 关联该窗口。
			string aumid = "TouhouMix.TouhouMixCommunityEdition";
			int aum = SetCurrentProcessExplicitAppUserModelID(aumid);
			GD.Print($"[MediaSessionControlCs] AUMID set ({aumid}) hr={aum}");

			IntPtr hwnd = (IntPtr)DisplayServer.WindowGetNativeHandle(
				DisplayServer.HandleType.WindowHandle,
				(int)DisplayServer.MainWindowId);
			if (hwnd == IntPtr.Zero)
			{
				GD.PrintErr("[MediaSessionControlCs] main window handle unavailable");
				return false;
			}
			ApplyWindowAppUserModelId(hwnd, "TouhouMix.TouhouMixCommunityEdition");

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
			_smtc.PlaybackPositionChangeRequested += OnPositionChangeRequested;
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
			_smtc.PlaybackPositionChangeRequested -= OnPositionChangeRequested;
			_smtc.IsEnabled = false;
		}
		catch (Exception e)
		{
			GD.PrintErr($"[MediaSessionControlCs] detach failed: {e.Message}");
		}
		_smtc = null;
	}

	/// <summary>COM 线程回调：进度条被拖动。同样只记录，由 _Process 转信号。</summary>
	private void OnPositionChangeRequested(SystemMediaTransportControls sender,
		PlaybackPositionChangeRequestedEventArgs args)
	{
		_pendingAction = "seek";
		_pendingPositionMs = args.RequestedPlaybackPosition.TotalMilliseconds;
	}

	/// <summary>COM 线程回调：只记录命令，由 _Process 在主线程转成信号</summary>
	private void OnButtonPressed(SystemMediaTransportControls sender,
		SystemMediaTransportControlsButtonPressedEventArgs args)
	{
		GD.Print($"[MediaSessionControlCs] ButtonPressed: {(SmtcButton)args.Button}");
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

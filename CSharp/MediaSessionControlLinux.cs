using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Threading.Tasks;
using Godot;
using Tmds.DBus;

namespace TouhouMixCommunityEdition;

/// <summary>
/// Linux 系统媒体控制（MPRIS2）桥接（Node，runtime 名由 MeltySynthPlayer 实例化）。
///
/// 与 Windows SMTC / Android MediaSession 同一份契约：
///   - update_state(playing, positionMs, durationMs, title, album, coverPng)
///   - update_repeat_mode(mode)（同步播放列表循环/随机模式到 LoopStatus / Shuffle）
///   - poll_command() -> [action, positionMs]（主线程每帧取走，由 MeltySynthPlayer 消费）
///   - clear()
///
/// Linux 没有独立媒体控件 API，统一走 MPRIS2（org.mpris.MediaPlayer2）——
/// 它通过 D-Bus 暴露，GNOME / KDE / Xfce / Cinnamon 等桌面环境全部原生支持，
/// 无需按桌面环境分别适配。这是 Linux 上等价于 Windows SMTC / Android MediaSession 的标准。
///
/// 线程模型（与 MediaSessionControlCs 的 Windows COM 线程处理一致）：
///   - D-Bus 方法回调（Play/Pause/...）在 Tmds.DBus 的读线程到达，
///     不直接碰 Godot，只把命令入队到 _pending。
///   - 主线程的 poll_command() 取走命令转成 command_received 语义。
///   - update_state / clear 由主线程调用，内部通过 D-Bus 事件把属性变化发成
///     PropertiesChanged / Seeked 信号。
/// </summary>
public partial class MediaSessionControlLinux : Node, IMprisPlayer, IMprisMediaPlayer2
{
	[Signal]
	public delegate void CommandReceivedEventHandler(string action, double positionMs);

	// ---- D-Bus 对象路径与总线名 ----
	private static readonly ObjectPath MprisPath = new ObjectPath("/org/mpris/MediaPlayer2");
	private const string BusNameBase = "org.mpris.MediaPlayer2.TouhouMixCommunityEdition";
	private const string Identity = "Touhou Mix Community Edition";
	private const string DesktopEntry = "touhoumix";
	private const string TrackId = "/org/mpris/MediaPlayer2/Track/Current";

	private Connection _conn;
	private volatile bool _registered;
	// 期望当前是否应占用 MPRIS 总线名。clear() 置 false，update_state() 置 true。
	private volatile bool _serviceWanted;
	private string _busName = BusNameBase;
	// 串行化 D-Bus 总线名的申请/释放，避免 clear 与起播同时发生时的竞态。
	private readonly object _serviceTaskLock = new object();
	private Task _serviceTask = Task.CompletedTask;

	// ---- 当前媒体状态（主线程写入，D-Bus 读线程读取）----
	// _playing/_hasState 跨线程：主线程写、D-Bus 读线程或注册回调读，用 volatile 保证可见性。
	private volatile bool _playing;
	private double _positionMs;
	private double _durationMs;
	private string _title = "";
	private string _album = "";
	private byte[] _cover;
	private double _volume = 1.0;
	private string _artUrl = "";
	private string _artFilePath = "";
	private string _trackId = TrackId;
	private Dictionary<string, object> _metadata = new Dictionary<string, object>();
	private volatile bool _hasState;

	// 用于实时计算 Position（播放时按流逝时间外推）
	private long _updateUsec;

	// 用于检测"跳变 = seek"以发出 Seeked 信号
	private double _lastReportedPositionMs = -1;

	// 上一次推给 MPRIS 的循环/随机状态，用于只在变化时发 PropertiesChanged
	private string _lastLoopStatus = "None";
	private bool _lastShuffle;

	// ---- D-Bus 线程 -> 主线程 的待处理命令队列 ----
	private readonly ConcurrentQueue<string[]> _pending = new ConcurrentQueue<string[]>();

	// ---- D-Bus 信号（调用即发出对应 D-Bus 信号）----
	// PropertyChanged 对应 org.mpris.MediaPlayer2.Player.PropertiesChanged
	public event Action<PropertyChanges> PropertyChanged;
	// BoringPropertyChanged 对应 org.mpris.MediaPlayer2.PropertiesChanged（Identity 等，几乎不变）
	public event Action<PropertyChanges> BoringPropertyChanged;
	public event Action<long> Seeked;

	public override void _Ready()
	{
		// 非 Linux 不初始化（该文件仅在 linuxbsd 构建下编译）
		if (OS.GetName() != "Linux")
		{
			return;
		}
		_ = StartAsync();
	}

	public override void _ExitTree()
	{
		_serviceWanted = false;
		try
		{
			_conn?.Dispose();
		}
		catch (Exception e)
		{
			GD.PrintErr($"[MediaSessionControlLinux] dispose failed: {e.Message}");
		}
		_conn = null;
		_registered = false;
	}

	// ====================================================================
	// D-Bus 生命周期
	// ====================================================================
	private async Task StartAsync()
	{
		try
		{
			_conn = new Connection(Address.Session);
			await _conn.ConnectAsync();
			await _conn.RegisterObjectAsync(this);

			// 不在启动阶段就占用 MPRIS 总线名：只有真正进入播放会话（update_state）才申请，
			// clear() 时释放。这样桌面控件在其它播放源接管后重新收到 NameOwnerChanged，
			// 本播放器才能被重新发现；同时避免应用在前台但没播放时也占着一个 Stopped 条目。
			if (_serviceWanted)
			{
				RequestService(true);
			}
		}
		catch (Exception e)
		{
			GD.PrintErr($"[MediaSessionControlLinux] MPRIS init failed (no session bus?): {e.Message}");
			_registered = false;
		}
	}

	/// <summary>
	/// 更新"是否需要占用 MPRIS 总线名"的期望值，并把实际的申请/释放排到串行队列。
	/// 主线程（update_state / clear）与 D-Bus 线程都可能调用，故用锁串行化。
	/// </summary>
	private void RequestService(bool want)
	{
		_serviceWanted = want;
		lock (_serviceTaskLock)
		{
			_serviceTask = _serviceTask.ContinueWith(
					_ => SyncServiceAsync(),
					System.Threading.CancellationToken.None,
					TaskContinuationOptions.DenyChildAttach,
					TaskScheduler.Default)
				.Unwrap();
		}
	}

	/// <summary>串行执行：让总线名的实际占用状态与 _serviceWanted 保持一致。</summary>
	private async Task SyncServiceAsync()
	{
		Connection conn = _conn;
		if (conn == null)
		{
			return;
		}
		if (_serviceWanted)
		{
			if (!_registered)
			{
				await AcquireServiceAsync(conn);
			}
			return;
		}
		if (!_registered)
		{
			return;
		}
		// 先置位再释放：UnregisterServiceAsync 也会触发 onLost，避免那条回调误判为"意外丢失"。
		_registered = false;
		try
		{
			await conn.UnregisterServiceAsync(_busName);
		}
		catch (Exception e)
		{
			GD.PrintErr($"[MediaSessionControlLinux] MPRIS release failed: {e.Message}");
		}
	}

	private async Task AcquireServiceAsync(Connection conn)
	{
		// 排队期间需求可能已被 clear() 撤销
		if (!_serviceWanted)
		{
			return;
		}
		string name = BusNameBase;
		try
		{
			await conn.RegisterServiceAsync(name, OnServiceLost);
		}
		catch (Exception)
		{
			// MPRIS 要求总线名唯一；同名已被占用（多实例）则追加 PID 后缀
			name = BusNameBase + "." + System.Environment.ProcessId;
			try
			{
				await conn.RegisterServiceAsync(name, OnServiceLost);
			}
			catch (Exception e)
			{
				GD.PrintErr($"[MediaSessionControlLinux] MPRIS register failed: {e.Message}");
				return;
			}
		}
		_busName = name;
		_registered = true;
		GD.Print("[MediaSessionControlLinux] MPRIS registered");
		// 重新占用后补发完整状态：客户端是在名字出现这一刻才建立代理的，
		// 不发这一轮它拿不到当前曲目/封面/进度。
		if (_hasState)
		{
			PushCurrentState();
		}
	}

	/// <summary>总线名被其它连接接管：不立即抢回，等下一次 update_state（播放中每 0.5s 一次）重建。</summary>
	private void OnServiceLost()
	{
		_registered = false;
	}

	// ====================================================================
	// 媒体会话契约（由 MeltySynthPlayer 调用）
	// ====================================================================

	/// <summary>主线程调用：下发播放状态与元数据，并发出 PropertiesChanged。</summary>
	public void update_state(bool playing, double positionMs, double durationMs, string title, string album,
		byte[] coverPng)
	{
		_playing = playing;
		_positionMs = Math.Max(0.0, positionMs);
		_durationMs = durationMs;
		_title = title ?? "";
		_album = album ?? "";
		_updateUsec = NowUsec();
		_hasState = true;

		// 封面变化才重写临时文件，避免每帧落盘
		if (!CoverEquals(coverPng))
		{
			_cover = coverPng;
			_artUrl = WriteCover(coverPng);
		}

		// trackid 必须随曲目变化：部分桌面控件据它判断"是否换曲"，不变就可能继续用旧封面
		_trackId = TrackIdFor(_title, _album, _artUrl);

		RebuildMetadata();

		// 播放中位置随引擎时间外推；暂停时位置不应前进。若本次位置相对"期望位置"
		// 出现大跳变，判定为 seek，主动发出 Seeked 让桌面控件同步进度。
		// 暂停态也要检测：媒体控件允许在暂停时拖动进度条，漏发会让控件进度与
		// 实际定位长期错开（恢复播放时表现为进度条先跳一下）。
		if (_lastReportedPositionMs >= 0.0)
		{
			double expected = _lastReportedPositionMs;
			if (_playing)
			{
				expected += (NowUsec() - _lastSeekRefUsec) / 1000.0;
			}
			if (Math.Abs(_positionMs - expected) > 1000.0)
			{
				EmitSeeked(_positionMs);
			}
		}
		_lastReportedPositionMs = _positionMs;
		_lastSeekRefUsec = _updateUsec;

		// 起播即重新申请总线名：控件被其它播放源接管/本播放器释放过名字后，
		// 下一次起播必须在总线上重新出现，桌面才会重新发现并查询本播放器。
		RequestService(true);
		if (_registered)
		{
			PushCurrentState();
		}
	}

	/// <summary>主线程调用：同步播放器的循环/随机模式到 MPRIS 的 LoopStatus / Shuffle。</summary>
	public void update_repeat_mode(int mode)
	{
		string loop = LoopStatusFor(mode);
		bool shuffle = mode == MidiCore.REPEAT_SHUFFLE;
		if (loop == _lastLoopStatus && shuffle == _lastShuffle)
		{
			return;
		}
		_lastLoopStatus = loop;
		_lastShuffle = shuffle;
		if (!_registered)
		{
			// 没有总线名时发信号没有意义；重新申请成功后 PushCurrentState 会带上这两项
			return;
		}
		PropertyChanged?.Invoke(new PropertyChanges(new[]
		{
			new KeyValuePair<string, object>("LoopStatus", loop),
			new KeyValuePair<string, object>("Shuffle", shuffle),
		}));
	}

	/// <summary>主线程调用：撤下媒体卡片（页面注销时）。</summary>
	public void clear()
	{
		_playing = false;
		_positionMs = 0.0;
		_durationMs = 0.0;
		_title = "";
		_album = "";
		_cover = null;
		_artUrl = "";
		_trackId = TrackId;
		_hasState = false;
		_metadata = new Dictionary<string, object>();
		_lastReportedPositionMs = -1.0;
		RebuildMetadata();
		// 先推一帧 Stopped 让控件立刻收起，再释放总线名：名字消失/重新出现
		// （NameOwnerChanged）是桌面重新枚举播放器的时机，仅改状态不足以恢复。
		PushCurrentState();
		RequestService(false);
	}

	/// <summary>主线程每帧调用：取走一条待处理命令（与 Windows 后端同一语义）。</summary>
	public string[] poll_command()
	{
		if (_pending.TryDequeue(out var cmd))
		{
			return cmd;
		}
		return Array.Empty<string>();
	}

	// ====================================================================
	// 内部：状态推送 / 信号
	// ====================================================================
	private void PushCurrentState()
	{
		if (!_registered)
		{
			return;
		}
		string status = _playing ? "Playing" : (_positionMs > 0.0 ? "Paused" : "Stopped");
		int mode = CurrentRepeatMode();
		string loop = LoopStatusFor(mode);
		bool shuffle = mode == MidiCore.REPEAT_SHUFFLE;
		// 重新占用总线名后这一帧就是客户端的全部初始状态，循环/随机也要一起给，
		// 否则控件再次出现时这两个按钮会退回到默认值。
		_lastLoopStatus = loop;
		_lastShuffle = shuffle;
		var changes = new List<KeyValuePair<string, object>>
		{
			new KeyValuePair<string, object>("PlaybackStatus", status),
			new KeyValuePair<string, object>("Metadata", _metadata),
			new KeyValuePair<string, object>("LoopStatus", loop),
			new KeyValuePair<string, object>("Shuffle", shuffle),
		};
		PropertyChanged?.Invoke(new PropertyChanges(changes.ToArray()));
	}

	private void EmitSeeked(double positionMs)
	{
		if (!_registered)
		{
			return;
		}
		Seeked?.Invoke((long)(positionMs * 1000.0)); // 微秒
	}

	private void RebuildMetadata()
	{
		var meta = new Dictionary<string, object>
		{
			// mpris:trackid 必须是 object path 类型 (o)
			["mpris:trackid"] = new ObjectPath(_trackId),
			["mpris:length"] = (long)(_durationMs * 1000.0), // 微秒
			["xesam:title"] = _title,
			["xesam:album"] = _album,
			["xesam:artist"] = new string[] { "" },
		};
		if (!string.IsNullOrEmpty(_artUrl))
		{
			meta["mpris:artUrl"] = _artUrl;
		}
		_metadata = meta;
	}

	private string WriteCover(byte[] png)
	{
		if (png == null || png.Length == 0)
		{
			return "";
		}
		try
		{
			string dir = OS.GetUserDataDir();
			if (string.IsNullOrEmpty(dir))
			{
				dir = Path.GetTempPath();
			}
			// 文件名带封面内容哈希：artUrl 随曲目变化而变化。固定文件名会让 artUrl
			// 保持不变，桌面控件按 URL 缓存图片时不重新读取，切歌后封面就停在上一首。
			string path = Path.Combine(dir, "touhoumix_mpris_cover_" + HashToken(png) + ".png");
			if (path != _artFilePath)
			{
				File.WriteAllBytes(path, png);
				// 新文件写成功后再删旧文件，避免控件恰好还在读上一次的封面
				DeleteArtFile(_artFilePath);
				_artFilePath = path;
			}
			// 不能直接拼 "file://" + path：Godot 的 user 目录带应用名，
			// 项目名里有空格，桌面环境按 RFC 3986 解析时会截断/拒绝该 URI，
			// 表现为媒体卡片没有封面。Uri 负责转义空格等字符并补全 file:///。
			return new Uri(path).AbsoluteUri;
		}
		catch (Exception e)
		{
			GD.PrintErr($"[MediaSessionControlLinux] cover write failed: {e.Message}");
			return "";
		}
	}

	/// <summary>8 字节内容哈希（16 位十六进制），用于生成稳定的唯一封面文件名。</summary>
	private static string HashToken(byte[] data)
	{
		byte[] hash = SHA256.HashData(data);
		return Convert.ToHexString(hash, 0, 8).ToLowerInvariant();
	}

	private static void DeleteArtFile(string path)
	{
		if (string.IsNullOrEmpty(path))
		{
			return;
		}
		try
		{
			File.Delete(path);
		}
		catch
		{
			// 旧封面删不掉不影响本次显示，忽略
		}
	}

	/// <summary>曲目 object path：同一首歌保持不变，换歌换封面即变化。</summary>
	private static string TrackIdFor(string title, string album, string artUrl)
	{
		byte[] hash = SHA256.HashData(
			System.Text.Encoding.UTF8.GetBytes($"{title}\u0001{album}\u0001{artUrl}"));
		return "/org/mpris/MediaPlayer2/Track/" + Convert.ToHexString(hash, 0, 8).ToLowerInvariant();
	}

	private bool CoverEquals(byte[] png)
	{
		if (_cover == null || png == null)
		{
			return _cover == null && png == null;
		}
		return _cover.AsSpan().SequenceEqual(png);
	}

	private static long NowUsec()
	{
		return DateTime.UtcNow.Ticks / 10; // 100ns -> us
	}

	private long _lastSeekRefUsec;

	// ====================================================================
	// D-Bus 方法（来自桌面环境的媒体控件；在 Tmds.DBus 读线程执行）
	// 只把命令入队，由主线程 poll_command 取走，避免跨线程碰 Godot。
	// ====================================================================
	public Task NextAsync()
	{
		Enqueue("next");
		return Task.CompletedTask;
	}

	public Task PreviousAsync()
	{
		Enqueue("prev");
		return Task.CompletedTask;
	}

	public Task PauseAsync()
	{
		Enqueue("pause");
		return Task.CompletedTask;
	}

	public Task PlayAsync()
	{
		Enqueue("play");
		return Task.CompletedTask;
	}

	public Task PlayPauseAsync()
	{
		// D-Bus 读线程：_playing 是 volatile，直接读取即可看到主线程最新值
		Enqueue(_playing ? "pause" : "play");
		return Task.CompletedTask;
	}

	public Task StopAsync()
	{
		Enqueue("stop");
		return Task.CompletedTask;
	}

	public Task SeekAsync(long offset)
	{
		// offset 为微秒；转为目标毫秒并入队
		double targetMs = LivePositionMs() + (offset / 1000.0);
		Enqueue("seek", targetMs);
		return Task.CompletedTask;
	}

	public Task SetPositionAsync(ObjectPath trackId, long position)
	{
		Enqueue("seek", position / 1000.0);
		return Task.CompletedTask;
	}

	public Task OpenUriAsync(string uri)
	{
		// 本项目无 URI 播放语义，忽略
		return Task.CompletedTask;
	}

	public Task QuitAsync() => Task.CompletedTask;
	public Task RaiseAsync() => Task.CompletedTask;

	private void Enqueue(string action, double positionMs = -1.0)
	{
		_pending.Enqueue(new[] { action, positionMs.ToString(System.Globalization.CultureInfo.InvariantCulture) });
	}

	private double LivePositionMs()
	{
		if (!_playing)
		{
			return _positionMs;
		}
		double live = _positionMs + (NowUsec() - _updateUsec) / 1000.0;
		if (_durationMs > 0.0)
		{
			live = Math.Min(live, _durationMs);
		}
		return Math.Max(0.0, live);
	}

	// ====================================================================
	// MPRIS LoopStatus / Shuffle <-> 播放列表 repeat_mode
	// MPRIS 把循环与随机分成两个独立属性，而播放列表只有一个四态循环模式，
	// 因此这里按互相切换的方式映射：Shuffle 对应 REPEAT_SHUFFLE，其余循环态
	// 对应 LoopStatus；开启随机时 LoopStatus 只能显示 None。
	// ====================================================================
	private static int CurrentRepeatMode()
	{
		var core = MidiCore.Instance;
		return core != null ? core.GetRepeatMode() : MidiCore.REPEAT_SEQUENTIAL;
	}

	private static string LoopStatusFor(int mode)
	{
		return mode switch
		{
			MidiCore.REPEAT_ALL => "Playlist",
			MidiCore.REPEAT_ONE => "Track",
			_ => "None",
		};
	}

	private static int ModeForLoopStatus(string status)
	{
		return status?.ToLowerInvariant() switch
		{
			"playlist" => MidiCore.REPEAT_ALL,
			"track" => MidiCore.REPEAT_ONE,
			_ => MidiCore.REPEAT_SEQUENTIAL,
		};
	}

	// ====================================================================
	// org.freedesktop.DBus.Properties 处理（Get/Set/GetAll）
	// 两个接口共用一个 GetAsync/SetAsync，GetAllAsync 各返回各自字典类型。
	// ====================================================================
	public async Task<object> GetAsync(string prop)
	{
		prop = prop.ToLowerInvariant();
		switch (prop)
		{
			case "cancontrol":
			case "cangonext":
			case "cangoprevious":
			case "canpause":
			case "canplay":
			case "canseek":
				return true;
			case "canraise":
			case "canquit":
				return false;
			case "desktopentry":
				return DesktopEntry;
			case "identity":
				return Identity;
			case "minimumrate":
			case "maximumrate":
			case "rate":
				return 1.0;
			case "volume":
				return _volume;
			case "playbackstatus":
				return _playing ? "Playing" : (_positionMs > 0.0 ? "Paused" : "Stopped");
			case "metadata":
				return _metadata;
			case "position":
				return (long)(LivePositionMs() * 1000.0); // 微秒
			case "loopstatus":
				return LoopStatusFor(CurrentRepeatMode());
			case "shuffle":
				return CurrentRepeatMode() == MidiCore.REPEAT_SHUFFLE;
			case "supportedmimetypes":
				return new string[0];
			case "supportedurischemes":
				return new[] { "file" };
			default:
				// 未知属性返回合理默认，避免客户端报 DBus 错误
				return "";
		}
	}

	public Task SetAsync(string prop, object val)
	{
		switch (prop.ToLowerInvariant())
		{
			case "volume":
				try
				{
					_volume = Convert.ToDouble(val, System.Globalization.CultureInfo.InvariantCulture);
				}
				catch
				{
					_volume = 1.0;
				}
				_volume = Math.Max(0.0, Math.Min(1.0, _volume));
				// 仅本地记录音量；真正接入 miniaudio 输出音量可作为后续工作
				PropertyChanged?.Invoke(new PropertyChanges(
					new[] { new KeyValuePair<string, object>("Volume", _volume) }));
				break;
			case "shuffle":
				bool shuffle = false;
				try
				{
					shuffle = Convert.ToBoolean(val, System.Globalization.CultureInfo.InvariantCulture);
				}
				catch
				{
					shuffle = false;
				}
				int mode = CurrentRepeatMode();
				if (shuffle)
				{
					if (mode != MidiCore.REPEAT_SHUFFLE)
					{
						Enqueue("set_repeat_mode", MidiCore.REPEAT_SHUFFLE);
					}
				}
				else if (mode == MidiCore.REPEAT_SHUFFLE)
				{
					Enqueue("set_repeat_mode", MidiCore.REPEAT_SEQUENTIAL);
				}
				break;
			case "loopstatus":
				int target = MidiCore.REPEAT_SEQUENTIAL;
				try
				{
					target = ModeForLoopStatus(Convert.ToString(val,
						System.Globalization.CultureInfo.InvariantCulture));
				}
				catch
				{
					target = MidiCore.REPEAT_SEQUENTIAL;
				}
				if (CurrentRepeatMode() != target)
				{
					Enqueue("set_repeat_mode", target);
				}
				break;
		}
		return Task.CompletedTask;
	}

	public Task<MprisPlayerProperties> GetAllAsync()
	{
		return Task.FromResult(new MprisPlayerProperties
		{
			PlaybackStatus = _playing ? "Playing" : (_positionMs > 0.0 ? "Paused" : "Stopped"),
			CanControl = true,
			CanGoNext = true,
			CanGoPrevious = true,
			CanPause = true,
			CanPlay = true,
			CanSeek = true,
			Metadata = _metadata,
			Position = (long)(LivePositionMs() * 1000.0),
			Volume = _volume,
			Rate = 1.0,
			MinimumRate = 1.0,
			MaximumRate = 1.0,
			LoopStatus = LoopStatusFor(CurrentRepeatMode()),
			Shuffle = CurrentRepeatMode() == MidiCore.REPEAT_SHUFFLE,
		});
	}

	Task<MprisMediaPlayer2Properties> IMprisMediaPlayer2.GetAllAsync()
	{
		return Task.FromResult(new MprisMediaPlayer2Properties
		{
			CanQuit = false,
			CanRaise = false,
			DesktopEntry = DesktopEntry,
			Identity = Identity,
			SupportedUriSchemes = new[] { "file" },
			SupportedMimeTypes = new string[0],
		});
	}

	// ====================================================================
	// 信号订阅（客户端侧 Watch；服务端通过上面的 event 发出）
	// ====================================================================
	public Task<IDisposable> WatchSeekedAsync(Action<long> handler, Action<Exception> onError = null)
	{
		Seeked += handler;
		return Task.FromResult<IDisposable>(new HandlerDisposable(() => Seeked -= handler));
	}

	Task<IDisposable> IMprisPlayer.WatchPropertiesAsync(Action<PropertyChanges> handler)
	{
		PropertyChanged += handler;
		return Task.FromResult<IDisposable>(new HandlerDisposable(() => PropertyChanged -= handler));
	}

	Task<IDisposable> IMprisMediaPlayer2.WatchPropertiesAsync(Action<PropertyChanges> handler)
	{
		BoringPropertyChanged += handler;
		return Task.FromResult<IDisposable>(new HandlerDisposable(() => BoringPropertyChanged -= handler));
	}

	public ObjectPath ObjectPath => MprisPath;
}

/// <summary>简单 IDisposable：Dispose 时移除事件订阅。</summary>
internal sealed class HandlerDisposable : IDisposable
{
	private readonly Action _onDispose;
	public HandlerDisposable(Action onDispose) => _onDispose = onDispose;
	public void Dispose() => _onDispose();
}

// ====================================================================
// MPRIS D-Bus 接口与属性字典（public 以便 Tmds.DBus 的动态程序集访问）
// ====================================================================

[DBusInterface("org.mpris.MediaPlayer2.Player")]
public interface IMprisPlayer : IDBusObject
{
	Task NextAsync();
	Task PreviousAsync();
	Task PauseAsync();
	Task PlayAsync();
	Task PlayPauseAsync();
	Task StopAsync();
	Task SeekAsync(long offset);
	Task SetPositionAsync(ObjectPath trackId, long position);
	Task OpenUriAsync(string uri);
	Task<IDisposable> WatchSeekedAsync(Action<long> handler, Action<Exception> onError = null);
	Task<object> GetAsync(string prop);
	Task<MprisPlayerProperties> GetAllAsync();
	Task SetAsync(string prop, object val);
	Task<IDisposable> WatchPropertiesAsync(Action<PropertyChanges> handler);
}

[DBusInterface("org.mpris.MediaPlayer2")]
public interface IMprisMediaPlayer2 : IDBusObject
{
	Task QuitAsync();
	Task RaiseAsync();
	Task<object> GetAsync(string prop);
	Task<MprisMediaPlayer2Properties> GetAllAsync();
	Task SetAsync(string prop, object val);
	Task<IDisposable> WatchPropertiesAsync(Action<PropertyChanges> handler);
}

// 【必须是 public 字段，不能写成 auto-property】
// Tmds.DBus 的 [Dictionary] 是「字段驱动」的：它反射枚举公开字段名/字段值来生成
// D-Bus 属性表。auto-property 只会暴露编译器生成的 <Foo>k__BackingField 字段，
// 于是 Introspect/GetAll 里属性名全是 "<PlaybackStatus>k__BackingField" 这种垃圾。
// MPRIS 客户端按规范名 "PlaybackStatus"/"Metadata" 读取，读不到就认为该播放器
// 不提供媒体信息 —— 桌面媒体控件因此完全不显示。
[Dictionary]
public class MprisPlayerProperties
{
	public bool CanControl = true;
	public bool CanGoNext = true;
	public bool CanGoPrevious = true;
	public bool CanPause = true;
	public bool CanPlay = true;
	public bool CanSeek = true;
	public IDictionary<string, object> Metadata = new Dictionary<string, object>();
	public string PlaybackStatus = "Stopped";
	public long Position;
	public double Volume = 1.0;
	public double Rate = 1.0;
	public double MinimumRate = 1.0;
	public double MaximumRate = 1.0;
	public string LoopStatus = "None";
	public bool Shuffle;
}

[Dictionary]
public class MprisMediaPlayer2Properties
{
	public bool CanQuit;
	public bool CanRaise;
	public string DesktopEntry = "";
	public string Identity = "";
	public string[] SupportedUriSchemes = new string[0];
	public string[] SupportedMimeTypes = new string[0];
}

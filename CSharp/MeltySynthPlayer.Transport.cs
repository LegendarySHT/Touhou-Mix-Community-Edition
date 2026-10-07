using Godot;
using System;
using System.Collections.Generic;
using System.Threading;

/// <summary>
/// MeltySynthPlayer 的「传输 / 媒体 / 播放列表编排」部分（partial class）—— 播放真值唯一归属。
///
/// 设计：GDScript 只查询与绘制，不再持有任何播放状态。播放列表 keys/索引/模式/落盘由
/// MidiCore（另一个 C# autoload）权威持有；本文件负责「传输状态 + 换曲编排 + 自动切歌 +
/// 媒体通知推送」。
///
/// 【线程约束】只有主线程能碰 Godot Object / 场景树 / EmitSignal。后台推进线程
/// （见 BackgroundAdvance.cs）只写 volatile 标量，回主线程后由 _Process 统一发信号。
/// </summary>
public partial class MeltySynthPlayer
{
	// ===== 传输真值 =====
	/// <summary>是否处于暂停态（C# 权威；GDScript 不再有 is_paused）。
	/// 【跨线程】主线程（pause/resume/handle_media_command）与后台换曲线程（据此决定换曲后
	/// 是否重新拉起设备）都会读写，故 volatile。</summary>
	private volatile bool _paused = false;
	/// <summary>当前曲目的 chart_key（C# 权威）。【跨线程】后台换曲线程经
	/// NotifySongChangedFromBackground 写入，主线程 get_current_key / PushMediaState 读取。</summary>
	private volatile string _currentKey = "";
	/// <summary>UI 状态暂停策略的注册标志</summary>
	private bool _uiPolicyConnected = false;
	/// <summary>媒体命令轮询节流累计（秒）</summary>
	private double _mediaPollAccum = 0.0;
	private const double MediaPollIntervalSec = 0.05;
	/// <summary>Windows SMTC 后端节点（按需创建）</summary>
	private Node _smtcBackend = null;
	/// <summary>封面 PNG 缓存（按路径）</summary>
	private readonly Dictionary<string, byte[]> _coverPngCache = new();
	/// <summary>上次推送的封面字节（避免每次位置刷新都重编码）</summary>
	private byte[] _lastPushedCover = Array.Empty<byte>();
	private string _lastPushedCoverPath = "";
	/// <summary>媒体后端已清除标志</summary>
	private bool _mediaCleared = true;
	/// <summary>
	/// 是否已有页面注册媒体会话（播放器页 / TrackView）——等价于旧 SystemMediaSession 的 `has_view()`。
	///
	/// 【为什么必须有】旧实现的 push_state 第一道门就是 `if not has_view(): return`：
	/// 没有页面注册时既不推送、也不重建通知。会话桥下沉 C# 后这道门丢了，而 PushMediaState
	/// 每帧都在跑（0.5s 节流）——于是 unregister_view 撤下通知之后，**下一次周期推送
	/// 立刻把通知以 STOPPED 状态又建回来**（前台服务也不退），即"离开播放页通知不撤下"。
	/// 只主线程读写。
	/// </summary>
	private bool _mediaViewRegistered = false;
	/// <summary>上次推送时的播放态（"只在播放态变化时推送"用）</summary>
	private bool _lastPushedPlaying = false;
	/// <summary>[诊断/回归] 通过媒体门控的次数（未注册视图时必须不增长）</summary>
	/// <summary>待主线程补发的「换曲」信号（后台线程换曲后置位）</summary>
	/// <summary>
	/// 后台换曲留下的"待收敛索引 key"：后台线程**不写**权威播放列表（写它要拿 _playlistLock，
	/// Save 还在锁内做 LiteDB 落盘 —— 主线程被系统挂起时会把后台线程钉死，真机日志里卡过 192 秒）。
	/// 只置位这里，由主线程在 TickTransport 里补 SetIndex + Save 一次。
	/// </summary>
	/// <summary>
	/// 后台换曲的**私有序标**（只由后台线程读写，主线程不碰）。
	/// 后台可能一口气连播几十上百首，而主线程冻结期间快照是静态的（index 不变），
	/// 必须让后台自己沿 key 顺序往下走；主线程在前台换过曲（currentKey 与游标不符）时重新对齐。
	/// </summary>
	/// <summary>
	/// 曲终处理的门闩（0=空闲 1=处理中）：前台 _Process 与后台推进线程共用。
	/// 两者都可能看到同一个 EndOfSequence 标志（前台刚恢复、后台的停摆判定还停留在 1.5s 前），
	/// 不串起来就会各换一次曲 = 连跳两首。
	/// </summary>
	private int _endHandling = 0;

	/// <summary>
	/// 传输停止代次：每次 stop() 自增。
	/// 用于识别"曲终信号广播期间被监听方停掉"——finished 是同步广播的，PlayView 会在回调里
	/// 调 stop()；若之后还按"原地重播"把播放拉起来，结算界面里就会从头再放一遍歌。
	/// </summary>
	/// <summary>显式停止代次。【跨线程】主线程 stop() 自增、后台换曲线程在 HandleSongEnded
	/// 里比对（判断"曲终广播期间被监听方停掉了"）。必须 Interlocked/Volatile：
	/// 陈旧读会让后台以为没被停过，于是曲终后又把歌起播 —— 正是该守卫要防的事。</summary>
	private int _stopGeneration = 0;
	/// <summary>主线程已发出的当前 key 快照（用于判断是否需要补发 current_song_changed）</summary>
	private string _emittedSongKey = "";

	// ===== 信号（UI 直接连） =====
	[Signal] public delegate void current_song_changedEventHandler(string chart_key);
	[Signal] public delegate void playback_state_changedEventHandler();
	[Signal] public delegate void transport_changedEventHandler();
	[Signal] public delegate void playlist_changedEventHandler();
	[Signal] public delegate void playlist_index_changedEventHandler(int index);
	[Signal] public delegate void repeat_mode_changedEventHandler(int mode);
	[Signal] public delegate void playlist_user_editedEventHandler();
	[Signal] public delegate void deferred_play_resumedEventHandler();
	[Signal] public delegate void soundfont_reload_completedEventHandler();
	[Signal] public delegate void midi_finishedEventHandler();
	/// <summary>音频焦点变化（来自 Java AudioManager）。取值：0=GAIN / 1=LOSS_TRANSIENT /
	/// 2=DUCK / 3=LOSS。上层据此暂停与恢复 —— 焦点归还的时刻才是恢复音频设备唯一可能成功的时刻。</summary>
	[Signal] public delegate void audio_focus_changedEventHandler(int state);
	/// <summary>音频设备被判定为已失效（ma_bridge_start 失败 / 音频钟停摆且未到曲终）。
	/// **由播放器自己判定**，上层只需据此表现"声音断了"（如暂停并提示），不要自己尝试恢复设备。</summary>
	[Signal] public delegate void audio_device_lostEventHandler(int reason);
	/// <summary>设备已恢复（就地重启成功，或整桥重建完成且位置已还原）。</summary>
	[Signal] public delegate void audio_device_recoveredEventHandler(bool rebuilt);

	/// <summary>由 _Ready 调用：初始化传输层（注册 UI 状态策略 + 媒体后端 + 恢复播放模式）。</summary>
	/// <summary>平台标志：后台线程不能调 OS.GetName()（引擎调用），主线程缓存一次。</summary>
	/// <summary>平台判定（主线程 _Ready 时取一次）。【跨线程】后台换曲线程据此决定是否写
	/// media_state.json —— 陈旧 false 会让熄屏切歌后的通知栏/封面永不更新，故 volatile。</summary>
	private volatile bool _isAndroid = false;

	private void InitTransport()
	{
		_isAndroid = OS.GetName() == "Android";
		_currentKey = "";
		ConnectUiStatePolicy();
		InitMediaBackend();
		// 播放模式不在这里读配置：唯一持久化位置是 MidiCore 的播放列表 meta，
		// 由 MidiCore.EnsureLoaded() 在读回列表时一并恢复（见下方"播放模式持久化"说明）。
	}

	/// <summary>由 _Process 调用：主线程侧的传输心跳（媒体轮询 / 补发信号 / 人声同步）。</summary>
	private void TickTransport(double delta)
	{
		// 把后台线程攒下的日志打出去（后台线程不能直接 GD.Print，会被冻结的主线程卡住）
		ThreadSafeLog.Flush();
		ConnectUiStatePolicy();


		TickEndOfSequenceOnMainThread();

		// 人声漂移同步（原 GDScript _sync_vocal_with_midi）
		TickVocalSync();

		// 媒体后端就绪 + 命令收取，挂在低频节拍上（Android 插件异步注册，直到注册为止
		// 每 0.5s 探一次；就绪后 EnsureMediaBackend 立即返回，不再有任何轮询开销）。
		_mediaPollAccum += delta;
		if (_mediaPollAccum >= MediaPollIntervalSec)
		{
			_mediaPollAccum = 0.0;
			EnsureMediaBackend();
			PollMediaCommands();
		}
		PushMediaState(false);
	}

	// ===================== 传输 API（GDScript 直调） =====================

	public bool is_paused() => _paused;

	/// <summary>
	/// 统一解析 MIDI 主音量：per-midi 显式值优先，未配置（&lt;0）回退全局默认，clamp 到 [0,1]。
	/// 全局默认由播放侧自己从 ConfigManager 缓存（_cachedDefaultMidiVolume），GDScript 不再读。
	/// </summary>
	public double get_effective_midi_volume(double midiVolume)
	{
		double vol = midiVolume < 0.0 ? _cachedDefaultMidiVolume : midiVolume;
		return Math.Clamp(vol, 0.0, 1.0);
	}

	public string get_current_key() => _currentKey;

	public int get_repeat_mode()
	{
		return MidiCore.Instance != null ? MidiCore.Instance.GetRepeatMode() : 0;
	}

	/// <summary>一次取回全部传输状态，供 UI 每帧读一次。</summary>
	public Godot.Collections.Dictionary get_state()
	{
		var core = MidiCore.Instance;
		return new Godot.Collections.Dictionary
		{
			["playing"] = playing,
			["paused"] = _paused,
			["position_ms"] = get_position_ms(),
			["duration_ms"] = get_duration_ms(),
			["current_key"] = _currentKey,
			["index"] = core != null ? core.GetIndex() : -1,
			["repeat_mode"] = core != null ? core.GetRepeatMode() : 0,
		};
	}

	/// <summary>播放下标（列表换曲必经点）。</summary>
	public void play_index(int index)
	{
		var core = MidiCore.Instance;
		if (core == null || core.GetCount() == 0)
		{
			return;
		}
		core.SetIndex(index);
		int i = core.GetIndex();
		EmitSignal(SignalName.playlist_index_changed, i);
		string key = core.GetKeyAt(i);
		if (string.IsNullOrEmpty(key))
		{
			return;
		}
		LoadAndPlayKey(key, true);
	}

	/// <summary>下一首。user_initiated=true 时不受单曲循环限制。</summary>
	public bool play_next(bool userInitiated = true)
	{
		var core = MidiCore.Instance;
		if (core == null || core.GetCount() == 0)
		{
			return false;
		}
		if (!userInitiated && core.GetRepeatMode() == MidiCore.REPEAT_ONE)
		{
			seek_ms(0.0);
			play();
			return true;
		}
		int i = core.IndexOf(core.NextKey());
		if (i < 0)
		{
			return false;
		}
		play_index(i);
		return true;
	}

	/// <summary>上一首（首项回绕到末尾）。</summary>
	public bool play_previous()
	{
		var core = MidiCore.Instance;
		if (core == null || core.GetCount() == 0)
		{
			return false;
		}
		int i = core.IndexOf(core.PrevKey());
		if (i < 0)
		{
			return false;
		}
		play_index(i);
		return true;
	}

	/// <summary>切换播放/暂停。</summary>
	public void toggle()
	{
		if (playing)
		{
			pause();
		}
		else
		{
			resume();
		}
	}

	/// <summary>统一处理系统媒体控件与页面按钮下发的播放命令。返回是否被消费。</summary>
	public bool handle_media_command(string action, double posMs = -1.0)
	{
		// 注意：**页面自己发起的命令不过门控**（旧实现同样如此 —— 那道门在
		// SystemMediaSession._on_backend_command 里，只管系统/外部命令）。
		// 门控见 HandleMediaCommandExternal。
		bool consumed;
		switch (action)
		{
			case "play":
				// 播放键语义 = "确保在播放"：暂停中恢复；若状态是"在播"但设备已被停掉
				// （系统打断 / 页面切换），也把设备拉起来，避免"按继续没反应"。
				if (_paused || !playing)
				{
					resume();
					consumed = true;
				}
				else if (_audioOutput is MiniaudioAudioOutputBridge maPlay && !maPlay.IsPlaying)
				{
					maPlay.Play();
					consumed = true;
				}
				else
				{
					return false;
				}
				break;
			case "toggle":
				toggle();
				consumed = true;
				break;
			case "pause":
				if (!playing)
				{
					return false;
				}
				pause();
				consumed = true;
				break;
			case "stop":
				stop();
				consumed = true;
				break;
			case "seek":
				if (posMs < 0.0)
				{
					return false;
				}
				seek_ms(posMs);
				EmitSignal(SignalName.playback_state_changed);
				return true;
			case "next":
				ensure_user_playlist();
				{
					var core = MidiCore.Instance;
					if (core == null || core.GetCount() == 0)
					{
						return false;
					}
					return play_next(true);
				}
			case "prev":
				ensure_user_playlist();
				{
					var core = MidiCore.Instance;
					if (core == null || core.GetCount() == 0)
					{
						return false;
					}
					return play_previous();
				}
			default:
				return false;
		}
		if (consumed)
		{
			EmitSignal(SignalName.transport_changed);
			EmitSignal(SignalName.playback_state_changed);
		}
		return consumed;
	}

	// ===================== 换曲编排 =====================

	/// <summary>载入并起播某 key（唯一换曲实现；前台/后台/自动前进共用）。</summary>
	private bool LoadAndPlayKey(string key, bool requireDisplaySignal)
	{
		var db = GetNodeOrNull<ChartDb>("/root/ChartDB");
		string path = ResolveMidiPath(db, key);
		if (string.IsNullOrEmpty(path))
		{
			ThreadSafeLog.PrintErr($"[MeltySynthPlayer] transport: midi path not found for key={key}");
			return false;
		}

		// 换曲先停设备清场（不广播暂停态，避免通知闪烁/封面硬切）
		stop();
		_file = path;
		LoadMidiFile(path);
		if (_midiFile == null)
		{
			ThreadSafeLog.Print("[MeltySynthPlayer] transport: midi load deferred (soundfont loading)");
			return false;
		}
		apply_chart_audio_config(key);
		if (_sequencer != null)
		{
			WithSynthLock(() =>
			{
				_sequencer.Play(_midiFile, false);
				_sequencerStarted = true;
				ApplyInstrumentOverridesToSynth();
			});
		}
		InvalidateJudgeClock();
		if (_audioOutput is MiniaudioAudioOutputBridge maWrap)
		{
			maWrap.ResetEndOfSequence();
		}
		playing = true;
		_paused = false;
		RequestAudioOutputPlay();
		request_startup_align();

		_currentKey = key;
		if (requireDisplaySignal)
		{
			_emittedSongKey = key;
			EmitSignal(SignalName.current_song_changed, key);
		}
		EmitSignal(SignalName.playback_state_changed);
		PushMediaState(true);
		return true;
	}

	/// <summary>
	/// 曲终（EndOfSequence）的统一决策：列表模式前进下一首，否则原地从头重启当前曲。
	/// 返回 true 表示处理完毕（调用方可消费已播完标志）；false 表示前提未就绪（保留标志重试）。
	/// </summary>
	/// <summary>
	/// 曲终检查（**只在主线程**）。两个调用来源，行为完全一致：
	///   1) 帧回调 `_Process` → TickTransport（前台，每帧）；
	///   2) Java ticker 的 `bg_tick`（熄屏/后台时**帧回调不跑**，但主线程仍在派发信号，
	///      由 Java 每秒叫醒一次）—— 这就是后台自动切歌的全部机制，没有独立线程。
	/// 于是"自动切歌"与"点按钮切歌"最终走同一份同步代码：HandleSongEnded → LoadAndPlayKey。
	/// 只窥视不先消费：换曲失败时把标志留着重试（否则表现为曲终后原地循环、再无输出）。
	/// </summary>
	/// <summary>[测试/诊断直调] 等价于 Java ticker 发出的 bg_tick（桌面 harness 用）。</summary>
	public void bg_tick() => TickEndOfSequenceOnMainThread();

	private void TickEndOfSequenceOnMainThread()
	{
		if (!(_audioOutput is MiniaudioAudioOutputBridge maEnd) || !maEnd.HasEndOfSequence)
		{
			return;
		}
		if (Interlocked.CompareExchange(ref _endHandling, 1, 0) != 0)
		{
			return;
		}
		try
		{
			if (HandleSongEnded())
			{
				maEnd.ConsumeEndOfSequence();
			}
		}
		finally
		{
			Interlocked.Exchange(ref _endHandling, 0);
		}
	}

	private bool HandleSongEnded()
	{
		var core = MidiCore.Instance;
		ThreadSafeLog.Print($"[MeltySynthPlayer] song ended: count={core?.GetCount()} idx={core?.GetIndex()} "
			+ $"repeat={core?.GetRepeatMode()} single={core?.IsSessionSingle()} loopFile={_sessionLoopFile}");

		// finished 是**同步**广播的：监听方（PlayView._on_game_finished 经 PlaybackDisplay.midi_finished）
		// 会在回调里调 stop()。记下代次，广播期间若被停掉就不再起播/换曲。
		int stopGenBefore = Volatile.Read(ref _stopGeneration);
		// 停设备/sequencer（幂等）+ 发 finished
		FinishPlayback();
		if (Volatile.Read(ref _stopGeneration) != stopGenBefore)
		{
			ThreadSafeLog.Print("[MeltySynthPlayer] song ended: transport stopped by listener during finished broadcast, not restarting/advancing");
			return true;   // 判定已完成（刻意不起播），标志可消费
		}

		string key = core != null ? core.ResolveAdvanceKey() : "";
		if (string.IsNullOrEmpty(key))
		{
			// 非循环会话（打歌页 PlayView）：曲终就是曲终，交给结算流程 ——
			// 旧实现用 start_session(..., loop_file=false) 的"关闭文件级循环"表达这件事。
			// 这里若照样原地重播，就会在结算界面里从头再放一遍歌。
			if (!_sessionLoopFile)
			{
				ThreadSafeLog.Print("[MeltySynthPlayer] song ended: non-looping session, staying stopped");
				EmitSignal(SignalName.playback_state_changed);
				return true;
			}
			// 单曲槽 / 列表只一首 / 单曲循环：显式从头重启（loop=false 下不会再自动回绕）
			ThreadSafeLog.Print("[MeltySynthPlayer] song ended: restart same song");
			seek_ms(0.0);
			playing = true;
			pause_resume_vocal_for_restart();
			play();
			EmitSignal(SignalName.playback_state_changed);
			return true;
		}
		int idx = core.IndexOf(key);
		if (idx >= 0)
		{
			core.SetIndex(idx);
			EmitSignal(SignalName.playlist_index_changed, idx);
		}
		if (!LoadAndPlayKey(key, true))
		{
			ThreadSafeLog.Print($"[MeltySynthPlayer] song advance failed, keeping flag to retry: {key}");
			return false;
		}
		ThreadSafeLog.Print($"[MeltySynthPlayer] advanced to next song: {key}");
		return true;
	}

	/// <summary>原地重启：把已播完的人声也拉回起点并起播（ApplyChartVocal 的门控会随 MIDI 位置放行）。</summary>
	private void pause_resume_vocal_for_restart()
	{
		if (_audioOutput is MiniaudioAudioOutputBridge ma && ma.IsVocalLoaded)
		{
			SeekVocalToMidi(0.0);
		}
	}

	/// <summary>
	/// 按 ChartDb 元数据解析谱面 MIDI 文件路径。
	///
	/// ChartDb 里存的 `path` 是**引擎风格路径**（桌面端为 `user://files/Charts/&lt;folder&gt;`，
	/// 只有 Android 自定义存储根下才是绝对路径）。用 System.IO 直接判存在性在桌面端必然失败，
	/// 于是"下一首 / 后台换曲"统统找不到谱面。这里先经主线程缓存的前缀换算成原生路径
	/// （任意线程安全，不碰引擎），再走 FileExistsSafe。
	/// </summary>
	private string ResolveMidiPath(ChartDb db, string key)
	{
		if (db == null || string.IsNullOrEmpty(key))
		{
			return "";
		}
		var folder = db.GetFolderPath(key);
		if (string.IsNullOrEmpty(folder))
		{
			return "";
		}
		folder = GlobalizeNativePath(folder);
		var candidates = new List<string> { "song.mid", key + ".mid" };
		int sep = key.IndexOf('_');
		if (sep > 0)
		{
			candidates.Add(key.Substring(0, sep) + ".mid");
		}
		foreach (var field in new[] { "_id", "file_hash", "hash" })
		{
			var s = db.GetChartFieldPlain(key, field);
			if (!string.IsNullOrEmpty(s))
			{
				candidates.Add(s + ".mid");
			}
		}
		foreach (var name in candidates)
		{
			var p = folder.PathJoin(name);
			if (FileExistsSafe(p))
			{
				return p;
			}
		}
		return "";
	}

	// ===================== 播放列表投影（转发 MidiCore） =====================

	public int playlist_count() => MidiCore.Instance != null ? MidiCore.Instance.GetCount() : 0;

	public Godot.Collections.Array playlist_keys()
	{
		return MidiCore.Instance != null ? (Godot.Collections.Array)MidiCore.Instance.GetKeys() : new Godot.Collections.Array();
	}

	public int get_playlist_index() => MidiCore.Instance != null ? MidiCore.Instance.GetIndex() : -1;

	public bool has_playlist() => playlist_count() > 0;

	public bool playlist_has_key(string key) => MidiCore.Instance != null && MidiCore.Instance.Has(key);

	public void clear_playlist()
	{
		MidiCore.Instance?.ClearAll();
		EmitSignal(SignalName.playlist_changed);
	}

	public bool ensure_user_playlist()
	{
		var core = MidiCore.Instance;
		if (core == null)
		{
			return false;
		}
		core.EnsureLoaded();
		if (core.GetCount() == 0)
		{
			// A 为空：借用单曲槽那首当起点（不落盘，用户编辑后再转正式）
			adopt_single_into_playlist();
		}
		if (core.GetCount() > 0)
		{
			core.SetPersistEnabled(true);
			core.SetSessionSingle(false);
		}
		EmitSignal(SignalName.playlist_changed);
		return core.GetCount() > 0;
	}

	public void restore_playlist()
	{
		MidiCore.Instance?.EnsureLoaded();
		MidiCore.Instance?.Prune();
		EmitSignal(SignalName.playlist_changed);
	}

	public void cycle_repeat_mode()
	{
		int cur = get_repeat_mode();
		int next = cur switch
		{
			MidiCore.REPEAT_SEQUENTIAL => MidiCore.REPEAT_ALL,
			MidiCore.REPEAT_ALL => MidiCore.REPEAT_ONE,
			MidiCore.REPEAT_ONE => MidiCore.REPEAT_SHUFFLE,
			_ => MidiCore.REPEAT_SEQUENTIAL,
		};
		set_repeat_mode(next);
	}

	// ===================== 播放控制的包装（补人声处理 + 广播） =====================

	/// <summary>暂停：C# pause() 落一次真实位置；人声一并暂停；广播状态。</summary>
	public void pause_with_vocal()
	{
		pause();
		if (_audioOutput is MiniaudioAudioOutputBridge ma && ma.IsVocalLoaded)
		{
			ma.PauseVocal();
		}
		_paused = true;
		EmitSignal(SignalName.playback_state_changed);
		PushMediaState(true);
	}

	/// <summary>恢复：C# resume()；人声一并恢复；广播状态。</summary>
	public void resume_with_vocal()
	{
		resume();
		if (_audioOutput is MiniaudioAudioOutputBridge ma && ma.IsVocalLoaded)
		{
			// 还没走到人声起点（预卷阶段，或 MIDI 位置 &lt; vocal_offset_ms）时不要抢跑：
			// native 的 vocal_play 一调就会立刻出声，人声会整整提前一个 vocal_offset_ms。
			// 旧实现的 resume() 对此有显式判断（position_ms - vocal_offset_ms >= 0 才恢复），
			// 未到起点时交给偏移门控/同步循环在正确时机放行。
			if (get_raw_position_ms() >= get_vocal_offset_ms())
			{
				ma.ResumeVocal();
			}
			else
			{
				ma.PauseVocal();
				ma.ResetVocalOffsetGate();
			}
		}
		_paused = false;
		EmitSignal(SignalName.playback_state_changed);
		PushMediaState(true);
	}

	public void stop_transport()
	{
		stop();
		_paused = false;
		EmitSignal(SignalName.playback_state_changed);
		PushMediaState(true);
	}

	// ===================== 人声漂移同步（原 GDScript _sync_vocal_with_midi） =====================

	private float _vocalSyncThresholdMs = 200.0f;
	private const int VocalSyncOffenseNeeded = 2;
	private const long VocalSyncCooldownMs = 1500;
	private double _lastVocalSyncCheckMs = -1000.0;
	private int _vocalSyncOffense = 0;
	private double _lastVocalSyncAtMs = 0.0;

	public void reset_vocal_sync()
	{
		_lastVocalSyncCheckMs = -1000.0;
		_vocalSyncOffense = 0;
		_lastVocalSyncAtMs = 0.0;
	}

	private void TickVocalSync()
	{
		if (!(_audioOutput is MiniaudioAudioOutputBridge ma))
		{
			return;
		}
		if (!ma.IsVocalLoaded)
		{
			return;
		}
		// 用户显式关掉了人声：只保证它不响，不做任何"恢复"动作
		if (_vocalDisabledByUser)
		{
			if (ma.IsVocalPlaying())
			{
				ma.PauseVocal();
			}
			return;
		}
		// 人声已自然结束：不再尝试恢复。
		// 【必须判这一条】native 的 ma_bridge_vocal_play 在 vocalEndReached 时会先把解码器
		// seek 回 0 再置 vocalPlaying；而结束瞬间 native 会把 vocalPlaying 清 0、
		// 于是 IsVocalPlaying() 为 false —— 若只按"没人声在播就 Resume"，已唱完的人声会被
		// 从头再放一遍（长伴奏尾巴的曲子上就是"曲尾又唱一遍"）。
		// 旧实现用 `_vocal_initialized and audio_manager.is_vocal_finished()` 挡住了这一点。
		// 反向 seek / 重新装载会清掉 native 的 vocalEndReached，故这里不是永久闸门。
		if (ma.IsVocalFinished())
		{
			return;
		}
		double rawMs = get_raw_position_ms();
		double offsetMs = get_vocal_offset_ms();
		double expected = rawMs - offsetMs;

		if (!ma.IsVocalPlaying())
		{
			// 只在 MIDI 已跨过人声起点后恢复
			if (expected >= 0.0 && playing)
			{
				ma.ResumeVocal();
				_lastVocalSyncCheckMs = rawMs;
			}
			return;
		}
		if (expected < 0.0)
		{
			ma.PauseVocal();
			ma.SeekVocal(0.0);
			return;
		}
		if (Math.Abs(rawMs - _lastVocalSyncCheckMs) < 100.0)
		{
			return;
		}
		double vocalPos = ma.GetVocalPositionMs();
		double diff = Math.Abs(vocalPos - expected);
		if (diff > _vocalSyncThresholdMs)
		{
			_vocalSyncOffense++;
		}
		else
		{
			_vocalSyncOffense = 0;
		}
		double nowMs = Time.GetTicksMsec();
		if (_vocalSyncOffense >= VocalSyncOffenseNeeded && nowMs - _lastVocalSyncAtMs >= VocalSyncCooldownMs)
		{
			ma.SeekVocal(expected);
			_lastVocalSyncAtMs = nowMs;
			_vocalSyncOffense = 0;
		}
		_lastVocalSyncCheckMs = rawMs;
	}

	// ===================== 播放模式持久化 =====================
	//
	// 播放模式（repeat_mode）的**唯一持久化位置是 MidiCore 的播放列表 meta**（_id="playlist"）：
	// MidiCore.SetRepeatMode → Save() 落盘、EnsureLoaded() 读回，与列表本体同生共死。
	//
	// 重构期间这里曾有一对从 ConfigManager 读写 [Playback] repeat_mode 的辅助方法，实际是死代码：
	// ConfigManager 是懒创建单例、不入场景树，`GetNodeOrNull("/root/ConfigManager")` 恒为 null，
	// 于是"读"永远早退、"写"永远落空（_systemClockRequested 那套同类问题见 set_global_playback_config）。
	// 已删除，避免留下"看起来会落盘、其实不会"的假象。

	// ===================== UI 状态暂停策略 =====================

	/// <summary>切到非播放页面（设置页、曲库浏览等）一律暂停。</summary>
	private void ConnectUiStatePolicy()
	{
		if (_uiPolicyConnected)
		{
			return;
		}
		var ui = GetNodeOrNull("/root/UiStatMGR");
		if (ui == null || !ui.HasSignal("state_changed"))
		{
			return;
		}
		_uiPolicyConnected = true;
		ui.Connect("state_changed", Callable.From<int, int>(OnUiStateChanged));
	}

	// UIStateManager.UIState（见 Core/UIStateManager.gd）：允许出声的三个页面
	private const int UiStatePlayView = 6;
	private const int UiStateTrackView = 21;
	private const int UiStateMusicPlayerView = 9;

	private void OnUiStateChanged(int oldState, int newState)
	{
		if (newState == UiStatePlayView || newState == UiStateTrackView || newState == UiStateMusicPlayerView)
		{
			return;
		}
		if (playing)
		{
			pause_with_vocal();
		}
	}

	// ===================== 媒体通知后端 =====================

	private void InitMediaBackend()
	{
		EnsureMediaBackend();
	}

	/// <summary>
	/// 确保媒体后端就绪。**每帧调用**：Android 的 Java 插件由 Godot 在渲染线程上异步注册，
	/// _Ready 时 `Engine.GetSingleton("AndroidBridge")` 往往还是 null；只连一次会永远连不上，
	/// 表现为"媒体键/通知栏上下首完全没反应"。
	/// </summary>
	private void EnsureMediaBackend()
	{
		string os = OS.GetName();
		if (os == "Android")
		{
			var backend = AndroidBackend();
			if (backend == null)
			{
				return;   // 插件尚未注册，下帧再试
			}
			// 媒体状态文件的绝对路径由 Java 侧给出（getExternalFilesDir），
			// 在 C# 里硬编码 "/storage/emulated/0/Android/data/<pkg>/files" 在工作资料
			// 等场景下会与 Java 实际读取的目录不一致 → 后台换曲后通知栏/封面静默不更新。
			// 只在主线程解析一次并缓存（后台线程不能碰 Java/Engine 调用）。
			//
			// 【不要用 HasMethod 判断 Java 插件能力】Godot 的 JNISingleton 只重写了 callp
			// （自带 @UsedByGodot 方法表），没有重写 has_method —— 见
			// platform/android/api/jni_singleton.{h,cpp}，故对 Java 插件对象 has_method 恒为 false，
			// 而 Call 是通的。用 HasMethod 守卫 = 这段代码永远不执行（静默失效）。
			if (!_mediaStatePathResolved)
			{
				var pv = backend.Call("get_media_state_path");
				if (pv.VariantType == Variant.Type.String && !string.IsNullOrEmpty(pv.AsString()))
				{
					_mediaStatePath = pv.AsString();
					_mediaStatePathResolved = true;
					ThreadSafeLog.Print($"[MeltySynthPlayer] media state path: {_mediaStatePath}");
					// 后台日志也落到同一个权威目录（MarkMainThread 里的硬编码路径在工作资料/
					// 副用户下不可写，那样熄屏期间的后台日志只剩排队，看不到实时进度）。
				}
			}
			if (_mediaBackendReady)
			{
				return;
			}
			_mediaBackendReady = true;
			RegisterCommandSignalIfAny();
			ThreadSafeLog.Print("[MeltySynthPlayer] media backend ready (AndroidBridge)");
			// 同上：直接调用，不能用 HasMethod 守卫（否则请求永远不会发出）。
			// Android 13+ 的 POST_NOTIFICATIONS 是运行时权限，不请求就没有媒体通知。
			backend.Call("ensure_notification_permission");
		}
		else if (os == "Windows" && _smtcBackend == null)
		{
			// Windows：非 autoload，按需实例化 C# SMTC 节点（Android 目标不编译该文件）
			var script = GD.Load<Script>("res://CSharp/MediaSessionControlCs.cs");
			if (script != null)
			{
				var node = script.Call("new").AsGodotObject();
				if (node is Node n)
				{
					AddChild(n);
					_smtcBackend = n;
				}
			}
		}
	}

	private bool _mediaBackendReady = false;
	/// <summary>media_state.json 的绝对路径：优先由 Java 侧 getExternalFilesDir 给出（主线程解析一次）。
	/// 为空时回退到硬编码路径，保证行为不退化。</summary>
	private volatile string _mediaStatePath = "";
	private volatile bool _mediaStatePathResolved = false;


	private GodotObject AndroidBackend()
	{
		return Engine.HasSingleton("AndroidBridge") ? Engine.GetSingleton("AndroidBridge") : null;
	}

	private void RegisterCommandSignalIfAny()
	{
		var backend = AndroidBackend();
		if (backend == null)
		{
			return;
		}
		if (!backend.HasSignal("command_received"))
		{
			ThreadSafeLog.PrintErr("[MeltySynthPlayer] AndroidBridge has no command_received signal");
			return;
		}
		var callable = Callable.From<string, double>(OnMediaCommandSignal);
		if (!backend.IsConnected("command_received", callable))
		{
			var err = backend.Connect("command_received", callable);
			ThreadSafeLog.Print($"[MeltySynthPlayer] connected AndroidBridge.command_received err={err}");
		}
		// 音频焦点：Java 侧 OnAudioFocusChangeListener → audio_focus_changed(state)，
		// 这里转成同名 C# 信号供 GDScript（PlaybackDisplay → PlayView）消费。
		if (backend.HasSignal("audio_focus_changed"))
		{
			var focusCallable = Callable.From<int>(OnAudioFocusChangedSignal);
			if (!backend.IsConnected("audio_focus_changed", focusCallable))
			{
				var ferr = backend.Connect("audio_focus_changed", focusCallable);
				ThreadSafeLog.Print($"[MeltySynthPlayer] connected AndroidBridge.audio_focus_changed err={ferr}");
			}
		}
	}

	/// <summary>音频焦点变化：只做转发，不在这里决定暂停/恢复策略
	/// （策略归显示层：打歌页要弹暂停菜单，播放器页只需停播）。</summary>
	private void OnAudioFocusChangedSignal(int state)
	{
		ThreadSafeLog.Print($"[MeltySynthPlayer] audio focus changed: state={state}");
		EmitSignal(SignalName.audio_focus_changed, state);
	}

	/// <summary>
	/// 主动触发一次托管堆回收，供 GDScript（MemoryGC / 后台内存压力）调用。
	///
	/// 为什么值得主动做：`dumpsys meminfo` 里我们的 Native Heap 常驻约 100MB，
	/// 其中一大块是 CoreCLR 的 GC 堆已提交页 —— 而 CoreCLR 默认**不主动把已提交页还给 OS**，
	/// 要等下一次分配压力或 GC 才可能收缩，空闲进程可能长期占着。
	/// 大块临时分配之后（SoundFont 30MB 解析、MIDI 解析的成批临时数组）主动收一次，
	/// 能把已经变成垃圾的那批还回去。
	///
	/// 代价：gen2 全回收 + LOH 压缩会停顿几十毫秒级，**绝不能放在对局中或切曲关键路径上**；
	/// 调用点是后台内存回收，那个时机没有实时性要求。
	/// </summary>
	public void collect_managed_garbage()
	{
		var before = System.GC.GetTotalMemory(false);
		System.GC.Collect();
		System.GC.WaitForPendingFinalizers();
		// 再收一次：第一次回收触发的 finalizer 可能又释放了新的可回收对象
		System.GC.Collect();
		var after = System.GC.GetTotalMemory(false);
		ThreadSafeLog.Print($"[MeltySynthPlayer] managed GC: {before / 1048576.0:F1}MB -> {after / 1048576.0:F1}MB");
	}

	private void OnMediaCommandSignal(string action, double posMs)
	{
		if (action != "bg_tick")   // 每秒一次的唤醒不该刷屏（真正的换曲会自己打日志）
		{
			ThreadSafeLog.Print($"[MeltySynthPlayer] media command: {action} ({posMs:F0}ms)");
		}
		HandleMediaCommandExternal(action, posMs);
	}

	private void PollMediaCommands()
	{
		if (_smtcBackend != null && _smtcBackend.HasMethod("poll_command"))
		{
			var res = _smtcBackend.Call("poll_command").AsGodotArray();
			if (res.Count > 0)
			{
				string action = res[0].AsString();
				double pos = res.Count > 1 ? res[1].AsDouble() : -1.0;
				HandleMediaCommandExternal(action, pos);
			}
		}
	}

	/// <summary>外部命令统一入口：处理 + 回推权威状态。</summary>
	private void HandleMediaCommandExternal(string action, double posMs)
	{
		// 【Java ticker 的"喂"】熄屏/后台时帧回调不跑，但主线程仍在派发信号（媒体按钮就是这么生效的）。
		// 这里做的检查与前台 _Process 完全相同 —— 自动切歌因此不需要独立线程，也不需要回调换手。
		if (action == "bg_tick")
		{
			TickEndOfSequenceOnMainThread();
			return;
		}
		// 【媒体门控：未注册媒体会话就丢弃 —— 等价旧 `SystemMediaSession` 的
		// `if not has_view(): return`】判据是**注册状态**而不是页面状态，理由见
		// is_media_command_allowed_here 的说明。PlayView 刻意不注册，于是
		// "打歌中按耳机键无效果"由注册状态天然保证，不会被打断、也不会误重开歌单。
		if (!is_media_command_allowed_here())
		{
			ThreadSafeLog.Print($"[MeltySynthPlayer] external media command ignored (no media view registered): {action}");
			return;
		}

		// 上下首：与旧 `_on_backend_command` 一致 —— **无条件**交给中心执行器
		// （handle_media_command 内部自己 ensure_user_playlist + play_next/play_previous），
		// 处理完一律进播放器页（这是该页面的入口语义，与歌单是否为空无关）。
		// 【刻意不按"当前是否在播放器页"分支】曾经的分支会让 TrackView 里的"下一首"
		// 变成"丢弃当前会话、从用户歌单第一首重开"，与 55b11058 的行为不一致。
		if (action == "next" || action == "prev")
		{
			handle_media_command(action, posMs);
			PushMediaState(true);
			NavigateToPlayer();
			return;
		}
		handle_media_command(action, posMs);
		PushMediaState(true);
	}

	/// <summary>
	/// 当前是否接受系统媒体命令。**等价于旧实现 `SystemMediaSession.has_view()`** ——
	/// 只要有页面注册了媒体会话（播放器页 / TrackView）就接受，与"此刻停在哪个页面"无关。
	///
	/// 【为什么不能用 UI 状态代替（曾经就是这么写的，会丢命令）】
	/// 旧的门是**注册状态**：`if not has_view(): return`。改成"current_state ∈ {播放器页, TrackView}"
	/// 之后，凡是"已注册但 current_state 不是这两个值"的窗口 —— 视图切换过渡期间、叠层子页推栈、
	/// 回前台后的状态对账、TrackView 内的次级状态 —— 都会把合法的系统命令直接丢掉，
	/// 表现为**后台拖通知栏进度条没反应/像卡住**（55b11058 及以前没有这个问题）。
	/// 深后台/熄屏时 UI 状态根本不变，注册状态才是权威；PlayView 刻意不注册，
	/// 于是"打歌中按耳机键无效果"这条语义由注册状态天然保证，无需页面判断。
	/// </summary>
	public bool is_media_command_allowed_here() => _mediaViewRegistered;

	private double _bgPreparseAccum = 0.0;

	/// <summary>
	/// 下一首的「主线程预取」快照：后台换曲要用的路径 / 歌名 / 专辑 / 封面路径 / (track,channel) 对，
	/// 全部在主线程算好。
	///
	/// 【为什么是一个不可变对象而不是几个散字段】后台线程要读它，主线程要写它。
	/// 若写成 `_bgNextKey` / `_bgNextPath` / … 这样一组散字段，读者可能看到"新的 key + 旧的 path"
	/// 这种撕裂组合（无同步的多字段发布）。改成**一次性发布整份不可变快照**后，读者只需
	/// `var info = _bgNext;` 取一次引用，之后读到的必定是同一首歌的全套字段。
	/// volatile 保证引用本身的可见性与有序性。
	/// </summary>

	/// <summary>已预解析过的 key（主线程持有，避免重复解析）</summary>
	/// <summary>后台换曲调用 apply_chart_audio_config 时的一次性 pairs 覆盖（同线程设置/消费）</summary>
	private int[] _bgPairsOverride = null;


	private void NavigateToPlayer()
	{
		var ui = GetNodeOrNull("/root/UiStatMGR");
		if (ui == null)
		{
			return;
		}
		if (ui.Get("current_state").AsInt32() == UiStateMusicPlayerView)
		{
			return;   // 已在该页：再 change_state 只会打一条 "can not change state" 噪音
		}
		var hist = ui.Get("state_history");
		if (hist.VariantType == Variant.Type.Array)
		{
			var arr = hist.AsGodotArray();
			int idx = arr.IndexOf(UiStateTrackView);
			if (idx >= 0)
			{
				arr.RemoveAt(idx);
			}
			ui.Set("state_history", arr);
		}
		ui.Call("change_state", UiStateMusicPlayerView, false);
	}

	private ulong _lastMediaPushTicks = 0;
	private const ulong MediaPushIntervalMs = 500;

	// ===== 媒体元数据缓存 =====
	// 推送节流到 0.5s 一次，但"歌名/专辑/封面"在一次播放里是不变的：每次重算会走
	// ResolveChartTitle（两次 LiteDB 查字段）、GetChartFieldPlain、GetCoverPath ——
	// 之前更是整份 GetChartJson（组装完整 MidiData 字典，含 search_* 副本）只为读一个
	// album_name。纯后台听歌时这是白烧的 CPU，故只在**换曲**时重算一次。
	private string _mediaMetaKey = null;
	private string _mediaMetaTitle = "";
	private string _mediaMetaAlbum = "";
	private byte[] _mediaMetaCover = Array.Empty<byte>();

	/// <summary>按需重建媒体元数据缓存（key 未变则零开销）。</summary>
	private void EnsureMediaMetadata(ChartDb db)
	{
		if (_mediaMetaKey == _currentKey)
		{
			return;
		}
		_mediaMetaKey = _currentKey;
		_mediaMetaTitle = ResolveChartTitle(db, _currentKey);
		// 纯字段读取：不组装 Godot 字典（原实现为取 album_name 调了整份 GetChartJson）
		_mediaMetaAlbum = db != null ? db.GetChartFieldPlain(_currentKey, "album_name") : "";
		_mediaMetaCover = ResolveCoverPng(db, _currentKey);
	}

	/// <summary>
	/// 撤下系统媒体通知并清空媒体侧状态（离开播放器页 / 音轨页 = 退出播放时调用）。
	///
	/// 旧 SystemMediaSession.unregister_view 在 stop() 之后还会 `_backend.clear()`：
	/// 页面注销 = 没人听了，通知与前台服务一并撤掉。重构后只调了 stop()，
	/// 于是通知会以 STOPPED 状态一直挂在通知栏里（前台服务也不退）。
	/// 只动媒体状态，不影响播放器的当前曲/播放列表（TrackView 还要复用当前曲）。
	/// </summary>
	public void clear_media_notification()
	{
		_mediaViewRegistered = false;   // 注销视图：后续周期推送不得再重建通知
		_mediaCleared = true;
		_mediaMetaKey = null;
		AndroidBackend()?.Call("clear");
		_smtcBackend?.Call("clear");
	}

	/// <summary>页面注册媒体会话（播放器页 / TrackView）＝ 旧 SystemMediaSession.register_view。</summary>
	public void register_media_view()
	{
		_mediaViewRegistered = true;
		PushMediaState(true);   // 立刻推一次，避免等下一个节拍
	}

	/// <summary>[诊断/回归] 当前是否有页面注册了媒体会话。</summary>
	public bool is_media_view_registered() => _mediaViewRegistered;


	/// <summary>立刻推一次媒体状态（页面注册时调用，避免等下一个 0.5s 节拍）</summary>
	public void refresh_media_state() => PushMediaState(true);

	/// <summary>向系统推送播放状态与元数据。force=true 无视节流。</summary>
	private void PushMediaState(bool force)
	{
		string os = OS.GetName();
		if (os != "Android" && os != "Windows")
		{
			return;
		}
		// 【旧 has_view() 门】没有页面注册时不推送，且保证通知处于已撤下状态。
		// 少了这道门，周期推送会把刚撤下的通知又建回来（见 _mediaViewRegistered 的说明）。
		if (!_mediaViewRegistered)
		{
			if (!_mediaCleared)
			{
				clear_media_notification();
			}
			return;
		}

		// 【Android 不再周期推送位置】系统按 PlaybackState(position, speed, updated) 自行外推，
		// 周期性推送纯属 JNI / 系统服务开销。事件点（play/pause/seek/换歌/恢复）走 force=true；
		// 非 force 的调用只在"播放态发生变化"时才真推。
		if (os == "Android" && !force && playing == _lastPushedPlaying)
		{
			return;
		}
		// 位置推送节流：系统侧按 playback_rate 自行外推，无需每帧刷新（JNI/COM 调用很贵）
		ulong now = Time.GetTicksMsec();
		if (!force && now - _lastMediaPushTicks < MediaPushIntervalMs)
		{
			return;
		}
		_lastMediaPushTicks = now;
		_lastPushedPlaying = playing;
		if (os == "Android" && AndroidBackend() == null)
		{
			return;
		}
		if (string.IsNullOrEmpty(_currentKey))
		{
			if (!_mediaCleared)
			{
				clear_media_notification();
			}
			return;
		}
		_mediaCleared = false;

		var db = GetNodeOrNull<ChartDb>("/root/ChartDB");
		EnsureMediaMetadata(db);
		double durationMs = get_duration_ms();
		double positionMs = Math.Max(0.0, get_position_ms());

		if (os == "Android")
		{
			AndroidBackend()?.Call("update_state", playing, positionMs, durationMs,
				_mediaMetaTitle, _mediaMetaAlbum, _mediaMetaCover);
		}
		else if (_smtcBackend != null)
		{
			_smtcBackend.Call("update_state", playing, positionMs, durationMs,
				_mediaMetaTitle, _mediaMetaAlbum, _mediaMetaCover);
		}
	}

	private byte[] ResolveCoverPng(ChartDb db, string key)
	{
		string path = db != null ? db.GetCoverPath(key) : "";
		if (string.IsNullOrEmpty(path))
		{
			return Array.Empty<byte>();
		}
		if (path.StartsWith("user://") || path.StartsWith("res://"))
		{
			path = ProjectSettings.GlobalizePath(path);
		}
		if (_lastPushedCoverPath == path && _lastPushedCover.Length > 0)
		{
			return _lastPushedCover;
		}
		if (_coverPngCache.TryGetValue(path, out var cached))
		{
			_lastPushedCoverPath = path;
			_lastPushedCover = cached;
			return cached;
		}
		try
		{
			var img = Image.LoadFromFile(path);
			if (img == null)
			{
				return Array.Empty<byte>();
			}
			if (img.IsCompressed())
			{
				img.Decompress();
			}
			var png = img.SavePngToBuffer();
			_coverPngCache[path] = png;
			_lastPushedCoverPath = path;
			_lastPushedCover = png;
			return png;
		}
		catch (Exception e)
		{
			ThreadSafeLog.PrintErr($"[MeltySynthPlayer] cover encode failed: {path} ({e.Message})");
			return Array.Empty<byte>();
		}
	}


	// ===================== 后端能力门面（UI 直调） =====================

	/// <summary>播放（含置位暂停态 + 广播）。UI 用。</summary>
	public void play_transport()
	{
		_paused = false;
		if (!play())
		{
			return;
		}
		EmitSignal(SignalName.playback_state_changed);
	}

	// ===== 视觉校准延迟（Gameplay/audio_playback_delay）=====
	private double _audioDelayMs = 0.0;

	/// <summary>下发视觉校准延迟（GDScript 按输出是否蓝牙算好）。</summary>
	public void set_audio_delay_ms(double ms) => _audioDelayMs = ms;


	/// <summary>
	/// 供显示用的位置：扣除视觉校准延迟（与旧 GDScript _process 口径一致）。
	///
	/// 【负值必须原样透出】开局预卷走的是负时间轴（PlayView 用 seek(-1000 - note_fall_time*1000)
	/// 开场，判定/渲染都靠它把音符从屏幕上方落下来）。原来这里无条件 Math.Max(0.0, ...)，
	/// 会把整个预卷钳成 0 —— 真机表现：准备动画结束后 current_time 从 0 起跳，
	/// 生成提前量恰好等于下落时间，第一批音符生成即过线 → 开局全部 Miss，
	/// 之后判定钟靠慢速校准一点点把墙钟拉回真实值，要几十秒才"恢复正常"。
	/// 校准延迟只对"已经超过 0 的播放位置"有意义，预卷阶段没有设备延迟可扣。
	/// </summary>
	public double get_visual_position_ms()
	{
		double pos = get_position_ms();
		if (pos < 0.0)
		{
			return pos;
		}
		return Math.Max(0.0, pos - _audioDelayMs);
	}

	// ===== 人声门面（原 GDScript MidiPlaybackManager 的转发）=====

	public bool play_vocal_file(string path, double offsetMs)
	{
		if (string.IsNullOrEmpty(path) || !(_audioOutput is MiniaudioAudioOutputBridge ma))
		{
			return false;
		}
		string native = GlobalizeNativePath(path);
		if (_loadedVocalFilePath != native)
		{
			if (!FileExistsSafe(native))
			{
				return false;
			}
			if (!ma.LoadVocalFile(native))
			{
				return false;
			}
			_loadedVocalFilePath = native;
		}
		ma.SeekVocal(Math.Max(0.0, offsetMs));
		ma.ResumeVocal();
		return true;
	}

	public void stop_vocal_file()
	{
		if (_audioOutput is MiniaudioAudioOutputBridge ma)
		{
			ma.StopVocal();
		}
	}

	/// <summary>
	/// 显示侧显式指定人声文件，并立刻对齐到给定 MIDI 位置起播。
	///
	/// 与 <see cref="apply_chart_audio_config"/> 的分工：那条路从 chart_runtime 读权威配置，
	/// 而 TrackView 中途「导入人声 / 切回启用人声」时新路径可能还只在显示侧的 MidiData 里
	/// （尚未落盘到 chart_runtime），所以这里由调用方把路径与偏移直接传进来——
	/// 也就是"Godot 只在真的需要时才把数据交过来"。
	/// </summary>
	public bool start_vocal_at(string path, double offsetMs, double midiPositionMs)
	{
		if (string.IsNullOrEmpty(path) || !(_audioOutput is MiniaudioAudioOutputBridge ma))
		{
			return false;
		}
		string native = GlobalizeNativePath(path);
		// 绝对路径用 System.IO（后台/主线程都安全）；res:// 走主线程引擎回退
		if (!FileExistsSafe(native))
		{
			ThreadSafeLog.PrintErr($"[MeltySynthPlayer] start_vocal_at: file not found: {native}");
			return false;
		}
		if (_loadedVocalFilePath != native)
		{
			if (!ma.LoadVocalFile(native))
			{
				return false;
			}
			_loadedVocalFilePath = native;
		}
		_vocalFinishedSignaled = false;
		ma.SetVocalVolume(_vocalVolumeLinear);
		// 偏移门控先就位，再按 MIDI 位置对齐（SeekVocalToMidi 会用 get_vocal_offset_ms 扣偏移）
		ma.SetVocalOffsetMs(offsetMs > 0.0 ? offsetMs : 0.0);
		ma.ResetVocalOffsetGate();
		SeekVocalToMidi(midiPositionMs);
		if (playing)
		{
			ma.ResumeVocal();
		}
		ThreadSafeLog.Print($"[MeltySynthPlayer] start_vocal_at: {native} midi={midiPositionMs:F0}ms offset={offsetMs:F0}ms");
		return true;
	}

	/// <summary>当前曲是否装载了可用人声（UI 判断"人声轨道是否可播"用）。</summary>
	public bool has_vocal() => _audioOutput is MiniaudioAudioOutputBridge ma && ma.IsVocalLoaded;

	public void stop_vocal_playback() => stop_vocal_file();

	/// <summary>
	/// 由显示侧告知"用户在本曲里显式开关了人声"（TrackView 的人声启用按钮）。
	///
	/// 关闭时不只是停播：还要**抑制自动同步把人声又拉起来**，并按关闭处理让后续
	/// apply_chart_audio_config 不再重新装载它。旧实现把这件事记在 MidiData.vocal_enabled 上、
	/// 由 _sync_vocal_with_midi 每次检查；播放侧读不到显示侧数据，故改为显式告知。
	/// 换曲/stop 会复位回"由配置决定"。
	/// </summary>
	public void set_vocal_enabled_runtime(bool enabled)
	{
		_vocalDisabledByUser = !enabled;
		if (!enabled)
		{
			stop_vocal_file();
		}
	}

	/// <summary>音源未就绪而推迟起播中（UI 读取用）</summary>
	public bool get_deferred_play_pending() => _pendingPlayAfterLoad;


	public void set_vocal_playing(bool on)
	{
		if (_audioOutput is MiniaudioAudioOutputBridge ma)
		{
			if (on) { ma.ResumeVocal(); } else { ma.PauseVocal(); }
		}
	}

	public double get_vocal_position() =>
		_audioOutput is MiniaudioAudioOutputBridge ma ? ma.GetVocalPositionMs() : 0.0;

	public void set_vocal_volume_db(double db) => set_vocal_volume(Mathf.DbToLinear((float)db));

	public double get_vocal_volume_db() =>
		_vocalVolumeLinear <= 0.0001f ? -80.0 : Mathf.LinearToDb(_vocalVolumeLinear);

	/// <summary>
	/// 延迟设置变化而播放继续时，把人声重新对齐到当前位置。
	///
	/// 必须走 SeekVocalToMidi（会扣掉 vocal_offset_ms 并处理"还没到人声起点"的负值情形），
	/// 而不是直接 SeekVocal(raw)：旧实现的 _seek_vocal_to_midi_position 就是
	/// `raw_pos - vocal_offset_ms`，漏掉这一步会让刚改完偏移的人声整整偏一个 offset。
	/// </summary>
	public void apply_vocal_offset()
	{
		SeekVocalToMidi(get_raw_position_ms());
	}

	public void set_sync_threshold(double ms) => _vocalSyncThresholdMs = (float)Math.Clamp(ms, 1.0, 100000.0);

	/// <summary>当前生效的人声漂移同步阈值（毫秒）。供设置页/诊断显示与回归验证读取。</summary>
	public int get_sync_threshold_ms() => (int)Math.Round(_vocalSyncThresholdMs);


	/// <summary>播放器页 MIDI 音量（线性）。未设置过（哨兵 -1）时**回退全局默认** ——
	/// 绝不能把哨兵交给 UI：滑块 min=0 会把它钳成 0，页面随即把 0 存回配置（音量"回退"的根因）。</summary>
	public double get_player_midi_linear() =>
		_playerMidiVolumeLinear >= 0.0f ? _playerMidiVolumeLinear : _cachedDefaultMidiVolume;

	/// <summary>播放器页人声音量（dB）；未设置过返回 0dB，静音返回 -80dB</summary>
	public double get_player_vocal_db() =>
		_playerVocalVolumeLinear < 0.0f
			? (_cachedDefaultVocalLinear <= 0.0001f ? -80.0 : Mathf.LinearToDb(_cachedDefaultVocalLinear))
			: (_playerVocalVolumeLinear <= 0.0001f ? -80.0 : Mathf.LinearToDb(_playerVocalVolumeLinear));

	/// <summary>音源是否仍在加载/切换（TrackView 挂在 soundfont_reload_completed 前的等待判据）</summary>
	public bool is_soundfont_reload_pending() => !_sfFinalized && (_sfLoadThread != null || _sfParseDone);

	// ===== 音源 =====

	private bool _soundfontPreloaded = false;

	/// <summary>确保音源已下发到后端（幂等）。</summary>
	public void ensure_soundfont_loaded(string soundfontPath)
	{
		if (_soundfontPreloaded || string.IsNullOrEmpty(soundfontPath))
		{
			return;
		}
		_soundfontPreloaded = true;
		set_soundfont(soundfontPath);
	}
}
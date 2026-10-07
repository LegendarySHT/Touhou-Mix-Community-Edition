using Godot;
using MeltySynth;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using TouhouMix.Midi;

/// <summary>
/// Meltysynth MIDI 播放器后端
/// 提供与 GDScript 后端一致的 API
/// </summary>
public partial class MeltySynthPlayer : Node
{
	// 可见性: internal 以便 partial 文件 (MeltySynthPlayer.MiniaudioBridge.cs) 中的
	// MiniaudioAudioOutputBridge 实现此接口
	internal interface IAudioOutputBridge
	{
		bool Initialize(Node owner, StringName bus, int sampleRate);
		void SetBus(StringName bus);
		void Play();
		void Stop();
		void Update();
		bool IsPlaying { get; }
		object SyncRoot { get; }
		void SetSynthesizers(MidiFileSequencer sequencer, Synthesizer autoSynth, Synthesizer manualSynth, bool useSeparateSynth);
		void SetVolume(float volumeLinear);
		void EnqueueNoteOn(int virtualId, int pitch, int velocity);
		void EnqueueNoteOff(int virtualId, int pitch);
		void Dispose();
		/// <summary>设置 post-seek 后需要静音渲染丢弃的帧数 (用于消耗 seek 瞬态).</summary>
		int PostSeekSilenceFrames { get; set; }
		/// <summary>获取当前音频输出延迟(毫秒), 包含设备内部延迟 + RingBuffer 延迟.</summary>
		float GetLatencyMs();
		bool LoadVocalFile(string path);
		void UnloadVocal();
		void PlayVocal();
		void PauseVocal();
		void ResumeVocal();
		void StopVocal();
		void SeekVocal(double positionMs);
		void SetVocalVolume(float volumeLinear);
		double GetVocalPositionMs();
		double GetVocalLengthMs();
		bool IsVocalPlaying();
		bool IsVocalFinished();
		uint GetVocalUnderrunCount();
	}
	[Signal]
	public delegate void finishedEventHandler();

	[Signal]
	public delegate void vocal_finishedEventHandler();

	[Signal]
	public delegate void soundfont_changedEventHandler(string soundfont_path);

	public int max_polyphony = 96;
	private float _volume_db = -20.0f;
	private string _soundfont = "";
	// 【跨线程】_file 由主线程（set_file / 前台换曲）与后台换曲线程（LoadMidiFile 前赋值）写入，
	// 且 get_file / apply_chart_audio_config 会从两侧读。字符串引用写入本身是原子的，
	// volatile 只是补齐可见性（否则后台写的新值可能长时间不被主线程观察到）。
	private volatile string _file = "";
	// 【跨线程】playing 是传输真值，主线程（play/pause/stop）与后台换曲线程都会写，UI 与
	// 曲终判定会读。非 volatile 时 JIT 可能把读结果留在寄存器里，导致"后台换曲后前台仍以为没在播"。
	public volatile bool playing = false;
	private StringName _bus = new StringName("Master");

	// 用户为 (track, channel) 指定的乐器覆盖（TrackView 改音色）。
	// 【线程模型】存**托管**容器而非 Godot.Collections.Dictionary：熄屏后台的换曲线程会在
	// 非主线程走 LoadMidiFile → 清空这份表，而 Godot 容器跨线程写会与冻结的主线程抢引擎锁。
	// 面向 GDScript 的读取（get_track_channel_instrument）在主线程按需包装成 Godot 字典。
	private readonly ConcurrentDictionary<int, ConcurrentDictionary<int, (int bank, int program)>> _trackChannelInstruments = new();

	// 【跨线程】主线程创建/重建（含 _ExitTree 置 null），后台换曲线程读它以重置回绕基准
	// （LoadMidiFile 里的 ResetEndOfSequence —— 少了它新曲起点会被回调误判为"又回绕一次"，
	// 表现是连续切歌）。引用写入原子，volatile 补可见性：陈旧 null 会静默跳过那次重置。
	private volatile IAudioOutputBridge _audioOutput;

	private Synthesizer _synth;
	private MidiFileSequencer _sequencer;
	// 【跨线程】_midiFile 由后台换曲线程在 LoadMidiFile 里替换，主线程 get_duration_ms /
	// get_position_ms / PushMediaState 会读。引用写入原子，volatile 补可见性。
	private volatile MidiFile _midiFile;
	private SoundFont _soundFont;

	private int _sampleRate;
	// 线程模型说明（TMX-005）：
	// - 下列标量字段（_volumeLinear/_sequencerStarted/_pendingSeekMs/_currentOffsetMs/_lastPositionMs/
	//   _hasSkippedPreroolEvents/_judgeAnchorMs/_judgeAnchorTicks/_judgeAnchorValid/_lastRenderedRefMs 等）
	//   均仅由主线程读写；音频线程在 MiniaudioBridge 内有自己的
	//   _volumeLinear/_playing 副本并通过 _synthLock 保护合成器引用交换，不直接访问本类标量字段，
	//   因此无需 volatile（double 也无法标记 volatile）。
	// - 真正跨线程共享的是下方字典：音频回调 handler 链（OnSendMessage）读写 vs 主线程
	//   set_track_channel_* 写入，全部改为 ConcurrentDictionary；
	//   _manualFilterRegistry 采用"不可变快照 + volatile 引用交换"（播放中禁止重建）。
	private float _volumeLinear = 1.0f;
	private bool _sequencerStarted = false;  // 追踪 sequencer 是否已启动
	private double _pendingSeekMs = double.NaN;  // 待处理的 seek 位置（NaN 表示无待处理的 seek）
	private double _currentOffsetMs = 0.0;  // 当前相对于 sequencer 的时间偏移（支持负数 pre-roll）
	private double _lastPositionMs = 0.0;  // 最后已知播放位置（暂停/seek 后保持，供 get_position_ms 读取）
	private int _seekPositionHoldFrames = 0;  // seek 后短暂保持目标位置，避免渲染钟未更新瞬回 0
	private bool _hasSkippedPreroolEvents = false;  // 标志：已跳过 pre-roll 事件

	// ============ 判定钟：墙钟锚点推进 + 音频参考慢速校准 ============
	// 判定位置 = 锚点位置 + 墙钟流逝 × Speed − 设备延迟；锚点在 play/seek/pause/resume/
	// stop/loop 回绕等边界重设。与音频回调解耦后，回调被延迟调度时判定位置仍连续推进，
	// 消除"点了没判定 / 判定滞后"（旧实现的外推上限一旦封顶就会冻结判定）。
	// 注意：人声同步走 get_raw_position_ms()（音频回调钟），不使用本钟。
	private double _judgeAnchorMs = 0.0;      // 锚点位置（毫秒，未扣设备延迟）
	private long _judgeAnchorTicks = 0;       // 锚点对应的墙钟时间戳
	private bool _judgeAnchorValid = false;   // 锚点是否有效（play/seek/暂停/停止后失效，下次读取重建）
	private double _lastRenderedRefMs = 0.0;  // 上次读到的音频渲染钟，用于识别 loop 回绕
	// seek 目标位置：重锚判定钟时优先用它，而不是等音频渲染钟追上。
	// 否则拖动进度条后渲染钟仍是旧位置，墙钟从旧值起算导致进度条复位到错误位置。
	private double _seekAnchorMs = double.NaN;
	private const double JudgeCalibrationDeadbandMs = 25.0;  // 音频参考误差超过此值视为真实欠载，不做校准
	private const double JudgeSlewGain = 0.02;               // 每次读取吸收的误差比例（慢速校准，避免跳变）
	private const double JudgeWrapBackwardEpsilonMs = 1.0;   // 渲染钟回跳超过此值视为 loop 回绕
	private readonly ConcurrentDictionary<int, float> _virtualChannelVolumes = new ConcurrentDictionary<int, float>();
	private readonly ConcurrentDictionary<int, (int bank, int program)> _virtualChannelInstruments = new ConcurrentDictionary<int, (int bank, int program)>();
	private readonly ConcurrentDictionary<int, int> _virtualChannelCurrentBank = new ConcurrentDictionary<int, int>();
	private readonly ConcurrentDictionary<int, int> _virtualChannelCurrentProgram = new ConcurrentDictionary<int, int>();
	private readonly ConcurrentDictionary<int, int> _virtualChannelCc7 = new ConcurrentDictionary<int, int>();
	private readonly ConcurrentDictionary<int, int> _virtualChannelCc11 = new ConcurrentDictionary<int, int>();
	private readonly ConcurrentDictionary<int, int> _virtualChannelCc10 = new ConcurrentDictionary<int, int>();
	private readonly ConcurrentDictionary<int, int> _virtualChannelPitchBend = new ConcurrentDictionary<int, int>();

	private readonly ManualNoteFilterRegistry _manualFilterRegistry = new ManualNoteFilterRegistry();
	private readonly ConcurrentDictionary<int, byte> _mutedVirtualChannels = new ConcurrentDictionary<int, byte>();
	private bool _vocalFinishedSignaled = false;
	/// <summary>
	/// 用户在本曲里显式关掉了人声（TrackView 的人声开关）。
	/// 旧实现把这件事记在 `MidiData.vocal_enabled` 上，`_sync_vocal_with_midi` 顶部每次都会检查
	/// `current_midi_data.vocal_enabled`，因此"关掉之后不会被自动同步又拉起来"。
	/// 播放侧现在读不到显示侧的 MidiData，改由调用方显式告知（set_vocal_enabled_runtime），
	/// 并在换曲/stop 时复位（人声开关是 per-MIDI 的，不该跨曲沿用）。
	/// volatile：主线程写（UI），音频回调侧的显示读取在主线程同步循环里。
	/// </summary>
	private volatile bool _vocalDisabledByUser = false;
	private string _loadedVocalFilePath = "";
	private float _vocalVolumeLinear = 1.0f;

	// ============ 选项 A：独立合成器用于低延迟手动音符 ============
	private Synthesizer _manualSynth;      // 专用于手动触发的音符
	private Synthesizer _autoSynth;        // 原有：用于MIDI自动播放（就是 _synth）
	private bool _useSeparateSynthForManual = true;  // 启用独立合成器

	// 音频 period 固定为低延迟档（256×2），不随页面切换。
	// 曾有过"听歌降耗档"（播放器页拉大到 4096×3）：实测省电收益可忽略，却要
	// 在页面进出时反复重建输出桥（切页卡顿），且大缓冲下人声位置读数量化严重，
	// 会持续触发人声 seek。已整体移除。
	private const int GameplayPeriodFrames = 256;
	private const int GameplayPeriodCount = 2;
	private bool _preferNativeSequencerSeek = true;

	// 系统时钟模式请求状态（配置来源 Playback/use_system_stopwatch）。
	// sequencer 在 soundfont / 采样率重建时会重新创建，创建点按本字段恢复模式，避免被静默重置为关闭。
	private bool _systemClockRequested = false;

	// 当前请求与已创建设备使用的 period 帧数
	private int _desiredBufferFrames = GameplayPeriodFrames;
	private int _desiredPeriodCount = GameplayPeriodCount;
	private int _activeAudioPeriodFrames = 0;

	// 跟踪已应用通道状态到手动合成器的虚拟通道，避免每次触发音符重复设置
	private readonly ConcurrentDictionary<int, byte> _channelStateAppliedToManual = new ConcurrentDictionary<int, byte>();

	// ============ OnSendMessage 拦截器管道 ============
	private MessageHandlerContext _messageContext;
	// 管道只构建一次，但用 volatile 引用交换保证音频线程迭代的是一致快照
	private volatile IReadOnlyList<IMidiMessageHandler> _handlers = Array.Empty<IMidiMessageHandler>();

	// ============ 后台线程加载 SoundFont（避免启动期 3-5s 解析阻塞主线程）============
	// 解析与合成器/序列器创建在 worker 线程完成（纯 C#，不碰 Godot/音频桥），
	// 主线程在 _Process 里 FinalizeSoundfontLoad 完成合成器引用与音频桥绑定（必须主线程）。
	private Thread _sfLoadThread = null;
	private readonly object _sfLock = new object();
	private volatile bool _sfParseDone = false;
	private bool _sfFinalized = false;
	private SoundFont _sfPendingSoundFont;
	private Synthesizer _sfPendingAuto;
	private Synthesizer _sfPendingManual;
	private MidiFileSequencer _sfPendingSeq;
	private MessageHandlerContext _sfPendingMsgCtx;
	private List<IMidiMessageHandler> _sfPendingHandlers;
	// 音源后台加载完成前若已调用 play()/load_midi，记录意图待 FinalizeSoundfontLoad 补启动
	private bool _pendingPlayAfterLoad = false;

	// 当前在响音符集合（自动音符，经序列器管道产生）：暂停时记录、续播时重发以延续长音。
	// 键为 (virtualChannel, key)，值为 velocity。手动音符走 _manualSynth 不经过管道，不纳入。
	private readonly object _activeNotesLock = new object();
	private readonly Dictionary<(int, int), int> _activeNotes = new Dictionary<(int, int), int>();
	// 暂停时记录：是否需要在续播时重发在响音符，以及当时的音源代际
	private bool _restoreHeldNotes = false;
	private int _pausedSoundfontGen = 0;
	// 每次音源重建(finalize)自增；用于判断续播时音源是否与暂停时同一实例
	private int _soundfontGeneration = 0;

	private void RequestAudioOutputPlay()
	{
		if (_audioOutput == null) return;
		if (!_audioOutput.IsPlaying)
			_audioOutput.Play();
	}

	private void PrepareAudioOutputForPlaybackStart()
	{
		EnsureAudioInitialized();
	}

	// 【并发修复】MidiFileSequencer/Synthesizer 非线程安全：音频回调在 _synthLock 内执行
	// _sequencer.Render()（遍历 voices），主线程的 seek/play/stop 会调用 synthesizer.Reset()/
	// ProcessMidiMessage() 修改同一集合，无锁并发导致数组越界并持续报错。
	// 所有对 sequencer/synthesizer 的写操作必须在此锁内执行，与回调渲染互斥。
	// 注意：ma_bridge_stop（等待回调完成）与 ma_bridge_start 都必须在锁外调用，避免死锁。
	private void WithSynthLock(Action action)
	{
		if (_audioOutput is MiniaudioAudioOutputBridge maBridge)
		{
			lock (maBridge.SyncRoot)
			{
				action();
			}
		}
		else
		{
			// 无音频桥（无回调线程）时无需加锁
			action();
		}
	}


	private void EnsureAudioInitialized()
	{
		if (_audioOutput != null)
			return;

		// 【线程约束】音频桥必须在主线程创建：这里会调用 AudioServer.GetMixRate()/OS.GetName()
		// 等引擎 API，并绑定 Godot 节点。后台换曲线程理论上走不到（它要求 _audioOutput 已就绪），
		// 但 set_file()/resume() 都会顺路调用本方法，故显式挡一道：
		// 非主线程直接放弃创建，交由回前台后的主线程补上，绝不在后台碰引擎。
		if (!ThreadSafeLog.IsMainThread)
		{
			ThreadSafeLog.Print("[MeltySynthPlayer] EnsureAudioInitialized skipped on non-main thread (bridge stays null)");
			return;
		}

		// WASAPI 采样率策略 (借鉴 TouhouMix Unity 项目技巧, 仅 Windows 适用):
		// Realtek 驱动限制 WASAPI 共享模式 min period=480 帧.
		// - 480 帧 @ 48000Hz = 10ms (不达标)
		// - 480 帧 @ 96000Hz = 5ms  (达标 <10ms)
		// 提高采样率让同样帧数对应更短时间, 突破 Realtek 的 period 限制.
		// 如果设备原生支持 96000Hz, IAudioClient3 会用 96000Hz, period 降为 5ms.
		// 如果设备只支持 48000Hz, miniaudio 用内部重采样器做 96k→48k SRC.
		//
		// 【注意】96000Hz 技巧仅 Windows/WASAPI 需要. Android/iOS 的 AAudio/OpenSL
		// 后端本身就支持低延迟 (AAUDIO_CONTENT_TYPE_MEDIA, framesPerBurst 通常 192-240),
		// 无需高采样率技巧. 强制 96000Hz 会导致:
		//   - Android: AAudio 后端初始化失败 (noAutoConvertSRC 是 WASAPI 专用)
		//   - iOS: 类似不兼容
		// 【方向 1】Android 改为请求设备原生采样率 (cfg.SampleRate=0, 见下方 useDeviceNativeRate)，
		// 不再跟随 AudioServer.GetMixRate()；iOS 仍使用系统 mix rate。
		//
		// 环境变量 MINIAUDIO_SAMPLE_RATE 可覆盖默认采样率 (方便测试).
		// 独占模式必须用设备原生采样率 (通常 48000Hz), 不能强制 96000Hz.
		int oldSampleRate = _sampleRate;
		_sampleRate = (int)AudioServer.GetMixRate();  // 重新读取 (可能 44100)
		int targetRate = _sampleRate;  // 默认使用系统采样率
		// 仅 Windows 需要高采样率技巧突破 WASAPI period 限制
		var envRate = System.Environment.GetEnvironmentVariable("MINIAUDIO_SAMPLE_RATE");
		int envRateVal = 0;
		if (!string.IsNullOrEmpty(envRate) && int.TryParse(envRate, out envRateVal) && envRateVal > 0)
		{
			targetRate = envRateVal;
		}

		// 【方向 1】Android 默认用设备原生采样率初始化 miniaudio：
		// 显式请求 AudioServer.GetMixRate()（默认 44100）会让 AAudio 走系统 SRC/非原生路径，
		// Oboe 官方实测该路径往返延迟最坏可达 ~160ms；sampleRate=0 则由系统选择原生率（通常 48000）。
		// 设置 MINIAUDIO_NATIVE_SAMPLE_RATE=1 可在其他平台强制开启（用于验证重建路径）。
		bool useDeviceNativeRate = envRateVal <= 0 &&
			(OS.GetName() == "Android" ||
			 System.Environment.GetEnvironmentVariable("MINIAUDIO_NATIVE_SAMPLE_RATE") == "1");

		if (OS.GetName() == "Windows" && !useDeviceNativeRate)
		{
			// 独占模式必须用设备原生采样率 (通常 48000Hz), 共享模式用 96000Hz 突破 period 限制
			targetRate = (System.Environment.GetEnvironmentVariable("MINIAUDIO_EXCLUSIVE") == "1") ? 48000 : 96000;
		}
		if (_sampleRate != targetRate)
		{
			ThreadSafeLog.Print($"[MeltySynthPlayer] miniaudio: adjusting sample rate {_sampleRate} → {targetRate} " +
				$"({(OS.GetName() == "Windows" ? "high sample rate for lower latency" : "env override")})");
			_sampleRate = targetRate;
		}

		// 【关键修复】采样率变化时必须重建合成器, 否则合成器仍用旧采样率渲染.
		// 例: 合成器 44100Hz + 设备 96000Hz → 音高偏高 2.18x (尖锐声) + 序列器加速
		//     → 音符触发频率翻倍 → CPU 过载 → 大量 underrun.
		// _midiFile 对象独立于合成器, 重建后 play() 会用新 sequencer 重新加载它.
		// 原生采样率模式下跳过此处的提前重建：设备实际率在 Initialize 之后才可知，
		// 统一由"设备初始化后同步"块重建，避免先用旧率重建一次。
		if (_sampleRate != oldSampleRate && !useDeviceNativeRate && _autoSynth != null && !string.IsNullOrEmpty(_soundfont))
		{
			ThreadSafeLog.Print($"[MeltySynthPlayer] Sample rate changed {oldSampleRate}→{_sampleRate}, rebuilding synthesizers");
			LoadSoundfont(_soundfont);
		}

		var bridge = CreateAudioOutputBridge(useDeviceNativeRate);

		// 【关键】在 Initialize() 创建音频流之前先设置合成器引用
		// 否则 Initialize() 一触发 PCM 回调，合成器还来不及设置就会报 null 错误
		if (_sequencer != null && _autoSynth != null)
		{
			bridge.SetSynthesizers(_sequencer, _autoSynth, _manualSynth, _useSeparateSynthForManual);
			bridge.SetVolume(_volumeLinear);
		}

		if (!bridge.Initialize(this, _bus, _sampleRate))
		{
			ThreadSafeLog.PrintErr("[MeltySynthPlayer] Failed to initialize audio bridge. MIDI playback will be silent.");
			return;
		}

		// 【方向 1】设备已按原生采样率初始化：回读实际率，并与合成器/序列器对齐。
		if (useDeviceNativeRate && bridge is MiniaudioAudioOutputBridge maBridge && maBridge.ActualSampleRate > 0 && maBridge.ActualSampleRate != (uint)_sampleRate)
		{
			ThreadSafeLog.Print($"[MeltySynthPlayer] Device native sample rate: {maBridge.ActualSampleRate}Hz (synth was {_sampleRate}Hz), rebuilding synthesizers");
			_sampleRate = (int)maBridge.ActualSampleRate;
			if (_autoSynth != null && !string.IsNullOrEmpty(_soundfont))
			{
				LoadSoundfont(_soundfont);
			}
			// LoadSoundfont 内部绑定合成器时 _audioOutput 尚未赋值，这里须显式重新绑定到新桥
			maBridge.SetSynthesizers(_sequencer, _autoSynth, _manualSynth, _useSeparateSynthForManual);
			maBridge.SetVolume(_volumeLinear);
		}

		_audioOutput = bridge;
		_activeAudioPeriodFrames = ResolveAudioPeriodFrames(OS.GetName());
		ThreadSafeLog.Print("[MeltySynthPlayer] Audio bridge initialized with synthesizers preset");
	}

	private int ResolveAudioPeriodFrames(string osName)
	{
		if (osName == "Windows")
		{
			return System.Environment.GetEnvironmentVariable("MINIAUDIO_EXCLUSIVE") == "1" ? 128 : 256;
		}
		if (osName == "Android")
		{
			return _desiredBufferFrames;
		}
		return Math.Min(_desiredBufferFrames, 256);
	}

	private IAudioOutputBridge CreateAudioOutputBridge(bool useDeviceNativeRate)
	{
		// 使用 miniaudio 后端: 优先低延迟, RingBuffer 容量 ×3
		var maBridge = new MiniaudioAudioOutputBridge(0);

		var osName = OS.GetName();

		if (osName == "Windows")
		{
			// WASAPI 共享模式 (默认): period 被强制为 480 (≈10ms), 设备延迟 ~15ms.
			// 可与 Godot AudioServer 共存, 无冲突.
			//
			// WASAPI 独占模式: period 可设到 128 (≈2.7ms), 设备延迟 ~4ms.
			// 但独占模式与 Godot AudioServer 冲突, 会导致:
			//   1. "Device was unplugged" 警告刷屏
			//   2. 独占模式虽然 period=128 成功, 但可能无声音 (设备端点被 invalidate)
			// 要启用独占模式, 必须设 Godot audio/driver/driver="Dummy".
			// 通过环境变量 MINIAUDIO_EXCLUSIVE=1 启用独占模式.
			maBridge.SetBackend(MiniaudioNative.Backend.Wasapi);
			bool useExclusive = System.Environment.GetEnvironmentVariable("MINIAUDIO_EXCLUSIVE") == "1";
			maBridge.SetWASAPIExclusive(useExclusive);
		}
		else if (osName == "Android")
		{
			maBridge.SetBackend(MiniaudioNative.Backend.Aaudio);
			maBridge.SetAAudioExclusive(true);
		}

		var maPeriod = (uint)ResolveAudioPeriodFrames(osName);

		if (useDeviceNativeRate)
		{
			maBridge.UseDeviceNativeSampleRate(true);
		}

		// _decodeFrames 初始设为 period, Initialize 后会根据 actualPeriod 上调
		maBridge.SetDecodeFrames((int)maPeriod);
		maBridge.SetPeriodSize(maPeriod, (uint)_desiredPeriodCount);

		ThreadSafeLog.Print($"[MeltySynthPlayer] Creating miniaudio bridge: decode={maPeriod}f, period=({maPeriod},{_desiredPeriodCount}), os={osName}, exclusive={(osName == "Windows" ? (System.Environment.GetEnvironmentVariable("MINIAUDIO_EXCLUSIVE") == "1" ? "yes" : "no") : "n/a")}");
		return maBridge;
	}

	private void RecreateAudioOutputBridge()
	{
		if (_audioOutput == null)
		{
			EnsureAudioInitialized();
			return;
		}

		var wasPlaying = _audioOutput.IsPlaying;
		var wasVocalPlaying = _audioOutput.IsVocalPlaying();
		var vocalPositionMs = _audioOutput.GetVocalPositionMs();

		_audioOutput.Dispose();
		_audioOutput = null;
		_activeAudioPeriodFrames = 0;
		EnsureAudioInitialized();
		if (_audioOutput == null)
		{
			return;
		}

		if (_sequencer != null && _autoSynth != null)
		{
			_audioOutput.SetSynthesizers(_sequencer, _autoSynth, _manualSynth, _useSeparateSynthForManual);
			_audioOutput.SetVolume(_volumeLinear);
		}

		var vocalRestored = false;
		if (!string.IsNullOrEmpty(_loadedVocalFilePath))
		{
			_audioOutput.SetVocalVolume(_vocalVolumeLinear);
			vocalRestored = _audioOutput.LoadVocalFile(_loadedVocalFilePath);
			if (vocalRestored)
			{
				_audioOutput.SeekVocal(Math.Max(0.0, vocalPositionMs));
				_vocalFinishedSignaled = false;
				ThreadSafeLog.Print($"[MeltySynthPlayer] Vocal restored after audio bridge recreation: {vocalPositionMs:F1}ms");
			}
			else
			{
				ThreadSafeLog.PrintErr($"[MeltySynthPlayer] Failed to restore vocal after audio bridge recreation: {_loadedVocalFilePath}");
			}
		}

		if (wasPlaying)
		{
			_audioOutput.Play();
		}
		if (wasVocalPlaying && vocalRestored)
		{
			_audioOutput.PlayVocal();
		}
	}

	/// <summary>
	/// 设置音频缓冲区大小（帧）
	/// 注意：此设置需要重新初始化音频后端才能生效
	/// </summary>
	public void set_audio_buffer_frames(int frames)
	{
		// 对齐到 2 的幂，避免内部 DSP 块不对齐
		var aligned = 256;
		if (frames <= 256) aligned = 256;
		else if (frames <= 512) aligned = 512;
		else if (frames <= 1024) aligned = 1024;
		else aligned = 2048;
		
		// 检查缓冲区大小是否真的改变了
		if (_desiredBufferFrames == aligned &&
			(_audioOutput == null || _activeAudioPeriodFrames == ResolveAudioPeriodFrames(OS.GetName())))
		{
			ThreadSafeLog.Print($"[MeltySynthPlayer] Audio buffer frames already set to {aligned}, skipping reinitialization");
			return;
		}
		
		_desiredBufferFrames = aligned;
		ThreadSafeLog.Print($"[MeltySynthPlayer] Audio buffer frames: requested={frames}, aligned={aligned}");

		if (_audioOutput != null)
		{
			ThreadSafeLog.Print($"[MeltySynthPlayer] Recreating audio bridge with new buffer size: {aligned} frames");
			RecreateAudioOutputBridge();
		}
		else
		{
			ThreadSafeLog.Print("[MeltySynthPlayer] Audio bridge not yet created, new buffer size will be applied on next initialization");
		}
	}

	/// <summary>
	/// 强制重建音频输出设备（跟随当前系统默认输出端点）。
	/// 用于输出设备切换（如用户连接/断开蓝牙耳机）后重新路由音频：
	/// WASAPI/AAudio 流绑定打开设备时的端点，需销毁重建才会跟随新的系统默认设备。
	/// 复用 set_audio_buffer_frames 已验证的重建流程（销毁旧桥→重新初始化→恢复播放）。
	/// </summary>
	public void recreate_audio_output()
	{
		// 独占模式绑定固定设备端点，重建后目标端点可能不可用（如蓝牙），跳过并告警
		if (System.Environment.GetEnvironmentVariable("MINIAUDIO_EXCLUSIVE") == "1")
		{
			ThreadSafeLog.Print("[MeltySynthPlayer] recreate_audio_output skipped: WASAPI exclusive mode enabled");
			return;
		}
		// 尚未初始化则无需重建：下次初始化自然使用新的默认设备
		if (_audioOutput == null)
		{
			ThreadSafeLog.Print("[MeltySynthPlayer] recreate_audio_output: no audio output yet, nothing to rebuild");
			return;
		}

		ThreadSafeLog.Print("[MeltySynthPlayer] Recreating audio output device to follow system default endpoint");
		RecreateAudioOutputBridge();
	}

	/// <summary>
	/// 中断恢复：音频被系统打断（如来电/切后台）后，安卓 AAudio 被系统夺走音频焦点，
	/// 仅 ma_device_stop/start 无法重新申请到会话，必须整桥销毁重建才能恢复声音。
	/// </summary>
	public void recover_audio_output()
	{
		ThreadSafeLog.Print("[MeltySynthPlayer] Recreating audio output bridge for interruption recovery");
		recreate_audio_output();
	}

	/// <summary>
	/// 获取当前音频延迟 (毫秒).
	/// miniaudio 后端: 设备内部延迟 (ma_device_get_latency) + RingBuffer 延迟
	/// </summary>
	public float GetAudioLatencyMs()
	{
		if (_audioOutput is MiniaudioAudioOutputBridge maBridge)
		{
			return maBridge.GetLatencyMs();
		}
		return 0f;
	}

	/// <summary>
	/// 获取音频延迟分解 (设备延迟 ms, RingBuffer 延迟 ms).
	/// 用于诊断延迟来源
	/// </summary>
	public Godot.Collections.Dictionary GetAudioLatencyBreakdown()
	{
		var result = new Godot.Collections.Dictionary();
		if (_audioOutput is MiniaudioAudioOutputBridge maBridge)
		{
			var (deviceMs, ringMs) = maBridge.GetLatencyBreakdown();
			result["device_ms"] = deviceMs;
			result["ring_ms"] = ringMs;
			result["total_ms"] = deviceMs + ringMs;
			result["actual_period"] = (int)maBridge.ActualPeriod;
			result["actual_period_count"] = (int)maBridge.ActualPeriodCount;
			result["sample_rate"] = _sampleRate;
			result["actual_sample_rate"] = (int)maBridge.ActualSampleRate;
		}
		else
		{
			result["device_ms"] = 0f;
			result["ring_ms"] = 0f;
			result["total_ms"] = 0f;
			result["actual_period"] = 0;
			result["actual_period_count"] = 0;
			result["sample_rate"] = _sampleRate;
			result["actual_sample_rate"] = 0;
		}
		return result;
	}

	/// <summary>
	/// 获取音频调试诊断信息（慢回调统计 / 人声欠载 / 外推量），用于验证统一时钟架构。
	/// </summary>
	public Godot.Collections.Dictionary get_audio_debug_info()
	{
		var result = GetAudioLatencyBreakdown();
		if (_audioOutput is MiniaudioAudioOutputBridge maBridge)
		{
			result["perf_total_callbacks"] = maBridge.PerfTotalCallbacks;
			result["perf_slow_callbacks"] = maBridge.PerfSlowCallbacks;
			result["perf_slow_ratio"] = maBridge.PerfSlowRatio;
			result["vocal_underrun_count"] = (int)maBridge.GetVocalUnderrunCount();
			result["vocal_underrun_frames"] = (long)maBridge.GetVocalUnderrunFrames();
			result["vocal_catchup_frames"] = (int)maBridge.GetVocalCatchupFrames();
			result["extrapolation_ms"] = maBridge.GetExtrapolationMs();
		}
		return result;
	}

	public override void _Ready()
	{
		// 登记主线程：之后非主线程的日志只入队，由 _Process 打出去（见 ThreadSafeLog）
		ThreadSafeLog.MarkMainThread();
		ThreadSafeLog.Print("[MeltySynthPlayer] _Ready() called");
		// 缓存 user:// / res:// 的原生前缀（引擎调用，只能主线程）：后台换曲线程据此
		// 自行换算绝对路径，全程不碰引擎 API。
		_userDataPathPrefix = ProjectSettings.GlobalizePath("user://");
		_projectPathPrefix = ProjectSettings.GlobalizePath("res://");
		EnsureAudioInitialized();
		ThreadSafeLog.Print($"[MeltySynthPlayer] _Ready() complete: _audioOutput={( _audioOutput != null ? _audioOutput.GetType().Name : "null" )}");

		SetProcess(true);
		// 帧回调心跳时间戳 + 设备看门狗线程。注意：熄屏/后台时**只有帧回调（_Process/Timer）停跑**，
		// Godot 主线程仍在派发信号（Java ticker 的 bg_tick 就是这么被处理的）——曲终推进仍走主线程。
		StartBackgroundAdvanceThread();
		// 传输/媒体/播放列表编排层（播放真值唯一归属）
		InitTransport();
	}

	public override void _Process(double delta)
	{
		// 缓存后台线程要用的主线程侧依赖（节点引用不能从后台线程取）
		// 后台 SoundFont 解析完成后，在主线程完成合成器/音频桥绑定（音频相关 API 必须主线程）
		if (_sfParseDone && !_sfFinalized && (_sfLoadThread == null || !_sfLoadThread.IsAlive))
		{
			_sfLoadThread = null;
			FinalizeSoundfontLoad();
		}

		_audioOutput?.Update();

		if (_audioOutput is MiniaudioAudioOutputBridge maBridge && maBridge.IsVocalFinished())
		{
			if (!_vocalFinishedSignaled)
			{
				_vocalFinishedSignaled = true;
				EmitSignal(SignalName.vocal_finished);
			}
		}

		// 传输/媒体/自动切歌心跳：取走回绕标志并推进播放列表、补发换曲信号、推媒体状态。
		// （回绕检测在音频回调；这里在主线程消费 —— 前台每帧，后台由 Java ticker 的 bg_tick 叫醒。）
		TickTransport(delta);

		// 【关键】处理待处理的 seek 操作优先级最高，即使不在播放中也要处理
		if (!double.IsNaN(_pendingSeekMs))
		{
			// ThreadSafeLog.Print($"[MeltySynthPlayer] Processing seek to {_pendingSeekMs} ms (playing={playing})");
			
			if (_sequencer == null || _midiFile == null)
			{
				ThreadSafeLog.PrintErr("[MeltySynthPlayer] Cannot seek: sequencer or midiFile is null");
				_pendingSeekMs = double.NaN;
				return;
			}

			// 如果 seek 位置是负数，进入 pre-roll 模式
			if (_pendingSeekMs < 0.0)
			{
				// 负数 seek：停止所有播放，记录 offset，准备 pre-roll
				_currentOffsetMs = _pendingSeekMs;
				_sequencerStarted = false;  // 标记 sequencer 需要重启
				_hasSkippedPreroolEvents = false;  // 重置标志，准备首次 crossing zero
				InvalidateJudgeClock();
		
				// 停止所有播放（AudioStreamPlayer 和 Sequencer）
				// 注意：ma_bridge_stop 会等待回调完成，必须在锁外调用（回调可能阻塞在锁上）
				_audioOutput?.Stop();
				
				// 【关键】停止 sequencer，防止在后台继续运行（与回调渲染互斥）
				WithSynthLock(() =>
				{
					if (_sequencer != null)
					{
						_sequencer.Stop();
						// ThreadSafeLog.Print($"[MeltySynthPlayer] Stopped sequencer for pre-roll mode");
					}
				});
				
			// ThreadSafeLog.Print($"[MeltySynthPlayer] Pre-roll mode: offset set to {_currentOffsetMs} ms");
				_pendingSeekMs = double.NaN;
				return;
			}

			// 正数 seek：正常处理
			// 1. 如果正在播放，停止 AudioStreamPlayer 清空缓冲区
			// 注意：ma_bridge_stop 会等待回调完成，必须在锁外调用
			_audioOutput?.Stop();

			// 2. 确保 sequencer 已启动，再使用原生 Seek
			// 整个 sequencer 状态重建（Play/Seek/Reset/状态消息重放）与回调渲染互斥，
			// 避免 synthesizer.Reset()/ProcessMidiMessage() 与回调 voices 遍历并发导致数组越界。
			WithSynthLock(() =>
			{
				if (!_sequencerStarted)
				{
					_sequencer.Play(_midiFile, false);
					_sequencerStarted = true;
					ApplyInstrumentOverridesToSynth();
				}

				if (_preferNativeSequencerSeek)
				{
					try
					{
						_sequencer.Seek(TimeSpan.FromMilliseconds(_pendingSeekMs));
					}
					catch (Exception ex)
					{
						ThreadSafeLog.PrintErr($"[MeltySynthPlayer] Native sequencer seek failed, fallback to legacy seek: {ex.Message}");
						LegacySeekByFastForward(_pendingSeekMs);
					}
					// 原生 Seek 内部会调用 synthesizer.Reset()，把 Play 时应用的乐器覆盖清掉；
					// 这里幂等地重新应用（通道状态消息已在重建过程中按序生效，重复应用无害）。
					ApplyInstrumentOverridesToSynth();
					// Schedule post-seek silence to consume transient note attacks.
					// Rendered audio will be silently discarded for ~50ms instead of
					// doing a synchronous flush that can crash the renderer.
					// 通过接口访问音频后端
					if (_audioOutput != null)
						_audioOutput.PostSeekSilenceFrames = (int)(_sampleRate * 0.05);
				}
				else
				{
					LegacySeekByFastForward(_pendingSeekMs);
				}
			});
			_currentOffsetMs = 0.0;  // 清除任何 pre-roll offset
			_hasSkippedPreroolEvents = true;  // 正数seek时无需跳过事件
			ResetRenderTimestamp();
			InvalidateJudgeClock();  // 按 seek 后的音频参考重建锚点
			_lastPositionMs = _pendingSeekMs;  // 记录 seek 目标，供非播放状态读取
			_seekPositionHoldFrames = 10;  // 保持目标位置约 10 帧，待渲染钟追上
			_seekAnchorMs = _lastPositionMs;  // 同上：重锚优先用目标位置而非滞后的渲染钟

			// 3. 如果之前在播放，重新启动 AudioStreamPlayer（锁外，ma_bridge_start 不等待回调）
			if (playing)
			{
				RequestAudioOutputPlay();
			}
			
			// 5. 清除待处理标志
			_pendingSeekMs = double.NaN;
			
			// ThreadSafeLog.Print("[MeltySynthPlayer] Seek completed");
			
			// 【关键】返回，跳过本帧渲染，让缓冲区在下一帧重新开始
			return;
		}

		// 【处理 pre-roll 阶段】如果在 pre-roll 中（offset 为负数），进行时间累积，不渲染
		if (_currentOffsetMs < 0.0 && playing)
		{
			_currentOffsetMs += delta * 1000.0;  // 毫秒
			
			// 检查是否跨越零点（从 pre-roll 进入正常播放）
			if (_currentOffsetMs >= 0.0 && !_hasSkippedPreroolEvents)
			{
				// 第一次跨越零点：启动 sequencer 和 AudioStreamPlayer（与回调渲染互斥）
				WithSynthLock(() =>
				{
					if (_sequencer != null && _midiFile != null && !_sequencerStarted)
					{
						// ThreadSafeLog.Print($"[MeltySynthPlayer] Crossing zero from pre-roll, starting sequencer at position 0");
						_sequencer.Play(_midiFile, false);
						_sequencerStarted = true;
						ApplyInstrumentOverridesToSynth();
					}
				});
				
				// 【关键】启动 AudioStreamPlayer，确保 sequencer 和播放器同步（锁外）
				RequestAudioOutputPlay();
				
				_hasSkippedPreroolEvents = true;
				_currentOffsetMs = 0.0;  // 重置 offset，准备正常播放阶段
				ResetRenderTimestamp();
				InvalidateJudgeClock();  // 跨零点后按音频参考重建锚点（位置归 0）
				
				// 【不要返回】继续执行到正常播放流程，让 sequencer 自然渲染第一批帧
			}
			else
			{
				// 还在 pre-roll 期间，不播放声音
				return;
			}
		}

		// 曲终由 TickTransport 统一处理（非循环模式 EndOfSequence，显式）。

		if (!playing || _sequencer == null || _audioOutput == null)
		{
			return;
		}

		// [诊断] 音频看门狗：playing 且非暂停时，音频钟应在推进。
		// 若长时间不动，说明音频回调停摆（Android 后台挂起 / 设备被抢占）。
		// 正常播放时静默，仅在检出停摆时打印。
		_tickAudioWatchdog();

		// [诊断] 曲尾回绕观测：进入末尾 1.5s 后每帧打印一次位置与 loop 状态，
		// 用于区分"回绕成功"与"卡在末尾不再推进"。只在接近曲尾时输出。
		_tickLoopTailDiag();

		// [诊断] 人声欠载/追平观测：计数变化时打一条，观察漂移是否被即时修正。
		_tickVocalDriftDiag();

		// 直接在回调中合成，主循环只需要确保播放已启动
		RequestAudioOutputPlay();
	}

	// [诊断] 曲尾回绕观测
	private int _loopTailDiagFrames = 0;

	private void _tickLoopTailDiag()
	{
		if (_midiFile == null || !_sequencerStarted)
		{
			_loopTailDiagFrames = 0;
			return;
		}
		double durMs = _midiFile.Length.TotalMilliseconds;
		double posMs = _sequencer.RenderedPosition.TotalMilliseconds;
		if (durMs - posMs > 1500.0)
		{
			_loopTailDiagFrames = 0;
			return;
		}
		// 每 30 帧（约 0.5s）打一条，避免刷屏
		if (++_loopTailDiagFrames % 30 != 1)
		{
			return;
		}
		ThreadSafeLog.Print($"[MeltySynthPlayer][DIAG] TAIL pos={posMs:F0}/{durMs:F0}ms " +
			$"endOfSeq={_sequencer.EndOfSequence} paused={_sequencer.IsPaused} playing={playing}");
	}

	// [诊断] 人声欠载/追平观测
	private ulong _lastVocalUnderrunFrames = 0;

	private void _tickVocalDriftDiag()
	{
		if (_audioOutput is MiniaudioAudioOutputBridge ma)
		{
			ulong underrunFrames = ma.GetVocalUnderrunFrames();
			if (underrunFrames != _lastVocalUnderrunFrames)
			{
				_lastVocalUnderrunFrames = underrunFrames;
				ThreadSafeLog.Print($"[MeltySynthPlayer][DIAG] VOCAL underrun_frames={underrunFrames} " +
					$"catchup_frames={ma.GetVocalCatchupFrames()} underruns={ma.GetVocalUnderrunCount()}");
			}
		}
	}

	// [诊断] 音频推进看门狗
	private double _watchdogLastPositionMs = -1.0;
	private int _watchdogStallFrames = 0;

	private void _tickAudioWatchdog()
	{
		double pos = _sequencer.RenderedPosition.TotalMilliseconds;
		if (_watchdogLastPositionMs >= 0.0 && pos <= _watchdogLastPositionMs + 0.5)
		{
			_watchdogStallFrames++;
			// 主循环约 60fps，连续 2 秒不动即视为停摆
			if (_watchdogStallFrames == 120)
			{
				ThreadSafeLog.Print($"[MeltySynthPlayer][DIAG] AUDIO STALLED pos={pos:F1}ms " +
					$"playing={playing} started={_sequencerStarted} endOfSeq={_sequencer.EndOfSequence}");
			}
		}
		else
		{
			if (_watchdogStallFrames >= 120)
			{
				ThreadSafeLog.Print($"[MeltySynthPlayer][DIAG] AUDIO RESUMED pos={pos:F1}ms " +
					$"(stalled {_watchdogStallFrames} frames)");
					// 【卡顿恢复后强行对齐人声】设备停顿时 MIDI 的渲染位置停了、而人声解码与位置记账已追平，
					// 于是出现『报告位置一致、实际内容落后』—— 按位置判定的漂移同步看不见它，只有 seek 会丢
					// 弃待播帧。真机现象：断/连蓝牙后 MIDI 比人声快，seek 一下就正常。这里主动补一次重对齐。
					RealignVocalToMidiPosition();
			}
			_watchdogStallFrames = 0;
		}
		_watchdogLastPositionMs = pos;
	}

	public override void _ExitTree()
	{
		ThreadSafeLog.Print("[MeltySynthPlayer] _ExitTree() called, disposing audio resources");
		// 【顺序是承重的，别调换】StopBackgroundAdvanceThread() 会 join 后台换曲线程；
		// 下面把 _sequencer/_synth/_autoSynth/_manualSynth/_soundFont/_midiFile 直接置 null，
		// 而后台线程对这些字段是**无同步裸读**的（LoadMidiFile / AdvanceToNextInBackground 里
		// 的 _sequencer.Seek、_midiFile.Length 等）。join 之后才置 null，这些裸读才成立；
		// 若把 join 去掉或挪到后面，后台线程就会读到 null → NRE（表现为退出期崩溃/换曲中断）。
		bool bgStopped = StopBackgroundAdvanceThread();
		if (_audioOutput != null)
		{
			_audioOutput.Dispose();
			_audioOutput = null;
		}
		if (bgStopped)
		{
			_sequencer = null;
			_synth = null;
			_autoSynth = null;
			_manualSynth = null;
			_soundFont = null;
			_midiFile = null;
		}
		else
		{
			// 后台线程可能仍在跑：**不能**置 null（它对上面这些字段是无同步裸读的）。
			// 宁可留着引用让进程回收，也不要制造 NRE。
			ThreadSafeLog.PrintErr("[MeltySynthPlayer] _ExitTree: background thread still alive, keeping object refs");
		}
	}

	/// <summary>开始播放。返回 true 表示已真正启动，false 表示音源未就绪、已推迟到加载完成后续播。</summary>
	public bool play()
	{
		_paused = false;
		// 人声漂移同步的节流基准归零：与旧实现 play() 末尾的 reset_sync_state() 等价。
		// 不归零时下一帧的漂移检查会被 `|rawMs - _lastVocalSyncCheckMs| < 100` 挡掉，
		// 于是"刚开始播的这 100ms 内人声偏了也不纠正"。0 值不是合法哨兵（哨兵是 -1000），
		// 故 reset_vocal_sync() 用 -1000/0 重置三件套。
		reset_vocal_sync();
		PrepareAudioOutputForPlaybackStart();
		ThreadSafeLog.Print($"[MeltySynthPlayer] play() called - _midiFile={_midiFile != null}, _sequencerStarted={_sequencerStarted}, _audioOutput={( _audioOutput != null ? "OK" : "NULL" )}, _synth={(_synth != null ? "OK" : "NULL")}, _autoSynth={(_autoSynth != null ? "OK" : "NULL")}");
		if (_sequencer == null)
		{
			// 音源仍在后台异步加载中：记录播放意图，待 FinalizeSoundfontLoad 完成后再自动启动，
			// 避免主线程阻塞等待（原同步加载会卡 3-5s）。若无任何加载在飞，才是真正的失败。
			if (!_sfFinalized && (_sfLoadThread != null || _sfParseDone))
			{
				ThreadSafeLog.Print("[MeltySynthPlayer] SoundFont still loading, deferring play() until finalized");
				_pendingPlayAfterLoad = true;
				playing = true;
								return false;
			}
			ThreadSafeLog.PrintErr("[MeltySynthPlayer] Cannot play: sequencer is null");
						return false;
		}

		// 判定钟锚点作废：下次读取按当前音频参考重建
		InvalidateJudgeClock();

		// ThreadSafeLog.Print($"[MeltySynthPlayer] play() called - _midiFile: {_midiFile != null}, _sequencerStarted: {_sequencerStarted}, _currentOffsetMs: {_currentOffsetMs}, _audioOutput.IsPlaying: {_audioOutput?.IsPlaying}");

		// 【处理 pre-roll 模式】如果当前有负数 offset，不启动 sequencer，让 _Process 处理跨越零点
		if (_currentOffsetMs < 0.0)
		{
			// ThreadSafeLog.Print($"[MeltySynthPlayer] In pre-roll mode (offset={_currentOffsetMs} ms), sequencer will start when crossing zero");
			playing = true;
			return true;
		}

		// 如果 MIDI 已加载但还未启动 sequencer，则启动它（与回调渲染互斥）
		if (_midiFile != null && !_sequencerStarted)
		{
			// ThreadSafeLog.Print($"[MeltySynthPlayer] Starting sequencer with MIDI file,");
			WithSynthLock(() =>
			{
				_sequencer.Play(_midiFile, false);
				_sequencerStarted = true;
				ApplyInstrumentOverridesToSynth();
			});
		}
		else if (_midiFile == null)
		{
			ThreadSafeLog.PrintErr("[MeltySynthPlayer] Cannot play: no MIDI file loaded");
						return false;
		}
		else if (_sequencerStarted)
		{
			// ThreadSafeLog.Print("[MeltySynthPlayer] Sequencer already started, resuming playback");
		}
		
		playing = true;
		RequestAudioOutputPlay();
		return true;
	}

	public void stop()
	{
		// 记为一次显式停止：曲终信号的同步广播期间被调到时，HandleSongEnded 会据此不再起播
		Interlocked.Increment(ref _stopGeneration);
		playing = false;
		_pendingPlayAfterLoad = false;
		_restoreHeldNotes = false;
		lock (_activeNotesLock)
		{
			_activeNotes.Clear();
		}
		// 丢弃尚未被回调消费的手动音符：设备停着的时候它们不会被出队，
		// 等到下次起跑会一次性补发（开局幽灵音）。
		if (_audioOutput is MiniaudioAudioOutputBridge maClear)
		{
			maClear.ClearPendingNotes();
		}
		ResetManualVoices();
		// ma_bridge_stop 会等待回调完成，必须在锁外调用
		_audioOutput?.Stop();
		// 人声也要停：旧实现的 stop() 末尾会 stop_vocal_playback()，而 native 的
		// ma_bridge_vocal_stop 会停掉解码生产线程并把读写位置/已消费帧归零。
		// 少了这一步，设备再次启动时人声会从"上次停下的位置"继续（与本曲从头开始不一致），
		// 而"当前在播位置"与"人声位置"从此长期错开。
		if (_audioOutput is MiniaudioAudioOutputBridge maStop && maStop.IsVocalLoaded)
		{
			maStop.StopVocal();
		}
		_vocalFinishedSignaled = false;
		// 换曲/显式停止：人声的"用户显式关闭"状态回到由配置决定
		// （在某首歌里关掉人声不该影响下一首）
		_vocalDisabledByUser = false;
		// 与回调渲染互斥
		WithSynthLock(() =>
		{
			_sequencer?.Stop();
		});
		_sequencerStarted = false;  // 重置标志，下次 play() 会重新启动
		_currentOffsetMs = 0.0;  // 重置 offset
		_lastPositionMs = 0.0;  // 重置最后已知位置（stop 语义为回到开头）
		InvalidateJudgeClock();
	}

	private void FinishPlayback()
	{
		if (!playing)
		{
			return;
		}

		playing = false;
		// 丢弃尚未被回调消费的手动音符：设备停着的时候它们不会被出队，
		// 等到下次起跑会一次性补发（开局幽灵音）。
		if (_audioOutput is MiniaudioAudioOutputBridge maClear)
		{
			maClear.ClearPendingNotes();
		}
		ResetManualVoices();
		// ma_bridge_stop 会等待回调完成，必须在锁外调用
		_audioOutput?.Stop();
		// 与回调渲染互斥
		WithSynthLock(() =>
		{
			_sequencer?.Stop();
		});
		_sequencerStarted = false;
		_hasSkippedPreroolEvents = false;
		_currentOffsetMs = 0.0;
		_lastPositionMs = _midiFile != null ? _midiFile.Length.TotalMilliseconds : 0.0;
		InvalidateJudgeClock();

		// 通知 GDScript 侧。**两个信号名都要发**：
		//   - midi_finished：Transport 层新声明的 UI 面向信号，PlaybackDisplay 转发的就是它
		//     （PlayView 靠它"播放自然结束时立即触发结算"）；
		//   - finished：节点级历史信号名，保留给直接接节点的旧消费方。
		// 【教训】重构时这里只发了 finished，而 PlaybackDisplay 转发的是 midi_finished：
		//   _forward() 里 has_signal 为真、connect 也成功，但信号永远不发射 → 整条兜底路径
		//   静默失效（表现为"只有进度条走到头才结算"）。
		EmitSignal(SignalName.finished);
		EmitSignal(SignalName.midi_finished);
	}

	public void seek_ms(double positionMs)
	{
		// 【越界钳制】把进度拖到超过曲长，会把 sequencer 推到"末尾之外"：之后既没有声音、
		// 也永远不会闩上曲终标志（真机日志：`media command: seek (212657ms)`，而当时那首只有
		// 101151ms —— 212657 ≈ 0.78 × 271700，即系统侧量程还是**上一首**的时长）。
		// 表现为"后台拖一下就没动静，也不换歌"。钳到"结束前 100ms"，让正常曲终/换曲逻辑照常发生。
		double seekDurationMs = _midiFile != null ? _midiFile.Length.TotalMilliseconds : 0.0;
		if (positionMs > 0.0 && seekDurationMs > 0.0 && positionMs > seekDurationMs - 100.0)
		{
			positionMs = Math.Max(0.0, seekDurationMs - 100.0);
			ThreadSafeLog.Print($"[MeltySynthPlayer] seek clamped to {positionMs:F0}ms (duration={seekDurationMs:F0}ms)");
		}
		if (_midiFile == null || _sequencer == null)
		{
			return;
		}

		// 钳制上界：上层量程可能与实际曲目不一致（后台换曲后 UI 量程未刷新，
		// 或拖动时按旧曲长度取值）。把位置甩到曲尾之外会让下一个音频回调的
		// RestartVocalOnLoopWrap 看到"位置大幅回退"而误判为回绕，进而触发一次
		// 非预期的换曲。越界 seek 本来也没有语义。
		// 只夹上界：负值是 pre-roll 语义（[_currentOffsetMs,0)），不能动。
		double lengthMs = _midiFile.Length.TotalMilliseconds;
		if (positionMs > 0.0 && !double.IsNaN(lengthMs) && lengthMs > 0.0)
		{
			positionMs = Math.Min(positionMs, lengthMs);
		}

		// 【修复】允许负数 seek，设置待处理的 seek 标志
		// 负数（pre-roll）依赖 _currentOffsetMs 等主线程状态，仍走 _Process 路径
		if (positionMs < 0.0)
		{
			_pendingSeekMs = positionMs;
			SeekVocalToMidi(positionMs);
			return;
		}

		// 暂停时设备已停，音频线程不再跑，交给它的 seek 不会被消费，主线程必须自己落一次。
		// 下面仍照常排队：device 再次启动后回调会再落一次同目标（幂等），
		// 覆盖"先 seek 再 play()"——Play() 会把位置清回 0，只靠本次直落会丢失目标。
		if (_audioOutput is MiniaudioAudioOutputBridge maStopped && !maStopped.IsPlaying)
		{
			WithSynthLock(() => _sequencer.Seek(TimeSpan.FromMilliseconds(positionMs)));
			// 主线程直落的 seek 也要清回绕基准：否则渲染钟从大值回跳会被下一帧的
			// RestartVocalOnLoopWrap 误判成"回绕了一次"，导致 spurious 切歌。
			maStopped.ResetEndOfSequence();
		}

		// 非负 seek 下沉到音频线程：后台时 _Process 停摆，只有音频线程仍在跑。
		// 前台也走同一路径，保证两条路径行为一致（不会重复 seek）。
		if (_audioOutput is MiniaudioAudioOutputBridge ma)
		{
			// 同步上层缓存，使 get_position_ms 立即反映目标位置；
			// hold 若干帧避免 sequencer 渲染钟尚未反映新位置时瞬回 0
			_lastPositionMs = positionMs;
			_seekPositionHoldFrames = 10;
			_seekAnchorMs = positionMs;
			InvalidateJudgeClock();
			ma.RequestSeek(positionMs);
			// 人声跟随 seek：人声走原生解码器、不与 sequencer 共用时钟，必须显式重定位，
			// 否则拖动进度条只有 MIDI 跟着走、人声留在原处（原 GDScript _seek_vocal_to_midi_position）。
			SeekVocalToMidi(positionMs);
			return;
		}
		_pendingSeekMs = positionMs;
	}

	/// <summary>把原生人声解码器定位到与 MIDI 目标位置对齐处（扣除人声起点偏移）。</summary>
	private void SeekVocalToMidi(double midiPositionMs)
	{
		if (!(_audioOutput is MiniaudioAudioOutputBridge ma))
		{
			return;
		}
		// 判据用"是否装载过人声"，而不是原生 GetVocalLengthMs()（未装载时返回 -1，
		// 一旦被别处改动/时序不巧就会把 seek 静默吞掉）。
		if (string.IsNullOrEmpty(_loadedVocalFilePath))
		{
			ThreadSafeLog.Print($"[MeltySynthPlayer] vocal seek skipped: no vocal loaded (midi={midiPositionMs:F0}ms)");
			return;
		}
		_vocalFinishedSignaled = false;
		double vocalPos = midiPositionMs - get_vocal_offset_ms();
		ThreadSafeLog.Print($"[MeltySynthPlayer] vocal seek: midi={midiPositionMs:F0}ms offset={get_vocal_offset_ms():F0}ms -> vocal={vocalPos:F0}ms playing={playing}");
		if (vocalPos < 0.0)
		{
			ma.PauseVocal();
			ma.SeekVocal(0.0);
			return;
		}
		ma.SeekVocal(vocalPos);
		if (playing)
		{
			ma.ResumeVocal();
		}
		else
		{
			ma.PauseVocal();
		}
	}

	public void set_soundfont(string soundfontPath)
	{
		EnsureAudioInitialized();
		_soundfont = soundfontPath;
		if (playing)
		{
			// 播放中切换音源：保持原有同步行为（无法在播放时后台替换合成器）
			LoadSoundfont(soundfontPath);
			return;
		}
		// 若已有后台加载在飞，先等它完成并 finalize（主线程），避免并发与重复加载
		if (_sfLoadThread != null && _sfLoadThread.IsAlive)
		{
			_sfLoadThread.Join();
			_sfLoadThread = null;
			if (!_sfFinalized)
			{
				FinalizeSoundfontLoad();
			}
			if (_soundfont == soundfontPath)
			{
				return;
			}
		}
		// 否则在后台线程解析 SoundFont（30MB / 3-5s），主线程继续渲染不阻塞
		StartSoundfontLoadAsync(soundfontPath);
	}

	public void set_file(string midiPath)
	{
		EnsureAudioInitialized();
		_file = midiPath;
		LoadMidiFile(midiPath);
	}

	public void set_volume_db(float volumeDb)
	{
		_volume_db = volumeDb;
		_volumeLinear = Mathf.DbToLinear(volumeDb);
		
		_audioOutput?.SetVolume(_volumeLinear);
	}

	// ============ Vocal control (miniaudio unified output chain) ============
	public bool load_vocal_file(string path)
	{
		EnsureAudioInitialized();
		if (_audioOutput == null) return false;
		_vocalFinishedSignaled = false;
		var loaded = _audioOutput.LoadVocalFile(path);
		_loadedVocalFilePath = loaded ? path : "";
		if (loaded)
		{
			_audioOutput.SetVocalVolume(_vocalVolumeLinear);
		}
		return loaded;
	}

	public void unload_vocal()
	{
		_vocalFinishedSignaled = false;
		_loadedVocalFilePath = "";
		_audioOutput?.UnloadVocal();
	}

	public void play_vocal()
	{
		_vocalFinishedSignaled = false;
		if (_audioOutput != null && !_audioOutput.IsPlaying)
		{
			_audioOutput.Play();
		}
		_audioOutput?.PlayVocal();
	}

	public void pause_vocal()
	{
		_audioOutput?.PauseVocal();
	}

	public void resume_vocal()
	{
		_vocalFinishedSignaled = false;
		if (_audioOutput != null && !_audioOutput.IsPlaying)
		{
			_audioOutput.Play();
		}
		_audioOutput?.ResumeVocal();
	}

	public void stop_vocal()
	{
		_vocalFinishedSignaled = false;
		_audioOutput?.StopVocal();
	}

	public void seek_vocal(double positionMs)
	{
		_vocalFinishedSignaled = false;
		_audioOutput?.SeekVocal(positionMs);
	}

	public void set_vocal_volume(double volumeLinear)
	{
		_vocalVolumeLinear = (float)volumeLinear;
		_audioOutput?.SetVocalVolume(_vocalVolumeLinear);
	}

	// ============ 播放器页面的全局音量（后台换曲优先使用）============
	// 玩家在播放器页调的 MIDI/人声音量才是"实际听到的音量"；per-MIDI 配置里的
	// vocal_volume 等只是从未在播放器页调整过时的默认值。熄屏/深后台换曲由后台线程
	// 完成，GDScript 早已停摆、读不到页面状态，故由主线程在页面调整音量时缓存到这里。
	// 负值 = 未设置 → 后台换曲回退 per-MIDI 配置。
	private volatile float _playerMidiVolumeLinear = -1.0f;
	private volatile float _playerVocalVolumeLinear = -1.0f;

	/// <summary>缓存播放器页面的全局音量（线性值；负值 = 未设置，后台换曲回退 per-MIDI 配置）</summary>
	public void set_player_volumes(float midiLinear, float vocalLinear)
	{
		_playerMidiVolumeLinear = midiLinear;
		_playerVocalVolumeLinear = vocalLinear;
	}

	// ============ 谱面运行时配置（音频侧唯一实现）============
	// 前台 load_midi 与熄屏/深后台的自动换曲都调 apply_chart_audio_config。
	// 后台时 GDScript 停摆，过去只能应用这份配置的子集（漏启用通道门控 / solo / 乐器覆盖），
	// 回前台再由 reconcile 补齐 —— 表现为"后台换的那首听起来不对、回前台又变一次"。
	// 现在两份拷贝合一。调用前设备必须已停止（前台 stop()、后台换曲都会先停）。

	/// <summary>缓存：Playback/use_system_stopwatch（主线程每帧读一次）</summary>
	private bool _cachedUseSystemStopwatch = false;

	/// <summary>音源未就绪而推迟载入 MIDI 时记下的谱面 key：finalize 后补应用一次配置</summary>
	private string _pendingConfigChartKey = "";

	/// <summary>主线程入口：应用某谱面的全部音频侧运行时配置（不启动设备）</summary>
	public void apply_chart_audio_config(string chartKey)
	{
		apply_chart_audio_config(chartKey, GetNodeOrNull<ChartDb>("/root/ChartDB"));
	}

	/// <summary>后台换曲线程入口：db 由调用方传入（后台线程不做节点查找）</summary>
	public void apply_chart_audio_config(string chartKey, ChartDb db)
	{
		if (string.IsNullOrEmpty(chartKey))
		{
			return;
		}
		var core = MidiCore.Instance;
		var cfgs = System.Diagnostics.Stopwatch.StartNew();
		ThreadSafeLog.Print("[MeltySynthPlayer] cfg: begin");
		// 纯 C# 形态配置：后台换曲线程靠它避免接触 Godot 容器（首次构建须在主线程）
		var cfg = core?.GetConfigPlain(chartKey);
		ThreadSafeLog.Print($"[MeltySynthPlayer] cfg: got config ({cfgs.ElapsedMilliseconds}ms)");
		// (track, channel) 全集：与前台 soa_pairs_of 同源（解析缓存），缺缓存时由 C# 自己补齐。
		int[] pairs = System.Array.Empty<int>();
		if (_bgPairsOverride != null)
		{
			// 后台换曲：pairs 由主线程预取传入 —— 既不必解析谱面，也不碰任何 Godot 容器
			// 原子取走：后台线程可能正写入下一条，读-改-写会把新值当旧值清掉
			pairs = Interlocked.Exchange(ref _bgPairsOverride, null);
		}
		else if (core != null && !string.IsNullOrEmpty(_file))
		{
			// 缺解析缓存就自己按需补（System.IO 读盘，不经引擎）：后台线程调 Godot 文件 API
			// 会与可能被冻结的主线程抢引擎全局锁而永久阻塞（"不切歌且彻底静音"）。
			if (!core.HasParsed(_file))
			{
				// 解析本身已改为纯托管（MidiParserNative.ParsePlain），任意线程安全。
				// 但绝对路径之外的 res:// / user:// 仍要走 Godot FileAccess（PCK 内资源），
				// 那一步不能离开主线程，故后台线程只补绝对路径的谱面。
				if (ThreadSafeLog.IsMainThread || IsPlainFilePath(_file))
				{
					core.ParseChartFileSystemIo(_file, _file);
				}
				else
				{
					ThreadSafeLog.Print($"[MeltySynthPlayer] cfg: parse skipped on bg thread (engine-path, not pre-parsed): {_file}");
				}
			}
			ThreadSafeLog.Print($"[MeltySynthPlayer] cfg: parsed ({cfgs.ElapsedMilliseconds}ms)");
			pairs = core.GetPairs(_file);
		}
		ThreadSafeLog.Print($"[MeltySynthPlayer] cfg: pairs={pairs.Length} ({cfgs.ElapsedMilliseconds}ms)");

		ApplyTrackVolumeConfig(cfg, pairs);
		ThreadSafeLog.Print($"[MeltySynthPlayer] cfg: volume ({cfgs.ElapsedMilliseconds}ms)");
		ApplyTrackMuteConfig(cfg, pairs);
		ThreadSafeLog.Print($"[MeltySynthPlayer] cfg: mute ({cfgs.ElapsedMilliseconds}ms)");
		ApplyInstrumentOverrides(cfg);
		ThreadSafeLog.Print($"[MeltySynthPlayer] cfg: instr ({cfgs.ElapsedMilliseconds}ms)");
		ApplyChartMidiVolume(cfg);
		ApplyChartVocal(cfg, chartKey, db);
		ThreadSafeLog.Print($"[MeltySynthPlayer] cfg: vocal ({cfgs.ElapsedMilliseconds}ms)");
		set_use_system_stopwatch(_cachedUseSystemStopwatch);
		// 当前曲 key（媒体通知/状态查询用）：谱面配置是"换曲"的唯一信息点，在此记录
		_currentKey = chartKey;

		// MIDI 还没载入（音源仍在异步加载，LoadMidiFile 早退）：配置会在 finalize 的
		// LoadMidiFile 之后被清空，故记下 key 待那时补应用
		_pendingConfigChartKey = _midiFile == null ? chartKey : "";
	}

	/// <summary>
	/// 音源 finalize（主线程）后补应用推迟的谱面配置：LoadMidiFile 会清空轨道音量/静音/
	/// 乐器覆盖，若换曲时 MIDI 尚未载入，这些配置会在载入瞬间被清掉（表现为静音、音量全丢）。
	/// </summary>
	private void ApplyPendingChartConfigIfAny()
	{
		if (string.IsNullOrEmpty(_pendingConfigChartKey) || _midiFile == null)
		{
			return;
		}
		string key = _pendingConfigChartKey;
		_pendingConfigChartKey = "";
		ThreadSafeLog.Print($"[MeltySynthPlayer] applying deferred chart config: {key}");
		apply_chart_audio_config(key);
	}

	/// <summary>路径是否为原生文件系统路径（非 res:// / user://）。
	/// 只有这类路径的读取与存在性判断可以完全绕开引擎，在后台线程安全执行。</summary>
	private static bool IsPlainFilePath(string path)
	{
		return !string.IsNullOrEmpty(path)
			&& !path.StartsWith("res://")
			&& !path.StartsWith("user://");
	}

	/// <summary>
	/// user:// / res:// 的原生前缀，由 _Ready() 在主线程缓存一次。
	/// 后台换曲线程靠它自己换算绝对路径，避免调用 ProjectSettings.GlobalizePath（引擎调用，
	/// 主线程冻结时会永久阻塞）。
	/// </summary>
	private string _userDataPathPrefix = "";
	private string _projectPathPrefix = "";

	/// <summary>
	/// user:// / res:// 转原生路径。任意线程可用：只用主线程缓存的前缀 + 字符串拼接，
	/// 不调用任何引擎 API。前缀未就绪时原样返回（调用方再决定是否回退引擎）。
	/// （复刻 GDScript 侧 _globalize_vocal_path 的语义。）
	///
	/// 消费方：人声路径、谱面文件夹路径（ChartDb 存的 path 在桌面端就是 `user://files/Charts/...`，
	/// 直接丢给 System.IO 会永远判不存在 —— 这正是"下一首/后台换曲找不到谱面"的成因）。
	/// </summary>
	private string GlobalizeNativePath(string path)
	{
		if (string.IsNullOrEmpty(path))
		{
			return path;
		}
		string prefix = null;
		string rest = null;
		if (path.StartsWith("user://")) { prefix = _userDataPathPrefix; rest = path.Substring(7); }
		else if (path.StartsWith("res://")) { prefix = _projectPathPrefix; rest = path.Substring(6); }
		else return path;
		if (string.IsNullOrEmpty(prefix)) return path;
		var sep = System.IO.Path.DirectorySeparatorChar;
		return prefix.TrimEnd('/', '\\') + sep + rest.Replace('/', sep);
	}

	// ── 纯 C# 配置访问：后台换曲线程安全，全程不碰 Godot 容器 ──
	private static Dictionary<string, object> PlainDict(Dictionary<string, object> d, string key)
	{
		if (d != null && d.TryGetValue(key, out var o) && o is Dictionary<string, object> sub) return sub;
		return null;
	}

	private static bool PlainBool(Dictionary<string, object> d, string key, out bool v)
	{
		v = false;
		if (d != null && d.TryGetValue(key, out var o))
		{
			if (o is bool b) { v = b; return true; }
			if (o is long l) { v = l != 0; return true; }
		}
		return false;
	}

	private static bool PlainDouble(Dictionary<string, object> d, string key, out double v)
	{
		v = 0.0;
		if (d != null && d.TryGetValue(key, out var o))
		{
			if (o is double dd) { v = dd; return true; }
			if (o is long l) { v = l; return true; }
		}
		return false;
	}

	private static bool PlainStr(Dictionary<string, object> d, string key, out string v)
	{
		v = null;
		if (d != null && d.TryGetValue(key, out var o) && o is string s) { v = s; return true; }
		return false;
	}

	private static bool PlainToChannelIndex(object o, out int channel)
	{
		channel = 0;
		if (o is long l) { channel = (int)l; return true; }
		if (o is double d) { channel = (int)Math.Round(d); return true; }
		if (o is string s) return int.TryParse(s, out channel);
		return false;
	}

	/// <summary>轨道-通道音量：有配置按配置；无配置统一 0.5（与 TrackView 新谱面默认一致）</summary>
	private void ApplyTrackVolumeConfig(Dictionary<string, object> cfg, int[] pairs)
	{
		bool applied = false;
		var vol = PlainDict(cfg, "track_channel_volume_config");
		if (vol != null)
		{
			foreach (var trackEntry in vol)
			{
				if (!int.TryParse(trackEntry.Key, out int trackIdx)
						|| !(trackEntry.Value is Dictionary<string, object> chMap))
				{
					continue;
				}
				foreach (var chanEntry in chMap)
				{
					if (int.TryParse(chanEntry.Key, out int chan) && PlainDouble(chMap, chanEntry.Key, out double cv))
					{
						set_track_channel_volume(trackIdx, chan, (float)cv);
						applied = true;
					}
				}
			}
		}
		if (applied || pairs.Length == 0)
		{
			return;
		}
		foreach (int pair in pairs)
		{
			set_track_channel_volume(pair >> 8, pair & 0xFF, 0.5f);
		}
	}

	/// <summary>
	/// 静音：先按持久化状态下发，再叠加 solo / 启用通道门控的运行时静音（顺序不可颠倒：
	/// 持久化状态里 muted=false 会解除静音，运行时静音必须最后压上）。LoadMidiFile 已清空
	/// 静音集合，故配置里没提到的通道天然不静音。
	/// </summary>
	private void ApplyTrackMuteConfig(Dictionary<string, object> cfg, int[] pairs)
	{
		var mute = PlainDict(cfg, "track_channel_mute_state");
		if (mute != null)
		{
			foreach (var trackEntry in mute)
			{
				if (!int.TryParse(trackEntry.Key, out int trackIdx)
						|| !(trackEntry.Value is Dictionary<string, object> chMap))
				{
					continue;
				}
				foreach (var chanEntry in chMap)
				{
					if (int.TryParse(chanEntry.Key, out int chan) && PlainBool(chMap, chanEntry.Key, out bool muted))
					{
						set_track_channel_mute(trackIdx, chan, muted);
					}
				}
			}
		}

		// solo：非独奏轨运行时静音（与 TrackView._apply_solo_state 一致）
		var solo = PlainDict(cfg, "solo_pairs");
		if (solo != null && solo.Count > 0)
		{
			foreach (int pair in pairs)
			{
				int t = pair >> 8, c = pair & 0xFF;
				if (!solo.ContainsKey($"{t}:{c}"))
				{
					set_track_channel_mute(t, c, true);
				}
			}
		}

		// 启用/禁用通道（TrackView 的音轨开关）：未启用的通道运行时静音。
		// 从未配置过的谱面（_track_config_initialized=false）按"全部启用"处理——简介推荐轨的
		// 初始化在 GDScript 侧（ensure_track_config_initialized），与 MidiListItem 的兜底语义一致。
		if (!PlainBool(cfg, "_track_config_initialized", out bool initialized) || !initialized)
		{
			return;
		}
		var sel = PlainDict(cfg, "selected_track_configs");
		if (sel == null)
		{
			return;
		}
		var unselected = new System.Collections.Generic.List<int>();
		int selectedCount = 0;
		foreach (int pair in pairs)
		{
			if (IsChannelSelected(sel, pair >> 8, pair & 0xFF))
			{
				selectedCount++;
			}
			else
			{
				unselected.Add(pair);
			}
		}
		// 一个都没解析成"已启用"几乎只可能是键/值的类型没对上。真按它静音会把整首变哑，
		// 故按"全部启用"兜底 —— 与前台「推荐轨不存在 → 启用全部」同一哲学。
		if (selectedCount == 0)
		{
			ThreadSafeLog.PrintErr("[MeltySynthPlayer] selected_track_configs 解析为空，按全部启用兜底（请检查键/值类型）");
			return;
		}
		foreach (int pair in unselected)
		{
			set_track_channel_mute(pair >> 8, pair & 0xFF, true);
		}
	}

	/// <summary>
	/// selected_track_configs 里该 (track,channel) 是否启用。键与通道号都按 int/float/string 全认：
	/// 配置经 GDScript Dictionary → BSON → Godot Dictionary 往返，JSON 兼容层不保证数值仍是 int。
	/// </summary>
	private static bool IsChannelSelected(Dictionary<string, object> selected, int track, int channel)
	{
		if (selected == null || !selected.TryGetValue(track.ToString(), out var arrObj))
		{
			return false;
		}
		if (!(arrObj is System.Collections.Generic.List<object> arr))
		{
			return false;
		}
		foreach (var ch in arr)
		{
			if (PlainToChannelIndex(ch, out int c) && c == channel)
			{
				return true;
			}
		}
		return false;
	}

	/// <summary>
	/// 文件存在性判断。绝对路径走 System.IO。
	///
	/// 【线程模型】后台换曲线程不能碰 Godot 文件 API（引擎全局锁：主线程若正持锁被冻结，
	/// 后台线程再调就永久阻塞）。故 user:// / res:// 先用**主线程缓存的原生前缀**换算成绝对路径
	/// 再走 System.IO；只有前缀未知或资源落在 PCK 内时才回退到引擎 API，且仅限主线程。
	/// </summary>
	private bool FileExistsSafe(string path)
	{
		if (string.IsNullOrEmpty(path))
		{
			return false;
		}
		if (IsPlainFilePath(path))
		{
			return System.IO.File.Exists(path);
		}
		var native = GlobalizeNativePath(path);
		if (IsPlainFilePath(native) && System.IO.File.Exists(native))
		{
			return true;
		}
		// 前缀未就绪（启动极早期）或 res:// 落在 PCK 内：只有主线程能问引擎
		return ThreadSafeLog.IsMainThread && Godot.FileAccess.FileExists(path);
	}

	/// <summary>用户自定义的轨道-通道乐器覆盖（TrackView 改过音色的通道）</summary>
	private void ApplyInstrumentOverrides(Dictionary<string, object> cfg)
	{
		var ov = PlainDict(cfg, "track_channel_instrument_overrides");
		if (ov == null)
		{
			return;
		}
		foreach (var trackEntry in ov)
		{
			if (!int.TryParse(trackEntry.Key, out int trackIdx)
					|| !(trackEntry.Value is Dictionary<string, object> chMap))
			{
				continue;
			}
			foreach (var chanEntry in chMap)
			{
				if (!int.TryParse(chanEntry.Key, out int chan)
						|| !(chanEntry.Value is Dictionary<string, object> info))
				{
					continue;
				}
				PlainDouble(info, "bank", out double bankD);
				PlainDouble(info, "program", out double progD);
				set_track_channel_instrument(trackIdx, chan, (int)bankD, (int)progD);
			}
		}
		// 覆盖表已写入 _virtualChannelInstruments；起播（sequencer.Play）后还会再刷一遍
		ApplyInstrumentOverridesToSynth();
	}

	/// <summary>
	/// MIDI 主音量：播放器页面的音量优先（见 _playerMidiVolumeLinear），否则 per-MIDI 显式值，
	/// 未配置（<0，约定 -1）回退主线程缓存的全局 default_midi_volume；
	/// UI 线性值 × 8 增益后转 dB，下限 -80（与 apply_ui_midi_volume 同规则）。
	/// </summary>
	private void ApplyChartMidiVolume(Dictionary<string, object> cfg)
	{
		const double gain = 8.0;
		const double minDb = -80.0;
		if (_playerMidiVolumeLinear >= 0.0f)
		{
			set_volume_db((float)Math.Max(Mathf.LinearToDb(_playerMidiVolumeLinear * gain), minDb));
			return;
		}
		double vol = -1.0;
		if (!PlainDouble(cfg, "midi_volume", out vol))
		{
			vol = -1.0;
		}
		if (vol < 0.0)
		{
			vol = _cachedDefaultMidiVolume;
		}
		if (double.IsNaN(vol))
		{
			return;
		}
		vol = Math.Clamp(vol, 0.0, 1.0);
		set_volume_db((float)Math.Max(Mathf.LinearToDb(vol * gain), minDb));
	}

	/// <summary>
	/// 人声：读该谱面的启用/路径/音量/偏移，装载解码器并就位到 0（偏移 &gt; 0 时由音频回调的
	/// 门控放行）。播放器页面的音量优先：per-MIDI 的 vocal_volume 只是"没在播放器页调过"的
	/// 默认值。存的人声路径失效时回退到谱面元数据的 audio_path。
	/// </summary>
	private void ApplyChartVocal(Dictionary<string, object> cfg, string chartKey, ChartDb db)
	{
		if (!(_audioOutput is MiniaudioAudioOutputBridge ma))
		{
			return;
		}
		// 用户在本曲里显式关掉了人声：保持关闭，不让配置把它重新拉起来
		// （旧实现靠 _sync_vocal_with_midi 顶部检查 current_midi_data.vocal_enabled 达到同一效果）
		if (_vocalDisabledByUser)
		{
			ma.UnloadVocal();
			_loadedVocalFilePath = "";
			return;
		}
		bool enabled = true;   // 未配置过 vocal_enabled 时默认跟随"是否有音频"（与 DataManager 一致）
		string path = "";
		bool playerVolumeSet = _playerVocalVolumeLinear >= 0.0f;
		float vol = playerVolumeSet ? _playerVocalVolumeLinear : _vocalVolumeLinear;
		double offsetMs = 0.0;
		if (PlainBool(cfg, "vocal_enabled", out bool ev))
		{
			enabled = ev;
		}
		if (PlainStr(cfg, "vocal_file_path", out string pv))
		{
			path = pv;
		}
		if (!playerVolumeSet && PlainDouble(cfg, "vocal_volume", out double vv))
		{
			vol = (float)vv;
		}
		if (PlainDouble(cfg, "vocal_offset_ms", out double ov))
		{
			offsetMs = ov;
		}
		// 与前台 VocalTrackController.resolve_vocal_path 同语义：路径失效则回退到谱面 audio_path
		if (!enabled || string.IsNullOrEmpty(path) || !FileExistsSafe(path))
		{
			path = db != null ? db.GetAudioPath(chartKey) : "";
			enabled = !string.IsNullOrEmpty(path) && FileExistsSafe(path);
		}
		if (!enabled)
		{
			ma.UnloadVocal();
			_loadedVocalFilePath = "";
			return;
		}
		// miniaudio 的 C 解码器只认原生文件系统路径
		path = GlobalizeNativePath(path);
		// 同一人声文件（同一首曲重载，如 TrackView 刷新）不必重建解码器：
		// 与旧行为一致（旧 _preload_vocal_native 只在路径变化时装载），只重定位/重排门控。
		bool sameVocal = !string.IsNullOrEmpty(_loadedVocalFilePath) && _loadedVocalFilePath == path;
		if (!sameVocal)
		{
			if (!ma.LoadVocalFile(path))
			{
				ThreadSafeLog.PrintErr($"[MeltySynthPlayer] vocal load failed: {path}");
				return;
			}
			_loadedVocalFilePath = path;
		}
		_vocalVolumeLinear = vol;
		ma.SetVocalVolume(vol);
		ma.SeekVocal(0.0);
		// 偏移门控：MIDI 未走到 vocal_offset_ms 时人声保持静音，由音频回调放行。
		// 必须在 PlayVocal 之前设置——门控未放行时它会自行起播。
		ma.SetVocalOffsetMs(offsetMs);
		ma.ResetVocalOffsetGate();
		if (offsetMs <= 0.0)
		{
			ma.PlayVocal();
		}
		ThreadSafeLog.Print($"[MeltySynthPlayer] vocal ready: {path} (offset={offsetMs:F0}ms)");
	}

	/// <summary>
	/// 人声相对 MIDI 的起点偏移（毫秒）。下发到 bridge，由音频回调执行门控
	/// （后台主循环停摆时 GDScript 的 _sync_vocal_with_midi 不运行，只有回调可靠）。
	/// </summary>
	public void set_vocal_offset_ms(double offsetMs)
	{
		if (_audioOutput is MiniaudioAudioOutputBridge ma)
		{
			ma.SetVocalOffsetMs(offsetMs);
		}
	}

	public double get_vocal_offset_ms()
	{
		return _audioOutput is MiniaudioAudioOutputBridge ma ? ma.GetVocalOffsetMs() : 0.0;
	}

	public double get_vocal_position_ms()
	{
		return _audioOutput?.GetVocalPositionMs() ?? 0.0;
	}

	public double get_vocal_length_ms()
	{
		return _audioOutput?.GetVocalLengthMs() ?? -1.0;
	}

	public bool is_vocal_playing()
	{
		return _audioOutput?.IsVocalPlaying() ?? false;
	}

	public bool is_vocal_finished()
	{
		return _audioOutput?.IsVocalFinished() ?? false;
	}

	public uint get_vocal_underrun_count()
	{
		return _audioOutput?.GetVocalUnderrunCount() ?? 0u;
	}


	public void set_bus(StringName targetBus)
	{
		_bus = targetBus;
		if (_audioOutput != null)
		{
			_audioOutput.SetBus(targetBus);
		}
	}

	public void set_max_polyphony(int value)
	{
		max_polyphony = Math.Max(16, Math.Min(256, value));
		ThreadSafeLog.Print($"[MeltySynthPlayer] Max polyphony set to: {max_polyphony}");
		
		// 注意：Synthesizer.MaximumPolyphony 是只读属性，只能在创建时设置
		// 新设置将在下一次加载 SoundFont 时生效
	}

	/// <summary>听歌降耗档已移除（见 GameplayPeriod 处的说明）</summary>

	// Getter methods for compatibility
	public string get_soundfont() => _soundfont;
	public string get_file() => _file;
	public float get_volume_db() => _volume_db;
	public StringName get_bus() => _bus;

	/// <summary>重置音频渲染时间戳（位置重启时调用，避免首帧误外推）</summary>
	private void ResetRenderTimestamp()
	{
		if (_audioOutput is MiniaudioAudioOutputBridge maBridge)
		{
			maBridge.ResetLastRenderTimestamp();
		}
	}

	/// <summary>
	/// 音频侧原始参考位置（已渲染帧 + 短外推，未扣设备延迟），仅用于校准判定钟。
	/// 人声同步请使用 get_raw_position_ms()。
	/// </summary>
	private double GetAudioRawReferenceMs(double renderedMs)
	{
		if (_audioOutput != null && _audioOutput.IsPlaying && _audioOutput is MiniaudioAudioOutputBridge maBridge)
		{
			return renderedMs + maBridge.GetExtrapolationMs();
		}
		return renderedMs;
	}

	/// <summary>作废判定钟锚点：下次 get_position_ms() 按当前音频参考重建锚点。</summary>
	private void InvalidateJudgeClock()
	{
		_judgeAnchorValid = false;
	}

	/// <summary>上次排队的 seek 是否已被音频线程落盘（无桥/无请求按未落盘处理）。</summary>
	private bool IsBridgeSeekApplied()
	{
		return _audioOutput is MiniaudioAudioOutputBridge ma && ma.IsSeekApplied;
	}

	/// <summary>以给定位置建立判定钟墙钟锚点（位置未扣设备延迟，读取时统一扣除）。</summary>
	private void ReanchorJudgeClock(double positionMs)
	{
		_judgeAnchorMs = positionMs;
		_judgeAnchorTicks = Stopwatch.GetTimestamp();
		_judgeAnchorValid = true;
	}

	public double get_position_ms()
	{
		// 【修复】seek 待处理期间返回目标位置，避免 NoteDisplayer 看到不连贯的位置跳跃
		// 支持负数位置（pre-roll）
		if (!double.IsNaN(_pendingSeekMs))
		{
			_lastPositionMs = _pendingSeekMs;
			return _pendingSeekMs;
		}

		// 【修复】seek 完成后若干帧内（原生 Seek 后 sequencer 渲染钟尚未反映新位置，
		// 会瞬回 ~0），直接返回 seek 目标位置，避免上层 NoteDisplayer 误判位置回退而
		// 触发音符左缩、各音轨已通过计数清零。
		// 仅在"seek 还没被音频线程落盘"时成立：已落盘说明渲染钟已到目标，再返回旧值
		// 反而会跨后台挂起残留（回前台头几帧显示 seek 目标而不是真实位置）。
		if (_seekPositionHoldFrames > 0 && !IsBridgeSeekApplied())
		{
			_seekPositionHoldFrames--;
			return _lastPositionMs;
		}

		// 在 pre-roll 阶段返回当前的负数 offset
		if (_currentOffsetMs < 0.0)
		{
			_lastPositionMs = _currentOffsetMs;
			return _currentOffsetMs;
		}

		// 【修复D-4】非播放状态（暂停 / seek 后 / 自然结束）返回最后已知位置，不再归零，
		// 避免暂停或 seek 后位置丢失（TrackView / NoteDisplayer / 判定链路读取位置时依赖稳定值）
		if (!playing)
		{
			return _lastPositionMs;
		}

		if (_sequencer == null || !_sequencerStarted)
		{
			return _lastPositionMs;
		}

		// 【判定钟 = 墙钟锚点推进 + 音频参考慢速校准】
		// 旧实现为"已渲染帧 + 上限 2 周期的外推"：音频回调被延迟调度时外推封顶、
		// 判定位置冻结，玩家看到音符到线却判定不到（漏判 / 滞后）。
		// 改为墙钟锚点后判定位置与回调调度无关，始终连续推进。
		double renderedMs = _sequencer.RenderedPosition.TotalMilliseconds;

		// 音频渲染钟大幅回跳只可能是 loop 回绕（或未显式处理的 seek）：
		// 判定钟必须跟随回绕，否则会停滞在回绕点。
		if (_judgeAnchorValid && renderedMs < _lastRenderedRefMs - JudgeWrapBackwardEpsilonMs)
		{
			InvalidateJudgeClock();
		}
		_lastRenderedRefMs = renderedMs;

		double audioRefMs = GetAudioRawReferenceMs(renderedMs);

		// 音频尚未产出任何渲染帧（play() 后设备启动 / 跨零点重启窗口）：锚点必须持续钉在
		// 音频参考上。否则墙钟会在设备真正出声前抢先推进，造成开局判定超前（音符到线早于发声）。
		// 设备一旦开始渲染 renderedMs 立即大于 0，此后恢复正常锚点推进。
		if (!_judgeAnchorValid || renderedMs <= 0.0)
		{
			// seek 后优先按目标位置重建：音频渲染钟要等音频线程消费请求后才更新，
			// 用它重锚会让进度条从 seek 前的位置起算（表现为复位到错误位置）。
			// 但目标位置只在「seek 尚未被音频线程落盘」时可信：主循环挂起（后台）期间
			// 音频可能早已落盘并播走甚至回绕，此时陈旧目标会让判定钟与音频长期分叉
			// （进度条停在 seek 处自走到满，而实际音频在别处）。
			double reanchorMs = audioRefMs;
			if (!double.IsNaN(_seekAnchorMs) && !IsBridgeSeekApplied())
			{
				reanchorMs = _seekAnchorMs;
			}
			ReanchorJudgeClock(reanchorMs);
			_seekAnchorMs = double.NaN;
		}

		double latencyMs = (_audioOutput != null && _audioOutput.IsPlaying) ? _audioOutput.GetLatencyMs() : 0.0;
		double elapsedMs = (Stopwatch.GetTimestamp() - _judgeAnchorTicks) / (double)Stopwatch.Frequency * 1000.0;
		double wallRawMs = _judgeAnchorMs + elapsedMs * _sequencer.Speed;

		// 慢速校准：健康区间内把墙钟稳稳拉向音频参考（只吸收一小部分，不产生位置跳变）；
		// 误差超出去噪带说明音频确实被卡住/落后，此时保持墙钟推进（判定不冻结），
		// 音频侧的补偿交由上层重同步策略处理。
		double errorMs = audioRefMs - wallRawMs;
		if (Math.Abs(errorMs) <= JudgeCalibrationDeadbandMs)
		{
			_judgeAnchorMs += errorMs * JudgeSlewGain;
			wallRawMs += errorMs * JudgeSlewGain;
		}

		double resultMs = Math.Max(0.0, wallRawMs - latencyMs);
		_lastPositionMs = resultMs;
		return resultMs;
	}

	/// <summary>
	/// 获取音频回调已渲染的 MIDI 原始位置（毫秒）。
	/// 不做设备延迟补偿，也不使用系统墙钟；该位置与 miniaudio 回调中
	/// 人声消费帧使用相同的音频回调时钟，仅用于人声同步比较。
	/// </summary>
	public double get_raw_position_ms()
	{
		if (!double.IsNaN(_pendingSeekMs))
		{
			return _pendingSeekMs;
		}

		if (_currentOffsetMs < 0.0)
		{
			return _currentOffsetMs;
		}

		if (!playing || _sequencer == null || !_sequencerStarted)
		{
			return _lastPositionMs;
		}

		return _sequencer.RenderedPosition.TotalMilliseconds;
	}

	/// <summary>
	/// 人声是否已就绪（解码生产端已跟上，可以起播/对齐）。
	/// 人声由原生解码线程异步填环形缓冲，起播瞬间往往还没填好，直接出声会落后伴奏一截。
	/// 判定：无配置人声 → 立即就绪；已加载 → 需已在播放，且连续若干帧没有新增欠载
	/// （欠载计数稳定说明缓冲不再断供）。调用方据此替代固定等待，慢设备自然多等一会。
	/// </summary>
	public bool is_vocal_ready()
	{
		if (!(_audioOutput is MiniaudioAudioOutputBridge ma) || !ma.IsVocalLoaded)
		{
			return true;
		}
		if (!ma.IsVocalPlaying() || ma.GetVocalPositionMs() < 0.0)
		{
			return false;
		}
		uint underruns = ma.GetVocalUnderrunCount();
		if (underruns != _vocalReadyProbeUnderruns)
		{
			// 仍在欠载（缓冲没填上）：重置稳定计数，等下一帧再看
			_vocalReadyProbeUnderruns = underruns;
			_vocalReadyStableFrames = 0;
			return false;
		}
		_vocalReadyStableFrames++;
		return _vocalReadyStableFrames >= VocalReadyStableFrames;
	}

	/// <summary>人声就绪探测：欠载计数的上次采样值与连续稳定帧数</summary>
	private uint _vocalReadyProbeUnderruns;
	private int _vocalReadyStableFrames;
	private const int VocalReadyStableFrames = 6;

	/// <summary>起播后补一次与拖动等价的原地 seek（由音频回调按帧数计时，后台也生效）</summary>
	public void request_startup_align()
	{
		if (_audioOutput is MiniaudioAudioOutputBridge maBridge)
		{
			maBridge.RequestStartupAlign();
		}
	}

	public void set_track_channel_volume(int trackIndex, int channel, float volumeLinear)
	{
		var virtualId = trackIndex * 16 + channel;
		_virtualChannelVolumes[virtualId] = Mathf.Clamp(volumeLinear, 0.0f, 1.0f);
	}

	public float get_track_channel_volume(int trackIndex, int channel)
	{
		var virtualId = trackIndex * 16 + channel;
		return _virtualChannelVolumes.TryGetValue(virtualId, out var volume) ? volume : 1.0f;
	}

	// 【系统时钟模式】事件派发时机改由系统墙钟驱动：sequencer 在每个 block 边界取一次
	// 墙钟位置，并 flush 该位置之前的全部事件。启用后事件派发钟与判定钟（同为墙钟锚点）
	// 同源，低性能设备上音频回调被延迟调度时，二者不再沿不同时间轴分离。
	// 关闭时回退为按音频渲染帧派发（旧行为）。
	// 线程模型：SetSystemClockMode 会重写 clockBasePosition/clockBaseTimestamp，而音频线程
	// 在 Render→GetSystemClockPosition 中读取这两个字段，故必须在 _synthLock 内调用，
	// 与其它 sequencer 状态变更保持同一互斥域。
	public void set_use_system_stopwatch(bool enabled)
	{
		_systemClockRequested = enabled;

		if (_sequencer == null)
		{
			return;  // sequencer 尚未创建，创建时按 _systemClockRequested 应用
		}

		if (_sequencer.UseSystemClock == enabled)
		{
			return;  // 状态未变化，避免重复作废判定钟锚点
		}

		WithSynthLock(() =>
		{
			_sequencer.SetSystemClockMode(enabled);
		});

		// 模式切换会把 RenderedPosition 基准重置到当前位置，判定钟锚点与渲染时间戳须一并作废
		ResetRenderTimestamp();
		InvalidateJudgeClock();
		ThreadSafeLog.Print($"[MeltySynthPlayer] System clock mode: {(enabled ? "ON" : "OFF")}");
	}

	public bool get_use_system_stopwatch()
	{
		return _sequencer != null && _sequencer.UseSystemClock;
	}

	public void set_track_channel_instrument(int trackIndex, int channel, int bank, int program)
	{
		var trackMap = _trackChannelInstruments.GetOrAdd(trackIndex, _ => new ConcurrentDictionary<int, (int, int)>());
		trackMap[channel] = (bank, program);

		var virtualId = trackIndex * 16 + channel;
		_virtualChannelInstruments[virtualId] = (bank, program);
		_virtualChannelCurrentBank[virtualId] = bank;
		_virtualChannelCurrentProgram[virtualId] = program;

		// 【修复】立即写入合成器，使用两种方式确保改变立即生效：
		// 1. 直接通过 ProcessMidiMessage（标准 MIDI 方式）
		// 2. 如果通道已存在，直接修改通道对象（确保对正在播放的音符也有效）
		//
		// 【必须 WithSynthLock】ProcessMidiMessage 会改通道的 bank/program/patch（并可能触发
		// NoteOffAll 与 voices 数组变动），而音频回调正在同一合成器上 Process/Render voices。
		// 这两者并发就是"数组越界"那类崩溃；TrackView 改音色时歌曲通常正在播放，属常见操作。
		WithSynthLock(() =>
		{
			if (_synth != null)
			{
				_synth.ProcessMidiMessage(virtualId, 0xB0, 0x00, bank);
				_synth.ProcessMidiMessage(virtualId, 0xC0, program, 0);

				// 检查通道是否已存在，如果存在则直接修改其 Bank 和 Patch
				if (_synth.HasVirtualChannel(virtualId))
				{
					try
					{
						var (_, physicalChannel) = _synth.ParseVirtualChannelId(virtualId);
						// 通过反射获取通道对象并直接修改（备选方案）
						// 如果 MeltySynth 将来提供直接访问通道的 API，可以改用那个
						// ThreadSafeLog.Print($"[MeltySynthPlayer] [RUNTIME] Set instrument for virtual channel {virtualId} (Track {trackIndex}, Channel {physicalChannel}): Bank {bank}, Program {program}");
					}
					catch (Exception ex)
					{
						ThreadSafeLog.PrintErr($"[MeltySynthPlayer] Error accessing channel info: {ex.Message}");
					}
				}
			}

			if (_manualSynth != null)
			{
				_manualSynth.ProcessMidiMessage(virtualId, 0xB0, 0x00, bank);
				_manualSynth.ProcessMidiMessage(virtualId, 0xC0, program, 0);
			}
		});

		// 通道状态变化，清除缓存以强制下次触发时重新应用
		_channelStateAppliedToManual.TryRemove(virtualId, out _);
	}

	public Godot.Collections.Dictionary get_track_channel_instrument(int trackIndex, int channel)
	{
		if (_trackChannelInstruments.TryGetValue(trackIndex, out var trackMap)
				&& trackMap.TryGetValue(channel, out var info))
		{
			return new Godot.Collections.Dictionary
			{
				{ "bank", info.bank },
				{ "program", info.program }
			};
		}

		return new Godot.Collections.Dictionary
		{
			{ "bank", 0 },
			{ "program", 0 }
		};
	}

	public Godot.Collections.Array get_presets_list()
	{
		var presets = new Godot.Collections.Array();
		if (_soundFont == null)
		{
			return presets;
		}

		foreach (var preset in _soundFont.PresetArray)
		{
			var entry = new Godot.Collections.Dictionary
			{
				{ "bank", preset.BankNumber },
				{ "program", preset.PatchNumber },
				{ "name", preset.Name }
			};
			presets.Add(entry);
		}

		return presets;
	}

	public string get_preset_name(int program, int bank = 0)
	{
		if (_soundFont == null)
		{
			return "";
		}

		foreach (var preset in _soundFont.PresetArray)
		{
			if (preset.BankNumber == bank && preset.PatchNumber == program)
			{
				return preset.Name;
			}
		}

		return "";
	}

	public void set_manually_controlled_notes(Godot.Collections.Dictionary manuallyControlled)
	{
		// 【TMX-005】快照重建契约：播放中禁止重建。
		// 音频线程在播放中持有旧快照并修改内部计数，重建只能在非播放状态进行。
		if (playing)
		{
			ThreadSafeLog.PrintErr("[MeltySynthPlayer] set_manually_controlled_notes ignored while playing (snapshot rebuild not allowed)");
			return;
		}

		// 新格式：{track_index: {channel: {pitch: {start_tick: true}}}}
		// 旧格式：{channel: {pitch: true}}
		var newFilters = new Dictionary<long, ManualFilterState>();
		foreach (var key in manuallyControlled.Keys)
		{
			var level1Variant = (Variant)manuallyControlled[key];
			if (level1Variant.VariantType != Variant.Type.Dictionary)
			{
				continue;
			}
			var level1Dict = level1Variant.AsGodotDictionary();

			if (!TryConvertToInt(key, out var outerKey))
			{
				continue;
			}
			var isNewFormat = false;

			// 探测新格式：level1 的 value 仍是 Dictionary（channel -> pitchMap）
			foreach (var level1Key in level1Dict.Keys)
			{
				var level2Variant = (Variant)level1Dict[level1Key];
				if (level2Variant.VariantType == Variant.Type.Dictionary)
				{
					isNewFormat = true;
				}
				break;
			}

			if (isNewFormat)
			{
				var trackIndex = outerKey;
				foreach (var channelKey in level1Dict.Keys)
				{
					var pitchMapVariant = (Variant)level1Dict[channelKey];
					if (pitchMapVariant.VariantType != Variant.Type.Dictionary)
					{
						continue;
					}
					var pitchMap = pitchMapVariant.AsGodotDictionary();

					if (!TryConvertToInt(channelKey, out var channel))
					{
						continue;
					}
					var virtualChannel = trackIndex * 16 + channel;

					foreach (var pitchKey in pitchMap.Keys)
					{
						if (TryConvertToInt(pitchKey, out var pitch))
						{
							var startTickMapVariant = (Variant)pitchMap[pitchKey];
							AddManualFilterCountsByTick(newFilters, virtualChannel, pitch, startTickMapVariant);
						}
					}
				}
			}
			else
			{
				// 旧格式兼容：outerKey 即 channel，默认 track=0
				var channel = outerKey;
				var virtualChannel = channel;

				foreach (var pitchKey in level1Dict.Keys)
				{
					if (TryConvertToInt(pitchKey, out var pitch))
					{
						// 旧格式只有 bool，保持"全局屏蔽该音高"语义
						AddManualFilterCount(newFilters, virtualChannel, pitch, MessageHandlerContext.ManualWildcardTick, int.MaxValue / 4);
					}
				}
			}
		}

		// 【TMX-005】不可变快照：构建完成后一次性交换引用（volatile 写）。
		// 音频线程在每条消息里只捕获一次引用、只读字典结构（内部计数仅音频线程改）。
		_manualFilterRegistry.Filters = newFilters;
	}

	private void AddManualFilterCount(Dictionary<long, ManualFilterState> filters, int virtualChannel, int pitch, int tick, int count)
	{
		if (count <= 0)
		{
			return;
		}

		var key = MessageHandlerContext.MakeManualFilterKey(virtualChannel, pitch);
		if (!filters.TryGetValue(key, out var state))
		{
			state = new ManualFilterState();
			filters[key] = state;
		}

		var current = state.PendingManualOnsByTick.ContainsKey(tick) ? state.PendingManualOnsByTick[tick] : 0;
		if (current > int.MaxValue - count)
		{
			state.PendingManualOnsByTick[tick] = int.MaxValue;
		}
		else
		{
			state.PendingManualOnsByTick[tick] = current + count;
		}
	}

	private void AddManualFilterCountsByTick(Dictionary<long, ManualFilterState> filters, int virtualChannel, int pitch, Variant startTickMapVariant)
	{
		if (startTickMapVariant.VariantType == Variant.Type.Dictionary)
		{
			var tickDict = startTickMapVariant.AsGodotDictionary();
			foreach (var tickKey in tickDict.Keys)
			{
				if (!TryConvertToInt(tickKey, out var tick))
				{
					continue;
				}

				var entry = (Variant)tickDict[tickKey];
				var count = 0;
				switch (entry.VariantType)
				{
					case Variant.Type.Bool:
						count = entry.AsBool() ? 1 : 0;
						break;
					case Variant.Type.Int:
						count = Math.Max(0, (int)entry.AsInt64());
						break;
					case Variant.Type.Float:
						count = Math.Max(0, (int)Math.Round(entry.AsDouble()));
						break;
					default:
						count = 1;
						break;
				}

				AddManualFilterCount(filters, virtualChannel, pitch, tick, count);
			}
			return;
		}

		if (startTickMapVariant.VariantType == Variant.Type.Bool)
		{
			if (startTickMapVariant.AsBool())
			{
				AddManualFilterCount(filters, virtualChannel, pitch, MessageHandlerContext.ManualWildcardTick, 1);
			}
			return;
		}

		if (startTickMapVariant.VariantType == Variant.Type.Int)
		{
			AddManualFilterCount(filters, virtualChannel, pitch, MessageHandlerContext.ManualWildcardTick, Math.Max(0, (int)startTickMapVariant.AsInt64()));
			return;
		}

		if (startTickMapVariant.VariantType == Variant.Type.Float)
		{
			AddManualFilterCount(filters, virtualChannel, pitch, MessageHandlerContext.ManualWildcardTick, Math.Max(0, (int)Math.Round(startTickMapVariant.AsDouble())));
			return;
		}

		AddManualFilterCount(filters, virtualChannel, pitch, MessageHandlerContext.ManualWildcardTick, 1);
	}

	private static bool TryConvertToInt(object value, out int result)
	{
		result = 0;

		if (value == null)
		{
			return false;
		}

		if (value is int intValue)
		{
			result = intValue;
			return true;
		}

		if (value is long longValue)
		{
			result = (int)longValue;
			return true;
		}

		if (value is float floatValue)
		{
			result = (int)floatValue;
			return true;
		}

		if (value is double doubleValue)
		{
			result = (int)doubleValue;
			return true;
		}

		if (value is string stringValue)
		{
			return int.TryParse(stringValue, out result);
		}

		if (value is Variant variantValue)
		{
			switch (variantValue.VariantType)
			{
				case Variant.Type.Int:
					result = (int)variantValue.AsInt64();
					return true;
				case Variant.Type.Float:
					result = (int)variantValue.AsDouble();
					return true;
				case Variant.Type.String:
					return int.TryParse(variantValue.AsString(), out result);
				default:
					return false;
			}
		}

		return false;
	}

	public void trigger_note_on(int pitch, int velocity, int channel)
	{
		trigger_note_on(pitch, velocity, channel, 0);
	}

	// 【TEMP DIAG】首触卡顿定位：前 5 次 trigger_note_on 耗时（验证后移除）
	private int _diag_trigger_count = 0;

	public void trigger_note_on(int pitch, int velocity, int channel, int trackIndex)
	{
		// 【TEMP DIAG】首触卡顿定位（验证后移除）
		var diagSw = System.Diagnostics.Stopwatch.StartNew();
		var virtualId = trackIndex * 16 + channel;
		var volume = _virtualChannelVolumes.TryGetValue(virtualId, out var vol) ? vol : 1.0f;
		var scaledVelocity = Math.Clamp((int)Math.Round(velocity * volume), 0, 127);

		if (_mutedVirtualChannels.ContainsKey(virtualId) || scaledVelocity == 0)
		{
			diagSw.Stop();
			return;
		}

		// 应用通道状态（Bank/Program/CC等），缓存确保仅首次触发时生效
		ApplyChannelStateToManualSynth(virtualId);

		if (_audioOutput != null)
		{
			// 正常路径：无锁入队，音频线程在 FillPcmDataDirect 中处理
			_audioOutput.EnqueueNoteOn(virtualId, pitch, scaledVelocity);
			// 确保 audio device 已启动：非播放状态（如 DelayAdjust 校准）下 _Process 不渲染，
			// audio device 可能处于停止状态，入队的音符不会被消费。此处强制启动。
			RequestAudioOutputPlay();
		}
		else
		{
			// 回退路径：音频输出未就绪，直接调用合成器
			var synth = (_useSeparateSynthForManual && _manualSynth != null) ? _manualSynth : _synth;
			synth?.NoteOn(virtualId, pitch, scaledVelocity);
		}

		diagSw.Stop();
		if (_diag_trigger_count < 5)
		{
			_diag_trigger_count++;
			ThreadSafeLog.Print($"[TapDiag] trigger_note_on#{_diag_trigger_count} pitch={pitch} vel={scaledVelocity} ch={virtualId} elapsed={diagSw.Elapsed.TotalMilliseconds:F3}ms");
		}
	}

	/// <summary>
	/// 批量触发手动音符（演奏模式一次判定只做一次跨语言调用，避免逐 original note 的 GDScript→C# 开销）。
	/// events: Array[Dictionary]，每项 {pitch:int, velocity:int, channel:int, track_index:int}。
	/// 语义与 trigger_note_on 完全一致（音量/静音过滤、通道状态应用、无锁入队）。
	/// </summary>
	public void trigger_notes_on(Godot.Collections.Array events)
	{
		foreach (var ev in events)
		{
			if (ev.VariantType != Variant.Type.Dictionary)
			{
				continue;
			}
			var dict = ev.AsGodotDictionary();
			var pitch = dict.TryGetValue("pitch", out var p) && p.VariantType == Variant.Type.Int ? (int)p.AsInt64() : 0;
			var velocity = dict.TryGetValue("velocity", out var v) && v.VariantType == Variant.Type.Int ? (int)v.AsInt64() : 0;
			var channel = dict.TryGetValue("channel", out var c) && c.VariantType == Variant.Type.Int ? (int)c.AsInt64() : 0;
			var track = dict.TryGetValue("track_index", out var t) && t.VariantType == Variant.Type.Int ? (int)t.AsInt64() : 0;
			trigger_note_on(pitch, velocity, channel, track);
		}
	}

	/// <summary>
	/// 预热手动音符触发路径（无声音、无副作用）。
	/// 对每个 (track, channel) 在独立手动合成器上预建通道并走一遍 ProcessMidiMessage + NoteOn(velocity=1)+NoteOff：
	/// - 预热 JIT：Synthesizer.NoteOn/NoteOff、Voice.Start、preset 查找、通道分配
	/// - 不写任何共享状态（_virtualChannelInstruments/镜像字典等），不触碰音频输出，
	///   手动合成器仅在 _manualActiveVoiceCount > 0（经 EnqueueNoteOn 入队）时才被音频回调渲染，直接调用必然静音。
	/// 由 PlayView 在歌曲信息面板展示期（主线程本就可阻塞）调用，把首次点击的一次性成本移到开局前。
	/// trackChannelInstruments: {track_index: {channel: {bank:int, program:int}}}（可选，用于预建歌曲实际用到的通道）
	/// </summary>
	public void warmup_manual_path(Godot.Collections.Dictionary trackChannelInstruments)
	{
		// 单独合成器模式才预热：若手动与自动共用同一合成器，直接 NoteOn 会在自动合成器上
		// 产生会被音频回调渲染的残余 voice（即使立即 NoteOff 也可能留下短暂声音）
		if (_manualSynth == null || _synth == null || _manualSynth == _synth)
		{
			return;
		}

		if (trackChannelInstruments.Count == 0)
		{
			// 无乐器表：预热默认钢琴通道（JIT + 通道分配，兜底）
			_manualSynth.NoteOn(0, 60, 1);
			_manualSynth.NoteOff(0, 60);
			return;
		}

		foreach (var trackKey in trackChannelInstruments.Keys)
		{
			if (!TryConvertToInt(trackKey, out var track))
			{
				continue;
			}
			var channelsVariant = (Variant)trackChannelInstruments[trackKey];
			if (channelsVariant.VariantType != Variant.Type.Dictionary)
			{
				continue;
			}
			var channels = channelsVariant.AsGodotDictionary();
			foreach (var chKey in channels.Keys)
			{
				if (!TryConvertToInt(chKey, out var channel))
				{
					continue;
				}
				var infoVariant = (Variant)channels[chKey];
				if (infoVariant.VariantType != Variant.Type.Dictionary)
				{
					continue;
				}
				var info = infoVariant.AsGodotDictionary();
				var bank = info.TryGetValue("bank", out var b) && b.VariantType == Variant.Type.Int ? (int)b.AsInt64() : 0;
				var program = info.TryGetValue("program", out var pr) && pr.VariantType == Variant.Type.Int ? (int)pr.AsInt64() : 0;
				var virtualId = track * 16 + channel;
				// NoteOn/NoteOff 直接动 voices 数组，而音频回调正在同一手动合成器上 Render：
				// 与回调互斥后再写（本方法在打歌预卷期由主线程调用，那时设备已在跑）。
				WithSynthLock(() =>
				{
					_manualSynth.ProcessMidiMessage(virtualId, 0xB0, 0x00, bank);
					_manualSynth.ProcessMidiMessage(virtualId, 0xC0, program, 0);
					_manualSynth.NoteOn(virtualId, 60, 1);
					_manualSynth.NoteOff(virtualId, 60);
				});
			}
		}
	}

	public void trigger_note_off(int pitch, int _velocity, int channel)
	{
		trigger_note_off(pitch, _velocity, channel, 0);
	}

	public void trigger_note_off(int pitch, int _velocity, int channel, int trackIndex)
	{
		var virtualId = trackIndex * 16 + channel;

		if (_audioOutput != null)
		{
			// 正常路径：无锁入队
			_audioOutput.EnqueueNoteOff(virtualId, pitch);
		}
		else
		{
			// 回退路径：直接调用合成器
			var synth = (_useSeparateSynthForManual && _manualSynth != null) ? _manualSynth : _synth;
			synth?.NoteOff(virtualId, pitch);
		}
	}

	public void stop_channel_notes(int channel)
	{
		// 归零控制器（CC123 All Notes Off）会改合成器 voices → 必须与音频回调互斥
		WithSynthLock(() => _synth?.ProcessMidiMessage(channel, 0xB0, 0x7B, 0));
	}

	private void stop_channel_notes_manual(int channel)
	{
		WithSynthLock(() => _manualSynth?.ProcessMidiMessage(channel, 0xB0, 0x7B, 0));
	}

	// Note: set_track_channel_mute with three parameters
	public void set_track_channel_mute(int trackIndex, int channel, bool muted)
	{
		var virtualId = trackIndex * 16 + channel;
		if (muted)
		{
			_mutedVirtualChannels.TryAdd(virtualId, 0);
			stop_channel_notes(virtualId);
			stop_channel_notes_manual(virtualId);
		}
		else
		{
			_mutedVirtualChannels.TryRemove(virtualId, out _);
		}
	}

	// Legacy overload for backward compatibility (assumes track 0)
	public void set_track_channel_mute(int channel, bool muted)
	{
		set_track_channel_mute(0, channel, muted);
	}

	// ===================== 接口实现：兼容性包装方法 =====================
	
	/// <summary>加载 MIDI 文件 (接口别名)。
	///
	/// 【必须先 stop()】旧的 GDScript 管理器 load_midi 开头就是 `stop()`，并留了原因：
	/// "TrackView 循环播放中直接进入 PlayView 时，后端 sequencer/playing 状态可能残留
	/// （实测：旧曲位置停留在 74s，pre-roll seek(-2000) 后 crossing-zero 状态机错乱，
	/// 表现为判定时钟异常 + 位置冻结 + 游戏提前结束）"。重构时这个 stop 丢了 ——
	/// 于是"在 TrackView 试听后直接进打歌页"这条常见路径会踩回同一个坑。
	/// 用底层 stop() 而不是 stop_transport()：不广播播放态，避免媒体通知闪暂停/封面硬切。
	/// </summary>
	public bool load_midi(string filePath)
	{
		try
		{
			stop();
			set_file(filePath);
			return _midiFile != null;
		}
		catch (Exception ex)
		{
			ThreadSafeLog.PrintErr($"[MeltySynthPlayer] Failed to load MIDI: {ex.Message}");
			return false;
		}
	}

	/// <summary>暂停播放 (接口方法)</summary>
	public void pause()
	{
		// 暂停态必须只在这里翻转（单一来源）：媒体键 "play"、UI 状态策略都靠它判断
		// "是不是被暂停了、该不该恢复"。只在 pause_with_vocal 里设会漏掉内部调用（如
		// 切到非播放页），表现为"暂停后按继续没反应"。
		_paused = true;
		// 暂停后 get_position_ms() 直接返回 _lastPositionMs，而主循环挂起（后台）期间
		// get_position_ms 不会被调用，那个值可能还停在 seek 目标上——于是"一点暂停进度条
		// 就跳回上次 seek 的位置"。这里按"已渲染 - 设备延迟"落一次真实位置（与判定钟同口径）。
		if (_sequencer != null && _sequencerStarted)
		{
			double pauseLatency = (_audioOutput != null && _audioOutput.IsPlaying) ? _audioOutput.GetLatencyMs() : 0.0;
			_lastPositionMs = Math.Max(0.0, _sequencer.RenderedPosition.TotalMilliseconds - pauseLatency);
		}
		InvalidateJudgeClock();  // 恢复时按暂停后的音频参考重建锚点
		playing = false;
		if (_sequencer != null)
		{
			// 线程模型：系统时钟模式下音频线程在 GetSystemClockPosition 中读取
			// isPaused/clockBasePosition/clockBaseTimestamp，Pause 写这些字段必须与回调渲染互斥。
			WithSynthLock(() =>
			{
				_sequencer.Pause();
				// 释放正在响的声部（发 NoteOff，走 release 包络自然衰减），避免暂停时
				// 已进入延音阶段的音符（长音/管风琴）因永远收不到 NoteOff 而持续鸣响。
				_synth?.NoteOffAll(false);
				if (_useSeparateSynthForManual && _manualSynth != null)
					_manualSynth.NoteOffAll(false);
			});
		}
		// 暂停时停掉设备：否则回调仍以约 187 次/秒渲染静音，后台停留时是纯发热。
		// ma_bridge_stop 会等待回调完成，必须在 _synthLock 之外调用（同 stop()）。
		_audioOutput?.Stop();
		// ThreadSafeLog.Print($"[MeltySynthPlayer] pause() called - _currentOffsetMs={_currentOffsetMs}, _sequencerStarted={_sequencerStarted}");
		// 保持 sequencer 状态，不重置位置

		// 记录暂停时的音源代际与在响音符，供 resume() 决定是否重发以延续长音
		_pausedSoundfontGen = _soundfontGeneration;
		lock (_activeNotesLock)
		{
			_restoreHeldNotes = _activeNotes.Count > 0;
		}
	}

	/// <summary>恢复播放 (接口方法)。返回 true 表示已真正续播，false 表示音源未就绪、已推迟到加载完成后续播。</summary>
	public bool resume()
	{
		_paused = false;
		InvalidateJudgeClock();  // 按 resume 后的音频参考重建锚点
		// 音源后台加载/切换尚未完成（_sequencer 可能仍是旧合成器）：不在旧合成器上续播，
		// 改为记录意图，待 FinalizeSoundfontLoad 用新合成器续播，避免切换瞬间静音。
		if (!_sfFinalized && (_sfLoadThread != null || _sfParseDone))
		{
			ThreadSafeLog.Print("[MeltySynthPlayer] SoundFont still loading/switching, deferring resume() until finalized");
			_pendingPlayAfterLoad = true;
			playing = true;
			return false;
		}
		PrepareAudioOutputForPlaybackStart();
		if (_midiFile != null && _sequencer != null)
		{
			// 【处理 pre-roll 模式】如果在 pre-roll 中，继续等待跨越零点
			if (_currentOffsetMs < 0.0)
			{
				// ThreadSafeLog.Print($"[MeltySynthPlayer] Resume from pre-roll (offset={_currentOffsetMs} ms)");
				playing = true;
				return true;  // 不启动 AudioStreamPlayer，等待跨越零点
			}

			// 线程模型：同 pause()，Resume 重设墙钟锚点，必须与回调渲染互斥
			WithSynthLock(() =>
			{
				if (!_sequencerStarted)
				{
					// 音源重载后新 sequencer 从未 Play 过：Resume() 是空操作，
					// 位置/渲染钟全部静止（进度条冻结、MIDI 静音），必须先启动
					_sequencer.Play(_midiFile, false);
					_sequencerStarted = true;
					ApplyInstrumentOverridesToSynth();
				}
				else
				{
					_sequencer.Resume();
				}
			});

			playing = true;
			_audioOutput?.Play();

			// 续播：把暂停瞬间仍在响的音符重新触发（经管道，乐器覆盖等仍生效），
			// 其后续 NoteOff 会由原序列器按时发出自然收尾。音源已切换（代际不符）则不重发。
			if (_restoreHeldNotes && _soundfontGeneration == _pausedSoundfontGen)
			{
			List<(int ch, int key, int vel)> toRestore = new List<(int, int, int)>();
			lock (_activeNotesLock)
			{
				foreach (var kv in _activeNotes)
					toRestore.Add((kv.Key.Item1, kv.Key.Item2, kv.Value));
			}
				foreach (var n in toRestore)
				{
					OnSendMessage(_synth, n.ch, 0x90, n.key, n.vel, 0);
				}
				_restoreHeldNotes = false;
			}
			return true;
		}
				return false;
	}

	/// <summary>跳转到指定位置 (接口别名)</summary>
	public void seek(float positionMs)
	{
		seek_ms((double)positionMs);
	}

	/// <summary>获取总时长 (接口方法)</summary>
	public float get_duration_ms()
	{
		if (_midiFile == null)
		{
			return 0.0f;
		}
		// MeltySynth 的 MidiFile.Length 是 TimeSpan 类型
		return (float)(_midiFile.Length.TotalMilliseconds);
	}

	/// <summary>检查是否正在播放 (接口方法)</summary>
	public bool is_playing()
	{
		return playing;
	}

	// ===================== 私有辅助方法 =====================

	/// <summary>
	/// 使用 Godot FileAccess 读取文件为 MemoryStream
	/// 解决 Android 上 res:// 路径无法通过 System.IO 访问的问题
	/// </summary>
	private MemoryStream OpenFileAsStream(string path, bool preferSystemIo = false)
	{
		// preferSystemIo：后台换曲线程专用。Godot 文件 API 有全局锁，而熄屏时主线程可能正
		// 持锁被冻结，后台线程再调就永久阻塞 —— 表现为"设备已停、不切歌、彻底静音"。
		//
		// 【user:// 也必须走 System.IO】桌面端 ChartDb 存的谱面路径就是 `user://files/Charts/...`，
		// 若只对"绝对路径"用 System.IO，后台换曲在桌面上依旧会落到 Godot FileAccess ——
		// 正是要避免的那种死锁。GlobalizeNativePath 只用主线程 _Ready 缓存的前缀做字符串拼接
		// （任意线程可用），故这里先把 user:// 转成原生路径再读。
		// res:// 例外：Android 上它在 APK/PCK 内，只能由引擎读。
		if (preferSystemIo && !path.StartsWith("res://"))
		{
			string nativePath = GlobalizeNativePath(path);
			if (!string.IsNullOrEmpty(nativePath) && !nativePath.StartsWith("res://") && !nativePath.StartsWith("user://"))
			{
				try
				{
					return new MemoryStream(System.IO.File.ReadAllBytes(nativePath));
				}
				catch (Exception e)
				{
					ThreadSafeLog.PrintErr($"[MeltySynthPlayer] System.IO read failed, falling back to Godot: {nativePath} ({e.Message})");
				}
			}
		}
		// res:// 路径在 Android 上嵌入 APK/PCK 中，必须通过 Godot FileAccess 读取
		// user:// 和绝对路径可以通过 System.IO 访问，但为统一起见全部用 Godot API
		var file = Godot.FileAccess.Open(path, Godot.FileAccess.ModeFlags.Read);
		if (file == null)
		{
			var error = Godot.FileAccess.GetOpenError();
			ThreadSafeLog.PrintErr($"[MeltySynthPlayer] Failed to open file via Godot FileAccess: {path} (error: {error})");
			
			// 回退：尝试 System.IO（仅对非 res:// 路径有效）
			if (!path.StartsWith("res://") && !path.StartsWith("user://"))
			{
				// ThreadSafeLog.Print($"[MeltySynthPlayer] Falling back to System.IO for path: {path}");
				return new MemoryStream(System.IO.File.ReadAllBytes(path));
			}
			throw new FileNotFoundException($"Cannot open file: {path} (Godot error: {error})");
		}
		
		var length = (long)file.GetLength();
		var bytes = file.GetBuffer(length);
		file.Close();
		// ThreadSafeLog.Print($"[MeltySynthPlayer] Loaded {length} bytes from: {path}");
		return new MemoryStream(bytes);
	}


	/// <summary>诊断：合成器锁当前是否被探针持住（供回归探针的等待线程自旋判断）。</summary>
	private volatile bool _diagSynthLockHeld = false;




	// 启动后台线程解析 SoundFont（纯 CPU：读文件 + 建合成器/序列器），解析完成置 _sfParseDone，	// 由主线程 _Process → FinalizeSoundfontLoad 完成合成器引用与音频桥绑定（必须主线程）。
	private void StartSoundfontLoadAsync(string path)
	{
		_sfParseDone = false;
		_sfFinalized = false;
		_sfLoadThread = new Thread(() => ParseSoundfontIntoPending(path));
		_sfLoadThread.IsBackground = true;
		_sfLoadThread.Start();
	}

	// worker 线程执行：只做纯 C# 解析，绝不碰 _audioOutput / EmitSignal（那些必须主线程）。
	private void ParseSoundfontIntoPending(string path)
	{
		try
		{
			using var stream = OpenFileAsStream(path);
			var soundFont = new SoundFont(stream);
			var settings = new SynthesizerSettings(_sampleRate)
			{
				MaximumPolyphony = max_polyphony,
				BlockSize = 256,
				EnableReverbAndChorus = false
			};
			var autoSynth = new Synthesizer(soundFont, settings);

			MessageHandlerContext msgCtx = _messageContext;
			List<IMidiMessageHandler> handlers;
			if (msgCtx == null)
			{
				msgCtx = new MessageHandlerContext(
					_virtualChannelCurrentBank, _virtualChannelCurrentProgram,
					_virtualChannelCc7, _virtualChannelCc11, _virtualChannelCc10,
					_virtualChannelPitchBend, _virtualChannelInstruments,
					_virtualChannelVolumes, _manualFilterRegistry,
					_mutedVirtualChannels, _channelStateAppliedToManual);
				handlers = new List<IMidiMessageHandler>
				{
					new ChannelStateMirrorHandler(msgCtx),
					new ManualNoteFilterHandler(msgCtx),
					new MuteFilterHandler(msgCtx),
					new InstrumentOverrideHandler(msgCtx),
					new VolumeScaleHandler(msgCtx),
					new SynthForwarderHandler()
				};
			}
			else
			{
				// 管道只构建一次：复用已有的 handler 快照
				handlers = new List<IMidiMessageHandler>(_handlers);
			}

			var sequencer = new MidiFileSequencer(autoSynth) { OnSendMessage = OnSendMessage };
			sequencer.SetSystemClockMode(_systemClockRequested);
			sequencer.SetDiagnosticsEnabled(false);

			Synthesizer manualSynth;
			if (_useSeparateSynthForManual)
			{
				var manualSettings = new SynthesizerSettings(_sampleRate)
				{
					MaximumPolyphony = Math.Max(16, max_polyphony / 4),
					BlockSize = 256,
					EnableReverbAndChorus = false
				};
				manualSynth = new Synthesizer(soundFont, manualSettings);
			}
			else
			{
				manualSynth = autoSynth;
			}

			lock (_sfLock)
			{
				_sfPendingSoundFont = soundFont;
				_sfPendingAuto = autoSynth;
				_sfPendingManual = manualSynth;
				_sfPendingSeq = sequencer;
				_sfPendingMsgCtx = msgCtx;
				_sfPendingHandlers = handlers;
			}
			_sfParseDone = true;
		}
		catch (Exception e)
		{
			ThreadSafeLog.PrintErr($"[MeltySynthPlayer] background SoundFont parse failed: {e.Message}");
			_sfParseDone = true; // 标记完成（即便失败），避免 _Process 反复重试
		}
	}

	// 主线程：把后台解析结果绑定到合成器与音频桥（音频相关 API 必须主线程）。
	private void FinalizeSoundfontLoad()
	{
		SoundFont soundFont;
		Synthesizer autoSynth, manualSynth;
		MidiFileSequencer sequencer;
		MessageHandlerContext msgCtx;
		List<IMidiMessageHandler> handlers;
		lock (_sfLock)
		{
			soundFont = _sfPendingSoundFont;
			autoSynth = _sfPendingAuto;
			manualSynth = _sfPendingManual;
			sequencer = _sfPendingSeq;
			msgCtx = _sfPendingMsgCtx;
			handlers = _sfPendingHandlers;
			_sfPendingSoundFont = null; _sfPendingAuto = null; _sfPendingManual = null;
			_sfPendingSeq = null; _sfPendingMsgCtx = null; _sfPendingHandlers = null;
		}
		if (soundFont == null)
		{
			return;
		}

		// 音源已重建：代际自增并使旧在响集合作废，避免把暂停时记录的旧音符注入新合成器
		// （设置→TrackView 切换音源后走 defer→play() 从头续播，不应残留旧音）。
		_soundfontGeneration++;
		_restoreHeldNotes = false;
		lock (_activeNotesLock)
		{
			_activeNotes.Clear();
		}

		_soundFont = soundFont;
		_autoSynth = autoSynth;
		_synth = autoSynth;
		_manualSynth = manualSynth;
		_sequencer = sequencer;
		_messageContext = msgCtx;
		_handlers = handlers;

		// 【TMX-005】合成器重建后清理手动通道状态缓存，并重新应用乐器覆盖
		_channelStateAppliedToManual.Clear();
		ApplyInstrumentOverridesToSynth();

		_sequencerStarted = false;
		_currentOffsetMs = 0.0;
		_hasSkippedPreroolEvents = false;

		// 纯 soundfont 重载（未重新 load_midi）时重新加载 MIDI 文件
		if (!string.IsNullOrEmpty(_file))
		{
			LoadMidiFile(_file);
		}

		_audioOutput?.SetSynthesizers(_sequencer, _autoSynth, _manualSynth, _useSeparateSynthForManual);
		_audioOutput?.SetVolume(_volumeLinear);
		_sfFinalized = true;
		EmitSignal(SignalName.soundfont_changed, _soundfont);
		EmitSignal(SignalName.soundfont_reload_completed);

		// 换曲时 MIDI 因音源未就绪而推迟载入：轨配置已在上面 LoadMidiFile 里被清空，补应用一次
		ApplyPendingChartConfigIfAny();

		// 异步加载完成前若已请求播放，现在后端已就绪，自动续播
		if (_pendingPlayAfterLoad && _midiFile != null)
		{
			_pendingPlayAfterLoad = false;
			ThreadSafeLog.Print("[MeltySynthPlayer] Resuming deferred play() after soundfont finalize");
			play();
			// 广播"推迟的续播已真正开始"。
			// 【必须有】旧实现在 _on_backend_soundfont_changed 里发这个信号，消费方是 TrackView：
			// 音源重载期间 play()/resume() 会被推迟，TrackView 据此把"音符显示"一起延后，
			// 等本信号再打开。重构后信号只声明未发射 → TrackView 的等待永远不返回，
			// 表现为"从设置页返回 TrackView 后音符静止不动"。
			EmitSignal(SignalName.deferred_play_resumed);
		}
	}

	/// <summary>
	/// 按当前音源重建合成器，并**保住播放位置与播放态**。
	///
	/// 用途：`max_polyphony` 这类参数是合成器**创建期**参数（SynthesizerSettings），
	/// 改完必须重建音源才生效。旧的 GDScript 管理器是"置新值 → 重新加载音源"，
	/// 结果播放位置被清零、还要靠 TrackView 的续播逻辑补救（注释里抱怨过"先回到原位置又从头重播"）。
	/// 这里把"停设备 → 重建 → 重载谱面 → 重放配置 → 回到原位 → 恢复播放"一次做完，
	/// 不留"从头重播 / 静音停在原地"的窗口。
	/// </summary>
	public void reload_soundfont_preserving_position()
	{
		if (string.IsNullOrEmpty(_soundfont))
		{
			return;
		}
		// 已有一次音源加载在飞：不要去和后台解析线程抢合成器。
		// 它 finalize 时会按当时已更新的 max_polyphony 重建，并自行重载 MIDI + 补应用配置。
		if (!_sfFinalized && (_sfLoadThread != null || _sfParseDone))
		{
			ThreadSafeLog.Print("[MeltySynthPlayer] reload_soundfont: async load in flight, deferring to finalize");
			return;
		}

		bool wasPlaying = playing;
		bool wasPaused = _paused;
		double pos = Math.Max(0.0, wasPlaying ? get_position_ms() : _lastPositionMs);
		ThreadSafeLog.Print($"[MeltySynthPlayer] reload_soundfont: preserving playing={wasPlaying} pos={pos:F0}ms");

		// 与音频回调互斥：先停设备（会等回调退出，故在锁外），再停 sequencer
		_audioOutput?.Stop();
		WithSynthLock(() =>
		{
			_sequencer?.Stop();
		});

		LoadSoundfont(_soundfont);

		if (!string.IsNullOrEmpty(_file))
		{
			LoadMidiFile(_file);
		}
		if (_midiFile != null && _sequencer != null)
		{
			WithSynthLock(() =>
			{
				_sequencer.Play(_midiFile, false);
				_sequencerStarted = true;
				ApplyInstrumentOverridesToSynth();
			});
			// 谱面运行时配置：LoadMidiFile 已清空轨道状态，必须重放（与换曲走同一份实现）
			if (!string.IsNullOrEmpty(_currentKey))
			{
				apply_chart_audio_config(_currentKey);
			}
			// 位置恢复放在配置之后：此时人声解码器已按配置重新装载/归零，
			// seek_ms 会一并把人声重定位到同一位置。
			if (pos > 0.0)
			{
				seek_ms(pos);
			}
		}

		playing = wasPlaying;
		_paused = wasPaused;
		InvalidateJudgeClock();
		if (wasPlaying && !wasPaused)
		{
			RequestAudioOutputPlay();
		}
	}

	private void LoadSoundfont(string path)
	{
		if (string.IsNullOrEmpty(path))
		{
			return;
		}

		using var stream = OpenFileAsStream(path);
		_soundFont = new SoundFont(stream);
		// BlockSize=256 与回调周期对齐（Android 256帧@48k≈5.33ms/回调）。
		// 此前 512 让整个块渲染集中在"每两次回调中的一次"（突发 5.5-6.2ms > 预算），
		// 导致设备缓冲周期性欠载；256 把渲染量均摊到每次回调（约 2.8-3.2ms），
		// 不增加延迟、不改复音数，事件触发粒度也细化到回调边界（与人声消费帧对齐）。
		var settings = new SynthesizerSettings(_sampleRate)
		{
			MaximumPolyphony = max_polyphony,
			BlockSize = 256,
			EnableReverbAndChorus = false
		};

		// ========== 创建两个独立的合成器 ==========
		// 自动播放合成器（用于 MIDI 序列器）
		_autoSynth = new Synthesizer(_soundFont, settings);
		_synth = _autoSynth;  // 兼容性：保持 _synth 指向自动合成器
		ThreadSafeLog.Print($"[MeltySynthPlayer] Created autoSynth: sampleRate={settings.SampleRate}, polyphony={settings.MaximumPolyphony}");

		// 初始化 OnSendMessage 拦截器管道（仅一次，字典引用持久有效）
		if (_messageContext == null)
		{
			_messageContext = new MessageHandlerContext(
				_virtualChannelCurrentBank, _virtualChannelCurrentProgram,
				_virtualChannelCc7, _virtualChannelCc11, _virtualChannelCc10,
				_virtualChannelPitchBend, _virtualChannelInstruments,
				_virtualChannelVolumes, _manualFilterRegistry,
				_mutedVirtualChannels, _channelStateAppliedToManual);
			var handlerList = new List<IMidiMessageHandler>
			{
				new ChannelStateMirrorHandler(_messageContext),
				new ManualNoteFilterHandler(_messageContext),
				new MuteFilterHandler(_messageContext),
				new InstrumentOverrideHandler(_messageContext),
				new VolumeScaleHandler(_messageContext),
				new SynthForwarderHandler()
			};
			// volatile 引用交换：音频线程只读一致快照，不会在迭代中被 Clear/Add 破坏
			_handlers = handlerList;
		}

		_sequencer = new MidiFileSequencer(_autoSynth)
		{
			OnSendMessage = OnSendMessage
		};
		// 创建时按请求状态恢复系统时钟模式（音源 / 采样率重建后不能静默回落到关闭）
		_sequencer.SetSystemClockMode(_systemClockRequested);
		_sequencer.SetDiagnosticsEnabled(false);
		ThreadSafeLog.Print($"[MeltySynthPlayer] Created sequencer with autoSynth (system clock: {(_systemClockRequested ? "ON" : "OFF")})");

		// 手动音符合成器（独立，用于低延迟响应）
		if (_useSeparateSynthForManual)
		{
			// 手动音符合成器用较少的复音数（通常不需要太多并发音符）
			var manualSettings = new SynthesizerSettings(_sampleRate)
			{
				MaximumPolyphony = Math.Max(16, max_polyphony / 4),  // 至少 16 个复音
				BlockSize = 256,
				EnableReverbAndChorus = false
			};
			_manualSynth = new Synthesizer(_soundFont, manualSettings);
			// ThreadSafeLog.Print($"[MeltySynthPlayer] Created separate synthesizers: " +
			// 		$"auto={max_polyphony} voices, manual={manualSettings.MaximumPolyphony} voices");
		}
		else
		{
			_manualSynth = _autoSynth;  // 回退：使用同一个合成器
			// ThreadSafeLog.Print("[MeltySynthPlayer] Using single synthesizer for both auto and manual notes");
		}

		// 【TMX-005】合成器重建后清理手动通道状态缓存，并重新应用乐器覆盖：
		// 纯 soundfont 重载（未重新 load_midi）时，手动音符不再退回默认音色。
		_channelStateAppliedToManual.Clear();
		ApplyInstrumentOverridesToSynth();

		// 重置状态
		_sequencerStarted = false;
		_currentOffsetMs = 0.0;
		_hasSkippedPreroolEvents = false;

		// ========== 新架构：将合成器引用传递给音频桥接器 ==========
		_audioOutput?.SetSynthesizers(_sequencer, _autoSynth, _manualSynth, _useSeparateSynthForManual);
		_audioOutput?.SetVolume(_volumeLinear);
		ThreadSafeLog.Print("[MeltySynthPlayer] Synthesizers passed to audio bridge");

		EmitSignal(SignalName.soundfont_changed, path);
		EmitSignal(SignalName.soundfont_reload_completed);
	}

	/// <summary>
	/// 装载一首 MIDI（换曲的唯一实现，前台与后台共用）。
	///
	/// 【每曲状态复位契约 —— 改这里之前先读这段】
	/// 任何"本曲"语义的状态都必须**在这里**复位，而不能只放在 <see cref="stop"/> 里。
	/// 原因：后台换曲（熄屏自动切歌）走的是 `AdvanceToNextInBackground → bridge.Stop() +
	/// LoadMidiFile(...)`，**根本不经过 stop()**。历史上这条差异连续造成过 4 个跨曲残留 bug：
	///   1. 待处理手动音符事件（设备停着不入队、下次起跑一次性补发 → 开局幽灵音）
	///   2. 独立手动合成器的 voices（不随 sequencer 重置 → 跨曲卡住的音）
	///   3. `_vocalDisabledByUser`（ApplyChartVocal 一进门就据它 UnloadVocal + return
	///      → 后台切歌后新歌**永远没有人声**）
	///   4. `_activeNotes` / `_restoreHeldNotes`（resume 只比对音源代际，而换曲不改代际
	///      → 后台切歌后暂停再续播会把旧曲的 NoteOn 重发到新曲 = 幽灵音）
	/// 故：新增"本曲"状态时，在这里加复位；只在 stop() 里加等于漏掉后台换曲。
	/// </summary>
	private void LoadMidiFile(string path, bool preferSystemIo = false)
	{
		if (string.IsNullOrEmpty(path))
		{
			ThreadSafeLog.PrintErr("[MeltySynthPlayer] LoadMidiFile: path is null or empty");
			return;
		}

		// ThreadSafeLog.Print($"[MeltySynthPlayer] LoadMidiFile: {path}");

		if (_synth == null)
		{
			// 后台异步加载进行中：不要同步阻塞主线程（会卡 3-5s 且与后台线程竞争合成器），
			// 等待 FinalizeSoundfontLoad 完成后由它/load_midi 续接载入 MIDI。
			if (!_sfFinalized && (_sfLoadThread != null || _sfParseDone))
			{
				ThreadSafeLog.Print("[MeltySynthPlayer] SoundFont async loading; deferring MIDI load to finalize");
				return;
			}
			// 如果没有设置 soundfont，使用默认的
			if (string.IsNullOrEmpty(_soundfont))
			{
				_soundfont = "res://Resources/Soundfont/GeneralUser-GS.sf2";
			}
			// 后台换曲线程也会走到这里（_synth 为 null 意味着音源从未就绪）：
			// LoadSoundfont 内部走 Godot FileAccess（引擎调用），在冻结的主线程锁上会永久阻塞，
			// 故非主线程直接放弃，交给主线程下次 load_midi/重启流程处理。
			if (!ThreadSafeLog.IsMainThread)
			{
				ThreadSafeLog.PrintErr("[MeltySynthPlayer] LoadMidiFile on worker thread but synth is null; deferring to main thread");
				return;
			}
			LoadSoundfont(_soundfont);
		}

		// 再次检查，如果还是 null 说明 soundfont 加载失败
		if (_sequencer == null)
		{
			// LoadMidiFile 也会被后台换曲线程调用（AdvanceToNextInBackground），
			// 故此处不能走 GD.PushError（引擎调用，主线程冻结时会把后台线程卡住）
			ThreadSafeLog.PrintErr($"[MeltySynthPlayer] Failed to initialize synthesizer with soundfont: {_soundfont}");
			return;
		}

		using var stream = OpenFileAsStream(path, preferSystemIo);
		_midiFile = new MidiFile(stream);
		// 换曲同样丢弃遗留的手动音符事件（后台换曲路径不经过 stop()，故这里也要清）
		if (_audioOutput is MiniaudioAudioOutputBridge maClearNotes)
		{
			maClearNotes.ClearPendingNotes();
		}
		ResetManualVoices();
		// 【每曲状态：必须在这里清，不能只在 stop() 里清】
		// _vocalDisabledByUser 表示"用户在本曲里显式关掉了人声"，而 ApplyChartVocal 一进门就
		// 据它 UnloadVocal + return —— 若它跨曲残留，新歌的人声永远加载不出来。
		// stop() 里确实清了，但**后台换曲路径不经过 stop()**（它直接停设备 + LoadMidiFile），
		// 于是"熄屏自动切歌后新歌没人声"。LoadMidiFile 是两条路径的公共必经点。
		_vocalDisabledByUser = false;
		// 同理：曲终/换曲时旧曲的"在响音符"簿记也必须清。
		_activeNotesClearedOnLoad++;   // 每曲复位发生点（主线程装载路径）pause() 会据它决定续播是否重发
		// NoteOn（_restoreHeldNotes = _activeNotes.Count > 0），而 resume() 只比对**音源代际**
		// （换曲不会改变代际）→ 后台换曲后暂停再续播，会把旧曲的 NoteOn 重发到新曲的合成器上
		// = 新歌里冒出幽灵音。stop() 与 FinalizeSoundfontLoad 都清了，唯独换曲路径漏了。
		_restoreHeldNotes = false;
		lock (_activeNotesLock)
		{
			_activeNotes.Clear();
		}
		_activeNotesClearedOnLoad++;
		ThreadSafeLog.Print("[MeltySynthPlayer] per-song state reset on load (active notes cleared)");
		_sequencerStarted = false;  // 重置标志，等待 play() 调用
		_currentOffsetMs = 0.0;  // 重置 offset
		_hasSkippedPreroolEvents = false;  // 重置跳过标志
		_lastPositionMs = 0.0;  // 清除上一首 MIDI 的位置残留
		// 换曲重置回绕基准：否则新曲起始位置相对旧曲回绕点大幅后退，
		// 会被音频回调误判为"又回绕了一次"，导致连续切歌
		if (_audioOutput is MiniaudioAudioOutputBridge maNewSong)
		{
			maNewSong.ResetEndOfSequence();
		}
		
		// 清理旧的乐器覆盖配置，防止状态在不同 MIDI 之间错误延续
		_trackChannelInstruments.Clear();
		_virtualChannelInstruments.Clear();
		// 清理虚拟通道的音量/CC/音色等状态，防止旧歌配置残留到新歌
		_virtualChannelVolumes.Clear();
		_virtualChannelCurrentBank.Clear();
		_virtualChannelCurrentProgram.Clear();
		_virtualChannelCc7.Clear();
		_virtualChannelCc11.Clear();
		_virtualChannelCc10.Clear();
		_virtualChannelPitchBend.Clear();
		_channelStateAppliedToManual.Clear();
		// 清理手动控制音符过滤器，防止上一首歌的 manual control 标记残留到新歌
		// PlayView._finish_generate_game_sequences 会根据 play_mode 重新下发
		_manualFilterRegistry.Filters = new Dictionary<long, ManualFilterState>();
		// ThreadSafeLog.Print($"[MeltySynthPlayer] MIDI file loaded, cleared instrument overrides, _sequencerStarted reset to false");
		// 注意：不在这里调用 Play()，而是等待明确的 play() 调用
		// 这样可以与 MidiPlayer (Addon) 的行为保持一致
		// _sequencer.Play(_midiFile, false);  // 移除自动播放

		// 音源就绪前已请求播放：MIDI 现已载入，补启动。
		// 仅当 finalize 已完成（音频桥已在 FinalizeSoundfontLoad 绑定合成器）后才触发，
		// 否则（同在 finalize 内、SetSynthesizers 之前）交由 finalize 末尾统一续播。
		if (_pendingPlayAfterLoad && _sequencer != null && _sfFinalized)
		{
			_pendingPlayAfterLoad = false;
			play();
			// 见 FinalizeSoundfontLoad 里的说明：推迟的续播真正开始时必须广播，
			// 否则等待方（TrackView 的音符显示）永远等不到。
			EmitSignal(SignalName.deferred_play_resumed);
		}
	}

	private void LegacySeekByFastForward(double targetMs)
	{
		if (_sequencer == null || _midiFile == null || _synth == null)
		{
			return;
		}

		if (targetMs < 0.0)
		{
			targetMs = 0.0;
		}

		var targetSeconds = targetMs / 1000.0;
		var targetFrames = (long)(_sampleRate * targetSeconds);

		_sequencer.Play(_midiFile, false);
		_sequencerStarted = true;
		ApplyInstrumentOverridesToSynth();

		var scratchLeft = new float[_synth.BlockSize];
		var scratchRight = new float[_synth.BlockSize];
		long remaining = targetFrames;

		while (remaining > 0)
		{
			var block = (int)Math.Min(remaining, _synth.BlockSize);
			_sequencer.Render(scratchLeft.AsSpan(0, block), scratchRight.AsSpan(0, block));
			remaining -= block;
		}
	}

	/// <summary>
	/// 将 _virtualChannelInstruments 中所有存储的乐器覆盖刷入 _synth。
	/// 必须在每次 _sequencer.Play() 之后调用，确保没有 Program Change 事件的通道也能正确更换音色。
	///
	/// 【自带锁】本方法写的是与音频回调共享的合成器通道状态，而它的调用点分散（前台 play/seek、
	/// 后台换曲、音源重载 finalize……），逐个核对调用点是否在锁内太脆弱 —— 这里自己加，
	/// 锁可重入，故已被外层 WithSynthLock 包住的调用点不受影响。
	/// </summary>
	/// <summary>
	/// 清掉**独立手动合成器**上残留的 voices。
	///
	/// 为什么需要：换曲/停止时 `_sequencer.Play/Reset` 只重置**自动**合成器，独立手动合成器
	/// （`_useSeparateSynthForManual` 默认开启）不会被它碰到。玩家按着长音时曲终、或在曲终后
	/// 的等待期里点过屏幕，那个 voice 就一直留在手动合成器里，下一首起跑时被渲染出来 ——
	/// 表现为跨曲"卡住的音"。
	///
	/// 只在确实是独立合成器时动它：共用 `_synth` 时 `Reset`/`NoteOffAll` 会连自动播放一起打断。
	/// </summary>



	/// <summary>
	/// 把已加载的人声按**当前 MIDI 渲染位置**重新定位（丢弃待播帧）。
	/// 用于音频设备停顿 / 路由切换之后：那时 MIDI 位置停了、人声的位置记账却追平了，
	/// 于是『位置一致但内容落后』，按位置判定的漂移同步发现不了，只能靠一次重定位对齐
	/// （真机现象：切蓝牙后 MIDI 比人声快，seek 一下即恢复正常）。
	/// </summary>
	public void RealignVocalToMidiPosition()
	{
		if (!(_audioOutput is MiniaudioAudioOutputBridge ma) || !ma.IsVocalLoaded)
		{
			return;
		}
		double posMs = _sequencer != null ? _sequencer.RenderedPosition.TotalMilliseconds : 0.0;
		SeekVocalToMidi(posMs);
	}
	private void ResetManualVoices()
	{
		if (!_useSeparateSynthForManual || _manualSynth == null || _manualSynth == _synth)
		{
			return;
		}
		WithSynthLock(() => _manualSynth.NoteOffAll(true));
	}

	/// <summary>[诊断/回归] 独立手动合成器当前活跃 voice 数（0 表示没有残留）。</summary>

	/// <summary>[诊断/回归] LoadMidiFile 里清空"在响音符"簿记的次数（换曲路径必须走到）。</summary>
	private long _activeNotesClearedOnLoad = 0;



	private void ApplyInstrumentOverridesToSynth()
	{
		if (_synth == null) return;
		WithSynthLock(() =>
		{
			foreach (var kvp in _virtualChannelInstruments)
			{
				_synth.ProcessMidiMessage(kvp.Key, 0xB0, 0x00, kvp.Value.bank);
				_synth.ProcessMidiMessage(kvp.Key, 0xC0, kvp.Value.program, 0);
				// 独立手动合成器同样应用覆盖，保证纯 soundfont 重载后手动音符音色正确
				if (_manualSynth != null && _manualSynth != _synth)
				{
					_manualSynth.ProcessMidiMessage(kvp.Key, 0xB0, 0x00, kvp.Value.bank);
					_manualSynth.ProcessMidiMessage(kvp.Key, 0xC0, kvp.Value.program, 0);
				}
			}
		});
	}

	private void OnSendMessage(Synthesizer synthesizer, int virtualChannel, int command, int data1, int data2, int tick)
	{
		// 维护当前在响音符集合（供暂停记录 / 续播重发）。音频线程写入，主线程 pause/resume 读取，需加锁。
		if (command == 0x90 && data2 > 0)
		{
			lock (_activeNotesLock)
			{
				_activeNotes[(virtualChannel, data1)] = data2;
			}
		}
		else if (command == 0x80 || (command == 0x90 && data2 == 0))
		{
			lock (_activeNotesLock)
			{
				_activeNotes.Remove((virtualChannel, data1));
			}
		}

		var handlers = _handlers;  // volatile 快照：与主线程重建管道互不干扰
		foreach (var handler in handlers)
		{
			if (!handler.Process(synthesizer, virtualChannel, ref command, ref data1, ref data2, tick))
				return;
		}
	}

	private void ApplyChannelStateToManualSynth(int virtualChannel)
	{
		if (_manualSynth == null)
		{
			return;
		}

		// 如果该通道状态已经应用过，跳过（大幅减少每次触发音符的MIDI消息开销）
		if (_channelStateAppliedToManual.ContainsKey(virtualChannel))
		{
			return;
		}

		// 本方法从 trigger_note_on（主线程、打歌输入路径）调用，而音频回调正在同一手动合成器上
		// Render voices：ProcessMidiMessage 会改通道状态，必须与回调互斥，否则是"数组越界"那类崩溃。
		// 缓存命中时上面已提前返回，故这里的锁只在"某通道首次触发"时付出，不进热路径。
		WithSynthLock(() =>
		{
			// TrackView 的显式覆盖必须优先于 MIDI 事件镜像状态。
			// 自动序列器收到原始 Bank/Program 事件时，ChannelStateMirrorHandler
			// 会先更新 current 状态，再由 InstrumentOverrideHandler 修改实际输出；
			// 若这里优先读取 current，演奏模式的独立手动合成器就会恢复为原始音色。
			if (_virtualChannelInstruments.TryGetValue(virtualChannel, out var overrideInstrument))
			{
				_manualSynth.ProcessMidiMessage(virtualChannel, 0xB0, 0x00, overrideInstrument.bank);
				_manualSynth.ProcessMidiMessage(virtualChannel, 0xC0, overrideInstrument.program, 0);
			}
			else
			{
				if (_virtualChannelCurrentBank.TryGetValue(virtualChannel, out var bank))
				{
					_manualSynth.ProcessMidiMessage(virtualChannel, 0xB0, 0x00, bank);
				}

				if (_virtualChannelCurrentProgram.TryGetValue(virtualChannel, out var program))
				{
					_manualSynth.ProcessMidiMessage(virtualChannel, 0xC0, program, 0);
				}
			}

			if (_virtualChannelCc7.TryGetValue(virtualChannel, out var cc7))
			{
				_manualSynth.ProcessMidiMessage(virtualChannel, 0xB0, 0x07, cc7);
			}
			if (_virtualChannelCc11.TryGetValue(virtualChannel, out var cc11))
			{
				_manualSynth.ProcessMidiMessage(virtualChannel, 0xB0, 0x0B, cc11);
			}
			if (_virtualChannelCc10.TryGetValue(virtualChannel, out var cc10))
			{
				_manualSynth.ProcessMidiMessage(virtualChannel, 0xB0, 0x0A, cc10);
			}
			if (_virtualChannelPitchBend.TryGetValue(virtualChannel, out var pitchBend14))
			{
				var lsb = pitchBend14 & 0x7F;
				var msb = (pitchBend14 >> 7) & 0x7F;
				_manualSynth.ProcessMidiMessage(virtualChannel, 0xE0, lsb, msb);
			}
		});

		// 标记通道状态已应用
		_channelStateAppliedToManual.TryAdd(virtualChannel, 0);
	}
}
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
	public bool loop = false;
	private float _volume_db = -20.0f;
	private string _soundfont = "";
	private string _file = "";
	public bool playing = false;
	private StringName _bus = new StringName("Master");

	public Godot.Collections.Dictionary track_channel_instruments = new Godot.Collections.Dictionary();

	private IAudioOutputBridge _audioOutput;

	private Synthesizer _synth;
	private MidiFileSequencer _sequencer;
	private MidiFile _midiFile;
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

	// ============ 选项 A：独立合成器用于低延迟手动音符 ============
	private Synthesizer _manualSynth;      // 专用于手动触发的音符
	private Synthesizer _autoSynth;        // 原有：用于MIDI自动播放（就是 _synth）
	private bool _useSeparateSynthForManual = true;  // 启用独立合成器
	private bool _preferNativeSequencerSeek = true;

	// 系统时钟模式请求状态（配置来源 Playback/use_system_stopwatch）。
	// sequencer 在 soundfont / 采样率重建时会重新创建，创建点按本字段恢复模式，避免被静默重置为关闭。
	private bool _systemClockRequested = false;

	// 用户配置的音频缓冲区大小（帧），对齐到2的幂
	private int _desiredBufferFrames = 1024;  // 默认1024帧，与稳定工作的旧版本一致

	// 跟踪已应用通道状态到手动合成器的虚拟通道，避免每次触发音符重复设置
	private readonly ConcurrentDictionary<int, byte> _channelStateAppliedToManual = new ConcurrentDictionary<int, byte>();

	// ============ OnSendMessage 拦截器管道 ============
	private MessageHandlerContext _messageContext;
	// 管道只构建一次，但用 volatile 引用交换保证音频线程迭代的是一致快照
	private volatile IReadOnlyList<IMidiMessageHandler> _handlers = Array.Empty<IMidiMessageHandler>();

	private void RequestAudioOutputPlay()
	{
		if (_audioOutput == null) return;
		if (!_audioOutput.IsPlaying)
			_audioOutput.Play();
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
			GD.Print($"[MeltySynthPlayer] miniaudio: adjusting sample rate {_sampleRate} → {targetRate} " +
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
			GD.Print($"[MeltySynthPlayer] Sample rate changed {oldSampleRate}→{_sampleRate}, rebuilding synthesizers");
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
			GD.PrintErr("[MeltySynthPlayer] Failed to initialize audio bridge. MIDI playback will be silent.");
			return;
		}

		// 【方向 1】设备已按原生采样率初始化：回读实际率，并与合成器/序列器对齐。
		if (useDeviceNativeRate && bridge is MiniaudioAudioOutputBridge maBridge && maBridge.ActualSampleRate > 0 && maBridge.ActualSampleRate != (uint)_sampleRate)
		{
			GD.Print($"[MeltySynthPlayer] Device native sample rate: {maBridge.ActualSampleRate}Hz (synth was {_sampleRate}Hz), rebuilding synthesizers");
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
		GD.Print("[MeltySynthPlayer] Audio bridge initialized with synthesizers preset");
	}

	private IAudioOutputBridge CreateAudioOutputBridge(bool useDeviceNativeRate)
	{
		// 使用 miniaudio 后端: 优先低延迟, RingBuffer 容量 ×3
		var maBridge = new MiniaudioAudioOutputBridge(0);

		var osName = OS.GetName();
		uint maPeriod;

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
			// 注意: Windows 下 period 固定为 256/128（共享/独占），有意忽略
			// set_audio_buffer_frames(_desiredBufferFrames)：共享模式 WASAPI 对
			// 更小 period 支持不稳定，且当前无任何 UI 暴露该设置（TMX-041 结论）。
			maPeriod = useExclusive ? 128u : 256u;
		}
		else if (osName == "Android")
		{
			maBridge.SetBackend(MiniaudioNative.Backend.Aaudio);
			maBridge.SetAAudioExclusive(true);
			maPeriod = (uint)Math.Min(_desiredBufferFrames, 256);
		}
		else
		{
			maPeriod = (uint)Math.Min(_desiredBufferFrames, 256);
		}

		if (useDeviceNativeRate)
		{
			maBridge.UseDeviceNativeSampleRate(true);
		}

		// _decodeFrames 初始设为 period, Initialize 后会根据 actualPeriod 上调
		maBridge.SetDecodeFrames((int)maPeriod);
		maBridge.SetPeriodSize(maPeriod, 2);

		GD.Print($"[MeltySynthPlayer] Creating miniaudio bridge: decode={maPeriod}f, period=({maPeriod},2), os={osName}, exclusive={(osName == "Windows" ? (System.Environment.GetEnvironmentVariable("MINIAUDIO_EXCLUSIVE") == "1" ? "yes" : "no") : "n/a")}");
		return maBridge;
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
		if (_desiredBufferFrames == aligned)
		{
			GD.Print($"[MeltySynthPlayer] Audio buffer frames already set to {aligned}, skipping reinitialization");
			return;
		}
		
		_desiredBufferFrames = aligned;
		GD.Print($"[MeltySynthPlayer] Audio buffer frames: requested={frames}, aligned={aligned}");

		// 重新创建音频桥以应用新的缓冲区大小
		if (_audioOutput != null)
		{
			GD.Print($"[MeltySynthPlayer] Recreating audio bridge with new buffer size: {aligned} frames");
			
			// 保存当前播放状态
			bool wasPlaying = _audioOutput.IsPlaying;
			
			// 【关键修复】先销毁旧音频桥，停止其音频回调
			// 否则旧桥的 PCM 回调仍在音频线程运行，与新桥共享_sequencer
			// 两个桥各自有独立的 _synthLock，无法保护共享合成器，导致竞态条件
			_audioOutput.Dispose();
			_audioOutput = null;
			
			// 重新初始化音频桥（会使用新的 _desiredBufferFrames）
			EnsureAudioInitialized();
			
			// 恢复合成器引用
			if (_sequencer != null && _autoSynth != null)
			{
				_audioOutput.SetSynthesizers(_sequencer, _autoSynth, _manualSynth, _useSeparateSynthForManual);
				_audioOutput.SetVolume(_volumeLinear);
				GD.Print("[MeltySynthPlayer] Synthesizers restored after audio bridge recreation");
			}
			
			// 如果之前在播放，恢复播放
			if (wasPlaying && _audioOutput != null)
			{
				_audioOutput.Play();
				GD.Print("[MeltySynthPlayer] Playback resumed after audio bridge recreation");
			}
		}
		else
		{
			GD.Print($"[MeltySynthPlayer] Audio bridge not yet created, new buffer size will be applied on next initialization");
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
			GD.Print("[MeltySynthPlayer] recreate_audio_output skipped: WASAPI exclusive mode enabled");
			return;
		}
		// 尚未初始化则无需重建：下次初始化自然使用新的默认设备
		if (_audioOutput == null)
		{
			GD.Print("[MeltySynthPlayer] recreate_audio_output: no audio output yet, nothing to rebuild");
			return;
		}

		GD.Print("[MeltySynthPlayer] Recreating audio output device to follow system default endpoint");
		bool wasPlaying = _audioOutput.IsPlaying;

		// 先销毁旧音频桥，停止其音频回调（与 set_audio_buffer_frames 相同的竞态防护）
		_audioOutput.Dispose();
		_audioOutput = null;

		// 重新初始化（使用当前系统默认设备；内部已含合成器重绑）
		EnsureAudioInitialized();

		// 恢复合成器引用（EnsureAudioInitialized 已重绑，此处冗余加固保持与既有路径一致）
		if (_audioOutput != null && _sequencer != null && _autoSynth != null)
		{
			_audioOutput.SetSynthesizers(_sequencer, _autoSynth, _manualSynth, _useSeparateSynthForManual);
			_audioOutput.SetVolume(_volumeLinear);
		}

		// 如果之前在播放，恢复播放
		if (wasPlaying && _audioOutput != null)
		{
			_audioOutput.Play();
			GD.Print("[MeltySynthPlayer] Playback resumed after audio output recreation");
		}
	}

	/// <summary>
	/// 中断恢复：音频被系统打断（如来电/切后台）后，安卓 AAudio 被系统夺走音频焦点，
	/// 仅 ma_device_stop/start 无法重新申请到会话，必须整桥销毁重建才能恢复声音。
	/// 重建会保留 sequencer 位置与合成器音源，但原生人声解码器会丢失（由 MidiPlaybackManager 重新加载）。
	/// </summary>
	public void recover_audio_output()
	{
		GD.Print("[MeltySynthPlayer] Recreating audio output bridge for interruption recovery");
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
			result["extrapolation_ms"] = maBridge.GetExtrapolationMs();
		}
		return result;
	}

	public override void _Ready()
	{
		GD.Print("[MeltySynthPlayer] _Ready() called");
		EnsureAudioInitialized();
		GD.Print($"[MeltySynthPlayer] _Ready() complete: _audioOutput={( _audioOutput != null ? _audioOutput.GetType().Name : "null" )}");

		SetProcess(true);
	}

	public override void _Process(double delta)
	{
		_audioOutput?.Update();

		if (_audioOutput is MiniaudioAudioOutputBridge maBridge && maBridge.IsVocalFinished())
		{
			if (!_vocalFinishedSignaled)
			{
				_vocalFinishedSignaled = true;
				EmitSignal(SignalName.vocal_finished);
			}
		}

		// 【关键】处理待处理的 seek 操作优先级最高，即使不在播放中也要处理
		if (!double.IsNaN(_pendingSeekMs))
		{
			// GD.Print($"[MeltySynthPlayer] Processing seek to {_pendingSeekMs} ms (playing={playing})");
			
			if (_sequencer == null || _midiFile == null)
			{
				GD.PrintErr("[MeltySynthPlayer] Cannot seek: sequencer or midiFile is null");
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
						// GD.Print($"[MeltySynthPlayer] Stopped sequencer for pre-roll mode");
					}
				});
				
			// GD.Print($"[MeltySynthPlayer] Pre-roll mode: offset set to {_currentOffsetMs} ms");
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
					_sequencer.Play(_midiFile, loop);
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
						GD.PrintErr($"[MeltySynthPlayer] Native sequencer seek failed, fallback to legacy seek: {ex.Message}");
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

			// 3. 如果之前在播放，重新启动 AudioStreamPlayer（锁外，ma_bridge_start 不等待回调）
			if (playing)
			{
				RequestAudioOutputPlay();
			}
			
			// 5. 清除待处理标志
			_pendingSeekMs = double.NaN;
			
			// GD.Print("[MeltySynthPlayer] Seek completed");
			
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
						// GD.Print($"[MeltySynthPlayer] Crossing zero from pre-roll, starting sequencer at position 0");
						_sequencer.Play(_midiFile, loop);
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

		// 【修复D-5】自然播放结束检测（非循环模式）：
		// Sequencer 处理完全部事件后 EndOfSequence 为 true（循环模式恒为 false），
		// 此时停止播放并发出 finished 信号，驱动 GDScript 侧 midi_finished → 游戏结算。
		// 此前 finished 信号从未 emit，PlayView 只能依赖"位置停滞"启发式兜底。
		if (playing && !loop && _sequencerStarted && _sequencer != null && _midiFile != null && _sequencer.EndOfSequence)
		{
			FinishPlayback();
			return;
		}

		if (!playing || _sequencer == null || _audioOutput == null)
		{
			return;
		}

		// 直接在回调中合成，主循环只需要确保播放已启动
		RequestAudioOutputPlay();
	}

	public override void _ExitTree()
	{
		GD.Print("[MeltySynthPlayer] _ExitTree() called, disposing audio resources");
		if (_audioOutput != null)
		{
			_audioOutput.Dispose();
			_audioOutput = null;
		}
		_sequencer = null;
		_synth = null;
		_autoSynth = null;
		_manualSynth = null;
		_soundFont = null;
		_midiFile = null;
	}

	public void play()
	{
		EnsureAudioInitialized();
		GD.Print($"[MeltySynthPlayer] play() called - _midiFile={_midiFile != null}, _sequencerStarted={_sequencerStarted}, _audioOutput={( _audioOutput != null ? "OK" : "NULL" )}, _synth={(_synth != null ? "OK" : "NULL")}, _autoSynth={(_autoSynth != null ? "OK" : "NULL")}");
		if (_sequencer == null)
		{
			GD.PrintErr("[MeltySynthPlayer] Cannot play: sequencer is null");
			return;
		}

		// 判定钟锚点作废：下次读取按当前音频参考重建
		InvalidateJudgeClock();

		// GD.Print($"[MeltySynthPlayer] play() called - _midiFile: {_midiFile != null}, _sequencerStarted: {_sequencerStarted}, _currentOffsetMs: {_currentOffsetMs}, _audioOutput.IsPlaying: {_audioOutput?.IsPlaying}");

		// 【处理 pre-roll 模式】如果当前有负数 offset，不启动 sequencer，让 _Process 处理跨越零点
		if (_currentOffsetMs < 0.0)
		{
			// GD.Print($"[MeltySynthPlayer] In pre-roll mode (offset={_currentOffsetMs} ms), sequencer will start when crossing zero");
			playing = true;
			return;
		}

		// 如果 MIDI 已加载但还未启动 sequencer，则启动它（与回调渲染互斥）
		if (_midiFile != null && !_sequencerStarted)
		{
			// GD.Print($"[MeltySynthPlayer] Starting sequencer with MIDI file, loop={loop}");
			WithSynthLock(() =>
			{
				_sequencer.Play(_midiFile, loop);
				_sequencerStarted = true;
				ApplyInstrumentOverridesToSynth();
			});
		}
		else if (_midiFile == null)
		{
			GD.PrintErr("[MeltySynthPlayer] Cannot play: no MIDI file loaded");
			return;
		}
		else if (_sequencerStarted)
		{
			// GD.Print("[MeltySynthPlayer] Sequencer already started, resuming playback");
		}
		
		playing = true;
		RequestAudioOutputPlay();
	}

	public void stop()
	{
		playing = false;
		// ma_bridge_stop 会等待回调完成，必须在锁外调用
		_audioOutput?.Stop();
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

		// 通知 GDScript 侧（MidiPlaybackManager._on_midi_finished → midi_finished）
		EmitSignal(SignalName.finished);
	}

	public void seek_ms(double positionMs)
	{
		if (_midiFile == null || _sequencer == null)
		{
			return;
		}

		// 【修复】允许负数 seek，设置待处理的 seek 标志
		// _Process 会在下一帧处理这个 seek，确保不会阻塞音频线程
		_pendingSeekMs = positionMs;  // 负数值会被接受

		// GD.Print($"[MeltySynthPlayer] Queued seek to {positionMs} ms");
	}

	public void set_soundfont(string soundfontPath)
	{
		EnsureAudioInitialized();
		_soundfont = soundfontPath;
		LoadSoundfont(soundfontPath);
		// 注意：LoadSoundfont 创建新的 _sequencer，需要重新加载 MIDI 文件
		if (!string.IsNullOrEmpty(_file))
		{
			// GD.Print($"[MeltySynthPlayer] Reloading MIDI after soundfont change: {_file}");
			LoadMidiFile(_file);
		}
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
		return _audioOutput.LoadVocalFile(path);
	}

	public void unload_vocal()
	{
		_vocalFinishedSignaled = false;
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
		_audioOutput?.SetVocalVolume((float)volumeLinear);
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

	public void set_loop(bool enabled)
	{
		loop = enabled;
		// GD.Print($"[MeltySynthPlayer] Loop set to: {enabled}");
	}

	public void set_max_polyphony(int value)
	{
		max_polyphony = Math.Max(16, Math.Min(256, value));
		GD.Print($"[MeltySynthPlayer] Max polyphony set to: {max_polyphony}");
		
		// 注意：Synthesizer.MaximumPolyphony 是只读属性，只能在创建时设置
		// 新设置将在下一次加载 SoundFont 时生效
	}

	public bool get_loop()
	{
		return loop;
	}
	
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
			ReanchorJudgeClock(audioRefMs);
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
		GD.Print($"[MeltySynthPlayer] System clock mode: {(enabled ? "ON" : "OFF")}");
	}

	public bool get_use_system_stopwatch()
	{
		return _sequencer != null && _sequencer.UseSystemClock;
	}

	public void set_track_channel_instrument(int trackIndex, int channel, int bank, int program)
	{
		if (!track_channel_instruments.ContainsKey(trackIndex))
		{
			track_channel_instruments[trackIndex] = new Godot.Collections.Dictionary();
		}

		var trackDict = (Godot.Collections.Dictionary)track_channel_instruments[trackIndex];
		trackDict[channel] = new Godot.Collections.Dictionary
		{
			{ "bank", bank },
			{ "program", program }
		};

		var virtualId = trackIndex * 16 + channel;
		_virtualChannelInstruments[virtualId] = (bank, program);
		_virtualChannelCurrentBank[virtualId] = bank;
		_virtualChannelCurrentProgram[virtualId] = program;

		// 【修复】立即写入合成器，使用两种方式确保改变立即生效：
		// 1. 直接通过 ProcessMidiMessage（标准 MIDI 方式）
		// 2. 如果通道已存在，直接修改通道对象（确保对正在播放的音符也有效）
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
					// GD.Print($"[MeltySynthPlayer] [RUNTIME] Set instrument for virtual channel {virtualId} (Track {trackIndex}, Channel {physicalChannel}): Bank {bank}, Program {program}");
				}
				catch (Exception ex)
				{
					GD.PrintErr($"[MeltySynthPlayer] Error accessing channel info: {ex.Message}");
				}
			}
		}

		if (_manualSynth != null)
		{
			_manualSynth.ProcessMidiMessage(virtualId, 0xB0, 0x00, bank);
			_manualSynth.ProcessMidiMessage(virtualId, 0xC0, program, 0);
		}

		// 通道状态变化，清除缓存以强制下次触发时重新应用
		_channelStateAppliedToManual.TryRemove(virtualId, out _);
	}

	public Godot.Collections.Dictionary get_track_channel_instrument(int trackIndex, int channel)
	{
		if (track_channel_instruments.ContainsKey(trackIndex))
		{
			var trackDict = (Godot.Collections.Dictionary)track_channel_instruments[trackIndex];
			if (trackDict.ContainsKey(channel))
			{
				return (Godot.Collections.Dictionary)trackDict[channel];
			}
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
			GD.PrintErr("[MeltySynthPlayer] set_manually_controlled_notes ignored while playing (snapshot rebuild not allowed)");
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
			GD.Print($"[TapDiag] trigger_note_on#{_diag_trigger_count} pitch={pitch} vel={scaledVelocity} ch={virtualId} elapsed={diagSw.Elapsed.TotalMilliseconds:F3}ms");
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
				_manualSynth.ProcessMidiMessage(virtualId, 0xB0, 0x00, bank);
				_manualSynth.ProcessMidiMessage(virtualId, 0xC0, program, 0);
				_manualSynth.NoteOn(virtualId, 60, 1);
				_manualSynth.NoteOff(virtualId, 60);
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
		_synth?.ProcessMidiMessage(channel, 0xB0, 0x7B, 0);
	}

	private void stop_channel_notes_manual(int channel)
	{
		_manualSynth?.ProcessMidiMessage(channel, 0xB0, 0x7B, 0);
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
	
	/// <summary>加载 MIDI 文件 (接口别名)</summary>
	public bool load_midi(string filePath)
	{
		try
		{
			set_file(filePath);
			return _midiFile != null;
		}
		catch (Exception ex)
		{
			GD.PrintErr($"[MeltySynthPlayer] Failed to load MIDI: {ex.Message}");
			return false;
		}
	}

	/// <summary>暂停播放 (接口方法)</summary>
	public void pause()
	{
		InvalidateJudgeClock();  // 恢复时按暂停后的音频参考重建锚点
		playing = false;
		if (_sequencer != null)
		{
			// 线程模型：系统时钟模式下音频线程在 GetSystemClockPosition 中读取
			// isPaused/clockBasePosition/clockBaseTimestamp，Pause 写这些字段必须与回调渲染互斥。
			WithSynthLock(() => _sequencer.Pause());
		}
		// GD.Print($"[MeltySynthPlayer] pause() called - _currentOffsetMs={_currentOffsetMs}, _sequencerStarted={_sequencerStarted}");
		// 保持 sequencer 状态，不重置位置
	}

	/// <summary>恢复播放 (接口方法)</summary>
	public void resume()
	{
		InvalidateJudgeClock();  // 按 resume 后的音频参考重建锚点
		if (_midiFile != null && _sequencer != null)
		{
			// 线程模型：同 pause()，Resume 重设墙钟锚点，必须与回调渲染互斥
			WithSynthLock(() => _sequencer.Resume());

			// 【处理 pre-roll 模式】如果在 pre-roll 中，继续等待跨越零点
			if (_currentOffsetMs < 0.0)
			{
				// GD.Print($"[MeltySynthPlayer] Resume from pre-roll (offset={_currentOffsetMs} ms)");
				playing = true;
				return;  // 不启动 AudioStreamPlayer，等待跨越零点
			}

			playing = true;
			_audioOutput?.Play();
		}
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
	private MemoryStream OpenFileAsStream(string path)
	{
		// res:// 路径在 Android 上嵌入 APK/PCK 中，必须通过 Godot FileAccess 读取
		// user:// 和绝对路径可以通过 System.IO 访问，但为统一起见全部用 Godot API
		var file = Godot.FileAccess.Open(path, Godot.FileAccess.ModeFlags.Read);
		if (file == null)
		{
			var error = Godot.FileAccess.GetOpenError();
			GD.PrintErr($"[MeltySynthPlayer] Failed to open file via Godot FileAccess: {path} (error: {error})");
			
			// 回退：尝试 System.IO（仅对非 res:// 路径有效）
			if (!path.StartsWith("res://") && !path.StartsWith("user://"))
			{
				// GD.Print($"[MeltySynthPlayer] Falling back to System.IO for path: {path}");
				return new MemoryStream(System.IO.File.ReadAllBytes(path));
			}
			throw new FileNotFoundException($"Cannot open file: {path} (Godot error: {error})");
		}
		
		var length = (long)file.GetLength();
		var bytes = file.GetBuffer(length);
		file.Close();
		// GD.Print($"[MeltySynthPlayer] Loaded {length} bytes from: {path}");
		return new MemoryStream(bytes);
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
		GD.Print($"[MeltySynthPlayer] Created autoSynth: sampleRate={settings.SampleRate}, polyphony={settings.MaximumPolyphony}");

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
		GD.Print($"[MeltySynthPlayer] Created sequencer with autoSynth (system clock: {(_systemClockRequested ? "ON" : "OFF")})");

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
			// GD.Print($"[MeltySynthPlayer] Created separate synthesizers: " +
			// 		$"auto={max_polyphony} voices, manual={manualSettings.MaximumPolyphony} voices");
		}
		else
		{
			_manualSynth = _autoSynth;  // 回退：使用同一个合成器
			// GD.Print("[MeltySynthPlayer] Using single synthesizer for both auto and manual notes");
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
		GD.Print("[MeltySynthPlayer] Synthesizers passed to audio bridge");

		EmitSignal(SignalName.soundfont_changed, path);
	}

	private void LoadMidiFile(string path)
	{
		if (string.IsNullOrEmpty(path))
		{
			GD.PrintErr("[MeltySynthPlayer] LoadMidiFile: path is null or empty");
			return;
		}

		// GD.Print($"[MeltySynthPlayer] LoadMidiFile: {path}");

		if (_synth == null)
		{
			// 如果没有设置 soundfont，使用默认的
			if (string.IsNullOrEmpty(_soundfont))
			{
				_soundfont = "res://Resources/Soundfont/GeneralUser-GS.sf2";
			}
			LoadSoundfont(_soundfont);
		}

		// 再次检查，如果还是 null 说明 soundfont 加载失败
		if (_sequencer == null)
		{
			GD.PushError($"[MeltySynthPlayer] Failed to initialize synthesizer with soundfont: {_soundfont}");
			return;
		}

		using var stream = OpenFileAsStream(path);
		_midiFile = new MidiFile(stream);
		_sequencerStarted = false;  // 重置标志，等待 play() 调用
		_currentOffsetMs = 0.0;  // 重置 offset
		_hasSkippedPreroolEvents = false;  // 重置跳过标志
		_lastPositionMs = 0.0;  // 清除上一首 MIDI 的位置残留
		
		// 清理旧的乐器覆盖配置，防止状态在不同 MIDI 之间错误延续
		track_channel_instruments.Clear();
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
		// GD.Print($"[MeltySynthPlayer] MIDI file loaded, cleared instrument overrides, _sequencerStarted reset to false");
		// 注意：不在这里调用 Play()，而是等待明确的 play() 调用
		// 这样可以与 MidiPlayer (Addon) 的行为保持一致
		// _sequencer.Play(_midiFile, loop);  // 移除自动播放
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

		_sequencer.Play(_midiFile, loop);
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
	/// </summary>
	private void ApplyInstrumentOverridesToSynth()
	{
		if (_synth == null) return;
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
	}

	private void OnSendMessage(Synthesizer synthesizer, int virtualChannel, int command, int data1, int data2, int tick)
	{
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

		// 标记通道状态已应用
		_channelStateAppliedToManual.TryAdd(virtualChannel, 0);
	}
}

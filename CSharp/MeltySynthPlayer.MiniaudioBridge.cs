using Godot;
using MeltySynth;
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using TouhouMix.Midi;

// 此文件是 MeltySynthPlayer 的 partial 实现 (全局命名空间, 与 MeltySynthPlayer.cs 一致)
// 包含 miniaudio 音频输出后端 (低延迟, 跨平台一致)
// 注意: 必须与 MeltySynthPlayer.cs 同命名空间才能合并为同一个 partial class
public partial class MeltySynthPlayer
{
	/// <summary>
	/// miniaudio 音频输出桥
	/// 架构: 直接渲染模式 + RingBuffer (备选) + 双合成器
	///
	/// 关键延迟优化:
	///   1. 直接渲染模式: 回调中直接合成, 无 RingBuffer 中间层, 延迟 = 设备延迟
	///   2. 默认 periodSize=256, periodCount=2 (256×2 ≈ 5.3ms 平均延迟)
	///   3. miniaudio 回调直接提供 pOutput 缓冲区
	///   4. 可选 WASAPI exclusive 模式, 绕开 Windows 音频引擎 ~10ms 延迟
	/// </summary>
	internal sealed class MiniaudioAudioOutputBridge : IAudioOutputBridge
	{
		// ---- 缓冲区限制 ----
		private const int MIN_DECODE_FRAMES = 128;
			private const int MAX_DECODE_FRAMES = 4096;

			// ---- miniaudio 句柄 ----
			private IntPtr _bridgeHandle = IntPtr.Zero;
			private MiniaudioNative.DataProc _dataCallback;
			// GCHandle 用于将 this 指针传给 native 回调, 避免 delegate 被 GC
			private GCHandle _selfHandle;
			// 设备枚举回调委托 (必须存储防 GC)
			private MiniaudioNative.DeviceEnumProc _deviceEnumCallback;

			// ---- 合成器引用 ----
			private MidiFileSequencer _sequencer = null;
			private Synthesizer _autoSynth = null;
			private Synthesizer _manualSynth = null;
			private bool _useSeparateSynth = false;

			// ---- 渲染缓冲区 (交错格式) ----
			private float[] _tempLeft = Array.Empty<float>();
			private float[] _tempRight = Array.Empty<float>();
			private float[] _manualLeft = Array.Empty<float>();
			private float[] _manualRight = Array.Empty<float>();
			private float[] _outputBuffer = Array.Empty<float>();

			// ---- 配置 ----
			private int _sampleRate = 48000;
			private int _decodeFrames = 0;
			private int _targetDecodeFrames = 256;  // 默认低延迟
			private float _volumeLinear = 1.0f;
			private const float OUTPUT_GAIN = 2.0f;

			// miniaudio period 配置
			private uint _periodSizeInFrames = 256;
			private uint _periodCount = 2;
			private MiniaudioNative.Backend _backend = MiniaudioNative.Backend.Default;
			private bool _wasapiExclusive = false;
			private bool _aaudioExclusive = false;
			private bool _useDeviceNativeSampleRate = false;  // 方向 1: sampleRate=0 请求设备原生率

			private bool _initialized = false;
			// 【跨线程】主线程 Play/Stop 写，后台换曲线程经 IsPlaying 读（决定换曲后要不要重新拉起
			// 设备）。陈旧读会让设备该起不起 → 换完曲彻底静音，故 volatile。
			private volatile bool _playing = false;
			// 【跨线程】主线程在 seek 后设置（PostSeekSilenceFrames），音频回调读取并递减。
			// 无可见性保证时那次"seek 后静音"可能整段丢失 → seek 会听到瞬态攻击音。
			// 递减方只有回调自己（单回调线程），偶发丢一次递减只是多静音一个 period（无害）。
			private volatile int _postSeekSilenceFrames = 0;
			private StringName _bus = new StringName("Master");

			// Vocal control methods are called from the Godot main thread. The native
			// audio callback owns the actual playback state and never reads these fields.
			// 【跨线程】主线程在 vocalLock 内装载/卸载，音频回调的偏移门控**刻意不取锁**读它
			// （避免与 vocalLock 形成嵌套）。故用 volatile 保证可见性：陈旧 false 会让门控
			// 晚放行一个回调（约 5ms），陈旧 true 才是问题，而卸载路径同时会把门重置。
			private volatile bool _vocalLoaded = false;
			private float _vocalVolumeLinear = 1.0f;

			// ---- 统计 ----
			private float _lastSampleL = 0;
			private float _lastSampleR = 0;

			// ---- 延迟查询 ----
			private uint _actualPeriod = 0;       // 设备实际 period (TryCreateDevice 后填充)
			private uint _actualPeriodCount = 0;  // 设备实际 period 数量
			private uint _actualSampleRate = 0;   // 设备实际采样率 (TryCreateDevice 后填充)
			private bool _nativeGetLatencyAvailable = true;  // 旧 DLL 无此导出时设为 false

			/// <summary>设备实际 period (帧数), 供外部诊断用</summary>
			internal uint ActualPeriod => _actualPeriod;
			/// <summary>设备实际 period 数量, 供外部诊断用</summary>
			internal uint ActualPeriodCount => _actualPeriodCount;
			/// <summary>设备实际采样率 (Hz), 0 表示查询失败/未初始化</summary>
			internal uint ActualSampleRate => _actualSampleRate;

			// ---- 线程同步 ----
			internal readonly object _synthLock = new object();
			public object SyncRoot => _synthLock;

			// ---- 手动合成器活跃音符计数 ----
			private volatile int _manualActiveVoiceCount = 0;

			// ---- 性能诊断 ----
			private Stopwatch _perfStopwatch = new Stopwatch();
			private int _perfSlowCallbackCount = 0;
			private int _perfTotalCallbackCount = 0;
			// 音频线程禁止直接 GD.Print（会与主线程争用打印锁、拖延回调返回）。
			// 诊断日志先入队，由主线程 Update() 每帧排空打印。
			private readonly ConcurrentQueue<string> _audioLogQueue = new ConcurrentQueue<string>();

			/// <summary>音频回调内的异常次数（诊断/回归用；回调把异常吞成静音，不计数就不可见）</summary>
			private long _callbackExceptionCount = 0;
			public long CallbackExceptionCount => Interlocked.Read(ref _callbackExceptionCount);

			/// <summary>慢回调比例（回调耗时 &gt; 回调周期），用于验证欠载是否被根治</summary>
			internal double PerfSlowRatio =>
				_perfTotalCallbackCount > 0 ? (double)_perfSlowCallbackCount / _perfTotalCallbackCount : 0.0;
			internal int PerfTotalCallbacks => _perfTotalCallbackCount;
			internal int PerfSlowCallbacks => _perfSlowCallbackCount;

			// ---- 位置外推（非系统时钟模式） ----
			// _sequencer.Position 只在音频回调边界推进，读取时陈旧 0~一个周期。
			// 记录最后一次渲染的墙钟时间戳，get_position_ms 据此外推消除锯齿滞后。
			private long _lastRenderTimestampTicks = Stopwatch.GetTimestamp();

			// ---- 无锁事件队列 ----
			private struct NoteEvent
			{
				public bool IsNoteOn;
				public int VirtualId;
				public int Pitch;
				public int Velocity;
			}
			private readonly ConcurrentQueue<NoteEvent> _pendingNoteEvents =
				new ConcurrentQueue<NoteEvent>();

			// ====================================================================
			// 配置方法 (在 Initialize 前调用)
			// ====================================================================
			public MiniaudioAudioOutputBridge(float bufferLengthSeconds)
			{
				if (bufferLengthSeconds > 0)
				{
					_targetDecodeFrames = (int)(bufferLengthSeconds * 48000);
				}
			}

			public void SetDecodeFrames(int frames)
			{
				_targetDecodeFrames = Math.Clamp(frames, MIN_DECODE_FRAMES, MAX_DECODE_FRAMES);
				ThreadSafeLog.Print($"[MeltySynthPlayer][miniaudio] Target decode frames: {_targetDecodeFrames}");
			}

			/// <summary>
			/// 设置 miniaudio period 大小
			/// 必须在 Initialize 之前调用
			/// </summary>
			public void SetPeriodSize(uint periodSizeInFrames, uint periodCount)
			{
				_periodSizeInFrames = Math.Max(periodSizeInFrames, 64u);
				_periodCount = (uint)Math.Clamp(periodCount, 2, 4);
				ThreadSafeLog.Print($"[MeltySynthPlayer][miniaudio] Period size target: {_periodSizeInFrames}×{_periodCount}");
			}

			/// <summary>设置后端 (Default/Wasapi/CoreAudio/Aaudio 等)</summary>
			public void SetBackend(MiniaudioNative.Backend backend)
			{
				_backend = backend;
			}

			/// <summary>启用 WASAPI 独占模式 (Windows only, 必须在 Initialize 之前)</summary>
			public void SetWASAPIExclusive(bool exclusive)
			{
				_wasapiExclusive = exclusive;
				if (exclusive)
				{
					ThreadSafeLog.Print("[MeltySynthPlayer][miniaudio] WASAPI exclusive mode enabled");
				}
			}

			/// <summary>启用 AAudio 低延迟独占模式 (Android only)</summary>
			public void SetAAudioExclusive(bool exclusive)
			{
				_aaudioExclusive = exclusive;
			}

			/// <summary>启用设备原生采样率模式 (sampleRate=0), 必须在 Initialize 之前调用</summary>
			public void UseDeviceNativeSampleRate(bool useNative)
			{
				_useDeviceNativeSampleRate = useNative;
				ThreadSafeLog.Print($"[MeltySynthPlayer][miniaudio] Device native sample rate mode: {(useNative ? "enabled (sampleRate=0)" : "disabled")}");
			}

			public void SetSynthesizers(MidiFileSequencer sequencer, Synthesizer autoSynth, Synthesizer manualSynth, bool useSeparateSynth)
			{
				lock (_synthLock)
				{
					_sequencer = sequencer;
					_autoSynth = autoSynth;
					_manualSynth = manualSynth;
					_useSeparateSynth = useSeparateSynth;
					ThreadSafeLog.Print($"[MeltySynthPlayer][miniaudio] SetSynthesizers: seq={sequencer!=null}, auto={autoSynth!=null}, manual={manualSynth!=null}, separate={useSeparateSynth}");
				}
			}

			public void SetVolume(float volumeLinear)
			{
				lock (_synthLock)
				{
					_volumeLinear = volumeLinear;
				}
			}

			int IAudioOutputBridge.PostSeekSilenceFrames
			{
				get => _postSeekSilenceFrames;
				set => _postSeekSilenceFrames = value;
			}

			// ====================================================================
			// Vocal control (native decoder + ring buffer, mixed by the C bridge)
			// ====================================================================
			public bool LoadVocalFile(string path)
			{
				if (_bridgeHandle == IntPtr.Zero || string.IsNullOrEmpty(path))
				{
					return false;
				}
				// Native load first unloads any previous decoder. Keep the managed state
				// aligned even when opening the replacement file fails.
				_vocalLoaded = false;
				var utf8Path = MiniaudioNative.StringToUtf8NullTerminated(path);
				var r = MiniaudioNative.ma_bridge_vocal_load(_bridgeHandle, utf8Path);
				if (r != MiniaudioNative.Result.Ok)
				{
					ThreadSafeLog.PrintErr($"[MeltySynthPlayer][miniaudio] ma_bridge_vocal_load failed: {r} ({path})");
					return false;
				}
				_vocalLoaded = true;
				ApplyVocalVolume();
				ThreadSafeLog.Print($"[MeltySynthPlayer][miniaudio] Vocal loaded: {path}");
				return true;
			}

			public void UnloadVocal()
			{
				_vocalLoaded = false;
				if (_bridgeHandle != IntPtr.Zero)
				{
					MiniaudioNative.ma_bridge_vocal_unload(_bridgeHandle);
				}
			}

			public void PlayVocal()
			{
				if (_bridgeHandle == IntPtr.Zero || !_vocalLoaded) return;
				var r = MiniaudioNative.ma_bridge_vocal_play(_bridgeHandle);
				if (r != MiniaudioNative.Result.Ok)
				{
					ThreadSafeLog.PrintErr($"[MeltySynthPlayer][miniaudio] ma_bridge_vocal_play failed: {r}");
				}
			}

			public void PauseVocal()
			{
				if (_bridgeHandle == IntPtr.Zero || !_vocalLoaded) return;
				var r = MiniaudioNative.ma_bridge_vocal_pause(_bridgeHandle);
				if (r != MiniaudioNative.Result.Ok)
				{
					ThreadSafeLog.PrintErr($"[MeltySynthPlayer][miniaudio] ma_bridge_vocal_pause failed: {r}");
				}
			}

			public void ResumeVocal()
			{
				PlayVocal();
			}

			public void StopVocal()
			{
				if (_bridgeHandle == IntPtr.Zero || !_vocalLoaded) return;
				var r = MiniaudioNative.ma_bridge_vocal_stop(_bridgeHandle);
				if (r != MiniaudioNative.Result.Ok)
				{
					ThreadSafeLog.PrintErr($"[MeltySynthPlayer][miniaudio] ma_bridge_vocal_stop failed: {r}");
				}
			}

			public void SeekVocal(double positionMs)
			{
				if (_bridgeHandle == IntPtr.Zero || !_vocalLoaded) return;
				// The native decoder is configured with the device's actual rate. This can
				// differ from the requested synth rate when WASAPI applies a device format.
				int vocalSampleRate = _actualSampleRate > 0 ? (int)_actualSampleRate : _sampleRate;
				double frames = positionMs / 1000.0 * vocalSampleRate;
				if (frames < 0.0) frames = 0.0;
				var r = MiniaudioNative.ma_bridge_vocal_seek(_bridgeHandle, (ulong)Math.Round(frames));
				if (r != MiniaudioNative.Result.Ok)
				{
					ThreadSafeLog.PrintErr($"[MeltySynthPlayer][miniaudio] ma_bridge_vocal_seek failed: {r} ({positionMs}ms)");
				}
			}

			public void SetVocalVolume(float volumeLinear)
			{
				_vocalVolumeLinear = Math.Clamp(volumeLinear, 0.0f, 4.0f);
				if (_bridgeHandle == IntPtr.Zero || !_vocalLoaded) return;
				ApplyVocalVolume();
			}

			private void ApplyVocalVolume()
			{
				var r = MiniaudioNative.ma_bridge_vocal_set_volume(_bridgeHandle, _vocalVolumeLinear);
				if (r != MiniaudioNative.Result.Ok)
				{
					ThreadSafeLog.PrintErr($"[MeltySynthPlayer][miniaudio] ma_bridge_vocal_set_volume failed: {r}");
				}
			}

			public double GetVocalPositionMs()
			{
				return _bridgeHandle != IntPtr.Zero
					? MiniaudioNative.ma_bridge_vocal_get_position_ms(_bridgeHandle)
					: 0.0;
			}

			/// <summary>
			/// 是否已装载人声解码器。**判"有没有人声"必须用它，不能用 GetVocalLengthMs() &gt; 0**：
			/// native 对 .ogg 刻意把总帧数置 0（stb_vorbis 报的是重采样前的源帧数，换算成设备率会错），
			/// 于是 GetVocalLengthMs() 对 ogg 恒返回 -1 —— 而本项目的人声几乎都是 ogg。
			/// 之前多处用长度判"有人声"，等于把这些逻辑对人声整个关掉了。
			/// </summary>
			public double GetVocalLengthMs()
			{
				return _bridgeHandle != IntPtr.Zero
					? MiniaudioNative.ma_bridge_vocal_get_length_ms(_bridgeHandle)
					: -1.0;
			}

			public bool IsVocalPlaying()
			{
				return _bridgeHandle != IntPtr.Zero &&
					MiniaudioNative.ma_bridge_vocal_is_playing(_bridgeHandle) != 0;
			}

		public bool IsVocalFinished()
		{
			return _bridgeHandle != IntPtr.Zero &&
				MiniaudioNative.ma_bridge_vocal_is_finished(_bridgeHandle) != 0;
		}

		/// <summary>
		/// 人声相对 MIDI 的起点偏移（毫秒），来自 runtime 配置 vocal_offset_ms。
		/// MIDI 位置小于它时人声保持静音，等 MIDI 走到该点再放行——
		/// 与前台 _sync_vocal_with_midi 的 expected_vocal_position < 0 分支同语义。
		/// volatile 不支持 double（C# 不做 64 位原子），故用整型微秒存、锁保护读写。
		/// </summary>
		private long _vocalOffsetUs = 0;
		private readonly object _vocalOffsetLock = new object();

		/// <summary>
		/// 偏移门控是否已放行（起播过一次）。换曲时复位。
		/// 用它而不是"当前是否在播"来判定首次放行：暂停态下 IsVocalPlaying 为 false，
		/// 但那不代表还没到偏移点。
		/// </summary>
		private volatile bool _vocalOffsetGatePassed = true;

		public void SetVocalOffsetMs(double offsetMs)
		{
			double clamped = double.IsNaN(offsetMs) || offsetMs < 0.0 ? 0.0 : offsetMs;
			lock (_vocalOffsetLock)
			{
				// 写侧必须与回调侧的 Volatile.Read 配对（release/acquire）：
				// 普通写在缺少屏障时可能长时间不被音频线程观察到，
				// 表现是人声偏移门控按**旧偏移**放行（人声提前/滞后进）。
				Volatile.Write(ref _vocalOffsetUs, (long)(clamped * 1000.0));
			}
		}

		public double GetVocalOffsetMs()
		{
			lock (_vocalOffsetLock)
			{
				return _vocalOffsetUs / 1000.0;
			}
		}

		/// <summary>换曲：偏移门回到「未放行」，由新曲的起播重新走一遍</summary>
		public void ResetVocalOffsetGate()
		{
			_vocalOffsetGatePassed = GetVocalOffsetMs() <= 0.0;
		}

		/// <summary>
		/// 偏移门控，在音频回调内执行（与 RestartVocalOnLoopWrap 同一时序）。
		/// 后台主循环停摆时前台 _sync_vocal_with_midi 不运行，故必须在这里判定：
		/// MIDI 未到 vocal_offset_ms 就把人声按住不放，否则熄屏期间人声整首提前。
		/// 只用 ma_bridge_vocal_pause/play（改 vocalPlaying 标志），不动解码器位置。
		/// </summary>
		private void TickVocalOffsetGateInCallback()
		{
			if (_vocalOffsetGatePassed || !_vocalLoaded || _sequencer == null)
			{
				return;
			}
			// 回调里不取锁（避免与 vocalLock 形成嵌套）：偏移值用 Volatile.Read 读，
			// 它保证可见性且不阻塞；写入侧频率极低（换曲时一次），读到的旧值最多
			// 导致本帧晚放行一帧，下一帧即生效。
			double offsetMs = Volatile.Read(ref _vocalOffsetUs) / 1000.0;
			double nowMs = _sequencer.RenderedPosition.TotalMilliseconds;
			if (double.IsNaN(nowMs) || nowMs < offsetMs)
			{
				return;
			}
			_vocalOffsetGatePassed = true;
			PlayVocal();
		}


	private void TickEndOfSequenceInCallback()
	{
	if (_sequencer != null && _sequencer.EndOfSequence && Volatile.Read(ref _endOfSequenceFlag) == 0)
	{
		Volatile.Write(ref _endOfSequenceFlag, 1);
			// 有交棒就先换手：换成功则本次"曲终"已被处理，标志立刻清掉（不让主线程再处理一次）；
			// 失败（如音源未就绪）则把交棒放回，标志留给前台正规路径。
		// 音频线程不能碰引擎：ThreadSafeLog 会入队，主线程 flush。带绝对时间戳便于对表
		ThreadSafeLog.Print($"[MeltySynthPlayer] end-of-sequence latched (t={System.Environment.TickCount64})");
	}
}

/// <summary>
/// "已播完"闩锁（0/1）。
///
/// 【为什么是 int + Interlocked 而不是 volatile bool】这个标志有三个写入方/读取方：
/// 音频回调置位、前台 _Process 消费、后台推进线程消费，而"读-改-写"（consume / reset）
/// 在两边都可能发生。用 volatile bool 时 `if (!_endOfSequence) return; _endOfSequence = false;`
/// 不是原子操作 —— 前台与后台同时消费会**双双通过判定**，两边各换一次曲 = 连跳两首；
/// 而 reset 与回调置位交叉时又会**丢掉闩锁** = 曲终不换曲。改成原子交换后两者都不会发生。
/// </summary>
private int _endOfSequenceFlag = 0;



	/// <summary>由播放器注册：在回调里真正完成换手（纯 C#/MeltySynth）。返回 false 表示无法换。</summary>

/// <summary>只窥视"已播完"标志，不消费（换曲真正落地后才消费，失败要留着重试）。</summary>
public bool HasEndOfSequence => Volatile.Read(ref _endOfSequenceFlag) != 0;

/// <summary>消费"已播完"标志（一次性，原子）。返回 true 表示本次由调用方取走。</summary>
public bool ConsumeEndOfSequence()
{
	return Interlocked.Exchange(ref _endOfSequenceFlag, 0) != 0;
}

/// <summary>换曲/seek 后清掉标志（新位置未必在末尾，重播时重新判定）。</summary>
public void ResetEndOfSequence()
{
	Interlocked.Exchange(ref _endOfSequenceFlag, 0);
}

		// 后台 seek：Godot 主循环挂起时 _Process 不再处理 _pendingSeekMs，
		// 故由音频线程消费。_seekTargetMs 为 NaN 表示无待处理请求。
		private volatile bool _hasPendingSeek = false;
		private double _seekTargetMs = double.NaN;
		// 上次排队的 seek 是否已被音频线程落盘。主线程据此判断判定钟重锚能否信任
		// seek 目标位置：未落盘时渲染钟还是旧值，必须用目标位置；已落盘则以真实渲染钟
		// 为准——后台挂起期间的陈旧目标会让进度条自走到满而音频早已在别处。
		//
		// 【为什么用请求号而不是一个 bool】主线程的"清 applied → 排队"与音频线程的
		// "落盘 → 置 applied"会交错：主线程刚把 applied 清成 false，回调可能正在收尾
		// 上一次请求并把它置回 true，于是**新请求看起来已经落盘**（ABA）。判定钟据此
		// 误信"渲染钟已到新位置"，进度条与判定就会有若干帧偏在旧位置。
		// 用单调递增的请求号比对，任何交错下 IsSeekApplied 都不会提前为真。
		private long _seekRequestToken = 0;   // Interlocked
		private long _seekAppliedToken = 0;   // Interlocked

		/// <summary>请求在音频线程内执行 seek（后台可用）</summary>
		public void RequestSeek(double positionMs)
		{
			// 先写出目标值，再用 volatile 写发布（release），回调侧 volatile 读（acquire）后可见
			_seekTargetMs = positionMs;
			Interlocked.Increment(ref _seekRequestToken);
			_hasPendingSeek = true;
		}

		/// <summary>上次排队的 seek 是否已被音频线程落盘（按请求号单调比对）</summary>
		public bool IsSeekApplied =>
			Interlocked.Read(ref _seekAppliedToken) >= Interlocked.Read(ref _seekRequestToken);

		/// <summary>起播对齐延时（秒）：等播放真正滚动起来再做，避开起播时的缓冲填充/欠载过渡态</summary>
		private const double StartupAlignDelaySec = 0.4;
		/// <summary>起播对齐待计的已渲染帧数（0=无请求）</summary>
		private long _startupAlignPendingFrames = 0;
		private volatile bool _startupAlignRequested = false;

		/// <summary>
		/// 起播后补一次"与拖动进度条等价"的原地 seek：拖动路径会走 MIDI seek
		/// （跳过 seek 静音帧 + 人声重定位），实测该状态才是听觉对齐的。
		/// 按帧数计时而非 GDScript 侧计时：切后台后 Godot 主循环停摆，
		/// GDScript 的 _process / Timer 都不再运行，只有音频回调照常推进。
		/// </summary>
		public void RequestStartupAlign()
		{
			_startupAlignPendingFrames = (long)(_sampleRate * StartupAlignDelaySec);
			_startupAlignRequested = _startupAlignPendingFrames > 0;
		}

		/// <summary>推进起播对齐计时；到点后排队一次原地 seek（同一回调内立即被消费）</summary>
		private void TickStartupAlignInCallback(int framesRequested)
		{
			if (!_startupAlignRequested)
			{
				return;
			}
			_startupAlignPendingFrames -= framesRequested;
			if (_startupAlignPendingFrames > 0 || _sequencer == null)
			{
				return;
			}
			_startupAlignRequested = false;
			double posMs = _sequencer.RenderedPosition.TotalMilliseconds;
			ThreadSafeLog.Print($"[MeltySynthPlayer] start-up align: in-place seek to {posMs:F0} ms");
			RequestSeek(posMs);
		}

		/// <summary>
		/// 在音频回调内消费 seek 请求。回绕检测与进度条自走共用此处，
		/// 保证 seek 与人声循环在同一时序内一致。
		/// </summary>
		private void ProcessPendingSeekInCallback()
		{
		if (!_hasPendingSeek)
		{
			return;
		}
		// 先取本次要落盘的请求号，再清 pending。若这期间主线程又排了新的请求，
		// 我们写回的旧请求号 < 新请求号 → IsSeekApplied 仍为 false，上层不会误信。
		long token = Interlocked.Read(ref _seekRequestToken);
		_hasPendingSeek = false;
		double targetMs = _seekTargetMs;
		if (_sequencer == null || double.IsNaN(targetMs) || targetMs < 0.0)
		{
			Interlocked.Exchange(ref _seekAppliedToken, token);   // 无效目标也算已消费，别让上层一直等
			return;
		}
		// seek 后新位置未必在末尾：清掉"已播完"标志，由下一次回调按 EndOfSequence 重判。
		Interlocked.Exchange(ref _endOfSequenceFlag, 0);
			try
			{
				_sequencer.Seek(TimeSpan.FromMilliseconds(targetMs));
			}
			catch (Exception)
			{
				// 音频线程内不打印（会争用打印锁拖慢回调）；失败留给主线程的诊断
			}
		Interlocked.Exchange(ref _seekAppliedToken, token);
		// 人声定位不在这里做：上层 MidiPlaybackManager.seek() 已按目标位置调用
		// _seek_vocal_to_midi_position(pos)，这里再拉回 0 会覆盖掉正确结果，
		// 导致拖动进度条后 MIDI 在新位置、人声却从头播（拖到靠后处即立刻播完）。
		// 音频线程只负责 MIDI 时钟，与人声各自独立。
	}

		/// <summary>
		/// 是否已装载人声解码器。**判"有没有人声"必须用它，不能用 GetVocalLengthMs() &gt; 0**：
		/// native 对 .ogg 刻意把总帧数置 0（stb_vorbis 报的是重采样前的源帧数，换算成设备率会错），
		/// 于是 GetVocalLengthMs() 对 ogg 恒返回 -1 —— 而本项目的人声几乎都是 ogg。
		/// 之前多处用长度判"有人声"，等于把这些逻辑对人声整个关掉了。
		/// </summary>
		public bool IsVocalLoaded => _bridgeHandle != IntPtr.Zero && _vocalLoaded;

			public uint GetVocalUnderrunCount()
			{
				return _bridgeHandle != IntPtr.Zero
					? MiniaudioNative.ma_bridge_vocal_get_underrun_count(_bridgeHandle)
					: 0u;
			}

			public ulong GetVocalUnderrunFrames()
			{
				return _bridgeHandle != IntPtr.Zero
					? MiniaudioNative.ma_bridge_vocal_get_underrun_frames(_bridgeHandle)
					: 0ul;
			}

			public uint GetVocalCatchupFrames()
			{
				return _bridgeHandle != IntPtr.Zero
					? MiniaudioNative.ma_bridge_vocal_get_catchup_frames(_bridgeHandle)
					: 0u;
			}

			// ====================================================================
			// Initialize
			// ====================================================================
			public bool Initialize(Node owner, StringName bus, int sampleRate)
			{
				if (_initialized) return true;

				_bus = bus;
				int systemSampleRate = (int)AudioServer.GetMixRate();
				_sampleRate = sampleRate > 0 ? sampleRate : systemSampleRate;

				if (_sampleRate != systemSampleRate)
				{
					// 用 Print 而非 PushWarning，避免每次启动都误报为异常。
					ThreadSafeLog.Print($"[MeltySynthPlayer][miniaudio] Sample rate: synth={_sampleRate}Hz, system={systemSampleRate}Hz (intentional, SRC will handle)");
				}

				_decodeFrames = Math.Max(MIN_DECODE_FRAMES, Math.Min(MAX_DECODE_FRAMES, _targetDecodeFrames));

				// 分配渲染缓冲区 (先用 _decodeFrames, TryCreateDevice 后可能根据实际 period 上调)
				_tempLeft = new float[_decodeFrames];
				_tempRight = new float[_decodeFrames];
				_manualLeft = new float[_decodeFrames];
				_manualRight = new float[_decodeFrames];
				_outputBuffer = new float[MAX_DECODE_FRAMES * 2];

				Array.Clear(_tempLeft, 0, _tempLeft.Length);
				Array.Clear(_tempRight, 0, _tempRight.Length);
				Array.Clear(_manualLeft, 0, _manualLeft.Length);
				Array.Clear(_manualRight, 0, _manualRight.Length);
				Array.Clear(_outputBuffer, 0, _outputBuffer.Length);

				ThreadSafeLog.Print($"[MeltySynthPlayer][miniaudio] System audio: mix_rate={systemSampleRate}Hz");
				ThreadSafeLog.Print($"[MeltySynthPlayer][miniaudio] Initializing: " +
					$"sample_rate={_sampleRate}, decode_buffer={_decodeFrames}f ({_decodeFrames * 1000.0 / _sampleRate:F1}ms), " +
					$"period={_periodSizeInFrames}×{_periodCount}");

				if (!MiniaudioNative.TryLoadNativeLibrary())
				{
					GD.PushWarning("[MeltySynthPlayer][miniaudio] Native library could not be loaded.");
					return false;
				}

				if (!TryCreateDevice())
				{
					DisposeNative();
					return false;
				}

				// 查询设备实际 period (WASAPI 共享模式可能强制为 480, 独占模式为请求值)
				uint actualPeriod = 0, actualCount = 0;
				var qPeriod = MiniaudioNative.ma_bridge_get_period_size(_bridgeHandle, out actualPeriod, out actualCount);
				if (qPeriod == MiniaudioNative.Result.Ok && actualPeriod > 0)
				{
					// _decodeFrames 不上调到 actualPeriod, 保持小批量渲染以降低 RingBuffer 稳态延迟.
					// 之前的 underrun 根因是 Thread.Sleep(1) (Windows 定时器 1-15ms),
					// 现在 SpinWait 唤醒延迟 <0.1ms, 渲染线程生产速率远高于回调消耗速率,
					// 即使 _decodeFrames < actualPeriod 也不会 underrun.
					//
					// 渲染线程是 SpinWait 循环, 只要总生产速率 >= 消耗速率即可, 与每次生产量无关.
					// 小批量渲染 (如 128 帧) 让 RingBuffer 填充更平滑, 稳态延迟更低.
					ThreadSafeLog.Print($"[MeltySynthPlayer][miniaudio] Decode frames: {_decodeFrames} (actualPeriod={actualPeriod}, not adjusted up)");
				}

				_initialized = true;
				return true;
			}

			private bool TryCreateDevice()
			{
				var cfg = MiniaudioNative.ConfigInitDefault();
				// 【方向 1】Android 使用设备原生采样率：sampleRate=0 时 AAudio 不指定采样率，
				// 由系统选择原生率（通常 48000Hz），避免显式请求 44100 触发 SRC/高延迟路径。
				cfg.SampleRate = _useDeviceNativeSampleRate ? 0 : (uint)_sampleRate;
				cfg.PeriodSizeInFrames = _periodSizeInFrames;
				cfg.PeriodCount = _periodCount;
				cfg.Channels = 2;
				cfg.Backend = _backend;
				cfg.WasapiExclusive = _wasapiExclusive ? 1 : 0;
				cfg.AaudioExclusive = _aaudioExclusive ? 1 : 0;
				cfg.NoClip = 1;  // C# 侧 SoftLimit

				// WASAPI 低延迟共享模式 (仅 Windows): 启用 noAutoConvertSRC + 强制 48000Hz.
				// 这启用 IAudioClient3 低延迟共享模式, 可让共享模式使用小 period (如 128 帧),
				// 达到接近独占模式的延迟, 但不需要独占设备.
				// IAudioClient3 要求: 不能有 AUTOCONVERTPCM 标志.
				// 启用 noAutoConvertSRC 后, miniaudio 用内部重采样器做 SRC (如需).
				// 由于 _sampleRate 已被 EnsureAudioInitialized 强制为 48000 (设备原生),
				// 不需要 SRC, 直接匹配.
				//
				// 【注意】noAutoConvertSRC 是 WASAPI 专用选项, 不能在 Android/iOS 上启用.
				// Android AAudio 后端不需要此选项, 默认就支持低延迟.
				// 在 Android 上设置 NoAutoConvertSRC=1 会导致 ma_bridge_init 失败.
				if (!_wasapiExclusive && _backend == MiniaudioNative.Backend.Wasapi)
				{
					cfg.NoAutoConvertSRC = 1;
					ThreadSafeLog.Print("[MeltySynthPlayer][miniaudio] Low-latency shared mode: noAutoConvertSRC=true " +
						"(enables IAudioClient3, target period=" + _periodSizeInFrames + "×" + _periodCount + ")");
				}

				// 设置设备名称 (用于独占模式选择正确的端点)
				// 通过环境变量 MINIAUDIO_DEVICE_NAME 指定设备名称 (UTF-8).
				// 独占模式下 WASAPI 直接绑定设备, 不会自动路由, 必须选择正确的端点.
				// 如果不设置, 使用系统默认设备 (可能导致独占模式打开 HDMI 等错误设备).
				string deviceName = System.Environment.GetEnvironmentVariable("MINIAUDIO_DEVICE_NAME");
				if (!string.IsNullOrEmpty(deviceName))
				{
					ThreadSafeLog.Print($"[MeltySynthPlayer][miniaudio] Setting device name: {deviceName}");
					MiniaudioNative.ma_bridge_set_device_name(MiniaudioNative.StringToUtf8NullTerminated(deviceName));
				}
				else
				{
					// 清除之前可能设置的设备名称
					MiniaudioNative.ma_bridge_set_device_name(null);
				}

				// 固定 GCHandle 防止 this 被 GC, 同时获得稳定指针传给 native
				_selfHandle = GCHandle.Alloc(this, GCHandleType.Normal);
				_dataCallback = OnDataCallback;  // 必须存储委托引用防 GC

				IntPtr userData = (IntPtr)_selfHandle;
				var result = MiniaudioNative.ma_bridge_init(ref cfg, _dataCallback, userData, out _bridgeHandle);
				if (result != MiniaudioNative.Result.Ok || _bridgeHandle == IntPtr.Zero)
				{
					// C# 层回退: 如果启用了 WASAPI 独占模式且初始化失败, 尝试共享模式
					// (旧版 DLL 可能没有 C 层回退逻辑, 这里作为双保险)
					if (_wasapiExclusive)
					{
						GD.PushWarning($"[MeltySynthPlayer][miniaudio] ma_bridge_init failed with WASAPI exclusive: {result}, retrying shared mode");
						_wasapiExclusive = false;
						cfg.WasapiExclusive = 0;
						result = MiniaudioNative.ma_bridge_init(ref cfg, _dataCallback, userData, out _bridgeHandle);
					}
					if (result != MiniaudioNative.Result.Ok || _bridgeHandle == IntPtr.Zero)
					{
						GD.PushWarning($"[MeltySynthPlayer][miniaudio] ma_bridge_init failed: {result}");
						_selfHandle.Free();
						return false;
					}
				}

				// 【方向 1】优先回读设备实际采样率：
				// 原生模式下请求 sampleRate=0，AAudio 会使用设备原生率（通常 48000Hz）。
				// 延迟/外推换算必须用真实率，合成器也须由上层按此重建，否则音高/时长/延迟估算全错。
				var qSr = MiniaudioNative.ma_bridge_get_sample_rate(_bridgeHandle, out uint actualSr);
				if (qSr == MiniaudioNative.Result.Ok)
				{
					_actualSampleRate = actualSr;
					ThreadSafeLog.Print($"[MeltySynthPlayer][miniaudio] Actual sample rate: {actualSr}Hz");
					if (_useDeviceNativeSampleRate && actualSr > 0)
					{
						if (actualSr != (uint)_sampleRate)
						{
							ThreadSafeLog.Print($"[MeltySynthPlayer][miniaudio] Device native rate {actualSr}Hz differs from requested {_sampleRate}Hz; using native rate");
						}
						_sampleRate = (int)actualSr;
					}
					else if (_wasapiExclusive && actualSr != (uint)_sampleRate)
					{
						// 独占模式: 设备使用原生采样率 (可能是 48000Hz), 而合成器用 _sampleRate (44100Hz).
						// 如果两者不匹配, 会导致音高偏高/偏低.
						GD.PushWarning($"[MeltySynthPlayer][miniaudio] Sample rate mismatch in exclusive mode: " +
							$"synth={_sampleRate}Hz, device={actualSr}Hz. " +
							$"Pitch will be off. Need to recreate synthesizer at device sample rate.");
					}
				}
				else if (_useDeviceNativeSampleRate)
				{
					GD.PushWarning($"[MeltySynthPlayer][miniaudio] Failed to query actual sample rate ({qSr}); synthesizer may not match device");
				}

				// 查询实际参数 (驱动可能调整请求值); 此时 _sampleRate 已更新为设备真实率
				var qResult = MiniaudioNative.ma_bridge_get_period_size(_bridgeHandle, out uint actualPeriod, out uint actualCount);
				if (qResult == MiniaudioNative.Result.Ok)
				{
					_actualPeriod = actualPeriod;
					_actualPeriodCount = actualCount;
					ThreadSafeLog.Print($"[MeltySynthPlayer][miniaudio] Actual period: {actualPeriod}×{actualCount} " +
						$"(≈{actualPeriod * actualCount / (double)_sampleRate * 1000:F1}ms total, " +
						$"≈{actualPeriod * (actualCount - 0.5) / _sampleRate * 1000:F1}ms avg latency)");
				}

				IntPtr namePtr = MiniaudioNative.ma_bridge_get_backend_name(_bridgeHandle);
				string backendName = MiniaudioNative.PtrToStringAnsiSafe(namePtr);
				ThreadSafeLog.Print($"[MeltySynthPlayer][miniaudio] Backend: {backendName}");

				IntPtr verPtr = MiniaudioNative.ma_bridge_get_version();
				string ver = MiniaudioNative.PtrToStringAnsiSafe(verPtr);
				ThreadSafeLog.Print($"[MeltySynthPlayer][miniaudio] miniaudio version: {ver}");

				// 枚举可用播放设备 (用于诊断独占模式无声音问题)
				// 独占模式可能打开错误的端点 (如 HDMI), 通过设备列表可以确认.
				EnumerateAndLogDevices();

				return true;
			}

			/// <summary>
			/// 枚举可用播放设备并打印日志 (用于诊断独占模式无声音问题).
			/// 独占模式直接绑定设备端点, 不会自动路由.
			/// 如果默认设备是 HDMI 而用户使用扬声器, 独占模式会打开 HDMI 导致无声音.
			/// </summary>
			private void EnumerateAndLogDevices()
			{
				if (_bridgeHandle == IntPtr.Zero) return;

				_deviceEnumCallback = (userData, namePtr, isDefault) =>
				{
					string name = MiniaudioNative.PtrToStringUtf8Safe(namePtr);
					ThreadSafeLog.Print($"[MeltySynthPlayer][miniaudio]   Device: {name}{(isDefault != 0 ? " (DEFAULT)" : "")}");
					return 1; // 继续枚举
				};

				ThreadSafeLog.Print("[MeltySynthPlayer][miniaudio] Available playback devices:");
				int count = MiniaudioNative.ma_bridge_enumerate_devices(_bridgeHandle, _deviceEnumCallback, IntPtr.Zero);
				ThreadSafeLog.Print($"[MeltySynthPlayer][miniaudio] Total: {count} device(s)");

				if (string.IsNullOrEmpty(System.Environment.GetEnvironmentVariable("MINIAUDIO_DEVICE_NAME")))
				{
					ThreadSafeLog.Print("[MeltySynthPlayer][miniaudio] Tip: If exclusive mode has no sound, " +
						"set MINIAUDIO_DEVICE_NAME env var to the correct device name above.");
				}
			}

			// ====================================================================
			// 播放控制
			// ====================================================================
			public void SetBus(StringName bus) { _bus = bus; }

			public void Play()
			{
				if (_bridgeHandle == IntPtr.Zero) return;
				if (!_playing)
				{
					// 直接渲染模式: 不启动渲染线程, 不需要 Pre-fill.
					// 回调线程直接调用 _sequencer.Render, 无 RingBuffer 中间层.
					// 重置性能计数器
					_perfTotalCallbackCount = 0;
					_perfSlowCallbackCount = 0;

					var r = MiniaudioNative.ma_bridge_start(_bridgeHandle);
					if (r != MiniaudioNative.Result.Ok)
					{
						// Play() 会从后台换曲线程调用 → 不能走 GD.PushWarning（引擎调用，
						// 主线程冻结时会阻塞）。ThreadSafeLog 主线程直接打、非主线程入队。
						ThreadSafeLog.PrintErr($"[MeltySynthPlayer][miniaudio] ma_bridge_start failed: {r}");
						// 记下来供上层判断：ma_device_start 失败说明这条 AAudio stream 已经永久失效
						// （通话抢焦点后的典型结果），此时任何重试都没用，只能整桥重建。
						// 上层（PlayView / 暂停恢复）据此决定是否走重建，而不是靠"音频钟停滞"事后推断。
						AudioStartFailed = true;
						return;
					}
					AudioStartFailed = false;
					_playing = true;

				ThreadSafeLog.Print("[MeltySynthPlayer][miniaudio] Playback started (DIRECT MODE)");
				}
			}

			/// <summary>最近一次 Play() 是否因 ma_bridge_start 失败而没能起播。
			/// true = 设备/流已失效，需要整桥重建；false = 要么起播成功，要么根本没尝试。</summary>
			public bool AudioStartFailed { get; private set; }

			public void Stop()
			{
				if (_bridgeHandle != IntPtr.Zero)
				{
					MiniaudioNative.ma_bridge_stop(_bridgeHandle);
				}
				Array.Clear(_outputBuffer, 0, _outputBuffer.Length);
				_lastSampleL = 0;
				_lastSampleR = 0;
				_playing = false;
				// 停设备不代表流失效；下一次 Play() 会重新尝试并如实置位
				AudioStartFailed = false;
			}

			public void Update()
			{
				// miniaudio 不需要轮询更新，但主线程在此排空音频线程的诊断日志，
				// 避免音频线程直接调用 GD.Print（打印锁争用会拖延回调，诱发欠载）。
				while (_audioLogQueue.TryDequeue(out var log))
				{
					ThreadSafeLog.Print(log);
				}
			}

			public bool IsPlaying => _playing;

			// ====================================================================
			// 音符事件
			// ====================================================================
			public void EnqueueNoteOn(int virtualId, int pitch, int velocity)
			{
				_pendingNoteEvents.Enqueue(new NoteEvent
				{
					IsNoteOn = true,
					VirtualId = virtualId,
					Pitch = pitch,
					Velocity = velocity
				});				// self-heal：若计数器为负（历史重复 note_off 导致），强制重置为 1
				// 否则 shouldRenderManual 永远为 false，manual synth 不渲染
				if (Interlocked.Increment(ref _manualActiveVoiceCount) <= 0)
				{
					_manualActiveVoiceCount = 1;
				}
			}

			/// <summary>
			/// 丢弃尚未被音频回调消费的手动音符事件。停止播放 / 换曲时调用。
			///
			/// 【为什么必须清】设备停止期间回调不再出队，而打歌页的输入路径（trigger_note_on）
			/// 仍可能继续入队 —— 例如曲终后 PlayView 还要等最多 10s 让音符落完，玩家在这段
			/// 时间里点屏幕就会被记下，等下一局（或下一首）设备重新起跑时**一次性补发**，
			/// 表现为开局就有一个卡住的音（幽灵音）。
			/// ConcurrentQueue.Clear 本身线程安全，回调并发出队时也安全。
			/// </summary>
			public void ClearPendingNotes()
			{
				_pendingNoteEvents.Clear();
				// 丢弃的 NoteOn 不能把"手动音符活跃数"留在高位：否则 shouldRenderManual 永远为真，
				// 独立手动合成器会被一直渲染（并让已结束的手动音继续存在）。
				Interlocked.Exchange(ref _manualActiveVoiceCount, 0);
			}

			/// <summary>[诊断/回归] 尚未被回调消费的手动音符事件数。</summary>
			public int PendingNoteCount => _pendingNoteEvents.Count;

			public void EnqueueNoteOff(int virtualId, int pitch)
			{
				_pendingNoteEvents.Enqueue(new NoteEvent
				{
					IsNoteOn = false,
					VirtualId = virtualId,
					Pitch = pitch,
					Velocity = 0
				});
				// 原子 decrement 后若为负（重复 note_off 导致），强制 clamp 到 0
				// 避免 shouldRenderManual 永久 false 使 manual synth 不渲染
				if (Interlocked.Decrement(ref _manualActiveVoiceCount) < 0)
					Interlocked.Exchange(ref _manualActiveVoiceCount, 0);
			}

			// ====================================================================
			// miniaudio 数据回调 (实时音频线程)
			// 签名: void(IntPtr pUserData, IntPtr pOutput, uint frameCount)
			// pOutput: 交错 float32 stereo 缓冲区, 容量 = frameCount * 2 * sizeof(float)
			// ====================================================================
			// 注意: 回调必须是 static 以保证 AOT (iOS) 兼容性
			// this 通过 GCHandle 回查, 委托通过 _dataCallback 字段防止 GC
			private static void OnDataCallback(IntPtr pUserData, IntPtr pOutput, uint frameCount)
			{
				// 静态方法 + GCHandle 回查实例, 避免 this 委托被 GC
				if (pUserData == IntPtr.Zero) return;
				var self = (MiniaudioAudioOutputBridge)GCHandle.FromIntPtr(pUserData).Target;
				if (self == null) return;
				self.FillDataDirect(pOutput, (int)frameCount);
			}

			/// <summary>
			/// 直接在 miniaudio 回调中渲染音频 (无 RingBuffer, 无渲染线程).
			/// 设计:
			///   - 回调线程直接调用 _sequencer.Render 和 _manualSynth.Render
			///   - 用 ConcurrentQueue 传递手动音符事件 (无锁)
			///   - lock _synthLock 保护合成器引用 (仅在 SetSynthesizers/SetVolume 时短暂竞争)
			///
			/// 为什么不用 RingBuffer + 渲染线程:
			///   96000Hz 高采样率下回调频率 375Hz (2.67ms 间隔),
			///   渲染线程用 Thread.SpinWait 检测 RingBuffer 可读帧变化有延迟,
			///   导致 53% underrun. 直接渲染完全消除时序竞争.
			///
			/// 性能: MeltySynth Render 256 帧 avg=0.012ms, max=1ms, 远小于 2.67ms 回调间隔.
			/// 延迟: 仅设备延迟 (7.5ms @ 96000Hz), 无 RingBuffer 延迟.
			/// </summary>
			private void FillDataDirect(IntPtr pOutput, int framesRequested)
			{
				// 防御性: 若 native 回调请求量超过 _outputBuffer 容量, 截断避免越界
				if (framesRequested > MAX_DECODE_FRAMES)
				{
					// 音频线程禁止任何引擎调用（GD.PushWarning 会争用引擎/打印锁，
					// 主线程冻结时甚至永久阻塞回调）。与其它音频线程诊断一致：只入队，
					// 由主线程 Update() 统一打出去。
					_audioLogQueue.Enqueue($"[MeltySynthPlayer][miniaudio] WARN framesRequested={framesRequested} exceeds MAX_DECODE_FRAMES={MAX_DECODE_FRAMES}, clamping");
					framesRequested = MAX_DECODE_FRAMES;
				}

				// 首次回调诊断（音频线程只入队，主线程打印）
				if (_perfTotalCallbackCount == 0)
				{
					_audioLogQueue.Enqueue($"[MeltySynthPlayer][miniaudio] First callback (DIRECT MODE): framesRequested={framesRequested}, " +
						$"actualPeriod={_actualPeriod}, sampleRate={_sampleRate}Hz");
				}

				_perfStopwatch.Restart();

				// 无锁出队手动音符事件 (ConcurrentQueue 线程安全)
				Span<NoteEvent> localEvents = stackalloc NoteEvent[32];
				int eventCount = 0;
				while (eventCount < 32 && _pendingNoteEvents.TryDequeue(out localEvents[eventCount]))
					eventCount++;

				try
				{
					lock (_synthLock)
					{
						if (_sequencer == null || _autoSynth == null)
						{
							FillWithSilence(pOutput, framesRequested);
							return;
						}

						// 确保渲染缓冲区足够大
						if (_tempLeft.Length < framesRequested)
						{
							_tempLeft = new float[framesRequested];
							_tempRight = new float[framesRequested];
							_manualLeft = new float[framesRequested];
							_manualRight = new float[framesRequested];
						}

						// Post-seek silence: 渲染到 discard 缓冲区消耗瞬态, 输出静音衰减
						if (_postSeekSilenceFrames > 0)
						{
							int silence = Math.Min(framesRequested, _postSeekSilenceFrames);
							var discardSpan = _tempLeft.AsSpan(0, silence);
							_sequencer.Render(discardSpan, discardSpan);
							_postSeekSilenceFrames -= silence;
							FillRemainderWithDecay(0, framesRequested);
							_lastRenderTimestampTicks = Stopwatch.GetTimestamp();
							if (IsVocalPlaying())
							{
								MiniaudioNative.ma_bridge_vocal_skip_frames(_bridgeHandle, (uint)silence);
							}
							Marshal.Copy(_outputBuffer, 0, pOutput, framesRequested * 2);
							return;
						}

						// 清零渲染缓冲区
						Array.Clear(_tempLeft, 0, framesRequested);
						Array.Clear(_tempRight, 0, framesRequested);

						// 处理手动音符事件
						for (int i = 0; i < eventCount; i++)
						{
							var synth = (_useSeparateSynth && _manualSynth != null) ? _manualSynth : _autoSynth;
							if (synth == null) continue;
							if (localEvents[i].IsNoteOn)
								synth.NoteOn(localEvents[i].VirtualId, localEvents[i].Pitch, localEvents[i].Velocity);
							else
								synth.NoteOff(localEvents[i].VirtualId, localEvents[i].Pitch);
						}

						float scale = _volumeLinear * OUTPUT_GAIN;

						bool shouldRenderManual = _useSeparateSynth && _manualSynth != null
							&& _manualSynth != _autoSynth && _manualActiveVoiceCount > 0;

						if (shouldRenderManual)
						{
							Array.Clear(_manualLeft, 0, framesRequested);
							Array.Clear(_manualRight, 0, framesRequested);
							_sequencer.Render(_tempLeft.AsSpan(0, framesRequested), _tempRight.AsSpan(0, framesRequested));
							_manualSynth.Render(_manualLeft.AsSpan(0, framesRequested), _manualRight.AsSpan(0, framesRequested));
							MixToOutput(_tempLeft, _tempRight, _manualLeft, _manualRight, framesRequested, scale);
						}
						else
					{
						_sequencer.Render(_tempLeft.AsSpan(0, framesRequested), _tempRight.AsSpan(0, framesRequested));
						MixToOutput(_tempLeft, _tempRight, null, null, framesRequested, scale);
					}

// 后台 seek 与 MIDI 回绕后人声重播。此处必须在音频回调内：
                                       // Android 切后台后 Godot 主循环挂起，GDScript 与 _Process 均无法执行。
                                       TickStartupAlignInCallback(framesRequested);
                                       ProcessPendingSeekInCallback();
                                       TickVocalOffsetGateInCallback();
                                       TickEndOfSequenceInCallback();
				}

					_lastRenderTimestampTicks = Stopwatch.GetTimestamp();
					Marshal.Copy(_outputBuffer, 0, pOutput, framesRequested * 2);
				}
				catch (Exception ex)
				{
					// 计数供 smoke 断言：音频回调里的异常会被吞成静音，光看"还能播"是发现不了的。
					// 典型成因是主线程无锁直写合成器与回调 voices 遍历并发（见 WithSynthLock 的注释）。
					Interlocked.Increment(ref _callbackExceptionCount);
					ThreadSafeLog.PrintErr($"[MeltySynthPlayer][miniaudio] FillDataDirect exception: {ex}");
					FillWithSilence(pOutput, framesRequested);
				}

				_perfStopwatch.Stop();
				_perfTotalCallbackCount++;

				// 非零数据诊断: 前 3 次回调 + 之后每 10000 次（音频线程只入队，主线程打印）
				if (_perfTotalCallbackCount <= 3 || _perfTotalCallbackCount % 10000 == 0)
				{
					float maxAbs = 0f;
					int checkLen = Math.Min(framesRequested * 2, 64);
					for (int i = 0; i < checkLen; i++)
					{
						float a = Math.Abs(_outputBuffer[i]);
						if (a > maxAbs) maxAbs = a;
					}
					_audioLogQueue.Enqueue($"[MeltySynthPlayer][miniaudio] Callback #{_perfTotalCallbackCount}: " +
						$"frames={framesRequested}, maxAbs={maxAbs:F4} (first {checkLen} samples)");
				}

				double elapsedMs = _perfStopwatch.Elapsed.TotalMilliseconds;
				// 【修复】budget 即回调周期（frames/sampleRate），此前误乘 0.5 把
				// 256帧@48k 的 5.33ms 预算算成 2.67ms，制造大量伪慢回调误报。
				double budgetMs = (double)framesRequested / _sampleRate * 1000.0;
				if (elapsedMs > budgetMs)
				{
					_perfSlowCallbackCount++;
					if (_perfSlowCallbackCount <= 1 || _perfSlowCallbackCount % 300 == 0)
					{
						_audioLogQueue.Enqueue($"[MeltySynthPlayer][miniaudio] PERF: callback {elapsedMs:F3}ms " +
							$"(budget={budgetMs:F2}ms, frames={framesRequested}, " +
							$"slow={_perfSlowCallbackCount}/{_perfTotalCallbackCount})");
					}
				}
			}

			// ====================================================================
			// 辅助方法
			// ====================================================================
			private void MixToOutput(float[] autoLeft, float[] autoRight, float[] manualLeft, float[] manualRight, int frames, float scale)
			{
				for (int i = 0; i < frames; i++)
				{
					float left = autoLeft[i];
					float right = autoRight[i];
					if (manualLeft != null)
					{
						left += manualLeft[i];
						right += manualRight[i];
					}
					left = SoftLimit(left);
					right = SoftLimit(right);
					left *= scale;
					right *= scale;
					_outputBuffer[i * 2] = left;
					_outputBuffer[i * 2 + 1] = right;
				}
				_lastSampleL = _outputBuffer[(frames - 1) * 2];
				_lastSampleR = _outputBuffer[(frames - 1) * 2 + 1];
			}

			private static float SoftLimit(float sample)
			{
				// tanh(sample*0.9)*0.95 的有理数近似（经典 27+9x² 形式，|x|≤3 误差 <0.005 ≈ -46dBFS）。
				// 音频回调每回调调用约 512-1024 次，双精度 Math.Tanh 在 Android 小核上约 50-150ns/次，
				// 换成纯单精度乘除后此段开销可忽略；曲线仍是单调饱和软限幅，听感等效。
				float x = sample * 0.9f;
				if (x > 3f)
				{
					return 0.95f;
				}
				if (x < -3f)
				{
					return -0.95f;
				}
				float x2 = x * x;
				return x * (27f + x2) / (27f + 9f * x2) * 0.95f;
			}

			private void FillWithSilence(IntPtr data, int frames)
			{
				int required = frames * 2;
				if (_outputBuffer.Length < required)
				{
					Array.Resize(ref _outputBuffer, required);
				}
				float decay = (float)Math.Exp(-2.0 / Math.Max(1, frames));
				float l = _lastSampleL;
				float r = _lastSampleR;
				for (int i = 0; i < frames; i++)
				{
					_outputBuffer[i * 2] = l;
					_outputBuffer[i * 2 + 1] = r;
					l *= decay;
					r *= decay;
				}
				_lastSampleL = l;
				_lastSampleR = r;
				Marshal.Copy(_outputBuffer, 0, data, required);
			}

			private void FillRemainderWithDecay(int startFrame, int endFrame)
			{
				int frames = endFrame - startFrame;
				float decay = (float)Math.Exp(-2.0 / Math.Max(1, frames));
				float l = _lastSampleL;
				float r = _lastSampleR;
				for (int i = startFrame; i < endFrame; i++)
				{
					_outputBuffer[i * 2] = l;
					_outputBuffer[i * 2 + 1] = r;
					l *= decay;
					r *= decay;
				}
				_lastSampleL = l;
				_lastSampleR = r;
			}

			// ====================================================================
			// 销毁
			// ====================================================================
			private void DisposeNative()
			{
				if (_bridgeHandle != IntPtr.Zero)
				{
					MiniaudioNative.ma_bridge_uninit(_bridgeHandle);
					_bridgeHandle = IntPtr.Zero;
				}
				if (_selfHandle.IsAllocated)
				{
					_selfHandle.Free();
				}
				_initialized = false;
				_playing = false;
			}

			public void Dispose()
		{
			DisposeNative();
		}

		/// <summary>
			/// 获取当前总音频延迟 (毫秒)
			/// = 设备内部延迟 (ma_device_get_latency 或 period 估算) + RingBuffer 延迟
			/// </summary>
			public float GetLatencyMs()
			{
				var (deviceMs, ringMs) = GetLatencyBreakdown();
				return deviceMs + ringMs;
			}

			/// <summary>
			/// 获取延迟分解: (设备延迟 ms, RingBuffer 延迟 ms)
			/// 用于诊断延迟来源
			/// </summary>
			public (float deviceMs, float ringMs) GetLatencyBreakdown()
			{
				float deviceLatencyMs = 0f;

				// 1. 尝试获取 native 设备延迟 (真实值)
				if (_nativeGetLatencyAvailable && _bridgeHandle != IntPtr.Zero)
				{
					try
					{
						var r = MiniaudioNative.ma_bridge_get_latency(_bridgeHandle, out uint latencyFrames);
						if (r == MiniaudioNative.Result.Ok)
						{
							deviceLatencyMs = latencyFrames * 1000.0f / _sampleRate;
						}
						else
						{
							// 后端不支持 ma_device_get_latency, 用 period 估算
							deviceLatencyMs = EstimateDeviceLatencyMs();
						}
					}
					catch (EntryPointNotFoundException)
					{
						// 旧版 DLL 无此导出, 不再尝试
						_nativeGetLatencyAvailable = false;
						ThreadSafeLog.Print("[MeltySynthPlayer][miniaudio] ma_bridge_get_latency not found in DLL, using estimate");
						deviceLatencyMs = EstimateDeviceLatencyMs();
					}
				}
				else
				{
					deviceLatencyMs = EstimateDeviceLatencyMs();
				}

				// 2. RingBuffer 延迟 (应用层缓冲, 尚未进入设备)
			// RingBuffer 已删除, 直接渲染模式下无应用层缓冲延迟
			float ringLatencyMs = 0f;

			return (deviceLatencyMs, ringLatencyMs);
			}

			/// <summary>
			/// 自最后一次音频渲染以来的墙钟流逝（毫秒），用于非系统时钟模式下外推陈旧位置。
			/// 上限 2 个回调周期：正常只需桥接 0~1 周期；超过说明设备真实卡顿，停止外推。
			/// </summary>
			public double GetExtrapolationMs()
			{
				double elapsedMs = (Stopwatch.GetTimestamp() - _lastRenderTimestampTicks) / (double)Stopwatch.Frequency * 1000.0;
				double periodMs = _sampleRate > 0 ? _actualPeriod * 1000.0 / (double)_sampleRate : 0.0;
				double maxExtrapMs = Math.Max(1.0, periodMs * 2.0);
				return Math.Min(elapsedMs, maxExtrapMs);
			}

			/// <summary>重置渲染时间戳（播放/seek 重启时调用，避免首帧误外推）</summary>
			public void ResetLastRenderTimestamp()
			{
				_lastRenderTimestampTicks = Stopwatch.GetTimestamp();
			}

			/// <summary>用 period size × (count - 0.5) 估算设备延迟 (fallback)</summary>
			private float EstimateDeviceLatencyMs()
			{
				if (_actualPeriod > 0 && _actualPeriodCount > 0)
				{
					// WASAPI 回调触发时: 1 个 period 正在播放, (count-1) 个已排队
					// 平均延迟 = periodSize × (count - 0.5)
					float latencyPeriods = _actualPeriodCount >= 2 ? (_actualPeriodCount - 0.5f) : 0.5f;
					return _actualPeriod * latencyPeriods * 1000.0f / _sampleRate;
				}
				return 0f;
			}
		}
}

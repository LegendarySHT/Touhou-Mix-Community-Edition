using System;

/// <summary>
/// MeltySynthPlayer 的**只读**状态查询（播放器意图 API 重构 · 阶段 0，只加不改）。
///
/// 本文件是纯增量：不修改任何既有方法的签名与行为，只把既有状态读出来打包成
/// <see cref="PlaybackSnapshot"/> / <see cref="PlaybackPosition"/>。
/// 阶段 0 尚无 GDScript 消费者（调用点迁移在阶段 3），所以这里只保证三件事：
///   1. 口径正确（两套钟，见下）；
///   2. 预卷负值原样透出（永不钳制到 0）；
///   3. 不引入任何新状态写入 —— 唯一被调用的既有读方法 `get_position_ms()` 自身的
///      副作用（更新 `_lastPositionMs`、递减 `_seekPositionHoldFrames`）保持原样、不加码。
///
/// 【口径（§3.2 最终版：这套钟是两套，不是三套）】
///   JudgeMs / VisualMs —— 判定·感知轴：现有 C# `get_position_ms()`（已扣设备延迟）再扣
///                          `_audioDelayMs`（校准延迟），即现有 `get_visual_position_ms()`
///                          去掉 Math.Max 钳制后的口径；两者当前**恒等**。
///   RawTimelineMs      —— 原始时间轴：现有 `get_raw_position_ms()`（sequencer 的时间域）。
///   AudioMs            —— 音频回调渲染钟：与 RawTimelineMs 同源同值（同属原始时间域的
///                          两个名字，关系如同 Judge/Visual），供人声同步 / 停滞检测。
/// </summary>
public partial class MeltySynthPlayer
{
	/// <summary>
	/// 取一份播放状态快照（只读查询）。
	///
	/// 【纯读约定】本方法不写任何传输/设备/位置状态。它调用的既有 getter
	/// `get_position_ms()` 自身会更新 `_lastPositionMs` 并递减 `_seekPositionHoldFrames`
	/// —— 那是既有行为（今天 PlayView 每帧调的就是它），此处**不加新副作用**：
	/// 一次调用只触发一次该 getter，因此 seek-hold 帧的消耗与"直接调一次
	/// get_visual_position_ms()"完全等价。一帧内多次调用本方法 = 多次调用既有 getter
	/// （hold 帧同样被多次递减），与现状一致，未做额外缓存；需要"每帧只取一次"的
	/// 消费者请按 §6.8 在调用侧缓存整个快照对象。
	///
	/// 【线程】只能在主线程调用（返回值是 Godot 对象；位置/锚点/设备引用均为主线程所有）。
	/// </summary>
	public PlaybackSnapshot GetPlaybackSnapshot()
	{
		// 位置：**一次读取、就地展开**（避免同一帧内多次读钟导致的口径分裂）。
		// judgeSourceMs = 既有判定钟（未扣校准延迟）。
		double judgeSourceMs = get_position_ms();
		// 负值原样透出（预卷 / pending-seek / seek-hold / 非播放分支都可能为负）；
		// 只有非负位置才扣校准延迟，且不再 Math.Max 钳制 —— 这正是 §8 阶段 0 要求的
		// "把 Math.Max(0.0, ...) 换成负值透出"。与今天 get_visual_position_ms() 的唯一差别
		// 是 0 <= pos < _audioDelayMs 这一小段（今天那里会被钳成 0）。
		double judgeMs = judgeSourceMs < 0.0 ? judgeSourceMs : judgeSourceMs - _audioDelayMs;

		// 原始时间轴：get_raw_position_ms() 是纯读（无副作用、不写 _lastPositionMs）。
		// AudioMs 与它同源同值（同一时间域的两个用途名），故复用同一个值。
		double rawMs = get_raw_position_ms();

		int deviceState = (int)AudioDeviceState.Absent;
		double latencyMs = 0.0;
		if (_audioOutput != null)
		{
			// AudioStartFailed 只在"最近一次 Play() 起播失败"时为真，且下一次成功后自动清零
			// （见 MiniaudioAudioOutputBridge.Play/Stop），因此它优先于 IsPlaying 判定。
			if (_audioOutput.AudioStartFailed)
			{
				deviceState = (int)AudioDeviceState.StartFailed;
			}
			else if (_audioOutput.IsPlaying)
			{
				deviceState = (int)AudioDeviceState.Running;
			}
			else
			{
				deviceState = (int)AudioDeviceState.Stopped;
			}
			latencyMs = _audioOutput.GetLatencyMs();
		}

		double durationMs = _midiFile != null ? _midiFile.Length.TotalMilliseconds : 0.0;

		return new PlaybackSnapshot
		{
			Phase = ResolvePlaybackPhase(durationMs),
			SequencerRunning = _sequencerStarted,
			MidiLoaded = _midiFile != null,
			// 现有唯一的"本会话是否已进入时间轴"事实：跨过预卷零点、或已落一次正数 seek、
			// 或整桥重建后按正数位置恢复过（三处都置位；stop/曲终/换曲复位）。
			HasEverStarted = _hasSkippedPreroolEvents,
			CurrentKey = _currentKey ?? "",
			DeviceState = deviceState,
			LatencyMs = latencyMs,
			JudgeMs = judgeMs,
			VisualMs = judgeMs,  // 恒等于 JudgeMs（§3.2）
			RawTimelineMs = rawMs,
			AudioMs = rawMs,
			PendingSeekMs = _pendingSeekMs,  // NaN = 无待处理 seek
			PrerollRemainingMs = _currentOffsetMs < 0.0 ? -_currentOffsetMs : 0.0,
			DurationMs = durationMs,
			AudioDelayMs = _audioDelayMs,
			// 阶段 0 没有"当前打断原因"的存储字段（打断决策收归 C# 是阶段 1），
			// 只能从"最近一次起播失败"推断设备失效；其余原因一律 None（不做臆测）。
			InterruptReason = deviceState == (int)AudioDeviceState.StartFailed
				? (int)PlaybackInterruptReason.DeviceLost
				: (int)PlaybackInterruptReason.None,
			Paused = _paused,
			Playing = playing,  // 传输级 playing：pause() 不清它，暂停期间 Paused 与 Playing 同时为真
		};
	}

	/// <summary>
	/// 位置查询（§3.2 的 <see cref="PlaybackPosition"/>，§8 阶段 0 的第二个查询）。
	/// 只读，复用上面的实现，不重复任何口径计算。
	/// </summary>
	public PlaybackPosition GetPlaybackPosition()
	{
		PlaybackSnapshot snap = GetPlaybackSnapshot();
		return new PlaybackPosition
		{
			JudgeMs = snap.JudgeMs,
			VisualMs = snap.VisualMs,
			RawTimelineMs = snap.RawTimelineMs,
			AudioMs = snap.AudioMs,
			// 预卷 = 负时间轴（sequencer 停在 0，负偏移由 _currentOffsetMs 表达）
			IsPreRoll = _currentOffsetMs < 0.0,
		};
	}

	// 文档 §5.2 里 GDScript 侧写的是 snake_case 调用名（与本仓既有 GDScript 可调 API 一致，
	// 如 get_position_ms / get_visual_position_ms）。别名只为阶段 3 不必在两种命名间二选一，
	// 实现只有一处。
	public PlaybackSnapshot get_playback_snapshot() => GetPlaybackSnapshot();
	public PlaybackPosition get_playback_position() => GetPlaybackPosition();

	/// <summary>
	/// 由既有状态**推导** PlaybackPhase。
	///
	/// 阶段 0 刻意不新增状态机字段（那会改到 play/pause/stop 等既有方法的写入点，
	/// 违反"零行为变化"），因此这里是推导而非权威状态；阶段 2 引入真正的状态机后，
	/// 本函数应被替换为单一权威字段的读取。
	///
	/// 已知近似（阶段 0 无法区分，已与代码事实对齐，不臆造）：
	///   - `Stopped`（显式结束、位置归 0）与 `Preparing`（装配完未起播）在"位置 0 且未在播"
	///     时状态完全同形，只能靠 `_hasSkippedPreroolEvents` 区分"本会话是否进过时间轴"；
	///   - 预卷期间用户暂停 → 报 `Paused`（位置冻结在负 offset），而不是 `PreRolling`；
	///   - 传输在播但设备起播失败 → 仍报 `Playing`（设备侧的坏消息由 DeviceState 单独暴露，
	///     两者组合正是 §5.2 要看见的信息）。
	/// </summary>
	private int ResolvePlaybackPhase(double durationMs)
	{
		if (_midiFile == null)
		{
			return (int)PlaybackPhase.Idle;  // 无曲目、无会话
		}

		// 暂停优先于预卷：pause() 只置 _paused（playing 仍为 true，见 §1.1 的说明）。
		if (_paused)
		{
			return (int)PlaybackPhase.Paused;
		}

		// 负时间轴倒计时：sequencer 刻意停着、设备刻意停着
		if (_currentOffsetMs < 0.0)
		{
			return (int)PlaybackPhase.PreRolling;
		}

		if (playing)
		{
			return (int)PlaybackPhase.Playing;
		}

		// 自然曲终：FinishPlayback() 把 _lastPositionMs 钉在曲尾且 playing=false；
		// 显式 stop() 则把位置归 0（下面落到 Stopped/Preparing）。
		if (durationMs > 0.0 && _lastPositionMs >= durationMs - 1.0)
		{
			return (int)PlaybackPhase.Ended;
		}

		// 会话已装配、尚未进入时间轴（含预卷开始前的待播态）
		if (!_hasSkippedPreroolEvents)
		{
			return (int)PlaybackPhase.Preparing;
		}

		return (int)PlaybackPhase.Stopped;
	}
}

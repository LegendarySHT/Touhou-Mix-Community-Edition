using Godot;

/// <summary>
/// 一次取全的播放状态快照（播放器意图 API 重构 · 阶段 0，只加不改）。
///
/// GDScript 侧只读、不再逐项拼凑（文档 §5.2）。字段定义严格按
/// `Doc/architecture/player_intent_api.md` §3.2 的**最终版本**。
///
/// 【这套钟是两套，不是三套】（§3.2 / §5.1 的最终结论）
///   - 判定·感知轴：<see cref="JudgeMs"/> 与 <see cref="VisualMs"/>，**当前恒等**。
///     保留两个名字只为"按用途取用"（我要判定位置 / 我要显示位置）+ 将来可分化；
///     任何把它们当成"两个不同的数"的用法都是错的。
///   - 原始时间轴：<see cref="RawTimelineMs"/>（sequencer 的时间域）与
///     <see cref="AudioMs"/>（音频回调渲染钟）。二者同属原始时间域、当前同值，
///     分开命名同样只为用途可读（人声同步 / 停滞检测用 AudioMs，状态恢复用 RawTimelineMs）。
///
/// 【负值不钳制】预卷期间 <see cref="JudgeMs"/> / <see cref="VisualMs"/> /
/// <see cref="RawTimelineMs"/> 均为负值，**原样透出**（本项目踩过的核心 bug：
/// 把预卷钳成 0 → 准备动画结束后音符突然冒出来、开局全部 Miss）。
///
/// 【跨语言契约】字段类型刻意用 int/bool/double（不用 C# 枚举）：
/// GDScript 侧镜像同序枚举后按数值比较（§5.2），不依赖跨语言枚举名字解析。
/// 全部字段带 [Export]，否则 GDScript 读不到（Godot C# 只把 [Export] 成员注册为属性）。
/// </summary>
[GlobalClass]
public partial class PlaybackSnapshot : RefCounted
{
	// —— 状态机 #1：传输 ——
	[Export] public int Phase;                 // PlaybackPhase
	[Export] public bool SequencerRunning;     // 状态机 #3
	[Export] public bool MidiLoaded;
	[Export] public bool HasEverStarted;       // 本会话是否已跨越预卷（替代 PlayView._session_started）
	[Export] public string CurrentKey = "";

	// —— 状态机 #2：音频设备 ——
	[Export] public int DeviceState;           // AudioDeviceState
	[Export] public double LatencyMs;

	// —— 位置（见 §5.1 用途表）——
	[Export] public double JudgeMs;            // 判定·感知钟（扣设备延迟 + 校准延迟）
	[Export] public double VisualMs;           // 【与 JudgeMs 同值】显示钟（用途可读性）
	[Export] public double RawTimelineMs;      // 原始时间轴 = 现有 get_raw_position_ms()
	[Export] public double AudioMs;            // 音频回调渲染钟（人声同步 / 停滞检测）
	[Export] public double PendingSeekMs;      // NaN = 无待处理 seek
	[Export] public double PrerollRemainingMs; // 预卷剩余（负 offset 的绝对值）；非预卷为 0

	// —— 汇总量 ——
	[Export] public double DurationMs;
	[Export] public double AudioDelayMs;       // 当前生效的校准延迟；仅供诊断/显示，不参与判定
	[Export] public int InterruptReason;       // PlaybackInterruptReason（None=0）
	[Export] public bool Paused;
	[Export] public bool Playing;              // = 传输级 playing（注意：pause() 不清它，见 Paused）
}

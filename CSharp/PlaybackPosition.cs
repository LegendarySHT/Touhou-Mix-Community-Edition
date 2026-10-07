using Godot;

/// <summary>
/// 位置查询的返回值（播放器意图 API 重构 · 阶段 0，只加不改）：供只需要时间的调用点
/// 少建一个对象。字段定义严格按 `Doc/architecture/player_intent_api.md` §3.2 最终版本。
///
/// 口径与 <see cref="PlaybackSnapshot"/> 完全一致：
///   <see cref="JudgeMs"/> / <see cref="VisualMs"/> —— 判定·感知轴（扣校准延迟），当前恒等；
///   <see cref="RawTimelineMs"/> —— 原始时间轴（sequencer 的时间域）；
///   <see cref="AudioMs"/> —— 音频回调渲染钟。
/// 预卷期间三者均为负值，**不钳制**。
/// </summary>
[GlobalClass]
public partial class PlaybackPosition : RefCounted
{
	[Export] public double JudgeMs;        // 判定·感知轴（扣校准延迟）
	[Export] public double VisualMs;       // 与 JudgeMs 同值（用途可读性）
	[Export] public double RawTimelineMs;  // 原始时间轴（sequencer 的时间域）
	[Export] public double AudioMs;        // 音频回调渲染钟
	[Export] public bool IsPreRoll;        // 是否处于预卷（负时间轴）
}

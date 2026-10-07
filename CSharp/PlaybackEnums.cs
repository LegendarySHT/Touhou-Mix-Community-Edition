// ============================================================================
// 播放器意图 API 重构 · 阶段 0（只加不改）
//
// 本文件只新增枚举，不修改任何既有类型的成员。枚举成员与取值**严格**按设计文档
// `Doc/architecture/player_intent_api.md` §3.2 定义（顺序即数值，不可重排）。
//
// 【为什么是顶层枚举而不是嵌套在播放器类里】
//   GDScript 侧不直接读这些枚举：`PlaybackSnapshot` / `PlaybackPosition` 的字段一律是
//   **int**（文档 §3.2 的字段类型就是 int），GDScript 用自己在 `PlaybackDisplay.gd`
//   镜像的同序枚举（文档 §5.2）比较。这样跨语言不依赖任何枚举名字解析，
//   数值即是契约（与 MeltySynthPlayer.DEVICE_LOST_REASON_DEVICE_LOST 的既有做法一致）。
//
// 【阶段 0 谁在用】
//   只有 `PlaybackSnapshot.InterruptReason` / `DeviceState` / `Phase` 的写入方
//   （MeltySynthPlayer.GetPlaybackSnapshot）在用。`SessionKind` / `PlaybackStartMode`
//   在阶段 0 尚无生产者（会话装配在阶段 2 才引入），此处先按文档落地类型，
//   避免阶段 2 再动"类型定义"这一层。
// ============================================================================

/// <summary>
/// 播放阶段（唯一权威；阶段 0 由既有状态**推导**，阶段 2 起改为状态机字段）。
/// </summary>
public enum PlaybackPhase
{
	Idle = 0,        // 无曲目、无会话
	Preparing = 1,   // 会话已装配、文件已载入，尚未在时间轴上（offset==0 且未起播）
	PreRolling = 2,  // 负时间轴倒计时；sequencer 刻意停着，设备刻意停着
	Playing = 3,     // sequencer 运行中、设备运行中
	Paused = 4,      // sequencer 停着（位置保留）、设备已 Stop
	Ended = 5,       // 自然曲终、非循环会话且未起播；位置停在曲尾
	Stopped = 6,     // 显式结束；位置归 0
}

/// <summary>
/// 会话类型（决定曲终行为 + 是否落盘）。
/// </summary>
public enum SessionKind
{
	Performance = 0,  // 打歌一局：曲终即停，交给结算；不落盘；不文件级循环
	Preview = 1,      // 音轨试听：文件级循环；不落盘
	PlayerPage = 2,   // 播放器页：文件级循环 + 落盘 + 列表可推进
}

/// <summary>
/// 起始方式（替代"seek 负数"这个隐式协议）。
/// </summary>
public enum PlaybackStartMode
{
	PreRollFromNoteFall = 0,  // 由 C# 用 [Generator] note_fall_time 自行算预卷时长
	PreRollMs = 1,            // 显式预卷毫秒（负值）；仅调试/测试用
	AtCurrentOffset = 2,      // 从当前位置开始；位置未知则从 0
	AtMs = 3,                 // 从指定非负位置开始
	DeferToCaller = 4,        // 只装配到 Preparing，由调用方随后显式下发起始意图
}

/// <summary>
/// 音频设备状态（独立于传输状态）。阶段 0 由既有桥状态推导：
/// 桥不存在 → Absent；最近一次 Play() 起播失败 → StartFailed；
/// 设备在跑 → Running；否则 Stopped。
/// </summary>
public enum AudioDeviceState
{
	Absent = 0,      // 桥尚未创建
	Stopped = 1,     // 桥存在，ma_device 已 Stop（正常：暂停/预卷）
	Running = 2,     // ma_device 运行中
	StartFailed = 3, // 最近一次 ma_bridge_start 失败 → 流已失效，只有整桥重建能救
}

/// <summary>
/// 打断原因（由播放器判定并广播）。
/// 阶段 0 尚无"当前打断原因"的存储字段（打断决策收归 C# 是阶段 1），
/// 故快照里只能从 `AudioStartFailed` 推断出 <see cref="DeviceLost"/>，其余一律 None。
/// </summary>
public enum PlaybackInterruptReason
{
	None = 0,
	AudioFocusLoss = 1,         // 焦点丢失（来电/他人播放）→ 播放器已自行暂停
	DeviceLost = 2,             // 音频钟停滞且未到曲终 → 播放器已自行尝试恢复
	AppBackgrounded = 3,        // 应用进后台
	OutputEndpointChanged = 4,  // Windows 默认输出端点改变
}

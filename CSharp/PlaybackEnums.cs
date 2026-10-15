/// <summary>
/// 播放阶段（唯一权威；阶段 0 由既有状态**推导**，阶段 2 起改为状态机字段）。
/// 【预卷去负化】原 PreRolling（负时间轴倒计时）已删除：开局预卷改为 UI 侧主线程
/// 倒计时（PlayView），到期显式起播；C# 侧预卷等待期表现为"未起播的 Preparing"。
/// 数值因此重排（Idle=0 … Stopped=5），GDScript 镜像 PlaybackTypes.Phase 同步。
/// </summary>
public enum PlaybackPhase
{
	Idle = 0,        // 无曲目、无会话
	Preparing = 1,   // 会话已装配、文件已载入，尚未起播
	Playing = 2,     // sequencer 运行中、设备运行中
	Paused = 3,      // sequencer 停着（位置保留）、设备已 Stop
	Ended = 4,       // 自然曲终、非循环会话且未起播；位置停在曲尾
	Stopped = 5,     // 显式结束；位置归 0
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
/// 页面侧统一换曲入口 <see cref="MeltySynthPlayer.play_song"/> 的会话模式。
/// 【前台路径统一】TrackView（Preview）/ PlayView（Performance）原先各自在 GDScript 侧
/// 编排"load_midi 三步壳 + start_preview/start_performance + 起播"，与 C# 内部
/// LoadAndPlayKey 是两套不同源的实现（复制差异已造成 5 个跨曲残留 bug）。现收敛为：
/// 页面只声明"播这首、什么模式、要不要保持进度"，载入/配置/起播/会话装配全在 C#。
/// </summary>
public enum SongMode
{
	Playlist = 0,     // 播放器页列表换曲：会话由调用方装配（ensure_user_playlist 等），入口不碰
	Preview = 1,      // TrackView 试听：单曲槽 + 文件级循环 + 起播
	Performance = 2,  // PlayView 打歌：单曲槽 + 不循环 + 只装配不起播（DeferToCaller，
	                  // 起播由预卷倒计时到期显式调 play() 负责）
}

/// <summary>
/// 起始方式（替代"seek 负数"这个隐式协议）。
/// 【预卷去负化】负 seek 已从 C# 移除，开局预卷由 UI 侧倒计时 + 到期显式起播完成；
/// 前两个 PreRoll* 值暂无生产者（阶段 2 引入显式起始 API 时按新架构重新设计），
/// 此处保留占位以避免阶段 2 再动类型层。
/// </summary>
public enum PlaybackStartMode
{
	PreRollFromNoteFall = 0,  // 【暂无生产者】预卷时长由 UI 侧倒计时管理（原 C# 自行计算已移除）
	PreRollMs = 1,            // 【暂无生产者】显式预卷毫秒；仅调试/测试用
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

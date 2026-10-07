## 播放相关的枚举与常量（供 UI 引用；真值在 C# MeltySynth）
## 用法：PlaybackTypes.RepeatMode.REPEAT_ALL / PlaybackTypes.MIDI_VOLUME_GAIN
##
## 【本文件 vs 邻近文件的分工】
##   - `PlaybackTypes`（本文件）：播放相关的**类型/枚举/常量**
##   - `PlayerSettings`：播放相关**配置键 → 如何下发给播放器**的声明表
##   - `PlaybackDisplay`：GDScript 侧门面（转发 C# 信号、按需读回快照）
class_name PlaybackTypes
extends RefCounted

## 播放模式（数值必须与 CSharp/MidiCore.cs 的 REPEAT_* 对齐）
enum RepeatMode {
	SEQUENTIAL = 0,
	REPEAT_ALL = 1,
	REPEAT_ONE = 2,
	SHUFFLE = 3,
}

## 播放阶段（数值必须与 CSharp/PlaybackEnums.cs 的 PlaybackPhase 严格同序）
## 快照字段 `Phase` 是 int，GDScript 用本枚举按数值比较，不依赖跨语言枚举名解析。
enum Phase {
	IDLE = 0,        ## 无曲目、无会话
	PREPARING = 1,   ## 会话已装配、文件已载入，尚未在时间轴上
	PRE_ROLLING = 2, ## 负时间轴倒计时；sequencer 与设备都刻意停着
	PLAYING = 3,     ## sequencer 运行中、设备运行中
	PAUSED = 4,      ## sequencer 停着（位置保留）、设备已 Stop
	ENDED = 5,       ## 自然曲终
	STOPPED = 6,     ## 显式结束
}

## 音频设备状态（与 CSharp/PlaybackEnums.cs 的 AudioDeviceState 严格同序）
## 独立于播放阶段：正是"在播但设备已失效"这种组合需要被看见，故单列。
enum DeviceState {
	ABSENT = 0,       ## 桥尚未创建
	STOPPED = 1,      ## 桥存在，ma_device 已 Stop（正常：暂停/预卷）
	RUNNING = 2,      ## ma_device 运行中
	START_FAILED = 3, ## 最近一次起播失败 → 流已失效，只有整桥重建能救
}

## 打断原因（与 CSharp/PlaybackEnums.cs 的 PlaybackInterruptReason 严格同序）
enum InterruptReason {
	NONE = 0,
	AUDIO_FOCUS_LOSS = 1,        ## 焦点丢失（来电/他人播放）
	DEVICE_LOST = 2,             ## 音频钟停滞且未到曲终
	APP_BACKGROUNDED = 3,        ## 应用进后台
	OUTPUT_ENDPOINT_CHANGED = 4, ## Windows 默认输出端点改变
}

## MIDI 主音量映射系数：UI 线性值(0~1) × 本系数 = 后端线性增益。
## 8.0 ⇒ 50% = +6dB、100% = +12dB（合成器输出响度天然低于成品人声母带，需放大上限才能与人声拉平）。
const MIDI_VOLUME_GAIN: float = 8.0

## 音量下限(dB)：linear_to_db(0) 为 -inf，统一钳到此值表示静音
const MIN_VOLUME_DB: float = -80.0

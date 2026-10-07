## 播放相关的枚举与常量（供 UI 引用；真值在 C# MeltySynth）
## 用法：PlaybackTypes.RepeatMode.REPEAT_ALL / PlaybackTypes.MIDI_VOLUME_GAIN
class_name PlaybackTypes
extends RefCounted

## 播放模式（数值必须与 CSharp/MidiCore.cs 的 REPEAT_* 对齐）
enum RepeatMode {
	SEQUENTIAL = 0,
	REPEAT_ALL = 1,
	REPEAT_ONE = 2,
	SHUFFLE = 3,
}

## MIDI 主音量映射系数：UI 线性值(0~1) × 本系数 = 后端线性增益。
## 8.0 ⇒ 50% = +6dB、100% = +12dB（合成器输出响度天然低于成品人声母带，需放大上限才能与人声拉平）。
const MIDI_VOLUME_GAIN: float = 8.0

## 音量下限(dB)：linear_to_db(0) 为 -inf，统一钳到此值表示静音
const MIN_VOLUME_DB: float = -80.0

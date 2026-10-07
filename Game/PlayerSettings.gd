## 播放器设置表（声明式）—— 播放器相关配置的**唯一清单**。
##
## 背景：此前"哪些配置属于播放器、改了要怎么下发"这件事散在三处 ——
##   1. `Main._on_config_changed` 里一个手工维护的 switch，逐键 `elif key == "..."`；
##      新增一个播放器设置若忘记回来加分支，就是"改了设置不生效、要重启"
##      （`audio_playback_delay` 当年就踩过这个坑，见 Main.gd 里那段注释）。
##   2. `PlaybackDisplay` 内部各自内联读配置 + 自己决定要不要下发。
##   3. `SettingsMapper` / `SettingGroupsData` 管设置页 UI（那是另一件事，见下）。
##
## 本表**只回答一个问题**：这个配置键改了之后，播放器要不要动作、动作是什么？
## 它**不管**设置页的显示名/控件类型/分组 —— 那是 `SettingsMapper` + `SettingGroupsData` 的职责。
## 两者刻意分开，避免出现第五份清单。
##
## 默认值不写在这里：`config.ini` 是默认值的权威来源（`ConfigManager.merge_with_defaults`
## 保证默认层里有的键在读取时一定存在），故代码侧一律不再写内联回退。
class_name PlayerSettings
extends RefCounted

## 标识名（仅可读性用）→ {section, apply, note}
##
## apply 取值：
##   push_global      → 推全局播放配置（音量/系统时钟/同步阈值）并重载播放器页音量
##   delay_if_active  → 仅在"该键是当前生效的延迟预设"时下发（另一套预设的改动不影响当前输出）
##   polyphony        → 置复音数 + 保位置重载音源（复音数是合成器创建期参数）
##   soundfont        → 切换音源
##   preroll          → 影响预卷时长/下落窗口：由消费方（FlowArea）在解析后推给 C#
##
## 未列入本表的配置键 = 改了对播放器无影响（例：`performing_mode` 由 PlayView 自己读，
## 不进播放器；`vibrate_on_touch` 是判定反馈）。这不是遗漏，是有意为之。
const ENTRIES: Dictionary = {
	"default_midi_volume": {
		"section": "Gameplay", "apply": "push_global",
		"note": "全局默认 MIDI 音量（0-100 或 0-1，C# 侧兼容两种历史存值）",
	},
	"default_vocal_volume": {
		"section": "Gameplay", "apply": "push_global",
		"note": "全局默认人声音量（0-100 百分数或 dB，C# 侧兼容）",
	},
	"audio_sync_threshold": {
		"section": "Gameplay", "apply": "push_global",
		"note": "人声同步阈值（毫秒）",
	},
	"use_system_stopwatch": {
		"section": "Playback", "apply": "push_global",
		"note": "sequencer 系统时钟模式：开启后事件派发以系统墙钟为真源",
	},
	"audio_playback_delay": {
		"section": "Gameplay", "apply": "delay_if_active",
		"note": "普通输出的校准延迟预设",
	},
	"audio_playback_delay_bt": {
		"section": "Gameplay", "apply": "delay_if_active",
		"note": "蓝牙输出的校准延迟预设（改动只在当前是蓝牙输出时生效）",
	},
	"max_polyphony": {
		"section": "Playback", "apply": "polyphony",
		"note": "最大复音数（合成器创建期参数，改后需保位置重载音源）",
	},
	"soundfont_file": {
		"section": "Gameplay", "apply": "soundfont",
		"note": "音源文件名",
	},
	"note_fall_time": {
		"section": "Generator", "apply": "preroll",
		"note": "音符下落时间（秒）——决定音符生成窗口与开局预卷时长",
	},
}

## 该配置键是否影响播放器
static func affects(key: String) -> bool:
	return ENTRIES.has(key)

## 取条目（不存在返回空字典）
static func entry(key: String) -> Dictionary:
	return ENTRIES.get(key, {})

## 该键是否属于某个 section（诊断/校验用）
static func section_of(key: String) -> String:
	var e := entry(key)
	return str(e.get("section", ""))

## 列出全部受管键（诊断/校验用）
static func managed_keys() -> Array:
	return ENTRIES.keys()

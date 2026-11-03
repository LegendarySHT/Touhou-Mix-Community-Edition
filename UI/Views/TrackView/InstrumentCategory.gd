extends RefCounted
class_name InstrumentCategory

# 轨道初始乐器类型 → 16 个乐器大类。
# 大类顺序同时就是后续乐器图标 atlas 的排列顺序（与用户约定一致）：
# 1.Piano 2.Chromatic Percussion 3.Organ 4.Guitar 5.Bass 6.Strings
# 7.Ensemble 8.Brass 9.Reed 10.Pipe 11.Synth Lead 12.Synth Pad
# 13.Synth Effects 14.Ethnic 15.Percussive 16.Sound Effects
const CATEGORY_NAMES: Array[String] = [
	"Piano",
	"Chromatic Percussion",
	"Organ",
	"Guitar",
	"Bass",
	"Strings",
	"Ensemble",
	"Brass",
	"Reed",
	"Pipe",
	"Synth Lead",
	"Synth Pad",
	"Synth Effects",
	"Ethnic",
	"Percussive",
	"Sound Effects",
]

# 图标 atlas 规格（整图边长 / 每行数量 / 单格边长）
const ATLAS_SIZE: int = 320
const COLUMNS: int = 4
const CATEGORY_COUNT: int = 16

# GM/GS/GM2 鼓组 bank（包括 GeneralUser-GS 的 B120 与 B128）统一归入打击乐大类。
# B120 的 kit 若按 program 分类，会被错误分散到 Piano、Organ 等普通乐器类别。
const DRUM_BANK_MIN: int = 120
const DRUM_CATEGORY: int = 14

# 由泛用 MIDI（GM）的 bank / program 归入 16 大类，返回大类索引 0-15。
# program 为 0 基（0=Acoustic Grand Piano），每 8 个程序一组对应一个大类。
static func get_category(bank: int, program: int) -> int:
	if is_drum_bank(bank):
		return DRUM_CATEGORY
	@warning_ignore("integer_division")
	var idx: int = int(program) / 8
	return clampi(idx, 0, CATEGORY_COUNT - 1)

## 判断 SoundFont bank 是否属于 GM/GS/GM2 鼓组 bank。
static func is_drum_bank(bank: int) -> bool:
	return bank >= DRUM_BANK_MIN

# 由大类索引计算图标 atlas 区域（坐标）。
# 单格边长由 atlas 规格推导：ATLAS_SIZE / COLUMNS。
static func get_icon_region(category: int) -> Rect2:
	var c: int = clampi(category, 0, CATEGORY_COUNT - 1)
	@warning_ignore("integer_division")
	var col: int = c % COLUMNS
	@warning_ignore("integer_division")
	var row: int = c / COLUMNS
	@warning_ignore("integer_division")
	var cell: int = ATLAS_SIZE / COLUMNS
	return Rect2(col * cell, row * cell, cell, cell)

# 快捷获取大类名称（调试/日志用）
static func get_category_name(category: int) -> String:
	var c: int = clampi(category, 0, CATEGORY_COUNT - 1)
	return CATEGORY_NAMES[c]

# 缓存 display 名解析正则（避免每次重建）
static var _display_regex: RegEx = null

## 解析 "乐器名 (BX:PY)" 显示名，返回 {name, bank, program}
## 显示名 → 解析结果。RegEx 搜索是这条路径的唯一开销，而同一批显示名每条轨道都会重解析一遍
## （130+ 项 × N 条轨道）。显示名集合只在换音源时变，条目量级很小，缓存只增不减。
## 返回的是共享实例，调用方只读不写（当前全部调用点都是 get）。
static var _display_cache: Dictionary = {}

static func parse_display_name(display: String) -> Dictionary:
	if _display_cache.has(display):
		return _display_cache[display] as Dictionary
	if _display_regex == null:
		_display_regex = RegEx.create_from_string(r"^(.*)\(B(\d+):P(\d+)\)$")
	var result := {}
	var m := _display_regex.search(display)
	if m:
		result = {
			"name": m.get_string(1).strip_edges(),
			"bank": int(m.get_string(2)),
			"program": int(m.get_string(3)),
		}
	_display_cache[display] = result
	return result

# 从显示名直接查大类索引（解析失败归为 Piano）
static func get_category_from_display(display: String) -> int:
	var info := parse_display_name(display)
	return get_category(info.get("bank", 0), info.get("program", 0))

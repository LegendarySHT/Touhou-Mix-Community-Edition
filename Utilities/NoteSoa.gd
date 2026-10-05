## SOA（Structure of Arrays）只读访问器
## 包装 C# MidiParserNative 产出的 6 个并行紧凑数组，作为音符数据的唯一事实来源。
## 替代 Array[NoteEvent] 的对象形态：22w 音符 = 22w 个 NoteEvent → 6 个 PackedInt32Array，
## 消除 Android ARM 上 RefCounted + StringName 引用计数开销（Easy 大谱面闪退/高内存的根源）。
## 对象仅在下游"确实需要 NoteEvent"的边界点按需重建（note(i) / build_from_indices），
## 而非一次性批量 materialize。访问器只在主线程使用；不创建 RefCounted 到 worker。
class_name NoteSoa
extends RefCounted

## 6 个并行数组（索引语义一致，长度相等）
var _pitches: PackedInt32Array
var _velocities: PackedInt32Array
var _start_ticks: PackedInt32Array
var _durations: PackedInt32Array
var _track_indices: PackedInt32Array
var _channels: PackedInt32Array

## (track,channel) 分组（C# worker 一次性统计后经 soa 传入，供 grouped_indices 快速重建）
var _group_keys: Variant = null       # 组键 track<<8|channel，按首次出现顺序
var _group_offsets: Variant = null    # 前缀和，len=组数+1（末尾哨兵）
var _group_indices: Variant = null    # 扁平 SOA 索引

## 时间换算（可选）：tick → ms 依赖 bpm_timeline + timebase；未提供时仅能取 tick
var _timebase: int = 480
var _bpm_lookup: Array = []   # [[tick, bpm, cumulative_ms], ...]，按 tick 升序

static func from_result(parse_result: Dictionary) -> NoteSoa:
	## 从 load_and_parse_midi 结果构建（优先读 "soa" 字典，无则回退单数组空）。
	var instance := NoteSoa.new()
	instance._init_arrays(parse_result.get("soa", {}), parse_result.get("timebase", 480), parse_result.get("bpm_timeline", []))
	return instance

func _init_arrays(arrays: Dictionary, timebase: int, bpm_timeline: Array) -> void:
	if arrays.has("pitches"):
		_pitches = arrays.get("pitches", PackedInt32Array())
		_velocities = arrays.get("velocities", PackedInt32Array())
		_start_ticks = arrays.get("start_ticks", PackedInt32Array())
		_durations = arrays.get("durations", PackedInt32Array())
		_track_indices = arrays.get("track_indices", PackedInt32Array())
		_channels = arrays.get("channels", PackedInt32Array())
	_group_keys = arrays.get("track_channel_groups_keys", null)
	_group_offsets = arrays.get("track_channel_groups_offsets", null)
	_group_indices = arrays.get("track_channel_groups_indices", null)
	_timebase = timebase if timebase > 0 else 480
	_prebuild_bpm_lookup(bpm_timeline)

func _prebuild_bpm_lookup(bpm_timeline: Array) -> void:
	_bpm_lookup.clear()
	if _timebase <= 0:
		_timebase = 480
	var cum: float = 0.0
	for i in range(bpm_timeline.size()):
		var e = bpm_timeline[i]
		var tk: float = float(e.get("tick", 0.0))
		var bpm: float = float(e.get("bpm", 120.0))
		_bpm_lookup.append([tk, bpm, cum])
		if i + 1 < bpm_timeline.size():
			var nt: float = float(bpm_timeline[i + 1].get("tick", tk))
			var ms_per_tick: float = (60000.0 / bpm) / float(_timebase)
			cum += (nt - tk) * ms_per_tick

## ===================== 基础只读访问 =====================

func size() -> int:
	return _pitches.size()

## 精确字节：6 个紧凑数组的底层字节数之和（不含访问器对象本身）
func size_bytes() -> int:
	return _pitches.to_byte_array().size() + _velocities.to_byte_array().size() \
		+ _start_ticks.to_byte_array().size() + _durations.to_byte_array().size() \
		+ _track_indices.to_byte_array().size() + _channels.to_byte_array().size()

## 暴露 6 个底层并行数组（只读共享，COW 零拷贝），供 C# KeySequenceCore 按启用索引装配输入
## 顺序：{pitches, velocities, start_ticks, durations, track_indices, channels}
func get_raw_arrays() -> Array:
	return [_pitches, _velocities, _start_ticks, _durations, _track_indices, _channels]

func pitch(i: int) -> int:
	return _pitches[i]

func velocity(i: int) -> int:
	return _velocities[i]

func track(i: int) -> int:
	return _track_indices[i]

func channel(i: int) -> int:
	return _channels[i]

## 开始 tick（C# 已按 start_ticks 升序，数组即有序）
func start_tick(i: int) -> float:
	return float(_start_ticks[i])

func duration(i: int) -> float:
	return float(_durations[i])

func end_tick(i: int) -> float:
	return float(_start_ticks[i] + _durations[i])

## 第一个 start_tick >= tick 的音符索引（_start_ticks 已升序，二分定位窗口起点）
func first_index_from_start_tick(tick: float) -> int:
	if _start_ticks.is_empty():
		return 0
	return _start_ticks.bsearch(int(tick), true)

## 全曲最大音符时长（tick）。窗口起点需回溯这么多，才不会漏掉"起始在窗口之前、
## 尾部仍落在窗口内"的长音符
func max_duration_ticks() -> int:
	var m := 0
	for i in _durations.size():
		var d := _durations[i]
		if d > m:
			m = d
	return m

func start_tick_ms(i: int) -> float:
	return _tick_to_ms(float(_start_ticks[i]))

func end_tick_ms(i: int) -> float:
	return _tick_to_ms(float(_start_ticks[i] + _durations[i]))

## ms → tick：与 start_tick_ms / end_tick_ms 共用同一 _bpm_lookup，保证互为逆映射
func ms_to_tick(ms: float) -> float:
	if _bpm_lookup.is_empty():
		return ms * float(_timebase) / (60000.0 / 120.0)
	var n: int = _bpm_lookup.size()
	var first = _bpm_lookup[0]
	if ms <= first[2]:
		return first[0] + (ms - first[2]) * float(_timebase) * first[1] / 60000.0
	var lo: int = 0
	var hi: int = n - 1
	while lo < hi:
		var mid: int = (lo + hi + 1) >> 1
		if _bpm_lookup[mid][2] <= ms:
			lo = mid
		else:
			hi = mid - 1
	var entry = _bpm_lookup[lo]
	return entry[0] + (ms - entry[2]) * float(_timebase) * entry[1] / 60000.0

## ===================== tick → ms（BPM 感知） =====================

func _tick_to_ms(tick: float) -> float:
	if _bpm_lookup.is_empty():
		return (tick / float(_timebase)) * (60000.0 / 120.0)
	var n: int = _bpm_lookup.size()
	var first = _bpm_lookup[0]
	if tick <= first[0]:
		return first[2] + (tick - first[0]) * ((60000.0 / first[1]) / float(_timebase))
	var last = _bpm_lookup[n - 1]
	if tick >= last[0]:
		return last[2] + (tick - last[0]) * ((60000.0 / last[1]) / float(_timebase))
	var lo: int = 0
	var hi: int = n - 1
	while lo < hi:
		var mid: int = (lo + hi + 1) >> 1
		if _bpm_lookup[mid][0] <= tick:
			lo = mid
		else:
			hi = mid - 1
	var entry = _bpm_lookup[lo]
	return entry[2] + (tick - entry[0]) * ((60000.0 / entry[1]) / float(_timebase))

## ===================== 边界重建（按需建对象，不批量） =====================

## 惰性重建单个 NoteEvent（仅明确的边界消费点使用，如 ManualNoteOffScheduler 触发）
func note(i: int) -> MidiParser.NoteEvent:
	return MidiParser.NoteEvent.new(
		pitch(i), velocity(i),
		start_tick(i), duration(i),
		track(i), channel(i)
	)

## 按给定索引集合批量重建 NoteEvent 数组（索引须指向本 SOA，保持原有顺序）
## 供 PlayView/MidiListItem 构建"启用 (track,channel) 子集"后再喂给 generate_keys
func build_from_indices(indices: Array) -> Array:
	var notes: Array = []
	notes.resize(indices.size())
	for k in range(indices.size()):
		notes[k] = note(indices[k])
	return notes

## ===================== 分组（索引化 runtime_track_channel_notes） =====================

## 构建 { "track:channel": PackedInt32Array（SOA 索引）}，取代旧的 object 分组。
## 数组保持 start_tick 升序（C# 预统计按 SOA 索引递增填充，各分组内有序）。
## 主路径：复用 C# worker 一次性算好的分组（_group_*），仅在主线程做末次容器重建，
## 不再逐元素 COW 写回 / 逐键字符串哈希（22w 音符下旧实现可慢到 1s 级）。
## 兜底：_group_* 缺失（旧缓存 / 非 C# 源）时走两遍式（先统计计数，预分配后索引写原地填充）。
func grouped_indices() -> Dictionary:
	if _group_keys != null and _group_keys.size() > 0 \
			and _group_offsets != null and _group_indices != null:
		var fast_groups: Dictionary = {}
		var gcount: int = _group_keys.size()
		for g in range(gcount):
			var key := "%d:%d" % [_group_keys[g] >> 8, _group_keys[g] & 0xFF]
			var start: int = _group_offsets[g]
			var end: int = _group_offsets[g + 1]
			var arr := PackedInt32Array()
			arr.resize(end - start)
			for w in range(start, end):
				arr[w - start] = _group_indices[w]
			fast_groups[key] = arr
		return fast_groups

	var total := size()
	# 兜底：第一遍统计每 key 元素个数 + 记录 key 顺序（纯整数累加，无 COW）
	var count: Dictionary = {}
	var keys: Array = []
	for i in range(total):
		var key := "%d:%d" % [track(i), channel(i)]
		if count.has(key):
			count[key] += 1
		else:
			count[key] = 1
			keys.append(key)
	# 预分配定长数组并记录写出游标
	var groups: Dictionary = {}
	var cursors: Dictionary = {}
	for key in keys:
		var arr := PackedInt32Array()
		arr.resize(count[key])
		groups[key] = arr
		cursors[key] = 0
	# 第二遍：索引写原地填充（不整体写回字典）
	for i in range(total):
		var key := "%d:%d" % [track(i), channel(i)]
		var arr: PackedInt32Array = groups[key]
		arr[cursors[key]] = i
		cursors[key] += 1
	return groups

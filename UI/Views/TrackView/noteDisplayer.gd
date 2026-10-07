extends HBoxContainer

class_name NoteDisplayer

@onready var flow_area: Panel = $noteFlowArea/canvas
@onready var note_count_passed: Label = $noteTotal/VBoxC/passedNote
@onready var note_count_total: Label = $noteTotal/VBoxC/totalNote

var area_height: float = 160
var area_width: float = 0
var lane_count: int = 12
var scale_factor: float = 0.5

# 每个车道的高度
var lane_height: float = 0

# 活动音符状态列表（由 master 统一创建/销毁，children 经 _bucket_active 共享读取）
var active_notes: Array[NoteState] = []

# 按 (track, channel) 分组的音轨容器（master 专用，懒生成按 bucket 独立推进）
var buckets: Array[TrackNoteBucket] = []

# 是否是主显示器（唯一承载 _process 计时/生命周期/派发）
var is_master: bool = false

# 子 displayer 指向的 master 引用（绘制时取共享 ct）
var _master: NoteDisplayer = null

# MIDI 最大 end_tick（所有 bucket 中最后一个音符的结束 tick）
# 用于检测 ct 异常：循环播放时 Sequencer.Position 可能继续增长而不跳回 0，
# 导致 ct 超过所有音符的 end_tick，active_notes 被清空。此时跳过移除操作等待循环恢复
# 类型为 float 与 NoteState.start_tick/end_tick 对齐
var _max_end_tick: float = 0.0
# 上一帧的 ct，用于检测 ct 回退（循环跳回 0）时重置 cursor
var _last_ct: float = -1.0

# track view节点
var master_node: Node = null

var note_color: Color

# 批量绘制节点（单 Node2D 替代 N 个 ColorRect）
var _draw_node: NoteDrawNode = null

# master 专用：多键 "t:ch" → 活动音符数组（含禁用 bucket，供子 displayer 共享读取）
var _bucket_active: Dictionary = {}
# master 专用：多键 "t:ch" → 已通过计数（推进子 displayer 计数标签）
var _bucket_passed: Dictionary = {}
# master 专用：多键 "t:ch" → 子 displayer 引用（更新计数 + 触发重绘）
var _child_by_key: Dictionary = {}
# master 专用：多键 "t:ch" → bucket 对象（读取 total 用）
var _bucket_by_key: Dictionary = {}
# 当前播放 tick（master 每帧计算一次，children 绘制时读取）
var _computed_ct: float = 0.0

# NoteState 存 tick 域数据（start/end/pitch）+ 预缓存两套静态矩形（w/h/y，x 每帧更新）；
# NoteState.bucket 引用 master 的 bucket 对象（记录色相与 is_enabled）
class TrackNoteBucket:
	extends RefCounted
	var track_index: int = 0
	var channel: int = 0
	var hue: float = 0.0              # 颜色色相（由 track_index 查 colors_set 一次）
	var color: Color = Color.WHITE    # 由 hue 预计算的绘制颜色（避免逐音符 Color.from_hsv）
	## 音符容器：PackedInt32Array（notes_soa 索引），显示路径经 soa 只读直引，
	## 不物化 22w NoteEvent。soa 为 null 表示该MIDI 未解析出音符，桶内为空。
	var notes: Variant = []
	var soa: NoteSoa = null          # 共享 SOA 引用（索引形态时只读直引；_draw 不持有全量对象）
	var cursor: int = 0               # 懒生成游标（指向下一个待生成的音符）
	var is_enabled: bool = true       # master 用：该音轨是否启用

	## 元素统一只读接口：e 为 notes[cursor]（SOA 索引 int）
	func n_start(e: Variant) -> float:
		return soa.start_tick(e) if soa != null else 0.0
	func n_end(e: Variant) -> float:
		return soa.end_tick(e) if soa != null else 0.0
	func n_pitch(e: Variant) -> int:
		return soa.pitch(e) if soa != null else 0
	func n_count() -> int:
		return notes.size()

class NoteState:
	extends RefCounted
	var pitch: int = 0
	var start_tick: float = 0.0
	var end_tick: float = 0.0
	var bucket: TrackNoteBucket = null  # 反向引用所在 bucket（记录色相与 is_enabled）
	var is_passed: bool = false
	# 预缓存的绘制矩形（w/h/y 在创建时按各自几何一次算定，每帧仅更新 position.x）：
	# rect_master = 主音轨几何（lane 数/高度）；rect_child = 该音符所在普通音轨几何
	var rect_master: Rect2 = Rect2()
	var rect_child: Rect2 = Rect2()

# 单 Node2D 批量绘制所有音符
# 每帧仅更新各音符 rect 的 position.x（w/h/y 已在创建时预缓存），ct 来自 master（子 displayer 读 _master._computed_ct）
class NoteDrawNode:
	extends Node2D
	# 共享数组引用（master=active_notes；子 displayer=master._bucket_active[key]，只做原地修改）
	var notes: Array = []
	var note_displayer: NoteDisplayer = null
	# 单色模式：子 displayer 的 note_color 已设置，所有音符同色，_draw 直接读 single_color
	var single_color: Color = Color.WHITE
	var use_single_color: bool = false

	func _draw() -> void:
		var d := note_displayer
		if d == null:
			return
		var ct := d._computed_ct
		if d._master != null:
			ct = d._master._computed_ct
		var aw := d.area_width
		var sw := d.scale_factor
		if use_single_color:
			# 普通音轨：用预缓存 rect_child（按自身几何算定的 w/h/y），每帧仅更新 x
			for n in notes:
				n.rect_child.position.x = aw - (n.end_tick - ct) * sw
				if n.rect_child.position.x + n.rect_child.size.x < 0.0 or n.rect_child.position.x > aw:
					continue  # 横向可见性剔除
				draw_rect(n.rect_child, single_color)
		else:
			# 主音轨：用预缓存 rect_master
			for n in notes:
				n.rect_master.position.x = aw - (n.end_tick - ct) * sw
				if n.rect_master.position.x + n.rect_master.size.x < 0.0 or n.rect_master.position.x > aw:
					continue  # 横向可见性剔除
				draw_rect(n.rect_master, n.bucket.color)

func _ready():
	if size.y > 250:
		lane_count = 24
	_on_flow_area_resized()

	flow_area.resized.connect(_on_flow_area_resized)

	_draw_node = NoteDrawNode.new()
	_draw_node.name = "NoteDrawNode"
	_draw_node.notes = active_notes  # 共享数组引用，原地修改对 _draw 可见
	_draw_node.note_displayer = self
	flow_area.add_child(_draw_node)


func _exit_tree() -> void:
	# 清空音符状态引用（_draw_node 随父节点 queue_free 自动释放）
	active_notes.clear()
	for key in _bucket_active:
		(_bucket_active[key] as Array).clear()


func _on_flow_area_resized():
	area_height = flow_area.get_rect().size.y
	area_width = flow_area.get_rect().size.x
	lane_height = area_height / lane_count

	if _draw_node:
		# 尺寸变化后按归属重算已存在音符的矩形（master 重算 rect_master，child 重算 rect_child）
		if is_master:
			_refresh_note_rects(active_notes, false)
		else:
			_refresh_note_rects(_draw_node.notes, true)
		_draw_node.queue_redraw()

func update_color():
	if _draw_node == null:
		return
	# note_color 已设置（子 displayer）→ 单色模式；未设置（master）→ 多色模式（颜色由 bucket.color 实时读）
	if note_color != Color(0, 0, 0, 0):
		_draw_node.use_single_color = true
		_draw_node.single_color = note_color
	else:
		_draw_node.use_single_color = false
	_draw_node.queue_redraw()

func _process(_delta):
	# 仅 master 推进生命周期/计数/派发；子 displayer 完全不做 _process
	if not is_master:
		return
	if master_node == null or buckets.is_empty():
		return

	# total 不在视口内时仅跳过重绘，计数与生命周期照常推进
	# ScrollContainer 滚动使子节点滑出视口时，get_global_rect() 与视口无交集
	var on_screen: bool = flow_area.get_global_rect().intersects(get_viewport_rect())

	var midi_mgr = PlaybackDisplay.instance
	if midi_mgr == null or not midi_mgr.is_playing:
		# 不主动 set_process(false)：由 TrackView._set_note_displayers_process 统一管理启停
		return

	# 播放位置转换为 tick；ct 与音符的 start_tick/end_tick 在同一 tick 参考系
	# 一帧只计算一次，供所有子 displayer 绘制共享
	var delayed_ms: float = midi_mgr.get_position_ms()
	_computed_ct = midi_mgr.calculate_tick_from_position_with_bpm_timeline(delayed_ms, midi_mgr.midi_timebase)
	var ct := _computed_ct

	# ct 异常保护：循环播放时 Sequencer.Position 可能继续增长而不跳回 0，
	# 导致 ct 超过所有音符的 end_tick。此时不做移除操作，等待 TrackView 循环检测恢复
	# 同时清空活动音符，防止旧音符残留累积拖慢渲染
	if _max_end_tick > 0 and ct > _max_end_tick + area_width / scale_factor:
		_clear_all_notes()
		_last_ct = ct
		return

	# 检测 ct 回退（循环跳回 0 或 seek 回退）：重置所有 bucket cursor 和活动音符
	if _last_ct >= 0 and ct < _last_ct - area_width / scale_factor:
		_clear_all_notes()
		for b in buckets:
			b.cursor = 0
	_last_ct = ct

	# 提前计算视野边界
	var view_right_bound = ct + area_width / scale_factor

	# 按 bucket 懒生成：每 bucket 独立游标
	# 所有 bucket（含禁用）都生成到 _bucket_active（供子 displayer 绘制）；
	# 启用 bucket 额外进 active_notes（总览绘制 + master 计数）
	for b in buckets:
		while b.cursor < b.n_count() and b.n_start(b.notes[b.cursor]) < view_right_bound:
			_create_note(b.notes[b.cursor], b)
			b.cursor += 1

	# 生命周期：标记通过 + 移除已完成 + 推进 master/子 displayer 计数
	for key in _bucket_active:
		var arr: Array = _bucket_active[key]
		if arr.is_empty():
			continue
		var to_remove: Array[NoteState] = []
		for n in arr:
			# 已完全离开视野（右边缘越过 playhead）或完全滚出左侧（长音符提前出屏）即移除，
			# 缩小数组供后续 _draw 循环更短，计数已在 start_tick 行进时累计，提前移除不影响统计
			var note_w: float = (n.end_tick - n.start_tick) * scale_factor
			if note_w < 1.0:
				note_w = 1.0
			var off_left: float= (n.end_tick - ct) * scale_factor - note_w > area_width
			if n.end_tick < ct or off_left:
				to_remove.append(n)
				continue
			# 标记已通过的音符（ct > start_tick 避免 start_tick=0 首帧误计）
			if not n.is_passed and ct > n.start_tick:
				n.is_passed = true
				_bucket_passed[key] = _bucket_passed.get(key, 0) + 1
				if n.bucket.is_enabled:
					note_count_passed.text = str(int(note_count_passed.text) + 1)
				var child_candidate = _child_by_key.get(key)
				if is_instance_valid(child_candidate):
					(child_candidate as NoteDisplayer).note_count_passed.text = str(_bucket_passed[key])
		for n in to_remove:
			arr.erase(n)
			active_notes.erase(n)

	# 单帧一次重绘：master 自身 + 每个子 displayer（子绘制用自身几何，读共享 ct）
	if _draw_node and on_screen:
		_draw_node.queue_redraw()
	for key in _child_by_key.keys():
		var child_candidate = _child_by_key[key]
		if not is_instance_valid(child_candidate):
			_child_by_key.erase(key)   # 子 displayer 已随轨道行重建被释放
			continue
		var child: NoteDisplayer = child_candidate
		if child._draw_node and child._draw_node.is_visible_in_tree() \
				and child.flow_area.get_global_rect().intersects(child.get_viewport_rect()):
			child._draw_node.queue_redraw()

func _create_note(e: Variant, bucket: TrackNoteBucket):
	var state := NoteState.new()
	state.pitch = bucket.n_pitch(e)
	state.start_tick = bucket.n_start(e)
	state.end_tick = bucket.n_end(e)
	state.bucket = bucket
	state.is_passed = false
	var key := _key_str(bucket.track_index, bucket.channel)
	# 创建时一次性算定两套静态矩形（w/h/y），x 由 _draw 每帧更新
	state.rect_master = _build_note_rect(state, scale_factor, lane_height, lane_count)
	var child_candidate = _child_by_key.get(key)
	if is_instance_valid(child_candidate):
		var child := child_candidate as NoteDisplayer
		state.rect_child = _build_note_rect(state, child.scale_factor, child.lane_height, child.lane_count)
	if not _bucket_active.has(key):
		_bucket_active[key] = []
	_bucket_active[key].append(state)
	if bucket.is_enabled:
		active_notes.append(state)

# 按 displayer 几何算定音符静态矩形（w/h/y；x 留给 _draw 更新）。反转 lane_index 使高音在上、低音在下
func _build_note_rect(n: NoteState, sw: float, lh: float, lc: int) -> Rect2:
	var w := (n.end_tick - n.start_tick) * sw
	if w < 1.0:
		w = 1.0
	var lane_index := lc - 1 - ((n.pitch - 21) % lc)
	var h := lh * 0.8
	var y := (lh * lane_index) + (lh - h) * 0.5
	return Rect2(0.0, y, w, h)

# 几何变化时按归属重算已存在音符的矩形：is_child=false 重算 rect_master（主音轨），否则重算 rect_child
func _refresh_note_rects(arr: Array, is_child: bool) -> void:
	for n in arr:
		if is_child:
			n.rect_child = _build_note_rect(n, scale_factor, lane_height, lane_count)
		else:
			n.rect_master = _build_note_rect(n, scale_factor, lane_height, lane_count)

func _key_str(track: int, channel: int) -> String:
	return str(track) + ":" + str(channel)

func _clear_all_notes() -> void:
	active_notes.clear()
	for key in _bucket_active:
		(_bucket_active[key] as Array).clear()

## 初始化 displayer
## master: 传入所有 buckets，由 sync_from_midi_data 控制 bucket.is_enabled；统一创建 NoteState 并派发给子 displayer
## 子 displayer: 仅保留 bucket 引用，生命周期与计数由 master 统一推进，_process 关闭
func init_displayer_with_buckets(mn: Node, track_buckets: Array[TrackNoteBucket], max_end_tick: float = 0.0) -> void:
	master_node = mn
	buckets = track_buckets

	if not is_master:
		# 子 displayer 不参与推算，仅保留引用；共享数据由 register_child 建立
		_max_end_tick = max_end_tick
		set_process(false)
		return

	# master：清空全部状态（RefCounted 自动释放）
	active_notes.clear()
	_bucket_active.clear()
	_bucket_passed.clear()
	_child_by_key.clear()
	_bucket_by_key.clear()
	_max_end_tick = max_end_tick
	_computed_ct = 0.0
	_last_ct = -1.0

	for b in buckets:
		b.cursor = 0
		_bucket_by_key[_key_str(b.track_index, b.channel)] = b

	_compute_counts_from(0.0)

	if _draw_node:
		_draw_node.queue_redraw()

## 向 master 注册一个子 displayer（按 (track, channel) 绑定共享数据）
func register_child(child: NoteDisplayer, track_idx: int, channel: int) -> void:
	child._master = self
	var key := _key_str(track_idx, channel)
	if not _bucket_active.has(key):
		_bucket_active[key] = []
	child._draw_node.notes = _bucket_active[key]  # 共享引用，master 原地修改对 child 可见
	_child_by_key[key] = child

	# 兜底：若该 key 已有音符（极端时序），按 child 几何补齐 rect_child
	_refresh_note_rects(_bucket_active[key], true)

	var bucket := _bucket_by_key.get(key) as TrackNoteBucket
	if bucket:
		child.note_count_total.text = str(bucket.notes.size())
	child.note_count_passed.text = str(_bucket_passed.get(key, 0))

## 按给定 ct 重算 master 与各子 displayer 的计数（init / reset / sync 用）
func _compute_counts_from(ct: float) -> void:
	_bucket_passed.clear()
	var master_total := 0
	var master_passed := 0
	for b in buckets:
		var key := _key_str(b.track_index, b.channel)
		var passed := 0
		for n in b.notes:
			if b.n_start(n) < ct:
				passed += 1
			else:
				break  # bucket 内已排序，提前退出
		_bucket_passed[key] = passed
		if b.is_enabled:
			master_total += b.n_count()
			master_passed += passed
	for n in active_notes:
		if n.start_tick < ct:
			n.is_passed = true
	note_count_total.text = str(master_total)
	note_count_passed.text = str(master_passed)
	var invalid_children: Array = []
	for key in _child_by_key:
		var child_candidate = _child_by_key[key]
		if not is_instance_valid(child_candidate):
			invalid_children.append(key)
			continue
		var child: NoteDisplayer = child_candidate
		var bucket := _bucket_by_key.get(key) as TrackNoteBucket
		if bucket:
			child.note_count_total.text = str(bucket.notes.size())
		child.note_count_passed.text = str(_bucket_passed.get(key, 0))
	for key in invalid_children:
		_child_by_key.erase(key)

func _redraw_all() -> void:
	if _draw_node:
		_draw_node.queue_redraw()
	var invalid_children: Array = []
	for key in _child_by_key:
		var child_candidate = _child_by_key[key]
		if not is_instance_valid(child_candidate):
			invalid_children.append(key)
			continue
		var child: NoteDisplayer = child_candidate
		if child._draw_node:
			child._draw_node.queue_redraw()
	for key in invalid_children:
		_child_by_key.erase(key)

# 重置播放头位置 - 用于进度条跳转
func reset_playhead_position(target_ms: float) -> void:
	if not is_master or buckets.is_empty() or master_node == null:
		return

	# 确保 _process 处于启用状态：拖动进度条/重入时恢复计时
	set_process(true)

	# 获取PlaybackDisplay以计算tick
	var midi_playback_mgr = PlaybackDisplay.instance
	if midi_playback_mgr == null:
		return

	# 计算目标tick（根据BPM时间线）
	var target_tick = midi_playback_mgr.calculate_tick_from_position_with_bpm_timeline(
		target_ms, midi_playback_mgr.midi_timebase)
	_computed_ct = target_tick

	_clear_all_notes()
	for b in buckets:
		b.cursor = 0

	# 定位每 bucket 到视野起点（跳过一个 end_tick < target_tick 的音符）
	for b in buckets:
		while b.cursor < b.n_count() and b.n_end(b.notes[b.cursor]) < target_tick:
			b.cursor += 1

	# 生成视野内音符
	var view_right_bound = target_tick + area_width / scale_factor
	for b in buckets:
		while b.cursor < b.n_count() and b.n_start(b.notes[b.cursor]) < view_right_bound:
			_create_note(b.notes[b.cursor], b)
			b.cursor += 1

	_last_ct = target_tick
	_compute_counts_from(target_tick)
	_redraw_all()

# 刷新音符车道数（master 用，lazy 高度重算 + 重绘）
func refresh_notes_lane(lane_ctn: int):
	lane_count = lane_ctn
	lane_height = area_height / lane_count

	if is_master:
		# 展开/收起改变 lane 数，所有已存在音符的 rect_master 需重算
		_refresh_note_rects(active_notes, false)

	if _draw_node:
		_draw_node.queue_redraw()

func toggle_track(toggled_on: bool, track_index: int):
	if not is_master:
		return
	# bucket 级过滤：切换对应 track_index 的 bucket.is_enabled
	for b in buckets:
		if b.track_index == track_index:
			b.is_enabled = toggled_on

	# 依据 is_enabled 重建总览 active_notes（新启用 bucket 已在 _bucket_active 的音符合并进来）
	active_notes.clear()
	for b in buckets:
		if not b.is_enabled:
			continue
		var arr: Array = _bucket_active.get(_key_str(b.track_index, b.channel), [])
		if arr:
			for n in arr:
				active_notes.append(n)

	if _draw_node:
		_draw_node.queue_redraw()

## 从MidiData同步启用的(track, channel)配置（master 级一次性过滤）
func sync_from_midi_data(midi_data: MidiData) -> void:
	if midi_data == null:
		return

	for b in buckets:
		b.is_enabled = midi_data.is_track_channel_selected(b.track_index, b.channel)

	if not is_master:
		return

	# 依据 is_enabled 重建总览 active_notes
	active_notes.clear()
	for b in buckets:
		if not b.is_enabled:
			continue
		var arr: Array = _bucket_active.get(_key_str(b.track_index, b.channel), [])
		if arr:
			for n in arr:
				active_notes.append(n)

	_compute_counts_from(_computed_ct)
	_redraw_all()

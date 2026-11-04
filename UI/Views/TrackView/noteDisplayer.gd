extends HBoxContainer

class_name NoteDisplayer

# canvas 在 midiTrack.tscn 里是 Control、在 TrackView.tscn 里是 Panel，统一按基类 Control 取
@onready var flow_area: Control = %NoteCanvas
@onready var note_count_passed: Label = %NotePassed
@onready var note_count_total: Label = %NoteTotal

## 全量重建时向前回溯的最大条数（收「起始在播放头之前、尾部仍在窗口内」的长音符）
const BACKWALK_STEPS := 2048
## 计数标签刷新间隔（秒）
const COUNT_REFRESH_INTERVAL := 0.1
## 窗口重建触发阈值（相对窗口宽度）：提高后重建频率减半、总 CPU 更低
const REBUILD_TRIGGER_RATIO := 0.5
## 未来音符提前进入窗口的余量（相对窗口宽度）：必须覆盖触发阈值 + 渐进重建耗时
const ENTER_MARGIN_RATIO := 0.75
## 实例缓冲初始容量（2 的幂，按需翻倍）
const INITIAL_CAPACITY := 128
## 慢帧自测量阈值（微秒）：总耗时超过才打一行日志，正常帧不产生任何分配/日志
const SLOW_FRAME_WARN_US := 8000
## _process 内触发的全量重建每帧回溯总预算（按 renderer 数均摊；seek 走 reset 不受此限制）
const MAX_BACKWALK_STEPS_PER_PROCESS_SYNC := 4096
## 渐进重建每帧最多处理的总条目数（按活跃 staging 数轮转分配）
const STAGE_ITEMS_PER_FRAME := 256
## 渐进重建每帧时间上限（微秒）：与条数上限双保险，超时本帧停止、下一帧继续
const STAGE_TIME_BUDGET_US := 500
## 单次 step_staged 最多处理的条数（限制单次调用的最坏耗时）
const STAGE_MAX_STEP_ITEMS := 128
## 同时进行的渐进重建数上限（避免多个重桶叠加；到期的按 anchor 最旧排队）
const MAX_CONCURRENT_STAGING := 2

var area_height: float = 160
var area_width: float = 0
var lane_count: int = 12
var scale_factor: float = 0.5

# 每个车道的高度
var lane_height: float = 0

# 按 (track, channel) 分组的音轨容器（master 专用，按 bucket 独立推进窗口）
var buckets: Array[TrackNoteBucket] = []

# 是否是主显示器（唯一承载 _process 计时/窗口调度/计数）
var is_master: bool = false

# 子 displayer 指向的 master 引用（窗口回溯上限、ct 均取 master）
var _master: NoteDisplayer = null

# MIDI 最大 end_tick（所有 bucket 中最后一个音符的结束 tick）
# 用于检测 ct 异常：循环播放时 Sequencer.Position 可能继续增长而不跳回 0，
# 导致 ct 超过所有音符的 end_tick。此时清空窗口等待循环恢复
var _max_end_tick: float = 0.0
# 上一帧的 ct，用于检测 ct 回绕（循环跳回 0 / seek）与大幅前跳
var _last_ct: float = -1.0

# track view节点
var master_node: Node = null

var note_color: Color

# 当前 displayer 的全部窗口渲染器（master = 每 bucket 一个，按 buckets 顺序；子 = 单个）
var _renderers: Array = []
# master 专用：多键 "t:ch" → 已通过计数（推进子 displayer 计数标签）
var _bucket_passed: Dictionary = {}
# master 专用：多键 "t:ch" → 子 displayer 引用
var _child_by_key: Dictionary = {}
# master 专用：多键 "t:ch" → bucket 对象（读取 total 用）
var _bucket_by_key: Dictionary = {}
# 当前播放 tick（master 每帧计算一次，子 displayer 由 master 同步）
var _computed_ct: float = 0.0

# 全曲最大音符时长（tick，0 = 未知；窗口回溯用）
var _max_note_duration_ticks: float = 0.0
# 回退过窗口回溯上限时只告警一次
var _warned_duration_fallback: bool = false
# 计数标签刷新计时
var _count_timer: float = 0.0
# 分帧重建调度用的复用数组（避免每帧分配）
var _scratch_renderers: Array = []
var _invalid_children: Array = []
# 本帧 Label 文本实际改写次数（仅慢帧日志用）
var _label_writes_frame: int = 0
# 本帧渐进重建处理的条目数 / 帧末仍在 staging 的 renderer 数（仅慢帧日志用）
var _stage_items_frame: int = 0
var _staging_renderers_frame: int = 0

## 单个 bucket 的音符几何容器（TrackView 构建并读取字段）
## notes 为 notes_soa 索引，显示路径经 soa 只读直引，不物化 NoteEvent。
class TrackNoteBucket:
	extends RefCounted
	var track_index: int = 0
	var channel: int = 0
	var hue: float = 0.0              # 颜色色相（由 track_index 查 colors_set 一次）
	var color: Color = Color.WHITE    # 由 hue 预计算的绘制颜色
	## 音符容器：PackedInt32Array（notes_soa 索引），按 start_tick 升序
	var notes: Variant = []
	var soa: NoteSoa = null          # 共享 SOA 引用（只读直引）
	var cursor: int = 0               # 保留字段（窗口推进由渲染器自己的游标负责）
	var is_enabled: bool = true       # master 用：该音轨是否启用
	## 本桶最大音符时长（tick，0 = 未知）：窗口回溯下限用，比全曲最大值更紧
	var max_duration_ticks: float = 0.0

	## 元素统一只读接口：e 为 notes[cursor]（SOA 索引 int）
	func n_start(e: Variant) -> float:
		return soa.start_tick(e) if soa != null else 0.0
	func n_end(e: Variant) -> float:
		return soa.end_tick(e) if soa != null else 0.0
	func n_pitch(e: Variant) -> int:
		return soa.pitch(e) if soa != null else 0
	func n_count() -> int:
		return notes.size()

## 一个 bucket 在某个 displayer 上的窗口渲染器：
## 实例几何只在重建时写入 MultiMesh，播放中每帧只改节点 position.x / scale.y
class NoteWindowRenderer:
	extends RefCounted
	var node: MultiMeshInstance2D = null
	var mm: MultiMesh = null
	var bucket: TrackNoteBucket = null
	var displayer: NoteDisplayer = null
	## 当前窗口内音符的 SOA 索引，按 start_tick 升序
	var items: PackedInt32Array = PackedInt32Array()
	## bucket.notes 中下一个待考虑的下标（只增）
	var cursor: int = 0
	## 实例坐标锚点（每次重建 = 当时的 ct）
	var anchor_ct: float = 0.0
	## = items.size()
	var count: int = 0
	## 实例容量（2 的幂）
	var capacity: int = 0
	## capacity * 8 的实例缓冲（全 0 = 零矩阵，不绘制）
	var buffer: PackedFloat32Array = PackedFloat32Array()
	## 上次写 buffer 时的 area_height（纵向拉伸基准）
	var geometry_area_height: float = 0.0
	## 上次写 buffer 时的 area_width（横向补偿基准）
	var geometry_area_width: float = 0.0
	## 尺寸/车道变化后需要尽快重建
	var dirty: bool = false

	# ---- 渐进重建（staging）状态：构建期间继续用旧的 items/buffer/anchor 显示 ----
	## 是否正在渐进重建
	var staging: bool = false
	## 本次重建的播放头快照（窗口判定与实例坐标都按它，跨帧稳定）
	var stage_ct: float = 0.0
	## 本次重建的实例坐标锚点（= stage_ct）
	var stage_anchor: float = 0.0
	## bucket.notes 中下一条待追加的下标（staging 开始时的 cursor）
	var stage_cursor: int = 0
	## 旧 items 中下一条待压缩的下标
	var stage_off: int = 0
	## 新窗口条目的 SOA 索引（完成时替换 items）
	var stage_items: PackedInt32Array = PackedInt32Array()
	## 新窗口的实例缓冲（完成时替换 buffer）
	var stage_buf: PackedFloat32Array = PackedFloat32Array()
	## stage_buf 的实例容量（2 的幂；不足时扩成新数组）
	var stage_capacity: int = 0
	## stage_items 条数
	var stage_count: int = 0
	## staging 开始时的几何快照（保证跨帧写入一致，完成后再换回当前尺寸）
	var stage_geometry_h: float = 0.0
	var stage_geometry_w: float = 0.0
	var stage_lane_count: int = 1
	var stage_lane_height: float = 0.0
	var stage_scale_factor: float = 0.5
	var stage_area_width: float = 0.0
	## 视窗宽度（tick）与窗口右界（含进入余量）
	var stage_window: float = 0.0
	var stage_hi: float = 0.0
	## stage 写入实例的矩形并集（完成时写 custom_aabb）
	var stage_min_x: float = INF
	var stage_min_y: float = INF
	var stage_max_x: float = -INF
	var stage_max_y: float = -INF
	## 上一次 step_staged 实际处理条数
	var stage_last_step_items: int = 0

	## 视窗宽度（tick）= area_width / scale_factor
	func window_ticks() -> float:
		if displayer == null or displayer.scale_factor <= 0.0:
			return 0.0
		return displayer.area_width / displayer.scale_factor

	## 是否到了该重建窗口的时间（dirty 由尺寸变化标记；staging 期间不重复触发）
	func is_due(ct: float) -> bool:
		if staging:
			return false
		if dirty:
			return true
		var window := window_ticks()
		if window <= 0.0:
			return false
		return absf(ct - anchor_ct) > window * NoteDisplayer.REBUILD_TRIGGER_RATIO

	## 按当前播放头重建窗口实例缓冲；full=true 时回溯长音符并从头推进游标。
	## backwalk_limit 限制本次回溯条数（-1 = 用 BACKWALK_STEPS）；返回实际回溯条数
	func rebuild(ct: float, full: bool, backwalk_limit: int = -1) -> int:
		cancel_staged()
		dirty = false
		var soa: NoteSoa = bucket.soa if bucket != null else null
		var notes: Variant = bucket.notes if bucket != null else []
		if soa == null or notes.is_empty():
			items.clear()
			count = 0
			anchor_ct = ct
			_cache_geometry()
			if mm != null:
				mm.visible_instance_count = 0
				mm.custom_aabb = AABB()
			return 0

		var window := window_ticks()
		var hi: float = ct + window + window * NoteDisplayer.ENTER_MARGIN_RATIO
		var first_ge: int = _first_index_ge(ct)
		var steps: int = 0
		if full:
			# 向回走，收「起始在 ct 之前、但尾部仍在窗口内」的长音符；
			# 从第一个 start >= ct 的前一条开始按条数/时长上限回溯，避免正向扫全曲。
			# 回溯下限优先用本桶最大音符时长（更紧且精确），缺失时回退到全曲值
			items.clear()
			var max_dur: float = bucket.max_duration_ticks
			if max_dur <= 0.0:
				max_dur = displayer._resolve_max_duration_ticks()
			var walk_floor: float = ct - max_dur
			var limit: int = NoteDisplayer.BACKWALK_STEPS
			if backwalk_limit >= 0 and backwalk_limit < limit:
				limit = backwalk_limit
			var back: int = first_ge - 1
			while back >= 0 and steps < limit:
				var idx: int = notes[back]
				if soa.start_tick(idx) < walk_floor:
					break
				if soa.end_tick(idx) > ct:
					items.append(idx)
				back -= 1
				steps += 1
			items.reverse()
			cursor = first_ge
		else:
			# 单趟压缩：丢掉已经完全离开（end_tick <= ct）的音符，保持顺序
			var w: int = 0
			var n_items: int = items.size()
			for i in n_items:
				var idx2: int = items[i]
				if soa.end_tick(idx2) > ct:
					items[w] = idx2
					w += 1
			items.resize(w)

		# 追加窗口右界内的未来音符（已过期的直接跳过）
		var total: int = notes.size()
		while cursor < total:
			var idx3: int = notes[cursor]
			if soa.start_tick(idx3) >= hi:
				break
			if soa.end_tick(idx3) > ct:
				items.append(idx3)
			cursor += 1

		count = items.size()
		anchor_ct = ct
		_ensure_capacity(count)
		_cache_geometry()
		if count > 0 and capacity > 0:
			_write_buffer(soa)
		elif mm != null:
			mm.custom_aabb = AABB()
		if mm != null:
			mm.visible_instance_count = count
		return steps

	## 车道数/尺寸变化后按当前几何原地重写实例缓冲（不重新推进窗口，不改变 dirty 状态）
	func rewrite_geometry() -> void:
		cancel_staged()
		_cache_geometry()
		if bucket == null or bucket.soa == null:
			return
		if count <= 0 or capacity <= 0:
			if mm != null:
				mm.custom_aabb = AABB()
			return
		_write_buffer(bucket.soa)

	## 每帧 O(1)：只用节点位移表达播放头推进，尺寸变化期间靠节点变换补偿
	func update_transform(ct: float) -> void:
		if node == null or displayer == null:
			return
		node.position.x = (ct - anchor_ct) * displayer.scale_factor \
			+ (displayer.area_width - geometry_area_width)
		node.position.y = 0.0
		node.scale.y = displayer.area_height / maxf(geometry_area_height, 1.0)

	## 清空可见实例（ct 异常保护用），游标保持不变
	func hide_all() -> void:
		cancel_staged()
		items.clear()
		count = 0
		if mm != null:
			mm.visible_instance_count = 0
			mm.custom_aabb = AABB()

	## 开始一次渐进重建：只记录快照，真正完成前不改动当前显示的 items/buffer/anchor
	func start_staged_refresh(ct: float) -> void:
		if staging or displayer == null or bucket == null:
			return
		dirty = false
		staging = true
		stage_ct = ct
		stage_anchor = ct
		stage_cursor = cursor
		stage_off = 0
		stage_count = 0
		stage_items.clear()
		stage_geometry_h = displayer.area_height
		stage_geometry_w = displayer.area_width
		stage_lane_count = maxi(displayer.lane_count, 1)
		stage_lane_height = displayer.lane_height
		stage_scale_factor = displayer.scale_factor if displayer.scale_factor > 0.0 else 1.0
		stage_area_width = displayer.area_width
		stage_window = stage_area_width / stage_scale_factor
		stage_hi = stage_ct + stage_window + stage_window * NoteDisplayer.ENTER_MARGIN_RATIO
		stage_min_x = INF
		stage_min_y = INF
		stage_max_x = -INF
		stage_max_y = -INF
		stage_last_step_items = 0
		stage_capacity = capacity
		if stage_capacity <= 0:
			stage_capacity = NoteDisplayer.INITIAL_CAPACITY
		stage_buf.resize(stage_capacity * 8)

	## 放弃渐进重建（尺寸/车道/seek/init 等同步重建前调用）：当前显示内容保持不变
	func cancel_staged() -> void:
		staging = false
		stage_items.clear()
		stage_off = 0
		stage_count = 0
		stage_cursor = 0
		stage_last_step_items = 0

	## 渐进重建推进一步：最多处理 max_items 条窗口条目；返回 true 表示已完成并已 swap
	func step_staged(max_items: int) -> bool:
		stage_last_step_items = 0
		if not staging:
			return true
		if max_items <= 0:
			return false
		var soa: NoteSoa = bucket.soa
		var notes: Variant = bucket.notes
		if soa == null or notes.is_empty():
			# 空桶：直接换成空窗口
			items.clear()
			count = 0
			cursor = 0
			anchor_ct = stage_ct
			_cache_geometry()
			staging = false
			if mm != null:
				mm.visible_instance_count = 0
				mm.custom_aabb = AABB()
			return true

		var processed: int = 0
		var old_n: int = items.size()
		# 1) 压缩旧窗口：保留 end_tick > stage_ct 的条目，其余丢弃
		while stage_off < old_n and processed < max_items:
			var old_idx: int = items[stage_off]
			stage_off += 1
			processed += 1
			var old_et: float = soa.end_tick(old_idx)
			if old_et > stage_ct:
				_stage_append(old_idx, soa, soa.start_tick(old_idx), old_et)

		# 2) 从旧游标向后追加进入新窗口的音符（受右界限制）
		var total: int = notes.size()
		while processed < max_items and stage_cursor < total:
			var idx: int = notes[stage_cursor]
			var idx_st: float = soa.start_tick(idx)
			if idx_st >= stage_hi:
				break
			stage_cursor += 1
			processed += 1
			var idx_et: float = soa.end_tick(idx)
			if idx_et > stage_ct:
				_stage_append(idx, soa, idx_st, idx_et)

		stage_last_step_items = processed
		# 3) 旧窗口压缩完 + 新窗口追加到右界 → 完成并换用新数据
		var old_done: bool = stage_off >= old_n
		var new_done: bool = stage_cursor >= total or soa.start_tick(notes[stage_cursor]) >= stage_hi
		if old_done and new_done:
			_swap_staged()
			return true
		return false

	## 把一条音符写入 staging 缓冲（几何用 staging 开始时的快照，保证跨帧一致）
	## st_tick/et_tick 由调用方传入，避免重复的 SOA 访问
	func _stage_append(idx: int, soa: NoteSoa, st: float, et: float) -> void:
		if stage_count >= stage_capacity:
			_stage_ensure_capacity(stage_count + 1)
		var pitch: int = soa.pitch(idx)
		var w: float = (et - st) * stage_scale_factor
		if w < 1.0:
			w = 1.0
		var x: float = stage_area_width - (et - stage_anchor) * stage_scale_factor
		var lane_index: int = stage_lane_count - 1 - ((pitch - 21) % stage_lane_count)
		var h: float = stage_lane_height * 0.8
		var y: float = stage_lane_height * lane_index + (stage_lane_height - h) * 0.5
		var o: int = stage_count * 8
		stage_buf[o] = w
		stage_buf[o + 1] = 0.0
		stage_buf[o + 2] = 0.0
		stage_buf[o + 3] = x + w * 0.5
		stage_buf[o + 4] = 0.0
		stage_buf[o + 5] = h
		stage_buf[o + 6] = 0.0
		stage_buf[o + 7] = y + h * 0.5
		stage_items.append(idx)
		stage_count += 1
		if x < stage_min_x:
			stage_min_x = x
		if y < stage_min_y:
			stage_min_y = y
		if x + w > stage_max_x:
			stage_max_x = x + w
		if y + h > stage_max_y:
			stage_max_y = y + h

	## staging 缓冲容量不足时扩成新的 2 的幂数组（已有条目需复制到新数组）
	func _stage_ensure_capacity(n: int) -> void:
		if n <= stage_capacity:
			return
		var cap: int = NoteDisplayer.INITIAL_CAPACITY
		while cap < n:
			cap <<= 1
		var new_buf := PackedFloat32Array()
		new_buf.resize(cap * 8)
		var copy_n: int = stage_count * 8
		for i in copy_n:
			new_buf[i] = stage_buf[i]
		stage_buf = new_buf
		stage_capacity = cap

	## staging 完成：换用新窗口数据，刷新几何缓存与裁剪矩形（custom_aabb）
	func _swap_staged() -> void:
		items = stage_items
		stage_items = PackedInt32Array()
		count = stage_count
		cursor = stage_cursor
		anchor_ct = stage_anchor
		geometry_area_height = stage_geometry_h
		geometry_area_width = stage_geometry_w
		if stage_capacity != capacity:
			capacity = stage_capacity
			mm.instance_count = capacity
		buffer = stage_buf
		stage_buf = PackedFloat32Array()
		if count > 0 and capacity > 0:
			mm.set_buffer(buffer)
			mm.custom_aabb = AABB(Vector3(stage_min_x, stage_min_y, 0.0),
				Vector3(stage_max_x - stage_min_x, stage_max_y - stage_min_y, 0.0))
		else:
			mm.custom_aabb = AABB()
		mm.visible_instance_count = count
		staging = false

	## 记录本次写 buffer 时的 displayer 尺寸（纵向拉伸/横向补偿基准）
	func _cache_geometry() -> void:
		if displayer == null:
			return
		geometry_area_height = displayer.area_height
		geometry_area_width = displayer.area_width

	## 容量按 2 的幂增长；MultiMesh.instance_count 变更会重分配底层缓冲
	func _ensure_capacity(n: int) -> void:
		if n <= capacity:
			return
		var cap: int = NoteDisplayer.INITIAL_CAPACITY
		while cap < n:
			cap <<= 1
		capacity = cap
		mm.instance_count = cap
		buffer.resize(cap * 8)

	## 把窗口内音符写成 QuadMesh（原点为中心）的实例变换。
	## 同时按实例矩形算 custom_aabb：set_buffer 不会 emit_changed，MultiMeshInstance2D
	## 的 canvas item 可视野矩形缓存不会刷新，滚动后整节点会被错误剔除；
	## set_custom_aabb 会 emit_changed → queue_redraw 让裁剪矩形按新几何重算，并省掉引擎的 AABB 重算
	func _write_buffer(soa: NoteSoa) -> void:
		if capacity <= 0:
			return
		var aw: float = displayer.area_width
		var sw: float = displayer.scale_factor
		var lc: int = displayer.lane_count
		if lc <= 0:
			lc = 1
		var lh: float = displayer.lane_height
		var o: int = 0
		var ct: float = anchor_ct
		var min_x: float = INF
		var min_y: float = INF
		var max_x: float = -INF
		var max_y: float = -INF
		for i in count:
			var idx: int = items[i]
			var st: float = soa.start_tick(idx)
			var et: float = soa.end_tick(idx)
			var pitch: int = soa.pitch(idx)
			var w: float = (et - st) * sw
			if w < 1.0:
				w = 1.0
			var x: float = aw - (et - ct) * sw
			var lane_index: int = lc - 1 - ((pitch - 21) % lc)
			var h: float = lh * 0.8
			var y: float = lh * lane_index + (lh - h) * 0.5
			# 2D 实例变换 8 float：[x_axis.x, y_axis.x, 0, origin.x, x_axis.y, y_axis.y, 0, origin.y]
			buffer[o] = w
			buffer[o + 1] = 0.0
			buffer[o + 2] = 0.0
			buffer[o + 3] = x + w * 0.5
			buffer[o + 4] = 0.0
			buffer[o + 5] = h
			buffer[o + 6] = 0.0
			buffer[o + 7] = y + h * 0.5
			o += 8
			if x < min_x:
				min_x = x
			if y < min_y:
				min_y = y
			if x + w > max_x:
				max_x = x + w
			if y + h > max_y:
				max_y = y + h
		mm.set_buffer(buffer)
		if count > 0:
			mm.custom_aabb = AABB(Vector3(min_x, min_y, 0.0),
				Vector3(max_x - min_x, max_y - min_y, 0.0))
		else:
			mm.custom_aabb = AABB()

	## 第一个 start_tick >= tick 的音符在 bucket.notes 中的下标（手写二分）
	func _first_index_ge(tick: float) -> int:
		var notes: Variant = bucket.notes
		var soa: NoteSoa = bucket.soa
		var lo: int = 0
		var hi: int = notes.size()
		while lo < hi:
			var mid: int = (lo + hi) >> 1
			if soa.start_tick(notes[mid]) < tick:
				lo = mid + 1
			else:
				hi = mid
		return lo

func _ready():
	if size.y > 250:
		lane_count = 24
	_on_flow_area_resized()

	flow_area.resized.connect(_on_flow_area_resized)


func _exit_tree() -> void:
	_destroy_renderers()


## 尺寸变化：更新几何缓存；播放中只标记待重建（靠节点 transform 补偿），
## 暂停/未启用 _process 时立即同步重写，保证暂停态下尺寸变化也立刻正确
func _on_flow_area_resized():
	if flow_area == null:
		return
	var rs: Vector2 = flow_area.get_rect().size
	area_height = rs.y
	area_width = rs.x
	lane_height = area_height / lane_count if lane_count > 0 else 0.0

	if area_width <= 0.0 or area_height <= 0.0 or _renderers.is_empty():
		return

	# 尺寸变化后窗口内容不变：位置靠节点位移补偿、车道靠纵向拉伸保持正确。
	# 始终标记待重建，让播放中的刷新预算按新尺寸补齐窗口（子 displayer 也在调度范围内）
	_mark_all_dirty()
	var mgr = PlaybackDisplay.instance
	var playing: bool = is_master and is_processing() and mgr != null and mgr.is_playing
	if playing:
		return
	# 暂停/未启用 _process 时没有后续调度：立即按新尺寸重写几何，保证画面立刻正确
	_rewrite_geometry_all(_computed_ct)

func update_color():
	var single_color: bool = note_color != Color(0, 0, 0, 0)
	for r in _renderers:
		if r.node == null:
			continue
		if is_master:
			r.node.modulate = r.bucket.color
		else:
			r.node.modulate = note_color if single_color else Color.WHITE

## 仅 master 执行：每帧 O(1) 位移更新 + 低频分帧重建窗口 + 10Hz 计数。
## 慢帧自测量：只在总耗时超过 SLOW_FRAME_WARN_US 时打一行 [slow-frame] 日志，正常帧零分配
func _process(delta):
	if not is_master:
		return
	if master_node == null or buckets.is_empty():
		return

	var t_start: int = Time.get_ticks_usec()
	var midi_mgr = PlaybackDisplay.instance
	var t_inst: int = Time.get_ticks_usec()
	if midi_mgr == null or not midi_mgr.is_playing:
		# 不主动 set_process(false)：由 TrackView._set_note_displayers_process 统一管理启停
		# 暂停/非播放早退也测一次慢帧：is_playing 是 C# 互操作，卡顿可能发生在这里
		var t_early: int = Time.get_ticks_usec()
		if t_early - t_start >= SLOW_FRAME_WARN_US:
			_warn_slow_frame(t_early - t_start, delta, t_inst - t_start, t_early - t_inst,
				0, 0, 0, 0, 0, 0, 3, _last_ct, _computed_ct, _window_ticks(), 0, 0, 0, 0)
		return
	var t_playing: int = Time.get_ticks_usec()

	# 播放位置转换为 tick；ct 与音符的 start_tick/end_tick 在同一 tick 参考系
	# 一帧只计算一次，供所有子 displayer 共享
	var delayed_ms: float = midi_mgr.get_position_ms()
	var t_pos: int = Time.get_ticks_usec()
	var prev_ct: float = _last_ct
	_computed_ct = midi_mgr.calculate_tick_from_position_with_bpm_timeline(delayed_ms, midi_mgr.midi_timebase)
	var ct := _computed_ct
	var t_ct: int = Time.get_ticks_usec()

	var window: float = _window_ticks()
	# 0=正常 1=ct 异常清空 2=回退/前跳全量重建
	var path: int = 0
	var rebuilt: int = 0
	var backwalk_used: int = 0
	var t_tf: int = t_ct
	var t_rb: int = t_ct
	var t_cl: int = t_ct
	_label_writes_frame = 0
	_stage_items_frame = 0
	_staging_renderers_frame = 0

	# ct 异常保护：循环播放时 Sequencer.Position 可能继续增长而不跳回 0，
	# 导致 ct 超过所有音符的 end_tick。此时清空窗口，等待位置回绕
	if _max_end_tick > 0.0 and ct > _max_end_tick + window:
		_hide_all_renderers()
		_last_ct = ct
		t_rb = Time.get_ticks_usec()
		t_cl = t_rb
		path = 1
	elif _last_ct >= 0.0 and (ct < _last_ct - window or ct > _last_ct + window * 0.5):
		# 播放头大幅后退（循环跳回 0 / seek）或大幅前跳（页面/后台恢复）时同步全量重建，
		# 保证跳变后的第一帧就是正确画面。前跳阈值取半个窗口：超过它时已生成窗口覆盖不到
		# 左缘新进入的音符；更小的前跳靠节点位移 + 刷新预算即可追平。
		# 回溯成本按帧预算均摊到各 renderer（seek 走 reset_playhead_position，不受此预算限制）
		@warning_ignore("integer_division")
		var per_renderer: int = maxi(1, MAX_BACKWALK_STEPS_PER_PROCESS_SYNC / maxi(_renderer_total_count(), 1))
		backwalk_used = _rebuild_all_sync(ct, per_renderer)
		t_rb = Time.get_ticks_usec()
		t_cl = t_rb
		path = 2
		rebuilt = _renderer_total_count()
	else:
		_last_ct = ct
		# 每帧只写节点位移与纵向拉伸（O(renderer 数)）
		_update_all_transforms(ct)
		t_tf = Time.get_ticks_usec()
		# 低频渐进重建：到期窗口按 anchor 最旧排队，分帧构建（条数 + 时间双预算）
		rebuilt = _schedule_rebuilds(ct)
		t_rb = Time.get_ticks_usec()
		# 清理已随轨道行释放的子 displayer
		_cleanup_invalid_children()
		t_cl = Time.get_ticks_usec()

		# 计数标签按固定频率刷新（二分统计，不逐音符扫描）
		_count_timer += delta
		if _count_timer >= COUNT_REFRESH_INTERVAL:
			_count_timer = 0.0
			_recompute_counts(ct)

	var t_end: int = Time.get_ticks_usec()
	var total: int = t_end - t_start
	if total >= SLOW_FRAME_WARN_US:
		_warn_slow_frame(total, delta, t_inst - t_start, t_playing - t_inst,
			t_pos - t_playing, t_ct - t_pos, t_tf - t_ct, t_rb - t_tf,
			t_cl - t_rb, t_end - t_cl, path, prev_ct, ct, window, rebuilt,
			backwalk_used, _stage_items_frame, _staging_renderers_frame)

## 慢帧日志：总耗时、各段耗时、路径、ct 跳变、renderer/重建/Label/staging 统计
func _warn_slow_frame(total_us: int, frame_delta: float, inst_us: int, playing_us: int,
		pos_us: int, calc_us: int, tf_us: int, rebuild_us: int, cleanup_us: int,
		tail_us: int, path: int, prev_ct: float, ct: float, window: float,
		rebuilt: int, backwalk_used: int, stage_items: int, staging_n: int) -> void:
	var path_name := "normal"
	if path == 1:
		path_name = "ct_abnormal"
	elif path == 2:
		path_name = "jump_full_rebuild"
	elif path == 3:
		path_name = "not_playing"
	var stats: Vector2i = _window_max_stats()
	GLogger.warning(
		"slow-frame total=%dus delta=%.2fms autoload=%dus playing=%dus get_pos=%dus calc_ct=%dus transform=%dus rebuild=%dus cleanup=%dus tail=%dus path=%s ct=%.1f prev_ct=%.1f ct_delta=%.1f window=%.1f renderers=%d rebuilt=%d backwalk=%d labels=%d stage_items=%d stage_n=%d max_items=%d max_cap=%d" %
		[total_us, frame_delta * 1000.0, inst_us, playing_us, pos_us, calc_us,
		tf_us, rebuild_us, cleanup_us, tail_us, path_name, ct, prev_ct,
		ct - prev_ct, window, _renderer_total_count(), rebuilt, backwalk_used,
		_label_writes_frame, stage_items, staging_n, stats.x, stats.y],
		"NoteDisplayer")

## 所有窗口的最大 items 数 / 最大实例容量（仅慢帧日志用）
func _window_max_stats() -> Vector2i:
	var max_items: int = 0
	var max_cap: int = 0
	for r in _renderers:
		max_items = maxi(max_items, maxi(r.items.size(), r.stage_items.size()))
		max_cap = maxi(max_cap, maxi(r.capacity, r.stage_capacity))
	if is_master:
		for key in _child_by_key:
			var child_candidate = _child_by_key[key]
			if is_instance_valid(child_candidate):
				var child: NoteDisplayer = child_candidate
				for r in child._renderers:
					max_items = maxi(max_items, maxi(r.items.size(), r.stage_items.size()))
					max_cap = maxi(max_cap, maxi(r.capacity, r.stage_capacity))
	return Vector2i(max_items, max_cap)

## 当前 displayer 及其所有子 displayer 的窗口渲染器总数（仅日志用）
func _renderer_total_count() -> int:
	var n: int = _renderers.size()
	if not is_master:
		return n
	for key in _child_by_key:
		var child_candidate = _child_by_key[key]
		if is_instance_valid(child_candidate):
			n += (child_candidate as NoteDisplayer)._renderers.size()
	return n

## 视窗宽度（tick）
func _window_ticks() -> float:
	if scale_factor <= 0.0:
		return 0.0
	return area_width / scale_factor

## 窗口回溯上限（tick）：优先用解析缓存；缺失时按 max_end_tick/8 或 4 倍窗口保守回退
func _resolve_max_duration_ticks() -> float:
	if not is_master:
		return _master._resolve_max_duration_ticks() if _master != null else 0.0
	if _max_note_duration_ticks > 0.0:
		return _max_note_duration_ticks
	var fallback: float = maxf(_max_end_tick * 0.125, _window_ticks() * 4.0)
	if not _warned_duration_fallback:
		_warned_duration_fallback = true
		GLogger.warning("NoteDisplayer: 缺少 max_note_duration_ticks，窗口回溯回退为 %.0f tick" % fallback, "NoteDisplayer")
	return fallback

## 初始化 displayer
## master: 传入所有 buckets，由 sync_from_midi_data 控制 bucket.is_enabled；为每桶建窗口渲染器
## 子 displayer: 仅保留自己那一个 bucket，建单个渲染器，_process 关闭，窗口由 master 调度
func init_displayer_with_buckets(mn: Node, track_buckets: Array[TrackNoteBucket], max_end_tick: float = 0.0) -> void:
	# 换曲/重入：先销毁旧渲染节点，避免旧音符残留一帧
	_destroy_renderers()
	master_node = mn
	buckets = track_buckets
	_max_end_tick = max_end_tick

	if not is_master:
		# 子 displayer 不参与推算，仅保留引用并为自己唯一的 bucket 建渲染器
		set_process(false)
		_computed_ct = 0.0
		_last_ct = -1.0
		if not buckets.is_empty():
			_add_renderer(buckets[0])
		return

	# master：清空全部状态并重建渲染器
	_bucket_passed.clear()
	_child_by_key.clear()
	_bucket_by_key.clear()
	_computed_ct = 0.0
	_last_ct = -1.0
	_count_timer = 0.0
	_warned_duration_fallback = false
	_max_note_duration_ticks = _read_max_note_duration_ticks(mn)

	for b in buckets:
		b.cursor = 0
		_bucket_by_key[_key_str(b.track_index, b.channel)] = b
		_add_renderer(b)

	# 初始窗口（ct = 0）与计数
	_rebuild_all_sync(0.0)

## 向 master 注册一个子 displayer（按 (track, channel) 绑定）
func register_child(child: NoteDisplayer, track_idx: int, channel: int) -> void:
	child._master = self
	var key := _key_str(track_idx, channel)
	_child_by_key[key] = child
	var bucket := _bucket_by_key.get(key) as TrackNoteBucket
	if bucket != null:
		_write_label(child.note_count_total, str(bucket.notes.size()))
	_write_label(child.note_count_passed, str(_bucket_passed.get(key, 0)))
	# 子的窗口与 master 当前播放头对齐
	child._rebuild_all_sync(_computed_ct)
	# 轨道行刚入树时几何可能尚未布局完成（窗口可能为空），标记待重建，
	# 由 master 的刷新预算在后续帧按成形的尺寸补齐
	for r in child._renderers:
		r.dirty = true

## 重置播放头位置 - 用于进度条跳转 / 循环回绕 / 焦点恢复
func reset_playhead_position(target_ms: float) -> void:
	if not is_master or buckets.is_empty() or master_node == null:
		return

	# 确保 _process 处于启用状态：拖动进度条/重入时恢复计时
	set_process(true)

	var midi_playback_mgr = PlaybackDisplay.instance
	if midi_playback_mgr == null:
		return

	# 计算目标tick（根据BPM时间线）
	var t_start: int = Time.get_ticks_usec()
	var target_tick: float = midi_playback_mgr.calculate_tick_from_position_with_bpm_timeline(
		target_ms, midi_playback_mgr.midi_timebase)

	# 同步全量重建 master 与所有子 displayer 的窗口（暂停态下也要立刻出正确画面）
	# seek 必须精确：不受回溯预算限制
	var backwalk_used: int = _rebuild_all_sync(target_tick)
	var total_us: int = Time.get_ticks_usec() - t_start
	if total_us >= SLOW_FRAME_WARN_US:
		GLogger.warning(
			"slow-seek total=%dus renderers=%d backwalk=%d ct=%.1f target_ms=%.1f" %
			[total_us, _renderer_total_count(), backwalk_used, target_tick, target_ms],
			"NoteDisplayer")

## 刷新音符车道数（master 用；同步按新车道重写实例几何）
func refresh_notes_lane(lane_ctn: int):
	lane_count = lane_ctn
	lane_height = area_height / lane_count if lane_count > 0 else 0.0
	_rewrite_geometry_all(_computed_ct)

func toggle_track(toggled_on: bool, track_index: int):
	if not is_master:
		return
	# bucket 级过滤：切换对应 track_index 的 bucket.is_enabled
	for b in buckets:
		if b.track_index == track_index:
			b.is_enabled = toggled_on
	for r in _renderers:
		if r.node != null:
			r.node.visible = r.bucket.is_enabled
	_recompute_counts(_computed_ct)

## 从MidiData同步启用的(track, channel)配置（master 级一次性过滤）
func sync_from_midi_data(midi_data: MidiData) -> void:
	if midi_data == null:
		return

	for b in buckets:
		b.is_enabled = midi_data.is_track_channel_selected(b.track_index, b.channel)

	if not is_master:
		return

	# 只同步可见性与计数，不重建几何
	for r in _renderers:
		if r.node != null:
			r.node.visible = r.bucket.is_enabled
	_recompute_counts(_computed_ct)

# ===================== 内部实现 =====================

## 创建一个 bucket 的窗口渲染器（节点顺序 = buckets 顺序 = 绘制顺序）
func _add_renderer(b: TrackNoteBucket) -> NoteWindowRenderer:
	var r := NoteWindowRenderer.new()
	r.bucket = b
	r.displayer = self

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = false
	mm.use_custom_data = false
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	mm.mesh = quad

	var mmi := MultiMeshInstance2D.new()
	mmi.name = "NoteMM_%d_%d" % [b.track_index, b.channel]
	mmi.multimesh = mm
	flow_area.add_child(mmi)
	if is_master:
		mmi.visible = b.is_enabled
		mmi.modulate = b.color
	else:
		mmi.visible = true
		mmi.modulate = note_color if note_color != Color(0, 0, 0, 0) else Color.WHITE

	r.mm = mm
	r.node = mmi
	_renderers.append(r)
	return r

## 销毁全部渲染节点（init / 退出树时调用）
func _destroy_renderers() -> void:
	for r in _renderers:
		if r.node != null and is_instance_valid(r.node):
			var parent: Node = r.node.get_parent()
			if parent != null:
				parent.remove_child(r.node)
			r.node.queue_free()
		r.node = null
		r.mm = null
	_renderers.clear()

## 标记全部窗口待重建（master 同时标记子 displayer）
func _mark_all_dirty() -> void:
	for r in _renderers:
		r.dirty = true
	if is_master:
		for key in _child_by_key:
			var child_candidate = _child_by_key[key]
			if is_instance_valid(child_candidate):
				(child_candidate as NoteDisplayer)._mark_all_dirty()

## 同步全量重建（init / seek / 回绕 / 大幅跳变 / 暂停态尺寸变化）。
## backwalk_limit >= 0 时限制**每个** renderer 本次的回溯条数（_process 跳变路径分摊成本用，
## 主子由 master 统一按 renderer 数均摊），返回实际使用的回溯条数总和；
## -1 = 不限制（seek/init 走精确路径）
func _rebuild_all_sync(ct: float, backwalk_limit: int = -1) -> int:
	_computed_ct = ct
	_last_ct = ct
	_count_timer = 0.0
	var used_total: int = 0
	for r in _renderers:
		used_total += r.rebuild(ct, true, backwalk_limit)
		r.update_transform(ct)
	if not is_master:
		return used_total
	for key in _child_by_key:
		var child_candidate = _child_by_key[key]
		if is_instance_valid(child_candidate):
			used_total += (child_candidate as NoteDisplayer)._rebuild_all_sync(ct, backwalk_limit)
	_recompute_counts(ct)
	return used_total

## 每帧 O(1)：写 master 与所有子 displayer 的节点位移/纵向拉伸
func _update_all_transforms(ct: float) -> void:
	for r in _renderers:
		r.update_transform(ct)
	if not is_master:
		return
	for key in _child_by_key:
		var child_candidate = _child_by_key[key]
		if not is_instance_valid(child_candidate):
			continue
		var child: NoteDisplayer = child_candidate
		child._computed_ct = ct
		for r in child._renderers:
			r.update_transform(ct)

## 渐进重建调度：先按剩余预算推进已在 staging 的窗口（按活跃数轮转分配），
## 再在并发上限内为 anchor 最旧的到期窗口启动新的 staging。
## 每帧受「总条数 + 总耗时」双预算限制；返回本帧完成（swap）的窗口数（慢帧日志用）
func _schedule_rebuilds(ct: float) -> int:
	_scratch_renderers.clear()
	for r in _renderers:
		_scratch_renderers.append(r)
	for key in _child_by_key:
		var child_candidate = _child_by_key[key]
		if is_instance_valid(child_candidate):
			for r in (child_candidate as NoteDisplayer)._renderers:
				_scratch_renderers.append(r)

	var t_stage_start: int = Time.get_ticks_usec()
	var budget: int = STAGE_ITEMS_PER_FRAME
	var completed: int = 0
	_stage_items_frame = 0

	# 1) 推进已经在 staging 的窗口：预算按活跃数均分，避免单桶独占
	var active: int = 0
	for r in _scratch_renderers:
		if r.staging:
			active += 1
	if active > 0:
		@warning_ignore("integer_division")
		var share: int = maxi(1, budget / active)
		for r in _scratch_renderers:
			if not r.staging:
				continue
			if budget <= 0 or Time.get_ticks_usec() - t_stage_start >= STAGE_TIME_BUDGET_US:
				break
			var done: bool = r.step_staged(mini(mini(share, budget), STAGE_MAX_STEP_ITEMS))
			_stage_items_frame += r.stage_last_step_items
			budget -= r.stage_last_step_items
			if done:
				r.update_transform(ct)
				completed += 1

	# 2) 并发上限内启动新的 staging（到期窗口按 anchor 最旧优先排队）
	var staging_count: int = 0
	for r in _scratch_renderers:
		if r.staging:
			staging_count += 1
	while staging_count < MAX_CONCURRENT_STAGING \
			and Time.get_ticks_usec() - t_stage_start < STAGE_TIME_BUDGET_US:
		var best: NoteWindowRenderer = null
		for r in _scratch_renderers:
			if r.staging or not r.is_due(ct):
				continue
			if best == null or r.anchor_ct < best.anchor_ct:
				best = r
		if best == null:
			break
		best.start_staged_refresh(ct)
		staging_count += 1
		if budget <= 0:
			continue
		var done2: bool = best.step_staged(mini(budget, STAGE_MAX_STEP_ITEMS))
		_stage_items_frame += best.stage_last_step_items
		budget -= best.stage_last_step_items
		if done2:
			best.update_transform(ct)
			staging_count -= 1
			completed += 1

	# 本帧结束时仍在 staging 的窗口数（慢帧日志用）
	_staging_renderers_frame = 0
	for r in _scratch_renderers:
		if r.staging:
			_staging_renderers_frame += 1
	return completed

## 清理已随轨道行释放的子 displayer 引用
func _cleanup_invalid_children() -> void:
	_invalid_children.clear()
	for key in _child_by_key:
		if not is_instance_valid(_child_by_key[key]):
			_invalid_children.append(key)
	for key in _invalid_children:
		_child_by_key.erase(key)

## 清空全部窗口的可见实例（ct 异常保护）
func _hide_all_renderers() -> void:
	for r in _renderers:
		r.hide_all()
	if not is_master:
		return
	for key in _child_by_key:
		var child_candidate = _child_by_key[key]
		if is_instance_valid(child_candidate):
			(child_candidate as NoteDisplayer)._hide_all_renderers()

## 按新车道数原地重写全部窗口几何（master 同时处理子 displayer）
func _rewrite_geometry_all(ct: float) -> void:
	for r in _renderers:
		r.rewrite_geometry()
		r.update_transform(ct)
	if not is_master:
		return
	for key in _child_by_key:
		var child_candidate = _child_by_key[key]
		if is_instance_valid(child_candidate):
			(child_candidate as NoteDisplayer)._rewrite_geometry_all(ct)

## 按播放头重算 master 与各子 displayer 的计数（二分，不逐音符扫描）
func _recompute_counts(ct: float) -> void:
	_bucket_passed.clear()
	var master_total: int = 0
	var master_passed: int = 0
	for b in buckets:
		var key := _key_str(b.track_index, b.channel)
		var passed := _bucket_passed_at(b, ct)
		_bucket_passed[key] = passed
		if b.is_enabled:
			master_total += b.n_count()
			master_passed += passed
	_write_label(note_count_total, str(master_total))
	_write_label(note_count_passed, str(master_passed))

	for key in _child_by_key:
		var child_candidate = _child_by_key[key]
		if not is_instance_valid(child_candidate):
			continue
		var child: NoteDisplayer = child_candidate
		var bucket := _bucket_by_key.get(key) as TrackNoteBucket
		if bucket != null:
			_write_label(child.note_count_total, str(bucket.n_count()))
		_write_label(child.note_count_passed, str(_bucket_passed.get(key, 0)))

## 某 bucket 中 start_tick < ct 的音符数量（= 第一个 start >= ct 的下标）
func _bucket_passed_at(b: TrackNoteBucket, ct: float) -> int:
	if b == null or b.soa == null:
		return 0
	var notes: Variant = b.notes
	var soa: NoteSoa = b.soa
	var lo: int = 0
	var hi: int = notes.size()
	while lo < hi:
		var mid: int = (lo + hi) >> 1
		if soa.start_tick(notes[mid]) < ct:
			lo = mid + 1
		else:
			hi = mid
	return lo

## 值有变化才写 Label，避免逐帧重复触发文本重排；并记录本帧改写了几个标签（慢帧日志用）
func _write_label(label: Label, text: String) -> void:
	if label != null and label.text != text:
		label.text = text
		_label_writes_frame += 1

## 从 MidiData 读取全曲最大音符时长（旧缓存/兜底路径为 0）
func _read_max_note_duration_ticks(mn: Node) -> float:
	if mn == null:
		return 0.0
	var data: Variant = mn.get("current_midi_data")
	if data is MidiData:
		return float(data.max_note_duration_ticks)
	return 0.0

func _key_str(track: int, channel: int) -> String:
	return str(track) + ":" + str(channel)

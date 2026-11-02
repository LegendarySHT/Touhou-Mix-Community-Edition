class_name PlayHud
extends Control

## PlayView HUD 展示层（Layer 节点）。
## 组件（combo / 分数 / 判定指示 / 暂停按钮 ...）按 hud_layout.json 动态实例化，
## 位置、缩放、变体、动画参数都由布局数据驱动；本类只做三件事：
##   1. 造 / 删 / 重排组件
##   2. 维护一份共享展示状态 _state，推给各组件
##   3. 分数补间（真分 → 显示分）与进度条分段
## 计分数据源（ScoreCalculator）仍在 PlayView。

## 进度条到达最大值（由 PlayView 连接 _on_game_finished）
signal game_finished_requested
## 判定命中请求背景闪光（由 PlayView 连接 bg.flash）
signal flash_requested
## 组件请求（当前只有暂停按钮）转发给 PlayView
signal pause_requested

@onready var progress_bar: ProgressBar = %TopProgressBar

const PROGRESS_BAR_IDLE_COLOR: Color = Color.BLACK

## 判定色（与 ScoreView / recordListItem 保持一致）
const color_map = {
	"Perfect": Color("#FF50FD"),
	"Great": Color("#FF7600"),
	"Good": Color("#0AE000"),
	"Bad": Color("#1CB0FF"),
	"Miss": Color("#DC3450"),
}

## 分数补间默认窗口（秒），可被 score 组件的 roll_duration 覆盖
const SCORE_DRAIN_SEC := 1.0

# ---- 组件 ----
## 布局数据（与 hud_layout.json 的 components 同构）
var layout: Array = []
## id -> HudComponent
var _components: Dictionary = {}
## 顺序（即 Layer 内的子节点顺序，后者在上）
var _order: Array[String] = []

# ---- 共享展示状态 ----
var _state: Dictionary = {}

# ---- 分数补间 ----
var _score_target: int = 0
var _score_shown: int = 0
var _score_start: int = 0
var _score_t: float = 0.0

# ---- 帧内判定 UI 合并刷新 ----
var _judge_ui_dirty: bool = false
var _judge_ui_result: String = ""
var _judge_ui_offset: String = ""
var _judge_ui_cl: Color = Color.WHITE
var _judge_ui_snap: Dictionary = {}
var _judge_ui_hold_tick: bool = false
var _judge_seq: int = 0

# ---- 进度条分段 ----
var _current_rect: ColorRect = null
var _last_rect: ColorRect = null
const _PROGRESS_THROTTLE_MS := 10.0
var _last_progress_shown: float = 0.0

# ---- 调试悬浮 ----
var show_debug_info: bool = false
var debug_info_refresh_interval: float = 0.5
var debug_info_elapsed: float = 0.0

# ---- 编辑 / 预览模式 ----
var edit_mode: bool = false
## 编辑模式里循环播放假判定（方便调动画参数）
var preview_loop: bool = true
var _preview_timer: float = 0.0
const PREVIEW_INTERVAL := 1.4


func _ready() -> void:
	_state = _empty_state()
	resized.connect(apply_all_layouts)
	rebuild_from_layout(HudLayout.load_layout())
	set_process(true)


func _process(delta: float) -> void:
	if not visible:
		return

	# 分数补间：真分 → 显示分
	if _score_shown != _score_target:
		_drain_score(delta)

	if edit_mode:
		if preview_loop:
			_preview_timer += delta
			if _preview_timer >= PREVIEW_INTERVAL:
				_preview_timer = 0.0
				_trigger_preview_judgment()
		return

	if show_debug_info and %DebugInfo and %DebugInfo.visible:
		debug_info_elapsed += delta
		if debug_info_elapsed >= debug_info_refresh_interval:
			debug_info_elapsed = 0.0
			_update_debug_overlay()


func _empty_state() -> Dictionary:
	return {
		"combo": 0,
		"score_raw": 0,
		"score_shown": 0,
		"score_add": 0,
		"pending": 0,
		"accuracy": 1.0,
		"pp": 0.0,
		"judge_text": "",
		"judge_color": Color.WHITE,
		"judge_seq": 0,
		"early_text": "",
		"late_text": "",
		"album": "",
		"song": "",
		"midi_name": "",
		"difficulty": "",
	}


# ==================== 组件管理 ====================

func rebuild_from_layout(p_layout: Array) -> void:
	for id in _order:
		var old: HudComponent = _components.get(id)
		if old != null and is_instance_valid(old):
			remove_child(old)
			old.queue_free()
	_components.clear()
	_order.clear()
	layout = p_layout
	for item in layout:
		_spawn(item)
	apply_all_layouts()
	_refresh_all()


func _spawn(item: Dictionary) -> HudComponent:
	var id := String(item.get("id", ""))
	var path := HudSchema.script_of(id)
	if path.is_empty():
		return null
	var scr: Script = load(path)
	if scr == null:
		GLogger.warning("HUD 组件脚本缺失: %s" % path, "PlayHud")
		return null
	var comp: HudComponent = scr.new()
	comp.name = "Hud_" + id
	add_child(comp)
	comp.setup(item, edit_mode)
	comp.action_requested.connect(_on_component_action)
	_components[id] = comp
	_order.append(id)
	return comp


func get_component(id: String) -> HudComponent:
	var c: HudComponent = _components.get(id)
	if c != null and is_instance_valid(c):
		return c
	return null


## 按渲染顺序（后者在上）返回全部组件
func get_components() -> Array:
	var out: Array = []
	for id in _order:
		var c := get_component(id)
		if c != null:
			out.append(c)
	return out


func has_component(id: String) -> bool:
	return get_component(id) != null


## 添加组件（编辑模式）。位置居中，参数取组件默认值。
func add_component(id: String) -> HudComponent:
	if has_component(id) or not HudSchema.exists(id):
		return null
	var data := HudSchema.new_component_data(id)
	layout.append(data)
	var comp := _spawn(data)
	apply_all_layouts()
	_refresh_all()
	return comp


func remove_component(id: String) -> void:
	var comp := get_component(id)
	if comp == null:
		return
	remove_child(comp)
	comp.queue_free()
	_components.erase(id)
	_order.erase(id)
	var keep: Array = []
	for item in layout:
		if String(item.get("id", "")) != id:
			keep.append(item)
	layout = keep


## 导出当前布局（深拷贝，编辑器的保存用）
func snapshot_layout() -> Array:
	var out: Array = []
	for id in _order:
		var c := get_component(id)
		if c != null:
			out.append(c.data.duplicate(true))
	return out


func save_layout() -> bool:
	return HudLayout.save_layout(snapshot_layout())



func apply_all_layouts() -> void:
	for id in _order:
		var c := get_component(id)
		if c != null:
			c.apply_layout()


func _refresh_all() -> void:
	for id in _order:
		var c := get_component(id)
		if c != null:
			c.on_state(_state)


func _refresh(ids: Array) -> void:
	for id in ids:
		var c := get_component(String(id))
		if c != null:
			c.on_state(_state)


func _on_component_action(action: String, _payload: Variant) -> void:
	if action == "pause":
		pause_requested.emit()


# ==================== 展示数据入口（PlayView 调用） ====================

## 每局开始复位全部展示
func init_display() -> void:
	_score_shown = 0
	_score_target = 0
	_score_start = 0
	_score_t = 0.0
	_state["score_shown"] = 0
	_state["score_raw"] = 0
	_state["score_add"] = 0
	_state["pending"] = 0
	_state["combo"] = 0
	_state["accuracy"] = 1.0
	_state["pp"] = 0.0
	_state["judge_text"] = ""
	_state["early_text"] = ""
	_state["late_text"] = ""
	_refresh_all()

	_current_rect = null
	_last_rect = null
	_last_progress_shown = 0.0
	progress_bar.value = 0
	for i in progress_bar.get_children():
		i.queue_free()


## 歌曲信息（专辑/歌名/MIDI 名/难度）推给信息类组件
func set_song_info(album: String, song: String, midi_name: String, difficulty: String) -> void:
	_state["album"] = album
	_state["song"] = song
	_state["midi_name"] = midi_name
	_state["difficulty"] = difficulty
	_refresh(["album", "song", "midi_name", "difficulty"])


## 判定回调（PlayView 算好 snap 后传入；含 LONG hold tick 轻量路径）
func on_note_judged(result: String, offset: String, snap: Dictionary, is_hold_tick: bool = false) -> void:
	_score_set_target(int(snap["total_score"]))
	_queue_judge_ui(result, offset, color_map.get(result, Color.WHITE), snap, is_hold_tick)


func set_progress_max(v: float) -> void:
	progress_bar.max_value = v


## 进度条写入（节流：与上次显示值差 <10ms 不写，避免每帧触发 value_changed/锚点布局更新）
func set_progress(value: float) -> void:
	if value >= progress_bar.max_value:
		_last_progress_shown = value
		progress_bar.value = value
		return
	if absf(value - _last_progress_shown) < _PROGRESS_THROTTLE_MS:
		return
	_last_progress_shown = value
	progress_bar.value = value


func set_debug_enabled(debug_visible: bool) -> void:
	show_debug_info = debug_visible
	%DebugInfo.visible = debug_visible
	debug_info_elapsed = debug_info_refresh_interval
	if visible:
		_update_debug_overlay()


# ==================== 分数补间 ====================

func _score_set_target(target: int) -> void:
	if target == _score_target:
		return
	_score_start = _score_shown
	_score_target = target
	_score_t = 0.0
	_state["score_raw"] = target


func _drain_score(delta: float) -> void:
	var dur := SCORE_DRAIN_SEC
	var ease_idx := 0
	var comp := get_component("score")
	if comp != null:
		dur = float(comp.get_param("roll_duration", SCORE_DRAIN_SEC))
		ease_idx = int(comp.get_param("roll_easing", 0))
	if dur <= 0.0:
		_score_shown = _score_target
		_score_t = 0.0
	else:
		_score_t = minf(_score_t + delta, dur)
		var p := _score_t / dur
		var e := _ease(p, ease_idx)
		var v := int(round(lerpf(float(_score_start), float(_score_target), e)))
		if p >= 1.0:
			_score_shown = _score_target
		elif _score_target >= _score_start and v >= _score_target:
			_score_shown = _score_target
		else:
			_score_shown = v
	_state["score_shown"] = _score_shown
	_state["pending"] = maxi(_score_target - _score_shown, 0)
	_refresh(["score", "score_pending"])


## 0 立方缓出 / 1 二次缓出 / 2 正弦 / 3 线性
func _ease(p: float, idx: int) -> float:
	var t := clampf(p, 0.0, 1.0)
	match idx:
		1:
			return 1.0 - pow(1.0 - t, 2.0)
		2:
			return sin(t * PI * 0.5)
		3:
			return t
		_:
			return 1.0 - pow(1.0 - t, 3.0)


# ==================== 判定 UI 合并刷新 ====================

func _queue_judge_ui(result: String, offset: String, cl: Color, snap: Dictionary, is_hold_tick: bool = false) -> void:
	_judge_ui_result = result
	_judge_ui_offset = offset
	_judge_ui_cl = cl
	_judge_ui_snap = snap
	_judge_ui_hold_tick = is_hold_tick
	if not _judge_ui_dirty:
		_judge_ui_dirty = true
		_apply_judge_ui.call_deferred()


## 帧末统一应用判定 UI（Label/颜色/tween/闪光只执行一次）
func _apply_judge_ui() -> void:
	if not _judge_ui_dirty:
		return
	_judge_ui_dirty = false
	var snap: Dictionary = _judge_ui_snap
	var result: String = _judge_ui_result
	var cl: Color = _judge_ui_cl
	var offset: String = _judge_ui_offset
	var is_hold_tick: bool = _judge_ui_hold_tick

	_state["combo"] = int(snap.get("combo", 0))
	_state["accuracy"] = float(snap.get("accuracy", 1.0))
	_state["pp"] = float(snap.get("pp", 0.0))
	_state["score_add"] = int(snap.get("last_score_add", 0))
	_state["score_raw"] = int(snap.get("total_score", 0))
	# 判定序号：组件靠它区分「是不是新的一次判定」，避免重复播动画
	_judge_seq += 1
	_state["judge_seq"] = _judge_seq

	if is_hold_tick:
		# LONG 持续 tick：只刷数据类组件（不重播判定指示 / 偏移指示 / 背景闪光）
		_refresh(["combo", "accuracy", "pp", "score_add", "score"])
		return

	_state["judge_text"] = result
	_state["judge_color"] = cl
	_state["early_text"] = offset if offset.begins_with("+") else ""
	_state["late_text"] = offset if offset.begins_with("-") else ""
	if result == "Miss":
		_state["early_text"] = ""
		_state["late_text"] = ""

	_refresh_all()
	_set_progress_bar_color(cl)

	if result != "Miss":
		flash_requested.emit()


# ==================== 进度条分段 ====================

func _on_progress_bar_value_changed(value: float) -> void:
	if get_parent().is_pause:
		return

	var anchor_l = 0.0 if not _last_rect else _last_rect.anchor_right
	if not _current_rect:
		_current_rect = ColorRect.new()

		_current_rect.anchor_left = anchor_l if anchor_l < 0.002 else anchor_l - 0.001
		_current_rect.color = PROGRESS_BAR_IDLE_COLOR if not _last_rect else _last_rect.color
		_current_rect.size.y = progress_bar.size.y

		_last_rect = _current_rect
		progress_bar.add_child(_current_rect)

	_current_rect.anchor_right = value / progress_bar.max_value

	if value >= progress_bar.max_value:
		game_finished_requested.emit()


func _set_progress_bar_color(cl: Color) -> void:
	if not _current_rect or (_current_rect.size.x > 15 and cl != _current_rect.color):
		_current_rect = null
		_on_progress_bar_value_changed(progress_bar.value)
		if _current_rect:
			_current_rect.color = cl
		return
	_current_rect.color = cl


# ==================== 调试悬浮 ====================

func _update_debug_overlay() -> void:
	var fps = Engine.get_frames_per_second()
	var frame_ms = (1000.0 / max(1.0, float(fps)))
	var draw_calls = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var objects_in_frame = int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	var memory_static_mb = float(Performance.get_monitor(Performance.MEMORY_STATIC)) / (1024.0 * 1024.0)
	var memory_static_max_mb = float(Performance.get_monitor(Performance.MEMORY_STATIC_MAX)) / (1024.0 * 1024.0)

	%DebugInfo.text = "FPS: %d (%.2f ms)\n渲染: DrawCalls %d | Objects %d\n内存: %.1f MB / 峰值 %.1f MB" % [
		fps,
		frame_ms,
		draw_calls,
		objects_in_frame,
		memory_static_mb,
		memory_static_max_mb,
	]


# ==================== 编辑 / 预览模式 ====================

func set_edit_mode(on: bool) -> void:
	if edit_mode == on:
		return
	edit_mode = on
	for c in get_components():
		(c as HudComponent).editing = on
		(c as HudComponent).refresh_visible()
	progress_bar.visible = not on
	%DebugInfo.visible = (not on) and show_debug_info
	if on:
		_fill_preview_state()
		_preview_timer = 0.0
		_score_shown = _score_target
		_state["score_shown"] = _score_shown
		_state["pending"] = 0
		_refresh_all()
	else:
		init_display()


## 编辑模式的示例数据：不依赖真实对局，也能看出各组件在长什么样
func _fill_preview_state() -> void:
	# 伪装成「刚发生一次判定」：判定指示 / 本次得分 / 偏移指示都靠 judge_seq 变化来重播动画
	# 与切换可见性，不推进序号的话进编辑模式会看到几个空框。
	_judge_seq += 1
	_state["judge_seq"] = _judge_seq
	_score_target = 1234567
	_score_shown = 1234567
	_state["combo"] = 128
	_state["score_raw"] = 1234567
	_state["score_shown"] = 1234567
	_state["score_add"] = 1234
	_state["pending"] = 0
	_state["accuracy"] = 0.9961
	_state["pp"] = 998.75
	_state["judge_text"] = "Perfect"
	_state["judge_color"] = color_map["Perfect"]
	_state["early_text"] = "+12.3 ms"
	_state["late_text"] = "-8.0 ms"
	_state["album"] = "东方 Project 原曲集"
	_state["song"] = "U.N.オーエンは彼女なのか？"
	_state["midi_name"] = "sample_chart"
	_state["difficulty"] = "Lunatic"


## 编辑模式循环播放一次假判定，方便调动画参数
func _trigger_preview_judgment() -> void:
	var results := ["Perfect", "Perfect", "Great", "Good", "Bad", "Miss"]
	var r: String = results[randi() % results.size()]
	_judge_seq += 1
	_state["judge_seq"] = _judge_seq
	_state["combo"] = int(_state.get("combo", 0)) + 1
	_state["accuracy"] = clampf(float(_state.get("accuracy", 1.0)) + randf_range(-0.002, 0.001), 0.0, 1.0)
	_state["pp"] = float(_state.get("pp", 0.0)) + randf_range(-0.4, 1.2)
	var add := randi() % 2400 + 200
	_state["score_add"] = add
	_score_start = _score_shown
	_score_target = _score_target + add
	_score_t = 0.0
	_state["score_raw"] = _score_target
	_state["judge_text"] = r
	_state["judge_color"] = color_map.get(r, Color.WHITE)
	var off := randf_range(-30.0, 30.0)
	_state["early_text"] = ("+%.1f ms" % off) if off >= 0.0 else ""
	_state["late_text"] = ("%.1f ms" % off) if off < 0.0 else ""
	_refresh_all()


## 强制播一次假判定（编辑器「预览动画」按钮）
func preview_once() -> void:
	_trigger_preview_judgment()

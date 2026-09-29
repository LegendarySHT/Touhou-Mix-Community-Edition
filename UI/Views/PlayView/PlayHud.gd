class_name PlayHud
extends Control

## PlayView HUD 展示层
## 挂载在 PlayView.tscn 的 Layer 节点上，负责：
## - 判定 UI（Perfect/Great/... 中心文字、early/late、combo、分数增量、进度条分段色、背景闪光请求）
## - 分数增量消化（_process 逐帧）
## - 调试悬浮（FPS/DrawCalls/内存）
## 计分数据源（ScoreCalculator）仍在 PlayView，本层只做展示。

## 进度条到达最大值（由 PlayView 连接 _on_game_finished）
signal game_finished_requested
## 判定命中请求背景闪光（由 PlayView 连接 bg_ctrl.flash）
signal flash_requested

@onready var ani: AnimationManager = AniMGR

@onready var combo: Label = $Combo/count
@onready var score: Label = $Score/count
@onready var score_add: Label = $Score/add
@onready var center: VBoxContainer = $Center
@onready var center_text: Label = $Center/type
@onready var early_text: Label = $Center/up
@onready var late_text: Label = $Center/down
@onready var pp_text: Label = $LeftBottom
@onready var accuracy_text: Label = $RightBottom
@onready var progress_bar: ProgressBar = $TopProgressBar
@onready var debug_info_label: Label = $DebugInfo

const PROGRESS_BAR_IDLE_COLOR: Color = Color.BLACK

## 判定色（与 ScoreView / recordListItem 保持一致：Perfect 品红 / Great 橙 / Good 绿 / Bad 蓝 / Miss 红）
const color_map = {
	"Perfect": Color("#FF50FD"),
	"Great": Color("#FF7600"),
	"Good": Color("#0AE000"),
	"Bad": Color("#1CB0FF"),
	"Miss": Color("#DC3450")
}

## 分数增量消化（_process 逐帧取 sqrt 收敛到 0）
var score_wait_to_add: int = 0
## 分数显示 int 累加（避免每帧 parse Label 文本）
var _score_display: int = 0

## 调试悬浮
var show_debug_info: bool = false
var debug_info_refresh_interval: float = 0.5
var debug_info_elapsed: float = 0.0

# ---- 帧内判定 UI 合并刷新 ----
# 三押/多指同帧多次判定时，Label.set_text / add_theme_color_override / tween 创建 / 全屏闪光
# 都是引擎 C++ 原生开销（GDScript profiler 不统计），同帧 ×N 会叠加成帧时间尖峰。
# 策略：计分数据（record_judgment / score_wait_to_add）逐判定实时累加，展示部分攒到帧末
# call_deferred 合并刷一次 —— 同帧 3 次判定只更新 1 次 UI。
var _judge_ui_dirty: bool = false
var _judge_ui_result: String = ""
var _judge_ui_offset: String = ""
var _judge_ui_cl: Color = Color.WHITE
var _judge_ui_snap: Dictionary = {}
# LONG 持续加分 tick：只刷数据类 UI，跳过 center 动画/偏移指示/背景闪光（保持旧轻量语义）
var _judge_ui_hold_tick: bool = false

# ---- 进度条分段 ----
var _current_rect: ColorRect = null
var _last_rect: ColorRect = null
## 上次写入进度条的显示值（毫秒）；节流阈值：差 <10ms 不触发 value_changed（10ms 对细进度条不可见）
const _PROGRESS_THROTTLE_MS := 10.0
var _last_progress_shown: float = 0.0


func _ready() -> void:
	set_process(true)


func _process(delta: float) -> void:
	if not visible:
		return

	# 分数增量逐帧消化
	if score_wait_to_add > 0:
		var amount = int(sqrt(score_wait_to_add))
		_score_display += amount
		score.text = str(_score_display)
		score_wait_to_add -= amount

	# 调试悬浮刷新
	if show_debug_info and debug_info_label and debug_info_label.visible:
		debug_info_elapsed += delta
		if debug_info_elapsed >= debug_info_refresh_interval:
			debug_info_elapsed = 0.0
			_update_debug_overlay()


# ========== 公共 API（PlayView 调用） ==========

## 每局开始复位全部展示（分数/连击/判定中心/进度条）
func init_display() -> void:
	_score_display = 0
	score.text = "0"
	combo.text = "0"
	score_wait_to_add = 0
	score_add.text = "+0"

	pp_text.text = "0.00pp"
	accuracy_text.text = "100.00%"

	center.modulate.a = 0

	_current_rect = null
	_last_rect = null
	_last_progress_shown = 0.0
	progress_bar.value = 0
	for i in progress_bar.get_children():
		i.queue_free()


## 判定回调（PlayView 算好 snap 后传入；含 LONG hold tick 轻量路径）
func on_note_judged(result: String, offset: String, snap: Dictionary, is_hold_tick: bool = false) -> void:
	_score_add_accumulate(int(snap["last_score_add"]))
	_queue_judge_ui(result, offset, color_map.get(result, Color.WHITE), snap, is_hold_tick)


func set_progress_max(v: float) -> void:
	progress_bar.max_value = v


## 进度条写入（节流：与上次显示值差 <10ms 不写，避免每帧触发 value_changed/锚点布局更新）
## 到达 max 时强制写入，保证进度条路径的结算检测不丢
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
	if debug_info_label == null:
		return
	debug_info_label.visible = debug_visible
	debug_info_elapsed = debug_info_refresh_interval
	if visible:
		_update_debug_overlay()


# ========== 判定 UI 合并刷新 ==========

func _score_add_accumulate(amount: int) -> void:
	if amount == 0:
		return
	score_wait_to_add += amount

## 存展示快照并排定帧末刷新；同帧后续判定只覆盖快照，不重复排队。
## 用 call_deferred 而非 _process 做帧末 flush：PlayView._process 先于子节点 FlowArea._process
## 执行，auto 判定发生在 FlowArea._process，若用 _process 刷会把反馈推迟一帧；call_deferred
## 在整帧结束后统一 flush，覆盖 input / PlayView._process / FlowArea._process 所有来源的判定。
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

	center_text.text = result
	center_text.add_theme_color_override("font_color", cl)

	# combo显示
	combo.text = str(snap["combo"])

	# 增加分数（增量已逐判定累加到 score_wait_to_add，这里只刷展示）
	var score_add_amount := int(snap["last_score_add"])
	if score_add_amount != 0:
		score_add.text = "+%d" % score_add_amount
		score_add.modulate.a = 1
		var tween = ani._create_tween("score_add_out")
		tween.set_trans(Tween.TRANS_CUBIC)
		tween.tween_property(score_add, "modulate:a", 0.0, 2)
		ani.animate_pulse(score_add, 1, 1.1, 0.1, "score_pluse")

	# 设置进度条颜色
	_set_progress_bar_color(cl)

	# pp和准度
	pp_text.text = snap["pp_text"]
	accuracy_text.text = snap["accuracy_text"]

	# LONG hold tick：轻量路径，到这里就结束（不清偏移指示、不播 center 动画、不闪背景）
	if is_hold_tick:
		return

	# 显示偏移
	early_text.self_modulate.a = 0
	late_text.self_modulate.a = 0
	if result != "Miss" and offset != "":
		if offset[0] == "+":
			early_text.text = offset
			early_text.self_modulate.a = 1
		else:
			late_text.text = offset
			late_text.self_modulate.a = 1

	# 动画
	center.rotation_degrees = (randf()-0.5) * 5
	var pulse: Tween = ani._create_tween("center pluse")
	pulse.set_parallel(true)
	center.scale = Vector2.ONE * 1.1
	pulse.tween_property(center, "scale", Vector2.ONE, 0.1)
	pulse.tween_property(center, "rotation_degrees", 0, 0.1)

	var fade = ani._create_tween("center fade out")
	center.modulate.a = 1
	fade.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	fade.tween_property(center, "modulate:a", 0.0, 2)

	if result != "Miss":
		flash_requested.emit()


# ========== 进度条分段 ==========

## 进度条 value_changed（tscn 连接）：维护分段颜色并检测游戏结束
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

	# 游戏结束
	if value >= progress_bar.max_value:
		game_finished_requested.emit()


func _set_progress_bar_color(cl: Color):
	if not _current_rect or (_current_rect.size.x > 15 and cl != _current_rect.color):
		_current_rect = null
		_on_progress_bar_value_changed(progress_bar.value)
		if _current_rect:
			_current_rect.color = cl
		return

	_current_rect.color = cl


# ========== 调试悬浮 ==========

func _update_debug_overlay() -> void:
	if debug_info_label == null:
		return

	var fps = Engine.get_frames_per_second()
	var frame_ms = (1000.0 / max(1.0, float(fps)))
	var draw_calls = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var objects_in_frame = int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	var memory_static_mb = float(Performance.get_monitor(Performance.MEMORY_STATIC)) / (1024.0 * 1024.0)
	var memory_static_max_mb = float(Performance.get_monitor(Performance.MEMORY_STATIC_MAX)) / (1024.0 * 1024.0)

	debug_info_label.text = "FPS: %d (%.2f ms)\n渲染: DrawCalls %d | Objects %d\n内存: %.1f MB / 峰值 %.1f MB" % [
		fps,
		frame_ms,
		draw_calls,
		objects_in_frame,
		memory_static_mb,
		memory_static_max_mb
	]

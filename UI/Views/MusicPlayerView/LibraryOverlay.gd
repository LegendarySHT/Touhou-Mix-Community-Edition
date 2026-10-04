extends Control
## 曲库网格的覆盖层：卡片挂在这里，滚动值也由本节点驱动。
##
## 机制照 SortedMidiView：页面只提供一个像素滚动量与滚动范围，卡片位置由页面
## 按锚点/offset_transform 表达。常规 GridContainer + VBox 布局无法池化复用——
## 每条数据都要一个真实节点，1882 首就是 1882 个节点。
##
## 本节点负责接收滚轮/拖拽输入，经注入的 Callable 读写页面的滚动值。
## 拖拽带惯性（照 SortedMidiView._step_fling）：0.1s 窗口采样松手速度，之后每帧
## 按速度推进并按固定减速度衰减，撞边界或停摆即止。

## 由页面注入的两个无参回调（不要用带方法名的 Callable.call("get")，
## 实际调用签名不匹配会报 "Expected 0 argument(s)"）
var get_scroll_y: Callable = Callable()
var set_scroll_y: Callable = Callable()
var get_scroll_max: Callable = Callable()
var scrolled: Callable = Callable()

## 滚轮每格滚动像素
const WHEEL_STEP := 120.0
## 惯性减速度（px/s²），同 SortedMidiView
const FLING_DECAY := 1000.0
## 速度采样窗口（秒），同原生 ScrollContainer
const SAMPLE_WINDOW := 0.1

var _dragging: bool = false
## 本次拖动累计位移 / 上次采样点位移（用于算松手速度）
var _drag_accum: float = 0.0
var _sample_accum: float = 0.0
var _sample_time: float = 0.0
var _fling_velocity: float = 0.0
var _flinging: bool = false

func _ready() -> void:
	set_process(false)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_stop_fling()
			_scroll_by(-WHEEL_STEP)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_stop_fling()
			_scroll_by(WHEEL_STEP)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_stop_fling()
				_dragging = true
				_drag_accum = 0.0
				_sample_accum = 0.0
				_sample_time = 0.0
				set_process(true)
				accept_event()   # 按下即吃掉，避免穿透到下层按钮
			else:
				_dragging = false
				# 用最后一段采样窗口补全速度（快速轻扫也拿到惯性）
				if _sample_time > 0.0:
					_fling_velocity = (_drag_accum - _sample_accum) / maxf(_sample_time, 0.001)
				_launch_fling(_fling_velocity)
				accept_event()
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_drag_accum += mm.relative.y
		_scroll_by(mm.relative.y)
		accept_event()

func _process(delta: float) -> void:
	if _dragging:
		# 拖动中：每 0.1s 窗口记录一次拖动速度
		_sample_time += delta
		if _sample_time >= SAMPLE_WINDOW:
			_fling_velocity = (_drag_accum - _sample_accum) / _sample_time
			_sample_accum = _drag_accum
			_sample_time = 0.0
		return
	if _flinging:
		_step_fling(delta)
		return
	set_process(false)

## 每帧推进惯性：内容按速度位移，速度按减速度衰减；撞边界或停摆即止
func _step_fling(delta: float) -> void:
	var prev := _get_scroll()
	_scroll_by(_fling_velocity * delta)
	var s := 1.0 if _fling_velocity >= 0.0 else -1.0
	_fling_velocity = s * maxf(0.0, absf(_fling_velocity) - FLING_DECAY * delta)
	if _fling_velocity == 0.0 or absf(_get_scroll() - prev) < 0.5:
		_stop_fling()

func _stop_fling() -> void:
	_fling_velocity = 0.0
	_flinging = false

func _launch_fling(v: float) -> void:
	_fling_velocity = v
	_flinging = absf(v) > 1.0
	set_process(_flinging)

func _scroll_by(delta_px: float) -> void:
	if not set_scroll_y.is_valid() or not get_scroll_y.is_valid():
		return
	var cur: float = get_scroll_y.call()
	var v: float = clampf(cur - delta_px, 0.0, _max_scroll())
	if absf(v - cur) > 0.5:
		set_scroll_y.call(v)
		if scrolled.is_valid():
			scrolled.call(v)

func _get_scroll() -> float:
	if not get_scroll_y.is_valid():
		return 0.0
	return float(get_scroll_y.call())

func _max_scroll() -> float:
	if not get_scroll_max.is_valid():
		return 0.0
	return float(get_scroll_max.call())

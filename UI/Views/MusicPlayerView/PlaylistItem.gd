class_name PlaylistItem extends Button

## 播放列表中的一行：点击播放 + 移除；排序拖拽由列表容器 PlaylistList 统一处理
##
## 本体是 Button（toggle_mode）：点击 = 播放该首，button_pressed 由页面按 playlist_index 同步。
## 本体设 PASS，行内拖动不吞事件，会冒泡给上层（列表 → ScrollContainer）去滚列表。

signal remove_requested(index: int)
signal activated(index: int)

## 位移超过此值才算拖动，否则视为点击
const DRAG_THRESHOLD := 8.0

var index: int = -1
var is_current: bool = false
var midi: MidiData = null

## 行内点击追踪
var _row_pressing: bool = false
var _row_accum: float = 0.0
## 行内拖动过（超阈值）后抑制紧随其后的 pressed，避免拖动被当成点击
var _suppress_press: bool = false

@onready var _title: Label = $HBox/Title
@onready var _remove_btn: Button = $HBox/RemoveBtn
@onready var _drag_btn: Button = $HBox/DragBtn

func _ready() -> void:
	pressed.connect(_on_pressed)
	if _remove_btn != null:
		_remove_btn.pressed.connect(func(): remove_requested.emit(index))
	# 拖动把手是 STOP（点它不触发"播放该首"），把它的拖拽事件转交给列表处理；
	# 拖拽状态存在列表上，所以调序引起的整表重建不会把拖动中断。
	if _drag_btn != null:
		_drag_btn.gui_input.connect(_on_drag_btn_input)
	gui_input.connect(_on_row_input)

## 转交拖动把手的按下/松开给列表：位移由列表按鼠标位置轮询现算（调序会重建行、
## 释放把手节点，焦点会丢，所以不依赖把手收到 motion/release）。
func _on_drag_btn_input(event: InputEvent) -> void:
	var list := get_parent() as PlaylistList
	if list == null:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			list.begin_handle_drag(index)
		else:
			list.end_handle_drag()

## 面板隐藏/列表重建后放弃当前点击追踪，避免隐藏后仍处理残留事件
func cancel_drag() -> void:
	_row_pressing = false
	_row_accum = 0.0

## current=true 时按钮处于按下态（由页面按 playlist_index 同步）
func setup_with(p_midi: MidiData, idx: int, current: bool, animate_in: bool = false) -> void:
	midi = p_midi
	index = idx
	is_current = current
	if animate_in:
		modulate.a = 0.0
		AniMGR.animate_fade_in(self, 0.22, "plitem_%d" % get_instance_id())
	if _title != null:
		_title.set_scroll_text("" if p_midi == null else (
			p_midi.song_name if not p_midi.song_name.is_empty() else p_midi.name))
	if button_pressed != current:
		set_pressed_no_signal(current)

func _on_pressed() -> void:
	if _suppress_press:
		_suppress_press = false
		return
	if index >= 0:
		activated.emit(index)

## 行内按下→松开 = 点击（由 Button 自身发 pressed）；拖动则不 accept，
## 事件继续冒泡给上层滚列表；拖动过则置抑制位吞掉这一次 clicked
func _on_row_input(event: InputEvent) -> void:
	if not is_inside_tree() or not is_visible_in_tree():
		cancel_drag()
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_row_pressing = true
			_row_accum = 0.0
			_suppress_press = false
		else:
			_row_pressing = false
	elif event is InputEventMouseMotion and _row_pressing:
		var mm := event as InputEventMouseMotion
		if mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
			_row_accum += mm.relative.y
			if absf(_row_accum) > DRAG_THRESHOLD:
				_suppress_press = true

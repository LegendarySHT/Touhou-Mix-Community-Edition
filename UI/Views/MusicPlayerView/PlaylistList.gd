class_name PlaylistList extends VBoxContainer

## 播放列表的列表容器：项的排序拖拽在这里统一处理。
##
## 拖拽状态放在列表上、不放项上——调序会触发整表重建（项被释放重建），
## 状态挂在项上会随重建丢失，表现为「移动一位后就跟丢」。
## 只有按在行的拖动把手（DragBtn，已设 IGNORE 透传）上才进入调序；
## 其余位置不拦截，事件继续冒泡给上层 ScrollContainer 滚列表。

signal move_requested(from_index: int, to_index: int)

## 位移超过此值才判定为拖动
const DRAG_THRESHOLD := 8.0

var _dragging: bool = false
var _from_index: int = -1
## 拖动起点（列表本地坐标）。位移每帧按"当前鼠标位置 − 起点"现算，
## 不依赖收到 motion 事件——调序会重建行、释放把手节点，鼠标焦点会丢，
## 事件不再保证送达；轮询才是稳的。
var _drag_start_y: float = 0.0
var _accum: float = 0.0

## 由行内的拖动把手转发按下/松开（把手是 STOP：点它不会触发"播放该首"）。
## 拖拽状态存在列表上，所以整表重建（调序会重建）也不会丢。
func begin_handle_drag(idx: int) -> void:
	_dragging = true
	_from_index = idx
	_accum = 0.0
	_drag_start_y = get_local_mouse_position().y
	set_process(true)

func end_handle_drag() -> void:
	_dragging = false
	_from_index = -1
	_accum = 0.0
	set_process(false)

func _process(_delta: float) -> void:
	if not _dragging:
		set_process(false)
		return
	# 松开即结束：即便 release 事件被吞掉（把手节点已重建）也能靠这里收尾
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		end_handle_drag()
		return
	_accum = get_local_mouse_position().y - _drag_start_y
	if absf(_accum) > DRAG_THRESHOLD:
		_move_by_drag()

## 按累计位移换算目标行；每跨过一行请求移动一次，并把拖动起点整体平移一格，
## 避免下一帧用它算出同一个目标行而重复触发。
func _move_by_drag() -> void:
	var stride := _row_stride()
	if stride <= 0.0:
		return
	var to := clampi(_from_index + int(round(_accum / stride)), 0, _item_count() - 1)
	if to == _from_index:
		return
	var from := _from_index
	_drag_start_y += float(to - from) * stride
	_from_index = to
	move_requested.emit(from, to)

## 行步进 = 项高 + 容器 separation
func _row_stride() -> float:
	for c in get_children():
		var item := c as PlaylistItem
		if item != null:
			return maxf(item.size.y + float(get_theme_constant("separation")), 1.0)
	return 1.0

func _item_count() -> int:
	var n := 0
	for c in get_children():
		if c is PlaylistItem:
			n += 1
	return n

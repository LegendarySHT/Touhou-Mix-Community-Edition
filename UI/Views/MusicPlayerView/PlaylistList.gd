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
var _accum: float = 0.0

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			var idx := _handle_index_at(mb.position)
			if idx < 0:
				return
			_dragging = true
			_from_index = idx
			_accum = 0.0
			accept_event()   # 调序期间不让滚动容器同时滚
		elif _dragging:
			_end_drag()
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		if not (mm.button_mask & MOUSE_BUTTON_MASK_LEFT):
			_end_drag()
			return
		_accum += mm.relative.y
		if absf(_accum) > DRAG_THRESHOLD:
			_move_by_drag()
		accept_event()

func _end_drag() -> void:
	_dragging = false
	_from_index = -1
	_accum = 0.0

## 按下点落在某行的拖动把手上时返回该项索引（本地坐标判定），否则返回 -1
func _handle_index_at(pos: Vector2) -> int:
	for c in get_children():
		var item := c as PlaylistItem
		if item == null or not item.visible:
			continue
		var item_rect := Rect2(item.position, item.size)
		if not item_rect.has_point(pos):
			continue
		var h := item.get_handle_rect()
		if Rect2(item_rect.position + h.position, h.size).has_point(pos):
			return item.index
		return -1
	return -1

## 按累计位移换算目标行；每跨过一行请求移动一次，并把位移减去对应行高
func _move_by_drag() -> void:
	var stride := _row_stride()
	if stride <= 0.0:
		return
	var to := clampi(_from_index + int(round(_accum / stride)), 0, _item_count() - 1)
	if to == _from_index:
		return
	_accum -= (to - _from_index) * stride
	var from := _from_index
	_from_index = to   # 调序后该项落到新位置，后续位移以新位置为基准
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

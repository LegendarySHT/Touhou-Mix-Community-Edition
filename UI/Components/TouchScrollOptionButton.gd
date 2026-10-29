extends OptionButton
class_name TouchScrollOptionButton

## 让 OptionButton 的原生 PopupMenu 支持触摸拖动滚动。
##
## 机制：
##   1. items → PASS → 事件穿透到 ScrollContainer 实现原生触摸拖拽
##   2. hide_on_item_selection=false → 阻止自动关闭
##   3. 监听 ScrollContainer gui_input 检测拖拽
##   4. item_selected 信号中判断：拖拽→回退选中项且不确认，非拖拽→发出 item_confirmed 确认选中
##   5. 关闭 popup 时用 set_v_scroll(get_v_scroll()) 清除 ScrollContainer 卡住的拖拽状态

## 选项确认信号：一次有效点选（按下与松开同属一次点选）后发出，携带被选中的索引。
## 拖拽取消的选择不会发出本信号，外部据此决定是否响应选中变化。
signal item_confirmed(index: int)

## 判定为拖拽滚动所需的最小位移（像素）：点击时的细微抖动不算拖拽，
## 否则一次正常点选会被当成滚动而回退，表现为"点了没反应"。
const DRAG_THRESHOLD_PX := 6.0

var _drag_detected := false
var _pre_popup_selected := -1
var _press_pos := Vector2.ZERO

func _ready() -> void:
	var popup := get_popup()

	GLogger.info("TSOB _ready: connections=%d" % popup.index_pressed.get_connections().size(), "TSOB")

	# 阻止 activate_item 自动关闭弹窗（OptionButton 用 radio check items，
	# activate_item 检查的是 hide_on_checkable_item_selection 而非 hide_on_item_selection）
	popup.hide_on_checkable_item_selection = false
	popup.popup_hide.connect(_on_popup_hide)
	toggled.connect(_on_toggled)
	item_selected.connect(_on_item_selected)

	# items → PASS：事件穿透到 ScrollContainer 实现原生触摸拖拽
	var scroll := _find_scroll_container(popup)
	if scroll:
		_set_mouse_filter_recursive(scroll, Control.MOUSE_FILTER_PASS, true)
		scroll.gui_input.connect(_on_scroll_gui_input)
		GLogger.info("TSOB scroll configured", "TSOB")
	else:
		GLogger.warning("TSOB scroll NOT found", "TSOB")

func _on_toggled(_pressed: bool) -> void:
	if _pressed:
		_drag_detected = false
		_pre_popup_selected = selected
		_press_pos = get_viewport().get_mouse_position()

func _on_scroll_gui_input(event: InputEvent) -> void:
	if _drag_detected:
		return
	var pos := Vector2.ZERO
	var moved := false
	if event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		pos = event.global_position
		moved = true
	elif event is InputEventScreenDrag:
		pos = event.position
		moved = true
	if moved and pos.distance_to(_press_pos) > DRAG_THRESHOLD_PX:
		_drag_detected = true

func _on_item_selected(idx: int) -> void:
	GLogger.info("TSOB item_selected: idx=%d drag=%s pre=%d" % [idx, _drag_detected, _pre_popup_selected], "TSOB")
	if _drag_detected:
		_drag_detected = false
		# 拖拽后松手：恢复到之前的选择，弹窗保持打开，且不确认本次选中
		if _pre_popup_selected >= 0 and _pre_popup_selected != idx:
			select(_pre_popup_selected)
		return
	# 有效点选：关闭弹窗并确认本次选中
	get_popup().hide()
	item_confirmed.emit(idx)

func _on_popup_hide() -> void:
	# 重置父级 ScrollContainer 的卡住状态
	var parent_scroll := _find_parent_scroll()
	if parent_scroll:
		parent_scroll.set_v_scroll(parent_scroll.get_v_scroll())

	# 重置 popup 内部 ScrollContainer 的卡住状态
	var scroll := _find_scroll_container(get_popup())
	if scroll:
		scroll.set_v_scroll(scroll.get_v_scroll())

func _find_parent_scroll() -> ScrollContainer:
	var node := get_parent()
	while node:
		if node is ScrollContainer:
			return node
		node = node.get_parent()
	return null

func _find_scroll_container(node: Node) -> ScrollContainer:
	for child in node.get_children(true):
		if child is ScrollContainer:
			return child
		var found := _find_scroll_container(child)
		if found:
			return found
	return null

func _set_mouse_filter_recursive(node: Node, filter: int, skip_root: bool = false) -> void:
	if not skip_root and node is Control:
		node.mouse_filter = filter
	for child in node.get_children(true):
		_set_mouse_filter_recursive(child, filter, false)

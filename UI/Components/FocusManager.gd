extends Control

class_name FocusManager

@onready var ui: UIStateManager = UiStatMGR
@onready var ani: AnimationManager = AniMGR

var _last_input_was_keyboard := false
var _skew_c: Control = null

# 弹窗打开前持有焦点的控件，关闭时恢复（仅键盘输入触发）
var _popup_source_ctrl: Control = null

# FocusManager 接管的焦点导航按键（方向键 + Tab + 确认键）
const _NAV_KEYS: Array = [
	KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_TAB, KEY_ENTER, KEY_KP_ENTER,
]

func _ready() -> void:
	get_viewport().gui_focus_changed.connect(_on_focus_change)
	_skew_c = get_node_or_null(PathRegistry.SKEW_C)
	# PopupWindow 是 Main 下子节点，_ready 时序晚于本节点，延迟连接
	call_deferred("_connect_popup_window")

func _connect_popup_window() -> void:
	var popup = PopupWindow.instance
	if popup:
		if not popup.window_close.is_connected(_restore_popup_focus):
			popup.window_close.connect(_restore_popup_focus)
		if not popup.about_to_popup.is_connected(_on_popup_about_to_show):
			popup.about_to_popup.connect(_on_popup_about_to_show)

## 弹窗即将弹出：键盘输入打开时记录来源焦点，并延迟到弹出后移入首个可聚焦项
## 鼠标/触摸打开时不动焦点（避免点击弹窗按钮时焦点被抢走）
func _on_popup_about_to_show() -> void:
	if not _last_input_was_keyboard:
		return
	if _popup_source_ctrl == null:
		_popup_source_ctrl = _safe_focus_owner()
	call_deferred("_grab_first_focusable", PopupWindow.instance)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		_last_input_was_keyboard = true
		_handle_key_navigation(event)
	elif event is InputEventScreenTouch and event.pressed:
		_last_input_was_keyboard = false

## 接管焦点导航按键：按键时校验当前焦点是否属于本页，否则移动到本页合法项
func _handle_key_navigation(event: InputEventKey) -> void:
	if not _is_nav_key(event.keycode):
		return
	# 打歌界面：无聚焦控件（焦点为 null），方向键/Enter/Tab 由 FlowArea 等自行处理，
	# 这里直接放行，避免 set_input_as_handled 吞掉按键
	if ui.current_state == ui.UIState.PLAY_VIEW:
		return

	# 弹窗场景：焦点不在弹窗内则移入弹窗，并记录来源以便关闭时恢复
	var popup = PopupWindow.instance
	if popup and popup.visible:
		if not _focus_inside(popup):
			if _popup_source_ctrl == null:
				_popup_source_ctrl = _safe_focus_owner()
			_grab_first_focusable(popup)
			get_viewport().set_input_as_handled()
		return

	# 常规页面：焦点无效（null/隐藏/已释放）时重定向到当前页默认合法项
	var focus_owner := _safe_focus_owner()
	if focus_owner == null or not is_valid_focus(focus_owner):
		_redirect_focus_by_state()
		get_viewport().set_input_as_handled()

func _is_nav_key(keycode: Key) -> bool:
	return keycode in _NAV_KEYS

func _safe_focus_owner() -> Control:
	var focus_owner := get_viewport().gui_get_focus_owner()
	if focus_owner == null or not is_instance_valid(focus_owner):
		return null
	return focus_owner

## 焦点是否有效：在树、可见、且允许聚焦
func is_valid_focus(focus_owner: Control) -> bool:
	return focus_owner.is_visible_in_tree() and focus_owner.focus_mode != Control.FOCUS_NONE

## 当前焦点是否位于 node 内部（含 node 本身）
func _focus_inside(node: Node) -> bool:
	var focus_owner := _safe_focus_owner()
	if focus_owner == null:
		return false
	return node == focus_owner or node.is_ancestor_of(focus_owner)

## 让 node 内第一个可见可聚焦的控件获得焦点
func _grab_first_focusable(root: Node) -> void:
	var target := _find_first_focusable(root)
	if target:
		target.grab_focus()

func _find_first_focusable(node: Node) -> Control:
	if node is Control and node.focus_mode != Control.FOCUS_NONE and node.is_visible_in_tree():
		return node
	for child in node.get_children():
		var r := _find_first_focusable(child)
		if r:
			return r
	return null

## 弹窗关闭：恢复打开前（键盘操作）的焦点位置
func _restore_popup_focus() -> void:
	var src := _popup_source_ctrl
	_popup_source_ctrl = null
	if src and is_instance_valid(src) and src.is_visible_in_tree():
		src.grab_focus()

func _on_focus_change(node: Control):
	# print("[FocusMGR] Focus changed to: %s" % node.name)
	if node == null:
		return
	# 焦点落到 skew/C（视图容器）或其下的列表容器时，按当前 UI 状态转发给选中项。
	# 触发场景：ShortCutMenu 搜索按钮 focus_neighbor_left → AlbumList（按左方向键）等。
	if node == _skew_c or ("selected_item" in node):
		_redirect_focus_by_state()

## 按当前 UI 状态把焦点转发到本页合法项（列表选中项 / 设置导航 / 商店首项）
## 由按键接管触发（_handle_key_navigation）与 _on_focus_change 兜底共用
func _redirect_focus_by_state() -> void:
	match ui.current_state:
		ui.UIState.ALBUM_VIEW:
			_grab_list_selected(PathRegistry.ALBUM_LIST)
		ui.UIState.SONG_VIEW:
			_grab_list_selected(PathRegistry.SONG_LIST)
		ui.UIState.SORTED_VIEW:
			_grab_list_selected(PathRegistry.SORTED_MIDIS_LIST)
		ui.UIState.MIDI_VIEW:
			_grab_list_selected(PathRegistry.MIDI_LIST)
		ui.UIState.STORE_VIEW:
			_grab_store_first()
		ui.UIState.SETTINGS_VIEW:
			_redirect_settings_focus()

## 让列表的选中项获得焦点：无选中项时选首项兜底；列表为空则不做动作
func _grab_list_selected(list_path: String) -> void:
	var nd = get_node_or_null(list_path)
	if nd == null or not ("selected_item" in nd):
		return
	# 虚拟化列表：项可能已滚出屏幕被释放，交给其负责先滚动补位再聚焦
	if nd.has_method("focus_selected_item"):
		nd.call("focus_selected_item")
		return
	# 无选中项时选首项兜底（进入视图但尚未选中任何项，默认聚焦第一项）
	if nd.selected_item == -1 and nd.list_items.size() > 0:
		if nd.has_method("select_item"):
			nd.select_item(0)
	if nd.selected_item < 0 or nd.selected_item >= nd.list_items.size():
		return
	var selected_node = nd.get_selected_node()
	if selected_node == null:
		return
	selected_node.button.grab_focus()
	GLogger.debug("[FocusMGR] 焦点转发 → %s 选中项 #%d" % [list_path, nd.selected_item], "FocusMGR")

## SETTINGS_VIEW：资源管理子页可见时聚焦首个标签按钮，否则聚焦左侧当前选中的快捷按钮
func _redirect_settings_focus() -> void:
	var sv = get_node_or_null(PathRegistry.SETTING_VIEW)
	if sv == null:
		return
	var resource_view = sv.get_node_or_null("ResourceView")
	if resource_view and resource_view.visible:
		if resource_view.has_method("focus_first_tab"):
			resource_view.focus_first_tab()
		return
	if sv.short_cut_btn:
		# 聚焦当前按下的快捷按钮（对应设置项所在区域），而非容器本身
		var pressed: Button = null
		for b in sv.short_cut_btn.get_children():
			if b is Button and b.button_pressed:
				pressed = b
				break
		if pressed:
			pressed.grab_focus()
		else:
			sv.short_cut_btn.grab_focus()

## STORE_VIEW：交给商店视图自己决定落点（标签页 / 当前列表第一张可见卡片）。
## 虚拟化列表的节点会被池回收，不能再按「容器第一项」取节点。
func _grab_store_first() -> void:
	var store = get_node_or_null(PathRegistry.STORE_VIEW)
	if store and store.has_method("focus_first"):
		store.call("focus_first")

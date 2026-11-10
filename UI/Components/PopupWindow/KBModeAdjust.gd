extends Control

class_name KBModeAdjust

## 不能作为键位的按键（保留作取消/删除/导航等功能键）
## 只作用于键盘输入；鼠标左键在 token 化阶段就被排除，手柄与 MIDI 没有额外黑名单
const BLACKLISTED_KEYS: Array[Key] = [
	Key.KEY_ESCAPE, Key.KEY_TAB, Key.KEY_BACKTAB, Key.KEY_BACKSPACE, Key.KEY_DELETE,
	Key.KEY_ENTER, Key.KEY_KP_ENTER,
	Key.KEY_HOME, Key.KEY_END, Key.KEY_PAGEUP, Key.KEY_PAGEDOWN, Key.KEY_INSERT,
	Key.KEY_UP, Key.KEY_DOWN, Key.KEY_LEFT, Key.KEY_RIGHT,
	Key.KEY_F1, Key.KEY_F2, Key.KEY_F3, Key.KEY_F4, Key.KEY_F5, Key.KEY_F6,
	Key.KEY_F7, Key.KEY_F8, Key.KEY_F9, Key.KEY_F10, Key.KEY_F11, Key.KEY_F12,
	Key.KEY_F13, Key.KEY_F14, Key.KEY_F15, Key.KEY_F16,
	Key.KEY_PRINT, Key.KEY_SYSREQ, Key.KEY_SCROLLLOCK, Key.KEY_PAUSE, Key.KEY_MENU,
	Key.KEY_CAPSLOCK, Key.KEY_NUMLOCK,
	Key.KEY_CTRL, Key.KEY_SHIFT, Key.KEY_ALT, Key.KEY_META,
	Key.KEY_KP_ADD, Key.KEY_KP_SUBTRACT, Key.KEY_KP_MULTIPLY, Key.KEY_KP_DIVIDE,
	Key.KEY_KP_PERIOD, Key.KEY_KP_0,
]

## 键位项场景（用于动态实例化）
const KEY_ITEM_SCENE := preload("res://UI/Components/PopupWindow/KeySequenceItem.tscn")

## 拖出删除的判定余量（像素）：贴着按键框边缘划过时留一点缓冲，避免擦边就删
const DELETE_ZONE_MARGIN: float = 16.0

## 拖拽期间的提示文案
## 静止文案也由脚本写入：KeyArea 的 Hint 是页内普通节点，不依赖 tscn 里的占位文字
const HINT_IDLE := "拖动排序，拖出框外松开可删除；单击选中后可编辑"
const HINT_DRAGGING := "拖动排序 · 松开调整顺序"
const HINT_DELETE := "松开删除该按键"

# 节点引用
# 键盘模式开关 + 左右间距 + 轨道分隔线（HBox 左列）
# 交替轨道颜色（HBox 右列）

# 按键框内的拖拽提示
var _hint: Label = null

# 交替颜色序列按钮颜色（按索引保存，重建时保留）
var _alt_colors_state: Array[Color] = []

# 数据：每个 item 为 {"token": int, "display_name": String}
# token 统一表示键盘键 / MIDI 音符 / 鼠标键 / 手柄按钮与轴（编码见 ConfigParser）
var _items: Array = []
var _selected_index: int = -1
var _recording: bool = false

# 拖拽状态
var _dragged_item: KeySequenceItem = null
var _last_drop_index: int = -1  # 最近一次 drag_over 计算出的插入位置（item 索引）
var _dragging: bool = false
var _in_delete_zone: bool = false  # 光标是否已离开按键框（松手即删除）
var _drop_handled: bool = false    # 本次拖拽是否已按排序落位（落位后不再判定删除）

# 共享 ButtonGroup（确保所有 KeySequenceItem 互斥单选）
var _shared_button_group: ButtonGroup = ButtonGroup.new()

# 标记 %KeyDisplayNameEdit 的文本由程序设置（避免触发 text_changed 死循环）
var _suppress_display_name_signal: bool = false

func _ready() -> void:
	_hint = $KeyArea/Hint
	_hint.text = HINT_IDLE
	# 光标是否离开按键框只在拖拽期间需要，平时关掉逐帧轮询
	set_process(false)


## 由 PopupWindow.show_kb_mode_adjust 调用：解析配置字符串并重建 UI
## kb_mode：键盘模式开关（0/1）；gap：左右间距（偶数键位时中间额外间距，最低 0）
## alt_color / alt_count / alt_colors：交替轨道颜色配置（键盘模式覆盖音符颜色）
## lane_sep：轨道分隔线开关（0/1，仅键盘模式生效）
func init_adjust(current_keys: String, current_display_names: String,
		kb_mode: Variant = 1, alt_color: Variant = 1, alt_count: Variant = 2,
		alt_colors: String = "#ff0000,#0000ff", gap: Variant = 0, lane_sep: Variant = 0) -> void:
	_cancel_recording()
	# 显式重置按钮文本（_cancel_recording 在非录入态下不设置文本）
	%KeyConfigBtn.text = "输入按键"
	_items.clear()
	_selected_index = -1

	var tokens: Array = ConfigParser.parse_lane_bindings(current_keys)
	var names: Array[String] = ConfigParser.parse_keyboard_display_names(current_display_names, tokens.size())

	for i in tokens.size():
		_items.append({
			"token": int(tokens[i]),
			"display_name": names[i] if i < names.size() else ""
		})

	_rebuild_items()
	_refresh_detail_panel()
	%KeyName.text = "当前按键： -"

	# 键盘模式开关
	%EnableMode.button_pressed = bool(kb_mode)
	# 左右间距（最低 0）
	var safe_gap: int = max(0, int(gap))
	%KBModeGapEdit.text = str(safe_gap)
	# 轨道分隔线（仅键盘模式生效）
	%SeperateLine.button_pressed = bool(lane_sep)

	# 交替轨道颜色：数量最低 1，颜色序列按数量补齐
	%AltColorCheck.button_pressed = bool(alt_color)
	var safe_count: int = max(1, int(alt_count))
	%AltColorCountEdit.text = str(safe_count)
	var colors: Array[Color] = _parse_alt_colors(alt_colors)
	while colors.size() < safe_count:
		colors.append(Color.WHITE)
	colors.resize(safe_count)
	_rebuild_color_buttons(safe_count, colors)


## 返回当前配置给 PopupWindow.show_kb_mode_adjust
## 过滤掉未绑定（token 为 0）的 item，避免无效键写入配置
func get_result() -> Dictionary:
	var valid_keys: Array[String] = []
	var valid_names: Array[String] = []
	for item in _items:
		var token := int(item.get("token", ConfigParser.BINDING_NONE))
		if token == ConfigParser.BINDING_NONE:
			continue
		valid_keys.append(ConfigParser.binding_to_token_string(token))
		# strip_edges 保证与 parse_keyboard_display_names 的解析行为一致（round-trip）
		valid_names.append(String(item.get("display_name", "")).strip_edges())

	# 交替轨道颜色：数量最低 1（空/非法文本兜底为 1），颜色补齐到数量
	var alt_count: int = max(1, %AltColorCountEdit.text.to_int())
	var colors: Array[String] = []
	for btn in %ColorSeq.get_children():
		if btn is ColorPickerButton:
			colors.append("#" + (btn as ColorPickerButton).color.to_html())
	while colors.size() < alt_count:
		colors.append("#ffffff")
	colors.resize(alt_count)

	return {
		"keys": ",".join(valid_keys),
		"display_names": ",".join(valid_names),
		"keyboard_mode": 1 if %EnableMode.button_pressed else 0,
		"keyboard_mode_gap": max(0, %KBModeGapEdit.text.to_int()),
		"alt_color": 1 if %AltColorCheck.button_pressed else 0,
		"alt_count": alt_count,
		"alt_colors": ",".join(colors),
		"lane_separator": 1 if %SeperateLine.button_pressed else 0,
	}


# ===== 交替轨道颜色 =====

## 按数量重建颜色序列按钮（保留已有颜色；不够则生成，多余则移除）
## colors 非空时以传入为准（init_adjust 用配置初始化）
func _rebuild_color_buttons(count: int, colors: Array = []) -> void:
	var existing: Array = _alt_colors_state.duplicate()
	if not colors.is_empty():
		existing = colors
	# 移除所有 ColorPickerButton（保留「颜色序列」Label）
	for btn in %ColorSeq.get_children():
		if btn is ColorPickerButton:
			%ColorSeq.remove_child(btn)
			btn.queue_free()
	# 生成 count 个按钮（先设色再连信号，避免程序设色触发 color_changed 越界）
	_alt_colors_state.clear()
	for i in count:
		var btn := ColorPickerButton.new()
		btn.custom_minimum_size = Vector2(60, 60)
		btn.mouse_filter = Control.MOUSE_FILTER_PASS
		btn.size_flags_vertical = 4     # SHRINK_CENTER
		btn.color = existing[i] if i < existing.size() else Color.WHITE
		# 只统一取色器弹层形态（色板 + 滑条 + Hex），不挂 HexEdit：
		# 这里是按轨道数动态生成的色块序列，少则 2 个多则十几个，每个前面塞一个
		# 输入框会把「颜色序列」这一行彻底挤爆，手机上也点不动。
		ThemeMGR.setup_color_picker(btn, false)
		btn.color_changed.connect(_on_alt_color_changed.bind(i))
		%ColorSeq.add_child(btn)
		_alt_colors_state.append(btn.color)


## 数量 LineEdit 变化：数量 ≥1 时按新数量重建颜色序列按钮
func _on_alt_count_changed(new_text: String) -> void:
	var n := new_text.to_int()
	if n < 1:
		return  # 空/非法/0 → 不重建，由 get_result 兜底为 1
	_rebuild_color_buttons(n)


## 颜色按钮变化：记录到 _alt_colors_state（重建时保留）
func _on_alt_color_changed(col: Color, idx: int) -> void:
	if idx >= 0 and idx < _alt_colors_state.size():
		_alt_colors_state[idx] = col


## 解析交替颜色序列字符串（逗号分隔的 #RRGGBB / RRGGBB），空串或无效项跳过
func _parse_alt_colors(colors_str: String) -> Array[Color]:
	var result: Array[Color] = []
	if colors_str.is_empty():
		return result
	for part in colors_str.split(",", false):
		var p := part.strip_edges()
		if p.is_empty() or not Color.html_is_valid(p):
			continue
		result.append(Color.from_string(p, Color.WHITE))
	return result


# ===== UI 重建 =====

## 清空并重建 HBoxC 中所有 KeySequenceItem（保留 InsertPlace + AddBtn）
## 同步执行：立即 free 旧节点，避免 await 引发的时序问题
func _rebuild_items() -> void:
	# 立即释放所有现有的 KeySequenceItem
	for child in %KeySequenceFlow.get_children():
		if child is KeySequenceItem:
			%KeySequenceFlow.remove_child(child)
			child.free()

	# 实例化新的 KeySequenceItem
	for i in _items.size():
		var item: KeySequenceItem = KEY_ITEM_SCENE.instantiate()
		%KeySequenceFlow.add_child(item)
		%KeySequenceFlow.move_child(item, i)  # 插入到 InsertPlace 之前
		item.button_group = _shared_button_group
		var item_data: Dictionary = _items[i]
		item.set_data(int(item_data.get("token", ConfigParser.BINDING_NONE)),
			item_data.get("display_name", ""), i)
		# 连接信号
		item.item_selected.connect(_on_item_selected)
		item.drag_started.connect(_on_item_drag_started)
		item.drag_over.connect(_on_item_drag_over)
		item.drop_received.connect(_on_item_drop_received)
		item.drag_ended.connect(_on_item_drag_ended)

	# 确保 InsertPlace 在所有 item 之后、AddBtn 之前
	var insert_idx := _items.size()
	if %InsertPlace.get_parent() == %KeySequenceFlow:
		%KeySequenceFlow.move_child(%InsertPlace, insert_idx)
	%InsertPlace.visible = false


# ===== 选中 =====

func _on_item_selected(item: KeySequenceItem) -> void:
	_selected_index = item.item_index
	_refresh_detail_panel()


func _refresh_detail_panel() -> void:
	if _selected_index < 0 or _selected_index >= _items.size():
		%KeyName.text = "当前按键： -"
		_suppress_display_name_signal = true
		%KeyDisplayNameEdit.text = ""
		_suppress_display_name_signal = false
		return
	var item: Dictionary = _items[_selected_index]
	%KeyName.text = "当前按键： " + _binding_label(item)
	_suppress_display_name_signal = true
	%KeyDisplayNameEdit.text = item.get("display_name", "")
	_suppress_display_name_signal = false


# ===== AddBtn =====

func _on_add_btn_pressed() -> void:
	_items.append({"token": ConfigParser.BINDING_NONE, "display_name": ""})
	_rebuild_items()
	# 选中新增的项
	var new_idx := _items.size() - 1
	if new_idx >= 0:
		_select_item_by_index(new_idx)


func _select_item_by_index(idx: int) -> void:
	if idx < 0 or idx >= %KeySequenceFlow.get_child_count():
		return
	for child in %KeySequenceFlow.get_children():
		if child is KeySequenceItem and (child as KeySequenceItem).item_index == idx:
			(child as KeySequenceItem).set_pressed(true)
			_on_item_selected(child as KeySequenceItem)
			return


# ===== KeyConfig 录入 =====

func _on_key_config_btn_pressed() -> void:
	if _selected_index < 0:
		# 禁用按钮避免 await 期间重入产生多个 timer
		%KeyConfigBtn.disabled = true
		%KeyConfigBtn.text = "先选按键"
		await get_tree().create_timer(1.0).timeout
		%KeyConfigBtn.text = "输入按键"
		%KeyConfigBtn.disabled = false
		return
	if _recording:
		_cancel_recording()
	else:
		_start_recording()


func _start_recording() -> void:
	_recording = true
	%KeyConfigBtn.text = "等待输入..."
	# 录入期间独占键盘：焦点导航不接管方向键 / Tab
	if FocusMGR:
		FocusMGR.set_capture_disabled(true)
	# 实体键盘、MIDI 键盘、鼠标键、手柄都能录入，提示里点明，避免玩家以为只认实体按键
	%KeyName.text = "请按下按键、鼠标键、手柄按钮或扳机，或弹奏 MIDI 音符"
	# 释放 LineEdit 焦点，避免按键被吞
	%KeyDisplayNameEdit.release_focus()


func _cancel_recording() -> void:
	if not _recording:
		return
	_recording = false
	if FocusMGR:
		FocusMGR.set_capture_disabled(false)
	%KeyConfigBtn.text = "输入按键"
	# 取消录入（ESC 等）时把「当前按键」那行还原成选中项的真实绑定
	_refresh_detail_panel()


# ===== 显示名编辑 =====

func _on_display_name_changed(new_text: String) -> void:
	if _suppress_display_name_signal:
		return
	if _selected_index < 0 or _selected_index >= _items.size():
		return
	_items[_selected_index]["display_name"] = new_text
	# 同步刷新对应 KeySequenceItem 的按钮文本
	var item_node := _find_item_node_by_index(_selected_index)
	if item_node:
		item_node.display_name = new_text
		item_node.refresh_text()


func _find_item_node_by_index(idx: int) -> KeySequenceItem:
	for child in %KeySequenceFlow.get_children():
		if child is KeySequenceItem and (child as KeySequenceItem).item_index == idx:
			return child as KeySequenceItem
	return null


# ===== 按键录入与删除（_input） =====

func _input(event: InputEvent) -> void:
	# 用 is_visible_in_tree() 而非 visible：PopupWindow.hide() 不改子节点 visible，
	# 仅 visible 会在此窗口已隐藏但仍为当前 tab 时继续拦截按键
	if not is_visible_in_tree():
		return

	# 录入模式：实体键盘、MIDI 键盘、鼠标键与手柄都能写入当前槽位
	if _recording:
		_handle_recording_event(event)
		return

	if not (event is InputEventKey) or not event.pressed or event.is_echo():
		return
	var key_event: InputEventKey = event as InputEventKey

	# 非录入模式：LineEdit 有焦点时不拦截（让用户正常编辑文本）
	if %KeyDisplayNameEdit.has_focus() or %AltColorCountEdit.has_focus():
		return

	# 颜色选择器弹窗打开时不拦截（避免其中按 Backspace/Delete 误删按键）
	for btn in %ColorSeq.get_children():
		if btn is ColorPickerButton:
			var pp := (btn as ColorPickerButton).get_popup()
			if pp and pp.visible:
				return

	# Backspace / Delete → 删除选中项（无确认弹窗以避免嵌套 PopupWindow）
	if key_event.keycode in [Key.KEY_BACKSPACE, Key.KEY_DELETE]:
		if _selected_index >= 0:
			accept_event()
			_delete_selected()


## 录入态的输入处理：Esc / Backspace / Delete 保留为取消录入，
## 被排除的输入只给提示不写入，其余可用输入立即绑定并退出录入
func _handle_recording_event(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		# 键盘连发（长按重复）不是新的按下
		if key_event.is_echo():
			return
		if key_event.pressed and key_event.keycode in [
				Key.KEY_ESCAPE, Key.KEY_BACKSPACE, Key.KEY_DELETE]:
			accept_event()
			_cancel_recording()
			return

	# 鼠标左键保留给界面点击：只给提示，事件照常放行，否则录制期间按钮点不动
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		%KeyName.text = "不可用： 鼠标左键（保留给界面）"
		return

	var token := ConfigParser.binding_token_from_event(event)
	if token == ConfigParser.BINDING_NONE:
		# MIDI 的 Note Off 与其它消息也吞掉，避免录入期间触发别处的 MIDI 处理
		if event is InputEventMIDI:
			accept_event()
		return
	# 抬起事件不写入，等真正的按下
	if not ConfigParser.binding_event_pressed(event):
		return
	accept_event()
	if _is_blacklisted(token):
		var blocked := ConfigParser.binding_to_display_name(token)
		%KeyName.text = "不可用： " + blocked
		GLogger.warning("Binding '%s' is blacklisted" % blocked, "KBModeAdjust")
		return
	_apply_recorded_token(token)


## 该绑定是否被排除：键盘的功能键走黑名单，鼠标左键在 token 化阶段就已排除
func _is_blacklisted(token: int) -> bool:
	if token == ConfigParser.BINDING_NONE:
		return true
	if ConfigParser.binding_kind(token) != ConfigParser.BindingKind.KEY:
		return false
	return ConfigParser.binding_value(token) in BLACKLISTED_KEYS


## 把绑定写入当前选中项
func _apply_recorded_token(token: int) -> void:
	if _selected_index < 0 or _selected_index >= _items.size():
		_cancel_recording()
		return
	var label := ConfigParser.binding_to_display_name(token)
	# 同一个输入不能绑到两个槽位
	for i in _items.size():
		if i == _selected_index:
			continue
		if int(_items[i].get("token", ConfigParser.BINDING_NONE)) == token:
			%KeyName.text = "已绑定到第 %d 个按键" % (i + 1)
			GLogger.warning("Binding '%s' is already bound to item %d" % [label, i],
				"KBModeAdjust")
			_cancel_recording()
			return
	var old_token := int(_items[_selected_index].get("token", ConfigParser.BINDING_NONE))
	_items[_selected_index]["token"] = token
	_sync_display_name(_selected_index, old_token)
	# 刷新 UI
	%KeyName.text = "当前按键： " + label
	var item_node := _find_item_node_by_index(_selected_index)
	if item_node:
		item_node.binding_token = token
		item_node.display_name = String(_items[_selected_index].get("display_name", ""))
		item_node.refresh_text()
	# 退出录入模式
	_cancel_recording()


## 槽位的默认显示名（键名 / 音名 / 鼠标键 / 手柄键）
func _default_binding_name(token: int) -> String:
	return ConfigParser.binding_to_display_name(token)


## 重新录入后刷新显示名：只替换「仍是旧绑定默认名」的自动填充值，
## 玩家自己改过的名字保持不动
func _sync_display_name(idx: int, old_token: int) -> void:
	var current := String(_items[idx].get("display_name", "")).strip_edges()
	if not current.is_empty() and current != _default_binding_name(old_token):
		return
	var new_name := _default_binding_name(int(_items[idx].get("token", ConfigParser.BINDING_NONE)))
	_items[idx]["display_name"] = new_name
	_suppress_display_name_signal = true
	%KeyDisplayNameEdit.text = new_name
	_suppress_display_name_signal = false


## 槽位的显示文本：未绑定时显示未设置，否则用绑定的默认名
func _binding_label(item: Dictionary) -> String:
	var token := int(item.get("token", ConfigParser.BINDING_NONE))
	if token == ConfigParser.BINDING_NONE:
		return "未设置"
	return ConfigParser.binding_to_display_name(token)


## 删除当前选中的 item
func _delete_selected() -> void:
	if _selected_index < 0 or _selected_index >= _items.size():
		return
	_items.remove_at(_selected_index)
	_selected_index = -1
	_rebuild_items()
	_refresh_detail_panel()
	%KeyName.text = "当前按键： -"


# ===== 拖拽 =====

func _on_item_drag_started(item: KeySequenceItem) -> void:
	_dragged_item = item
	# 重置为 -1 表示尚未确定插入位置，确保首次 drag_over 能正确 move_child
	_last_drop_index = -1
	_drop_handled = false
	_dragging = true
	_in_delete_zone = false
	_hint.text = HINT_DRAGGING
	%InsertPlace.visible = true
	set_process(true)


## 拖拽期间逐帧判定光标是否已拖出按键框（拖放系统不会为「框外」发任何回调）
func _process(_delta: float) -> void:
	if not _dragging or not is_instance_valid(_dragged_item):
		return
	# 拖到一半窗口被关掉时等不到松手，直接复位
	if not is_visible_in_tree():
		_reset_drag_state()
		_hide_insert_place()
		return
	var outside := not _is_pointer_in_key_area()
	if outside == _in_delete_zone:
		return
	_set_delete_zone_active(outside)
	_hint.text = HINT_DELETE if outside else HINT_DRAGGING


## 切换「框外删除」高亮：按键框描边转警示色、拖动预览染红（提示文案由调用方设置）
func _set_delete_zone_active(active: bool) -> void:
	_in_delete_zone = active
	if is_instance_valid(_dragged_item):
		_dragged_item.set_drag_delete_state(active)
	if active:
		var danger := ThemeMGR.get_color("danger")
		# 复制主题里的凹陷盒再改描边：不能直接改，那份 StyleBox 是全主题共享的
		var base: StyleBox = $KeyArea.get_theme_stylebox("panel")
		var highlight := StyleBoxFlat.new()
		if base is StyleBoxFlat:
			highlight = (base as StyleBoxFlat).duplicate()
		highlight.bg_color = highlight.bg_color.lerp(danger, 0.12)
		highlight.border_color = danger
		highlight.set_border_width_all(2)
		$KeyArea.add_theme_stylebox_override("panel", highlight)
		_hint.add_theme_color_override("font_color", danger)
		# 排序落点标记在删除态没有意义，先收起来
		%InsertPlace.visible = false
	else:
		$KeyArea.remove_theme_stylebox_override("panel")
		_hint.remove_theme_color_override("font_color")
		%InsertPlace.visible = true


## 光标是否还在按键框内（判定用外扩过的矩形，贴边划过不触发删除）
func _is_pointer_in_key_area() -> bool:
	var area := $KeyArea as Control
	return area.get_global_rect().grow(DELETE_ZONE_MARGIN).has_point(area.get_global_mouse_position())


func _on_item_drag_over(target: KeySequenceItem, at_pos: Vector2) -> void:
	# 根据鼠标在 target 上的横向位置决定插入到 target 之前或之后
	var target_idx := target.item_index
	var insert_idx: int
	if at_pos.x < target.size.x / 2.0:
		insert_idx = target_idx
	else:
		insert_idx = target_idx + 1
	# 仅在插入位置变化时才 move_child（避免每帧冗余调用）
	if insert_idx == _last_drop_index:
		return
	_last_drop_index = insert_idx
	# 在 VFlowC 中将 InsertPlace 移动到对应位置
	# VFlowC 子节点顺序：[item_0, ..., item_{N-1}, InsertPlace, AddBtn]
	# InsertPlace 应在 item_{insert_idx - 1} 之后、item_{insert_idx} 之前
	# 即 InsertPlace 的 child index 应为 insert_idx
	if %InsertPlace.get_parent() == %KeySequenceFlow:
		%KeySequenceFlow.move_child(%InsertPlace, insert_idx)


func _on_item_drop_received(_target: KeySequenceItem, dragged: KeySequenceItem) -> void:
	if dragged == null or _last_drop_index < 0:
		_hide_insert_place()
		return
	var dragged_idx: int = dragged.item_index
	if dragged_idx < 0 or dragged_idx >= _items.size():
		_hide_insert_place()
		return
	# 已经按排序落位，松手时不再判定删除
	_drop_handled = true
	# 保存插入位置（_hide_insert_place 会重置 _last_drop_index）
	var drop_idx := _last_drop_index
	# 从原位置移除数据
	var item_data: Dictionary = _items[dragged_idx]
	_items.remove_at(dragged_idx)
	# 计算实际插入位置（若拖拽项在插入位置之前，需要 -1）
	var insert_idx := drop_idx
	if dragged_idx < insert_idx:
		insert_idx -= 1
	insert_idx = clamp(insert_idx, 0, _items.size())
	_items.insert(insert_idx, item_data)
	_selected_index = insert_idx
	# 先把 InsertPlace 移到末尾（所有 item 之后），确保 move_child 索引正确
	if %InsertPlace.get_parent() == %KeySequenceFlow:
		%KeySequenceFlow.move_child(%InsertPlace, _items.size())
	# 直接移动被拖拽的节点到目标位置，避免 free locked object
	# （_drop_data 调用栈中被拖拽节点处于锁定状态，无法 free）
	%KeySequenceFlow.move_child(dragged, insert_idx)
	# 更新所有节点的 item_index
	_refresh_item_indices()
	_hide_insert_place()
	# 恢复选中状态
	_select_item_by_index(_selected_index)


## 遍历 HBoxC 子节点，按顺序刷新每个 KeySequenceItem 的 item_index
func _refresh_item_indices() -> void:
	var idx := 0
	for child in %KeySequenceFlow.get_children():
		if child is KeySequenceItem:
			(child as KeySequenceItem).item_index = idx
			idx += 1


func _on_item_drag_ended(source: KeySequenceItem) -> void:
	# 只认本次拖拽开始时记下的那个节点：拖拽结束通知是按控件广播的，
	# 不加这层过滤会把每个键位都当成刚被拖过（一次拖拽删掉多个）
	if not _dragging or source != _dragged_item:
		return
	# 落点再判一次：_process 是逐帧轮询，最后一帧可能已落后于实际松手位置
	var delete_index := -1
	if not _drop_handled and is_instance_valid(source) and source.item_index >= 0 \
			and source.item_index < _items.size() and not _is_pointer_in_key_area():
		delete_index = source.item_index
	_reset_drag_state()
	# 复位会重新显示 InsertPlace，故放到它之后隐藏
	_hide_insert_place()
	if delete_index >= 0:
		# 拖放回调栈里被拖节点仍被拖放系统占用，删除（会 free 该节点）延到下一帧
		_delete_item_at.call_deferred(delete_index)


## 清掉拖拽期间加的高亮与提示，回到静止外观
func _reset_drag_state() -> void:
	set_process(false)
	_dragging = false
	if _in_delete_zone:
		_set_delete_zone_active(false)
	elif is_instance_valid(_dragged_item):
		_dragged_item.set_drag_delete_state(false)
	_hint.text = HINT_IDLE
	_hint.remove_theme_color_override("font_color")
	_dragged_item = null
	_drop_handled = false


## 拖出框外松开后删除该按键：收尾与 Backspace/Delete 删除选中项一致
func _delete_item_at(idx: int) -> void:
	if idx < 0 or idx >= _items.size():
		return
	_items.remove_at(idx)
	# 删除后选中原来的邻位，右侧详情不至于突然空掉
	_selected_index = mini(idx, _items.size() - 1) if not _items.is_empty() else -1
	_rebuild_items()
	if _selected_index >= 0:
		_select_item_by_index(_selected_index)
	else:
		_refresh_detail_panel()


func _hide_insert_place() -> void:
	%InsertPlace.visible = false
	_last_drop_index = -1

extends VBoxContainer

class_name KBModeAdjust

## 不能作为键位的按键（保留作取消/删除/导航等功能键）
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

# 节点引用
@onready var _hbox: HFlowContainer = $KeySequence/VFlowC
@onready var _insert_place: Panel = $KeySequence/VFlowC/InsertPlace
@onready var _key_name_label: Label = $HBox/Center/KeyName
@onready var _display_name_edit: LineEdit = $HBox/Center/KeyDisplayName/LineEdit
@onready var _key_config_btn: Button = $HBox/Center/KeyConfig/Button
# 键盘模式开关 + 左右间距 + 轨道分隔线（HBox 左列）
@onready var _kb_mode_cb: CheckBox = $HBox/Left/EnableMode
@onready var _gap_edit: LineEdit = $HBox/Left/EnableKBMode/LineEdit
@onready var _lane_sep_cb: CheckBox = $HBox/Left/SeperateLine
# 交替轨道颜色（HBox 右列）
@onready var _alt_color_cb: CheckBox = $HBox/Right/CheckBox
@onready var _alt_count_edit: LineEdit = $HBox/Right/ColorCount/LineEdit
@onready var _color_seq: HBoxContainer = $HBox/Center/ColorSeq

# 交替颜色序列按钮颜色（按索引保存，重建时保留）
var _alt_colors_state: Array[Color] = []

# 数据：每个 item 为 {"key": Key, "display_name": String}
var _items: Array = []
var _selected_index: int = -1
var _recording_key: bool = false

# 拖拽状态
var _dragged_item: KeySequenceItem = null
var _last_drop_index: int = -1  # 最近一次 drag_over 计算出的插入位置（item 索引）

# 共享 ButtonGroup（确保所有 KeySequenceItem 互斥单选）
var _shared_button_group: ButtonGroup = ButtonGroup.new()

# 标记 _display_name_edit 的文本由程序设置（避免触发 text_changed 死循环）
var _suppress_display_name_signal: bool = false

## 由 PopupWindow.show_kb_mode_adjust 调用：解析配置字符串并重建 UI
## kb_mode：键盘模式开关（0/1）；gap：左右间距（偶数键位时中间额外间距，最低 0）
## alt_color / alt_count / alt_colors：交替轨道颜色配置（键盘模式覆盖音符颜色）
## lane_sep：轨道分隔线开关（0/1，仅键盘模式生效）
func init_adjust(current_keys: String, current_display_names: String,
		kb_mode: Variant = 1, alt_color: Variant = 1, alt_count: Variant = 2,
		alt_colors: String = "#ff0000,#0000ff", gap: Variant = 0, lane_sep: Variant = 0) -> void:
	_cancel_recording()
	# 显式重置按钮文本（_cancel_recording 在 _recording_key=false 时不设置文本）
	_key_config_btn.text = "输入按键"
	_items.clear()
	_selected_index = -1

	var keys: Array[Key] = ConfigParser.parse_keyboard_keys(current_keys)
	var names: Array[String] = ConfigParser.parse_keyboard_display_names(current_display_names, keys.size())

	for i in keys.size():
		_items.append({
			"key": keys[i],
			"display_name": names[i] if i < names.size() else ""
		})

	_rebuild_items()
	_refresh_detail_panel()
	_key_name_label.text = "当前按键： -"

	# 键盘模式开关
	_kb_mode_cb.button_pressed = bool(kb_mode)
	# 左右间距（最低 0）
	var safe_gap: int = max(0, int(gap))
	_gap_edit.text = str(safe_gap)
	# 轨道分隔线（仅键盘模式生效）
	_lane_sep_cb.button_pressed = bool(lane_sep)

	# 交替轨道颜色：数量最低 1，颜色序列按数量补齐
	_alt_color_cb.button_pressed = bool(alt_color)
	var safe_count: int = max(1, int(alt_count))
	_alt_count_edit.text = str(safe_count)
	var colors: Array[Color] = _parse_alt_colors(alt_colors)
	while colors.size() < safe_count:
		colors.append(Color.WHITE)
	colors.resize(safe_count)
	_rebuild_color_buttons(safe_count, colors)


## 返回当前配置给 PopupWindow.show_kb_mode_adjust
## 过滤掉未设置按键（KEY_NONE）的 item，避免无效键写入配置
func get_result() -> Dictionary:
	var valid_keys: Array[String] = []
	var valid_names: Array[String] = []
	for item in _items:
		var k: Key = item.get("key", Key.KEY_NONE)
		if k == Key.KEY_NONE:
			continue
		valid_keys.append(_key_to_config_string(k))
		# strip_edges 保证与 parse_keyboard_display_names 的解析行为一致（round-trip）
		valid_names.append(String(item.get("display_name", "")).strip_edges())

	# 交替轨道颜色：数量最低 1（空/非法文本兜底为 1），颜色补齐到数量
	var alt_count: int = max(1, _alt_count_edit.text.to_int())
	var colors: Array[String] = []
	for btn in _color_seq.get_children():
		if btn is ColorPickerButton:
			colors.append("#" + (btn as ColorPickerButton).color.to_html())
	while colors.size() < alt_count:
		colors.append("#ffffff")
	colors.resize(alt_count)

	return {
		"keys": ",".join(valid_keys),
		"display_names": ",".join(valid_names),
		"keyboard_mode": 1 if _kb_mode_cb.button_pressed else 0,
		"keyboard_mode_gap": max(0, _gap_edit.text.to_int()),
		"alt_color": 1 if _alt_color_cb.button_pressed else 0,
		"alt_count": alt_count,
		"alt_colors": ",".join(colors),
		"lane_separator": 1 if _lane_sep_cb.button_pressed else 0,
	}


# ===== 交替轨道颜色 =====

## 按数量重建颜色序列按钮（保留已有颜色；不够则生成，多余则移除）
## colors 非空时以传入为准（init_adjust 用配置初始化）
func _rebuild_color_buttons(count: int, colors: Array = []) -> void:
	var existing: Array = _alt_colors_state.duplicate()
	if not colors.is_empty():
		existing = colors
	# 移除所有 ColorPickerButton（保留「颜色序列」Label）
	for btn in _color_seq.get_children():
		if btn is ColorPickerButton:
			_color_seq.remove_child(btn)
			btn.queue_free()
	# 生成 count 个按钮（先设色再连信号，避免程序设色触发 color_changed 越界）
	_alt_colors_state.clear()
	for i in count:
		var btn := ColorPickerButton.new()
		btn.custom_minimum_size = Vector2(60, 60)
		btn.size_flags_vertical = 4     # SHRINK_CENTER
		btn.color = existing[i] if i < existing.size() else Color.WHITE
		# 只统一取色器弹层形态（色板 + 滑条 + Hex），不挂 HexEdit：
		# 这里是按轨道数动态生成的色块序列，少则 2 个多则十几个，每个前面塞一个
		# 输入框会把「颜色序列」这一行彻底挤爆，手机上也点不动。
		ThemeMGR.setup_color_picker(btn, false)
		btn.color_changed.connect(_on_alt_color_changed.bind(i))
		_color_seq.add_child(btn)
		_alt_colors_state.append(btn.color)


## 数量 LineEdit 变化：数量 ≥1 时按新数量重建颜色序列按钮
func _on_alt_count_changed(new_text: String) -> void:
	var n := new_text.to_int()
	if n < 1:
		return  # 空/非法/0 → 不重建，由 get_result 兜底为 1
	_rebuild_color_buttons(n)


## 颜色按钮变化：记录到 _alt_colors_state（重建时保留）
func _on_alt_color_changed(idx: int, col: Color) -> void:
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
	for child in _hbox.get_children():
		if child is KeySequenceItem:
			_hbox.remove_child(child)
			child.free()

	# 实例化新的 KeySequenceItem
	for i in _items.size():
		var item: KeySequenceItem = KEY_ITEM_SCENE.instantiate()
		_hbox.add_child(item)
		_hbox.move_child(item, i)  # 插入到 InsertPlace 之前
		item.button_group = _shared_button_group
		var item_data: Dictionary = _items[i]
		item.set_data(item_data.get("key", Key.KEY_NONE), item_data.get("display_name", ""), i)
		# 连接信号
		item.item_selected.connect(_on_item_selected)
		item.drag_started.connect(_on_item_drag_started)
		item.drag_over.connect(_on_item_drag_over)
		item.drop_received.connect(_on_item_drop_received)
		item.drag_ended.connect(_on_item_drag_ended)

	# 确保 InsertPlace 在所有 item 之后、AddBtn 之前
	var insert_idx := _items.size()
	if _insert_place.get_parent() == _hbox:
		_hbox.move_child(_insert_place, insert_idx)
	_insert_place.visible = false


## 将 Key 枚举转为可被 ConfigParser.parse_keyboard_keys 解析的字符串
## 优先使用 OS.get_keycode_string（与 OS.find_keycode_from_string 互逆）
func _key_to_config_string(k: Key) -> String:
	return OS.get_keycode_string(k)


# ===== 选中 =====

func _on_item_selected(item: KeySequenceItem) -> void:
	_selected_index = item.item_index
	_refresh_detail_panel()


func _refresh_detail_panel() -> void:
	if _selected_index < 0 or _selected_index >= _items.size():
		_key_name_label.text = "当前按键： -"
		_suppress_display_name_signal = true
		_display_name_edit.text = ""
		_suppress_display_name_signal = false
		return
	var item: Dictionary = _items[_selected_index]
	var k: Key = item.get("key", Key.KEY_NONE)
	_key_name_label.text = "当前按键： " + ("未设置" if k == Key.KEY_NONE else OS.get_keycode_string(k))
	_suppress_display_name_signal = true
	_display_name_edit.text = item.get("display_name", "")
	_suppress_display_name_signal = false


# ===== AddBtn =====

func _on_add_btn_pressed() -> void:
	_items.append({"key": Key.KEY_NONE, "display_name": ""})
	_rebuild_items()
	# 选中新增的项
	var new_idx := _items.size() - 1
	if new_idx >= 0:
		_select_item_by_index(new_idx)


func _select_item_by_index(idx: int) -> void:
	if idx < 0 or idx >= _hbox.get_child_count():
		return
	for child in _hbox.get_children():
		if child is KeySequenceItem and (child as KeySequenceItem).item_index == idx:
			(child as KeySequenceItem).set_pressed(true)
			_on_item_selected(child as KeySequenceItem)
			return


# ===== KeyConfig 录入 =====

func _on_key_config_btn_pressed() -> void:
	if _selected_index < 0:
		# 禁用按钮避免 await 期间重入产生多个 timer
		_key_config_btn.disabled = true
		_key_config_btn.text = "先选按键"
		await get_tree().create_timer(1.0).timeout
		_key_config_btn.text = "输入按键"
		_key_config_btn.disabled = false
		return
	if _recording_key:
		_cancel_recording()
	else:
		_start_recording()


func _start_recording() -> void:
	_recording_key = true
	_key_config_btn.text = "按键中..."
	# 释放 LineEdit 焦点，避免按键被吞
	_display_name_edit.release_focus()


func _cancel_recording() -> void:
	if not _recording_key:
		return
	_recording_key = false
	_key_config_btn.text = "输入按键"


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
	for child in _hbox.get_children():
		if child is KeySequenceItem and (child as KeySequenceItem).item_index == idx:
			return child as KeySequenceItem
	return null


# ===== 按键录入与删除（_input） =====

func _input(event: InputEvent) -> void:
	# 用 is_visible_in_tree() 而非 visible：PopupWindow.hide() 不改子节点 visible，
	# 仅 visible 会在此窗口已隐藏但仍为当前 tab 时继续拦截按键
	if not is_visible_in_tree():
		return
	if not (event is InputEventKey) or not event.pressed or event.is_echo():
		return
	var key_event: InputEventKey = event as InputEventKey

	# 录入模式：拦截所有按键
	if _recording_key:
		accept_event()
		# ESC / Backspace / Delete → 取消录入
		if key_event.keycode in [Key.KEY_ESCAPE, Key.KEY_BACKSPACE, Key.KEY_DELETE]:
			_cancel_recording()
			return
		# 黑名单键 → 警告，保持录入状态
		if key_event.keycode in BLACKLISTED_KEYS:
			_key_name_label.text = "不可用： " + OS.get_keycode_string(key_event.keycode)
			GLogger.warning("Key '%s' is blacklisted" % OS.get_keycode_string(key_event.keycode), "KBModeAdjust")
			return
		# 录入有效按键
		_apply_recorded_key(key_event.keycode)
		return

	# 非录入模式：LineEdit 有焦点时不拦截（让用户正常编辑文本）
	if _display_name_edit.has_focus() or _alt_count_edit.has_focus():
		return

	# 颜色选择器弹窗打开时不拦截（避免其中按 Backspace/Delete 误删按键）
	for btn in _color_seq.get_children():
		if btn is ColorPickerButton:
			var pp := (btn as ColorPickerButton).get_popup()
			if pp and pp.visible:
				return

	# Backspace / Delete → 删除选中项（无确认弹窗以避免嵌套 PopupWindow）
	if key_event.keycode in [Key.KEY_BACKSPACE, Key.KEY_DELETE]:
		if _selected_index >= 0:
			accept_event()
			_delete_selected()


## 录入按键到当前选中项
func _apply_recorded_key(k: Key) -> void:
	if _selected_index < 0 or _selected_index >= _items.size():
		_cancel_recording()
		return
	# 检查按键冲突：该键是否已绑定到其他 item
	for i in _items.size():
		if i == _selected_index:
			continue
		if _items[i].get("key", Key.KEY_NONE) == k:
			_key_name_label.text = "已绑定到第 %d 个按键" % (i + 1)
			GLogger.warning("Key '%s' is already bound to item %d" % [OS.get_keycode_string(k), i], "KBModeAdjust")
			_cancel_recording()
			return
	_items[_selected_index]["key"] = k
	# 若显示名为空，自动填充按键默认名
	if String(_items[_selected_index].get("display_name", "")).is_empty():
		var default_name := OS.get_keycode_string(k)
		_items[_selected_index]["display_name"] = default_name
		_suppress_display_name_signal = true
		_display_name_edit.text = default_name
		_suppress_display_name_signal = false
	# 刷新 UI
	_key_name_label.text = "当前按键： " + OS.get_keycode_string(k)
	var item_node := _find_item_node_by_index(_selected_index)
	if item_node:
		item_node.key_code = k
		item_node.display_name = String(_items[_selected_index].get("display_name", ""))
		item_node.refresh_text()
	# 退出录入模式
	_cancel_recording()


## 删除当前选中的 item
func _delete_selected() -> void:
	if _selected_index < 0 or _selected_index >= _items.size():
		return
	_items.remove_at(_selected_index)
	_selected_index = -1
	_rebuild_items()
	_refresh_detail_panel()
	_key_name_label.text = "当前按键： -"


# ===== 拖拽 =====

func _on_item_drag_started(item: KeySequenceItem) -> void:
	_dragged_item = item
	# 重置为 -1 表示尚未确定插入位置，确保首次 drag_over 能正确 move_child
	_last_drop_index = -1
	_insert_place.visible = true


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
	if _insert_place.get_parent() == _hbox:
		_hbox.move_child(_insert_place, insert_idx)


func _on_item_drop_received(_target: KeySequenceItem, dragged: KeySequenceItem) -> void:
	if dragged == null or _last_drop_index < 0:
		_hide_insert_place()
		return
	var dragged_idx: int = dragged.item_index
	if dragged_idx < 0 or dragged_idx >= _items.size():
		_hide_insert_place()
		return
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
	if _insert_place.get_parent() == _hbox:
		_hbox.move_child(_insert_place, _items.size())
	# 直接移动被拖拽的节点到目标位置，避免 free locked object
	# （_drop_data 调用栈中被拖拽节点处于锁定状态，无法 free）
	_hbox.move_child(dragged, insert_idx)
	# 更新所有节点的 item_index
	_refresh_item_indices()
	_hide_insert_place()
	# 恢复选中状态
	_select_item_by_index(_selected_index)


## 遍历 HBoxC 子节点，按顺序刷新每个 KeySequenceItem 的 item_index
func _refresh_item_indices() -> void:
	var idx := 0
	for child in _hbox.get_children():
		if child is KeySequenceItem:
			(child as KeySequenceItem).item_index = idx
			idx += 1


func _on_item_drag_ended(_source: KeySequenceItem) -> void:
	_hide_insert_place()
	_dragged_item = null


func _hide_insert_place() -> void:
	_insert_place.visible = false
	_last_drop_index = -1

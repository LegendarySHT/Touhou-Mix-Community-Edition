extends ListItemBase
class_name SettingItem

var item_value_line_edit: String = "res://UI/Views/SettingView/ValueLineEdit.tscn"
var item_value_color: String = "res://UI/Views/SettingView/ValueColor.tscn"
var item_value_option: String = "res://UI/Views/SettingView/ValueOption.tscn"
var item_value_button: String = "res://UI/Views/SettingView/ValueButton.tscn"

var id: String = ""

enum ValueType {
	TYPE_OPTION,
	TYPE_COLOR,
	TYPE_LINE_EDIT,
	TYPE_BUTTON,
}

var value_type: ValueType
var value_node: Control

var _can_edit_alpha: bool = false

# 持有 SettingList 引用，用于 on_click / options_provider 回调
var setting_list: Node = null

# 添加信号，用于通知值改变
signal value_changed(id: String, value: Variant)
signal option_popup_about_to_show(id: String)

func setup_item(ID: String, content: String, desc: String, valueType: ValueType, initial_value: Variant = null, on_click_method: String = "", options_provider_method: String = "") -> Control:
	self.id = ID
	self.value_type = valueType  # 设置value_type

	# 设置标题和描述
	var name_label = get_node_or_null("name")
	if name_label:
		name_label.text = content

	var desc_label = get_node_or_null("desc")
	if desc_label:
		desc_label.text = desc

	# 创建对应的值控件
	var v_node: Control = null
	match valueType:
		ValueType.TYPE_OPTION:
			v_node = load(item_value_option).instantiate()
			var option_btn: OptionButton = v_node
			# 连接拖拽判定后的确认信号，仅在有效点选时通知值变化
			option_btn.connect("item_confirmed", Callable(self, "_on_option_selected"))

			var popup_menu: PopupMenu = option_btn.get_popup()
			popup_menu.about_to_popup.connect(_on_popup_menu_popup.bind(popup_menu))

			# 若声明了 options_provider，调用它填充选项，并在 about_to_popup 时刷新
			if options_provider_method != "" and setting_list:
				var provider := Callable(setting_list, options_provider_method)
				_refresh_options_from_provider(provider, option_btn, initial_value)
				# about_to_popup 时重新刷新
				popup_menu.about_to_popup.connect(_on_popup_refresh_provider.bind(provider, option_btn))

		ValueType.TYPE_COLOR:
			v_node = load(item_value_color).instantiate()
			var btn: ColorPickerButton = v_node.get_node("ColorPickerButton")

			var color_edit: LineEdit = v_node.get_node("HexColor")
			btn.color_changed.connect(_on_color_changed.bind(color_edit))
			color_edit.text_changed.connect(_on_color_changed.bind(btn))

			var pk: ColorPicker = btn.get_picker()

			pk.edit_intensity = false
			pk.can_add_swatches = false
			pk.sampler_visible = false
			pk.presets_visible = false

		ValueType.TYPE_LINE_EDIT:
			v_node = load(item_value_line_edit).instantiate()
			var line_edit: LineEdit = v_node.get_node("LineEdit")
			if line_edit:
				line_edit.connect("text_changed", Callable(self, "_on_text_changed"))

		ValueType.TYPE_BUTTON:
			v_node = setting_list.make_value_button()
			var btn: Button = v_node
			# 若声明了 on_click，直接连接到 SettingList 上的方法（绕过 value_changed 信号）
			if on_click_method != "" and setting_list:
				btn.connect("pressed", Callable(setting_list, on_click_method))
			else:
				# 回退：未声明 on_click 时走原 value_changed 流程
				btn.connect("pressed", Callable(self, "_on_button_pressed"))

	value_node = v_node

	# 父节点是grid容器，所以添加到父节点
	get_parent().add_child(v_node)

	# 设置初始值（TYPE_OPTION 已在 _refresh_options_from_provider 内选中，避免覆盖）
	if initial_value != null and valueType != ValueType.TYPE_OPTION:
		set_value(initial_value)

	return v_node

# 从 provider 获取选项列表并填充 OptionButton，同时尝试选中当前值对应的索引
func _refresh_options_from_provider(provider: Callable, option_btn: OptionButton, initial_value: Variant) -> void:
	var options: Array = provider.call()
	option_btn.clear()
	for i in range(options.size()):
		option_btn.add_item(options[i], i)
	# 尝试选中当前值对应的索引
	var default_index := 0
	if initial_value is String and not initial_value.is_empty():
		for i in range(options.size()):
			if options[i] == initial_value:
				default_index = i
				break
	if default_index >= 0 and default_index < options.size():
		option_btn.select(default_index)

# about_to_popup 时重新从 provider 刷新选项列表，保持当前选中项不变
func _on_popup_refresh_provider(provider: Callable, option_btn: OptionButton) -> void:
	var current_text := option_btn.text
	var options: Array = provider.call()
	option_btn.clear()
	for i in range(options.size()):
		option_btn.add_item(options[i], i)
	# 尝试恢复选中项
	var idx := options.find(current_text)
	if idx >= 0:
		option_btn.select(idx)
	else:
		option_btn.select(0)

# 更新弹出菜单样式
func _on_popup_menu_popup(popup_menu: PopupMenu) -> void:
	option_popup_about_to_show.emit(id)
	await get_tree().process_frame
	popup_menu.position.y += 20
	popup_menu.position.x -= 20

# 获取当前值
func get_value() -> Variant:
	if not value_node:
		return null

	match value_type:
		ValueType.TYPE_OPTION:
			var option_btn: OptionButton = value_node
			if option_btn:
				return option_btn.selected
			return 0

		ValueType.TYPE_COLOR:
			var color_btn: ColorPickerButton = value_node.get_node("ColorPickerButton")
			if color_btn:
				return color_btn.color
			return Color.WHITE

		ValueType.TYPE_LINE_EDIT:
			var line_edit: LineEdit = value_node.get_node("LineEdit")
			if line_edit:
				return line_edit.text
			return ""

		ValueType.TYPE_BUTTON:
			# 按钮类型无持久值
			return null

	return null

# 设置值
func set_value(value: Variant) -> void:
	if not value_node:
		return

	match value_type:
		ValueType.TYPE_OPTION:
			var option_btn: OptionButton = value_node
			if option_btn and value is int:
				option_btn.select(value)

		ValueType.TYPE_COLOR:
			var color_btn: ColorPickerButton = value_node.get_node("ColorPickerButton")
			if color_btn:
				if value is Color:
					color_btn.color = value
				elif value is String and value.is_valid_html_color():
					color_btn.color = Color(value)
				value_node.get_node("HexColor").text = "#%s" % (value if value is String else value.to_html(_can_edit_alpha))

		ValueType.TYPE_LINE_EDIT:
			var line_edit: LineEdit = value_node.get_node("LineEdit")
			if line_edit:
				line_edit.text = str(value)

		ValueType.TYPE_BUTTON:
			# 按钮类型无需设置值
			pass

# 设置选项（仅用于TYPE_OPTION）
func set_options(options: Array, default_index: int = 0) -> void:
	if value_type != ValueType.TYPE_OPTION or not value_node:
		return
	
	var option_btn: OptionButton = value_node
	if option_btn:
		option_btn.clear()
		for i in range(options.size()):
			option_btn.add_item(options[i], i)
		
		if default_index >= 0 and default_index < options.size():
			option_btn.select(default_index)

# 设置颜色按钮参数
func set_color_picker_options(edit_alpha: bool = true, presets_visible: bool = false, sampler_visible: bool = false) -> void:
	if value_type != ValueType.TYPE_COLOR or not value_node:
		return
	
	_can_edit_alpha = edit_alpha

	var color_btn: ColorPickerButton = value_node.get_node("ColorPickerButton")
	if color_btn:
		var pk: ColorPicker = color_btn.get_picker()
		if pk:
			pk.edit_alpha = edit_alpha
			pk.presets_visible = presets_visible
			pk.sampler_visible = sampler_visible

# 设置行编辑属性
func set_line_edit_properties(placeholder: String = "", secret: bool = false, unit: String = "") -> void:
	if value_type != ValueType.TYPE_LINE_EDIT or not value_node:
		return
	
	var line_edit: LineEdit = value_node.get_node("LineEdit")
	if line_edit:
		line_edit.placeholder_text = placeholder
		line_edit.secret = secret
		
		var un: Label = value_node.get_node("Label")
		if not unit.is_empty():
			un.text = unit
			un.visible = true


# 信号处理函数
func _on_option_selected(index: int) -> void:
	emit_signal("value_changed", id, index)

func _on_color_changed(color, node) -> void:
	node.set_block_signals(true)

	if node is LineEdit:
		node.text = "#%s"% color.to_html(_can_edit_alpha)
	elif node is ColorPickerButton and color.is_valid_html_color():
		node.color = color

	node.set_block_signals(false)
	emit_signal("value_changed", id, color)

func _on_text_changed(new_text: String) -> void:
	emit_signal("value_changed", id, new_text)

# 按钮点击：emit value_changed(id, null)，由 SettingList 区分处理
func _on_button_pressed() -> void:
	emit_signal("value_changed", id, null)

# 启用/禁用设置项
func set_enabled(enabled: bool) -> void:
	match value_type:
		ValueType.TYPE_OPTION:
			var option_btn: OptionButton = value_node
			if option_btn:
				option_btn.disabled = not enabled

		ValueType.TYPE_COLOR:
			var color_btn: ColorPickerButton = value_node.get_node("ColorPickerButton")
			if color_btn:
				color_btn.modulate.a = 1.0 if enabled else 0.45
				color_btn.disabled = not enabled
			# HexColor 是 ColorPickerButton 的兄弟节点，只禁按钮的话输入框还能打字
			var hex_edit: LineEdit = value_node.get_node_or_null("HexColor")
			if hex_edit:
				hex_edit.editable = enabled
				hex_edit.focus_mode = Control.FOCUS_ALL if enabled else Control.FOCUS_NONE

		ValueType.TYPE_LINE_EDIT:
			var line_edit: LineEdit = value_node.get_node("LineEdit")
			if line_edit:
				line_edit.editable = enabled
				# LineEdit 在 editable=false 时仍可被 Tab/方向键聚焦，一并关掉才真的"跳过"
				line_edit.focus_mode = Control.FOCUS_ALL if enabled else Control.FOCUS_NONE

		ValueType.TYPE_BUTTON:
			var btn: Button = value_node
			if btn:
				btn.disabled = not enabled

# 清理函数
func _exit_tree() -> void:
	if value_node:
		value_node.queue_free()

extends BaseScrollList
class_name SettingList

var item_separator: String = "res://UI/Views/SettingView/Seperator.tscn"
var setting_items: Dictionary = {}  # 存储所有设置项，键为id，值为SettingItem

const VALUE_BUTTON_SCENE := preload("res://UI/Views/SettingView/ValueButton.tscn")
var _value_button_instance: Button = null

# 受难度预设控制的生成设置项（难度 != Custom 时锁定）
const DIFFICULTY_LOCKED_IDS: Array[String] = [
	"max_simultaneous_blocks",
	"min_tap_interval",
	"min_touch_cooldown_time",
	"max_touch_move_speed",
	"max_block_coalesce_time",
]
const DIFFICULTY_CUSTOM_ID: int = 4
const DIFFICULTY_CFG_SECTION: String = "Generator"
const DIFFICULTY_CFG_KEY: String = "difficulty"

# 进入 SettingView 时的配置快照（setting_id → 原始值，类型已转换好）
var _initial_config: Dictionary = {}
# 当前待保存的配置（setting_id → 已转换好类型的最终值）
var _pending_config: Dictionary = {}

var setting_groups: Array = []

func _ready() -> void:
	setting_groups = SettingGroupsData.get_setting_groups()
	work_state = UIStateManager.UIState.SETTINGS_VIEW
	super._ready()
	_value_button_instance = VALUE_BUTTON_SCENE.instantiate()
	apply_button_theme(ThemeMGR.get_color("primary"))
	get_v_scroll_bar().value_changed.connect(func (_v):
		var btns = get_parent().get_parent().short_cut_btn.get_children()
		var idx = _get_current_para_sepa_idx()
		# 边界检查：分组索引超出快捷按钮数量时跳过
		if idx < 0 or idx >= btns.size():
			return
		var tBtn: Button = btns[idx]
		# await get_tree().process_frame
		if tBtn.get_parent().has_meta("snaping"):
			return

		if tBtn and not tBtn.button_pressed:
			for b in btns:
				b.set_block_signals(true)
				b.call_deferred("set_block_signals", false)
				# 取消所有 ShortCut 按钮的焦点，避免 focus 样式残留
				# release_focus 内部会判断是否持有焦点，对未持有焦点的按钮调用是安全的
				b.release_focus()
			tBtn.button_pressed = true
	)

	# 监听难度变更：SettingView 缓存不重跑 load_settings，需主动刷新 5 个受控项
	if EvtBus and not EvtBus.config_changed.is_connected(_on_difficulty_config_changed):
		EvtBus.config_changed.connect(_on_difficulty_config_changed)

# 传入配置字典加载界面
func load_settings(setting: Dictionary = {}):
	# 清空现有项目
	clear_items()
	setting_items.clear()
	separators.clear()

	# 初始化配置快照和待保存配置
	_initial_config = setting.duplicate(true)
	_pending_config = setting.duplicate(true)

	# 遍历所有分组
	var group_idx := 0
	for group in setting_groups:
		# 添加分隔符
		_add_separator()

		# 添加该组的所有设置项
		for setting_data in group.settings:
			# 跳过未实装的设置项（不创建 UI，实装后改 not_implemented=false 即可恢复）
			if setting_data.get("not_implemented", false):
				continue
			var init_value = _pending_config.get(setting_data.id, setting_data.default_value)
			add_setting_item(setting_data, init_value, group_idx)
		group_idx += 1

	# 应用高级设置项可见性（根据 show_advanced_settings 的值）
	_apply_advanced_visibility()

	# 应用难度预设锁定（值已由 load_settings 从文件读入，仅切换锁定态）
	_apply_difficulty_lock_state(true)

var separators = []
@onready var separator_scene = load(item_separator)
func _add_separator():
	# 加载并添加分隔符
	if separator_scene:
		var separator = separator_scene.instantiate()
		container.add_child(separator)
		separators.append(separator)
		separator = separator_scene.instantiate()
		container.add_child(separator)
		separators.append(separator)

func _get_current_para_sepa_idx():
	# 每个分组的分界线是 separators[2*idx]（_add_separator 给每个分组添加两个 separator）
	# 当分界线越过视口中线（向上越过进入上半屏）时切换到对应按钮
	# 即：找到第一个仍在视口下半屏的分界线，它的前一个分组就是当前分组
	var viewport_mid_y := get_global_rect().get_center().y
	var group_count := floori(separators.size() / 2.0)
	for i in range(group_count):
		if separators[i * 2].global_position.y > viewport_mid_y:
			return max(i - 1, 0)
	# 所有分界线都已越过中线，已滚动到最后一个分组
	return group_count - 1

func _process(delta: float) -> void:
	super._process(delta)

func add_setting_item(setting_data: Dictionary, init_value: Variant = "", group_idx: int = 0):
	# 创建设置项
	var setting_item: SettingItem = create_and_add_item(setting_data.id, "SettingItem")
	# 注入 SettingList 引用，供 on_click / options_provider 回调使用
	setting_item.setting_list = self

	# 解析值类型
	var value_type: SettingItem.ValueType = SettingItem.ValueType.TYPE_LINE_EDIT
	match setting_data.type:
		"TYPE_OPTION":
			value_type = SettingItem.ValueType.TYPE_OPTION
		"TYPE_COLOR":
			value_type = SettingItem.ValueType.TYPE_COLOR
		"TYPE_LINE_EDIT":
			value_type = SettingItem.ValueType.TYPE_LINE_EDIT
		"TYPE_BUTTON":
			value_type = SettingItem.ValueType.TYPE_BUTTON

	# 设置界面语言（这里假设使用中文，可以根据需要调整）
	var language = "zh"  # 可以改为从全局设置获取
	var display_name = setting_data["name_%s" % language] if language in ["en", "zh"] else setting_data.name_en
	var description = setting_data.description

	# 设置初始值（从保存的数据或默认值）
	var initial_value = init_value if init_value != null and str(init_value) != "" else setting_data.default_value
	# theme_preset 不持久化到 INI，从 ThemeManager 读取当前主题名作为初始值，确保下拉框选中当前主题
	if setting_data.id == "theme_preset" and (initial_value == null or str(initial_value) == "") and ThemeMGR:
		initial_value = ThemeMGR.get_theme_name()

	# 读取 JSON 中声明的回调方法名
	var on_click_method := String(setting_data.get("on_click", ""))
	var options_provider_method := String(setting_data.get("options_provider", ""))

	# 调用 setup_item 方法（传入回调方法名供自动连接）
	setting_item.setup_item(
		setting_data.id,
		display_name,
		description,
		value_type,
		initial_value,
		on_click_method,
		options_provider_method
	)

	# 处理未声明 options_provider 的 TYPE_OPTION（静态 options / dynamic_options 空列表 / 自定义缓动）
	if value_type == SettingItem.ValueType.TYPE_OPTION and options_provider_method == "":
		_setup_static_options(setting_item, setting_data, initial_value, language)
	elif value_type == SettingItem.ValueType.TYPE_COLOR:
		var enable_alpha = setting_data.get("edit_alpha", false)
		setting_item.set_color_picker_options(enable_alpha, false, false)
		# 设置初始颜色值
		if initial_value is String and initial_value.is_valid_html_color():
			setting_item.set_value(Color(initial_value))
	elif value_type == SettingItem.ValueType.TYPE_LINE_EDIT:
		if setting_data.get("unit"):
			setting_item.set_line_edit_properties("", false, setting_data.unit)

	# 连接值改变信号（按钮类型若声明了 on_click 则不走 value_changed，但仍连接以兼容）
	setting_item.connect("value_changed", Callable(self, "_on_setting_value_changed"))

	# 存储到字典中
	setting_items[setting_data.id] = setting_item

	# 设置 focus_neighbor_left 指向对应分组的左侧快捷按钮（按左方向键回到对应区域）
	_setup_focus_neighbor_left(setting_item, group_idx)

## 让设置项的值控件 focus_neighbor_left 指向对应分组的快捷按钮
## 分组下标与 SettingView 左侧 ShortCut 按钮下标一一对应（每个分组前都 _add_separator）
## 仅设置真正的可聚焦控件（OptionButton/ColorPickerButton/LineEdit/Button），容器本身不可聚焦
func _setup_focus_neighbor_left(setting_item: SettingItem, group_idx: int) -> void:
	var shortcut = get_parent().get_parent().short_cut_btn
	if shortcut == null or group_idx < 0 or group_idx >= shortcut.get_child_count():
		return
	var target: Button = shortcut.get_child(group_idx)
	if target == null:
		return
	var focusable: Control = null
	match setting_item.value_type:
		SettingItem.ValueType.TYPE_OPTION:
			focusable = setting_item.value_node
		SettingItem.ValueType.TYPE_COLOR:
			if setting_item.value_node:
				focusable = setting_item.value_node.get_node_or_null("ColorPickerButton")
		SettingItem.ValueType.TYPE_LINE_EDIT:
			if setting_item.value_node:
				focusable = setting_item.value_node.get_node_or_null("LineEdit")
		SettingItem.ValueType.TYPE_BUTTON:
			focusable = setting_item.value_node
	if focusable:
		focusable.focus_neighbor_left = target.get_path()

# 为未声明 options_provider 的 TYPE_OPTION 设置静态选项
func _setup_static_options(setting_item: SettingItem, setting_data: Dictionary, initial_value: Variant, language: String) -> void:
	var option_texts = []

	if setting_data.get("dynamic_options", false) and setting_data.get("options", []).is_empty():
		# 动态 options 为空且未声明 provider，先占位
		option_texts = ["Loading..."]
	elif setting_data.get("is_custom_easing", false):
		# 自定义缓动选项，从 EasingMapper 动态生成
		var easing_type = setting_data.get("easing_type", "func")
		var easing_options = []
		if easing_type == "func":
			easing_options = EasingMapper.get_func_options()
		elif easing_type == "phase":
			easing_options = EasingMapper.get_phase_options()
		for easing_opt in easing_options:
			option_texts.append(easing_opt.display_name)
	else:
		# 静态 options
		for option in setting_data.options:
			var option_text = option["text_%s" % language] if language in ["en", "zh"] else option.text_en
			option_texts.append(option_text)

	# 选中初始值对应的索引
	var default_index = 0
	if setting_data.get("is_custom_easing", false) and initial_value is String:
		var easing_type = setting_data.get("easing_type", "func")
		var easing_options = []
		if easing_type == "func":
			easing_options = EasingMapper.get_func_options()
		elif easing_type == "phase":
			easing_options = EasingMapper.get_phase_options()
		for i in range(easing_options.size()):
			if easing_options[i].name.to_upper() == initial_value.to_upper():
				default_index = i
				break
	elif initial_value is String and initial_value.is_valid_int():
		default_index = int(initial_value)
	elif initial_value is String:
		var matched_index = -1
		for i in range(setting_data.get("options", []).size()):
			var option_data = setting_data.get("options", [])[i]
			if option_data.has("value") and str(option_data["value"]).to_lower() == initial_value.to_lower():
				matched_index = i
				break
		if matched_index >= 0:
			default_index = matched_index
		else:
			var idx = option_texts.find(initial_value)
			default_index = idx if idx >= 0 else 0

	setting_item.set_options(option_texts, default_index)

func _on_setting_value_changed(id: String, value: Variant):
	# 按钮类型若声明了 on_click 已直接走 on_click 回调，不会触发此分支
	# 未声明 on_click 的按钮会 emit value_changed(id, null)，此处忽略
	var item: SettingItem = setting_items.get(id)
	if item and item.value_type == SettingItem.ValueType.TYPE_BUTTON:
		return

	GLogger.info("Setting '%s' changed to: %s" % [id, value], "SettingList")

	# theme_preset 即时应用到 ThemeManager
	if id == "theme_preset" and value is int:
		if ThemeMGR:
			var presets := ThemeMGR.get_available_presets()
			if value >= 0 and value < presets.size():
				ThemeMGR.apply_preset(presets[value])
		_pending_config[id] = value
		return

	# 转换值（索引→实际值、类型转换）
	var converted_value = _convert_setting_value(id, value)
	if converted_value == null:
		return  # 转换失败（如颜色不完整），跳过

	_pending_config[id] = converted_value
	GLogger.info("Pending config: %s = %s" % [id, str(converted_value)], "SettingList")

	# performing_mode 实时生效：立即写入当前配置并 emit config_changed（与键盘模式弹窗同一约定）
	# 否则退出时仅与进入快照 diff，同会话内来回切换会因最终值绕回初始值而被跳过，导致切不回原模式
	if id == "performing_mode":
		ConfigManager.instance.set_value_and_notify("Playback", "performing_mode", converted_value)

	# 即时可见性刷新
	if id == "show_advanced_settings":
		_apply_advanced_visibility()

# 将 UI 控件返回的值转换为配置存储用的值（索引→文件名、类型转换等）
# 返回 null 表示值不完整，调用方应跳过本次写入
func _convert_setting_value(id: String, value: Variant) -> Variant:
	# 自定义缓动选项：索引→名称（LINEAR / IN 等）
	var setting_data := _find_setting_data(id)
	if not setting_data.is_empty() and setting_data.get("is_custom_easing", false) and value is int:
		var easing_type = setting_data.get("easing_type", "func")
		var easing_options: Array = []
		if easing_type == "func":
			easing_options = EasingMapper.get_func_options()
		elif easing_type == "phase":
			easing_options = EasingMapper.get_phase_options()
		if value >= 0 and value < easing_options.size():
			return easing_options[value].name
		return null

	# soundfont_select: 索引→文件名（去 .sf2 和 [内置] 标签）
	if id == "soundfont_select" and value is int:
		var display_text = get_option_text(id, value)
		var actual_name = display_text.split(" [")[0] if " [" in display_text else display_text
		if actual_name.ends_with(".sf2"):
			actual_name = actual_name.get_basename()
		return actual_name
	# 其他走 SettingsMapper 类型转换
	if SettingsMapper.mappings.has(id):
		var info = SettingsMapper.mappings[id]
		var value_type = info.get("value_type", "string")
		match value_type:
			"int":
				return int(value) if value is not int else value
			"float":
				return float(value) if value is not float else value
			"bool":
				if value is int:
					return value != 0
				elif value is String:
					return value.to_lower() in ["1", "true", "yes"]
				else:
					return bool(value)
			"string":
				return str(value)
			"color":
				if value is Color:
					return value
				elif str(value).is_valid_html_color():
					return Color(str(value))
				else:
					return null  # 颜色不完整时跳过
	# 未在 mappings 中的项（如 theme_preset）原样返回
	return value

# 在 setting_groups 中查找指定 id 的 setting_data 字典
func _find_setting_data(id: String) -> Dictionary:
	for group in setting_groups:
		for setting_data in group.settings:
			if setting_data.id == id:
				return setting_data
	return {}

# 弹出皮肤修改窗口，关闭后将选中皮肤名缓存到 _pending_config
# PopupWindow 内部已通过 ConfigManager.set_value_and_notify 即时应用到 PlayView
# _pending_config 仅确保退出 SettingView 时保存到配置文件
func _popup_note_skin_adjust() -> void:
	var skin_name := await PopupWindow.instance.show_note_skin_adjust()
	if skin_name.is_empty():
		return
	_pending_config["block_skin_preset"] = skin_name
	GLogger.info("block_skin_preset selected: '%s' (pending save)" % skin_name, "SettingList")

# ===== 键位设置弹窗入口 =====
# 弹出键位设置窗口，关闭后即时应用（set_value_and_notify）+ 缓存 _pending_config
# 打开弹窗时从 _pending_config 读取当前值传入，确保未保存的修改能接着改
# 即时应用与皮肤/下落弹窗一致；若只靠退出时 diff（str(old)==str(new) 比较），
# 同会话内键盘模式先关再开、最终值绕回初始值时会被判为"无变化"而跳过 emit，
# 导致 PlayView 的 keyboard_mode 字段停留在中间状态不生效
func _popup_kb_mode_adjust() -> void:
	var pending_keys := String(_pending_config.get("keyboard_mode_keys", ""))
	var pending_names := String(_pending_config.get("keyboard_mode_display_names", ""))
	var pending_kb_mode := int(_pending_config.get("keyboard_mode", 0))
	var pending_gap := int(_pending_config.get("keyboard_mode_gap", 0))
	var pending_alt_color := int(_pending_config.get("keyboard_alt_color", 1))
	var pending_alt_count := int(_pending_config.get("keyboard_alt_color_count", 2))
	var pending_alt_colors := String(_pending_config.get("keyboard_alt_colors", "#ff0000,#0000ff"))
	var pending_separator := int(_pending_config.get("keyboard_lane_separator", 0))
	var result := await PopupWindow.instance.show_kb_mode_adjust(
		pending_keys, pending_names, pending_kb_mode, pending_alt_color, pending_alt_count, pending_alt_colors, pending_gap, pending_separator)
	var keys_str := String(result.get("keys", ""))
	var names_str := String(result.get("display_names", ""))
	_pending_config["keyboard_mode_keys"] = keys_str
	_pending_config["keyboard_mode_display_names"] = names_str
	_pending_config["keyboard_mode"] = int(result.get("keyboard_mode", 0))
	_pending_config["keyboard_mode_gap"] = int(result.get("keyboard_mode_gap", 0))
	_pending_config["keyboard_alt_color"] = int(result.get("alt_color", 1))
	_pending_config["keyboard_alt_color_count"] = int(result.get("alt_count", 2))
	_pending_config["keyboard_alt_colors"] = String(result.get("alt_colors", "#ff0000,#0000ff"))
	_pending_config["keyboard_lane_separator"] = int(result.get("lane_separator", 0))
	# 即时应用到运行时（关闭弹窗即提交，无取消路径）
	_apply_kb_mode_result_to_runtime(result)
	GLogger.info("keyboard_mode_keys updated: %s, kb_mode=%s" % [keys_str, str(result.get("keyboard_mode", 0))], "SettingList")

## 弹窗结果即时写回 ConfigManager 并 emit config_changed（PlayView/KeySequenceManager 热更新）
func _apply_kb_mode_result_to_runtime(result: Dictionary) -> void:
	var cm := ConfigManager.instance
	cm.set_value_and_notify("Lane", "keyboard_mode", int(result.get("keyboard_mode", 0)))
	cm.set_value_and_notify("Lane", "keyboard_mode_keys", String(result.get("keys", "")))
	cm.set_value_and_notify("Lane", "keyboard_mode_display_names", String(result.get("display_names", "")))
	cm.set_value_and_notify("Lane", "keyboard_mode_gap", max(0, int(result.get("keyboard_mode_gap", 0))))
	cm.set_value_and_notify("Lane", "keyboard_alt_color", int(result.get("alt_color", 1)))
	cm.set_value_and_notify("Lane", "keyboard_alt_color_count", max(1, int(result.get("alt_count", 2))))
	cm.set_value_and_notify("Lane", "keyboard_alt_colors", String(result.get("alt_colors", "#ff0000,#0000ff")))
	cm.set_value_and_notify("Lane", "keyboard_lane_separator", int(result.get("lane_separator", 0)))

# ===== 下落模式设置弹窗入口 =====
# 弹出下落模式设置窗口，关闭后 FallingAdjust 已通过 set_value_and_notify 即时应用到 FlowArea
# _pending_config 同步缓存，确保退出 SettingView 时 diff 保存到 settings.ini
func _popup_falling_adjust() -> void:
	var result := await PopupWindow.instance.show_falling_adjust()
	if result.is_empty():
		return
	_pending_config["note_fall_mode"] = int(result.get("note_fall_mode", 0))
	_pending_config["note_fall_time"] = float(result.get("note_fall_time", 1.0))
	_pending_config["note_fall_speed_after_judge_multiplier"] = float(result.get("note_fall_speed_after_judge_multiplier", 1.0))
	_pending_config["note_fall_easing_before_func"] = String(result.get("note_fall_easing_before_func", "LINEAR"))
	_pending_config["note_fall_easing_before_phase"] = String(result.get("note_fall_easing_before_phase", "IN"))
	_pending_config["note_fall_easing_after_func"] = String(result.get("note_fall_easing_after_func", "LINEAR"))
	_pending_config["note_fall_easing_after_phase"] = String(result.get("note_fall_easing_after_phase", "IN"))
	GLogger.info("Falling params updated: mode=%s time=%s (pending save)" % [result.get("note_fall_mode"), result.get("note_fall_time")], "SettingList")

# 弹出延迟校准窗口，校准结果写入当前输出类型对应的延迟预设（pending 保存）
# 双预设：蓝牙输出校准写 audio_playback_delay_bt，普通输出校准写 audio_playback_delay
# DelayAdjust 内部用 MidiPlaybackManager 实时合成 GM 鼓组节拍音，与 PlayView 演奏模式同音频路径
func _popup_delay_adjust() -> void:
	# 强制刷新检测后再选预设，保证校准目标与状态提示一致
	AudioBtDetector.is_bluetooth_output(true)
	var id := AudioBtDetector.get_active_delay_key()
	var default_value := 200 if id == "audio_playback_delay_bt" else 0
	var current := int(_pending_config.get(id,
		ConfigManager.instance.get_int("Gameplay", id, default_value)))
	var result := await PopupWindow.instance.show_delay_adjust(current)
	_pending_config[id] = int(result.get("delay", current))
	_pending_config["bt_auto_disable_performing_mode"] = int(result.get("bt_auto_off_performing", 1))
	GLogger.info("%s calibrated: %d ms (pending save)" % [id, _pending_config[id]], "SettingList")

# ===== 各判定类型特效设置弹窗入口 =====
# 4 个按钮分别对应 Perfect/Great/Good/Bad，调用统一的 _popup_spark_adjust(judge_type)
# ParticleAdjust 内部已通过 ConfigManager.set_value_and_notify 即时保存到对应字段
# _pending_config 同步缓存，确保退出 SettingView 时 diff 保存到 settings.ini

func _popup_perfect_spark_adjust() -> void:
	await _popup_spark_adjust("Perfect")

func _popup_great_spark_adjust() -> void:
	await _popup_spark_adjust("Great")

func _popup_good_spark_adjust() -> void:
	await _popup_spark_adjust("Good")

func _popup_bad_spark_adjust() -> void:
	await _popup_spark_adjust("Bad")

## 统一的特效设置弹窗入口
## judge_type: Perfect / Great / Good / Bad
## 关闭后将 preset 和 scaling 缓存到 _pending_config，由 save_config_to_file diff 保存
func _popup_spark_adjust(judge_type: String) -> void:
	var result := await PopupWindow.instance.show_particle_adjust(judge_type)
	if result.is_empty():
		return
	var judge_lower := judge_type.to_lower()
	_pending_config[judge_lower + "_spark_preset"] = result.get("preset", "")
	_pending_config[judge_lower + "_spark_emitter"] = result.get("emitter", "")
	_pending_config[judge_lower + "_spark_scaling"] = result.get("scaling", 100)
	_pending_config[judge_lower + "_spark_alpha"] = result.get("alpha", 100)
	_pending_config[judge_lower + "_spark_emitter_scaling"] = result.get("emitter_scaling", 150)
	GLogger.info("%s spark updated: base=%s emitter=%s scale=%s alpha=%s emitter_scale=%s (pending save)"
		% [judge_type, result.get("preset"), result.get("emitter"), result.get("scaling"), result.get("alpha"), result.get("emitter_scaling")], "SettingList")

# ===== 各视图背景设置弹窗入口 =====
# 每个视图一个 TYPE_BUTTON 入口，调用统一的 _popup_view_background_adjust(view_name)
# 配置即时保存到 theme.ini 的 [backgrounds] 段（由 ThemeManager.set_view_background 处理）
# 不走 _pending_config（不走 config.ini），因此退出 SettingView 时无需 diff 保存

func _popup_play_background_adjust() -> void:
	await _popup_view_background_adjust("play")

func _popup_main_background_adjust() -> void:
	await _popup_view_background_adjust("main")

func _popup_store_background_adjust() -> void:
	await _popup_view_background_adjust("store")

func _popup_score_background_adjust() -> void:
	await _popup_view_background_adjust("score")

func _popup_track_background_adjust() -> void:
	await _popup_view_background_adjust("track")

func _popup_midi_background_adjust() -> void:
	await _popup_view_background_adjust("midi")

func _popup_setting_background_adjust() -> void:
	await _popup_view_background_adjust("setting")

## 统一的视图背景设置弹窗
## view_name: main/store/score/play/track/midi/setting
## 仅 play 视图允许选择"封面"类型（allow_cover=true）
func _popup_view_background_adjust(view_name: String) -> void:
	var allow_cover := (view_name == "play")
	var result := await PopupWindow.instance.show_image_adjust(view_name, allow_cover)
	if result.is_empty():
		return
	# 转换为 ThemeManager 期望的格式（值统一为 String，与 theme.ini 读取时一致）
	var type_str := "image"
	match int(result.get("type", 0)):
		ImageAdjust.IMG_TYPE_IMAGE: type_str = "image"
		ImageAdjust.IMG_TYPE_GRADIENT: type_str = "gradient"
		ImageAdjust.IMG_TYPE_SOLID: type_str = "solid"
		ImageAdjust.IMG_TYPE_COVER: type_str = "cover"
	var config: Dictionary = {
		"type": type_str,
		"image_path": str(result.get("image_file", "")),
		"image_stretch": "cover" if int(result.get("fill_mode", 0)) == 0 else "fit",
		"solid_color": (result.get("solid_color") as Color).to_html(true),
		"gradient_top": (result.get("start_color") as Color).to_html(true),
		"gradient_bottom": (result.get("end_color") as Color).to_html(true),
	}
	var from: Vector2 = result.get("from", Vector2(0, 0))
	var to: Vector2 = result.get("to", Vector2(0, 1))
	config["gradient_from_x"] = str(from.x)
	config["gradient_from_y"] = str(from.y)
	config["gradient_to_x"] = str(to.x)
	config["gradient_to_y"] = str(to.y)
	if allow_cover:
		config["cover_blur"] = str(result.get("cover_blur", 0.35))
	# 即时保存到 theme.ini + 轻量刷新背景（refresh_backgrounds，不触发完整主题刷新）
	# PlayView 的 cover 模式由 PlayView 在切回 PLAY_VIEW 时通过 PlayBackground.apply_background 处理
	ThemeMGR.set_view_background(view_name, config)
	GLogger.info("%s background updated: type=%s" % [view_name, type_str], "SettingList")

# 重置内置资源：调用 FileSystemManager 重新复制默认资源
func _reload_builtin_resources() -> void:
	if FileSystemManager.instance:
		GLogger.info("Reloading built-in resources...", "SettingList")
		await FileSystemManager.instance.reload_default_resources()
		GLogger.info("Built-in resources reloaded", "SettingList")
	else:
		push_warning("[SettingList] FileSystemManager not available")

# ===== 存储位置设置弹窗入口 =====
# 流程：弹窗输入/浏览目标路径 → Android 权限检查 → 路径校验 → 非空警告 → 迁移 → 提示重启
# 浏览采用协程贯穿：弹窗关闭 → FileDialog 打开 → 选择后自动重开弹窗填入，不依赖弹窗记忆
func _popup_storage_location_adjust() -> void:
	if StorageManager.instance == null:
		push_warning("[SettingList] StorageManager not available")
		return

	var target := String(_pending_config.get("storage_location", ""))
	# 循环：browsing（弹窗为浏览让路关闭）→ 打开目录选择器 → 重开弹窗填入所选目录
	while true:
		var result := await PopupWindow.instance.show_storage_location_adjust(target)
		if String(result.get("action", "")) == "browsing":
			# Android：浏览公共存储目录前按需引导授权（SAF 选择后写入该路径同样需要权限；
			# 应用私有目录/默认路径无需权限，已授权则直接跳过）
			if PathHelper.is_android() \
					and not StorageManager.instance.is_android_storage_permission_granted():
				var go := await PopupWindow.instance.show_message(
					"浏览公共存储目录需要外部存储权限。\n点击“确定”前往系统设置开启，返回后请再次点击浏览。", true)
				if go:
					StorageManager.instance.open_android_permission_settings()
				return
			var picked := await _pick_storage_dir(String(result.get("path", "")))
			if picked.is_empty():
				return  # 用户取消了浏览，不重开弹窗
			# Android：SAF 原生选择器返回 content:// URI（如 tree/primary%3AthmixData），
			# 转换为真实文件路径（/storage/emulated/0/thmixData/）；SD 卡等无法转换时提示手动输入
			if PathHelper.is_android() and not picked.begins_with("/"):
				var real := StorageManager.saf_uri_to_path(picked)
				if real.is_empty():
					GLogger.warning("Android SAF picker returned unusable path: %s" % picked, "SettingList")
					await PopupWindow.instance.show_message(
						"所选位置（SD 卡等外部卷）无法转换为可直接写入的存储路径，请在输入框中手动填写路径。")
					return
				GLogger.info("Android SAF path converted: %s -> %s" % [picked, real], "SettingList")
				picked = real
			target = picked
			continue
		if String(result.get("action", "")) != "confirmed":
			return  # cancelled
		break
	var new_path := target.strip_edges()
	if new_path.is_empty():
		return

	# Android：共享存储公共目录需要"所有文件访问"权限，未授权先引导
	if StorageManager.needs_android_permission(new_path) \
			and not StorageManager.instance.is_android_storage_permission_granted():
		var go := await PopupWindow.instance.show_message(
			"目标目录位于共享存储中，需要“所有文件访问”权限。\n点击“确定”前往系统设置开启，返回后请再次点击本设置项。", true)
		if go:
			StorageManager.instance.open_android_permission_settings()
		return

	# 路径校验
	var v := StorageManager.validate_target_path(new_path)
	if not bool(v.get("ok", false)):
		await PopupWindow.instance.show_message(str(v.get("reason", "路径无效")))
		return

	# 目标目录冲突处理（迁移只创建/合并游戏资源目录，不删除目标内任何内容）
	var merge_dirs: Array = v.get("merge_dirs", [])
	var conflict_files: Array = v.get("conflict_files", [])
	var keep_target_files := false
	if not merge_dirs.is_empty():
		# 目标已存在同名游戏资源目录 → 合并确认
		var proceed := await PopupWindow.instance.show_message(
			"目标目录已检测到游戏资源：%s。\n迁移将合并两侧内容（同名文件保留目标已有版本），不删除任何内容。\n是否继续？" % "、".join(merge_dirs), true)
		if not proceed:
			return
	elif bool(v.get("target_not_empty", false)):
		# 目标有其它文件（非游戏资源）→ 现有非空警告
		var proceed := await PopupWindow.instance.show_message(
			"目标目录中已存在其他文件/文件夹。\n迁移只会在其中创建游戏资源目录"
			+ "（Charts/Soundfont/Skins/BackgroundImage/Particles/Charas），不会删除其中任何内容。\n是否继续？", true)
		if not proceed:
			return

	if not conflict_files.is_empty():
		# 不可合并文件（settings.ini/favorites.json/charts.ldb 等）：统一询问保留哪一侧
		keep_target_files = await PopupWindow.instance.show_storage_conflict_adjust(conflict_files)
		# true=保留目标已有版本（跳过）；false=保留当前版本（覆盖目标）

	# 迁移（弹窗已关闭，进度条遮罩可复用）
	var fs := FileSystemManager.instance
	var ui := {}
	if fs and fs.has_method("show_progress_ui"):
		ui = fs.show_progress_ui("正在迁移资源，请勿关闭游戏", 1)
	var mig: Dictionary = await StorageManager.instance.migrate(
		PathHelper.get_storage_root(), new_path, ui, keep_target_files)
	if fs and fs.has_method("hide_progress_ui"):
		fs.hide_progress_ui()

	if not bool(mig.get("ok", false)):
		await PopupWindow.instance.show_message("迁移失败：%s" % str(mig.get("reason", "未知错误")))
		return

	# 迁移提交成功：缓存 pending（退出设置页时幂等写回配置），提示重启生效
	# 使用规范化路径，与 migrate 提交到 settings.ini 的值保持一致
	_pending_config["storage_location"] = PathHelper.normalize_storage_path(new_path)
	# 自动重启（桌面：拉起新进程后退出）；不支持（Android）或失败时强制重启提示
	if not StorageManager.instance.request_restart():
		await _force_restart_prompt()

## 强制重启提示：迁移必须重启才能生效。自动重启不可用（Android / 桌面失败）时，
## 弹窗以强制模态模式循环显示（exclusive：无法点外部关闭），玩家只能点"确定"退出游戏，
## 从而无法继续游玩（若经 Android 返回键等其他途径关闭，会立即重新弹出）
func _force_restart_prompt() -> void:
	var msg := "资源迁移已完成，游戏必须重启后才能使用新的存储位置。\n请点击“确定”退出游戏，然后重新打开。"
	while true:
		var confirmed := await PopupWindow.instance.show_message(msg, false, [], true)
		if get_tree() == null:
			return
		if confirmed:
			get_tree().quit()
			return
		# 其他途径关闭（Android 返回键等）→ 循环重开，直到玩家退出游戏

## 打开系统原生目录选择器并等待选择结果（协程）
## 原生对话框（use_native_dialog=true，OS 级窗口）：dir_selected/canceled 信号由引擎保证
## （Godot 源码 _native_dialog_cb_with_options：取消 emit canceled，OPEN_DIR 选择 emit dir_selected）。
## 注意：原生模式下 FileDialog 节点不置位 visible（走 _native_popup 的 OS 窗口），
## 因此 visible 兜底仅适用于内置对话框，否则会在对话框刚打开时误判为取消。
## 等待采用 信号 + 超时 双重兜底，杜绝挂起。
var _storage_file_dialog: FileDialog = null

func _pick_storage_dir(current: String) -> String:
	if _storage_file_dialog == null or not is_instance_valid(_storage_file_dialog):
		_storage_file_dialog = FileDialog.new()
		_storage_file_dialog.name = "StoragePickDialog"
		_storage_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		_storage_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_storage_file_dialog.use_native_dialog = true
		_storage_file_dialog.title = "选择资源存储目录"
		get_tree().root.add_child(_storage_file_dialog)
	var fd: FileDialog = _storage_file_dialog
	if not current.is_empty() and DirAccess.dir_exists_absolute(current):
		fd.current_dir = current

	# 用 Dictionary 作为跨 lambda 的状态（GDScript lambda 按值捕获局部变量，修改不对外可见）
	var state := {"picked": "", "done": false}
	var on_dir := func(path: String) -> void:
		state["picked"] = path
		state["done"] = true
		GLogger.info("StoragePickDialog dir_selected: %s" % path, "SettingList")
	var on_canceled := func() -> void:
		state["done"] = true
		GLogger.info("StoragePickDialog canceled", "SettingList")
	fd.dir_selected.connect(on_dir)
	if fd.has_signal("canceled"):
		fd.canceled.connect(on_canceled)
	fd.popup_centered_clamped(Vector2(1024, 768), 0.7)
	GLogger.info("StoragePickDialog opened (native=%s, current=%s)" % [str(fd.use_native_dialog), current], "SettingList")
	var elapsed := 0
	while not bool(state["done"]):
		await get_tree().process_frame
		elapsed += 1
		if elapsed > 7200:
			GLogger.warning("StoragePickDialog wait timeout", "SettingList")
			break
		# visible 兜底仅对内置对话框有效：原生对话框为 OS 级窗口，FileDialog 节点 visible 恒为 false
		if not fd.use_native_dialog and not fd.visible and str(state["picked"]).is_empty():
			GLogger.info("StoragePickDialog closed without selection", "SettingList")
			break
	fd.dir_selected.disconnect(on_dir)
	if fd.has_signal("canceled"):
		fd.canceled.disconnect(on_canceled)
	GLogger.info("StoragePickDialog result: %s" % str(state["picked"]), "SettingList")
	return str(state["picked"])

## ========== options_provider 方法（供 SettingListItem 通过 Callable 调用） ==========

# 提供 theme_preset 选项
func _provide_theme_preset_options() -> Array:
	if not ThemeMGR:
		return []
	var presets := ThemeMGR.get_available_presets()
	var texts: Array = []
	for p in presets:
		texts.append(p)
	return texts

# 提供 soundfont_select 选项
func _provide_soundfont_options() -> Array:
	var sf_list = _scan_all_soundfonts()
	if sf_list.is_empty():
		sf_list = ["GeneralUser-GS [内置]"]
	return sf_list

## ========== 文件扫描方法（从 SettingView 移入） ==========

## 扫描所有 SoundFont 文件（user 优先）
func _scan_all_soundfonts() -> Array[String]:
	var soundfonts: Dictionary = {}  # {filename_without_ext: {display_name, path, is_builtin}}

	# 第一步：扫描用户音源目录（user 优先）
	var user_dir = PathHelper.get_soundfont_dir()
	if DirAccess.open(user_dir) != null:
		var dir = DirAccess.open(user_dir)
		if dir:
			dir.list_dir_begin()
			var file_name = dir.get_next()
			while file_name != "":
				if file_name.ends_with(".sf2"):
					var font_name = file_name.get_basename()
					soundfonts[font_name] = {
						"display_name": font_name,
						"path": user_dir.path_join(file_name),
						"is_builtin": false
					}
				file_name = dir.get_next()
			dir.list_dir_end()

	# 第二步：扫描 res://Resources/Soundfont/（仅添加 user 中没有的）
	var res_dir = "res://Resources/Soundfont/"
	if DirAccess.open(res_dir) != null:
		var dir = DirAccess.open(res_dir)
		if dir:
			dir.list_dir_begin()
			var file_name = dir.get_next()
			while file_name != "":
				if file_name.ends_with(".sf2"):
					var font_name = file_name.get_basename()
					if not soundfonts.has(font_name):
						soundfonts[font_name] = {
							"display_name": font_name + " [内置]",
							"path": res_dir.path_join(file_name),
							"is_builtin": true
						}
				file_name = dir.get_next()
			dir.list_dir_end()

	# 第三步：整理返回列表
	var result: Array[String] = []
	for font_name in soundfonts.keys():
		result.append(soundfonts[font_name]["display_name"])

	# 排序：用户文件优先，内置文件在后
	result.sort_custom(func(a: String, b: String) -> bool:
		var a_is_builtin = " [内置]" in a
		var b_is_builtin = " [内置]" in b
		if a_is_builtin != b_is_builtin:
			return a_is_builtin  # 内置的排在后面
		return a < b
	)

	return result

## 验证 SoundFont 文件是否存在
func _verify_soundfont_exists(soundfont_name: String) -> bool:
	var user_path = PathHelper.get_soundfont_dir().path_join(soundfont_name + ".sf2")
	if FileAccess.file_exists(user_path):
		return true
	var res_path = ("res://Resources/Soundfont/").path_join(soundfont_name + ".sf2")
	if ResourceLoader.exists(res_path):
		return true
	return false

## 获取 SoundFont 的实际路径
func _get_soundfont_path(soundfont_name: String) -> String:
	var user_path = PathHelper.get_soundfont_dir().path_join(soundfont_name + ".sf2")
	if FileAccess.file_exists(user_path):
		return user_path
	var res_path = ("res://Resources/Soundfont/").path_join(soundfont_name + ".sf2")
	if ResourceLoader.exists(res_path):
		return res_path
	return ""

## ========== 配置保存与应用 ==========

## 退出 SettingView 时调用：emit config_changed 信号应用变更
## 仅 emit 与 _initial_config 不同的项
func apply_pending_config_updates() -> int:
	var emitted_count = 0
	if EvtBus == null:
		push_warning("[SettingList] EventBus is null, skip applying pending config updates")
		return emitted_count

	for setting_id in _pending_config:
		if not SettingsMapper.mappings.has(setting_id):
			continue  # theme_preset 等不在 mappings 中的跳过
		var mapping = SettingsMapper.mappings[setting_id]
		var section = mapping.get("section", "")
		var key = mapping.get("key", "")
		if section.is_empty() or key.is_empty():
			continue
		var value = _pending_config[setting_id]
		var old_value = _initial_config.get(setting_id, null)
		# 仅 emit 变更项
		if str(old_value) == str(value):
			continue
		EvtBus.config_changed.emit(key, section, value)
		emitted_count += 1

	# 同步已应用状态到进入快照：后续 diff 基于"上次已应用值"而非"进入设置时快照"，
	# 修复同一会话内将设置切回启动时初始值后，退出时被判定为"无变化"而跳过 emit/写盘的问题
	for setting_id in _pending_config:
		_initial_config[setting_id] = _pending_config[setting_id]

	return emitted_count

## 是否有待保存的变更
func has_pending_changes() -> bool:
	for setting_id in _pending_config:
		var old_value = _initial_config.get(setting_id, null)
		if str(old_value) != str(_pending_config[setting_id]):
			return true
	return false

## 获取当前所有待保存配置的副本（供外部查询用）
func get_all_settings_as_json() -> Dictionary:
	return _pending_config.duplicate(true)

## 获取特定设置项的待保存值
func get_setting_value(setting_id: String) -> Variant:
	return _pending_config.get(setting_id, null)

## 设置特定设置项的值（同时更新 _pending_config）
func set_setting_value(setting_id: String, value: Variant) -> bool:
	if setting_items.has(setting_id):
		var setting_item = setting_items[setting_id]
		setting_item.set_value(value)
		_pending_config[setting_id] = value
		return true
	return false

## 获取指定选项型设置的显示文本
func get_option_text(setting_id: String, index: int) -> String:
	if not setting_items.has(setting_id):
		return ""
	var setting_item = setting_items[setting_id]
	if setting_item == null:
		return ""
	if not setting_item.value_node or not (setting_item.value_node is OptionButton):
		return ""
	var option_btn: OptionButton = setting_item.value_node
	if index < 0 or index >= option_btn.item_count:
		return ""
	return option_btn.get_item_text(index)

## 重置所有设置为默认值
func reset_to_defaults():
	for setting_id in setting_items:
		for group in setting_groups:
			for setting_data in group.settings:
				if setting_data.id == setting_id:
					var setting_item = setting_items[setting_id]
					if setting_item:
						setting_item.set_value(setting_data.default_value)
					break

## ========== 可见性控制 ==========

## 根据 show_advanced_settings 的值显示/隐藏所有标记为 advanced 的设置项
## 高级设置项与 SettingItem（Key VBoxContainer）和其 value_node 是 grid 容器中的兄弟节点，需同时切换
func _apply_advanced_visibility() -> void:
	var show_advanced := int(_pending_config.get("show_advanced_settings", "0")) == 1
	for group in setting_groups:
		for setting_data in group.settings:
			if not setting_data.get("advanced", false):
				continue
			var setting_id: String = setting_data.id
			if not setting_items.has(setting_id):
				continue
			var setting_item: SettingItem = setting_items[setting_id]
			if setting_item == null:
				continue
			setting_item.visible = show_advanced
			if setting_item.value_node:
				setting_item.value_node.visible = show_advanced

## ========== 难度预设锁定 ==========

## 难度相关配置变更：刷新 5 个受控项的显示值 + 锁定态
func _on_difficulty_config_changed(key: String, _section: String, _value: Variant) -> void:
	if key != DIFFICULTY_CFG_KEY:
		return
	_apply_difficulty_lock_state(false)

## apply_values_from_config=true: 仅切换锁定态（load_settings 后调用，值已就位）
## apply_values_from_config=false: 同时从 ConfigManager 重读 5 项值刷新显示（难度变更后调用）
func _apply_difficulty_lock_state(apply_values_from_config: bool) -> void:
	var difficulty_id: int = ConfigManager.instance.get_int(DIFFICULTY_CFG_SECTION, DIFFICULTY_CFG_KEY, 1)
	var locked: bool = difficulty_id != DIFFICULTY_CUSTOM_ID
	for setting_id in DIFFICULTY_LOCKED_IDS:
		if not setting_items.has(setting_id):
			continue
		var item: SettingItem = setting_items[setting_id]
		if item == null:
			continue
		if not apply_values_from_config:
			var mapping = SettingsMapper.mappings.get(setting_id)
			if mapping:
				var v: Variant = ConfigManager.instance.get_value(mapping.section, mapping.key, "")
				item.set_value(v)
				_pending_config[setting_id] = v
				_initial_config[setting_id] = v
		item.set_enabled(not locked)

## ========== 主题化 ==========

## 通过 StyleBoxFlat 共享引用自动同步，无需遍历 setting_items
## 注意：必须直接操作按钮自带 Theme 资源的 StyleBox（而非 Control.get_theme_stylebox）——
## 临时刻件未入树时 get_theme_stylebox 会沿引擎默认主题链解析，既不生效也触发
## "Viewport Texture must be set to use it" 报错；theme.get_stylebox 才是共享引用改色的正确入口
func apply_button_theme(color: Color) -> void:
	if not _value_button_instance:
		return
	var button_theme: Theme = _value_button_instance.theme
	if button_theme == null:
		return
	var sb_normal: StyleBoxFlat = button_theme.get_stylebox("normal", "Button") as StyleBoxFlat
	var sb_pressed: StyleBoxFlat = button_theme.get_stylebox("pressed", "Button") as StyleBoxFlat
	var sb_hover: StyleBoxFlat = button_theme.get_stylebox("hover", "Button") as StyleBoxFlat
	if sb_normal:
		sb_normal.bg_color = color
	if sb_pressed:
		sb_pressed.bg_color = color.darkened(0.25)
	if sb_hover:
		sb_hover.bg_color = color.lightened(0.15)

## 供 SettingListItem.setup_item 调用：从场景直接 instantiate 出 TYPE_BUTTON 的 value_node
func make_value_button() -> Button:
	return VALUE_BUTTON_SCENE.instantiate() as Button

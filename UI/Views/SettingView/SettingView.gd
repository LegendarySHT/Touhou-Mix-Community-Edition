extends Control
@onready var setting_list: SettingList = $HBoxC/SettingList
@onready var short_cut_btn = $HBoxC/ShortCut

## 配置文件路径（通过 PathHelper 动态获取，兼容 Android）
## 使用 getter 确保运行时才求值
static var CONFIG_PATH: String:
	get: return PathHelper.get_user_config_path()
const DEFAULT_CONFIG_PATH = "res://Resources/Config/config.ini"


func _ready() -> void:
	var idx: int = 0
	for btn:Button in short_cut_btn.get_children():
		btn.toggled.connect(_on_button_toggled.bind(idx))
		btn.focus_entered.connect(_btn_focus_entered.bind(btn))
		idx += 1

	# 页面切换
	EvtBus.page_left.connect(switch_page.bind(-1))
	EvtBus.page_right.connect(switch_page.bind(1))

	# 转移焦点至导航按钮
	short_cut_btn.focus_entered.connect(func():
		var btn: Button = short_cut_btn.get_child(0)
		for i in short_cut_btn.get_children():
			if i is Button and i.button_pressed:
				break
		btn.grab_focus()
	)

	# 从 ConfigLoader 加载配置
	_load_config_from_file()

	# 注册主题应用者并首次着色
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()

## 应用主题色（由 ThemeManager 广播调用 + _ready 首次自调）
## SettingList 的 value_button 主题；ShortCut 导航按钮的 focus 直接复用共享 Theme 的 focus StyleBox
## （ThemeManager 在 _refresh_theme_colors 里就地改其边框色，不再逐按钮 duplicate 覆盖）
func apply_theme() -> void:
	if setting_list:
		setting_list.apply_button_theme(ThemeMGR.get_color("primary"))

func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)

func get_all_child_nodes(c: Container):
	var node_array = []
	for i in c.get_children():
		node_array.append(i)
		if i.get_children():
			node_array += get_all_child_nodes(i)
	return node_array

func get_nearest_focusable_node(pos_y) -> Control:
	var nearest_node: Control = null
	var min_distance = INF
	
	# 获取GridContainer的全局位置
	var c: Container = setting_list.container
	
	
	# 遍历GridContainer的所有子节点
	var na = get_all_child_nodes(c)
	if not na:
		return null

	for child in na:
		# 确保节点是Control类型且可以聚焦
		if child.focus_mode != Control.FOCUS_NONE and child.global_position.y > 0 and child.global_position.y < c.get_global_rect().size.y:
			# 计算节点的中心点全局坐标
			var node_y = child.get_global_rect().position.y
			
			# 计算距离
			var distance = abs(node_y - pos_y)
			
			# 更新最近节点
			if distance < min_distance:
				min_distance = distance
				nearest_node = child

	return nearest_node

func _btn_focus_entered(btn: Button):
	if not btn.button_pressed:
		short_cut_btn.set_meta("snaping", true)
		btn.button_pressed = true
	
	for i in btn.get_parent().get_children():
		if i is Button and i != btn:
			i.z_index = 0
		else:
			i.z_index = 1

## 从文件加载配置
func _load_config_from_file() -> void:
	# 使用 ConfigManager 单例
	var config_manager = ConfigManager.instance

	# 优先从用户配置文件加载，如果不存在则使用默认配置
	var config_path = CONFIG_PATH if FileAccess.file_exists(CONFIG_PATH) else DEFAULT_CONFIG_PATH
	var ini_config = config_manager.load_config(config_path)

	if ini_config.is_empty():
		push_error("[SettingView] Failed to load config from: %s" % config_path)
		# 使用空字典，让 SettingList 使用默认值
		setting_list.load_settings({})
		return

	# 检查并迁移配置版本
	ini_config = config_manager.check_and_migrate(ini_config, config_path)

	# 转换 INI 格式为 SettingList 格式
	var settings_dict = SettingsMapper.ini_to_settings(ini_config)

	# 加载到 SettingList（内部会触发 options_provider 自动填充下拉选项、应用可见性等）
	setting_list.load_settings(settings_dict)

	GLogger.info("Loaded %d settings from: %s" % [settings_dict.size(), config_path], "SettingView")

## 保存配置到文件（由 AnimationManager 在退出时调用）
## 同步：构造待写盘配置（内存计算，含 soundfont 回退 + 类型化→字符串，颜色转 hex）+ 应用运行时变更。
##   这一步让运行时在退场动画开始前即更新，回去的界面读到的是新值，消除"卡得比较旧"。
## 异步：INI 序列化 + 磁盘写入较重，推到下一帧执行（call_deferred），避免阻塞退场动画首帧导致卡顿。
func save_config_to_file() -> bool:
	var config_manager = ConfigManager.instance

	# 1. 构造待写盘配置：基于磁盘已有内容做 diff，仅写变更项（内存计算，load_config 多数为缓存命中）
	#    value_type 统一字符串化；颜色转 hex（ConfigManager._serialize_ini 对 Color 只会写成 Color(...) 而非 hex，
	#    故必须在此显式处理，否则改过的配色会写坏）。
	var pending = setting_list._pending_config
	var initial = setting_list._initial_config
	var base_config = config_manager.load_config(
		CONFIG_PATH if FileAccess.file_exists(CONFIG_PATH) else DEFAULT_CONFIG_PATH).duplicate(true)

	for setting_id in pending:
		if not SettingsMapper.mappings.has(setting_id):
			continue  # theme_preset 等不在 mappings 中的项跳过（不写入 INI）
		var mapping = SettingsMapper.mappings[setting_id]
		var section = mapping.section
		var key = mapping.key
		var value = pending[setting_id]

		var old_value = initial.get(setting_id, null)
		if str(old_value) == str(value):
			continue  # 仅保存变更项

		var value_type = mapping.get("value_type", "string")
		match value_type:
			"int":
				value = str(int(value))
			"float":
				value = str(float(value))
			"bool":
				value = "1" if ConfigManager.parse_bool(value) else "0"
			"color":
				value = value.to_html() if value is Color else str(value)
			_:
				value = str(value)

		# soundfont 文件存在性校验，不存在则回退默认
		if setting_id == "soundfont_select":
			if not setting_list._verify_soundfont_exists(str(value)):
				GLogger.warning("Soundfont '%s' not found, falling back to default" % value, "SettingView")
				value = "GeneralUser-GS"
				pending[setting_id] = value  # 同步待保存值：通知与写盘须一致

		if not base_config.has(section) or not (base_config[section] is Dictionary):
			base_config[section] = {}
		base_config[section][key] = value
		GLogger.info("Save diff: [%s] %s = %s" % [section, key, str(value)], "SettingView")

	if not base_config.has("Game"):
		base_config["Game"] = {}
	base_config["Game"]["config_version"] = ConfigManager.CONFIG_VERSION

	# 2. 先统一 emit config_changed（运行时即时生效），再写盘。顺序不可颠倒：
	#    save_config 会把"字符串化"的新值合并进 ConfigManager._current_config，而 set_value_and_notify
	#    以 str 比较判定"值未变化"；若先写盘，typed 新值（如 int 1）与字符串值（"1"）判等，通知被静默吞掉，
	#    导致 NetManager(online_mode/server_address) 等依赖 config_changed 的运行时无法即时生效。
	if setting_list and setting_list.has_method("apply_pending_config_updates"):
		var applied_count = setting_list.apply_pending_config_updates(false)
		GLogger.info("Applied %d deferred config updates" % applied_count, "SettingView")

	# 同步发出 settings_changed：必须在退场动画之前。
	#    PlaybackDisplay 据此异步重载音源，重载完成回调在 is_playing=false（退场/暂停态）时
	#    会跳过人声 resync；若推迟到下一帧，TrackView 已 resume 并启动人声，重载完成会再次重启人声
	if EvtBus:
		EvtBus.settings_changed.emit("*", null)

	# 3. 磁盘写入较重，推迟到下一帧，避免阻塞退场动画首帧导致卡顿
	call_deferred("_persist_config_to_disk", base_config)
	return true

## 退场帧之后执行：把构造好的配置序列化并写盘。
## 写盘成功后才同步"已应用"快照；失败则保留 diff，下次退出会重试保存并重新通知。
func _persist_config_to_disk(base_config: Dictionary) -> void:
	var config_manager = ConfigManager.instance
	var success = config_manager.save_config(CONFIG_PATH, base_config)
	if success:
		GLogger.info("Saved config to: %s" % CONFIG_PATH, "SettingView")
		if setting_list and setting_list.has_method("sync_applied_config_snapshot"):
			setting_list.sync_applied_config_snapshot()
	else:
		push_error("[SettingView] Failed to save config to: %s" % CONFIG_PATH)

var _snap_tween: Tween = null
# 左侧快速跳转按钮的事件
func _on_button_toggled(_toggled_on: bool, idx: int):
	var target_idx = idx*2
	var c_idx = 0
	
	for node in setting_list.container.get_children():
		if node is Separator:
			if c_idx == target_idx:
				if _snap_tween:
					_snap_tween.kill()
				_snap_tween = AniMGR.create_managed_tween(self)
				_snap_tween.tween_property(setting_list, "scroll_vertical", node.position.y + node.size.y, 0.25).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
				_snap_tween.finished.connect(func ():
					_snap_tween = null
					short_cut_btn.remove_meta("snaping")
					var btn = short_cut_btn.get_child(idx)
					var neighbor = get_nearest_focusable_node(btn.get_global_position().y)
					if neighbor:
						btn.focus_neighbor_right = neighbor.get_path()
				)
			c_idx += 1

# 获取当前ui中的配置
func _get_config():
	var config = setting_list.get_all_settings_as_json()
	return config

## 获取特定设置的值
## 此方法由其他模块（如TrackView、PlayView）调用，用于查询当前设置值
## 优先从 SettingList 的 _pending_config 读取（包含本次会话的修改），未命中则回退到配置文件
func get_setting_value(setting_id: String) -> Variant:
	if setting_list == null:
		push_warning("[SettingView] SettingList not initialized when querying: %s" % setting_id)
		return null

	# 优先从待保存配置中读取（已转换好类型）
	var pending_value = setting_list.get_setting_value(setting_id)
	if pending_value != null:
		return pending_value

	# 回退：从配置文件读取
	var config_path = CONFIG_PATH if FileAccess.file_exists(CONFIG_PATH) else DEFAULT_CONFIG_PATH
	var ini_config = ConfigManager.instance.load_config(config_path)
	if not ini_config.is_empty():
		var settings_dict = SettingsMapper.ini_to_settings(ini_config)
		if settings_dict.has(setting_id):
			var value_str = settings_dict[setting_id]
			# 根据类型转换值
			match setting_id:
				"default_midi_volume", "default_vocal_volume", "audio_sync_threshold":
					if value_str.is_valid_int():
						return int(value_str)
			return value_str

	GLogger.warning("Setting not found: %s" % setting_id, "SettingView")
	return null

@onready var setting_page = $HBoxC
@onready var delete_page = $DelView
@onready var ani: AnimationManager = AniMGR
func switch_page(direction: int = 0):
	var op: bool = true
	if direction == -1:
		op = false
		delete_page.visible = true
		TextScrollMGR.resume_page(delete_page)
	else:
		setting_page.visible = true
		TextScrollMGR.resume_page(setting_page)

	var wid = setting_page.size.x + 600
	ani.animate_position(setting_page, Vector2(wid * 1 if not op else 0, 0), 0.5, "SV_PAGE_SW_1")
	await ani.animate_position(delete_page, Vector2(-wid * 1 if op else 0, 0), 0.5, "SV_PAGE_SW_2").finished

	setting_page.visible = op
	delete_page.visible = not op
	if op:
		TextScrollMGR.suspend_page(delete_page)
	else:
		TextScrollMGR.suspend_page(setting_page)
	# DelView 生命周期钩子：进入时触发懒加载构建，返回设置主页时保留节点
	if op:
		delete_page.on_exited_to_setting_list()
	else:
		delete_page.on_entered()

func has_pending_changes() -> bool:
	return setting_list and setting_list.has_pending_changes()

func switch_page_instant() -> void:
	setting_page.visible = true
	TextScrollMGR.resume_page(setting_page)
	delete_page.visible = false
	TextScrollMGR.suspend_page(delete_page)
	delete_page.on_exited_to_setting_list()

## 返回处理：DelView 子页面可见时先切回设置主页（Esc / Android 返回键调用）
## 返回 true 表示已消费返回事件，上层不应再执行 go_back
func handle_back_request() -> bool:
	if delete_page and delete_page.visible and not setting_page.visible:
		EvtBus.page_right.emit()
		return true
	return false

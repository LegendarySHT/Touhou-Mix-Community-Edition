extends Control
@onready var setting_list: SettingList = $HBoxC/SettingList
@onready var short_cut_btn = $HBoxC/ShortCut
@onready var about_page: Panel = $HBoxC/AboutPage

## 「关于」按钮在 ShortCut 中的下标。
## 该按钮不对应任何设置分组——按下它时把列表区整体换成 AboutPage，而非滚动到某个分组。
## 因此它必须 >= SettingGroupsData 的组数，否则会与真实分组抢下标。
const ABOUT_BTN_INDEX: int = 6

# ============ 关于页链接 ============
const PROJECT_URL := "https://github.com/LegendarySHT/Touhou-Mix-Community-Edition"
const WEBSITE_URL := "https://thmixce.org"
## 富文本链接颜色（暗/亮背景都可读的中蓝）
const LINK_COLOR := "#5aa9ff"

## 进入「关于」前停留的分组按钮下标，从关于页返回时用它还原位置
var _last_group_btn_idx: int = 0

## 关于页「自动检查更新」开关（会话内状态；联网接入后可持久化到配置）
var _auto_update_enabled: bool = false

## 配置文件路径（通过 PathHelper 动态获取，兼容 Android）
## 使用 getter 确保运行时才求值
static var CONFIG_PATH: String:
	get: return PathHelper.get_user_config_path()
const DEFAULT_CONFIG_PATH = "res://Resources/Config/config.ini"


func _ready() -> void:
	# 面板初始态：设置列表在前，关于页隐藏。两者互斥显示，由 _show_about 统一切换
	_show_about(false)

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

	# 关于页动态内容绑定（版本号/关于项目/更新历史，版本以 VerMGR / version_history.json 为准）
	refresh_about_page()

## 应用主题色（由 ThemeManager 广播调用 + _ready 首次自调）
## SettingList 的 value_button 主题；ShortCut 导航按钮的 focus 直接复用共享 Theme 的 focus StyleBox
## （ThemeManager 在 _refresh_theme_colors 里就地改其边框色，不再逐按钮 duplicate 覆盖）
func apply_theme() -> void:
	if setting_list:
		setting_list.apply_button_theme(ThemeMGR.get_color("primary"))

	# 关于页面板：比 TabContainer 内容底(surface)再后退一档——
	# 暗色模式更深、浅色模式更浅，统一取 surface_low（该 token 在两种模式下都更远离 surface：
	# 暗色 V 更低、浅色 V 更高）。几何与 alpha 沿用 tscn 的 StyleBoxFlat_xkn3i，仅改 RGB。
	if about_page and about_page.has_theme_stylebox_override("panel"):
		var sb := about_page.get_theme_stylebox("panel")
		if sb is StyleBoxFlat:
			var c := ThemeMGR.get_color("surface_low")
			sb.bg_color = Color(c.r, c.g, c.b, sb.bg_color.a)

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

	# 检查并迁移配置版本。
	# 只对用户配置做迁移：内置 res:// 默认配置永远是最新结构，而且导出版里是只读的 PCK，
	# 拿它去迁移只会尝试写一个不可写路径。
	if config_path == CONFIG_PATH:
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
		var key = String(mapping.key)
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

		# 落点 section 从 ConfigManager 的 key 索引取（唯一真相），不写死字符串：
		# ini 分组怎么重排，这里都跟着走。
		var section := config_manager.get_section_of(key)
		if section.is_empty():
			GLogger.warning("Save diff: key 未登记，跳过写入: %s" % key, "SettingView")
			continue
		if not (base_config.get(section) is Dictionary):
			base_config[section] = {}
		base_config[section][key] = value
		GLogger.info("Save diff: [%s] %s = %s" % [section, key, str(value)], "SettingView")

	# 版本号同样按键写入（原先写死 [Game] 段，导致 [System] 里的版本号永远不更新）
	config_manager.set_value("config_version", ConfigManager.CONFIG_VERSION, "System", base_config)

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
	# 「关于」不是设置分组：切面板后直接返回。
	# 它没有对应的分隔符，继续走下面的滚动定位会算不到目标而空转
	if idx == ABOUT_BTN_INDEX:
		_enter_about()
		return

	_last_group_btn_idx = idx
	# 若当前停在关于页，先播退出动画，结束后再揭示目标分组；否则直接显示并吸附
	if about_page.visible:
		_exit_about(_reveal_group.bind(idx))
	else:
		_show_about(false)
		_reveal_group(idx)

## 揭示指定分组：显示设置列表并吸附滚动到该组（原 _on_button_toggled 内的滚动定位逻辑）
func _reveal_group(idx: int) -> void:
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

## 切换「设置列表 ↔ 关于页」。
## 两者都是 HBoxC 的直接子节点且都设了 expand，互斥显示即可让 HBoxContainer
## 只给可见的那个分配宽度——左侧 ShortCut 按钮栏因此保持原位，不会被挤压。
func _show_about(is_about: bool) -> void:
	if setting_list:
		setting_list.visible = not is_about
	if about_page:
		about_page.visible = is_about

## 关于页入场：从右侧滑入 + 淡入；子元素轻微上移错峰增加层次（不改 alpha，避免与整体淡入叠加）
func _enter_about() -> void:
	if about_page.visible:
		return
	_show_about(true)   # setting_list 隐藏、about_page 显示
	AniMGR.animate_fade_slide_in(about_page, Vector2(1500, 0), AniMGR.DURATION_NORMAL, "about_enter")
	_stagger_about_children()

## 关于页子元素错峰入场（仅位移，不改 alpha）
func _stagger_about_children() -> void:
	# AboutPage 的三个直接子节点：项目头（Project）/ 分隔线（Line）/ 标签页（TabContainer）
	var child_names := ["Project", "Line", "TabContainer"]
	var i := 0
	for name in child_names:
		var node := about_page.get_node_or_null(name)
		if node == null or not (node is Control):
			continue
		node.offset_transform_enabled = true
		node.offset_transform_position = Vector2(0, 40)
		var tw := AniMGR.create_managed_tween(node, "about_child_%d" % i)
		if tw == null:
			i += 1
			continue
		tw.set_ease(AnimationManager.EASING_STANDARD)
		tw.set_trans(Tween.TRANS_CUBIC)
		tw.tween_property(node, "offset_transform_position", Vector2.ZERO, 0.3).set_delay(0.08 * i)
		i += 1

## 关于页出场：滑出 + 淡出，结束后显示设置列表并回调（p_on_done 通常为揭示目标分组）
func _exit_about(p_on_done: Callable = Callable()) -> void:
	if not about_page.visible:
		if p_on_done.is_valid():
			p_on_done.call()
		return
	var tween := AniMGR.animate_fade_slide_out(about_page, Vector2(1500, 0), AniMGR.DURATION_QUICK, "about_exit")
	if tween and tween.is_valid():
		tween.finished.connect(func() -> void:
			if is_instance_valid(setting_list):
				setting_list.visible = true
				TextScrollMGR.resume_page(setting_list)
			if p_on_done.is_valid():
				p_on_done.call()
		)
	else:
		if is_instance_valid(setting_list):
			setting_list.visible = true
		if p_on_done.is_valid():
			p_on_done.call()

## 从关于页返回上一次停留的分组。
## 直接置 button_pressed 会重新触发 toggled → _on_button_toggled，从而复用那里的
## 滚动吸附与右邻焦点重建，不必在这里重复实现一遍定位逻辑。
func _restore_last_group() -> void:
	var btn := short_cut_btn.get_child(_last_group_btn_idx)
	if btn is Button and not (btn as Button).button_pressed:
		(btn as Button).button_pressed = true
	else:
		# 按钮已是按下态则不会触发 toggled，兜底播退出动画并把面板切回去
		_exit_about(func() -> void: _show_about(false))

# 获取当前ui中的配置
func _get_config():
	var config = setting_list.get_all_settings_as_json()
	return config

## 关于页版本号动态绑定（避免硬编码，版本以 VerMGR / version_history.json 为准）
func _refresh_about_version() -> void:
	if about_page == null or VerMGR == null:
		return
	var ver_label := about_page.get_node_or_null("Project/Info/Version")
	if ver_label is Label:
		ver_label.text = VerMGR.get_version_label()

## 刷新关于页全部动态内容：版本号、关于项目正文、更新历史、链接与更新按钮。
## _ready 时调用一次；外部需要时也可再次调用强制刷新。
func refresh_about_page() -> void:
	if about_page == null:
		return
	_refresh_about_version()
	_setup_about_content()

## 构建关于项目的 BBCode（含可点击链接）
func _about_project_bbcode() -> String:
	var lines := PackedStringArray()
	lines.append("TouHou Mix Cummunity Edition 是由 TouHou Mix 的爱好者共同开发的 THMIX 社区版")
	lines.append("如有问题或者改进建议可在 Github 或在 THMIX QQ群 (β群: 1020610194 γ群: 140497416) 中提出")
	lines.append("目前项目缺少IOS端的测试及擅长UI设计的成员，如果你对此项目感兴趣，欢迎加入我们~")
	lines.append("")
	lines.append("项目贡献者: LegendarySHT, YangQwQ")
	lines.append("")
	lines.append("[b]相关链接[/b]")
	lines.append("[url=%s][color=%s]项目地址[/color][/url]	[url=%s][color=%s]临时官网[/color][/url]" % [PROJECT_URL, LINK_COLOR, WEBSITE_URL, LINK_COLOR])
	return "\n".join(lines)

## 绑定关于页各 RichTextLabel 的动态内容与链接点击、检查更新按钮。
## 外观/滚动/字号/布局等静态属性全部在 SettingView.tscn 中定义，代码不覆盖。
func _setup_about_content() -> void:
	# 关于项目
	var about_text := about_page.get_node_or_null("TabContainer/About/Margin/text") as RichTextLabel
	if about_text:
		_bind_link_signal(about_text)
		about_text.text = _about_project_bbcode()

	# 版本历史
	var hist_text := about_page.get_node_or_null("TabContainer/History/Content/Margin/RichTextLabel") as RichTextLabel
	if hist_text:
		_bind_link_signal(hist_text)
		hist_text.text = _history_bbcode()

	# 检查更新按钮
	var manual_btn := about_page.get_node_or_null("TabContainer/History/Update/ManualUpdate") as Button
	if manual_btn and not manual_btn.pressed.is_connected(_on_manual_update_pressed):
		manual_btn.pressed.connect(_on_manual_update_pressed)
	var auto_btn := about_page.get_node_or_null("TabContainer/History/Update/AutoUpdate") as Button
	if auto_btn and not auto_btn.toggled.is_connected(_on_auto_update_toggled):
		auto_btn.toggled.connect(_on_auto_update_toggled)

## 统一配置 RichTextLabel：只负责行为（[url] 点击），
## 富文本/滚动/字号/布局等静态属性全部在 SettingView.tscn 中定义。
func _bind_link_signal(rt: RichTextLabel) -> void:
	if not rt.meta_clicked.is_connected(_on_link_clicked):
		rt.meta_clicked.connect(_on_link_clicked)

## 点击富文本里的 [url] 链接：交给系统浏览器打开
func _on_link_clicked(meta: Variant) -> void:
	var url := str(meta).strip_edges()
	if url.is_empty():
		return
	var err := OS.shell_open(url)
	if err != OK:
		GLogger.warning("打开链接失败(%d): %s" % [err, url], "SettingView")

## 生成版本历史的 BBCode
func _history_bbcode() -> String:
	if VerMGR == null:
		return ""
	var entries: Array = VerMGR.get_history(true)
	if entries.is_empty():
		return "[i]暂无版本历史[/i]"
	var blocks := PackedStringArray()
	for entry in entries:
		if entry is Dictionary:
			blocks.append(_history_entry_bbcode(entry))
	return "\n\n".join(blocks)

## 单条版本记录：标题 版本号 / 更新内容 / 发布频道 时间 / 下载链接
func _history_entry_bbcode(entry: Dictionary) -> String:
	var title := str(entry.get("title", "")).strip_edges()
	var ver := str(entry.get("version", "")).strip_edges()
	var channel := str(entry.get("channel", "")).strip_edges()
	var date := str(entry.get("date", "")).strip_edges()
	var download := str(entry.get("download_url", "")).strip_edges()
	var changes: Array = entry.get("changes", [])

	var lines := PackedStringArray()
	# 1) 标题 版本号
	var head := ""
	if not title.is_empty():
		head += "[b][font_size=34]%s[/font_size][/b]" % title
	if not ver.is_empty():
		if not head.is_empty():
			head += "    "
		head += "[color=#8b93a1][font_size=28]v%s[/font_size][/color]" % ver
	if not head.is_empty():
		lines.append(head)
	# 2) 更新内容
	if changes is Array and not changes.is_empty():
		for c in changes:
			lines.append("    • %s" % str(c))
	# 3) 发布频道 时间
	var meta_parts := PackedStringArray()
	if not channel.is_empty():
		meta_parts.append("发布频道：%s" % _channel_label(channel))
	if not date.is_empty():
		meta_parts.append("时间：%s" % date)
	if not meta_parts.is_empty():
		lines.append("[color=#8b93a1][i]%s[/i][/color]" % "　　".join(meta_parts))
	# 4) 下载链接（可点击）
	if not download.is_empty():
		lines.append("[url=%s][color=%s]下载链接[/color][/url]" % [download, LINK_COLOR])
	return "\n".join(lines)

## 发布频道值转中文标签（未知值原样返回）
func _channel_label(channel: String) -> String:
	match channel.to_lower():
		"stable", "release", "lts":
			return "稳定版"
		"beta":
			return "测试版"
		"alpha":
			return "内测版"
		"dev", "nightly", "snapshot":
			return "开发版"
		_:
			return channel

## 「手动检查更新」按钮
func _on_manual_update_pressed() -> void:
	var status_label := about_page.get_node_or_null("TabContainer/History/Update/Status") as Label
	check_for_update(status_label)

## 「自动检查更新」开关（当前仅记录会话内状态；联网接入后可持久化）
func _on_auto_update_toggled(on: bool) -> void:
	_auto_update_enabled = on
	if on:
		_on_manual_update_pressed()

## 检查更新入口（也供外部调用）。
func check_for_update(status_label: Label = null) -> void:
	if VerMGR == null:
		return
	if status_label:
		status_label.text = "正在检查更新…"
	VerMGR.update_check_finished.connect(func(result: Dictionary) -> void:
		if status_label == null:
			return
		if not result.get("ok", false):
			var reason := str(result.get("reason", ""))
			if reason == "disabled":
				status_label.text = "在线更新尚未接入"
			else:
				status_label.text = "检查更新失败：%s" % reason
			return
		if result.get("has_update", false):
			status_label.text = "发现新版本：v%s" % str(result.get("latest", ""))
		else:
			status_label.text = "已是最新版本（v%s）" % str(result.get("current", ""))
	, CONNECT_ONE_SHOT)
	VerMGR.check_for_updates()

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
	# 关于页可见时，返回键先回设置列表（还原进入前的分组），而不是直接退出设置
	if about_page and about_page.visible:
		_restore_last_group()
		return true
	return false

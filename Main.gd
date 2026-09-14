extends Control

# Root 节点脚本
# 重构后的主节点，负责初始化核心系统

## 核心系统引用
var data_manager: DataManager
var event_bus: EventBus
var state_manager: UIStateManager
var animation_manager: AnimationManager
var sorting_engine: SortingEngine
var score_calculator: ScoreCalculator
var audio_manager: AudioManager
var midi_playback_manager: MidiPlaybackManager
var key_sequence_manager: KeySequenceManager
var config_loader: ConfigManager
var logger: GameLogger
var filesystem_manager: FileSystemManager
var storage_manager: StorageManager
var net_manager: NetManager
var auth_manager: AuthManager
var score_manager: ScoreManager
var community_manager: CommunityManager
var _is_reloading_settings: bool = false

# UI组件路径
@export var midi_view_path: String
@export var store_view_path: String
@export var track_view_path: String
@export var play_view_path: String
@export var score_view_path: String
@export var setting_view_path: String

func _ready():
	# Android 平台：请求存储权限（fire-and-forget，外部私有目录实际不需要运行时权限）
	if PathHelper.is_android():
		GLogger.info("Android platform detected", "Main")
		GLogger.info("Base dir: %s" % PathHelper.get_base_dir(), "Main")
		OS.request_permissions()

	_initialize_core_systems()

## Android 系统返回键
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_handle_back_request()
	elif what == NOTIFICATION_WM_CLOSE_REQUEST:
		# 应用退出时关闭 CoverLoader 线程池，确保所有后台线程 wait_to_finish
		if CoverLoader:
			CoverLoader.shutdown()
		# 关闭 LiteDB（Dispose 刷写 journal）
		if ChartDB:
			ChartDB.CloseDb()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
			# 应用焦点回归：重新检测蓝牙输出（用户可能在离开期间切换了输出设备），
			# 蓝牙状态变化时自动切换延迟预设并重建音频桥跟随新默认设备
			if MidiPlaybackManager.instance != null:
				MidiPlaybackManager.instance.refresh_audio_delay()
				# 安卓：返回前台时仍处 PLAY_VIEW，设备可能已被系统打断(全屏来电/切后台再回)，
				# 设备级重启自愈，避免挂断/返回后无声音；即使已自动暂停也先修好设备
				if OS.get_name() == "Android" \
						and state_manager.current_state == UIStateManager.UIState.PLAY_VIEW:
					MidiPlaybackManager.instance.recover_audio_output()

## 桌面端 Esc 键（仅在无其他控件消费事件时触发）
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed:
		_handle_back_request()

## 统一的返回/退出处理
func _handle_back_request() -> void:
	# 主界面 → 显示退出确认
	if state_manager.current_state == UIStateManager.UIState.ALBUM_VIEW:
		var popup = PopupWindow.instance
		if popup and await popup.show_message("确定要退出游戏吗？", true):
			get_tree().quit()

	# 打歌界面 → 交由 PlayView 处理（准备阶段切暂停菜单/暂停后继续等逻辑都在其中）
	elif state_manager.current_state == UIStateManager.UIState.PLAY_VIEW:
		var play_view = get_node_or_null("PlayView")
		if play_view:
			play_view.show_or_hide_menu()

	# 设置页内部子页面（DelView）→ 先切回设置主页，而非直接退出设置
	elif state_manager.current_state == UIStateManager.UIState.SETTINGS_VIEW:
		var setting_view = state_manager.get_loaded_view(UIStateManager.UIState.SETTINGS_VIEW)
		if setting_view and setting_view.has_method("handle_back_request"):
			setting_view.handle_back_request()

	# 其他层级 → 返回上一级
	else:
		state_manager.go_back()

## 初始化核心系统
func _initialize_core_systems() -> void:
	GLogger.info("Initializing Core Systems", "Main")

	# 启动阶段显示通用加载提示（ProcessTip 默认可见，「加载中，请稍后」；数据就绪后由 _on_data_loaded 隐藏）
	var process_tip := get_node_or_null("ProcessTip")
	if process_tip:
		process_tip.visible = true

	# 1. 初始化日志系统（单例，已自动管理）
	logger = GLogger
	if logger:
		logger.info("Logger initialized", "Main")

	# 1.5. 存储管理器：恢复/解析自定义存储根（必须先于配置加载，因为 settings.ini 随存储根迁移）
	# 读取迁移日志 / 引导指针处理崩溃恢复，并把最终存储根注入 PathHelper
	storage_manager = StorageManager.new()
	storage_manager.name = "StorageManager"
	add_child(storage_manager)
	var storage_resolve: Dictionary = storage_manager.recover_and_resolve()
	if logger:
		logger.info("Storage root resolved: %s (note=%s, full_rescan=%s, restored=%s)" % [
			PathHelper.get_storage_root(),
			str(storage_resolve.get("note", "")),
			str(storage_resolve.get("needs_full_rescan", false)),
			str(storage_resolve.get("restored", false))], "Main")
	# 自定义存储根生效后刷新日志路径（日志目录 Logs/ 随存储根迁移）
	if PathHelper.get_storage_root() != PathHelper.get_boot_dir():
		GLogger.refresh_log_path()

	# 2. 初始化配置管理器（单例，已自动管理）
	config_loader = ConfigManager.instance
	if logger:
		logger.info("ConfigManager initialized", "Main")

	# 2.5. **关键**：立即加载并设置当前配置，以便后续 Manager 初始化时能读取配置
	# 必须在其他 Manager 初始化之前调用；settings.ini 位于存储根下（override 已生效）
	config_loader.clear_cache()
	config_loader.load_and_set_current()
	if logger:
		logger.info("Configuration pre-loaded before Manager initialization", "Main")

	# 2.6. 刚完成迁移提交时，把 custom_storage_path 幂等补写进 settings.ini
	# （committed 与配置落盘之间可能崩溃，需保证无日志引导时也能定位新根）
	if bool(storage_resolve.get("needs_config_commit", false)):
		config_loader.set_value("Storage", "custom_storage_path", str(storage_resolve.get("pending_root", "")))
		config_loader.save_config(ConfigManager.USER_CONFIG_PATH, config_loader.get_current_config())
		if logger:
			logger.info("Storage config committed to settings.ini", "Main")

	# 2.75. ThemeManager 已通过 autoload 自动实例化
	if ThemeMGR and ThemeMGR.is_loaded():
		logger.info("ThemeManager initialized with theme: %s" % ThemeMGR.get_theme_name(), "Main")

	# 3. 初始化文件系统管理器（单例，已自动管理）
	filesystem_manager = FileSystemManager.new()
	filesystem_manager.name = "FileSystemManager"
	add_child(filesystem_manager)
	# 存储根刚迁移时强制全量扫描（重建 DB 缓存投影中的绝对路径）
	filesystem_manager.force_full_rescan = bool(storage_resolve.get("needs_full_rescan", false))
	if logger:
		logger.info("FileSystemManager initialized", "Main")
	
	# 初始化目录结构（异步：复制默认资源 → 导入外部游戏 → 扫描并更新 DB 缓存）
	# 注意：initialize_directory_structure 是异步协程，其内部扫描可能同步执行，
	# 因此必须先把 ChartDB 打开，确保扫描读缓存时 DB 已就绪（避免每次启动误走全量扫描）
	# 3.25. 确保 DB 目录存在后再打开 ChartDB（LiteDB 数据层），必须在 FileSystemManager 扫描前就绪
	# 路径经 globalize_path 转为真实 OS 路径供 C# System.IO 使用
	# DB 随可移动存储根迁移（charts.ldb 位于 get_storage_root() 下）
	var files_dir := ProjectSettings.globalize_path(PathHelper.get_storage_root())
	DirAccess.make_dir_recursive_absolute(files_dir)
	if ChartDB:
		var db_path := files_dir.path_join("charts.ldb")
		var old_cache_path := ProjectSettings.globalize_path(PathHelper.get_base_dir()).path_join(".charts_scan_cache.json")
		ChartDB.OpenDb(db_path, old_cache_path)
		if logger:
			logger.info("ChartDB opened (db: %s)" % db_path, "Main")

	# 初始化目录结构（扫描此时 DB 已就绪）
	filesystem_manager.initialize_directory_structure()
	
	# 4. 初始化事件总线（单例，已自动管理）
	event_bus = EvtBus
	if event_bus and logger:
		logger.info("EventBus initialized", "Main")
	
	# 5. 初始化UI状态管理器（单例，已自动管理）
	state_manager = UiStatMGR
	if state_manager and logger:
		logger.info("UIStateManager initialized", "Main")
	
	# 6. 初始化动画管理器（单例，已自动管理）
	animation_manager = AniMGR
	if animation_manager and logger:
		logger.info("AnimationManager initialized", "Main")
	
	# 7. 初始化排序引擎（单例，已自动管理）
	sorting_engine = SortEngine
	if sorting_engine and logger:
		logger.info("SortingEngine initialized", "Main")
	
	# 8. 初始化数据管理器（单例，已自动管理）
	data_manager = DataMGR
	if data_manager and logger:
		logger.info("DataManager initialized", "Main")

	# 8.5 初始化收藏夹管理器（需在 DataManager 之后，因为它依赖 data_loaded_complete 验证 midi 引用）
	var favorite_manager := FavoriteManager.new()
	favorite_manager.name = "FavoriteManager"
	add_child(favorite_manager)
	if logger:
		logger.info("FavoriteManager initialized", "Main")

	# 9.5 初始化分数计算器
	score_calculator = ScoreCalculator.new()
	score_calculator.name = "ScoreCalculator"
	add_child(score_calculator)
	if logger:
		logger.info("ScoreCalculator initialized", "Main")
	
	# 10. 初始化音频管理器
	audio_manager = AudioManager.new()
	audio_manager.name = "AudioManager"
	add_child(audio_manager)
	if logger:
		logger.info("AudioManager initialized", "Main")
	
	# 11. 初始化MIDI播放管理器
	midi_playback_manager = MidiPlaybackManager.new()
	midi_playback_manager.name = "MidiPlaybackManager"
	add_child(midi_playback_manager)
	if logger:
		logger.info("MidiPlaybackManager initialized", "Main")
	
	# 让出帧：MeltySynth 后端初始化（场景加载 + C# _Ready）较重，
	# 让引擎先渲染一帧再继续 UI 初始化，避免单帧卡顿
	await get_tree().process_frame

	# 12. 初始化键序列管理器
	key_sequence_manager = KeySequenceManager.new()
	key_sequence_manager.name = "KeySequenceManager"
	add_child(key_sequence_manager)
	if logger:
		logger.info("KeySequenceManager initialized", "Main")

	# 12.5. 初始化网络与认证管理器（必须在 ConfigManager 之后，UI 之前）
	net_manager = NetManager.new()
	net_manager.name = "NetManager"
	add_child(net_manager)
	# 读取 online_mode 配置并启动连接
	var online_mode := ConfigManager.instance.get_int("General", "online_mode", 0)
	net_manager.set_online_mode(online_mode == 1)
	if logger:
		logger.info("NetManager initialized (online_mode=%d)" % online_mode, "Main")

	auth_manager = AuthManager.new()
	auth_manager.name = "AuthManager"
	add_child(auth_manager)
	if logger:
		logger.info("AuthManager initialized", "Main")

	# 12.6. 初始化成绩管理器（必须在 NetManager 和 AuthManager 之后）
	score_manager = ScoreManager.new()
	score_manager.name = "ScoreManager"
	add_child(score_manager)
	if logger:
		logger.info("ScoreManager initialized", "Main")

	# 12.7. 初始化社区管理器（依赖网络、认证、成绩管理器与已打开的 ChartDB）
	community_manager = CommunityManager.new()
	community_manager.name = "CommunityManager"
	add_child(community_manager)
	if logger:
		logger.info("CommunityManager initialized", "Main")

	# 13. 初始化并加载UI（确保各管理器已就绪）
	_init_ui()

	# 让出帧：让引擎先渲染 Main.tscn 内嵌视图，再继续信号连接和数据加载
	# （6 个 _init_ui 视图已改为懒加载，启动阶段不再实例化）
	await get_tree().process_frame

	# 13.5. 预加载 SoundFont 到后端（~30MB，同步阻塞 3-5 秒）
	# 放在 UI 渲染后、信号连接/MIDI 数据加载前，确保阻塞发生在启动阶段而非用户交互阶段
	midi_playback_manager._preload_soundfont_to_backend()

	# 连接信号
	_connect_signals()
	
	# 加载配置
	_load_configuration()
	
	# 异步加载MIDI数据
	_load_midi_data()
	
	GLogger.info("Core Systems Initialized", "Main")

func _init_ui() -> void:
	# 6 个视图（MidiView/StoreView/TrackView/SettingView/ScoreView/PlayView）改为懒加载，

	# 应用主题（Theme 资源 + 主界面组件；背景不在此刷新，由各视图/refresh_backgrounds 处理）
	# Main 注册为主题应用者，首次自调 apply_theme，再由 refresh_theme_only 广播给所有已注册视图/组件
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()
		ThemeMGR.refresh_theme_only()

## 应用主题色到主框架组件（由 ThemeManager 广播调用 + _init_ui 首次自调）
func apply_theme() -> void:
	# LT_Btn — 蓝 (primary)，按钮各状态渐变框
	var lt := get_node_or_null("LT_Btn") as Button
	if lt:
		ThemeMGR._modify_button_states_color(lt, "primary")
	# RB_Btn — 淡蓝 (primary_light)
	var rb := get_node_or_null("RB_Btn") as Button
	if rb:
		ThemeMGR._modify_button_states_color(rb, "primary_light")
	# ShortCutMenu 面板 — 蓝 (primary)
	var sc_panel := get_node_or_null("skew/C/ShortCutMenu/Panel")
	if sc_panel:
		ThemeMGR._modify_panel_color(sc_panel, "primary")
	# PlayerInfo 面板按钮 — 暗色 (primary_dark)
	var info_btn := get_node_or_null("PlayerInfo/InfoPanelBtn") as Button
	if info_btn:
		var pd := ThemeMGR.get_color("primary_dark")
		for state in ["normal", "pressed", "hover"]:
			var sb := info_btn.get_theme_stylebox(state)
			if sb is StyleBoxFlat:
				sb.bg_color = pd
				sb.border_color = pd.lightened(0.3)
	# LogIn 在 Node2D(Skew) 下，不继承 Main 的 theme，手动复制
	var login := get_node_or_null("PlayerInfo/InfoPanelBtn/TabC/C/Skew/LogIn") as Control
	if login:
		login.theme = self.theme

## 连接核心系统信号
func _connect_signals() -> void:
	# 数据加载完成信号
	data_manager.data_loaded.connect(_on_data_loaded)
	
	# 状态改变信号
	state_manager.state_changed.connect(_on_state_changed)

	# 设置变化信号
	event_bus.settings_changed.connect(_on_settings_changed)
	
	# 配置变更信号（新增）
	event_bus.config_changed.connect(_on_config_changed)

## 加载配置文件（验证和应用）
func _load_configuration() -> void:
	# 配置已在 _initialize_core_systems() 中预加载
	# 这里仅进行验证和应用
	var config = config_loader.get_current_config()
	
	if config.is_empty():
		logger.warning("Current configuration is empty", "Main")
		return
	
	logger.info("Configuration loaded successfully, sections: %d" % config.size(), "Main")
	
	# 检查版本并迁移（如必要）
	config_loader.check_and_migrate()

## 加载MIDI数据
func _load_midi_data() -> void:
	logger.info("=== Starting MIDI Data Load ===", "Main")
	logger.info("Platform: %s" % OS.get_name(), "Main")
	logger.info("User data path: %s" % OS.get_user_data_dir(), "Main")
	
	# 诊断：检查 res:// 资源是否存在
	var resources_to_check = [
		"res://Resources/Config/config.ini",
		"res://Resources/Charts/",
		"res://Resources/Soundfont/",
		"res://Resources/BackgroundImage/"
	]
	
	for res in resources_to_check:
		var exists = false
		if res.ends_with("/"):
			exists = DirAccess.dir_exists_absolute(res)
		else:
			exists = FileAccess.file_exists(res)
		logger.info("Resource check [%s]: %s" % [res, "✓" if exists else "✗"], "Main")
		if not exists:
			logger.error("Critical resource missing - Check export settings!", "Main")
	
	logger.info("Waiting for FileSystemManager resources...", "Main")
	
	# 等待 FileSystemManager 资源准备完毕
	var max_wait_frames = 300  # 最多等待5秒（300帧 * 60fps）
	var wait_count = 0
	
	while not filesystem_manager.resources_scanned and wait_count < max_wait_frames:
		await get_tree().process_frame
		wait_count += 1
	
	if not filesystem_manager.resources_scanned:
		logger.warning("FileSystemManager resources timeout - proceeding anyway", "Main")
	else:
		logger.info("FileSystemManager resources scanned (%d frames), starting MIDI load..." % wait_count, "Main")
	
	# 输出 charts_index 信息用于诊断
	var charts_count = filesystem_manager.charts_index.size()
	logger.info("Charts index contains %d entries" % charts_count, "Main")
	
	logger.info("Loading all MIDI files asynchronously...", "Main")
	data_manager.load_all_midis_async()
	logger.info("=== MIDI Data Load Initiated ===", "Main")

## 数据加载完成回调
func _on_data_loaded() -> void:
	logger.info("MIDI data loaded successfully", "Main")

	# 数据就绪、首个视图即将入场：隐藏通用加载提示
	var process_tip := get_node_or_null("ProcessTip")
	if process_tip:
		process_tip.visible = false

	# 发送数据就绪事件
	event_bus.data_loaded_complete.emit()

## UI状态改变回调
func _on_state_changed(old_state: int, new_state: int) -> void:
	var old_name = state_manager.get_state_name(old_state)
	var new_name = state_manager.get_state_name(new_state)
	logger.debug("UI State changed: %s -> %s" % [old_name, new_name], "Main")

## 设置变化回调
func _on_settings_changed(setting_name: String, value: Variant) -> void:
	# 通配符 "*" 表示批量设置变更，重新加载所有配置
	if setting_name == "*":
		logger.info("Settings changed, reloading all configurations", "Main")
		_reload_all_settings()
		return
	
	# 处理单个设置项变更
	logger.debug("Setting changed: %s = %s" % [setting_name, value], "Main")
	_apply_single_setting(setting_name, value)

## 重新加载所有设置
func _reload_all_settings() -> void:
	if _is_reloading_settings:
		return
	_is_reloading_settings = true
	# 重新加载配置
	config_loader.reload_config()

	# 应用Gameplay设置（包括SoundFont）
	if midi_playback_manager:
		var soundfont_name = config_loader.get_value("Gameplay", "soundfont_file", "GeneralUser-GS.sf2")
		midi_playback_manager.set_soundfont(soundfont_name)

	# 应用显示设置
	var fullscreen = config_loader.get_bool("Display", "fullscreen", true)
	var vsync = config_loader.get_bool("Display", "vsync_enabled", true)

	if fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)

	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)

	logger.info("All settings reloaded and applied", "Main")
	_is_reloading_settings = false

## 应用单个设置项
func _apply_single_setting(setting_name: String, value: Variant) -> void:
	# SoundFont相关设置
	if setting_name == "soundfont_select":
		if midi_playback_manager:
			var soundfont_name = str(value)
			midi_playback_manager.set_soundfont(soundfont_name)

	# 显示相关设置
	elif setting_name == "fullscreen":
		var is_fullscreen = ConfigManager.parse_bool(value)
		if is_fullscreen:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		else:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)

	elif setting_name == "vsync_enabled":
		var is_vsync = ConfigManager.parse_bool(value)
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if is_vsync else DisplayServer.VSYNC_DISABLED)

## 配置变更回调（新增）
func _on_config_changed(key: String, section: String, value: Variant) -> void:
	if _is_reloading_settings:
		return
	# 通配符 "*" 和 "all" 表示全量配置重新加载
	if key == "*" or section == "all":
		logger.info("Configuration changed (batch), reloading all settings", "Main")
		_reload_all_settings()
		return

	# 处理单个配置项变更
	logger.debug("Configuration changed: [%s] %s = %s" % [section, key, str(value)], "Main")

	# 根据 section 和 key 应用相应的配置
	match section:
		"General":
			if key == "online_mode" and net_manager:
				net_manager.set_online_mode(int(value) == 1)

		"Gameplay":
			# MIDI播放管理器监听这些配置
			if key == "soundfont_file" and midi_playback_manager:
				midi_playback_manager.set_soundfont(str(value))
		
		"Display":
			if key == "fullscreen":
				var is_fullscreen = ConfigManager.parse_bool(value)
				if is_fullscreen:
					DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
				else:
					DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			elif key == "vsync_enabled":
				var is_vsync = ConfigManager.parse_bool(value)
				DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if is_vsync else DisplayServer.VSYNC_DISABLED)

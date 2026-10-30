extends Control

# Root 节点脚本
# 重构后的主节点，负责初始化核心系统

## 核心系统引用
var data_manager: DataManager
var event_bus: EventBus
var state_manager: UIStateManager
var animation_manager: AnimationManager
var sorting_engine: SortingEngine
var config_loader: ConfigManager
var logger: GameLogger
var filesystem_manager: FileSystemManager
var storage_manager: StorageManager
var net_manager: NetManager
var memory_gc: MemoryGC
var _is_reloading_settings: bool = false

# --- 管理器引导（依赖顺序敏感，不要随意调换）---
# 入场前：轻量、无相互依赖（FavoriteManager 仅需 DataMGR 已就绪）
func _bootstrap_pre_managers() -> void:
	var specs := [
		[FavoriteManager, "FavoriteManager"],
		[ScoreCalculator, "ScoreCalculator"],
	]
	_bootstrap_managers(specs)

# 入场后：NetManager 必须先于 AuthManager / CommunityManager；
# CommunityManager 需 Net/Auth/Score + 已打开的 ChartDB；MemoryGC 依赖最广，置于末位
func _bootstrap_post_managers() -> void:
	var specs := [
		[KeySequenceManager, "KeySequenceManager"],
		[NetManager, "NetManager"],
		[AuthManager, "AuthManager"],
		[ScoreManager, "ScoreManager"],
		[CommunityManager, "CommunityManager"],
		[MemoryGC, "MemoryGC"],
	]
	_bootstrap_managers(specs)

# UI组件路径
@export var midi_view_path: String
@export var store_view_path: String
@export var track_view_path: String
@export var play_view_path: String
@export var score_view_path: String
@export var setting_view_path: String

func _ready():
	# Android 平台：仅在日志中记录（不再启动时固定请求存储权限——
	# 默认路径位于应用私有目录，无需任何权限；权限改为玩家把存储路径改到
	# 公共目录时才按需请求，见 SettingList 迁移/浏览流程）
	if PathHelper.is_android():
		GLogger.info("Android platform detected", "Main")
		GLogger.info("Base dir: %s" % PathHelper.get_base_dir(), "Main")

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
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN or what == NOTIFICATION_APPLICATION_RESUMED:
			# 应用焦点回归：重新检测蓝牙输出（用户可能在离开期间切换了输出设备），
			# 蓝牙状态变化时自动切换延迟预设并重建音频桥跟随新默认设备
			if PlaybackDisplay.instance != null:
				PlaybackDisplay.instance.refresh_audio_delay()
			# 安卓：返回前台时仍处 PLAY_VIEW，设备可能已被系统打断(全屏来电/切后台再回)，
			# 设备级重启自愈，避免挂断/返回后无声音；即使已自动暂停也先修好设备
			# 【只触发，不判断】是否就地重启/是否整桥重建由 C# 的 EvaluateAudioDeviceHealth 决定
			if MeltySynth != null and OS.get_name() == "Android" \
					and state_manager.current_state == UIStateManager.UIState.PLAY_VIEW:
				MeltySynth.evaluate_audio_device_health("app_resume", false, true)
			# 内存回收：回前台消费一次内存档位（兜住后台投递时机不定的情况），
			# 并让封面等被清掉的缓存自愈。放在最后：自愈会触发重载，不该抢在音频自修复之前。
			if memory_gc != null:
				memory_gc.set_background(false)
				memory_gc.notify_resumed()
	elif what == NOTIFICATION_APPLICATION_PAUSED:
		# 进后台：置位"后台态"。MemoryGC 只在后台执行回收（前台的内存压力只记日志），
		# 该标志也用于诊断（onTrimMemory 的日志里会打出来）。
		# 该通知在引擎挂起前于主线程触发，与 AndroidBridge.onMainPause 同源。
		if memory_gc != null:
			memory_gc.set_background(true)

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

	# 商店页：详情弹窗打开时先关弹窗，不再直接退出商店
	elif state_manager.current_state == UIStateManager.UIState.STORE_VIEW:
		var store_view = state_manager.get_loaded_view(UIStateManager.UIState.STORE_VIEW)
		if store_view and store_view.has_method("handle_back_request"):
			if store_view.handle_back_request():
				return
		state_manager.go_back()

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
	# 2.5.1 默认值自检：config.ini 是默认值的唯一来源，映射表漏写键会在这里暴露，
	#       而不是让代码里 get_xxx 的兜底值静默生效（失败不中断启动）
	config_loader.validate_defaults()

	# 2.6. 刚完成迁移提交时，把 custom_storage_path 幂等补写进 settings.ini
	# （committed 与配置落盘之间可能崩溃，需保证无日志引导时也能定位新根）
	if bool(storage_resolve.get("needs_config_commit", false)):
		config_loader.set_value("custom_storage_path", str(storage_resolve.get("pending_root", "")))
		config_loader.save_config(ConfigManager.USER_CONFIG_PATH, config_loader.get_current_config())
		if logger:
			logger.info("Storage config committed to settings.ini", "Main")

	# 2.75. ThemeManager 已通过 autoload 自动实例化（首次加载在其 _ready 里完成）
	#
	# 【它为何能读到正确的存储根】主题路径依赖 PathHelper.get_files_dir()，而存储根到
	# 步骤 1.5 才注入 —— autoload 的 _ready 早于这里。为此 PathHelper.get_storage_root()
	# 会惰性从引导指针（storage_pointer.ini）解析一次 override（见其注释），
	# 故主题无需在这里二次加载。这条日志用于对表"启动后实际生效的外观模式"。
	if ThemeMGR and ThemeMGR.is_loaded():
		logger.info("ThemeManager initialized with theme: %s (appearance=%s)" %
			[ThemeMGR.get_theme_name(), ThemeMGR.get_appearance()], "Main")

	# 3. 初始化文件系统管理器（单例，已自动管理）
	filesystem_manager = FileSystemManager.new()
	filesystem_manager.name = "FileSystemManager"
	add_child(filesystem_manager)
	# 存储根刚迁移时强制全量扫描（重建 DB 缓存投影中的绝对路径）
	filesystem_manager.force_full_rescan = bool(storage_resolve.get("needs_full_rescan", false))
	if filesystem_manager.force_full_rescan:
		# 扫完即把日志里的重扫标记落盘：之后即使旧根清理失败（cleanup_pending 残留），
		# 下次启动也不会再白扫一遍全量索引
		filesystem_manager.resources_ready.connect(storage_manager.mark_rescan_done, CONNECT_ONE_SHOT)
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

	# 8.5 / 9.5 收藏夹 & 分数计算器（入场前，轻量；顺序见 _bootstrap_pre_managers）
	_bootstrap_pre_managers()

	# 让出帧：MeltySynth 后端初始化（场景加载 + C# _Ready）较重，
	# 让引擎先渲染一帧再继续 UI 初始化，避免单帧卡顿
	await get_tree().process_frame

	# 先给主框架组件上色（LT_Btn/RB_Btn 强调色、ShortCutMenu/PlayerInfo 面板等）
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()

	# 主界面首帧已渲染：触发左上/右下导航按钮的入场滑入，衔接启动画面
	# （出场离屏位置在 Main.tscn 中由 offset_transform_position 预设；上色已完成，滑入即终态色）
	_play_corner_buttons_entrance()

	# 等入场动画播完再跑后续同步初始化。入场动画是主线程 Tween，必须每帧推进；
	# 若紧接着执行 6 个 Manager 实例化 + _init_ui（含直接改写 LT_Btn/RB_Btn 样式色的
	# apply_theme），手机端这段同步阻塞会把 Tween 卡在入场一半，阻塞结束才“跳”到终点
	# —— 桌面端主线程快、不易复现，手机上明显。
	# 用定时 await 而非 tween.finished：即使动画被外部 kill，协程也不会永久挂起。
	await get_tree().create_timer(AnimationManager.DURATION_SLOW).timeout

	# 10 / 10.5 / 10.6 / 10.7 / 12.8 各管理器（依赖顺序见 _bootstrap_post_managers：
	# NetManager 必须先于 AuthManager / CommunityManager，MemoryGC 依赖最广置于末位）
	_bootstrap_post_managers()

	# 13. 初始化并加载UI（确保各管理器已就绪）
	_init_ui()

	# 让出帧：让引擎先渲染 Main.tscn 内嵌视图，再继续信号连接和数据加载
	# （6 个 _init_ui 视图已改为懒加载，启动阶段不再实例化）
	await get_tree().process_frame

	# 13.5. 预加载 SoundFont 到后端（~30MB，同步阻塞 3-5 秒）
	# 放在 UI 渲染后、信号连接/MIDI 数据加载前，确保阻塞发生在启动阶段而非用户交互阶段
	PlaybackDisplay.instance.load_soundfont_from_config()
	PlaybackDisplay.instance.preload_soundfont()

	# 连接信号
	_connect_signals()
	
	# 加载配置
	_load_configuration()
	
	# 异步加载MIDI数据
	_load_midi_data()
	
	GLogger.info("Core Systems Initialized", "Main")

# 按清单实例化并把管理器挂入场景树（add_child 触发 _ready，使其 static instance 就绪）。
# 仅保留 Main 内部仍直接引用的句柄（net_manager / memory_gc）；其余模块一律走各自 .instance。
func _bootstrap_managers(specs: Array) -> void:
	for spec in specs:
		var mgr_type = spec[0]
		var mgr_name: String = spec[1]
		var mgr = mgr_type.new()
		mgr.name = mgr_name
		add_child(mgr)
		if logger:
			logger.info("%s initialized" % mgr_name, "Main")
		# NetManager 创建后立即按配置启动连接（必须早于 Auth/Community 的 _ready 访问）
		if mgr is NetManager:
			net_manager = mgr
			var online_mode := ConfigManager.instance.get_int("online_mode", 0)
			net_manager.set_online_mode(online_mode == 1)
			if logger:
				logger.info("NetManager online_mode=%d" % online_mode, "Main")
		elif mgr is MemoryGC:
			memory_gc = mgr

func _init_ui() -> void:
	# 6 个视图（MidiView/StoreView/TrackView/SettingView/ScoreView/PlayView）改为懒加载，
	# 启动阶段不再实例化。

	# 主框架主题（含 LT_Btn/RB_Btn 等）已在入场动画前应用（见上方
	# register_theme_applier + apply_theme），此处仅向已注册的视图/组件再广播一次
	# （启动阶段视图尚未注册，这里属预防性调用，避免后续懒加载视图漏掉首轮主题）。
	if ThemeMGR:
		ThemeMGR.refresh_theme_only()

## 应用主题色到主框架组件（由 ThemeManager 广播调用；首轮在入场动画前于 _initialize_core_systems 中自调）
func apply_theme() -> void:
	var primary := ThemeMGR.get_color("primary")
	var surface := ThemeMGR.get_color("surface")

	# LT_Btn / RB_Btn — 强调色渐变导航按钮
	var lt := get_node_or_null("LT_Btn") as Button
	if lt:
		ThemeMGR._modify_button_states_color(lt, "primary")
	var rb := get_node_or_null("RB_Btn") as Button
	if rb:
		ThemeMGR._modify_button_states_color(rb, "primary")
	# ShortCutMenu 面板 — 中性凸起面 + 强调色细描边
	var sc_panel := get_node_or_null("skew/C/ShortCutMenu/Panel") as Panel
	if sc_panel:
		var sc_sb := sc_panel.get_theme_stylebox("panel")
		if sc_sb is StyleBoxFlat:
			sc_sb.bg_color = ThemeMGR.get_color("surface_high")
			sc_sb.border_color = Color(primary.r, primary.g, primary.b, 0.55)
	# PlayerInfo 面板按钮 — 展开后兼作 ProfilePage 的页面底色，用较深的中性面（内容面板在其上更亮，形成层次）
	var info_btn := get_node_or_null("PlayerInfo/InfoPanelBtn") as Button
	if info_btn:
		for state in ["normal", "pressed", "hover"]:
			var sb := info_btn.get_theme_stylebox(state)
			if sb is StyleBoxFlat:
				sb.bg_color = surface
				sb.border_color = Color(primary.r, primary.g, primary.b, 0.7)

## 左上(LT_Btn)/右下(RB_Btn)导航按钮入场动画
func _play_corner_buttons_entrance() -> void:
	var lt := get_node_or_null("LT_Btn") as Control
	var rb := get_node_or_null("RB_Btn") as Control
	if lt == null or rb == null:
		return
	# 离屏起点需与 Main.tscn 中设置的 offset_transform_position 保持一致
	var lt_from := Vector2(-600, -1600)
	var rb_from := Vector2(800, 2000)
	if animation_manager != null:
		animation_manager.animate_fade_slide_in(lt, lt_from, AnimationManager.DURATION_SLOW)
		animation_manager.animate_fade_slide_in(rb, rb_from, AnimationManager.DURATION_SLOW)

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

	# C# 播放器的导航请求（外部媒体命令的上下首处理完后发来）：由 UI 侧切到播放器页。
	# C# 只发信号、不直接切页面——媒体命令处理（后台时经主线程信号派发到达）不被
	# 视图实例化/入场动画这些按帧推进的活阻塞。
	if MeltySynth != null:
		MeltySynth.navigate_to_player_requested.connect(_on_navigate_to_player_requested)
	else:
		logger.warning("MeltySynth is null, cannot connect navigate_to_player_requested signal", "Main")

## C# 播放器请求导航到播放器页（外部媒体命令"上下首"的入口语义：切歌由播放器负责，
## 页面切换只发信号通知 UI）。延迟一帧执行：与命令处理解耦。
func _on_navigate_to_player_requested() -> void:
	call_deferred("_navigate_to_player")

func _navigate_to_player() -> void:
	if state_manager == null or state_manager.current_state == UIStateManager.UIState.MUSIC_PLAYER_VIEW:
		return
	# 从 TrackView 的试听会话过来时摘掉历史栈里的 TRACK_VIEW：否则从播放器页按返回
	# 会回到 TrackView（同一首歌的另一种视图），与"上下首 = 进播放器页"的入口语义不符
	# （原 C# NavigateToPlayer 的同款逻辑，随页面切换一并搬到 UI 侧）
	var hist := state_manager.state_history
	var idx := hist.find(UIStateManager.UIState.TRACK_VIEW)
	if idx >= 0:
		hist.remove_at(idx)
	state_manager.change_state(UIStateManager.UIState.MUSIC_PLAYER_VIEW, false)

## 加载配置文件（验证和应用）
func _load_configuration() -> void:
	# 配置已在 _initialize_core_systems() 中预加载
	# 这里仅进行验证和应用
	var config = config_loader.get_current_config()
	
	if config.is_empty():
		logger.warning("Current configuration is empty", "Main")
		return
	
	logger.info("Configuration loaded successfully, sections: %d" % config.size(), "Main")
	
	# 全局播放配置的真值在 GDScript 侧：加载完成后推一次给 C# 播放器。
	# （ConfigManager 是懒创建单例、不入场景树，C# 无法按节点路径自取，必须显式推送）
	if PlaybackDisplay.instance != null:
		PlaybackDisplay.instance.push_global_playback_config()
		# 校准延迟也要在此刻按真实配置应用一次：PlaybackDisplay 是 autoload，
		# 它的 _ready 早于本次配置加载，那时只能读到默认值
		PlaybackDisplay.instance.refresh_audio_delay()
	
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
	_update_net_probing_for_state(new_state)

## 对帧预算敏感的界面挂起网络定时探测。
## 健康检查/延迟测量本身开销很小，但连接成功会广播 online_status_changed，
## 触发资料与头像重新拉取，图片解码落在渲染线程上，会让正在打歌的这一帧掉帧。
## 业务请求（成绩上传、评论等）不受影响。
func _update_net_probing_for_state(state: int) -> void:
	if net_manager == null:
		return
	var sensitive := state == UIStateManager.UIState.PLAY_VIEW \
		or state == UIStateManager.UIState.MUSIC_PLAYER_VIEW
	net_manager.set_activity_suspended(sensitive, "playback_view")

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
	# 注意：不在此重新从磁盘读取配置。设置退出时 live 配置已由 SettingView.apply_pending_config_updates
	# 更新为正确值；若重新读取磁盘（延迟落盘尚未完成）会读到旧值，反而把刚改的音源当成"变化"触发重载。

	# 应用Gameplay设置（包括SoundFont）
	if PlaybackDisplay.instance:
		var soundfont_name = config_loader.get_value("soundfont_file")
		var cur_basename = PlaybackDisplay.instance.current_soundfont_path.get_file().get_basename()
		var new_basename = soundfont_name.replace(".sf2", "").replace("[内置]", "").strip_edges()
		if new_basename != cur_basename:
			PlaybackDisplay.instance.set_soundfont(soundfont_name)

	# 应用显示设置
	var fullscreen = config_loader.get_bool("fullscreen", true)
	var vsync = config_loader.get_bool("vsync_enabled", true)

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
		if PlaybackDisplay.instance:
			PlaybackDisplay.instance.set_soundfont(str(value))

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
func _on_config_changed(key: String, value: Variant) -> void:
	if _is_reloading_settings:
		return
	# 通配符 "*" 表示全量配置重新加载
	if key == "*":
		logger.info("Configuration changed (batch), reloading all settings", "Main")
		_reload_all_settings()
		return

	# 处理单个配置项变更
	logger.debug("Configuration changed: %s = %s" % [key, str(value)], "Main")

	# 播放器相关配置：查声明式设置表（Game/PlayerSettings.gd）统一下发，不再逐键 elif。
	# 新增播放器设置只需在表里加一条 —— 漏加分支导致"改了不生效要重启"的旧坑由此关闭。
	if _apply_player_setting(key, value):
		return

	# 其余按 key 应用。配置键全局唯一，不需要（也不该）拿 section 再筛一遍：
	# 设置页重组分类不会让这里失效。
	match key:
		"online_mode":
			if net_manager:
				net_manager.set_online_mode(int(value) == 1)

		# 窗口状态没有设置页入口，存在 [System]
		"fullscreen":
			var is_fullscreen = ConfigManager.parse_bool(value)
			if is_fullscreen:
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
			else:
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		"vsync_enabled":
			var is_vsync = ConfigManager.parse_bool(value)
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if is_vsync else DisplayServer.VSYNC_DISABLED)

## 播放器相关配置的统一下发入口。声明在 Game/PlayerSettings.gd，此处只做分发。
## 返回 true 表示该键由本函数处理（调用方不再往下走 key match）。
func _apply_player_setting(key: String, value: Variant) -> bool:
	if not PlayerSettings.affects(key):
		return false
	var display := PlaybackDisplay.instance
	if display == null:
		return true   # 已声明为播放器设置，但播放器未就绪：吞掉即可，稍后 push_global 会带全量
	match str(PlayerSettings.entry(key).get("apply", "")):
		"push_global":
			display.push_global_playback_config()
		"delay_if_active":
			# 只在该键是"当前生效的延迟预设"时下发：另一套预设的改动不应影响当前输出
			if key == display.active_delay_key():
				display.apply_audio_delay_from_config()
				logger.info("Audio playback delay applied live: %s = %s" % [key, str(value)], "Main")
			else:
				logger.debug("Delay preset %s updated but inactive, not applied" % key, "Main")
		"polyphony":
			# 复音数是合成器创建期参数：置新值后必须重建音源才生效。
			# 重建走 C# 的保位置版本，避免"从头重播 / 停在原地静音"。
			display.set_max_polyphony(int(value))
			display.reload_soundfont_preserving_position()
			logger.info("Max polyphony applied live: %s" % str(value), "Main")
		"soundfont":
			display.set_soundfont(str(value))
		"preroll":
			# 下落窗口/预卷时长的真值由消费方（FlowArea）在解析音符配置后推给 C#
			# （PlaybackDisplay.set_note_generation_lead_ms）；此处无需动作。
			pass
		_:
			logger.warning("PlayerSettings entry has unknown apply: %s" % key, "Main")
	return true

## 存储根热切换：迁移提交后不重启，直接把整个应用切到新根
## 步骤：关库 → 换根 → 开新库 → 重载配置/收藏/日志/主题 → 全量重建文件系统索引 → 刷新数据与音源
## 返回 {ok, reason}；返回失败时已回滚到旧根（DB 重开），调用方应回退到"提示重启"流程，
## 保证任何一步重建失败都不会留下"半个应用指向新根"的状态
func reinitialize_after_storage_migration(new_root: String) -> Dictionary:
	var target := PathHelper.normalize_storage_path(new_root)
	if target.is_empty():
		return {"ok": false, "reason": "目标路径为空"}
	var old_root := PathHelper.get_storage_root()
	if target == old_root:
		return {"ok": false, "reason": "目标路径与当前存储路径相同"}

	var cache_path := ProjectSettings.globalize_path(PathHelper.get_base_dir()).path_join(".charts_scan_cache.json")

	# 1. 数据层：关旧库 → 换根 → 开新库（迁移已把 charts.ldb 复制到新根）
	#    新库打不开时立刻回滚旧根并重开旧库，交由调用方走重启流程
	#    关库前先等后台缓存校验结束，避免工作线程持有旧库引用
	if filesystem_manager and filesystem_manager.is_busy():
		await filesystem_manager.await_busy_done()
	if ChartDB != null and ChartDB.IsOpen():
		ChartDB.CloseDb()
	PathHelper.set_storage_root(target)
	var new_db_dir := ProjectSettings.globalize_path(target)
	DirAccess.make_dir_recursive_absolute(new_db_dir)
	if ChartDB == null or not ChartDB.OpenDb(new_db_dir.path_join("charts.ldb"), cache_path):
		PathHelper.set_storage_root(old_root)
		if ChartDB != null:
			ChartDB.OpenDb(ProjectSettings.globalize_path(old_root).path_join("charts.ldb"), cache_path)
		logger.warning("Storage hot switch aborted: cannot open new chart db", "Main")
		return {"ok": false, "reason": "无法打开新存储位置的数据索引"}

	# 2. 配置与收藏：settings.ini / favorites.json 已随迁移落到新根，重新加载并记录新根
	config_loader.clear_cache()
	config_loader.load_and_set_current()
	config_loader.set_value("custom_storage_path", target)
	config_loader.save_config(ConfigManager.USER_CONFIG_PATH, config_loader.get_current_config())
	if FavoriteManager.instance != null:
		FavoriteManager.instance.reload_from_disk()

	# 3. 日志目录随根切换
	if logger:
		logger.refresh_log_path()

	# 4. 主题与背景（theme.ini 位于存储根；背景图缓存里的纹理来自旧根路径）
	# 先清缓存再重载：load_theme 内部会 apply_preset → save_theme + refresh_theme_only
	ThemeMGR.invalidate_background_cache()
	ThemeMGR.load_theme()

	# 5. 文件系统索引：DB 投影里的绝对路径仍指向旧根，必须全量重建
	if filesystem_manager:
		await filesystem_manager.reinitialize_after_storage_change()

	# 6. 视图数据（惰性水合的 MidiData 带旧根绝对路径）与音源（路径变了需重新定位）
	if data_manager:
		data_manager.rebuild_after_storage_change()
	if PlaybackDisplay.instance != null:
		PlaybackDisplay.instance.load_soundfont_from_config()
		PlaybackDisplay.instance.preload_soundfont()

	# 7. 落盘标记：新根的索引已重建，复位重扫标记
	#    （没重建就复位会让下次启动跳过必要的全量扫描）
	if storage_manager and filesystem_manager:
		storage_manager.mark_rescan_done()
	logger.info("Storage hot switch completed: %s -> %s" % [old_root, target], "Main")
	return {"ok": true, "reason": ""}

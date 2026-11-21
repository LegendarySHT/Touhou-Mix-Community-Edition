extends Control

# Root 节点脚本
# 重构后的主节点，负责初始化核心系统

## Android 软键盘遮挡修复（自运行补丁，无对外 API
var vk_guard: VirtualKeyboardGuard
var _is_reloading_settings: bool = false
## 存储根恢复/解析的返回值，供随后 FS 全量重扫与配置提交使用（跨 on_started 闭包共享）
var _storage_resolve: Dictionary = {}

func _enter_tree() -> void:
	# 全局节点自注册：Main 直属常驻节点
	# 放在 _enter_tree 是为了保证早于各子节点（视图 / 常驻组件）的 _ready
	GlobalNodes.main = self
	GlobalNodes.skew_c = %SkewC
	GlobalNodes.selected_album = %SelectedAlbum as AlbumListItem
	GlobalNodes.album_view = %AlbumList as AlbumView
	GlobalNodes.song_view = %SongList as SongView
	GlobalNodes.sorted_view = %SortedMidisList as SortedMidiView
	GlobalNodes.shortcut_menu = %ShortCutMenu as Shortcut_Menu
	GlobalNodes.player_info = %PlayerInfo as PlayerInfoPanel
	GlobalNodes.lt_btn = %LTBtn as LT_Btn
	GlobalNodes.rb_btn = %RBBtn as RB_Btn
	GlobalNodes.character = %CharaDisplay
	GlobalNodes.random_select_btn = %RandomSelectBtn
	GlobalNodes.popup_window_shader = %PopupWindowShader
	GlobalNodes.task_progress = %TaskProgress
	GlobalNodes.process_tip = %ProcessTip
	GlobalNodes.process_progress = %ProcessProgress

	# 角落导航按钮只走方向键，不占页面的 Tab 循环
	(GlobalNodes.lt_btn as Control).set_meta(&"focus_no_tab", true)
	(GlobalNodes.rb_btn as Control).set_meta(&"focus_no_tab", true)

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
		shutdown_and_quit()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN or what == NOTIFICATION_APPLICATION_RESUMED:
			# 应用焦点回归：重新检测蓝牙输出（用户可能在离开期间切换了输出设备），
			# 蓝牙状态变化时自动切换延迟预设并重建音频桥跟随新默认设备
			if ServiceHub.playback != null:
				ServiceHub.playback.refresh_audio_delay()
			# 安卓：返回前台时仍处 PLAY_VIEW，设备可能已被系统打断(全屏来电/切后台再回)，
			# 设备级重启自愈，避免挂断/返回后无声音；即使已自动暂停也先修好设备
			# 【只触发，不判断】是否就地重启/是否整桥重建由 C# 的 evaluate_audio_device_health 决定
			if MeltySynth != null and OS.get_name() == "Android" \
					and UiStatMGR.current_state == UIStateManager.UIState.PLAY_VIEW:
				MeltySynth.evaluate_audio_device_health("app_resume", false, true)
			# 内存回收：回前台消费一次内存档位（兜住后台投递时机不定的情况），
			# 并让封面等被清掉的缓存自愈。放在最后：自愈会触发重载，不该抢在音频自修复之前。
			if ServiceHub.memory != null:
				ServiceHub.memory.set_background(false)
				ServiceHub.memory.notify_resumed()
	elif what == NOTIFICATION_APPLICATION_PAUSED:
		# 进后台：置位"后台态"。MemoryGC 只在后台执行回收（前台的内存压力只记日志），
		# 该标志也用于诊断（onTrimMemory 的日志里会打出来）。
		# 该通知在引擎挂起前于主线程触发，与 AndroidBridge.onMainPause 同源。
		if ServiceHub.memory != null:
			ServiceHub.memory.set_background(true)

## 应用退出清理：关闭 CoverLoader 线程池并刷写 LiteDB，再退出
func shutdown_and_quit() -> void:
	if CoverLoader:
		CoverLoader.shutdown()
	if ChartDB:
		ChartDB.CloseDb()
	get_tree().quit()

## 桌面端 Esc 键（仅在无其他控件消费事件时触发）
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed:
		_handle_back_request()

## 统一的返回/退出处理
func _handle_back_request() -> void:
	# 主界面 → 显示退出确认
	if UiStatMGR.current_state == UIStateManager.UIState.ALBUM_VIEW:
		if await PopupWindow.instance.show_message("确定要退出游戏吗？", true):
			get_tree().quit()

	# 打歌界面 → 交由 PlayView 处理（准备阶段切暂停菜单/暂停后继续等逻辑都在其中）
	elif UiStatMGR.current_state == UIStateManager.UIState.PLAY_VIEW:
		get_node_or_null("PlayView").show_or_hide_menu()

	# 商店 / 个人资料页：详情弹窗打开时先关弹窗，不再直接退出页面
	elif UiStatMGR.current_state in [UIStateManager.UIState.STORE_VIEW,
			UIStateManager.UIState.PROFILE_VIEW]:
		var view := UiStatMGR.get_loaded_view(UiStatMGR.current_state)
		if view and view.has_method("handle_back_request") and view.handle_back_request():
			return
		UiStatMGR.go_back()

	# 设置页内部子页面（ResourceView / About）→ 先切回设置主页，而非直接退出设置
	elif UiStatMGR.current_state == UIStateManager.UIState.SETTINGS_VIEW:
		UiStatMGR.get_loaded_view(UIStateManager.UIState.SETTINGS_VIEW).handle_back_request()
	# 其他层级 → 返回上一级
	else:
		UiStatMGR.go_back()

## 初始化核心系统

func _initialize_core_systems() -> void:
	GLogger.info("Initializing Core Systems", "Main")

	# 启动阶段显示通用加载提示（ProcessTip 默认可见，「加载中，请稍后」；数据就绪后由 _on_data_loaded 隐藏）
	%ProcessTip.visible = true

	# 1. 初始化日志系统（单例，已自动管理）
	if GLogger:
		GLogger.info("Logger initialized", "Main")

	# 1.1 软键盘遮挡修复：只要"挂着听焦点"就行，没有对外 API，不值得占 autoload 名额。
	#     必须早于任何输入交互创建（这里紧跟日志，后续都是数据初始化）。
	vk_guard = VirtualKeyboardGuard.new()
	vk_guard.name = "VirtualKeyboardGuard"
	add_child(vk_guard)

	# 1.2. MIDI 键盘输入：引擎自带桌面端驱动（Windows winmm / Linux ALSA / macOS CoreMIDI），
	#     与实体键盘共用同一条输入流。键位录入与打歌都要用，开机统一打开。
	#     Android 没有 MIDI 驱动，调用会直接报错，因此跳过。
	if not OS.has_feature("android"):
		OS.open_midi_inputs()
		GLogger.info("MIDI inputs opened: %s" % str(OS.get_connected_midi_inputs()), "Main")

	# ---- 收编保留的 autoload 锚点：它们在引擎启动时已在场景树，只登记为已就绪服务，
	#      可作为其它服务的依赖节点，ServiceHub 不重复实例化。 ----
	for anchor_id in ["EvtBus", "GLogger", "ChartDB", "MeltySynth", "PlaybackDisplay",
			"UiStatMGR", "AniMGR", "DataMGR", "ThemeMGR", "FocusMGR", "CoverLoader"]:
		var node := get_node_or_null("/root/" + anchor_id)
		if node != null:
			ServiceHub.adopt(anchor_id, node)

	# ---- 注册由 Main 引导的管理器，依赖图推导启动顺序 ----
	var hub := ServiceHub

	var storage_def := ServiceDef.gd("StorageManager", "res://Core/StorageManager.gd")
	storage_def.phase = "core"
	storage_def.on_started = func(_inst: Node) -> void:
		_storage_resolve = ServiceHub.storage.recover_and_resolve()
		GLogger.info("Storage root resolved: %s (note=%s, full_rescan=%s, restored=%s)" % [
			PathHelper.get_storage_root(),
			str(_storage_resolve.get("note", "")),
			str(_storage_resolve.get("needs_full_rescan", false)),
			str(_storage_resolve.get("restored", false))], "Main")
		if PathHelper.get_storage_root() != PathHelper.get_boot_dir():
			GLogger.refresh_log_path()
	hub.register(storage_def)

	var config_def := ServiceDef.gd("ConfigManager", "res://Utilities/ConfigManager.gd")
	config_def.phase = "core"
	config_def.factory = func() -> Node: return ServiceHub.config
	config_def.on_started = func(_inst: Node) -> void:
		var cfg := ServiceHub.config
		GLogger.info("ConfigManager initialized", "Main")
		cfg.clear_cache()
		cfg.load_and_set_current()
		cfg.validate_defaults()
		GLogger.info("Configuration pre-loaded before Manager initialization", "Main")
		if bool(_storage_resolve.get("needs_config_commit", false)):
			cfg.set_value("custom_storage_path",
				str(_storage_resolve.get("pending_root", "")))
			cfg.save_config(ConfigManager.USER_CONFIG_PATH,
				cfg.get_current_config())
			GLogger.info("Storage config committed to settings.ini", "Main")
		if ThemeMGR and ThemeMGR.is_loaded():
			GLogger.info("ThemeManager initialized with theme: %s (appearance=%s)" %
				[ThemeMGR.get_theme_name(), ThemeMGR.get_appearance()], "Main")
	hub.register(config_def)

	# ---- 轻量内容管理器（原薄 autoload）：改为 core 阶段实例化，经静态 instance 访问 ----
	# 依赖声明已下沉到各服务脚本的 SERVICE_DEPS 常量，注册时由 ServiceHub 自动读取。
	var content_defs: Array = [
		["SkinMGR", "res://Core/SkinManager.gd"],
		["ParticleMGR", "res://Core/ParticleManager.gd"],
		["CharaMGR", "res://Core/CharaManager.gd"],
		["SortEngine", "res://Core/SortingEngine.gd"],
		["TextScrollMGR", "res://Game/TextScrollMGR.gd"],
	]
	for spec in content_defs:
		var def := ServiceDef.gd(spec[0], spec[1])
		def.phase = "core"
		hub.register(def)

	var bt_def := ServiceDef.gd("AudioBtDetector", "res://Utilities/AudioBtDetector.gd")
	bt_def.phase = "core"
	hub.register(bt_def)

	var fs_def := ServiceDef.gd("FileSystemManager", "res://Core/FileSystemManager.gd")
	fs_def.phase = "core"
	# 数据就绪门：扫描合并完成才算真正就绪，供 service_ready("FileSystemManager") 等待
	fs_def.ready_by = func(inst: Node) -> bool: return (inst as FileSystemManager).resources_scanned
	fs_def.on_started = func(_inst: Node) -> void:
		# 目录/复制/导入/扫描管线在 ImportManager 也启动后再统一触发（见 import_def.on_started），
		# 保证 process_startup_files 在扫描前已可用。这里只做就绪配置。
		ServiceHub.fs.force_full_rescan = bool(_storage_resolve.get("needs_full_rescan", false))
		if ServiceHub.fs.force_full_rescan:
			ServiceHub.fs.resources_ready.connect(
				ServiceHub.storage.mark_rescan_done, CONNECT_ONE_SHOT)
		GLogger.info("FileSystemManager initialized", "Main")
	hub.register(fs_def)

	var import_def := ServiceDef.gd("ImportManager", "res://Core/ImportManager.gd")
	import_def.phase = "core"
	import_def.on_started = func(_inst: Node) -> void:
		GLogger.info("ImportManager initialized", "Main")
		# 依赖导入管理器就绪后，触发文件系统「建目录 → 复制默认资源 → 导入外部文件 → 扫描」管线
		if not ServiceHub.fs.is_initialized:
			ServiceHub.fs.initialize_directory_structure()
	hub.register(import_def)

	var fav_def := ServiceDef.gd("FavoriteManager", "res://Core/FavoriteManager.gd")
	fav_def.phase = "pre"
	hub.register(fav_def)

	var sc_def := ServiceDef.gd("ScoreCalculator", "res://Game/ScoreCalculator.gd")
	sc_def.phase = "pre"
	hub.register(sc_def)

	var ksq_def := ServiceDef.gd("KeySequenceManager", "res://Game/KeySequenceManager.gd")
	ksq_def.phase = "post"
	hub.register(ksq_def)

	var net_def := ServiceDef.gd("NetManager", "res://Core/NetManager.gd")
	net_def.phase = "post"
	net_def.on_started = func(_inst: Node) -> void:
		var online_mode := ServiceHub.config.get_int("online_mode", 0)
		ServiceHub.net.set_online_mode(online_mode == 1)
		GLogger.info("NetManager online_mode=%d" % online_mode, "Main")
	hub.register(net_def)

	var post_list: Array = [
		["AuthManager", "res://Core/AuthManager.gd"],
		["ScoreManager", "res://Core/ScoreManager.gd"],
		["CommunityManager", "res://Core/CommunityManager.gd"],
		["DraftManager", "res://Core/DraftManager.gd"],
		["MemoryGC", "res://Core/MemoryGC.gd"],
	]
	for spec in post_list:
		var def := ServiceDef.gd(spec[0], spec[1])
		def.phase = "post"
		hub.register(def)

	# ---- 按需（lazy）服务：不进启动队列，首次 .service(id) 时创建挂载 ----
	var vm_def := ServiceDef.gd("VersionManager", "res://Core/VersionManager.gd")
	vm_def.lazy = true
	vm_def.parent = "lazy"
	hub.register(vm_def)

	var rm_def := ServiceDef.gd("ResourceManager", "res://Core/ResourceManager.gd")
	rm_def.lazy = true
	rm_def.parent = "lazy"
	hub.register(rm_def)

	# ---- 启动 core 层（存储/配置/DB/文件系统/导入），再进入入场节奏 ----
	hub.start_phase("core")
	# 存储根此刻已由 storage 服务解析/迁移确定；必须在文件系统扫描前按最终根打开 ChartDB。
	# 扫描由 import_def.on_started 触发，其首个扫描点在 await 之后，故此处同步开库早于扫描。
	_chartdb_open()

	# 让出帧：让引擎先渲染一帧再继续，避免单帧卡顿
	await get_tree().process_frame

	# 先给主框架组件上色，再触发入场动画（演示层，不在依赖图中）
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()
	_play_corner_buttons_entrance()

	# 入场动画主线程 Tween 必须每帧推进：等它播完再启动 pre/post 段，
	# 否则同步实例化会卡住动画（手机端明显）。定时 await 防动画被 kill 永久挂起。
	await get_tree().create_timer(AnimationManager.DURATION_SLOW).timeout

	# pre 段：收藏夹、分数计算器（入场前轻量）
	hub.start_phase("pre")

	# post 段：业务管理器（Net/Auth/Score/Community/MemoryGC）
	# start_phase 为同步调用（同一顺序实例化完即返回），返回后所有核心服务已就绪
	hub.start_phase("post")
	if not hub.started:
		push_error("Main: 核心服务未全部就绪，后续流程可能异常")

	# 13. 初始化并加载UI（确保各管理器已就绪）
	_init_ui()

	# 让出帧：让引擎先渲染 Main.tscn 内嵌视图，再继续信号连接和数据加载
	# （6 个 _init_ui 视图已改为懒加载，启动阶段不再实例化）
	await get_tree().process_frame

	# 13.5. 下发音源到后端：后台异步解析 ~30MB，主线程不阻塞，由 MeltySynth._Process 完成绑定
	ServiceHub.playback.load_soundfont_from_config()
	ServiceHub.playback.preload_soundfont()

	# 连接信号
	_connect_signals()

	# 加载配置
	_load_configuration()

	# 异步加载MIDI数据
	_load_midi_data()

	GLogger.info("Core Systems Initialized", "Main")


## 打开 ChartDB（autoload 锚点，扫描前必须先开库；DB 随可移动存储根迁移）。
func _chartdb_open() -> void:
	var files_dir := ProjectSettings.globalize_path(PathHelper.get_storage_root())
	DirAccess.make_dir_recursive_absolute(files_dir)
	if ChartDB:
		var db_path := files_dir.path_join("charts.ldb")
		var old_cache_path := ProjectSettings.globalize_path(PathHelper.get_base_dir()).path_join(".charts_scan_cache.json")
		ChartDB.OpenDb(db_path, old_cache_path)
		GLogger.info("ChartDB opened (db: %s)" % db_path, "Main")


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
	ThemeMGR._modify_button_states_color(get_node_or_null("LTBtn"), "primary")
	ThemeMGR._modify_button_states_color(get_node_or_null("RBBtn"), "primary")
	# ShortCutMenu 面板 — 中性凸起面 + 强调色细描边
	# 面板底在 BgPanel 上（根是 Control，收起时整体淡出，按钮不受影响）
	var sc_sb: StyleBoxFlat = (%ShortCutMenu.get_node("BgPanel") as Panel).get_theme_stylebox("panel")
	sc_sb.bg_color = ThemeMGR.get_color("surface_high")
	sc_sb.border_color = Color(primary.r, primary.g, primary.b, 0.55)

	# PlayerInfo 面板按钮 — 展开后兼作 ProfileView 的页面底色，用较深的中性面（内容面板在其上更亮，形成层次）
	for state in ["normal", "pressed", "hover"]:
		var sb: StyleBoxFlat = %PlayerInfo.info_panel_btn.get_theme_stylebox(state)
		sb.bg_color = surface
		sb.border_color = Color(primary.r, primary.g, primary.b, 0.7)

## 左上(LT_Btn)/右下(RB_Btn)导航按钮入场动画
func _play_corner_buttons_entrance() -> void:
	var lt := get_node_or_null("LTBtn") as Control
	var rb := get_node_or_null("RBBtn") as Control
	if lt == null or rb == null:
		return
	# 离屏起点需与 Main.tscn 中设置的 offset_transform_position 保持一致
	var lt_from := Vector2(-600, -1600)
	var rb_from := Vector2(800, 2000)
	if AniMGR != null:
		AniMGR.animate_fade_slide_in(lt, lt_from, AnimationManager.DURATION_SLOW)
		AniMGR.animate_fade_slide_in(rb, rb_from, AnimationManager.DURATION_SLOW)

## 连接核心系统信号
func _connect_signals() -> void:
	# 数据加载完成信号
	DataMGR.data_loaded.connect(_on_data_loaded)
	
	# 状态改变信号
	UiStatMGR.state_changed.connect(_on_state_changed)

	# 设置变化信号
	EvtBus.settings_changed.connect(_on_settings_changed)
	
	# 配置变更信号（新增）
	EvtBus.config_changed.connect(_on_config_changed)

	# C# 播放器的导航请求（外部媒体命令的上下首处理完后发来）：由 UI 侧切到播放器页。
	# C# 只发信号、不直接切页面——媒体命令处理（后台时经主线程信号派发到达）不被
	# 视图实例化/入场动画这些按帧推进的活阻塞。
	if MeltySynth != null:
		MeltySynth.navigate_to_player_requested.connect(_on_navigate_to_player_requested)
	else:
		GLogger.warning("MeltySynth is null, cannot connect navigate_to_player_requested signal", "Main")

## C# 播放器请求导航到播放器页（外部媒体命令"上下首"的入口语义：切歌由播放器负责，
## 页面切换只发信号通知 UI）。延迟一帧执行：与命令处理解耦。
func _on_navigate_to_player_requested() -> void:
	call_deferred("_navigate_to_player")

func _navigate_to_player() -> void:
	if UiStatMGR == null or UiStatMGR.current_state == UIStateManager.UIState.MUSIC_PLAYER_VIEW:
		return
	# 从 TrackView 的试听会话过来时摘掉历史栈里的 TRACK_VIEW：否则从播放器页按返回
	# 会回到 TrackView（同一首歌的另一种视图），与"上下首 = 进播放器页"的入口语义不符
	# （原 C# NavigateToPlayer 的同款逻辑，随页面切换一并搬到 UI 侧）
	var hist := UiStatMGR.state_history
	var idx := hist.find(UIStateManager.UIState.TRACK_VIEW)
	if idx >= 0:
		hist.remove_at(idx)
	UiStatMGR.change_state(UIStateManager.UIState.MUSIC_PLAYER_VIEW, false)

## 加载配置文件（验证和应用）
func _load_configuration() -> void:
	# 配置已在 _initialize_core_systems() 中预加载
	# 这里仅进行验证和应用
	var config = ServiceHub.config.get_current_config()
	
	if config.is_empty():
		GLogger.warning("Current configuration is empty", "Main")
		return
	
	GLogger.info("Configuration loaded successfully, sections: %d" % config.size(), "Main")
	
	# 全局播放配置的真值在 GDScript 侧：加载完成后推一次给 C# 播放器。
	# （ConfigManager 是懒创建单例、不入场景树，C# 无法按节点路径自取，必须显式推送）
	if ServiceHub.playback != null:
		ServiceHub.playback.push_global_playback_config()
		ServiceHub.playback.apply_ui_midi_volume(
			ServiceHub.playback.get_effective_midi_volume(-1.0))
		# 校准延迟也要在此刻按真实配置应用一次：PlaybackDisplay 是 autoload，
		# 它的 _ready 早于本次配置加载，那时只能读到默认值
		ServiceHub.playback.refresh_audio_delay()
	
	# 检查版本并迁移（如必要）
	ServiceHub.config.check_and_migrate()

## 加载MIDI数据
func _load_midi_data() -> void:
	GLogger.info("=== Starting MIDI Data Load ===", "Main")
	GLogger.info("Platform: %s" % OS.get_name(), "Main")
	GLogger.info("User data path: %s" % OS.get_user_data_dir(), "Main")
	
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
		GLogger.info("Resource check [%s]: %s" % [res, "✓" if exists else "✗"], "Main")
		if not exists:
			GLogger.error("Critical resource missing - Check export settings!", "Main")
	
	GLogger.info("Waiting for FileSystemManager resources...", "Main")

	# 经就绪门等待扫描完成（最多 5 秒）；逾期按既有语义继续，不阻断启动
	var wait_started := Time.get_ticks_msec()
	if not await ServiceHub.service_ready("FileSystemManager", 5.0):
		GLogger.warning("FileSystemManager resources timeout - proceeding anyway", "Main")
	else:
		GLogger.info("FileSystemManager resources scanned (%d ms), starting MIDI load..." %
			(Time.get_ticks_msec() - wait_started), "Main")
	
	# 输出 charts_index 信息用于诊断
	var charts_count = ServiceHub.fs.charts_index.size()
	GLogger.info("Charts index contains %d entries" % charts_count, "Main")
	
	GLogger.info("Loading all MIDI files asynchronously...", "Main")
	DataMGR.load_all_midis_async()
	GLogger.info("=== MIDI Data Load Initiated ===", "Main")

## 数据加载完成回调
func _on_data_loaded() -> void:
	GLogger.info("MIDI data loaded successfully", "Main")

	# 数据就绪、首个视图即将入场：隐藏通用加载提示
	var process_tip := get_node_or_null("ProcessTip")
	if process_tip:
		process_tip.visible = false

	# 发送数据就绪事件
	EvtBus.data_loaded_complete.emit()

	# 启动自动检查更新（不阻塞启动，失败静默）
	_check_updates_on_startup()

## 启动时自动检查更新。设置项 auto_check_update 关闭、或线上模式关闭时不联网。
## 刻意等两帧再发请求：让首屏绘制与音频初始化先完成，避免与启动阶段抢帧。
func _check_updates_on_startup() -> void:
	if ServiceHub.config.get_int("auto_check_update", 1) != 1:
		return
	if ServiceHub.config.get_int("online_mode", 1) != 1:
		return
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_inside_tree():
		return
	ServiceHub.version.update_check_finished.connect(_on_startup_update_finished, CONNECT_ONE_SHOT)
	ServiceHub.version.check_for_updates()

func _on_startup_update_finished(result: Dictionary) -> void:
	GLogger.info("启动自动检查更新完成：has_update=%s reason=%s" % [
		str(result.get("has_update", false)), str(result.get("reason", ""))], "Main")

## UI状态改变回调
func _on_state_changed(old_state: int, new_state: int) -> void:
	var old_name = UiStatMGR.get_state_name(old_state)
	var new_name = UiStatMGR.get_state_name(new_state)
	GLogger.debug("UI State changed: %s -> %s" % [old_name, new_name], "Main")
	_update_net_probing_for_state(new_state)

## 对帧预算敏感的界面挂起网络定时探测。
## 健康检查/延迟测量本身开销很小，但连接成功会广播 online_status_changed，
## 触发资料与头像重新拉取，图片解码落在渲染线程上，会让正在打歌的这一帧掉帧。
## 业务请求（成绩上传、评论等）不受影响。
func _update_net_probing_for_state(state: int) -> void:
	if ServiceHub.net == null:
		return
	var sensitive := state == UIStateManager.UIState.PLAY_VIEW \
		or state == UIStateManager.UIState.MUSIC_PLAYER_VIEW
	ServiceHub.net.set_activity_suspended(sensitive, "playback_view")

## 设置变化回调
func _on_settings_changed(setting_name: String, value: Variant) -> void:
	# 通配符 "*" 表示批量设置变更，重新加载所有配置
	if setting_name == "*":
		GLogger.info("Settings changed, reloading all configurations", "Main")
		_reload_all_settings()
		return
	
	# 处理单个设置项变更
	GLogger.debug("Setting changed: %s = %s" % [setting_name, value], "Main")
	_apply_single_setting(setting_name, value)

## 重新加载所有设置
func _reload_all_settings() -> void:
	if _is_reloading_settings:
		return
	_is_reloading_settings = true
	# 注意：不在此重新从磁盘读取配置。设置退出时 live 配置已由 SettingView.apply_pending_config_updates
	# 更新为正确值；若重新读取磁盘（延迟落盘尚未完成）会读到旧值，反而把刚改的音源当成"变化"触发重载。

	# 应用Gameplay设置（包括SoundFont）
	if ServiceHub.playback:
		var soundfont_name = ServiceHub.config.get_value("soundfont_file")
		var cur_basename = ServiceHub.playback.current_soundfont_path.get_file().get_basename()
		var new_basename = soundfont_name.replace(".sf2", "").replace("[内置]", "").strip_edges()
		if new_basename != cur_basename:
			ServiceHub.playback.set_soundfont(soundfont_name)

	# 应用显示设置
	var fullscreen = ServiceHub.config.get_bool("fullscreen", true)
	var vsync = ServiceHub.config.get_bool("vsync_enabled", true)

	if fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)

	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)

	GLogger.info("All settings reloaded and applied", "Main")
	_is_reloading_settings = false

## 应用单个设置项
func _apply_single_setting(setting_name: String, value: Variant) -> void:
	# SoundFont相关设置
	if setting_name == "soundfont_select":
		if ServiceHub.playback:
			ServiceHub.playback.set_soundfont(str(value))

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
		GLogger.info("Configuration changed (batch), reloading all settings", "Main")
		_reload_all_settings()
		return

	# 处理单个配置项变更
	GLogger.debug("Configuration changed: %s = %s" % [key, str(value)], "Main")

	# 播放器相关配置：查声明式设置表（Game/PlayerSettings.gd）统一下发，不再逐键 elif。
	# 新增播放器设置只需在表里加一条 —— 漏加分支导致"改了不生效要重启"的旧坑由此关闭。
	if _apply_player_setting(key, value):
		return

	# 其余按 key 应用。配置键全局唯一，不需要（也不该）拿 section 再筛一遍：
	# 设置页重组分类不会让这里失效。
	match key:
		"online_mode":
			if ServiceHub.net:
				ServiceHub.net.set_online_mode(int(value) == 1)

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
	var display := ServiceHub.playback
	if display == null:
		return true   # 已声明为播放器设置，但播放器未就绪：吞掉即可，稍后 push_global 会带全量
	match str(PlayerSettings.entry(key).get("apply", "")):
		"push_global":
			display.push_global_playback_config()
		"delay_if_active":
			# 只在该键是"当前生效的延迟预设"时下发：另一套预设的改动不应影响当前输出
			if key == display.active_delay_key():
				display.apply_audio_delay_from_config()
				GLogger.info("Audio playback delay applied live: %s = %s" % [key, str(value)], "Main")
			else:
				GLogger.debug("Delay preset %s updated but inactive, not applied" % key, "Main")
		"polyphony":
			# 复音数是合成器创建期参数：置新值后必须重建音源才生效。
			# 重建走 C# 的保位置版本，避免"从头重播 / 停在原地静音"。
			display.set_max_polyphony(int(value))
			display.reload_soundfont_preserving_position()
			GLogger.info("Max polyphony applied live: %s" % str(value), "Main")
		"soundfont":
			display.set_soundfont(str(value))
		"preroll":
			# 下落窗口/预卷时长的真值由消费方（FlowArea）在解析音符配置后推给 C#
			# （PlaybackDisplay.set_note_generation_lead_ms）；此处无需动作。
			pass
		_:
			GLogger.warning("PlayerSettings entry has unknown apply: %s" % key, "Main")
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
	if ServiceHub.fs and ServiceHub.fs.is_busy():
		await ServiceHub.fs.await_busy_done()
	if ChartDB != null and ChartDB.IsOpen():
		ChartDB.CloseDb()
	PathHelper.set_storage_root(target)
	var new_db_dir := ProjectSettings.globalize_path(target)
	DirAccess.make_dir_recursive_absolute(new_db_dir)
	if ChartDB == null or not ChartDB.OpenDb(new_db_dir.path_join("charts.ldb"), cache_path):
		PathHelper.set_storage_root(old_root)
		if ChartDB != null:
			ChartDB.OpenDb(ProjectSettings.globalize_path(old_root).path_join("charts.ldb"), cache_path)
		GLogger.warning("Storage hot switch aborted: cannot open new chart db", "Main")
		return {"ok": false, "reason": "无法打开新存储位置的数据索引"}

	# 2. 配置与收藏：settings.ini / favorites.json 已随迁移落到新根，重新加载并记录新根
	ServiceHub.config.clear_cache()
	ServiceHub.config.load_and_set_current()
	ServiceHub.config.set_value("custom_storage_path", target)
	ServiceHub.config.save_config(ConfigManager.USER_CONFIG_PATH, ServiceHub.config.get_current_config())
	if ServiceHub.favorite != null:
		ServiceHub.favorite.reload_from_disk()

	# 3. 日志目录随根切换
	GLogger.refresh_log_path()

	# 4. 主题与背景（theme.ini 位于存储根；背景图缓存里的纹理来自旧根路径）
	# 先清缓存再重载：load_theme 内部会 apply_preset → save_theme + refresh_theme_only
	ThemeMGR.invalidate_background_cache()
	ThemeMGR.load_theme()

	# 5. 文件系统索引：DB 投影里的绝对路径仍指向旧根，必须全量重建
	if ServiceHub.fs:
		await ServiceHub.fs.reinitialize_after_storage_change()

	# 6. 视图数据（惰性水合的 MidiData 带旧根绝对路径）与音源（路径变了需重新定位）
	if DataMGR:
		DataMGR.rebuild_after_storage_change()
	if ServiceHub.playback != null:
		ServiceHub.playback.load_soundfont_from_config()
		ServiceHub.playback.preload_soundfont()

	# 7. 落盘标记：新根的索引已重建，复位重扫标记
	#    （没重建就复位会让下次启动跳过必要的全量扫描）
	if ServiceHub.storage and ServiceHub.fs:
		ServiceHub.storage.mark_rescan_done()
	GLogger.info("Storage hot switch completed: %s -> %s" % [old_root, target], "Main")
	return {"ok": true, "reason": ""}

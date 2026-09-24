extends BaseScrollList

class_name TrackView

@onready var master_note_displayer: NoteDisplayer = $MC/VBox/TotalView/MC/VBoxC/flowArea
@onready var current_time: Label = $MC/VBox/TotalView/MC/VBoxC/playArea/currentTime
@onready var progress_bar: HSlider = $MC/VBox/TotalView/MC/VBoxC/playArea/progressBar
@onready var total_time: Label = $MC/VBox/TotalView/MC/VBoxC/playArea/totalTime

# 导入人声按钮
@onready var vocal_import_btn: TextureButton = $MC/VBox/VolumeView/HBoxC/VBoxC2/VocalImportBtn
# 切换人声启用状态按钮
@onready var vocal_enable_btn: Button = $MC/VBox/VolumeView/HBoxC/VBoxC2/VocalEnableBtn

@onready var latency_edit: LineEdit = $MC/VBox/VolumeView/HBoxC/VBoxC2/HBoxC/Latency
@onready var midi_vol_btn: TextureButton = $MC/VBox/VolumeView/HBoxC/GridC/midiVolIcon
@onready var midi_vol_slider: HSlider = $MC/VBox/VolumeView/HBoxC/GridC/midiVolSlider
@onready var vocal_vol_btn: TextureButton = $MC/VBox/VolumeView/HBoxC/GridC/vocalVolIcon
@onready var vocal_vol_slider: HSlider = $MC/VBox/VolumeView/HBoxC/GridC/vocalVolSlider

@onready var midi_vol_label: Label = $MC/VBox/VolumeView/HBoxC/GridC/midiVolLabel
@onready var vocal_vol_label: Label = $MC/VBox/VolumeView/HBoxC/GridC/vocalVolLabel

# MIDI播放相关

@onready var midi_playback_manager: MidiPlaybackManager = MidiPlaybackManager.instance
@onready var ui_stat_mgr: UIStateManager = UiStatMGR

var current_midi_data: MidiData = null
var is_progress_dragging: bool = false

# 静音按钮记住的上一次音量条值（<0 表示本次会话尚未静音过，恢复时用默认值）
var _prev_midi_vol: float = -1.0
var _prev_vocal_vol: float = -1.0

var current_tick: int = 0
var last_position_ms: float = 0.0  # 用于检测循环播放重置

# 给midi轨道访问的默认值，临时占位用。
var instrument_options: Array = [] # 全局乐器列表（会被 _extract_instruments_from_midi() 填充）
var regular_instruments: Array = []  # 常规乐器
var drum_instruments: Array = []     # GM/GS/GM2 鼓组 bank（B120+）

# 全局共享的乐器子菜单（16 大类各一套，跨所有音轨复用），挂在本视图下避免随轨道场景释放。
# 打开某轨主菜单时经 midiTrack._ensure_submenus_attached reparent 到该轨弹窗下（见 get_shared_submenu）。
var _shared_instrument_submenus: Dictionary = {}
# 人声音频路径存在时相关组件会显示
# vocal_file_path 现由 _vocal_controller 管理

# 子系统控制器
var _vocal_controller: VocalTrackController = null
var _config_persistence: MidiConfigPersistence = null


# 按 (track, channel) 分组的音轨容器（由 _build_buckets 一次性构建）
# master_note_displayer 直接引用；子 displayer 在 _init_track_note_displayer 中独立构建
var _all_buckets: Array[NoteDisplayer.TrackNoteBucket] = []

# Additive Solo 状态
var solo_pairs: Dictionary = {}  # {"track:channel": true}
var solo_mute_snapshot: Dictionary = {}  # {"track:channel": bool}

func _ready() -> void:
	work_state = UIStateManager.UIState.TRACK_VIEW

	# 检查管理器引用
	if midi_playback_manager == null:
		push_error("MidiPlaybackManager not initialized in Main! MIDI features will not work.")
		return

	# 反推MIDI音量slider值（映射的逆：UI值 = 后端线性增益 / MIDI_VOLUME_GAIN）
	midi_vol_slider.value = clampf(
		db_to_linear(midi_playback_manager.midi_player_config["volume_db"]) / MidiPlaybackManager.MIDI_VOLUME_GAIN,
		0.0, 1.0)
	_set_display_midi_volume(midi_vol_slider.value)

	# 连接信号（检查防止重复连接）
	if not EvtBus.is_connected("enter_track_view_with", Callable(self, "_load_midi")):
		EvtBus.enter_track_view_with.connect(_load_midi)

	if not ui_stat_mgr.is_connected("state_changed", Callable(self, "_on_ui_state_changed")):
		ui_stat_mgr.state_changed.connect(_on_ui_state_changed)

	# 监听SoundFont变更信号（用于实时更新乐器列表）
	if midi_playback_manager.midi_player and not midi_playback_manager.midi_player.is_connected("soundfont_changed", Callable(self, "_on_soundfont_changed")):
		midi_playback_manager.midi_player.soundfont_changed.connect(_on_soundfont_changed)

	if not midi_vol_btn.is_connected("toggled", Callable(self, "_on_volume_btn_toggled")):
		midi_vol_btn.toggled.connect(_on_volume_btn_toggled.bind(midi_vol_btn))

	if not vocal_vol_btn.is_connected("toggled", Callable(self, "_on_volume_btn_toggled")):
		vocal_vol_btn.toggled.connect(_on_volume_btn_toggled.bind(vocal_vol_btn))

	# midi_vol_slider/vocal_vol_slider.value_changed、progress_bar 三个信号、
	# vocal_import_btn.pressed、vocal_enable_btn.toggled、latency_edit.text_changed
	# 已在 TrackView.tscn 中连接

	# 初始化子系统控制器（file_dialog 由 controller 惰性创建，不再传入）
	if _vocal_controller == null:
		_vocal_controller = VocalTrackController.new()
		_vocal_controller.name = "VocalTrackController"
		add_child(_vocal_controller)
		_vocal_controller.setup(self, null, vocal_import_btn, vocal_enable_btn,
			vocal_vol_btn, vocal_vol_slider, vocal_vol_label)

	if _config_persistence == null:
		_config_persistence = MidiConfigPersistence.new()
		_config_persistence.name = "MidiConfigPersistence"
		add_child(_config_persistence)
		_config_persistence.setup(self)

	super._ready()

	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()

## 应用主题色（由 ThemeManager 广播调用 + _ready 首次自调）
func apply_theme() -> void:
	var p := ThemeMGR.get_color("primary")
	var pl := ThemeMGR.get_color("primary_light")
	# TotalView panel -> primary
	var total_view := get_node_or_null("MC/VBox/TotalView") as Panel
	if total_view:
		var sb := total_view.get_theme_stylebox("panel")
		if sb is StyleBoxFlat:
			sb.bg_color = p
	# noteTotal panel -> primary_light
	var note_total := get_node_or_null("MC/VBox/TotalView/MC/VBoxC/flowArea/noteTotal") as Panel
	if note_total:
		var sb := note_total.get_theme_stylebox("panel")
		if sb is StyleBoxFlat:
			sb.bg_color = pl
	# VocalEnableBtn button states
	if vocal_enable_btn:
		var sb_n := vocal_enable_btn.get_theme_stylebox("normal")
		if sb_n is StyleBoxFlat:
			sb_n.bg_color = p
		var sb_h := vocal_enable_btn.get_theme_stylebox("hover")
		if sb_h is StyleBoxFlat:
			sb_h.bg_color = p.lightened(0.15)
		var sb_p := vocal_enable_btn.get_theme_stylebox("pressed")
		if sb_p is StyleBoxFlat:
			sb_p.bg_color = ThemeMGR.DANGER_COLOR
		var sb_hp := vocal_enable_btn.get_theme_stylebox("hover_pressed")
		if sb_hp is StyleBoxFlat:
			sb_hp.bg_color = ThemeMGR.DANGER_COLOR.lightened(0.2)

func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)

# 加载并播放midi
func _load_midi(midi: MidiData) -> void:
	current_midi_data = midi
	# 清空独奏状态
	solo_pairs.clear()
	solo_mute_snapshot.clear()

	# 收回全局共享的乐器子菜单（避免随旧轨道场景一起被释放）
	_reclaim_shared_submenus()

	# 清空现有的轨道
	clear_items()

	# 重置列表高度
	await get_tree().process_frame
	container.custom_minimum_size.y = 0
	container.size.y = 0

# 人声文件检测已前移至 MidiView（选中谱面时解析），此处仅同步已解析的人声路径
	_vocal_controller.vocal_file_path = current_midi_data.vocal_file_path
	# 在执行同步耗时的 load_midi 之前先让 UI 渲染一帧
	# （此时转场动画刚启动，避免被 MIDI 解析/JSON 写入阻塞导致首帧卡顿）
	await get_tree().process_frame
	# 线程化预解析 MIDI：将昂贵的文件 I/O + 数据结构构建移到 worker 线程
	# 主线程在 await 期间继续渲染转场动画，避免复杂 MIDI 导致的首帧卡顿
	# load_midi 后续会命中缓存跳过同步解析
	if not await midi_playback_manager.preparse_midi_async(midi):
		push_error("Failed to preparse MIDI: " + midi.name)
	# 加载MIDI到播放管理器（此时已命中解析缓存，仅做配置应用 + 后端加载）
	if not midi_playback_manager.load_midi(midi):
		push_error("Failed to load MIDI: " + midi.name)
	await get_tree().process_frame

	# 更新进度条最大范围
	if midi.duration_ms > 0:
		_set_display_total_time(midi.duration_ms)
	# TrackView 加载时设置循环播放
	midi_playback_manager.set_loop(true)

	# 新增：从加载的 MIDI 和 SoundFont 提取可用乐器选项
	_extract_instruments_from_midi()
	# 提取乐器列表是同步操作（遍历 SoundFont presets），让它后让出一帧给 UI
	await get_tree().process_frame

	# 恢复用户配置的数据部分（音量值、进度条、独奏状态）
	_config_persistence.restore_midi_data_config()

	# 加载音符
	# runtime_track_channel_notes 由 MidiPlaybackManager.load_midi 兜底从 notes_soa 重建（保证与 SOA 强一致），
	# _build_buckets 直接读取（SOA 就绪时经 grouped_indices 重建 bucket，无需主线程遍历全量音符）。
	# 守卫不能只看 is_empty()：残留"空分组字典"也要重建；SOA 就绪则直接以 grouped_indices 兜底。
	if (current_midi_data.notes_soa == null or current_midi_data.notes_soa.size() == 0) \
			and current_midi_data.runtime_track_channel_notes.is_empty():
		push_warning("No track_channel_notes available (preparse may have failed)")
		return
	if current_midi_data.notes_soa != null and current_midi_data.notes_soa.size() > 0 \
			and current_midi_data.runtime_track_channel_notes.is_empty():
		current_midi_data.runtime_track_channel_notes = current_midi_data.notes_soa.grouped_indices()
	# 按 (track, channel) 分组构建 TrackNoteBucket（主线程仅 O(Buckets)）
	_build_buckets()
	# 构建 buckets 后让出一帧，避免 _init_master_note_displayer 紧接其后再阻塞
	await get_tree().process_frame

	# 先设置 is_master 标志，确保 init_displayer_with_buckets 内的 is_master 分支正确执行
	master_note_displayer.is_master = true
	# 初始化总览的音符显示器
	_init_master_note_displayer()
	await get_tree().process_frame

	# 创建轨道UI
	await _create_track_views()

	# 初始化新MIDI的轨道音量为50%（如果没有保存过配置）
	_initialize_track_volumes_for_new_midi()

	# 恢复用户配置的UI部分（按钮状态、文本标签等）
	_config_persistence.restore_midi_ui_config()

	# 检测并初始化人声文件
	_vocal_controller.init_vocal_btn_display()

	# 初始化Latency输入框
	_init_latency_edit()

	# 启动播放（UI 已完全加载，避免 _prepare_to_play 阻塞 UI 渲染）
	midi_playback_manager.play()

	# 启用 TrackView 进度更新和音符显示器
	set_process(true)
	_set_note_displayers_process(true)

	# 等容器尺寸更新，再增加上下边距 （这个不是一定会触发，请勿在后面加总是需要执行的代码）
	await get_tree().process_frame
	container.custom_minimum_size.y = container.size.y + 300

# 创建轨道视图
func _create_track_views() -> void:
	if not current_midi_data:
		return

	# 获取轨道信息
	var track_infos = midi_playback_manager.get_track_infos()

	if track_infos.is_empty():
		push_warning("No track info available")
		return

	if _all_buckets.is_empty():
		push_warning("No buckets available")
		return

	# 缓存 track 名称
	var track_name_map = {}
	for track_info in track_infos:
		track_name_map[track_info.index] = track_info.name

	# 按 (channel asc, track asc) 排序 buckets，与原逻辑一致
	_all_buckets.sort_custom(func(a, b):
		if a.channel != b.channel:
			return a.channel < b.channel
		return a.track_index < b.track_index
	)

	# 为每个 bucket 创建 MidiTrack UI 项
	for bucket in _all_buckets:
		if bucket.notes.is_empty():
			continue

		var track_idx = bucket.track_index
		var channel = bucket.channel
		var track_name = track_name_map.get(track_idx, "Track %d" % track_idx)

		# 创建MidiTrack UI项
		var track_scene = create_and_add_item(track_name, "MidiTrack") as MidiTrack
		track_scene.setup_track(self, track_idx, track_name, instrument_options, channel, current_midi_data)

		# 设置该 (track, channel) 的正确乐器
		_set_track_instrument_from_midi_data(track_scene, track_idx, channel)

		# 初始化该(track, channel)对的音符显示（子 displayer 共享 bucket.notes 但独立 cursor）
		_init_track_note_displayer(track_scene, bucket)
		await get_tree().process_frame

	


# ============= 信号回调函数 ===============

# 进度条拖拽开始
func _on_progress_bar_drag_started() -> void:
	# 拖拽开始时停止自动更新进度条
	is_progress_dragging = true
	GLogger.info("Progress bar drag started", "TrackView")

# 进度条拖拽结束 - 执行跳转
func _on_progress_bar_drag_ended(_value_changed: bool) -> void:
	is_progress_dragging = false
	
	if midi_playback_manager == null:
		return
	
	var target_ms = progress_bar.value
	GLogger.info("Progress bar seek to: %.1f ms" % target_ms, "TrackView")
	
	# 执行跳转
	midi_playback_manager.seek(target_ms)

	# 【关键】更新 last_position_ms 和 current_tick，防止下一帧循环检测误判
	last_position_ms = target_ms
	current_tick = int(midi_playback_manager.position)
	
	# Reset individual track displayers first
	for track in list_items:
		if track.note_display:
			track.note_display.reset_playhead_position(target_ms)

	# Then reset master displayer
	if master_note_displayer:
		master_note_displayer.reset_playhead_position(target_ms)

# 进度条值改变 - 预览时间
func _on_progress_bar_value_changed(value: float) -> void:
	# 只在拖拽时预览时间
	if is_progress_dragging:
		current_time.text = _format_time(value)


# 音量按钮回调：按下→把对应音量条拉到0静音（记住原值），再按→恢复原值。
# 不禁止滑块：静音状态下滑动滑块会解除静音并采用新值（见 _on_midi/vocal_volume_changed）
func _on_volume_btn_toggled(toggle_on: bool, btn: TextureButton) -> void:
	# 静音时的体积（dB），避免 linear_to_db(0) 产生 -inf
	const MUTE_DB: float = -80.0
	const DEFAULT_MIDI_VOL: float = 0.5  # 无历史值时恢复的默认MIDI音量（50%）
	const DEFAULT_VOCAL_VOL: float = 1.0 # 无历史值时恢复的默认人声音量（100%）

	if btn == midi_vol_btn:
		if toggle_on:
			_prev_midi_vol = midi_vol_slider.value
			_set_display_midi_volume(0.0)
			midi_playback_manager.set_volume_db(MUTE_DB)
		else:
			_on_midi_volume_changed(_prev_midi_vol if _prev_midi_vol >= 0.0 else DEFAULT_MIDI_VOL)
	elif btn == vocal_vol_btn:
		if toggle_on:
			_prev_vocal_vol = vocal_vol_slider.value
			_vocal_controller.set_display_vocal_volume(0.0)
			midi_playback_manager.set_vocal_volume_db(MUTE_DB)
		else:
			_on_vocal_volume_changed(_prev_vocal_vol if _prev_vocal_vol >= 0.0 else DEFAULT_VOCAL_VOL)

# MIDI音量改变回调
func _on_midi_volume_changed(value: float) -> void:
	if midi_playback_manager == null:
		return

	# 静音状态下拖动滑块到非0 → 视为解除静音并采用新值
	if midi_vol_btn.button_pressed and value > 0.0:
		_prev_midi_vol = value
		midi_vol_btn.set_pressed_no_signal(false)

	# MIDI音量实际效果为UI值的 MIDI_VOLUME_GAIN 倍（0.5=+6dB, 1.0=+12dB）
	midi_playback_manager.apply_ui_midi_volume(value)

	# 更新标签
	_set_display_midi_volume(value)

func _on_vocal_volume_changed(value: float) -> void:
	if midi_playback_manager == null:
		return

	# 静音状态下拖动滑块到非0 → 解除静音并采用新值
	if vocal_vol_btn.button_pressed and value > 0.0:
		_prev_vocal_vol = value
		vocal_vol_btn.set_pressed_no_signal(false)

	# 人声音量1:1映射（0-1 线性）
	var volume_db = linear_to_db(value)
	volume_db = maxf(volume_db, -80.0)
	midi_playback_manager.set_vocal_volume_db(volume_db)

	# 更新MidiData中的音量值，用于持久化
	if current_midi_data != null:
		current_midi_data.vocal_volume = value

	# 更新标签
	_vocal_controller.set_display_vocal_volume(value)

## VocalImportBtn.pressed 代理（信号已在 tscn 中连接到 self）
func _on_vocal_import_btn_pressed() -> void:
	_vocal_controller.on_vocal_import_btn_pressed()

## VocalEnableBtn.toggled 代理（信号已在 tscn 中连接到 self）
func _on_vocal_enable_btn_toggled(toggle_on: bool) -> void:
	_vocal_controller.on_vocal_enable_btn_toggled(toggle_on)

func _on_expand_master_area_btn_toggled(is_expanded: bool) -> void:
	var node: Panel = $MC/VBox/TotalView
	var expd_y:int = int(get_viewport().get_visible_rect().size.y) - 50
	
	var tween: Tween = AniMGR.create_managed_tween(self)
	tween.pause()
	tween.set_parallel(true)
	
	var finl_size = Vector2(node.custom_minimum_size.x, expd_y if is_expanded else 350)
	tween.tween_property(node, "custom_minimum_size", finl_size, 0.25)
	
	container.custom_minimum_size.y += expd_y if is_expanded else -expd_y
	await get_tree().process_frame
	
	tween.tween_property(self, "scroll_vertical", 0, 0.2)
	tween.tween_property(master_note_displayer, "lane_count", 88 if is_expanded else 24, 0.2)
	
	tween.play()
	await tween.finished
	master_note_displayer.refresh_notes_lane(master_note_displayer.lane_count)

# ============= 音轨信号回调 =======================

# 轨道启用状态切换
func _on_track_enable_toggled(is_checked: bool, track_index: int, channel: int) -> void:
	if current_midi_data == null:
		return

	# 更新指定(track, channel)启用状态
	current_midi_data.set_track_channel_enabled(track_index, channel, is_checked)

	# 同步主音符显示器（按 selected_track_configs 过滤音符可见性）
	if master_note_displayer:
		master_note_displayer.sync_from_midi_data(current_midi_data)

# 轨道静音切换
func _on_track_mute_toggled(is_muted: bool, track_index: int, channel: int) -> void:
	GLogger.info("Track %d Channel %d mute: %s" % [track_index, channel, is_muted], "TrackView")
	if midi_playback_manager == null:
		return

	# 调用MidiPlaybackManager的实时mute接口（会同步MidiData）
	midi_playback_manager.set_track_channel_mute(track_index, channel, is_muted)

# 轨道独奏切换
func _on_track_solo_toggled(is_solo: bool, track_index: int, channel: int) -> void:
	GLogger.info("Track %d Channel %d solo: %s" % [track_index, channel, is_solo], "TrackView")
	if midi_playback_manager == null:
		return

	var key = _make_pair_key(track_index, channel)

	# 第一次进入独奏时，记录当前mute状态
	if is_solo and solo_pairs.is_empty():
		_capture_solo_snapshot()

	if is_solo:
		solo_pairs[key] = true
	else:
		solo_pairs.erase(key)

	# 更新MIDI播放的mute状态（根据独奏状态调整）
	if solo_pairs.is_empty():
		_restore_solo_snapshot()
	else:
		for track_ui in list_items:
			var tc_key = _make_pair_key(track_ui.track_index, track_ui.track_channel)
			var should_solo = solo_pairs.has(tc_key)
			var is_muted_in_snapshot = solo_mute_snapshot.get(tc_key, false)
			var target_muted = true if not should_solo else is_muted_in_snapshot
			midi_playback_manager.set_track_channel_mute_runtime(track_ui.track_index, track_ui.track_channel, target_muted)

# 轨道音量改变
func _on_track_volume_changed(value: float, track_index: int, channel: int ) -> void:
	if midi_playback_manager == null:
		return
	
	# 获取对应的轨道UI（需要同时匹配 track_index 和 channel）
	var track_ui: MidiTrack = null
	for track in list_items:
		if track.track_index == track_index and track.track_channel == channel:
			track_ui = track
			break
	
	if track_ui == null:
		return
	
	# 滑块已是线性 0-1 值，直接透传
	var volume_linear = value

	# 调用MidiPlaybackManager设置轨道音量（立即生效）
	midi_playback_manager.set_track_channel_volume(track_index, channel, volume_linear)
	
	# 同时保存到MidiData以支持持久化
	if current_midi_data != null:
		current_midi_data.set_track_channel_volume(track_index, channel, volume_linear)
	
	GLogger.info("Track %d Channel %d volume changed: %.1f%%" % [track_index, channel, value], "TrackView")
	
# 乐器选择（新签名：由 MidiTrack 子菜单直接传乐器数据）
func _on_track_instrument_changed(track_index: int, channel: int, bank: int, program: int, preset_name: String) -> void:
	var instr_data := {"bank": bank, "program": program, "name": preset_name}

	# 获取对应的轨道UI并同步大类图标
	var track_item: MidiTrack = null
	for track in list_items:
		if track.track_index == track_index and track.track_channel == channel:
			track_item = track
			break
	if track_item:
		track_item.set_instrument_category(InstrumentCategory.get_category(bank, program))
	
	# 1. 保存到 MidiData
	current_midi_data.set_track_channel_instrument_override(
		track_index,
		channel,
		instr_data["bank"],
		instr_data["program"],
		instr_data["name"]
	)
	
	# 2. 立即应用到后端播放器
	if not midi_playback_manager:
		push_error("[TrackView] midi_playback_manager is null")
		return

	var midi_player_ref = midi_playback_manager.midi_player

	if midi_player_ref == null:
		push_error("[TrackView] midi_player is null - backend probably not initialized")
		return

	if not midi_player_ref.has_method("set_track_channel_instrument"):
		push_error("[TrackView] midi_player doesn't have set_track_channel_instrument method")
		return
	
	GLogger.info("【调用】 set_track_channel_instrument(track=%d, channel=%d, bank=%d, program=%d)" %
		[track_index, channel, instr_data["bank"], instr_data["program"]], "TrackView")
	
	midi_player_ref.set_track_channel_instrument(
		track_index,
		channel,
		instr_data["bank"],
		instr_data["program"]
	)
	
	GLogger.info("Track %d Channel %d: 乐器设置为 %s (Bank %d Program %d)" %
		[track_index, channel, instr_data["name"], instr_data["bank"], instr_data["program"]], "TrackView")

# 解析乐器字符串 "乐器名 (BX:PY)" 返回 {name, bank, program}
func _parse_instrument_string(instrument_str: String) -> Dictionary:
	var regex = RegEx.new()
	regex.compile(r"^(.+?)\s*\(B(\d+):P(\d+)\)$")
	var result = regex.search(instrument_str)
	
	if result:
		return {
			"name": result.get_string(1).strip_edges(),
			"bank": int(result.get_string(2)),
			"program": int(result.get_string(3))
		}
	return {}

# 重置轨道-通道的乐器到 MIDI 原始值
func _on_track_instrument_reset(track_index: int, channel: int) -> void:
	if not current_midi_data:
		return
	
	# 清除用户覆盖
	current_midi_data.clear_track_channel_instrument_override(track_index, channel)
	
	# 从 MIDI 原始数据恢复
	if midi_playback_manager:
		var original_instr = midi_playback_manager.get_original_track_channel_instrument(track_index, channel)
		midi_playback_manager.set_track_channel_instrument(
			track_index,
			channel,
			original_instr["bank"],
			original_instr["program"]
		)
		
		# 更新 UI 下拉框（需要遍历查找匹配 track_index 和 channel 的UI项）
		var track_ui: MidiTrack = null
		for track in list_items:
			if track.track_index == track_index and track.track_channel == channel:
				track_ui = track
				break
		
		if track_ui:
			_set_track_instrument_from_midi_data(track_ui, track_index, channel)
	
	GLogger.info("Track %d Channel %d: 已重置为原始乐器" % [track_index, channel], "TrackView")

# 更新预览（当轨道或音源改变时）
func _update_preview() -> void:	
	var current_pos = midi_playback_manager.position_ms
	midi_playback_manager.load_midi(current_midi_data)
	midi_playback_manager.seek(current_pos)
	midi_playback_manager.play()

## 更新主音符显示器（显示所有音符，不按轨道启用状态过滤）
func _update_master_note_displayer() -> void:
	if master_note_displayer == null or current_midi_data == null:
		return

	if _all_buckets.is_empty():
		push_warning("No buckets available")
		return

	# 传入全部 buckets（未过滤），由 sync_from_midi_data 控制 bucket.is_enabled
	# max_end_tick 直接读 MidiData（preparse 已缓存），避免遍历所有音符
	master_note_displayer.init_displayer_with_buckets(self, _all_buckets, current_midi_data.max_end_tick)
	if not current_midi_data.selected_track_configs.is_empty():
		master_note_displayer.sync_from_midi_data(current_midi_data)


func _make_pair_key(track_index: int, channel: int) -> String:
	return "%d:%d" % [track_index, channel]

func _capture_solo_snapshot() -> void:
	solo_mute_snapshot.clear()
	if current_midi_data == null:
		return
	for track_ui in list_items:
		var key = _make_pair_key(track_ui.track_index, track_ui.track_channel)
		solo_mute_snapshot[key] = current_midi_data.get_track_channel_mute(track_ui.track_index, track_ui.track_channel)

func _restore_solo_snapshot() -> void:
	if midi_playback_manager == null or current_midi_data == null:
		solo_mute_snapshot.clear()
		return
	for track_ui in list_items:
		var key = _make_pair_key(track_ui.track_index, track_ui.track_channel)
		if solo_mute_snapshot.has(key):
			var muted = solo_mute_snapshot[key]
			midi_playback_manager.set_track_channel_mute_runtime(track_ui.track_index, track_ui.track_channel, muted)
	solo_mute_snapshot.clear()

func _apply_solo_state() -> void:
	if midi_playback_manager == null:
		return
	if solo_pairs.is_empty():
		_restore_solo_snapshot()
		return

	for track_ui in list_items:
		var key = _make_pair_key(track_ui.track_index, track_ui.track_channel)
		var should_solo = solo_pairs.has(key)
		var is_muted_in_snapshot = solo_mute_snapshot.get(key, false)
		var target_muted = true if not should_solo else is_muted_in_snapshot
		# 使用runtime mute来应用临时的独奏状态（不持久化）
		midi_playback_manager.set_track_channel_mute_runtime(track_ui.track_index, track_ui.track_channel, target_muted)

# =============== MIDI播放器信号回调 ====================

func _set_note_displayers_process(enable: bool) -> void:
	# 仅 master 承载 _process；子 displayer 由 master 每帧派发重绘
	if master_note_displayer:
		master_note_displayer.set_process(enable)

# ============== UI 显示函数 ========================

# 更新MIDI音量标签
func _set_display_midi_volume(value: float) -> void:
	# value 是线性 0-1 值
	midi_vol_slider.set_block_signals(true)
	midi_vol_slider.value = value
	midi_vol_slider.set_block_signals(false)

	midi_vol_label.text = "%d%%" % int(round(value * 100.0))

# 格式化时间（毫秒到 HH:MM:SS）
func _format_time(ms: float) -> String:
	var total_seconds: int = int(ms / 1000)
	@warning_ignore("integer_division")
	var minutes: int = total_seconds / 60
	var seconds: int = total_seconds % 60
	@warning_ignore("integer_division")
	var hours: int = minutes / 60
	if hours:
		return "%02d:%02d:%02d" % [hours, minutes, seconds]
	else:
		return "%02d:%02d" % [minutes, seconds]

# 设置总时间
func _set_display_total_time(total_ms: float) -> void:
	progress_bar.set_block_signals(true)
	progress_bar.max_value = total_ms
	progress_bar.set_block_signals(false)
	
	total_time.text = _format_time(total_ms)

func _set_display_current_time(current_ms: float) -> void:
	# 只在不拖拽时更新进度条位置和时间文本
	if not is_progress_dragging:
		progress_bar.set_block_signals(true)
		progress_bar.value = current_ms
		progress_bar.set_block_signals(false)
		
		current_time.text = _format_time(current_ms)

func _process(delta: float) -> void:
	if midi_playback_manager.is_playing:
		var current_position = midi_playback_manager.position_ms
		
		# 检测循环播放重置（位置从大跳到小，说明循环了）
		if current_position < last_position_ms - 100:  # 100ms容差，避免误判seek操作
			GLogger.info("Loop detected: %.1f -> %.1f ms, resetting noteDisplayers" % [last_position_ms, current_position], "TrackView")
			_reset_player()
		
		# 更新当前时间
		_set_display_current_time(current_position)
		# 更新当前 tick（从 position 获取）
		current_tick = int(midi_playback_manager.position)
		# 记录本帧位置
		last_position_ms = current_position

	super._process(delta)

func _gui_input(event: InputEvent) -> void:
	super._gui_input(event)

# 初始化主音符显示器（显示所有音符，不按轨道启用状态过滤）
func _init_master_note_displayer() -> void:
	if master_note_displayer == null:
		return
	
	if current_midi_data == null:
		push_warning("No MIDI data loaded")
		return
	
	_reset_player()

	# 获取所有音符
	# All_Notes 已删除，改用 _all_buckets 判断（runtime_track_channel_notes 为空时 _build_buckets 已 return）
	if _all_buckets.is_empty():
		push_warning("No notes found in selected tracks")
		return
	
	# 推荐轨道的首次应用与 _track_config_initialized 标记已在 MidiPlaybackManager.load_midi 中完成
	# TrackView 只需根据已恢复的 selected_track_configs 显示 UI（由 restore_midi_ui_config 处理）
	# 这里仅记录日志，不再重复应用推荐轨道
	if current_midi_data.is_track_config_initialized():
		GLogger.info("MIDI config already initialized: %d tracks have enabled channels" %
			current_midi_data.selected_track_configs.size(), "TrackView")
	else:
		# 理论上不应走到这里（load_midi 已设置 _track_config_initialized=true），防御性日志
		push_warning("[TrackView] Unexpected: track config not initialized, selected_track_configs may be incomplete")
	
	# 统计音符总数（从 buckets 汇总）
	var total_notes = 0
	for bucket in _all_buckets:
		total_notes += bucket.notes.size()
	GLogger.info("Master note displayer: %d total notes across %d buckets" % [total_notes, _all_buckets.size()], "TrackView")
	# 初始化主音符显示器（传入所有 buckets + max_end_tick 从 MidiData 直接读取），随后按 selected_track_configs 过滤可见性
	master_note_displayer.init_displayer_with_buckets(self, _all_buckets, current_midi_data.max_end_tick)
	if not current_midi_data.selected_track_configs.is_empty():
		master_note_displayer.sync_from_midi_data(current_midi_data)

## 按 (track, channel) 分组构建 TrackNoteBucket
## groups 直接读 set_parsed_soa 构建的 runtime_track_channel_notes（与 SOA 强一致），只读复用；
## 仅当缓存缺失/空分组时才从 SOA 兜底重建并回写
func _build_buckets() -> void:
	_all_buckets.clear()
	var soa := current_midi_data.notes_soa
	var use_soa := soa != null and soa.size() > 0
	# 分组唯一权威来源是 set_parsed_soa 与 SOA 一并构建的 runtime_track_channel_notes（与 SOA 强一致）。
	# 只读复用，不再每次进入重复 O(N) 重建；仅当缓存缺失/空分组时才从 SOA 兜底重建。
	var groups: Dictionary = current_midi_data.runtime_track_channel_notes
	if groups.is_empty() and use_soa:
		groups = soa.grouped_indices()
		current_midi_data.runtime_track_channel_notes = groups
	for key in groups:
		var parts = key.split(":")
		var track_idx = int(parts[0])
		var channel = int(parts[1])
		var indices = groups[key]

		var bucket = NoteDisplayer.TrackNoteBucket.new()
		bucket.track_index = track_idx
		bucket.channel = channel
		bucket.hue = MidiTrack.colors_set[track_idx % MidiTrack.colors_set.size()].h
		bucket.color = Color.from_hsv(bucket.hue, 1, 0.9, 0.8)
		# 统一透传到 bucket：soa != null 时 indices 为 PackedInt32Array（SOA 索引），显示路径
		# 只读直引 bucket.soa，不物化全量 22w NoteEvent（音符数据唯一来源仍是 SOA）
		bucket.notes = indices
		bucket.soa = soa if use_soa else null
		_all_buckets.append(bucket)
	# SOA 来源数组已按 start_tick 升序，每组内天然有序，无需再 sort
	var diag_total := 0
	for b in _all_buckets:
		diag_total += b.notes.size()
	GLogger.info("Build buckets: soa_size=%d use_soa=%s buckets=%d total_notes=%d" %
		[soa.size() if soa != null else -1, use_soa, _all_buckets.size(), diag_total], "TrackView")

func _init_track_note_displayer(track_scene: MidiTrack, source_bucket: NoteDisplayer.TrackNoteBucket) -> void:
	if track_scene.note_display == null:
		return

	if source_bucket.notes.is_empty():
		push_warning("No notes found for track %d channel %d" % [source_bucket.track_index, source_bucket.channel])
		return

	# 子 displayer 不再独立推算：生命周期/计数/计时统一由 master 推进，
	# 共享 master 的 bucket + 活动音符数组，绘制时按自身几何换算
	var child := track_scene.note_display
	child.is_master = false
	var max_end_tick := current_midi_data.max_end_tick if current_midi_data != null else 0.0
	child.init_displayer_with_buckets(self, [source_bucket], max_end_tick)
	master_note_displayer.register_child(child, source_bucket.track_index, source_bucket.channel)

	GLogger.info("Track %d Channel %d: %d notes (time-sorted)" %
		[source_bucket.track_index, source_bucket.channel, source_bucket.notes.size()], "TrackView")

# 重置音符显示器索引
func _reset_player() -> void:	
	current_tick = 0
	last_position_ms = 0.0
	_set_display_current_time(0)

	# 重置音符显示器位置
	master_note_displayer.reset_playhead_position(0)
	for track in list_items:
		if track.note_display:
			track.note_display.reset_playhead_position(0)

## 初始化新MIDI的轨道音量为50%
## 只在首次加载MIDI时调用（如果没有保存过音量配置）
func _initialize_track_volumes_for_new_midi() -> void:
	if current_midi_data == null or midi_playback_manager == null:
		return
	
	# 检查是否已有音量配置（旧MIDI或已保存过）
	if not current_midi_data.track_channel_volume_config.is_empty():
		# 已有配置，跳过初始化
		return
	
	# 新MIDI：为所有已创建的轨道初始化音量为50%（0.5线性值）
	var initialized_count = 0
	for track_item in list_items:
		if track_item is MidiTrack:
			var track_idx = track_item.track_index
			var channel = track_item.track_channel
			
			# 设置默认音量为50%（0.5）
			var default_volume = 0.5
			midi_playback_manager.set_track_channel_volume(track_idx, channel, default_volume)
			current_midi_data.set_track_channel_volume(track_idx, channel, default_volume)
			initialized_count += 1
	
	GLogger.info("Initialized %d tracks with default volume 50%%" % initialized_count, "TrackView")

# 页面状态回调
func _on_ui_state_changed(old_state: UIStateManager.UIState, new_state: UIStateManager.UIState) -> void:
	# 保存当前MIDI配置到JSON文件
	if current_midi_data != null:
		_config_persistence.call_deferred("save_midi_config")

	if old_state == work_state:
		if midi_playback_manager:
			if new_state == ui_stat_mgr.UIState.MIDI_VIEW:
				midi_playback_manager.stop()
				_cleanup()
			elif new_state == ui_stat_mgr.UIState.SETTINGS_VIEW:
				midi_playback_manager.pause()

		_set_note_displayers_process(false)
		# 收起主面板的展开状态
		get_node("MC/VBox/TotalView/MC/VBoxC/flowArea/noteFlowArea/Button").button_pressed = false

	# Reload MIDI when returning from settings (handles backend switch)
	if old_state == ui_stat_mgr.UIState.SETTINGS_VIEW and new_state == work_state:
		if current_midi_data:
			midi_playback_manager.set_loop(true)
			midi_playback_manager.resume()
			_set_note_displayers_process(true)
			GLogger.info("Reloaded MIDI after returning from settings", "TrackView")

## 释放视图内部资源（列表项、音符数据），保留节点壳和信号连接
## 不 unload_midi / 不 clear_parsed_notes：同一 MIDI 在 MidiView/TrackView/PlayView 间
## 切换时复用解析数据，避免反复重解析。离开 MidiView 或切换 MidiList 项时才彻底清理
func _cleanup() -> void:
	clear_items()
	_all_buckets.clear()
	_set_note_displayers_process(false)

## 初始化Latency输入框（从MidiData读取偏移值）
func _init_latency_edit() -> void:
	if latency_edit == null or current_midi_data == null:
		return

	# 从MidiData读取人声偏移量并显示
	latency_edit.set_block_signals(true)
	latency_edit.text = str(int(current_midi_data.vocal_offset_ms))
	latency_edit.set_block_signals(false)

	# 将偏移值应用到MidiPlaybackManager
	midi_playback_manager.set_vocal_offset_ms(current_midi_data.vocal_offset_ms)

## 处理Latency输入框文本变化
func _on_latency_changed(new_text: String) -> void:
	if current_midi_data == null or midi_playback_manager == null or latency_edit == null:
		return

	# 验证输入（确保是有效的整数）
	var offset_ms: int = 0
	if not new_text.is_empty():
		if new_text.is_valid_int():
			offset_ms = int(new_text)
		else:
			# 如果输入无效，恢复为之前的值
			latency_edit.set_block_signals(true)
			latency_edit.text = str(int(current_midi_data.vocal_offset_ms))
			latency_edit.set_block_signals(false)
			return

	# 更新MidiData中的偏移值
	current_midi_data.vocal_offset_ms = offset_ms

	# 应用到MidiPlaybackManager
	midi_playback_manager.set_vocal_offset_ms(offset_ms)

	# 如果人声正在播放，立即应用偏移
	if midi_playback_manager.is_playing:
		midi_playback_manager.apply_vocal_offset()

	GLogger.info("Latency offset changed to %d ms" % offset_ms, "TrackView")

## 缓存上次提取乐器列表时使用的 SoundFont 路径
## 乐器列表只依赖 SoundFont（与 MIDI 文件无关），同 SoundFont 下无需重复提取
var _instruments_soundfont_path: String = ""

## 从当前加载的 MIDI 和 SoundFont 提取可用的乐器选项
func _extract_instruments_from_midi() -> void:
	if midi_playback_manager == null:
		return

	# 缓存命中：SoundFont 未变且已提取过，直接跳过
	var current_sf_path: String = midi_playback_manager.current_soundfont_path
	if not current_sf_path.is_empty() and current_sf_path == _instruments_soundfont_path \
			and not instrument_options.is_empty():
		return

	var presets_list = midi_playback_manager.get_presets_list()

	if presets_list.is_empty():
		GLogger.warning("No presets available from SoundFont", "TrackView")
		instrument_options = ["Unknown (B0:P0)"]
		regular_instruments = instrument_options.duplicate()
		drum_instruments = []
		return

	# 清空之前的列表
	instrument_options.clear()
	regular_instruments.clear()
	drum_instruments.clear()
	
	var seen_options = {}  # 用于去重
	var entries: Array = []  # 收集 {display_name, bank, program}，填充前统一排序

	for preset in presets_list:
		var bank = preset["bank"]
		var program = preset["program"]
		var preset_name = preset["name"].strip_edges()
		
		if preset_name.is_empty():
			preset_name = "#%d" % program
		
		# 构建显示名称："乐器名 (BX:PY)"
		var display_name = "%s (B%d:P%d)" % [preset_name, bank, program]
		
		# 去重
		if seen_options.has(display_name):
			continue
		seen_options[display_name] = true
		entries.append({"display_name": display_name, "bank": bank, "program": program})

	# 固定排序：按 16 乐器大类分组，同类内 program 升序，再按 bank 升序
	entries.sort_custom(func(a, b):
		var cat_a: int = InstrumentCategory.get_category(a["bank"], a["program"])
		var cat_b: int = InstrumentCategory.get_category(b["bank"], b["program"])
		if cat_a != cat_b:
			return cat_a < cat_b
		if a["program"] != b["program"]:
			return a["program"] < b["program"]
		return a["bank"] < b["bank"]
	)

	for entry in entries:
		# 根据 GM/GS/GM2 bank 分类；部分 SoundFont 将 kit 放在 B120 而非 B128。
		if InstrumentCategory.is_drum_bank(entry["bank"]):
			# 鼓组乐器
			drum_instruments.append(entry["display_name"])
		else:
			# 常规乐器
			regular_instruments.append(entry["display_name"])
		# 全局列表包含所有
		instrument_options.append(entry["display_name"])

	GLogger.info("已提取 %d 个常规乐器, %d 个鼓组乐器" %
		[regular_instruments.size(), drum_instruments.size()], "TrackView")

	# 提取成功后记录所用 SoundFont 路径，供下次进入时跳过重复提取
	_instruments_soundfont_path = current_sf_path

## 根据 MIDI 数据设置轨道的正确乐器
func _set_track_instrument_from_midi_data(track_scene: MidiTrack, track_idx: int, channel: int) -> void:
	if current_midi_data == null or midi_playback_manager == null:
		return
	
	# 首先检查是否有用户覆盖
	var override_instr = current_midi_data.get_track_channel_instrument_override(track_idx, channel)
	var bank: int
	var program: int
	var preset_name: String
	
	if not override_instr.is_empty():
		# 使用用户覆盖的乐器
		bank = override_instr.get("bank", 0)
		program = override_instr.get("program", 0)
		preset_name = override_instr.get("name", midi_playback_manager.get_preset_name(program, bank))
		GLogger.info("Track %d Channel %d: 使用用户覆盖乐器 %s" % [track_idx, channel, preset_name], "TrackView")
	else:
		# 使用 MIDI 文件中的原始乐器
		var instrument_info = midi_playback_manager.get_track_channel_instrument(track_idx, channel)
		bank = instrument_info.get("bank", 0)
		program = instrument_info.get("program", 0)
		preset_name = midi_playback_manager.get_preset_name(program, bank)

	# 构建显示名称
	var display_name = "%s (B%d:P%d)" % [preset_name, bank, program]

	# 根据初始乐器设置轨道大类图标（区域由 InstrumentCategory 计算）
	track_scene.set_instrument_category(InstrumentCategory.get_category(bank, program))

	# 设置菜单按钮显示当前乐器并高亮对应大类（默认显示使用中的乐器）
	track_scene.set_current_instrument(InstrumentCategory.get_category(bank, program), display_name)

	GLogger.info("轨道 %d 通道 %d: 设置乐器为 '%s' (program: %d, bank: %d)" %
		[track_idx, channel, preset_name, program, bank], "TrackView")

## 当SoundFont变更时，重新提取乐器列表并更新UI
func _on_soundfont_changed(soundfont_path: String) -> void:
	GLogger.info("SoundFont changed: %s" % soundfont_path, "TrackView")

	# 重新提取乐器列表
	_extract_instruments_from_midi()

	# 更新所有现有的MidiTrack UI项的乐器选项
	_refresh_all_track_instruments()

## 当乐器列表变更时，快速更新所有MidiTrack的选项
func _refresh_all_track_instruments() -> void:
	GLogger.info("Refreshing all track instrument options", "TrackView")

	if current_midi_data == null:
		return

	for item in list_items:
		if item is MidiTrack:
			item.refresh_instrument_options(regular_instruments, drum_instruments)
			GLogger.info("Updated instrument options for track %d channel %d" % [item.track_index, item.track_channel], "TrackView")

# ===== 全局共享的乐器子菜单 =====
# 16 大类子菜单全程只创建一套（挂在 TrackView 下），所有音轨共用；
# 打开某轨主菜单时由 midiTrack._ensure_submenus_attached reparent 到该轨弹窗下。
# 相比每轨各建 16 个 PopupMenu/Window 节点，可显著降低 TrackView 随音轨数线性增长的内存。

## 取全局共享子菜单（不存在则创建一个裸 PopupMenu 挂在本视图下），category 为乐器大类号
func get_shared_submenu(category: int) -> PopupMenu:
	if _shared_instrument_submenus.has(category):
		var existing = _shared_instrument_submenus[category]
		if existing != null and is_instance_valid(existing):
			return existing
	var sub := PopupMenu.new()
	sub.name = "SharedSubmenu_%d" % category
	sub.hide_on_item_selection = false  # 选中项由 MidiTrack 手动控制关闭
	add_child(sub)  # 本视图持有；绑定到某轨弹窗后需调 _reclaim_shared_submenus 收回
	_shared_instrument_submenus[category] = sub
	return sub

## 把共享子菜单从轨道弹窗收回本视图持有（不销毁），防止换谱/清轨时随轨道场景被释放
func _reclaim_shared_submenus() -> void:
	for cat in _shared_instrument_submenus:
		var sub = _shared_instrument_submenus[cat]
		if sub == null or not is_instance_valid(sub):
			_shared_instrument_submenus[cat] = null
			continue
		if sub.get_parent() != self:
			sub.get_parent().remove_child(sub)
			add_child(sub)

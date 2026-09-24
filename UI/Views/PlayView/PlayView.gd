extends Control

## 结算界面返回演奏并重开一局时触发（LT_Btn 在 SCORE_VIEW 点击触发）
signal retry_pressed

# 音符显示区
@onready var flow_area: Panel = $FlowArea
# 背景控制器（BackgroundControl 节点，封装封面/模糊/暗化/闪光）
@onready var bg_ctrl: PlayBackground = $BackgroundControl
# HUD 展示层（Layer 节点，封装判定 UI/进度条/调试悬浮）
@onready var hud: PlayHud = $Layer

# 菜单及歌曲信息的背景遮罩
@onready var center_bg:ColorRect = $CenterBackGround
# 菜单
@onready var menu: Control = $CenterBackGround/VBox/Menu
@onready var retry_btn: Button = $CenterBackGround/VBox/Menu/retry
# 歌曲信息
@onready var song_info: Control = $CenterBackGround/VBox/SongInfo
@onready var cover: TextureRect = $CenterBackGround/VBox/SongInfo/PanelContainer/TextureRect
# 原曲
@onready var album: Label = $CenterBackGround/VBox/SongInfo/GridContainer/album
@onready var song: Label = $CenterBackGround/VBox/SongInfo/GridContainer/song
@onready var artist: Label = $CenterBackGround/VBox/SongInfo/GridContainer/artist
# midi
@onready var midi_name: Label = $CenterBackGround/VBox/SongInfo/GridContainer/midiName
@onready var midi_author: Label = $CenterBackGround/VBox/SongInfo/GridContainer/midiAuthor
@onready var midi_duration: Label = $CenterBackGround/VBox/SongInfo/GridContainer/midiDuration
# 难度
@onready var difficulty: Label = $CenterBackGround/VBox/SongInfo/GridContainer/difficulty

# 难度预设显示名（下标即 difficulty id：0=Easy,1=Normal,2=Hard,3=Lunatic,4=Custom）
const DIFFICULTY_NAMES: Array[String] = ["Easy", "Normal", "Hard", "Lunatic", "Custom"]
const DIFFICULTY_CFG_SECTION: String = "Generator"
const DIFFICULTY_CFG_KEY: String = "difficulty"

# 轨道光效及键位显示
@onready var lane_area: Control = $Lane

# auto标识
@onready var auto_label: Label = $AutoLabel

var current_midi: MidiData = null
## play_result 仅作为传递给 ScoreView 的展示数据容器
var play_result: ScoreView.ScoreData = null

@onready var ani: AnimationManager = AniMGR
@onready var playback_mgr: MidiPlaybackManager = MidiPlaybackManager.instance
@onready var key_sequence_mgr: KeySequenceManager = KeySequenceManager.instance
@onready var score_calc: ScoreCalculator = ScoreCalculator.instance

var midi_start_time: float = 0.0

## 本次游玩开始时间（毫秒，墙钟），用于计算游玩时长统计
var _play_start_time: int = 0

## 演奏模式标志：true = 演奏模式（响应键盘触发音符），false = 听奏模式（MIDI只在背景播放）
var play_mode: bool = true

var _is_finishing_game: bool = false

## 游戏是否已正式开始, 用于区分开局准备阶段是否完成并可以开始
var _game_started: bool = false

## 游戏代次：每次 _prepare_game 自增，用于让已启动的 _on_game_finished 协程在
## 用户重试（仍停留在 PLAY_VIEW）时失效，避免等待结束后被强切回 ScoreView
var _game_generation: int = 0

## 本次游玩是否开启 AUTO 模式（开局时快照，AUTO 模式成绩不上传）
var _is_auto_mode_play: bool = false

## position stall 检测：当 loop=false 时 MIDI 播放结束后 position 被 clamp 到 midiFile.Length
## 若 duration_ms 与 midiFile.Length 不一致，进度条可能永远无法达到 max_value
## 通过检测 position 停止增长来触发游戏结束
var _last_playback_position: float = -1.0
var _position_stall_frames: int = 0
const _PLAYBACK_STALL_THRESHOLD := 30  # 30帧 ≈ 0.5秒

########## 配置参数 #############
# 有一部分配置参数在flow_area里面
var lane_count: int = 12
var lane_padding: int = 100 # 左右填充安全区
var keyboard_mode: bool = false
var key_map: Array[Key] = []
var key_display_names: Array[String] = []

var judge_line_offset_y: int = 250

# 光柱特效不透明度
var beam_alpha: float = 0.5
# 交替轨道颜色（仅键盘模式生效，开启时覆盖音符颜色及轨道光效颜色）
var keyboard_alt_color: bool = true
var keyboard_alt_color_count: int = 2
var keyboard_alt_colors: Array[Color] = [Color.RED, Color.BLUE] # 交替颜色序列，颜色数量可大于轨道数一半（多余的不会被用到）
# 左右间距（像素；键盘模式且键位数为偶数时在中间额外加此间距，分隔左右手）
var keyboard_mode_gap: int = 0
# 轨道分隔线（仅键盘模式生效，相邻轨道之间与两端生成竖线）
var keyboard_lane_separator: bool = false

#################################

func _ready() -> void:
	# 从配置加载键盘和轨道相关的参数
	_load_lane_parameters()
	_load_debug_display_setting()
	_load_note_skin_setting()
	
	# 窗口大小变化
	get_window().size_changed.connect(_init_lane_display)
	if not get_window().focus_exited.is_connected(_on_window_focus_exited):
		get_window().focus_exited.connect(_on_window_focus_exited)

	EvtBus.start_game_with.connect(_prepare_game)
	UiStatMGR.state_changed.connect(_on_state_changed)
	_on_state_changed(UiStatMGR.UIState.NONE, UiStatMGR.current_state)

	flow_area.note_judged.connect(_on_note_judged)
	flow_area.long_holding.connect(_on_long_holding)
	flow_area.parent_node = self

	# HUD 展示层回调（结算检测 / 背景闪光请求）
	hud.game_finished_requested.connect(_on_game_finished)
	hud.flash_requested.connect(bg_ctrl.flash)

	retry_btn.pressed.connect(func ():
		_prepare_game()
	)
	retry_pressed.connect(func ():
		_prepare_game()
	)
	
	# 初始化MIDI播放管理器
	if playback_mgr == null:
		push_error("MidiPlaybackManager not initialized!")
		return

	# 播放自然结束时立即触发游戏结算（C# 后端 finished → midi_finished）
	# 原"位置停滞"启发式检测保留作为兜底
	if not playback_mgr.midi_finished.is_connected(_on_game_finished):
		playback_mgr.midi_finished.connect(_on_game_finished)
	
	# 从配置加载演奏模式设置
	_load_play_mode_setting()
	
	# 连接配置变更信号
	if not EvtBus.config_changed.is_connected(_on_lane_config_changed):
		EvtBus.config_changed.connect(_on_lane_config_changed)
	if not EvtBus.config_changed.is_connected(_on_config_changed):
		EvtBus.config_changed.connect(_on_config_changed)

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED:
		_auto_pause_on_background("app_notification_%d" % what)

var current_time: float = 0
var max_time: float = 20

# 视觉时钟（毫秒）：墙钟 delta 累加，平滑驱动音符渲染位置；
# 判定仍走 current_time（音频钟），保证判定与听到的声音对齐。
var _visual_time_ms: float = 0.0
# 视觉钟软锚定：每帧纠正与音频钟偏差的 2%，上限 ±0.5ms/帧（≈60ms/s 收敛，肉眼不可见）
const _VISUAL_ANCHOR_RATE := 0.02
const _VISUAL_ANCHOR_MAX_MS := 0.5
# 需要硬锚定（开始播放/暂停恢复时对齐音频钟，避免大跳）
var _visual_time_needs_anchor: bool = true
# 方向 3（输入及时性）：演奏视图内关闭 Input 事件累积，触摸事件立即派发，
# 可减少 Godot 输入按帧合并带来的 0~16.7ms 延迟；退出播放视图时恢复原值。
var _saved_accumulated_input: bool = true
var _accumulated_input_override_active: bool = false

func _process(delta: float) -> void:
	if not is_pause:
		if _is_finishing_game:
			# 游戏结束阶段：用delta模拟时间推进，让剩余音符自然下落
			current_time += delta * 1000.0
			_visual_time_ms = current_time
			flow_area.set_current_time(current_time, current_time)
		else:
			# 如果正在播放MIDI，使用MIDI播放管理器的时间（判定时钟）
			current_time = playback_mgr.get_position_ms()
			hud.set_progress(current_time)
			# 视觉时钟：墙钟累加 + 软锚定音频钟（渲染平滑，判定仍用音频钟）
			if _visual_time_needs_anchor:
				_visual_time_ms = current_time
				_visual_time_needs_anchor = false
			else:
				_visual_time_ms += delta * 1000.0
				var drift: float = current_time - _visual_time_ms
				_visual_time_ms += clampf(drift * _VISUAL_ANCHOR_RATE, -_VISUAL_ANCHOR_MAX_MS, _VISUAL_ANCHOR_MAX_MS)
			# 【方案C】同步到FlowArea：判定与渲染均为墙钟锚点钟（current_time），
			# _visual_time_ms 仅做帧间平滑
			flow_area.set_current_time(current_time, _visual_time_ms)

			# 检测音频停滞：判定钟（current_time）已改为墙钟锚点推导，音频卡顿时不再停滞，
			# 故停滞检测必须改用音频回调钟（get_raw_position_ms）——音频中断/曲终时停止增长的是它。
			# 当 duration_ms 与 midiFile.Length 不一致时，进度条可能永远无法达到 max_value
			var stall_clock_ms: float = playback_mgr.get_raw_position_ms() if playback_mgr else current_time
			if stall_clock_ms > 0.0 and abs(stall_clock_ms - _last_playback_position) < 0.5:
				_position_stall_frames += 1
				if _position_stall_frames >= _PLAYBACK_STALL_THRESHOLD:
					_position_stall_frames = 0
					# 区分曲终与音频中断：播放位置被后端 clamp 到 midiFile.Length，
					# 以实际后端总时长为主、解析器 duration_ms 为辅判定曲终（两者可能不一致）
					var backend_ms: float = playback_mgr.get_backend_duration_ms() if playback_mgr else 0.0
					var at_end: bool = (current_midi != null and current_time >= current_midi.duration_ms - 100.0) \
							or (backend_ms > 0.0 and current_time >= backend_ms - 100.0)
					if at_end:
						GLogger.warning("Playback position stalled at end %.1fms, triggering game finished" % current_time, "PlayView")
						_on_game_finished()
					elif OS.get_name() == "Android":
						# 安卓设备被系统打断（如来电/切后台）：整桥重建恢复声音，再自动弹暂停
						# 阻止停滞被误判为曲终跳结算，同时覆盖悬浮来电不暂停 Activity 时的自动暂停
						if playback_mgr:
							playback_mgr.recover_audio_output()
						_auto_pause_on_background("audio_interrupted")
					else:
						GLogger.warning("Playback position stalled at %.1fms, triggering game finished" % current_time, "PlayView")
						_on_game_finished()
			else:
				_position_stall_frames = 0
			_last_playback_position = stall_clock_ms
	
## 演奏视图专用：关闭/恢复 Input 事件累积（低延迟输入路径）
func _apply_input_low_latency(enable: bool) -> void:
	if enable and not _accumulated_input_override_active:
		_saved_accumulated_input = Input.use_accumulated_input
		Input.use_accumulated_input = false
		_accumulated_input_override_active = true
		GLogger.info("Input accumulation disabled for low-latency touch", "PlayView")
	elif not enable and _accumulated_input_override_active:
		Input.use_accumulated_input = _saved_accumulated_input
		_accumulated_input_override_active = false
		GLogger.info("Input accumulation restored to %s" % _saved_accumulated_input, "PlayView")

func get_lane_count() -> int:
	return lane_count if not keyboard_mode else key_map.size()

## 获取轨道交替颜色（仅键盘模式 + 交替轨道颜色开启时返回，否则返回 null）
## 交替方式：两端对称，colors[lane_idx % int(轨道数/2) % colors.size()]
## 返回 null 时调用方回退到皮肤解析色
func get_lane_color(lane_idx: int):
	if lane_idx == -1 or not keyboard_mode or not keyboard_alt_color:
		return null
	if keyboard_alt_colors.is_empty():
		return null
	@warning_ignore("integer_division")
	var lc = int(get_lane_count() / 2)
	if lc <= 0:
		return null
	return keyboard_alt_colors[lane_idx % lc % keyboard_alt_colors.size()]

## 解析交替颜色序列字符串（逗号分隔的 #RRGGBB / RRGGBB），空串或无效项跳过
func _parse_alt_colors(colors_str: String) -> Array[Color]:
	var result: Array[Color] = []
	for part in colors_str.split(",", false):
		var p := part.strip_edges()
		if p.is_empty() or not Color.html_is_valid(p):
			continue
		result.append(Color.from_string(p, Color.WHITE))
	return result

## 中间间距：键盘模式且键位数为偶数时返回设置的间距，否则 0
## 用于把左右手轨道分隔更远（LaneEffect 布局与触摸轨道估算共用）
func get_mid_lane_gap() -> int:
	if not keyboard_mode:
		return 0
	if get_lane_count() % 2 != 0:
		return 0
	return keyboard_mode_gap

## 轨道分隔线是否显示（键盘模式开启且选项开启；LaneEffect.init_beam 据此生成竖线）
func get_lane_separator_enabled() -> bool:
	return keyboard_mode and keyboard_lane_separator

func _on_state_changed(_oldState: UIStateManager.UIState, state: UIStateManager.UIState) -> void:
	var enable:bool = state == UIStateManager.UIState.PLAY_VIEW
	_apply_input_low_latency(enable)
	set_process(enable)
	get_node("Layer").visible = enable

	# 离开播放视图时统一清理所有资源（无论从哪条路径退出都走这里）
	if _oldState == UIStateManager.UIState.PLAY_VIEW and state != UIStateManager.UIState.PLAY_VIEW:
		if playback_mgr:
			playback_mgr.stop()
			playback_mgr.clear_manual_control_notes()
		flow_area.clear_flow_area()
		# 游戏序列数据由 C# KeySequenceCore 持有（跨视图复用），离开时本地无需持有引用
		# 结算页(from SCORE_VIEW 重试)与播放页同 MIDI，保留已烘焙的模糊背景以便重试复用；
		# 仅离开播放到其它视图时才清理，避免重试触发重新烘焙、闪现清晰原图
		if state != UIStateManager.UIState.SCORE_VIEW:
			bg_ctrl.clear_blur_bake()
		# 不 unload_midi / 不 clear_sequences / 不 clear_parsed_notes：
		# 同一 MIDI 在 MidiView/TrackView/PlayView 间切换时复用解析数据与 GameSequence 缓存，
		# 避免反复重解析/重生成。离开 MidiView 或切换 MidiList 项时才彻底清理
		# 重置状态，供下次 _prepare_game 使用
		_is_finishing_game = false
		is_pause = true

	if enable:
		GLogger.info("Node: %s , ProcessMode: %s" % [self.name, enable], "PlayView")
		# 从设置界面切回时，背景配置可能已变更，重新应用 play 背景（含 cover 模式烘焙）
		if _oldState == UIStateManager.UIState.SETTINGS_VIEW and current_midi != null:
			bg_ctrl.apply_background(null, false, current_midi)

## 新增：配置变更回调
func _on_config_changed(key: String, section: String, value: Variant) -> void:
	if section == "Appearance" and key == "background_dim_color":
		bg_ctrl.apply_dim()
		return

	if section == "Appearance" and key == "background_image_flash_color":
		bg_ctrl.apply_dim()
		return

	if section == "Appearance" and key in ["note_glow_intensity", "note_glow_size"]:
		var gi = ConfigManager.instance.get_float("Appearance", "note_glow_intensity", 0.5)
		var gs = ConfigManager.instance.get_float("Appearance", "note_glow_size", 5.0)
		if flow_area and flow_area.has_method("set_glow_params"):
			flow_area.set_glow_params(gi, gs)
		return
	
	if section == "Appearance" and key == "block_skin_preset":
		var skin_name = str(value)
		if flow_area and flow_area.has_method("load_note_skin"):
			flow_area.load_note_skin(skin_name)
		return

	if section == "Appearance" and key in [
		"randomize_block_color",
		"sync_color_across_block_type",
		"short_block_color",
		"instant_block_color",
		"long_block_color",
	]:
		_regenerate_global_random_colors()
		if flow_area:
			flow_area.refresh_note_colors()
		return

	if section == "General" and key == "display_debug_info":
		hud.set_debug_enabled(int(value) == 1)
		return

	if section == "Playback" and key == "auto_mode":
		var auto_enabled = int(value) == 1
		if flow_area:
			flow_area.auto_mode = auto_enabled
		auto_label.visible = auto_enabled
		GLogger.info("PlayView auto mode changed: %s" % ("ON" if auto_enabled else "OFF"), "PlayView")
		return

	if section == "Playback" and key == "performing_mode":
		var new_mode = int(value) == 1

		# 只在值实际改变时处理
		if new_mode == play_mode:
			return

		play_mode = new_mode
		
		if play_mode:
			# 演奏模式开启：重新应用手动控制notes标记（数据在 C# 端，经访问器读取）
			if playback_mgr and key_sequence_mgr != null and key_sequence_mgr.seq_count() > 0:
				playback_mgr.set_manual_control_from_core(key_sequence_mgr)
				GLogger.info("Performing mode ON: reapplied manual control notes (%d)" % key_sequence_mgr.manual_count(), "PlayView")
		else:
			# 演奏模式关闭：清除手动控制notes标记，恢复全自动播放
			if playback_mgr:
				playback_mgr.clear_manual_control_notes()
				GLogger.info("Performing mode OFF: cleared manual control notes", "PlayView")

func _load_debug_display_setting() -> void:
	hud.set_debug_enabled(ConfigManager.instance.get_int("General", "display_debug_info", 0) == 1)


func _load_note_skin_setting() -> void:
	# 如果 FileSystemManager 还未完成资源扫描，等待扫描完成
	if FileSystemManager.instance and not FileSystemManager.instance.resources_scanned:
		GLogger.info("Waiting for FileSystemManager to scan resources...", "PlayView")
		if not FileSystemManager.instance.resources_ready.is_connected(_on_skin_resources_ready):
			FileSystemManager.instance.resources_ready.connect(_on_skin_resources_ready)
		return
	
	_do_load_note_skin()

func _on_skin_resources_ready() -> void:
	_do_load_note_skin()

func _do_load_note_skin() -> void:
	# 从配置加载皮肤设置
	var skin_name = ConfigManager.instance.get_string("Appearance", "block_skin_preset", "旧版2 [内置]")

	# 应用皮肤
	if flow_area and flow_area.has_method("load_note_skin"):
		flow_area.load_note_skin(skin_name)
		GLogger.info("Loaded note skin: %s" % skin_name, "PlayView")

## 根据当前皮肤的 random_color 配置生成随机颜色并推送到 FlowArea
## 仅在 custom_color 主开关 + 该类型 enable_color + random_color 均开启时生成
## 必须在 flow_area.init_flow_area() 之前调用，使新音符按新颜色生成
func _regenerate_random_note_colors() -> void:
	if not flow_area:
		return
	var skin_name = ConfigManager.instance.get_string("Appearance", "block_skin_preset", "旧版2 [内置]")
	var skin_config = SkinMGR.get_skin_config(skin_name)
	if skin_config.is_empty():
		return
	var custom_color_on := false
	if skin_config.has("general"):
		custom_color_on = bool(skin_config["general"].get("custom_color", false))
	if not custom_color_on:
		# 主开关关闭，清空随机颜色（_resolve_note_colors 会回退到 WHITE）
		flow_area.set_random_colors({}, false)
		return

	var random_colors: Dictionary = {}
	for key in ["short", "instant", "long"]:
		# skin/粒子键名保持旧格式：short=点块(Block)、instant=滑块(Slide)、long=长条
		if not skin_config.has(key):
			continue
		var sec: Dictionary = skin_config[key]
		if bool(sec.get("enable_color", false)) and bool(sec.get("random_color", false)):
			# 强制饱和度 1.0：纯色相至少一个通道恒为 0，加色同色叠加不会发白，颜色也不淡
			# （饱和 <1 的粉彩色三个通道都 >0，同色光效叠加会往白里走）
			random_colors[key] = Color.from_hsv(randf(), 1.0, 1.0)
	flow_area.set_random_colors(random_colors, false)
	GLogger.info("Generated random note colors: %s" % str(random_colors.keys()), "PlayView")

## 根据全局设置（非键盘模式 + 皮肤 custom_color 关闭时生效）生成随机调色板并推送到 FlowArea
## 必须在 flow_area.init_flow_area() 之前调用，使新音符按新颜色生成
func _regenerate_global_random_colors() -> void:
	if not flow_area:
		return
	var random_on := ConfigManager.instance.get_int("Appearance", "randomize_block_color", 0) == 1
	if not random_on:
		flow_area.set_random_colors({}, true)
		return
	var unified := ConfigManager.instance.get_int("Appearance", "sync_color_across_block_type", 0) == 1
	var palette := NoteColorPalette.generate(unified)
	flow_area.set_random_colors(palette, true)
	GLogger.info("Generated global random note colors: %s" % str(palette.keys()), "PlayView")

var is_pause: bool = false:
	set(v):
		is_pause = v
		if playback_mgr:
			if is_pause:
				playback_mgr.pause()
			else:
				playback_mgr.resume()
				# 暂停期间音频钟冻结，恢复时硬锚定视觉钟，避免音符位置大跳
				_visual_time_needs_anchor = true

func show_or_hide_menu():
	if is_pause and menu.visible:
		if _game_started:
			is_pause = false
			ani.animate_fade_out(center_bg, 0.2, "_show_bg")
		ani.animate_fade_out(menu, 0.2, "_show_menu")
	else:
		_show_pause_menu()

func _show_pause_menu() -> void:
	is_pause = true
	if not center_bg.visible:
		ani.animate_fade_in(center_bg, 0.2, "_show_bg")
	ani.animate_fade_in(menu, 0.2, "_show_menu")

func _on_window_focus_exited() -> void:
	_auto_pause_on_background("window_focus_exited")

func _auto_pause_on_background(reason: String) -> void:
	if UiStatMGR.current_state != UIStateManager.UIState.PLAY_VIEW:
		return
	if playback_mgr and not playback_mgr.is_playing:
		return
	if is_pause:
		return

	_show_pause_menu()
	GLogger.info("Auto pause triggered by background event: %s" % reason, "PlayView")

func _prepare_game(midi:MidiData = current_midi) -> void:
	_game_generation += 1
	current_midi = midi
	play_result = ScoreView.ScoreData.new()
	_is_finishing_game = false
	_game_started = false
	_is_auto_mode_play = false
	_last_playback_position = -1.0
	_position_stall_frames = 0

	# 读取“播放准备动画”设置（0=关闭, 1=开启）
	var play_ready_animation: bool = ConfigManager.instance.get_int("Playback", "play_ready_animation", 1) == 1
	GLogger.info("Play ready animation: %s" % ("ON" if play_ready_animation else "OFF"), "PlayView")
	# 歌曲信息面板开始显示的时刻（遮罩期起点，用于动态计算剩余等待时长）
	var panel_start_ms := Time.get_ticks_msec()
	# 初始化显示；开启准备动画时显示歌曲信息面板
	_init_display(play_ready_animation)

	# 重置 ScoreCalculator
	if score_calc:
		score_calc.reset()
	# 生成随机颜色（若皮肤配置启用）— 必须在 init_flow_area 前完成，使新音符按新颜色生成
	_regenerate_random_note_colors()
	_regenerate_global_random_colors()
	flow_area.init_flow_area()
	_is_auto_mode_play = flow_area.auto_mode
	auto_label.visible = flow_area.auto_mode

	# 线程化预解析 MIDI：将昂贵的文件 I/O + 数据结构构建移到 worker 线程
	# 主线程在 await 期间继续渲染歌曲信息面板 + 转场动画
	if not await playback_mgr.preparse_midi_async(midi):
		push_error("Failed to preparse MIDI: " + midi.name)
	# 加载 MIDI（此时已命中解析缓存，仅做配置应用 + 后端加载）
	_load_and_convert_midi_notes(midi)

	# 确保游戏模式下不循环播放
	playback_mgr.set_loop(false)

	# 新增：从配置读取演奏模式
	var performing_mode = ConfigManager.instance.get_int("Playback", "performing_mode", 1)
	play_mode = (performing_mode == 1)
	GLogger.info("Performing mode: %s" % ("ON" if play_mode else "OFF"), "PlayView")

	# 新增：连接配置变更信号
	if not EvtBus.config_changed.is_connected(_on_config_changed):
		EvtBus.config_changed.connect(_on_config_changed)

	# 计算初始seek位置：-1000ms（固定：给予UI准备时间）- 音符下落时间（配置项）
	var note_fall_time = ConfigManager.instance.get_float("Generator", "note_fall_time", 1.5)
	var seek_position = -(1000 + note_fall_time * 1000)
	playback_mgr.seek(seek_position)
	# 视觉钟硬锚定：开局 pre-roll 从负时间起，首次 resume 对齐音频钟
	_visual_time_needs_anchor = true
	is_pause = true

	# 读取并设置音频同步阈值
	var setting_view = get_node_or_null(PathRegistry.SETTING_VIEW)
	if setting_view and setting_view.has_method("get_setting_value"):
		var sync_threshold = setting_view.get_setting_value("audio_sync_threshold")
		if sync_threshold != null:
			playback_mgr.set_sync_threshold(float(sync_threshold))
			GLogger.info("Audio sync threshold set to %.0f ms" % float(sync_threshold), "PlayView")

	# 提前启动 generate_keys 的 worker 线程（主线程筛选音符 + 后台线程跑全量 generate_keys）
	# 通常 MidiView 已触发过 generate_keys，此处命中缓存直接返回（0ms）
	# 若未命中（如跳过 MidiView 直接进 PlayView），主线程 await 等待全量生成完成后再开局，不再流式抢先
	var gen_task_id := await _start_generate_game_sequences(midi)
	if gen_task_id >= 0:
		await key_sequence_mgr.await_generate_keys(gen_task_id)

	# 解析/生成序列期间若用户已退出播放视图，立即中止后续启动流程，
	if UiStatMGR.current_state != UIStateManager.UIState.PLAY_VIEW:
		GLogger.info("Prepare aborted: left PLAY_VIEW during note generation", "PlayView")
		return

	# 全量快照：把 C# KeySequenceCore 全部序列的静态数据一次写入平行数组 + 结算总音符数
	flow_area.build_seq_data()
	_finish_playback_setup()
	GLogger.info("FlowArea prebuilt seq data = %d" % flow_area.get_sequence_count(), "PlayView")
	# 设置进度条最大值
	hud.set_progress_max(current_midi.duration_ms)

	# 歌曲信息面板显示期间预启动人声：加载 + play + 立即暂停
	# 此处主线程可阻塞（有歌曲信息面板遮罩），消除 is_pause=false 时
	# resume() 触发 start_vocal_playback 的同步加载/解码卡顿
	# 同时预热演奏模式手动音符触发路径（首次点击的一次性 JIT/通道分配成本移到开局前）
	playback_mgr.warmup_manual_path()
	# 【预热】音符预合成贴图：覆盖本局全部 (类型,颜色) 组合（含随机色/键盘交替色），
	# 使逐像素合成 + GPU 上传发生在面板遮罩期，避免游戏开始后前几个音符 spawn 帧尖峰
	var _prewarm_t0 := Time.get_ticks_usec()
	flow_area.prewarm_all_composites()
	# 【预热】粒子精灵图：首次判定 spawn 粒子时的同步 load() + GPU 上传前移到面板遮罩期
	flow_area.prewarm_spark_packs()
	GLogger.info("Prewarm done: composites+sparks in %.2fms" % [(Time.get_ticks_usec() - _prewarm_t0) / 1000.0], "PlayView")
	playback_mgr.prepare_vocal_playback()

	if play_ready_animation:
		# 面板总显示时长动态补偿：固定等 1s 改为 3s - 遮罩期内耗时操作已用时，
		# 操作耗时 ≥3s 则不再额外等待（遮罩至少已覆盖 0.2s 淡入，不会闪现即没）
		var remain_ms := 3000 - (Time.get_ticks_msec() - panel_start_ms)
		if remain_ms > 0:
			await get_tree().create_timer(remain_ms / 1000.0).timeout
		# 等待期间若用户主动呼出了暂停菜单，则不再自动淡出遮罩并开始播放，
		# 交给用户从暂停菜单手动"继续"（标记 _game_started 使"继续"等同于直接开局）
		if menu.visible:
			GLogger.info("Ready phase done but pause menu opened, skipping auto-start (awaiting user resume)", "PlayView")
			_game_started = true
			return
		await AniMGR.animate_fade_out(center_bg, 1).finished

	# 准备阶段若用户已退出播放视图（打开菜单后强退/返回），不再启动播放：
	if UiStatMGR.current_state != UIStateManager.UIState.PLAY_VIEW:
		GLogger.info("Prepare aborted: left PLAY_VIEW during ready phase", "PlayView")
		return

	# 记录游玩开始时间（用于统计游玩时长）
	_play_start_time = Time.get_ticks_msec()
	# 开始播放MIDI
	_game_started = true
	is_pause = false

## 加载MIDI（不再处理FlowArea初始化，该部分由KeySequenceManager处理）
func _load_and_convert_midi_notes(midi_data: MidiData) -> void:
	if playback_mgr == null:
		push_error("MidiPlaybackManager not available!")
		return

	# 加载MIDI
	if not playback_mgr.load_midi(midi_data):
		push_error("Failed to load MIDI for gameplay")
		return
	
	# 应用TrackView中保存的MIDI配置（音量、静音、独奏等）
	_apply_midi_runtime_config(midi_data)
	
	GLogger.info("MIDI loaded and runtime config applied", "PlayView")

## 启动游戏序列生成（主线程筛选音符 + 启动 worker 线程跑全量 generate_keys）
## 返回 worker task_id（-1 表示未启动/命中缓存/无启用音符，如缺 key_sequence_mgr 或无启用音符）
## 生成完成后经 await_generate_keys(task_id) 等待，随后由调用方 build_seq_data 快照平行数组
func _start_generate_game_sequences(midi_data: MidiData) -> int:
	if key_sequence_mgr == null:
		GLogger.warning("KeySequenceManager not available", "PlayView")
		return -1

	# 音符数据以 SOA 形式存储，parsed_notes 恒为空；改用 has_notes() 判断数据就绪
	if not midi_data.has_notes():
		GLogger.warning("No parsed notes available for key generation", "PlayView")
		key_sequence_mgr.clear_sequences()
		return -1

	# screen_width 已不进 cache_key，且 lane_area.size.x 永远是 40（Lane 节点 anchors_preset=0 不拉伸）
	# 不再调用 set_screen_size：读 lane_area.size.x 没意义，KSM 内部用默认 1920 即可
	# （仅影响 _judge_block_type 速度限制的边缘场景，FlowArea 显示位置由 viewport 宽度算）

	# 构建启用 (track, channel) 集合并筛选音符（主线程）。
	# 音符数据以 SOA 形式存储（parsed_notes 恒为空），自身已按 start_tick 升序；
	# C# 端 SaveInputGather 用 (全量 SOA 数组 + 启用索引) 装配输入，避免建 NoteEvent 对象数组。
	var enabled_pairs := midi_data.get_enabled_pairs_flat()
	var soa := midi_data.notes_soa
	if soa == null or soa.size() <= 0:
		key_sequence_mgr.clear_sequences()
		return -1
	var enabled_indices: Array
	if enabled_pairs.is_empty():
		# 空对语义取决于轨道配置是否已初始化（与 MidiListItem 一致）：
		# 已初始化 → 用户主动禁用了所有轨道（空局，清序列返回）；未初始化 → 全部启用
		if midi_data.is_track_config_initialized():
			GLogger.warning("All (track, channel) pairs disabled", "PlayView")
			key_sequence_mgr.clear_sequences()
			return -1
		enabled_indices = []
		enabled_indices.resize(soa.size())
		for i in range(soa.size()):
			enabled_indices[i] = i
	else:
		enabled_indices = midi_data.get_enabled_note_indices(enabled_pairs)

	if enabled_indices.is_empty():
		GLogger.warning("No notes in enabled (track, channel) pairs", "PlayView")
		key_sequence_mgr.clear_sequences()
		return -1

	# 启动 worker 线程跑全量 generate_keys（一次 RunGenerateGather 完成全部序列，完成后返回，
	# 不再流式抢先；命中缓存则内部直接返回 -1，此处 0ms 复用）
	# 传入 SOA 底层数组 + 启用索引：C# 在 worker 中装配合集并产出，避免建对象数组/浅拷贝
	# 显式传入 midi 自己的 timebase/bpm_timeline，不依赖/改写 MidiPlaybackManager 全局时间线字段
	# （MidiListItem 的统计生成也用同一 midi 的显式参数，二者 cache_key 一致可互相命中，
	#   cache_key = 配置指纹|midi_id+enabled_indices滚动哈希，MidiListItem 同走 KSM._build_cache_key）
	var task_id := await key_sequence_mgr.generate_keys_async(
		soa.get_raw_arrays(), enabled_indices, midi_data.id,
		midi_data.midi_timebase, midi_data.bpm_timeline
	)
	return task_id

## 全量生成完成后的收尾（应用手动分类 + 结算总音符数），仅在 _prepare_game 内调用一次
func _finish_playback_setup() -> void:
	# 分类数据由 C# KeySequenceCore 保存，经 KSM 访问器读取（manual/auto 计数）
	var manual_count := key_sequence_mgr.manual_count()
	var auto_count := key_sequence_mgr.auto_count()

	# 将真实分类提交给MidiPlaybackManager
	# 仅在演奏模式开启时下发手动控制；关闭时必须清空以恢复自动播放
	if playback_mgr:
		if play_mode:
			playback_mgr.set_manual_control_from_core(key_sequence_mgr)
			GLogger.info("[Performing ON] Submitted notes classification: %d manual, %d auto" %
				[manual_count, auto_count], "PlayView")
		else:
			playback_mgr.clear_manual_control_notes()
			GLogger.info("[Performing OFF] Cleared manual control notes: all notes will auto-play (manual=%d, auto=%d)" %
				[manual_count, auto_count], "PlayView")

	# 结算总音符数（LONG 的持续 tick 不计入）：平行数组快照完成后已确定
	var seq_total: int = flow_area.get_sequence_count()
	if score_calc:
		score_calc.total_notes = seq_total
	play_result.total_notes = seq_total
	GLogger.info("Playback setup finalized: %d game sequences" % seq_total, "PlayView")

## 从ConfigManager加载键盘和轨道相关的参数
func _load_lane_parameters() -> void:
	var config_mgr = ConfigManager.instance
	
	# 加载轨道数量（默认12）
	lane_count = config_mgr.get_int("Lane", "lane_count", 12)
	# 加载左右安全区（默认100）
	lane_padding = config_mgr.get_int("Judge", "canvas_horizontal_padding", 100)
	# 加载判定线高度（默认200）
	judge_line_offset_y = max(0, config_mgr.get_int("Judge", "judge_line_position", 200))
	
	# 加载键盘模式（0=关闭，1=开启，默认0）
	keyboard_mode = config_mgr.get_int("Lane", "keyboard_mode", 0) == 1
	
	# 加载键盘键位字符串（默认 "A,S,D,F,J,K,L,;"）
	var keyboard_keys_str = config_mgr.get_string("Lane", "keyboard_mode_keys", "A,S,D,F,J,K,L,;")
	key_map = ConfigParser.parse_keyboard_keys(keyboard_keys_str)
	# 加载键盘键位显示名称（与 key_map 对齐，空字符串=使用按键默认名）
	var keyboard_names_str = config_mgr.get_string("Lane", "keyboard_mode_display_names", "")
	key_display_names = ConfigParser.parse_keyboard_display_names(keyboard_names_str, key_map.size())

	# 加载交替轨道颜色（默认开启；仅键盘模式生效）
	keyboard_alt_color = config_mgr.get_bool("Lane", "keyboard_alt_color", true)
	keyboard_alt_color_count = max(1, config_mgr.get_int("Lane", "keyboard_alt_color_count", 2))
	keyboard_alt_colors = _parse_alt_colors(
		config_mgr.get_string("Lane", "keyboard_alt_colors", "#ff0000,#0000ff")
	)
	# 颜色数组对齐到声明的数量（不足补白，多余截断）
	while keyboard_alt_colors.size() < keyboard_alt_color_count:
		keyboard_alt_colors.append(Color.WHITE)
	keyboard_alt_colors.resize(keyboard_alt_color_count)

	# 左右间距（偶数键位时中间额外间距）
	keyboard_mode_gap = max(0, config_mgr.get_int("Lane", "keyboard_mode_gap", 0))
	# 轨道分隔线（仅键盘模式生效）
	keyboard_lane_separator = config_mgr.get_bool("Lane", "keyboard_lane_separator", false)

	GLogger.info(
		"PlayView lane parameters loaded: lane_count=%d, lane_padding=%d, keyboard_mode=%s, key_map_size=%d" % 
		[lane_count, lane_padding, str(keyboard_mode), key_map.size()],
		"PlayView"
	)
	beam_alpha = config_mgr.get_float("Lane", "flash_alpha", 0.8)
	if lane_area and lane_area.has_method("set_beam_alpha"):
		lane_area.set_beam_alpha(beam_alpha)
	var note_glow_intensity = config_mgr.get_float("Appearance", "note_glow_intensity", 0.5)
	var note_glow_size = config_mgr.get_float("Appearance", "note_glow_size", 5.0)
	if flow_area and flow_area.has_method("set_glow_params"):
		flow_area.set_glow_params(note_glow_intensity, note_glow_size)


## 处理 Lane/Judge 段配置变更（轨道数量、键位、左右安全区）
func _on_lane_config_changed(key: String, section: String, value: Variant) -> void:
	if section != "Lane" and section != "Judge":
		return
	
	var should_reinit = false

	if section == "Judge" and key == "judge_line_position":
		var new_offset : int = max(0, int(value))
		if new_offset != judge_line_offset_y:
			judge_line_offset_y = new_offset
			should_reinit = true
			if flow_area and flow_area.has_method("_apply_judge_line_position"):
				flow_area._apply_judge_line_position()
			GLogger.info("PlayView judge_line_offset_y updated: %d" % judge_line_offset_y, "PlayView")

	if section == "Judge" and key == "canvas_horizontal_padding":
		var new_lane_padding = int(value)
		if new_lane_padding != lane_padding:
			lane_padding = new_lane_padding
			should_reinit = true
			GLogger.info("PlayView lane_padding updated: %d" % lane_padding, "PlayView")
	
	match key:
		"lane_count":
			if section == "Lane":
				var new_lane_count = int(value)
				if new_lane_count != lane_count:
					lane_count = new_lane_count
					# 仅在非键盘模式时需要重初始化轨道显示
					if not keyboard_mode:
						should_reinit = true
					GLogger.info("PlayView lane_count updated: %d" % lane_count, "PlayView")
		
		"keyboard_mode":
			if section == "Lane":
				var new_mode = int(value) == 1
				if new_mode != keyboard_mode:
					keyboard_mode = new_mode
					should_reinit = true
					GLogger.info("PlayView keyboard_mode updated: %s" % str(keyboard_mode), "PlayView")
		
		"keyboard_mode_keys":
			if section == "Lane":
				var new_keys = ConfigParser.parse_keyboard_keys(str(value))
				if new_keys.size() != key_map.size() or _are_keys_different(new_keys, key_map):
					key_map = new_keys
					# 键位变化时同步重算 display_names（按新 key 数量对齐）
					key_display_names = ConfigParser.parse_keyboard_display_names(
						ConfigManager.instance.get_string("Lane", "keyboard_mode_display_names", ""),
						key_map.size()
					)
					# 仅在键盘模式时需要重初始化
					if keyboard_mode:
						should_reinit = true
					GLogger.info("PlayView keyboard_mode_keys updated: %d keys" % key_map.size(), "PlayView")

		"keyboard_mode_display_names":
			if section == "Lane":
				key_display_names = ConfigParser.parse_keyboard_display_names(str(value), key_map.size())
				# 仅在键盘模式时需要重初始化（刷新标签文本）
				if keyboard_mode:
					should_reinit = true
				GLogger.info("PlayView keyboard_mode_display_names updated: %d names" % key_display_names.size(), "PlayView")

		"keyboard_alt_color", "keyboard_alt_color_count", "keyboard_alt_colors":
			if section == "Lane":
				var old_alt_color := keyboard_alt_color
				var old_alt_count := keyboard_alt_color_count
				var old_alt_colors: Array = keyboard_alt_colors.duplicate()
				keyboard_alt_color = int(value) == 1 if key == "keyboard_alt_color" else keyboard_alt_color
				if key == "keyboard_alt_color_count":
					keyboard_alt_color_count = max(1, int(value))
				if key == "keyboard_alt_colors":
					keyboard_alt_colors = _parse_alt_colors(str(value))
					while keyboard_alt_colors.size() < keyboard_alt_color_count:
						keyboard_alt_colors.append(Color.WHITE)
					keyboard_alt_colors.resize(keyboard_alt_color_count)
				# 仅键盘模式且颜色配置有变化时重初始化（刷新音符/光束颜色）
				if keyboard_mode and (keyboard_alt_color != old_alt_color or keyboard_alt_color_count != old_alt_count or keyboard_alt_colors != old_alt_colors):
					should_reinit = true
				GLogger.info("PlayView keyboard_alt_color updated: enabled=%s count=%d colors=%s" %
					[str(keyboard_alt_color), keyboard_alt_color_count, str(keyboard_alt_colors)], "PlayView")

		"keyboard_mode_gap":
			if section == "Lane":
				var new_gap: int = max(0, int(value))
				if new_gap != keyboard_mode_gap:
					keyboard_mode_gap = new_gap
					should_reinit = true
					GLogger.info("PlayView keyboard_mode_gap updated: %d" % keyboard_mode_gap, "PlayView")

		"keyboard_lane_separator":
			if section == "Lane":
				var new_sep := int(value) == 1
				if new_sep != keyboard_lane_separator:
					keyboard_lane_separator = new_sep
					if keyboard_mode:
						should_reinit = true
					GLogger.info("PlayView keyboard_lane_separator updated: %s" % str(keyboard_lane_separator), "PlayView")

		"flash_alpha":
			if section == "Lane":
				beam_alpha = float(value)
				if lane_area and lane_area.has_method("set_beam_alpha"):
					lane_area.set_beam_alpha(beam_alpha)
	
	if should_reinit:
		# 仅在游戏未开始或者允许的情况下重新初始化轨道
		if not (playback_mgr and playback_mgr.is_playing):
			_reinit_lane_display()

## 比较两个KeyCode数组是否不同
func _are_keys_different(keys1: Array[Key], keys2: Array[Key]) -> bool:
	if keys1.size() != keys2.size():
		return true
	for i in range(keys1.size()):
		if keys1[i] != keys2[i]:
			return true
	return false

## 重新初始化轨道显示
## 清空旧轨道并根据当前配置重新初始化
func _reinit_lane_display() -> void:
	if flow_area == null or lane_area == null:
		return
	
	# 重新初始化流动区域
	flow_area.init_flow_area()
	
	# 重新初始化轨道光效（lane_area 已经是 LaneEffect 实例）
	lane_area.init_beam(get_lane_count(), self)
	lane_area.set_beam_alpha(beam_alpha)
	
	# 如果启用了键盘模式，显示键位提示
	if keyboard_mode and key_map.size() > 0:
		lane_area.init_key_display(key_map, key_display_names)
	
	GLogger.info("PlayView lane display reinitialized", "PlayView")

## 从配置加载演奏模式设置
func _load_play_mode_setting() -> void:
	var performing_mode = ConfigManager.instance.get_int("Playback", "performing_mode", 1)
	play_mode = (performing_mode == 1)
	GLogger.info("PlayView play mode: %s" % ("ON" if play_mode else "OFF"), "PlayView")
	# 蓝牙输出时自动关闭演奏模式（高延迟下演奏手感不佳）；
	# 仅当局会话生效（不覆写全局 performing_mode 配置），玩家可在游戏中手动重开
	if play_mode and AudioBtDetector.is_bluetooth_output() \
			and ConfigManager.instance.get_int("Gameplay", "bt_auto_disable_performing_mode", 1) == 1:
		play_mode = false
		GLogger.info("Performing mode auto-disabled: bluetooth audio output detected", "PlayView")

## 应用TrackView中保存的MIDI运行时配置（音量、静音、独奏等）
func _apply_midi_runtime_config(midi_data: MidiData) -> void:
	if playback_mgr == null:
		return
	
	# 应用全局音量（映射系数见 MidiPlaybackManager.MIDI_VOLUME_GAIN: 0.5=+6dB, 1.0=+12dB）
	# 默认值(0.5)回退全局 default_midi_volume，与 TrackView 保持一致
	playback_mgr.apply_ui_midi_volume(playback_mgr.get_effective_midi_volume(midi_data.midi_volume))
	
	# 应用轨道-通道的静音状态
	# track_channel_mute_state: {track_idx: {channel: bool}}
	if not midi_data.track_channel_mute_state.is_empty():
		for track_idx in midi_data.track_channel_mute_state.keys():
			var channels = midi_data.track_channel_mute_state[track_idx]
			if channels is Dictionary:
				for channel in channels.keys():
					var is_muted = channels[channel]
					playback_mgr.set_track_channel_mute(track_idx, channel, is_muted)
	
	# 应用独奏状态（Additive Solo，与 TrackView._apply_solo_state 一致）：
	# - 独奏轨保持其持久化静音状态（上面已按 track_channel_mute_state 应用）
	# - 非独奏轨运行时静音（不写入 MidiData，避免污染持久化配置）
	# solo_pairs: {"track:channel": true}
	if not midi_data.solo_pairs.is_empty():
		var seen_pairs := {}
		# SOA 路径：只枚举 (track,channel) 对，不建全量 NoteEvent（current_notes 恒为空）
		var soa := midi_data.notes_soa
		if soa != null and soa.size() > 0:
			for i in range(soa.size()):
				var solo_key := "%d:%d" % [soa.track(i), soa.channel(i)]
				if seen_pairs.has(solo_key):
					continue
				seen_pairs[solo_key] = true
				if not midi_data.solo_pairs.has(solo_key):
					playback_mgr.set_track_channel_mute_runtime(soa.track(i), soa.channel(i), true)
		else:
			# 兼容回退：无 SOA 时遍历对象列表
			for note in playback_mgr.current_notes:
				var solo_key := "%d:%d" % [note.track_index, note.channel]
				if seen_pairs.has(solo_key):
					continue
				seen_pairs[solo_key] = true
				if not midi_data.solo_pairs.has(solo_key):
					playback_mgr.set_track_channel_mute_runtime(note.track_index, note.channel, true)

	# 应用音轨-通道的音量调整
	# track_channel_volume_config: {track_idx: {channel: volume_value}}（值为线性 0.0-1.0）
	if not midi_data.track_channel_volume_config.is_empty():
		for track_idx in midi_data.track_channel_volume_config.keys():
			var channels = midi_data.track_channel_volume_config[track_idx]
			if channels is Dictionary:
				for channel in channels.keys():
					var volume = channels[channel]
					# 设置通道音量（线性值直接透传，勿再除以100）
					playback_mgr.set_track_channel_volume(int(track_idx), int(channel), float(volume))
	
	# 乐器覆盖已在 MidiPlaybackManager.load_midi 中应用（MidiPlaybackManager.gd:372），
	# 此处不再重复设置（原 set_track_channel_program 调用不存在，属死代码，TMX-023）
	
	# 应用人声偏移量
	playback_mgr.set_vocal_offset_ms(midi_data.vocal_offset_ms)
	
	GLogger.info("MIDI runtime config applied: volume=%d%%, mute_states=%d, solo_pairs=%d" %
		[int(round(playback_mgr.get_effective_midi_volume(midi_data.midi_volume) * 100.0)), midi_data.track_channel_mute_state.size(), midi_data.solo_pairs.size()], "PlayView")

## 游戏结束回调
func _on_game_finished() -> void:
	if _is_finishing_game:
		return
	_is_finishing_game = true
	# 记录本次游戏结束开始时的代次，等待期间若用户重试（ _prepare_game 自增代次）则本协程作废
	var start_generation := _game_generation

	GLogger.info("Game finished!", "PlayView")

	# 停止MIDI播放但不暂停FlowArea，让剩余音符继续自然下落
	if playback_mgr:
		playback_mgr.stop()

	# 等待所有音符自然消除（被判定或落出屏幕），最长等待10秒
	var safety_timer := get_tree().create_timer(10.0)
	while flow_area.has_active_notes():
		if safety_timer.time_left <= 0.0:
			break
		await get_tree().process_frame

	# 音符全部消除后，从 ScoreCalculator 拿最终快照（包含自然Miss）
	var snap = score_calc.get_snapshot()
	# 记录本次游玩实际耗时（毫秒），用于服务端统计
	snap["play_duration_ms"] = Time.get_ticks_msec() - _play_start_time
	play_result.score = snap["total_score"]
	play_result.max_combo = snap["max_combo"]
	play_result.accuracy = snap["accuracy"]
	play_result.performance_point = snap["pp"]
	play_result.count["Perfect"] = snap["judge_counts"][ScoreCalculator.Judgment.PERFECT]
	play_result.count["Great"] = snap["judge_counts"][ScoreCalculator.Judgment.GREAT]
	play_result.count["Good"] = snap["judge_counts"][ScoreCalculator.Judgment.GOOD]
	play_result.count["Bad"] = snap["judge_counts"][ScoreCalculator.Judgment.BAD]
	play_result.count["Miss"] = snap["judge_counts"][ScoreCalculator.Judgment.MISS]
	play_result.early_count = snap["early_count"]
	play_result.late_count = snap["late_count"]

	# 进入结算界面（资源清理已统一由 _on_state_changed 处理）
	await get_tree().create_timer(1).timeout
	if UiStatMGR.current_state != UIStateManager.UIState.PLAY_VIEW or _game_generation != start_generation:
		return
	UiStatMGR.change_state(UIStateManager.UIState.SCORE_VIEW, false)
	get_node(PathRegistry.SCORE_VIEW).set_display(play_result, current_midi, _is_auto_mode_play)
	# 异步上传成绩（由 ScoreView 展示结果与重试按钮，不阻塞结算界面）
	if not _is_auto_mode_play:
		get_node(PathRegistry.SCORE_VIEW).request_upload(current_midi, snap)

## 异步上传成绩（fire-and-forget，失败仅记日志）
func _upload_score_async(midi: MidiData, snapshot: Dictionary) -> void:
	if midi == null or midi.file_hash.is_empty():
		GLogger.warning("Score upload skipped: midi is null or file_hash empty (midi=%s hash=%s)" % [str(midi), str(midi.file_hash) if midi else "null"], "PlayView")
		return
	if _is_auto_mode_play:
		GLogger.info("Score upload skipped: auto mode enabled (midi=%s)" % midi.file_hash, "PlayView")
		return
	# 本地成绩：无论在线与否都记录（中途退出 W 由 save_local_score 内部过滤）
	if ScoreManager.instance:
		ScoreManager.instance.save_local_score(midi, snapshot)
	# 手动上传模式：不自动上传（结算页改由玩家手动触发；中途退出不做自动补传）
	if ConfigManager.instance != null and ConfigManager.instance.get_int("General", "auto_upload_score", 1) != 1:
		GLogger.info("Score upload skipped: manual mode enabled (midi=%s)" % midi.file_hash, "PlayView")
		return
	if NetManager.instance == null or not NetManager.instance.is_online:
		GLogger.warning("Score upload skipped: offline (NetManager=%s is_online=%s)" % [str(NetManager.instance), str(NetManager.instance.is_online) if NetManager.instance else "null"], "PlayView")
		return
	if ScoreManager.instance == null:
		GLogger.warning("Score upload skipped: ScoreManager not ready", "PlayView")
		return
	GLogger.info("Score upload starting: midi=%s pp=%s" % [midi.file_hash, str(snapshot.get("pp", 0))], "PlayView")
	var result = await ScoreManager.instance.upload_score(midi, snapshot)
	if result.get("ok", false):
		GLogger.info("Score uploaded: midi=%s pp=%s" % [midi.file_hash, str(snapshot.get("pp", 0))], "PlayView")
		# 通知个人信息页刷新统计
		EvtBus.score_uploaded.emit(midi.file_hash)
	elif result.get("skipped", false):
		GLogger.info("Score upload skipped: chart not found on server (midi=%s)" % midi.file_hash, "PlayView")
	else:
		GLogger.warning("Score upload failed: %s (status=%s)" % [result.get("error", "unknown"), str(result.get("status", 0))], "PlayView")

## 退出游戏（中途退出）
func _on_quit_pressed() -> void:
	# 中途退出：上传成绩（评级强制为 W），等待上传完成后再返回，确保排行榜刷新时数据已写入
	await _upload_score_on_quit()
	# 返回上级界面（_on_state_changed 统一处理 MIDI 停止、音符回收、背景清理等）
	UiStatMGR.go_back()

## 中途退出时上传成绩：评级强制 W，cleared=false
## await 此方法可等待上传完成
func _upload_score_on_quit() -> void:
	if current_midi == null or current_midi.file_hash.is_empty():
		return
	if NetManager.instance == null or not NetManager.instance.is_online:
		return
	if ScoreManager.instance == null:
		return
	if score_calc == null:
		return
	var snap = score_calc.get_snapshot()
	# 强制评级为 W（中途退出），服务端据此排序到最后并允许完成记录覆盖
	snap["rank"] = "W"
	# 记录本次游玩实际耗时（毫秒），W 评级时长仍计入统计
	snap["play_duration_ms"] = Time.get_ticks_msec() - _play_start_time
	await _upload_score_async(current_midi, snap)

# 初始化分数等内容的显示
func _init_display(show_ready_animation: bool = true):
	_is_finishing_game = false
	hud.init_display()

	# 设置歌曲信息（封面只加载一次，同时传给信息面板和背景）
	var cover_texture = FileSystemManager.instance.get_cover_by_midiData(current_midi)
	var has_custom_cover := bg_ctrl.has_cover_for_current_midi(current_midi)
	if cover_texture:
		cover.texture = cover_texture
	bg_ctrl.apply_background(cover_texture, has_custom_cover, current_midi)

	if show_ready_animation:
		ani.animate_fade_in(center_bg, 0.2, "_show_bg")
	album.set_scroll_text(current_midi.album_name if not current_midi.album_name.is_empty() else current_midi.artist_name)
	song.set_scroll_text(current_midi.song_name)
	artist.set_scroll_text(current_midi.author_name if current_midi.author_name else "Unknow")
	var s := int(current_midi.duration_ms / 1000.0)
	@warning_ignore("integer_division")
	midi_duration.text = "%02d:%02d" % [s / 60, s % 60]
	midi_name.set_scroll_text(current_midi.name)
	midi_author.set_scroll_text(current_midi.artist_name)

	# 显示当前选中的难度预设
	var difficulty_id := ConfigManager.instance.get_int(DIFFICULTY_CFG_SECTION, DIFFICULTY_CFG_KEY, 1)
	if difficulty_id >= 0 and difficulty_id < DIFFICULTY_NAMES.size():
		difficulty.text = DIFFICULTY_NAMES[difficulty_id]

	menu.visible = false
	song_info.visible = true

	center_bg.visible = show_ready_animation
	is_pause = true
	
	# 恢复flow_area显示
	flow_area.visible = true

	_init_lane_display()

	auto_label.visible = flow_area.auto_mode


func _init_lane_display():
	# 窗口大小变化时重新计算音符尺寸
	if flow_area and flow_area.has_method("_recalculate_note_dimensions"):
		flow_area._recalculate_note_dimensions()
	lane_area.init_beam(get_lane_count(), self)
	lane_area.set_beam_alpha(beam_alpha)
	if keyboard_mode:
		lane_area.init_key_display(key_map, key_display_names)

# ---- 判定回调（计分数据源留在 PlayView，展示委托 HUD） ----

func _on_note_judged(result: String, offset: String, block_type: int, timing_sec: float, signed_offset_sec: float):
	# 委托 ScoreCalculator 计算（数据源，逐判定实时）
	var judgment = ScoreCalculator.Judgment.MISS
	match result:
		"Perfect": judgment = ScoreCalculator.Judgment.PERFECT
		"Great":   judgment = ScoreCalculator.Judgment.GREAT
		"Good":    judgment = ScoreCalculator.Judgment.GOOD
		"Bad":     judgment = ScoreCalculator.Judgment.BAD
		"Miss":    judgment = ScoreCalculator.Judgment.MISS

	var snap = score_calc.record_judgment(judgment, block_type, timing_sec, signed_offset_sec)
	hud.on_note_judged(result, offset, snap)

## LONG 持续 tick 加分（已委托 ScoreCalculator）
func _on_long_holding(long_instance_id: int):
	var snap = score_calc.record_long_sustain(ScoreCalculator.Judgment.PERFECT, long_instance_id)
	hud.on_note_judged("Perfect", "", snap, true)

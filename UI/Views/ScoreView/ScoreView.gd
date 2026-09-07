extends Control

class_name ScoreView

# 数据区
@onready var c: Control = $Bottom/skew/C
@onready var data_box: VBoxContainer = $Bottom/skew/C/Data

# 歌曲信息区
@onready var cover: TextureRect = $Bottom/skew/C/SongInfo/PanelContainer/TextureRect
@onready var album_label: Label = $Bottom/skew/C/SongInfo/Info/album
@onready var song_label: Label = $Bottom/skew/C/SongInfo/Info/song
@onready var midi_name_label: Label = $Bottom/skew/C/SongInfo/Info/midiName
@onready var midi_author_label: Label = $Bottom/skew/C/SongInfo/Info/midiAuthor

# 标志区
@onready var auto_mode_flag: Label = $Bottom/skew/C/Flags/AutoMode
@onready var all_perfect_flag: Label = $Bottom/skew/C/Flags/AllPerfect
@onready var full_combo_flag: Label = $Bottom/skew/C/Flags/FullCombo

@onready var rank: Label = $Rank
@onready var accuracy: Label = $Accuracy
@onready var score: Label = $Score/score
@onready var pp: Label = $Score/score/pp

# 个人信息区
@onready var avator: TextureRect = $LevelingProgress/Panel/TextureRect
@onready var name_label: Label = $LevelingProgress/Data/name
@onready var lvl_label: Label = $LevelingProgress/Data/level
@onready var pp_label: Label = $LevelingProgress/Data/level/pp
@onready var lvl_exp_progress: ProgressBar = $LevelingProgress/Data/ProgressBar

# 图片
@onready var bg: TextureRect = $BackGround
@onready var chara: TextureRect = $Chara

# 动画相关
@onready var bottom: Panel = $Bottom
@onready var info: Panel = $LevelingProgress
@onready var score_panel: Panel = $Score

# 成绩上传状态
@onready var upload_state: Label = $UploadState
@onready var retry_btn: Button = $UploadState/RetryBtn

# 待上传/重试的成绩数据
var _upload_midi: MidiData = null
var _upload_snapshot: Dictionary = {}
var _upload_tween: Tween = null
# 是否已因上传成功弹出玩家等级面板（避免入场动画覆盖已弹出的面板）
var _level_panel_shown: bool = false
# 页面入场动画是否已播放完毕（上传成功后需等它播完再弹等级面板）
var _entry_animation_done: bool = false
# 手动上传模式：是否正等待玩家点击上传
var _manual_pending: bool = false
# 上传代次：每次 set_display 递增，用于丢弃上一次未完成上传的回调结果
var _upload_generation: int = 0
var _entry_generation: int = 0
var _entry_animation_running: bool = false
var _portrait: DynamicPortrait

class ScoreData:
	## 由 ScoreCalculator 填充的最终数据（纯数据容器，不含计算逻辑）
	var accuracy: float = 1.0
	var performance_point: float = 0.0
	var max_combo: int = 0
	var total_notes: int = 0
	var score: int = 0
	var count: Dictionary = {
		"Perfect": 0,
		"Great": 0,
		"Good": 0,
		"Bad": 0,
		"Miss": 0
	}
	var early_count: int = 0
	var late_count: int = 0

	## 评级 - 委托 ScoreCalculator（唯一计分真源）
	func get_rank() -> String:
		if ScoreCalculator.instance:
			return ScoreCalculator.instance.get_rank()
		# 回退：使用本地 accuracy 按阈值查找
		for threshold in ScoreCalculator.RANK_THRESHOLDS:
			if accuracy >= threshold[0]:
				return threshold[1]
		return "F"

	func get_formated_score() -> String:
		var str_num = str(score)
		var regex = RegEx.new()
		regex.compile("(\\d)(?=(\\d{3})+(?!\\d))")
		return regex.sub(str_num, "$1,", true)

	func get_accuracy() -> String:
		return "%0.2f%%" % (accuracy * 100)

	func get_pp() -> String:
		return "%0.2fpp" % performance_point

func _ready() -> void:
	_portrait = DynamicPortrait.new()
	_portrait.message_top_ratio = 0.43
	chara.add_child(_portrait)
	_portrait.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	chara.self_modulate.a = 0.0
	chara.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiStatMGR.state_changed.connect(_on_state_changed)
	animate(false)

	# 监听 PlayerInfoContent 统计刷新信号，成绩上传后自动同步玩家信息
	_connect_stats_refreshed()

	# 手动上传模式下点击提示触发上传
	upload_state.mouse_filter = Control.MOUSE_FILTER_STOP
	upload_state.gui_input.connect(_on_upload_state_gui_input)

	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()

## 应用主题色（由 ThemeManager 广播调用 + _ready 首次自调）
func apply_theme() -> void:
	# LevelingProgress — 透明 primary_dark
	if info:
		var sb := info.get_theme_stylebox("panel")
		if sb is StyleBoxFlat:
			var a = sb.bg_color.a
			var pd := ThemeMGR.get_color("primary_dark")
			sb.bg_color = Color(pd.r, pd.g, pd.b, a)

func _exit_tree() -> void:
	_cleanup()
	AniMGR.stop_tween("sv_exit")
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)
	_disconnect_stats_refreshed()

## 连接 PlayerInfoContent 的 stats_refreshed 信号
func _connect_stats_refreshed() -> void:
	var pic := _get_player_info_content()
	if pic and not pic.stats_refreshed.is_connected(_on_stats_refreshed):
		pic.stats_refreshed.connect(_on_stats_refreshed)

## 断开 PlayerInfoContent 的 stats_refreshed 信号
func _disconnect_stats_refreshed() -> void:
	var pic := _get_player_info_content()
	if pic and pic.stats_refreshed.is_connected(_on_stats_refreshed):
		pic.stats_refreshed.disconnect(_on_stats_refreshed)

## 获取 PlayerInfoContent 节点（可能在不同路径下）
func _get_player_info_content() -> PlayerInfoContent:
	var node = get_node_or_null(PathRegistry.PLAYER_INFO_TAB_C)
	if node:
		return node as PlayerInfoContent
	return null

## 统计刷新回调：重新同步玩家信息（头像、名称、等级、进度条）
func _on_stats_refreshed() -> void:
	_update_player_info()

func _on_state_changed(old_state: UIStateManager.UIState, new_state: UIStateManager.UIState) -> void:
	# 退出 SCORE_VIEW 时停止循环动画，节省 CPU
	if old_state == UIStateManager.UIState.SCORE_VIEW and new_state != UIStateManager.UIState.SCORE_VIEW:
		_cleanup()

## 释放视图内部资源（循环动画 Tween），保留节点壳
func _cleanup() -> void:
	_entry_generation += 1
	_upload_generation += 1
	_entry_animation_running = false
	_entry_animation_done = false
	for tween_id in ["sv_bg", "sv_score", "sv_bottom", "sv_rank", "sv_acc", "sv_chara", "sv_upload_state"]:
		AniMGR.stop_tween(tween_id)
	if is_instance_valid(_portrait):
		_portrait.set_active(false)
	_kill_loop_ani()
	_kill_pp_tween()
	if _upload_tween:
		_upload_tween.kill()
		_upload_tween = null

func set_display(result: ScoreData, midi: MidiData = null, is_auto: bool = false):
	var restart_entry := _entry_animation_running or _entry_animation_done
	_cleanup()
	AniMGR.stop_tween("sv_exit")
	var final_rank := result.get_rank()
	# 判定数据
	data_box.get_node("Hbox/PerfectCtn").text = str(result.count.Perfect)
	data_box.get_node("Hbox/GreatCtn").text = str(result.count.Great)
	data_box.get_node("Hbox/GoodCtn").text = str(result.count.Good)
	data_box.get_node("Hbox/BadCtn").text = str(result.count.Bad)
	data_box.get_node("Hbox/MissCtn").text = str(result.count.Miss)

	data_box.get_node("HBox1/EarlyCtn").text = str(result.early_count)
	data_box.get_node("HBox1/LateCtn").text = str(result.late_count)
	data_box.get_node("HBox1/MaxCombo").text = "%d/%d" % [result.max_combo, result.total_notes]

	rank.text = final_rank
	accuracy.text = result.get_accuracy()
	score.text = result.get_formated_score()
	pp.text = result.get_pp()

	# 立绘：按评级切换人物表情
	_update_chara_art(final_rank)

	# 歌曲信息（专辑/歌名/Midi名/Midi作者/难度）
	_update_song_info(midi)

	# 旗帜（AUTO / AP / FC）
	_update_flags(result, is_auto)

	# 确保统计刷新信号已连接（_ready 时可能 PlayerInfoContent 尚未就绪）
	_connect_stats_refreshed()
	# 同步玩家信息（头像、名称、等级、进度条）
	_update_player_info()

	# 自动模式不尝试上传成绩，隐藏上传状态提示
	upload_state.visible = not is_auto
	# 新的一局，重置玩家等级面板弹出标志与入场动画状态
	_level_panel_shown = false
	_entry_animation_done = false
	# 新一局：递增上传代次，使上一次未完成上传的回调结果失效
	_upload_generation += 1
	if restart_entry and UiStatMGR.current_state == UIStateManager.UIState.SCORE_VIEW:
		animate()

## 按评级合成并切换人物立绘（人物未就绪或合成失败时静默跳过，保留原立绘）
func _update_chara_art(final_rank: String) -> void:
	var chara_key := CharaMGR.get_current_chara_key()
	chara.texture = CharaMGR.get_portrait(chara_key, CharaMGR.get_rating_emotion(chara_key, final_rank))
	_portrait.show_result(chara_key, final_rank)

## 填充歌曲信息（来自本次游玩的 MidiData，与 PlayView 信息面板保持一致）
func _update_song_info(midi: MidiData) -> void:
	if midi == null:
		return
	cover.texture = FileSystemManager.instance.get_cover_by_midiData(midi)
	album_label.set_scroll_text(midi.album_name if not midi.album_name.is_empty() else midi.artist_name)
	song_label.set_scroll_text(midi.song_name)
	midi_name_label.set_scroll_text(midi.name)
	midi_author_label.set_scroll_text(midi.artist_name)

## 根据 AP / FC / AUTO 设置旗帜节点可见性
func _update_flags(result: ScoreData, is_auto: bool) -> void:
	auto_mode_flag.visible = is_auto
	# AP：所有音符均为 Perfect（其余判定计数为零）
	var is_all_perfect : bool = result.count.Great == 0 and result.count.Good == 0 \
		and result.count.Bad == 0 and result.count.Miss == 0
	all_perfect_flag.visible = is_all_perfect
	# FC：无 Miss（连击无断）
	full_combo_flag.visible = result.count.Miss == 0

## 从 PlayerInfoContent 同步玩家信息（头像、名称、等级、进度条）
## 在 set_display 后调用，确保结算界面显示最新玩家状态
## 也在 stats_refreshed 信号回调中调用，成绩上传后自动刷新（此时 pp 变化触发上涨动画）
func _update_player_info() -> void:
	_pic = _get_player_info_content()
	if _pic == null:
		return
	# 头像
	avator.texture = _pic.mini_avatar_rect.texture
	# 名称
	var player_data: Dictionary = _pic.get_player_data()
	name_label.text = player_data.display_name if not player_data.display_name.is_empty() else player_data.name
	# PP 上涨动画：进度条/等级/PP 标签随数值变化实时更新
	_animate_pp_to(player_data.pp)

func _on_like_btn_pressed():
	pass

func _on_dislike_btn_pressed():
	pass

func _on_love_btn_pressed():
	pass

############################# 动画 ###############################
@onready var ani: AnimationManager = AniMGR
var _loop_ani_rank: Tween = null

# PP 上涨动画状态
var _pic: PlayerInfoContent = null
var _pp_displayed: float = -1.0  # 当前已显示的 pp（-1 表示尚未初始化）
var _pp_tween: Tween = null

## 是否已登录（未登录或在线模式关闭时不播放 LevelingProgress 出现动画，也不做上涨动画）
func _is_logged_in() -> bool:
	if AuthManager.instance == null or not AuthManager.instance.is_logged_in:
		return false
	# 在线模式关闭时视为未登录（临时关闭后不展示玩家等级面板）
	if NetManager.instance == null or NetManager.instance.connect_state == NetManager.ConnectState.OFFLINE_MODE:
		return false
	return true

func _kill_loop_ani():
	AniMGR.stop_tween("score_loop_rank")
	if _loop_ani_rank:
		_loop_ani_rank.kill()
		_loop_ani_rank = null

## 终止 PP 上涨动画
func _kill_pp_tween() -> void:
	AniMGR.stop_tween("sv_pp_%d" % get_instance_id())
	if _pp_tween:
		_pp_tween.kill()
		_pp_tween = null

## PP 数值上涨动画：把当前显示的 pp 缓动到目标值，期间实时更新等级/进度条/PP 标签
func _animate_pp_to(target_pp: float) -> void:
	# 终止之前未完成的动画（含延迟期），避免并发调用/打断导致重播
	if _pp_tween:
		_pp_tween.kill()
		_pp_tween = null
	var from_pp := _pp_displayed if _pp_displayed >= 0.0 else target_pp
	if absf(from_pp - target_pp) < 0.001:
		_set_pp_display(target_pp)
		return
	# 延迟并入 tween，立即赋值，重入时可取消掉未完成的延迟并从中断处续播
	_pp_tween = AniMGR.create_managed_tween(self, "sv_pp_%d" % get_instance_id())
	_pp_tween.set_trans(Tween.TRANS_CUBIC)
	_pp_tween.set_ease(Tween.EASE_OUT)
	_pp_tween.tween_interval(1.0)
	_pp_tween.tween_method(_set_pp_display, from_pp, target_pp, 1.5)

## 按指定 pp 同步刷新等级/进度条/PP 标签（供上涨动画逐帧调用，也可直接设置）
func _set_pp_display(current_pp: float) -> void:
	_pp_displayed = current_pp
	var lvl := 0
	var lvl_progress := 0.0
	if _pic:
		lvl = _pic.calc_level(current_pp)
		lvl_progress = _pic.calc_level_progress(current_pp, lvl) * 100.0
	lvl_label.text = "Lv%d" % lvl
	lvl_exp_progress.value = lvl_progress
	pp_label.text = "%.2fpp" % current_pp

func _play_loop_ani():
	_kill_loop_ani()
	_loop_ani_rank = AniMGR.create_managed_tween(self, "score_loop_rank")

	_loop_ani_rank.set_loops()

	_loop_ani_rank.tween_property(rank, "offset_transform_scale", Vector2.ONE*0.99, 1)
	_loop_ani_rank.tween_property(rank, "offset_transform_scale", Vector2.ONE*1.01, 1)

	_portrait.set_active(true)

func animate(ani_in: bool = true):
	if not ani_in:
		# 整页缩放淡出
		_cleanup()
		return ani.animate_fade_scale_out(self, Vector2.ONE * 0.8, 0.2, "sv_exit")

	if _entry_animation_done or _entry_animation_running:
		return

	AniMGR.stop_tween("sv_exit")
	_entry_generation += 1
	var generation := _entry_generation
	_entry_animation_running = true
	_entry_animation_done = false
	# 复位整页状态（上次退出可能已缩放淡出隐藏）
	visible = true
	modulate.a = 1.0
	offset_transform_position = Vector2.ZERO
	offset_transform_scale = Vector2.ONE
	# LevelingProgress 不在进入结算时弹出（上传成功后由 _show_level_panel_on_upload_success 触发）
	if not _level_panel_shown:
		info.visible = false
		info.offset_transform_position = Vector2(-info.size.x, 0)

	# 前置隐藏并放置到各自起始偏移，避免轮到它们之前已在目标位置显示
	_place_staged_node(bg, Vector2.ZERO, Vector2.ONE * 0.8)
	_place_staged_node(score_panel, Vector2(-100, 0), Vector2.ONE)
	_place_staged_node(bottom, Vector2(0, 150), Vector2.ONE)
	_place_staged_node(rank, Vector2(0, 150), Vector2.ONE)
	_place_staged_node(accuracy, Vector2(0, 100), Vector2.ONE)
	_place_staged_node(chara, Vector2(0, 150), Vector2.ONE)

	# 第 1 阶段：背景从 0.8 原地缩放淡入（外围按钮入场沿用原有逻辑）
	ani.animate_fade_scale_in(bg, Vector2.ONE * 0.8, 0.35, "sv_bg")
	await get_tree().create_timer(0.35).timeout
	if not _is_current_entry(generation):
		return

	# 第 2 阶段：Score 左滑、Bottom 上滑淡入
	ani.animate_fade_slide_in(score_panel, Vector2(-100, 0), 0.4, "sv_score")
	ani.animate_fade_slide_in(bottom, Vector2(0, 150), 0.4, "sv_bottom")
	await get_tree().create_timer(0.4).timeout
	if not _is_current_entry(generation):
		return

	# 第 3 阶段：Rank / Accuracy / Chara 上滑淡入（Accuracy 时长略短）
	ani.animate_fade_slide_in(rank, Vector2(0, 150), 0.55, "sv_rank")
	ani.animate_fade_slide_in(chara, Vector2(0, 150), 0.4, "sv_chara")
	ani.animate_fade_slide_in(accuracy, Vector2(0, 100), 0.3, "sv_acc")
	await get_tree().create_timer(0.4).timeout
	if not _is_current_entry(generation):
		return

	_entry_animation_running = false
	_entry_animation_done = true
	_play_loop_ani()

func _is_current_entry(generation: int) -> bool:
	return is_inside_tree() and generation == _entry_generation and _entry_animation_running \
		and UiStatMGR.current_state == UIStateManager.UIState.SCORE_VIEW

## 前置放置动画起始状态（隐藏 + 缩放 + 偏移），供分阶段入场前各组件归位
func _place_staged_node(node: Control, from_offset: Vector2, from_scale: Vector2) -> void:
	node.offset_transform_enabled = true
	node.offset_transform_position = from_offset
	node.offset_transform_scale = from_scale
	node.modulate.a = 0.0

## 由 PlayView 在进入结算界面后调用，异步上传成绩并展示结果/重试按钮
func request_upload(midi: MidiData, snapshot: Dictionary) -> void:
	_upload_midi = midi
	_upload_snapshot = snapshot
	_manual_pending = false
	if _is_auto_upload_enabled():
		_do_upload_score()
	else:
		# 手动上传模式：仅在线时提示点击上传，点击后才触发上传
		if NetManager.instance != null and NetManager.instance.connect_state != NetManager.ConnectState.OFFLINE_MODE:
			_manual_pending = true
			_show_upload_slide()
			upload_state.text = "点击此处上传成绩"
			retry_btn.visible = false
		else:
			upload_state.visible = false

## 是否自动上传成绩（读配置，默认开启）
func _is_auto_upload_enabled() -> bool:
	if ConfigManager.instance == null:
		return true
	return ConfigManager.instance.get_int("General", "auto_upload_score", 1) == 1

## 点击上传提示（手动上传模式）
func _on_upload_state_gui_input(event: InputEvent) -> void:
	if not _manual_pending:
		return
	var pressed := false
	if event is InputEventMouseButton:
		pressed = event.pressed and event.button_index == MOUSE_BUTTON_LEFT
	elif event is InputEventScreenTouch:
		pressed = event.pressed
	if pressed:
		_manual_pending = false
		_do_upload_score()

## 展示上传状态并从右侧 100px 滑入淡入
func _show_upload_slide() -> void:
	upload_state.visible = true
	if _upload_tween:
		_upload_tween.kill()
		_upload_tween = null
	_upload_tween = ani.animate_fade_slide_in(upload_state, Vector2(100, 0), 0.3, "sv_upload_state")

## 服务端没有该 MIDI 时属于正常的在线不收录场景，不向玩家展示失败状态。
func _hide_upload_state() -> void:
	_manual_pending = false
	retry_btn.visible = false
	upload_state.visible = false
	if _upload_tween:
		_upload_tween.kill()
		_upload_tween = null

## 执行成绩上传并更新上传状态提示（支持重试复用）
func _do_upload_score() -> void:
	_manual_pending = false
	var midi := _upload_midi
	if midi == null or midi.file_hash.is_empty():
		# 无有效成绩，不展示上传状态
		upload_state.visible = false
		return
	# 本地成绩记录（无论上传成败都保留）
	if ScoreManager.instance:
		ScoreManager.instance.save_local_score(midi, _upload_snapshot)
	# 仅在线模式关闭时才不展示/不尝试上传
	# （连接失败也尝试上传，从而展示失败提示与重试按钮）
	if NetManager.instance == null or NetManager.instance.connect_state == NetManager.ConnectState.OFFLINE_MODE:
		upload_state.visible = false
		return
	if ScoreManager.instance == null:
		_show_upload_slide()
		upload_state.text = "成绩上传失败"
		retry_btn.visible = true
		return
	_show_upload_slide()
	upload_state.text = "正在上传成绩..."
	retry_btn.visible = false
	var gen := _upload_generation
	var result = await ScoreManager.instance.upload_score(midi, _upload_snapshot)
	# 期间离开本页或已进入新一局，丢弃本次结果
	if not is_inside_tree() or gen != _upload_generation:
		return
	if result.get("ok", false):
		# 通知个人信息页刷新统计
		EvtBus.score_uploaded.emit(midi.file_hash)
		upload_state.text = "成绩上传成功"
		retry_btn.visible = false
		# 上传成功后再弹出玩家等级面板
		_show_level_panel_on_upload_success()
	elif result.get("skipped", false):
		GLogger.info("Score upload skipped: chart not found on server (midi=%s)" % midi.file_hash, "ScoreView")
		# 谱面不在服务端收录范围，属于正常不收录，但仍给出提示避免手动上传时无声反馈
		upload_state.text = "成绩上传失败：服务端未收录该谱面"
		retry_btn.visible = false
	else:
		var err := str(result.get("error", "上传异常"))
		if err == "not_logged_in":
			upload_state.text = "登录已断开，请重新登录后再上传成绩"
		elif err == "token_refresh_failed":
			upload_state.text = "登录已过期，请重新登录后再上传成绩"
		else:
			upload_state.text = "成绩上传失败：%s" % err
		retry_btn.visible = true

func _on_score_sync_retry_btn_pressed() -> void:
	_show_upload_slide()
	_do_upload_score()

## 成绩上传成功后弹出玩家等级面板，并同步最新玩家信息
func _show_level_panel_on_upload_success() -> void:
	if not _is_logged_in():
		return
	_level_panel_shown = true
	# 等其它页面入场动画播放完毕再弹出，避免看起来像一进来面板就在
	if not _entry_animation_done:
		while not _entry_animation_done:
			await get_tree().process_frame
			if not is_inside_tree():
				return
	info.visible = true
	ani.animate_fade_slide_in(info, Vector2(-100, 0), 0.3, "sv_info")
	_update_player_info()

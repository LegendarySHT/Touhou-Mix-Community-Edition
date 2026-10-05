extends Control
## 音乐播放器页
##
## 与其他页面不同，本页不驱动播放——系统媒体控件与页面按钮的命令都经
## MidiPlaybackManager.handle_media_command 执行，本页只订阅状态信号并更新界面。
## 这样页面切换、后台、失焦都不影响播放控制。
##
## 结构：TopBar（返回）/ Stage（封面 or 音符可视化）/ BottomBar（播放控制）。
## 曲库为 Stage 内覆盖的子页（逻辑在 LibraryLayer.gd），播放列表为右侧滑入
## 面板（逻辑在 PlaylistPanel.gd）。本脚本只留页面骨架：播放控制、媒体会话、
## 进度/封面/歌曲信息、主题、面板开关按钮与主栏让位动画。

const WORK_STATE := UIStateManager.UIState.MUSIC_PLAYER_VIEW
## 播放方式枚举直接引用 manager 的，避免两处字面量漂移
const RepeatMode := MidiPlaybackManager.RepeatMode
## 子页脚本用 preload 常量做类型标注，不依赖全局类缓存
const LibraryLayerScript := preload("res://UI/Views/MusicPlayerView/LibraryLayer.gd")
const PlaylistPanelScript := preload("res://UI/Views/MusicPlayerView/PlaylistPanel.gd")

@onready var _back_btn: TextureButton = $BackBtn
@onready var _cover_view: Control = $MainColumn/Stage/CoverView
@onready var _cover: TextureRect = $MainColumn/Stage/CoverView/AspectRatio/Cover
@onready var _cover_placeholder: Label = $MainColumn/Stage/CoverView/AspectRatio/CoverPlaceholder
@onready var _note_roll: Control = $MainColumn/Stage/NoteRollView
@onready var _note_roll_view: Node = $MainColumn/Stage/NoteRollView
@onready var _main_column: Control = $MainColumn
@onready var _stage: Control = $MainColumn/Stage
@onready var _bottom_bar: Control = $MainColumn/BottomBar
@onready var _stage_switch_btn: TextureButton = $MainColumn/BottomBar/RightBts/StageSwitchBtn
@onready var _song_title: Label = $MainColumn/BottomBar/SongInfo/SongTitle
@onready var _song_artist: Label = $MainColumn/BottomBar/SongInfo/SongArtist
@onready var _prev_btn: TextureButton = $MainColumn/BottomBar/CenterBtns/PrevBtn
@onready var _play_pause_btn: TextureButton = $MainColumn/BottomBar/CenterBtns/PlayPauseBtn
@onready var _next_btn: TextureButton = $MainColumn/BottomBar/CenterBtns/NextBtn
@onready var _repeat_btn: TextureButton = $MainColumn/BottomBar/RightBts/RepeatBtn
@onready var _volume_btn: TextureButton = $MainColumn/BottomBar/RightBts/VolumeBtn
@onready var _equalizer_btn: TextureButton = $MainColumn/BottomBar/RightBts/EqualizerBtn
@onready var _library_btn: TextureButton = $MainColumn/BottomBar/RightBts/LibraryBtn
@onready var _playlist_btn: TextureButton = $MainColumn/BottomBar/RightBts/PlaylistBtn
@onready var _progress: HSlider = $MainColumn/BottomBar/Progress
@onready var _time_cur: Label = $MainColumn/BottomBar/Progress/CurrentTime
@onready var _time_total: Label = $MainColumn/BottomBar/Progress/TotalTime
@onready var _library_layer: LibraryLayerScript = $LibraryLayer
@onready var _playlist_panel: PlaylistPanelScript = $PlaylistPanel
@onready var _fav_picker: Panel = $FavoritePicker

## 进度条拖动中，避免被 _process 回写打断
var _progress_dragging: bool = false

@onready var _volume_popup: VBoxContainer = $MainColumn/BottomBar/RightBts/VolumeBtn/VolumePopup
@onready var _midi_vol_slider: HSlider = $MainColumn/BottomBar/RightBts/VolumeBtn/VolumePopup/MidiVolSlider
@onready var _vocal_vol_slider: HSlider = $MainColumn/BottomBar/RightBts/VolumeBtn/VolumePopup/VocalVolSlider

func _ready() -> void:
	UiStatMGR.state_changed.connect(_on_ui_state_changed)
	ThemeMGR.register_theme_applier(self)
	apply_theme()

	if _progress != null:
		_progress.drag_started.connect(func(): _progress_dragging = true)

	# 主栏让位动画与曲库开合是绑定的一对，由页面统一编排
	_library_layer.opened.connect(_main_slide_out)
	_library_layer.closed.connect(_main_slide_in)
	_library_layer.favorite_requested.connect(_on_favorite_requested)
	_playlist_panel.favorite_requested.connect(_on_favorite_requested)

	var mgr := MidiPlaybackManager.instance
	if mgr != null:
		mgr.current_song_changed.connect(_on_current_song_changed)
		mgr.transport_changed.connect(_on_transport_changed)
		mgr.playback_state_changed.connect(_on_playback_state_changed)
		mgr.repeat_mode_changed.connect(_on_repeat_mode_changed)
		_midi_vol_slider.value = mgr.get_effective_midi_volume(-1.0)
		_vocal_vol_slider.value = mgr.get_vocal_volume_db()

	_apply_stage_mode()
	# 懒加载视图的 _ready 可能晚于 state_changed，两处都调 _activate_page（幂等）
	if UiStatMGR.current_state == WORK_STATE:
		_activate_page()

func _on_current_song_changed(data) -> void:
	_refresh_song_info()
	_refresh_cover()
	_note_roll_view.bind(data)

func _on_transport_changed() -> void:
	_refresh_song_info()

## 播放/暂停键跟随实际播放态。current_song_changed 在 play() 之前发出（点歌单、
## 自动换曲都走 play_playlist_index），彼时 is_playing 还是 false，只靠它同步
## 按钮会慢一拍——真正的状态翻转在 playback_state_changed 里
func _on_playback_state_changed() -> void:
	var mgr := MidiPlaybackManager.instance
	_set_play_pause_pressed(mgr != null and mgr.is_playing)

func _on_repeat_mode_changed(_mode: int) -> void:
	_sync_repeat_btn()

func _on_ui_state_changed(_old: int, new: int) -> void:
	if new == WORK_STATE:
		_activate_page()
	elif _old == WORK_STATE and new != UIStateManager.UIState.TRACK_VIEW:
		# 离开本页才注销。跳去 TrackView（点歌单上的曲子去音轨编辑）是同一首歌的
		# 另一种视图，不算退出播放，故保留会话。
		MediaSess.unregister_view(self)
		# 注销会停止播放；同时把活动会话交还给单曲槽(B)，A 只在本页期间活动
		var mgr := MidiPlaybackManager.instance
		if mgr != null:
			mgr.end_user_session()

func _process(_delta: float) -> void:
	_refresh_progress()

## 进度条：拖动中不回写，其余按播放位置更新
func _refresh_progress() -> void:
	if _progress == null or _progress_dragging:
		return
	var mgr := MidiPlaybackManager.instance
	if mgr == null:
		return
	# 时长是 load 后才可知的；若 max 停在 HSlider 默认 100，value 会被 clamp 满
	var dur: float = mgr.get_backend_duration_ms()
	if dur > 0.0 and absf(_progress.max_value - dur) > 0.5:
		_progress.max_value = dur
	_progress.value = clampf(mgr.get_realtime_position_ms(), 0.0, _progress.max_value)
	_update_time_labels(mgr)


func _on_progress_drag_ended(value_changed: bool) -> void:
	_progress_dragging = false
	if not value_changed:
		return
	var mgr := MidiPlaybackManager.instance
	if mgr != null:
		mgr.handle_media_command("seek", _progress.value)

## 页面激活：注册媒体会话、灌入播放列表、起播、刷新界面。
## 幂等，且需在 _ready 之后再跑一遍——懒加载视图 add_child 后才进入树，_ready
## 可能晚于 state_changed，那时机 @onready 尚未赋值、_on_ui_state_changed 会静默失效。
func _activate_page() -> void:
	# 每次进页面都要重新注册：离开本页时 _on_ui_state_changed 会 unregister_view，
	# 不重新注册则 has_view() 为 false，系统媒体卡片不显示、媒体命令被直接丢弃。
	# register_view 自身幂等（同一视图重复调用直接返回），不必再自己判断。
	MediaSess.register_view(self)
	var mgr := MidiPlaybackManager.instance
	if mgr != null:
		# 本页的页面级播放模式 = 单曲文件循环（从演奏/TrackView 过来都要纠正回来）。
		# 这不是"起一次会话"，所以不走 start_session：那会重设用户播放列表(A)，
		# 而这里只需要改当前曲的循环标志。
		mgr.set_loop(true)
		_ensure_playing(mgr)
	# 从其它页面返回本页时复位全部开关：面板/模式是子页状态，不跨页面保留。
	# 曲库/播放列表/音量连 toggled，取消按下即收起；StageSwitchBtn 连的是 pressed，
	# 程序化取消按下不触发，由下方 _apply_stage_mode 同步视图。
	for b in [_library_btn, _playlist_btn, _volume_btn, _stage_switch_btn]:
		if b != null and b.button_pressed:
			b.button_pressed = false
	_refresh_panel_btn_tint()
	_refresh_song_info()
	_refresh_cover()
	_apply_stage_mode()
	if mgr != null:
		_note_roll_view.bind(mgr.current_midi_data)
	# 预载曲库（池子 + 首次排序），逻辑在 LibraryLayer
	_library_layer.prewarm()

## 接入主题色：页面背景 / 底栏。曲库与播放列表面板各自的主题在
## LibraryLayer.apply_theme / PlaylistPanel.apply_theme。
## tscn 里的颜色只是占位，运行时以主题 token 为准。
func apply_theme() -> void:
	if ThemeMGR == null:
		return
	var bg := get_node_or_null("Bg") as ColorRect
	if bg != null:
		bg.color = ThemeMGR.get_color("background", bg.color)
	var bar := get_node_or_null("MainColumn/BottomBar") as Panel
	if bar != null:
		var sb := bar.get_theme_stylebox("panel") as StyleBoxFlat
		if sb != null:
			sb.bg_color = ThemeMGR.get_color("surface_low", sb.bg_color)
			sb.border_color = ThemeMGR.get_color("border_soft", sb.border_color)
	_apply_icon_tints()

## 入场/出场动画。由 AnimationManager 转调（契约：ani_comp.call("animate", [ani_in])），
## 模式同 ScoreView.animate()——分段动画写在页面自己脚本里，管理器只负责转发与
## 置可见，不在这里堆 match 分支。
## 关键：每段动画用各自的 tween id。AnimationManager._create_tween 会 kill 同名
## tween，被 kill 的属性会停在设定值上（曾导致底栏永久透明却仍可点）。
func animate(ani_in: bool = true) -> void:
	if not ani_in:
		# 打断进行中的入场，避免它继续把已隐藏的区块淡回来
		_entry_pending = false
		AniMGR.animate_fade_scale_out(self, Vector2.ONE * 0.97, 0.18, "mpv_exit")
		return
	if _entry_pending:
		return   # 入场进行中，忽略重复触发
	_entry_pending = true
	# 复位整页状态（上次退出可能已缩放淡出）
	visible = true
	modulate.a = 1.0
	offset_transform_position = Vector2.ZERO
	offset_transform_scale = Vector2.ONE
	_main_column.offset_transform_position_ratio = Vector2.ZERO
	_main_column.offset_transform_position = Vector2.ZERO

	var staged := _stage_staged_nodes()
	await get_tree().create_timer(0.22).timeout
	if not _entry_pending:
		return
	_animate_staged_in(staged)
	_entry_pending = false

## 预置各区块的起始态（隐藏 + 偏移），避免轮到它们之前已在目标位置显示
func _stage_staged_nodes() -> Dictionary:
	var staged := {}
	# 偏移量取控件高度的量级才有「从边缘进入」的感觉（50px 在 1080p 上几乎看不出）
	var bh := _bottom_bar.size.y + 40.0
	var sw := _stage_switch_btn.size.x + 40.0
	_stage_one(staged, "stage", _stage, Vector2.ZERO, Vector2(0.94, 0.94))
	_stage_one(staged, "bottom", _bottom_bar, Vector2(0, bh))
	_stage_one(staged, "switch", _stage_switch_btn, Vector2(sw, 0))
	return staged

func _stage_one(staged: Dictionary, key: String, node: CanvasItem, from_offset: Vector2,
		from_scale: Vector2 = Vector2.ONE) -> void:
	if node == null:
		return
	var c := node as Control
	if c != null:
		c.offset_transform_enabled = true
		c.offset_transform_position = from_offset
		c.offset_transform_scale = from_scale
	node.modulate.a = 0.0
	staged[key] = [node, from_offset, from_scale]

## 第 2 阶段：各区块归位淡入
func _animate_staged_in(staged: Dictionary) -> void:
	# 错峰入场：舞台先落定，控件随后从边缘滑入，避免四个区块同时到齐显得平
	if staged.has("stage"):
		AniMGR.animate_fade_scale_in(staged["stage"][0], staged["stage"][2], 0.30, "mpv_stage")
	if staged.has("top"):
		AniMGR.animate_fade_slide_in(staged["top"][0], staged["top"][1], 0.26, "mpv_top")
	if staged.has("bottom"):
		AniMGR.animate_fade_slide_in(staged["bottom"][0], staged["bottom"][1], 0.30, "mpv_bottom")
	if staged.has("switch"):
		AniMGR.animate_fade_slide_in(staged["switch"][0], staged["switch"][1], 0.24, "mpv_switch")

## 入场进行中（用于中途退出时打断）
var _entry_pending: bool = false

## 进入页面时确保在播。列表本体由 MidiPlaybackManager 持有（唯一事实来源），
## 跨重启由 PlaylistMGR 落盘 / restore_playlist 读回，这里不再做第二份副本的同步。
## 判据只看 is_playing：stop() 不清 current_midi_data，用它判断会永远不重播。
## 随机重排只发生在初次进入（列表从盘恢复）与「打乱列表」按钮，返回本页不重洗。
func _ensure_playing(mgr) -> void:
	# 要用用户播放列表(A)时先确保它就绪：内存为空先读盘恢复，仍为空则借单曲槽那首(B)。
	# 正常通道（演奏/试听/媒体播种）只写单曲槽、不碰 A，所以这里必须自己确保 A 可用；
	# 为此本页的播放动作天然就是"开始播放 A"，与用户从 TrackView 试听过来不冲突。
	if mgr.playlist.is_empty() or not PlaylistMGR.persist_enabled:
		mgr.ensure_user_playlist()
	mgr.align_index_to_current()
	if mgr.is_playing:
		return
	if mgr.playlist.is_empty():
		return
	# restore 已把 playlist_index 对准 saved 位置；已恢复列表则从当前索引续播
	mgr.play_playlist_index(mgr.playlist_index)


# ── 舞台 ──────────────────────────────────────────────

func _on_stage_switch_pressed() -> void:
	_apply_stage_mode()

## 舞台模式由 StageSwitchBtn 的 button_pressed 表达：未按下=封面，按下=可视化。
## 按钮是 toggle_mode，两态贴图（texture_normal / texture_pressed）已由 tscn 给好。
func _apply_stage_mode() -> void:
	_cover_view.visible = not _stage_switch_btn.button_pressed
	_note_roll.visible = _stage_switch_btn.button_pressed

# ── 底部控制 ──────────────────────────────────────────

func _on_back_pressed() -> void:
	UiStatMGR.go_back_to(UIStateManager.UIState.ALBUM_VIEW)

## 去音轨编辑页：把当前播放的 MIDI 整给 TrackView（当前没有在播的歌则不响应）
func _on_track_view_pressed() -> void:
	var mgr := MidiPlaybackManager.instance
	var midi: MidiData = mgr.current_midi_data if mgr != null else null
	if midi == null:
		return
	if midi.chart_key.is_empty() and not midi.id.is_empty():
		# 投影来源的 MidiData 可能没带规范键，按 id 补一次水合
		var m: MidiData = DataMGR.get_midi_by_id(midi.id)
		if m != null:
			midi = m
	UiStatMGR.change_state(UIStateManager.UIState.TRACK_VIEW)
	EvtBus.enter_track_view_with.emit.call_deferred(midi)

func _on_prev_pressed() -> void:
	var mgr := MidiPlaybackManager.instance
	if mgr != null:
		mgr.handle_media_command("prev", -1.0)

func _on_next_pressed() -> void:
	var mgr := MidiPlaybackManager.instance
	if mgr != null:
		mgr.handle_media_command("next", -1.0)

## button_pressed 语义：正在播放。默认（未按下）显示播放图标，按下显示暂停图标。
func _on_play_pause_toggled(_pressed: bool) -> void:
	# 只处理「因播放状态变化而被动更新」之外的用户点击，避免与状态同步互相触发
	if _syncing_pause_btn:
		return
	var mgr := MidiPlaybackManager.instance
	if mgr == null:
		return
	# 点击时的目标状态 = 本次点击后按钮将处的状态
	var want_playing := _play_pause_btn.button_pressed
	if want_playing == mgr.is_playing and not mgr.is_paused:
		return
	mgr.handle_media_command("play" if want_playing else "pause", -1.0)

var _syncing_pause_btn: bool = false

## 播放方式两态：默认=循环播放（顺序），按下=随机。
## 三态循环（顺序/列表循环/单曲）由媒体控件的 repeat 键承担，按钮只做两态。
func _on_repeat_toggled(pressed: bool) -> void:
	var mgr := MidiPlaybackManager.instance
	if mgr == null:
		return
	if _syncing_repeat_btn:
		return
	var want := RepeatMode.SHUFFLE if pressed else RepeatMode.REPEAT_ALL
	if mgr.repeat_mode == want:
		return
	mgr.set_repeat_mode(want)

var _syncing_repeat_btn: bool = false

## 三个面板按钮的 toggle 状态即面板开关：想关面板就把它 button_pressed 置 false。
## 按下态同时用主题强调色点亮（未按下为原色）。
func _on_volume_toggled(on: bool) -> void:
	_volume_popup.visible = on
	_refresh_panel_btn_tint()

func _on_library_toggled(on: bool) -> void:
	if on:
		_playlist_btn.button_pressed = false   # 打开曲库即收起播放列表（其 toggled 会执行收起）
		_library_layer.open()
	else:
		_library_layer.close()
	_refresh_panel_btn_tint()

func _on_playlist_toggled(on: bool) -> void:
	if on:
		_library_btn.button_pressed = false
		_playlist_panel.open()
	else:
		_playlist_panel.close()
	_refresh_panel_btn_tint()

## 图标贴图是白色描线，浅色模式下会消失在浅底上，需按主题翻成常规文字色
func _icon_color() -> Color:
	if ThemeMGR == null:
		return Color.WHITE
	return ThemeMGR.get_color("text_primary", Color.WHITE)

## TextureButton 没有 icon_*_color 主题项（只有 StyleBox），贴图不会被主题染色，
## 只能逐节点 self_modulate 接入主题。
func _apply_icon_tints() -> void:
	var normal := _icon_color()
	var dim := normal
	if ThemeMGR != null:
		dim = ThemeMGR.get_color("text_dim", normal)
	for b in [_back_btn, _stage_switch_btn, _prev_btn, _play_pause_btn, _next_btn, _repeat_btn]:
		if b != null:
			b.self_modulate = normal
	if _equalizer_btn != null:
		_equalizer_btn.self_modulate = dim
	_refresh_panel_btn_tint()

func _refresh_panel_btn_tint() -> void:
	var off := _icon_color()
	var on := off
	if ThemeMGR != null:
		on = ThemeMGR.get_color("primary", off)
	for b in [_volume_btn, _library_btn, _playlist_btn]:
		if b != null:
			b.self_modulate = on if b.button_pressed else off

func _on_midi_volume_changed(value: float) -> void:
	var mgr := MidiPlaybackManager.instance
	if mgr != null:
		mgr.apply_ui_midi_volume(value)

func _on_vocal_volume_changed(value: float) -> void:
	var mgr := MidiPlaybackManager.instance
	if mgr != null:
		mgr.set_vocal_volume_db(value)

# ── 曲库开合（页面侧）─────────────────────────────────

## 打开曲库时主页面整体上移：offset_transform_position 与 offset_transform_position_ratio 一起动。
## ratio.y: -1（全出屏）→ 0（屏幕内基准位），同时
## offset_transform_position.y: 0 → MAIN_UP_SHIFT，两者叠加使播放栏刚好停在顶部。
const MAIN_UP_SHIFT := 160.0

func _main_slide_out() -> void:
	_main_column.offset_transform_enabled = true
	_main_column.offset_transform_position_ratio = Vector2(0, -1.0)
	_main_column.offset_transform_position = Vector2.ZERO
	# 两条通道同一个 tween 驱动，真正同步
	AniMGR.animate_offset_and_ratio_to(_main_column, Vector2(0, MAIN_UP_SHIFT),
		Vector2(0, -1), 0.28, "MpvMainUp")

## 回落：同样两通道一起反向
func _main_slide_in() -> void:
	_main_column.offset_transform_enabled = true
	AniMGR.animate_offset_and_ratio_to(_main_column, Vector2.ZERO,
		Vector2(0, 0), 0.24, "MpvMainDown")

# ── 收藏选择器（曲库单曲/批量与播放列表共用）──────────

var _pending_fav_midis: Array = []

## 收到的是 chart_id 列表（曲库投影的 key / 播放列表项的 chart_id），选择收藏夹后批量入
func _on_favorite_requested(midis: Array) -> void:
	_pending_fav_midis = midis
	_fav_picker.open(true)

func _on_favorite_picked(fav_id: String) -> void:
	if not _pending_fav_midis.is_empty():
		FavoriteManager.instance.add_ids_to_favorite(fav_id, _pending_fav_midis)
	_pending_fav_midis = []

# ── 状态刷新 ──────────────────────────────────────────

func _refresh_song_info() -> void:
	var mgr := MidiPlaybackManager.instance
	var data: MidiData = mgr.current_midi_data if mgr != null else null
	if data == null:
		_song_title.set_scroll_text("未在播放")
		_song_artist.set_scroll_text("")
		_set_play_pause_pressed(false)
	else:
		_song_title.set_scroll_text(data.song_name if not data.song_name.is_empty() else data.name)
		# 与 PlayView 的显示逻辑一致：第二行显示作曲（author_name），不是 MIDI 作者
		_song_artist.set_scroll_text(data.author_name if not data.author_name.is_empty() else "Unknow")
		# 正在播放 → 按下态（暂停图标）；已暂停 → 默认态（播放图标）
		_set_play_pause_pressed(mgr != null and mgr.is_playing)
	_sync_repeat_btn()
	_sync_progress_range()

## mm:ss 格式
func _fmt_time(ms: float) -> String:
	var total_s := int(maxf(ms, 0.0) / 1000.0)
	return "%d:%02d" % [total_s / 60, total_s % 60]

## 当前时间 / 总时间标签
func _update_time_labels(mgr) -> void:
	if _time_cur == null or _time_total == null:
		return
	var pos: float = mgr.get_realtime_position_ms()
	_time_cur.text = _fmt_time(pos)
	_time_total.text = _fmt_time(mgr.get_backend_duration_ms())

## 进度条上限随当前曲目时长
func _sync_progress_range() -> void:
	if _progress == null:
		return
	var mgr := MidiPlaybackManager.instance
	var dur: float = mgr.get_backend_duration_ms() if mgr != null else 0.0
	_progress.max_value = maxf(dur, 1.0)
	_progress.step = 1.0

## 以 button_pressed 反映播放态。用 _syncing_* 防止「状态同步」与「用户点击」互相触发
func _set_play_pause_pressed(playing: bool) -> void:
	if _play_pause_btn.button_pressed == playing:
		return
	_syncing_pause_btn = true
	_play_pause_btn.button_pressed = playing
	_syncing_pause_btn = false

## 以 button_pressed 反映播放方式：按下=随机，默认=循环
func _sync_repeat_btn() -> void:
	var mgr := MidiPlaybackManager.instance
	if mgr == null:
		return
	var random_on := mgr.repeat_mode == RepeatMode.SHUFFLE
	if _repeat_btn.button_pressed == random_on:
		return
	_syncing_repeat_btn = true
	_repeat_btn.button_pressed = random_on
	_syncing_repeat_btn = false

# ── 封面 ──────────────────────────────────────────────

const COVER_ITEM_ID := "music_player_cover"

func _refresh_cover() -> void:
	var mgr := MidiPlaybackManager.instance
	var data: MidiData = mgr.current_midi_data if mgr != null else null
	if data == null:
		CoverLoader.cancel(COVER_ITEM_ID)
		_cover.texture = null
		_cover_placeholder.visible = true
		return
	var fs_mgr := FileSystemManager.instance
	if fs_mgr == null:
		return
	CoverLoader.request_load(COVER_ITEM_ID, fs_mgr.get_cover_path_by_midiData(data), _on_cover_loaded)

func _on_cover_loaded(_path: String, tex: Texture2D, _version: int) -> void:
	_cover.texture = tex
	_cover_placeholder.visible = tex == null

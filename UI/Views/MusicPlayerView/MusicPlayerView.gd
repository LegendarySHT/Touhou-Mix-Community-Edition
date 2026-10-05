extends Control
## 音乐播放器页
##
## 与其他页面不同，本页不驱动播放——系统媒体控件与页面按钮的命令都经
## MidiPlaybackManager.handle_media_command 执行，本页只订阅状态信号并更新界面。
## 这样页面切换、后台、失焦都不影响播放控制。
##
## 结构：TopBar（返回）/ Stage（封面 or 音符可视化）/ BottomBar（播放控制）
## 曲库为 Stage 内覆盖的子页，播放列表为右侧滑入面板。

const WORK_STATE := UIStateManager.UIState.MUSIC_PLAYER_VIEW
## 播放方式枚举直接引用 manager 的，避免两处字面量漂移
const RepeatMode := MidiPlaybackManager.RepeatMode
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
	EvtBus.sort_finished.connect(_on_library_items_ready)

	var mgr := MidiPlaybackManager.instance
	if mgr != null:
		mgr.current_song_changed.connect(_on_current_song_changed)
		mgr.transport_changed.connect(_on_transport_changed)
		mgr.playback_state_changed.connect(_on_playback_state_changed)
		mgr.repeat_mode_changed.connect(_on_repeat_mode_changed)
		mgr.playlist_index_changed.connect(_on_playlist_index_changed)
		# 列表被手动改动 → 歌单选择框复位（视图常驻，绑一次即可）
		mgr.playlist_user_edited.connect(_on_playlist_user_edited)
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

func _on_playlist_index_changed(_i: int) -> void:
	_refresh_playlist_highlight()

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

func _process(delta: float) -> void:
	_refresh_progress()
	_step_pl_scroll(delta)

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
	# 从其它页面返回本页时收起曲库与列表面板：本页是「播放页」，
	# 子页状态不应跨页面保留。
	if _library_open:
		_force_close_library()
	# 面板收起统一走按钮状态（toggled 回调负责实际收起）
	_playlist_btn.button_pressed = false
	_volume_btn.button_pressed = false
	_refresh_panel_btn_tint()
	_refresh_song_info()
	_refresh_cover()
	_apply_stage_mode()
	if mgr != null:
		_note_roll_view.bind(mgr.current_midi_data)
	# 预载曲库：池子 + 首次排序请求（异步）。不提前做的话，点曲库那一刻
	# 卡片实例化 + DB 查询全挤在一帧，音频会卡一下导致人声/MIDI 错位。
	# 排序本身异步，deferred 摊开开销。
	_ensure_library_pool.call_deferred()
	_request_sort.call_deferred()

## 接入主题色：页面背景 / 底栏 / 播放列表面板 / 曲库内容面板。
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
	var pl := get_node_or_null("PlaylistPanel") as Panel
	if pl != null:
		var psb := pl.get_theme_stylebox("panel") as StyleBoxFlat
		if psb != null:
			psb.bg_color = ThemeMGR.get_color("surface", psb.bg_color)
			psb.border_color = ThemeMGR.get_color("border_soft", psb.border_color)
	var lib := get_node_or_null("LibraryLayer") as Control
	if lib != null:
		var lsb := lib.get_theme_stylebox("panel") as StyleBoxFlat
		if lsb != null:
			lsb.bg_color = ThemeMGR.get_color("surface", lsb.bg_color)
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
	# 复位整页状态（上次退出可能已缩放淡出；曲库收起时 ratio 停在 -1）
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
		_open_library()
	else:
		_close_library()
	_refresh_panel_btn_tint()

func _on_playlist_toggled(on: bool) -> void:
	if on:
		_library_btn.button_pressed = false
		_open_playlist_panel()
	else:
		_close_playlist_panel()
	_refresh_panel_btn_tint()

## 图标贴图是白色描线，浅色模式下会消失在浅底上，需按主题翻成常规文字色
func _icon_color() -> Color:
	if ThemeMGR == null:
		return Color.WHITE
	return ThemeMGR.get_color("text_primary", Color.WHITE)

## TextureButton 没有 icon_*_color 主题项（只有 StyleBox），贴图不会被主题染色，
## 只能逐节点 self_modulate 接入主题。曲库搜索框的放大镜是 TextureRect，同理。
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
	if _search_icon != null:
		_search_icon.self_modulate = normal
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

# ── 曲库 ──────────────────────────────────────────────

const CARD_SCENE := preload("res://UI/Views/MusicPlayerView/LibraryCard.tscn")
## 网格列数
const LIBRARY_COLUMNS := 3
## 行间距 / 列间距
const LIBRARY_ROW_GAP := 25.0
const LIBRARY_COL_GAP := 20.0
## 固定槽位数：只创建这么多卡片，滚动时换绑数据（照搬 SortedMidiView 的对象池思路）
const LIBRARY_POOL_SIZE := 36

## 卡片高度由 LibraryCard.tscn 的 custom_minimum_size.y 指定（宽度交给锚点自适应屏幕）；
## 建池时读取，兜底值仅防未初始化
var _lib_card_h: float = 250.0

var _lib_items: Array = []
var _lib_slots: Array = []          # LibraryCard 节点（槽位）
## 空闲槽池（存槽位下标）+ 占用表（槽位下标 → 数据索引）。
## 不变量：两者并集恒为全部槽位、互不相交；绑定 = 从空闲池 pop 后写入占用表。
var _lib_free_slots: Array = []
var _lib_occupied: Dictionary = {}
var _lib_loaded: bool = false
## 曲库滚动值（像素）。由 LibraryOverlay 经 Callable 读写，页面自己持有，
## 不再依赖 ScrollContainer——卡片位置是锚点/像素混合表达，转 scroll_vertical 不划算
var _lib_scroll_y: float = 0.0
## 筛选状态（按状态过滤，照 AlbumView 的做法）
var _lib_status: int = SortingEngine.SortStatField.ALL
var _lib_field: int = SortingEngine.SortDataField.DOWNLOAD_COUNT
var _lib_direction: int = SortingEngine.SortDirection.ASCENDING

@onready var _library_layer: Control = $LibraryLayer
@onready var _search_edit: LineEdit = $LibraryLayer/SearchRow/SearchEdit
@onready var _search_icon: TextureRect = $LibraryLayer/SearchRow/SearchEdit/SearchBtn
@onready var _filter_status_btn: Button = $LibraryLayer/SearchRow/FilterStatusBtn
@onready var _filter_data_btn: Button = $LibraryLayer/SearchRow/FilterDataBtn
@onready var _sort_order_btn: Button = $LibraryLayer/SearchRow/SortOrderBtn
@onready var _batch_add_btn: Button = $LibraryLayer/SearchRow/BatchAddBtn
@onready var _batch_fav_btn: Button = $LibraryLayer/SearchRow/BatchFavBtn
@onready var _library_empty: Label = $LibraryLayer/Content/LibraryEmpty
@onready var _fav_picker: Panel = $FavoritePicker

## 曲库开合：主页面整体上移让位（此时播放栏充当顶栏），曲库层自身从下方滑入。
## 再点曲库按钮则反向恢复。两处位移都用 offset_transform，不用 position。
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

func _open_library() -> void:
	_library_open = true
	_ensure_library_pool()
	_apply_sort_icon()
	_request_sort()
	# 排序签名没变时 _request_sort 会直接复用，不会发 items_ready；
	# 这里补一次窗口绑定，保证打开时按当前覆盖层尺寸铺满可见行
	_reconcile_library_pool.call_deferred(false)

	_library_layer.visible = true
	_library_layer.offset_transform_enabled = true
	_library_layer.offset_transform_position_ratio = Vector2(0, 1.0)
	_library_layer.offset_transform_position = Vector2.ZERO
	AniMGR.animate_offset_and_ratio_to(_library_layer, Vector2.ZERO, Vector2.ZERO, 0.30,
		"MpvLibraryIn")
	_main_slide_out()

func _close_library() -> void:
	if not _library_open:
		return
	_library_open = false
	_animate_library_closed()
	_main_slide_in()

## 曲库下沉退出。等动画结束再隐藏；期间若重新打开（visible 已被置回 true）则放弃隐藏
func _animate_library_closed() -> void:
	_library_layer.offset_transform_enabled = true
	AniMGR.animate_offset_and_ratio_to(_library_layer, Vector2.ZERO, Vector2(0, 1.0),
		0.22, "MpvLibraryOut")
	await get_tree().create_timer(0.24).timeout
	if _library_layer != null and _library_open:
		return
	if _library_layer != null:
		_library_layer.visible = false

## 立即收起曲库（不走下沉动画），用于重新进入本页时复位
func _force_close_library() -> void:
	_library_open = false
	if _library_btn != null:
		_library_btn.button_pressed = false
	if _library_layer == null:
		return
	_library_layer.visible = false
	_library_layer.offset_transform_enabled = true
	_library_layer.offset_transform_position_ratio = Vector2(0, 1.0)
	_library_layer.offset_transform_position = Vector2.ZERO
	# 主页面一并复位（ratio 归 -1 即完全出屏，offset 归零）
	_main_column.offset_transform_enabled = true
	_main_column.offset_transform_position_ratio = Vector2(0, -1.0)
	_main_column.offset_transform_position = Vector2.ZERO

var _library_open: bool = false

## 节点池：卡片挂在覆盖层上（机制同 SortedMidiView——只固定数量的卡片，
## 滚动时换绑数据），这样才能池化复用而不是每首歌一个节点。
func _ensure_library_pool() -> void:
	if not _lib_slots.is_empty():
		return
	_lib_overlay = get_node_or_null("LibraryLayer/Content/LibraryOverlay") as Control
	if _lib_overlay == null:
		return
	if not _lib_overlay.resized.is_connected(_on_overlay_resized):
		_lib_overlay.resized.connect(_on_overlay_resized)
	_lib_overlay.get_scroll_y = Callable(self, "_get_scroll_y")
	_lib_overlay.set_scroll_y = Callable(self, "_set_scroll_y")
	_lib_overlay.get_scroll_max = Callable(self, "_max_scroll_y")
	_lib_overlay.scrolled = Callable(self, "_on_overlay_scrolled")
	for i in LIBRARY_POOL_SIZE:
		var card: PanelContainer = CARD_SCENE.instantiate()
		if i == 0:
			# 高度以 tscn 的 custom_minimum_size.y 为准（宽度交给锚点自适应）
			_lib_card_h = maxf(card.custom_minimum_size.y, 1.0)
		_lib_overlay.add_child(card)
		card.visible = false   # 池内未绑定的卡片必须隐藏，否则会全部堆在左上角重叠
		card.play_next_requested.connect(_on_card_play_next)
		card.add_to_playlist_requested.connect(_on_card_add)
		card.add_to_favorite_requested.connect(_on_card_favorite)
		_lib_slots.append(card)
		_lib_free_slots.append(i)

@onready var _lib_overlay: Control = $LibraryLayer/Content/LibraryOverlay

## 供 LibraryOverlay 经 Callable 读写滚动值（页面自持像素滚动量，不再依赖 ScrollContainer）
func _get_scroll_y() -> float:
	return _lib_scroll_y

func _set_scroll_y(v: float) -> void:
	_lib_scroll_y = clampf(v, 0.0, _max_scroll_y())
	_translate_lib_to_scroll()

func _max_scroll_y() -> float:
	var view_h := _lib_overlay.size.y if _lib_overlay != null else 0.0
	return maxf(0.0, _lib_content_height() - view_h)

## 滚动入口：把每张已绑定卡片整体上移（offset_transform），零重排
func _on_overlay_scrolled(_v: float) -> void:
	_translate_lib_to_scroll()

## 滚动只改卡片自身的 offset_transform_position（视觉与命中区一起跟随），
## 不重排、不重算卡位——只有当前可见的那十几张需要写
func _translate_lib_to_scroll() -> void:
	for slot in _lib_occupied.keys():
		_lib_slots[slot].offset_transform_position = Vector2(0.0, -_lib_scroll_y)
	# 可见窗口变化后补位/释放，deferred 摊开，避免拖动帧里抢占
	_reconcile_library_pool.call_deferred(false)

## 覆盖层尺寸变化：曲库隐藏时容器不给它排布（size 为 0），显示后这里才拿到真实尺寸，
## 故必须重跑一次可见窗口计算，否则只会绑到最初那一行
func _on_overlay_resized() -> void:
	_lib_scroll_y = clampf(_lib_scroll_y, 0.0, _max_scroll_y())
	_relayout_library_cards()
	_reconcile_library_pool.call_deferred(false)

func _lib_row_count() -> int:
	var cols := maxi(1, LIBRARY_COLUMNS)
	return int(ceil(float(_lib_items.size()) / float(cols)))

## 真实内容高度：行数张卡 + 行间空隙（供滚动范围用）
func _lib_content_height() -> float:
	var rows := _lib_row_count()
	if rows <= 0:
		return 0.0
	return float(rows) * _lib_card_h + float(rows - 1) * LIBRARY_ROW_GAP

## 卡片位置由【数据索引】决定（列 = idx % 列数，行 = idx / 列数）：
##   横向用锚点分数定列宽（列/列数 ~ (列+1)/列数），随覆盖层宽度自适应不同屏幕；
##     两侧各缩 half 列间距，使整排左右留白相等（居中），相邻卡之间恰好一个列间距。
##   纵向固定高度，按行号像素排（行步进 = 卡片高 + 行间距），滚动量由 offset_transform 叠加。
func _place_library_card(card: Control, idx: int) -> void:
	var n := maxi(1, LIBRARY_COLUMNS)
	var col := idx % n
	var row := idx / n
	var half_gap := LIBRARY_COL_GAP * 0.5
	card.anchor_left = float(col) / float(n)
	card.anchor_right = float(col + 1) / float(n)
	card.offset_left = half_gap
	card.offset_right = -half_gap
	var y := float(row) * (_lib_card_h + LIBRARY_ROW_GAP)
	card.anchor_top = 0.0
	card.anchor_bottom = 0.0
	card.offset_top = y
	card.offset_bottom = y + _lib_card_h
	# 宽度交给锚点（置 0 不被 tscn 的 custom_minimum_size.x 卡住），高度固定
	card.custom_minimum_size = Vector2(0.0, _lib_card_h)
	card.offset_transform_enabled = true
	card.offset_transform_position = Vector2(0.0, -_lib_scroll_y)
	card.offset_transform_position_ratio = Vector2.ZERO

## 尺寸变化时重排所有已绑定卡片（空闲槽位无需定位）
func _relayout_library_cards() -> void:
	for slot in _lib_occupied.keys():
		_place_library_card(_lib_slots[slot], _lib_occupied[slot])

## 定位并绑定可见窗口。数据刷新时全量重绑（增量对齐会残留旧数据），滚动时只补位/释放。
func _reconcile_library_pool(animate_in: bool = false) -> void:
	if _lib_slots.is_empty():
		return
	var n := maxi(1, LIBRARY_COLUMNS)
	var row_step := _lib_card_h + LIBRARY_ROW_GAP
	var vtop := _lib_scroll_y
	var view_h := _lib_overlay.size.y if _lib_overlay != null else 0.0

	# 可见数据索引区间：按行换算成二维索引
	var first_row := maxi(0, floori(vtop / row_step))
	var vis_rows := int(ceil(view_h / row_step)) + 1
	var lo := first_row * n
	var hi := mini(lo + vis_rows * n - 1, _lib_items.size() - 1)

	# 全部归还到空闲池（数据刷新时按视觉顺序重绑，避免残留旧数据）
	if animate_in:
		for slot in _lib_occupied.keys():
			_lib_slots[slot].visible = false
			_lib_free_slots.append(slot)
		_lib_occupied.clear()
		for idx in range(lo, hi + 1):
			if idx >= _lib_items.size() or _lib_free_slots.is_empty():
				break
			var slot: int = _lib_free_slots.pop_back()
			_lib_occupied[slot] = idx
			_assign_library_slot(slot, idx, true)
		return

	# 滚动：把移出窗口的槽归还空闲池，并记下窗口内已绑定的索引
	var bound := {}
	for slot in _lib_occupied.keys():
		var idx: int = _lib_occupied[slot]
		if idx < lo or idx > hi:
			_lib_occupied.erase(slot)
			_lib_slots[slot].visible = false
			_lib_free_slots.append(slot)
		else:
			bound[idx] = true
	# 只给「窗口内尚未绑定」的索引补空槽——已绑定的不能再绑一次，
	# 否则同一索引会落到多张卡上，它们位置相同 → 重叠
	for idx in range(lo, hi + 1):
		if idx >= _lib_items.size():
			break
		if bound.has(idx):
			continue
		if _lib_free_slots.is_empty():
			break
		var slot: int = _lib_free_slots.pop_back()
		_lib_occupied[slot] = idx
		_assign_library_slot(slot, idx, false)

## 把数据绑到槽上：先按数据索引定位卡位，再换绑内容
func _assign_library_slot(slot: int, idx: int, animate: bool) -> void:
	var card: PanelContainer = _lib_slots[slot]
	_place_library_card(card, idx)
	card.visible = true
	card.setup_with(_lib_items[idx] as Dictionary, idx, animate)

## 搜索词变化即重查（搜索基于当前筛选字段，由 DB 侧 FilterSearch 完成）
func _on_search_changed(_t: String) -> void:
	if _library_open:
		_request_sort()

## 排序/筛选：沿用 ShortCutMenu.shortcut_menu.gd 的状态机 + 图标区域表，
## 保证两处筛选语义与图标一致。
func _on_sort_order_pressed() -> void:
	_lib_direction = (_lib_direction + 1) % 2 as SortingEngine.SortDirection
	_apply_sort_icon()
	_request_sort()

func _on_filter_status_pressed() -> void:
	_lib_status = (_lib_status + 1) % 5 as SortingEngine.SortStatField
	_apply_sort_icon()
	_request_sort()

func _on_filter_data_pressed() -> void:
	var cur := _lib_data_fields.find(int(_lib_field))
	var next := (cur + 1) % _lib_data_fields.size() if cur >= 0 else 0
	_lib_field = _lib_data_fields[next] as SortingEngine.SortDataField
	_apply_sort_icon()
	_request_sort()

## 按当前状态刷新三个按钮的图标（AtlasTexture.region 切换，同 ShortCutMenu）
func _apply_sort_icon() -> void:
	var st := _filter_status_btn.icon as AtlasTexture
	if st != null:
		st.region = STATUS_REGION[_lib_status]
	var dt := _filter_data_btn.icon as AtlasTexture
	if dt != null:
		dt.region = DATA_REGION[_lib_field]
	var ot := _sort_order_btn.icon as AtlasTexture
	if ot != null:
		ot.region = ASC_REGION if _lib_direction == SortingEngine.SortDirection.ASCENDING 			else DESC_REGION

## 发起排序。参数与上次相同且已有结果时直接复用——否则每次打开曲库都会
## 重查全库（1882 首），表现为打开瞬间音频卡一下。
var _last_sort_sig := ""

func _request_sort() -> void:
	var q := _search_edit.text.strip_edges()
	var sig := "%d|%d|%d|%s" % [_lib_status, _lib_field, _lib_direction, q]
	if sig == _last_sort_sig and not _lib_items.is_empty():
		return
	_last_sort_sig = sig
	if q.is_empty():
		SortEngine.set_sort_mode(_lib_status, _lib_field, _lib_direction)
	else:
		SortEngine.set_sort_mode_with_query(q)

## 排序结果就绪：撑滚动范围 + 跳回顶部按视觉顺序全量重绑
## （照 SortedMidiView 的 refecth 分支——增量对齐会残留旧数据）
func _on_library_items_ready() -> void:
	_lib_items = SortEngine.get_items()
	_lib_loaded = true
	_library_empty.visible = _lib_items.is_empty()
	# 跳回顶部 + 归位锚点平移（否则新结果会停在旧滚动位移上），再全量重绑
	_lib_scroll_y = 0.0
	_translate_lib_to_scroll()
	_reconcile_library_pool(true)

## 图标区域表（照 ShortCutMenu.shortcut_menu.gd）
const STATUS_REGION := {
	SortingEngine.SortStatField.ALL: Rect2(0, 160, 80, 80),
	SortingEngine.SortStatField.PENDING: Rect2(80, 160, 80, 80),
	SortingEngine.SortStatField.APPROVED: Rect2(160, 160, 80, 80),
	SortingEngine.SortStatField.INCLUDED: Rect2(240, 160, 80, 80),
	SortingEngine.SortStatField.DEAD: Rect2(320, 160, 80, 80),
}
const ASC_REGION := Rect2(0, 240, 80, 80)
const DESC_REGION := Rect2(80, 240, 80, 80)
const DATA_REGION := {
	SortingEngine.SortDataField.DOWNLOAD_COUNT: Rect2(0, 320, 80, 80),
	SortingEngine.SortDataField.TRIAL_COUNT: Rect2(80, 320, 80, 80),
	SortingEngine.SortDataField.UP_COUNT: Rect2(160, 320, 80, 80),
	SortingEngine.SortDataField.UPLOADED_DATE: Rect2(240, 320, 80, 80),
}
## 数据字段循环顺序（同 ShortCutMenu._data_fields）
var _lib_data_fields: Array = [
	SortingEngine.SortDataField.DOWNLOAD_COUNT,
	SortingEngine.SortDataField.TRIAL_COUNT,
	SortingEngine.SortDataField.UP_COUNT,
	SortingEngine.SortDataField.UPLOADED_DATE,
]

## 列表项是轻量投影（Dictionary），批量操作前水合为 MidiData。
## 单个曲子水合失败（已删除/DB 未就绪）时跳过。
func _visible_library_midis() -> Array[MidiData]:
	var out: Array[MidiData] = []
	for it in _lib_items:
		if it is Dictionary:
			var m: MidiData = DataMGR.get_midi_by_id(String((it as Dictionary).get("key", "")))
			if m != null:
				out.append(m)
	return out

# ── 曲库卡片操作 ──────────────────────────────────────

## 把轻量投影的 key 写进播放列表
func _key_of(item: Dictionary) -> String:
	var k := String(item.get("key", ""))
	if k.is_empty():
		k = String(item.get("id", ""))
	return k

func _on_card_play_next(item: Dictionary) -> void:
	var k := _key_of(item)
	if k.is_empty():
		return
	var mgr := MidiPlaybackManager.instance
	if mgr == null:
		return
	var data: MidiData = DataMGR.get_midi_by_id(k)
	if data != null:
		mgr.insert_next_in_playlist(data)

func _on_card_add(item: Dictionary) -> void:
	var k := _key_of(item)
	if k.is_empty():
		return
	var mgr := MidiPlaybackManager.instance
	if mgr == null:
		return
	var data: MidiData = DataMGR.get_midi_by_id(k)
	if data != null and not mgr.playlist.has(data):
		mgr.append_to_playlist([data] as Array[MidiData])

func _on_card_favorite(item: Dictionary) -> void:
	_pending_fav_midis = [DataMGR.get_midi_by_id(_key_of(item))] as Array
	_fav_picker.open(true)

func _on_batch_next_pressed() -> void:
	for it in _lib_items:
		if it is Dictionary:
			_on_card_play_next(it)

func _on_batch_add_pressed() -> void:
	var mgr := MidiPlaybackManager.instance
	if mgr == null:
		return
	var add: Array[MidiData] = []
	for m in _visible_library_midis():
		if not mgr.playlist.has(m):
			add.append(m)
	if not add.is_empty():
		mgr.append_to_playlist(add)

func _on_batch_fav_pressed() -> void:
	_pending_fav_midis = _visible_library_midis()
	if _pending_fav_midis.is_empty():
		return
	_fav_picker.open(true)

var _pending_fav_midis: Array = []

func _on_favorite_picked(fav_id: String) -> void:
	for m in _pending_fav_midis:
		if m is MidiData:
			FavoriteManager.instance.add_midi_to_favorite(fav_id, m)
	_pending_fav_midis = []

# ── 播放列表面板 ──────────────────────────────────────

const PL_ITEM_SCENE := preload("res://UI/Views/MusicPlayerView/PlaylistItem.tscn")

@onready var _playlist_panel: Panel = $PlaylistPanel
@onready var _pl_list: PlaylistList = $PlaylistPanel/PlColumn/PlScroll/PlList
@onready var _pl_empty: Label = $PlaylistPanel/PlColumn/PlScroll/PlList/PlEmpty
@onready var _fav_select_btn: OptionButton = $PlaylistPanel/PlColumn/PlCtrl/FavSelectBtn
@onready var _pl_add_fav_btn: Button = $PlaylistPanel/PlColumn/PlCtrl/PlAddFavBtn
@onready var _pl_clear_btn: Button = $PlaylistPanel/PlColumn/PlCtrl/PlClearBtn
@onready var _pl_scroll: ScrollContainer = $PlaylistPanel/PlColumn/PlScroll

## 播放列表拖动滚动（仅桌面补足）：ScrollContainer 的拖拽滚动只在触屏平台生效，
## 桌面没有，所以在视图里补一份，手感同曲库（1:1 跟手 + 松手惯性）。
## 触屏平台直接放行，交给 ScrollContainer 原生拖拽，避免两套同时推动。
const PL_FLING_DECAY := 1000.0
const PL_SAMPLE_WINDOW := 0.1

var _pl_dragging: bool = false
var _pl_accum: float = 0.0
var _pl_sample_accum: float = 0.0
var _pl_sample_time: float = 0.0
var _pl_fling: float = 0.0
var _pl_flinging: bool = false

func _on_pl_scroll_gui_input(event: InputEvent) -> void:
	if DisplayServer.is_touchscreen_available():
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_stop_pl_fling()
			_pl_dragging = true
			_pl_accum = 0.0
			_pl_sample_accum = 0.0
			_pl_sample_time = 0.0
		else:
			_pl_dragging = false
			# 用最后一段采样窗口补全速度（快速轻扫也拿到惯性）
			if _pl_sample_time > 0.0:
				_pl_fling = (_pl_accum - _pl_sample_accum) / maxf(_pl_sample_time, 0.001)
			_pl_flinging = absf(_pl_fling) > 1.0
	elif event is InputEventMouseMotion and _pl_dragging:
		var dy := (event as InputEventMouseMotion).relative.y
		_pl_accum += dy
		_scroll_pl(dy)

func _step_pl_scroll(delta: float) -> void:
	if _pl_dragging:
		_pl_sample_time += delta
		if _pl_sample_time >= PL_SAMPLE_WINDOW:
			_pl_fling = (_pl_accum - _pl_sample_accum) / _pl_sample_time
			_pl_sample_accum = _pl_accum
			_pl_sample_time = 0.0
		return
	if not _pl_flinging:
		return
	var prev := _pl_scroll.scroll_vertical
	_scroll_pl(_pl_fling * delta)
	var s := 1.0 if _pl_fling >= 0.0 else -1.0
	_pl_fling = s * maxf(0.0, absf(_pl_fling) - PL_FLING_DECAY * delta)
	if _pl_fling == 0.0 or _pl_scroll.scroll_vertical == prev:
		_stop_pl_fling()

func _stop_pl_fling() -> void:
	_pl_fling = 0.0
	_pl_flinging = false

## 滚动由 ScrollContainer 自身的取值范围钳制，越界自然停下
func _scroll_pl(delta_px: float) -> void:
	_pl_scroll.scroll_vertical = int(round(float(_pl_scroll.scroll_vertical) - delta_px))

func _open_playlist_panel() -> void:
	GLogger.info("[DIAG] open_playlist begin", "MusicPlayerView")
	_playlist_panel.visible = true
	_rebuild_fav_select()
	_rebuild_playlist_list()
	# 从右侧滑入。走 AnimationManager 统一管理 tween，避免快速连点时叠加冲突
	_playlist_panel.offset_transform_position.x = size.x
	AniMGR.animate_offset_to(_playlist_panel, Vector2.ZERO, 0.25, "PlaylistPanelIn")
	GLogger.info("[DIAG] open_playlist done, items=%d" % _pl_list.get_child_count(),
		"MusicPlayerView")

func _close_playlist_panel() -> void:
	if not _playlist_panel.visible:
		return
	GLogger.info("[DIAG] close_playlist begin, items=%d" % _pl_list.get_child_count(),
		"MusicPlayerView")
	AniMGR.animate_offset_to(_playlist_panel, Vector2(size.x, 0), 0.2, "PlaylistPanelOut")
	await get_tree().create_timer(0.2).timeout
	# await 期间面板可能已随页面切换被释放，故先校验再访问
	if not is_instance_valid(self) or not is_instance_valid(_playlist_panel):
		GLogger.info("[DIAG] close_playlist: panel already freed", "MusicPlayerView")
		return
	# 正在被拖动的项会继续收 gui_input，先停掉再隐藏
	_stop_all_pl_dragging()
	_playlist_panel.visible = false
	GLogger.info("[DIAG] close_playlist done", "MusicPlayerView")

## 停掉所有播放列表项的拖动状态：隐藏后它们仍可能收到残留的鼠标事件
func _stop_all_pl_dragging() -> void:
	_pl_dragging = false
	_stop_pl_fling()
	if not is_instance_valid(_pl_list):
		return
	_pl_list.end_handle_drag()   # 拖拽状态在列表上，面板收起时一并收尾
	for c in _pl_list.get_children():
		var item := c as PlaylistItem
		if item != null:
			item.cancel_drag()

## 收藏夹下拉：首项为「未选择歌单」
func _rebuild_fav_select() -> void:
	_fav_select_btn.clear()
	_fav_select_btn.add_item("未选择歌单")
	_fav_select_btn.set_item_metadata(0, "")
	var fav_mgr := FavoriteManager.instance
	if fav_mgr != null:
		for f in fav_mgr.favorites:
			_fav_select_btn.add_item(f.name)
			_fav_select_btn.set_item_metadata(_fav_select_btn.item_count - 1, f.id)
	# 恢复当前选择
	if PlaylistMGR.source_fav_id.is_empty():
		_fav_select_btn.select(0)
	else:
		for i in _fav_select_btn.item_count:
			if str(_fav_select_btn.get_item_metadata(i)) == PlaylistMGR.source_fav_id:
				_fav_select_btn.select(i)
				break

func _on_fav_select_selected(idx: int) -> void:
	var fav_id := str(_fav_select_btn.get_item_metadata(idx))
	var mgr := MidiPlaybackManager.instance
	if mgr == null:
		return
	if fav_id.is_empty():
		# 「未选择歌单」：只解除关联，不动列表内容
		PlaylistMGR.source_fav_id = ""
		return
	# 选中收藏夹 = 用它整表替换当前播放列表（空收藏夹即替换为空列表）
	var keys := PlaylistMGR.keys_of_favorite(fav_id)
	PlaylistMGR.source_fav_id = fav_id
	var list: Array[MidiData] = []
	for k in keys:
		var m: MidiData = DataMGR.get_midi_by_id(str(k))
		if m != null:
			list.append(m)
	# 选歌单是「要记住」的会话（persist=true），并按本页页面级模式开文件循环
	# （loop_file=true）——播完的推进挂在这个回绕点上，非空则从第一首起播
	mgr.start_session(list, 0, true, true)
	if not list.is_empty():
		mgr.play_playlist_index(0)
	_rebuild_fav_select()
	_rebuild_playlist_list()

## 列表被手动改动（增/删/移/清空）→ 选择框复位回"未选择歌单"，避免歧义
func _on_playlist_user_edited() -> void:
	_rebuild_fav_select()

func _rebuild_playlist_list() -> void:
	for c in _pl_list.get_children():
		if c != _pl_empty:
			c.queue_free()
	var mgr := MidiPlaybackManager.instance
	var current_idx: int = mgr.playlist_index if mgr != null else -1
	# 列表以 manager 为唯一事实来源（改收藏夹/增删时 manager 已同步）
	var midis: Array[MidiData] = mgr.playlist if mgr != null else [] as Array[MidiData]
	_pl_empty.visible = midis.is_empty()
	for i in midis.size():
		var item: PlaylistItem = PL_ITEM_SCENE.instantiate()
		_pl_list.add_child(item)
		item.setup_with(midis[i], i, i == current_idx)
		item.remove_requested.connect(_on_pl_remove)
		item.activated.connect(_on_pl_activated)

func _on_pl_remove(idx: int) -> void:
	var mgr := MidiPlaybackManager.instance
	if mgr != null:
		mgr.remove_from_playlist(idx)
	_rebuild_playlist_list.call_deferred()

func _on_pl_move(from_idx: int, to_idx: int) -> void:
	var mgr := MidiPlaybackManager.instance
	if mgr != null:
		mgr.move_in_playlist(from_idx, to_idx)
	_rebuild_playlist_list.call_deferred()

## 注意：下面是 PlaylistItem 信号的回调。immediate 重建会 queue_free「正在处理
## 输入事件的那个节点」，其后续语句访问已释放的 self 而崩溃，故一律 call_deferred。
func _on_pl_activated(idx: int) -> void:
	var mgr := MidiPlaybackManager.instance
	if mgr != null:
		mgr.play_playlist_index(idx)
	_rebuild_playlist_list.call_deferred()

func _on_pl_add_fav_pressed() -> void:
	var mgr := MidiPlaybackManager.instance
	_pending_fav_midis = mgr.playlist if mgr != null else ([] as Array[MidiData])
	if _pending_fav_midis.is_empty():
		return
	_fav_picker.open(true)

func _on_pl_clear_pressed() -> void:
	var mgr := MidiPlaybackManager.instance
	if mgr != null:
		mgr.clear_playlist()
	_rebuild_playlist_list()

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

# ── 播放列表高亮 ──────────────────────────────────────

func _refresh_playlist_highlight() -> void:
	# 面板未打开时无需重建（下次打开会全量重建）
	if not _playlist_panel.visible:
		return
	var cur := _current_playlist_index()
	for c in _pl_list.get_children():
		var item := c as PlaylistItem
		if item != null:
			item.setup_with(item.midi, item.index, item.index == cur)

func _current_playlist_index() -> int:
	var mgr := MidiPlaybackManager.instance
	return mgr.playlist_index if mgr != null else -1

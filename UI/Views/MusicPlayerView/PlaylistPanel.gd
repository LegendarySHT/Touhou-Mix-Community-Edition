extends Panel
## 播放列表面板：从 MusicPlayerView 拆出的全部播放列表逻辑——
## 行池滚动换绑、高亮同步、收藏夹选择、行内删除/调序、桌面滚动物理、
## 面板开合动画。行节点的排序拖拽在 PlList（列表容器）上。

## 收藏选择器在页面级（曲库批量收藏共用），面板只上报要收藏的曲目
signal favorite_requested(midis: Array)

## preload 常量做类型标注，不依赖全局类缓存
const ITEM_SCRIPT := preload("res://UI/Views/MusicPlayerView/PlaylistItem.gd")
const LIST_SCRIPT := preload("res://UI/Views/MusicPlayerView/PlaylistList.gd")
const PL_ITEM_SCENE := preload("res://UI/Views/MusicPlayerView/PlaylistItem.tscn")
## 播放方式枚举直接引用 manager 的，避免两处字面量漂移。
## 用 preload 拿而不是全局类名：全局类表可能因编辑器缓存过期而缺失该条目（实测掉过），
## 那样本脚本会在解析期直接报错。preload 不依赖全局类表。
const PlaybackTypesLib := preload("res://Game/PlaybackTypes.gd")
const RepeatMode := PlaybackTypesLib.RepeatMode

## 行对象池（照曲库的池化思路）：只保留「视窗 ± margin」的行节点，滚动时换绑数据。
## 行高一致，PlList 里用上下两个 spacer 撑出滚动总高，池行夹在中间占住可视窗口的位置
const POOL_MARGIN_ROWS := 3
## 页面一次能显示 ~15 行，池 = 可见 + margin 就够；上限只防窗口异常大时无节制膨胀
const POOL_MAX_ROWS := 24

@onready var _pl_list: LIST_SCRIPT = $PlColumn/PlScroll/PlList
@onready var _pl_empty: Label = $PlColumn/PlScroll/PlList/PlEmpty
@onready var _fav_select_btn: OptionButton = $PlColumn/PlCtrl/FavSelectBtn
@onready var _pl_scroll: ScrollContainer = $PlColumn/PlScroll
@onready var _reshuffle_btn: Button = $PlColumn/PlTitle/ReshuffleBtn

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

## 上次构建播放列表时的内容签名（keys 序列）。
## 面板每次打开都调 _rebuild_playlist_list，列表没变时靠它跳过全量重建
var _pl_last_sig: PackedStringArray = PackedStringArray()

## 可见窗口行的 MidiData 缓存：只对可视行按 key 水合，不整表水合（省内存）。
## 行池有上限，缓存随之有界；超限整体清空，丢的重水合很快。
var _row_data_cache: Dictionary = {}

## 当前歌跟随：面板打开且用户无操作时，定期把视图滚到当前歌（不在可视区才滚）。
## 滚动带动画；动画期间 scrollbar 的 value_changed 不算用户操作
const FOLLOW_CHECK_INTERVAL := 3.0
const FOLLOW_IDLE_MS := 10000
const FOLLOW_SCROLL_MIN := 0.25
const FOLLOW_SCROLL_MAX := 0.8
const FOLLOW_SCROLL_SPEED := 3000.0   # px/s，换算动画时长用
var _follow_accum: float = 0.0
var _last_user_scroll_ms: int = 0
var _follow_tween: Tween = null
## 程序化滚动标志：置位期间 scrollbar 的 value_changed 不算用户操作
var _auto_scrolling: bool = false

## 行池状态。行高在建池时实测一次（行 + separation），窗口 = [first, first+行数)
var _row_stride_px: float = 0.0
var _top_spacer: Control = null
var _bottom_spacer: Control = null
var _pool_rows: Array = []
var _window_first: int = 0
var _playlist_total: int = 0

func _ready() -> void:
	ThemeMGR.register_theme_applier(self)
	apply_theme()
	_pl_scroll.get_v_scroll_bar().value_changed.connect(_on_scroll_moved)
	_pl_scroll.resized.connect(_on_pl_scroll_resized)
	var mgr := PlaybackDisplay.instance
	if mgr != null:
		mgr.playlist_index_changed.connect(_refresh_playlist_highlight)
		# 列表被手动改动 → 歌单选择框复位（视图常驻，绑一次即可）
		mgr.playlist_user_edited.connect(_rebuild_fav_select)
		# 列表本体变化（打乱、增删）→ 行池内容强制重绑
		mgr.playlist_changed.connect(_on_playlist_list_changed)
		# 打乱按钮只在随机模式下显示（顺序/循环模式下没有意义）
		mgr.repeat_mode_changed.connect(_on_repeat_mode_changed)
		_reshuffle_btn.visible = mgr.repeat_mode == RepeatMode.SHUFFLE
	if not visible:
		TextScrollMGR.suspend_page(self)

## 打乱按钮跟随播放模式显隐
func _on_repeat_mode_changed(_mode: int) -> void:
	var mgr := PlaybackDisplay.instance
	_reshuffle_btn.visible = mgr != null and mgr.repeat_mode == RepeatMode.SHUFFLE

## 「打乱列表」：整表打乱并从头播（manager 侧清空历史/重放栈，全新收听会话）
func _on_reshuffle_pressed() -> void:
	var mgr := PlaybackDisplay.instance
	if mgr != null:
		mgr.shuffle_playlist_from_head()

func apply_theme() -> void:
	if ThemeMGR == null:
		return
	var sb := get_theme_stylebox("panel") as StyleBoxFlat
	if sb != null:
		sb.bg_color = ThemeMGR.get_color("surface", sb.bg_color)
		sb.border_color = ThemeMGR.get_color("border_soft", sb.border_color)

func _process(delta: float) -> void:
	if not visible:
		return
	_step_pl_scroll(delta)
	_follow_accum += delta
	if _follow_accum >= FOLLOW_CHECK_INTERVAL:
		_follow_accum = 0.0
		_follow_current_song_if_needed()

## 面板打开且用户 4 秒内没碰过滚动，当前歌不在可视区时滚到居中
func _follow_current_song_if_needed() -> void:
	if _pl_dragging or _pl_flinging or _row_stride_px <= 0.0:
		return
	if Time.get_ticks_msec() - _last_user_scroll_ms < FOLLOW_IDLE_MS:
		return
	var mgr := PlaybackDisplay.instance
	if mgr == null:
		return
	var idx := mgr.playlist_index
	if idx < 0 or idx >= _playlist_total:
		return
	var top := float(idx) * _row_stride_px
	var view_h := _pl_scroll.size.y
	var scroll := float(_pl_scroll.scroll_vertical)
	# 已完整可见（含一点余量）就不动
	if top >= scroll and top + _row_stride_px <= scroll + view_h:
		return
	var bar := _pl_scroll.get_v_scroll_bar()
	var target := clampf(top - (view_h - _row_stride_px) * 0.5, 0.0, maxf(bar.max_value - bar.page, 0.0))
	# 带动画滚过去；动画期间 _auto_scrolling 保持置位
	_kill_follow_tween()
	_auto_scrolling = true
	var dist := absf(target - float(_pl_scroll.scroll_vertical))
	var dur := clampf(dist / FOLLOW_SCROLL_SPEED, FOLLOW_SCROLL_MIN, FOLLOW_SCROLL_MAX)
	_follow_tween = AniMGR.create_managed_tween(_pl_scroll, "PlFollowScroll")
	_follow_tween.tween_property(_pl_scroll, "scroll_vertical", int(round(target)), dur) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_follow_tween.finished.connect(func(): _auto_scrolling = false)

func _kill_follow_tween() -> void:
	if _follow_tween != null and _follow_tween.is_valid():
		_follow_tween.kill()
	_auto_scrolling = false

func _on_scroll_moved(_value: float) -> void:
	# 程序化滚动不算用户操作，否则跟随会被自己的滚动一直续期
	if not _auto_scrolling:
		_last_user_scroll_ms = Time.get_ticks_msec()
	_sync_row_window()

func _on_pl_scroll_resized() -> void:
	_grow_row_pool()
	_sync_row_window()

func open() -> void:
	visible = true
	TextScrollMGR.resume_page(self)
	_rebuild_fav_select()
	_rebuild_playlist_list()
	# 从右侧滑入。走 AnimationManager 统一管理 tween，避免快速连点时叠加冲突
	offset_transform_position.x = get_viewport_rect().size.x
	AniMGR.animate_offset_to(self, Vector2.ZERO, 0.25, "PlaylistPanelIn")

func close() -> void:
	if not visible:
		return
	AniMGR.animate_offset_to(self, Vector2(get_viewport_rect().size.x, 0), 0.2, "PlaylistPanelOut")
	await get_tree().create_timer(0.2).timeout
	# 正在被拖动的项会继续收 gui_input，先停掉再隐藏
	_stop_all_dragging()
	visible = false
	TextScrollMGR.suspend_page(self)

# ── 行池 ──────────────────────────────────────────────

## 建池：实测行高 → 按视窗行数建池行 + 上下 spacer。行高拿不到（首帧未布局）返回 false
func _ensure_row_pool() -> bool:
	if _row_stride_px > 0.0:
		return true
	if _pl_scroll.size.y <= 0.0:
		return false
	var sample: ITEM_SCRIPT = PL_ITEM_SCENE.instantiate()
	_pl_list.add_child(sample)
	var row_h := sample.get_combined_minimum_size().y
	_pl_list.remove_child(sample)
	sample.queue_free()
	if row_h <= 0.0:
		return false
	_row_stride_px = row_h + float(_pl_list.get_theme_constant("separation"))
	_top_spacer = _make_spacer()
	_pl_list.add_child(_top_spacer)
	_grow_row_pool()
	_bottom_spacer = _make_spacer()
	_pl_list.add_child(_bottom_spacer)
	return true

func _make_spacer() -> Control:
	var sp := Control.new()
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return sp

## 池行数对齐视窗（窗口拉伸/首建补行、缩小裁行）。补行后把底 spacer 挪回末尾
func _grow_row_pool() -> void:
	if _row_stride_px <= 0.0:
		return
	var need := int(ceil(_pl_scroll.size.y / _row_stride_px)) + 1 + POOL_MARGIN_ROWS * 2
	need = clampi(need, 1, POOL_MAX_ROWS)
	while _pool_rows.size() < need:
		var item: ITEM_SCRIPT = PL_ITEM_SCENE.instantiate()
		item.visible = false
		_pl_list.add_child(item)
		item.remove_requested.connect(_on_pl_remove)
		item.activated.connect(_on_pl_activated)
		_pool_rows.append(item)
	while _pool_rows.size() > need:
		var row: ITEM_SCRIPT = _pool_rows.pop_back()
		_pl_list.remove_child(row)
		row.queue_free()
	_window_first = -1   # 池成员变了，下轮同步强制重算窗口
	if _bottom_spacer != null:
		_pl_list.move_child(_bottom_spacer, _pl_list.get_child_count() - 1)

## 把池行对准当前滚动窗口：更新 spacer 高度 + 换绑窗口内行。
## 已绑同一条目的行直接跳过（文字测宽是重绑的大头）。
## 显示与绑定是两回事：池可能大于视窗（POOL_MAX 上限/历史超长窗口建大过），
## 只有真正落在滚动视窗 ±margin 的行才 visible——可视区外的行不参与绘制，
## 否则长歌名的字形（阴影+描边+填充三遍）会把图元数顶上去
func _sync_row_window(force: bool = false) -> void:
	if _row_stride_px <= 0.0:
		return
	var mgr := PlaybackDisplay.instance
	var total: int = mgr.playlist_count() if mgr != null else 0
	var cur: int = mgr.playlist_index if mgr != null else -1
	var first := 0
	if total > _pool_rows.size():
		first = clampi(int(_pl_scroll.scroll_vertical / _row_stride_px) - POOL_MARGIN_ROWS,
			0, total - _pool_rows.size())
	if first != _window_first:
		_window_first = first
		if _top_spacer != null:
			_top_spacer.custom_minimum_size.y = float(first) * _row_stride_px
		if _bottom_spacer != null:
			_bottom_spacer.custom_minimum_size.y = float(maxi(total - first - _pool_rows.size(), 0)) * _row_stride_px
	var vis_first := int(floor(_pl_scroll.scroll_vertical / _row_stride_px)) - POOL_MARGIN_ROWS
	var vis_last := int(ceil((_pl_scroll.scroll_vertical + _pl_scroll.size.y) / _row_stride_px)) + POOL_MARGIN_ROWS
	for k in _pool_rows.size():
		var item: ITEM_SCRIPT = _pool_rows[k]
		var idx := first + k
		if idx >= total or idx < vis_first or idx > vis_last:
			item.visible = false
			continue
		item.visible = true
		if not force and item.index == idx:
			continue
		var data: MidiData = _midi_for_key(MidiCore.GetKeyAt(idx))
		item.setup_with(data, idx, idx == cur)

# ── 列表重建 ──────────────────────────────────────────

## 按 key 取（并缓存）MidiData：只对可视行水合，避免整表水合占内存
func _midi_for_key(key: String) -> MidiData:
	if key.is_empty():
		return null
	if _row_data_cache.has(key):
		return _row_data_cache[key]
	var m: MidiData = DataMGR.get_midi_by_id(key)
	_row_data_cache[key] = m
	# 有界：超过池行数两倍就整体清空（丢的重水合很快）
	if _row_data_cache.size() > POOL_MAX_ROWS * 2:
		_row_data_cache.clear()
		_row_data_cache[key] = m
	return m

func _playlist_sig(keys: Array) -> PackedStringArray:
	var sig := PackedStringArray()
	sig.resize(keys.size())
	for i in keys.size():
		sig[i] = str(keys[i])
	return sig

func _rebuild_playlist_list() -> void:
	var mgr := PlaybackDisplay.instance
	# 列表以 C# MidiCore 为唯一事实来源（改收藏夹/增删/打乱时 manager 已推过去）；
	# 这里只读 keys 做签名与总数，不整表水合 MidiData
	var keys: Array = mgr.playlist_keys() if mgr != null else []
	var sig := _playlist_sig(keys)
	# 内容没变且池已就绪才走复用；池未建（首次打开当帧 PlScroll 尚未布局，建池失败
	# 走 deferred 重试）时必须放行，否则重试被这里挡死，面板永远空白
	if sig == _pl_last_sig and _row_stride_px > 0.0:
		# 内容没变：行节点全部复用，只同步高亮 + 窗口
		_refresh_playlist_highlight()
		_sync_row_window()
		return
	_pl_last_sig = sig
	if not _ensure_row_pool():
		# 行高还没量出来（首帧未布局），下一帧再试
		_rebuild_playlist_list.call_deferred()
		return
	_playlist_total = keys.size()
	_pl_list.total_count = keys.size()
	_pl_empty.visible = keys.is_empty()
	_sync_row_window(true)

## 列表本体变化（切随机/顺序重排、外部增删）→ 强制重绑池行内容
func _on_playlist_list_changed() -> void:
	if not visible:
		return
	_sync_row_window(true)
	_refresh_playlist_highlight()

## 直连 playlist_index_changed（信号带索引参数，这里不用它，自行读 manager 的当前值）。
## 面板未打开时行池内容仍是旧的，打开时 open() 会全量重绑
func _refresh_playlist_highlight(_changed_index: int = -1) -> void:
	# 面板未打开时行池内容仍是旧的，打开时 open() 会全量重绑
	if not visible:
		return
	var mgr := PlaybackDisplay.instance
	var cur: int = mgr.playlist_index if mgr != null else -1
	for item in _pool_rows:
		if not item.visible:
			continue
		# 行内容没变，只切高亮；走 setup_with 会触发 set_scroll_text 重新测宽
		var is_cur: bool = item.index == cur
		item.is_current = is_cur
		if item.button_pressed != is_cur:
			item.set_pressed_no_signal(is_cur)
	# 切歌信号直达这里：空闲状态下立即跟随新歌（内部自检空闲/拖拽/可见性），
	# 不空闲则由 _process 的周期检查兜底
	_follow_current_song_if_needed()

# ── 行操作回调 ────────────────────────────────────────

## 注意：下面是 PlaylistItem 信号的回调。immediate 重建会 queue_free「正在处理
## 输入事件的那个节点」，其后续语句访问已释放的 self 而崩溃，故一律 call_deferred。
func _on_pl_remove(idx: int) -> void:
	var mgr := PlaybackDisplay.instance
	if mgr != null:
		mgr.remove_from_playlist(idx)
	_rebuild_playlist_list.call_deferred()

func _on_pl_move(from_idx: int, to_idx: int) -> void:
	var mgr := PlaybackDisplay.instance
	if mgr != null:
		mgr.move_in_playlist(from_idx, to_idx)
	_rebuild_playlist_list.call_deferred()

func _on_pl_activated(idx: int) -> void:
	var mgr := PlaybackDisplay.instance
	if mgr != null:
		mgr.play_playlist_index(idx)
	_rebuild_playlist_list.call_deferred()

func _on_pl_add_fav_pressed() -> void:
	var mgr := PlaybackDisplay.instance
	if mgr == null:
		return
	# 列表 key 即规范键（folder_name）= 收藏夹条目 id，直接上报，无需水合 MidiData
	var ids: Array = []
	for k in mgr.playlist_keys():
		if not k.is_empty():
			ids.append(k)
	if ids.is_empty():
		return
	favorite_requested.emit(ids)

func _on_pl_clear_pressed() -> void:
	var mgr := PlaybackDisplay.instance
	if mgr != null:
		mgr.clear_playlist()
	_rebuild_playlist_list()

# ── 收藏夹下拉 ────────────────────────────────────────

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
	if MidiCore.GetSourceFavId().is_empty():
		_fav_select_btn.select(0)
	else:
		for i in _fav_select_btn.item_count:
			if str(_fav_select_btn.get_item_metadata(i)) == MidiCore.GetSourceFavId():
				_fav_select_btn.select(i)
				break

## 收藏夹 → 规范键数组（收藏夹按 chart_id/chart_key 存储，与列表 key 同源）
func _keys_of_favorite(fav_id: String) -> Array:
	var fav_mgr := FavoriteManager.instance
	if fav_mgr == null:
		return []
	var out: Array = []
	for m in fav_mgr.get_midis_of_favorite(fav_id):
		out.append(fav_mgr.chart_id_of(m))
	return out

func _on_fav_select_selected(idx: int) -> void:
	var fav_id := str(_fav_select_btn.get_item_metadata(idx))
	var mgr := PlaybackDisplay.instance
	if mgr == null:
		return
	if fav_id.is_empty():
		# 「未选择歌单」：只解除关联，不动列表内容
		MidiCore.SetSourceFavId("")
		return
	# 选中收藏夹 = 用它整表替换当前播放列表（空收藏夹即替换为空列表）
	# 直接用 keys 开会话，免去把整表水合成 MidiData（省内存）
	var keys := _keys_of_favorite(fav_id)
	MidiCore.SetSourceFavId(fav_id)
	# 选歌单是「要记住」的会话（persist=true）；播完由 EndOfSequence 推进到下一首
	mgr.start_session_keys(keys, 0)
	if not keys.is_empty():
		mgr.play_playlist_index(0)
	_rebuild_fav_select()
	_rebuild_playlist_list()

# ── 桌面拖动滚动 ──────────────────────────────────────

func _on_pl_scroll_gui_input(event: InputEvent) -> void:
	# 只把「按下去」类操作当作用户滚动（悬停/划过不算），否则跟随永远不会触发。
	# 用户按下即打断跟随动画，避免和手抢滚动条
	if event is InputEventMouseButton:
		_last_user_scroll_ms = Time.get_ticks_msec()
		if event.pressed:
			_kill_follow_tween()
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

## 停掉所有播放列表项的拖动状态：隐藏后它们仍可能收到残留的鼠标事件
func _stop_all_dragging() -> void:
	_pl_dragging = false
	_stop_pl_fling()
	_pl_list.end_handle_drag()   # 拖拽状态在列表上，面板收起时一并收尾
	for item in _pool_rows:
		item.cancel_drag()

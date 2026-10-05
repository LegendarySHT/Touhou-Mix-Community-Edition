extends Control
## 曲库子页：从 MusicPlayerView 拆出——卡片对象池/滚动换绑、排序筛选搜索、
## 单曲与批量操作。开合动画自己驱动；主栏让位（上移/回落）经 opened/closed
## 信号由页面驱动（主栏位移和曲库动画是绑定的一对，归页面统一编排）。

## 收藏选择器在页面级（播放列表「加入收藏」共用），这里只上报要收藏的曲目
signal favorite_requested(midis: Array)
signal opened
signal closed

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
## 曲库滚动值（像素）。由 LibraryOverlay 经 Callable 读写，自己持有，
## 不再依赖 ScrollContainer——卡片位置是锚点/像素混合表达，转 scroll_vertical 不划算
var _lib_scroll_y: float = 0.0
## 筛选状态（按状态过滤，照 AlbumView 的做法）
var _lib_status: int = SortingEngine.SortStatField.ALL
var _lib_field: int = SortingEngine.SortDataField.DOWNLOAD_COUNT
var _lib_direction: int = SortingEngine.SortDirection.ASCENDING
## 数据字段循环顺序（同 ShortCutMenu._data_fields）
var _lib_data_fields: Array = [
	SortingEngine.SortDataField.DOWNLOAD_COUNT,
	SortingEngine.SortDataField.TRIAL_COUNT,
	SortingEngine.SortDataField.UP_COUNT,
	SortingEngine.SortDataField.UPLOADED_DATE,
]
## 发起排序。参数与上次相同且已有结果时直接复用——否则每次打开曲库都会
## 重查全库（1882 首），表现为打开瞬间音频卡一下。
var _last_sort_sig := ""
var _open: bool = false

@onready var _search_edit: LineEdit = $SearchRow/SearchEdit
@onready var _search_icon: TextureRect = $SearchRow/SearchEdit/SearchBtn
@onready var _filter_status_btn: Button = $SearchRow/FilterStatusBtn
@onready var _filter_data_btn: Button = $SearchRow/FilterDataBtn
@onready var _sort_order_btn: Button = $SearchRow/SortOrderBtn
@onready var _library_empty: Label = $Content/LibraryEmpty
@onready var _lib_overlay: Control = $Content/LibraryOverlay

func _ready() -> void:
	ThemeMGR.register_theme_applier(self)
	apply_theme()
	EvtBus.sort_finished.connect(_on_library_items_ready)
	if not visible:
		TextScrollMGR.suspend_page(self)

func apply_theme() -> void:
	if ThemeMGR == null:
		return
	var sb := get_theme_stylebox("panel") as StyleBoxFlat
	if sb != null:
		sb.bg_color = ThemeMGR.get_color("surface", sb.bg_color)
	# TextureButton 没有 icon_*_color 主题项，放大镜贴图只能逐节点染色
	if _search_icon != null:
		_search_icon.self_modulate = ThemeMGR.get_color("text_primary", Color.WHITE)

## 页面激活时预载：池子 + 首次排序请求（异步）。不提前做的话，点曲库那一刻
## 卡片实例化 + DB 查询全挤在一帧，音频会卡一下导致人声/MIDI 错位。
## 排序本身异步，deferred 摊开开销。
func prewarm() -> void:
	_ensure_library_pool.call_deferred()
	_request_sort.call_deferred()

func open() -> void:
	_open = true
	_ensure_library_pool()
	_apply_sort_icon()
	_request_sort()
	# 排序签名没变时 _request_sort 会直接复用，不会发 items_ready；
	# 这里补一次窗口绑定，保证打开时按当前覆盖层尺寸铺满可见行
	_reconcile_library_pool.call_deferred(false)

	visible = true
	TextScrollMGR.resume_page(self)
	offset_transform_enabled = true
	offset_transform_position_ratio = Vector2(0, 1.0)
	offset_transform_position = Vector2.ZERO
	AniMGR.animate_offset_and_ratio_to(self, Vector2.ZERO, Vector2.ZERO, 0.30, "MpvLibraryIn")
	opened.emit()

func close() -> void:
	if not _open:
		return
	_open = false
	_animate_closed()
	closed.emit()

## 曲库下沉退出。等动画结束再隐藏；期间若重新打开则放弃隐藏
func _animate_closed() -> void:
	offset_transform_enabled = true
	AniMGR.animate_offset_and_ratio_to(self, Vector2.ZERO, Vector2(0, 1.0), 0.22, "MpvLibraryOut")
	await get_tree().create_timer(0.24).timeout
	if _open:
		return
	visible = false
	TextScrollMGR.suspend_page(self)

## 节点池：卡片挂在覆盖层上（机制同 SortedMidiView——只固定数量的卡片，
## 滚动时换绑数据），这样才能池化复用而不是每首歌一个节点。
func _ensure_library_pool() -> void:
	if not _lib_slots.is_empty():
		return
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

## 供 LibraryOverlay 经 Callable 读写滚动值（自己持有像素滚动量，不再依赖 ScrollContainer）
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
	if _open:
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
	var k := _key_of(item)
	if k.is_empty():
		return
	favorite_requested.emit([k])

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
	# 投影里就有 key（= chart_id），直接收集，零 DB 查询
	var ids: Array = []
	for it in _lib_items:
		if it is Dictionary:
			var k := _key_of(it)
			if not k.is_empty():
				ids.append(k)
	if ids.is_empty():
		return
	favorite_requested.emit(ids)

extends Control
## 曲库子页：从 MusicPlayerView 拆出——卡片对象池/滚动换绑、排序筛选搜索、
## 单曲与批量操作。开合动画自己驱动；主栏让位（上移/回落）经 opened/closed
## 信号由页面驱动（主栏位移和曲库动画是绑定的一对，归页面统一编排）。

## 收藏选择器在页面级（播放列表「加入收藏」共用），这里只上报要收藏的曲目
signal favorite_requested(midis: Array)
signal opened
signal closed

const CARD_SCENE := preload("res://UI/Views/MusicPlayerView/LibraryCard.tscn")
## 通用虚拟化列表（与 DelView/播放列表/SortedMidi 共用）。preload 而非全局类名，避免类缓存问题
const VirtualListLib := preload("res://UI/Components/VirtualList.gd")
## 网格列数
const LIBRARY_COLUMNS := 3
## 行间距 / 列间距
const LIBRARY_ROW_GAP := 25.0
const LIBRARY_COL_GAP := 20.0
## 视窗上下各多绑几行卡片（滑得快时不留白）
const LIBRARY_MARGIN_ROWS := 2

var _lib_items: Array = []
## 卡片池（滚动容器 + 内容层 + 自由槽位复用，见 VirtualList 头注释）
var _vlist: VirtualListLib = null
## 下次绑定是否播入场动画（全量重绑时置位，滚动补位不播）
var _lib_animate_next: bool = false
## 卡片池封面纹理被后台回收放掉过（见 release_cover_state）：下次 open 需全量重绑才会重新加载
var _cover_released: bool = false
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
@onready var _library_empty: Label = $LibraryList/ListContent/ListEmpty
@onready var _lib_scroll: ScrollContainer = $LibraryList
@onready var _list_content: Control = $LibraryList/ListContent

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

## 后台内存回收用（见 Core/MemoryGC.gd）：把卡片池里所有封面纹理放掉。
##
## 刻意不在这里就地重绑：清理发生在后台、主循环暂停中，重绑会立刻重新请求封面，
## 等于把刚释放的内存又装回去。重绑留给下次 open()：
## 那时以"可见窗口只有十几张卡"重绑，代价可接受，且只加载真正要看的那几张。
func release_cover_state() -> void:
	if _vlist == null or _vlist.pool.is_empty():
		return
	for card in _vlist.pool:
		if is_instance_valid(card) and card.has_method("release_cover_state"):
			card.call("release_cover_state")
	_cover_released = true

func open() -> void:
	_open = true
	_ensure_library_pool()
	_apply_sort_icon()
	_request_sort()
	# 排序签名没变时 _request_sort 会直接复用，不会发 items_ready；
	# 这里补一次窗口绑定，保证打开时按当前视窗尺寸铺满可见行
	_reconcile.call_deferred(false)
	# 池内卡片可能刚被后台回收放掉过封面纹理（release_cover_state），
	# 此时窗口内槽位都还"已绑定"，上面那次补位不会给它们重绑 → 封面会一直是空的。
	# 故再补一次全量重绑（force 会先归还全部槽位再按可见窗口重绑）。
	if _cover_released:
		_cover_released = false
		_reconcile.call_deferred(true, true)

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

## 节点池：卡片挂在滚动容器的内容层上，只建视窗需要的那些，滚动时换绑数据（见 VirtualList 头注释）
func _ensure_library_pool() -> void:
	if _vlist != null:
		return
	if _lib_scroll == null or _list_content == null:
		return
	_vlist = VirtualListLib.new()
	_vlist.columns = LIBRARY_COLUMNS
	_vlist.row_gap = LIBRARY_ROW_GAP
	_vlist.col_gap = LIBRARY_COL_GAP
	_vlist.margin_rows = LIBRARY_MARGIN_ROWS
	_vlist.on_row_ready = _on_card_ready
	_vlist.on_row_bind = _on_card_bind
	_vlist.setup(_lib_scroll, _list_content, CARD_SCENE)


## 池卡首次创建：只连信号（位置/尺寸/offset_transform 由 VirtualList 统一接管）
func _on_card_ready(node) -> void:
	var card: PanelContainer = node
	card.play_next_requested.connect(_on_card_play_next)
	card.add_to_playlist_requested.connect(_on_card_add)
	card.add_to_favorite_requested.connect(_on_card_favorite)


## 换绑到数据索引：定位由模块做，这里只填内容
func _on_card_bind(node, idx: int) -> void:
	var card: PanelContainer = node
	if idx >= _lib_items.size():
		return
	card.setup_with(_lib_items[idx] as Dictionary, idx, _lib_animate_next)


## 对齐槽位与可见窗口。force=true 全量重绑（数据刷新 / 封面重载后），animate 控制入场动画
func _reconcile(force: bool = false, animate: bool = false) -> void:
	if _vlist == null:
		return
	_lib_animate_next = animate
	_vlist.sync(force)
	_lib_animate_next = false

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
	if _vlist == null:
		return
	# reset_scroll=true：内容换了一批，带着旧滚动位置会停在莫名其妙的段；再全量重绑（含入场动画）
	_vlist.set_total(_lib_items.size(), true)
	_reconcile(true, true)

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
	var mgr := PlaybackDisplay.instance
	if mgr == null:
		return
	var data: MidiData = DataMGR.get_midi_by_id(k)
	if data != null:
		mgr.insert_next_in_playlist(data)

func _on_card_add(item: Dictionary) -> void:
	var k := _key_of(item)
	if k.is_empty():
		return
	var mgr := PlaybackDisplay.instance
	if mgr == null:
		return
	var data: MidiData = DataMGR.get_midi_by_id(k)
	if data != null and not mgr.playlist_has_key(k):
		mgr.append_to_playlist([data] as Array[MidiData])

func _on_card_favorite(item: Dictionary) -> void:
	var k := _key_of(item)
	if k.is_empty():
		return
	favorite_requested.emit([k])

func _on_batch_add_pressed() -> void:
	var mgr := PlaybackDisplay.instance
	if mgr == null:
		return
	var add: Array[MidiData] = []
	for m in _visible_library_midis():
		if not mgr.playlist_has_midi(m):
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

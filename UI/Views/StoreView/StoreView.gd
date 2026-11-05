## 商店页面（重设计版）
##
## 结构：
##   TopBar    左侧搜索 / 排序 / 批量下载 / 人声开关，右侧五个标签页（歌曲 / 皮肤 / 特效 / 音源 / 下载管理）
##   Tabs      TabContainer（tabs_visible=false）：四个列表页（ScrollContainer → ListContent → VirtualList 池）
##             → 共享空状态页 → 下载管理页；切换标签只改 current_tab，空状态靠切到共享页表达
##   DetailLayer 卡片展开式详情弹窗（通用组件 ChartDetailPanel，默认 STORE 模式）
##   Bottom    歌曲页分页条（进场/退场由本脚本的 _play_enter/_play_exit 驱动）
##
## 数据：
##   歌曲来自服务端 ResourceManager.instance.get_chart_list（搜索 / 排序 / 分页）
##   皮肤 / 特效 / 音源暂取本地资源索引作为预览数据（远端接口未就绪）
##   下载管理按本会话经商店发起的下载任务 + 当前页已下载谱面构建
##
## 下载一律串行：ResourceManager 的并行下载信箱是单实例的，同时发起两次会互相踩。
extends ViewBase

class_name StoreView

const SONG_CARD_SCENE := preload("res://UI/Views/StoreView/StoreSongCard.tscn")
const CATEGORY_CARD_SCENE := preload("res://UI/Views/StoreView/StoreCategoryCard.tscn")
const DOWNLOAD_ROW_SCENE := preload("res://UI/Views/StoreView/StoreDownloadRow.tscn")
## 通用虚拟容器（与曲库 / DelView / 播放列表共用）。preload 而非全局类名，避免类缓存问题
const VirtualListLib := preload("res://UI/Components/VirtualList.gd")
## 新脚本不依赖全局类缓存：一律 preload 后按常量调用，避免未打开编辑器时 "Identifier not declared"
const StoreIconsLib := preload("res://UI/Views/StoreView/StoreIcons.gd")
const CategoryCardLib := preload("res://UI/Views/StoreView/StoreCategoryCard.gd")
const DownloadRowLib := preload("res://UI/Views/StoreView/StoreDownloadRow.gd")

enum Tab { SONGS, SKINS, EFFECTS, SOUNDFONTS, DOWNLOADS }

## TabContainer 的下标布局：四个列表页与 Tab 前四项一一对应，
## 其后依次是「共享空状态页」和下载管理页（下载管理的空提示在自己页面里，不占共享页）
const EMPTY_TAB_INDEX := 4
const DOWNLOADS_TAB_INDEX := 5

const TAB_PLACEHOLDERS := [
	"搜索谱面 / 作者 / 专辑",
	"搜索皮肤",
	"搜索特效",
	"搜索音源",
	"搜索下载记录",
]

## 后端排序字段（与 StoreView 旧实现的 FilterBtn 一一对应）
const SORT_FIELDS := ["download_count", "trial_count", "up_count", "uploaded_at"]
const SORT_LABELS := ["下载数", "游玩数", "点赞数", "上传时间"]

const PAGE_SIZE := 24
const SONG_COLUMNS := 3
const SONG_ROW_GAP := 25.0
const SONG_COL_GAP := 20.0
const GRID_MARGIN_ROWS := 2

var work_state: UIStateManager.UIState = UIStateManager.UIState.STORE_VIEW

## 页面容器（内部只有一页可见，切换 content tab 即切页）
@onready var _tabs: TabContainer = $Tabs

# ── 标签 / 页面 ───────────────────────────────────────
var _current_tab: int = Tab.SONGS
var _tab_buttons: Array[Button] = []
## 各列表页的空状态文案（空串 = 有内容，显示列表页；非空 = 切到共享空状态页）
var _empty_text: Dictionary = {
	Tab.SONGS: "正在加载…",
	Tab.SKINS: "",
	Tab.EFFECTS: "",
	Tab.SOUNDFONTS: "",
}

# ── 歌曲页状态 ────────────────────────────────────────
var _song_items: Array = []
var _song_page: int = 1
var _song_total: int = 0
var _song_req_version: int = 0
var _search_text: String = ""
var _search_timer: SceneTreeTimer = null
var _sort_index: int = 3          # 默认按上传时间
var _sort_order: String = "desc"

# ── 分类页状态（皮肤 / 特效 / 音源） ─────────────────
var _category_cache: Dictionary = {Tab.SKINS: [], Tab.EFFECTS: [], Tab.SOUNDFONTS: []}
var _category_loaded: Dictionary = {Tab.SKINS: false, Tab.EFFECTS: false, Tab.SOUNDFONTS: false}
var _category_view: Dictionary = {Tab.SKINS: [], Tab.EFFECTS: [], Tab.SOUNDFONTS: []}
var _category_vlists: Dictionary = {}

# ── 下载管理状态 ──────────────────────────────────────
## hash → {hash, item, state, stage, percent, order}
var _download_entries: Dictionary = {}
var _download_rows: Array = []
var _download_order: int = 0
var _active_hashes: Dictionary = {}
## 单曲下载队列：所有下载串行执行（ResourceManager 的并行信箱是单实例，不能同时跑两路）
var _manual_queue: Array = []
var _manual_running: bool = false
var _batch_queue: Array = []
var _batch_running: bool = false
var _batch_current: String = ""
var _hero_hash: String = ""
var _hero_cover_version: int = 0

## 详情弹窗打开期间记录被临时隐藏的导航按钮（RB_Btn z=99，会盖在弹窗之上）
## 打开详情的那张卡片/下载行：关闭时把焦点还给原项，而不是跳回列表第一项
var _detail_source_node: Control = null
var _detail_source_item: Dictionary = {}

# ── 虚拟列表 / 绑定动画 ───────────────────────────────
var _song_vlist: VirtualListLib = null
var _dl_vlist: VirtualListLib = null
var _bind_animate: bool = false
var _dl_last_count: int = -1

# 皮肤 / 特效 / 音源页的滚动容器与列表内容，下标与 Tab 一致
var _category_scrolls: Array[ScrollContainer] = []
var _category_lists: Array[Control] = []


func _on_view_ready() -> void:
	_tab_buttons = [
		%TabSongBtn,
		%TabSkinBtn,
		%TabEffectBtn,
		%TabSoundfontBtn,
		%TabDownloadBtn,
	]
	_category_scrolls = [
		null, %SkinsScroll, %EffectsScroll, %SoundfontsScroll, null,
	]
	_category_lists = [
		null, %SkinsListContent, %EffectsListContent, %SoundfontsListContent, null,
	]

	_connect_ui()
	_init_vocal_toggle()
	_setup_song_vlist()
	_apply_sort_icons()
	_select_tab(Tab.SONGS, true)
	_load_songs()

	UiStatMGR.state_changed.connect(_on_state_changed)
	if FileSystemManager.instance:
		FileSystemManager.instance.resources_ready.connect(_on_resources_ready)

	# 标签下划线位置依赖容器布局，等首帧量出按钮位置后再摆放
	call_deferred("_update_tab_underline", true)

## 出场：整页淡出
func _play_exit() -> Tween:
	return AniMGR.animate_fade_out(self, 0.35, "%s_out" % name)

## 入场：顶栏下滑入、底栏上滑入，整页淡入
func _play_enter() -> Tween:
	var top_bar := %TopBar
	top_bar.offset_transform_position = Vector2(0, -500)
	AniMGR.animate_offset_back(top_bar, 0.25, "top_bar_in")
	var bottom := %Bottom
	bottom.offset_transform_position = Vector2(0, 500)
	AniMGR.animate_offset_back(bottom, 0.25, "bottom_in")
	return AniMGR.animate_fade_in(self, 0.45, "%s_in" % name)


# ══════════════════════════════════════════════════════
#  UI 连接
# ══════════════════════════════════════════════════════

func _connect_ui() -> void:
	for i in _tab_buttons.size():
		var btn := _tab_buttons[i]
		btn.pressed.connect(_on_tab_pressed.bind(i))
		# 标签栏被容器压缩时要保持可点区域与视觉一致
		btn.resized.connect(func() -> void:
			if i == _current_tab:
				_update_tab_underline(true)
		)
	%SearchEdit.text_changed.connect(_on_search_changed)
	%SearchEdit.text_submitted.connect(_on_search_submitted)
	%FilterDataBtn.pressed.connect(_on_filter_pressed)
	%SortOrderBtn.pressed.connect(_on_order_pressed)
	%BatchDownloadBtn.pressed.connect(_on_batch_download_pressed)
	%VocalBtn.toggled.connect(_on_vocal_toggled)
	%PreviBtn.pressed.connect(_on_previ_pressed)
	%NextBtn.pressed.connect(_on_next_pressed)
	%DetailLayer.closed.connect(_on_detail_closed)
	%DetailLayer.download_requested.connect(_on_detail_download_requested)
	# 空状态提示兼作「手动重载」入口：加载失败 / 无内容时点一下重新拉取当前标签页
	# （列表页共用一个空状态页，下载管理有自己的空提示）
	%PageEmpty.gui_input.connect(_on_empty_gui_input)
	%DownloadsEmpty.gui_input.connect(_on_empty_gui_input)
	%TopBar.resized.connect(func() -> void: _update_tab_underline(true))


func _init_vocal_toggle() -> void:
	var enabled := true
	if ConfigManager.instance != null:
		enabled = ConfigManager.instance.get_int("download_vocal", 1) == 1
	%VocalBtn.set_pressed_no_signal(enabled)
	_update_vocal_visual()


func _on_vocal_toggled(pressed: bool) -> void:
	if ConfigManager.instance != null:
		ConfigManager.instance.set_value_and_notify("download_vocal", 1 if pressed else 0)
	_update_vocal_visual()


func _update_vocal_visual() -> void:
	var on: bool = %VocalBtn.button_pressed
	%VocalBtn.icon = StoreIconsLib.mic() if on else StoreIconsLib.mic_off()
	%VocalBtn.tooltip_text = "下载谱面时一并下载人声：%s（点击切换）" % ("开" if on else "关")


# ══════════════════════════════════════════════════════
#  标签页
# ══════════════════════════════════════════════════════

func _on_tab_pressed(tab: int) -> void:
	if tab == _current_tab:
		return
	_select_tab(tab, false)


func _select_tab(tab: int, instant: bool) -> void:
	var old_tab := _current_tab
	_current_tab = tab
	for i in _tab_buttons.size():
		_tab_buttons[i].set_pressed_no_signal(i == tab)
	_show_page(tab)
	if not instant:
		TextScrollMGR.suspend_page(_page_node(old_tab))
	TextScrollMGR.resume_page(_page_node(tab))

	%SearchEdit.placeholder_text = TAB_PLACEHOLDERS[tab]
	%Bottom.visible = tab == Tab.SONGS
	_apply_toolbar_for_tab()
	_update_tab_underline(instant)

	if tab >= Tab.SKINS and tab <= Tab.SOUNDFONTS:
		_ensure_category(tab)
		_rebuild_category(tab)
	elif tab == Tab.DOWNLOADS:
		_seed_download_entries()
		_ensure_download_vlist()
		_refresh_downloads_page(true)
	_update_batch_button()

	# 上面的构建可能把页面换成共享空状态页，动画只作用于最后真正显示的那一页
	if not instant:
		_animate_page_in(_shown_page())


## 逻辑标签页 → TabContainer 下标（列表页与 Tab 前四项同序，下载管理排最后）
func _page_index(tab: int) -> int:
	return DOWNLOADS_TAB_INDEX if tab == Tab.DOWNLOADS else clampi(tab, 0, EMPTY_TAB_INDEX - 1)


## 逻辑标签页对应的内容节点（TextScrollMGR 挂起/恢复用）
func _page_node(tab: int) -> Control:
	return _tabs.get_child(_page_index(tab)) as Control


## 当前真正显示在容器里的页面（可能是共享空状态页）
func _shown_page() -> Control:
	return _tabs.get_child(_tabs.current_tab) as Control


## 按逻辑标签页摆好容器：有内容→列表页，无内容→共享空状态页
func _show_page(tab: int) -> void:
	if tab == Tab.DOWNLOADS:
		_tabs.current_tab = DOWNLOADS_TAB_INDEX
		return
	var text := str(_empty_text.get(tab, ""))
	if text.is_empty():
		_tabs.current_tab = _page_index(tab)
		return
	%PageEmpty.text = text
	_tabs.current_tab = EMPTY_TAB_INDEX


## 设置列表页空状态（text 为空 = 有内容）。非当前标签页只记状态，不动显示
func _set_empty(tab: int, text: String) -> void:
	_empty_text[tab] = text
	if tab == _current_tab:
		_show_page(tab)


func _apply_toolbar_for_tab() -> void:
	var is_songs := _current_tab == Tab.SONGS
	%FilterDataBtn.disabled = not is_songs
	%FilterDataBtn.tooltip_text = ("排序字段：%s（点击切换）" % SORT_LABELS[_sort_index]) if is_songs \
		else "排序字段仅对歌曲页生效"
	%SortOrderBtn.disabled = false
	%SortOrderBtn.tooltip_text = "当前%s（点击切换）" % ("升序" if _sort_order == "asc" else "降序")


func _update_tab_underline(instant: bool) -> void:
	if _tab_buttons.is_empty():
		return
	var index := clampi(_current_tab, 0, _tab_buttons.size() - 1)
	var btn := _tab_buttons[index]
	if btn.size.x <= 0.0 or %TopBar.size.y <= 0.0:
		return
	var bar_pos: Vector2 = btn.global_position - %TopBar.global_position
	var target_pos := Vector2(bar_pos.x + 8.0, %TopBar.size.y - 4.0)
	var target_size := Vector2(maxf(btn.size.x - 16.0, 16.0), 4.0)
	if instant:
		%TabUnderlinePanel.position = target_pos
		%TabUnderlinePanel.size = target_size
		return
	var tw := AniMGR.create_managed_tween(%TabUnderlinePanel, "store_tab_underline")
	if tw == null:
		%TabUnderlinePanel.position = target_pos
		%TabUnderlinePanel.size = target_size
		return
	tw.set_parallel(true)
	tw.tween_property(%TabUnderlinePanel, "position", target_pos, 0.26) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(%TabUnderlinePanel, "size", target_size, 0.26) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _animate_page_in(page: Control) -> void:
	page.offset_transform_enabled = true
	page.offset_transform_visual_only = false
	page.offset_transform_position = Vector2(0, 18)
	page.modulate.a = 0.0
	var tw := AniMGR.create_managed_tween(page, "store_page_in")
	if tw == null:
		page.offset_transform_position = Vector2.ZERO
		page.modulate.a = 1.0
		return
	tw.set_parallel(true)
	tw.tween_property(page, "modulate:a", 1.0, 0.2) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(page, "offset_transform_position", Vector2.ZERO, 0.26) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


# ══════════════════════════════════════════════════════
#  歌曲页
# ══════════════════════════════════════════════════════

func _setup_song_vlist() -> void:
	if _song_vlist != null:
		return
	_song_vlist = VirtualListLib.new()
	_song_vlist.columns = SONG_COLUMNS
	_song_vlist.row_gap = SONG_ROW_GAP
	_song_vlist.col_gap = SONG_COL_GAP
	_song_vlist.margin_rows = GRID_MARGIN_ROWS
	_song_vlist.on_row_ready = _on_card_ready
	_song_vlist.on_row_bind = _bind_song_card
	_song_vlist.setup(%SongsScroll, %SongsListContent, SONG_CARD_SCENE)


func _load_songs() -> void:
	_song_req_version += 1
	var version := _song_req_version

	if NetManager.instance == null:
		_show_songs_message("商店服务不可用")
		return
	if not NetManager.instance.is_online:
		if NetManager.instance.connect_state == NetManager.ConnectState.OFFLINE_MODE:
			_show_songs_message("在线模式未开启")
		else:
			_show_songs_message("无法连接到服务器")
		return

	if _song_items.is_empty():
		_show_songs_message("正在加载…")

	var result: Dictionary = await ResourceManager.instance.get_chart_list(
		_song_page, PAGE_SIZE, _search_text,
		SORT_FIELDS[_sort_index], _sort_order
	)
	if version != _song_req_version:
		return

	if not result.get("ok", false):
		GLogger.warning("加载商店列表失败: %s" % str(result.get("error", "")), "StoreView")
		_show_songs_message("加载失败，请稍后重试")
		return

	var data: Dictionary = result.get("data", {})
	var charts: Array = data.get("charts", [])
	_song_total = int(data.get("total", charts.size()))
	_song_items.clear()
	for chart in charts:
		if chart is Dictionary:
			_song_items.append(_make_song_item(chart))

	_set_empty(Tab.SONGS, "" if not _song_items.is_empty() else "没有找到谱面")
	_update_pager()
	_bind_animate = true
	_song_vlist.set_total(_song_items.size(), true)
	_bind_animate = false
	_update_batch_button()


## 服务端 ChartResponse → 卡片/详情共用的规范化条目
func _make_song_item(chart: Dictionary) -> Dictionary:
	var hash_str := str(chart.get("hash", ""))
	var server := ""
	if NetManager.instance != null:
		server = NetManager.instance.server_url
	var state := int(ResourceManager.DownloadState.NOT_DOWNLOADED)
	if not hash_str.is_empty():
		state = ResourceManager.instance.get_download_state(hash_str)
	return {
		"kind": "song",
		"hash": hash_str,
		"key": hash_str,
		"title": str(chart.get("title", chart.get("name", "未命名谱面"))),
		"author": str(chart.get("midiAuthor", chart.get("artistName", ""))),
		"album": str(chart.get("albumName", "")),
		"song": str(chart.get("songName", "")),
		"uploader": str(chart.get("uploaderName", "")),
		"desc": str(chart.get("description", "")),
		"difficulty": str(chart.get("difficulty", "")),
		"size_bytes": int(chart.get("fileSize", 0)),
		"duration_sec": int(chart.get("durationSec", 0)),
		"has_vocal": bool(chart.get("hasVocal", false)),
		"downloads": int(chart.get("downloadCount", -1)),
		# 商店列表响应字段为 playCount / likeCount / dislikeCount；
		# trialCount / upCount / downCount 是旧命名，保留兜底
		"plays": int(chart.get("playCount", chart.get("trialCount", -1))),
		"likes": int(chart.get("likeCount", chart.get("upCount", -1))),
		"dislikes": int(chart.get("dislikeCount", chart.get("downCount", -1))),
		"uploaded_at": str(chart.get("uploadedAt", "")),
		"cover_url": ("%s/api/charts/%s/cover" % [server, hash_str]) \
			if (not server.is_empty() and not hash_str.is_empty()) else "",
		"state": state,
		"raw": chart,
	}


func _bind_song_card(node, idx: int) -> void:
	if idx < 0 or idx >= _song_items.size():
		return
	var item: Dictionary = _song_items[idx]
	if not str(item.get("hash", "")).is_empty():
		item["state"] = ResourceManager.instance.get_download_state(str(item.get("hash", "")))
	node.call("set_item", item, _bind_animate)


func _on_card_ready(node) -> void:
	node.detail_requested.connect(_on_detail_requested)
	node.download_requested.connect(_on_card_download_requested)


func _on_detail_requested(item: Dictionary, source_rect: Rect2) -> void:
	_detail_source_node = _find_bound_node_for_item(item)
	_detail_source_item = item
	%DetailLayer.open(item, source_rect)


func _on_detail_closed() -> void:
	var source := _detail_source_node
	var source_item := _detail_source_item
	_detail_source_node = null
	_detail_source_item = {}
	# 弹窗关闭后优先把焦点还给打开它的那张卡片；只有卡片已被池回收/换绑时才退回首项
	if UiStatMGR.current_state == UIStateManager.UIState.STORE_VIEW:
		if is_instance_valid(source) and source.is_visible_in_tree() \
				and _node_shows_item(source, source_item):
			source.grab_focus()
		else:
			call_deferred("focus_first")


# ── 搜索 / 排序 / 分页 ────────────────────────────────

func _on_search_changed(text: String) -> void:
	_search_text = text
	if _current_tab == Tab.SONGS:
		if _search_timer and _search_timer.timeout.is_connected(_on_search_debounced):
			_search_timer.timeout.disconnect(_on_search_debounced)
		_search_timer = get_tree().create_timer(0.35)
		_search_timer.timeout.connect(_on_search_debounced)
	elif _current_tab >= Tab.SKINS and _current_tab <= Tab.SOUNDFONTS:
		_rebuild_category(_current_tab)
	elif _current_tab == Tab.DOWNLOADS:
		_refresh_downloads_page(false)


func _on_search_submitted(_text: String) -> void:
	if _current_tab != Tab.SONGS:
		return
	if _search_timer and _search_timer.timeout.is_connected(_on_search_debounced):
		_search_timer.timeout.disconnect(_on_search_debounced)
	_search_timer = null
	_song_page = 1
	_load_songs()


func _on_search_debounced() -> void:
	_search_timer = null
	_song_page = 1
	_load_songs()


func _on_filter_pressed() -> void:
	_sort_index = (_sort_index + 1) % SORT_FIELDS.size()
	_apply_sort_icons()
	_apply_toolbar_for_tab()
	if _current_tab == Tab.SONGS:
		_song_page = 1
		_load_songs()


func _on_order_pressed() -> void:
	_sort_order = "asc" if _sort_order == "desc" else "desc"
	_apply_sort_icons()
	_apply_toolbar_for_tab()
	if _current_tab == Tab.SONGS:
		_song_page = 1
		_load_songs()
	elif _current_tab >= Tab.SKINS and _current_tab <= Tab.SOUNDFONTS:
		_rebuild_category(_current_tab)
	elif _current_tab == Tab.DOWNLOADS:
		_refresh_downloads_page(false)


func _apply_sort_icons() -> void:
	%FilterDataBtn.icon = [
		StoreIconsLib.downloads(),
		StoreIconsLib.plays(),
		StoreIconsLib.likes(),
		StoreIconsLib.uploaded(),
	][_sort_index]
	%SortOrderBtn.icon = StoreIconsLib.order_asc() if _sort_order == "asc" else StoreIconsLib.order_desc()


func _on_previ_pressed() -> void:
	if _song_page <= 1:
		return
	_song_page -= 1
	_load_songs()


func _on_next_pressed() -> void:
	var total_pages := _total_pages()
	if _song_page >= total_pages:
		return
	_song_page += 1
	_load_songs()


func _total_pages() -> int:
	return maxi(1, ceili(float(_song_total) / float(PAGE_SIZE)))


func _update_pager() -> void:
	if _song_total <= 0:
		%PagerText.text = "—"
		%PreviBtn.disabled = true
		%NextBtn.disabled = true
		return
	%PagerText.text = "%d / %d" % [_song_page, _total_pages()]
	%PreviBtn.disabled = _song_page <= 1
	%NextBtn.disabled = _song_page >= _total_pages()


func _show_songs_message(text: String) -> void:
	_song_items.clear()
	_song_total = 0
	if _song_vlist != null:
		_song_vlist.clear()
	_set_empty(Tab.SONGS, text)
	_update_pager()
	_update_batch_button()


# ══════════════════════════════════════════════════════
#  皮肤 / 特效 / 音源（本地资源预览数据）
# ══════════════════════════════════════════════════════

func _ensure_category(tab: int) -> void:
	if not bool(_category_loaded.get(tab, false)):
		_category_cache[tab] = _build_category_items(tab)
		_category_loaded[tab] = true
	_ensure_category_vlist(tab)


func _ensure_category_vlist(tab: int) -> void:
	if _category_vlists.has(tab):
		return
	var vl := VirtualListLib.new()
	vl.columns = SONG_COLUMNS
	vl.row_gap = SONG_ROW_GAP
	vl.col_gap = SONG_COL_GAP
	vl.margin_rows = GRID_MARGIN_ROWS
	vl.on_row_ready = _on_card_ready
	vl.on_row_bind = func(node, idx: int) -> void: _bind_category_card(node, idx, tab)
	vl.setup(_category_scrolls[tab], _category_lists[tab], CATEGORY_CARD_SCENE)
	_category_vlists[tab] = vl


func _build_category_items(tab: int) -> Array:
	var items: Array = []
	match tab:
		Tab.SKINS:
			if SkinMGR != null:
				var keys := SkinMGR.skins_index.keys()
				keys.sort()
				for key in keys:
					var meta = SkinMGR.skins_index[key]
					var builtin := false
					var skin_path := ""
					if meta is SkinMetadata:
						builtin = meta.is_builtin
						skin_path = meta.path
					elif meta is Dictionary:
						builtin = bool(meta.get("is_builtin", false))
						skin_path = str(meta.get("path", ""))
					var title := str(key).replace(" [内置]", "")
					# 只解码一张代表贴图（整包十张贴图全读既慢又会把用户的损坏文件一路报错）
					var preview := _skin_preview_texture(skin_path)
					var texture_count := _count_image_files(skin_path)
					items.append({
						"kind": "skin",
						"key": str(key),
						"hash": "",
						"title": title,
						"author": "内置资源" if builtin else "本地导入",
						"desc": "音符皮肤包，包含 %d 张贴图，可替换演奏界面的音符、长条与判定光效外观。" % texture_count,
						"size_text": "%d 张贴图" % texture_count,
						"cover_tex": preview,
						"is_builtin": builtin,
						"downloads": -1,
						"plays": -1,
						"likes": -1,
						"dislikes": -1,
						"state": CategoryCardLib.STATE_INSTALLED,
					})
		Tab.EFFECTS:
			if ParticleMGR != null:
				var keys := ParticleMGR.get_particle_list()
				for key in keys:
					var data: Dictionary = ParticleMGR.get_particle_data(key)
					var builtin := bool(data.get("is_builtin", false))
					var textures: Array = ParticleMGR.get_base_textures(key)
					if textures.is_empty():
						textures = ParticleMGR.get_emitter_textures(key)
					var preview: Texture2D = null
					if not textures.is_empty() and textures[0] is Texture2D:
						preview = textures[0]
						# 精灵图是一整张序列帧：取第一帧做封面，避免满屏小格子
						var frame_px := int(data.get("size", 0))
						if frame_px > 0 and preview.get_width() >= frame_px \
								and preview.get_height() >= frame_px:
							var frame_atlas := AtlasTexture.new()
							frame_atlas.atlas = preview
							frame_atlas.region = Rect2(0, 0, frame_px, frame_px)
							preview = frame_atlas
					var frame := int(data.get("frame", 0))
					var fps := float(data.get("fps", 0.0))
					var roles: Array[String] = []
					if not data.get("base_files", []).is_empty():
						roles.append("基础粒子")
					if not data.get("emitter_files", []).is_empty():
						roles.append("散射粒子")
					items.append({
						"kind": "effect",
						"key": str(key),
						"hash": "",
						"title": str(key).replace(" [内置]", ""),
						"author": "内置资源" if builtin else "本地导入",
						"desc": "判定特效包（%s），%d 帧 @ %.0f FPS，可替换 Perfect / Great / Good / Bad 的粒子表现。" % [
							" / ".join(roles) if not roles.is_empty() else "未声明角色", frame, fps],
						"size_text": "%d 帧 · %d FPS" % [frame, int(fps)],
						"cover_tex": preview,
						"is_builtin": builtin,
						"downloads": -1,
						"plays": -1,
						"likes": -1,
						"dislikes": -1,
						"state": CategoryCardLib.STATE_INSTALLED,
					})
		Tab.SOUNDFONTS:
			if FileSystemManager.instance != null:
				var index: Dictionary = FileSystemManager.instance.soundfonts_index
				var keys := index.keys()
				keys.sort()
				for key in keys:
					var data: Dictionary = index[key]
					var builtin := bool(data.get("is_builtin", false))
					var size_mb := float(data.get("size_mb", 0.0))
					items.append({
						"kind": "soundfont",
						"key": str(key),
						"hash": "",
						"title": str(key),
						"author": "内置音源" if builtin else "本地导入",
						"desc": "音源库（.sf2），用于演奏与音乐播放时的音色合成。",
						"size_text": "%.1f MB" % size_mb,
						"cover_tex": null,
						"is_builtin": builtin,
						"downloads": -1,
						"plays": -1,
						"likes": -1,
						"dislikes": -1,
						"state": CategoryCardLib.STATE_INSTALLED,
					})
	return items




## 皮肤预览：只取一张代表贴图（short / block → 长条），不加载整套皮肤
func _skin_preview_texture(skin_path: String) -> Texture2D:
	if skin_path.is_empty():
		return null
	for base_name in ["short", "block", "long-f", "long-t", "instant"]:
		for ext in ["png", "svg"]:
			var file_path := "%s/%s.%s" % [skin_path.trim_suffix("/"), base_name, ext]
			if file_path.begins_with("res://"):
				if ResourceLoader.exists(file_path):
					return load(file_path)
			elif FileAccess.file_exists(file_path):
				var image := ImageUtil.load_image_file(file_path)
				if image != null:
					return ImageTexture.create_from_image(image)
	return null


## 统计皮肤目录里的贴图文件数（只列目录，不解码）
func _count_image_files(skin_path: String) -> int:
	if skin_path.is_empty():
		return 0
	var files := DirAccess.get_files_at(skin_path.trim_suffix("/"))
	var count := 0
	for file_name in files:
		var ext := str(file_name).get_extension().to_lower()
		if ext in ["png", "svg"]:
			count += 1
	return count

func _rebuild_category(tab: int) -> void:
	_ensure_category(tab)
	var view := _filtered_category(tab)
	_category_view[tab] = view
	var vl: VirtualListLib = _category_vlists.get(tab)
	if vl == null:
		return
	_bind_animate = true
	vl.set_total(view.size(), true)
	_bind_animate = false
	_set_empty(tab, "" if not view.is_empty() \
		else "没有找到%s" % ["皮肤", "特效", "音源"][clampi(tab - Tab.SKINS, 0, 2)])


func _filtered_category(tab: int) -> Array:
	var source: Array = _category_cache.get(tab, [])
	var query := _search_text.strip_edges().to_lower()
	var view: Array = []
	for item in source:
		if not query.is_empty():
			var haystack := "%s %s %s" % [
				str(item.get("title", "")), str(item.get("author", "")), str(item.get("desc", ""))
			]
			if not haystack.to_lower().contains(query):
				continue
		view.append(item)
	var descending := _sort_order == "desc"
	view.sort_custom(func(a, b) -> bool:
		var ka := str(a.get("title", "")).to_lower()
		var kb := str(b.get("title", "")).to_lower()
		return ka > kb if descending else ka < kb
	)
	return view


func _bind_category_card(node, idx: int, tab: int) -> void:
	var view: Array = _category_view.get(tab, [])
	if idx < 0 or idx >= view.size():
		return
	node.call("set_item", view[idx], _bind_animate)


func _on_resources_ready() -> void:
	# 资源扫描在商店打开后才完成（极少见）：作废本地分类缓存，下次进入时重建
	for tab in [Tab.SKINS, Tab.EFFECTS, Tab.SOUNDFONTS]:
		_category_loaded[tab] = false
	if _current_tab >= Tab.SKINS and _current_tab <= Tab.SOUNDFONTS:
		_rebuild_category(_current_tab)


# ══════════════════════════════════════════════════════
#  下载
# ══════════════════════════════════════════════════════

func _on_card_download_requested(item: Dictionary) -> void:
	_request_download(item)


func _on_detail_download_requested(item: Dictionary) -> void:
	_request_download(item)


## 单曲下载入口：空闲时立刻开跑，忙时排队（批量下载/另一个单曲下载进行中）
func _request_download(item: Dictionary) -> void:
	var hash_str := str(item.get("hash", ""))
	if hash_str.is_empty():
		return
	if ResourceManager.instance.get_download_state(hash_str) == ResourceManager.DownloadState.DOWNLOADED:
		_set_entry_state(hash_str, ResourceManager.DownloadState.DOWNLOADED,
			ResourceManager.DownloadStage.RESCAN, 1.0)
		return
	if _is_hash_queue(hash_str) or _active_hashes.has(hash_str):
		return

	if _batch_running or _manual_running or not _active_hashes.is_empty():
		_manual_queue.append(item)
		_ensure_download_entry(item, DownloadRowLib.STATE_QUEUED, -1, -1.0)
		if _current_tab == Tab.DOWNLOADS:
			_refresh_downloads_page(false)
		_update_batch_button()
		return

	_manual_queue.append(item)
	_run_manual_queue()


func _run_manual_queue() -> void:
	if _manual_running or _batch_running:
		return
	_manual_running = true
	while not _manual_queue.is_empty():
		if _batch_running:
			break
		var item: Dictionary = _manual_queue.pop_front()
		var hash_str := str(item.get("hash", ""))
		if ResourceManager.instance.get_download_state(hash_str) == ResourceManager.DownloadState.DOWNLOADED:
			_set_entry_state(hash_str, ResourceManager.DownloadState.DOWNLOADED,
				ResourceManager.DownloadStage.RESCAN, 1.0)
			continue
		await _start_download(item)
	_manual_running = false
	_update_batch_button()
	if _current_tab == Tab.DOWNLOADS:
		_refresh_downloads_page(false)


func _is_hash_queue(hash_str: String) -> bool:
	if _download_entries.has(hash_str):
		var state := int(_download_entries[hash_str].get("state", -1))
		if state == DownloadRowLib.STATE_QUEUED:
			return true
	for item in _manual_queue:
		if str(item.get("hash", "")) == hash_str:
			return true
	for item in _batch_queue:
		if str(item.get("hash", "")) == hash_str:
			return true
	return false


func _start_download(item: Dictionary, from_batch: bool = false) -> void:
	var hash_str := str(item.get("hash", ""))
	if hash_str.is_empty():
		return
	if _active_hashes.has(hash_str):
		return
	var state := ResourceManager.instance.get_download_state(hash_str)
	if state == ResourceManager.DownloadState.DOWNLOADED:
		_set_entry_state(hash_str, ResourceManager.DownloadState.DOWNLOADED,
			ResourceManager.DownloadStage.RESCAN, 1.0)
		_refresh_card_state(hash_str)
		return
	if state == ResourceManager.DownloadState.DOWNLOADING and not from_batch:
		return

	item["state"] = ResourceManager.DownloadState.DOWNLOADING
	_ensure_download_entry(item, ResourceManager.DownloadState.DOWNLOADING,
		ResourceManager.DownloadStage.METADATA, 0.0)
	_active_hashes[hash_str] = true
	_refresh_bound_card(hash_str)
	if _current_tab == Tab.DOWNLOADS:
		_refresh_downloads_page(false)

	var result: Dictionary = await ResourceManager.instance.download_chart(hash_str,
		Callable(self, "_on_download_progress").bind(hash_str), _get_download_hint(item))

	_active_hashes.erase(hash_str)
	if result.get("ok", false):
		_set_entry_state(hash_str, ResourceManager.DownloadState.DOWNLOADED,
			ResourceManager.DownloadStage.RESCAN, 1.0)
		GLogger.info("商店谱面下载完成: %s" % hash_str, "StoreView")
	else:
		var entry: Dictionary = _download_entries.get(hash_str, {})
		_set_entry_state(hash_str, ResourceManager.DownloadState.FAILED,
			int(entry.get("stage", ResourceManager.DownloadStage.METADATA)),
			float(entry.get("percent", -1.0)))
		GLogger.warning("商店谱面下载失败: %s (%s)" % [hash_str, str(result.get("error", ""))], "StoreView")

	if _current_tab == Tab.DOWNLOADS:
		_refresh_downloads_page(false)


## ⚠️ chart_hash 必须是**最后一个参数**：Callable.bind 的绑定参数追加在调用参数之后
func _on_download_progress(stage: int, percent: float, chart_hash: String) -> void:
	var entry: Dictionary = _download_entries.get(chart_hash, {})
	if entry.is_empty():
		return
	entry["stage"] = stage
	entry["percent"] = percent
	if _current_tab != Tab.DOWNLOADS:
		return
	_refresh_hero()
	_refresh_download_row(chart_hash)


func _get_download_hint(item: Dictionary) -> Dictionary:
	var raw: Dictionary = item.get("raw", {})
	if raw.is_empty():
		return {}
	return {
		"fileSize": int(raw.get("fileSize", 0)),
		"hasCover": bool(raw.get("hasCover", false)),
		"songName": str(raw.get("songName", "")),
		"difficulty": str(raw.get("difficulty", "")),
		"hasVocal": bool(raw.get("hasVocal", false)),
		"vocalSize": int(raw.get("vocalSize", 0)),
		"vocalFormat": str(raw.get("vocalFormat", "")),
	}


func _ensure_download_entry(item: Dictionary, state: int, stage: int, percent: float) -> void:
	var hash_str := str(item.get("hash", ""))
	if hash_str.is_empty():
		return
	var order := _download_order
	if _download_entries.has(hash_str):
		order = int(_download_entries[hash_str].get("order", order))
	else:
		_download_order += 1
		order = _download_order
	_download_entries[hash_str] = {
		"hash": hash_str,
		"item": item,
		"state": state,
		"stage": stage,
		"percent": percent,
		"order": order,
	}


func _set_entry_state(hash_str: String, state: int, stage: int, percent: float) -> void:
	if not _download_entries.has(hash_str):
		return
	var entry: Dictionary = _download_entries[hash_str]
	entry["state"] = state
	entry["stage"] = stage
	entry["percent"] = percent
	_refresh_card_state(hash_str)
	if _current_tab == Tab.DOWNLOADS:
		_refresh_downloads_page(false)


func _refresh_card_state(hash_str: String) -> void:
	for item in _song_items:
		if str(item.get("hash", "")) == hash_str:
			item["state"] = ResourceManager.instance.get_download_state(hash_str)
			break
	_refresh_bound_card(hash_str)
	_update_batch_button()


func _refresh_bound_card(hash_str: String) -> void:
	if _song_vlist != null:
		for node in _song_vlist.bound_nodes():
			if not is_instance_valid(node):
				continue
			var node_item = node.get("item")
			if node_item is Dictionary and str(node_item.get("hash", "")) == hash_str:
				node.call("refresh_download_state")
	if %DetailLayer.is_open():
		%DetailLayer.refresh_download_state()


func _sync_song_states() -> void:
	for item in _song_items:
		var hash_str := str(item.get("hash", ""))
		if hash_str.is_empty():
			continue
		item["state"] = ResourceManager.instance.get_download_state(hash_str)


## 切到下载管理页时，把当前页已经下载的谱面并入记录（只做一次）
func _seed_download_entries() -> void:
	for item in _song_items:
		var hash_str := str(item.get("hash", ""))
		if hash_str.is_empty() or _download_entries.has(hash_str):
			continue
		if ResourceManager.instance.get_download_state(hash_str) == ResourceManager.DownloadState.DOWNLOADED:
			_ensure_download_entry(item, ResourceManager.DownloadState.DOWNLOADED,
				ResourceManager.DownloadStage.RESCAN, 1.0)


# ── 批量下载 ──────────────────────────────────────────

func _on_batch_download_pressed() -> void:
	if _batch_running or _manual_running or not _active_hashes.is_empty() \
			or _current_tab != Tab.SONGS:
		return
	var pending: Array = []
	for item in _song_items:
		var hash_str := str(item.get("hash", ""))
		if hash_str.is_empty() or _download_entries.has(hash_str):
			continue
		if ResourceManager.instance.get_download_state(hash_str) == ResourceManager.DownloadState.DOWNLOADED:
			continue
		if _active_hashes.has(hash_str):
			continue
		pending.append(item)
	if pending.is_empty():
		return

	_batch_running = true
	for item in pending:
		_ensure_download_entry(item, DownloadRowLib.STATE_QUEUED, -1, -1.0)
		_batch_queue.append(item)
	_update_batch_button()
	_run_batch()


func _run_batch() -> void:
	while not _batch_queue.is_empty():
		var item: Dictionary = _batch_queue.pop_front()
		var hash_str := str(item.get("hash", ""))
		_batch_current = hash_str
		_update_batch_button()
		if ResourceManager.instance.get_download_state(hash_str) == ResourceManager.DownloadState.DOWNLOADED:
			_set_entry_state(hash_str, ResourceManager.DownloadState.DOWNLOADED,
				ResourceManager.DownloadStage.RESCAN, 1.0)
			continue
		await _start_download(item, true)
	_batch_current = ""
	_batch_running = false
	_update_batch_button()
	_run_manual_queue()


func _update_batch_button() -> void:
	var remain := _batch_queue.size() + (0 if _batch_current.is_empty() else 1)
	%BatchDownloadBtn.text = "批量下载" if remain <= 0 else "批量下载 (%d)" % remain
	%BatchDownloadBtn.disabled = _current_tab != Tab.SONGS or _batch_running or _manual_running \
		or not _active_hashes.is_empty() or not _has_downloadable_songs()


func _has_downloadable_songs() -> bool:
	for item in _song_items:
		var hash_str := str(item.get("hash", ""))
		if hash_str.is_empty() or _active_hashes.has(hash_str):
			continue
		if ResourceManager.instance.get_download_state(hash_str) != ResourceManager.DownloadState.DOWNLOADED:
			return true
	return false


# ══════════════════════════════════════════════════════
#  下载管理页
# ══════════════════════════════════════════════════════

func _ensure_download_vlist() -> void:
	if _dl_vlist != null:
		return
	_dl_vlist = VirtualListLib.new()
	_dl_vlist.columns = 1
	_dl_vlist.row_gap = 8.0
	_dl_vlist.margin_rows = 2
	_dl_vlist.on_row_ready = _on_download_row_ready
	_dl_vlist.on_row_bind = _bind_download_row
	_dl_vlist.setup(%DownloadsScroll, %DownloadsListContent, DOWNLOAD_ROW_SCENE)


func _on_download_row_ready(node) -> void:
	node.detail_requested.connect(_on_detail_requested)


func _bind_download_row(node, idx: int) -> void:
	if idx < 0 or idx >= _download_rows.size():
		return
	var entry: Dictionary = _download_rows[idx]
	node.call("set_entry", entry.get("item", {}), int(entry.get("state", 0)),
		int(entry.get("stage", -1)), float(entry.get("percent", -1.0)))


func _refresh_downloads_page(reset_scroll: bool) -> void:
	if _dl_vlist == null:
		return
	var active := _find_active_entry()
	var active_hash := str(active.get("hash", "")) if not active.is_empty() else ""
	var rows: Array = []
	var query := _search_text.strip_edges().to_lower()
	for entry in _download_entries.values():
		if str(entry.get("hash", "")) == active_hash:
			continue
		if not query.is_empty():
			var item: Dictionary = entry.get("item", {})
			var haystack := "%s %s" % [str(item.get("title", "")), str(item.get("author", ""))]
			if not haystack.to_lower().contains(query):
				continue
		rows.append(entry)
	rows.sort_custom(func(a, b) -> bool:
		var pa := _row_priority(int(a.get("state", 0)))
		var pb := _row_priority(int(b.get("state", 0)))
		if pa != pb:
			return pa < pb
		return int(a.get("order", 0)) < int(b.get("order", 0)) \
			if _sort_order == "asc" else int(a.get("order", 0)) > int(b.get("order", 0))
	)
	_download_rows = rows

	if rows.size() != _dl_last_count or reset_scroll:
		_dl_last_count = rows.size()
		_bind_animate = false
		_dl_vlist.set_total(rows.size(), reset_scroll)
	else:
		_dl_vlist.refresh_all()

	_refresh_hero()
	%DownloadsEmpty.visible = rows.is_empty() and active.is_empty()
	%DownloadsEmpty.text = "还没有下载记录"
	_update_batch_button()


func _row_priority(state: int) -> int:
	match state:
		ResourceManager.DownloadState.DOWNLOADING: return 0
		DownloadRowLib.STATE_QUEUED: return 1
		ResourceManager.DownloadState.FAILED: return 2
		ResourceManager.DownloadState.DOWNLOADED: return 3
	return 4


func _find_active_entry() -> Dictionary:
	var best: Dictionary = {}
	for entry in _download_entries.values():
		if int(entry.get("state", 0)) != ResourceManager.DownloadState.DOWNLOADING:
			continue
		if best.is_empty() or int(entry.get("order", 0)) > int(best.get("order", 0)):
			best = entry
	return best


func _refresh_hero() -> void:
	var active := _find_active_entry()
	if active.is_empty():
		%HeroBody.visible = false
		%HeroEmpty.visible = true
		_hero_hash = ""
		return
	%HeroBody.visible = true
	%HeroEmpty.visible = false

	var item: Dictionary = active.get("item", {})
	var hash_str := str(active.get("hash", ""))
	if hash_str != _hero_hash:
		_hero_hash = hash_str
		_load_hero_cover(item)

	var percent := float(active.get("percent", -1.0))
	var stage := int(active.get("stage", -1))
	%TitleText.set_scroll_text(str(item.get("title", "未命名谱面")))
	%StageText.text = _stage_text(stage) + (" %d%%" % int(round(percent * 100.0)) if percent >= 0.0 else "")
	%HeroProgress.value = clampf(percent * 100.0, 0.0, 100.0) if percent >= 0.0 else 0.0
	%PercentText.text = ("%d%%" % int(round(percent * 100.0))) if percent >= 0.0 else "…"
	var author := str(item.get("author", ""))
	var album := str(item.get("album", ""))
	var size_text := StoreIconsLib.format_size(int(item.get("size_bytes", 0)))
	var meta_parts: Array[String] = []
	if not author.is_empty():
		meta_parts.append(author)
	if not album.is_empty():
		meta_parts.append(album)
	%MetaText.set_scroll_text("  ·  ".join(meta_parts))
	%DetailText.text = "文件 %s" % size_text


func _load_hero_cover(item: Dictionary) -> void:
	_hero_cover_version += 1
	var version := _hero_cover_version
	%CoverImage.texture = null
	%CoverPlaceholder.visible = true
	var local_tex = item.get("cover_tex")
	if local_tex is Texture2D:
		%CoverImage.texture = local_tex
		%CoverPlaceholder.visible = false
		return
	var url := str(item.get("cover_url", ""))
	if url.is_empty():
		return
	HttpImageLoader.load(url, self, func(tex: Texture2D) -> void:
		if version != _hero_cover_version:
			return
		if tex:
			%CoverImage.texture = tex
			%CoverPlaceholder.visible = false
	)


func _refresh_download_row(hash_str: String) -> void:
	if _dl_vlist == null:
		return
	for i in _download_rows.size():
		var entry: Dictionary = _download_rows[i]
		if str(entry.get("hash", "")) != hash_str:
			continue
		var node := _dl_vlist.node_at(i)
		if node != null:
			node.call("set_entry", entry.get("item", {}), int(entry.get("state", 0)),
				int(entry.get("stage", -1)), float(entry.get("percent", -1.0)))
		return


func _stage_text(stage: int) -> String:
	match stage:
		ResourceManager.DownloadStage.METADATA: return "正在获取谱面信息"
		ResourceManager.DownloadStage.COVER: return "正在下载封面"
		ResourceManager.DownloadStage.MIDI: return "正在下载 MIDI"
		ResourceManager.DownloadStage.JSON: return "正在写入谱面信息"
		ResourceManager.DownloadStage.RESCAN: return "正在刷新本地曲库"
		ResourceManager.DownloadStage.VOCAL: return "正在下载人声音频"
	return "正在下载"


# ══════════════════════════════════════════════════════
#  空状态点击重载
# ══════════════════════════════════════════════════════

## 空状态 Label 收到点击 → 当前标签页重新加载（各页加载失败后就地重试的唯一入口）
func _on_empty_gui_input(event: InputEvent) -> void:
	if not event is InputEventMouseButton:
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	_reload_page(_current_tab)


func _reload_page(tab: int) -> void:
	match tab:
		Tab.SONGS:
			_song_page = 1
			_load_songs()
		Tab.DOWNLOADS:
			_sync_song_states()
			_seed_download_entries()
			_refresh_downloads_page(true)
		_:
			_reload_local_category(tab)


## 皮肤 / 特效 / 音源页的重载入口。
## 这三页目前只读本地资源索引（远端分类接口未就绪），这里先作废旧缓存再按最新索引重建；
## 等远端接口可用后，换成本函数内发起重新拉取即可，调用方无需改动。
func _reload_local_category(tab: int) -> void:
	if tab < Tab.SKINS or tab > Tab.SOUNDFONTS:
		return
	_category_loaded[tab] = false
	_rebuild_category(tab)


# ══════════════════════════════════════════════════════
#  状态 / 焦点 / 返回
# ══════════════════════════════════════════════════════

func _on_state_changed(old_state: UIStateManager.UIState,
		new_state: UIStateManager.UIState) -> void:
	if new_state == UIStateManager.UIState.STORE_VIEW:
		_sync_song_states()
		if _song_vlist != null:
			for node in _song_vlist.bound_nodes():
				if is_instance_valid(node):
					node.call("refresh_download_state")
		if _current_tab == Tab.DOWNLOADS:
			_refresh_downloads_page(false)
		_update_tab_underline(true)
		TextScrollMGR.resume_page(self)
	elif old_state == UIStateManager.UIState.STORE_VIEW \
			and new_state != UIStateManager.UIState.STORE_VIEW:
		if %DetailLayer.is_open():
			%DetailLayer.close()
		TextScrollMGR.suspend_page(self)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if %DetailLayer.handle_back_request():
			get_viewport().set_input_as_handled()


## Main 的全局返回键调用：详情打开时先关详情，返回 true 表示事件已被消费
func handle_back_request() -> bool:
	return %DetailLayer.handle_back_request()


## FocusManager 的商店页焦点落点：当前页第一张可见卡片，没有卡片就聚焦当前标签
func focus_first() -> void:
	var vl := _active_vlist()
	if vl != null:
		var best: Control = null
		var best_index := 2147483647
		for node in vl.bound_nodes():
			if not is_instance_valid(node) or not node.visible:
				continue
			var idx := int(node.get_meta(&"row_index", 2147483647))
			if idx < best_index:
				best = node
				best_index = idx
		if best != null:
			best.grab_focus()
			return
	if _current_tab >= 0 and _current_tab < _tab_buttons.size():
		_tab_buttons[_current_tab].grab_focus()


## 找到当前页正在显示指定条目的池节点（详情关闭后恢复焦点用）
func _find_bound_node_for_item(item: Dictionary) -> Control:
	var vl := _active_vlist()
	if vl == null:
		return null
	for node in vl.bound_nodes():
		if is_instance_valid(node) and _node_shows_item(node, item):
			return node as Control
	return null


func _node_shows_item(node: Control, item: Dictionary) -> bool:
	var node_item = node.get("item")
	if not node_item is Dictionary:
		return false
	var hash_str := str(item.get("hash", ""))
	if not hash_str.is_empty():
		return str(node_item.get("hash", "")) == hash_str
	var key := str(item.get("key", ""))
	return not key.is_empty() and str(node_item.get("key", "")) == key


func _active_vlist() -> VirtualListLib:
	match _current_tab:
		Tab.SONGS: return _song_vlist
		Tab.DOWNLOADS: return _dl_vlist
		_:
			return _category_vlists.get(_current_tab)


# ══════════════════════════════════════════════════════
#  主题
# ══════════════════════════════════════════════════════

func apply_theme() -> void:
	if not ThemeMGR:
		return
	var surface := ThemeMGR.get_color("surface")
	var surface_low := ThemeMGR.get_color("surface_low")
	var surface_high := ThemeMGR.get_color("surface_high")
	var border := ThemeMGR.get_color("border")
	var text_secondary := ThemeMGR.get_color("text_secondary")
	var text_dim := ThemeMGR.get_color("text_dim")
	var primary := ThemeMGR.get_color("primary")
	var primary_light := ThemeMGR.get_color("primary_light")
	var primary_dark := ThemeMGR.get_color("primary_dark")
	var text_primary := ThemeMGR.get_color("text_primary")
	var is_light := ThemeMGR.get_appearance() == "light"
	# 次要文字从 text_dim（浅色下偏灰）提到 text_secondary，保证小字号可读
	var muted_text := text_secondary if is_light else text_dim

	var top_sb: StyleBoxFlat = %TopBar.get_theme_stylebox("panel")
	top_sb.bg_color = ThemeMGR._tint_keep_alpha(surface, 0.97)
	top_sb.border_color = ThemeMGR._tint_keep_alpha(primary, 0.55 if is_light else 0.4)

	%SearchIcon.modulate = text_secondary
	%TabUnderlinePanel.get_theme_stylebox("panel").bg_color = primary_dark if is_light else primary_light

	# 分页
	for btn in [%PreviBtn, %NextBtn]:
		var b := btn as Button
		ThemeMGR.style_flat_button(b)
		b.add_theme_color_override("icon_normal_color", text_secondary)
		b.add_theme_color_override("icon_hover_color", text_primary)
	%PagerText.get_theme_stylebox("normal").bg_color = surface_low

	# 下载管理
	var hero_sb: StyleBoxFlat = %HeroPanel.get_theme_stylebox("panel")
	hero_sb.bg_color = ThemeMGR._tint_keep_alpha(surface, 0.96)
	hero_sb.border_color = ThemeMGR._tint_keep_alpha(primary, 0.45)
	var hero_cover_sb: StyleBoxFlat = %CoverWrapPanel.get_theme_stylebox("panel")
	hero_cover_sb.bg_color = surface_high if is_light else surface_low
	hero_cover_sb.border_color = border
	%HeroProgress.get_theme_stylebox("background").bg_color = surface_low.darkened(0.15)
	%HeroProgress.get_theme_stylebox("fill").bg_color = primary
	%CoverPlaceholder.modulate = muted_text
	%CoverPlaceholder.modulate.a = 0.35

	_refresh_hero()
	_update_batch_button()

## 商店页面（重设计版）
##
## 结构：
##   TopBar    左侧搜索 / 排序 / 批量下载 / 人声开关，右侧五个标签页（歌曲 / 皮肤 / 特效 / 音源 / 下载管理）
##   Tabs      TabContainer（tabs_visible=false）：四个列表页（ScrollContainer → ListContent → VirtualList 池）
##             → 共享空状态页 → 下载管理页；切换标签只改 current_tab，空状态靠切到共享页表达
##   详情页由 PopupWindow 的谱面详情页承载（ChartDetailPage，默认 STORE 模式）
##   Bottom    歌曲页分页条（进场/退场由本脚本的 _play_enter/_play_exit 驱动）
##
## 数据：
##   歌曲来自服务端 ResourceManager.instance.get_chart_list（搜索 / 排序 / 分页）
##   皮肤 / 特效 / 音源暂取本地资源索引作为预览数据（远端接口未就绪）
##   下载管理按本会话经商店发起的下载任务构建（不读本地已下载谱面，重启即清空）
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
## 下划线滑动动画（判断是否要「补位滑动」还是可以直接摆正）
var _underline_tween: Tween = null
## 下划线上一次设定的目标 [位置, 尺寸]，用来判断布局后是否真的需要挪
var _underline_target: Array = []
## 已排队一次「布局落地后再对齐」，同帧重复请求只保留一次
var _underline_realign_pending: bool = false
## 等待对齐期间又有新变化，本轮量完要再补一轮
var _underline_realign_dirty: bool = false
## 各列表页的空状态文案（空串 = 有内容，显示列表页；非空 = 切到共享空状态页）
var _empty_text: Dictionary = {
	Tab.SONGS: "正在加载…",
	Tab.SKINS: "",
	Tab.EFFECTS: "",
	Tab.SOUNDFONTS: "",
}

# ── 歌曲页状态 ────────────────────────────────────────
## 正在等服务端返回列表（分页按钮 / 页码框据此禁用，避免连点出一串请求）
var _songs_loading: bool = false
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
## hash → {hash, item, state, stage, percent, order, vocal_only}
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
## 暂停态：只拦「开始下一个任务」，正在下的那首会跑完（底层请求没有中途取消的通道）
var _download_paused: bool = false
var _hero_hash: String = ""
var _hero_cover_version: int = 0

## 详情弹窗打开期间记录被临时隐藏的导航按钮（RB_Btn z=99，会盖在弹窗之上）
## 打开详情的那张卡片/下载行：关闭时把焦点还给原项，而不是跳回列表第一项

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
	_setup_focus_tabs()
	_setup_song_vlist()
	_apply_sort_icons()
	_select_tab(Tab.SONGS, true)
	_load_songs()

	UiStatMGR.state_changed.connect(_on_state_changed)
	if FileSystemManager.instance:
		FileSystemManager.instance.resources_ready.connect(_on_resources_ready)
	EvtBus.charts_cache_validated.connect(_on_charts_cache_validated)

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
				_request_underline_realign()
		)
	%SearchEdit.text_changed.connect(_on_search_changed)
	%SearchEdit.text_submitted.connect(_on_search_submitted)
	%FilterDataBtn.pressed.connect(_on_filter_pressed)
	%SortOrderBtn.pressed.connect(_on_order_pressed)
	%BatchDownloadBtn.pressed.connect(_on_batch_download_pressed)
	%VocalBtn.toggled.connect(_on_vocal_toggled)
	%PreviBtn.pressed.connect(_on_previ_pressed)
	%NextBtn.pressed.connect(_on_next_pressed)
	%PagerText.text_submitted.connect(_on_pager_submitted)
	%PagerText.focus_entered.connect(_on_pager_focus_entered)
	%PagerText.focus_exited.connect(_apply_pager_text)
	%DownloadPauseBtn.pressed.connect(_on_download_pause_pressed)
	%DownloadRetryBtn.pressed.connect(_on_download_retry_pressed)
	%DownloadsClearDoneBtn.pressed.connect(_on_downloads_clear_done_pressed)
	%DownloadsClearBtn.pressed.connect(_on_downloads_clear_pressed)
	var popup := PopupWindow.instance
	if popup != null:
		if not popup.chart_download_requested.is_connected(_on_detail_download_requested):
			popup.chart_download_requested.connect(_on_detail_download_requested)
		if not popup.chart_reaction_changed.is_connected(_on_chart_reaction_changed):
			popup.chart_reaction_changed.connect(_on_chart_reaction_changed)
	# 空状态提示兼作「手动重载」入口：加载失败 / 无内容时点一下重新拉取当前标签页
	# （列表页共用一个空状态页，下载管理有自己的空提示）
	%PageEmpty.gui_input.connect(_on_empty_gui_input)
	%DownloadsEmpty.gui_input.connect(_on_empty_gui_input)
	%TopBar.resized.connect(func() -> void: _request_underline_realign())


func _init_vocal_toggle() -> void:
	var enabled := true
	if ConfigManager.instance != null:
		enabled = ConfigManager.instance.get_int("download_vocal", 1) == 1
	%VocalBtn.set_pressed_no_signal(enabled)
	_update_vocal_visual()


## 顶部标签栏按 Tab 切换，页内控件交给方向键
func _setup_focus_tabs() -> void:
	var bar := FocusTabBar.new()
	bar.root = _tab_buttons[0].get_parent()
	bar.page_root = self
	bar.buttons_fn = func() -> Array: return _tab_buttons.duplicate()
	bar.current_fn = func() -> int: return _current_tab
	bar.select_fn = func(i: int) -> void: _select_tab(i, false)
	FocusMGR.register_tab_bar(bar)


func _on_vocal_toggled(pressed: bool) -> void:
	if ConfigManager.instance != null:
		ConfigManager.instance.set_value_and_notify("download_vocal", 1 if pressed else 0)
	_update_vocal_visual()
	# 关闭后「只补人声」的排队任务已经没有意义，先出队再重算卡片状态
	_drop_pending_vocal_tasks()
	_sync_bound_cards()


## 关掉「下载人声」时清掉队列里只补人声的任务：它们提交时的目标是补人声，
## 现在开关关了，跑起来只会空转一次（整包下载任务不受影响，它在启动时才读开关）
func _drop_pending_vocal_tasks() -> void:
	if _vocal_enabled():
		return
	_manual_queue = _manual_queue.filter(func(item) -> bool:
		return not _is_vocal_only(str(item.get("hash", ""))))
	_batch_queue = _batch_queue.filter(func(item) -> bool:
		return not _is_vocal_only(str(item.get("hash", ""))))
	for hash_str in _download_entries.keys():
		if hash_str == _batch_current or _active_hashes.has(hash_str):
			continue
		if _is_vocal_only(hash_str) and int(_download_entries[hash_str].get("state", -1)) \
				== DownloadRowLib.STATE_QUEUED:
			_download_entries.erase(hash_str)
	_update_task_badges()


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
		_ensure_download_vlist()
		_refresh_downloads_page(true)
	_update_task_badges()

	# 上面的构建可能把页面换成共享空状态页，动画只作用于最后真正显示的那一页
	if not instant:
		_animate_page_in(_shown_page())
	# 切页会改按下态（按钮尺寸可能变），布局落地后再对一次下划线
	_request_underline_realign()


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
	# 下载记录固定「状态分组 + 入队顺序」，这个开关对它无效
	var is_downloads := _current_tab == Tab.DOWNLOADS
	%SortOrderBtn.disabled = is_downloads
	%SortOrderBtn.tooltip_text = "下载记录固定按状态与入队顺序排列" if is_downloads \
		else "当前%s（点击切换）" % ("升序" if _sort_order == "asc" else "降序")


func _update_tab_underline(instant: bool) -> void:
	var rect := _underline_rect()
	if rect.is_empty():
		return
	var target_pos: Vector2 = rect[0]
	var target_size: Vector2 = rect[1]
	_underline_target = rect
	if instant:
		_underline_tween = null
		%TabUnderlinePanel.position = target_pos
		%TabUnderlinePanel.size = target_size
		return
	var tw := AniMGR.create_managed_tween(%TabUnderlinePanel, "store_tab_underline")
	if tw == null:
		_underline_tween = null
		%TabUnderlinePanel.position = target_pos
		%TabUnderlinePanel.size = target_size
		return
	_underline_tween = tw
	tw.set_parallel(true)
	tw.tween_property(%TabUnderlinePanel, "position", target_pos, 0.26) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(%TabUnderlinePanel, "size", target_size, 0.26) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


## 下划线目标矩形 [位置, 尺寸]（相对 %TopBar）；按钮还没布局出来时返回空数组
func _underline_rect() -> Array:
	if _tab_buttons.is_empty():
		return []
	var btn := _tab_buttons[clampi(_current_tab, 0, _tab_buttons.size() - 1)]
	if btn.size.x <= 0.0 or %TopBar.size.y <= 0.0:
		return []
	var bar_pos: Vector2 = btn.global_position - %TopBar.global_position
	return [
		Vector2(bar_pos.x + 8.0, %TopBar.size.y - 4.0),
		Vector2(maxf(btn.size.x - 16.0, 16.0), 4.0),
	]


## 布局落地后再对一次：改标签文字会先走延迟的 min-size 更新、再走容器重排，
## 当帧量到的按钮矩形还是旧的，直接摆上去就「歪一截」。
## 目标没变就什么都不做——否则会把正在跑的切页动画打断成「没有平移动画」
func _request_underline_realign() -> void:
	if _underline_realign_pending:
		# 等待期间又变了（下载数量刷新很密）：这一轮量完再补一轮
		_underline_realign_dirty = true
		return
	_underline_realign_pending = true
	await get_tree().process_frame
	_underline_realign_pending = false
	var dirty := _underline_realign_dirty
	_underline_realign_dirty = false
	var rect := _underline_rect()
	if not rect.is_empty() and rect != _underline_target:
		_update_tab_underline(not _underline_animating())
	if dirty:
		_request_underline_realign()


func _underline_animating() -> bool:
	return _underline_tween != null and _underline_tween.is_valid() and _underline_tween.is_running()


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

	# 翻页要等一次网络往返：期间把分页控件锁住并显示「加载中…」，
	# 否则旧页留在屏幕上什么都不动，等待时间完全不可预期
	_songs_loading = true
	_update_pager()
	var result: Dictionary = await ResourceManager.instance.get_chart_list(
		_song_page, PAGE_SIZE, _search_text,
		SORT_FIELDS[_sort_index], _sort_order
	)
	_songs_loading = false
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
	_update_task_badges()


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
		# 封面 URL 统一走 CoverUrl：优先服务端内容寻址 coverUrl（同图同 URL），
		# 老服务端回退裸旧端点。见 Core/CoverUrl.gd
		"cover_url": CoverUrl.from_chart(server, hash_str, chart),
		"state": state,
		"raw": chart,
	}


func _bind_song_card(node, idx: int) -> void:
	if idx < 0 or idx >= _song_items.size():
		return
	var item: Dictionary = _song_items[idx]
	if not str(item.get("hash", "")).is_empty():
		item["state"] = _display_state(item)
	node.call("set_item", item, _bind_animate)


## 歌曲卡片与分类卡片（皮肤/特效/音源）共用本回调：后者是本地资源预览，
## 没有「已下载跳曲库」的概念，也就没有 open_requested 信号，连接前先判存在
func _on_card_ready(node) -> void:
	node.detail_requested.connect(_on_detail_requested)
	node.download_requested.connect(_on_card_download_requested)
	if node.has_signal("open_requested"):
		node.open_requested.connect(_on_card_open_requested)


## 卡片请求打开详情：详情页现在由 PopupWindow 承载，关闭后的焦点还原也由它负责
func _on_detail_requested(item: Dictionary, source_rect: Rect2) -> void:
	if PopupWindow.instance != null:
		PopupWindow.instance.show_chart_detail(item, 0, source_rect)


## 详情页评价成功后回写内存条目：翻页 / 重绑时都用新计数，当前已绑定的卡片立即刷新
func _on_chart_reaction_changed(midi_hash: String, like_count: int, dislike_count: int) -> void:
	if midi_hash.is_empty():
		return
	var likes := maxi(like_count, 0)
	var dislikes := maxi(dislike_count, 0)
	for item in _song_items:
		if str(item.get("hash", "")) == midi_hash:
			item["likes"] = likes
			item["dislikes"] = dislikes
			break
	# 下载记录里的条目可能来自早先翻过的页，是另一份独立字典
	if _download_entries.has(midi_hash):
		var entry_item: Dictionary = _download_entries[midi_hash].get("item", {})
		if not entry_item.is_empty():
			entry_item["likes"] = likes
			entry_item["dislikes"] = dislikes
	if _song_vlist == null:
		return
	for node in _song_vlist.bound_nodes():
		if not is_instance_valid(node):
			continue
		var node_item = node.get("item")
		if node_item is Dictionary and str(node_item.get("hash", "")) == midi_hash \
				and node.has_method("refresh_reaction_counts"):
			node.call("refresh_reaction_counts", likes)


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
	# 下载管理页固定按「状态分组 + 入队顺序」排列，不跟这个开关走


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
	var pages := _total_pages()
	var can_jump := _song_total > 0 and not _songs_loading
	%PagerText.editable = can_jump
	%PagerText.focus_mode = Control.FOCUS_CLICK if can_jump else Control.FOCUS_NONE
	%PagerText.tooltip_text = "输入页码后按回车跳转" if can_jump else ""
	%PreviBtn.disabled = not can_jump or _song_page <= 1
	%NextBtn.disabled = not can_jump or _song_page >= pages
	# 输入态由用户掌控文本，不要在加载回来时把正在敲的页码冲掉
	if not %PagerText.has_focus():
		_apply_pager_text()


## 分页信息文本：非输入态一律显示「当前页 / 总页数」
func _apply_pager_text() -> void:
	if _songs_loading:
		%PagerText.text = "加载中…"
		return
	if _song_total <= 0:
		%PagerText.text = "—"
		return
	%PagerText.text = "%d / %d" % [_song_page, _total_pages()]


## 焦点进入分页框：只留当前页码，方便直接覆盖输入
func _on_pager_focus_entered() -> void:
	if _song_total <= 0:
		return
	%PagerText.text = str(_song_page)
	%PagerText.select_all()


## 回车提交页码：越界夹取到有效范围，跳转失败（离线等）时文本由 focus_exited 还原
func _on_pager_submitted(text: String) -> void:
	var trimmed := text.strip_edges()
	if trimmed.is_valid_int():
		var page := clampi(trimmed.to_int(), 1, _total_pages())
		if page != _song_page:
			_song_page = page
			_load_songs()
	%PagerText.release_focus()


func _show_songs_message(text: String) -> void:
	_song_items.clear()
	_song_total = 0
	if _song_vlist != null:
		_song_vlist.clear()
	_set_empty(Tab.SONGS, text)
	_update_pager()
	_update_task_badges()


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
	var prev: Array = _category_view.get(tab, [])
	_category_view[tab] = view
	var vl: VirtualListLib = _category_vlists.get(tab)
	_set_empty(tab, "" if not view.is_empty() \
		else "没有找到%s" % ["皮肤", "特效", "音源"][clampi(tab - Tab.SKINS, 0, 2)])
	if vl == null:
		return
	# 数据没变（切回同一标签页是最常见的路径）：复用已绑定的池。
	# 重绑整屏卡片（含逐卡入场 tween）是切页卡顿的主要来源
	if vl.total == view.size() and _same_item_refs(prev, view):
		return
	_bind_animate = true
	vl.set_total(view.size(), true)
	_bind_animate = false


## 两个条目数组是否逐项同一个字典（分类页条目由缓存复用，引用不变即内容不变）
func _same_item_refs(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in b.size():
		if not is_same(a[i], b[i]):
			return false
	return true


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
	# 重扫可能带进/带走人声文件，「只缺人声」的判定缓存要跟着作废
	if ResourceManager.instance != null:
		ResourceManager.instance.invalidate_local_vocal_cache()
		_sync_bound_cards()


# ══════════════════════════════════════════════════════
#  下载
# ══════════════════════════════════════════════════════

func _on_card_download_requested(item: Dictionary) -> void:
	_request_download(item)


## 卡片「已下载」按钮：按 hash 反查本地曲库后进 MIDI_VIEW。
## 导航调用序列与 PopupWindow/ChartDetailPage._open_midi_view() 保持一致，
## 只是不需要收起详情弹窗（从卡片进入时弹窗并未打开），
## 保证「详情弹窗查看谱面」与「商店卡片已下载」两个入口的返回链行为相同。
func _on_card_open_requested(item: Dictionary) -> void:
	var hash_str := str(item.get("hash", ""))
	if hash_str.is_empty():
		return
	var midi: MidiData = DataMGR.get_midi_by_id(hash_str)
	if midi == null:
		GLogger.warning("谱面已标记本地可用但曲库查不到: %s" % hash_str, "StoreView")
		return
	if not midi.album_id.is_empty() and not midi.song_id.is_empty():
		UiStatMGR.navigate_to_album_song(midi.album_id, midi.song_id, midi.id)
		if UiStatMGR.current_state != UIStateManager.UIState.MIDI_VIEW:
			UiStatMGR.change_state(UIStateManager.UIState.MIDI_VIEW)
			EvtBus.emit_midi_selected(midi.id, midi)
	else:
		UiStatMGR.change_state(UIStateManager.UIState.MIDI_VIEW)
		EvtBus.emit_midi_selected(midi.id, midi)


func _on_detail_download_requested(item: Dictionary) -> void:
	_request_download(item)


## 单曲下载入口：直接入队，队列空闲时立即开跑（批量下载 / 另一个单曲下载进行中就排队）
func _request_download(item: Dictionary) -> void:
	var hash_str := str(item.get("hash", ""))
	if hash_str.is_empty() or _is_queued(hash_str):
		return
	var vocal_only := false
	if ResourceManager.instance.get_download_state(hash_str) == ResourceManager.DownloadState.DOWNLOADED:
		if not _needs_vocal(hash_str, item):
			_set_entry_state(hash_str, ResourceManager.DownloadState.DOWNLOADED,
				ResourceManager.DownloadStage.RESCAN, 1.0)
			return
		vocal_only = true

	_manual_queue.append(item)
	_ensure_download_entry(item, DownloadRowLib.STATE_QUEUED, -1, -1.0, vocal_only)
	_refresh_card_state(hash_str)
	if _current_tab == Tab.DOWNLOADS:
		_refresh_downloads_page(false)
	_pump_download_queue()


func _run_manual_queue() -> void:
	if _manual_running or _batch_running or not _active_hashes.is_empty():
		return
	_manual_running = true
	while not _manual_queue.is_empty():
		if _batch_running or _download_paused:
			break
		var item: Dictionary = _manual_queue.pop_front()
		var hash_str := str(item.get("hash", ""))
		if not _is_vocal_only(hash_str) \
				and ResourceManager.instance.get_download_state(hash_str) == ResourceManager.DownloadState.DOWNLOADED:
			_set_entry_state(hash_str, ResourceManager.DownloadState.DOWNLOADED,
				ResourceManager.DownloadStage.RESCAN, 1.0)
			continue
		await _start_download(item)
	_manual_running = false
	_update_task_badges()
	if _current_tab == Tab.DOWNLOADS:
		_refresh_downloads_page(false)
	_pump_download_queue()


## 该 hash 是否已在下载队列里（批量队列 / 单曲队列 / 正在下载）
func _is_queued(hash_str: String) -> bool:
	if _active_hashes.has(hash_str):
		return true
	if _download_entries.has(hash_str):
		if int(_download_entries[hash_str].get("state", -1)) == DownloadRowLib.STATE_QUEUED:
			return true
	for item in _manual_queue:
		if str(item.get("hash", "")) == hash_str:
			return true
	for item in _batch_queue:
		if str(item.get("hash", "")) == hash_str:
			return true
	return false


## 该 hash 的队列任务是否只是「补下已下载谱面缺失的人声」
func _is_vocal_only(hash_str: String) -> bool:
	if _download_entries.has(hash_str):
		return bool(_download_entries[hash_str].get("vocal_only", false))
	return false


## 卡片/详情显示用的下载状态：把「排队中」和「只缺人声」并进 ResourceManager 的四态。
## ResourceManager 只认谱面本体是否落盘，排队中的谱面在它眼里还是未下载，
## 直接用它会让卡片在轮到该曲之前一直显示「下载」。
func _display_state(item: Dictionary) -> int:
	var hash_str := str(item.get("hash", ""))
	if hash_str.is_empty():
		return int(item.get("state", ResourceManager.DownloadState.NOT_DOWNLOADED))
	if _is_queued(hash_str):
		item["needs_vocal"] = false
		return ResourceManager.DownloadState.DOWNLOADING
	var state := ResourceManager.instance.get_download_state(hash_str)
	if state == ResourceManager.DownloadState.DOWNLOADED and _needs_vocal(hash_str, item):
		item["needs_vocal"] = true
		return ResourceManager.DownloadState.NOT_DOWNLOADED
	item["needs_vocal"] = false
	return state


## 谱面本体已在本地，「下载人声」开启时却仍缺人声文件 → 按钮照样显示下载（点击只补人声）
func _needs_vocal(hash_str: String, item: Dictionary) -> bool:
	if not _vocal_enabled() or not bool(item.get("has_vocal", false)):
		return false
	if ResourceManager.instance.get_download_state(hash_str) != ResourceManager.DownloadState.DOWNLOADED:
		return false
	return not ResourceManager.instance.has_local_vocal(hash_str)


## 「下载人声」开关（与 ResourceManager 读同一配置项，ConfigManager 不可用按开启处理）
func _vocal_enabled() -> bool:
	if ConfigManager.instance == null:
		return true
	return ConfigManager.instance.get_int("download_vocal", 1) == 1


func _start_download(item: Dictionary, from_batch: bool = false) -> void:
	var hash_str := str(item.get("hash", ""))
	if hash_str.is_empty() or _active_hashes.has(hash_str):
		return
	# 串行通道只有一个：已经有一首在下载时绝不并发启动（信箱是单实例的，会互相踩）
	if not _active_hashes.is_empty():
		return
	if not _download_entries.has(hash_str):
		_ensure_download_entry(item, DownloadRowLib.STATE_QUEUED, -1, -1.0)
	var vocal_only := _is_vocal_only(hash_str)
	if vocal_only and ResourceManager.instance.get_download_state(hash_str) \
			!= ResourceManager.DownloadState.DOWNLOADED:
		# 排队期间谱面被本地删掉了：退回整包下载，只补人声会找不到目标目录
		_download_entries[hash_str]["vocal_only"] = false
		vocal_only = false
	if vocal_only:
		# 人声可能在这条任务排队期间已经补齐（另一次下载带上了），直接收尾
		if not _needs_vocal(hash_str, item):
			_set_entry_state(hash_str, ResourceManager.DownloadState.DOWNLOADED,
				ResourceManager.DownloadStage.RESCAN, 1.0)
			_refresh_card_state(hash_str)
			return
	else:
		var state := ResourceManager.instance.get_download_state(hash_str)
		if state == ResourceManager.DownloadState.DOWNLOADED:
			_set_entry_state(hash_str, ResourceManager.DownloadState.DOWNLOADED,
				ResourceManager.DownloadStage.RESCAN, 1.0)
			_refresh_card_state(hash_str)
			return
		if state == ResourceManager.DownloadState.DOWNLOADING and not from_batch:
			return

	_active_hashes[hash_str] = true
	_set_entry_state(hash_str, ResourceManager.DownloadState.DOWNLOADING,
		ResourceManager.DownloadStage.VOCAL if vocal_only else ResourceManager.DownloadStage.METADATA,
		-1.0 if vocal_only else 0.0)
	_refresh_card_state(hash_str)
	if _current_tab == Tab.DOWNLOADS:
		_refresh_downloads_page(false)

	var result: Dictionary
	if vocal_only:
		result = await ResourceManager.instance.download_vocal(hash_str)
	else:
		result = await ResourceManager.instance.download_chart(hash_str,
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
		# 并行下载路径在元数据回来之前就要发封面请求，URL 信息只能从列表项预取。
		# 优先内容寻址 coverUrl（同图同 URL，客户端缓存天然去重）；
		# 老服务端没有该字段时 CoverUrl 会回退裸旧端点。
		"coverUrl": str(raw.get("coverUrl", "")),
		"songName": str(raw.get("songName", "")),
		"difficulty": str(raw.get("difficulty", "")),
		"hasVocal": bool(raw.get("hasVocal", false)),
		"vocalSize": int(raw.get("vocalSize", 0)),
		"vocalFormat": str(raw.get("vocalFormat", "")),
	}


func _ensure_download_entry(item: Dictionary, state: int, stage: int, percent: float,
		vocal_only: bool = false) -> void:
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
		"vocal_only": vocal_only,
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
			item["state"] = _display_state(item)
			break
	# 下载记录里的条目可能来自早先翻过的页，和当前页不是同一个字典：
	# 不一起刷的话，从下载记录点进详情会拿到卡在「下载中」的旧状态
	if _download_entries.has(hash_str):
		var entry_item: Dictionary = _download_entries[hash_str].get("item", {})
		if not entry_item.is_empty():
			entry_item["state"] = _display_state(entry_item)
	_refresh_bound_card(hash_str)
	_update_task_badges()


func _refresh_bound_card(hash_str: String) -> void:
	if _song_vlist != null:
		for node in _song_vlist.bound_nodes():
			if not is_instance_valid(node):
				continue
			var node_item = node.get("item")
			if node_item is Dictionary and str(node_item.get("hash", "")) == hash_str:
				node.call("refresh_download_state")
	if PopupWindow.instance != null:
		PopupWindow.instance.refresh_chart_detail_state()


func _sync_song_states() -> void:
	for item in _song_items:
		item["state"] = _display_state(item)
	for entry in _download_entries.values():
		var entry_item: Dictionary = entry.get("item", {})
		if not entry_item.is_empty():
			entry_item["state"] = _display_state(entry_item)


## 重取当前页状态并刷新已绑定卡片 / 详情弹窗，队列或本地曲库变化后统一走这里
func _sync_bound_cards() -> void:
	_sync_song_states()
	if _song_vlist != null:
		for node in _song_vlist.bound_nodes():
			if is_instance_valid(node):
				node.call("refresh_download_state")
	# 详情页已收进 PopupWindow，refresh_chart_detail_state() 内部自带「没打开就忽略」的判断
	if PopupWindow.instance != null:
		PopupWindow.instance.refresh_chart_detail_state()
	_update_task_badges()


## 后台缓存校验完成后本地反向索引才补齐新下载的谱面。此时统一重取状态并刷新
## 已绑定卡片 / 详情弹窗 / 下载管理页，消除「下载其实已完成，按钮仍停在下载」的残留窗口。
## 该信号在启动扫描、DelView 删除等场景也会触发，所以这里必须能安全处理空数据。
func _on_charts_cache_validated(_changed: bool) -> void:
	_sync_bound_cards()
	if _current_tab == Tab.DOWNLOADS:
		_refresh_downloads_page(false)


# ── 批量下载 ──────────────────────────────────────────

## 批量下载：把当前页还能下的谱面追加进队列。
## 队列正在跑的时候也允许继续按——新条目排到队尾，不会再起第二条并发下载链
func _on_batch_download_pressed() -> void:
	if _current_tab != Tab.SONGS:
		return
	var pending := _collect_pending_songs()
	if pending.is_empty():
		return
	for task in pending:
		var item: Dictionary = task["item"]
		_ensure_download_entry(item, DownloadRowLib.STATE_QUEUED, -1, -1.0, bool(task["vocal_only"]))
		_batch_queue.append(item)
	_sync_bound_cards()
	if _current_tab == Tab.DOWNLOADS:
		_refresh_downloads_page(false)
	_pump_download_queue()


## 队列水泵：同一时刻只允许一条下载链在跑（ResourceManager 的并行信箱是单实例的）。
## 批量优先——批量任务成批推进，单曲任务等整批跑完再接着来
func _pump_download_queue() -> void:
	if _download_paused or _batch_running or _manual_running:
		return
	if not _active_hashes.is_empty():
		return
	if not _batch_queue.is_empty():
		_run_batch()
	elif not _manual_queue.is_empty():
		_run_manual_queue()


## 当前页还能加入下载队列的谱面：[{item, vocal_only}]。
## vocal_only 表示谱面本体已在本地、只差人声（「下载人声」开启时才算待办）
func _collect_pending_songs() -> Array:
	var pending: Array = []
	for item in _song_items:
		var hash_str := str(item.get("hash", ""))
		if hash_str.is_empty() or _is_queued(hash_str):
			continue
		var state := ResourceManager.instance.get_download_state(hash_str)
		if state == ResourceManager.DownloadState.DOWNLOADING:
			continue
		if state == ResourceManager.DownloadState.DOWNLOADED:
			if not _needs_vocal(hash_str, item):
				continue
			pending.append({"item": item, "vocal_only": true})
			continue
		pending.append({"item": item, "vocal_only": false})
	return pending


func _run_batch() -> void:
	if _batch_running or _manual_running or not _active_hashes.is_empty():
		return
	_batch_running = true
	while not _batch_queue.is_empty():
		if _download_paused:
			break
		var item: Dictionary = _batch_queue.pop_front()
		var hash_str := str(item.get("hash", ""))
		_batch_current = hash_str
		_update_task_badges()
		if not _is_vocal_only(hash_str) \
				and ResourceManager.instance.get_download_state(hash_str) == ResourceManager.DownloadState.DOWNLOADED:
			_set_entry_state(hash_str, ResourceManager.DownloadState.DOWNLOADED,
				ResourceManager.DownloadStage.RESCAN, 1.0)
			continue
		await _start_download(item, true)
	_batch_current = ""
	_batch_running = false
	_update_task_badges()
	_pump_download_queue()


## 下载任务徽标：排队中 + 下载中的总数统一显示在「下载管理」标签上（批量与单曲合算），
## 批量下载按钮只表达可用状态——队列在跑时依然可以继续往里加
func _update_task_badges() -> void:
	var pending := _pending_task_count()
	# 队列自然跑空后自动解除暂停态，避免「继续」按钮空挂着
	if _download_paused and pending <= 0:
		_download_paused = false
	var badge_text := "下载管理" if pending <= 0 else "下载管理 (%d)" % pending
	if %TabDownloadBtn.text != badge_text:
		%TabDownloadBtn.text = badge_text
		# 文字变宽/变窄会挤动整条标签栏，下划线要跟着挪（等布局落地后再挪，见 realign）
		_request_underline_realign()
	%DownloadPauseBtn.text = "继续" if _download_paused else "暂停"
	%DownloadPauseBtn.icon = StoreIconsLib.play() if _download_paused else StoreIconsLib.pause()
	%DownloadPauseBtn.tooltip_text = "继续执行下载队列" if _download_paused \
		else "不再开始新任务，正在下的谱面下完后停住"
	%DownloadPauseBtn.disabled = pending <= 0 and not _download_paused

	var failed := _count_entries(ResourceManager.DownloadState.FAILED)
	%DownloadRetryBtn.icon = StoreIconsLib.retry()
	%DownloadRetryBtn.tooltip_text = ("把 %d 个失败的谱面重新排队" % failed) if failed > 0 \
		else "没有失败的下载"
	%DownloadRetryBtn.disabled = failed <= 0

	var done := _count_entries(ResourceManager.DownloadState.DOWNLOADED)
	%DownloadsClearDoneBtn.icon = StoreIconsLib.check()
	%DownloadsClearDoneBtn.tooltip_text = ("清空 %d 条已完成记录" % done) if done > 0 \
		else "没有已完成的记录"
	%DownloadsClearDoneBtn.disabled = done <= 0
	%DownloadsClearBtn.icon = StoreIconsLib.trash()
	%DownloadsClearBtn.tooltip_text = "清空整个下载列表（正在下载的谱面不受影响）"
	%DownloadsClearBtn.disabled = _download_entries.is_empty()

	if _current_tab != Tab.SONGS:
		%BatchDownloadBtn.disabled = true
		%BatchDownloadBtn.tooltip_text = "批量下载仅对歌曲页生效"
	elif _collect_pending_songs().is_empty():
		%BatchDownloadBtn.disabled = true
		%BatchDownloadBtn.tooltip_text = "当前页没有可下载的谱面"
	else:
		%BatchDownloadBtn.disabled = false
		%BatchDownloadBtn.tooltip_text = "把当前页未下载的谱面加入下载队列"


## 还没跑完的下载任务数（排队 + 正在下载），作为下载管理页的数量徽标
func _pending_task_count() -> int:
	var count := 0
	for entry in _download_entries.values():
		var state := int(entry.get("state", -1))
		if state == DownloadRowLib.STATE_QUEUED \
				or state == ResourceManager.DownloadState.DOWNLOADING:
			count += 1
	return count


## 指定状态的条目数（全部重试 / 清空已完成的可点性判断用）
func _count_entries(state: int) -> int:
	var count := 0
	for entry in _download_entries.values():
		if int(entry.get("state", -1)) == state:
			count += 1
	return count


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
	# 先按状态分组（等待中 → 失败 → 已完成），组内**一律按入队顺序正序**：
	# 队列是从上往下执行的，列表也就该从上往下读。这里不受歌曲页的排序开关影响——
	# 之前跟着 _sort_order 走，默认降序会让「列表最下面那首最先下载」
	rows.sort_custom(func(a, b) -> bool:
		var pa := _row_priority(int(a.get("state", 0)))
		var pb := _row_priority(int(b.get("state", 0)))
		if pa != pb:
			return pa < pb
		return int(a.get("order", 0)) < int(b.get("order", 0))
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
	_update_task_badges()


## 暂停 / 继续下载队列：只拦「开始下一个任务」，正在下的谱面会照常跑完
## （底层 HTTPRequest 没有中途取消的通道，硬掐会留下半截 .part 目录）
func _on_download_pause_pressed() -> void:
	_download_paused = not _download_paused
	if not _download_paused:
		_pump_download_queue()
	_update_task_badges()


## 失败的全部重试：把失败的条目重新排进队列（保留它原本的任务类型——整包 / 补人声）
func _on_download_retry_pressed() -> void:
	var tasks: Array = []
	for entry in _download_entries.values():
		if int(entry.get("state", -1)) != ResourceManager.DownloadState.FAILED:
			continue
		var hash_str := str(entry.get("hash", ""))
		var item: Dictionary = entry.get("item", {})
		if hash_str.is_empty() or item.is_empty() or _is_queued(hash_str):
			continue
		tasks.append({"item": item, "vocal_only": bool(entry.get("vocal_only", false))})
	if tasks.is_empty():
		return
	for task in tasks:
		_ensure_download_entry(task["item"], DownloadRowLib.STATE_QUEUED, -1, -1.0,
			bool(task["vocal_only"]))
		_batch_queue.append(task["item"])
	_sync_bound_cards()
	_refresh_downloads_page(false)
	_pump_download_queue()


## 清空已完成：只丢掉成功的记录，失败的留着让人能看见 / 重试，在下的不动
func _on_downloads_clear_done_pressed() -> void:
	for hash_str in _download_entries.keys():
		var state := int(_download_entries[hash_str].get("state", -1))
		if state != ResourceManager.DownloadState.DOWNLOADED or _active_hashes.has(hash_str):
			continue
		_download_entries.erase(hash_str)
	_refresh_downloads_page(true)


## 清空列表：丢掉已完成 / 失败的记录和还没开始的任务，
## 正在下载的那首保留条目，等它自己跑完
func _on_downloads_clear_pressed() -> void:
	_manual_queue.clear()
	_batch_queue.clear()
	for hash_str in _download_entries.keys():
		if _active_hashes.has(hash_str):
			continue
		_download_entries.erase(hash_str)
	_sync_bound_cards()
	_refresh_downloads_page(true)


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
	var meta_parts: Array[String] = []
	if not author.is_empty():
		meta_parts.append(author)
	if not album.is_empty():
		meta_parts.append(album)
	%MetaText.set_scroll_text("  ·  ".join(meta_parts))
	%DetailText.text = _transfer_size_text(item, stage)


## 顶部大卡右下角的尺寸：跟着**当前正在传的文件**走。
## 进度百分比也是按阶段给的（下 MIDI 时是 MIDI 的进度，下人声时是人声的进度），
## 固定显示 MIDI 大小的话，人声阶段那个数字就是错的
func _transfer_size_text(item: Dictionary, stage: int) -> String:
	var raw: Dictionary = item.get("raw", {})
	var midi_size := int(item.get("size_bytes", 0))
	var vocal_size := int(raw.get("vocalSize", 0))
	match stage:
		ResourceManager.DownloadStage.VOCAL:
			if vocal_size > 0:
				return "人声 %s" % StoreIconsLib.format_size(vocal_size)
		ResourceManager.DownloadStage.MIDI:
			if midi_size > 0:
				return "MIDI %s" % StoreIconsLib.format_size(midi_size)
		ResourceManager.DownloadStage.COVER:
			return "封面"
	if midi_size <= 0:
		return "—"
	return "文件 %s" % StoreIconsLib.format_size(midi_size)


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


## 空状态点一下 = 重载当前标签页。歌曲页按**当前页码**重试：
## 加载失败时 _song_total 已被清零，但用户翻到哪一页就该重试哪一页，
## 否则第 3 页失败后点重试会被踢回第 1 页
func _reload_page(tab: int) -> void:
	match tab:
		Tab.SONGS:
			_load_songs()
		Tab.DOWNLOADS:
			_sync_bound_cards()
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
		_sync_bound_cards()
		if _current_tab == Tab.DOWNLOADS:
			_refresh_downloads_page(false)
		_update_tab_underline(true)
		TextScrollMGR.resume_page(self)
	elif old_state == UIStateManager.UIState.STORE_VIEW \
			and new_state != UIStateManager.UIState.STORE_VIEW:
		if PopupWindow.instance != null:
			PopupWindow.instance.close_chart_detail()
		TextScrollMGR.suspend_page(self)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if PopupWindow.instance != null and PopupWindow.instance.is_chart_detail_open():
			PopupWindow.instance.close_chart_detail()
			get_viewport().set_input_as_handled()


## Main 的全局返回键调用：详情打开时先关详情，返回 true 表示事件已被消费
func handle_back_request() -> bool:
	if PopupWindow.instance != null and PopupWindow.instance.is_chart_detail_open():
		PopupWindow.instance.close_chart_detail()
		return true
	return false


## 商店页默认焦点落点：当前页第一张可见卡片，没有卡片就落在当前标签上
func _focus_default() -> Control:
	var first := _first_bound_card()
	if first != null:
		return first
	if _current_tab >= 0 and _current_tab < _tab_buttons.size():
		return _tab_buttons[_current_tab]
	return null


## 当前页最早一张已绑定卡片
func _first_bound_card() -> Control:
	var vl := _active_vlist()
	if vl == null:
		return null
	var best: Control = null
	var best_index := 2147483647
	for node in vl.bound_nodes():
		if not is_instance_valid(node) or not node.visible:
			continue
		var idx := int(node.get_meta(&"row_index", 2147483647))
		if idx < best_index:
			best = node
			best_index = idx
	return best


## 详情关闭后的兜底：把焦点放回商店页的默认落点
func focus_first() -> void:
	var target := _focus_default()
	if target != null:
		target.grab_focus()


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
	%PagerText.add_theme_color_override("font_color", text_secondary)
	%PagerText.add_theme_color_override("font_uneditable_color", muted_text)
	%PagerText.add_theme_color_override("caret_color", primary)
	%PagerText.add_theme_color_override("selection_color", ThemeMGR._tint_keep_alpha(primary, 0.35))

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
	for btn in [%DownloadPauseBtn, %DownloadRetryBtn, %DownloadsClearDoneBtn, %DownloadsClearBtn]:
		var b := btn as Button
		b.add_theme_color_override("icon_normal_color", text_secondary)
		b.add_theme_color_override("icon_hover_color", text_primary)

	_refresh_hero()
	_update_task_badges()

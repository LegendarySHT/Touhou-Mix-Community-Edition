## 资源管理页（原 DelView 重做）
##
## 位置与生命周期不变：作为 SettingView 的兄弟节点从左侧滑入，回到设置列表时保留节点。
## 视觉改为商店式：顶部搜索 + 标签页，内容为小卡片；歌曲页额外有底部“待操作列表”抽屉。
##
## 歌曲页：点击卡片加入/移出待操作列表，动作对整个列表生效
##         （删除人声 / 删除歌曲 / 重置歌曲 / 加入收藏夹 / 清空列表）。
## 其它页：点击卡片直接弹确认框删除，没有待操作列表。
extends Control

enum Tab { SONGS, SKINS, EFFECTS, SOUNDFONTS, BACKGROUNDS }
const TAB_COUNT := 5

const CARD_SCENE := preload("res://UI/Views/ResourceView/ResourceCard.tscn")
const PENDING_ROW_SCENE := preload("res://UI/Views/ResourceView/ResourcePendingRow.tscn")
const VirtualListLib := preload("res://UI/Components/VirtualList.gd")
const StoreIconsLib := preload("res://UI/Views/StoreView/StoreIcons.gd")

const CARD_COLUMNS := 3
const CARD_ROW_GAP := 18.0
const CARD_COL_GAP := 20.0
const CARD_MARGIN_ROWS := 2
const PENDING_COLLAPSED_H := 170.0
const PENDING_EXPANDED_H := 520.0

const SEARCH_PLACEHOLDERS := [
	"搜索歌曲 / 作者 / 专辑",
	"搜索皮肤",
	"搜索特效",
	"搜索音源",
	"搜索背景",
]
const EMPTY_TEXTS := ["没有找到歌曲", "没有皮肤", "没有特效", "没有音源", "没有背景图"]

var _current_tab: int = Tab.SONGS
var _tab_buttons: Array[Button] = []
var _pages: Array[Control] = []
var _entered: bool = false
var _busy: bool = false

var _search_text: String = ""
var _search_timer: SceneTreeTimer = null

# ── 歌曲 ──
var _song_items: Array = []
var _song_loaded: bool = false
var _song_applied_query: String = ""
var _vocal_folders: Dictionary = {}
var _song_vlist: VirtualListLib = null

# 封面路径按需解析：只处理当前绑定的可见卡片，每帧少量，避免进入页面时扫全库
var _cover_paths: Dictionary = {}
var _cover_path_queue: Array[String] = []
var _cover_path_queued: Dictionary = {}
var _load_token := 0

# ── 其它资源页 ──
var _resource_items: Dictionary = {}
var _resource_loaded: Dictionary = {}
var _resource_view: Dictionary = {}
var _resource_vlists: Dictionary = {}

# ── 待操作列表（仅歌曲页） ──
var _pending: Dictionary = {}
var _pending_order: Array[String] = []
var _pending_expanded: bool = false
var _pending_vlist: VirtualListLib = null

var _bind_animate: bool = false

@onready var _background: Panel = $Background
@onready var _top_bar: Panel = $TopBar
@onready var _tab_underline: Panel = $TopBar/TabUnderline
@onready var _search_edit: LineEdit = $TopBar/HeaderMargin/Row/Toolbar/SearchEdit
@onready var _search_icon: TextureRect = $TopBar/HeaderMargin/Row/Toolbar/SearchEdit/SearchIcon
@onready var _count_label: Label = $TopBar/HeaderMargin/Row/Toolbar/CountLabel
@onready var _songs_empty: Label = $Pages/SongsPage/Empty
@onready var _skins_empty: Label = $Pages/SkinsPage/Empty
@onready var _effects_empty: Label = $Pages/EffectsPage/Empty
@onready var _soundfonts_empty: Label = $Pages/SoundfontsPage/Empty
@onready var _backgrounds_empty: Label = $Pages/BackgroundsPage/Empty

@onready var _pending_bar: PanelContainer = $PendingBar
@onready var _pending_title: Label = $PendingBar/VBox/Head/PendingTitle
@onready var _pending_count: Label = $PendingBar/VBox/Head/PendingCount
@onready var _select_all_btn: Button = $PendingBar/VBox/Head/SelectAllBtn
@onready var _expand_btn: Button = $PendingBar/VBox/Head/ExpandBtn
@onready var _pending_scroll: ScrollContainer = $PendingBar/VBox/PendingScroll
@onready var _pending_list: Control = $PendingBar/VBox/PendingScroll/PendingList
@onready var _pending_empty: Label = $PendingBar/PendingEmpty
@onready var _delete_vocal_btn: Button = $PendingBar/VBox/Actions/DeleteVocalBtn
@onready var _delete_song_btn: Button = $PendingBar/VBox/Actions/DeleteSongBtn
@onready var _reset_btn: Button = $PendingBar/VBox/Actions/ResetBtn
@onready var _fav_btn: Button = $PendingBar/VBox/Actions/FavBtn
@onready var _clear_btn: Button = $PendingBar/VBox/Actions/ClearBtn


func _ready() -> void:
	_tab_buttons = [
		$TopBar/HeaderMargin/Row/TabBar/TabSong,
		$TopBar/HeaderMargin/Row/TabBar/TabSkin,
		$TopBar/HeaderMargin/Row/TabBar/TabEffect,
		$TopBar/HeaderMargin/Row/TabBar/TabSoundfont,
		$TopBar/HeaderMargin/Row/TabBar/TabBackground,
	]
	_pages = [
		$Pages/SongsPage,
		$Pages/SkinsPage,
		$Pages/EffectsPage,
		$Pages/SoundfontsPage,
		$Pages/BackgroundsPage,
	]
	_setup_icons()
	_setup_song_vlist()
	_setup_pending_vlist()
	_connect_ui()
	_select_tab(Tab.SONGS, true)
	_update_pending_ui()
	UiStatMGR.state_changed.connect(_on_ui_state_changed)
	if FileSystemManager.instance:
		FileSystemManager.instance.resources_ready.connect(_on_resources_ready)
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()
	call_deferred("_update_tab_underline", true)


func _exit_tree() -> void:
	if _song_vlist:
		_song_vlist.release()
	if _pending_vlist:
		_pending_vlist.release()
	for vl in _resource_vlists.values():
		if vl:
			vl.release()
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)


func _setup_icons() -> void:
	_search_icon.texture = StoreIconsLib.search()
	_tab_buttons[Tab.SONGS].icon = StoreIconsLib.song()
	_tab_buttons[Tab.SKINS].icon = StoreIconsLib.skin()
	_tab_buttons[Tab.EFFECTS].icon = StoreIconsLib.effect()
	_tab_buttons[Tab.SOUNDFONTS].icon = StoreIconsLib.soundfont()
	_tab_buttons[Tab.BACKGROUNDS].icon = StoreIconsLib.atlas(3, 240, 0)


func _setup_song_vlist() -> void:
	_song_vlist = VirtualListLib.new()
	_song_vlist.columns = CARD_COLUMNS
	_song_vlist.row_gap = CARD_ROW_GAP
	_song_vlist.col_gap = CARD_COL_GAP
	_song_vlist.margin_rows = CARD_MARGIN_ROWS
	_song_vlist.on_row_ready = _on_card_ready
	_song_vlist.on_row_bind = _bind_song_card
	_song_vlist.setup($Pages/SongsPage/List, $Pages/SongsPage/List/ListContent, CARD_SCENE)


func _setup_pending_vlist() -> void:
	_pending_vlist = VirtualListLib.new()
	_pending_vlist.columns = 1
	_pending_vlist.row_gap = 2.0
	_pending_vlist.margin_rows = 4
	_pending_vlist.on_row_ready = _on_pending_row_ready
	_pending_vlist.on_row_bind = _bind_pending_row
	_pending_vlist.setup(_pending_scroll, _pending_list, PENDING_ROW_SCENE)


func _connect_ui() -> void:
	for i in _tab_buttons.size():
		_tab_buttons[i].pressed.connect(_on_tab_pressed.bind(i))
		_tab_buttons[i].resized.connect(func() -> void:
			if i == _current_tab:
				_update_tab_underline(true)
		)
	_top_bar.resized.connect(func() -> void: _update_tab_underline(true))
	_search_edit.text_changed.connect(_on_search_changed)
	_search_edit.text_submitted.connect(_on_search_submitted)
	_select_all_btn.pressed.connect(_on_select_all_pressed)
	_expand_btn.pressed.connect(_on_expand_pressed)
	_delete_vocal_btn.pressed.connect(_on_delete_vocal_pressed)
	_delete_song_btn.pressed.connect(_on_delete_song_pressed)
	_reset_btn.pressed.connect(_on_reset_pressed)
	_fav_btn.pressed.connect(_on_favorite_pressed)
	_clear_btn.pressed.connect(_on_clear_pressed)


# ══════════════════════════════════════════════════════
#  设置页生命周期（SettingView 调用）
# ══════════════════════════════════════════════════════

func on_entered() -> void:
	_entered = true
	_pending_bar.visible = _current_tab == Tab.SONGS
	TextScrollMGR.resume_page(self)
	var need_load := _current_tab == Tab.SONGS \
		and (not _song_loaded or _song_applied_query != _search_text.strip_edges())
	if _current_tab != Tab.SONGS:
		need_load = not bool(_resource_loaded.get(_current_tab, false))
	if need_load:
		_show_loading_state(_current_tab)
		_schedule_tab_load(_current_tab, 0.55 if _current_tab == Tab.SONGS else 0.20)
	else:
		_rebuild_current_tab()
	_update_pending_ui()
	_update_tab_underline(true)


func _show_loading_state(tab: int) -> void:
	var empty := _empty_label_for(tab)
	if empty:
		empty.visible = true
		empty.text = "正在加载…"
	_count_label.text = "…"


## 数据加载分帧/延时：先让页面切换或滑入动画开始，再构建列表。
## token 用于在用户快速切换标签时丢弃过期的加载任务。
func _schedule_tab_load(tab: int, delay: float) -> void:
	_load_token += 1
	var token := _load_token
	await get_tree().create_timer(delay).timeout
	if token != _load_token or not _entered or _current_tab != tab:
		return
	_ensure_tab_data(tab)
	_rebuild_current_tab()
	_update_pending_ui()


func on_exited_to_setting_list() -> void:
	_entered = false
	_load_token += 1
	_stop_search_timer()
	_search_text = ""
	_search_edit.text = ""
	_set_pending_expanded(false, true)
	TextScrollMGR.suspend_page(self)


func _on_ui_state_changed(old_state: int, new_state: int) -> void:
	if old_state == UIStateManager.UIState.SETTINGS_VIEW \
			and new_state != UIStateManager.UIState.SETTINGS_VIEW:
		_release_all()


func _release_all() -> void:
	_entered = false
	_load_token += 1
	_stop_search_timer()
	_search_text = ""
	_search_edit.text = ""
	_song_items.clear()
	_song_loaded = false
	_song_applied_query = ""
	_vocal_folders.clear()
	_cover_paths.clear()
	_cover_path_queue.clear()
	_cover_path_queued.clear()
	_resource_items.clear()
	_resource_loaded.clear()
	_resource_view.clear()
	_pending.clear()
	_pending_order.clear()
	_set_pending_expanded(false, true)
	if _song_vlist:
		_song_vlist.clear()
	for vl in _resource_vlists.values():
		if vl:
			vl.clear()
	if _pending_vlist:
		_pending_vlist.clear()
	_update_pending_ui()


# ══════════════════════════════════════════════════════
#  标签页 / 搜索
# ══════════════════════════════════════════════════════

func _on_tab_pressed(tab: int) -> void:
	if tab == _current_tab:
		return
	_select_tab(tab, false)


func _select_tab(tab: int, instant: bool) -> void:
	var old_tab := _current_tab
	_current_tab = tab
	if old_tab != tab:
		_stop_search_timer()
		_search_text = ""
		_search_edit.text = ""
	for i in _tab_buttons.size():
		_tab_buttons[i].set_pressed_no_signal(i == tab)
	for i in _pages.size():
		_pages[i].visible = i == tab
	if not instant:
		TextScrollMGR.suspend_page(_pages[old_tab])
	TextScrollMGR.resume_page(_pages[tab])
	_search_edit.placeholder_text = SEARCH_PLACEHOLDERS[tab]
	_pending_bar.visible = tab == Tab.SONGS
	if tab != Tab.SONGS:
		_set_pending_expanded(false, true)
	_update_tab_underline(instant)
	if _entered:
		if _tab_needs_load(tab):
			_show_loading_state(tab)
			_schedule_tab_load(tab, 0.26)
		else:
			_rebuild_current_tab()
	else:
		_update_count_for_current()
	if not instant:
		_animate_page_in(_pages[tab])


func _tab_needs_load(tab: int) -> bool:
	if tab == Tab.SONGS:
		return not _song_loaded or _song_applied_query != _search_text.strip_edges()
	return not bool(_resource_loaded.get(tab, false))


func _ensure_tab_data(tab: int) -> void:
	if tab == Tab.SONGS:
		# 搜索词在切 tab 时会被清空；用「已应用的查询」判断，避免拿着上一次的过滤结果不重载
		if not _song_loaded or _song_applied_query != _search_text.strip_edges():
			_load_song_items()
		return
	if not bool(_resource_loaded.get(tab, false)):
		_build_resource_items(tab)
		_resource_loaded[tab] = true


func _rebuild_current_tab() -> void:
	if _current_tab == Tab.SONGS:
		_rebuild_song_cards()
	else:
		_rebuild_resource_cards(_current_tab)


func _on_search_changed(text: String) -> void:
	_search_text = text
	if _current_tab == Tab.SONGS:
		_stop_search_timer()
		_search_timer = get_tree().create_timer(0.28)
		_search_timer.timeout.connect(_apply_search)
	elif _current_tab >= Tab.SKINS:
		if _entered:
			_rebuild_resource_cards(_current_tab)


func _on_search_submitted(_text: String) -> void:
	_apply_search()


func _apply_search() -> void:
	_stop_search_timer()
	if not _entered:
		return
	if _current_tab == Tab.SONGS:
		_load_song_items()
		_rebuild_song_cards()
	else:
		_rebuild_resource_cards(_current_tab)


func _stop_search_timer() -> void:
	if _search_timer and _search_timer.timeout.is_connected(_apply_search):
		_search_timer.timeout.disconnect(_apply_search)
	_search_timer = null


func _update_tab_underline(instant: bool) -> void:
	if _tab_buttons.is_empty():
		return
	var btn := _tab_buttons[clampi(_current_tab, 0, _tab_buttons.size() - 1)]
	if btn.size.x <= 0.0 or _top_bar.size.y <= 0.0:
		return
	var bar_pos := btn.global_position - _top_bar.global_position
	var target_pos := Vector2(bar_pos.x + 8.0, _top_bar.size.y - 4.0)
	var target_size := Vector2(maxf(btn.size.x - 16.0, 16.0), 4.0)
	if instant:
		_tab_underline.position = target_pos
		_tab_underline.size = target_size
		return
	var tw := AniMGR.create_managed_tween(_tab_underline, "resource_tab_underline")
	if tw == null:
		_tab_underline.position = target_pos
		_tab_underline.size = target_size
		return
	tw.set_parallel(true)
	tw.tween_property(_tab_underline, "position", target_pos, 0.24) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(_tab_underline, "size", target_size, 0.24) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _animate_page_in(page: Control) -> void:
	page.offset_transform_enabled = true
	page.offset_transform_visual_only = false
	page.offset_transform_position = Vector2(0, 16)
	page.modulate.a = 0.0
	var tw := AniMGR.create_managed_tween(page, "resource_page_in")
	if tw == null:
		page.offset_transform_position = Vector2.ZERO
		page.modulate.a = 1.0
		return
	tw.set_parallel(true)
	tw.tween_property(page, "modulate:a", 1.0, 0.18) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(page, "offset_transform_position", Vector2.ZERO, 0.24) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _update_count_for_current() -> void:
	if _current_tab == Tab.SONGS:
		_count_label.text = "%d 首" % _song_items.size()
	else:
		var arr: Array = _resource_view.get(_current_tab, [])
		_count_label.text = "%d 项" % arr.size()


# ══════════════════════════════════════════════════════
#  歌曲卡片 / 待操作列表
# ══════════════════════════════════════════════════════

func _on_card_ready(node) -> void:
	if node.has_signal("clicked"):
		node.clicked.connect(_on_card_clicked)


func _bind_song_card(node, idx: int) -> void:
	if idx < 0 or idx >= _song_items.size():
		return
	var item := _ensure_song_item(idx)
	var key := str(item.get("key", ""))
	if not item.has("cover_path"):
		if _cover_paths.has(key):
			item["cover_path"] = _cover_paths[key]
		else:
			_queue_cover_path(key)
	node.call("setup", item, _pending.has(key), _bind_animate)


func _queue_cover_path(key: String) -> void:
	if key.is_empty() or _cover_paths.has(key) or _cover_path_queued.has(key):
		return
	_cover_path_queued[key] = true
	_cover_path_queue.append(key)


## 每帧只解析极少量封面路径；ChartDB.GetCoverPath 只查 DB，不做 FileAccess 存在性检查。
func _process(_delta: float) -> void:
	if not _entered or _current_tab != Tab.SONGS or _cover_path_queue.is_empty():
		return
	var budget := 2
	while budget > 0 and not _cover_path_queue.is_empty():
		var key: String = _cover_path_queue.pop_front()
		_cover_path_queued.erase(key)
		if _cover_paths.has(key):
			continue
		var path := ""
		if ChartDB != null and ChartDB.IsOpen():
			path = str(ChartDB.GetCoverPath(key))
		_cover_paths[key] = path
		for node in _song_vlist.bound_nodes():
			var bound_item: Dictionary = node.get("item")
			if str(bound_item.get("key", "")) == key:
				node.call("set_cover_path", path)
		budget -= 1


func _load_song_items() -> void:
	_refresh_vocal_folders()
	_song_items.clear()
	if ChartDB == null or not ChartDB.IsOpen():
		_song_loaded = false
		return
	var query := _search_text.strip_edges()
	# 只取 C# 投影，不在这里为 2000+ 首逐条构造卡片字典；
	# 真正绑定的可见卡片才走 _ensure_song_item，避免进入页面时主线程长阻塞。
	_song_items = ChartDB.GetSortedMidiListItems("", 0, 0, query)
	_song_loaded = true
	_song_applied_query = query.strip_edges()


func _ensure_song_item(idx: int) -> Dictionary:
	var raw: Dictionary = _song_items[idx]
	if str(raw.get("kind", "")) == "song":
		return raw
	var item := _make_song_item(raw)
	_song_items[idx] = item
	return item


func _make_song_item(p: Dictionary) -> Dictionary:
	var key := str(p.get("key", ""))
	var author := str(p.get("author_name", ""))
	if author.is_empty():
		author = str(p.get("artist_name", ""))
	var album := str(p.get("album_name", ""))
	var song := str(p.get("song_name", ""))
	var meta_parts: Array[String] = []
	if not song.is_empty():
		meta_parts.append(song)
	if not album.is_empty():
		meta_parts.append(album)
	var title := str(p.get("name", key))
	if title.is_empty():
		title = key
	var has_vocal := _vocal_folders.has(key)
	return {
		"kind": "song",
		"key": key,
		"title": title,
		"subtitle": author if not author.is_empty() else "未知作者",
		"meta": "  ·  ".join(meta_parts),
		"badge": "有人声" if has_vocal else "纯音乐",
		"has_vocal": has_vocal,
		"is_builtin": false,
	}

func _refresh_vocal_folders() -> void:
	_vocal_folders.clear()
	var fs_mgr := FileSystemManager.instance
	if fs_mgr == null:
		return
	for entry in fs_mgr.audio_files_index:
		if not entry is Dictionary:
			continue
		var file_name := str(entry.get("file_name", ""))
		if file_name.get_basename().to_lower() != "vocal":
			continue
		var path := str(entry.get("path", ""))
		if path.is_empty():
			continue
		_vocal_folders[path.get_base_dir().get_file()] = true


func _rebuild_song_cards() -> void:
	if _song_vlist == null:
		return
	_bind_animate = true
	_song_vlist.set_total(_song_items.size(), true)
	_bind_animate = false
	_songs_empty.visible = _song_items.is_empty()
	_songs_empty.text = "没有找到歌曲" if not _search_text.strip_edges().is_empty() else "没有谱面数据"
	_update_count_for_current()
	_update_pending_ui()


func _on_card_clicked(item: Dictionary) -> void:
	if str(item.get("kind", "")) == "song":
		_toggle_pending(item)
		return
	_confirm_delete_resource(item)


func _toggle_pending(item: Dictionary) -> void:
	var key := str(item.get("key", ""))
	if key.is_empty():
		return
	if _pending.has(key):
		_pending.erase(key)
		_pending_order.erase(key)
	else:
		_pending[key] = item
		_pending_order.append(key)
	_refresh_song_card_selection()
	_update_pending_ui()


func _refresh_song_card_selection() -> void:
	if _song_vlist == null:
		return
	for node in _song_vlist.bound_nodes():
		if not is_instance_valid(node):
			continue
		var item = node.get("item")
		if item is Dictionary:
			node.call("set_selected", _pending.has(str(item.get("key", ""))))


func _on_pending_row_ready(node) -> void:
	if node.has_signal("remove_requested"):
		node.remove_requested.connect(_on_pending_remove)


func _bind_pending_row(node, idx: int) -> void:
	if idx < 0 or idx >= _pending_order.size():
		return
	var key := _pending_order[idx]
	var item: Dictionary = _pending.get(key, {})
	node.call("setup", item)


func _on_pending_remove(item: Dictionary) -> void:
	var key := str(item.get("key", ""))
	if key.is_empty():
		return
	_pending.erase(key)
	_pending_order.erase(key)
	_refresh_song_card_selection()
	_update_pending_ui()


func _on_select_all_pressed() -> void:
	if _busy or _song_items.is_empty():
		return
	for i in _song_items.size():
		var item := _ensure_song_item(i)
		var key := str(item.get("key", ""))
		if key.is_empty() or _pending.has(key):
			continue
		_pending[key] = item
		_pending_order.append(key)
	_refresh_song_card_selection()
	_update_pending_ui()


func _on_clear_pressed() -> void:
	_clear_pending()


func _clear_pending() -> void:
	if _pending.is_empty():
		return
	_pending.clear()
	_pending_order.clear()
	_refresh_song_card_selection()
	_update_pending_ui()


func _update_pending_ui() -> void:
	var count := _pending_order.size()
	_pending_title.text = "待操作列表"
	_pending_count.text = "%d 首" % count
	_pending_empty.visible = _pending_expanded and count == 0
	var can_act := count > 0 and not _busy
	for btn in [_delete_vocal_btn, _delete_song_btn, _reset_btn, _fav_btn]:
		btn.disabled = not can_act
	_clear_btn.disabled = count == 0 or _busy
	_select_all_btn.disabled = _song_items.is_empty() or _busy
	if _pending_vlist:
		_pending_vlist.set_total(count, false)
		if _pending_expanded:
			_sync_pending_vlist()


func _sync_pending_vlist() -> void:
	if _pending_vlist:
		_pending_vlist.sync(true)


func _on_expand_pressed() -> void:
	_set_pending_expanded(not _pending_expanded)


func _set_pending_expanded(expanded: bool, instant: bool = false) -> void:
	if expanded == _pending_expanded and not instant:
		return
	_pending_expanded = expanded
	_expand_btn.text = "收起" if expanded else "展开"
	if expanded:
		_pending_scroll.visible = true
		_pending_empty.visible = _pending_order.is_empty()
	var target_top := -PENDING_EXPANDED_H if expanded else -PENDING_COLLAPSED_H
	if instant:
		_pending_bar.offset_top = target_top
		_pending_scroll.visible = expanded
		if expanded:
			_sync_pending_vlist.call_deferred()
		return
	var tw := AniMGR.create_managed_tween(_pending_bar, "resource_pending_bar")
	if tw == null:
		_pending_bar.offset_top = target_top
		_pending_scroll.visible = expanded
		return
	tw.tween_property(_pending_bar, "offset_top", target_top, 0.24) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if not expanded:
		tw.finished.connect(func() -> void:
			if not _pending_expanded:
				_pending_scroll.visible = false
		)
	else:
		_sync_pending_vlist.call_deferred()


# ══════════════════════════════════════════════════════
#  歌曲待操作动作
# ══════════════════════════════════════════════════════

func _on_delete_vocal_pressed() -> void:
	if _busy or _pending.is_empty():
		return
	var keys := _pending_order.duplicate()
	if not await _confirm("确定删除所选 %d 首歌的人声？\n只删除 vocal.*，不会删除 MIDI 本体。" % keys.size()):
		return
	_set_busy(true)
	var result := _delete_vocals(keys)
	_set_busy(false)
	var deleted := int(result.get("deleted", 0))
	if deleted > 0:
		_clear_pending()
		_song_loaded = false
		_load_song_items()
		_rebuild_song_cards()
		await _info("已删除 %d 首歌的人声。" % deleted)
	else:
		await _info("没有找到可删除的人声文件。")


func _delete_vocals(keys: Array) -> Dictionary:
	var deleted := 0
	var missing := 0
	var failed := 0
	var fs_mgr := FileSystemManager.instance
	for key in keys:
		var files := _find_vocal_files(str(key))
		if files.is_empty():
			missing += 1
			continue
		var any := false
		for path in files:
			if fs_mgr and fs_mgr.delete_audio(path):
				any = true
			else:
				failed += 1
		if any:
			deleted += 1
	return {"deleted": deleted, "missing": missing, "failed": failed}


func _find_vocal_files(chart_key: String) -> Array[String]:
	var result: Array[String] = []
	var fs_mgr := FileSystemManager.instance
	if fs_mgr == null:
		return result
	var folder := fs_mgr.get_chart_folder_path(chart_key)
	if folder.is_empty():
		return result
	for file_name in DirAccess.get_files_at(folder):
		if str(file_name).get_basename().to_lower() != "vocal":
			continue
		var ext := str(file_name).get_extension().to_lower()
		if ext in ["ogg", "mp3", "wav", "flac", "m4a", "opus", "aac"]:
			result.append(folder.path_join(file_name))
	return result


func _on_delete_song_pressed() -> void:
	if _busy or _pending.is_empty():
		return
	var keys := _pending_order.duplicate()
	if not await _confirm("确定删除所选 %d 首歌？\n会连同 MIDI、人声和谱面配置一起删除，且不可撤销。" % keys.size()):
		return
	_set_busy(true)
	var removed: Array = await FileSystemManager.instance.delete_charts_batch(keys)
	for id in removed:
		DataMGR.remove_midi(id)
	_set_busy(false)
	if removed.is_empty():
		await _info("删除失败，没有删除任何文件。")
		return
	EvtBus.midis_deleted.emit(removed)
	_clear_pending()
	_song_loaded = false
	_load_song_items()
	_rebuild_song_cards()
	await _info("已删除 %d 首歌。" % removed.size())


func _on_reset_pressed() -> void:
	if _busy or _pending.is_empty():
		return
	var keys := _pending_order.duplicate()
	if not await _confirm("确定重置所选 %d 首歌的配置？\n会清除音轨选择/音量/静音/独奏等设置。" % keys.size()):
		return
	_set_busy(true)
	var count := 0
	for key in keys:
		var midi: MidiData = DataMGR.get_midi_by_id(str(key))
		if midi == null:
			continue
		_reset_midi_config(midi)
		count += 1
	_set_busy(false)
	if count > 0:
		_clear_pending()
	await _info("已重置 %d 首歌的配置。" % count)


func _reset_midi_config(midi: MidiData) -> void:
	var chart_id: String = midi.chart_key if not midi.chart_key.is_empty() else midi.id
	midi.selected_track_indices.clear()
	midi.selected_track_configs.clear()
	midi.track_channel_mute_state.clear()
	midi.track_channel_volume_config.clear()
	midi.track_channel_instrument_overrides.clear()
	midi.solo_pairs.clear()
	midi.midi_volume = -1.0
	midi.vocal_volume = -1.0
	midi.set_track_config_initialized(false)
	MidiCore.ClearConfig(chart_id)


func _on_favorite_pressed() -> void:
	if _busy or _pending.is_empty():
		return
	var fav_mgr := FavoriteManager.instance
	if fav_mgr == null or fav_mgr.favorites.is_empty():
		await _info("还没有收藏夹，请先在侧栏收藏夹里新建一个。")
		return
	var names: Array[String] = []
	for fav in fav_mgr.favorites:
		names.append(fav.name)
	var popup := PopupWindow.instance
	if popup == null:
		return
	if not await popup.show_message("加入收藏夹", true, names):
		return
	var selected_name := popup.get_selected()
	var target_id := ""
	for fav in fav_mgr.favorites:
		if fav.name == selected_name:
			target_id = fav.id
			break
	if target_id.is_empty():
		return
	fav_mgr.add_ids_to_favorite(target_id, _pending_order.duplicate())
	await _info("已加入收藏夹：%s" % selected_name)


func _set_busy(busy: bool) -> void:
	_busy = busy
	_update_pending_ui()


func _confirm(text: String) -> bool:
	var popup := PopupWindow.instance
	if popup == null:
		return false
	return await popup.show_message(text, true)


func _info(text: String) -> void:
	var popup := PopupWindow.instance
	if popup != null:
		await popup.show_message(text, false)


# ══════════════════════════════════════════════════════
#  其它资源页
# ══════════════════════════════════════════════════════

func _ensure_resource_vlist(tab: int) -> void:
	if _resource_vlists.has(tab):
		return
	var page: Control = _pages[tab]
	var scroll := page.get_node("List") as ScrollContainer
	var content := page.get_node("List/ListContent") as Control
	var vl := VirtualListLib.new()
	vl.columns = CARD_COLUMNS
	vl.row_gap = CARD_ROW_GAP
	vl.col_gap = CARD_COL_GAP
	vl.margin_rows = CARD_MARGIN_ROWS
	vl.on_row_ready = _on_card_ready
	vl.on_row_bind = func(node, idx: int) -> void: _bind_resource_card(node, idx, tab)
	vl.setup(scroll, content, CARD_SCENE)
	_resource_vlists[tab] = vl


func _build_resource_items(tab: int) -> void:
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
					items.append({
						"kind": "skin",
						"key": str(key),
						"title": str(key).replace(" [内置]", ""),
						"subtitle": "内置皮肤" if builtin else "本地皮肤",
						"meta": "%d 张贴图" % _count_image_files(skin_path),
						"badge": "内置" if builtin else "用户",
						"is_builtin": builtin,
						"path": skin_path,
					})
		Tab.EFFECTS:
			if ParticleMGR != null:
				for key in ParticleMGR.get_particle_list():
					var data: Dictionary = ParticleMGR.get_particle_data(key)
					var builtin := bool(data.get("is_builtin", false))
					var frame := int(data.get("frame", 0))
					var fps := float(data.get("fps", 0.0))
					items.append({
						"kind": "effect",
						"key": str(key),
						"title": str(key).replace(" [内置]", ""),
						"subtitle": "判定特效",
						"meta": "%d 帧 · %d FPS" % [frame, int(fps)],
						"badge": "内置" if builtin else "用户",
						"cover_tex": _particle_preview_texture(key, data),
						"is_builtin": builtin,
						"path": str(data.get("path", "")),
					})
		Tab.SOUNDFONTS:
			if FileSystemManager.instance != null:
				var index: Dictionary = FileSystemManager.instance.soundfonts_index
				var keys := index.keys()
				keys.sort()
				for key in keys:
					var data: Dictionary = index[key]
					var builtin := bool(data.get("is_builtin", false))
					items.append({
						"kind": "soundfont",
						"key": str(key),
						"title": str(key),
						"subtitle": "音源库",
						"meta": "%.1f MB" % float(data.get("size_mb", 0.0)),
						"badge": "内置" if builtin else "用户",
						"is_builtin": builtin,
						"path": str(data.get("path", "")),
					})
		Tab.BACKGROUNDS:
			if FileSystemManager.instance != null:
				var index: Dictionary = FileSystemManager.instance.get_backgrounds_index()
				var keys := index.keys()
				keys.sort()
				for key in keys:
					var path := str(index[key])
					var builtin := path.begins_with("res://")
					items.append({
						"kind": "background",
						"key": str(key),
						"title": str(key),
						"subtitle": "背景图",
						"meta": path.get_extension().to_upper(),
						"badge": "内置" if builtin else "用户",
						"is_builtin": builtin,
						"path": path,
					})
	_resource_items[tab] = items
	_resource_view[tab] = _filter_resource_items(items)
	_ensure_resource_vlist(tab)


func _filter_resource_items(items: Array) -> Array:
	var query := _search_text.strip_edges().to_lower()
	var view: Array = []
	for item in items:
		if not query.is_empty():
			var haystack := "%s %s %s" % [
				str(item.get("title", "")), str(item.get("subtitle", "")), str(item.get("meta", ""))
			]
			if not haystack.to_lower().contains(query):
				continue
		view.append(item)
	return view


func _bind_resource_card(node, idx: int, tab: int) -> void:
	var view: Array = _resource_view.get(tab, [])
	if idx < 0 or idx >= view.size():
		return
	node.call("setup", view[idx], false, _bind_animate)


func _rebuild_resource_cards(tab: int) -> void:
	_ensure_resource_vlist(tab)
	var vl: VirtualListLib = _resource_vlists.get(tab)
	if vl == null:
		return
	var view := _filter_resource_items(_resource_items.get(tab, []))
	_resource_view[tab] = view
	_bind_animate = true
	vl.set_total(view.size(), true)
	_bind_animate = false
	var empty: Label = _empty_label_for(tab)
	if empty:
		empty.visible = view.is_empty()
		empty.text = EMPTY_TEXTS[tab] if _search_text.strip_edges().is_empty() \
			else "没有匹配的资源"
	_update_count_for_current()


func _empty_label_for(tab: int) -> Label:
	match tab:
		Tab.SONGS: return _songs_empty
		Tab.SKINS: return _skins_empty
		Tab.EFFECTS: return _effects_empty
		Tab.SOUNDFONTS: return _soundfonts_empty
		Tab.BACKGROUNDS: return _backgrounds_empty
	return null


func _confirm_delete_resource(item: Dictionary) -> void:
	if _busy:
		return
	if bool(item.get("is_builtin", false)):
		await _info("内置资源不能删除。")
		return
	var title := str(item.get("title", "该资源"))
	if not await _confirm("确定删除「%s」？\n该操作不可撤销。" % title):
		return
	_set_busy(true)
	var ok := false
	match str(item.get("kind", "")):
		"skin":
			ok = SkinMGR.remove_skin(str(item.get("key", "")))
		"effect":
			ok = ParticleMGR.remove_particle_pack(str(item.get("key", "")))
		"soundfont":
			ok = FileSystemManager.instance.delete_soundfont(str(item.get("path", "")))
		"background":
			ok = FileSystemManager.instance.delete_background(str(item.get("path", "")))
			if ok:
				ThemeMGR.invalidate_background_cache(str(item.get("key", "")))
	_set_busy(false)
	if not ok:
		await _info("删除失败，请稍后重试。")
		return
	# 数据源已变化：丢掉当前 tab 缓存并重建（保留搜索词）
	_resource_loaded[_current_tab] = false
	_build_resource_items(_current_tab)
	_resource_loaded[_current_tab] = true
	_rebuild_resource_cards(_current_tab)


func _on_resources_ready() -> void:
	if not _entered:
		return
	_refresh_vocal_folders()
	if _current_tab == Tab.SONGS:
		if _song_loaded:
			_song_loaded = false
			_load_song_items()
			_rebuild_song_cards()
	else:
		_resource_loaded[_current_tab] = false
		_build_resource_items(_current_tab)
		_resource_loaded[_current_tab] = true
		_rebuild_resource_cards(_current_tab)


# ══════════════════════════════════════════════════════
#  预览图（资源卡）
# ══════════════════════════════════════════════════════

func _count_image_files(skin_path: String) -> int:
	if skin_path.is_empty():
		return 0
	var count := 0
	for file_name in DirAccess.get_files_at(skin_path.trim_suffix("/")):
		if str(file_name).get_extension().to_lower() in ["png", "svg"]:
			count += 1
	return count


func _particle_preview_texture(pack_key: String, data: Dictionary) -> Texture2D:
	var textures: Array = ParticleMGR.get_base_textures(pack_key)
	if textures.is_empty():
		textures = ParticleMGR.get_emitter_textures(pack_key)
	if textures.is_empty() or not textures[0] is Texture2D:
		return null
	var preview: Texture2D = textures[0]
	var frame_px := int(data.get("size", 0))
	if frame_px > 0 and preview.get_width() >= frame_px and preview.get_height() >= frame_px:
		var atlas := AtlasTexture.new()
		atlas.atlas = preview
		atlas.region = Rect2(0, 0, frame_px, frame_px)
		return atlas
	return preview


# ══════════════════════════════════════════════════════
#  焦点 / 主题
# ══════════════════════════════════════════════════════

func focus_first_tab() -> void:
	if _current_tab >= 0 and _current_tab < _tab_buttons.size():
		_tab_buttons[_current_tab].grab_focus()


func apply_theme() -> void:
	if not ThemeMGR:
		return
	var surface := ThemeMGR.get_color("surface")
	var surface_low := ThemeMGR.get_color("surface_low")
	var surface_high := ThemeMGR.get_color("surface_high")
	var surface_hover := ThemeMGR.get_color("surface_hover")
	var border := ThemeMGR.get_color("border")
	var text_primary := ThemeMGR.get_color("text_primary")
	var text_secondary := ThemeMGR.get_color("text_secondary")
	var text_dim := ThemeMGR.get_color("text_dim")
	var primary := ThemeMGR.get_color("primary")
	var primary_light := ThemeMGR.get_color("primary_light")
	var primary_dark := ThemeMGR.get_color("primary_dark")
	var is_light := ThemeMGR.get_appearance() == "light"
	var accent_text := primary_dark if is_light else primary_light
	var muted_text := text_secondary if is_light else text_dim

	var bg_sb := _background.get_theme_stylebox("panel") as StyleBoxFlat
	if bg_sb:
		bg_sb.bg_color = ThemeMGR._tint_keep_alpha(surface_low, 0.97)
	var top_sb := _top_bar.get_theme_stylebox("panel") as StyleBoxFlat
	if top_sb:
		top_sb.bg_color = ThemeMGR._tint_keep_alpha(surface, 0.97)
		top_sb.border_color = ThemeMGR._tint_keep_alpha(primary, 0.55 if is_light else 0.4)

	var search_sb := _search_edit.get_theme_stylebox("normal") as StyleBoxFlat
	if search_sb:
		search_sb.bg_color = surface_low
		search_sb.border_color = border
	var search_focus_sb := _search_edit.get_theme_stylebox("focus") as StyleBoxFlat
	if search_focus_sb:
		search_focus_sb.bg_color = surface_low.lightened(0.04)
		search_focus_sb.border_color = ThemeMGR._tint_keep_alpha(primary, 0.9)
	_search_edit.add_theme_color_override("font_color", text_primary)
	_search_edit.add_theme_color_override("font_placeholder_color", muted_text)
	_search_edit.add_theme_color_override("caret_color", primary)
	_search_icon.modulate = text_secondary
	_count_label.add_theme_color_override("font_color", text_secondary)

	for btn in _tab_buttons:
		_style_flat_button(btn, surface_high, surface_hover, primary_dark, border, text_secondary, text_primary)
		if is_light:
			var tab_pressed := btn.get_theme_stylebox("pressed") as StyleBoxFlat
			if tab_pressed:
				tab_pressed.bg_color = ThemeMGR._tint_keep_alpha(primary, 0.16)
				tab_pressed.border_color = primary_dark
		btn.add_theme_color_override("font_pressed_color", accent_text)
		btn.add_theme_color_override("font_hover_pressed_color", accent_text)
		btn.add_theme_color_override("font_focus_color", text_primary)
		btn.add_theme_color_override("icon_normal_color", text_secondary)
		btn.add_theme_color_override("icon_hover_color", text_primary)
		btn.add_theme_color_override("icon_pressed_color", accent_text)
		btn.add_theme_color_override("icon_hover_pressed_color", accent_text)
		btn.add_theme_color_override("icon_focus_color", accent_text)
		var focus_sb := btn.get_theme_stylebox("focus") as StyleBoxFlat
		if focus_sb:
			focus_sb.border_color = accent_text

	var underline_sb := _tab_underline.get_theme_stylebox("panel") as StyleBoxFlat
	if underline_sb:
		underline_sb.bg_color = primary_dark if is_light else primary_light

	var pending_sb := _pending_bar.get_theme_stylebox("panel") as StyleBoxFlat
	if pending_sb:
		pending_sb.bg_color = ThemeMGR._tint_keep_alpha(surface, 0.98)
		pending_sb.border_color = ThemeMGR._tint_keep_alpha(primary, 0.55 if is_light else 0.45)
	_pending_title.add_theme_color_override("font_color", text_primary)
	_pending_count.add_theme_color_override("font_color", muted_text)
	_pending_empty.add_theme_color_override("font_color", muted_text)
	for label in [_songs_empty, _skins_empty, _effects_empty, _soundfonts_empty, _backgrounds_empty]:
		label.add_theme_color_override("font_color", muted_text)

	for btn in [_select_all_btn, _expand_btn, _delete_vocal_btn, _delete_song_btn,
			_reset_btn, _fav_btn, _clear_btn]:
		_style_flat_button(btn, surface_high, surface_hover, primary_dark, border, text_secondary, text_primary)
		var pressed_color := Color.WHITE if is_light else primary_light
		btn.add_theme_color_override("font_pressed_color", pressed_color)
		btn.add_theme_color_override("font_hover_pressed_color", pressed_color)
		btn.add_theme_color_override("font_focus_color", text_primary)
		var b_focus := btn.get_theme_stylebox("focus") as StyleBoxFlat
		if b_focus:
			b_focus.border_color = accent_text
		# ResourceView.tscn 没写 disabled 样式，会落到 MainTheme 的 Button/disabled
		# （浅色下几乎白底），压在深色工具条上像块膏药。按 normal 的几何补一份。
		var b_normal := btn.get_theme_stylebox("normal") as StyleBoxFlat
		if b_normal:
			var b_disabled := b_normal.duplicate() as StyleBoxFlat
			b_disabled.bg_color = ThemeMGR._tint_keep_alpha(
				surface_low.darkened(0.06) if is_light else surface_low, b_normal.bg_color.a * 0.8)
			b_disabled.border_color = ThemeMGR._tint_keep_alpha(
				ThemeMGR.get_color("border_soft"), b_normal.border_color.a)
			btn.add_theme_stylebox_override("disabled", b_disabled)


func _style_flat_button(btn: Button, normal_bg: Color, hover_bg: Color, pressed_bg: Color,
		border: Color, normal_text: Color, hover_text: Color) -> void:
	var normal_sb := btn.get_theme_stylebox("normal") as StyleBoxFlat
	if normal_sb:
		normal_sb.bg_color = ThemeMGR._tint_keep_alpha(normal_bg, normal_sb.bg_color.a)
		normal_sb.border_color = border
	var hover_sb := btn.get_theme_stylebox("hover") as StyleBoxFlat
	if hover_sb:
		hover_sb.bg_color = ThemeMGR._tint_keep_alpha(hover_bg, hover_sb.bg_color.a)
		hover_sb.border_color = ThemeMGR.get_color("primary") \
			if ThemeMGR.get_appearance() == "light" else ThemeMGR.get_color("primary_light")
	var pressed_sb := btn.get_theme_stylebox("pressed") as StyleBoxFlat
	if pressed_sb:
		pressed_sb.bg_color = ThemeMGR._tint_keep_alpha(pressed_bg, pressed_sb.bg_color.a)
		pressed_sb.border_color = ThemeMGR.get_color("primary_light")
	btn.add_theme_color_override("font_color", normal_text)
	btn.add_theme_color_override("font_hover_color", hover_text)
	# 禁用态统一走 text_disabled（低饱和深灰）。不要再额外降透明度：
	# 颜色本身已经够"熄火"，再叠 alpha 会淡到看不清
	var disabled_text: Color = ThemeMGR.get_color("text_disabled")
	btn.add_theme_color_override("font_disabled_color", disabled_text)
	btn.add_theme_color_override("icon_disabled_color", disabled_text)

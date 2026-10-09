extends HBoxContainer
class_name DelView

enum Tab {MIDI = 0, AUDIO = 1, SF2 = 2, SKIN = 3, BG = 4}

## 行类型：组行（可折叠的分组头）/ 子行（组内条目）/ 扁平行（无分组的单层条目）
enum RowKind {GROUP, ITEM, FLAT}

const TREE_ROW_SCENE := preload("res://UI/Views/SettingView/TreeRow.tscn")

# ── Sidebar ──
@onready var _tab_buttons: Array[Button] = [
	$SideBar/TabBtn0,
	$SideBar/TabBtn1,
	$SideBar/TabBtn2,
	$SideBar/TabBtn3,
	$SideBar/TabBtn4,
]

# ── TopBar ──
@onready var _tab_title := $Content/PC/TopBar/TabTitle as Label
@onready var _item_sum := $Content/PC/TopBar/ItemSum/Text as Label
@onready var _search_box := $Content/PC/TopBar/SearchBox as LineEdit

# ── 共用列表（5 个 tab 同一个 ScrollContainer + 同一个池）──
@onready var _page_scroll := $Content/PC/PageContainer/PageScroll as ScrollContainer
@onready var _page_list := $Content/PC/PageContainer/PageScroll/PageList as Control

# ── 共享底栏 ──
@onready var _select_toggle := $Content/BottomBarPC/BottomBar/SelectToggle as Button
@onready var _collapse_toggle := $Content/BottomBarPC/BottomBar/CollapseToggle as Button
@onready var _delete_btn := $Content/BottomBarPC/BottomBar/DeleteBtn as Button

var _current_tab: Tab = Tab.MIDI
var _search_query: String = ""

# ════════════════════════════════════════════════════════════
# 统一行模型
#
# 原来每个 tab 各有一份「数据字典 + 节点字典」，有多少项就 add_child 多少个节点
# （MIDI 展开全部 = 2000+ 个节点）。现在数据与节点彻底解耦：
#   _rows         全量行数据（纯 Dictionary，不建节点）
#   _visible_rows 当前可视行在 _rows 中的下标（折叠 / 搜索后的结果）
#   _vlist        虚拟化渲染器，只把 _visible_rows 里落在滚动窗口的那几十条绑到池行上
# 5 个 tab 共用同一套 _rows / _vlist，切 tab 只是换数据，不再有 5 份列表容器。
# ════════════════════════════════════════════════════════════
var _vlist: VirtualList
var _rows: Array[Dictionary] = []
var _visible_rows: Array = []

# ── MIDI 数据 ──
var _midi_groups: Array = []                    # GetSortedAlbumItems 结果
var _midi_children: Dictionary = {}             # album_id → Array[String] midi_key
var _midi_loaded: Dictionary = {}               # album_id → bool（子行是否已进 _rows）
var _midi_total: int = 0                        # 谱面总数（子行未建也能统计）

# ── Audio 数据 ──
var _audio_items: Array[Dictionary] = []        # 扁平数据
var _audio_groups: Array = []                   # song_name 有序列表
var _audio_in_group: Dictionary = {}            # song_name → Array[int]（_audio_items 下标）

# ── SF2 / Skin / BG 数据（扁平）──
var _sf2_items: Array[Dictionary] = []
var _skin_items: Array[Dictionary] = []
var _bg_items: Array[Dictionary] = []

# 数据是否已构建（切 tab 时免重复扫描）
var _tab_data_built: Array[bool] = [false, false, false, false, false]
# DelView 是否已展示过（未进入前不构建）
var _delview_entered: bool = false
# 构建代次（切 tab / 重建时作废在途的异步构建）
var _build_gen: int = 0

# MIDI 就地搜索：非空时缓存命中的 folder_name 集合（零水合）
var _midi_search_matched: Dictionary = {}
var _midi_search_albums: Dictionary = {}
## MIDI 谱面勾选态的真源（album_id/midi_key → bool）。
## 子行是展开时才建节点的，折叠状态下没有行对象可存，所以勾选态必须有一份与节点无关的
## 存储，否则「折叠着全选 → 展开」会丢勾选，删除也会漏掉没展开的谱面。
var _midi_checked: Dictionary = {}


func _ready() -> void:
	_vlist = VirtualList.new()
	_vlist.setup(_page_scroll, _page_list, TREE_ROW_SCENE)
	_vlist.row_gap = 0.0   # 还原旧 PageList(VBox) 的 separation=0
	_vlist.on_row_ready = _on_row_ready
	_vlist.on_row_bind = _on_row_bind

	for i in _tab_buttons.size():
		_tab_buttons[i].pressed.connect(_on_tab_button_pressed.bind(i))
		_tab_buttons[i].focus_entered.connect(_on_tab_focus_entered.bind(i))

	_select_toggle.toggled.connect(_on_select_toggled)
	_delete_btn.pressed.connect(_on_delete_pressed)
	_collapse_toggle.toggled.connect(_on_collapse_toggled)
	for b in [_select_toggle, _collapse_toggle, _delete_btn]:
		b.focus_entered.connect(_on_bottom_btn_focus_entered)

	DataMGR.data_loaded.connect(_on_data_loaded)
	_search_box.text_changed.connect(_on_search_text_changed)
	# 离开 SETTINGS_VIEW 时释放全部数据
	UiStatMGR.state_changed.connect(_on_ui_state_changed)

	_current_tab = Tab.MIDI
	_tab_buttons[Tab.MIDI].set_pressed_no_signal(true)
	_tab_title.text = "MIDI 谱面管理"
	_update_item_sum("未加载")
	_collapse_toggle.visible = true
	_collapse_toggle.set_pressed_no_signal(true)
	_collapse_toggle.text = "展开全部"
	_select_toggle.disabled = true
	_delete_btn.disabled = true

	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()


## 应用主题色（由 ThemeManager 广播调用 + _ready 首次自调）
func apply_theme() -> void:
	var top_panel := get_node_or_null("Content/PC") as Control
	if top_panel:
		var sb := top_panel.get_theme_stylebox("panel")
		if sb is StyleBoxFlat:
			sb.bg_color = ThemeMGR.get_color("surface")


func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)
	if _vlist:
		_vlist.release()


# ════════════════════════════════════════════════════════════
# 虚拟化渲染
# ════════════════════════════════════════════════════════════

## 池行首次创建（每个池行只调一次）：在这里连信号。
## 数据是复用的，绝不能把数据键 bind 到连接上 —— 回调统一走 row_index 反查。
func _on_row_ready(node: Control) -> void:
	var tr := node as TreeRow
	if tr and tr.checkbox:
		tr.checkbox.toggled.connect(func(on: bool) -> void: _on_row_checked(node, on))
	# 点击组行非 CheckBox 区域 → 折叠 / 展开
	node.gui_input.connect(func(event: InputEvent) -> void: _on_row_gui_input(event, node))


## 把池行绑定到第 vis_index 个可视行
func _on_row_bind(node: Control, vis_index: int) -> void:
	var tr := node as TreeRow
	if tr == null or vis_index < 0 or vis_index >= _visible_rows.size():
		return
	var row: Dictionary = _rows[_visible_rows[vis_index]]
	var is_item := int(row.get("kind", RowKind.FLAT)) == RowKind.ITEM
	tr.apply_style(is_item)
	tr.set_content(String(row.get("left", "")), String(row.get("right", "")))
	tr.set_checked(bool(row.get("selected", false)))
	tr.set_check_disabled(bool(row.get("disabled", false)))
	tr.set_indeterminate(_is_group_indeterminate(row))


## 勾选变化：从节点反查当前行，再按 tab 走各自的联动逻辑
func _on_row_checked(node: Control, on: bool) -> void:
	var row := _row_of_node(node)
	if row.is_empty():
		return
	var kind := int(row.get("kind", RowKind.FLAT))
	row["selected"] = on
	_set_row_selected(row, on)
	if kind == RowKind.GROUP:
		# 组行：联动整组。子行可能还没建（折叠态），所以要写进与节点无关的勾选源
		match _current_tab:
			Tab.MIDI: _midi_set_group_checked(String(row["key"]), on)
			Tab.AUDIO: _audio_set_group_checked(String(row["key"]), on)
	else:
		_sync_group_check_state(String(row.get("group", "")))
	_update_selection_ui()
	# 组行勾选会改到别的行：重刷一次可视行内容（不重建池）
	_vlist.refresh_all()


## 点击行：组行（非 CheckBox 区）折叠 / 展开
func _on_row_gui_input(event: InputEvent, node: Control) -> void:
	if not event is InputEventMouseButton:
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	var row := _row_of_node(node)
	if row.is_empty() or int(row.get("kind", RowKind.FLAT)) != RowKind.GROUP:
		return
	var tr := node as TreeRow
	if tr and tr.checkbox and tr.checkbox.get_global_rect().has_point(event.global_position):
		return  # 点在 CheckBox 上，不算折叠
	if event.pressed:
		node.set_meta(&"_press_pos", event.global_position)
		return
	var press_pos: Vector2 = node.get_meta(&"_press_pos", Vector2.INF)
	node.remove_meta(&"_press_pos")
	if press_pos == Vector2.INF:
		return
	if event.global_position.distance_to(press_pos) >= 10.0:
		return  # 拖动，不触发
	_toggle_group_collapse(row)


## 从池行反查它当前显示的行数据
func _row_of_node(node: Control) -> Dictionary:
	var vis_index := int(node.get_meta(&"row_index", -1))
	if vis_index < 0 or vis_index >= _visible_rows.size():
		return {}
	var row_index := int(_visible_rows[vis_index])
	if row_index < 0 or row_index >= _rows.size():
		return {}
	return _rows[row_index]


## 组行是否半选（组内部分选中）
## 组行是否半选。统计一律走数据真源而不是遍历 _rows —— 每组只查自己那几条，
## 否则「每行绑定都 O(rows)」会让滚动变成 O(rows²)（2400 行时肉眼可见地卡）
func _is_group_indeterminate(row: Dictionary) -> bool:
	if int(row.get("kind", RowKind.FLAT)) != RowKind.GROUP:
		return false
	var checked := 0
	var total := 0
	match _current_tab:
		Tab.MIDI:
			for k in _midi_children.get(String(row["key"]), []):
				total += 1
				if bool(_midi_checked.get(String(k), false)):
					checked += 1
		Tab.AUDIO:
			for idx in _audio_in_group.get(String(row["key"]), []):
				total += 1
				if bool(_audio_items[int(idx)].get("selected", false)):
					checked += 1
		_:
			return false
	return total > 0 and checked > 0 and checked < total


## 按 key 找行（只在当前 _rows 里线性找；组展开后子行才存在）
func _find_row(key: String) -> Dictionary:
	for r in _rows:
		if String(r.get("key", "")) == key:
			return r
	return {}


## 重算可视行：折叠 + 搜索过滤后的结果，喂给虚拟化渲染器
## keep_scroll=false（默认）：回到顶部，用于切页 / 重建 / 改搜索词
## keep_scroll=true：保留滚动位置，用于折叠 / 展开这类就地增删（否则列表会跳回顶部）
func _recompute_visible(keep_scroll: bool = false) -> void:
	# 保位锚点：记住视口顶部那一行是谁。"保留 scroll_vertical"只保证不归零，
	# 但收起全部时锚点上方会少掉一批子行，同一个像素位置对应的内容已经变了，
	# 所以重算后要按锚点的新下标把它放回原处，视觉上才是"没动"。
	var anchor_key := ""
	var anchor_off := 0.0
	if keep_scroll and _vlist != null and _vlist.row_stride > 0.0 \
			and not _visible_rows.is_empty():
		var top := clampi(int(_vlist.scroll.scroll_vertical / _vlist.row_stride),
			0, _visible_rows.size() - 1)
		anchor_key = String(_rows[_visible_rows[top]].get("key", ""))
		anchor_off = _vlist.scroll.scroll_vertical - float(top) * _vlist.row_stride

	_visible_rows.clear()
	var group_collapsed := false
	for i in _rows.size():
		var row: Dictionary = _rows[i]
		var kind := int(row.get("kind", RowKind.FLAT))
		if kind == RowKind.GROUP:
			group_collapsed = bool(row.get("collapsed", false))
			if _row_matches(row):
				_visible_rows.append(i)
		elif kind == RowKind.ITEM:
			if group_collapsed:
				continue
			if _row_matches(row):
				_visible_rows.append(i)
		else:
			if _row_matches(row):
				_visible_rows.append(i)
	# 容器尚未布局时 VirtualList 会自行延后建池（滚动/resized 触发时补上），这里无需重试
	_vlist.set_total(_visible_rows.size(), not keep_scroll)
	# 锚点行还在（没被折叠/过滤掉）→ 按新下标复位；找不到了就沿用 set_total 夹过的值
	if keep_scroll and not anchor_key.is_empty():
		var pos := _visible_pos_of(anchor_key)
		if pos >= 0:
			_vlist.set_scroll(float(pos) * _vlist.row_stride + anchor_off)


## 锚点行在当前可视序列中的下标（不在则 -1）
func _visible_pos_of(key: String) -> int:
	for i in _visible_rows.size():
		if String(_rows[_visible_rows[i]].get("key", "")) == key:
			return i
	return -1


## 单行是否通过当前搜索条件
func _row_matches(row: Dictionary) -> bool:
	if _search_query.is_empty():
		return true
	var kind := int(row.get("kind", RowKind.FLAT))
	var q := _search_query.to_lower()
	if _current_tab == Tab.MIDI:
		# DB 驱动的命中集（零水合）：专辑名命中显示根，谱面命中显示子行
		if kind == RowKind.GROUP:
			return bool(_midi_search_albums.has(String(row["key"])))
		if kind == RowKind.ITEM:
			return bool(_midi_search_matched.has(String(row["key"])))
		return true
	if _current_tab == Tab.AUDIO:
		# 曲名命中则整组可见；组内任一文件名命中也算（与原先的分组搜索语义一致）
		if kind == RowKind.GROUP:
			if q in String(row.get("left", "")).to_lower():
				return true
			for idx in _audio_in_group.get(String(row["key"]), []):
				if q in String(_audio_items[int(idx)]["file_name"]).to_lower():
					return true
			return false
		if kind == RowKind.ITEM:
			if q in String(row.get("left", "")).to_lower():
				return true
			return q in String(row.get("group", "")).to_lower()
	return q in String(row.get("left", "")).to_lower()


## 数据已变、行数未变时重刷（勾选联动等）：保留滚动位置
func _refresh_rows() -> void:
	_recompute_visible(true)


# ════════════════════════════════════════════════════════════
# 生命周期
# ════════════════════════════════════════════════════════════

func on_entered() -> void:
	_delview_entered = true
	_ensure_tab_built(_current_tab)


## 返回设置主页：清空搜索，保留数据（再进入立即显示）
func on_exited_to_setting_list() -> void:
	if not _search_box.text.is_empty():
		_search_box.text = ""
	_search_query = ""
	_midi_search_matched.clear()
	_midi_search_albums.clear()
	_recompute_visible()


func _on_ui_state_changed(_old: int, new: int) -> void:
	if new != UIStateManager.UIState.SETTINGS_VIEW:
		_release_all()


## 离开设置页：作废在途构建 + 清空全部数据与行
func _release_all() -> void:
	_build_gen += 1
	_rows.clear()
	_visible_rows.clear()
	_midi_groups.clear()
	_midi_children.clear()
	_midi_loaded.clear()
	_midi_checked.clear()
	_midi_total = 0
	_audio_items.clear()
	_audio_groups.clear()
	_audio_in_group.clear()
	_sf2_items.clear()
	_skin_items.clear()
	_bg_items.clear()
	_tab_data_built = [false, false, false, false, false]
	_delview_entered = false
	_midi_search_matched.clear()
	_midi_search_albums.clear()
	if _vlist:
		_vlist.clear()
	if _search_box:
		_search_box.text = ""
	_search_query = ""
	_update_item_sum("未加载")
	_select_toggle.set_pressed_no_signal(false)
	_select_toggle.disabled = true
	_delete_btn.disabled = true


func _ensure_tab_built(tab: Tab) -> void:
	if _tab_data_built[tab]:
		return
	match tab:
		Tab.MIDI: _build_midi_page()
		Tab.AUDIO: _build_audio_page()
		Tab.SF2: _build_sf2_page()
		Tab.SKIN: _build_skin_page()
		Tab.BG: _build_bg_page()


# ════════════════════════════════════════════════════════════
# Tab 切换
# ════════════════════════════════════════════════════════════

func _on_tab_button_pressed(idx: int) -> void:
	if idx != _current_tab:
		_switch_tab(idx as Tab)


func _on_tab_focus_entered(idx: int) -> void:
	if idx != _current_tab:
		_switch_tab(idx as Tab)


func _switch_tab(tab: Tab) -> void:
	if tab == _current_tab:
		return
	_build_gen += 1
	_current_tab = tab
	_tab_buttons[tab].set_pressed(true)
	_search_box.text = ""
	_search_query = ""
	_midi_search_matched.clear()
	_midi_search_albums.clear()
	_collapse_toggle.visible = (tab == Tab.MIDI or tab == Tab.AUDIO)

	match tab:
		Tab.MIDI: _tab_title.text = "MIDI 谱面管理"
		Tab.AUDIO: _tab_title.text = "人声音频管理"
		Tab.SF2: _tab_title.text = "SF2 音源管理"
		Tab.SKIN: _tab_title.text = "皮肤管理"
		Tab.BG: _tab_title.text = "背景管理"

	if _tab_data_built[tab]:
		_rebuild_rows_for_tab()
		_update_tab_header(tab)
		return

	_update_item_sum("加载中...")
	_select_toggle.disabled = true
	_delete_btn.disabled = true
	if _delview_entered:
		_ensure_tab_built(tab)


## 切回已构建的 tab：按当前数据重建 _rows（折叠态与勾选态保留在原始数据里）
func _rebuild_rows_for_tab() -> void:
	_rows.clear()
	match _current_tab:
		Tab.MIDI: _midi_fill_rows()
		Tab.AUDIO: _audio_fill_rows()
		Tab.SF2: _flat_fill_rows(_sf2_items, "file_name", "size_text")
		Tab.SKIN: _flat_fill_rows(_skin_items, "name", "")
		Tab.BG: _flat_fill_rows(_bg_items, "name", "ext")
	_recompute_visible()
	_update_focus_relations()


func _update_tab_header(tab: Tab) -> void:
	_collapse_toggle.visible = (tab == Tab.MIDI or tab == Tab.AUDIO)
	match tab:
		Tab.MIDI:
			_tab_title.text = "MIDI 谱面管理"
			_update_item_sum("共 %d 首谱面" % _midi_total)
		Tab.AUDIO:
			_tab_title.text = "人声音频管理"
			_update_item_sum("共 %d 个音频文件" % _audio_items.size())
		Tab.SF2:
			_tab_title.text = "SF2 音源管理"
			_update_item_sum("共 %d 个音源" % _sf2_items.size())
		Tab.SKIN:
			_tab_title.text = "皮肤管理"
			_update_item_sum("共 %d 个皮肤" % _skin_items.size())
		Tab.BG:
			_tab_title.text = "背景管理"
			_update_item_sum("共 %d 张背景" % _bg_items.size())
	_sync_collapse_button()
	_update_selection_ui()


## 折叠按钮文案同步到当前实际折叠态
func _sync_collapse_button() -> void:
	if not _collapse_toggle:
		return
	var all_collapsed := true
	var any_group := false
	for row in _rows:
		if int(row.get("kind", RowKind.FLAT)) != RowKind.GROUP:
			continue
		any_group = true
		if not bool(row.get("collapsed", false)):
			all_collapsed = false
	if not any_group:
		return
	_collapse_toggle.set_pressed_no_signal(all_collapsed)
	_collapse_toggle.text = "展开全部" if all_collapsed else "收起全部"


func _update_focus_relations() -> void:
	var tab_btn := _tab_buttons[_current_tab]
	var tab_path := tab_btn.get_path()
	_search_box.focus_previous = tab_path
	for b in _tab_buttons:
		b.focus_previous = _delete_btn.get_path()
	for b in [_select_toggle, _collapse_toggle, _delete_btn]:
		b.focus_next = tab_path
	# 内容首项：池化后取当前绑定的第一行即可
	var first_node := _vlist.node_at(0) if _vlist else null
	var right_path := first_node.get_path() if first_node else NodePath("")
	for b in _tab_buttons:
		b.focus_neighbor_right = right_path
	if _vlist:
		# 只遍历真在显示的槽位；pool 里含已解绑但仍在树上（平移出视口）的行
		for node in _vlist.bound_nodes():
			node.focus_neighbor_left = tab_path


func _on_bottom_btn_focus_entered() -> void:
	var tab_path := _tab_buttons[_current_tab].get_path()
	for b in [_select_toggle, _collapse_toggle, _delete_btn]:
		b.focus_next = tab_path


func focus_first_tab() -> void:
	_tab_buttons[Tab.MIDI].grab_focus()


# ════════════════════════════════════════════════════════════
# MIDI 管理
# ════════════════════════════════════════════════════════════

func _build_midi_page() -> void:
	_tab_data_built[Tab.MIDI] = false
	var my_gen := _bump_gen()
	_rows.clear()
	_midi_groups.clear()
	_midi_children.clear()
	_midi_loaded.clear()
	_midi_total = 0
	_update_item_sum("加载中...")
	_update_selection_ui()

	# 等待 FileSystemManager 扫描 + 后台校验完成，防止与重建并发 clobber
	if FileSystemManager.instance.is_busy():
		_update_item_sum("资源扫描中...")
		await FileSystemManager.instance.await_busy_done()
		if my_gen != _build_gen or _current_tab != Tab.MIDI or not _delview_entered:
			return

	if ChartDB == null or not ChartDB.IsOpen() or ChartDB.CountCharts() == 0:
		_update_item_sum("数据加载中..." if DataMGR.is_loading else "无谱面数据")
		if not DataMGR.is_loading:
			_tab_data_built[Tab.MIDI] = true
		return

	var method_str := ConfigManager.instance.get_string("Browse", "album_sort_method", "creation_time")
	var dir_str := ConfigManager.instance.get_string("Browse", "album_sort_direction", "asc")
	var direction := 0 if dir_str == "asc" else 1
	_midi_groups = ChartDB.GetSortedAlbumItems(method_str, direction)
	if _midi_groups.is_empty():
		_update_item_sum("无谱面数据")
		_tab_data_built[Tab.MIDI] = true
		return

	# 收集每个专辑的 midi key（轻量，不水合 MidiData）
	var built := 0
	for album in _midi_groups:
		if my_gen != _build_gen or _current_tab != Tab.MIDI:
			return
		var album_id := String(album.get("id", ""))
		var keys: Array[String] = []
		for song in DataMGR.get_songs_by_album(album_id):
			for midi_key: String in ChartDB.GetMidiKeysBySong(String(song.get("id", ""))):
				keys.append(midi_key)
		_midi_children[album_id] = keys
		_midi_loaded[album_id] = false
		_midi_total += keys.size()
		built += 1
		if built % 10 == 0:
			await get_tree().process_frame
			if my_gen != _build_gen or _current_tab != Tab.MIDI:
				return

	if my_gen != _build_gen or _current_tab != Tab.MIDI:
		return
	_midi_fill_rows()
	if _current_tab == Tab.MIDI:
		_update_tab_header(Tab.MIDI)
		_update_focus_relations()
	_tab_data_built[Tab.MIDI] = true


## 按专辑数据填 _rows（仅组行，子行在展开时插入）
func _midi_fill_rows() -> void:
	_rows.clear()
	for album in _midi_groups:
		var album_id := String(album.get("id", ""))
		var keys: Array = _midi_children.get(album_id, [])
		_rows.append({
			"kind": RowKind.GROUP,
			"key": album_id,
			"left": String(album.get("name", "")),
			"right": "%d 首" % keys.size(),
			"collapsed": true,
			"selected": false,
			"disabled": false,
		})
		# 已加载过的专辑：把子行还原回 _rows
		if bool(_midi_loaded.get(album_id, false)):
			_midi_append_children(_rows, album_id)
	_recompute_visible()


## 展开专辑：批量取该专辑谱面投影并插入子行（插入点在该组行之后）
func _midi_load_children(album_id: String) -> void:
	if bool(_midi_loaded.get(album_id, false)):
		return
	var keys: Array = _midi_children.get(album_id, [])
	_midi_loaded[album_id] = true
	if keys.is_empty():
		return  # 重算可视行由调用方统一做（展开全部时可只算一次）
	var projections: Array = ChartDB.GetMidiListItemsByKeys(keys, "")
	var by_key := {}
	for p in projections:
		by_key[String(p.get("key", ""))] = p
	# 找到组行位置，在其后插入
	for i in _rows.size():
		var row: Dictionary = _rows[i]
		if int(row.get("kind", RowKind.FLAT)) == RowKind.GROUP and String(row["key"]) == album_id:
			var inserted: Array = []
			for k in keys:
				var info: Dictionary = by_key.get(String(k), {})
				var author := String(info.get("artist_name", ""))
				if author.is_empty():
					author = "-"
				inserted.append({
					"kind": RowKind.ITEM,
					"key": String(k),
					"group": album_id,
					"left": "    %s" % String(info.get("name", String(k))),
					"right": author,
					# 折叠期间被组行全选过的谱面，展开后要还原勾选
					"selected": bool(_midi_checked.get(String(k), false)),
					"disabled": false,
				})
			var at := i + 1
			for r in inserted:
				_rows.insert(at, r)
				at += 1
			break


func _midi_append_children(out: Array, album_id: String) -> void:
	var keys: Array = _midi_children.get(album_id, [])
	if keys.is_empty():
		return
	var projections: Array = ChartDB.GetMidiListItemsByKeys(keys, "")
	var by_key := {}
	for p in projections:
		by_key[String(p.get("key", ""))] = p
	for k in keys:
		var info: Dictionary = by_key.get(String(k), {})
		var author := String(info.get("artist_name", ""))
		if author.is_empty():
			author = "-"
		out.append({
			"kind": RowKind.ITEM,
			"key": String(k),
			"group": album_id,
			"left": "    %s" % String(info.get("name", String(k))),
			"right": author,
			"selected": bool(_midi_checked.get(String(k), false)),
			"disabled": false,
		})


# ════════════════════════════════════════════════════════════
# Audio 管理
# ════════════════════════════════════════════════════════════

func _build_audio_page() -> void:
	_tab_data_built[Tab.AUDIO] = false
	var my_gen := _bump_gen()
	_rows.clear()
	_audio_items.clear()
	_audio_groups.clear()
	_audio_in_group.clear()
	_update_item_sum("扫描中...")

	_audio_items = await _scan_audio_files()
	if my_gen != _build_gen or _current_tab != Tab.AUDIO:
		return

	if _audio_items.is_empty():
		_update_item_sum("无音频文件")
		_recompute_visible()
		_tab_data_built[Tab.AUDIO] = true
		_update_selection_ui()
		return

	# 按 song_name 分组
	for i in _audio_items.size():
		var song_name := String(_audio_items[i]["song_name"])
		if not _audio_in_group.has(song_name):
			_audio_in_group[song_name] = []
			_audio_groups.append(song_name)
		(_audio_in_group[song_name] as Array).append(i)
	_audio_groups.sort()

	_audio_fill_rows()
	if _current_tab == Tab.AUDIO:
		_update_tab_header(Tab.AUDIO)
		_update_focus_relations()
	_tab_data_built[Tab.AUDIO] = true


func _audio_fill_rows() -> void:
	_rows.clear()
	for song_name in _audio_groups:
		var idxs: Array = _audio_in_group[song_name]
		var single := idxs.size() == 1
		var right_text := String(_audio_items[int(idxs[0])]["file_name"]) if single \
			else "%d 个" % idxs.size()
		_rows.append({
			"kind": RowKind.GROUP,
			"key": song_name,
			"left": song_name,
			"right": right_text,
			"collapsed": false,   # 音频页默认展开（沿用原行为）
			"selected": false,
			"disabled": false,
		})
		if not single:
			for idx in idxs:
				var item: Dictionary = _audio_items[int(idx)]
				_rows.append({
					"kind": RowKind.ITEM,
					"key": "a%d" % int(idx),
					"group": song_name,
					"left": String(item["file_name"]),
					"right": String(item.get("format", "")),
					"selected": bool(item.get("selected", false)),
					"disabled": false,
				})
	_recompute_visible()


func _scan_audio_files() -> Array[Dictionary]:
	# 1. FileSystemManager 内存索引（扫描过一次后常驻，零 I/O）
	var result: Array[Dictionary] = []
	var fs_mgr = FileSystemManager.instance
	if fs_mgr and not fs_mgr.audio_files_index.is_empty():
		for entry in fs_mgr.audio_files_index:
			result.append({
				"file_name": entry["file_name"], "path": entry["path"],
				"format": entry["format"], "song_name": entry["song_name"],
				"selected": false,
			})
		return result

	# 2. DB 速查库（audio_files 集合）—— 一次表扫描，远快于遍历 Charts/ 全部子目录
	if fs_mgr and ChartDB != null and ChartDB.IsOpen():
		for entry in fs_mgr.load_audio_files_from_db():
			result.append({
				"file_name": entry["file_name"], "path": entry["path"],
				"format": entry["format"], "song_name": entry["song_name"],
				"selected": false,
			})
		if not result.is_empty():
			GLogger.info("DelView 音频列表取自 DB 速查库：%d 项" % result.size(), "DelView")
			return result

	# 3. 兜底：独立扫描文件系统（每目录只开一次 DirAccess）
	var charts_dir := PathHelper.get_charts_dir()
	if not DirAccess.dir_exists_absolute(charts_dir):
		return result
	var dir := DirAccess.open(charts_dir)
	if not dir:
		return result
	var audio_exts := ["ogg", "mp3", "wav", "flac"]
	dir.list_dir_begin()
	var dn := dir.get_next()
	var dir_count := 0
	while dn != "":
		if dir.current_is_dir() and not dn.begins_with("."):
			var chart_path := charts_dir.path_join(dn)
			var song_name := String(dn)
			var hash_idx := song_name.find("_")
			if hash_idx >= 0:
				song_name = song_name.substr(hash_idx + 1)
			var sub := DirAccess.open(chart_path)
			if sub:
				sub.list_dir_begin()
				var fn := sub.get_next()
				while fn != "":
					if not sub.current_is_dir():
						var ext := fn.get_extension().to_lower()
						if audio_exts.has(ext):
							result.append({
								"file_name": fn, "path": chart_path.path_join(fn),
								"format": ext, "song_name": song_name, "selected": false,
							})
					fn = sub.get_next()
				sub.list_dir_end()
			dir_count += 1
			if dir_count % 5 == 0:
				await get_tree().process_frame
		dn = dir.get_next()
	dir.list_dir_end()
	result.sort_custom(func(a, b):
		if a["song_name"] != b["song_name"]:
			return a["song_name"] < b["song_name"]
		return a["format"] < b["format"]
	)
	return result


# ════════════════════════════════════════════════════════════
# SF2 / Skin / BG —— 均为扁平行
# ════════════════════════════════════════════════════════════

## 扁平数据填行：left_key 为主文本，right_key 为副文本（可为空串表示不显示）
func _flat_fill_rows(items: Array, left_key: String, right_key: String) -> void:
	_rows.clear()
	for i in items.size():
		var item: Dictionary = items[i]
		var left := String(item.get(left_key, ""))
		if bool(item.get("is_builtin", false)):
			left += " [内置]"
		var builtin := bool(item.get("is_builtin", false))
		_rows.append({
			"kind": RowKind.FLAT,
			"key": "f%d" % i,
			"left": left,
			"right": (String(item.get(right_key, "")) if right_key != "" else ""),
			"selected": bool(item.get("selected", false)),
			"disabled": builtin,
			"index": i,
		})
	_recompute_visible()


func _build_sf2_page() -> void:
	_tab_data_built[Tab.SF2] = false
	_bump_gen()
	_rows.clear()
	_sf2_items = _scan_sf2_files()
	_flat_fill_rows(_sf2_items, "file_name", "size_text")
	if _current_tab == Tab.SF2:
		_update_tab_header(Tab.SF2)
		_update_focus_relations()
	_tab_data_built[Tab.SF2] = true


func _build_skin_page() -> void:
	_tab_data_built[Tab.SKIN] = false
	_bump_gen()
	_rows.clear()
	_skin_items.clear()
	for skin_name in SkinMGR.get_skins_index():
		var meta: SkinMetadata = SkinMGR.get_skins_index()[skin_name]
		_skin_items.append({
			"name": skin_name, "path": meta.path,
			"is_builtin": meta.is_builtin, "selected": false,
		})
	_skin_items.sort_custom(func(a, b):
		if a["is_builtin"] != b["is_builtin"]:
			return not a["is_builtin"]
		return a["name"] < b["name"]
	)
	_flat_fill_rows(_skin_items, "name", "")
	if _current_tab == Tab.SKIN:
		_update_tab_header(Tab.SKIN)
		_update_focus_relations()
	_tab_data_built[Tab.SKIN] = true


func _build_bg_page() -> void:
	_tab_data_built[Tab.BG] = false
	_bump_gen()
	_rows.clear()
	_bg_items.clear()
	for bg_name in FileSystemManager.instance.get_backgrounds_index():
		var path: String = FileSystemManager.instance.get_backgrounds_index()[bg_name]
		_bg_items.append({
			"name": bg_name, "path": path,
			"ext": path.get_extension().to_lower() if not path.is_empty() else "",
			"selected": false,
		})
	_bg_items.sort_custom(func(a, b): return a["name"] < b["name"])
	_flat_fill_rows(_bg_items, "name", "ext")
	if _current_tab == Tab.BG:
		_update_tab_header(Tab.BG)
		_update_focus_relations()
	_tab_data_built[Tab.BG] = true


func _scan_sf2_files() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var fs_mgr = FileSystemManager.instance
	if fs_mgr:
		var sf_index = fs_mgr.get_soundfonts_index()
		if not sf_index.is_empty():
			for sf_name in sf_index:
				var entry = sf_index[sf_name]
				result.append({
					"file_name": sf_name + ".sf2", "path": entry["path"],
					"is_builtin": entry["is_builtin"], "size_mb": entry["size_mb"],
					"size_text": "%.1f MB" % float(entry["size_mb"]),
					"selected": false,
				})
			return result

	var user_dir := PathHelper.get_soundfont_dir()
	if DirAccess.dir_exists_absolute(user_dir):
		var dir := DirAccess.open(user_dir)
		if dir:
			dir.list_dir_begin()
			var fn := dir.get_next()
			while fn != "":
				if fn.ends_with(".sf2") and not dir.current_is_dir():
					result.append({
						"file_name": fn, "path": user_dir.path_join(fn),
						"is_builtin": false, "size_mb": _file_size_mb(user_dir.path_join(fn)),
						"selected": false,
					})
				fn = dir.get_next()
			dir.list_dir_end()

	var res_dir := "res://Resources/Soundfont/"
	if DirAccess.dir_exists_absolute(res_dir):
		var dir := DirAccess.open(res_dir)
		if dir:
			dir.list_dir_begin()
			var fn := dir.get_next()
			while fn != "":
				if fn.ends_with(".sf2") and not dir.current_is_dir():
					var dup := false
					for item in result:
						if item["file_name"] == fn:
							dup = true
							break
					if not dup:
						result.append({
							"file_name": fn, "path": res_dir.path_join(fn),
							"is_builtin": true, "size_mb": _file_size_mb(res_dir.path_join(fn)),
							"selected": false,
						})
				fn = dir.get_next()
			dir.list_dir_end()

	for item in result:
		item["size_text"] = "%.1f MB" % float(item["size_mb"])
	result.sort_custom(func(a, b):
		if a["is_builtin"] != b["is_builtin"]:
			return not a["is_builtin"]
		return a["file_name"] < b["file_name"]
	)
	return result


func _file_size_mb(path: String) -> float:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0.0
	var mb = snapped(f.get_length() / 1048576.0, 0.1)
	f.close()
	return mb


# ════════════════════════════════════════════════════════════
# 折叠 / 展开
# ════════════════════════════════════════════════════════════

func _toggle_group_collapse(row: Dictionary) -> void:
	var collapsed := not bool(row.get("collapsed", false))
	row["collapsed"] = collapsed
	if not collapsed and _current_tab == Tab.MIDI:
		_midi_load_children(String(row["key"]))
	# 子行增删都发生在这组行之后，上方内容未变 → 保留滚动位置，别把列表拽回顶部
	_recompute_visible(true)
	_sync_collapse_button()
	_update_focus_relations()


func _on_collapse_toggled(toggled: bool) -> void:
	_collapse_toggle.text = "展开全部" if toggled else "收起全部"
	var my_gen := _bump_gen()
	for row in _rows:
		if int(row.get("kind", RowKind.FLAT)) == RowKind.GROUP:
			row["collapsed"] = toggled
	if not toggled and _current_tab == Tab.MIDI:
		# 展开全部：逐个专辑加载子行（每 8 个让一帧，避免大谱库下单帧卡顿）。
		# _midi_load_children 自己不重算可视行，循环结束后统一算一次
		var n := 0
		for album_id in _midi_children.keys():
			if my_gen != _build_gen:
				return
			if not bool(_midi_loaded.get(album_id, false)):
				_midi_load_children(String(album_id))
				n += 1
				if n % 8 == 0:
					await get_tree().process_frame
				if my_gen != _build_gen:
					return
	_recompute_visible(true)
	_sync_collapse_button()
	_update_focus_relations()


# ════════════════════════════════════════════════════════════
# 搜索
# ════════════════════════════════════════════════════════════

func _on_search_text_changed(new_text: String) -> void:
	_search_query = new_text.strip_edges()
	_apply_search_filter()


func _apply_search_filter() -> void:
	if _search_query.is_empty():
		_midi_search_matched.clear()
		_midi_search_albums.clear()
		_recompute_visible()
		_update_tab_header(_current_tab)
		return

	if _current_tab == Tab.MIDI:
		# DB 驱动命中集（零水合）：专辑级 + 谱面级
		_midi_search_albums.clear()
		for aid in ChartDB.GetMatchingAlbumIds(_search_query):
			_midi_search_albums[aid] = true
		_midi_search_matched.clear()
		for key in ChartDB.SearchMidiKeys(_search_query):
			_midi_search_matched[key] = true
		var matched := _midi_search_matched.size()
		_recompute_visible()
		_update_item_sum("匹配 %d 首谱面" % matched)
		return

	_recompute_visible()
	var n := _visible_rows.size()
	match _current_tab:
		Tab.AUDIO: _update_item_sum("共 %d 个音频文件 (匹配 %d 个)" % [_audio_items.size(), n])
		Tab.SF2: _update_item_sum("共 %d 个音源 (匹配 %d 个)" % [_sf2_items.size(), n])
		Tab.SKIN: _update_item_sum("共 %d 个皮肤 (匹配 %d 个)" % [_skin_items.size(), n])
		Tab.BG: _update_item_sum("共 %d 张背景 (匹配 %d 个)" % [_bg_items.size(), n])


# ════════════════════════════════════════════════════════════
# 选择 / 删除
# ════════════════════════════════════════════════════════════

func _on_select_toggled(toggled: bool) -> void:
	_select_toggle.text = "取消全选" if toggled else "全选"
	# 先写与节点无关的勾选源：折叠着的分组没有行对象，只改 _rows 会漏掉它们
	match _current_tab:
		Tab.MIDI:
			for album_id in _midi_children:
				for k in _midi_children[album_id]:
					_midi_checked[String(k)] = toggled
		Tab.AUDIO:
			for i in _audio_items.size():
				_audio_items[i]["selected"] = toggled
		_:
			var arr := _current_flat_items()
			for i in arr.size():
				if not bool(arr[i].get("is_builtin", false)):
					arr[i]["selected"] = toggled
	# 已建的行对象同步（内置项不可选，跳过）
	for row in _rows:
		if bool(row.get("disabled", false)):
			continue
		row["selected"] = toggled
	_vlist.refresh_all()
	_update_selection_ui()


func _on_delete_pressed() -> void:
	match _current_tab:
		Tab.MIDI: _on_midi_delete_selected()
		Tab.AUDIO: _on_audio_delete_selected()
		Tab.SF2: _on_sf2_delete_selected()
		Tab.SKIN: _on_skin_delete_selected()
		Tab.BG: _on_bg_delete_selected()


func _on_midi_delete_selected() -> void:
	var to_delete: Array[String] = []
	for row in _rows:
		if int(row.get("kind", RowKind.FLAT)) == RowKind.ITEM and bool(row.get("selected", false)):
			to_delete.append(String(row["key"]))
	# 未展开的专辑：其谱面没有子行，但可能已被组行勾选 → 用组行勾选态补齐
	for row in _rows:
		if int(row.get("kind", RowKind.FLAT)) == RowKind.GROUP and bool(row.get("selected", false)):
			for k in _midi_children.get(String(row["key"]), []):
				if not to_delete.has(String(k)):
					to_delete.append(String(k))
	if to_delete.is_empty():
		return

	_build_gen += 1
	_rows.clear()
	_visible_rows.clear()
	if _vlist:
		_vlist.clear()
	_midi_groups.clear()
	_midi_children.clear()
	_midi_loaded.clear()
	_midi_checked.clear()
	_midi_total = 0
	_update_selection_ui()
	await get_tree().process_frame

	_search_box.text = ""
	_search_query = ""
	_midi_search_matched.clear()
	_midi_search_albums.clear()

	var removed := await FileSystemManager.instance.delete_charts_batch(to_delete)
	for midi_id in removed:
		DataMGR.remove_midi(midi_id)
	for midi_id in to_delete:
		if not removed.has(midi_id):
			push_error("[DelView] 删除失败: %s" % midi_id)
	if not removed.is_empty():
		EvtBus.midis_deleted.emit(removed)
	await get_tree().process_frame
	_build_midi_page()


func _on_audio_delete_selected() -> void:
	var to_delete: Array[Dictionary] = []
	for item in _audio_items:
		if bool(item.get("selected", false)):
			to_delete.append(item)
	if to_delete.is_empty():
		return
	_build_gen += 1
	_rows.clear()
	if _vlist:
		_vlist.clear()
	_audio_items.clear()
	_audio_groups.clear()
	_audio_in_group.clear()
	_update_selection_ui()
	await get_tree().process_frame
	_search_box.text = ""
	_search_query = ""
	for item in to_delete:
		if not FileSystemManager.instance.delete_audio(item["path"]):
			push_error("[DelView] 删除失败: %s" % item["path"])
	await get_tree().process_frame
	_build_audio_page()


func _on_sf2_delete_selected() -> void:
	var to_delete: Array[Dictionary] = []
	for item in _sf2_items:
		if bool(item.get("selected", false)) and not bool(item.get("is_builtin", false)):
			to_delete.append(item)
	if to_delete.is_empty():
		return
	_build_gen += 1
	for item in to_delete:
		if not FileSystemManager.instance.delete_soundfont(item["path"]):
			push_error("[DelView] 删除失败: %s" % item["path"])
	await get_tree().process_frame
	_build_sf2_page()


func _on_skin_delete_selected() -> void:
	var to_delete: Array[Dictionary] = []
	for item in _skin_items:
		if bool(item.get("selected", false)) and not bool(item.get("is_builtin", false)):
			to_delete.append(item)
	if to_delete.is_empty():
		return
	_build_gen += 1
	for item in to_delete:
		if not SkinMGR.remove_skin(item["name"]):
			push_error("[DelView] 皮肤已从列表移除，但文件夹删除失败，请手动清理: %s" % item["path"])
	await get_tree().process_frame
	_build_skin_page()


func _on_bg_delete_selected() -> void:
	var to_delete: Array[Dictionary] = []
	for item in _bg_items:
		if bool(item.get("selected", false)):
			to_delete.append(item)
	if to_delete.is_empty():
		return
	_build_gen += 1
	for item in to_delete:
		if FileSystemManager.instance.delete_background(item["path"]):
			ThemeMGR.invalidate_background_cache(item["name"])
		else:
			push_error("[DelView] 删除失败: %s" % item["path"])
	await get_tree().process_frame
	_build_bg_page()


# ════════════════════════════════════════════════════════════
# 工具
# ════════════════════════════════════════════════════════════

func _update_item_sum(text: String) -> void:
	_item_sum.text = text


## 把勾选态回写到"与节点无关的数据源"。
## 行对象只反映"当前这一屏显示成什么样"，节点是池化复用的，不能当存储用；
## 真正的勾选记录在各 tab 的数据源里（_midi_checked / _audio_items / 扁平数据数组）。
func _set_row_selected(row: Dictionary, on: bool) -> void:
	if bool(row.get("disabled", false)):
		return
	var kind := int(row.get("kind", RowKind.FLAT))
	match _current_tab:
		Tab.MIDI:
			if kind == RowKind.ITEM:
				_midi_checked[String(row["key"])] = on
		Tab.AUDIO:
			if kind == RowKind.ITEM:
				var idx := int(String(row["key"]).substr(1))
				if idx >= 0 and idx < _audio_items.size():
					_audio_items[idx]["selected"] = on
		_:
			if row.has("index"):
				var arr := _current_flat_items()
				var i := int(row["index"])
				if i >= 0 and i < arr.size():
					arr[i]["selected"] = on


## 组行勾选 → 联动其所有子行（子行未建则记在 _midi_checked，展开时还原）
func _midi_set_group_checked(album_id: String, on: bool) -> void:
	for k in _midi_children.get(album_id, []):
		_midi_checked[String(k)] = on
	_sync_built_children_checked(album_id, on)


func _audio_set_group_checked(song_name: String, on: bool) -> void:
	for idx in _audio_in_group.get(song_name, []):
		var i := int(idx)
		if i < _audio_items.size():
			_audio_items[i]["selected"] = on
	_sync_built_children_checked(song_name, on)


## 把某组"已经建出来的"子行勾选态统一同步：一次线性遍历，
## 不要对每条子数据调 _find_row（那是 O(组大小 × 总行数)）
func _sync_built_children_checked(group_key: String, on: bool) -> void:
	for row in _rows:
		if int(row.get("kind", RowKind.FLAT)) != RowKind.ITEM:
			continue
		if String(row.get("group", "")) != group_key:
			continue
		row["selected"] = on


## 子行勾选 → 回写组行勾选态（全选 / 全不选 / 否则走半选视觉）
func _sync_group_check_state(group_key: String) -> void:
	var group_row := _find_row(group_key)
	if group_row.is_empty():
		return
	var checked := 0
	var total := 0
	match _current_tab:
		Tab.MIDI:
			for k in _midi_children.get(group_key, []):
				total += 1
				if bool(_midi_checked.get(String(k), false)):
					checked += 1
		Tab.AUDIO:
			for idx in _audio_in_group.get(group_key, []):
				total += 1
				if bool(_audio_items[int(idx)].get("selected", false)):
					checked += 1
		_:
			return
	group_row["selected"] = (total > 0 and checked == total)


## 当前扁平页的数据数组（全选回写用）
func _current_flat_items() -> Array:
	match _current_tab:
		Tab.SF2: return _sf2_items
		Tab.SKIN: return _skin_items
		Tab.BG: return _bg_items
	return []


## 全选 / 删除按钮状态：按当前 tab 的实际勾选情况同步
func _update_selection_ui() -> void:
	var any_checked := false
	var all_checked := true
	var countable := 0
	match _current_tab:
		Tab.MIDI:
			countable = _midi_total
			any_checked = _midi_any_checked()
			all_checked = countable > 0 and _midi_all_checked()
		Tab.AUDIO:
			countable = _audio_items.size()
			for item in _audio_items:
				if bool(item.get("selected", false)):
					any_checked = true
				else:
					all_checked = false
		_:
			var arr := _current_flat_items()
			countable = arr.size()
			for item in arr:
				if bool(item.get("is_builtin", false)):
					continue
				if bool(item.get("selected", false)):
					any_checked = true
				else:
					all_checked = false

	if countable == 0:
		_select_toggle.set_pressed_no_signal(false)
		_select_toggle.text = "全选"
		_select_toggle.disabled = true
		_delete_btn.disabled = true
		return
	_select_toggle.disabled = false
	_select_toggle.set_pressed_no_signal(all_checked)
	_select_toggle.text = "取消全选" if all_checked else "全选"
	_delete_btn.disabled = not any_checked


## 勾选统计一律以 _midi_checked 为准（它是与节点无关的真源，覆盖未展开的分组）
func _midi_any_checked() -> bool:
	for k in _midi_checked:
		if bool(_midi_checked[k]):
			return true
	return false


func _midi_all_checked() -> bool:
	if _midi_total <= 0:
		return false
	var n := 0
	for k in _midi_checked:
		if bool(_midi_checked[k]):
			n += 1
	return n >= _midi_total


## 递增构建代次并返回当前值（异步构建用它判断自己是否已过期）
func _bump_gen() -> int:
	_build_gen += 1
	return _build_gen


func _on_data_loaded() -> void:
	_tab_data_built[Tab.MIDI] = false
	if _delview_entered and _current_tab == Tab.MIDI:
		_build_midi_page()

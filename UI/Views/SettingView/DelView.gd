extends HBoxContainer
class_name DelView

enum Tab {MIDI = 0, AUDIO = 1, SF2 = 2, SKIN = 3, BG = 4}

const TREE_ROOT_SCENE := preload("res://UI/Views/SettingView/TreeRoot.tscn")
const TREE_ITEM_SCENE := preload("res://UI/Views/SettingView/TreeItem.tscn")

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

# ── PageContainer ──
@onready var _page_container := $Content/PageContainer as TabContainer

# ── MIDI 页面 ──
@onready var _midi_list := $Content/PageContainer/MidiPage2/MidiList as VBoxContainer

# ── 音频页面 ──
@onready var _audio_list := $Content/PageContainer/AudioPage/AudioList as VBoxContainer

# ── SF2 页面 ──
@onready var _sf2_list := $Content/PageContainer/Sf2Page/Sf2List as VBoxContainer

# ── 皮肤页面 ──
@onready var _skin_list := $Content/PageContainer/SkinPage/SkinList as VBoxContainer

# ── 背景页面 ──
@onready var _bg_list := $Content/PageContainer/BgPage/BgList as VBoxContainer

# ── 共享底栏 ──
@onready var _select_toggle := $Content/BottomBarPC/BottomBar/SelectToggle as Button
@onready var _collapse_toggle := $Content/BottomBarPC/BottomBar/CollapseToggle as Button
@onready var _delete_btn := $Content/BottomBarPC/BottomBar/DeleteBtn as Button

# ── TopBar 控件 ──
@onready var _search_box := $Content/PC/TopBar/SearchBox as LineEdit

var _current_tab: Tab = Tab.MIDI
var _search_query: String = ""

# MIDI 数据
var _midi_selected: Dictionary = {}              # midi_id → bool
var _midi_root_map: Dictionary = {}              # album_id → TreeRoot node
var _midi_item_map: Dictionary = {}              # midi_id → TreeItem node
var _midi_album_order: Array = []        # 当前排序的 album_id 列表
var _midi_album_midi_map: Dictionary = {}        # album_id → Array[String] midi_id

# Audio 数据 — 按 song_name 分组
var _audio_items: Array[Dictionary] = []         # 扁平数据（保留用于搜索/选中状态）
var _audio_root_map: Dictionary = {}             # song_name → TreeRoot node
var _audio_item_map: Dictionary = {}             # flat_index → TreeItem node
var _audio_group_order: Array = []       # 当前排序的 song_name 列表
var _audio_items_in_group: Dictionary = {}       # song_name → Array[int] flat indices

# SF2/Skin/BG 数据
var _sf2_items: Array[Dictionary] = []
var _sf2_nodes: Dictionary = {}                  # index → TreeRoot node
var _skin_items: Array[Dictionary] = []
var _skin_nodes: Dictionary = {}                 # index → TreeRoot node
var _bg_items: Array[Dictionary] = []
var _bg_nodes: Dictionary = {}                   # index → TreeRoot node

# 缓存标记（构建锁由 LazyListLoader 内部管理）
var _tab_data_built: Array[bool] = [false, false, false, false, false]

# 懒加载器（每标签页一个）
var _midi_loader: LazyListLoader
var _audio_loader: LazyListLoader
var _sf2_loader: LazyListLoader
var _skin_loader: LazyListLoader
var _bg_loader: LazyListLoader

# DelView 是否已展示过（懒加载守卫：未进入前不构建）
var _delview_entered: bool = false

# 构建上下文（工厂函数使用，避免 Callable.bind 分配）
var _midi_build_albums: Array = []
var _midi_build_total: int = 0

# 专辑子项懒加载：album_id → bool（子项是否已构建）；子项构建工作器 generation（取消在途构建）
var _midi_album_loaded: Dictionary = {}
var _midi_children_gen: int = 0

# MIDI 就地搜索（双层级）：搜索词非空时缓存命中的 folder_name 集合（零水合），
# 供可见性过滤 + 懒加载子项匹配复用；空词时清空并恢复全部可见
var _midi_search_matched_keys: Dictionary = {}


func _ready() -> void:
	# 创建 5 个懒加载器（MIDI/Audio 每组让一帧，SF2/Skin/BG 每 5 项让一帧）
	_midi_loader = LazyListLoader.new(1)
	_audio_loader = LazyListLoader.new(1)
	_sf2_loader = LazyListLoader.new(5)
	_skin_loader = LazyListLoader.new(5)
	_bg_loader = LazyListLoader.new(5)

	for i in _tab_buttons.size():
		_tab_buttons[i].pressed.connect(_on_tab_button_pressed.bind(i))
		_tab_buttons[i].focus_entered.connect(_on_tab_focus_entered.bind(i))

	_select_toggle.toggled.connect(_on_select_toggled)
	_delete_btn.pressed.connect(_on_delete_pressed)
	_collapse_toggle.toggled.connect(_on_collapse_toggled)
	# 底部按钮聚焦时刷新正向循环下一项为当前标签页按钮（切 tab/重建后焦点落在底部时，
	# focus_next 可能是旧 tab 的按钮，聚焦时统一刷新避免 Tab 走错）
	for b in [_select_toggle, _collapse_toggle, _delete_btn]:
		b.focus_entered.connect(_on_bottom_btn_focus_entered)

	DataMGR.data_loaded.connect(_on_data_loaded)

	_search_box.text_changed.connect(_on_search_text_changed)

	# 监听状态变化：离开 SETTINGS_VIEW 时释放全部节点
	UiStatMGR.state_changed.connect(_on_ui_state_changed)

	# 仅设置初始 tab 视觉状态，不触发构建（懒加载：进入 DelView 时才构建）
	_current_tab = Tab.MIDI
	_tab_buttons[Tab.MIDI].set_pressed_no_signal(true)
	_page_container.current_tab = Tab.MIDI
	_tab_title.text = "MIDI 谱面管理"
	_update_item_sum("未加载")
	_collapse_toggle.visible = true
	# MIDI 页默认只显示专辑层（折叠）：折叠按钮初始为「展开全部」态
	_collapse_toggle.set_pressed_no_signal(true)
	_collapse_toggle.text = "展开全部"
	_select_toggle.disabled = true
	_delete_btn.disabled = true

	# 注册主题应用者并首次着色
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()

## 应用主题色（由 ThemeManager 广播调用 + _ready 首次自调）
## 标签页按钮的 focus 直接复用共享 Theme 的 focus StyleBox（ThemeManager 就地改色），不再逐按钮 duplicate 覆盖
func apply_theme() -> void:
	var top_panel := get_node_or_null("Content/PC") as PanelContainer
	if top_panel:
		var sb := top_panel.get_theme_stylebox("panel")
		if sb is StyleBoxFlat:
			sb.bg_color = ThemeMGR.get_color("surface")

## 标签页按钮聚焦时自动切换（与 SettingView 快捷按钮聚焦自动按下一致）
func _on_tab_focus_entered(idx: int) -> void:
	if idx != _current_tab:
		_switch_tab(idx as Tab)

## 聚焦首个标签按钮（MIDI 管理），由 FocusManager 在进入 DelView 时调用
func focus_first_tab() -> void:
	_tab_buttons[Tab.MIDI].grab_focus()

## 更新 DelView 区域间焦点关系
## - Tab 循环：标签页按钮 → 搜索栏 → 底部按钮（正向/反向）
## - 标签页按钮右进：当前标签页内容的第一个可聚焦项；内容项左退回标签页按钮
## 依赖当前 tab 与内容项，需在 tab 切换、内容构建后调用
func _update_focus_relations() -> void:
	var tab_btn := _tab_buttons[_current_tab]
	var tab_path := tab_btn.get_path()
	# 反向循环：搜索栏 ← 当前标签页按钮；标签页按钮 ← 底部末尾按钮
	_search_box.focus_previous = tab_path
	for b in _tab_buttons:
		b.focus_previous = _delete_btn.get_path()
	# 正向循环：底部三个按钮 → 当前标签页按钮（搜索栏→底部已在 tscn 配置）
	for b in [_select_toggle, _collapse_toggle, _delete_btn]:
		b.focus_next = tab_path
	# 标签页按钮右进当前内容首项；内容各可聚焦项左退回到标签页按钮
	var list := _get_current_tab_list()
	var first_in_content := _get_first_focusable(list)
	var right_path := first_in_content.get_path() if first_in_content else NodePath("")
	for b in _tab_buttons:
		b.focus_neighbor_right = right_path
	if list:
		_set_list_left_neighbor(list, tab_path)


## 底部按钮聚焦时刷新三个按钮的正向循环下一项为当前标签页按钮
## 仅当焦点落在底部时刷新（避免每次可见性变化全量重算），Tab 从底部按钮即可回到当前标签页
func _on_bottom_btn_focus_entered() -> void:
	var tab_path := _tab_buttons[_current_tab].get_path()
	for b in [_select_toggle, _collapse_toggle, _delete_btn]:
		b.focus_next = tab_path


func _get_current_tab_list() -> VBoxContainer:
	match _current_tab:
		Tab.MIDI: return _midi_list
		Tab.AUDIO: return _audio_list
		Tab.SF2: return _sf2_list
		Tab.SKIN: return _skin_list
		Tab.BG: return _bg_list
	return null


## 列表中第一个可聚焦控件（TreeRoot/TreeItem 的 CheckBox）
func _get_first_focusable(root: Node) -> Control:
	if root is Control and root.focus_mode != Control.FOCUS_NONE and root.is_visible_in_tree():
		return root
	for child in root.get_children():
		var r := _get_first_focusable(child)
		if r:
			return r
	return null


## 给列表内所有可聚焦控件设置左邻居为标签页按钮（左方向键退回标签页）
func _set_list_left_neighbor(root: Node, tab_path: NodePath) -> void:
	if root is Control and root.focus_mode != Control.FOCUS_NONE:
		root.focus_neighbor_left = tab_path
	for child in root.get_children():
		_set_list_left_neighbor(child, tab_path)

func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)


# ============================================================
# 生命周期（由 SettingView 调用）
# ============================================================

## 进入 DelView（SettingView.switch_page(-1) 调用）：触发当前 tab 构建
func on_entered() -> void:
	_delview_entered = true
	_ensure_tab_built(_current_tab)
	_update_focus_relations()


## 返回设置主页（SettingView.switch_page(1) 调用）：保留节点，再进入立即可见。
## 离开 DelView 时重置页面搜索状态，再进入展示干净的两层级列表（不触发重建）
func on_exited_to_setting_list() -> void:
	if not _search_box.text.is_empty():
		_search_box.text = ""
	_search_query = ""
	_midi_search_matched_keys.clear()
	_apply_search_filter()


## 离开 SETTINGS_VIEW 时释放全部节点
func _on_ui_state_changed(_old: int, new: int) -> void:
	if new != UIStateManager.UIState.SETTINGS_VIEW:
		_release_all_loaders()


## 释放所有 loader 的节点 + 重置状态
func _release_all_loaders() -> void:
	for loader in [_midi_loader, _audio_loader, _sf2_loader, _skin_loader, _bg_loader]:
		if loader:
			loader.cancel()
	_cancel_all_expand_loaders()
	_clear_page(_midi_list, [_midi_root_map, _midi_item_map, _midi_selected, _midi_album_order, _midi_album_midi_map, _midi_album_loaded])
	_clear_page(_audio_list, [_audio_root_map, _audio_item_map, _audio_group_order, _audio_items_in_group, _audio_items])
	_clear_page(_sf2_list, [_sf2_nodes, _sf2_items])
	_clear_page(_skin_list, [_skin_nodes, _skin_items])
	_clear_page(_bg_list, [_bg_nodes, _bg_items])
	_tab_data_built = [false, false, false, false, false]
	_delview_entered = false
	_midi_search_matched_keys.clear()
	if _search_box:
		_search_box.text = ""
	_search_query = ""
	_update_item_sum("未加载")
	_select_toggle.set_pressed_no_signal(false)
	_select_toggle.disabled = true
	_delete_btn.disabled = true


## 获取指定 tab 的 loader
func _get_loader(tab: Tab) -> LazyListLoader:
	match tab:
		Tab.MIDI: return _midi_loader
		Tab.AUDIO: return _audio_loader
		Tab.SF2: return _sf2_loader
		Tab.SKIN: return _skin_loader
		Tab.BG: return _bg_loader
	return null


## 确保指定 tab 已构建（懒加载守卫；fire-and-forget 异步构建）
func _ensure_tab_built(tab: Tab) -> void:
	if _tab_data_built[tab]:
		return
	var loader := _get_loader(tab)
	if loader and loader.is_building():
		return
	match tab:
		Tab.MIDI:
			_tab_title.text = "MIDI 谱面管理"
			_build_midi_page()
		Tab.AUDIO:
			_tab_title.text = "人声音频管理"
			_build_audio_page()
		Tab.SF2:
			_tab_title.text = "SF2 音源管理"
			_build_sf2_page()
		Tab.SKIN:
			_tab_title.text = "皮肤管理"
			_build_skin_page()
		Tab.BG:
			_tab_title.text = "背景管理"
			_build_bg_page()


# ============================================================
# Tab 切换
# ============================================================

func _on_tab_button_pressed(idx: int) -> void:
	if idx == _current_tab:
		return
	_switch_tab(idx as Tab)


func _switch_tab(tab: Tab) -> void:
	if tab == _current_tab:
		return
	# 取消旧 tab 的 in-flight build
	var old_tab := _current_tab
	var old_loader := _get_loader(old_tab)
	if old_loader:
		old_loader.cancel()
	_current_tab = tab
	# set_pressed 经按钮组互斥，自动取消其它标签按钮的按下状态
	_tab_buttons[tab].set_pressed(true)
	_page_container.current_tab = tab

	_search_box.text = ""
	_search_query = ""

	_collapse_toggle.visible = (tab == Tab.MIDI or tab == Tab.AUDIO)

	match tab:
		Tab.MIDI: _tab_title.text = "MIDI 谱面管理"
		Tab.AUDIO: _tab_title.text = "人声音频管理"
		Tab.SF2: _tab_title.text = "SF2 音源管理"
		Tab.SKIN: _tab_title.text = "皮肤管理"
		Tab.BG: _tab_title.text = "背景管理"

	if _tab_data_built[tab]:
		# 已缓存：仅更新 header + 搜索
		_update_tab_header(tab)
		_apply_search_filter()
		_update_focus_relations()
		return

	# 未构建：显示"加载中"，若已进入 DelView 则触发构建
	_update_item_sum("加载中...")
	_select_toggle.disabled = true
	_delete_btn.disabled = true
	if _delview_entered:
		_ensure_tab_built(tab)


func _on_select_toggled(toggled: bool) -> void:
	match _current_tab:
		Tab.MIDI:
			_on_midi_select_toggled(toggled)
		Tab.AUDIO:
			_on_audio_select_toggled(toggled)
		Tab.SF2:
			_on_sf2_select_toggled(toggled)
		Tab.SKIN:
			_on_skin_select_toggled(toggled)
		Tab.BG:
			_on_bg_select_toggled(toggled)


func _on_delete_pressed() -> void:
	match _current_tab:
		Tab.MIDI:
			_on_midi_delete_selected()
		Tab.AUDIO:
			_on_audio_delete_selected()
		Tab.SF2:
			_on_sf2_delete_selected()
		Tab.SKIN:
			_on_skin_delete_selected()
		Tab.BG:
			_on_bg_delete_selected()


func _update_tab_header(tab: Tab) -> void:
	_collapse_toggle.visible = (tab == Tab.MIDI or tab == Tab.AUDIO)
	match tab:
		Tab.MIDI:
			_tab_title.text = "MIDI 谱面管理"
			_update_item_sum("共 %d 首谱面" % _midi_selected.size())
			_update_midi_toggle_state()
		Tab.AUDIO:
			_tab_title.text = "人声音频管理"
			_update_item_sum("共 %d 个音频文件" % _audio_items.size())
			_update_flat_toggle_state(_audio_items)
		Tab.SF2:
			_tab_title.text = "SF2 音源管理"
			_update_item_sum("共 %d 个音源" % _sf2_items.size())
			_update_flat_toggle_state(_sf2_items)
		Tab.SKIN:
			_tab_title.text = "皮肤管理"
			_update_item_sum("共 %d 个皮肤" % _skin_items.size())
			_update_flat_toggle_state(_skin_items)
		Tab.BG:
			_tab_title.text = "背景管理"
			_update_item_sum("共 %d 张背景" % _bg_items.size())
			_update_flat_toggle_state(_bg_items)
	_sync_collapse_button()


## 将折叠按钮的 pressed/text 同步到当前 tab 的实际折叠态
## （MIDI 默认全折叠 → pressed=true「展开全部」；Audio 默认全展开 → pressed=false「收起全部」）
## 无根节点（未构建/扁平搜索/SF2 等页）时保持现状
func _sync_collapse_button() -> void:
	if not _collapse_toggle:
		return
	var all_collapsed := true
	var any_root := false
	match _current_tab:
		Tab.MIDI:
			for album_id in _midi_root_map:
				any_root = true
				if not bool(_midi_root_map[album_id].get_meta("collapsed", false)):
					all_collapsed = false
		Tab.AUDIO:
			for song_name in _audio_root_map:
				any_root = true
				if not bool(_audio_root_map[song_name].get_meta("collapsed", false)):
					all_collapsed = false
	if not any_root:
		return
	_collapse_toggle.set_pressed_no_signal(all_collapsed)
	_collapse_toggle.text = "展开全部" if all_collapsed else "收起全部"


# ============================================================
# MIDI 管理 — TreeRoot（专辑）+ TreeItem（歌曲）
# ============================================================

func _build_midi_page() -> void:
	_tab_data_built[Tab.MIDI] = false
	_cancel_all_expand_loaders()
	_clear_page(_midi_list, [_midi_root_map, _midi_item_map, _midi_selected, _midi_album_order, _midi_album_midi_map, _midi_album_loaded])
	_update_item_sum("加载中...")
	_update_midi_toggle_state()

	# 等待 FileSystemManager 扫描 + 后台缓存校验全部完成
	# 防止用户在 charts_index 重建期间删除条目，导致 rescan 与校验协程并发 clobber
	if FileSystemManager.instance.is_busy():
		_update_item_sum("资源扫描中...")
		await FileSystemManager.instance.await_busy_done()
		# 等待期间若 tab 切走 / 退出 DelView，放弃构建
		if _current_tab != Tab.MIDI or not _delview_entered:
			return

	var dm := DataMGR
	# 数据是否存在以 DB 为准（惰性水合下内存缓存可能为空）
	if ChartDB == null or not ChartDB.IsOpen() or ChartDB.CountCharts() == 0:
		if dm.is_loading:
			_update_item_sum("数据加载中...")
		else:
			_update_item_sum("无谱面数据")
			_tab_data_built[Tab.MIDI] = true
		return

	# 数据源：与 AlbumView 同一套 [Browse] 配置排序（creation_time/download_time/name 三态），Unknown 由 C# 排最后
	var method_str := ConfigManager.instance.get_string("Browse", "album_sort_method", "creation_time")
	var dir_str := ConfigManager.instance.get_string("Browse", "album_sort_direction", "asc")
	var direction := 0 if dir_str == "asc" else 1
	_midi_build_albums = ChartDB.GetSortedAlbumItems(method_str, direction)
	if _midi_build_albums.is_empty():
		_update_item_sum("无谱面数据")
		_tab_data_built[Tab.MIDI] = true
		return

	# 懒加载：只建专辑层（折叠态），展开/展开全部时才加载各专辑子项
	_midi_build_total = 0
	var completed: bool = await _midi_loader.build(_midi_build_albums.size(), _create_midi_album_root)
	if not completed:
		return  # 被取消（切 tab / 退出 DelView / 删除流程）
	if _current_tab != Tab.MIDI:
		return  # 构建期间切走，不覆写当前页 header
	_update_item_sum("共 %d 首谱面" % _midi_build_total)
	_update_midi_toggle_state()
	await _apply_scrolls_to_container(_midi_list)
	_tab_data_built[Tab.MIDI] = true
	_update_tab_header(Tab.MIDI)
	# 构建期间用户输入了搜索词，build 完成后补一次过滤
	if not _search_query.is_empty():
		_apply_search_filter()
	_update_focus_relations()


## MIDI 工厂（专辑层）：只创建 TreeRoot（折叠态），不创建子项
## 用 GetMidiKeysBySong（不水合）收集该专辑全部 midi key，预填 _midi_selected 供全选/勾选使用
## 返回 Array[Node]（已 add_child）；返回 null 请求中止构建
func _create_midi_album_root(album_index: int) -> Variant:
	if _current_tab != Tab.MIDI:
		return null  # 请求中止
	var album: Dictionary = _midi_build_albums[album_index]
	var album_id := String(album.get("id", ""))

	var root_node := _create_tree_root(String(album.get("name", "")), "%d 首" % album.get("total_midi_count", 0), album_id)
	_midi_list.add_child(root_node)
	_midi_root_map[album_id] = root_node
	_midi_album_order.append(album_id)
	_midi_album_loaded[album_id] = false
	# 默认折叠：只显示专辑层，子项按需加载
	root_node.set_meta("collapsed", true)

	var root_cb := root_node.get_node("CheckBox") as CheckBox
	root_cb.toggled.connect(_on_midi_root_checkbox_toggled.bind(album_id))

	# 收集该专辑全部 midi key（轻量，不水合 MidiData），供选择数据与子项构建复用
	var album_midis: Array[String] = []
	for song in DataMGR.get_songs_by_album(album_id):
		for midi_key: String in ChartDB.GetMidiKeysBySong(String(song.get("id", ""))):
			_midi_selected[midi_key] = false
			album_midis.append(midi_key)
	_midi_album_midi_map[album_id] = album_midis
	_midi_build_total += album_midis.size()
	return [root_node]


## MIDI 子项工厂：为指定专辑创建一条 TreeItem（懒加载，展开时才逐条构建）
## slot_index 为 _midi_album_midi_map[album_id] 中的下标；每次只水合一条
## 用 root_node.add_sibling 插到专辑根之后，保证专辑块在列表中保持连续
## 返回 Array[Node]（已 add_child）；返回 null 请求中止构建
func _create_midi_album_child(slot_index: int, album_id: String) -> Variant:
	if _current_tab != Tab.MIDI:
		return null  # 请求中止
	var root_node: HBoxContainer = _midi_root_map.get(album_id)
	if not root_node:
		return null
	var slots: Array = _midi_album_midi_map.get(album_id, [])
	if slot_index < 0 or slot_index >= slots.size():
		return null
	var midi_key := String(slots[slot_index])
	if _midi_item_map.has(midi_key):
		return []  # 已存在（取消后重入续建），跳过
	var midi: MidiData = DataMGR.get_midi_by_id(midi_key)
	if not midi:
		return null

	var author := midi.artist_name if not midi.artist_name.is_empty() else "-"
	var item_node := _create_tree_item("    %s" % midi.name, author)
	# 插到专辑根之后（add_sibling = 紧随其后），折叠态时隐藏
	root_node.add_sibling(item_node)
	item_node.visible = not bool(root_node.get_meta("collapsed", false))
	# 就地搜索激活时：新构建的子项按命中集过滤（专辑根已命中才可能被展开）
	if not _search_query.is_empty():
		item_node.visible = item_node.visible and _midi_search_matched_keys.has(midi_key)
	_midi_item_map[midi_key] = item_node

	var item_cb := item_node.get_node("CheckBox") as CheckBox
	item_cb.set_pressed_no_signal(_midi_selected.get(midi_key, false))
	item_cb.toggled.connect(_on_midi_item_checkbox_toggled.bind(midi_key, album_id))
	return [item_node]


## 为指定专辑（或一组）构建子项：单线程顺序构建，每 20 条让一帧，单帧负载有界
## 工厂幂等（已存在节点跳过），被取消后可安全重入续建（不重复）
func _build_albums_children(album_ids: Array) -> void:
	_midi_children_gen += 1
	var my_gen := _midi_children_gen
	var built := 0
	for album_id in album_ids:
		if my_gen != _midi_children_gen:
			return  # 被新的子项构建取代
		if _current_tab != Tab.MIDI:
			return
		if _midi_album_loaded.get(album_id, false):
			continue
		var slots: Array = _midi_album_midi_map.get(album_id, [])
		if slots.is_empty():
			_midi_album_loaded[album_id] = true
			continue
		var album_done := true
		for slot in slots.size():
			if my_gen != _midi_children_gen:
				return
			if _current_tab != Tab.MIDI:
				return
			if _create_midi_album_child(slot, album_id) == null:
				album_done = false
				break
			built += 1
			if built % 20 == 0:
				await get_tree().process_frame
		if album_done:
			_midi_album_loaded[album_id] = true
	await _apply_scrolls_to_container(_midi_list)
	_update_focus_relations()


## 展开单个专辑：开始构建其子项（fire-and-forget）
func _start_load_album_children(album_id: String) -> void:
	_build_albums_children([album_id])


## 「展开全部」：顺序构建所有未加载专辑的子项（fire-and-forget）
func _load_all_midi_children() -> void:
	_build_albums_children(_midi_root_map.keys())


## 取消所有在途的子项构建（重建/删除/退出时调用）
func _cancel_all_expand_loaders() -> void:
	_midi_children_gen += 1


func _on_data_loaded() -> void:
	# 数据加载完成：标记 MIDI 页需重建；若 DelView 已进入且当前在 MIDI 页则立即重建
	_tab_data_built[Tab.MIDI] = false
	if _delview_entered and _current_tab == Tab.MIDI:
		_midi_loader.cancel()
		_build_midi_page()

# ── MIDI 勾选逻辑 ──

func _on_midi_root_checkbox_toggled(toggled: bool, album_id: String) -> void:
	var midi_ids: Array = _midi_album_midi_map.get(album_id, [])
	for midi_id in midi_ids:
		if not _midi_selected.has(midi_id):
			continue
		_midi_selected[midi_id] = toggled
		if _midi_item_map.has(midi_id):
			var item_node: HBoxContainer = _midi_item_map[midi_id]
			var cb := item_node.get_node("CheckBox") as CheckBox
			cb.set_pressed_no_signal(toggled)
	# 清除不确定状态
	var root_node: HBoxContainer = _midi_root_map.get(album_id)
	if root_node:
		var root_cb := root_node.get_node("CheckBox") as CheckBox
		_set_indeterminate(root_cb, false)
	_update_midi_toggle_state()


func _on_midi_item_checkbox_toggled(toggled: bool, midi_id: String, album_id: String) -> void:
	_midi_selected[midi_id] = toggled
	_update_root_check_state(album_id)
	_update_midi_toggle_state()


func _update_root_check_state(album_id: String) -> void:
	if not _midi_root_map.has(album_id):
		return
	var root_node: HBoxContainer = _midi_root_map[album_id]
	var root_cb := root_node.get_node("CheckBox") as CheckBox

	var midi_ids: Array = _midi_album_midi_map.get(album_id, [])
	var checked_count := 0
	var total := 0
	for midi_id in midi_ids:
		if not _midi_selected.has(midi_id):
			continue
		total += 1
		if _midi_selected[midi_id]:
			checked_count += 1

	if total == 0:
		root_cb.set_pressed_no_signal(false)
		_set_indeterminate(root_cb, false)
	elif checked_count == total:
		root_cb.set_pressed_no_signal(true)
		_set_indeterminate(root_cb, false)
	elif checked_count == 0:
		root_cb.set_pressed_no_signal(false)
		_set_indeterminate(root_cb, false)
	else:
		root_cb.set_pressed_no_signal(false)
		_set_indeterminate(root_cb, true)


func _on_midi_select_toggled(toggled: bool) -> void:
	_select_toggle.text = "取消全选" if toggled else "全选"
	# 两层模式：按专辑分组更新（含 root checkbox）
	for album_id in _midi_root_map:
		var midi_ids: Array = _midi_album_midi_map.get(album_id, [])
		for midi_id in midi_ids:
			if not _midi_selected.has(midi_id):
				continue
			_midi_selected[midi_id] = toggled
			if _midi_item_map.has(midi_id):
				var item_node: HBoxContainer = _midi_item_map[midi_id]
				var cb := item_node.get_node("CheckBox") as CheckBox
				cb.set_pressed_no_signal(toggled)
		var root_node: HBoxContainer = _midi_root_map[album_id]
		var root_cb := root_node.get_node("CheckBox") as CheckBox
		root_cb.set_pressed_no_signal(toggled)
		_set_indeterminate(root_cb, false)
	_update_midi_toggle_state()


func _update_midi_toggle_state() -> void:
	if _midi_selected.is_empty():
		_select_toggle.set_pressed_no_signal(false)
		_select_toggle.text = "全选"
		_select_toggle.disabled = true
		_delete_btn.disabled = true
		return

	var all_selected := true
	var any_selected := false
	for midi_id in _midi_selected:
		if _midi_selected[midi_id]:
			any_selected = true
		else:
			all_selected = false

	_select_toggle.disabled = false
	_select_toggle.set_pressed_no_signal(all_selected)
	_select_toggle.text = "取消全选" if all_selected else "全选"
	_delete_btn.disabled = not any_selected


func _on_midi_delete_selected() -> void:
	var to_delete: Array[String] = []
	for midi_id in _midi_selected:
		if _midi_selected[midi_id]:
			to_delete.append(midi_id)

	if to_delete.is_empty():
		return

	# 取消进行中的 build，避免删除过程中工厂继续往已清空的容器写入
	_midi_loader.cancel()
	_cancel_all_expand_loaders()

	# 先清空页面（视觉即时反馈）
	_clear_page(_midi_list, [_midi_root_map, _midi_item_map, _midi_album_loaded])
	_midi_album_order.clear()
	_midi_album_midi_map.clear()
	_midi_selected.clear()
	_update_midi_toggle_state()
	await get_tree().process_frame

	# 清除搜索状态，确保重建后显示全部内容
	_search_box.text = ""
	_search_query = ""
	_midi_search_matched_keys.clear()

	# 批量删除：文件逐个删（每 3 个让一帧），DB 一次性提交（单锁 + 单次聚合重建）
	var removed := await FileSystemManager.instance.delete_charts_batch(to_delete)
	for midi_id in removed:
		DataMGR.remove_midi(midi_id)
	for midi_id in to_delete:
		if not removed.has(midi_id):
			push_error("[DelView] 删除失败: %s" % midi_id)
	if not removed.is_empty():
		# 聚合通知一次，避免逐 id 触发 N 次视图刷新/收藏夹写盘
		EvtBus.midis_deleted.emit(removed)

	await get_tree().process_frame
	_build_midi_page()


# ============================================================
# 音频管理 — TreeRoot（歌曲）+ TreeItem（文件）
# ============================================================

func _build_audio_page() -> void:
	_tab_data_built[Tab.AUDIO] = false
	_clear_page(_audio_list, [_audio_root_map, _audio_item_map])
	_audio_group_order.clear()
	_audio_items_in_group.clear()

	_update_item_sum("扫描中...")
	_audio_items = await _scan_audio_files()

	if _audio_items.is_empty():
		_update_item_sum("无音频文件")
		_update_flat_toggle_state(_audio_items)
		_tab_data_built[Tab.AUDIO] = true
		return

	# 按 song_name 分组
	var groups: Dictionary = {}
	for i in _audio_items.size():
		var song_name: String = _audio_items[i]["song_name"]
		if not groups.has(song_name):
			groups[song_name] = []
		groups[song_name].append(i)

	# 排序分组
	var group_names := groups.keys()
	group_names.sort_custom(func(a, b): return a < b)
	_audio_group_order = group_names
	_audio_items_in_group = groups

	var completed: bool = await _audio_loader.build(group_names.size(), _create_audio_group)
	if not completed:
		return
	if _current_tab != Tab.AUDIO:
		return
	_update_item_sum("共 %d 个音频文件" % _audio_items.size())
	_update_flat_toggle_state(_audio_items)
	await _apply_scrolls_to_container(_audio_list)
	_tab_data_built[Tab.AUDIO] = true
	_update_tab_header(Tab.AUDIO)
	if not _search_query.is_empty():
		_apply_search_filter()
	_update_focus_relations()


## Audio 工厂：创建一个 song_name 分组（TreeRoot + 该组所有音频 TreeItem）
func _create_audio_group(group_index: int) -> Variant:
	if _current_tab != Tab.AUDIO:
		return null
	var song_name: String = _audio_group_order[group_index]
	var indices: Array = _audio_items_in_group[song_name]
	var created: Array = []

	# 创建 TreeRoot
	var root_node := _create_tree_root(song_name, "%d 个" % indices.size(), song_name)
	_audio_list.add_child(root_node)
	_audio_root_map[song_name] = root_node
	created.append(root_node)

	var root_cb := root_node.get_node("CheckBox") as CheckBox
	root_cb.toggled.connect(_on_audio_root_checkbox_toggled.bind(song_name))

	for idx in indices:
		var item: Dictionary = _audio_items[idx]
		var fmt: String = item.get("format", "")
		var item_node := _create_tree_item(item["file_name"], fmt)
		_audio_list.add_child(item_node)
		_audio_item_map[idx] = item_node
		created.append(item_node)

		var item_cb := item_node.get_node("CheckBox") as CheckBox
		item_cb.toggled.connect(_on_audio_item_checkbox_toggled.bind(idx, song_name))

	return created


func _scan_audio_files() -> Array[Dictionary]:
	# 优先从 FileSystemManager 索引读取
	var result: Array[Dictionary] = []
	var fs_mgr = FileSystemManager.instance
	if fs_mgr and not fs_mgr.audio_files_index.is_empty():
		for entry in fs_mgr.audio_files_index:
			result.append({
				"file_name": entry["file_name"],
				"path": entry["path"],
				"format": entry["format"],
				"song_name": entry["song_name"],
				"selected": false,
			})
		return result

	# 回退：独立扫描文件系统
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
			var song_name: String = dn
			var hash_idx := song_name.find("_")
			if hash_idx >= 0:
				song_name = song_name.substr(hash_idx + 1)
			for ext in audio_exts:
				var files := FileSystemManager.instance.find_files_in_dir(chart_path, "*." + ext)
				for f in files:
					result.append({
						"file_name": f,
						"path": chart_path.path_join(f),
						"format": ext,
						"song_name": song_name,
						"selected": false,
					})
			dir_count += 1
			if dir_count % 5 == 0:
				await get_tree().process_frame
		dn = dir.get_next()
	dir.list_dir_end()

	result.sort_custom(func(a, b):
		var cmp_song = a["song_name"] < b["song_name"]
		if cmp_song: return true
		if a["song_name"] > b["song_name"]: return false
		return a["format"] < b["format"]
	)
	return result


func _on_audio_root_checkbox_toggled(toggled: bool, song_name: String) -> void:
	var indices: Array = _audio_items_in_group.get(song_name, [])
	for idx in indices:
		_audio_items[idx]["selected"] = toggled
		if _audio_item_map.has(idx):
			var item_node: HBoxContainer = _audio_item_map[idx]
			var cb := item_node.get_node("CheckBox") as CheckBox
			cb.set_pressed_no_signal(toggled)
	# 清除不确定状态
	var root_node: HBoxContainer = _audio_root_map.get(song_name)
	if root_node:
		var root_cb := root_node.get_node("CheckBox") as CheckBox
		_set_indeterminate(root_cb, false)
	_update_flat_toggle_state(_audio_items)


func _on_audio_item_checkbox_toggled(toggled: bool, idx: int, song_name: String) -> void:
	_audio_items[idx]["selected"] = toggled
	_update_audio_root_check_state(song_name)
	_update_flat_toggle_state(_audio_items)


func _update_audio_root_check_state(song_name: String) -> void:
	if not _audio_root_map.has(song_name):
		return
	var root_node: HBoxContainer = _audio_root_map[song_name]
	var root_cb := root_node.get_node("CheckBox") as CheckBox

	var indices: Array = _audio_items_in_group.get(song_name, [])
	var checked_count := 0
	for idx in indices:
		if _audio_items[idx]["selected"]:
			checked_count += 1

	if indices.is_empty():
		root_cb.set_pressed_no_signal(false)
		_set_indeterminate(root_cb, false)
	elif checked_count == indices.size():
		root_cb.set_pressed_no_signal(true)
		_set_indeterminate(root_cb, false)
	elif checked_count == 0:
		root_cb.set_pressed_no_signal(false)
		_set_indeterminate(root_cb, false)
	else:
		root_cb.set_pressed_no_signal(false)
		_set_indeterminate(root_cb, true)


func _on_audio_select_toggled(toggled: bool) -> void:
	for i in _audio_items.size():
		_audio_items[i]["selected"] = toggled
		if _audio_item_map.has(i):
			var item_node: HBoxContainer = _audio_item_map[i]
			var cb := item_node.get_node("CheckBox") as CheckBox
			cb.set_pressed_no_signal(toggled)
	# 同步所有 TreeRoot 的勾选状态
	for song_name in _audio_root_map:
		var root_node: HBoxContainer = _audio_root_map[song_name]
		var root_cb := root_node.get_node("CheckBox") as CheckBox
		root_cb.set_pressed_no_signal(toggled)
		_set_indeterminate(root_cb, false)
	_select_toggle.text = "取消全选" if toggled else "全选"
	_update_flat_toggle_state(_audio_items)


func _on_audio_delete_selected() -> void:
	var to_delete: Array[Dictionary] = []
	for item in _audio_items:
		if item["selected"]:
			to_delete.append(item)

	if to_delete.is_empty():
		return

	# 取消进行中的 build
	_audio_loader.cancel()

	# 先清空页面（视觉即时反馈）
	_clear_page(_audio_list, [_audio_root_map, _audio_item_map])
	_audio_group_order.clear()
	_audio_items_in_group.clear()
	_audio_items.clear()
	_update_flat_toggle_state(_audio_items)
	await get_tree().process_frame

	# 清除搜索状态
	_search_box.text = ""
	_search_query = ""

	for item in to_delete:
		if FileSystemManager.instance.delete_audio(item["path"]):
			pass
		else:
			push_error("[DelView] 删除失败: %s" % item["path"])

	await get_tree().process_frame
	_build_audio_page()


# ============================================================
# SF2 管理 — 扁平 TreeRoot
# ============================================================

func _build_sf2_page() -> void:
	_tab_data_built[Tab.SF2] = false
	_clear_page(_sf2_list, [_sf2_nodes])
	_sf2_items = _scan_sf2_files()

	if _sf2_items.is_empty():
		_update_item_sum("无 SF2 音源")
		_update_flat_toggle_state(_sf2_items)
		_tab_data_built[Tab.SF2] = true
		return

	var completed: bool = await _sf2_loader.build(_sf2_items.size(), _create_sf2_item)
	if not completed:
		return
	if _current_tab != Tab.SF2:
		return
	_update_item_sum("共 %d 个音源" % _sf2_items.size())
	_update_flat_toggle_state(_sf2_items)
	await _apply_scrolls_to_container(_sf2_list)
	_tab_data_built[Tab.SF2] = true
	_update_tab_header(Tab.SF2)
	if not _search_query.is_empty():
		_apply_search_filter()
	_update_focus_relations()


## SF2 工厂：创建一个扁平 TreeRoot
func _create_sf2_item(index: int) -> Variant:
	if _current_tab != Tab.SF2:
		return null
	var item: Dictionary = _sf2_items[index]
	var display_name: String = item["file_name"]
	if item["is_builtin"]:
		display_name += " [内置]"
	var size_text := "%.1f MB" % item["size_mb"]

	var root_node := _create_tree_root(display_name, size_text, "")
	root_node.set_meta("flat_index", index)
	_sf2_list.add_child(root_node)
	_sf2_nodes[index] = root_node

	var cb := root_node.get_node("CheckBox") as CheckBox
	cb.button_pressed = item["selected"]
	if item["is_builtin"]:
		cb.disabled = true
	cb.toggled.connect(func(on: bool):
		_sf2_items[index]["selected"] = on
		_update_flat_toggle_state(_sf2_items)
	)

	# 扁平项不折叠，隐藏点击展开事件
	root_node.get_node("RightLabel").visible = true
	return [root_node]


func _scan_sf2_files() -> Array[Dictionary]:
	# 优先从 FileSystemManager 索引读取
	var result: Array[Dictionary] = []
	var fs_mgr = FileSystemManager.instance
	if fs_mgr:
		var sf_index = fs_mgr.get_soundfonts_index()
		if not sf_index.is_empty():
			for sf_name in sf_index:
				var entry = sf_index[sf_name]
				result.append({
					"file_name": sf_name + ".sf2",
					"path": entry["path"],
					"is_builtin": entry["is_builtin"],
					"size_mb": entry["size_mb"],
					"selected": false,
				})
			return result

	# 回退：独立扫描文件系统
	var user_dir := PathHelper.get_soundfont_dir()
	if DirAccess.dir_exists_absolute(user_dir):
		var dir := DirAccess.open(user_dir)
		if dir:
			dir.list_dir_begin()
			var fn := dir.get_next()
			while fn != "":
				if fn.ends_with(".sf2") and not dir.current_is_dir():
					var f := FileAccess.open(user_dir.path_join(fn), FileAccess.READ)
					var size_mb := 0.0
					if f:
						size_mb = snapped(f.get_length() / 1048576.0, 0.1)
						f.close()
					result.append({
						"file_name": fn,
						"path": user_dir.path_join(fn),
						"is_builtin": false,
						"size_mb": size_mb,
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
					var already_in_user := false
					for item in result:
						if item["file_name"] == fn:
							already_in_user = true
							break
					if not already_in_user:
						var f := FileAccess.open(res_dir.path_join(fn), FileAccess.READ)
						var size_mb := 0.0
						if f:
							size_mb = snapped(f.get_length() / 1048576.0, 0.1)
							f.close()
						result.append({
							"file_name": fn,
							"path": res_dir.path_join(fn),
							"is_builtin": true,
							"size_mb": size_mb,
							"selected": false,
						})
				fn = dir.get_next()
			dir.list_dir_end()

	result.sort_custom(func(a, b):
		if a["is_builtin"] != b["is_builtin"]:
			return not a["is_builtin"]
		return a["file_name"] < b["file_name"]
	)
	return result


func _on_sf2_select_toggled(toggled: bool) -> void:
	for i in _sf2_items.size():
		if not _sf2_items[i]["is_builtin"]:
			_sf2_items[i]["selected"] = toggled
		if _sf2_nodes.has(i):
			var cb := _sf2_nodes[i].get_node("CheckBox") as CheckBox
			if not _sf2_items[i]["is_builtin"]:
				cb.set_pressed_no_signal(toggled)
	_select_toggle.text = "取消全选" if toggled else "全选"
	_update_flat_toggle_state(_sf2_items)


func _on_sf2_delete_selected() -> void:
	var to_delete: Array[Dictionary] = []
	for item in _sf2_items:
		if item["selected"] and not item["is_builtin"]:
			to_delete.append(item)

	if to_delete.is_empty():
		return

	_sf2_loader.cancel()

	for item in to_delete:
		if FileSystemManager.instance.delete_soundfont(item["path"]):
			pass
		else:
			push_error("[DelView] 删除失败: %s" % item["path"])

	await get_tree().process_frame
	_build_sf2_page()


# ============================================================
# 皮肤管理 — 扁平 TreeRoot
# ============================================================

func _build_skin_page() -> void:
	_tab_data_built[Tab.SKIN] = false
	_clear_page(_skin_list, [_skin_nodes])

	var skins_index := SkinMGR.get_skins_index()
	_skin_items.clear()

	for skin_name in skins_index:
		var meta: SkinMetadata = skins_index[skin_name]
		_skin_items.append({
			"name": skin_name,
			"path": meta.path,
			"is_builtin": meta.is_builtin,
			"selected": false,
		})

	_skin_items.sort_custom(func(a, b):
		if a["is_builtin"] != b["is_builtin"]:
			return not a["is_builtin"]
		return a["name"] < b["name"]
	)

	if _skin_items.is_empty():
		_update_item_sum("无皮肤")
		_update_flat_toggle_state(_skin_items)
		_tab_data_built[Tab.SKIN] = true
		return

	var completed: bool = await _skin_loader.build(_skin_items.size(), _create_skin_item)
	if not completed:
		return
	if _current_tab != Tab.SKIN:
		return
	_update_item_sum("共 %d 个皮肤" % _skin_items.size())
	_update_flat_toggle_state(_skin_items)
	await _apply_scrolls_to_container(_skin_list)
	_tab_data_built[Tab.SKIN] = true
	_update_tab_header(Tab.SKIN)
	if not _search_query.is_empty():
		_apply_search_filter()
	_update_focus_relations()


## 皮肤工厂：创建一个扁平 TreeRoot
func _create_skin_item(index: int) -> Variant:
	if _current_tab != Tab.SKIN:
		return null
	var item: Dictionary = _skin_items[index]
	var display_name: String = item["name"]
	if item["is_builtin"]:
		display_name += " [内置]"

	var root_node := _create_tree_root(display_name, "", "")
	root_node.get_node("RightLabel").visible = false  # 皮肤无格式信息
	root_node.set_meta("flat_index", index)
	_skin_list.add_child(root_node)
	_skin_nodes[index] = root_node

	var cb := root_node.get_node("CheckBox") as CheckBox
	cb.button_pressed = item["selected"]
	if item["is_builtin"]:
		cb.disabled = true
	cb.toggled.connect(func(on: bool):
		_skin_items[index]["selected"] = on
		_update_flat_toggle_state(_skin_items)
	)
	return [root_node]


func _on_skin_select_toggled(toggled: bool) -> void:
	for i in _skin_items.size():
		if not _skin_items[i]["is_builtin"]:
			_skin_items[i]["selected"] = toggled
		if _skin_nodes.has(i):
			var cb := _skin_nodes[i].get_node("CheckBox") as CheckBox
			if not _skin_items[i]["is_builtin"]:
				cb.set_pressed_no_signal(toggled)
	_select_toggle.text = "取消全选" if toggled else "全选"
	_update_flat_toggle_state(_skin_items)


func _on_skin_delete_selected() -> void:
	var to_delete: Array[Dictionary] = []
	for item in _skin_items:
		if item["selected"] and not item["is_builtin"]:
			to_delete.append(item)

	if to_delete.is_empty():
		return

	_skin_loader.cancel()

	for item in to_delete:
		if SkinMGR.remove_skin(item["name"]):
			pass
		else:
			push_error("[DelView] 皮肤已从列表移除，但文件夹删除失败，请手动清理: %s" % item["path"])

	await get_tree().process_frame
	_build_skin_page()


# ============================================================
# 背景管理 — 扁平 TreeRoot
# ============================================================

func _build_bg_page() -> void:
	_tab_data_built[Tab.BG] = false
	_clear_page(_bg_list, [_bg_nodes])

	var bg_index := FileSystemManager.instance.get_backgrounds_index()
	_bg_items.clear()

	for bg_name in bg_index:
		var path: String = bg_index[bg_name]
		var ext := path.get_extension().to_lower() if not path.is_empty() else ""
		_bg_items.append({
			"name": bg_name,
			"path": path,
			"ext": ext,
			"selected": false,
		})

	_bg_items.sort_custom(func(a, b): return a["name"] < b["name"])

	if _bg_items.is_empty():
		_update_item_sum("无背景图片")
		_update_flat_toggle_state(_bg_items)
		_tab_data_built[Tab.BG] = true
		return

	var completed: bool = await _bg_loader.build(_bg_items.size(), _create_bg_item)
	if not completed:
		return
	if _current_tab != Tab.BG:
		return
	_update_item_sum("共 %d 张背景" % _bg_items.size())
	_update_flat_toggle_state(_bg_items)
	await _apply_scrolls_to_container(_bg_list)
	_tab_data_built[Tab.BG] = true
	_update_tab_header(Tab.BG)
	if not _search_query.is_empty():
		_apply_search_filter()
	_update_focus_relations()


## 背景工厂：创建一个扁平 TreeRoot
func _create_bg_item(index: int) -> Variant:
	if _current_tab != Tab.BG:
		return null
	var item: Dictionary = _bg_items[index]
	var ext: String = item.get("ext", "")
	var root_node := _create_tree_root(item["name"], ext, "")
	root_node.set_meta("flat_index", index)
	_bg_list.add_child(root_node)
	_bg_nodes[index] = root_node

	var cb := root_node.get_node("CheckBox") as CheckBox
	cb.button_pressed = item["selected"]
	cb.toggled.connect(func(on: bool):
		_bg_items[index]["selected"] = on
		_update_flat_toggle_state(_bg_items)
	)
	return [root_node]


func _on_bg_select_toggled(toggled: bool) -> void:
	for i in _bg_items.size():
		_bg_items[i]["selected"] = toggled
		if _bg_nodes.has(i):
			var cb := _bg_nodes[i].get_node("CheckBox") as CheckBox
			cb.set_pressed_no_signal(toggled)
	_select_toggle.text = "取消全选" if toggled else "全选"
	_update_flat_toggle_state(_bg_items)


func _on_bg_delete_selected() -> void:
	var to_delete: Array[Dictionary] = []
	for item in _bg_items:
		if item["selected"]:
			to_delete.append(item)

	if to_delete.is_empty():
		return

	_bg_loader.cancel()

	for item in to_delete:
		if FileSystemManager.instance.delete_background(item["path"]):
			# 同步清除 ThemeManager 的背景图片缓存，避免缓存指向已删除文件
			ThemeMGR.invalidate_background_cache(item["name"])
		else:
			push_error("[DelView] 删除失败: %s" % item["path"])

	await get_tree().process_frame
	_build_bg_page()


# ============================================================
# 折叠 / 展开
# ============================================================

func _on_collapse_toggled(toggled: bool) -> void:
	_collapse_toggle.text = "展开全部" if toggled else "收起全部"
	match _current_tab:
		Tab.MIDI:
			for album_id in _midi_root_map:
				var root_node: HBoxContainer = _midi_root_map[album_id]
				root_node.set_meta("collapsed", toggled)
			if not toggled:
				# 展开全部：加载所有未加载的专辑子项（fire-and-forget）
				_load_all_midi_children()
			_apply_collapse_visibility(_midi_list)
			# 就地搜索激活时：折叠/展开后按命中集重刷可见性（含根 + 子项）
			if not _search_query.is_empty():
				_apply_midi_search_filter()
		Tab.AUDIO:
			for song_name in _audio_root_map:
				var root_node: HBoxContainer = _audio_root_map[song_name]
				root_node.set_meta("collapsed", toggled)
			_apply_collapse_visibility(_audio_list)


func _on_root_label_gui_input(event: InputEvent, root_node: HBoxContainer) -> void:
	if not event is InputEventMouseButton:
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	# 排除 CheckBox 区域的点击
	var cb := root_node.get_node("CheckBox") as CheckBox
	if cb.get_global_rect().has_point(event.global_position):
		return
	if event.pressed:
		# 记录按下位置，用于判断是否为点击（非拖动）
		root_node.set_meta("_press_pos", event.global_position)
	else:
		# 松手时判断：位置偏移小 → 点击，偏移大 → 拖动，不触发
		var press_pos: Vector2 = root_node.get_meta("_press_pos", Vector2.INF)
		root_node.remove_meta("_press_pos")
		if press_pos == Vector2.INF:
			return
		if event.global_position.distance_to(press_pos) < 10.0:
			_toggle_root_collapse(root_node)


func _toggle_root_collapse(root_node: HBoxContainer) -> void:
	var collapsed: bool = root_node.get_meta("collapsed", false)
	var new_state := not collapsed
	root_node.set_meta("collapsed", new_state)

	var list_container := root_node.get_parent() as VBoxContainer
	if list_container:
		var children := list_container.get_children()
		var found_self := false
		for child in children:
			if child == root_node:
				found_self = true
				continue
			if not found_self:
				continue
			# 遇到下一个 TreeRoot（有 collapsed meta）时停止
			if child.has_meta("collapsed"):
				break
			child.visible = not new_state  # collapsed=true → visible=false

	# 展开且子项未加载 → 开始懒加载（新增子项由工厂按 collapsed 态设置可见性）
	if not new_state:
		var album_id := String(root_node.get_meta("group_id", ""))
		if not album_id.is_empty() and not _midi_album_loaded.get(album_id, false):
			_start_load_album_children(album_id)

	# 就地搜索激活时（MIDI 层）：折叠/展开后按命中集重刷可见性（含根 + 子项）
	if not _search_query.is_empty() and _midi_root_map.has(String(root_node.get_meta("group_id", ""))):
		_apply_midi_search_filter()


func _apply_collapse_visibility(list_container: VBoxContainer) -> void:
	var children := list_container.get_children()
	var current_root: HBoxContainer = null
	for child in children:
		if child.has_meta("collapsed"):
			current_root = child as HBoxContainer
			continue
		if current_root:
			var collapsed: bool = current_root.get_meta("collapsed", false)
			child.visible = not collapsed


# ============================================================
# 搜索 / 排序
# ============================================================

func _on_search_text_changed(new_text: String) -> void:
	_search_query = new_text.strip_edges()
	_apply_search_filter()


func _apply_search_filter() -> void:
	# MIDI 页走独立的就地搜索（双层级可见性过滤，不重建列表）
	if _current_tab == Tab.MIDI:
		_apply_midi_search_filter()
		return
	# 其他 tab：构建进行中时忽略（这些 tab 的搜索只切换可见性，build 完成后会补一次）
	var cur_loader := _get_loader(_current_tab)
	if cur_loader and cur_loader.is_building():
		return
	# 空搜索：恢复全部可见
	if _search_query.is_empty():
		match _current_tab:
			Tab.AUDIO:
				_reset_grouped_visibility(_audio_list, _audio_root_map, _audio_item_map)
				_update_item_sum("共 %d 个音频文件" % _audio_items.size())
			Tab.SF2:
				_reset_flat_visibility(_sf2_nodes)
				_update_item_sum("共 %d 个音源" % _sf2_items.size())
			Tab.SKIN:
				_reset_flat_visibility(_skin_nodes)
				_update_item_sum("共 %d 个皮肤" % _skin_items.size())
			Tab.BG:
				_reset_flat_visibility(_bg_nodes)
				_update_item_sum("共 %d 张背景" % _bg_items.size())
		return

	match _current_tab:
		Tab.AUDIO:
			_apply_grouped_search(_audio_root_map, _audio_item_map,
				_audio_group_order, _audio_items_in_group, _audio_items,
				"file_name", "个音频文件")
		Tab.SF2:
			_apply_flat_search(_sf2_nodes, _sf2_items, "file_name", "个音源")
		Tab.SKIN:
			_apply_flat_search(_skin_nodes, _skin_items, "name", "个皮肤")
		Tab.BG:
			_apply_flat_search(_bg_nodes, _bg_items, "name", "张背景")


## MIDI 就地搜索（双层级，与 AlbumView 一致的原地过滤语义）：
## - 非空 query → 仅切可见性：专辑名命中或含命中谱面的专辑根显示，
##   命中谱面的 TreeItem 显示（折叠态不展开）；不重建列表、不水合数据
## - 空 query → 清空命中集，恢复全部可见（保留折叠态）
## 命中集缓存于 _midi_search_matched_keys，懒加载子项在工厂里按它匹配
func _apply_midi_search_filter() -> void:
	if _search_query.is_empty():
		_midi_search_matched_keys.clear()
		_reset_midi_visibility()
		_update_item_sum("共 %d 首谱面" % _midi_selected.size())
		return
	# 专辑层未构建（构建中/空页）：交给 build 完成后补过滤，不覆写"加载中"文案
	if _midi_root_map.is_empty():
		return
	# DB 驱动命中集（零水合）：专辑级 + 谱面级（folder_name），与 AlbumView 同源 FilterSearch
	var matched_albums := {}
	for aid in ChartDB.GetMatchingAlbumIds(_search_query):
		matched_albums[aid] = true
	_midi_search_matched_keys.clear()
	for key in ChartDB.SearchMidiKeys(_search_query):
		_midi_search_matched_keys[key] = true

	var visible_count := 0
	for album_id in _midi_root_map:
		var root: HBoxContainer = _midi_root_map[album_id]
		var album_match := matched_albums.has(album_id)
		root.visible = album_match
		var collapsed := bool(root.get_meta("collapsed", false))
		var slots: Array = _midi_album_midi_map.get(album_id, [])
		for midi_key in slots:
			if _midi_search_matched_keys.has(midi_key):
				visible_count += 1
			if _midi_item_map.has(midi_key):
				_midi_item_map[midi_key].visible = _midi_search_matched_keys.has(midi_key) and not collapsed
	_update_item_sum("匹配 %d 首谱面" % visible_count)


func _get_album_name(album_id: String) -> String:
	var dm := DataMGR
	if dm.albums.has(album_id):
		return dm.albums[album_id].name
	return album_id


func _apply_grouped_search(root_map: Dictionary, item_map: Dictionary,
		group_order: Array, items_in_group: Dictionary, data: Array,
		 item_key: String, unit: String) -> void:
	var query_lower := _search_query.to_lower()
	var visible_count := 0

	for group_name in group_order:
		var group_match := query_lower in str(group_name).to_lower()
		var has_visible := false
		var root_node: HBoxContainer = root_map.get(group_name)

		for idx in items_in_group[group_name]:
			var text: String = data[idx].get(item_key, "")
			var matches := group_match or (query_lower in text.to_lower())
			if item_map.has(idx):
				var collapsed: bool = root_node.get_meta("collapsed", false) if root_node else false
				item_map[idx].visible = matches and not collapsed
			if matches:
				has_visible = true
				visible_count += 1

		if root_node:
			root_node.visible = has_visible

	_update_item_sum("共 %d %s (匹配 %d 个)" % [data.size(), unit, visible_count])


func _apply_flat_search(nodes: Dictionary, items: Array, key: String, unit: String) -> void:
	var query_lower := _search_query.to_lower()
	var visible_count := 0
	for i in items.size():
		var text: String = items[i].get(key, "")
		var matches := query_lower in text.to_lower()
		if nodes.has(i):
			nodes[i].visible = matches
		if matches:
			visible_count += 1
	_update_item_sum("共 %d %s (匹配 %d 个)" % [items.size(), unit, visible_count])


func _reset_midi_visibility() -> void:
	for album_id in _midi_root_map:
		_midi_root_map[album_id].visible = true
	for midi_id in _midi_item_map:
		_midi_item_map[midi_id].visible = true
	_apply_collapse_visibility(_midi_list)


func _reset_grouped_visibility(list: VBoxContainer, root_map: Dictionary, item_map: Dictionary) -> void:
	for key in root_map:
		root_map[key].visible = true
	for key in item_map:
		item_map[key].visible = true
	_apply_collapse_visibility(list)


func _reset_flat_visibility(nodes: Dictionary) -> void:
	for idx in nodes:
		nodes[idx].visible = true


# ============================================================
# 通用工具
# ============================================================

func _update_item_sum(text: String) -> void:
	_item_sum.text = text


func _create_tree_root(left_text: String, right_text: String, group_id: String) -> HBoxContainer:
	var node := TREE_ROOT_SCENE.instantiate() as HBoxContainer
	var left_label := node.get_node("LeftLabel") as Label
	var right_label := node.get_node("RightLabel") as Label
	left_label.set_scroll_text(left_text)
	right_label.set_scroll_text(right_text)
	node.set_meta("group_id", group_id)
	node.set_meta("collapsed", false)
	# 点击 TreeRoot 的非 CheckBox 区域 → 折叠/展开
	node.gui_input.connect(_on_root_label_gui_input.bind(node))
	return node


func _create_tree_item(left_text: String, right_text: String) -> HBoxContainer:
	var node := TREE_ITEM_SCENE.instantiate() as HBoxContainer
	var left_label := node.get_node("LeftLabel") as Label
	var right_label := node.get_node("RightLabel") as Label
	left_label.set_scroll_text(left_text)
	right_label.set_scroll_text(right_text)
	return node

func _apply_scrolls_to_container(container: VBoxContainer) -> void:
	if container.get_child_count() == 0:
		return
	await get_tree().process_frame
	# await 期间场景可能被切换并释放 container / children，需重新校验
	if not is_instance_valid(container):
		return
	var processed := 0
	for child in container.get_children():
		if not is_instance_valid(child):
			continue
		processed += 1
		if processed % 30 == 0:
			await get_tree().process_frame
			if not is_instance_valid(container):
				return


func _set_indeterminate(cb: CheckBox, indeterminate: bool) -> void:
	if indeterminate:
		cb.self_modulate = Color(0.5, 0.5, 0.5, 1.0)
		cb.tooltip_text = "部分选中"
	else:
		cb.self_modulate = Color.WHITE
		cb.tooltip_text = ""


func _clear_page(container: VBoxContainer, collections: Array) -> void:
	for child in container.get_children():
		child.queue_free()
	for col in collections:
		if col is Dictionary:
			col.clear()
		elif col is Array:
			col.clear()


func _update_flat_toggle_state(items: Array) -> void:
	if items.is_empty():
		_select_toggle.set_pressed_no_signal(false)
		_select_toggle.text = "全选"
		_select_toggle.disabled = true
		_delete_btn.disabled = true
		return

	var all_checked := true
	var any_checked := false

	for item in items:
		if item["selected"]:
			any_checked = true
		else:
			all_checked = false

	_select_toggle.disabled = false
	_select_toggle.set_pressed_no_signal(all_checked)
	_select_toggle.text = "取消全选" if all_checked else "全选"
	_delete_btn.disabled = not any_checked

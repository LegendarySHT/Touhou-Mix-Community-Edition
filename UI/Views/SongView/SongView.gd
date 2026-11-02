## 歌曲视图
## 显示选中专辑下的所有歌曲列表
extends BaseScrollList

class_name SongView

## 当前显示的歌曲列表
var current_songs: Array = []
## 当前已选中的专辑 ID
var current_album_id: String = ""

## 标记 _load_songs 刚被调用（album_selected 触发，先于 state_changed）
## 用于跳过 state_changed lambda 中的冗余 _refresh_from_data 重建
## （_load_songs 已创建列表项，lambda 再重建会导致封面加载被中断重发）
var _load_songs_just_called: bool = false

## 从 MidiView 返回时待回选的歌曲 id（列表刷新完成后自动选中并滚动定位）
var _pending_restore_song_id: String = ""

## 当前就地搜索词（非空时歌曲列表过滤）
var _search_query: String = ""

## 管理器引用
@onready var data_manager: DataManager = DataMGR
@onready var event_bus: EventBus = EvtBus
@onready var state_manager = UiStatMGR

func _ready() -> void:
	# 获取管理器引用
	if not data_manager or not event_bus:
		push_error("SongView: Missing manager instances")
		return

	work_state = UIStateManager.UIState.SONG_VIEW
	# 设置直接相邻状态：切到不在此集合的状态时释放所有列表项封面
	# SONG_VIEW 相邻：ALBUM_VIEW（返回）、MIDI_VIEW（点进歌曲）
	set_adjacent_states([
		UIStateManager.UIState.ALBUM_VIEW,
		UIStateManager.UIState.MIDI_VIEW,
	])
	# 连接事件
	event_bus.album_selected.connect(_load_songs)
	event_bus.midi_deleted.connect(func(_id): if not current_album_id.is_empty(): _load_songs(current_album_id))
	event_bus.midis_deleted.connect(func(_ids): if not current_album_id.is_empty(): _load_songs(current_album_id))
	# 启动后全量/增量扫描完成，若发现谱面的 album_id / song_id 归属发生变更（结构变化），
	# 仅在此统一信号到来时刷新；避免中间每步变化都刷新导致卡顿
	event_bus.charts_structure_changed.connect(func():
		if not current_album_id.is_empty():
			_load_songs(current_album_id)
	)
	# 回到 SongView 时自动刷新，确保删除等操作后数据最新
	# 但 _load_songs 已处理首次进入和 album_selected 触发的场景，
	# 需跳过冗余重建避免封面加载被中断
	state_manager.state_changed.connect(func(old, new):
		if new == UIStateManager.UIState.SONG_VIEW and not current_album_id.is_empty():
			if _load_songs_just_called:
				_load_songs_just_called = false
				return  # _load_songs 已创建列表项,跳过冗余重建
			# 从 MidiView 返回：记录上次选中的歌曲，待列表刷新后自动选中并滚动定位
			if old == UIStateManager.UIState.MIDI_VIEW:
				_pending_restore_song_id = NavigationState.get_song_id()
				# 清除持久化的 song/midi 选中（仅保留 album），避免下次启动误恢复到 MidiView
				NavigationState.save(current_album_id, "", "")
			# 进入歌曲视图：应用当前共享搜索词（跨视图就地筛选持久化，仅 SORTED_VIEW 清空）
			_search_query = EvtBus.current_search_query
			call_deferred("_refresh_from_data")
	)
	# 就地搜索：当前为歌曲视图时过滤当前列表
	event_bus.search_query_changed.connect(_on_search_query_changed)

	super._ready()

	# 注册主题色应用器，由 ThemeManager 在主题切换时广播调用
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()

## 应用主题色（由 ThemeManager 广播调用 + _ready 首次自调）
func apply_theme() -> void:
	_apply_item_accent()

## 把主题强调色写入列表项暴露的计数标签颜色属性
## 计数标签的内联 StyleBox 由同类列表项共享，改首项即同步全部列表项
func _apply_item_accent() -> void:
	if list_items.is_empty():
		return
	var song_item := list_items[0] as SongListItem
	if is_instance_valid(song_item):
		song_item.midi_count_accent = ThemeMGR.get_color("primary_light")

func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)

## 加载指定专辑的歌曲
func _load_songs(album_id: String) -> void:
	if not data_manager:
		return
	_search_query = EvtBus.current_search_query
	_load_songs_just_called = true  # 标记,供 state_changed lambda 跳过冗余重建
	current_album_id = album_id
	current_songs = data_manager.get_songs_by_album(album_id)
	# 就地搜索：命中歌曲 id 集合与当前列表取交集，保留原顺序
	if not _search_query.is_empty():
		_apply_song_search_filter()
	_refresh_display()

	_connect_head_and_tail_next_frame()
	_update_ss_count()

	# 加长
	container.custom_minimum_size.y = (140 + 29) * (current_songs.size() + 1)

	# 安全网：若歌曲列表为空且 Album 也被删除（级联），延迟退回 AlbumView
	# 若 Song 被删除但 Album 仍存在，则显示该 Album 的空列表（不退回）
	if current_songs.is_empty() and state_manager.current_state == UIStateManager.UIState.SONG_VIEW:
		if ChartDB.GetAlbum(current_album_id).is_empty():
			# Album 也被删除，安全退回
			call_deferred("_deferred_go_back")

## 就地搜索词变化：当前为歌曲视图时才过滤当前列表
func _on_search_query_changed(query: String) -> void:
	if state_manager.current_state != UIStateManager.UIState.SONG_VIEW:
		return
	_search_query = query
	_refresh_from_data()

## 按 _search_query 过滤歌曲（任一谱面全文命中含简介即算命中，复用 ChartDB 检索）
func _apply_song_search_filter() -> void:
	var ids := {}
	for id in ChartDB.GetMatchingSongIds(_search_query):
		ids[id] = true
	current_songs = current_songs.filter(func(s): return ids.has(String(s.get("id", ""))))

## 刷新显示
func _refresh_display() -> void:
	# 清空现有项
	clear_items()
	
	var is_active := UiStatMGR.current_state == UIStateManager.UIState.SONG_VIEW
	if current_songs.is_empty():
		if %NoItems and is_active:
			%NoItems.visible = true
		return
	
	# 列表非空，隐藏空提示
	%NoItems.visible = false
	
	var counter:int = 0
	var bg = ButtonGroup.new()
	# 添加新项
	for song in current_songs:
		var item = create_and_add_item(String(song.get("id", "")), "song")
		if item:
			item.setup_with_dict(self, song, counter, bg)
			if counter == 0:
				_apply_item_accent()
			counter += 1
	# 列表构建完成，触发未加载项的封面加载
	trigger_cover_chain()

func _gui_input(event: InputEvent) -> void:
	super._gui_input(event)

func _deferred_go_back() -> void:
	if current_songs.is_empty() and state_manager.current_state == UIStateManager.UIState.SONG_VIEW:
		state_manager.go_back()

## 从 DataManager 重新拉取并刷新列表（call_deferred 调用，确保在状态转换完成后执行）
func _refresh_from_data() -> void:
	if current_album_id.is_empty():
		return
	current_songs = data_manager.get_songs_by_album(current_album_id)
	# 就地搜索：命中歌曲 id 集合与当前列表取交集，保留原顺序
	if not _search_query.is_empty():
		_apply_song_search_filter()
	_refresh_display()
	_connect_head_and_tail_next_frame()
	_update_ss_count()
	# 先把容器高度按歌曲数撑开，确保 _restore_selected_song 等布局稳定时项位置已就绪
	container.custom_minimum_size.y = (140 + 29) * (current_songs.size() + 1)
	# 从 MidiView 返回：自动选中上次选中的歌曲并滚动定位
	if not _pending_restore_song_id.is_empty():
		var sid := _pending_restore_song_id
		_pending_restore_song_id = ""
		_restore_selected_song(sid)
	if current_songs.is_empty():
		if ChartDB.GetAlbum(current_album_id).is_empty():
			_deferred_go_back()

## 首尾焦点连接延迟到下一帧执行
## clear_items 用 queue_free 移除旧项，旧项要到帧末才真正脱离容器；若同步调用
## _connect_head_and_tail，container.get_child(0) 会取到待释放的旧首项，使新末项的
## focus_neighbor_bottom 指向已释放节点（焦点移到末项按下报 invalid path 错误）。
## 等待一帧后旧项已移除，头尾才指向真实的新首/末项（与 AlbumView 的两阶段构建一致）。
func _connect_head_and_tail_next_frame() -> void:
	if not is_inside_tree() or container == null:
		return
	await get_tree().process_frame
	if not is_inside_tree() or container == null:
		return
	_connect_head_and_tail()

## 同步更新 SelectedAlbum 头部卡片（SongView 过渡时展示的选中专辑）的歌曲计数
func _update_ss_count() -> void:
	var album: Dictionary = ChartDB.GetAlbum(current_album_id)
	if album.is_empty():
		return
	var ss_node = get_node_or_null(PathRegistry.SELECTED_ALBUM)
	if not is_instance_valid(ss_node):
		return
	var count_label = ss_node.get_node_or_null("%SongCount")
	if is_instance_valid(count_label):
		count_label.text = "%d" % album.get("song_ids", []).size()


func on_item_button_confirmed(index: int):
	if index < 0 or index >= current_songs.size():
		return
	var song: Dictionary = current_songs[index]
	GLogger.info("Select Song: %s" % song.get("name", ""), "SongView")
	# 记录导航位置：进入 MidiView 时记录歌曲（保留 album；midi 由 MidiList 选中变化记录）
	NavigationState.save(current_album_id, String(song.get("id", "")), "")
	# 切换到MIDI视图
	state_manager.change_state(state_manager.UIState.MIDI_VIEW)
	event_bus.emit_song_selected(String(song.get("id", "")))

## 从 MidiView 返回时自动选中上次选中的歌曲
## 找到索引后先选中，等 Song_List 入场动画播完（布局已稳定）再平滑滚动到视口中部
func _restore_selected_song(song_id: String) -> void:
	if list_items.is_empty() or song_id.is_empty():
		return
	var idx := -1
	for i in list_items.size():
		var it: Control = list_items[i]
		if is_instance_valid(it) and String(it.item_id) == song_id:
			idx = i
			break
	if idx < 0:
		GLogger.info("RestoreSong: id=%s not in list" % song_id, "SongView")
		return
	# 等 Song_List 入场动画播完（此时列表布局已稳定），避免过早定位把目标算成 0
	await AniMGR.scene_transition_fin
	await get_tree().process_frame
	select_item(idx)
	if not is_inside_tree() or idx >= list_items.size():
		return
	_center_snap_to(idx)

## 平滑滚动到指定项，使其顶部对齐到本视图视口的中部高度
## 项的局部 position.y 即内容坐标（与当前滚动位置无关），目标滚动值 = 内容坐标 - 视口一半
func _center_snap_to(index: int) -> void:
	var item: Control = container.get_child(index)
	if item == null:
		return
	var center := maxf((size.y - item.size.y) / 2.0, 0.0)
	var maxv := int(get_v_scroll_bar().max_value)
	var target_scroll := clampi(int(item.position.y - center), 0, maxv)
	GLogger.info("RestoreSong: target=%d max=%d" % [target_scroll, maxv], "SongView")
	# 平滑吸附动画：直接补间 scroll_vertical 到位
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "scroll_vertical", float(target_scroll), 0.3)

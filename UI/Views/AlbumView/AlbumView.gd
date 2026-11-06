## 专辑视图
## 显示所有专辑列表，支持排序和搜索
extends BaseScrollList

class_name AlbumView

## 当前显示的专辑列表
var current_albums: Array = []

## 上次点进 SongView 的专辑 id（退回 AlbumView 时用于吸附回该专辑）
var _last_opened_album_id: String = ""

## 本次进入 AlbumView 前的旧状态（state_changed 的 old 记录）
## 用于区分"从专辑子视图（Song/Midi/Track）退回"与"从设置等平行视图退回"：
## 前者 _last_opened_album_id 权威，后者应保持当前位置、忽略陈旧专辑
var _prev_state_on_return: UIStateManager.UIState = UIStateManager.UIState.NONE

## 排序引擎引用
@onready var data_manager: DataManager = DataMGR
@onready var event_bus: EventBus = EvtBus

## 加载 generation（单调递增，使在途加载循环自动失效；替代 LazyListLoader 取消机制）
var _load_generation: int = 0
var _album_build_bg: ButtonGroup

## 当前就地搜索词（非空时 _load_albums 过滤专辑）
var _search_query: String = ""

## 预热目标：直达导航（商店跳转 / 启动恢复 / 外部导入）不经过本页的选中流程，
## 由 album_selected 记下目标专辑，进 SongView 时统一把选中项/滚动/封面摆好
var _warmup_album_id: String = ""

func _ready() -> void:
	if not data_manager or not event_bus:
		push_error("AlbumView: Missing manager instances")
		return

	work_state = UIStateManager.UIState.ALBUM_VIEW
	snap_offset_y = 100
	# 设置直接相邻状态：切到不在此集合的状态时释放所有列表项封面
	# ALBUM_VIEW 相邻：SONG_VIEW（点进专辑）、SORTED_VIEW/STORE_VIEW/SETTINGS_VIEW（侧栏切换）
	set_adjacent_states([
		UIStateManager.UIState.SONG_VIEW,
		UIStateManager.UIState.SORTED_VIEW,
		UIStateManager.UIState.STORE_VIEW,
		UIStateManager.UIState.SETTINGS_VIEW,
	])

	# 连接事件
	data_manager.data_loaded.connect(_load_albums)
	event_bus.midi_deleted.connect(func(_id): _load_albums())
	event_bus.midis_deleted.connect(func(_ids): _load_albums())
	# 启动后全量/增量扫描完成，若谱面 album_id / song_id 归属有变化，仅在此统一刷新
	# 覆盖"结构变化但 charts_cache_validated/data_loaded 未触发 AlbumView 重建"的边角场景
	event_bus.charts_structure_changed.connect(_load_albums)
	event_bus.config_changed.connect(_on_config_changed)
	event_bus.album_selected.connect(func(album_id):
		_last_opened_album_id = String(album_id)
		# 直达路径会在本页背面把上下文切走，目标专辑先记下来，等进 SongView 再预热
		_warmup_album_id = String(album_id)
	)
	# 回到 AlbumView 时补检空列表（midi_deleted 在不活跃时触发刷新，不会显示 NoItems）
	UiStatMGR.state_changed.connect(func(old, new):
		if new == UIStateManager.UIState.ALBUM_VIEW:
			# 记录返回前状态：区分"从专辑子视图退回"与"从平行视图退回"
			_prev_state_on_return = old
			# 进入专辑视图：应用当前共享搜索词（跨视图就地筛选持久化，仅 SORTED_VIEW 清空）
			_search_query = EvtBus.current_search_query
			# 从子视图退回时保留当前选中专辑：重建会把它清成 -1，
			# 于是选中项先收起、过渡结束后再展开，看起来像跳了一下
			var keep: bool = old in [UIStateManager.UIState.SONG_VIEW,
				UIStateManager.UIState.MIDI_VIEW, UIStateManager.UIState.TRACK_VIEW]
			call_deferred("_load_albums", keep)
		elif new == UIStateManager.UIState.SONG_VIEW and old != UIStateManager.UIState.ALBUM_VIEW:
			# 从 MidiView 退回 SongView：下一步多半是退回本页，趁视图不可见先把位置和封面备好
			_apply_warmup()
	)
	# 就地搜索：当前为专辑视图时过滤当前列表
	event_bus.search_query_changed.connect(_on_search_query_changed)
	# AlbumView 入场动画播完后恢复选中：此时视图已完全可见、列表已就绪，
	# 避免在出场动画期间（视图隐藏、布局未就绪）尝试吸附而落空
	AniMGR.scene_transition_fin.connect(func():
		if UiStatMGR.current_state == UIStateManager.UIState.ALBUM_VIEW:
			_restore_selection_on_return()
	)
	modulate.a = 0.0

	super._ready()

	# 注册主题色应用器，由 ThemeManager 在主题切换时广播调用
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()

## 应用主题色（由 ThemeManager 广播调用 + _ready 首次自调）
func apply_theme() -> void:
	_apply_item_accent()

## 把主题强调色写入列表项暴露的计数标签颜色属性
## 计数标签的内联 StyleBox 由同类列表项共享，改首项即同步全部列表项与 SelectedAlbum 头部卡片
func _apply_item_accent() -> void:
	if list_items.is_empty():
		return
	var album_item := list_items[0] as AlbumListItem
	if is_instance_valid(album_item):
		album_item.song_count_accent = ThemeMGR.get_color("primary_light")

func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)

## 加载专辑数据（异步，避免阻塞主线程）
## keep_selection：按 id 保留当前选中专辑（从子视图退回时用，避免选中项收起再展开的跳动）
func _load_albums(keep_selection: bool = false) -> void:
	if not data_manager:
		return

	_search_query = EvtBus.current_search_query
	# 递增 generation，使之前在途的加载循环自动失效（旧循环检测到不匹配后 return）
	_load_generation += 1
	var keep_album_id := ""
	if keep_selection and selected_item >= 0 and selected_item < list_items.size():
		keep_album_id = list_items[selected_item].item_id
	current_albums = data_manager.get_sorted_albums()
	# 就地搜索：命中专辑 id 集合与当前列表取交集，保留原排序
	if not _search_query.is_empty():
		_apply_album_search_filter()

	await _refresh_display_async(_load_generation, keep_album_id)

## 就地搜索词变化：当前为专辑视图时才过滤当前列表
func _on_search_query_changed(query: String) -> void:
	if UiStatMGR.current_state != UIStateManager.UIState.ALBUM_VIEW:
		return
	_search_query = query
	_load_albums()

## 按 _search_query 过滤专辑（任一谱面全文命中含简介即算命中，复用 ChartDB 检索）
func _apply_album_search_filter() -> void:
	var ids := {}
	for id in ChartDB.GetMatchingAlbumIds(_search_query):
		ids[id] = true
	current_albums = current_albums.filter(func(a): return ids.has(String(a.get("id", ""))))

## 会影响专辑列表内容/顺序的配置键（显式白名单：原来的粒度是「[General] 里任何一个键」，
## 但 section 不再是代码可依赖的东西，所以把真正相关的键列出来）
const ALBUM_AFFECTING_KEYS: Array[String] = [
	"album_sort_method", "album_sort_direction", "custom_storage_path",
]

## 配置变更时重新排序（deferred，避免阻塞 save 流程）
func _on_config_changed(key: String, _value: Variant) -> void:
	if key in ALBUM_AFFECTING_KEYS:
		call_deferred("_load_albums")


## 异步刷新显示：两阶段构建
## Phase A（同步、无 await）：裁剪多余项 + 一帧内建满全部节点，仅绑定身份（bind_with_dict）
##   —— 项高固定（tscn custom_minimum_size），滚动条长度只由 add_child 时机决定，一帧完成即立即稳定
## Phase B（异步）：每帧分批填充显示（fill_display：标签/封面/名称滚动），ChartDB 封面查询摊到帧间
## generation 守卫与复用逻辑保持不变（避免 clear_items 全清重建造成的闪烁 + 封面重载）
## keep_album_id：Phase A 之后按 id 重新选中该专辑（Phase B 填充时 keep_expanded 会保住它的展开态）
func _refresh_display_async(my_generation: int, keep_album_id: String = "") -> void:
	var is_active := UiStatMGR.current_state == UIStateManager.UIState.ALBUM_VIEW
	
	if current_albums.is_empty():
		clear_items()
		if %NoItems and is_active:
			%NoItems.visible = true
		return

	# 列表非空，隐藏空提示
	%NoItems.visible = false

	var had_items: bool = not list_items.is_empty()

	# ===== Phase A：建足节点（滚动条立即稳定） =====
	# 同步项数：多余的从尾部清理（释放封面使在途回调失效）
	var target_count: int = current_albums.size()
	var existing_count: int = list_items.size()
	if existing_count > target_count:
		for i in range(existing_count - 1, target_count - 1, -1):
			var extra_item: ListItemBase = list_items[i]
			if is_instance_valid(extra_item):
				if extra_item is CoverListItemBase:
					(extra_item as CoverListItemBase).release_cover()
				extra_item.queue_free()
			list_items.remove_at(i)
		# 裁剪后等待一帧：让 queue_free 的节点从容器移除，再继续建新项/连头尾
		await get_tree().process_frame
		# await 后校验:若期间被新调用取代,静默退出
		if my_generation != _load_generation:
			return

	# 重置选中与吸附状态（复用项内容已变，原选中索引不再有效）
	selected_item = -1
	need_snap = false
	_snap_active = false

	_album_build_bg = ButtonGroup.new()
	existing_count = list_items.size()

	# 新建节点分帧
	const BUILD_BATCH_SIZE := 24
	var counter := 0
	var built := 0
	for album in current_albums:
		var item
		if counter < existing_count:
			# 复用现有项：仅绑定新身份（显示在 Phase B 填充）
			item = list_items[counter]
		else:
			# 新建项；空列表重建的首项触发停止 Loading + fade-in
			item = create_and_add_item(String(album.get("id", "")), "album")
			if not had_items and counter == 0:
				_on_album_first_step()
			built += 1
			if built % BUILD_BATCH_SIZE == 0:
				await get_tree().process_frame
				if my_generation != _load_generation:
					return
		item.bind_with_dict(self, album, counter, _album_build_bg)
		if counter == 0:
			_apply_item_accent()
		counter += 1

	# 保留原有选中（返回本页时）：必须在 Phase B 之前选中，
	# 否则 fill_display 会先把该项按折叠态复位，画面上一收一张
	if not keep_album_id.is_empty():
		var keep_idx := _album_index(keep_album_id)
		if keep_idx >= 0:
			select_item(keep_idx)

	# ===== Phase B：异步分批填充显示 =====
	const FILL_BATCH_SIZE := 6
	var filled := 0
	for item in list_items:
		# generation 校验:若期间被新调用取代,静默退出（新调用会自行构建列表）
		if my_generation != _load_generation:
			return
		if is_instance_valid(item):
			(item as AlbumListItem).fill_display()
			filled += 1
			if filled % FILL_BATCH_SIZE == 0:
				await get_tree().process_frame
				# await 后校验:若期间被新调用取代,静默退出
				if my_generation != _load_generation:
					return

	# 最终校验:仅当本次 generation 仍最新时触发未加载项封面加载
	if my_generation == _load_generation:
		trigger_cover_chain()


## 首个专辑项出现时：停止 Loading + fade-in
func _on_album_first_step() -> void:
	AniMGR.create_managed_tween(self).tween_property(self, "modulate:a", 1.0, 0.3)

func _process(delta):
	super._process(delta)

	if selected_item == -1 and not is_scrolling():
		need_snap = true

func _gui_input(event: InputEvent) -> void:
	super._gui_input(event)

func reset_selection():
	if selected_item == -1:
		return
	get_selected_node().button.button_pressed = false

	selected_item= -1

## 从浅层视图退回 AlbumView 时恢复选中
## 关键：进入视图时 _process 逐帧自动吸附会抢先 select_item（布局未稳时可能误踩最后一项），
## 因此这里必须区分返回来源再决定优先级：
##  - 从专辑子视图（Song/Midi/Track）返回：真正的恢复目标是刚打开的专辑，_last_opened_album_id 权威，
##    此刻 selected_item 已被自动吸附抢先置值，不能再信它（否则会吸附到错误的可见项/最后一项）。
##  - 从设置等平行视图返回：应保持当前可见位置，自动吸附已正确地停在当前位置，
##    _last_opened_album_id 是陈旧的旧专辑，必须忽略（否则会跳去旧专辑）。
func _restore_selection_on_return() -> void:
	# 等待列表构建完成（最多若干帧），避免列表尚未加载完就尝试吸附而落空
	var wait := 0
	while list_items.is_empty() and wait < 10:
		await get_tree().process_frame
		wait += 1
	if list_items.is_empty():
		return
	var ui := UIStateManager.UIState
	var from_drill := _prev_state_on_return in [ui.SONG_VIEW, ui.MIDI_VIEW, ui.TRACK_VIEW]
	if from_drill:
		# 定位回 SongView/MidiView 选择的专辑（真正的恢复目标），覆盖被抢占的错误选中项
		if not _last_opened_album_id.is_empty():
			for i in current_albums.size():
				if String(current_albums[i].get("id", "")) == _last_opened_album_id:
					_restore_scroll_to_index(i)
					return
		# 目标专辑可能已被删：回落已有选中项，再兜底第一项
		if selected_item != -1 and selected_item < list_items.size():
			_restore_scroll_to_index(selected_item)
			return
		_restore_scroll_to_index(0)
		return
	# 平行视图返回：尊重当前选中/当前位置，不跳去陈旧专辑
	if selected_item != -1 and selected_item < list_items.size():
		_restore_scroll_to_index(selected_item)
	# selected_item == -1（自动吸附尚未选定）时不动，交由 _process 吸附到当前可见项，避免矫位到第一项

## 恢复到指定项：仅当目标距离当前很远（如启动恢复、列表仍停在顶部）时，
## 先把滚动值预置到目标前一屏，再做最后一段短吸附补完；距离短时不做任何滚动
## 值预处理，直接复用原本的强制吸附（避免手动改滚动值打断吸附态、造成选中项收起再重选）
func _restore_scroll_to_index(index: int) -> void:
	if list_items.is_empty() or index < 0 or index >= list_items.size():
		return
	var target_scroll: int = int(container.get_child(index).position.y) - int(snap_offset_y)
	if absf(target_scroll - scroll_vertical) > size.y:
		# 从远处恢复：预置滚动到目标前一屏，再由 force_snap_to 短吸附补完最后这段
		scroll_vertical = maxi(target_scroll - int(size.y), 0)
	force_snap_to(index)

## 预热返回位置：把选中项、滚动位置与视窗封面提前摆好。
## 只在视图不可见时被调用（从 MidiView 退回 SongView），所以全部按"立即置位、不播动画"处理；
## 真正退回 AlbumView 时就不会再从旧位置大跳一次、封面也不会现加载。
## 同时把选中项切到目标专辑：AnimationManager 取 SelectedAlbum 头卡数据时优先读它，
## 直达路径（商店跳转 / 启动恢复 / 外部导入）原来会停在旧专辑上。
func _apply_warmup() -> void:
	if _warmup_album_id.is_empty():
		return
	# 列表可能还在分帧构建（启动直达路径）：等它就绪，避免在残缺列表上算位置
	var wait := 0
	while list_items.size() != current_albums.size() and wait < 10:
		if not is_inside_tree():
			return
		await get_tree().process_frame
		wait += 1
	if list_items.is_empty() or list_items.size() != current_albums.size():
		return
	var idx := _album_index(_warmup_album_id)
	if idx < 0:
		return  # 目标专辑被删，或当前搜索词把它过滤掉了
	select_item(idx)
	preset_scroll_vertical(_scroll_value_for_album(idx))
	# 选中项的展开 / 旧选中项的收起会改项高（±250px），布局稳定后按最终位置再校一次
	await get_tree().create_timer(0.2).timeout
	# 只在仍停在 SongView 时补第二次：已经回到本页就交给吸附，中途又去了别的页也不必预热
	if not is_inside_tree() or UiStatMGR.current_state != UIStateManager.UIState.SONG_VIEW:
		return
	preset_scroll_vertical(_scroll_value_for_album(idx))
	_preload_album_covers(idx)

func _album_index(album_id: String) -> int:
	for i in current_albums.size():
		if String(current_albums[i].get("id", "")) == album_id:
			return i
	return -1

## 目标滚动值：项顶部对齐到吸附偏移。与吸附同一口径（用内容坐标，与当前滚动值无关）
func _scroll_value_for_album(idx: int) -> int:
	if idx < 0 or idx >= list_items.size() or container == null \
			or idx >= container.get_child_count():
		return scroll_vertical
	var item: Control = container.get_child(idx)
	if item == null:
		return scroll_vertical
	return maxi(int(item.position.y) - int(snap_offset_y), 0)

## 预热目标附近的封面：只补一两屏，多了会和 SongView 自己的封面加载抢队列
func _preload_album_covers(idx: int) -> void:
	if list_items.is_empty():
		return
	_load_covers_in_range(maxi(idx - 1, 0), mini(idx + 4, list_items.size() - 1),
		_cover_chain_generation)

func on_item_button_confirmed(index: int):
	var album_id: String = String(current_albums[index].get("id", ""))
	if container.get_child(index).expand_tween:
		await container.get_child(index).expand_tween.finished
	# 记录导航位置：进入 SongView 时记录所选专辑（清空更深的 song/midi 记录）
	NavigationState.save(album_id, "", "")
	event_bus.album_selected.emit(album_id)
	UiStatMGR.change_state(UiStatMGR.UIState.SONG_VIEW)


func _on_random_select_btn_pressed() -> void:
	if work_state != UiStatMGR.current_state:
		return
	if current_albums.is_empty() or list_items.is_empty():
		return
	var random_index := randi() % current_albums.size()
	# 用 force_snap_to：列表滚动中也要立即取消惯性并吸附到随机项（普通 need_snap 会被滚动状态门控）
	force_snap_to(random_index)

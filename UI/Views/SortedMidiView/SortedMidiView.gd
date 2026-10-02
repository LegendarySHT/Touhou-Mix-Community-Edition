## 排序MIDI视图
## 显示按特定条件排序或搜索后的MIDI列表
## 虚拟化实现：ScrollContainer 只负责滚动/滚动条/吸附逻辑，内层容器不实例化任何项；
## 项渲染在覆盖于滚动容器之上的 SortedMidiContainer（overlay）上，维护固定数量的对象池，
## 按滚动位置重用。项高(180)与间距(29)固定，仅需管理 y 位置（x 恒为 0）。
extends BaseScrollList

class_name SortedMidiView

## 列表项高度
const ITEM_HEIGHT := 180
## 项高 + 间距 = 单项步进
const ITEM_STRIDE := 209
## 内容顶部留白（MarginTop）
const TOP_PAD := 250
## 对象池项数（显示项 + 上下缓冲，避免滚动补位穿帮）
const POOL_COUNT := 20
## 可视窗口上下各预保留的缓冲项数
const PRE_PAD := 6

## 当前显示的MIDI轻量投影（DB 返回 / 收藏夹转换），列表项直接消费，不水合完整 MidiData
var current_items: Array = []

## 收藏夹浏览模式标志：true 时 current_items 来自收藏夹，搜索/清空走收藏夹逻辑
var _favorites_mode: bool = false
## 当前收藏夹的谱面 id 列表（缓存，用于搜索时按 keys 过滤）
var _favorite_ids: Array = []

## 覆盖层（列表项实际渲染的容器，与滚动容器同级，避免被滚动平移）
var _overlay: Control = null
## 平行数组：list_items[si] 当前显示的数据索引，-1 表示空闲
var _slot_index: Array[int] = []

## 共享惯性状态：虚拟化项池项会被复用，惯性绝不能挂在单项上——
## 若由某槽驱动而另一项按下，单项刹停不了全局惯性，反拖刹不住。故统一入视图驱动。
var _fling_velocity := 0.0
var _flinging := false

## 下次复用/补位是否播放入场动画（切筛选跳顶时为 true，滚动补位为 false）
var _slot_animate_next: bool = false

## 管理器引用
@onready var sm: UIStateManager = UiStatMGR
@onready var dm: DataManager = DataMGR
@onready var eb: EventBus = EvtBus
@onready var se: SortingEngine = SortEngine

## 空结果提示节点
@onready var no_items_node: Label = get_node_or_null(PathRegistry.NO_ITEMS)

var item_bg: ButtonGroup = null

func _ready() -> void:
	if not dm or not eb or not se:
		push_error("SortedMidiView: Missing manager instances")
		return

	work_state = UIStateManager.UIState.SORTED_VIEW
	# 设置直接相邻状态：切到不在此集合的状态时释放所有列表项封面
	set_adjacent_states([
		UIStateManager.UIState.ALBUM_VIEW,
		UIStateManager.UIState.MIDI_VIEW,
	])

	# 覆盖层：与滚动容器同级，裁剪显示区；自身鼠标过滤 IGNORE，不拦截任何输入，
	# 列表项渲染其上的同时，空区拖拽/滚轮/滚动条仍由滚动容器原生处理。
	var sk := PathRegistry.SKEW_C
	if sk != "":
		_overlay = get_node_or_null(sk + "/SortedMidiContainer")
	if _overlay:
		_overlay.clip_contents = true
		# 覆盖层对输入透明（IGNORE，与 Main.tscn 一致）：空白区点击/滚轮/滚动条全部透传，
		# 由其后的滚动容器原生拖拽/滚动处理；列表项按钮作为子节点仍各自独立命中可点击。
		_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# 初始显隐跟随当前状态
		_overlay.visible = (sm.current_state == work_state)

	# 滚动条按下也需刹停惯性：滚动条是 ScrollContainer 子节点，事件被其独占消费、不走父级
	# _gui_input，故单独连接；否则拖滚动条时惯性仍推着 scroll_vertical，抢其拖拽
	var vbar := get_v_scroll_bar()
	if vbar and not vbar.gui_input.is_connected(_stop_fling_on_press):
		vbar.gui_input.connect(_stop_fling_on_press)

	# 连接事件
	eb.search_query_changed.connect(_on_search_query_changed)
	eb.sort_finished.connect(_load_sorted_midis)
	sm.state_changed.connect(_hide_label)
	eb.favorite_selected_for_browse.connect(_on_favorite_selected_for_browse)

	super._ready()

## 重写基类状态切换处理：退回 ALBUM_VIEW/SONG_VIEW 时清空列表（保留池，隐藏项）。
## 覆盖层显隐与入场/出场平移由 AnimationManager 统一驱动（与滚动容器同步滑入/滑出），此处不干预，
## 避免过渡期间覆盖层先于滚动容器显示或跳位。
func _on_state_changed(old_state: UIStateManager.UIState, new_state: UIStateManager.UIState) -> void:
	super._on_state_changed(old_state, new_state)
	if new_state in [UIStateManager.UIState.ALBUM_VIEW, UIStateManager.UIState.SONG_VIEW]:
		clear_items()
		current_items.clear()
		_favorites_mode = false
		if container:
			container.custom_minimum_size.y = 0

## 项按下：立即刹停全局惯性（任意项按下即停，反拖才能刹住）
func item_stop_fling() -> void:
	_fling_velocity = 0.0
	_flinging = false

## 任何指针按下即刹停惯性（供滚动条等子节点连接使用——它们的事件不进入父级 _gui_input）。
## 项目启用了"鼠标模拟触摸"：桌面鼠标会被转成 InputEventScreenTouch，故两种按下类型都要处理
func _stop_fling_on_press(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.pressed:
			item_stop_fling()
	elif event is InputEventScreenTouch:
		if event.pressed:
			item_stop_fling()

## 项松开：以采样初速度启动全局惯性
func item_launch_fling(v: float) -> void:
	_fling_velocity = v
	_flinging = v != 0.0

## 每帧驱动惯性：scroll -= v*dt，速度按 1000px/s 衰减，撞边界或停摆即止
func _step_fling(delta: float) -> void:
	if not _flinging:
		return
	var prev := scroll_vertical
	scroll_vertical = roundi(scroll_vertical - _fling_velocity * delta)
	var s := 1.0 if _fling_velocity >= 0.0 else -1.0
	_fling_velocity = s * maxf(0.0, absf(_fling_velocity) - 1000.0 * delta)
	if _fling_velocity == 0.0 or scroll_vertical == prev:
		_fling_velocity = 0.0
		_flinging = false

func _process(delta):
	super._process(delta)
	_update_virtual_layout()
	_step_fling(delta)

## 滚动容器自身收到输入时立即刹停本视图的虚拟化惯性。
## 空白区左键按下/滚轮等由滚动容器原生处理，若不刹停，惯性每帧改写 scroll_vertical 会与
## 原生拖拽抢占，表现为"须等惯性停摆才能拖动滚动容器"（反向/同向拖动皆然）。
func _gui_input(event):
	if event is InputEventMouseButton:
		if event.pressed:
			item_stop_fling()
	elif event is InputEventScreenTouch:
		if event.pressed:
			item_stop_fling()
	super._gui_input(event)

## 点击列表项：仅当索引有效时惰性水合完整 MidiData 并进入 MIDI 视图
func on_item_button_confirmed(index: int) -> void:
	if index < 0 or index >= current_items.size():
		return
	var item: Dictionary = current_items[index]
	var midi_id: String = String(item.get("id", ""))
	var midi: MidiData = DataMGR.get_midi_by_id(midi_id)
	if midi and eb:
		sm.change_state(UIStateManager.UIState.MIDI_VIEW)
		eb.emit_midi_selected(midi.id, midi)

## 加载排序的MIDI列表（重建列表，切换筛选时跳回顶部并播放入场动画）
func _load_sorted_midis(refectch: bool = true) -> void:
	if not dm or not se:
		GLogger.warning("Missing manager instances", "SortedMidiView")
		return

	if not item_bg:
		item_bg = ButtonGroup.new()

	if refectch:
		# DB 排序路径：取排序引擎的轻量投影；同时退出收藏夹模式
		current_items = se.get_items()
		_favorites_mode = false

	no_items_node.visible = current_items.size() == 0

	# 撑高内层容器，让滚动范围覆盖全部项（项高+间距固定，总高 = n*ITEM_STRIDE - 间距）
	if container:
		container.custom_minimum_size.y = max(current_items.size() * ITEM_STRIDE + 500, 0)

	# 重置选中与滚动状态
	selected_item = -1
	need_snap = false
	_snap_active = false
	scroll_vertical = 0
	_drag_scrolling = false
	item_stop_fling()

	# 切筛选进顶：让进入首屏的复用项/补位项播放入场动画（滚动复用则不播）
	_slot_animate_next = true

	_ensure_pool_ready()
	_update_virtual_layout()

## 依据滚动位置实时排布对象池项
func _update_virtual_layout() -> void:
	if not _overlay or not is_instance_valid(_overlay):
		return

	# 覆盖层跟随滚动容器的锚点尺寸/位置，保证与视图始终对齐；
	# 入场/出场平移偏移由 AnimationManager 统一驱动（与滚动容器同步滑入），此处不覆盖
	if _overlay.position != position:
		_overlay.position = position
	if _overlay.size != size:
		_overlay.size = size

	var n := current_items.size()
	if n == 0:
		for item in list_items:
			item.visible = false
		return

	var vtop := float(scroll_vertical)
	var vbot := vtop + float(size.y)
	if vbot <= 0.0:
		return

	# 可视数据索引区间 [first,last]：内容 top = TOP_PAD + i*ITEM_STRIDE
	var first := maxi(0, floori((vtop - TOP_PAD) / ITEM_STRIDE))
	var last := mini(n - 1, floori((vbot - TOP_PAD) / ITEM_STRIDE))
	if first > n - 1:
		first = n - 1
	if last < 0:
		last = 0
	# 加上下缓冲形成待显示窗口
	var lo := maxi(0, first - PRE_PAD)
	var hi := mini(n - 1, last + PRE_PAD)

	var animate := _slot_animate_next
	_slot_animate_next = false
	_ensure_pool_ready()
	_reconcile_pool(lo, hi, vtop, animate)

## 对齐对象池与窗口 [lo,hi]。数据刷新/跳顶（animate=true）时整窗全量重绑定，
## 否则（滚动）按数据索引增量：复用仍在窗口内的槽、空闲槽补位、移出窗口的槽释放
func _reconcile_pool(lo: int, hi: int, vtop: float, animate: bool) -> void:
	var slots := list_items.size()

	# 数据刷新/跳顶：旧槽持有的数据索引在数据更新后不再与当前项对应，
	# 若按索引增量对齐只会残留旧数据（切换筛选不刷新），故按视觉顺序逐槽全量重绑。
	if animate:
		var si := 0
		for idx in range(lo, hi + 1):
			if si >= slots:
				break
			_slot_index[si] = idx
			_assign_slot(si, idx, vtop, animate)
			si += 1
		for si2 in range(si, slots):
			if _slot_index[si2] != -1:
				_slot_index[si2] = -1
				list_items[si2].visible = false
		return

	var covered := {}  # data index -> 已占用槽

	for si in range(slots):
		var idx: int = _slot_index[si]
		if idx >= lo and idx <= hi:
			covered[idx] = si

	# 释放移出窗口的槽
	for si in range(slots):
		var idx: int = _slot_index[si]
		if idx != -1 and not (idx >= lo and idx <= hi):
			_slot_index[si] = -1
			list_items[si].visible = false

	# 为空闲槽补位缺失项
	for idx in range(lo, hi + 1):
		if idx in covered:
			continue
		var slot := -1
		for si in range(slots):
			if _slot_index[si] == -1:
				slot = si
				break
		if slot == -1:
			break
		_slot_index[slot] = idx
		_assign_slot(slot, idx, vtop, animate)

	# 定位/可见性/封面懒加载/视差
	for si in range(slots):
		var idx: int = _slot_index[si]
		if idx == -1:
			list_items[si].visible = false
			continue
		var node := list_items[si] as SortedMidiListItem
		_place_slot(node, idx, vtop)
		node.visible = true
		if not node._cover_loaded:
			node.start_cover_load()
		if node._parallax_enabled:
			node._apply_parallax_offset()

## 把槽绑定到新数据索引：定位 + 设数据（复用项播/抑入场动画由 animate 决定）
func _assign_slot(slot: int, idx: int, vtop: float, animate: bool) -> void:
	var node := list_items[slot] as SortedMidiListItem
	node.item_index = idx
	_place_slot(node, idx, vtop)
	node._suppress_refresh_animation = not animate
	node.setup_with_dict(current_items[idx], idx, item_bg)

## 定位项到内容坐标（x 恒 0，仅管理 y）
func _place_slot(node: SortedMidiListItem, idx: int, vtop: float) -> void:
	node.position = Vector2(0.0, TOP_PAD + idx * ITEM_STRIDE - vtop)

## 惰性创建对象池（仅一次）
func _ensure_pool_ready() -> void:
	if not list_items.is_empty() or item_scene == null or not _overlay:
		return
	for i in range(POOL_COUNT):
		var node := item_scene.instantiate() as SortedMidiListItem
		_overlay.add_child(node)
		node.visible = false
		list_items.append(node)
		_slot_index.append(-1)

## 清空列表（保留池，仅隐藏并重置槽状态）
func clear_items() -> void:
	for si in range(_slot_index.size()):
		_slot_index[si] = -1
	for item in list_items:
		item.visible = false
	selected_item = -1
	need_snap = false
	_snap_active = false
	_slot_animate_next = false
	item_stop_fling()

## 覆盖基类封面/视差驱动：由 _update_virtual_layout 统一处理，避免按 list_items 全量索引
func trigger_cover_chain() -> void:
	pass

func _update_cover_window() -> void:
	pass

func _update_visible_parallax() -> void:
	pass

## 选中指定数据索引（兼容 FocusManager 等外部调用）
func select_item(index: int) -> int:
	if current_items.is_empty():
		return index
	index = (index + current_items.size()) % current_items.size()
	selected_item = index
	var node := get_pool_node_by_index(index)
	if node and is_instance_valid(node) and node.button:
		node.button.button_pressed = true
	return index

## 返回当前显示选中数据索引的那一槽节点（虚拟化项不在固定索引位，需按槽查找）
func get_selected_node() -> Control:
	if selected_item < 0 or list_items.is_empty():
		return null
	return get_pool_node_by_index(selected_item)

## 找持有指定数据索引的池槽节点（+-1 表示未显示返回 null）
func get_pool_node_by_index(idx: int) -> SortedMidiListItem:
	for si in range(_slot_index.size()):
		if _slot_index[si] == idx:
			return list_items[si] as SortedMidiListItem
	return null

## 把数据索引滚入可视窗口（含缓冲），越界方向补正 scroll_vertical
func _scroll_to_item(idx: int) -> void:
	var view_h := size.y
	if view_h <= 0.0:
		return
	var item_top := TOP_PAD + idx * ITEM_STRIDE
	var item_bot := item_top + ITEM_HEIGHT
	if item_top < scroll_vertical:
		scroll_vertical = roundi(item_top)
	elif item_bot > scroll_vertical + view_h:
		scroll_vertical = roundi(item_bot - view_h)

## 供 FocusManager 把焦点移入列表：确保选中的数据索引滚入可视窗口（被池化）
## 后聚焦其按钮。虚拟化项不在固定子位、且可能已滚出屏幕被释放，必须先滚动补位。
func focus_selected_item() -> void:
	if current_items.is_empty():
		return
	if selected_item < 0:
		select_item(0)
	_scroll_to_item(selected_item)
	_update_virtual_layout()
	var node := get_pool_node_by_index(selected_item)
	if node and node.button:
		node.button.grab_focus()

## 搜索查询改变
func _on_search_query_changed(query: String) -> void:
	if not se:
		return
	if sm.current_state != UIStateManager.UIState.SORTED_VIEW:
		return

	if query.is_empty():
		if _favorites_mode:
			current_items = ChartDB.GetMidiListItemsByKeys(_favorite_ids, "")
			_load_sorted_midis(false)
		else:
			se.set_sort_mode(se.current_sort_stat_field, se.current_sort_field, se.current_sort_direction)
		return

	if _favorites_mode:
		current_items = ChartDB.GetMidiListItemsByKeys(_favorite_ids, query)
		_load_sorted_midis(false)
	else:
		se.set_sort_mode_with_query(query)

func _hide_label(_old,_new):
	if no_items_node.visible:
		no_items_node.visible = false

## 收藏夹被选中浏览：加载该收藏夹的所有 midi（轻量投影）
func _on_favorite_selected_for_browse(fav_id: String) -> void:
	if not FavoriteManager.instance:
		return
	var fav = FavoriteManager.instance.get_favorite(fav_id)
	if not fav:
		return
	_favorites_mode = true
	_favorite_ids = fav.midi_ids.duplicate()
	current_items = ChartDB.GetMidiListItemsByKeys(_favorite_ids, "")
	_load_sorted_midis(false)

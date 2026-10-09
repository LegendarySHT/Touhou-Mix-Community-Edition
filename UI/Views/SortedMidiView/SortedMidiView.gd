## 排序MIDI视图
## 显示按特定条件排序或搜索后的MIDI列表
## 虚拟化实现：ScrollContainer → ListContent（纯 Control，高度 = 完整内容高度），
## 滚动/滚动条/惯性/拖动全交给 ScrollContainer 自己，ListContent 只负责把池项搬到各自位置。
## 项高(180)与间距(29)固定，仅需管理 y 位置（x 恒为 0），池管理走 `VirtualList`。
extends BaseScrollList

class_name SortedMidiView

## 列表项高度
const ITEM_HEIGHT := 180
## 项高 + 间距 = 单项步进
const ITEM_STRIDE := 209
## 内容顶部留白（MarginTop）
const TOP_PAD := 250
## 可视窗口上下各预保留的缓冲行数（池大小由 VirtualList 按视窗自行算）
const PRE_PAD := 5
## 通用虚拟化列表（与 DelView/播放列表/曲库共用）。preload 而非全局类名，避免类缓存问题
const VirtualListLib := preload("res://UI/Components/VirtualList.gd")

## 当前显示的MIDI轻量投影（DB 返回 / 收藏夹转换），列表项直接消费，不水合完整 MidiData
var current_items: Array = []

## 收藏夹浏览模式标志：true 时 current_items 来自收藏夹，搜索/清空走收藏夹逻辑
var _favorites_mode: bool = false
## 当前收藏夹的谱面 id 列表（缓存，用于搜索时按 keys 过滤）
var _favorite_ids: Array = []

## 对象池（内容层 + 自由槽位复用；内容层 = 滚动容器的唯一子节点 ListContent）
var _vlist: VirtualListLib = null

## 下次全量重绑是否播放入场动画（切筛选跳顶时为 true，滚动补位为 false）
var _slot_animate_next: bool = false
## 本次 sync 期间生效的动画标志。不能复用 _slot_animate_next —— 它在 sync 前就要清掉，
## 而 bind 回调是在 sync 内同步执行的，读它永远是 false
var _bind_animate: bool = false

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

	# 池项内容层是滚动容器的唯一子节点：滚动/拖动/惯性全部由滚动容器原生处理

	# 连接事件
	eb.search_query_changed.connect(_on_search_query_changed)
	eb.sort_finished.connect(_load_sorted_midis)
	sm.state_changed.connect(_hide_label)
	eb.favorite_selected_for_browse.connect(_on_favorite_selected_for_browse)

	super._ready()

## 重写基类状态切换处理：退回 ALBUM_VIEW/SONG_VIEW 时清空列表（保留池，隐藏项）。
## 入场/出场平移由 AnimationManager 驱动滚动容器（池项是它的子节点，跟着一起走）
func _on_state_changed(old_state: UIStateManager.UIState, new_state: UIStateManager.UIState) -> void:
	super._on_state_changed(old_state, new_state)
	if new_state in [UIStateManager.UIState.ALBUM_VIEW, UIStateManager.UIState.SONG_VIEW]:
		clear_items()
		current_items.clear()
		_favorites_mode = false

func _process(delta):
	super._process(delta)
	_update_virtual_layout()

## 滚动容器自身收到输入时立即刹停本视图的虚拟化惯性。
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
	_ensure_pool_ready()

	# 内容层高度 = 完整内容高度（模块写进 custom_minimum_size.y），滚动范围由此而来
	if _vlist != null:
		_vlist.set_total(current_items.size())

	# 重置选中与滚动状态
	selected_item = -1
	need_snap = false
	_snap_active = false
	scroll_vertical = 0
	_drag_scrolling = false

	# 切筛选进顶：让进入首屏的复用项/补位项播放入场动画（滚动复用则不播）
	_slot_animate_next = true
	_update_virtual_layout(true)

## 依据滚动位置实时排布对象池项
## force=true：全量重绑（数据刷新/跳顶时，增量对齐会残留旧数据）
func _update_virtual_layout(force: bool = false) -> void:
	_ensure_pool_ready()
	if _vlist == null:
		return
	# 切筛选跳顶时全量重绑，让进入首屏的复用项/补位项播入场动画。
	# 动画标志要在 sync 期间保持置位——bind 回调在 sync 内同步执行，先清就永远读不到 true
	var animate := _slot_animate_next
	_slot_animate_next = false
	_bind_animate = animate
	_vlist.sync(force or animate)
	_bind_animate = false
	# 封面懒加载 / 视差（基类按 list_items 全量索引，这里只对已绑定的池项做）
	for slot in _vlist.occupied:
		var item := _vlist.pool[int(slot)] as SortedMidiListItem
		if item == null:
			continue
		if not item._cover_loaded:
			item.start_cover_load()
		if item._parallax_enabled:
			item._apply_parallax_offset()

## 池项首次创建：连信号等一次性初始化。
## 同时挂进基类的 list_items —— 基类的封面释放/状态复位（_release_all_covers /
## invalidate_cover_state / release_covers）都遍历它，不挂进去会整批漏掉
func _on_pool_item_ready(node) -> void:
	list_items.append(node as ListItemBase)

## 池项换绑到数据索引：填数据。定位由模块做
func _on_pool_item_bind(node, idx: int) -> void:
	var item := node as SortedMidiListItem
	if item == null or idx >= current_items.size():
		return
	item.item_index = idx
	item._suppress_refresh_animation = not _bind_animate
	item.setup_with_dict(current_items[idx], idx, item_bg)

## 惰性创建对象池（仅一次）
func _ensure_pool_ready() -> void:
	if _vlist != null or item_scene == null:
		return
	var content := get_node_or_null("ListContent") as Control
	if content == null:
		return
	_vlist = VirtualListLib.new()
	_vlist.margin_rows = PRE_PAD
	_vlist.top_padding = TOP_PAD
	_vlist.row_gap = ITEM_STRIDE - ITEM_HEIGHT
	# 项宽由场景定（900），不铺满 list
	_vlist.stretch_width = false
	_vlist.on_row_ready = _on_pool_item_ready
	_vlist.on_row_bind = _on_pool_item_bind
	_vlist.setup(self, content, item_scene)

## 清空列表（保留池，仅隐藏并重置槽状态）
func clear_items() -> void:
	if _vlist != null:
		_vlist.clear()
	selected_item = -1
	need_snap = false
	_snap_active = false
	_slot_animate_next = false

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
	if selected_item < 0 or _vlist == null:
		return null
	return get_pool_node_by_index(selected_item)

## 找持有指定数据索引的池槽节点（未显示返回 null）
func get_pool_node_by_index(idx: int) -> SortedMidiListItem:
	if _vlist == null:
		return null
	return _vlist.node_at(idx) as SortedMidiListItem

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

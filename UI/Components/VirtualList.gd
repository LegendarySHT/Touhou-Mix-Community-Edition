## 池化虚拟列表（slot 模式：绝对定位 + 自由槽位复用）
##
## 四种列表共用：DelView / 播放列表（单列）、曲库 3 列 / SortedMidiView（单列 + 顶部留白）。
## 结构约定：**ScrollContainer → 一个纯 Control（list）**，list 的高度 = 完整内容高度
## （写进 custom_minimum_size.y），滚动完全交给 ScrollContainer；list 只负责把池项搬到各自的位置。
##
## 做法：维护一个固定大小的节点池，每个池项摆到自己的数据位置；滚动时只给「新进入窗口的索引」
## 分配空闲槽并换绑，滚出窗口的槽回收，再滚回来时从另一端复用——池项数恒定为
## 「视窗内容 + 上下缓冲」，与数据总量无关。
##
## 三条硬约束（都是踩过的坑）：
## 1. `list` 必须是**纯 Control**：VBox/HBox/GridContainer 等 Container 会强制布局子节点，
##    把池项的偏移覆盖掉。
## 2. `list.mouse_filter` 不能是 STOP（本模块会替默认的 STOP 改成 PASS）：纯 Control 默认 STOP
##    会把指针事件截在 list 上，外层 ScrollContainer 收不到按下/拖动，它自带的「按住拖动平移」
##    就废了（Container 默认是 PASS，从 VBox 改成纯 Control 时最容易漏这一步）。
## 3. **不要在这里叠加滚动位移**：list 是 ScrollContainer 的子节点，ScrollContainer 自己就会把
##    内容整体平移 -scroll_vertical（见 scroll_container.cpp:_reposition_children）。池项坐标只由
##    数据索引决定（idx*行距），随滚动平移交给外层容器——自己再减一次 scroll_vertical 就是
##    双重偏移，表现为滚动后可视窗口里出现错位的一段内容。
##
## 位置只写 `offset_transform_position`：它不参与布局结算（不触发 item_rect_changed、不会让容器
## 重排），而视觉、命中区、焦点几何（get_global_rect）都会跟着走，滚动帧里也只是重写这一个向量。
## 注意 offset_transform_enabled 默认 false、offset_transform_visual_only 默认 true，
## 两个都要在建池时显式改过来，否则写了不生效、或「看得见点不着」。
##
## 用法：
##   var vl := VirtualList.new()
##   vl.columns = 3; vl.row_gap = 25.0; vl.col_gap = 20.0   # 单列列表就是 columns=1
##   vl.setup(scroll_container, list_content, item_scene)
##   vl.on_row_ready = func(node): ...      # 池项首次创建，只调一次（连信号）
##   vl.on_row_bind  = func(node, idx): ... # 换绑到数据索引 idx
##   vl.set_total(n)                        # 换数据源（会跳回顶部并全量重绑）
##   vl.sync()                              # 数据内容变了但行数没变时手动对齐
##   vl.relayout()                          # 运行中改了 columns/col_gap 之后重排一次
##
## 注意：池项是复用的，信号只能在 on_row_ready 里连一次。回调里要取「这项当前显示的是哪条
## 数据」，一律走 node.get_meta(&"row_index") 或 node_at()，不要用 Callable.bind 把数据键绑死。
class_name VirtualList
extends RefCounted

const DEFAULT_MARGIN_ROWS := 3
const DEFAULT_MAX_SLOTS := 64

## 列数（1 = 单列列表；曲库为 3 列网格）。列宽由列锚点按 list 宽度均分，改完调 relayout()
var columns: int = 1
## 行间距（行高之外的留白，用来还原旧 VBox 的 separation）
var row_gap: float = 4.0
## 列间距（仅多列时生效）
var col_gap: float = 0.0
## 内容顶部留白（SortedMidiView 的 TOP_PAD）
var top_padding: float = 0.0
## 视窗外仍保持绑定的缓冲行数（上下各这么多个不可见行，滚动时不会闪空）
var margin_rows: int = DEFAULT_MARGIN_ROWS
## 池上限（多列时按「项数」计）：窗口被拉得极高时的兜底，避免一次建出上百个节点
var max_slots: int = DEFAULT_MAX_SLOTS
## 单列时是否把池项宽度铺满 list（多列时宽度由列锚点决定，此项无关）。
## 关掉用于「项自带固定宽度」的列表（SortedMidiView 的项宽 900 由场景定）
var stretch_width: bool = true

var scroll: ScrollContainer
var list: Control
var row_scene: PackedScene

## 池项首次创建（每项只调一次）：适合连接信号、一次性初始化
var on_row_ready: Callable
## 每次换绑到新数据索引：填内容
var on_row_bind: Callable

## 行高（不含 row_gap）。首次 ensure 时从 row_scene 实测
var row_height: float = 0.0
## 行步进 = 行高 + 行间距
var row_stride: float = 0.0
## 数据总条数（由使用方维护过滤/折叠后的结果）
var total: int = 0
## 池项节点（下标 = 槽位）
var pool: Array[Control] = []
## 空闲槽位下标
var free_slots: Array = []
## 占用表：槽位下标 → 数据索引。槽位与数据无固定对应（自由槽位模式）
var occupied: Dictionary = {}


func setup(p_scroll: ScrollContainer, p_list: Control, p_row_scene: PackedScene) -> void:
	scroll = p_scroll
	list = p_list
	row_scene = p_row_scene
	# 纯 Control 默认 STOP，会把指针事件截在 list 上：外层 ScrollContainer 收不到按下/拖动，
	# 它自带的「按住拖动平移」就失效了。场景里显式给过 PASS/IGNORE 的尊重原样，只改默认的 STOP
	if list.mouse_filter == Control.MOUSE_FILTER_STOP:
		list.mouse_filter = Control.MOUSE_FILTER_PASS
	scroll.get_v_scroll_bar().value_changed.connect(func(_v: float) -> void: sync(false))
	scroll.resized.connect(func() -> void:
		_grow()
		sync(false)
	)


## 量行高 + 建池。行高拿不到（首帧容器尚未布局）返回 false，调用方应稍后重试
func ensure() -> bool:
	if row_stride > 0.0:
		return true
	if scroll == null or list == null or row_scene == null or scroll.size.y <= 0.0:
		return false
	var sample := row_scene.instantiate() as Control
	if sample == null:
		return false
	list.add_child(sample)
	var h := sample.get_combined_minimum_size().y
	list.remove_child(sample)
	sample.queue_free()
	if h <= 0.0:
		return false
	row_height = h
	row_stride = h + row_gap
	_grow()
	_apply_content_height()
	return true


## 数据总量变化。**不碰滚动量**（归零由调用方决定，见 reset_scroll）。
## reset_scroll=false 用于就地增删（折叠 / 展开 / 勾选联动）：其上方内容没变，
## 保留 scroll_vertical 就等于把点击的那一行钉在原处，强行归零会表现为「列表跳回顶部」
func set_total(n: int, reset_scroll: bool = true) -> void:
	total = maxi(n, 0)
	_release_all()
	_apply_content_height()
	if scroll != null:
		scroll.scroll_vertical = 0.0 if reset_scroll \
			else _clamp_scroll(float(scroll.scroll_vertical))
	sync(true)


## 直接定位到指定滚动像素（夹进有效区间）并重绑窗口
func set_scroll(v: float) -> void:
	if scroll == null:
		return
	scroll.scroll_vertical = _clamp_scroll(v)
	sync(true)


## 按当前滚动位置把池项对准数据窗口。
## force=true：归还全部槽并按窗口全量重绑（数据刷新时用）
## force=false：增量——只给新进入窗口的索引补空槽，移出窗口的槽归还，已绑定的槽原地不动。
##   注意这里**不重定位**已绑定的槽：池项位置只由数据索引决定，滚动平移由 ScrollContainer 负责
func sync(force: bool = false) -> void:
	# 行高还没量出来（容器尚未布局）：任何一次 sync 都顺带重试建池，
	# 这样调用方不必自己等布局——滚动/resized/切页都会自然补上第一次渲染
	if row_stride <= 0.0:
		if not ensure():
			return
	if pool.is_empty():
		return
	if total <= 0:
		_release_all()
		return

	# set_total 可能早于 ensure 调用（那时 row_stride 还是 0，内容高度写成 0 且没人修正），
	# 这里做一次自愈；值没变时 set_custom_minimum_size 自身会 early-return，不扰动布局
	_apply_content_height()

	var vtop := float(scroll.scroll_vertical)
	var view_h := scroll.size.y
	if view_h <= 0.0:
		return

	var cols := maxi(1, columns)
	var first_row := maxi(0, floori((vtop - top_padding) / row_stride) - margin_rows)
	var vis_rows := int(ceil(view_h / row_stride)) + 1 + margin_rows * 2
	var lo := first_row * cols
	var hi := mini(lo + vis_rows * cols - 1, total - 1)

	if force:
		_release_all()
		for idx in range(lo, hi + 1):
			if free_slots.is_empty():
				break
			var slot: int = free_slots.pop_back()
			occupied[slot] = idx
			_bind(slot, idx)
		return

	# 增量：移出窗口的槽归还，窗口内未绑定的索引补空槽。
	# 已绑定的绝不能再绑一次——同一索引落到两项上会位置重合、互相遮挡
	var bound := {}
	for slot in occupied.keys():
		var idx: int = occupied[slot]
		if idx < lo or idx > hi:
			occupied.erase(slot)
			pool[slot].visible = false
			pool[slot].remove_meta("row_index")
			free_slots.append(slot)
		else:
			bound[idx] = true
	for idx in range(lo, hi + 1):
		if bound.has(idx) or free_slots.is_empty():
			continue
		var slot: int = free_slots.pop_back()
		occupied[slot] = idx
		_bind(slot, idx)


## 数据整体刷新但行数没变
func refresh_all() -> void:
	sync(true)


## 返回当前正显示指定数据索引的池项（不在窗口内返回 null）
func node_at(idx: int) -> Control:
	for slot in occupied.keys():
		if int(occupied[slot]) == idx:
			return pool[slot] as Control
	return null


## 当前已绑定（正在显示）的池项节点
func bound_nodes() -> Array:
	var arr: Array = []
	for slot in occupied.keys():
		arr.append(pool[slot])
	return arr


## 隐藏所有项并解除绑定（切页时用，池保留）
func clear() -> void:
	total = 0
	_release_all()
	if list != null:
		list.custom_minimum_size.y = 0.0


## 销毁池
func release() -> void:
	for node in pool:
		if is_instance_valid(node):
			node.queue_free()
	pool.clear()
	free_slots.clear()
	occupied.clear()
	row_height = 0.0
	row_stride = 0.0


# ── 内部 ──────────────────────────────────────────────

## 行数 = 总条数 / 列数
func _row_count() -> int:
	return int(ceil(float(total) / float(maxi(1, columns))))


## 内容总高（list 的 custom_minimum_size.y 与滚动范围都按它算）
func _content_height() -> float:
	# 行高还没量出来（尚未布局）：不给内容高度，免得算出个只有行间距的假高度
	var rows := _row_count()
	if rows <= 0 or row_height <= 0.0:
		return 0.0
	return top_padding + float(rows) * row_height + float(rows - 1) * row_gap


func _apply_content_height() -> void:
	if list != null:
		list.custom_minimum_size.y = _content_height()


## 把滚动位置夹进 [0, 内容总高 - 视窗高]：条数变少时防止停在底部空白区
func _clamp_scroll(v: float) -> float:
	if scroll == null or row_stride <= 0.0:
		return v
	return clampf(v, 0.0, maxf(_content_height() - scroll.size.y, 0.0))


## 池大小对齐视窗。只增不减：窗口拉大时补槽，缩小时靠 sync 的窗口判定隐藏多余槽位即可，
## 无需真去裁剪（裁了以后再拉大还要重建，节点身份一换信号就得重连）。
## 槽位下标稳定不变，on_row_ready 里连的信号因此一直有效
func _grow() -> void:
	if row_stride <= 0.0 or list == null or row_scene == null or scroll == null:
		return
	var need := (int(ceil(scroll.size.y / row_stride)) + 1 + margin_rows * 2) * maxi(1, columns)
	need = clampi(need, 1, max_slots)
	while pool.size() < need:
		var node := row_scene.instantiate() as Control
		if node == null:
			break
		list.add_child(node)
		_make_cell_base(node)
		if on_row_ready.is_valid():
			on_row_ready.call(node)
		pool.append(node)
		free_slots.append(pool.size() - 1)


## 池项基础态：矩形尺寸钉一次，位置起始为 0（之后全靠 offset_transform 搬）
func _make_cell_base(node: Control) -> void:
	# 多列：列宽由列锚点算，清掉场景里的 custom_minimum_size.x（如 LibraryCard 的 600），
	# 否则卡片宽度会被这个下限顶住、把相邻列挤掉
	if columns > 1:
		node.custom_minimum_size = Vector2(0.0, row_height)
	# 纵向必须钉死行高：list 是纯 Control，没有 Container 替池项排版
	node.anchor_top = 0.0
	node.anchor_bottom = 0.0
	node.offset_top = 0.0
	node.offset_bottom = row_height
	# 横向：单列且要求铺满时铺满，否则沿用场景自带尺寸（项自带固定宽度的情况）
	if columns == 1 and stretch_width:
		node.anchor_left = 0.0
		node.anchor_right = 1.0
		node.offset_left = 0.0
		node.offset_right = 0.0
	node.offset_transform_enabled = true        # 默认 false：不打开，写了位置也不生效
	node.offset_transform_visual_only = false   # 默认 true：只挪画面，命中区留在原地会"看得见点不着"
	node.offset_transform_position = Vector2.ZERO
	node.visible = false   # 未绑定的项必须隐藏，否则会全部堆在左上角重叠


## 把槽绑定到新数据索引：定位 + 设数据 + 记录 meta（供回调反查）
func _bind(slot: int, idx: int) -> void:
	var node: Control = pool[slot]
	_place(node, idx)
	node.visible = true
	node.set_meta(&"row_index", idx)
	if on_row_bind.is_valid():
		on_row_bind.call(node, idx)


## 按数据索引定位。**不叠加 scroll_vertical**——list 整体已被 ScrollContainer 平移过（见头注释第 3 条）。
## 横向（多列）用**列锚点**表达：第 col 列占 [col/cols, (col+1)/cols]，两侧各缩半个列间距。
## 这样列宽随 list 宽度自适应、list 尺寸变化时由引擎自己重算 —— 本模块不必读 list.size，
## 也就不会因为"绑定时 list 还没量出宽度"把列宽算成 0（那样整行卡片会全叠在第一列上）
func _place(node: Control, idx: int) -> void:
	var cols := maxi(1, columns)
	var row := idx / cols
	if cols > 1:
		var col := idx % cols
		node.anchor_left = float(col) / float(cols)
		node.anchor_right = float(col + 1) / float(cols)
		node.offset_left = col_gap * 0.5
		node.offset_right = -col_gap * 0.5
	node.offset_transform_position = Vector2(0.0, top_padding + float(row) * row_stride)


## 已绑定项重新摆位。改了 columns / col_gap / row_gap / top_padding 之后（或想重排列）调一次即可；
## 单纯改窗口尺寸不用调 —— 横向锚点由引擎随 list 尺寸自己算，纵向位置与尺寸无关
func relayout() -> void:
	for slot in occupied.keys():
		_place(pool[int(slot)], int(occupied[slot]))


func _release_all() -> void:
	for slot in occupied.keys():
		var node: Control = pool[int(slot)]
		node.visible = false
		node.remove_meta("row_index")
		free_slots.append(int(slot))
	occupied.clear()

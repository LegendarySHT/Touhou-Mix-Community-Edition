## 固定行高的虚拟化行池
##
## 把「几千条数据只渲染可视区几十行」这件事从具体业务里剥出来。
## 做法：维护一个固定大小的节点池 + 上下两个 spacer 撑起滚动范围，滚动时按窗口把池行
## 换绑到新的数据索引。节点数恒定为「视窗行数 + 缓冲」，与数据总量无关。
##
## 前提：**行高必须固定**（由 row_scene 实测得出）。这是能用 scroll_vertical 直接换算
## 数据索引、而不必累计每项实际高度的原因。若业务需要可变行高，本模块不适用。
##
## 用法：
##   var vl := VirtualRowList.new()
##   vl.setup(scroll_container, list_container, row_scene)
##   vl.on_row_ready = func(node: Control) -> void: ...   # 池行首次创建，只调一次（连信号）
##   vl.on_row_bind  = func(node: Control, row_index: int) -> void: ...  # 每次换绑，填内容
##   vl.set_total(n)
##   vl.sync(true)
##
## 注意：池行是复用的，信号只能在 on_row_ready 里连一次。回调里要取"这行当前显示的是哪条
## 数据"，一律走 node.get_meta(&"row_index")，不要用 Callable.bind 把数据键绑死在连接上。
class_name VirtualRowList
extends RefCounted

const DEFAULT_MARGIN_ROWS := 3
const DEFAULT_MAX_ROWS := 32

## 视窗外仍保持绑定的缓冲行数（上下各这么多个不可见行，滚动时不会闪空）
var margin_rows: int = DEFAULT_MARGIN_ROWS
## 池上限：窗口被拉得极高时的兜底，避免一次建出上百个节点
var max_rows: int = DEFAULT_MAX_ROWS

var scroll: ScrollContainer
var list: VBoxContainer
var row_scene: PackedScene

## 池行首次创建（每个池行只调一次）：适合连接信号、一次性初始化
var on_row_ready: Callable
## 每次换绑到新数据索引：填行内容
var on_row_bind: Callable

## 行距 = 行高 + 容器 separation（首次 ensure() 时实测）
var row_stride: float = 0.0
## 数据总行数（= 可视行数，由使用方维护过滤/折叠后的结果）
var total: int = 0
## 池行节点
var pool: Array[Control] = []

var _top_spacer: Control
var _bottom_spacer: Control
var _first: int = -1
## 每个池行当前绑定的数据索引，-1 = 空闲
var _bound: Array = []


func setup(p_scroll: ScrollContainer, p_list: VBoxContainer, p_row_scene: PackedScene) -> void:
	scroll = p_scroll
	list = p_list
	row_scene = p_row_scene
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
	row_stride = h + float(list.get_theme_constant("separation"))
	_top_spacer = _make_spacer()
	list.add_child(_top_spacer)
	_bottom_spacer = _make_spacer()
	list.add_child(_bottom_spacer)
	_grow()
	return true


## 数据总量变化：重置窗口与全部绑定（下次 sync 全量重绑）
## reset_scroll: true（默认）= 回到顶部，用于换数据源（切页 / 重建 / 改搜索词）
##               false        = 保留当前位置并夹进新区间，用于就地增删行（折叠 / 展开 / 勾选联动）
## 折叠展开必须走 false：插入/删除的行都在被点击的那一行之后，其上方内容没变，
## 保留 scroll_vertical 就等于把点击的那一行钉在原处；若强行归零会表现为"列表跳回顶部"
func set_total(n: int, reset_scroll: bool = true) -> void:
	total = maxi(n, 0)
	_first = -1
	for k in _bound.size():
		_bound[k] = -1
	if scroll != null:
		scroll.scroll_vertical = 0.0 if reset_scroll \
			else _clamp_scroll(float(scroll.scroll_vertical))
	sync(true)


## 把滚动位置夹进 [0, 内容总高 - 视窗高]：行数变少时防止停在底部空白区
func _clamp_scroll(v: float) -> float:
	if scroll == null or row_stride <= 0.0:
		return v
	var max_v := maxf(float(total) * row_stride - scroll.size.y, 0.0)
	return clampf(v, 0.0, max_v)


## 直接定位到指定滚动像素（夹进有效区间）并重绑窗口
func set_scroll(v: float) -> void:
	if scroll == null:
		return
	scroll.scroll_vertical = _clamp_scroll(v)
	sync(true)


## 按当前滚动位置把池行对准数据窗口。
## force=true：即使行已绑同一索引也强制重绑（数据内容变了但索引没变时用）
func sync(force: bool = false) -> void:
	# 行高还没量出来（容器尚未布局）：任何一次 sync 都顺带重试建池，
	# 这样调用方不必自己等布局——滚动/resized/切页都会自然补上第一次渲染
	if row_stride <= 0.0:
		if not ensure():
			return
	if pool.is_empty():
		return
	if total == 0:
		for node in pool:
			node.visible = false
		for k in _bound.size():
			_bound[k] = -1
		return

	# 窗口起点：让池整体尽量居中覆盖可视区（数据少于池容量时恒为 0）
	var first := 0
	if total > pool.size():
		first = clampi(int(scroll.scroll_vertical / row_stride) - margin_rows,
			0, total - pool.size())
	if first != _first:
		_first = first
		_apply_spacers(first)

	# 真正可见的范围：池可能大于视窗，只有落在范围内的行参与绘制
	var vis_first := int(floor(scroll.scroll_vertical / row_stride)) - margin_rows
	var vis_last := int(ceil((scroll.scroll_vertical + scroll.size.y) / row_stride)) + margin_rows

	for k in pool.size():
		var node := pool[k]
		var idx := first + k
		if idx >= total or idx < vis_first or idx > vis_last:
			node.visible = false
			_bound[k] = -1
			continue
		node.visible = true
		if not force and _bound[k] == idx:
			continue
		_bound[k] = idx
		node.set_meta(&"row_index", idx)
		if on_row_bind.is_valid():
			on_row_bind.call(node, idx)


## 返回当前正显示指定数据索引的池行（不在窗口内返回 null）
func node_at(row_index: int) -> Control:
	for k in _bound.size():
		if _bound[k] == row_index:
			return pool[k] as Control
	return null


## 全部池行重绑（数据整体刷新但行数没变）
func refresh_all() -> void:
	sync(true)


## 隐藏所有行并解除绑定（切页时用，池保留）
func clear() -> void:
	total = 0
	_first = -1
	for k in _bound.size():
		_bound[k] = -1
	for node in pool:
		node.visible = false
	_apply_spacers(0)


## 销毁池与 spacer
func release() -> void:
	for node in pool:
		if is_instance_valid(node):
			node.queue_free()
	pool.clear()
	_bound.clear()
	for sp in [_top_spacer, _bottom_spacer]:
		if sp != null and is_instance_valid(sp):
			sp.queue_free()
	_top_spacer = null
	_bottom_spacer = null
	row_stride = 0.0
	_first = -1


# ── 内部 ──────────────────────────────────────────────

func _make_spacer() -> Control:
	var sp := Control.new()
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return sp


## 池大小对齐视窗（拉伸补行、缩小裁行），并把底 spacer 挪回末尾
func _grow() -> void:
	if row_stride <= 0.0 or list == null:
		return
	var need := int(ceil(scroll.size.y / row_stride)) + 1 + margin_rows * 2
	need = clampi(need, 1, max_rows)
	while pool.size() < need:
		var node := row_scene.instantiate() as Control
		if node == null:
			break
		node.visible = false
		list.add_child(node)
		if on_row_ready.is_valid():
			on_row_ready.call(node)
		pool.append(node)
		_bound.append(-1)
	while pool.size() > need:
		var node: Control = pool.pop_back()
		_bound.pop_back()
		list.remove_child(node)
		node.queue_free()
	if _bottom_spacer != null:
		list.move_child(_bottom_spacer, list.get_child_count() - 1)
	_first = -1  # 池成员变了，下轮同步强制重算窗口


func _apply_spacers(first: int) -> void:
	if _top_spacer != null:
		_top_spacer.custom_minimum_size.y = float(first) * row_stride
	if _bottom_spacer != null:
		_bottom_spacer.custom_minimum_size.y = \
			float(maxi(total - first - pool.size(), 0)) * row_stride

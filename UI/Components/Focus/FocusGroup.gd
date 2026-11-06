## 焦点组：把一组同类控件当作「一个焦点单元」
##
## 列表、标签栏这类复合控件注册成组之后：
## - 方向键在组内按轴向移动；到边界返回 false，由 FocusRouter 接着做几何搜索；
## - Tab 遍历时整组只占一个停靠点，不会把列表里几百项挨个走一遍。
##
## 成员一律用控件引用表达（map_fn 返回「可聚焦控件 → 下标」），不存节点路径。
## 池化列表换绑节点、列表重建都不需要通知本对象：FocusRouter 在每次导航前重建成员表。
class_name FocusGroup
extends RefCounted

enum Axis {
	VERTICAL,    ## 纵向列表
	HORIZONTAL,  ## 横向标签栏
	GRID,        ## 网格（列数由 columns 决定）
}

## 组所在容器，成员都在它下面（用于判断某个控件是否属于本组）
var root: Control = null
## 组内移动轴
var axis: Axis = Axis.VERTICAL
## 网格列数（仅 Axis.GRID 生效）
var columns: int = 1
## 组内首尾是否环回
var wrap_around: bool = false
## 是否作为 Tab 的一个停靠点
var tab_stop: bool = true

## () -> int：成员数量
var count_fn: Callable = Callable()
## () -> int：当前选中下标，-1 表示无
var index_fn: Callable = Callable()
## () -> Dictionary：可聚焦控件 → 下标
var map_fn: Callable = Callable()
## (i) -> Control：取成员，取不到返回 null
var member_fn: Callable = Callable()
## (i) -> void：选中并让该成员获得焦点
var select_fn: Callable = Callable()

## 成员表（控件 → 下标），由 refresh 重建
var _map: Dictionary = {}
## 成员表是否非空：没有可聚焦成员时组退化为普通容器（如设置列表的行只是标签）
var _has_members: bool = false
## 是否已建过成员表
var _refreshed: bool = false

## 重建成员表。FocusRouter 每次导航前调用一次
func refresh() -> void:
	_map = map_fn.call() if map_fn.is_valid() else {}
	_has_members = not _map.is_empty()
	_refreshed = true

func is_active() -> bool:
	if not _refreshed:
		refresh()
	if not _has_members:
		return false
	if root == null or not is_instance_valid(root):
		return false
	return root.is_visible_in_tree()

func count() -> int:
	if not count_fn.is_valid():
		return 0
	return maxi(int(count_fn.call()), 0)

func get_index() -> int:
	if not index_fn.is_valid():
		return -1
	return int(index_fn.call())

## 控件是否属于组内成员。非成员（如设置行右侧的值控件）不受组的轴向规则约束，
## 方向键交给几何搜索处理
func index_of(ctl: Control) -> int:
	return int(_map.get(ctl, -1))

func contains(ctl: Control) -> bool:
	if ctl == null or root == null or not is_instance_valid(root):
		return false
	return root == ctl or root.is_ancestor_of(ctl)

## 方向键在组内移动。返回 false 表示已到边界或焦点不在组的当前项上，交由上层继续找目标
func handle_arrow(side: int, focused: Control) -> bool:
	if not is_active() or focused == null or not select_fn.is_valid():
		return false
	var n := count()
	var idx := get_index()
	if n <= 0 or idx < 0 or idx >= n:
		return false
	# 焦点不在组当前项上时不接管：这类控件（值输入框等）自己处理方向键更合适
	if not contains(focused) or index_of(focused) != idx:
		return false

	var step := 0
	match axis:
		Axis.VERTICAL:
			if side == SIDE_TOP:
				step = -1
			elif side == SIDE_BOTTOM:
				step = 1
			else:
				return false
		Axis.HORIZONTAL:
			if side == SIDE_LEFT:
				step = -1
			elif side == SIDE_RIGHT:
				step = 1
			else:
				return false
		Axis.GRID:
			match side:
				SIDE_LEFT:
					step = -1
				SIDE_RIGHT:
					step = 1
				SIDE_TOP:
					step = -maxi(columns, 1)
				SIDE_BOTTOM:
					step = maxi(columns, 1)

	if step == 0:
		return false
	var gridded := axis == Axis.GRID and maxi(columns, 1) > 1
	var horizontal_move := side == SIDE_LEFT or side == SIDE_RIGHT
	var next := idx + step
	if next < 0 or next >= n:
		# 多列网格的左右到行首 / 行尾就停住：跨行交给上下键，
		# 否则会顺着几何搜索跳到页面上方的标签栏
		if gridded and horizontal_move:
			return true
		if not wrap_around:
			return false
		next = posmod(next, n)
	elif gridded and horizontal_move:
		var cols := maxi(columns, 1)
		if int(next / float(cols)) != int(idx / float(cols)):
			return true
	select_fn.call(next)
	return true

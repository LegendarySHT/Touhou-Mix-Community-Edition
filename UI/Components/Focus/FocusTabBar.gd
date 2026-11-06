## 焦点标签栏：页面内的标签页对 Tab 键的响应
##
## 注册之后，焦点落在本页时按 Tab / Shift+Tab 直接切到下一页标签，
## 页内控件的移动交给方向键；没有标签栏的页面仍按停靠点顺序遍历。
class_name FocusTabBar
extends RefCounted

## 标签按钮所在容器
var root: Control = null
## 本标签栏控制的页面根（用于判断焦点是否属于本页）
var page_root: Control = null

## () -> Array：可见标签按钮，按显示顺序
var buttons_fn: Callable = Callable()
## () -> int：当前页下标
var current_fn: Callable = Callable()
## (i) -> void：切到第 i 页
var select_fn: Callable = Callable()

## 是否首尾环回
var wrap_around: bool = true
## 只在焦点位于本标签栏内部时生效。
## 面板 / 侧栏这类不属于当前页面的标签栏要置 true：否则焦点在页面主体时
## Tab 会被它抢走，切到面板里的另一页去。
var only_when_focused: bool = false

func buttons() -> Array:
	if not buttons_fn.is_valid():
		return []
	return buttons_fn.call()

func is_available() -> bool:
	if not (root != null and is_instance_valid(root) and root.is_visible_in_tree()):
		return false
	if page_root != null and is_instance_valid(page_root) and not page_root.is_visible_in_tree():
		return false
	return not buttons().is_empty()

## 本页焦点判定：焦点在标签按钮上或在页面内容里
func owns(ctl: Control) -> bool:
	if ctl == null:
		return false
	if root != null and is_instance_valid(root) and (root == ctl or root.is_ancestor_of(ctl)):
		return true
	if page_root != null and is_instance_valid(page_root) and (page_root == ctl or page_root.is_ancestor_of(ctl)):
		return true
	return false

## 切到相邻标签并返回目标下标；不可切换时返回 -1
func step(dir: int) -> int:
	var list := buttons()
	var n := list.size()
	if n <= 0:
		return -1
	var cur := int(current_fn.call()) if current_fn.is_valid() else 0
	cur = clampi(cur, 0, n - 1)
	var next := cur + dir
	if next < 0 or next >= n:
		if not wrap_around:
			return -1
		next = posmod(next, n)
	if next == cur:
		return -1
	return next

## 切页并把焦点放到目标标签按钮上
func focus_index(i: int) -> void:
	var list := buttons()
	if i < 0 or i >= list.size():
		return
	if select_fn.is_valid():
		select_fn.call(i)
	var btn := list[i] as Control
	if btn != null and is_instance_valid(btn):
		btn.grab_focus.call_deferred()

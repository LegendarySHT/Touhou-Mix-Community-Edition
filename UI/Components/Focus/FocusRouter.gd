## 焦点路由：统一接管方向键、Tab 与页面焦点落点
##
## 把「焦点该去哪」从场景里的邻居路径改成运行时推导：
## - 方向键：先问当前控件所属的 FocusGroup；组到边界后按矩形几何找最近的可聚焦控件；
## - Tab：当前页有标签栏就切换标签页，否则按「停靠点」顺序遍历，一个焦点组只算一站；
## - 落点：页面切换或焦点失效时，用视图注册的默认落点；都没注册就取阅读顺序第一个控件。
##
## 只在键盘/手柄操作时接管：鼠标/触摸点击后不主动抢焦点，避免触摸操作冒出焦点描边。
## 所有注册一律传节点引用，不存节点路径；目标缺失时只打警告，不会静默失效。
extends Node

## 候选控件的最小尺寸，过滤零尺寸的占位节点
const MIN_FOCUS_SIZE := 4.0
## 交叉方向错位的惩罚系数：越大越偏好同一行 / 同一列的候选
const CROSS_PENALTY := 3.0

## 方向与输入动作的对应
const SIDE_ACTIONS := {
	SIDE_TOP: &"ui_up",
	SIDE_BOTTOM: &"ui_down",
	SIDE_LEFT: &"ui_left",
	SIDE_RIGHT: &"ui_right",
}

## 焦点组注册表
var _groups: Array[FocusGroup] = []
## 标签栏注册表
var _tab_bars: Array[FocusTabBar] = []
## 页面默认落点提供者：{owner: Control, provider: Callable, priority: int}
var _defaults: Array[Dictionary] = []
## 模态层（打开时要独占焦点的面板 / 弹窗）：只导航其子树
var _layers: Array[Control] = []
## 与 _layers 一一对应的来源焦点，关闭时还原
var _layer_restore: Array[Control] = []

## 最近一次输入是否为键盘 / 手柄
var _keyboard_mode: bool = false
## 暂停接管（按键录入等需要独占输入的场景）
var _capture_disabled: bool = false
## 弹窗打开前持有焦点的控件，关闭后还原
var _restore_focus: Control = null
## 最近一次获得过焦点的控件（原控件已失效时兜底）
var _last_focus: Control = null

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_viewport().gui_focus_changed.connect(_on_focus_changed)
	if UiStatMGR:
		UiStatMGR.state_changed.connect(_on_state_changed)
	# PopupWindow 是 Main 的子节点，_ready 晚于本节点
	call_deferred("_bind_popup_window")

# ══════════════════════════════════════════════════════
#  注册接口
# ══════════════════════════════════════════════════════

func register_group(group: FocusGroup) -> void:
	if group == null or _groups.has(group):
		return
	_groups.append(group)

func unregister_group(group: FocusGroup) -> void:
	_groups.erase(group)

func register_tab_bar(bar: FocusTabBar) -> void:
	if bar == null or _tab_bars.has(bar):
		return
	_tab_bars.append(bar)

func unregister_tab_bar(bar: FocusTabBar) -> void:
	_tab_bars.erase(bar)

## 注册页面默认落点。owner_ctl 只用于查询可见性：页面隐藏时它的落点不参与竞争。
## provider 返回 null 表示「本页不指定」，会继续问下一优先级，最后退化为阅读顺序第一项。
## 优先级数值大者优先；同级时取树里更深（更具体）的那个。
func register_default(owner_ctl: Control, provider: Callable, priority: int = 0) -> void:
	if owner_ctl == null or not provider.is_valid():
		return
	unregister_default(owner_ctl)
	_defaults.append({"owner": owner_ctl, "provider": provider, "priority": priority})

func unregister_default(owner_ctl: Control) -> void:
	for i in range(_defaults.size() - 1, -1, -1):
		if _defaults[i].owner == owner_ctl:
			_defaults.remove_at(i)

## 暂停 / 恢复接管。按键录入等要独占键盘的场景在开始前关掉，结束后打开
func set_capture_disabled(disabled: bool) -> void:
	_capture_disabled = disabled

## 压入模态层：面板打开期间方向键 / Tab 只在它内部走，不会跑回背后的页面。
## default_focus 为空时退化为「层内第一个停靠点」。
func push_layer(root: Control, default_focus: Callable = Callable()) -> void:
	if root == null or not is_instance_valid(root) or _layers.has(root):
		return
	_layers.append(root)
	_layer_restore.append(focused_control())
	if default_focus.is_valid():
		_focus_layer_default.call_deferred(root, default_focus)
	else:
		request_default_focus.call_deferred()

## 弹出模态层：焦点还给打开它之前的控件
func pop_layer(root: Control) -> void:
	var index := _layers.find(root)
	if index < 0:
		return
	_layers.remove_at(index)
	var restore: Control = null
	if index < _layer_restore.size():
		restore = _layer_restore[index]
		_layer_restore.remove_at(index)
	if restore != null and is_instance_valid(restore) and _is_focusable(restore):
		restore.call_deferred(&"grab_focus")
	else:
		request_default_focus.call_deferred()

func _focus_layer_default(root: Control, provider: Callable) -> void:
	if not _layers.has(root):
		return
	var ctl = provider.call()
	if ctl is Control and _is_focusable(ctl) and _in_layer(ctl):
		(ctl as Control).grab_focus()
		return
	request_default_focus()

## 当前生效的模态层：栈顶且仍然可见。已释放的层顺手剔除（关闭动画期间不可见的层只跳过）
func _active_layer() -> Control:
	for i in range(_layers.size() - 1, -1, -1):
		var layer := _layers[i]
		if layer == null or not is_instance_valid(layer):
			_layers.remove_at(i)
			if i < _layer_restore.size():
				_layer_restore.remove_at(i)
			continue
		if not layer.is_visible_in_tree():
			continue
		return layer
	return null

func _in_layer(ctl: Control) -> bool:
	var layer := _active_layer()
	if layer == null:
		return true
	return layer == ctl or layer.is_ancestor_of(ctl)

func is_capture_disabled() -> bool:
	return _capture_disabled

## 最近一次输入是否为键盘 / 手柄（触摸 / 鼠标操作为 false）
func is_keyboard_mode() -> bool:
	return _keyboard_mode

## 当前焦点控件；无焦点、已隐藏或不可聚焦时返回 null
func focused_control() -> Control:
	if not is_inside_tree():
		return null
	var ctl := get_viewport().gui_get_focus_owner()
	if ctl == null or not is_instance_valid(ctl):
		return null
	if not ctl.is_visible_in_tree() or ctl.focus_mode == Control.FOCUS_NONE:
		return null
	return ctl

## 指定子树里第一个可聚焦控件（弹窗等需要自己决定初始落点时用）
func first_focusable_in(root: Node) -> Control:
	if root == null or not is_instance_valid(root):
		return null
	for child in root.get_children():
		if child is Control:
			var ctl := child as Control
			if _is_focusable(ctl):
				return ctl
		var deep := first_focusable_in(child)
		if deep != null:
			return deep
	return null

## 把焦点落到当前页的默认位置。返回是否发生了移动
func request_default_focus() -> bool:
	_refresh_registries()
	for entry in _sorted_defaults():
		var ctl = (entry.provider as Callable).call()
		if ctl is Control and _is_focusable(ctl) and _in_layer(ctl):
			(ctl as Control).grab_focus()
			return true
	for stop in _collect_stops(_layer_root()):
		if _focus_stop(stop):
			return true
	return false

# ══════════════════════════════════════════════════════
#  输入
# ══════════════════════════════════════════════════════

func _input(event: InputEvent) -> void:
	_track_input_mode(event)
	if _capture_disabled or not _keyboard_mode:
		return
	if not (event is InputEventKey or event is InputEventJoypadButton or event is InputEventJoypadMotion):
		return
	if UiStatMGR and UiStatMGR.current_state == UiStatMGR.UIState.PLAY_VIEW:
		return
	# 弹窗是独立窗口，弹窗内的焦点由弹窗自己的视口处理
	var popup := PopupWindow.instance
	if popup != null and is_instance_valid(popup) and popup.visible:
		return

	var focused := focused_control()

	# 先判上一页：带 Shift 的 Tab 会同时命中两个动作
	if event.is_action_pressed(&"ui_focus_prev", true, true):
		if _tab_step(-1):
			_accept()
		return
	if event.is_action_pressed(&"ui_focus_next", true, true):
		if _tab_step(1):
			_accept()
		return
	# 文本输入、滑条自己用方向键，这里不接管
	for side in SIDE_ACTIONS:
		if not event.is_action_pressed(SIDE_ACTIONS[side], true, true):
			continue
		if _self_handles_nav(focused, side):
			return
		if _navigate(focused, side):
			_accept()
		return

func _accept() -> void:
	get_viewport().set_input_as_handled()

## 记录输入来源：触摸/鼠标操作时不主动接管，避免冒出焦点描边
func _track_input_mode(event: InputEvent) -> void:
	if event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo:
			_keyboard_mode = true
	elif event is InputEventJoypadButton:
		if (event as InputEventJoypadButton).pressed:
			_keyboard_mode = true
	elif event is InputEventJoypadMotion:
		if absf((event as InputEventJoypadMotion).axis_value) > 0.5:
			_keyboard_mode = true
	elif event is InputEventMouseButton:
		if (event as InputEventMouseButton).pressed:
			_keyboard_mode = false
	elif event is InputEventScreenTouch:
		if (event as InputEventScreenTouch).pressed:
			_keyboard_mode = false

## 控件自己处理某个方向键的情况：文本输入的左右属于光标（到边界再交回导航），滑条属于调值
func _self_handles_nav(ctl: Control, side: int) -> bool:
	if ctl == null:
		return false
	var horizontal: bool = side == SIDE_LEFT or side == SIDE_RIGHT
	if ctl is LineEdit:
		if not horizontal:
			return false
		var edit := ctl as LineEdit
		if edit.has_selection():
			return true
		# 光标已经在头/尾时继续往同一方向按键，交给导航离开输入框
		if side == SIDE_LEFT:
			return edit.caret_column > 0
		return edit.caret_column < edit.text.length()
	if ctl is TextEdit:
		return true
	if ctl is Range or ctl is TabBar:
		return true
	var node: Node = ctl
	while node != null:
		if node.has_meta(&"focus_nav_self"):
			return true
		node = node.get_parent()
	return false

func _navigate(focused: Control, side: int) -> bool:
	_refresh_registries()
	if focused == null:
		return request_default_focus()
	var group := _group_of(focused)
	if group != null and group.handle_arrow(side, focused):
		return true
	var target := _find_neighbor(focused, side)
	if target != null:
		target.grab_focus()
		return true
	# 组内到边界也必须吞掉按键，否则引擎自带的几何导航会把焦点丢到组里任意一项
	return group != null

## Tab / Shift+Tab：有标签栏就切页，否则按停靠点顺序走
func _tab_step(dir: int) -> bool:
	_refresh_registries()
	var focused := focused_control()
	var bar := _tab_bar_for(focused)
	if bar != null:
		var next := bar.step(dir)
		if next >= 0:
			bar.focus_index(next)
			return true
	if focused == null:
		return request_default_focus()
	var stops := _collect_stops(_layer_root())
	if stops.is_empty():
		return false
	var cur := _stop_index(focused, stops)
	# 焦点不在任何停靠点上（如组内非成员控件）：从第一个停靠点重新开始
	if cur < 0:
		return _focus_stop(stops[0])
	return _focus_stop(stops[posmod(cur + dir, stops.size())])

# ══════════════════════════════════════════════════════
#  导航计算
# ══════════════════════════════════════════════════════

## 按当前页面找标签栏：优先包含焦点的那个（取最内层），
## 焦点不在任何标签页里时取最外层的可见标签栏（角落按钮等外围控件）。
## 模态层打开时只认层内的标签栏，否则 Tab 会切到背后页面的标签页上。
func _tab_bar_for(focused: Control) -> FocusTabBar:
	var layer := _active_layer()
	var best: FocusTabBar = null
	var best_depth := -1
	if focused != null:
		for bar in _tab_bars:
			if not bar.is_available() or not _bar_in_layer(bar, layer) or not bar.owns(focused):
				continue
			var depth := _depth(bar.page_root)
			if depth > best_depth:
				best = bar
				best_depth = depth
		if best != null:
			return best
	best_depth = -1
	for bar in _tab_bars:
		if not bar.is_available() or not _bar_in_layer(bar, layer):
			continue
		# 面板内的标签栏不参与「外围兜底」：焦点不在它里面时不该被它切页
		if bar.only_when_focused:
			continue
		var depth := _depth(bar.page_root)
		if best == null or depth < best_depth:
			best = bar
			best_depth = depth
	return best

func _bar_in_layer(bar: FocusTabBar, layer: Control) -> bool:
	if layer == null:
		return true
	for node in [bar.root, bar.page_root]:
		if node != null and is_instance_valid(node) and (node == layer or layer.is_ancestor_of(node)):
			return true
	return false

## 焦点所属的焦点组：取包含它的最内层（树里最深）那个
func _group_of(ctl: Control) -> FocusGroup:
	var best: FocusGroup = null
	var best_depth := -1
	for group in _groups:
		if not group.is_active() or not group.contains(ctl):
			continue
		var depth := _depth(group.root)
		if depth > best_depth:
			best = group
			best_depth = depth
	return best

## 几何搜索：沿方向找最近的候选控件。
## 先要求候选整体位于该方向（避免同一行/同一列的控件互相抢占），找不到再按中心点近似判断。
func _find_neighbor(from: Control, side: int) -> Control:
	var root := _layer_root()
	if root == null:
		return null
	# 斜向视图统一换到 SkewC 的本地坐标再比较，避免斜切把左右判定带偏
	var space_xf := _nav_transform()
	var from_rect := _rect_of(from, space_xf)
	var candidates := _collect_candidates(root, from)
	var best := _best_in_direction(from_rect, candidates, space_xf, side, true)
	if best == null:
		best = _best_in_direction(from_rect, candidates, space_xf, side, false)
	return best

func _best_in_direction(from_rect: Rect2, candidates: Array[Control],
		space_xf: Transform2D, side: int, strict: bool) -> Control:
	var best: Control = null
	var best_score := INF
	for ctl in candidates:
		var score := _side_score(from_rect, _rect_of(ctl, space_xf), side, strict)
		if score < 0.0:
			continue
		if score < best_score:
			best_score = score
			best = ctl
	return best

## 把全局坐标换算到导航坐标系（SkewC 的逆变换）；没有斜向视图时就是全局坐标
func _nav_transform() -> Transform2D:
	var space := GlobalNodes.skew_c
	if space != null and is_instance_valid(space) and space.is_inside_tree():
		return space.get_global_transform().affine_inverse()
	return Transform2D.IDENTITY

func _rect_of(ctl: Control, space_xf: Transform2D) -> Rect2:
	if not is_instance_valid(ctl) or not ctl.is_inside_tree():
		return Rect2()
	var xf := space_xf * ctl.get_global_transform()
	var s := ctl.size
	# 控件自身带旋转 / 缩放（如翻转的箭头按钮）时取四角包围盒
	var p0 := xf * Vector2.ZERO
	var p1 := xf * Vector2(s.x, 0.0)
	var p2 := xf * Vector2(0.0, s.y)
	var p3 := xf * s
	var low := p0.min(p1).min(p2).min(p3)
	var high := p0.max(p1).max(p2).max(p3)
	return Rect2(low, high - low)

func _collect_candidates(root: Node, from: Control) -> Array[Control]:
	var out: Array[Control] = []
	_walk_candidates(root, from, out)
	return out

func _walk_candidates(node: Node, from: Control, out: Array[Control]) -> void:
	for child in node.get_children():
		# 独立窗口（弹窗）自成视口，不参与主窗口的焦点几何
		if child is Window:
			continue
		if child is Control and _is_candidate(child as Control, from):
			out.append(child as Control)
		_walk_candidates(child, from, out)

func _is_candidate(ctl: Control, from: Control) -> bool:
	if ctl == from or not _is_focusable(ctl):
		return false
	# 祖先 / 后代之间不互相竞争方向
	if ctl.is_ancestor_of(from) or from.is_ancestor_of(ctl):
		return false
	# 焦点组内部只认组成员：卡片里的下载按钮这类子控件不单独参与方向键；
	# 组还没有当前项时允许所有成员参与，让几何搜索挑最近的那个
	var group := _group_of(ctl)
	if group != null:
		var index := group.index_of(ctl)
		if index < 0:
			return false
		var current := group.get_index()
		if current >= 0 and index != current:
			return false
	return true

## 候选打分：沿方向的距离 + 交叉方向错位惩罚；不在该方向返回 -1
func _side_score(from: Rect2, to: Rect2, side: int, strict: bool) -> float:
	var horizontal: bool = side == SIDE_LEFT or side == SIDE_RIGHT
	var forward: bool = side == SIDE_RIGHT or side == SIDE_BOTTOM
	var axis: int = 0 if horizontal else 1
	var cross: int = 1 - axis

	var from_near := from.position[axis]
	var from_far := from_near + from.size[axis]
	var to_near := to.position[axis]
	var to_far := to_near + to.size[axis]

	if strict:
		# 候选整体要在运动轴的另一侧（1px 容差）：同行/同列的控件不算「在上下左右」
		if forward:
			if to_near < from_far - 1.0:
				return -1.0
		else:
			if to_far > from_near + 1.0:
				return -1.0
	else:
		var from_center := from_near + from.size[axis] * 0.5
		var to_center := to_near + to.size[axis] * 0.5
		var delta := to_center - from_center
		if forward:
			if delta <= 0.5:
				return -1.0
		else:
			if delta >= -0.5:
				return -1.0

	var along := maxf(0.0, to_near - from_far) if forward else maxf(0.0, from_near - to_far)

	var from_cross_near := from.position[cross]
	var from_cross_far := from.position[cross] + from.size[cross]
	var to_cross_near := to.position[cross]
	var to_cross_far := to.position[cross] + to.size[cross]
	var cross_gap := maxf(0.0, maxf(from_cross_near - to_cross_far, to_cross_near - from_cross_far))

	# 平分时取中心更近的那个（相邻项优先于跨过整块区域的远端控件）
	var center_gap := (to.get_center() - from.get_center()).length() * 0.001
	return along + cross_gap * CROSS_PENALTY + center_gap

## 停靠点列表：一个焦点组算一站，组内部不再逐个展开
func _collect_stops(root: Node) -> Array:
	var out: Array = []
	if root != null:
		_walk_stops(root, out)
	return out

func _walk_stops(node: Node, out: Array) -> void:
	for child in node.get_children():
		# 独立窗口（弹窗）自成视口，弹窗内的停靠点由弹窗自己处理
		if child is Window:
			continue
		if child is Control:
			var ctl := child as Control
			var group := _group_root_at(ctl)
			if group != null:
				if group.tab_stop and group.is_active():
					out.append(group)
					continue
			if _is_tab_stop(ctl):
				out.append(ctl)
		_walk_stops(child, out)

func _group_root_at(ctl: Control) -> FocusGroup:
	for group in _groups:
		if group.root == ctl and group.is_active():
			return group
	return null

func _stop_index(focused: Control, stops: Array) -> int:
	for i in stops.size():
		var stop = stops[i]
		if stop is FocusGroup:
			if (stop as FocusGroup).contains(focused):
				return i
		elif stop == focused:
			return i
	return -1

func _focus_stop(stop) -> bool:
	if stop is FocusGroup:
		var group: FocusGroup = stop
		var index := group.get_index()
		if index < 0 or index >= group.count():
			index = 0
		if index >= group.count() or not group.select_fn.is_valid():
			return false
		group.select_fn.call(index)
		return true
	var ctl := stop as Control
	if ctl == null or not is_instance_valid(ctl):
		return false
	ctl.grab_focus()
	return true

## 焦点是否有效（在树、可见、允许聚焦、有实际尺寸）
func _is_focusable(ctl: Control) -> bool:
	if ctl == null or not is_instance_valid(ctl):
		return false
	if ctl.focus_mode != Control.FOCUS_ALL:
		return false
	if not ctl.is_visible_in_tree():
		return false
	if ctl is BaseButton and ctl.disabled:
		return false
	var rect := ctl.get_global_rect()
	return rect.size.x >= MIN_FOCUS_SIZE and rect.size.y >= MIN_FOCUS_SIZE

func _is_tab_stop(ctl: Control) -> bool:
	if not _is_focusable(ctl):
		return false
	# 角落导航按钮这类全局控件只走方向键，不占 Tab 循环
	if ctl.has_meta(&"focus_no_tab"):
		return false
	# 组成员由所属组统一代表，不单独作为停靠点
	return _group_of(ctl) == null

## 导航层：有模态层时以它子树为界，否则以 Main 为界。
## 各页面靠自己隐藏退出竞争，不需要逐页登记。
func _layer_root() -> Node:
	var layer := _active_layer()
	if layer != null:
		return layer
	if GlobalNodes.main != null and is_instance_valid(GlobalNodes.main):
		return GlobalNodes.main
	return get_tree().current_scene

func _depth(node: Node) -> int:
	if node == null or not is_instance_valid(node):
		return -1
	return node.get_path().get_name_count()

# ══════════════════════════════════════════════════════
#  生命周期
# ══════════════════════════════════════════════════════

## 清掉已释放的注册项并重建成员表（池项换绑、列表重建都在这一步反映出来）
func _refresh_registries() -> void:
	for i in range(_groups.size() - 1, -1, -1):
		var group := _groups[i]
		if group.root == null or not is_instance_valid(group.root):
			_groups.remove_at(i)
	for group in _groups:
		group.refresh()
	for i in range(_tab_bars.size() - 1, -1, -1):
		var bar := _tab_bars[i]
		if bar.root == null or not is_instance_valid(bar.root):
			_tab_bars.remove_at(i)
	for i in range(_defaults.size() - 1, -1, -1):
		var owner_ctl: Control = _defaults[i].owner
		if owner_ctl == null or not is_instance_valid(owner_ctl):
			_defaults.remove_at(i)

## 默认落点按「优先级降序、同级按树的深度降序」排序
func _sorted_defaults() -> Array:
	var out: Array = []
	for entry in _defaults:
		var owner_ctl: Control = entry.owner
		if owner_ctl == null or not is_instance_valid(owner_ctl) or not owner_ctl.is_visible_in_tree():
			continue
		out.append(entry)
	out.sort_custom(func(a, b) -> bool:
		if a.priority != b.priority:
			return a.priority > b.priority
		return _depth(a.owner) > _depth(b.owner)
	)
	return out

func _on_focus_changed(ctl: Control) -> void:
	if ctl != null and is_instance_valid(ctl):
		_last_focus = ctl

func _on_state_changed(_old_state, _new_state) -> void:
	# 视图在同一个信号的其它订阅者里才切换可见性，延后一帧再找落点
	call_deferred(&"_apply_default_focus_deferred")

func _apply_default_focus_deferred() -> void:
	if not _keyboard_mode or _capture_disabled:
		return
	# 焦点还留在页面上就不动它（例如从弹窗关闭回来）
	if focused_control() != null:
		return
	request_default_focus()

func _bind_popup_window() -> void:
	var popup := PopupWindow.instance
	if popup == null or not is_instance_valid(popup):
		return
	if not popup.about_to_popup.is_connected(_on_popup_about_to_show):
		popup.about_to_popup.connect(_on_popup_about_to_show)
	if not popup.window_close.is_connected(_on_popup_window_close):
		popup.window_close.connect(_on_popup_window_close)

func _on_popup_about_to_show() -> void:
	if not _keyboard_mode:
		return
	if _restore_focus == null:
		_restore_focus = focused_control()

func _on_popup_window_close() -> void:
	var target := _restore_focus
	_restore_focus = null
	if target == null or not is_instance_valid(target):
		target = _last_focus
	if target == null or not is_instance_valid(target):
		return
	if target.is_visible_in_tree() and target.focus_mode != Control.FOCUS_NONE:
		target.call_deferred(&"grab_focus")

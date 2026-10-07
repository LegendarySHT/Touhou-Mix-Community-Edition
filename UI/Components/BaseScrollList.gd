## 可滚动列表的基类
## 处理通用的滚动、吸附、虚拟化等功能
## 注：项目启用了"鼠标模拟触摸"，Godot ScrollContainer 自带惯性滚动，无需手动处理
extends ScrollContainer

class_name BaseScrollList

enum ScrollControlState {
	IDLE,              # 空闲 —— 无滚动活动
	USER_DRAG,         # 用户拖拽列表内容（含释放后的惯性阶段）
	SCROLLBAR_DRAG,    # 用户拖拽滚动条
	SNAP_ANIMATION,    # 吸附动画播放中
}

## 容器（放置列表项的VBox或HBox）
@export var container_path: NodePath
@onready var container: Container = get_node(container_path) if container_path else null

## 列表项场景（create_and_add_item 逐个 instantiate）
@export var list_item_class: Variant
@onready var item_scene: PackedScene = load(list_item_class)

## 主题样式句柄（惰性创建）：仅需定位列表项共享内联样式时使用。
## tscn 内联子资源默认跨实例共享（非 resource_local_to_scene），改一句柄即同步所有列表项，
## 无需逐项上色（替代旧"模板实例 + duplicate 继承样式"方案）
var _theme_handle: Control = null
func get_theme_handle() -> Control:
	if _theme_handle == null and item_scene:
		_theme_handle = item_scene.instantiate() as Control
	return _theme_handle

## 工作状态，当不处于该状态时停止处理操作
var work_state: UIStateManager.UIState = UIStateManager.UIState.NONE

## 列表项 _process 是否已启用（缓存 _on_state_changed 计算结果，避免重复遍历）
var _items_process_enabled: bool = true

## 正在拖动滚动条（内部状态，对外通过 scroll_control_state 统一查询）
var _is_dragging_bar: bool = false

## 正在拖拽列表内容（ScrollContainer 原生拖拽会话进行中，含释放后的惯性阶段）
## 拖拽期间即使速度为 0（用户按住停住看字）也不允许触发吸附，fix #72
var _drag_scrolling: bool = false

## 手指/鼠标是否正按在列表内容上（含尚未越过死区的按住阶段）
## 原生 scroll_started 只在越过死区后发出，若只靠它，用户"按住停住看字"且未越过
## 死区时吸附仍会触发；因此按下即置位、松开即清除，fix #72
var _pointer_pressed: bool = false

## 是否已观察到本次指针按下后的松开（用于原生会话兜底）
## Godot 原生 drag 会话的 scroll_ended 依赖松手事件送达 ScrollContainer；
## 若松手被子控件吞掉、或因松手时 drag_speed 非零进入惯性减速，scroll_ended 可能
## 迟迟不来甚至永远不来，导致 _drag_scrolling 永久卡死、吸附不再恢复（fix #72 跟进）。
## 因此：指针已松开 + 滚动已稳定（0.15s 无位移）时，即使 scroll_ended 未发出，
## 也视为原生会话已结束，解除 _drag_scrolling。
var _pointer_release_observed: bool = false

## 滚动控制状态 —— 统一查询当前是谁在控制滚动位置
## IDLE=空闲, USER_DRAG=拖拽列表内容, SCROLLBAR_DRAG=拖拽滚动条, SNAP_ANIMATION=吸附动画
var scroll_control_state: ScrollControlState:
	get:
		if _drag_scrolling:
			return ScrollControlState.USER_DRAG
		if _is_dragging_bar:
			return ScrollControlState.SCROLLBAR_DRAG
		if _snap_active:
			return ScrollControlState.SNAP_ANIMATION
		return ScrollControlState.IDLE

## 所有列表项
var list_items: Array[ListItemBase] = []

## 选中项变化信号（new_index = -1 表示取消选中/清空）
## 由 selected_item 属性 setter 统一发出，覆盖 select_item / 列表项按钮直改 / 展开收起等所有路径
signal selection_changed(new_index: int)

## 选中的项，或者snap的目标项
var selected_item: int = -1:
	set(v):
		if selected_item == v:
			return
		selected_item = v
		selection_changed.emit(v)

## 本列表"工作状态"对应的"直接相邻状态"集合
## 切到不在此集合的状态时，释放所有列表项封面
## 由子类在 _ready 中通过 set_adjacent_states 设置
var _adjacent_states: Array[UIStateManager.UIState] = []

## snap相关
var need_snap: bool = false # 吸附请求标志
var snap_offset_y: float = 500 # 吸附偏移量
var _snap_active: bool = false # 吸附动画进行中
var _snap_stable_frames: int = 0 # 连续稳定帧计数（防止布局抖动导致提前收敛）
var _snap_clamped_frames: int = 0 # 连续无法移动帧计数（滚动到 0/max 边界时结束吸附，避免卡死）

## 滚动速度追踪（像素/秒）—— 替代手动拖拽检测
var _prev_scroll_vertical: int = 0
var _scroll_speed: float = 0.0
const SCROLL_SPEED_COLLAPSE: float = 80.0   # 超过此速度 → 收起展开项
const SCROLL_SPEED_SNAP: float = 30.0       # 低于此速度 → 允许吸附

## 滚动稳定性检测 —— 速度降到阈值以下 + 短暂等待后允许吸附
var _scroll_stable: bool = true
var _scroll_stable_timer: Timer = null

func _ready() -> void:
	if container == null:
		push_error("Container not found at path: %s" % container_path)
		return

	# 创建滚动稳定性计时器（速度降到阈值以下 0.15 秒后允许吸附）
	_scroll_stable_timer = Timer.new()
	_scroll_stable_timer.wait_time = 0.15
	_scroll_stable_timer.one_shot = true
	_scroll_stable_timer.timeout.connect(_on_scroll_stable)
	add_child(_scroll_stable_timer)

	UiStatMGR.state_changed.connect(_on_state_changed)
	_on_state_changed(UIStateManager.UIState.NONE, UiStatMGR.current_state)

	# 原生拖拽会话跟踪：scroll_started/scroll_ended 只在"拖拽式滚动"会话中发出
	# （滚轮、滚动条拖拽不会触发；代码赋值 scroll_vertical 会取消拖拽并发出 scroll_ended），
	# 正好用于区分"用户按住停住"与"滚动自然结束"
	scroll_started.connect(_on_drag_scroll_started)
	scroll_ended.connect(_on_drag_scroll_ended)
	gui_input.connect(_on_gui_input_event)

	get_v_scroll_bar().gui_input.connect(_on_v_scrollbar_gui_input)
	get_v_scroll_bar().value_changed.connect(_on_v_scrollbar_changed)
	get_v_scroll_bar().custom_minimum_size.x = 18

## 用户拖拽开始（越过死区、列表开始跟随手指/鼠标移动）
func _on_drag_scroll_started() -> void:
	_drag_scrolling = true
	# 立即终止进行中的吸附动画，避免吸附与手指拖拽互相抢滚动位置
	if _snap_active:
		_snap_active = false
		_snap_stable_frames = 0
		_snap_clamped_frames = 0
	# 拖拽开始即清除选中，保证松手后 AlbumView 会重新请求吸附。
	# 之前只靠"滚动速度 > 阈值"触发 reset_selection，慢拖/小拖时旧选中项残留，
	# AlbumView._process 因 selected_item != -1 不再置 need_snap，导致松手后不吸附
	# （fix #72 跟进）。
	if has_method("reset_selection"):
		call("reset_selection")

## 拖拽会话结束（手指松开；若带惯性则等惯性自然停止后）
func _on_drag_scroll_ended() -> void:
	_drag_scrolling = false

## 按住/松开列表内容期间更新指针按下状态（含未越过死区的阶段），fix #72
func _on_gui_input_event(event: InputEvent) -> void:
	if work_state != UiStatMGR.current_state:
		return
	if work_state in [UIStateManager.UIState.TRACK_VIEW, UIStateManager.UIState.SETTINGS_VIEW]:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_pointer_pressed = event.pressed
		_pointer_release_observed = not event.pressed
	elif event is InputEventScreenTouch and event.index == 0:
		_pointer_pressed = event.pressed
		_pointer_release_observed = not event.pressed

func _on_scroll_stable():
	_scroll_stable = true
	# 滚动稳定后，若视区内仍有未加载封面的项，重新触发加载
	# 覆盖"用户快速滚到远处，初次触发未覆盖"的场景
	if _items_process_enabled:
		trigger_cover_chain()

## 外部查询：当前是否正在滚动（用于封面视差等效果）
func is_scrolling() -> bool:
	return not _scroll_stable or _pointer_pressed or _drag_scrolling or _is_dragging_bar or _snap_active

## 当前是否正在播放吸附动画（区别于普通惯性/拖拽滚动）
## 供焦点导航延迟选中判断：只有吸附动画飞向屏幕外远处目标时才需要延迟，
## 普通惯性滚动中按键应立即选中（会取消惯性、开始新吸附）
func is_snapping() -> bool:
	return _snap_active

## 判断指定索引的列表项是否在可视视口内（与视口有可见重叠）
## 供焦点导航延迟选中判断：滚动/吸附中焦点落到屏幕外的项时，
## 等待该项滚入视口再选中，避免把吸附目标反复改到屏幕外
func is_item_visible(index: int) -> bool:
	if index < 0 or index >= list_items.size():
		return false
	var item: Control = list_items[index]
	if not is_instance_valid(item):
		return false
	var list_top := global_position.y
	var list_bottom := global_position.y + size.y
	var item_top := item.global_position.y
	var item_bottom := item.global_position.y + item.size.y
	return item_top < list_bottom and item_bottom > list_top

## 把焦点拉回吸附项：
## 吸附飞行中（目标还没滚进视口）Godot 自动焦点导航（钳制在 ScrollContainer 可见区域，
## 见引擎 control.cpp 的 _window_find_focus_neighbor）会把焦点丢到屏幕内任意可见项；
## 此时 grab_focus 会触发 ScrollContainer 滚动与吸附打架，故仅当吸附目标已进入视口时才拉回。
## 焦点本就在吸附项上时不打扰；焦点在文本输入框（搜索框/输入框，用户在打字）时也不抢。
## 其余情况（焦点漂移到列表内其它项、或停留在其它视图/导航按钮上）都拉回吸附项，
## 保证吸附结束后焦点落在吸附目标上、按键可从吸附项继续导航。
func _grab_focus_to_selected() -> void:
	if selected_item < 0 or selected_item >= list_items.size():
		return
	if not is_item_visible(selected_item):
		return  # 目标还没滚进视口，此时 grab 会触发滚动与吸附打架
	var sel_node := get_selected_node()
	if sel_node == null or not is_instance_valid(sel_node):
		return
	var btn: Control = sel_node.button
	if btn == null or not is_instance_valid(btn):
		return
	var focus_owner := get_viewport().gui_get_focus_owner()
	if focus_owner == btn:
		return
	if focus_owner is LineEdit or focus_owner is TextEdit:
		return  # 用户在搜索框/输入框打字，不抢焦点
	btn.grab_focus()

# 滚动条值变化（scrollbar 自身拖拽时）
func _on_v_scrollbar_changed(_value: float):
	if work_state in [UIStateManager.UIState.ALBUM_VIEW] and _is_dragging_bar:
		call_deferred("reset_selection")

## 设置直接相邻状态（用于判定状态切换时是否释放封面）
## 子类在 _ready 中调用，传入与本视图直接相邻的所有 UIState
func set_adjacent_states(states: Array[UIStateManager.UIState]) -> void:
	_adjacent_states = states

func _on_state_changed(_oldState: UIStateManager.UIState, state: UIStateManager.UIState) -> void:
	var enable:bool = state == work_state

	# TRACK_VIEW 和 SETTINGS_VIEW 不需要 BaseScrollList 的触摸/滚动逻辑
	if work_state in [UIStateManager.UIState.TRACK_VIEW, UIStateManager.UIState.SETTINGS_VIEW]:
		enable = false

	# 离开本视图时清掉拖拽会话标记，避免返回后误以为仍在拖拽
	if state != work_state:
		_drag_scrolling = false
		_pointer_pressed = false
		_pointer_release_observed = false

	# 状态切换封面释放/重载逻辑（仅对设置了邻接状态的列表生效）
	if work_state != UIStateManager.UIState.NONE and not _adjacent_states.is_empty():
		if state == work_state:
			# 回到本视图：触发未加载项的封面加载
			_schedule_cover_reload()
		elif state == UIStateManager.UIState.MIDI_VIEW:
			# 进入 MIDI_VIEW 只显示选中的单个 MIDI，源列表的整页封面已无用，释放一次省内存
			_release_all_covers()
		elif not (state in _adjacent_states):
			# 切到不直接相邻的状态：立即释放所有封面
			_release_all_covers()

	# 后台被 MemoryGC 清过缓存：回本视图时把封面状态一并复位并重载。
	# 只靠上面那一条 _schedule_cover_reload 不够——它走的是视窗对比，
	# 而节点的 _cover_loaded 仍是 true，会被 start_cover_load 直接挡掉。
	if state == work_state and MemoryGC.instance != null and MemoryGC.instance.is_trimmed():
		invalidate_cover_state()

	# 状态未变化时提前返回，避免重复遍历 list_items 和无谓的 set_process 调用
	if enable == _items_process_enabled:
		return

	_items_process_enabled = enable
	set_process(enable)
	set_process_input(enable)

	# 同步停用/恢复列表项的 _process（如 CoverListItemBase 的封面视差）
	# 避免不可见视图的列表项每帧仍跑 _process，造成显著开销
	for item in list_items:
		if is_instance_valid(item):
			item.set_process(enable)

	# 聚焦列表项
	if enable:
		GLogger.info("Node: %s , ProcessMode: %s" % [self.name, enable], "BaseScrollList")

## 释放所有列表项封面（切到不直接相邻状态时调用）
## FileSystemManager 用 WeakRef 缓存 Texture：列表项 texture=null 后引用计数归零，
## Texture 自动 GC，无需手动 clear_cover_cache
func _release_all_covers() -> void:
	for item in list_items:
		if is_instance_valid(item) and item is CoverListItemBase:
			(item as CoverListItemBase).release_cover()

## 外部把全局封面缓存清空后，复位本列表的封面状态并让下次滚入重新加载。
## 必须同时复位 _cover_window 与各节点的 _cover_loaded：后者是"已加载"的纯标记，
## 缓存被清掉它仍为 true，会出现"封面永久空着、滚回去也不重载"。
## 调用方是 Core/MemoryGC.gd（后台内存回收）与视图自身（回前台自愈）。
func invalidate_cover_state() -> void:
	_cover_window = Vector2i(-1, -1)
	for item in list_items:
		if is_instance_valid(item) and item is CoverListItemBase:
			(item as CoverListItemBase).reset_cover_state()
	# 重载放到下一帧：清理发生在主循环暂停的后台，此刻排版/可见性都不可靠；
	# 回前台后这一帧一定是跑得起来的。trigger_cover_chain 内部自带空列表/未启用守卫。
	trigger_cover_chain.call_deferred()

## 只放掉封面纹理引用、不动节点（后台回收用，见 Core/MemoryGC.gd）。
## 与 invalidate_cover_state 同源但更轻：调用方随后可能还要销毁节点，
## 这里保证"引用已经放开"，内存立刻降下来，而不必等 queue_free 的帧末回收。
func release_covers() -> void:
	for item in list_items:
		if is_instance_valid(item) and item is CoverListItemBase:
			(item as CoverListItemBase).release_cover()

## 回到本视图时，延迟一帧触发未加载项的封面加载
## 延迟确保布局已稳定（global_position 有效，_resolve_cover_path 依赖的数据就绪）
func _schedule_cover_reload() -> void:
	call_deferred("trigger_cover_chain")

## 封面分帧入队的批次大小（每批入队后让一帧，避免瞬间锁竞争）
const COVER_BATCH_SIZE := 10

## 封面懒加载：可见区上下额外预加载的项数。
## 构建/滚动时只加载该视窗内的封面，屏幕外项滚进视窗才加载，避免数百项一次性入队导致掉帧。
const COVER_LAZY_EXTEND := 12

## trigger_cover_chain / 懒加载共用的 generation 守卫
## 每次新调用递增，使旧的 in-flight async 循环自然退出
var _cover_chain_generation: int = 0

## 上次已触发加载的封面视窗（闭区间）。与当前视窗一致时跳过，实现"滚到/停在稳定位置时不重复加载"。
var _cover_window: Vector2i = Vector2i(-1, -1)

## 当前需加载封面的视窗（闭区间 [first,last]；空列表返回 (-1,-1)）
func _current_cover_window() -> Vector2i:
	var n := list_items.size()
	if n == 0:
		return Vector2i(-1, -1)
	var top := float(scroll_vertical)
	var bottom := top + float(size.y)
	var first := _bound_visible(top)
	var last := _bound_visible(bottom)
	return Vector2i(maxi(first - COVER_LAZY_EXTEND, 0), mini(last + COVER_LAZY_EXTEND, n - 1))

## 封面懒加载驱动：每帧检查，视窗变化时加载新进入视窗的未加载封面。
## 视窗未变（静止/滑停）时零开销返回，不反复入队。
func _update_cover_window() -> void:
	if not _items_process_enabled or list_items.is_empty():
		return
	var w := _current_cover_window()
	if w == _cover_window:
		return
	_cover_window = w
	_cover_chain_generation += 1
	_load_covers_in_range(w.x, w.y, _cover_chain_generation)

## 立即加载当前视窗内未加载封面的封面（强制：重置视窗使重算必然触发）。
## 供"构建完成 / 回到本视图 / 滚动稳定"等时机显式触发；平时由 _update_cover_window 每帧懒驱动。
func trigger_cover_chain() -> void:
	if not _items_process_enabled or list_items.is_empty():
		return
	_cover_window = Vector2i(-1, -1)  # 强制 _update_cover_window 重算并加载
	_update_cover_window()

## async 实现：对视窗 [first,last] 内的未加载封面项调 start_cover_load
## 被选中项优先同步加载（命中 WeakRef 缓存立即应用，user:// 立即入队 CoverLoader FIFO）
## 分帧入队：每 COVER_BATCH_SIZE 项让一帧，避免瞬间 Mutex 锁竞争
## my_gen 不匹配时静默退出（被新视窗取代）
func _load_covers_in_range(first: int, last: int, my_gen: int) -> void:
	if first > last:
		return
	if selected_item >= first and selected_item <= last:
		var sel := list_items[selected_item]
		if is_instance_valid(sel) and sel is CoverListItemBase and not sel._cover_loaded:
			sel.start_cover_load()
	var batch := 0
	for i in range(first, last + 1):
		if my_gen != _cover_chain_generation:
			return  # 被新视窗取代，静默退出
		var item := list_items[i]
		if not is_instance_valid(item) or not (item is CoverListItemBase):
			continue
		if not item._cover_loaded:
			item.start_cover_load()
			batch += 1
			if batch % COVER_BATCH_SIZE == 0:
				await get_tree().process_frame

func _process(delta: float) -> void:
	if container == null:
		return
	
	# TRACK_VIEW 和 SETTINGS_VIEW 不需要 BaseScrollList 的触摸/滚动逻辑
	if work_state in [UIStateManager.UIState.TRACK_VIEW, UIStateManager.UIState.SETTINGS_VIEW]:
		return

	# 计算滚动速度
	var sv := scroll_vertical
	_scroll_speed = abs(sv - _prev_scroll_vertical) / max(delta, 0.001)
	_prev_scroll_vertical = sv

	# 滚动速度快 → 不稳定，自动收起展开项
	# 吸附期间跳过速度检测（吸附自己驱动 scroll_vertical，不应自中断）
	if not _snap_active and _scroll_speed > SCROLL_SPEED_COLLAPSE:
		_scroll_stable = false
		if _scroll_stable_timer and not _scroll_stable_timer.is_stopped():
			_scroll_stable_timer.stop()
		if work_state in [UIStateManager.UIState.ALBUM_VIEW] and has_method("reset_selection"):
			call_deferred("reset_selection")
	# 速度降到阈值以下 → 准备吸附
	elif not _snap_active and _scroll_speed < SCROLL_SPEED_SNAP and not _scroll_stable:
		if _scroll_stable_timer and _scroll_stable_timer.is_stopped():
			_scroll_stable_timer.start()

	# 原生会话兜底：指针已松开且滚动已稳定时，即使 scroll_ended 未发出
	# （松手事件被吞 / 惯性残留），也解除 _drag_scrolling，保证吸附能恢复
	if _drag_scrolling and _pointer_release_observed and not _pointer_pressed and _scroll_stable:
		_drag_scrolling = false

	# 吸附（逐帧 lerp，每帧重新计算目标位置以应对项展开/收起导致的布局变化）
	# 仅当滚动已稳定、未拖拽滚动条、且用户未在拖拽列表内容时执行
	if list_items and need_snap and not _is_dragging_bar and not _pointer_pressed and not _drag_scrolling and (_scroll_stable or _snap_active):
		if not _snap_active:
			_snap_active = true
		_process_snap(delta)
	elif _snap_active:
		_snap_active = false
		_snap_stable_frames = 0
		_snap_clamped_frames = 0

	# 吸附飞行中焦点可能被 Godot 自动焦点导航（钳制 ScrollContainer 可见区域）丢到
	# 屏幕内任意项；一旦吸附目标滚进视口就把焦点拉回吸附项，保证吸附结束后
	# 按键从吸附目标处继续正常导航（"吸附项在屏幕内可见时即可按键选择"）
	if _snap_active and selected_item >= 0 and selected_item < list_items.size():
		_grab_focus_to_selected()

	# 封面懒加载：视窗变化时才加载新进入的未加载封面
	_update_cover_window()

	# 批量更新封面视差：统一由本列表驱动，只对可见项触发计算
	call_deferred("_update_visible_parallax")


func _find_snap_target_from_visible() -> int:
	var view_top = global_position.y
	# 只要列表项的顶部在可视区域内，就认为它是吸附目标
	for it in container.get_children():
		if it.global_position.y > view_top:
			return it.get_index()
	# 底部边界兜底：没有项顶部低于视口顶部时（列表滚到末尾），以最后一项为目标，
	# 吸附会被滚动范围钳制在末尾，避免"特定位置松手后不吸附"（fix #72 跟进）
	if container.get_child_count() > 0:
		return container.get_child_count() - 1
	return -1

## 逐帧吸附处理
## 基于全局位置直接修正 —— 无视 scroll_vertical，只维护目标项在屏幕上的位置
func _process_snap(delta: float) -> void:
	# 无选中项时尝试自动寻找可见项
	if selected_item == -1:
		var found := _find_snap_target_from_visible()
		if found != -1:
			select_item(found)
		if selected_item == -1:
			_finish_snap()
			return

	var snap_node := container.get_child(selected_item)
	if not snap_node:
		_finish_snap()
		return

	# 目标：项顶部距离 ScrollContainer 顶部 = snap_offset_y 像素
	# 只用全局位置算距离，不依赖 scroll_vertical（避免容器尺寸变化干扰）
	var distance: float = snap_node.global_position.y - global_position.y - snap_offset_y

	if abs(distance) < 1.0:
		_snap_stable_frames += 1
		if _snap_stable_frames >= 5:
			_finish_snap()
		return

	_snap_stable_frames = 0

	# 纯 P 控制 + 至少 1px 步进：
	# 旧实现带积分项，在特定滚动位置会因积分残留把目标推过头并缓慢振荡，
	# 表现为"松手后长时间不吸附"（fix #72 三跟进）。去掉积分后每帧按剩余距离
	# 的固定比例逼近，舍入到 0 时强制走 1px，保证收敛且不过冲。
	var step: float = distance * clampf(delta * 12.0, 0.0, 1.0)
	var int_step := roundi(step)
	if int_step == 0:
		int_step = 1 if distance > 0.0 else -1

	var before := scroll_vertical
	scroll_vertical += int_step
	if scroll_vertical == before:
		# 滚动已到边界（0 / max），目标不可达：按钳制位置结束吸附，
		# 避免 _snap_active / need_snap 永久卡死
		_snap_clamped_frames += 1
		if _snap_clamped_frames >= 5:
			_finish_snap()
	else:
		_snap_clamped_frames = 0

## 结束吸附：统一清理吸附标志与计数
func _finish_snap() -> void:
	need_snap = false
	_snap_active = false
	_snap_stable_frames = 0
	_snap_clamped_frames = 0

## 批量更新可见项封面视差
## 常规滚动/吸附期间由本列表统一驱动，取代每个列表项各自 _process 造成的"每帧上百次视差计算"。
## 可见区间用二分定位（列表项在容器内纵向排布，position.y 单调递增）：只迭代真正可见的切片，
## 不再每帧遍历全部项；屏幕外项不触发 CoverListItemBase._apply_parallax_offset()
func _update_visible_parallax() -> void:
	if not _items_process_enabled:
		return
	var n := list_items.size()
	if n == 0:
		return
	var top: float = float(scroll_vertical)
	var bottom: float = top + float(size.y)
	var start := _bound_visible(top)
	var end := _bound_visible(bottom)
	if end < start:
		return
	for i in range(maxi(start - 1, 0) , end + 1):
		var item := list_items[i]
		if item == null or not (item is CoverListItemBase):
			continue
		var cb := item as CoverListItemBase
		if not cb._parallax_enabled:
			break
		cb._apply_parallax_offset()

## 二分查找可见区间边界 (并非精确范围)
func _bound_visible(bound: float) -> int:
	var lo := 0
	var hi := list_items.size()
	while lo < hi:
		var mid := (lo + hi) >> 1
		if list_items[mid].position.y + list_items[mid].size.y < bound:
			lo = mid + 1
		else:
			hi = mid
	return maxi(lo - 1, 0)

func _on_v_scrollbar_gui_input(event):
	if event is InputEventScreenTouch:
		_is_dragging_bar = event.pressed
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		# 桌面端鼠标拖拽滚动条同样标记拖拽中，避免 snap 吸附与用户拖拽打架
		_is_dragging_bar = event.pressed

func _gui_input(event: InputEvent) -> void:
	if work_state != UiStatMGR.current_state:
		return
	
	# TRACK_VIEW 和 SETTINGS_VIEW 不需要 BaseScrollList 的输入处理
	if work_state in [UIStateManager.UIState.TRACK_VIEW, UIStateManager.UIState.SETTINGS_VIEW]:
		return

	# 滚轮事件（桌面端鼠标滚轮 —— 接管项选择，滚动本身由 Godot ScrollContainer 处理）
	if event is InputEventMouseButton:
		if event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_UP]:
			var sig = 1 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else -1
			var ui = UIStateManager.UIState
			if work_state in [ui.ALBUM_VIEW, ui.MIDI_VIEW, ui.SONG_VIEW] and get_global_rect().has_point(get_global_mouse_position()) and selected_item != -1:
				select_item(selected_item + sig)
			accept_event()

	elif event is InputEventKey and event.pressed:
		# 文本输入控件获得焦点时，不拦截键盘事件，允许正常输入字母
		var focused = get_viewport().gui_get_focus_owner()
		if focused is LineEdit or focused is TextEdit:
			return
		if event.keycode in [KEY_W, KEY_S]:
			var evt = InputEventKey.new()
			if event.keycode == KEY_W:
				evt.keycode = KEY_UP
			elif event.keycode == KEY_S:
				evt.keycode = KEY_DOWN

			evt.pressed = true
			evt.echo = false

			# 发送到输入系统
			Input.parse_input_event(evt)
			accept_event()

		elif event.keycode in [KEY_TAB]:
			get_node(PathRegistry.SHORTCUT_MENU_SEARCH).grab_focus()
			accept_event()

func select_item(index: int) -> int:
	if index == selected_item or not list_items:
		return index

	index = (index + list_items.size()) % list_items.size()
	# 程序化选中前清理目标项残留的鼠标按压标记（拖拽结束后会残留 _mouse_press 与旧按位置，
	# 使 _on_toggled 误判 final 为 false，导致吸附选中后该项不展开）
	var item: ListItemBase = container.get_child(index)
	if is_instance_valid(item) and item.has_method("clear_mouse_press_state"):
		item.call("clear_mouse_press_state")
	item.button.button_pressed = true
	selected_item = index

	return index

## 强制吸附到指定项：无视滚动/拖拽状态，立即取消惯性并开始吸附
## 供"随机选择""外部选中"等程序化跳转使用 —— 列表滚动中时普通 need_snap
## 会被 _process 的 (_scroll_stable or _snap_active) 门控，且滚动快的分支还会
## call_deferred("reset_selection") 清掉本次选中，导致吸附延迟甚至吸附到别处
func force_snap_to(index: int) -> void:
	if list_items.is_empty():
		return
	# 先清除滚动状态机的拖拽标记，避免随后的 value_changed 回调误触发 reset_selection
	_is_dragging_bar = false
	_pointer_pressed = false
	_pointer_release_observed = false
	# 取消原生拖拽会话（含惯性）：set_v_scroll 内部调 _cancel_drag() 停惯性并发出 scroll_ended
	scroll_vertical = scroll_vertical
	_drag_scrolling = false
	# 立即置为稳定，让吸附条件立刻满足
	_scroll_stable = true
	if _scroll_stable_timer and not _scroll_stable_timer.is_stopped():
		_scroll_stable_timer.stop()
	_scroll_speed = 0.0
	_prev_scroll_vertical = scroll_vertical
	select_item(index)
	need_snap = true
	# 立即激活吸附：跳过 _process 中"滚动速度快 → reset_selection"分支对本次选中的清除
	_snap_active = true

func get_selected_node() -> Control:
	if selected_item == -1:
		return null
	return container.get_child(selected_item)

## 添加列表项
func add_list_item(item: ListItemBase) -> void:
	if container == null:
		return

	container.add_child(item)
	# 同步父列表的 _process 状态，避免不可见视图中新建的项每帧仍跑 _process
	item.set_process(is_processing())
	list_items.append(item)

## 创建并添加列表项
func create_and_add_item(item_id: String, item_type: String = "") -> ListItemBase:
	var item: ListItemBase = null

	if item_scene:
		item = item_scene.instantiate()

		item.initialize(item_id, item_type)
		add_list_item(item)

	return item

## 清空列表
func clear_items() -> void:
	if container == null:
		return

	# 先释放所有封面：立即清空 _loading_path，使在途回调自然失效
	# queue_free 是延迟的，若不主动 release_cover，帧末 free 之前回调可能仍到达并设置 texture
	for item in list_items:
		if item and is_instance_valid(item) and item is CoverListItemBase:
			(item as CoverListItemBase).release_cover()

	for item in list_items:
		if item:
			item.queue_free()

	list_items.clear()

	# 重置封面视窗，使重建后的首次 _update_cover_window 必然重算并加载（避免新旧视窗索引巧合相同导致跳过）
	_cover_window = Vector2i(-1, -1)

	# 重置值
	selected_item = -1
	need_snap = false
	_snap_active = false
	_snap_stable_frames = 0
	_snap_clamped_frames = 0
	_is_dragging_bar = false
	_drag_scrolling = false
	_pointer_pressed = false
	_pointer_release_observed = false
	_scroll_stable = true
	_scroll_speed = 0.0
	_prev_scroll_vertical = 0

## 将头尾连接 用于focus循环
func _connect_head_and_tail() -> void:
	if container == null:
		return
	# 少于 2 项时头尾连接无意义（空列表 get_child(0) 会越界崩溃）
	if container.get_child_count() < 2:
		return

	var node_h: Control = container.get_child(0).button
	var node_t: Control = container.get_child(-1).button

	node_h.focus_neighbor_top = node_t.get_path()
	node_h.focus_neighbor_left = node_t.get_path()
	node_t.focus_neighbor_bottom = node_h.get_path()
	node_t.focus_neighbor_right = node_h.get_path()

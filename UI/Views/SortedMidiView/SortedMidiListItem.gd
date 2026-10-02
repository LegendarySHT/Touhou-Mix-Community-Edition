## 排序MIDI列表项组件
## 继承自 CoverListItemBase，显示排序视图中的MIDI谱面信息
extends CoverListItemBase

class_name SortedMidiListItem

## 引用节点
@onready var status_label: Label = $MidiName/status
@onready var midi_name_label: Label = $MidiName
@onready var author_label: Label = $MidiName/Author
# cover_texture 继承自 CoverListItemBase，在 _ready() 中赋值

@onready var state_manager:UIStateManager = UiStatMGR

## 轻量投影数据（ChartDB.GetSortedMidiListItems / GetMidiListItemsByKeys 返回的字典）
## 替代完整 MidiData，避免列表全量水合；点击时由 SortedMidiView 惰性水合完整对象
var item_dict: Dictionary = {}

## 选择动画补间
var select_tween: Tween

## 刷新入场动画补间（复用时从左侧滑入）
var _refresh_ani_tween: Tween

## 入场动画抑制开关：滚动复用/虚拟化补位时不播滑入动画，仅普通刷新（切筛选进顶）播放
var _suppress_refresh_animation: bool = false

signal _init_fin

var _has_ready: bool = false

## 拖拽滚动手势（引擎单点路由的变通）：
## 项(Button)按下后即独占该指针流，同级的滚动容器收不到、无法启动其原生拖动。
## 故由项按"位移超阈值即拖动"手动代理滚动容器：位移不足视为点击、交还基类 Button；
## 超阈值转拖动，累计相对位移驱动 scroll_vertical，并用 0.1s 窗口采样松开时初速度，
## 交给视图（ScrollContainer 本体）统一驱动的惯性（1000px/s 衰减）。拖开时吞掉松开事件
## 避免误触点击/选择，但手动补齐松开弹起动画。
## 注意：惯性状态必须由视图统一持有驱动——项池会复用，挂在单项上刹停不了全局反拖。
const DRAG_SCROLL_THRESHOLD := 16.0

# 当前独占的输入流（引擎可能在同时下发触摸与被模拟的鼠标事件，用流锁去重）
enum TStream { NONE, TOUCH, MOUSE }

var _stream: int = TStream.NONE
var _pressing := false        # 指针是否在本项按下并持有
var _drag_accum := 0.0        # 按下后累计的局部 y 位移
var _drag_scrolling := false  # 是否已判为拖动(超过阈值)，需吞掉本次点击
var _launch_velocity := 0.0   # 松开时采样出的惯性初速度(px/s)，交给视图启动惯性
var _sample_accum := 0.0      # 上次速度采样时的累计位移
var _sample_time := 0.0       # 距上次采样经过的时间

## 处理输入：触摸/鼠标统一，低阈值点击、高阈值拖动；两流并存时仅首个持有
func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			if _stream == TStream.NONE:
				_stream = TStream.TOUCH
				_drag_begin()
		elif _stream == TStream.TOUCH:
			_stream = TStream.NONE
			_drag_end()
		return
	if event is InputEventScreenDrag:
		if _stream == TStream.TOUCH and _pressing:
			_drag_move(event.relative.y)
		return

	var mb := event as InputEventMouseButton
	if mb and mb.get_button_index() == MOUSE_BUTTON_LEFT:
		if _stream == TStream.NONE:
			if mb.pressed:
				_stream = TStream.MOUSE
				_drag_begin()
			else:
				_stream = TStream.MOUSE
				_drag_end()
				_stream = TStream.NONE
		elif _stream == TStream.MOUSE and not mb.pressed:
			_stream = TStream.NONE
			_drag_end()
		return

	var mm := event as InputEventMouseMotion
	if _stream == TStream.MOUSE and mm and _pressing and (mm.get_button_mask() & MOUSE_BUTTON_MASK_LEFT):
		_drag_move(mm.relative.y)

func _drag_begin() -> void:
	_pressing = true
	_drag_accum = 0.0
	_drag_scrolling = false
	_sample_accum = 0.0
	_sample_time = 0.0
	_launch_velocity = 0.0
	# 按下即刹停全局惯性：惯性由视图统一驱动，任意项按下立停，反拖才能刹住
	var v := parent_node as SortedMidiView
	if v:
		v.item_stop_fling()
	set_process(true)

func _drag_move(dy: float) -> void:
	_drag_accum += dy
	if _drag_scrolling:
		_scroll_by_drag(dy)
		accept_event()
		return
	# 位移超阈值且存在可滚动范围，才转拖动；否则保持点击（如列表不满屏时）
	if abs(_drag_accum) > DRAG_SCROLL_THRESHOLD and _can_drag_scroll():
		_drag_scrolling = true
		_scroll_by_drag(dy)
		accept_event()

func _drag_end() -> void:
	_pressing = false
	if not _drag_scrolling:
		return  # 未拖动：交还基类 Button 处理点击
	_drag_scrolling = false
	button.set_pressed_no_signal(false)
	# 用最后一段采样窗口补全速度（快速轻扫也拿到惯性），交给视图启动
	if _sample_time > 0.0:
		_launch_velocity = (_drag_accum - _sample_accum) / maxf(_sample_time, 0.001)
	var v := parent_node as SortedMidiView
	if v:
		v.item_launch_fling(_launch_velocity)
	_on_button_up()  # 手动补齐松开弹起动画（吞掉信号时不触发点击/选择）
	accept_event()  # 吞掉本次松开，避免误触点击/选择

func _process(delta: float) -> void:
	# 拖动中：0.1s 窗口采样速度（同原生 ScrollContainer._process）；惯性由视图 _step_fling 驱动
	if _pressing:
		_sample_time += delta
		if _sample_time >= 0.1:
			_launch_velocity = (_drag_accum - _sample_accum) / _sample_time
			_sample_accum = _drag_accum
			_sample_time = 0.0
	else:
		set_process(false)

func _scroll_container() -> ScrollContainer:
	return parent_node as ScrollContainer

func _can_drag_scroll() -> bool:
	var sc := _scroll_container()
	return is_instance_valid(sc) and sc.get_v_scroll_bar().max_value > 0.0

func _scroll_by_drag(dy: float) -> void:
	var sc := _scroll_container()
	if is_instance_valid(sc):
		sc.scroll_vertical = roundi(sc.scroll_vertical - dy)

## 焦点滚入视口：项在覆盖层上、非滚动容器子节点，自动滚动失效，
## 故聚焦时手动把项滚进可见区（越界方向补正 scroll_vertical）
func _on_focus_scroll_into_view() -> void:
	var sc := _scroll_container()
	if not is_instance_valid(sc):
		return
	var vsz := sc.size.y
	if vsz <= 0.0:
		return
	var top := position.y
	var bottom := position.y + size.y
	if top < 0.0:
		sc.scroll_vertical = roundi(sc.scroll_vertical + top)
	elif bottom > vsz:
		sc.scroll_vertical = roundi(sc.scroll_vertical + bottom - vsz)

func _ready() -> void:
	cover_texture = $cover
	await _init_fin
	# 先置位 _has_ready 再刷新：_refresh_display 里据此走"复用"分支（含播放入场动画），
	# 否则首次构建恒跳过动画（必须在 _play_refresh_slide_in / switch_cover_data 判断之前置位）
	_has_ready = true
	_refresh_display()

## 刷新显示数据并重新加载封面（新建与复用共用）
## 复用时先 switch_cover_data 重置加载状态（保留旧 texture 显示），再 start_cover_load 加载新封面；
## 新建节点 _cover_loaded=false 无需 switch_cover_data（避免冗余操作）
## 注:新建项若 path 暂不可用,start_cover_load 直接 return,由列表 trigger_cover_chain 统一重试
func _refresh_display() -> void:
	# 显示MIDI信息：下载/游玩/赞/踩，数字右对齐留六位
	get_node("Data").text = "下载 %6d | 游玩 %6d | 赞 %6d | 踩 %6d" % [
		item_dict.get("download_count", 0),
		item_dict.get("trial_count", 0),
		item_dict.get("up_count", 0),
		item_dict.get("down_count", 0)]
	status_label.text = String(item_dict.get("status", ""))
	midi_name_label.text = String(item_dict.get("name", "")).strip_edges()
	var artist := String(item_dict.get("artist_name", ""))
	author_label.text = artist if not artist.is_empty() else "Unknown"

	if _has_ready:
		switch_cover_data()
		_play_refresh_slide_in()

## 复用刷新时的滑入动画：offset_transform_position_ratio.x 从 -2 回到 0
## 仅当项自然位置（ratio=0）与父级可见区域重合时播放；不可见则直接归零
func _play_refresh_slide_in() -> void:
	if _refresh_ani_tween:
		_refresh_ani_tween.kill()
		_refresh_ani_tween = null

	# 滚动复用/虚拟化补位：直接归零，不播放滑入动画
	if _suppress_refresh_animation:
		offset_transform_position_ratio.x = 0.0
		return

	# 切换筛选已跳回顶部，固定为可见项播放入场动画：
	# 观感上整列表重新入场，掩盖"跳回顶部"的瞬时切位；不可见项不建动画省资源

	# 临时重置 x ratio 到 0，检测自然位置是否可见
	offset_transform_position_ratio.x = 0.0
	var in_view := _is_in_viewport()

	if in_view:
		# 可见：从左侧 -2 滑入到 0
		offset_transform_position_ratio.x = -2.0
		_refresh_ani_tween = AniMGR.create_managed_tween(self)
		_refresh_ani_tween.tween_property(
			self, "offset_transform_position_ratio:x", 0.0, 0.4
		).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	else:
		# 不可见：保持 0，无动画
		offset_transform_position_ratio.x = 0.0

## 检测自身是否与父级（ScrollContainer）当前可视视窗相交
## 覆盖层项 position 为"屏幕局部"坐标（覆盖层不被滚动平移，项 y 已含滚动偏移 -vtop），
## 故直接与覆盖层可视高度 [0, size.y] 比较判定可视即可（与 BaseScrollList._bound_visible 语义一致）。
func _is_in_viewport() -> bool:
	if not parent_node or not is_instance_valid(parent_node):
		return false
	var sc := parent_node as ScrollContainer
	if not sc or sc.size.y <= 0.0:
		return false
	return (position.y + size.y > 0.0) and (position.y < sc.size.y)

## 重写基类虚函数：返回 MIDI 封面 Texture2D
func _get_cover_texture() -> Texture2D:
	if item_dict.is_empty():
		return null
	var fs_mgr := FileSystemManager.instance
	if not fs_mgr:
		return null
	return fs_mgr.get_cover_by_ids(String(item_dict.get("file_hash", "")), String(item_dict.get("id", "")))

## 重写基类虚函数：返回封面文件路径（主线程调用，供异步加载器使用）
func _resolve_cover_path() -> String:
	if item_dict.is_empty():
		return ""
	var fs_mgr := FileSystemManager.instance
	if not fs_mgr:
		return ""
	var real := fs_mgr.get_cover_path_by_ids(String(item_dict.get("file_hash", "")), String(item_dict.get("id", "")))
	# 同一 coverHash 的封面内容一致，复用首个解析路径作为缓存键，
	# 同 hash 谱面（不同文件夹各存一份拷贝）共享一份 Texture，避免按路径重复上传
	return fs_mgr.canonicalize_cover_key(real, String(item_dict.get("coverHash", "")))

## 从轻量投影字典初始化显示（DB 返回，无完整 MidiData）
## 新建节点（_has_ready=false）：emit _init_fin 触发 _ready 中的 await 继续
## 复用节点（_has_ready=true）：直接调 _refresh_display 刷新数据
func setup_with_dict(d: Dictionary, index: int, bg:ButtonGroup) -> void:
	item_dict = d
	item_id = String(d.get("id", ""))
	item_type = "sorted_midi"
	item_index = index

	# 初始化按钮（MidiNode 本身即 Button，复用时已初始化，跳过重复初始化）
	if not button:
		button = self
		enable_selected_animation(button, get_node(PathRegistry.SORTED_MIDIS_LIST))
		# 焦点滚入视口（覆盖层项非滚动容器子节点，自动滚动失效，需手动补正）
		button.focus_entered.connect(_on_focus_scroll_into_view)
	button.button_group = bg

	if _has_ready:
		# 复用：清理残留 tween + 重置选中状态 + 刷新显示
		# pulse_tween 为 infinite loop，必须 kill 避免持续占用 CPU
		if pulse_tween:
			pulse_tween.kill()
			pulse_tween = null
		if press_tween:
			press_tween.kill()
		offset_transform_scale = Vector2.ONE
		if button:
			button.set_pressed_no_signal(false)
		is_selected = false
		_refresh_display()
	else:
		# 新建：触发 _ready 中的 await 继续
		_init_fin.emit()

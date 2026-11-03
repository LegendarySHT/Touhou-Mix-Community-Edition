extends PopupMenu

## 全页唯一的乐器两级菜单（大类 → 具体乐器），由 TrackView 持有一个实例。
##
## 【为什么不再每轨一个】原来每条 MidiTrack 各带一个 MenuButton + 自己的 popup，
## 而 16 个大类子菜单本身是全页共享的 —— 于是换轨时要把 16 个内嵌 Window 在两个弹窗之间
## 搬一趟（实测 ~10ms/轨），每轨还要把子菜单信号"摘旧接新"重接一遍。
## 收敛成单实例后：
##   - 子菜单永远挂在这个弹窗下，不再搬家；信号只接一次；
##   - 主菜单项只在"乐器集合变了"时重建（指纹比对）；
##   - 换轨只改"当前归属"，弹出位置跟着请求它的那个按钮走。
##
## 内容仍是懒填充：PopupMenu 没有批量接口，每 add_item 都要重算尺寸 + 重新文本排版
## （实测 ~96µs/项），所以只填当前真正要打开的那一个大类。
##
## 用法：TrackView.request_instrument_menu(track, anchor, options, current_display)
## 选中结果回调到 track.apply_instrument_selection(display)。

## 子菜单弹出后停留的最短时长(ms)：此窗口期内即便鼠标在列表区域也不收起（防刚点开即关闭）
const SUBMENU_AUTOCLOSE_DELAY_MS := 200

## 当前请求菜单的音轨：内容（乐器列表）与选中结果都归它
var _owner: Node = null
## 请求菜单的按钮：决定弹出位置
var _anchor: Control = null

## category(int) -> PopupMenu（每个大类一个，创建后永久复用）
var _submenus: Dictionary = {}
## 当前主菜单内容指纹（乐器集合的哈希）
var _cat_key: String = ""
## category(int) -> Array[String]：当前指纹下的大类分组结果
var _cat_items: Dictionary = {}

# ── 触摸拖拽滚动（全页一份；原来是每轨各一份） ──
## 主菜单内部的 ScrollContainer（16 类超出屏幕时可拖动）
var _main_scroll: ScrollContainer = null
## 主菜单拖拽中标志：区分"点击展开子菜单"与"拖拽滚动"，仅点击时才复位滚动
var _main_dragging: bool = false
## popup -> bool：该弹窗本次按下是否发生过拖拽（用于区分"点击选中"与"拖拽松手"）
var _drag_flags: Dictionary = {}
var _active_submenu: PopupMenu = null
var _submenu_open: bool = false
## 最近一次子菜单弹出的时间戳(ms)，防刚弹开就被悬停误关
var _last_submenu_open_ms: int = 0


func _ready() -> void:
	# 禁用 hover 自动展开子菜单：默认 hover 0.3s 就切换子菜单，拖拽滚动经过各分类项时
	# 频繁切换会打断拖动；设成极大延迟后只有点击才展开（引擎 _activate_submenu 原生行为）
	submenu_popup_delay = 100.0
	_ensure_main_scroll()
	popup_hide.connect(_on_menu_hide)


## 主菜单内部的 ScrollContainer：引擎在构造期建好内部控件，但为了不依赖这个时机，
## 每次打开时都确认一遍（找不到就下次再找，最多退化成"主菜单不能用触摸拖动"）
func _ensure_main_scroll() -> void:
	if _main_scroll != null and is_instance_valid(_main_scroll):
		return
	_main_scroll = _find_scroll_container(self)
	if _main_scroll:
		# 事件穿透到 ScrollContainer 实现原生触摸拖拽
		_set_mouse_filter_recursive(_main_scroll, Control.MOUSE_FILTER_IGNORE, true)
		_main_scroll.gui_input.connect(_on_main_scroll_gui_input)


## 打开菜单：按 track 的乐器列表准备内容，并锚在那个按钮下方
func open_for(track: Node, anchor: Control, options: Array, current_display: String) -> void:
	if track == null or anchor == null or not is_instance_valid(anchor):
		return
	_owner = track
	_anchor = anchor
	_ensure_main_scroll()
	_ensure_content(options, current_display)
	# 与 MenuButton 的定位方式一致（它在 show_popup 里就是 get_screen_position + 高度，
	# 然后 reset_size 让弹窗按内容自适应）
	position = Vector2i(anchor.get_screen_position() + Vector2(0.0, anchor.size.y))
	reset_size()
	popup()


## 内容准备：乐器集合变了才重建主菜单项，否则只更新勾选
func _ensure_content(options: Array, current_display: String) -> void:
	var key := str(options).sha256_text()
	if key != _cat_key:
		_cat_key = key
		_cat_items = _group_by_category(options)
		_rebuild_main_items()
	_apply_check_marks(current_display)


## 按大类分组。顺序沿用"首次出现的顺序"，与原实现一致（引擎按 ID 排序另有逻辑）
static func _group_by_category(options: Array) -> Dictionary:
	var out := {}
	for entry in options:
		var display := str(entry)
		var info := InstrumentCategory.parse_display_name(display)
		var cat := InstrumentCategory.get_category(int(info.get("bank", 0)), int(info.get("program", 0)))
		if not out.has(cat):
			out[cat] = []
		out[cat].append(display)
	return out


func _rebuild_main_items() -> void:
	var atlas: Texture2D = null
	if _owner != null and is_instance_valid(_owner) and _owner.has_method("get_icon_atlas"):
		atlas = _owner.get_icon_atlas()
	clear()
	var idx := 0
	for cat_key in _cat_items.keys():
		var cat := int(cat_key)
		var sub := _submenu_for(cat)
		add_submenu_item(InstrumentCategory.CATEGORY_NAMES[cat], sub.name)
		set_item_id(idx, cat)
		if atlas != null:
			var icon := _make_cat_icon(cat, atlas)
			if icon != null:
				set_item_icon(idx, icon)
		idx += 1


## 取（必要时创建）某个大类的子菜单。信号只在这里接一次 —— 不再有"换轨重接"。
func _submenu_for(cat: int) -> PopupMenu:
	if _submenus.has(cat):
		# 不写成 `var existing: PopupMenu = _submenus[cat]`：字典里若存着已释放实例，
		# 类型化赋值会报"previously freed instance"，用无类型变量 + is_instance_valid 判
		var existing: Variant = _submenus[cat]
		if existing != null and is_instance_valid(existing):
			return existing
	var sub := PopupMenu.new()
	sub.name = "InstrumentSub_%d" % cat
	sub.hide_on_item_selection = false  # 选中项由本类手动控制关闭
	sub.set_meta("category", cat)
	add_child(sub)
	sub.about_to_popup.connect(_on_submenu_about_to_popup.bind(sub))
	sub.id_pressed.connect(_on_submenu_selected.bind(sub))
	sub.popup_hide.connect(_on_submenu_hidden.bind(sub))
	_submenus[cat] = sub
	return sub


func _make_cat_icon(category: int, atlas: Texture2D) -> Texture2D:
	var at := AtlasTexture.new()
	at.atlas = atlas
	at.region = InstrumentCategory.get_icon_region(category)
	return at


## 勾选标记：PopupMenu 没有 select，用 set_item_checked 表达"当前大类"
func _mark_category(cat: int) -> void:
	for i in item_count:
		set_item_checked(i, false)
	var idx := get_item_index(cat)
	if idx >= 0:
		set_item_checked(idx, true)


func _apply_check_marks(current_display: String) -> void:
	if current_display.is_empty():
		_mark_category(-1)
		return
	var info := InstrumentCategory.parse_display_name(current_display)
	_mark_category(InstrumentCategory.get_category(int(info.get("bank", 0)), int(info.get("program", 0))))


## 子菜单内容懒填充：弹出前才填当前这一个大类（见头注释）
func _fill_submenu(sub: PopupMenu, cat: int) -> void:
	var list: Array = _cat_items.get(cat, [])
	var sig := "%s#%d" % [_cat_key, cat]
	if str(sub.get_meta("fill_sig", "")) == sig and sub.item_count == list.size():
		return
	sub.clear()
	for i in list.size():
		sub.add_item(list[i], i)
	sub.set_meta("fill_sig", sig)


## 子菜单的触摸滚动配置：容器与穿透都是实例固有结构，只处理一次
func _ensure_submenu_scroll(sub: PopupMenu) -> void:
	if sub.has_meta("menu_scroll"):
		return
	var scroll := _find_scroll_container(sub)
	sub.set_meta("menu_scroll", scroll)  # 可能为 null：meta 存在即代表"查过了"
	if scroll:
		_set_mouse_filter_recursive(scroll, Control.MOUSE_FILTER_PASS, true)
		scroll.gui_input.connect(_on_submenu_gui_input.bind(sub))


func _on_submenu_about_to_popup(sub: PopupMenu) -> void:
	_ensure_submenu_scroll(sub)
	# 内容在这里才填：about_to_popup 早于尺寸计算与显示，填完显示的就是最终内容
	_fill_submenu(sub, int(sub.get_meta("category", -1)))
	# 复位大类菜单的拖拽跟随：松手弹出子菜单后主菜单可能收不到松开事件，会一直跟着鼠标滚
	if _main_scroll and not _main_dragging:
		_main_scroll.set_v_scroll(_main_scroll.get_v_scroll())
	_active_submenu = sub
	_submenu_open = true
	_last_submenu_open_ms = Time.get_ticks_msec()
	set_process(true)


func _on_submenu_selected(id: int, sub: PopupMenu) -> void:
	# 拖拽滚动后松手：不选中、不关闭（与 TouchScrollOptionButton 一致）
	if _drag_flags.get(sub, false):
		return
	var cat := int(sub.get_meta("category", -1))
	var list: Array = _cat_items.get(cat, [])
	if id < 0 or id >= list.size():
		return
	var display: String = list[id]
	_mark_category(cat)
	sub.hide()
	if _owner != null and is_instance_valid(_owner) and _owner.has_method("apply_instrument_selection"):
		_owner.apply_instrument_selection(display)


func _on_submenu_hidden(sub: PopupMenu) -> void:
	_drag_flags.erase(sub)
	if _active_submenu == sub:
		_active_submenu = null
		_submenu_open = false
		set_process(false)
	var scroll: Variant = sub.get_meta("menu_scroll") if sub.has_meta("menu_scroll") else null
	if scroll and is_instance_valid(scroll):
		scroll.set_v_scroll(scroll.get_v_scroll())


func _on_menu_hide() -> void:
	# 主菜单关闭必然同时收起所有子菜单
	_drag_flags.erase(self)
	_main_dragging = false
	_active_submenu = null
	_submenu_open = false
	set_process(false)
	if _main_scroll:
		_main_scroll.set_v_scroll(_main_scroll.get_v_scroll())


## 子菜单拖拽检测：按下开始时重置标志，拖动时置位
func _on_submenu_gui_input(event: InputEvent, sub: PopupMenu) -> void:
	if (event is InputEventMouseButton or event is InputEventScreenTouch) and event.pressed:
		_drag_flags[sub] = false
	elif event is InputEventScreenDrag:
		_drag_flags[sub] = true
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		_drag_flags[sub] = true


## 主菜单拖拽检测：有拖拽位移时标记 _main_dragging（子菜单弹出时据此跳过复位）；
## 松手时清除标志并复位卡住的拖拽跟随（主菜单展开子菜单时自身不关闭，popup_hide 不触发，
## 只能靠松手事件里 set_v_scroll 内部 _cancel_drag() 停住"松手后还滚动"的残留跟随）
func _on_main_scroll_gui_input(event: InputEvent) -> void:
	if event is InputEventScreenDrag:
		_main_dragging = true
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		_main_dragging = true
	elif (event is InputEventMouseButton or event is InputEventScreenTouch) and not event.pressed:
		_main_dragging = false
		if _main_scroll:
			_main_scroll.set_v_scroll(_main_scroll.get_v_scroll())


## 提前收起子菜单轮询：子菜单打开后主菜单失活收不到输入，点击只会拿去收起子菜单而无法拖拽。
## 鼠标明确回到大类列表区域后主动收起，让主菜单恢复活性。仅在有子菜单打开时运行。
func _process(_delta: float) -> void:
	if not _submenu_open or _active_submenu == null or _active_submenu.is_embedded():
		set_process(false)
		return
	var now := Time.get_ticks_msec()
	if now - _last_submenu_open_ms < SUBMENU_AUTOCLOSE_DELAY_MS:
		return
	var mouse := DisplayServer.mouse_get_position()
	if not _window_contains(self, mouse):
		return
	if _window_contains(_active_submenu, mouse):
		return
	_active_submenu.hide()


## 某原生弹窗窗口是否包含某全局(OS)坐标点
func _window_contains(win: Window, point: Vector2) -> bool:
	return Rect2(Vector2(win.position), Vector2(win.size)).has_point(point)


func _find_scroll_container(node: Node) -> ScrollContainer:
	for child in node.get_children(true):
		if child is ScrollContainer:
			return child
		var found := _find_scroll_container(child)
		if found:
			return found
	return null


func _set_mouse_filter_recursive(node: Node, filter: int, skip_root: bool = false) -> void:
	if not skip_root and node is Control:
		node.mouse_filter = filter
	for child in node.get_children(true):
		_set_mouse_filter_recursive(child, filter, false)

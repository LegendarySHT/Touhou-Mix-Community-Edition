extends ListItemBase

class_name MidiTrack

@onready var note_display: NoteDisplayer = $HBoxC/MC/HBoxC/MC/flowArea

# 写着"Track"的按钮
@onready var track_btn: Button = $HBoxC/TR/TrackBtn
@onready var track_num: Label = $HBoxC/TR/TrackNum

@onready var channel_btn: Button = $HBoxC/CH/ChannelBtn
@onready var channel_num: Label = $HBoxC/CH/ChannelNum
# 切换轨道启用状态的按钮
@onready var enable_btn: Button = $HBoxC/MC/HBoxC/enableBtn

@onready var mute_btn: TextureButton = $HBoxC/MC/HBoxC/MC/ControlPanel/GridC/MuteBtn
@onready var solo_btn: TextureButton = $HBoxC/MC/HBoxC/MC/ControlPanel/GridC/SoloBtn
@onready var reset_btn: TextureButton = $HBoxC/MC/HBoxC/MC/ControlPanel/GridC/ResetBtn
@onready var volume_slider: HSlider = $HBoxC/MC/HBoxC/MC/ControlPanel/GridC/Volume/Slider
@onready var volume_label: Label = $HBoxC/MC/HBoxC/MC/ControlPanel/GridC/Volume/Label
# 乐器两级选择菜单：大类(MenuButton) → 具体乐器(子菜单)
@onready var instruments_btn: MenuButton = $HBoxC/MC/HBoxC/MC/ControlPanel/GridC/InstrumentBtn

# category(int) -> Array[String] 该类下的乐器 display_name（由 instrument_options 分组）
var _category_items: Dictionary = {}
# 当前菜单按钮显示的乐器名（完整 display_name）
var _current_display_name: String = ""
# popup -> bool 滚动拖拽中标志（用于区分"点击选中"与"拖拽滚动"）
var _drag_flags: Dictionary = {}
# 主菜单（大类）滚动挂钩是否已完成（防止 rebuild 时重复连接信号）
var _main_menu_hooked := false
# 主菜单 ScrollContainer 缓存（子菜单弹出时复位其拖拽跟随状态）
var _main_scroll: ScrollContainer = null
# 主菜单拖拽中标志：区分"点击展开子菜单"与"拖拽滚动"，仅点击时才复位滚动，避免拖拽被中断
var _main_dragging := false
# 提前收起子菜单机制：子菜单打开后，主菜单（大类列表）失活收不到输入，
# 点击只会被用于激活/收起子菜单而无法直接拖拽。因此当鼠标回到大类列表区域时
# 主动收起子菜单，让主菜单恢复活性，下一次按下即可直接拖拽滚动。
var _last_submenu_open_ms := 0      # 最近一次子菜单弹出的时间戳(ms)，防刚弹开就被悬停误关
var _active_submenu: PopupMenu = null   # 当前打开的子菜单
var _submenu_open := false          # 是否有任一子菜单打开
# 子菜单弹出后停留的最短时长(ms)：此窗口期内即便鼠标在列表区域也不收起（防刚点开即关闭）
const _SUBMENU_AUTOCLOSE_DELAY_MS := 200

# 初始化时需要调节颜色的节点 除下面的之外还有self和enable_btn
@onready var track_panel: Panel = $HBoxC/TR
@onready var channel_panel: Panel = $HBoxC/CH
@onready var note_panel: Panel = $HBoxC/MC/HBoxC/MC/flowArea/noteTotal


# 轨道属性
var track_index: int = 2
var track_channel: int = 0
var current_volume: float = 1.0
var current_instrument: String = ""

# 引用到MidiData以获取状态
var midi_data: MidiData = null

var instrument_options: Array = []

signal _init_fin

func _ready():
	await _init_fin
	
	# 连接按钮信号
	_connect_signals()
	_init_track_color()
	# 行内文字/图标固定白色（不随主题）
	_apply_row_text_theme()

	# 注册主题应用者：外观模式切换时整行重新配色
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)

	track_num.text = str(track_index)
	channel_num.text = str(track_channel)

	if not instrument_options:
		if not parent_node:
			push_error("轨道 %d 初始化失败: 无父节点" % track_index)
			return
		instrument_options = parent_node.instrument_options
	if not instrument_options:
		push_error("轨道 %d 初始化失败: 无可用乐器选项" % track_index)
		return

	# 构建两级乐器菜单：大类 → 具体乐器（大类子菜单节点急切创建，具体乐器项首次打开时惰性填充）
	if instruments_btn.get_popup().item_count == 0:
		_build_category_items()
		_build_instrument_menus()

	GLogger.info("Track %d initialized with %d instrument categories" % [track_index, _category_items.size()], "MidiTrack")

	# 从MidiData读取启用状态
	if midi_data:
		var is_enabled = midi_data.is_track_channel_selected(track_index, track_channel)
		enable_btn.button_pressed = is_enabled
	
## 轨道色相环（仅取 .h 使用）：现代高饱和但不过分刺眼的 13 色
const colors_set = [
	Color("#FF5C6C"),
	Color("#FF5CA8"),
	Color("#FF8C42"),
	Color("#FFC24B"),
	Color("#A8E05F"),
	Color("#3ED88C"),
	Color("#2AD4C4"),
	Color("#35C8E8"),
	Color("#5B8CFF"),
	Color("#6C6CFF"),
	Color("#A06BFF"),
	Color("#E05CFF"),
	Color("#FF6B9D"),
]

var color_light: Color
var color_normal: Color
var color_dark: Color

# 轨道/通道色相（主题切换时按外观模式重算）
var _track_hue: float = 0.0
var _channel_hue: float = 0.0

func _init_track_color():
	_track_hue = colors_set[track_index % colors_set.size()].h
	_channel_hue = colors_set[(-track_channel) % colors_set.size()].h
	_apply_track_colors()

## 主题刷新回调（由 ThemeManager 广播调用）
func apply_theme() -> void:
	_apply_track_colors()

## 行内文字/图标固定白色、不随主题。用一个只覆盖文字/图标色的局部 Theme 挂在根节点上，
## 样式框仍向上回落主 Theme（PopupMenu 等其它类型不受影响，仍是主题色）。
## 音量滑条的白色填充不在此处设置——它由 midiTrack.tscn 里 Slider 节点的 theme_override_styles
## 统一定义（所有音轨实例共享同一份样式框，无需每轨复制）。
func _apply_row_text_theme() -> void:
	var t := Theme.new()
	for type in ["Label", "Button", "MenuButton", "OptionButton", "CheckBox", "CheckButton"]:
		t.set_color("font_color", type, Color.WHITE)
	for type in ["Button", "MenuButton", "OptionButton"]:
		t.set_color("font_hover_color", type, Color.WHITE)
		t.set_color("font_pressed_color", type, Color.WHITE)
		t.set_color("icon_normal_color", type, Color.WHITE)
		t.set_color("icon_hover_color", type, Color.WHITE)
		t.set_color("icon_pressed_color", type, Color.WHITE)
	t.set_color("font_hover_pressed_color", "Button", Color.WHITE)
	t.set_color("font_disabled_color", "Button", Color(1, 1, 1, 0.5))
	theme = t

## 按当前外观模式重算整行配色。
## 轨道行 = 共享中性底板 × 轨道色相(self_modulate)：深色模式底板偏深、色相加浓；
## 浅色模式底板改近白、色相取浅色调，否则浅色页面里整行仍是一块深色卡片，比深色主题还暗。
func _apply_track_colors() -> void:
	var light: bool = ThemeMGR != null and ThemeMGR.get_appearance() == "light"
	if light:
		# 浅色模式同样「以音轨原色为主」：整行铺较饱和的音轨色（比深色模式亮），文字统一白色
		color_light = Color.from_hsv(_track_hue, 0.60, 0.80)
		color_normal = Color.from_hsv(_track_hue, 0.85, 0.75)
		color_dark = Color.from_hsv(_track_hue, 0.75, 0.68)
	else:
		color_light = Color.from_hsv(_track_hue, 0.3, 0.95)
		color_normal = Color.from_hsv(_track_hue, 0.9, 0.85)
		color_dark = Color.from_hsv(_track_hue, 0.8, 0.5)

	_set_track_base_colors(light)
	_apply_enable_btn_colors(light)

	channel_panel.self_modulate = Color.from_hsv(_channel_hue, 0.72 if light else 0.8, 0.68 if light else 0.5)
	track_panel.self_modulate = color_dark

	note_panel.self_modulate = color_light
	self_modulate = color_light
	# enableBtn 的图标/文字是按钮自身绘制（icon/text 属性），self_modulate 会连它们一起染色；
	# 故这里不改 self_modulate，底色改由 _apply_enable_btn_colors 直接写入每实例样式框
	enable_btn.self_modulate = Color.WHITE

	note_display.note_color = color_normal
	note_display.update_color()

## 写回整行各本地 StyleBox 的中性底板颜色（这些是场景内共享子资源，所有轨道一致；
## 轨道间的色相差异只靠每节点的 self_modulate 表达，故底板里不写入任何色相）。
func _set_track_base_colors(light: bool) -> void:
	# 浅色模式：底板统一为纯白（不受主题色影响），整行颜色完全由音轨色相 modify 决定
	var root_sb := get_theme_stylebox("panel")
	if root_sb is StyleBoxFlat:
		root_sb.bg_color = Color(1, 1, 1, 1) if light else Color(0.1044445, 0.12558684, 0.17314443, 0.8509804)
		root_sb.border_color = Color(0, 0, 0, 0.18) if light else Color(0.34404153, 0.40147635, 0.51591545)
	var tr_sb := track_panel.get_theme_stylebox("panel")
	if tr_sb is StyleBoxFlat:
		tr_sb.bg_color = Color(1, 1, 1, 1) if light else Color(0.7330051, 0.7330055, 0.7330051)
		tr_sb.border_color = Color(0, 0, 0, 0.18) if light else Color(0, 0, 0, 0.35)
	var ch_sb := channel_panel.get_theme_stylebox("panel")
	if ch_sb is StyleBoxFlat:
		ch_sb.bg_color = Color(1, 1, 1, 1) if light else Color(0.73333335, 0.73333335, 0.73333335)
		ch_sb.border_color = Color(0, 0, 0, 0.18) if light else Color(0, 0, 0, 0.35)
	var nt_sb := note_panel.get_theme_stylebox("panel")
	if nt_sb is StyleBoxFlat:
		nt_sb.bg_color = Color(1, 1, 1, 1) if light else Color(0.45177418, 0.4929024, 0.558753, 0.9019608)
		nt_sb.border_color = Color(0, 0, 0, 0.18) if light else Color(0, 0, 0, 0.25)
	# 注：noteFlowArea 上的半透明黑渐变叠加层（StyleBoxTexture）保持 .tscn 原样，不随外观模式改动。
	# noteTotal 里的白色斜线分隔条在浅色下不可见，改为深色半透明
	var sep := get_node_or_null("HBoxC/MC/HBoxC/MC/flowArea/noteTotal/VBoxC/Control/HSeparator") as HSeparator
	if sep:
		var ssb := sep.get_theme_stylebox("separator")
		if ssb is StyleBoxLine:
			ssb.color = Color(0, 0, 0, 0.25) if light else Color(1, 1, 1, 0.25)

## enableBtn 四态配色。其图标/文字挂在按钮自身上，若用 self_modulate 染色会连它们一起被染，
## 故这里直接给按钮「每实例独立」的样式框（.tscn 中 resource_local_to_scene）写入
## 「中性底板 × 轨道色相」后的最终色，只染底色、不动图标/文字（图标/文字保持白色）。
func _apply_enable_btn_colors(light: bool) -> void:
	var cn := color_normal
	# 各状态的中性底板与其描边（与原先 self_modulate 叠加前的底值一致）
	var specs := {
		"normal": [
			Color(0.55, 0.55, 0.55, 1) if light else Color(0.16, 0.19, 0.26, 1),
			Color(0, 0, 0, 0.25) if light else Color(0.28, 0.32, 0.4),
		],
		"hover": [
			Color(0.48, 0.48, 0.48, 1) if light else Color(0.22, 0.25, 0.32, 1),
			Color(0, 0, 0, 0.25) if light else Color(0.34, 0.38, 0.46),
		],
		"pressed": [
			Color(1, 1, 1, 1),
			Color(1, 1, 1, 1),
		],
		"hover_pressed": [
			Color(1, 1, 1, 0.92),
			Color(1, 1, 1, 1),
		],
	}
	for state in specs:
		var sb := enable_btn.get_theme_stylebox(state)
		if sb is StyleBoxFlat:
			var bg: Color = specs[state][0]
			var bd: Color = specs[state][1]
			sb.bg_color = Color(bg.r * cn.r, bg.g * cn.g, bg.b * cn.b, bg.a)
			sb.border_color = Color(bd.r * cn.r, bd.g * cn.g, bd.b * cn.b, bd.a)
	# 按下 / 悬停按下态带一圈「辉光」（StyleBoxFlat.shadow）。原来白色辉光会被 self_modulate 染成轨道色，
	# 现改为直接写入轨道色辉光（浅色模式下白辉光落在浅底上不可见，必须跟着轨道色走）。
	for state in ["pressed", "hover_pressed"]:
		var sb := enable_btn.get_theme_stylebox(state)
		if sb is StyleBoxFlat:
			sb.shadow_color = Color(cn.r, cn.g, cn.b, sb.shadow_color.a)

# 根据乐器大类索引设置图标区域（图标材质由外部 setup，此处仅改坐标）
# enable_btn.icon 须为 AtlasTexture 才会生效
func set_instrument_category(category: int) -> void:
	var tex := enable_btn.icon as AtlasTexture
	if tex:
		tex.region = InstrumentCategory.get_icon_region(category)

func _connect_signals():
	enable_btn.toggled.connect(_on_enable_toggled)
	mute_btn.toggled.connect(_on_mute_toggled)
	solo_btn.toggled.connect(_on_solo_toggled)

	volume_slider.value_changed.connect(
		func(value):
			volume_label.text = "%.2fdB" % linear_to_db(value)
			current_volume = value
	)

	if not parent_node:
		GLogger.error("轨道 %d 初始化失败: 无父节点" % track_index, "MidiTrack")
		return

	if parent_node.has_method("_on_track_enable_toggled"):
		enable_btn.toggled.connect(parent_node._on_track_enable_toggled.bind(track_index, track_channel))
	if parent_node.has_method("_on_track_mute_toggled"):
		mute_btn.toggled.connect(parent_node._on_track_mute_toggled.bind(track_index, track_channel))
	if parent_node.has_method("_on_track_solo_toggled"):
		solo_btn.toggled.connect(parent_node._on_track_solo_toggled.bind(track_index, track_channel))
	if parent_node.has_method("_on_track_volume_changed"):
		volume_slider.value_changed.connect(parent_node._on_track_volume_changed.bind(track_index, track_channel))
	if parent_node.has_method("_on_track_instrument_reset"):
		reset_btn.pressed.connect(parent_node._on_track_instrument_reset.bind(track_index, track_channel))

# 提供父节点及轨道信息，自动连接信号 乐器选项不提供时从传入的父节点获取
# channel 参数用于区分同一轨道的不同MIDI通道，后续UI完善时使用set_channel_label()显示
func setup_track(parent: Node, index: int, track_name: String, instruments: Array = [], channel: int = 0, midi_data_ref: MidiData = null):
	parent_node = parent
	track_index = index
	track_channel = channel
	midi_data = midi_data_ref
	name = track_name
	
	# 根据 channel 类型过滤乐器选项
	# 共享 parent 的乐器列表引用（不 duplicate）：instrument_options 仅读遍历，不会被修改
	# 避免每轨道复制 ~500 个字符串，30 轨道可省 ~15000 次字符串拷贝
	if channel == 9:
		# Channel 9 是鼓轨道，只显示鼓组乐器
		if "drum_instruments" in parent and not parent.drum_instruments.is_empty():
			instrument_options = parent.drum_instruments
			GLogger.info("Track %d Channel %d: 使用鼓组乐器列表 (%d 个)" % [index, channel, instrument_options.size()], "MidiTrack")
		else:
			instrument_options = instruments  # fallback
	else:
		# 普通 channel，只显示常规乐器
		if "regular_instruments" in parent and not parent.regular_instruments.is_empty():
			instrument_options = parent.regular_instruments
			GLogger.info("Track %d Channel %d: 使用常规乐器列表 (%d 个)" % [index, channel, instrument_options.size()], "MidiTrack")
		else:
			instrument_options = instruments  # fallback

	# 两级乐器菜单在 _ready 构建
	_init_fin.emit()

# 按大类把 instrument_options 分组成 _category_items（instrument_options 已按大类排序）
func _build_category_items() -> void:
	_category_items.clear()
	for display in instrument_options:
		var info := InstrumentCategory.parse_display_name(display)
		var cat := InstrumentCategory.get_category(info.get("bank", 0), info.get("program", 0))
		if not _category_items.has(cat):
			_category_items[cat] = []
		_category_items[cat].append(display)

# 用 enable_btn.icon 的同源图集生成某个大类的菜单图标
func _make_cat_icon(category: int) -> Texture2D:
	var icon_tex := enable_btn.icon as AtlasTexture
	if icon_tex == null or icon_tex.atlas == null:
		return null
	var at := AtlasTexture.new()
	at.atlas = icon_tex.atlas
	at.region = InstrumentCategory.get_icon_region(category)
	return at

# 构建大类主菜单 + 各具体乐器子菜单。
# 子菜单全部复用 TrackView 持有的全局共享 PopupMenu（add_submenu_item 要求节点构建时已是本弹窗的子元素，
# 故在 _attach_shared_submenu 中 reparent 到本弹窗下；打开时的归属按当前音轨由 _ensure_submenus_attached 决定）。
func _build_instrument_menus() -> void:
	var popup := instruments_btn.get_popup()
	popup.clear()
	_release_submenus()
	_main_dragging = false

	# 大类主菜单滚动支持（16 类超出屏幕时可触摸拖动滚动）
	_setup_main_menu_scroll(popup)
	# 主菜单弹出前把共享子菜单 reparent 到本弹窗并预填当前轨乐器项（此时才确定活动音轨）
	if not popup.is_connected("about_to_popup", Callable(self, "_on_main_menu_about_to_popup")):
		popup.about_to_popup.connect(_on_main_menu_about_to_popup)

	# 禁用 hover 自动展开子菜单：仅点击大类项时才打开子菜单。
	# 默认 hover 0.3s 就切换子菜单，拖拽滚动经过各分类项时频繁切换会打断/卡顿拖动；
	# 设大延迟后鼠标未 hover 触发也能流畅拖动（点击仍由引擎 _activate_submenu 原生展开）。
	popup.submenu_popup_delay = 100.0

	popup.set_block_signals(true)
	var idx := 0
	for cat in _category_items.keys():
		# 复用全局共享子菜单（reparent 到本弹窗下，供 add_submenu_item 相对名解析 + 引擎内嵌）
		var sub : PopupMenu = parent_node.get_shared_submenu(cat)
		_attach_shared_submenu(sub, cat)
		popup.add_submenu_item(InstrumentCategory.CATEGORY_NAMES[cat], sub.name)
		popup.set_item_id(idx, cat)
		var icon := _make_cat_icon(cat)
		if icon:
			popup.set_item_icon(idx, icon)
		idx += 1
	popup.set_block_signals(false)

# 归属共享子菜单：reparent 到本轨弹窗、清掉上一音轨遗留乐器项改装当前音轨、一次性信号接线。
# owner/category meta 让共享子菜单的信号回调定位到当前活动音轨（见 owner 分发）。
func _attach_shared_submenu(sub: PopupMenu, cat: int) -> void:
	var popup := instruments_btn.get_popup()
	if sub.get_parent() != popup:
		# add_child 不能直接 reparent，须先从旧父（其它轨/本视图）摘下再挂到本弹窗
		if sub.get_parent():
			sub.get_parent().remove_child(sub)
		popup.add_child(sub)
	sub.clear()
	sub.set_meta("owner", self)
	sub.set_meta("category", cat)
	var list: Array = _category_items.get(cat, [])
	for i in list.size():
		sub.add_item(list[i], i)
	if not sub.has_meta("wired"):
		sub.set_meta("wired", true)
		sub.about_to_popup.connect(_on_submenu_about_to_popup.bind(sub))
		sub.id_pressed.connect(_on_submenu_item_selected.bind(sub))
		_setup_submenu_scroll(sub)

# 主菜单弹出前，把所有共享子菜单 reparent 到本轨弹窗并预填本轨乐器项
func _on_main_menu_about_to_popup() -> void:
	if parent_node == null or not parent_node.has_method("get_shared_submenu"):
		return
	for cat in _category_items.keys():
		var sub : PopupMenu = parent_node.get_shared_submenu(cat)
		_attach_shared_submenu(sub, cat)

# 共享子菜单不销毁，只从本弹窗移除交还 TrackView 持有，供其它音轨复用
func _release_submenus() -> void:
	if parent_node and parent_node.has_method("_reclaim_shared_submenus"):
		parent_node._reclaim_shared_submenus()
	_drag_flags.clear()

# 大类主菜单（MenuButton popup）触摸滚动配置
func _setup_main_menu_scroll(popup: PopupMenu) -> void:
	if _main_menu_hooked:
		return
	_main_menu_hooked = true
	var scroll := _find_scroll_container(popup)
	if scroll == null:
		return
	_main_scroll = scroll
	# 事件穿透到 ScrollContainer 实现原生触摸拖拽
	_set_mouse_filter_recursive(scroll, Control.MOUSE_FILTER_IGNORE, true)
	scroll.gui_input.connect(_on_main_scroll_gui_input)
	popup.popup_hide.connect(_on_menu_hide.bind(popup, scroll))

# 为具体乐器子菜单配置触摸滚动（与 TouchScrollOptionButton 机制一致）
func _setup_submenu_scroll(submenu: PopupMenu) -> void:
	# 阻止选中后自动关闭：滚动拖拽松手不应误选中（由 _on_submenu_item_selected 手动控制关闭）
	submenu.hide_on_item_selection = false
	var scroll := _find_scroll_container(submenu)
	if scroll == null:
		return
	# 事件穿透到 ScrollContainer 实现原生触摸拖拽
	_set_mouse_filter_recursive(scroll, Control.MOUSE_FILTER_PASS, true)
	scroll.gui_input.connect(_on_menu_scroll_gui_input.bind(submenu))
	submenu.popup_hide.connect(_on_menu_hide.bind(submenu, scroll))

func _on_menu_scroll_gui_input(event: InputEvent, popup: PopupMenu) -> void:
	# 共享子菜单被复用，owner 定位到当前活动音轨
	var track = popup.get_meta("owner") as MidiTrack
	if track == null:
		return
	# 新一轮按下开始时重置拖拽标志：上一次"拖拽滚动但未选中项"的标记不应残留到后续点击，
	# 否则后续点击都会被误判成拖拽松手而无法选中（表现为按钮无效但 hover 正常）。
	if (event is InputEventMouseButton or event is InputEventScreenTouch) and event.pressed:
		track._drag_flags[popup] = false
	elif event is InputEventScreenDrag:
		track._drag_flags[popup] = true
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		track._drag_flags[popup] = true

# 主菜单拖拽检测：有拖拽位移时标记 _main_dragging，_on_submenu_about_to_popup 据此跳过复位；
# 松手时清除标志并复位卡住的拖拽跟随（主菜单打开子菜单时自身不关闭，popup_hide 不会触发，
# 只能靠松手事件里 set_v_scroll 内部 _cancel_drag() 停住"松手后还滚动"的残留跟随）
func _on_main_scroll_gui_input(event: InputEvent) -> void:
	if event is InputEventScreenDrag:
		_main_dragging = true
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		_main_dragging = true
	elif (event is InputEventMouseButton or event is InputEventScreenTouch) and not event.pressed:
		_main_dragging = false
		if _main_scroll:
			_main_scroll.set_v_scroll(_main_scroll.get_v_scroll())

# 子菜单弹出时复位大类菜单 ScrollContainer 的拖拽跟随状态。
# 松手弹出子菜单后，主菜单可能收不到松开事件导致 drag_touching 卡住，一直跟随鼠标滚动；
# set_v_scroll(get_v_scroll()) 内部会 _cancel_drag() 停止跟随。
# 仅"点击展开子菜单"（非拖拽）时复位：拖拽滚动中悬浮切到其它大类也会触发弹出，此时复位会中断拖拽。
# 同时记录打开的子菜单并启用"提前收起"轮询：鼠标一回到大类列表区域就收起子菜单，主菜单即可直接拖拽。
func _on_submenu_about_to_popup(sub: PopupMenu) -> void:
	# 共享子菜单被复用，owner 定位到当前活动音轨
	var track = sub.get_meta("owner") as MidiTrack
	if track == null:
		return
	if track._main_scroll and not track._main_dragging:
		track._main_scroll.set_v_scroll(track._main_scroll.get_v_scroll())
	track._active_submenu = sub
	track._submenu_open = true
	track._last_submenu_open_ms = Time.get_ticks_msec()
	track.set_process(true)

# 弹窗关闭时清除拖拽标志 + 重置 ScrollContainer 卡住的拖拽状态
func _on_menu_hide(popup: PopupMenu, scroll: ScrollContainer) -> void:
	if popup == instruments_btn.get_popup():
		# 主菜单关闭必然同时收起所有子菜单（popup 即本轨主弹窗）
		_drag_flags.erase(popup)
		_main_dragging = false
		if _active_submenu:
			_active_submenu = null
		_submenu_open = false
		set_process(false)
	else:
		# 共享子菜单被收起，owner 定位到当前活动音轨
		var track = popup.get_meta("owner") as MidiTrack
		if track:
			track._drag_flags.erase(popup)
			if track._active_submenu == popup:
				track._active_submenu = null
				track._submenu_open = false
				track.set_process(false)
	scroll.set_v_scroll(scroll.get_v_scroll())

# 提前收起子菜单轮询：仅当有子菜单打开时才运行（set_process 动态启停）。
# 鼠标回到大类列表区域（主菜单窗口内、且不在子菜单窗口内）且超过最短停留时长后，
# 主动收起子菜单，让主菜单恢复活性，下一次按下即可直接拖拽滚动。
func _process(_delta: float) -> void:
	if not _submenu_open or _active_submenu == null or _active_submenu.is_embedded():
		set_process(false)
		return
	var now := Time.get_ticks_msec()
	if now - _last_submenu_open_ms < _SUBMENU_AUTOCLOSE_DELAY_MS:
		return
	# 仍停留在"刚点开子菜单"所在行附近时不收起（避免误关）：用子菜单的纵向跨度作缓冲带
	var popup := instruments_btn.get_popup()
	var mouse := DisplayServer.mouse_get_position()
	if not _window_contains(popup, mouse):
		return
	if _window_contains(_active_submenu, mouse):
		return
	# 鼠标已明确回到大类列表的其它区域 → 收起子菜单
	_active_submenu.hide()

# 判断某原生弹窗窗口是否包含某全局(OS)坐标点
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

# 选中某大类下的具体乐器，更新按钮显示并通知父节点应用（共享子菜单经 owner 定位当前音轨）
func _on_submenu_item_selected(id: int, sub: PopupMenu) -> void:
	var track = sub.get_meta("owner") as MidiTrack
	if track == null:
		return
	var category := int(sub.get_meta("category", -1))
	var list: Array = track._category_items.get(category, [])
	if id < 0 or id >= list.size():
		return
	# 拖拽滚动后松手：不选中、不关闭（与 TouchScrollOptionButton 一致）
	if track._drag_flags.get(sub, false):
		return
	var display: String = list[id]
	track.current_instrument = display
	track._current_display_name = display
	track.instruments_btn.text = display
	# 勾选切换到当前大类
	var popup = track.instruments_btn.get_popup()
	for i in popup.item_count:
		popup.set_item_checked(i, false)
	var cat_idx = popup.get_item_index(category)
	if cat_idx >= 0:
		popup.set_item_checked(cat_idx, true)
	# hide_on_item_selection=false，需手动关闭子菜单
	sub.hide()
	if track.parent_node and track.parent_node.has_method("_on_track_instrument_changed"):
		var info := InstrumentCategory.parse_display_name(display)
		track.parent_node._on_track_instrument_changed(
			track.track_index,
			track.track_channel,
			info.get("bank", 0),
			info.get("program", 0),
			info.get("name", ""))

# 由外部设置当前显示的乐器并高亮对应大类（默认显示使用中的乐器，与原来 OptionButton 一致）
func set_current_instrument(category: int, display_name: String) -> void:
	instruments_btn.text = display_name
	current_instrument = display_name
	_current_display_name = display_name
	# 大类高亮通过勾选标记体现（PopupMenu 无 select，用 set_item_checked）
	var popup := instruments_btn.get_popup()
	var idx := popup.get_item_index(category)
	if idx >= 0:
		popup.set_item_checked(idx, true)

# 外部（SoundFont 变更等）更新本轨道的乐器选项并重建两级菜单，保持当前乐器选中
func refresh_instrument_options(regular: Array, drum: Array) -> void:
	if track_channel == 9 and not drum.is_empty():
		instrument_options = drum
	elif not regular.is_empty():
		instrument_options = regular

	_build_category_items()
	_build_instrument_menus()
	_refresh_current_highlight()

# 重建后重新应用当前乐器的显示与对应大类高亮
func _refresh_current_highlight() -> void:
	if _current_display_name.is_empty():
		_current_display_name = instruments_btn.text
	if _current_display_name.is_empty():
		return
	var info := InstrumentCategory.parse_display_name(_current_display_name)
	set_current_instrument(
		InstrumentCategory.get_category(info.get("bank", 0), info.get("program", 0)),
		_current_display_name)

func _on_mute_toggled(is_pressed: bool):
	# 注意：MidiData的修改由TrackView._on_track_mute_toggled通过PlaybackDisplay处理
	# 这里仅负责UI状态更新
	mute_btn.texture_normal.region = Rect2(0, 240, 80, 80) if is_pressed else Rect2(0, 160, 80, 80)

func _on_solo_toggled(is_pressed: bool):
	solo_btn.texture_normal.region = Rect2(80, 160, 80, 80) if is_pressed else Rect2(80, 240, 80, 80)

func _on_enable_toggled(toggle_on: bool):
	if midi_data:
		midi_data.set_track_channel_enabled(track_index, track_channel, toggle_on)
	enable_btn.text = "已启用" if toggle_on else "已禁用"

	note_display.note_color = color_normal if toggle_on else color_dark
	note_display.update_color()

func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)

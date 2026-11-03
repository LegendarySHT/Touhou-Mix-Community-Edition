extends ListItemBase

class_name MidiTrack

@onready var note_display: NoteDisplayer = %NoteDisplay

@onready var track_num: Label = %TrackNum
@onready var channel_num: Label = %ChannelNum
# 切换轨道启用状态的按钮
@onready var enable_btn: Button = %EnableBtn

@onready var mute_btn: TextureButton = %MuteBtn
@onready var solo_btn: TextureButton = %SoloBtn
@onready var reset_btn: TextureButton = %ResetBtn
@onready var volume_slider: HSlider = %VolumeSlider
@onready var volume_label: Label = %VolumeText
# 乐器两级选择菜单的入口按钮；真正的菜单是 TrackView 共用的 InstrumentMenu（按下时弹过来）
@onready var instruments_btn: Button = %InstrumentBtn

# 当前菜单按钮显示的乐器名（完整 display_name）
var _current_display_name: String = ""

# 初始化时需要调节颜色的节点 除下面的之外还有self和enable_btn
@onready var track_panel: Panel = %TrackPanel
@onready var channel_panel: Panel = %ChannelPanel
@onready var note_panel: Panel = %NoteCounterPanel

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

	track_num.text   = " Track    %3d" % track_index
	channel_num.text = "Channel %3d" % track_channel

	if not instrument_options:
		if not parent_node:
			push_error("轨道 %d 初始化失败: 无父节点" % track_index)
			return
		instrument_options = parent_node.instrument_options
	if not instrument_options:
		push_error("轨道 %d 初始化失败: 无可用乐器选项" % track_index)
		return

	GLogger.info("Track %d initialized with %d instrument options" % [track_index, instrument_options.size()], "MidiTrack")

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
	t.set_color("icon_disabled_color", "Button", Color(1, 1, 1, 0.4))
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
	instruments_btn.pressed.connect(_on_instrument_pressed)
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

	_init_fin.emit()

## 乐器按钮：把菜单请求转给 TrackView 共用的那个 InstrumentMenu（全页只有一个实例）。
## 弹出位置由本行的按钮决定，选中结果回到 apply_instrument_selection。
func _on_instrument_pressed() -> void:
	if instrument_options.is_empty():
		return   # 乐器表还没就绪（音源未完成加载）：弹一个空菜单没有意义
	if parent_node == null or not parent_node.has_method("request_instrument_menu"):
		return
	parent_node.request_instrument_menu(self, instruments_btn, instrument_options,
		_current_display_name)

## 大类菜单图标用的图集（与启用按钮同源，所有音轨一致）
func get_icon_atlas() -> Texture2D:
	var tex := enable_btn.icon as AtlasTexture
	if tex == null:
		return null
	return tex.atlas

## 共用菜单选中了某个乐器：更新本行显示，并把结果交给 TrackView 应用
func apply_instrument_selection(display: String) -> void:
	current_instrument = display
	_current_display_name = display
	instruments_btn.text = display
	if parent_node and parent_node.has_method("_on_track_instrument_changed"):
		var info := InstrumentCategory.parse_display_name(display)
		parent_node._on_track_instrument_changed(
			track_index,
			track_channel,
			info.get("bank", 0),
			info.get("program", 0),
			info.get("name", ""))

# 由外部设置当前显示的乐器（默认显示使用中的乐器，与原来 OptionButton 一致）。
# 大类高亮由共用的 InstrumentMenu 在打开时按 _current_display_name 现算，这里不用管。
func set_current_instrument(_category: int, display_name: String) -> void:
	instruments_btn.text = display_name
	current_instrument = display_name
	_current_display_name = display_name

# 外部（SoundFont 变更等）更新本轨道的乐器选项，并保持当前乐器选中。
# 菜单本身由共用的 InstrumentMenu 在下次打开时按新集合重建，这里不碰它。
func refresh_instrument_options(regular: Array, drum: Array) -> void:
	if track_channel == 9 and not drum.is_empty():
		instrument_options = drum
	elif not regular.is_empty():
		instrument_options = regular

	# 菜单是 TrackView 共用的那一个，打开时会按乐器集合指纹自行重建，这里不用动它
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

func _on_solo_toggled(_is_pressed: bool):
	# 贴图规则见 refresh_solo_icon；全局刷新由 TrackView._on_track_solo_toggled 完成
	refresh_solo_icon()

# 独奏按钮贴图规则（icon_set.png 图集，80px 网格）：
# - 本轨独奏开启         → 麦克风 (80,160)
# - 无任何音轨开启独奏   → 全部麦克风（此时没有音轨被独奏静音）
# - 他人独奏中、本轨未开 → 斜杠麦克风 (80,240)
# parent_node.solo_pairs 由 TrackView 维护（{"track:channel": true}）
func refresh_solo_icon() -> void:
	var any_solo := solo_btn.button_pressed
	if not any_solo and parent_node != null:
		var solo_pairs = parent_node.get("solo_pairs")
		if solo_pairs is Dictionary:
			any_solo = not solo_pairs.is_empty()
	var show_mic := solo_btn.button_pressed or not any_solo
	solo_btn.texture_normal.region = Rect2(80, 160, 80, 80) if show_mic else Rect2(80, 240, 80, 80)

func _on_enable_toggled(toggle_on: bool):
	if midi_data:
		midi_data.set_track_channel_enabled(track_index, track_channel, toggle_on)
	enable_btn.text = "已启用" if toggle_on else "已禁用"

	note_display.note_color = color_normal if toggle_on else color_dark
	note_display.update_color()

func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)

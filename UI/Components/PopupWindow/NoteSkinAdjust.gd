extends Control

class_name NoteSkinAdjust

const NOTE_GLOW_SHADER: Shader = preload("res://UI/Components/PopupWindow/NoteGlow.gdshader")

# 长条三项模式：UI 选项索引 ↔ 工作副本配置值 的映射（顺序与 PopupWindow.tscn 中各
# OptionButton 的 popup item 顺序一致，是索引/值对应关系的唯一来源）。
#   long_connect_mode: 0=边缘连接(edge)    1=中心连接(center)
#   long_f_mode:       0=拉伸(stretch)     1=重复(repeat)    ← 注意与上一项顺序相反
#   long_stretch_mode: 0=屏幕固定(screen)  1=跟随长条(length)
const _LONG_MODE_UI_ORDER := {
	"long_connect_mode": [SkinManager.LONG_CONNECT_MODE_EDGE, SkinManager.LONG_CONNECT_MODE_CENTER],
	"long_f_mode": [SkinManager.LONG_F_MODE_STRETCH, SkinManager.LONG_F_MODE_REPEAT],
	"long_stretch_mode": [SkinManager.LONG_STRETCH_MODE_SCREEN, SkinManager.LONG_STRETCH_MODE_LENGTH],
}

# 当前编辑中的皮肤配置工作副本（结构同 SkinManager.get_skin_config 的返回）
var _working_config: Dictionary = {}
# 当前选中的皮肤名（含 [内置] 后缀）
var _current_skin_name: String = ""
# 长条预览当前使用的音符颜色（容器尺寸变化时需按同一颜色重绘）
var _long_preview_color: Color = Color.WHITE

func _ready() -> void:
	# 连 item_confirmed 而非 item_selected：拖动选项列表滚动时 TouchScrollOptionButton 会
	# 回退选中并丢弃本次选中，但 item_selected 已经发出去了，会造成"没切换却重播一遍
	# 皮肤切换动画"并重复下发 block_skin_preset
	%NoteSkinOption.item_confirmed.connect(_on_skin_option_selected)
	# 新增控件信号 — 任意变化都触发：读 UI → 更新工作副本 → 刷新预览
	%NoteConnMode.item_confirmed.connect(_on_setting_changed)
	%NoteRepeatMode.item_confirmed.connect(_on_setting_changed)
	%NoteStretchMode.item_confirmed.connect(_on_setting_changed)
	# 预览长条容器尺寸/可见性变化：按新尺寸重算身体区域与头尾矩形后重绘
	%NoteLong.resized.connect(_refresh_long_preview)
	%NoteLong.visibility_changed.connect(_refresh_long_preview)
	%NoteEnableGlow.toggled.connect(_on_setting_changed)
	# 三个音符取色器统一配置（无透明度、无预设/吸管），并升级成设置页那套「输入框 + 色块」
	for picker in [%NoteBlockColorPicker, %NoteSlideColorPicker, %NoteLongColorPicker]:
		ThemeMGR.setup_color_picker(picker, false)
	# 自定义颜色总开关：单独处理，联动启用/禁用后续颜色子项
	%NoteCustomColor.toggled.connect(_on_custom_color_toggled)
	%NoteBlockColorCheck.toggled.connect(_on_setting_changed)
	%NoteBlockColorPicker.color_changed.connect(_on_setting_changed)
	# 随机颜色：勾选时若对应音符颜色未勾选，自动勾选
	%NoteRandomBlockColor.toggled.connect(_on_random_color_toggled.bind(%NoteBlockColorCheck))
	%NoteSlideColorCheck.toggled.connect(_on_setting_changed)
	%NoteSlideColorPicker.color_changed.connect(_on_setting_changed)
	%NoteRandomSlideColor.toggled.connect(_on_random_color_toggled.bind(%NoteSlideColorCheck))
	%NoteLongColorCheck.toggled.connect(_on_setting_changed)
	%NoteLongColorPicker.color_changed.connect(_on_setting_changed)
	%NoteRandomLongColor.toggled.connect(_on_random_color_toggled.bind(%NoteLongColorCheck))

## 程序赋值同色时 color_changed 不触发，输入框需要手动补一次
func _refresh_picker_hex(picker: ColorPickerButton) -> void:
	var edit := picker.get_node_or_null("HexEdit") as LineEdit
	if edit:
		edit.text = "#" + picker.color.to_html(false)

## 自定义颜色总开关 toggled：联动启用/禁用所有颜色子项，再走通用变更流程
func _on_custom_color_toggled(pressed: bool) -> void:
	_update_color_controls_state()
	_on_setting_changed(pressed)

## 随机颜色 toggled：勾选时若对应音符颜色未勾选，自动勾选（不触发信号避免递归）
func _on_random_color_toggled(pressed: bool, enable_cb: CheckBox) -> void:
	if pressed and not enable_cb.button_pressed:
		enable_cb.set_pressed_no_signal(true)
	_on_setting_changed(pressed)

## 根据 CustomColor 勾选状态启用/禁用所有颜色子项（保持布局稳定，仅灰显）
func _update_color_controls_state() -> void:
	var enabled: bool = %NoteCustomColor.button_pressed
	%NoteBlockColorCheck.disabled = not enabled
	%NoteBlockColorPicker.disabled = not enabled
	%NoteRandomBlockColor.disabled = not enabled
	%NoteSlideColorCheck.disabled = not enabled
	%NoteSlideColorPicker.disabled = not enabled
	%NoteRandomSlideColor.disabled = not enabled
	%NoteLongColorCheck.disabled = not enabled
	%NoteLongColorPicker.disabled = not enabled
	%NoteRandomLongColor.disabled = not enabled

## 由 PopupWindow.show_note_skin_adjust 调用：刷新选项 + 应用当前皮肤到预览 + 加载工作副本
func init_adjust() -> void:
	_refresh_skin_options()
	_current_skin_name = ConfigManager.instance.get_string("block_skin_preset", SkinManager.DEFAULT_SKIN_PRESET)
	_apply_skin_to_preview(_current_skin_name)
	# 加载当前皮肤的配置到工作副本
	_working_config = SkinMGR.get_skin_config(_current_skin_name).duplicate(true)
	if _working_config.is_empty():
		# 皮肤未找到，用默认配置兜底
		_working_config = _build_default_working_config()
	_sync_ui_from_config()
	# 重置预览容器位置和透明度（防止上次切换动画残留）
	%NotePreviewRow.offset_transform_position = Vector2.ZERO
	%NotePreviewRow.modulate.a = 1.0
	# 等一帧让布局稳定后应用预览（长条 head/tail 尺寸才能正确读取）
	await get_tree().process_frame
	_apply_preview_from_config()

## 返回当前选中的皮肤名（供 PopupWindow.show_note_skin_adjust 返回）
func get_selected_skin() -> String:
	return %NoteSkinOption.get_item_text(%NoteSkinOption.selected)

## 持久化工作副本到 skin.ini 并触发 FlowArea 重载
## 由 PopupWindow 在 window_close 后调用
func save_config() -> void:
	if _current_skin_name.is_empty():
		return
	# 读一次 UI 确保工作副本是最新值（防止有信号未触发的边界情况）
	_read_ui_to_config()
	SkinMGR.save_skin_config(_current_skin_name, _working_config)
	# 通过 config_changed 触发 PlayView 的 flow_area.load_note_skin() 重载
	# set_value_and_notify 在值未变化时不发通知——只改了光效/颜色等皮肤配置而没换皮肤时，
	# block_skin_preset 不变，不会触发重载，导致切换光效要换一次皮肤才生效。
	# 这里用 set_value 写值 + 强制 emit 一次，保证皮肤配置任何改动关闭弹窗后立即应用到游戏端
	ConfigManager.instance.set_value("block_skin_preset", _current_skin_name)
	if EvtBus:
		EvtBus.config_changed.emit("block_skin_preset", _current_skin_name)

## 构造一个默认的工作副本配置（皮肤未找到时兜底）
func _build_default_working_config() -> Dictionary:
	return {
		"general": {"enable_glow": false, "custom_color": false},
		"short": {"enable_color": false, "color": Color.WHITE, "random_color": false},
		"instant": {"enable_color": false, "color": Color.WHITE, "random_color": false},
		"long": {"enable_color": false, "color": Color.WHITE, "random_color": false, "long_connect_mode": SkinMGR.LONG_CONNECT_MODE_EDGE, "long_f_mode": SkinMGR.LONG_F_MODE_REPEAT, "long_stretch_mode": SkinMGR.LONG_STRETCH_MODE_LENGTH}
	}

## 将 _working_config 同步到所有 UI 控件（不触发信号）
func _sync_ui_from_config() -> void:
	var gen: Dictionary = _working_config.get("general", {})
	_set_checkbox_no_signal(%NoteEnableGlow, bool(gen.get("enable_glow", false)))
	_set_checkbox_no_signal(%NoteCustomColor, bool(gen.get("custom_color", false)))

	var short_sec: Dictionary = _working_config.get("short", {})
	_set_checkbox_no_signal(%NoteBlockColorCheck, bool(short_sec.get("enable_color", false)))
	%NoteBlockColorPicker.color = short_sec.get("color", Color.WHITE)
	_refresh_picker_hex(%NoteBlockColorPicker)
	_set_checkbox_no_signal(%NoteRandomBlockColor, bool(short_sec.get("random_color", false)))

	var instant_sec: Dictionary = _working_config.get("instant", {})
	_set_checkbox_no_signal(%NoteSlideColorCheck, bool(instant_sec.get("enable_color", false)))
	%NoteSlideColorPicker.color = instant_sec.get("color", Color.WHITE)
	_refresh_picker_hex(%NoteSlideColorPicker)
	_set_checkbox_no_signal(%NoteRandomSlideColor, bool(instant_sec.get("random_color", false)))

	var long_sec: Dictionary = _working_config.get("long", {})
	_set_checkbox_no_signal(%NoteLongColorCheck, bool(long_sec.get("enable_color", false)))
	%NoteLongColorPicker.color = long_sec.get("color", Color.WHITE)
	_refresh_picker_hex(%NoteLongColorPicker)
	_set_checkbox_no_signal(%NoteRandomLongColor, bool(long_sec.get("random_color", false)))

	# 长条三项模式（连接/延伸/缩放基准）：经统一映射表同步，不在各处手写索引对应关系
	_sync_long_modes_from_config()

	# 根据 CustomColor 总开关状态联动启用/禁用颜色子项
	# set_pressed_no_signal 不触发 toggled，需手动同步一次控件可用状态
	_update_color_controls_state()

## 从所有 UI 控件读取值写入 _working_config
func _read_ui_to_config() -> void:
	if not _working_config.has("general"):
		_working_config["general"] = {}
	_working_config["general"]["enable_glow"] = %NoteEnableGlow.button_pressed
	_working_config["general"]["custom_color"] = %NoteCustomColor.button_pressed

	_read_note_section_to_config("short", %NoteBlockColorCheck, %NoteBlockColorPicker, %NoteRandomBlockColor)
	_read_note_section_to_config("instant", %NoteSlideColorCheck, %NoteSlideColorPicker, %NoteRandomSlideColor)
	_read_note_section_to_config("long", %NoteLongColorCheck, %NoteLongColorPicker, %NoteRandomLongColor)
	# 长条三项模式（连接/延伸/缩放基准）：经统一映射表读回，不在各处手写索引对应关系
	_read_long_modes_to_config()

func _read_note_section_to_config(key: String, enable_cb: CheckBox, picker: ColorPickerButton, random_cb: CheckBox) -> void:
	if not _working_config.has(key):
		_working_config[key] = {}
	_working_config[key]["enable_color"] = enable_cb.button_pressed
	_working_config[key]["color"] = picker.color
	_working_config[key]["random_color"] = random_cb.button_pressed

## 长条模式配置键 → 对应 OptionButton
func _long_mode_btn(key: String) -> OptionButton:
	match key:
		"long_connect_mode": return %NoteConnMode
		"long_f_mode": return %NoteRepeatMode
		"long_stretch_mode": return %NoteStretchMode
	return null

## 工作副本中的长条三项模式（缺失键兜底为 SkinManager 默认值，默认值唯一来源）
func _working_long_modes() -> Dictionary:
	var long_sec: Dictionary = _working_config.get("long", {})
	return {
		"long_connect_mode": long_sec.get("long_connect_mode", SkinManager.LONG_CONNECT_MODE_EDGE),
		"long_f_mode": long_sec.get("long_f_mode", SkinManager.LONG_F_MODE_REPEAT),
		"long_stretch_mode": long_sec.get("long_stretch_mode", SkinManager.LONG_STRETCH_MODE_LENGTH),
	}

## 将工作副本中的长条三项模式同步到 UI（select 不发射 item_selected，无需防信号）
func _sync_long_modes_from_config() -> void:
	var modes := _working_long_modes()
	for key in _LONG_MODE_UI_ORDER:
		var values: Array = _LONG_MODE_UI_ORDER[key]
		var idx := values.find(modes.get(key, values[0]))
		var btn := _long_mode_btn(key)
		if btn:
			btn.select(maxi(0, idx))

## 从 UI 读回长条三项模式写入工作副本
func _read_long_modes_to_config() -> void:
	if not _working_config.has("long"):
		_working_config["long"] = {}
	for key in _LONG_MODE_UI_ORDER:
		var values: Array = _LONG_MODE_UI_ORDER[key]
		var btn := _long_mode_btn(key)
		if btn:
			_working_config["long"][key] = values[clampi(btn.selected, 0, values.size() - 1)]

## 任意设置项变化时：读 UI → 刷新预览
func _on_setting_changed(_v) -> void:
	_read_ui_to_config()
	_apply_preview_from_config()

## 根据工作副本应用预览：颜色、光效、长条连接模式、长条延伸模式
func _apply_preview_from_config() -> void:
	var gen: Dictionary = _working_config.get("general", {})
	var custom_color_on: bool = bool(gen.get("custom_color", false))
	var enable_glow: bool = bool(gen.get("enable_glow", false))

	# 1. 颜色：
	#    custom_color ON  → 用界面上的工作值（含皮肤内 random_color），便于边改边看
	#    custom_color OFF → 与运行时同规则解析（全局手动色 / 全局随机色 / 键盘模式白色），
	#                       不再一律白色，观感与实战一致
	var block_color := Color.WHITE
	var slide_color := Color.WHITE
	var long_color := Color.WHITE
	if custom_color_on:
		block_color = _resolve_preview_color("short", %NoteBlockColorCheck, %NoteBlockColorPicker, %NoteRandomBlockColor)
		slide_color = _resolve_preview_color("instant", %NoteSlideColorCheck, %NoteSlideColorPicker, %NoteRandomSlideColor)
		long_color = _resolve_preview_color("long", %NoteLongColorCheck, %NoteLongColorPicker, %NoteRandomLongColor)
	else:
		# 预览无键盘模式语境，按非键盘模式解析（实战常见情形）
		var resolved: Dictionary = SkinManager.resolve_note_colors(
			_working_config, false, {}, _preview_global_random_colors())
		block_color = resolved.get("short", Color.WHITE)
		slide_color = resolved.get("instant", Color.WHITE)
		long_color = resolved.get("long", Color.WHITE)
	%NoteBlockCore.modulate = block_color
	%NoteSlideCore.modulate = slide_color
	_long_preview_color = long_color

	# 2. 光效：enable_glow=true 时挂 shader 并设颜色；false 时清除 material
	# 强度/范围取自全局外观设置，与运行时光效同源（PlayView 读同两项，NoteBatchDrawer 同样钳制）
	var glow_intensity: float = clampf(
		ConfigManager.instance.get_float("note_glow_intensity", 0.5), 0.0, 2.0)
	var glow_size: float = clampf(
		ConfigManager.instance.get_float("note_glow_size", 5.0), 1.0, 30.0)
	_apply_preview_glow(%NoteBlockGlow, %NoteBlock, block_color, enable_glow, glow_intensity, glow_size)
	_apply_preview_glow(%NoteSlideGlow, %NoteSlide, slide_color, enable_glow, glow_intensity, glow_size)
	# 只给 head/tail 挂光效：与运行时 GlowLayer 一致（长条 body 不画光效）
	_apply_glow_material(%NoteLongGlowTail, long_color, enable_glow, glow_intensity, glow_size)
	_apply_glow_material(%NoteLongGlowHead, long_color, enable_glow, glow_intensity, glow_size)

	# 3. 长条：连接模式 / 延伸模式 / 颜色全部交给绘制器，
	#    几何与绘制顺序与实战同源（不再依赖节点布局拼接，也就不会出现预览独有的缝隙）
	_refresh_long_preview()

## 解析预览颜色：随机模式时生成一个临时随机色（仅用于预览，不写回配置）
func _resolve_preview_color(key: String, enable_cb: CheckBox, picker: ColorPickerButton, random_cb: CheckBox) -> Color:
	if not enable_cb.button_pressed:
		return Color.WHITE
	if random_cb.button_pressed:
		# 预览时用基于 key 的固定种子，避免每次刷新都变颜色
		var seed_val: int = hash(key) % 360
		return Color.from_hsv(seed_val / 360.0, 0.8, 1.0)
	return picker.color

## 预览用的全局随机调色板代表值。
## 预览无法得知本局实际生成的随机色（NoteColorPalette 每局 randf），且每次刷新都变会闪烁，
## 故用与 NoteColorPalette 同风格的确定性代表值：饱和度/亮度取该区间中值、色相两两 >= 30°；
## sync_color_across_block_type=1 时三类型同色（与运行时一致）。
func _preview_global_random_colors() -> Dictionary:
	var unified := ConfigManager.instance.get_int("sync_color_across_block_type", 0) == 1
	var saturation := 0.9
	var value := 0.95
	if unified:
		var same := Color.from_hsv(0.55, saturation, value)
		return {"short": same, "instant": same, "long": same}
	return {
		"short": Color.from_hsv(0.10, saturation, value),
		"instant": Color.from_hsv(0.55, saturation, value),
		"long": Color.from_hsv(0.85, saturation, value),
	}

## 给预览音符的光效节点应用或清除 NoteGlow shader，并让光晕跟随音符节点尺寸
## glow_intensity / glow_size 取自全局外观设置（与运行时光效同一来源），使预览与实战观感一致
func _apply_preview_glow(glow: CanvasItem, note_root: Node, glow_color: Color, enable_glow: bool,
		glow_intensity: float, glow_size: float) -> void:
	if not _apply_glow_material(glow, glow_color, enable_glow, glow_intensity, glow_size):
		return
	_bind_glow_fit(glow, note_root)

## 给光效节点应用或清除 NoteGlow shader（不负责摆位）。
## UV 标定与运行时 GlowLayer 一致：方形 quad 贴 1/6 半径单位的光晕纹理，
## note_uv_half 固定 1/6（1 单位 = quad 边长 / 6）。
## 返回是否已挂上光效材质，供调用方决定是否需要继续摆位
func _apply_glow_material(glow: CanvasItem, glow_color: Color, enable_glow: bool,
		glow_intensity: float, glow_size: float) -> bool:
	if glow == null:
		return false
	if not enable_glow:
		glow.material = null
		return false
	var mat := glow.material as ShaderMaterial
	if mat == null or mat.shader != NOTE_GLOW_SHADER:
		mat = ShaderMaterial.new()
		mat.shader = NOTE_GLOW_SHADER
		glow.material = mat
	mat.set_shader_parameter("glow_color", glow_color)
	mat.set_shader_parameter("glow_intensity", glow_intensity)
	mat.set_shader_parameter("glow_size", glow_size)
	mat.set_shader_parameter("glow_stretch", 1.0)
	mat.set_shader_parameter("note_uv_center", Vector2(0.5, 0.5))
	mat.set_shader_parameter("note_uv_half", Vector2(1.0 / 6.0, 1.0 / 6.0))
	return true

## 让光效节点的方形 quad 跟随 note_root 尺寸重算（连接 resized，只绑一次）。
## 不能只在应用预览时拟合一次：弹窗首次打开时 init_adjust() 早于 popup()，
## 预览容器还没完成布局，节点 size 为 0 / 上一次的值，_fit_glow_quad 会直接返回，
## 于是沿用场景里 -1..2（各轴 3 倍节点尺寸）的默认锚点 —— 扁 cap（BarSolid / BarFade
## 头尾）的 quad 就变成横向拉长的扁矩形，光晕被上下压缩；切换皮肤时布局已稳定，
## 才恢复正常。
func _bind_glow_fit(glow: Node, note_root: Node) -> void:
	if glow.has_meta("_glow_fit_bound"):
		return
	glow.set_meta("_glow_fit_bound", true)
	var root_ctrl := note_root as Control
	if root_ctrl:
		# resized：布局变化后重算；visibility_changed：弹窗 popup() 后补一次
		# （首次打开时容器可能是在隐藏状态下完成布局的，只靠 resized 会漏掉）
		root_ctrl.resized.connect(_fit_glow_quad.bind(glow, note_root))
		root_ctrl.visibility_changed.connect(_fit_glow_quad.bind(glow, note_root))
	_fit_glow_quad(glow, note_root)

## 把光效节点摆成与运行时 GlowLayer 相同的方形 quad：边长 = max(节点宽, 高) * GLOW_QUAD_SCALE，
## 中心与节点重合。必须用正方形，不能用「固定 3 倍节点尺寸」：
## 细长 cap（BarSolid / BarFade 的头尾）在短边方向只有几十像素，3 倍仍远小于光晕
## 半径，光晕会在矩形上下边被硬切；正方形且边长与运行时一致时，光晕到矩形边缘已
## 衰减到约 2%，与运行时的截断程度相同。
func _fit_glow_quad(glow: Node, note_root: Node) -> void:
	var glow_ctrl := glow as Control
	var root_ctrl := note_root as Control
	if glow_ctrl == null or root_ctrl == null:
		return
	var sz: Vector2 = root_ctrl.size
	if sz.x <= 0.0 or sz.y <= 0.0:
		return
	var side: float = maxf(sz.x, sz.y) * GlowLayer.GLOW_QUAD_SCALE
	glow_ctrl.anchor_left = 0.5 - side * 0.5 / sz.x
	glow_ctrl.anchor_right = 0.5 + side * 0.5 / sz.x
	glow_ctrl.anchor_top = 0.5 - side * 0.5 / sz.y
	glow_ctrl.anchor_bottom = 0.5 + side * 0.5 / sz.y
	glow_ctrl.offset_left = 0.0
	glow_ctrl.offset_top = 0.0
	glow_ctrl.offset_right = 0.0
	glow_ctrl.offset_bottom = 0.0

## 长条预览：几何与绘制全部交给 NoteBatchDrawer（与实战同一套函数），
## 这里只决定身体区域大小、连接模式与颜色，避免节点布局拼接产生的缝隙
func _refresh_long_preview() -> void:
	var sz: Vector2 = %NoteLong.size
	if sz.x <= 0.0 or sz.y <= 0.0:
		return
	%NoteLongDrawer.set_note_width(sz.x)
	var modes := _working_long_modes()
	var center: bool = modes.get("long_connect_mode", SkinManager.LONG_CONNECT_MODE_EDGE) == SkinManager.LONG_CONNECT_MODE_CENTER
	%NoteLongDrawer.set_long_body_mode(modes.get("long_f_mode", SkinManager.LONG_F_MODE_REPEAT))
	%NoteLongDrawer.set_long_stretch_mode(modes.get("long_stretch_mode", SkinManager.LONG_STRETCH_MODE_LENGTH))
	# 头尾各按贴图宽高比缩放；edge 连接时头尾整体在身体外，center 连接时各向身体内嵌半高
	var tail_half: float = %NoteLongDrawer.get_long_tail_half_height()
	var head_half: float = %NoteLongDrawer.get_long_head_half_height()
	var vis_h: float = (tail_half + head_half) if center else (tail_half + head_half) * 2.0
	var body_h: float = maxf(sz.y - vis_h, 1.0)
	var body_top: float = (sz.y - (body_h + vis_h)) * 0.5 + (tail_half if center else tail_half * 2.0)
	%NoteLongDrawer.set_long_preview(Rect2(0.0, body_top, sz.x, body_h), center, _long_preview_color, sz.y)
	_place_long_glow()

## 按绘制器给出的头尾矩形摆放长条光效（节点只负责光晕，本体由绘制器画）
func _place_long_glow() -> void:
	var rects: Dictionary = %NoteLongDrawer.get_long_preview_rects()
	_place_preview_glow(%NoteLongGlowTail, rects["tail"])
	_place_preview_glow(%NoteLongGlowHead, rects["head"])

## 把光效摆成与运行时 GlowLayer 一致的方形 quad，中心与对应部件中心重合：
## 正方形而非按节点矩形铺开，扁 cap 的光晕才不会被矩形短边硬切
func _place_preview_glow(glow: Control, rect: Rect2) -> void:
	if glow == null:
		return
	var side: float = maxf(rect.size.x, rect.size.y) * GlowLayer.GLOW_QUAD_SCALE
	var center: Vector2 = rect.get_center()
	glow.anchor_left = 0.0
	glow.anchor_top = 0.0
	glow.anchor_right = 0.0
	glow.anchor_bottom = 0.0
	glow.offset_left = center.x - side * 0.5
	glow.offset_top = center.y - side * 0.5
	glow.offset_right = center.x + side * 0.5
	glow.offset_bottom = center.y + side * 0.5

## 不触发信号设置 CheckBox 状态
func _set_checkbox_no_signal(cb: CheckBox, pressed: bool) -> void:
	cb.set_pressed_no_signal(pressed)

# 创建完全透明的纹理用于缺失贴图回退
func _create_transparent_texture(width: int = 64, height: int = 64) -> Texture2D:
	var image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	return ImageTexture.create_from_image(image)

# 应用指定皮肤的贴图到 NotePreview 预览节点
# 复用 FlowArea.set_note_texture 的节点路径约定：
#   block/slide: 根 texture + core 子节点 texture
#   long: NoteDrawer.set_long_textures（与实战同一个绘制器）
func _apply_skin_to_preview(skin_name: String) -> void:
	var skin_textures: Dictionary = {}
	skin_textures = SkinMGR.get_skin_textures(skin_name)

	var _transparent := _create_transparent_texture()
	# 纹理数组顺序与 FlowArea.load_note_skin 一致
	var tex_arr: Array = [
		skin_textures.get("short"),
		skin_textures.get("short_core"),
		skin_textures.get("instant"),
		skin_textures.get("instant_core"),
		skin_textures.get("long_b"),
		skin_textures.get("long_b_core"),
		skin_textures.get("long_f"),
		skin_textures.get("long_f_core"),
		skin_textures.get("long_t"),
		skin_textures.get("long_t_core")
	]

	# block
	%NoteBlock.texture = tex_arr[0] if tex_arr[0] else _transparent
	%NoteBlockCore.texture = tex_arr[1] if tex_arr[1] else _transparent

	# slide
	%NoteSlide.texture = tex_arr[2] if tex_arr[2] else _transparent
	%NoteSlideCore.texture = tex_arr[3] if tex_arr[3] else _transparent

	# long: 交给与实战同源的绘制器（head / body / tail 的原图直接传入，
	# 缺层保持 null，由绘制器按同一规则回退/取参考尺寸）
	%NoteLongDrawer.set_long_textures(tex_arr[4], tex_arr[5], tex_arr[6], tex_arr[7], tex_arr[8], tex_arr[9])

# 填充皮肤选项列表，选中当前配置的皮肤
func _refresh_skin_options() -> void:
	var skin_list: Array = SkinMGR.get_available_skins()
	if skin_list.is_empty():
		skin_list = [SkinManager.DEFAULT_SKIN_PRESET]
	var current := ConfigManager.instance.get_string("block_skin_preset", SkinManager.DEFAULT_SKIN_PRESET)
	%NoteSkinOption.clear()
	for skin in skin_list:
		%NoteSkinOption.add_item(skin)
	var idx := skin_list.find(current)
	%NoteSkinOption.select(maxi(0, idx))

# 选项切换：播放上移+淡出→换皮肤→从下方上移+淡入动画，并即时应用皮肤到 PlayView
# 注意：不能用 animate_fade_out/in，因为它们会设置 visible=false（fade_out 完成后）
# 和 modulate.a=0（fade_in 开头），会导致第二段动画期间节点不可见。
# 改用 create_sequence + tween_property 直接 tween modulate:a，避免 visible 副作用。
func _on_skin_option_selected(_index: int) -> void:
	var skin_name: String = %NoteSkinOption.get_item_text(%NoteSkinOption.selected)
	# 若有动画在跑，先 kill
	AniMGR.stop_tween("popup_skin_switch_up")
	AniMGR.stop_tween("popup_skin_switch_down")
	AniMGR.stop_tween("popup_skin_switch_fade_out")
	AniMGR.stop_tween("popup_skin_switch_fade_in")
	# 第一段：上移 + 淡出（并行）
	var move_up := AniMGR.animate_offset_to(%NotePreviewRow, Vector2(0, -80), 0.25, "popup_skin_switch_up")
	var fade_out := AniMGR.create_sequence("popup_skin_switch_fade_out")
	fade_out.tween_property(%NotePreviewRow, "modulate:a", 0.0, 0.25)
	await move_up.finished
	# 应用新皮肤到预览节点
	_apply_skin_to_preview(skin_name)
	# 切换工作副本到新皮肤（丢弃旧皮肤的未保存修改）
	_current_skin_name = skin_name
	_working_config = SkinMGR.get_skin_config(skin_name).duplicate(true)
	if _working_config.is_empty():
		_working_config = _build_default_working_config()
	_sync_ui_from_config()
	# 通过 ConfigManager 即时触发 config_changed → PlayView 的 flow_area.load_note_skin()
	# （相当于把设置保存时进行的皮肤应用提前到这里）
	ConfigManager.instance.set_value_and_notify("block_skin_preset", skin_name)
	# 重置到下方位置（瞬间）
	%NotePreviewRow.offset_transform_position = Vector2(0, 80)
	# 第二段：从下方上移 + 淡入（并行）
	AniMGR.animate_offset_to(%NotePreviewRow, Vector2.ZERO, 0.25, "popup_skin_switch_down")
	var fade_in := AniMGR.create_sequence("popup_skin_switch_fade_in")
	fade_in.tween_property(%NotePreviewRow, "modulate:a", 1.0, 0.25)
	# 等一帧让布局稳定后应用预览（颜色/光效/长条模式）
	await get_tree().process_frame
	_apply_preview_from_config()

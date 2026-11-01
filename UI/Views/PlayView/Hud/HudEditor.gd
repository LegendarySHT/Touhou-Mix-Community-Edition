class_name HudEditor
extends Control

## 自定义 HUD 的浮层面板。
## 布局：本节点铺满整个打歌页并接管鼠标/触摸 —— 点空白处取消选中，
## 点中组件即选中并可直接拖动；面板（拖标题栏移动、拖右下角改大小）负责改变体、
## 锚点、偏移、缩放与动画参数。内容用 HFlowContainer 横向流动分栏，面板越宽分栏越多。
## 数据全部落在 HudComponent.data 上，保存时才写盘。

signal closed

## 面板尺寸下限 / 默认宽度占比
const MIN_W := 540.0
const MIN_H := 480.0
## 面板左右内边距（MarginContainer）
const PANEL_PAD_X := 20.0
## 预留竖向滚动条 + 内边距宽度：ScrollContainer 出现竖滚动条后内容区比容器窄这么多
const SCROLLBAR_RESERVE := 44.0
const DEFAULT_W_RATIO := 0.46
const DEFAULT_W_MAX := 1150.0
const DEFAULT_H_MAX := 940.0
const PANEL_MARGIN := 24.0
## 分栏时每个区块的最小宽度
const COLUMN_MIN_W := 360.0
## 参数行横向流动时的最小宽度
const ROW_MIN_W := 340.0
const FLOW_SEP := 12.0
## 面板内字号
const PANEL_FONT_SIZE := 32
## 入场后重摆的帧数（到 2 帧和 0 帧各摆一次）
const SETTLE_TICKS := 4

var hud: PlayHud = null

var _panel: Panel = null
var _margin: MarginContainer = null
var _vbox: VBoxContainer = null
var _scroll: ScrollContainer = null
var _scroll_body: VBoxContainer = null
var _top_flow: HFlowContainer = null
var _grip: Button = null
## 上方四个短区块（按面板宽度重算列宽）
var _top_sections: Array[Control] = []
var _params_box: HFlowContainer = null
var _params_section: Control = null
## 用户手动调过的面板尺寸（Vector2.ZERO = 用默认值）
var _want_size: Vector2 = Vector2.ZERO

var _list: OptionButton = null
var _variant: OptionButton = null
var _add_btn: Button = null
var _add_menu: PopupMenu = null
var _del_btn: Button = null

var _anchor_btns: Array[Button] = []
var _edit_ax: LineEdit = null
var _edit_ay: LineEdit = null
var _edit_ox: LineEdit = null
var _edit_oy: LineEdit = null
var _edit_scale: LineEdit = null
var _chk_visible: Button = null
var _chk_loop: Button = null
var _hint: Label = null

var _selected: HudComponent = null
var _dirty: bool = false
var _syncing: bool = false

var _drag_panel: bool = false
var _panel_moved: bool = false
## 拖动基准点（第一次移动时的坐标），不是按下点
var _panel_anchor: Vector2 = Vector2.ZERO
var _drag_comp: HudComponent = null
var _drag_touch: bool = false
var _drag_pending: bool = false
var _drag_start_pos: Vector2 = Vector2.ZERO
var _drag_start_offset: Vector2 = Vector2.ZERO

var _resizing: bool = false
## 入场后还要再重摆几次：首帧拿到的是兜底尺寸，列宽会算错（表现为内容溢出窗口）
var _settle: int = 0
## 自动贴合内容高度时防止递归


var _hint_timer: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	z_index = 30
	resized.connect(_on_root_resized)
	# 不用 anchors 拉伸：运行时 new 出来的 Control 在父节点尺寸没变过时不会重算 anchored rect，
	# 会停在 (0,0) 导致面板被摆到屏幕外。直接跟父节点尺寸对齐。
	var par := get_parent()
	if par is Control:
		if not (par as Control).resized.is_connected(_sync_full_rect):
			(par as Control).resized.connect(_sync_full_rect)
	_sync_full_rect()


func _sync_full_rect() -> void:
	var par := get_parent()
	if par is Control:
		size = (par as Control).size
		position = Vector2.ZERO
	_on_root_resized()


func setup(p_hud: PlayHud) -> void:
	hud = p_hud
	_build()
	_rebuild_component_list()
	_select_first()
	# 面板尺寸依赖 ScrollContainer 的最终最小尺寸，首帧还拿不到，延迟一帧再摆
	call_deferred("_place_panel")
	_settle = SETTLE_TICKS
	set_process(true)


func _process(delta: float) -> void:
	if _hint_timer > 0.0:
		_hint_timer -= delta
		if _hint_timer <= 0.0 and _hint != null:
			_hint.text = ""
	# 入场后重摆两次：首帧的滚动区尺寸不可靠，重摆会按真实宽度重算列宽
	if _settle > 0:
		_settle -= 1
		if _settle == 2 or _settle == 0:
			_place_panel()
	# 选中框跟着组件走：文本变化 / 预览动画都会改变尺寸，每帧重画一次（就几个矩形）
	queue_redraw()


# ==================== 构建面板 ====================

func _build() -> void:
	# 用 Panel 而不是 PanelContainer：右下角要放一个独立的缩放手柄，
	# 容器会把它拉满整块，普通 Control 才能自由摆放。
	_panel = Panel.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := StyleBoxFlat.new()
	# 打歌舞台恒为深色，编辑面板也固定深色：跟随主题会出现「浅色面板 + 深色输入框」这种混搭
	sb.bg_color = Color(0.078, 0.094, 0.133, 0.97)
	sb.border_color = Color(1, 1, 1, 0.16)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(14)
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)
	_panel.resized.connect(_layout_panel_children)

	_margin = MarginContainer.new()
	_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_margin.add_theme_constant_override("margin_left", 20)
	_margin.add_theme_constant_override("margin_right", 20)
	_margin.add_theme_constant_override("margin_top", 14)
	_margin.add_theme_constant_override("margin_bottom", 12)
	_panel.add_child(_margin)

	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 10)
	_margin.add_child(_vbox)

	_vbox.add_child(_build_title_row())

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.custom_minimum_size = Vector2(0, 300)
	# 首帧面板尺寸还没定，列宽会算错；滚动区一旦拿到真实宽度就重算一次
	_scroll.resized.connect(_update_columns)
	_vbox.add_child(_scroll)

	_scroll_body = VBoxContainer.new()
	_scroll_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll_body.add_theme_constant_override("separation", int(FLOW_SEP))
	_scroll.add_child(_scroll_body)

	# 短区块（组件/变体/锚点/偏移）横向流动，面板越宽列越多
	_top_flow = HFlowContainer.new()
	_top_flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_top_flow.add_theme_constant_override("h_separation", int(FLOW_SEP))
	_top_flow.add_theme_constant_override("v_separation", int(FLOW_SEP))
	_scroll_body.add_child(_top_flow)
	_top_sections = [
		_build_component_section(),
		_build_variant_section(),
		_build_anchor_section(),
		_build_transform_section(),
	]
	for s in _top_sections:
		_top_flow.add_child(s)

	# 参数区独占整行，内部再横向流动 —— 参数动辄十来个，跟着其它区块挤一列会很矮胖
	_params_section = _build_params_section()
	_scroll_body.add_child(_params_section)

	_hint = Label.new()
	_hint.add_theme_font_size_override("font_size", 18)
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.text = "拖组件 / 标题栏 / 右下角可移动与缩放窗口"
	_vbox.add_child(_hint)

	_grip = Button.new()
	_grip.flat = true
	_grip.text = "◢"
	_grip.focus_mode = Control.FOCUS_NONE
	_grip.mouse_default_cursor_shape = Control.CURSOR_FDIAGSIZE
	_grip.tooltip_text = "拖动调整窗口大小"
	_grip.gui_input.connect(_on_grip_input)
	_panel.add_child(_grip)

	_apply_panel_theme()


func _build_title_row() -> Control:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	head.mouse_filter = Control.MOUSE_FILTER_PASS
	head.gui_input.connect(_on_title_input)

	var title := Label.new()
	title.text = "自定义 HUD"
	title.add_theme_font_size_override("font_size", 34)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(spacer)

	var reset_btn := Button.new()
	reset_btn.text = "重置"
	reset_btn.tooltip_text = "把组件恢复为默认布局"
	reset_btn.focus_mode = Control.FOCUS_NONE
	reset_btn.pressed.connect(_on_reset_pressed)
	head.add_child(reset_btn)

	var save_btn := Button.new()
	save_btn.text = "保存"
	save_btn.focus_mode = Control.FOCUS_NONE
	save_btn.pressed.connect(_on_save_pressed)
	head.add_child(save_btn)

	var close_btn := Button.new()
	close_btn.text = "关闭"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.pressed.connect(request_close)
	head.add_child(close_btn)
	return head


func _section(title: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var l := Label.new()
	l.text = title
	l.add_theme_font_size_override("font_size", 24)
	l.modulate.a = 0.75
	box.add_child(l)
	return box


func _build_component_section() -> Control:
	var box := _section("组件")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	# 下拉独占一行：和 ＋/－ 挤一行时，按最长项撑开后会把整块顶到 450+，
	# 流式布局就排不出第二列了
	_list = OptionButton.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.fit_to_longest_item = true
	_list.item_selected.connect(_on_list_selected)
	row.add_child(_list)
	box.add_child(row)

	var row_btns := HBoxContainer.new()
	row_btns.add_theme_constant_override("separation", 8)
	_add_btn = Button.new()
	_add_btn.text = "＋ 添加"
	_add_btn.tooltip_text = "添加组件（每种最多一个）"
	_add_btn.focus_mode = Control.FOCUS_NONE
	_add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_add_btn.pressed.connect(_on_add_pressed)
	row_btns.add_child(_add_btn)

	_del_btn = Button.new()
	_del_btn.text = "－ 删除"
	_del_btn.tooltip_text = "删除当前组件"
	_del_btn.focus_mode = Control.FOCUS_NONE
	_del_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_del_btn.pressed.connect(_on_delete_pressed)
	row_btns.add_child(_del_btn)
	box.add_child(row_btns)

	_add_menu = PopupMenu.new()
	_add_menu.index_pressed.connect(_on_add_menu_pressed)
	add_child(_add_menu)
	return box


func _build_variant_section() -> Control:
	var box := _section("外观变体")
	_variant = OptionButton.new()
	_variant.fit_to_longest_item = false
	_variant.item_selected.connect(_on_variant_selected)
	box.add_child(_variant)
	return box


func _build_anchor_section() -> Control:
	var box := _section("锚点")
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	var presets := HudSchema.anchor_presets()
	for i in presets.size():
		var btn := Button.new()
		btn.text = String(presets[i]["label"])
		btn.toggle_mode = true
		btn.focus_mode = Control.FOCUS_NONE
		btn.custom_minimum_size = Vector2(84, 64)
		btn.pressed.connect(_on_anchor_preset.bind(i))
		grid.add_child(btn)
		_anchor_btns.append(btn)
	box.add_child(grid)

	var custom := HBoxContainer.new()
	custom.add_theme_constant_override("separation", 6)
	var lx := Label.new()
	lx.text = "自定义"
	lx.custom_minimum_size = Vector2(90, 0)
	custom.add_child(lx)
	_edit_ax = _make_num_edit(0.5, false, 0.0, 1.0, 2, 100.0, _on_anchor_custom_changed.bind(0))
	_edit_ay = _make_num_edit(0.5, false, 0.0, 1.0, 2, 100.0, _on_anchor_custom_changed.bind(1))
	custom.add_child(_edit_ax)
	custom.add_child(_edit_ay)
	box.add_child(custom)
	return box


func _build_transform_section() -> Control:
	var box := _section("偏移 / 缩放")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var lx := Label.new()
	lx.text = "偏移"
	lx.custom_minimum_size = Vector2(90, 0)
	row.add_child(lx)
	_edit_ox = _make_num_edit(0.0, false, -4000.0, 4000.0, 1, 110.0, _on_offset_changed.bind(0))
	_edit_oy = _make_num_edit(0.0, false, -4000.0, 4000.0, 1, 110.0, _on_offset_changed.bind(1))
	row.add_child(_edit_ox)
	row.add_child(_edit_oy)
	box.add_child(row)

	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 6)
	var ls := Label.new()
	ls.text = "缩放"
	ls.custom_minimum_size = Vector2(90, 0)
	row2.add_child(ls)
	_edit_scale = _make_num_edit(1.0, false, 0.1, 5.0, 2, 110.0, _on_scale_changed)
	row2.add_child(_edit_scale)
	box.add_child(row2)

	var row3 := HBoxContainer.new()
	row3.add_theme_constant_override("separation", 6)
	var lv := Label.new()
	lv.text = "显示"
	lv.custom_minimum_size = Vector2(90, 0)
	row3.add_child(lv)
	_chk_visible = _make_toggle(true, _on_visible_toggled)
	row3.add_child(_chk_visible)
	box.add_child(row3)
	return box


func _build_params_section() -> Control:
	var box := _section("动画 / 样式参数")
	_params_box = HFlowContainer.new()
	_params_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_params_box.add_theme_constant_override("h_separation", int(FLOW_SEP))
	_params_box.add_theme_constant_override("v_separation", 6)
	box.add_child(_params_box)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var preview_btn := Button.new()
	preview_btn.text = "预览一次"
	preview_btn.focus_mode = Control.FOCUS_NONE
	preview_btn.pressed.connect(_on_preview_pressed)
	row.add_child(preview_btn)
	var loop_label := Label.new()
	loop_label.text = "循环预览"
	row.add_child(loop_label)
	_chk_loop = _make_toggle(true, _on_loop_toggled)
	_chk_loop.custom_minimum_size = Vector2(130, 0)
	row.add_child(_chk_loop)
	box.add_child(row)
	return box


## 数字输入用纯 LineEdit（SpinBox 的上下箭头在手机上又窄又难点，内嵌输入框还常拿不到焦点）。
## 提交策略：边输入边生效（解析成功就应用），失焦 / 回车时才夹紧并格式化；
## 解析失败什么都不做 —— 不动位置、不暂存、不把用户打了一半的内容改掉。
func _make_num_edit(value: float, is_int: bool, min_v: float, max_v: float,
		decimals: int, width: float, cb: Callable) -> LineEdit:
	var le := LineEdit.new()
	le.custom_minimum_size = Vector2(width, 0)
	le.alignment = HORIZONTAL_ALIGNMENT_CENTER
	le.select_all_on_focus = true
	# 负数范围（如偏移）用全键盘：数字小键盘在多数 Android 输入法上没有减号
	le.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_DEFAULT if min_v < 0.0 \
		else LineEdit.KEYBOARD_TYPE_NUMBER_DECIMAL
	le.set_meta("is_int", is_int)
	le.set_meta("min", min_v)
	le.set_meta("max", max_v)
	le.set_meta("decimals", decimals)
	le.set_meta("last", value)
	le.set_meta("silent", false)
	le.text = _fmt_num(value, is_int, decimals)
	le.text_changed.connect(func(_t: String) -> void: _on_num_typed(le, cb))
	le.text_submitted.connect(func(_t: String) -> void: _finalize_num(le, cb))
	le.focus_exited.connect(func() -> void: _finalize_num(le, cb))
	return le


func _fmt_num(v: float, is_int: bool, decimals: int) -> String:
	if is_int:
		return str(int(round(v)))
	return ("%." + str(decimals) + "f") % v


## 宽容解析：全角数字、中文逗号、各种减号、空格都能认出来。
## 不可解析返回 NAN。
func _parse_num(raw: String) -> float:
	var norm := ""
	for i in raw.length():
		var ch := raw[i]
		var code := ch.unicode_at(0)
		if code >= 0xFF10 and code <= 0xFF19:
			norm += char(code - 0xFF10 + 48)      # 全角数字
		elif ch == "，" or ch == ",":
			norm += "."
		elif ch == "－" or ch == "−" or ch == "–":
			norm += "-"
		elif ch == "." or ch == "-":
			norm += ch
		elif code >= 48 and code <= 57:
			norm += ch
	if not norm.is_valid_float():
		return NAN
	return float(norm)


## 输入过程中：能解析且在范围内就直接应用，不重写文本（否则光标会跳、打字被打断）
func _on_num_typed(le: LineEdit, cb: Callable) -> void:
	if bool(le.get_meta("silent", false)):
		return
	var v := _parse_num(le.text)
	if is_nan(v):
		return
	if bool(le.get_meta("is_int", false)):
		v = round(v)
	if v < float(le.get_meta("min", -1e9)) or v > float(le.get_meta("max", 1e9)):
		return
	le.set_meta("last", v)
	cb.call(v)


## 失焦 / 回车：能解析就夹紧并格式化，不能解析就还原成上次的合法值
func _finalize_num(le: LineEdit, cb: Callable) -> void:
	var is_int := bool(le.get_meta("is_int", false))
	var min_v := float(le.get_meta("min", -1e9))
	var max_v := float(le.get_meta("max", 1e9))
	var last := float(le.get_meta("last", 0.0))
	var v := _parse_num(le.text)
	if is_nan(v):
		v = last
	else:
		v = clampf(v, min_v, max_v)
		if is_int:
			v = round(v)
	_set_num_text(le, v)
	if not is_equal_approx(v, last):
		le.set_meta("last", v)
		cb.call(v)


func _set_num_text(le: LineEdit, v: float) -> void:
	if le == null:
		return
	# 用户正在这个框里打字且数值一致时不要重写文本，否则光标会跳到末尾（"0." 被改成 "0.00"）
	if le.has_focus():
		var cur := _parse_num(le.text)
		if not is_nan(cur) and is_equal_approx(cur, v):
			le.set_meta("last", v)
			return
	le.set_meta("silent", true)
	le.text = _fmt_num(v, bool(le.get_meta("is_int", false)), int(le.get_meta("decimals", 2)))
	le.set_meta("silent", false)


## 面板自成一套深色主题：文字浅色、按钮/输入框深色描边，
## 不依赖全局深浅色（打歌舞台恒为深色，跟随主题会出现浅底深字/深底深字两种翻车）。
func _apply_panel_theme() -> void:
	if _panel == null:
		return
	var t := Theme.new()
	# 编辑器信息密度高，字号统一收小一档（主主题那套是给全屏页面用的）
	t.default_font_size = PANEL_FONT_SIZE
	for ft in ["Label", "Button", "OptionButton", "LineEdit", "SpinBox", "PopupMenu", "CheckBox"]:
		t.set_font_size("font_size", ft, PANEL_FONT_SIZE)
	var text := Color("#F2F5FB")
	var dim := Color("#A6B1C9")
	var primary := Color("#FF6FAE")
	if ThemeMGR != null:
		primary = ThemeMGR.get_color("primary")
	for type in ["Label", "Button", "OptionButton", "CheckBox", "CheckButton", "SpinBox", "LineEdit"]:
		t.set_color("font_color", type, text)
		t.set_color("font_hover_color", type, text)
		t.set_color("font_pressed_color", type, text)
		t.set_color("font_hover_pressed_color", type, text)
		t.set_color("font_focus_color", type, text)
		t.set_color("font_disabled_color", type, Color(dim.r, dim.g, dim.b, 0.5))
	t.set_color("font_color", "PopupMenu", text)
	t.set_color("font_hover_color", "PopupMenu", text)
	t.set_color("font_disabled_color", "PopupMenu", dim)

	# 按钮三态：半透明白底，按下时用强调色
	for spec in [
		["normal", Color(1, 1, 1, 0.08), Color(1, 1, 1, 0.0)],
		["hover", Color(1, 1, 1, 0.16), Color(primary.r, primary.g, primary.b, 0.5)],
		["pressed", Color(primary.r, primary.g, primary.b, 0.42), Color(primary.r, primary.g, primary.b, 0.9)],
		["disabled", Color(1, 1, 1, 0.03), Color(1, 1, 1, 0.0)],
		["focus", Color(1, 1, 1, 0.0), Color(primary.r, primary.g, primary.b, 0.85)],
	]:
		var b := _flat(spec[1], spec[2], 8)
		t.set_stylebox(spec[0], "Button", b)
		t.set_stylebox(spec[0], "OptionButton", b)

	# 输入框：比面板再暗一层，形成凹陷
	var input := _flat(Color(0, 0, 0, 0.30), Color(1, 1, 1, 0.18), 6)
	var input_focus := _flat(Color(0, 0, 0, 0.36), Color(primary.r, primary.g, primary.b, 0.9), 6)
	for state in ["normal", "read_only"]:
		t.set_stylebox(state, "LineEdit", input)
	t.set_stylebox("focus", "LineEdit", input_focus)

	# 下拉箭头跟随文字色
	t.set_constant("modulate_arrow", "OptionButton", 1)

	var popup := _flat(Color(0.09, 0.11, 0.15, 0.98), Color(1, 1, 1, 0.18), 8)
	popup.set_content_margin_all(6)
	t.set_stylebox("panel", "PopupMenu", popup)
	var hover := _flat(Color(primary.r, primary.g, primary.b, 0.30), Color(0, 0, 0, 0.0), 5)
	t.set_stylebox("hover", "PopupMenu", hover)

	_panel.theme = t


func _flat(bg: Color, border: Color, radius: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(6)
	return sb


## 布尔控件用「开/关」切换按钮，不用 CheckBox：勾选图标是主题贴图，
## 浅色模式下是深色勾，落在本面板的深底上看不见。
func _make_toggle(on: bool, cb: Callable) -> Button:
	var b := Button.new()
	b.toggle_mode = true
	b.button_pressed = on
	b.text = "开" if on else "关"
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(160, 0)
	b.toggled.connect(func(v: bool) -> void:
		b.text = "开" if v else "关"
		cb.call(v)
	)
	return b


# ==================== 面板位置 / 尺寸 ====================

func _avail_size() -> Vector2:
	var w := size.x - PANEL_MARGIN * 2.0
	var h := size.y - PANEL_MARGIN * 2.0
	if w < 320.0 or h < 320.0:
		# 首帧自身尺寸还没算出来，给个能用的估值，_on_root_resized 会再摆一次
		return Vector2(1000.0, 760.0)
	return Vector2(w, h)


func _place_panel() -> void:
	if _panel == null:
		return
	var avail := _avail_size()
	var w := _want_size.x if _want_size.x > 0.0 \
		else clampf(avail.x * DEFAULT_W_RATIO, MIN_W, DEFAULT_W_MAX)
	var h := _want_size.y if _want_size.y > 0.0 else minf(avail.y, DEFAULT_H_MAX)
	_panel.size = Vector2(clampf(w, MIN_W, avail.x), clampf(h, MIN_H, avail.y))
	_panel.position = Vector2(size.x - _panel.size.x - PANEL_MARGIN, PANEL_MARGIN)
	_layout_panel_children()


## 面板尺寸变化时同步内部：内边距容器铺满、缩放手柄贴右下、按可用宽度重算分栏
func _layout_panel_children() -> void:
	if _panel == null or _margin == null:
		return
	_margin.position = Vector2.ZERO
	_margin.size = _panel.size
	if _grip != null:
		var g := 44.0
		_grip.size = Vector2(g, g)
		_grip.position = Vector2(_panel.size.x - g - 2.0, _panel.size.y - g - 2.0)
	# 容器要下一帧才排完，尺寸算完再按真实宽度分栏（分栏完再贴合高度）
	_update_columns.call_deferred()


## 分栏宽度按**面板宽度**算，不按滚动区实测宽度：
## 滚动区宽度本来就是由内容最小宽度撑出来的，用它反过来算列宽会形成正反馈（列越宽 → 内容越宽 → 列更宽）。
func _update_columns() -> void:
	if _panel == null:
		return
	# 优先用滚动区实测宽度（含滚动条占位），拿不到（首帧还没排）时才用面板宽兜底。
	# 不能用内容的最小宽度反推：列宽变宽会让内容变宽，形成正反馈。
	var w := _panel.size.x - PANEL_PAD_X * 2.0 - SCROLLBAR_RESERVE
	if _scroll != null and _scroll.size.x > 120.0:
		w = _scroll.size.x - SCROLLBAR_RESERVE
	if w < 120.0:
		return
	_apply_flow_columns(_top_flow, COLUMN_MIN_W, w)
	_apply_flow_columns(_params_box, ROW_MIN_W, w)


func _apply_flow_columns(flow: HFlowContainer, min_w: float, w: float) -> void:
	if flow == null or flow.get_child_count() == 0:
		return
	var cols := maxi(1, int(floor((w + FLOW_SEP) / (min_w + FLOW_SEP))))
	var cw := (w - FLOW_SEP * float(cols - 1)) / float(cols)
	for c in flow.get_children():
		var ctrl := c as Control
		if ctrl == null:
			continue
		var want := Vector2(maxf(min_w, cw), ctrl.custom_minimum_size.y)
		if not ctrl.custom_minimum_size.is_equal_approx(want):
			ctrl.custom_minimum_size = want


func _on_root_resized() -> void:
	if _panel == null:
		return
	if not _panel_moved:
		_place_panel()
	else:
		_clamp_panel()
		_layout_panel_children()
	queue_redraw()


func _on_title_input(event: InputEvent) -> void:
	# 这里只认「按下」，且**不取坐标**：_gui_input 里 event.position 是标题栏局部坐标，
	# 而面板 position 是画布坐标，两者混用会导致偏移量巨大、一拖就飞到右下角被夹住。
	# 真正的位置全部在 _input 里按「第一次移动当基准」的增量方式处理。
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_drag_panel = true
			_drag_touch = false
			_drag_pending = true
		accept_event()
	elif event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			_drag_panel = true
			_drag_touch = true
			_drag_pending = true
		accept_event()


## 右下角缩放手柄：同样只认按下，尺寸增量在 _input 里算
func _on_grip_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_resizing = true
			_drag_touch = false
			_drag_pending = true
		accept_event()
	elif event is InputEventScreenTouch:
		if (event as InputEventScreenTouch).pressed:
			_resizing = true
			_drag_touch = true
			_drag_pending = true
		accept_event()


func _clamp_panel() -> void:
	_panel.position.x = clampf(_panel.position.x, 80.0 - _panel.size.x, maxf(0.0, size.x - 80.0))
	_panel.position.y = clampf(_panel.position.y, 0.0, maxf(0.0, size.y - 60.0))


# ==================== 组件选中与拖动 ====================

func _gui_input(event: InputEvent) -> void:
	# 只有「按下」在这里处理；拖动过程走 _input（因为拖到面板上方时本节点收不到 Motion）
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_begin_drag(get_global_mouse_position(), false)
		else:
			_end_drag()
		accept_event()
	elif event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			_begin_drag(st.position, true)
		else:
			_end_drag()
		accept_event()


func _input(event: InputEvent) -> void:
	if _resizing:
		_resize_event(event)
		return
	if _drag_panel:
		_panel_drag_event(event)
		return
	if _drag_comp != null:
		_comp_drag_event(event)


func _resize_event(event: InputEvent) -> void:
	if event is InputEventMouseMotion and not _drag_touch:
		_resize_to((event as InputEventMouseMotion).position)
	elif event is InputEventScreenDrag and _drag_touch:
		_resize_to((event as InputEventScreenDrag).position)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			_resizing = false
			_drag_pending = false
	elif event is InputEventScreenTouch:
		if not (event as InputEventScreenTouch).pressed:
			_resizing = false
			_drag_pending = false


func _resize_to(pos: Vector2) -> void:
	if _drag_pending:
		_drag_pending = false
		_panel_anchor = pos
		return
	if pos == _panel_anchor:
		return
	var d := pos - _panel_anchor
	_panel_anchor = pos
	var avail := _avail_size()
	var ns := _panel.size + d
	ns.x = clampf(ns.x, MIN_W, maxf(MIN_W, avail.x))
	ns.y = clampf(ns.y, MIN_H, maxf(MIN_H, avail.y))
	_panel.size = ns
	# 右下角往外拖时面板会顶到屏幕外：把整块往里推，保证右边/下边不出界
	_panel.position.x = clampf(_panel.position.x, 0.0, maxf(0.0, size.x - PANEL_MARGIN - ns.x))
	_panel.position.y = clampf(_panel.position.y, 0.0, maxf(0.0, size.y - PANEL_MARGIN - ns.y))
	_want_size = ns
	_panel_moved = true
	_layout_panel_children()


## 面板拖动：一律用「第一次移动当基准 + 位移增量」，不碰按下点。
## 按下点来自 _gui_input（标题栏局部坐标），移动来自 _input（视口坐标），两者不能相减。
func _panel_drag_event(event: InputEvent) -> void:
	if event is InputEventMouseMotion and not _drag_touch:
		_panel_move_to((event as InputEventMouseMotion).position)
	elif event is InputEventScreenDrag and _drag_touch:
		_panel_move_to((event as InputEventScreenDrag).position)
	elif event is InputEventMouseButton:
		# 松手不看来源：真机同时有 touch 与模拟鼠标两路事件，任一路抬起都结束拖动
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			_drag_panel = false
			_drag_pending = false
	elif event is InputEventScreenTouch:
		if not (event as InputEventScreenTouch).pressed:
			_drag_panel = false
			_drag_pending = false


func _panel_move_to(pos: Vector2) -> void:
	if _drag_pending:
		_drag_pending = false
		_panel_anchor = pos
		return
	if pos == _panel_anchor:
		return
	_panel.position += pos - _panel_anchor
	_panel_anchor = pos
	_panel_moved = true
	_clamp_panel()


func _comp_drag_event(event: InputEvent) -> void:
	if event is InputEventMouseMotion and not _drag_touch:
		_update_drag((event as InputEventMouseMotion).position)
	elif event is InputEventScreenDrag and _drag_touch:
		_update_drag((event as InputEventScreenDrag).position)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			_end_drag()
	elif event is InputEventScreenTouch:
		if not (event as InputEventScreenTouch).pressed:
			_end_drag()


func _begin_drag(gpos: Vector2, touch: bool) -> void:
	var c := _component_at(gpos)
	if c == null:
		_select(null)
		return
	_drag_touch = touch
	_drag_pending = true
	_select(c)
	_drag_comp = c
	_drag_start_offset = c.pos_offset()


func _update_drag(gpos: Vector2) -> void:
	if _drag_comp == null or not is_instance_valid(_drag_comp):
		return
	# 起点同样取「第一次移动」，避免按下点与移动点坐标系不一致导致组件跳一下
	if _drag_pending:
		_drag_pending = false
		_drag_start_pos = gpos
		return
	if gpos == _drag_start_pos:
		return
	_drag_comp.set_pos_offset(_drag_start_offset + (gpos - _drag_start_pos))
	_sync_offset_fields()
	_mark_dirty()
	queue_redraw()


func _end_drag() -> void:
	_drag_comp = null
	_drag_touch = false
	_drag_pending = false


func _component_at(gpos: Vector2) -> HudComponent:
	if hud == null:
		return null
	var comps := hud.get_components()
	for i in range(comps.size() - 1, -1, -1):
		var c: HudComponent = comps[i]
		if _visual_rect(c).has_point(gpos):
			return c
	return null


func _visual_rect(c: HudComponent) -> Rect2:
	var g := c.get_global_transform()
	var p0 := g * Vector2.ZERO
	var p1 := g * c.size
	return Rect2(Vector2(minf(p0.x, p1.x), minf(p0.y, p1.y)),
		Vector2(absf(p1.x - p0.x), absf(p1.y - p0.y)))


func _draw() -> void:
	if hud == null:
		return
	var origin := get_global_position()
	for c in hud.get_components():
		var r := _visual_rect(c)
		r.position -= origin
		var sel: bool = (c == _selected)
		draw_rect(r, Color(1.0, 0.62, 0.24, 0.95) if sel else Color(1, 1, 1, 0.22),
			false, 3.0 if sel else 1.0)
		if sel:
			draw_circle(r.position + r.size * 0.5, 4.0, Color(1.0, 0.62, 0.24, 0.95))


# ==================== 选中 / 同步 ====================

func _select_first() -> void:
	var comps := hud.get_components() if hud != null else []
	_select(comps[0] if not comps.is_empty() else null)


func _select(comp: HudComponent) -> void:
	_selected = comp
	_sync_list_selection()
	_sync_variant()
	_sync_anchor()
	_sync_offset_fields()
	_sync_scale_field()
	_sync_visible()
	_rebuild_params()
	_update_buttons()
	if not _panel_moved:
		_place_panel.call_deferred()
	queue_redraw()


func _update_buttons() -> void:
	if _del_btn != null:
		_del_btn.disabled = _selected == null
	if _variant != null:
		_variant.disabled = _selected == null


func _sync_list_selection() -> void:
	if _list == null:
		return
	_syncing = true
	var idx := -1
	for i in _list.item_count:
		var id := String(_list.get_item_metadata(i))
		if _selected != null and id == _selected.component_id:
			idx = i
			break
	if idx >= 0:
		_list.select(idx)
	_syncing = false


func _sync_variant() -> void:
	if _variant == null:
		return
	_syncing = true
	_variant.clear()
	if _selected == null:
		_syncing = false
		return
	var variants: Array = _selected.get_variants()
	for v in variants:
		_variant.add_item(String((v as Dictionary).get("name", "变体")))
	var idx := clampi(_selected.get_variant(), 0, maxi(0, variants.size() - 1))
	if variants.size() > 0:
		_variant.select(idx)
	_syncing = false


func _sync_anchor() -> void:
	_syncing = true
	var a := _selected.anchor_point() if _selected != null else Vector2(0.5, 0.5)
	for i in _anchor_btns.size():
		var preset: Vector2 = (HudSchema.anchor_presets()[i]["anchor"] as Vector2)
		_anchor_btns[i].set_pressed_no_signal(preset.is_equal_approx(a))
	_set_num_text(_edit_ax, a.x)
	_set_num_text(_edit_ay, a.y)
	_syncing = false


func _sync_offset_fields() -> void:
	_syncing = true
	var o := _selected.pos_offset() if _selected != null else Vector2.ZERO
	_set_num_text(_edit_ox, o.x)
	_set_num_text(_edit_oy, o.y)
	_syncing = false


func _sync_scale_field() -> void:
	_syncing = true
	var sc := float(_selected.data.get("scale", 1.0)) if _selected != null else 1.0
	_set_num_text(_edit_scale, sc)
	_syncing = false


func _sync_visible() -> void:
	_syncing = true
	if _chk_visible != null:
		var on := bool(_selected.data.get("visible", true)) if _selected != null else true
		_chk_visible.set_pressed_no_signal(on)
		_chk_visible.text = "开" if on else "关"
		_chk_visible.disabled = _selected == null
	_syncing = false


# ==================== 参数区 ====================

func _rebuild_params() -> void:
	if _params_box == null:
		return
	for c in _params_box.get_children():
		_params_box.remove_child(c)
		c.queue_free()
	if _selected == null:
		return
	for e in _selected.get_param_schema():
		_params_box.add_child(_make_param_row(e as Dictionary))
	# 参数量随组件变化，重建后立刻按当前宽度重新分栏（面板还没尺寸就等 _update_columns）
	if _panel != null and _panel.size.x > 120.0:
		var w := _panel.size.x - PANEL_PAD_X * 2.0 - SCROLLBAR_RESERVE
		if _scroll != null and _scroll.size.x > 120.0:
			w = _scroll.size.x - SCROLLBAR_RESERVE
		_apply_flow_columns(_params_box, ROW_MIN_W, w)


func _make_param_row(e: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.custom_minimum_size = Vector2(ROW_MIN_W, 0)
	var l := Label.new()
	l.text = String(e.get("name", ""))
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(130, 0)
	row.add_child(l)
	var key := String(e.get("key", ""))
	match String(e.get("type", "string")):
		"int":
			row.add_child(_make_num_edit(float(_selected.get_param(key, 0)), true,
				float(e.get("min", 0)), float(e.get("max", 100)), 0, 150.0,
				_on_param_number.bind(key)))
		"float":
			row.add_child(_make_num_edit(float(_selected.get_param(key, 0.0)), false,
				float(e.get("min", 0.0)), float(e.get("max", 1.0)), 2, 150.0,
				_on_param_number.bind(key)))
		"bool":
			row.add_child(_make_toggle(bool(_selected.get_param(key, false)),
				_on_param_bool.bind(key)))
		"option":
			var ob := OptionButton.new()
			ob.fit_to_longest_item = false
			ob.custom_minimum_size = Vector2(150, 0)
			var opts: Array = e.get("options", [])
			for i in opts.size():
				ob.add_item(String(opts[i]))
			ob.select(clampi(int(_selected.get_param(key, 0)), 0, maxi(0, opts.size() - 1)))
			ob.item_selected.connect(_on_param_option.bind(key))
			row.add_child(ob)
		"color":
			var cp := ColorPickerButton.new()
			cp.custom_minimum_size = Vector2(150, 40)
			cp.edit_alpha = true
			cp.color = Color.from_string(String(_selected.get_param(key, "#FFFFFF")), Color.WHITE)
			if ThemeMGR:
				ThemeMGR.setup_color_picker(cp, true)
			cp.color_changed.connect(_on_param_color.bind(key))
			row.add_child(cp)
		_:
			var le := LineEdit.new()
			le.custom_minimum_size = Vector2(150, 0)
			le.text = String(_selected.get_param(key, ""))
			le.text_changed.connect(_on_param_text.bind(key))
			row.add_child(le)
	return row


# ==================== 控件回调 ====================

func _on_list_selected(idx: int) -> void:
	if _syncing or hud == null:
		return
	var id := String(_list.get_item_metadata(idx))
	_select(hud.get_component(id))


func _rebuild_component_list() -> void:
	if _list == null or hud == null:
		return
	_syncing = true
	_list.clear()
	for c in hud.get_components():
		var comp: HudComponent = c
		_list.add_item(HudSchema.name_of(comp.component_id))
		_list.set_item_metadata(_list.item_count - 1, comp.component_id)
	_syncing = false
	_sync_list_selection()


func _on_add_pressed() -> void:
	_add_menu.clear()
	var has: Dictionary = {}
	for c in hud.get_components():
		has[(c as HudComponent).component_id] = true
	var n := 0
	for e in HudSchema.entries():
		if has.has(String(e["id"])):
			continue
		_add_menu.add_item(String(e["name"]))
		_add_menu.set_item_metadata(n, String(e["id"]))
		n += 1
	if n == 0:
		_flash_hint("所有组件都已摆放（每种最多一个）")
		return
	_add_menu.size = Vector2i(400, n * 64)
	_add_menu.position = Vector2i(_add_btn.get_screen_position() + Vector2(-200.0, 64.0))
	_add_menu.popup()


func _on_add_menu_pressed(idx: int) -> void:
	var id := String(_add_menu.get_item_metadata(idx))
	var comp := hud.add_component(id)
	if comp != null:
		_rebuild_component_list()
		_select(comp)
		_mark_dirty()


func _on_delete_pressed() -> void:
	if _selected == null:
		return
	var id := _selected.component_id
	var idx := hud.get_components().find(_selected)
	_selected = null
	hud.remove_component(id)
	_rebuild_component_list()
	var comps := hud.get_components()
	if not comps.is_empty():
		_select(comps[clampi(idx, 0, comps.size() - 1)])
	else:
		_select(null)
	_mark_dirty()


func _on_variant_selected(idx: int) -> void:
	if _syncing or _selected == null:
		return
	_selected.data["variant"] = idx
	_selected.rebuild()
	_selected.refresh_visible()
	_sync_anchor()
	_sync_offset_fields()
	_sync_scale_field()
	_rebuild_params()
	_mark_dirty()
	queue_redraw()


func _on_anchor_preset(idx: int) -> void:
	if _syncing or _selected == null:
		return
	var a: Vector2 = HudSchema.anchor_presets()[idx]["anchor"]
	# 换锚点同时清掉偏移：偏移是相对锚点的，带着旧偏移跳到对角很容易把组件顶出屏幕
	_selected.set_anchor_point(a)
	_selected.set_pos_offset(Vector2.ZERO)
	_sync_anchor()
	_sync_offset_fields()
	_mark_dirty()
	queue_redraw()


func _on_anchor_custom_changed(v: float, axis: int) -> void:
	if _syncing or _selected == null:
		return
	var a := _selected.anchor_point()
	if axis == 0:
		a.x = v
	else:
		a.y = v
	_selected.set_anchor_point(a)
	_selected.set_pos_offset(Vector2.ZERO)
	_sync_anchor()
	_sync_offset_fields()
	_mark_dirty()
	queue_redraw()


func _on_offset_changed(v: float, axis: int) -> void:
	if _syncing or _selected == null:
		return
	var o := _selected.pos_offset()
	if axis == 0:
		o.x = v
	else:
		o.y = v
	_selected.set_pos_offset(o)
	_mark_dirty()
	queue_redraw()


func _on_scale_changed(v: float) -> void:
	if _syncing or _selected == null:
		return
	_selected.set_layout("scale", v)
	_mark_dirty()
	queue_redraw()


func _on_visible_toggled(on: bool) -> void:
	if _syncing or _selected == null:
		return
	_selected.set_layout("visible", on)
	_mark_dirty()


func _on_param_number(v: float, key: String) -> void:
	if _syncing or _selected == null:
		return
	_selected.set_param(key, float(int(round(v))) if _is_int_param(key) else v)
	_selected.rebuild()
	_selected.refresh_visible()
	_mark_dirty()
	queue_redraw()


func _is_int_param(key: String) -> bool:
	for e in _selected.get_param_schema():
		if String((e as Dictionary).get("key", "")) == key:
			return String((e as Dictionary).get("type", "")) == "int"
	return false


func _on_param_bool(on: bool, key: String) -> void:
	if _syncing or _selected == null:
		return
	_selected.set_param(key, on)
	_selected.rebuild()
	_selected.refresh_visible()
	_mark_dirty()


func _on_param_option(idx: int, key: String) -> void:
	if _syncing or _selected == null:
		return
	_selected.set_param(key, idx)
	_selected.rebuild()
	_selected.refresh_visible()
	_mark_dirty()
	queue_redraw()


func _on_param_color(c: Color, key: String) -> void:
	if _syncing or _selected == null:
		return
	_selected.set_param(key, c.to_html(true))
	_selected.rebuild()
	_selected.refresh_visible()
	_mark_dirty()
	queue_redraw()


func _on_param_text(text: String, key: String) -> void:
	if _syncing or _selected == null:
		return
	_selected.set_param(key, text)
	_selected.rebuild()
	_selected.refresh_visible()
	_mark_dirty()
	queue_redraw()


func _on_preview_pressed() -> void:
	if hud != null:
		hud.preview_once()


func _on_loop_toggled(on: bool) -> void:
	if hud != null:
		hud.preview_loop = on


# ==================== 保存 / 关闭 ====================

func _mark_dirty() -> void:
	_dirty = true


func _flash_hint(text: String) -> void:
	if _hint == null:
		return
	_hint.text = text
	_hint_timer = 2.5


## 恢复默认布局：只改内存里的组件，磁盘要按「保存」才写；不保存就关掉等于放弃
func _on_reset_pressed() -> void:
	if hud == null:
		return
	var popup = PopupWindow.instance
	if popup != null:
		var ok: bool = await popup.show_message(
			"把组件恢复成默认布局？当前的调整会全部丢弃（不点保存的话，之前的布局仍会保留）。", true)
		if not ok:
			return
	_selected = null
	hud.rebuild_from_layout(HudSchema.default_layout())
	_rebuild_component_list()
	_select_first()
	_mark_dirty()
	_flash_hint("已恢复默认布局，记得保存")


func _on_save_pressed() -> void:
	if hud == null:
		return
	if hud.save_layout():
		_dirty = false
		_flash_hint("已保存")
	else:
		_flash_hint("保存失败，请检查存储目录是否可写")


## 关闭入口（面板按钮 / 返回键都走这里）：有未保存修改先弹窗确认
func request_close() -> void:
	if _dirty:
		var popup = PopupWindow.instance
		if popup != null:
			var ok: bool = await popup.show_message("有未保存的 HUD 修改，确定放弃并返回吗？", true)
			if not ok:
				return
	closed.emit()

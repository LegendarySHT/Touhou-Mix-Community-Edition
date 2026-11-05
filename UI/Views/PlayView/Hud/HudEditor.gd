class_name HudEditor
extends Control

## 自定义 HUD 的浮层面板。
## 节点树、文案、尺寸与静态样式都在 HudEditor.tscn / HudEditorTheme.tres 里，
## 本脚本只负责接线与交互；仅「动画 / 样式参数」的行随组件数据动态生成。
## 布局：本节点铺满整个打歌页并接管鼠标/触摸 —— 点空白处取消选中，
## 点中组件即选中并可直接拖动；面板（拖标题栏移动、拖右下角改大小）负责改变体、
## 锚点、偏移、缩放与动画参数。内容用 HFlowContainer 自动分栏，列数随面板宽度变化。
## 数据全部落在 HudComponent.data 上，保存时才写盘。
## 节点常驻于 PlayView，由 setup() / deactivate() 切换启用状态，不重复创建。

signal closed

## 面板尺寸下限 / 默认宽度占比
const MIN_W := 540.0
const MIN_H := 480.0
const DEFAULT_W_RATIO := 0.46
const DEFAULT_W_MAX := 1150.0
const DEFAULT_H_MAX := 940.0
const PANEL_MARGIN := 24.0
## 参数行的最小宽度；列数由 HFlowContainer 按可用宽度自行决定
const ROW_MIN_W := 340.0

var hud: PlayHud = null

# 面板节点全部写在 HudEditor.tscn 里，脚本用 % 唯一名直接访问，改层级不用改路径
## .tres 里主色相关的色值统一写这个占位色（alpha 各自保留），运行时只换 rgb
const ACCENT_PLACEHOLDER := Color(1.0, 0.435294, 0.682353, 1.0)
const DEFAULT_HINT := "拖组件 / 标题栏 / 右下角可移动与缩放窗口"


var _anchor_btns: Array[Button] = []
## 用户手动调过的面板尺寸（Vector2.ZERO = 用默认值）
var _want_size: Vector2 = Vector2.ZERO

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

var _hint_timer: float = 0.0
## 每个 StyleBoxFlat 哪些色槽原值是占位色；换主题后仍能认出已染过的色
var _accent_flags: Dictionary = {}


func _ready() -> void:
	# 常驻节点默认不参与帧/输入处理，进出编辑模式时开关
	set_process(false)
	set_process_input(false)
	resized.connect(_on_root_resized)
	_connect_controls()


## 进入编辑模式：复用场景节点，只刷新数据与主色
func setup(p_hud: PlayHud) -> void:
	hud = p_hud
	_reset_state()
	visible = true
	set_process_input(true)
	_apply_theme()
	_rebuild_component_list()
	_select_first()
	# 面板位置尺寸只依赖根节点尺寸，延后一帧摆一次；之后由 resized 跟随
	call_deferred("_place_panel")
	set_process(true)


## 退出编辑模式：关掉显示与处理，节点留在树里等下次复用
func deactivate() -> void:
	visible = false
	set_process(false)
	set_process_input(false)
	_reset_state()


func _reset_state() -> void:
	_selected = null
	_dirty = false
	_syncing = false
	_want_size = Vector2.ZERO
	_panel_moved = false
	_panel_anchor = Vector2.ZERO
	_drag_panel = false
	_drag_touch = false
	_drag_pending = false
	_drag_comp = null
	_drag_start_pos = Vector2.ZERO
	_drag_start_offset = Vector2.ZERO
	_resizing = false
	_hint_timer = 0.0
	(%Hint as Label).text = DEFAULT_HINT
	(%AddMenu as PopupMenu).clear()


func _process(delta: float) -> void:
	if _hint_timer > 0.0:
		_hint_timer -= delta
		if _hint_timer <= 0.0:
			(%Hint as Label).text = ""
	# 选中框跟着组件走：文本变化 / 预览动画都会改变尺寸，每帧重画一次（就几个矩形）
	queue_redraw()


# ==================== 场景节点接线 ====================

## 结构、文案、尺寸都在 HudEditor.tscn 里；这里只把信号和数值框的行接上
func _connect_controls() -> void:

	# 3×3 锚点按钮按子节点顺序绑定预设索引，顺序与 HudSchema.anchor_presets() 一致
	for i in mini(HudSchema.anchor_presets().size(), (%Presets as GridContainer).get_child_count()):
		var btn := (%Presets as GridContainer).get_child(i) as Button
		btn.pressed.connect(_on_anchor_preset.bind(i))
		_anchor_btns.append(btn)

	_wire_num_edit((%EditAX as LineEdit), 0.5, false, 0.0, 1.0, 2, _on_anchor_custom_changed.bind(0))
	_wire_num_edit((%EditAY as LineEdit), 0.5, false, 0.0, 1.0, 2, _on_anchor_custom_changed.bind(1))
	_wire_num_edit((%EditOX as LineEdit), 0.0, false, -4000.0, 4000.0, 1, _on_offset_changed.bind(0))
	_wire_num_edit((%EditOY as LineEdit), 0.0, false, -4000.0, 4000.0, 1, _on_offset_changed.bind(1))
	_wire_num_edit((%EditScale as LineEdit), 1.0, false, 0.1, 5.0, 2, _on_scale_changed)
	_wire_toggle((%VisibleToggle as Button), _on_visible_toggled)
	_wire_toggle((%LoopToggle as Button), _on_loop_toggled)


## 数字输入用纯 LineEdit（SpinBox 的上下箭头在手机上又窄又难点，内嵌输入框还常拿不到焦点）。
## 提交策略：边输入边生效（解析成功就应用），失焦 / 回车时才夹紧并格式化；
## 解析失败什么都不做 —— 不动位置、不暂存、不把用户打了一半的内容改掉。
func _make_num_edit(value: float, is_int: bool, min_v: float, max_v: float,
		decimals: int, width: float, cb: Callable) -> LineEdit:
	var le := LineEdit.new()
	le.custom_minimum_size = Vector2(width, 0)
	le.alignment = HORIZONTAL_ALIGNMENT_CENTER
	le.select_all_on_focus = true
	_wire_num_edit(le, value, is_int, min_v, max_v, decimals, cb)
	return le


## 场景里写好的 LineEdit 和参数区动态行共用同一套数值解析与回调
func _wire_num_edit(le: LineEdit, value: float, is_int: bool, min_v: float, max_v: float,
		decimals: int, cb: Callable) -> void:
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


## 根节点在场景里挂的就是 HudEditorTheme.tres，直接原地改这份共享资源：
## 多个控件引用同一 StyleBoxFlat 时去重后改一次即全部生效，不必复制主题。
func _apply_theme() -> void:
	var primary := ThemeMGR.get_color("primary")
	var tinted: Array[StyleBoxFlat] = []
	for type in ["Button", "OptionButton", "LineEdit", "PopupMenu"]:
		for sb_name in theme.get_stylebox_list(type):
			var sb: StyleBoxFlat = theme.get_stylebox(sb_name, type)
			if not tinted.has(sb):
				tinted.append(sb)
				_tint(sb, primary)


## 首次记下哪些色槽原值是占位色，之后按记录重染，alpha 各自保留
func _tint(sb: StyleBoxFlat, primary: Color) -> void:
	if not _accent_flags.has(sb):
		_accent_flags[sb] = [
			_same_rgb(sb.bg_color, ACCENT_PLACEHOLDER),
			_same_rgb(sb.border_color, ACCENT_PLACEHOLDER),
		]
	var flags: Array = _accent_flags[sb]
	if flags[0]:
		sb.bg_color = Color(primary.r, primary.g, primary.b, sb.bg_color.a)
	if flags[1]:
		sb.border_color = Color(primary.r, primary.g, primary.b, sb.border_color.a)


func _same_rgb(a: Color, b: Color) -> bool:
	return is_equal_approx(a.r, b.r) and is_equal_approx(a.g, b.g) and is_equal_approx(a.b, b.b)


## 布尔控件用「开/关」切换按钮，不用 CheckBox：勾选图标是主题贴图，
## 浅色模式下是深色勾，落在本面板的深底上看不见。
func _make_toggle(on: bool, cb: Callable) -> Button:
	var b := Button.new()
	b.toggle_mode = true
	b.button_pressed = on
	b.text = "开" if on else "关"
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(160, 0)
	_wire_toggle(b, cb)
	return b


func _wire_toggle(b: Button, cb: Callable) -> void:
	b.toggled.connect(func(v: bool) -> void:
		b.text = "开" if v else "关"
		cb.call(v)
	)


# ==================== 面板位置 / 尺寸 ====================

func _avail_size() -> Vector2:
	return Vector2(size.x - PANEL_MARGIN * 2.0, size.y - PANEL_MARGIN * 2.0)


func _place_panel() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return  # 根节点还没被布局，交给 resized
	var avail := _avail_size()
	var w := _want_size.x if _want_size.x > 0.0 \
		else clampf(avail.x * DEFAULT_W_RATIO, MIN_W, DEFAULT_W_MAX)
	var h := _want_size.y if _want_size.y > 0.0 else minf(avail.y, DEFAULT_H_MAX)
	(%Panel as Panel).size = Vector2(clampf(w, MIN_W, avail.x), clampf(h, MIN_H, avail.y))
	(%Panel as Panel).position = Vector2(size.x - (%Panel as Panel).size.x - PANEL_MARGIN, PANEL_MARGIN)


func _on_root_resized() -> void:
	if not visible:
		return
	if not _panel_moved:
		_place_panel()
	else:
		_clamp_panel()
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
	(%Panel as Panel).position.x = clampf((%Panel as Panel).position.x, 80.0 - (%Panel as Panel).size.x, maxf(0.0, size.x - 80.0))
	(%Panel as Panel).position.y = clampf((%Panel as Panel).position.y, 0.0, maxf(0.0, size.y - 60.0))


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
	var ns := (%Panel as Panel).size + d
	ns.x = clampf(ns.x, MIN_W, maxf(MIN_W, avail.x))
	ns.y = clampf(ns.y, MIN_H, maxf(MIN_H, avail.y))
	(%Panel as Panel).size = ns
	# 右下角往外拖时面板会顶到屏幕外：把整块往里推，保证右边/下边不出界
	(%Panel as Panel).position.x = clampf((%Panel as Panel).position.x, 0.0, maxf(0.0, size.x - PANEL_MARGIN - ns.x))
	(%Panel as Panel).position.y = clampf((%Panel as Panel).position.y, 0.0, maxf(0.0, size.y - PANEL_MARGIN - ns.y))
	_want_size = ns
	_panel_moved = true

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
	(%Panel as Panel).position += pos - _panel_anchor
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
	queue_redraw()


func _update_buttons() -> void:
	(%Delete as Button).disabled = _selected == null
	(%Variant as OptionButton).disabled = _selected == null


func _sync_list_selection() -> void:
	_syncing = true
	var idx := -1
	for i in (%ComponentList as OptionButton).item_count:
		var id := String((%ComponentList as OptionButton).get_item_metadata(i))
		if _selected != null and id == _selected.component_id:
			idx = i
			break
	if idx >= 0:
		(%ComponentList as OptionButton).select(idx)
	_syncing = false


func _sync_variant() -> void:
	_syncing = true
	(%Variant as OptionButton).clear()
	if _selected == null:
		_syncing = false
		return
	var variants: Array = _selected.get_variants()
	for v in variants:
		(%Variant as OptionButton).add_item(String((v as Dictionary).get("name", "变体")))
	var idx := clampi(_selected.get_variant(), 0, maxi(0, variants.size() - 1))
	if variants.size() > 0:
		(%Variant as OptionButton).select(idx)
	_syncing = false


func _sync_anchor() -> void:
	_syncing = true
	var a := _selected.anchor_point() if _selected != null else Vector2(0.5, 0.5)
	for i in _anchor_btns.size():
		var preset: Vector2 = (HudSchema.anchor_presets()[i]["anchor"] as Vector2)
		_anchor_btns[i].set_pressed_no_signal(preset.is_equal_approx(a))
	_set_num_text((%EditAX as LineEdit), a.x)
	_set_num_text((%EditAY as LineEdit), a.y)
	_syncing = false


func _sync_offset_fields() -> void:
	_syncing = true
	var o := _selected.pos_offset() if _selected != null else Vector2.ZERO
	_set_num_text((%EditOX as LineEdit), o.x)
	_set_num_text((%EditOY as LineEdit), o.y)
	_syncing = false


func _sync_scale_field() -> void:
	_syncing = true
	var sc := float(_selected.data.get("scale", 1.0)) if _selected != null else 1.0
	_set_num_text((%EditScale as LineEdit), sc)
	_syncing = false


func _sync_visible() -> void:
	_syncing = true
	var on := bool(_selected.data.get("visible", true)) if _selected != null else true
	(%VisibleToggle as Button).set_pressed_no_signal(on)
	(%VisibleToggle as Button).text = "开" if on else "关"
	(%VisibleToggle as Button).disabled = _selected == null
	_syncing = false


# ==================== 参数区 ====================

func _rebuild_params() -> void:
	for c in (%ParamsBox as HFlowContainer).get_children():
		(%ParamsBox as HFlowContainer).remove_child(c)
		c.queue_free()
	if _selected == null:
		return
	for e in _selected.get_param_schema():
		(%ParamsBox as HFlowContainer).add_child(_make_param_row(e as Dictionary))


func _make_param_row(e: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.custom_minimum_size = Vector2(ROW_MIN_W, 0)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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
	var id := String((%ComponentList as OptionButton).get_item_metadata(idx))
	_select(hud.get_component(id))


func _rebuild_component_list() -> void:
	if hud == null:
		return
	_syncing = true
	(%ComponentList as OptionButton).clear()
	for c in hud.get_components():
		var comp: HudComponent = c
		(%ComponentList as OptionButton).add_item(HudSchema.name_of(comp.component_id))
		(%ComponentList as OptionButton).set_item_metadata((%ComponentList as OptionButton).item_count - 1, comp.component_id)
	_syncing = false
	_sync_list_selection()


func _on_add_pressed() -> void:
	(%AddMenu as PopupMenu).clear()
	var has: Dictionary = {}
	for c in hud.get_components():
		has[(c as HudComponent).component_id] = true
	var n := 0
	for e in HudSchema.entries():
		if has.has(String(e["id"])):
			continue
		(%AddMenu as PopupMenu).add_item(String(e["name"]))
		(%AddMenu as PopupMenu).set_item_metadata(n, String(e["id"]))
		n += 1
	if n == 0:
		_flash_hint("所有组件都已摆放（每种最多一个）")
		return
	(%AddMenu as PopupMenu).size = Vector2i(400, n * 64)
	(%AddMenu as PopupMenu).position = Vector2i((%Add as Button).get_screen_position() + Vector2(-200.0, 64.0))
	(%AddMenu as PopupMenu).popup()


func _on_add_menu_pressed(idx: int) -> void:
	var id := String((%AddMenu as PopupMenu).get_item_metadata(idx))
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
	(%Hint as Label).text = text
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

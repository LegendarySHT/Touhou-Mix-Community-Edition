class_name HudComponent
extends Control

## HUD 组件基类。
## 只负责三件事：按「锚点 + 偏移 + 缩放」摆放自己、按布局参数构建视觉、消费展示数据。
## 子类实现 _build_content() 与 on_state()，不直接读写 PlayHud 内部状态。

## 组件内部动作（暂停按钮等）回传给 PlayHud
@warning_ignore("unused_signal")
signal action_requested(action: String, payload: Variant)

## 组件类型 id（与 HudSchema 注册表一致，也是布局文件里的唯一键）
var component_id: String = ""
## 组件布局字典：{id, variant, anchor, offset, scale, visible, params}
var data: Dictionary = {}
## 编辑模式：被隐藏的组件也以半透明显示，便于选中与拖动
var editing: bool = false

## 主内容节点（子类在 _build_content 里赋值），动画一律作用在它身上，
## 不能改组件自身的 scale —— 那是布局缩放，会和动画互相覆盖。
var _content: Control = null

var _tweens: Dictionary = {}
var _applying: bool = false
## apply_layout_on_len 上一次的文本长度
var _last_text_len: int = -1


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE


## 由 PlayHud 创建后调用一次
func setup(p_data: Dictionary, p_editing: bool) -> void:
	component_id = String(p_data.get("id", ""))
	data = p_data
	editing = p_editing
	# 补齐默认参数：旧布局文件缺项 / 新增参数时都靠这里兜底
	var defaults := default_params()
	var p: Dictionary = data.get("params", {})
	if not (p is Dictionary):
		p = {}
	for k in defaults:
		if not p.has(k):
			p[k] = defaults[k]
	data["params"] = p
	rebuild()
	refresh_visible()


## 重建视觉（换变体、改参数后调用）。动画状态会归零，属预期行为。
func rebuild() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_content = null
	_last_text_len = -1
	_kill_tweens()
	_build_content()
	apply_layout()


# ==================== 供子类实现 ====================

func _build_content() -> void:
	pass

## 组件参数默认值（同时是参数白名单）
func default_params() -> Dictionary:
	return {}

## 变体列表：[{"name": "显示名"}]
func get_variants() -> Array:
	return [{"name": "默认"}]

## 参数编辑表：[{key, name, type: int|float|bool|option|string|color, min, max, step, options:[String]}]
func get_param_schema() -> Array:
	return []

## 消费展示数据（state 为 PlayHud 持有的共享字典，只读）
func on_state(_state: Dictionary) -> void:
	pass


# ==================== 布局 ====================

## 重算尺寸并摆放。改布局值、内容变化后都要调一次。
func apply_layout() -> void:
	if _applying:
		return
	_applying = true
	var m := _content_min_size()
	if size != m:
		size = m
	_fill_children()
	_place()
	_applying = false


## 文本类组件的换字入口：只有文本长度变了才重排。
## 分数 / PP / 连击每秒改几十次，但最小尺寸只在位数变化时才变，
## 每帧重算等于每帧让 Label 重做一次文字排版（实测 ~16µs/次）。
func apply_layout_on_len(text: String) -> void:
	var n := text.length()
	if n == _last_text_len:
		return
	_last_text_len = n
	apply_layout()


func _content_min_size() -> Vector2:
	# 绝大多数组件只有一个内容节点，直接问它，省掉 get_children() 的数组拷贝
	var m := Vector2.ZERO
	var one: Control = _content if is_instance_valid(_content) and _content.get_parent() == self else null
	if one != null:
		m = one.get_combined_minimum_size()
	else:
		for i in get_child_count():
			var c := get_child(i) as Control
			if c != null:
				m = m.max(c.get_combined_minimum_size())
	if m.x < 1.0:
		m.x = 1.0
	if m.y < 1.0:
		m.y = 1.0
	return m


func _fill_children() -> void:
	for i in get_child_count():
		var cc := get_child(i) as Control
		if cc == null:
			continue
		cc.position = Vector2.ZERO
		cc.size = size
		cc.pivot_offset = size * 0.5


## 锚点语义：anchor 是父容器内 0~1 的归一化点，offset 是相对该点的像素偏移。
## 组件自身对应的归一化点（如 anchor=[1,0] 时的右上角）落在该点上，
## 因此四个角/四边/中心的预设都能用同一套公式，缩放时以组件中心为轴。
func _place() -> void:
	var par := get_parent()
	if not (par is Control):
		return
	var parent_size: Vector2 = (par as Control).size
	var a: Array = data.get("anchor", [0.5, 0.5])
	var off: Array = data.get("offset", [0.0, 0.0])
	var ax := clampf(float(a[0]) if a.size() > 0 else 0.5, 0.0, 1.0)
	var ay := clampf(float(a[1]) if a.size() > 1 else 0.5, 0.0, 1.0)
	var s := maxf(0.05, float(data.get("scale", 1.0)))
	var ox := float(off[0]) if off.size() > 0 else 0.0
	var oy := float(off[1]) if off.size() > 1 else 0.0
	var target := Vector2(parent_size.x * ax + ox, parent_size.y * ay + oy)
	position = target - size * 0.5 + size * s * (Vector2(0.5, 0.5) - Vector2(ax, ay))
	pivot_offset = size * 0.5
	scale = Vector2(s, s)
	if _content and is_instance_valid(_content):
		_content.pivot_offset = size * 0.5


## 布局值改动入口（编辑器用）：anchor / offset / scale / visible
## 注意：不能叫 get_anchor / set_offset —— Control 已有同名原生方法（按 Side 取锚点/偏移），重名会覆盖基类。
func set_layout(key: String, value: Variant) -> void:
	data[key] = value
	if key == "scale" or key == "anchor" or key == "offset":
		apply_layout()
	elif key == "visible":
		refresh_visible()


func anchor_point() -> Vector2:
	var a: Array = data.get("anchor", [0.5, 0.5])
	return Vector2(float(a[0]) if a.size() > 0 else 0.5, float(a[1]) if a.size() > 1 else 0.5)


func pos_offset() -> Vector2:
	var o: Array = data.get("offset", [0.0, 0.0])
	return Vector2(float(o[0]) if o.size() > 0 else 0.0, float(o[1]) if o.size() > 1 else 0.0)


func set_pos_offset(v: Vector2) -> void:
	data["offset"] = [v.x, v.y]
	apply_layout()


func set_anchor_point(v: Vector2) -> void:
	data["anchor"] = [v.x, v.y]
	apply_layout()


## 编辑态下「已隐藏」组件的透明度
const HIDDEN_ALPHA := 0.25

## 展示可见性。编辑态下不真隐藏（半透明），否则没法选中定位。
## 注意必须用 modulate 而不是 self_modulate：self_modulate 只作用于节点自身，
## 而组件的内容全在子节点里，用它对整块没有任何视觉效果。
func refresh_visible() -> void:
	var want := bool(data.get("visible", true))
	if editing:
		visible = true
		modulate = Color(1, 1, 1, 1.0 if want else HIDDEN_ALPHA)
	else:
		visible = want
		modulate = Color(1, 1, 1, 1)


## 组件自己写 modulate.a 做动画时（combo 淡出、未计入分数）要乘上这个系数，
## 否则会把编辑态的「隐藏变淡」覆盖掉。
func vis_mul() -> float:
	if editing and not bool(data.get("visible", true)):
		return HIDDEN_ALPHA
	return 1.0


# ==================== 工具 ====================

func get_param(key: String, p_default: Variant = null) -> Variant:
	var p: Dictionary = data.get("params", {})
	if p.has(key):
		return p[key]
	var d := default_params()
	if d.has(key):
		return d[key]
	return p_default


func set_param(key: String, value: Variant) -> void:
	var p: Dictionary = data.get("params", {})
	p[key] = value
	data["params"] = p


func get_variant() -> int:
	return int(data.get("variant", 0))


func has_component(id: String) -> bool:
	return component_id == id


## 取一个受本节点管理的 Tween（同名旧 Tween 会被 kill）
func _restart_tween(slot: String) -> Tween:
	var old: Tween = _tweens.get(slot)
	if old != null and old.is_valid():
		old.kill()
	var t := create_tween()
	_tweens[slot] = t
	return t


func _kill_tweens() -> void:
	for k in _tweens:
		var t: Tween = _tweens[k]
		if t != null and t.is_valid():
			t.kill()
	_tweens.clear()


func _make_label(text: String, font_size: int,
		align: int = HORIZONTAL_ALIGNMENT_CENTER) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.horizontal_alignment = align as HorizontalAlignment
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## 半粗略的等宽数字盒：数字位数变化时避免整体左右跳动
func _mono_box(l: Label) -> void:
	l.add_theme_constant_override("outline_size", 0)


func _apply_font_color(l: Label, c: Color) -> void:
	l.add_theme_color_override("font_color", c)

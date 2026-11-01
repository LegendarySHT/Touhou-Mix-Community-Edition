extends HudComponent

## 分数。数字的补间由 PlayHud 统一驱动（它持有「真分 / 显示分」的差值，
## 未计入分数组件要读同一个值），本组件只负责格式化与显示。
## 补间时长与缓动从这里读参数，所以「分数插值动画」的开关仍在分数组件上。

var _num: Label = null
var _cur: int = -1


func get_variants() -> Array:
	return [
		{"name": "纯数字"},
		{"name": "带 SCORE 标签"},
		{"name": "描边数字"},
	]


func default_params() -> Dictionary:
	return {
		"font_size": 72,
		"label_size": 36,
		"label_text": "SCORE",
		"grouping": false,
		"min_digits": 0,
		"roll_duration": 1.0,
		"roll_easing": 0,
	}


func get_param_schema() -> Array:
	return [
		{"key": "font_size", "name": "数字字号", "type": "int", "min": 8, "max": 220, "step": 1},
		{"key": "label_size", "name": "标签字号", "type": "int", "min": 0, "max": 200, "step": 1},
		{"key": "label_text", "name": "标签文本", "type": "string"},
		{"key": "grouping", "name": "千位分隔", "type": "bool"},
		{"key": "min_digits", "name": "最少位数(补零)", "type": "int", "min": 0, "max": 12, "step": 1},
		{"key": "roll_duration", "name": "插值时长(0=立即)", "type": "float",
			"min": 0.0, "max": 4.0, "step": 0.05},
		{"key": "roll_easing", "name": "插值缓动", "type": "option",
			"options": ["立方缓出", "二次缓出", "正弦", "线性"]},
	]


func _build_content() -> void:
	var v := get_variant()
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.alignment = BoxContainer.ALIGNMENT_BEGIN
	if v == 1:
		var lab := _make_label(String(get_param("label_text", "SCORE")),
			maxi(1, int(get_param("label_size", 36))), HORIZONTAL_ALIGNMENT_RIGHT)
		box.add_child(lab)
	_num = _make_label("0", maxi(1, int(get_param("font_size", 72))), HORIZONTAL_ALIGNMENT_RIGHT)
	if v == 2:
		_num.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.55))
		_num.add_theme_constant_override("shadow_outline_size", 14)
	box.add_child(_num)
	add_child(box)
	_content = box
	_num.text = format_score(maxi(_cur, 0))


func on_state(state: Dictionary) -> void:
	if _num == null:
		return
	var v := int(state.get("score_shown", 0))
	if v == _cur:
		return
	_cur = v
	_num.text = format_score(v)
	apply_layout()


func format_score(v: int) -> String:
	var s := str(maxi(v, 0))
	if bool(get_param("grouping", false)):
		s = _group_digits(s)
	var md := int(get_param("min_digits", 0))
	while s.length() < md:
		s = "0" + s
	return s


func _group_digits(s: String) -> String:
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return out

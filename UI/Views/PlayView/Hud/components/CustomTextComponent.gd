extends HudComponent

## 自定义固定文本：内容、字号、颜色全部由参数指定，不消费任何展示数据。

var _label: Label = null


func get_variants() -> Array:
	return [
		{"name": "普通"},
		{"name": "描边"},
		{"name": "背景块"},
	]


func default_params() -> Dictionary:
	return {
		"text": "自定义文本",
		"font_size": 40,
		"color": "#F2F5FB",
		"outline_size": 8,
		"bg_alpha": 0.35,
		"align": 1,
	}


func get_param_schema() -> Array:
	return [
		{"key": "text", "name": "文本内容", "type": "string"},
		{"key": "font_size", "name": "字号", "type": "int", "min": 8, "max": 200, "step": 1},
		{"key": "color", "name": "文字颜色", "type": "color"},
		{"key": "outline_size", "name": "描边宽度", "type": "int", "min": 0, "max": 30, "step": 1},
		{"key": "bg_alpha", "name": "背景块不透明度", "type": "float", "min": 0.0, "max": 1.0, "step": 0.05},
		{"key": "align", "name": "对齐", "type": "option", "options": ["左", "中", "右"]},
	]


func _align() -> int:
	match int(get_param("align", 1)):
		0:
			return HORIZONTAL_ALIGNMENT_LEFT
		2:
			return HORIZONTAL_ALIGNMENT_RIGHT
		_:
			return HORIZONTAL_ALIGNMENT_CENTER


func _color() -> Color:
	return Color.from_string(String(get_param("color", "#F2F5FB")), Color.WHITE)


func _build_content() -> void:
	var v := get_variant()
	var c := _color()
	_label = _make_label(String(get_param("text", "")), maxi(1, int(get_param("font_size", 40))), _align())
	_label.add_theme_color_override("font_color", c)
	if v == 1:
		_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		_label.add_theme_constant_override("outline_size", maxi(0, int(get_param("outline_size", 8))))
		add_child(_label)
		_content = _label
	elif v == 2:
		var pc := PanelContainer.new()
		pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# 运行时创建的容器没有 tscn 可挂样式盒，只能节点私有覆盖；底色取组件参数色
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(c.r, c.g, c.b, clampf(float(get_param("bg_alpha", 0.35)), 0.0, 1.0))
		sb.set_corner_radius_all(10)
		sb.set_content_margin_all(14)
		pc.add_theme_stylebox_override("panel", sb)
		pc.add_child(_label)
		add_child(pc)
		_content = pc
	else:
		add_child(_label)
		_content = _label

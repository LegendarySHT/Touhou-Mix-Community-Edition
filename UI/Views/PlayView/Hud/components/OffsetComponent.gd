extends HudComponent

## 正 / 负偏移指示：同一个脚本，靠 component_id（offset_early / offset_late）取不同数据。
## hold_time 为 0 时常驻到下一次判定（与旧版一致），大于 0 则到时淡出。

var _num: Label = null
var _cur_text: String = ""
var _last_seq: int = -1


func get_variants() -> Array:
	return [
		{"name": "原样（+12.3 ms）"},
		{"name": "仅数字"},
		{"name": "箭头"},
	]


func default_params() -> Dictionary:
	return {
		"font_size": 32,
		"hold_time": 0.0,
		"fade_duration": 0.35,
		"use_color": false,
		"early_color": "#6FC3FF",
		"late_color": "#FF7B7B",
	}


func get_param_schema() -> Array:
	return [
		{"key": "font_size", "name": "字号", "type": "int", "min": 8, "max": 160, "step": 1},
		{"key": "hold_time", "name": "停留时长(0=常驻)", "type": "float",
			"min": 0.0, "max": 5.0, "step": 0.05},
		{"key": "fade_duration", "name": "淡出时长(秒)", "type": "float",
			"min": 0.05, "max": 3.0, "step": 0.05},
		{"key": "use_color", "name": "按正负着色", "type": "bool"},
		{"key": "early_color", "name": "正偏移颜色", "type": "color"},
		{"key": "late_color", "name": "负偏移颜色", "type": "color"},
	]


func _is_early() -> bool:
	return component_id == "offset_early"


func _build_content() -> void:
	_num = _make_label(_cur_text, maxi(1, int(get_param("font_size", 32))))
	add_child(_num)
	_content = _num
	_num.modulate.a = 0.0


func _format(raw: String) -> String:
	if raw.is_empty():
		return ""
	var body := raw.replace(" ms", "").strip_edges()
	match get_variant():
		1:
			return body.trim_prefix("+")
		2:
			if body.begins_with("+"):
				return "↑ %s" % body.substr(1)
			if body.begins_with("-"):
				return "↓ %s" % body.substr(1)
			return body
		_:
			return raw


func on_state(state: Dictionary) -> void:
	if _num == null:
		return
	var raw := String(state.get("early_text", "")) if _is_early() else String(state.get("late_text", ""))
	var txt := _format(raw)
	if txt != _cur_text:
		_cur_text = txt
		_num.text = txt
		if not txt.is_empty() and bool(get_param("use_color", false)):
			var key := "early_color" if _is_early() else "late_color"
			_num.add_theme_color_override("font_color",
				Color.from_string(String(get_param(key, "#FFFFFF")), Color.WHITE))
		apply_layout()
	# 偏移指示只在真正的判定上重播停留/淡出（长条 tick 不刷）
	var seq := int(state.get("judge_seq", 0))
	if seq == _last_seq:
		return
	_last_seq = seq
	if txt.is_empty():
		_num.modulate.a = 0.0
		return
	_num.modulate.a = 1.0
	var hold := float(get_param("hold_time", 0.0))
	if hold <= 0.0:
		return
	var fd := maxf(0.05, float(get_param("fade_duration", 0.35)))
	var t := _restart_tween("hold")
	t.tween_interval(hold)
	t.tween_property(_num, "modulate:a", 0.0, fd)

extends HudComponent

## 正 / 负偏移指示：同一个脚本，靠 component_id（offset_early / offset_late）取不同数据。
## 判定后停留 hold_time 再淡出 fade_duration；打开 stay 则一直显示到下一次判定。
## 偏移数字宽度随判定变化，构建时按最宽样例预留，之后换数字不再重排。

## 预留宽度用的样例文本（按变体取不同格式）
const SAMPLE_TEXT := {
	0: ["+888.8 ms", "-888.8 ms"],
	1: ["888.8"],
	2: ["↑ 888.8", "↓ 888.8"],
}

var _num: Label = null
var _cur_text: String = ""
var _cur_color: Color = Color(-1.0, -1.0, -1.0, -1.0)
var _last_seq: int = -1
## 是否已按最宽样例预留宽度（字体还未就绪时退回逐次重排）
var _fixed_width: bool = false


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
		"fade_duration": 2.0,
		"stay": false,
		"use_color": false,
		"early_color": "#6FC3FF",
		"late_color": "#FF7B7B",
	}


func get_param_schema() -> Array:
	return [
		{"key": "font_size", "name": "字号", "type": "int", "min": 8, "max": 160, "step": 1},
		{"key": "hold_time", "name": "停留时长(秒)", "type": "float",
			"min": 0.0, "max": 5.0, "step": 0.05},
		{"key": "fade_duration", "name": "淡出时长(秒)", "type": "float",
			"min": 0.05, "max": 5.0, "step": 0.05},
		{"key": "stay", "name": "常驻不消失", "type": "bool"},
		{"key": "use_color", "name": "按正负着色", "type": "bool"},
		{"key": "early_color", "name": "正偏移颜色", "type": "color"},
		{"key": "late_color", "name": "负偏移颜色", "type": "color"},
	]


func _is_early() -> bool:
	return component_id == "offset_early"


func _build_content() -> void:
	var fs := maxi(1, int(get_param("font_size", 32)))
	_num = _make_label(_cur_text, fs)
	add_child(_num)
	_content = _num
	_fixed_width = false
	_reserve_width(fs)
	_num.modulate.a = 0.0
	_cur_color = Color(-1.0, -1.0, -1.0, -1.0)


## 按当前变体最宽的样例文本预留宽度，避免数字位数变化时重排
func _reserve_width(fs: int) -> void:
	var font := _num.get_theme_font("font")
	if font == null:
		return
	var samples: Array = SAMPLE_TEXT.get(get_variant(), SAMPLE_TEXT[0])
	var w := 0.0
	for t in samples:
		w = maxf(w, font.get_string_size(String(t), HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
	if w <= 0.0:
		return
	_fixed_width = true
	_num.custom_minimum_size.x = w


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
	var txt_changed := txt != _cur_text
	if txt_changed:
		_cur_text = txt
		_num.text = txt
		if not _fixed_width:
			apply_layout()
	if not txt.is_empty() and bool(get_param("use_color", false)) and (txt_changed or _cur_color.a < 0.0):
		var key := "early_color" if _is_early() else "late_color"
		var cl := Color.from_string(String(get_param(key, "#FFFFFF")), Color.WHITE)
		if cl != _cur_color:
			_cur_color = cl
			_num.add_theme_color_override("font_color", cl)
	# 偏移指示只在真正的判定上重播停留/淡出（长条 tick 不刷）
	var seq := int(state.get("judge_seq", 0))
	if seq == _last_seq:
		return
	_last_seq = seq
	if txt.is_empty():
		_kill_tweens()
		_num.modulate.a = 0.0
		return
	_num.modulate.a = 1.0
	if bool(get_param("stay", false)):
		_kill_tweens()
		return
	var hold := maxf(0.0, float(get_param("hold_time", 0.0)))
	var fd := maxf(0.05, float(get_param("fade_duration", 2.0)))
	var t := _restart_tween("hold")
	if hold > 0.0:
		t.tween_interval(hold)
	t.tween_property(_num, "modulate:a", 0.0, fd)

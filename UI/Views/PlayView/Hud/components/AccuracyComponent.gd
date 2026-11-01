extends HudComponent

## 当前准确度。

var _num: Label = null
var _label: Label = null
var _cur_text: String = ""
var _last_seq: int = -1


func get_variants() -> Array:
	return [
		{"name": "百分比"},
		{"name": "前缀标签"},
		{"name": "标签在上"},
	]


func default_params() -> Dictionary:
	return {
		"font_size": 64,
		"decimals": 2,
		"prefix": "ACC",
		"suffix": "%",
		"pulse": false,
		"pulse_scale": 1.06,
	}


func get_param_schema() -> Array:
	return [
		{"key": "font_size", "name": "字号", "type": "int", "min": 8, "max": 200, "step": 1},
		{"key": "decimals", "name": "小数位", "type": "int", "min": 0, "max": 4, "step": 1},
		{"key": "prefix", "name": "前缀文本", "type": "string"},
		{"key": "suffix", "name": "后置文本", "type": "string"},
		{"key": "pulse", "name": "判定时脉冲", "type": "bool"},
		{"key": "pulse_scale", "name": "脉冲缩放", "type": "float", "min": 1.0, "max": 1.5, "step": 0.01},
	]


func _build_content() -> void:
	var v := get_variant()
	var fs := maxi(1, int(get_param("font_size", 64)))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if v == 2:
		_label = _make_label(String(get_param("prefix", "ACC")), maxi(1, int(fs * 0.5)),
			HORIZONTAL_ALIGNMENT_RIGHT)
		box.add_child(_label)
	_num = _make_label(_compose(1.0), fs, HORIZONTAL_ALIGNMENT_RIGHT)
	box.add_child(_num)
	add_child(box)
	_content = box


func _compose(acc: float) -> String:
	var d := clampi(int(get_param("decimals", 2)), 0, 4)
	var body := String.num(acc * 100.0, d)
	var pre := String(get_param("prefix", "ACC"))
	var suf := String(get_param("suffix", "%"))
	if get_variant() == 1:
		pre = pre + " "
	else:
		pre = ""
	return "%s%s%s" % [pre, body, suf]


func on_state(state: Dictionary) -> void:
	if _num == null:
		return
	var acc := float(state.get("accuracy", 1.0))
	var txt := _compose(acc)
	var seq := int(state.get("judge_seq", 0))
	var new_judge := seq != _last_seq
	if txt != _cur_text:
		_cur_text = txt
		_num.text = txt
		apply_layout()
	if not new_judge:
		return
	_last_seq = seq
	if not bool(get_param("pulse", false)):
		return
	var ps := clampf(float(get_param("pulse_scale", 1.06)), 1.0, 1.5)
	_num.pivot_offset = _num.size * 0.5
	_num.scale = Vector2.ONE * ps
	var t := _restart_tween("pulse")
	t.tween_property(_num, "scale", Vector2.ONE, 0.16)

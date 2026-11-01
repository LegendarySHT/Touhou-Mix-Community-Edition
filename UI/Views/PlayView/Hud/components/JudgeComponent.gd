extends HudComponent

## 判定指示（Perfect / Great / ...）。每次判定重播：随机角度 + 回正 + 缩放脉冲 + 淡出。

var _num: Label = null
var _cur_text: String = ""
var _last_seq: int = -1


func get_variants() -> Array:
	return [
		{"name": "文字"},
		{"name": "文字 + 辉光"},
		{"name": "描边"},
	]


func default_params() -> Dictionary:
	return {
		"font_size": 72,
		"random_rotation": 5.0,
		"pulse_scale": 1.1,
		"in_duration": 0.1,
		"hold_time": 0.0,
		"fade_duration": 2.0,
		"uppercase": false,
		"bold": true,
	}


func get_param_schema() -> Array:
	return [
		{"key": "font_size", "name": "字号", "type": "int", "min": 8, "max": 220, "step": 1},
		{"key": "random_rotation", "name": "随机角度(度)", "type": "float",
			"min": 0.0, "max": 30.0, "step": 0.5},
		{"key": "pulse_scale", "name": "起始缩放", "type": "float", "min": 1.0, "max": 2.0, "step": 0.02},
		{"key": "in_duration", "name": "弹入时长(秒)", "type": "float",
			"min": 0.02, "max": 0.8, "step": 0.01},
		{"key": "hold_time", "name": "停留时长(秒)", "type": "float", "min": 0.0, "max": 5.0, "step": 0.05},
		{"key": "fade_duration", "name": "淡出时长(秒)", "type": "float",
			"min": 0.1, "max": 6.0, "step": 0.05},
		{"key": "uppercase", "name": "全大写", "type": "bool"},
		{"key": "bold", "name": "加粗", "type": "bool"},
	]


func _build_content() -> void:
	var fs := maxi(1, int(get_param("font_size", 72)))
	_num = _make_label(_cur_text, fs)
	if bool(get_param("bold", true)):
		var fv := FontVariation.new()
		var base := get_theme_default_font()
		if base != null:
			fv.base_font = base
			fv.variation_embolden = 0.5
			_num.add_theme_font_override("font", fv)
	match get_variant():
		1:
			_num.add_theme_color_override("font_shadow_color", Color(1, 1, 1, 0.45))
			_num.add_theme_constant_override("shadow_outline_size", 24)
		2:
			_num.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
			_num.add_theme_constant_override("outline_size", 10)
	add_child(_num)
	_content = _num
	_num.modulate.a = 0.0


func on_state(state: Dictionary) -> void:
	if _num == null:
		return
	var txt := String(state.get("judge_text", ""))
	if txt.is_empty():
		return
	if bool(get_param("uppercase", false)):
		txt = txt.to_upper()
	var seq := int(state.get("judge_seq", 0))
	var changed := txt != _cur_text
	if changed:
		_cur_text = txt
		_num.text = txt
		_num.add_theme_color_override("font_color", state.get("judge_color", Color.WHITE))
		apply_layout()
	if seq == _last_seq:
		return
	_last_seq = seq
	_play()


func _play() -> void:
	if _num == null:
		return
	var rot_max := clampf(float(get_param("random_rotation", 5.0)), 0.0, 30.0)
	var ps := clampf(float(get_param("pulse_scale", 1.1)), 1.0, 2.0)
	var in_dur := maxf(0.02, float(get_param("in_duration", 0.1)))
	var hold := maxf(0.0, float(get_param("hold_time", 0.0)))
	var fade := maxf(0.1, float(get_param("fade_duration", 2.0)))

	_num.modulate.a = 1.0
	_num.pivot_offset = _num.size * 0.5
	_num.rotation_degrees = randf_range(-rot_max, rot_max)
	_num.scale = Vector2.ONE * ps

	var t := _restart_tween("judge")
	t.set_parallel(true)
	t.tween_property(_num, "scale", Vector2.ONE, in_dur)
	t.tween_property(_num, "rotation_degrees", 0.0, in_dur)
	t.set_parallel(false)
	if hold > 0.0:
		t.tween_interval(hold)
	t.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	t.tween_property(_num, "modulate:a", 0.0, fade)

extends HudComponent

## 本次得分（原来的 Score/add）：显示最近一次判定加了多少分。
## 每次判定重播：缩放脉冲 → 停留 → 淡出。

var _num: Label = null
var _last_seq: int = -1


func get_variants() -> Array:
	return [
		{"name": "+N"},
		{"name": "N"},
		{"name": "↑N"},
	]


func default_params() -> Dictionary:
	return {
		"font_size": 48,
		"pulse_scale": 1.1,
		"pulse_duration": 0.1,
		"hold_time": 0.0,
		"fade_duration": 2.0,
	}


func get_param_schema() -> Array:
	return [
		{"key": "font_size", "name": "字号", "type": "int", "min": 8, "max": 200, "step": 1},
		{"key": "pulse_scale", "name": "脉冲缩放", "type": "float", "min": 1.0, "max": 2.5, "step": 0.02},
		{"key": "pulse_duration", "name": "脉冲时长(秒)", "type": "float",
			"min": 0.02, "max": 0.6, "step": 0.01},
		{"key": "hold_time", "name": "停留时长(秒)", "type": "float", "min": 0.0, "max": 5.0, "step": 0.05},
		{"key": "fade_duration", "name": "淡出时长(秒)", "type": "float",
			"min": 0.05, "max": 5.0, "step": 0.05},
	]


func _build_content() -> void:
	_num = _make_label(_format(0), maxi(1, int(get_param("font_size", 48))),
		HORIZONTAL_ALIGNMENT_RIGHT)
	_num.modulate.a = 0.0
	add_child(_num)
	_content = _num


func _format(v: int) -> String:
	match get_variant():
		1:
			return str(maxi(v, 0))
		2:
			return "↑%d" % maxi(v, 0)
		_:
			return "+%d" % maxi(v, 0)


func on_state(state: Dictionary) -> void:
	if _num == null:
		return
	var seq := int(state.get("judge_seq", 0))
	var add := int(state.get("score_add", 0))
	var txt := _format(add)
	# 文本变了就刷（编辑模式回填示例值时不带新判定序号）；动画只在真正的新判定上播
	if txt != _num.text:
		_num.text = txt
		apply_layout()
	if seq == _last_seq:
		return
	_last_seq = seq
	if add == 0:
		return
	_num.modulate.a = 1.0
	_num.pivot_offset = _num.size * 0.5
	var ps := clampf(float(get_param("pulse_scale", 1.1)), 1.0, 2.5)
	var pd := maxf(0.02, float(get_param("pulse_duration", 0.1)))
	var hold := maxf(0.0, float(get_param("hold_time", 0.0)))
	var fd := maxf(0.05, float(get_param("fade_duration", 2.0)))
	var t := _restart_tween("burst")
	t.set_parallel(true)
	_num.scale = Vector2.ONE * ps
	t.tween_property(_num, "scale", Vector2.ONE, pd)
	t.set_parallel(false)
	if hold > 0.0:
		t.tween_interval(hold)
	t.tween_property(_num, "modulate:a", 0.0, fd)

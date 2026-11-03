extends HudComponent

## Combo 计数：数字 + 固定文本两段，按变体决定排列方式。
## 动效（弹跳 / 滚动 / 上浮）只作用于内容容器，不碰组件自身的布局缩放。

var _num: Label = null
var _txt: Label = null
var _cur: int = -1
var _roll_from: float = 0.0


func get_variants() -> Array:
	return [
		{"name": "数字 + 文本"},
		{"name": "仅数字"},
		{"name": "文本在上"},
		{"name": "辉光数字"},
	]


func default_params() -> Dictionary:
	return {
		"font_size": 48,
		"text_size": 42,
		"text": "COMBO",
		"anim": 1,
		"anim_amplitude": 0.25,
		"anim_duration": 0.12,
		"fade_delay": 0.0,
		"fade_duration": 0.5,
		"fade_alpha": 0.0,
		"hide_when_zero": false,
		"shadow": false,
	}


func get_param_schema() -> Array:
	return [
		{"key": "font_size", "name": "数字字号", "type": "int", "min": 8, "max": 200, "step": 1},
		{"key": "text_size", "name": "文本字号", "type": "int", "min": 0, "max": 200, "step": 1},
		{"key": "text", "name": "文本内容", "type": "string"},
		{"key": "anim", "name": "数字动效", "type": "option", "options": ["无", "弹跳", "滚动", "上浮"]},
		{"key": "anim_amplitude", "name": "动效幅度", "type": "float", "min": 0.0, "max": 1.5, "step": 0.05},
		{"key": "anim_duration", "name": "动效时长(秒)", "type": "float", "min": 0.02, "max": 0.6, "step": 0.01},
		{"key": "fade_delay", "name": "淡出延迟(0=关)", "type": "float", "min": 0.0, "max": 6.0, "step": 0.1},
		{"key": "fade_duration", "name": "淡出时长(秒)", "type": "float", "min": 0.05, "max": 3.0, "step": 0.05},
		{"key": "fade_alpha", "name": "淡出透明度", "type": "float", "min": 0.0, "max": 1.0, "step": 0.05},
		{"key": "hide_when_zero", "name": "Combo 为 0 时隐藏", "type": "bool"},
		{"key": "shadow", "name": "数字发光阴影", "type": "bool"},
	]


func _build_content() -> void:
	var v := get_variant()
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.alignment = BoxContainer.ALIGNMENT_BEGIN
	_num = _make_label(str(maxi(_cur, 0)), maxi(1, int(get_param("font_size", 48))))
	_txt = _make_label(String(get_param("text", "COMBO")), maxi(1, int(get_param("text_size", 42))))
	if bool(get_param("shadow", false)) or v == 3:
		_num.add_theme_color_override("font_shadow_color", Color(1, 1, 1, 0.35))
		_num.add_theme_constant_override("shadow_outline_size", 18)
	match v:
		1:
			box.add_child(_num)
		2:
			box.add_child(_txt)
			box.add_child(_num)
		_:
			box.add_child(_num)
			box.add_child(_txt)
	add_child(box)
	_content = box


func on_state(state: Dictionary) -> void:
	if _num == null:
		return
	var v := int(state.get("combo", 0))
	if v == _cur:
		return
	var first := _cur < 0
	_cur = v
	_apply_zero_visibility()
	var txt := str(v)
	_num.text = txt
	if first or v <= 0:
		modulate.a = vis_mul()
		apply_layout_on_len(txt)
		return
	match int(get_param("anim", 1)):
		1:
			_play_pop()
		2:
			_play_roll()
		3:
			_play_slide()
		_:
			pass
	apply_layout_on_len(txt)
	_restart_fade()


## 0 连击时整块隐去（不动 visible，那个由布局的「显示」开关和编辑态管辖）
func _apply_zero_visibility() -> void:
	if not bool(get_param("hide_when_zero", false)):
		return
	modulate.a = 0.0 if _cur <= 0 else vis_mul()


func _play_pop() -> void:
	if _content == null:
		return
	var amp := clampf(float(get_param("anim_amplitude", 0.25)), 0.0, 1.5)
	var dur := maxf(0.02, float(get_param("anim_duration", 0.12)))
	_content.pivot_offset = _content.size * 0.5
	_content.scale = Vector2.ONE * (1.0 + amp)
	var t := _restart_tween("pop")
	t.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_property(_content, "scale", Vector2.ONE, dur)


func _play_roll() -> void:
	var to := float(_cur)
	var from := _roll_from
	if from >= to or from <= 0.0:
		from = maxf(0.0, to - 1.0)
	_roll_from = to
	var dur := maxf(0.05, float(get_param("anim_duration", 0.12)) * 4.0)
	var t := _restart_tween("roll")
	t.tween_method(_set_roll_text, from, to, dur)


func _set_roll_text(v: float) -> void:
	if _num == null:
		return
	_num.text = str(int(round(v)))
	apply_layout()


func _play_slide() -> void:
	if _content == null:
		return
	var amp := clampf(float(get_param("anim_amplitude", 0.25)), 0.0, 1.5)
	var dy := -maxf(6.0, size.y * amp)
	var dur := maxf(0.05, float(get_param("anim_duration", 0.12)) * 2.0)
	_content.position = Vector2(0.0, dy)
	_content.modulate.a = 0.0
	var t := _restart_tween("slide")
	t.set_parallel(true)
	t.tween_property(_content, "position", Vector2.ZERO, dur)
	t.tween_property(_content, "modulate:a", 1.0, dur)


func _restart_fade() -> void:
	var delay := float(get_param("fade_delay", 0.0))
	if delay <= 0.0:
		modulate.a = vis_mul()
		return
	var target_alpha := clampf(float(get_param("fade_alpha", 0.0)), 0.0, 1.0) * vis_mul()
	var dur := maxf(0.05, float(get_param("fade_duration", 0.5)))
	modulate.a = vis_mul()
	var t := _restart_tween("fade")
	t.tween_interval(delay)
	t.tween_property(self, "modulate:a", target_alpha, dur)

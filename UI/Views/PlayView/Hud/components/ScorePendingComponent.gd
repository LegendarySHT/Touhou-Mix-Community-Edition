extends HudComponent

## 尚未计入的分数：真分与显示分的差值，随分数补间回落逐帧减少。

var _num: Label = null
var _cur: int = -1


func get_variants() -> Array:
	return [
		{"name": "N"},
		{"name": "(N)"},
		{"name": "未计入 N"},
	]


func default_params() -> Dictionary:
	return {
		"font_size": 36,
		"hide_when_zero": true,
		"alpha": 0.75,
	}


func get_param_schema() -> Array:
	return [
		{"key": "font_size", "name": "字号", "type": "int", "min": 8, "max": 160, "step": 1},
		{"key": "hide_when_zero", "name": "差值为 0 时隐藏", "type": "bool"},
		{"key": "alpha", "name": "不透明度", "type": "float", "min": 0.0, "max": 1.0, "step": 0.05},
	]


func _build_content() -> void:
	_num = _make_label(_format(0), maxi(1, int(get_param("font_size", 36))),
		HORIZONTAL_ALIGNMENT_RIGHT)
	add_child(_num)
	_content = _num
	_apply_alpha(maxi(_cur, 0))


func _format(v: int) -> String:
	match get_variant():
		1:
			return "(%d)" % v
		2:
			return "未计入 %d" % v
		_:
			return str(v)


func _apply_alpha(v: int) -> void:
	var a := clampf(float(get_param("alpha", 0.75)), 0.0, 1.0)
	if v <= 0 and bool(get_param("hide_when_zero", true)):
		a = 0.0
	modulate.a = a * vis_mul()


func on_state(state: Dictionary) -> void:
	if _num == null:
		return
	var v := int(state.get("pending", 0))
	if v == _cur:
		return
	_cur = v
	_num.text = _format(maxi(v, 0))
	_apply_alpha(v)
	apply_layout()

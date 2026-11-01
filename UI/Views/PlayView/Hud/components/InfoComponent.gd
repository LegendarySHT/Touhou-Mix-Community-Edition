extends HudComponent

## 歌曲信息类组件（专辑 / 歌曲名 / MIDI 名 / 难度）。
## 四种组件只有数据源不同，靠 component_id 直接当 state 的键取用。

const LABEL_DEFAULTS := {
	"album": "专辑",
	"song": "歌名",
	"midi_name": "MIDI",
	"difficulty": "难度",
}

var _value: Label = null


func get_variants() -> Array:
	return [
		{"name": "仅内容"},
		{"name": "标签: 内容"},
		{"name": "括号"},
	]


func default_params() -> Dictionary:
	return {
		"font_size": 32,
		"label_size": 24,
		"label_text": String(LABEL_DEFAULTS.get(component_id, "信息")),
		"max_width": 0,
		"align": 0,
	}


func get_param_schema() -> Array:
	return [
		{"key": "font_size", "name": "字号", "type": "int", "min": 8, "max": 160, "step": 1},
		{"key": "label_size", "name": "标签字号", "type": "int", "min": 8, "max": 120, "step": 1},
		{"key": "label_text", "name": "标签文本", "type": "string"},
		{"key": "max_width", "name": "最大宽度(0=不限)", "type": "int", "min": 0, "max": 1600, "step": 10},
		{"key": "align", "name": "对齐", "type": "option", "options": ["左", "中", "右"]},
	]


func _align() -> int:
	match int(get_param("align", 0)):
		1:
			return HORIZONTAL_ALIGNMENT_CENTER
		2:
			return HORIZONTAL_ALIGNMENT_RIGHT
		_:
			return HORIZONTAL_ALIGNMENT_LEFT


func _build_content() -> void:
	var fs := maxi(1, int(get_param("font_size", 32)))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if get_variant() == 1:
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 8)
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(_make_label(String(get_param("label_text", "")) + ":", 
			maxi(1, int(get_param("label_size", 24))), _align()))
		_value = _make_label("—", fs, _align())
		h.add_child(_value)
		box.add_child(h)
	else:
		_value = _make_label("—", fs, _align())
		box.add_child(_value)
	add_child(box)
	_content = box
	_apply_width()


func _apply_width() -> void:
	var mw := int(get_param("max_width", 0))
	if _content == null or mw <= 0:
		return
	_content.custom_minimum_size = Vector2(mw, 0)
	if _value != null:
		_value.clip_text = true
		_value.custom_minimum_size = Vector2(mw, 0)


func on_state(state: Dictionary) -> void:
	if _value == null:
		return
	var txt := String(state.get(component_id, ""))
	if txt.is_empty():
		txt = "—"
	if get_variant() == 2:
		txt = "(" + txt + ")"
	if _value.text != txt:
		_value.text = txt
		_apply_width()
		apply_layout()

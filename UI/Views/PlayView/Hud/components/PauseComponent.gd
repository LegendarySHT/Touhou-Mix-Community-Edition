extends HudComponent

## 暂停按钮。点击后由 PlayHud 转发给 PlayView 的暂停菜单。

static var _icon_cache: Texture2D = null

const ICON_PATH := "res://Resources/icon/icon_set.png"
const ICON_REGION := Rect2(160, 240, 80, 80)


func get_variants() -> Array:
	return [
		{"name": "图标"},
		{"name": "图标 + 文字"},
	]


func default_params() -> Dictionary:
	return {
		"size": 120,
		"icon_ratio": 0.5,
		"alpha": 1.0,
		"text": "暂停",
		"text_size": 32,
	}


func get_param_schema() -> Array:
	return [
		{"key": "size", "name": "按钮尺寸", "type": "int", "min": 40, "max": 320, "step": 2},
		{"key": "icon_ratio", "name": "图标占按钮比例", "type": "float",
			"min": 0.1, "max": 1.0, "step": 0.02},
		{"key": "alpha", "name": "不透明度", "type": "float", "min": 0.1, "max": 1.0, "step": 0.05},
		{"key": "text", "name": "文字(图标+文字变体)", "type": "string"},
		{"key": "text_size", "name": "文字字号", "type": "int", "min": 8, "max": 120, "step": 1},
	]


func _build_content() -> void:
	var s := maxi(40, int(get_param("size", 120)))
	var btn := Button.new()
	btn.flat = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.icon = _get_icon()
	btn.expand_icon = true
	btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	btn.add_theme_constant_override("icon_max_width", int(s * clampf(float(get_param("icon_ratio", 0.5)), 0.1, 1.0)))
	if get_variant() == 1:
		btn.text = String(get_param("text", "暂停"))
		btn.add_theme_font_size_override("font_size", maxi(8, int(get_param("text_size", 32))))
		btn.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.alignment = HORIZONTAL_ALIGNMENT_CENTER
		btn.custom_minimum_size = Vector2(s * 2.0, s)
	else:
		btn.custom_minimum_size = Vector2(s, s)
	btn.modulate.a = clampf(float(get_param("alpha", 1.0)), 0.1, 1.0)
	btn.pressed.connect(func() -> void: action_requested.emit("pause", null))
	add_child(btn)
	_content = btn


static func _get_icon() -> Texture2D:
	if _icon_cache != null:
		return _icon_cache
	var src: Texture2D = load(ICON_PATH)
	if src == null:
		return null
	var at := AtlasTexture.new()
	at.atlas = src
	at.region = ICON_REGION
	_icon_cache = at
	return at

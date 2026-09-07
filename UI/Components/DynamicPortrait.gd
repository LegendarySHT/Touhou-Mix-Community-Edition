extends Control
class_name DynamicPortrait

const MOTION_SHADER := preload("res://UI/Components/DynamicPortrait.gdshader")
const GRID_COLUMNS := 26
const GRID_ROWS := 40
const TWEEN_NAMES := ["idle", "blink_wait", "blink", "reaction", "effects", "message"]

var message_top_ratio: float = 0.84
var _canvas := Node2D.new()
var _reaction_pose := Node2D.new()
var _idle_pose := Node2D.new()
var _portrait := MeshInstance2D.new()
var _message_panel := PanelContainer.new()
var _message := Label.new()
var _material: ShaderMaterial
var _texture_size := Vector2.ZERO
var _chara_key := ""
var _emotion := 0
var _motion: Dictionary = {}
var _reaction: Dictionary = {}
var _active_requested := false
var _running := false
var _effect_phase := 0.0
var _effects: Array[Dictionary] = []
var _effect_color: Color
var _random := RandomNumberGenerator.new()

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.name = "PortraitCanvas"
	_portrait.name = "PortraitMesh"
	add_child(_canvas)
	_canvas.add_child(_reaction_pose)
	_reaction_pose.add_child(_idle_pose)
	_idle_pose.add_child(_portrait)
	_portrait.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_message_panel.name = "ReactionMessage"
	_message_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_message.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_message.max_lines_visible = 3
	_message.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	add_child(_message_panel)
	_message_panel.add_child(_message)
	_message_panel.hide()
	resized.connect(_update_layout)
	visibility_changed.connect(_refresh_active)
	ThemeMGR.register_theme_applier(self)
	apply_theme()
	_update_layout()
	_refresh_active()

func _exit_tree() -> void:
	_stop_motion()
	ThemeMGR.unregister_theme_applier(self)

func apply_theme() -> void:
	_effect_color = ThemeMGR.get_color("primary_light")
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = ThemeMGR.get_color("primary_dark")
	panel_style.bg_color.a = 0.88
	panel_style.border_color = _effect_color
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(12)
	panel_style.content_margin_left = 16.0
	panel_style.content_margin_right = 16.0
	panel_style.content_margin_top = 10.0
	panel_style.content_margin_bottom = 10.0
	_message_panel.add_theme_stylebox_override("panel", panel_style)
	_message.add_theme_color_override("font_color", ThemeMGR.get_color("text_primary"))
	queue_redraw()

func show_character(chara_key: String, emotion: int = 0) -> void:
	_stop_motion()
	_chara_key = CharaMGR.resolve_chara_key(chara_key)
	_emotion = emotion
	_reaction = {}
	_effects.clear()
	_message.text = ""
	_motion = CharaMGR.get_motion_config(_chara_key)
	_material = null
	_portrait.material = null
	_set_texture(CharaMGR.get_portrait(_chara_key, emotion))
	if not _motion.is_empty() and _portrait.texture != null:
		var weights := CharaMGR.get_chara_texture(_chara_key, _motion.weight_image)
		if weights != null and weights.get_size() == _texture_size:
			_material = ShaderMaterial.new()
			_material.shader = MOTION_SHADER
			_material.set_shader_parameter("weight_texture", weights)
			_material.set_shader_parameter("portrait_size", _texture_size)
			for parameter in ["breath", "sway", "wing", "hair", "skirt", "head_pivot"]:
				_material.set_shader_parameter(parameter, _motion[parameter])
			var blink: Dictionary = _motion.get("blink", {})
			if not blink.is_empty():
				var eyelids := CharaMGR.get_chara_texture(_chara_key, blink.image)
				if eyelids != null and eyelids.get_size() == _texture_size:
					_material.set_shader_parameter("blink_texture", eyelids)
				else:
					_motion.erase("blink")
			_portrait.material = _material
		else:
			_motion = {}
	_update_layout()
	_refresh_active()

func set_emotion(emotion: int) -> void:
	_emotion = emotion
	AniMGR.stop_tween(_tween_id("blink_wait"))
	AniMGR.stop_tween(_tween_id("blink"))
	_set_blink(0.0)
	_set_texture(CharaMGR.get_portrait(_chara_key, emotion))
	_refresh_active()
	_schedule_blink()

func show_result(chara_key: String, rank: String) -> void:
	show_character(chara_key, CharaMGR.get_rating_emotion(chara_key, rank))
	_stop_motion()
	_reaction = CharaMGR.get_score_reaction(_chara_key, rank)
	_message.text = str(_reaction.get("message", ""))
	if _material != null:
		_material.set_shader_parameter("motion_scale", float(_reaction.get("motion_scale", 1.0)))
	_effects.clear()
	for effect_index in range(int(_reaction.get("count", 0))):
		_effects.append({
			"origin": Vector2(_random.randf_range(0.06, 0.94), _random.randf()),
			"angle": _random.randf_range(0.0, TAU),
			"size": _random.randf_range(0.008, 0.017),
		})
	_refresh_active()

func set_active(active: bool) -> void:
	_active_requested = active
	_refresh_active()

func _refresh_active() -> void:
	var should_run := _active_requested and is_inside_tree() and is_visible_in_tree() and _portrait.texture != null
	if should_run == _running:
		return
	if not should_run:
		_stop_motion()
		return
	_running = true
	var idle := AniMGR.create_managed_tween(self, _tween_id("idle"))
	idle.set_loops()
	idle.tween_method(_set_phase, 0.0, TAU, 5.0 / float(_motion.get("speed", 1.0)))
	_schedule_blink()
	_start_reaction()

func _stop_motion() -> void:
	_running = false
	for tween_name in TWEEN_NAMES:
		AniMGR.stop_tween(_tween_id(tween_name))
	_set_phase(0.0)
	_set_blink(0.0)
	_reaction_pose.position = Vector2.ZERO
	_reaction_pose.rotation = 0.0
	_message_panel.hide()
	queue_redraw()

func _tween_id(suffix: String) -> String:
	return "portrait_%d_%s" % [get_instance_id(), suffix]

func _set_phase(value: float) -> void:
	if _material != null:
		_material.set_shader_parameter("phase", value)
	var float_amount: float = _motion.get("float", 8.0)
	_idle_pose.position.y = sin(value) * float_amount * float(_reaction.get("motion_scale", 1.0))

func _set_blink(value: float) -> void:
	if _material != null:
		_material.set_shader_parameter("blink_amount", value)

func _schedule_blink() -> void:
	var blink: Dictionary = _motion.get("blink", {})
	if not _running or _material == null or blink.is_empty() or _emotion not in blink.emotions:
		return
	var interval: Vector2 = blink.interval
	var wait := AniMGR.create_managed_tween(self, _tween_id("blink_wait"))
	wait.tween_interval(_random.randf_range(interval.x, interval.y))
	wait.tween_callback(_blink)

func _blink() -> void:
	if not _running:
		return
	var duration: float = _motion.blink.duration
	var blink := AniMGR.create_managed_tween(self, _tween_id("blink"))
	blink.tween_method(_set_blink, 0.0, 1.0, duration * 0.38)
	blink.tween_interval(duration * 0.24)
	blink.tween_method(_set_blink, 1.0, 0.0, duration * 0.38)
	blink.tween_callback(_schedule_blink)

func _start_reaction() -> void:
	if _reaction.is_empty():
		return
	var reaction := AniMGR.create_managed_tween(self, _tween_id("reaction"))
	reaction.set_parallel(true)
	reaction.tween_property(_reaction_pose, "position:y", -float(_reaction.bounce), 0.3).set_trans(Tween.TRANS_SINE)
	reaction.tween_property(_reaction_pose, "rotation_degrees", float(_reaction.tilt), 0.3)
	reaction.chain().tween_property(_reaction_pose, "position:y", 0.0, 0.8).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	reaction.tween_property(_reaction_pose, "rotation_degrees", float(_reaction.tilt) * 0.25, 0.8)
	if not _effects.is_empty() and _reaction.effect != "none":
		var effects := AniMGR.create_managed_tween(self, _tween_id("effects"))
		effects.set_loops()
		effects.tween_method(_set_effect_phase, 0.0, 1.0, 6.0)
	if not _message.text.is_empty():
		_message_panel.show()
		_message_panel.modulate.a = 0.0
		var message := AniMGR.create_managed_tween(self, _tween_id("message"))
		message.tween_property(_message_panel, "modulate:a", 1.0, 0.4)

func _set_effect_phase(value: float) -> void:
	_effect_phase = value
	queue_redraw()

func _set_texture(texture: Texture2D) -> void:
	_portrait.texture = texture
	_portrait.visible = texture != null
	if texture == null:
		return
	if texture.get_size() != _texture_size:
		_texture_size = texture.get_size()
		_portrait.mesh = _build_mesh(_texture_size)
		_update_layout()

func _build_mesh(texture_size: Vector2) -> ArrayMesh:
	var vertices := PackedVector2Array()
	var coordinates := PackedVector2Array()
	var indices := PackedInt32Array()
	for row_index in range(GRID_ROWS + 1):
		for column_index in range(GRID_COLUMNS + 1):
			var coordinate := Vector2(float(column_index) / GRID_COLUMNS, float(row_index) / GRID_ROWS)
			vertices.append((coordinate - Vector2(0.5, 0.5)) * texture_size)
			coordinates.append(coordinate)
			if row_index < GRID_ROWS and column_index < GRID_COLUMNS:
				var corner := row_index * (GRID_COLUMNS + 1) + column_index
				indices.append_array(PackedInt32Array([corner, corner + 1, corner + GRID_COLUMNS + 1, corner + 1, corner + GRID_COLUMNS + 2, corner + GRID_COLUMNS + 1]))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = coordinates
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func _update_layout() -> void:
	_canvas.position = size * 0.5
	if _texture_size.x > 0.0 and _texture_size.y > 0.0:
		var fit_scale := minf(size.x / _texture_size.x, size.y / _texture_size.y)
		_canvas.scale = Vector2.ONE * fit_scale
	_message_panel.position = Vector2(size.x * 0.06, size.y * message_top_ratio)
	_message_panel.size = Vector2(size.x * 0.88, size.y * 0.13)
	_message.add_theme_font_size_override("font_size", clampi(int(size.y * 0.027), 14, 28))
	queue_redraw()

func _draw() -> void:
	if not _running or _reaction.is_empty() or _reaction.effect == "none":
		return
	var shape := PackedVector2Array([Vector2(-1.0, 0.0), Vector2(-0.5, -0.45), Vector2(0.4, -0.55), Vector2(1.0, 0.0), Vector2(0.4, 0.55), Vector2(-0.5, 0.45)])
	if _reaction.effect == "sparkles":
		shape = PackedVector2Array([Vector2(0.0, -1.0), Vector2(0.2, -0.2), Vector2(1.0, 0.0), Vector2(0.2, 0.2), Vector2(0.0, 1.0), Vector2(-0.2, 0.2), Vector2(-1.0, 0.0), Vector2(-0.2, -0.2)])
	for effect in _effects:
		var origin: Vector2 = effect.origin
		var travel := fposmod(origin.y - _effect_phase, 1.0)
		var point := Vector2(origin.x + sin(_effect_phase * TAU + float(effect.angle)) * 0.045, travel) * size
		var tint := _effect_color
		tint.a = sin(travel * PI) * 0.8
		var radius: float = size.y * float(effect.size)
		draw_set_transform(point, float(effect.angle) + sin(_effect_phase * TAU), Vector2.ONE * radius)
		draw_colored_polygon(shape, tint)
	draw_set_transform(Vector2.ZERO)

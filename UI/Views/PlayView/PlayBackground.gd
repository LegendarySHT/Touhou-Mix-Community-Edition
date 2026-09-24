class_name PlayBackground
extends Node

## PlayView 背景控制器
## 负责背景应用（封面/渐变/纯色）、封面模糊烘焙、暗化遮罩与判定闪光。
## 由 PlayView.tscn 的 BackgroundControl 节点承载（背景细节不再留在 PlayView.gd）。

# 背景配置走 ThemeManager（theme.ini [backgrounds] 段），不再从 config.ini 读取
const BG_BLUR_SHADER_PATH := "res://UI/Views/PlayView/Shaders/BackgroundBlur.gdshader"
const BG_COMPOSITE_SHADER_PATH := "res://UI/Views/PlayView/Shaders/BackgroundComposite.gdshader"

@onready var background: TextureRect = $"../Background"

var flash_color: Color = Color.WHITE
## 背景合成材质（暗化 + 判定闪光），替代原 DimOverlay 全屏层
var _bg_material: ShaderMaterial = null
var _flash_tween: Tween = null
var _blur_bake_viewport: SubViewport = null
var _blur_bake_texture_rect: TextureRect = null
var _blur_bake_id: int = 0
## 已成功烘焙的谱面标识 + 模糊强度（重试/同谱面时复用，避免重新烘焙闪现清晰原图）
var _baked_midi_key: String = ""
var _baked_blur_strength: float = -1.0

## 应用背景（PlayView 在 _init_display / 从设置页返回时调用）
## cover 模式：曲包封面 + 模糊烘焙；image/solid/gradient 委托 ThemeManager 统一应用
## [param p_cover] 调用方已加载的封面（避免重复加载），可传 null 由本控制器自行查找
## [param p_has_custom_cover] 调用方已知的封面存在标记（p_cover 为 null 时忽略）
## [param midi] 当前谱面（p_cover 为 null 时查找封面用）
func apply_background(p_cover: Texture2D = null, p_has_custom_cover: bool = false, midi: MidiData = null) -> void:
	if background == null:
		return

	_apply_background_dim()

	var bg_config := ThemeMGR.get_view_background("play")
	var bg_type: String = bg_config.get("type", "gradient")

	if bg_type == "cover":
		# 封面模式：PlayView 独有逻辑（曲包封面 + 模糊烘焙）
		# ThemeManager 的 apply_background 对 cover 类型不实际应用，留给本控制器处理
		var blur_strength := float(bg_config.get("cover_blur", 0.35))
		var cover_texture: Texture2D = p_cover
		var has_custom: bool = p_has_custom_cover
		if p_cover == null:
			has_custom = has_cover_for_current_midi(midi)
			if has_custom:
				cover_texture = FileSystemManager.instance.get_cover_by_midiData(midi)
		if has_custom and cover_texture:
			background.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			# 重试/同谱面：若已为此 midi+blur 烘焙且 SubViewport 仍有效，直接复用，
			# 避免重新 _prepare_background_texture / _bake 导致闪现清晰原图
			if _can_reuse_bake(midi, blur_strength):
				background.texture = _blur_bake_viewport.get_texture()
				background.modulate = Color.WHITE
				background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
				return
			background.texture = _prepare_background_texture(cover_texture)
			background.modulate = Color.WHITE
			background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
			_set_cover_blur_material(blur_strength, _midi_key(midi))
			return
		# 无封面可用，降级到纯色（使用 play 段的 solid_color）
		var fallback_color: String = bg_config.get("solid_color", "#10121AFF")
		_apply_background_solid(fallback_color)
		return

	# image / solid / gradient 委托给 ThemeManager 统一应用
	ThemeMGR.apply_background(background, "play")
	_clear_cover_blur_material()


## 重新应用暗化遮罩 + 闪光色（config_changed 热更新：background_dim_color / background_image_flash_color）
func apply_dim() -> void:
	_apply_background_dim()


## 判定命中闪光（白色/配置色闪烁）
func flash() -> void:
	_flash_background()


## 释放模糊烘焙 SubViewport（离开 PlayView 时由 PlayView 调用）
func clear_blur_bake() -> void:
	_teardown_blur_bake_viewport()


## 当前 MIDI 是否有可用封面（PlayView 用返回值决定是否传 cover）
func has_cover_for_current_midi(midi: MidiData) -> bool:
	if midi == null or FileSystemManager.instance == null:
		return false

	var result = FileSystemManager.instance.lookup_chart(
		midi.chart_key if not midi.chart_key.is_empty() else midi.file_hash)
	if result.is_empty():
		result = FileSystemManager.instance.lookup_chart(midi.id)
	if result.is_empty():
		return false
	var metadata: ChartMetadata = result["metadata"]
	return not metadata.cover_path.is_empty() and FileAccess.file_exists(metadata.cover_path)


func _apply_background_solid(color_html: String) -> void:
	# 暗化/闪光已合并进本层 shader，而 TextureRect 无纹理时不产生绘制，
	# 故这里必须给出纯色纹理（原先置 null 会让整层连同暗化一起消失）
	var color := Color(color_html) if color_html.is_valid_html_color() else Color("#10121AFF")
	var img := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	img.fill(color)
	background.texture = ImageTexture.create_from_image(img)
	background.modulate = Color.WHITE
	_clear_cover_blur_material()


func _set_cover_blur_material(blur_strength: float, midi_key: String) -> void:
	var tex = background.texture
	if tex == null:
		return
	_bake_blurred_background(tex, blur_strength, midi_key)


func _clear_cover_blur_material() -> void:
	_teardown_blur_bake_viewport()


func _bake_blurred_background(cover_texture: Texture2D, blur_strength: float, midi_key: String) -> void:
	_blur_bake_id += 1
	var my_id = _blur_bake_id

	if _blur_bake_viewport:
		_blur_bake_viewport.queue_free()
		_blur_bake_viewport = null
		_blur_bake_texture_rect = null

	if blur_strength <= 0.001:
		return

	var window_size = DisplayServer.window_get_size()
	var bake_size := Vector2i(window_size)
	if bake_size.x > 1920 or bake_size.y > 1080:
		var s = min(1920.0 / bake_size.x, 1080.0 / bake_size.y)
		bake_size = Vector2i(bake_size * s)

	_blur_bake_viewport = SubViewport.new()
	_blur_bake_viewport.size = bake_size
	_blur_bake_viewport.transparent_bg = true
	_blur_bake_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(_blur_bake_viewport)

	_blur_bake_texture_rect = TextureRect.new()
	_blur_bake_texture_rect.texture = cover_texture
	_blur_bake_texture_rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_blur_bake_texture_rect.stretch_mode = background.stretch_mode
	_blur_bake_texture_rect.position = Vector2.ZERO
	_blur_bake_texture_rect.size = bake_size
	_blur_bake_texture_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_blur_bake_viewport.add_child(_blur_bake_texture_rect)

	var shader = load(BG_BLUR_SHADER_PATH)
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("blur_strength", clampf(blur_strength, 0.0, 1.0))
	_blur_bake_texture_rect.material = mat

	await RenderingServer.frame_post_draw

	if my_id != _blur_bake_id or _blur_bake_viewport == null:
		return

	background.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	background.texture = _blur_bake_viewport.get_texture()
	# 记录本次烘焙结果，供后续同谱面复用
	_baked_midi_key = midi_key
	_baked_blur_strength = blur_strength


func _teardown_blur_bake_viewport() -> void:
	if _blur_bake_viewport:
		_blur_bake_viewport.queue_free()
		_blur_bake_viewport = null
		_blur_bake_texture_rect = null
	_blur_bake_id += 1
	# SubViewport 释放后 ViewportTexture 失效，不再可复用
	_baked_midi_key = ""
	_baked_blur_strength = -1.0


## 谱面标识（复用判断用）
func _midi_key(midi: MidiData) -> String:
	if midi == null:
		return ""
	return midi.chart_key if not midi.chart_key.is_empty() else midi.file_hash


## 是否可复用已烘焙结果：同谱面 + 同 blur 强度 + SubViewport 仍有效
func _can_reuse_bake(midi: MidiData, blur_strength: float) -> bool:
	if _blur_bake_viewport == null or _baked_midi_key.is_empty():
		return false
	return _baked_midi_key == _midi_key(midi) \
		and absf(_baked_blur_strength - blur_strength) < 0.001


func _apply_background_dim() -> void:
	var mat := _ensure_bg_material()
	if mat == null:
		return
	var dim_color_html = ConfigManager.instance.get_string("Appearance", "background_dim_color", "#0000007F")
	var dim_color := Color(dim_color_html) if dim_color_html.is_valid_html_color() else Color(0, 0, 0, 0.5)
	mat.set_shader_parameter("dim_color", dim_color)
	var flash_color_html = ConfigManager.instance.get_string("Appearance", "background_image_flash_color", "#FFFFFF00")
	if flash_color_html.is_valid_html_color():
		flash_color = Color(flash_color_html)
	else:
		flash_color = Color(1, 1, 1, 0)
	mat.set_shader_parameter("flash_color", flash_color)


## 确保背景合成材质存在：暗化与判定闪光由它承担，
## 取代原先独立的 DimOverlay 全屏 ColorRect（少一层全屏 alpha 混合）
func _ensure_bg_material() -> ShaderMaterial:
	if background == null:
		return null
	if _bg_material == null:
		var shader := load(BG_COMPOSITE_SHADER_PATH)
		if shader == null:
			return null
		_bg_material = ShaderMaterial.new()
		_bg_material.shader = shader
		_bg_material.set_shader_parameter("flash_progress", 0.0)
		background.material = _bg_material
	return _bg_material


func _set_flash_progress(value: float, mat: ShaderMaterial) -> void:
	mat.set_shader_parameter("flash_progress", value)


func _flash_background() -> void:
	if flash_color.a <= 0:
		return
	var mat := _ensure_bg_material()
	if mat == null:
		return
	if _flash_tween and _flash_tween.is_valid():
		_flash_tween.kill()
	mat.set_shader_parameter("flash_progress", 1.0)
	_flash_tween = AniMGR.create_managed_tween(self)
	_flash_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_flash_tween.tween_method(_set_flash_progress.bind(mat), 1.0, 0.0, 1)


func _prepare_background_texture(source_texture: Texture2D) -> Texture2D:
	if source_texture == null:
		return null

	var image := source_texture.get_image()
	if image == null or image.is_empty():
		return source_texture

	if not image.has_mipmaps():
		# 异步生成 mipmap：先返回原图避免阻塞当前帧，下一帧再替换为 mipmap 版本
		_generate_mipmaps_deferred(image)
		return source_texture

	return source_texture


func _generate_mipmaps_deferred(image: Image) -> void:
	await RenderingServer.frame_post_draw
	if is_instance_valid(self) and image != null and not image.is_empty():
		image.generate_mipmaps()
		background.texture = ImageTexture.create_from_image(image)

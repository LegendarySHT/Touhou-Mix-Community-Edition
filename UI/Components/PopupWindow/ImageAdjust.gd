extends HBoxContainer

class_name ImageAdjust

# OtherOptions 子节点引用（用于显隐控制）
# 封面模式相关节点（已在 tscn 中存在，默认 visible=false）

# ===== 图片设置页 =====
## 图片类型枚举（与 ImgType OptionButton 顺序一致）
## public（无下划线前缀）：SettingList 通过 ImageAdjust.IMG_TYPE_* 访问
const IMG_TYPE_DEFAULT: int = 0
const IMG_TYPE_IMAGE: int = 1
const IMG_TYPE_GRADIENT: int = 2
const IMG_TYPE_SOLID: int = 3
const IMG_TYPE_COVER: int = 4

const _PREVIEW_BG_BLUR_SHADER_PATH := "res://UI/Views/PlayView/Shaders/BackgroundBlur.gdshader"

## 预览用的带 mipmap 封面副本（shader 的 textureLod 依赖 mipmap）
var _preview_mip_texture: Texture2D = null
var _preview_mip_key: Texture2D = null

func _ready() -> void:
	%StartColorPicker.color_changed.connect(_on_color_picker_changed.bind(%StartColorHex))
	%StartColorHex.text_changed.connect(_on_hex_color_changed.bind(%StartColorPicker))
	%EndColorPicker.color_changed.connect(_on_color_picker_changed.bind(%EndColorHex))
	%EndColorHex.text_changed.connect(_on_hex_color_changed.bind(%EndColorPicker))
	%SolidColorPicker.color_changed.connect(_on_color_picker_changed.bind(%SolidColorHex))
	%SolidColorHex.text_changed.connect(_on_hex_color_changed.bind(%SolidColorPicker))
	# 统一取色器弹层形态。背景色需要透明度滑条，故 edit_alpha=true。
	# HexColor 输入框是场景里自带的（不走 attach_hex_edit），这里只统一弹层内容。
	for picker in [%StartColorPicker, %EndColorPicker, %SolidColorPicker]:
		ThemeMGR.setup_color_picker(picker, true)

## 由 PopupWindow.show_image_adjust 调用：
## view_name: 视图名称（main/store/score/play/track/midi/setting），用于从 ThemeManager 读取当前配置初始化控件
## allow_cover: 是否允许选择"封面"类型（仅 play 视图为 true）
func init_adjust(view_name: String = "", allow_cover: bool = false) -> void:
	# 刷新图片文件列表
	_refresh_image_options()
	# 根据 allow_cover 启用/禁用"封面"选项（item_3）
	%ImgType.set_item_disabled(IMG_TYPE_COVER, not allow_cover)
	# 从 ThemeManager 读取当前配置初始化控件
	_init_image_controls_from_theme(view_name)
	# 若禁用且当前选中是封面，切回"跟随主题"
	if not allow_cover and %ImgType.selected == IMG_TYPE_COVER:
		%ImgType.selected = IMG_TYPE_DEFAULT
	_update_image_options_visibility()
	_update_image_preview()

## 返回当前图片设置（供 PopupWindow.show_image_adjust 返回）
## 包含字段：
##   "type": int (0=跟随主题, 1=图片, 2=渐变, 3=纯色, 4=封面)
##   "image_file": String (图片模式下选中的文件名)
##   "fill_mode": int (图片填充方式，0=覆盖, 1=适应)
##   "start_color": Color (渐变起始色)
##   "end_color": Color (渐变结束色)
##   "from": Vector2 (渐变起始坐标 0~1)
##   "to": Vector2 (渐变结束坐标 0~1)
##   "solid_color": Color (纯色)
##   "cover_blur": float (封面模糊强度 0~1)
##   "cover_style": String (封面模糊算法名，见 ViewBackground.COVER_BLUR_STYLES)
func get_result() -> Dictionary:
	var img_type = %ImgType.selected
	return {
		"type": img_type,
		# 图片模式
		"image_file": %ImgName.get_item_text(%ImgName.selected) if %ImgName.item_count > 0 else "",
		"fill_mode": %ImgFillMode.selected,
		# 渐变模式
		"start_color": %StartColorPicker.color,
		"end_color": %EndColorPicker.color,
		"from": Vector2(
			float(%FromXEdit.text) if %FromXEdit.text.is_valid_float() else 0.0,
			float(%FromYEdit.text) if %FromYEdit.text.is_valid_float() else 0.0
		),
		"to": Vector2(
			float(%ToXEdit.text) if %ToXEdit.text.is_valid_float() else 1.0,
			float(%ToYEdit.text) if %ToYEdit.text.is_valid_float() else 1.0
		),
		# 纯色模式
		"solid_color": %SolidColorPicker.color,
		# 封面模式
		"cover_blur": float(%CoverBlurEdit.text) if %CoverBlurEdit.text.is_valid_float() else 0.8,
		"cover_style": ViewBackground.COVER_BLUR_STYLES[
			clampi(%CoverStyleOption.selected, 0, ViewBackground.COVER_BLUR_STYLES.size() - 1)
		],
	}

## 扫描背景图片文件列表
func _scan_background_images() -> Array[String]:
	var result: Array[String] = []
	var image_dir := PathHelper.get_background_dir()
	var dir := DirAccess.open(image_dir)
	if dir == null:
		return result
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and not file_name.begins_with("."):
			var ext := file_name.get_extension().to_lower()
			if ext in ["jpg", "jpeg", "png", "webp"]:
				result.append(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	result.sort()
	return result

## 刷新图片文件下拉选项
func _refresh_image_options() -> void:
	var image_files := _scan_background_images()
	%ImgName.clear()
	for f in image_files:
		%ImgName.add_item(f)

## 切换图片类型：控制相关字段显隐 + 更新预览
func _on_img_type_selected(_index: int) -> void:
	_update_image_options_visibility()
	_update_image_preview()

## 更新 OtherOptions 中各控件的显隐（根据当前 ImgType）
func _update_image_options_visibility() -> void:
	var img_type = %ImgType.selected
	var show_image = img_type == IMG_TYPE_IMAGE
	var show_gradient = img_type == IMG_TYPE_GRADIENT
	var show_solid = img_type == IMG_TYPE_SOLID
	var show_cover = img_type == IMG_TYPE_COVER
	# 跟随主题：不显示任何参数
	# 图片模式
	%ImgNameLabel.visible = show_image
	%ImgName.visible = show_image
	%ImgFillModeLabel.visible = show_image
	%ImgFillMode.visible = show_image
	# 渐变模式
	%StartColorLabel.visible = show_gradient
	%StartColorRow.visible = show_gradient
	%EndColorLabel.visible = show_gradient
	%EndColorRow.visible = show_gradient
	%FromXRow.visible = show_gradient
	%FromYRow.visible = show_gradient
	%ToXRow.visible = show_gradient
	%ToYRow.visible = show_gradient
	# 纯色模式
	%SolidColorLabel.visible = show_solid
	%SolidColorRow.visible = show_solid
	# 封面模式（仅 cover 显示模糊强度 + 算法）
	%CoverBlurLabel.visible = show_cover
	%CoverBlurEdit.visible = show_cover
	%CoverStyleLabel.visible = show_cover
	%CoverStyleOption.visible = show_cover

## 创建纯色纹理（1x1 白色像素，通过 modulate 着色）
func _create_solid_texture() -> ImageTexture:
	var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	var tex := ImageTexture.create_from_image(image)
	return tex

## 创建渐变纹理
func _create_gradient_texture(start: Color, end: Color, from: Vector2, to: Vector2) -> GradientTexture2D:
	var grad_tex := GradientTexture2D.new()
	var gradient := Gradient.new()
	gradient.set_color(0, start)
	gradient.set_color(1, end)
	grad_tex.gradient = gradient
	# from/to 取值范围 0~1，LineEdit 输入的是 0~100 的百分比
	grad_tex.fill_from = from
	grad_tex.fill_to = to
	# fill_mode 默认值即 FILL_LINEAR(0)，无需显式赋值（Godot 4.6 中赋值 int 会报枚举类型错误）
	grad_tex.width = 500
	grad_tex.height = 500
	return grad_tex

## 更新图片预览（根据当前 ImgType 和控件值）
func _update_image_preview() -> void:
	var img_type = %ImgType.selected
	# 默认清除模糊 shader，仅 cover 分支重新设置
	%ImagePreviewTexture.material = null
	match img_type:
		IMG_TYPE_DEFAULT:
			# 跟随主题：直接预览主题衍生的默认背景
			%ImagePreviewTexture.texture = ThemeMGR.get_default_background_texture()
			%ImagePreviewTexture.stretch_mode = TextureRect.STRETCH_SCALE
			%ImagePreviewTexture.modulate = Color.WHITE
		IMG_TYPE_IMAGE:
			if %ImgName.item_count > 0:
				var file_name = %ImgName.get_item_text(%ImgName.selected)
				if not file_name.is_empty():
					var tex: Texture2D = ThemeMGR.load_background_image(file_name)
					if tex:
						%ImagePreviewTexture.texture = tex
			# 填充方式：0=覆盖（等比放大完全覆盖预览框，类似 CSS cover）
			#           1=适应（保证图片完全可见，类似 CSS contain）
			%ImagePreviewTexture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED if %ImgFillMode.selected == 0 else TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			%ImagePreviewTexture.modulate = Color.WHITE
		IMG_TYPE_GRADIENT:
			var start = %StartColorPicker.color
			var end = %EndColorPicker.color
			# fill_from / fill_to 用 Godot 原生 0~1 归一化坐标：(0,0)=左上, (1,1)=右下
			var from := Vector2(
				clampf(float(%FromXEdit.text) if %FromXEdit.text.is_valid_float() else 0.0, 0.0, 1.0),
				clampf(float(%FromYEdit.text) if %FromYEdit.text.is_valid_float() else 0.0, 0.0, 1.0)
			)
			var to := Vector2(
				clampf(float(%ToXEdit.text) if %ToXEdit.text.is_valid_float() else 1.0, 0.0, 1.0),
				clampf(float(%ToYEdit.text) if %ToYEdit.text.is_valid_float() else 1.0, 0.0, 1.0)
			)
			%ImagePreviewTexture.texture = _create_gradient_texture(start, end, from, to)
			%ImagePreviewTexture.modulate = Color.WHITE
		IMG_TYPE_SOLID:
			var color = %SolidColorPicker.color
			%ImagePreviewTexture.texture = _create_solid_texture()
			%ImagePreviewTexture.modulate = color
		IMG_TYPE_COVER:
			# 封面模式预览：随机取一个已渲染的专辑封面 + 模糊 shader
			# 预览用"适应"（保持比例、完整可见），避免"覆盖"裁切导致预览效果不佳
			var cover_tex := _get_preview_cover_texture()
			if cover_tex:
				%ImagePreviewTexture.texture = cover_tex
				%ImagePreviewTexture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				%ImagePreviewTexture.modulate = Color.WHITE
				var blur_strength := float(%CoverBlurEdit.text) if %CoverBlurEdit.text.is_valid_float() else 0.8
				_apply_preview_cover_blur(blur_strength, %CoverStyleOption.selected)
			else:
				# 无封面可用，显示占位
				%ImagePreviewTexture.texture = null
				%ImagePreviewTexture.modulate = Color(0.2, 0.2, 0.3, 1.0)

## 图片文件选择变化
func _on_img_name_selected(_index: int) -> void:
	_update_image_preview()

## 填充方式变化
func _on_img_fill_mode_selected(_index: int) -> void:
	_update_image_preview()

## 颜色选择器变化（渐变起始/结束/纯色共用）
## ColorPickerButton 颜色变化 → 同步到 LineEdit（带 alpha，格式 #RRGGBBAA）
func _on_color_picker_changed(color: Color, line_edit: LineEdit) -> void:
	line_edit.set_block_signals(true)
	# 带 alpha（背景颜色支持透明度：solid 通过 modulate、gradient 通过 GradientTexture2D）
	line_edit.text = "#" + color.to_html(true)
	line_edit.set_block_signals(false)
	_update_image_preview()

## LineEdit 文本变化 → 同步到 ColorPickerButton（仅当输入合法颜色时）
func _on_hex_color_changed(new_text: String, color_btn: ColorPickerButton) -> void:
	# 去除可能的前缀 # 或 0x
	var cleaned := new_text.strip_edges().lstrip("#")
	if cleaned.length() == 6 or cleaned.length() == 8:
		var html := "#" + cleaned
		if html.is_valid_html_color():
			color_btn.set_block_signals(true)
			color_btn.color = Color(html)
			color_btn.set_block_signals(false)
	_update_image_preview()

## 渐变坐标变化
func _on_gradient_coords_changed(_new_text: String) -> void:
	_update_image_preview()

## 封面模糊强度变化（仅占位，实际值在关闭弹窗时返回）
func _on_cover_blur_changed(_new_text: String) -> void:
	# 仅在当前预览为封面模式时实时刷新模糊强度
	if %ImgType.selected == IMG_TYPE_COVER:
		var blur_strength := float(%CoverBlurEdit.text) if %CoverBlurEdit.text.is_valid_float() else 0.8
		_apply_preview_cover_blur(blur_strength, %CoverStyleOption.selected)

## 封面模糊算法切换
func _on_cover_style_selected(_index: int) -> void:
	if %ImgType.selected == IMG_TYPE_COVER:
		var blur_strength := float(%CoverBlurEdit.text) if %CoverBlurEdit.text.is_valid_float() else 0.8
		_apply_preview_cover_blur(blur_strength, %CoverStyleOption.selected)

## 获取一个可用于预览的封面（随机从 AlbumList 已渲染的列表项中取一个封面纹理）
## 优先用界面已加载的封面，避免重复 IO；AlbumList 不可用时回退到数据层取第一个
func _get_preview_cover_texture() -> Texture2D:
	var album_list := GlobalNodes.album_view
	if album_list is BaseScrollList:
		var container: Container = album_list.container
		if container and container.get_child_count() > 0:
			# 收集所有有效封面，避免随机到空封面
			var covers: Array[Texture2D] = []
			for i in range(container.get_child_count()):
				var item: Node = container.get_child(i)
				if not is_instance_valid(item):
					continue
				# AlbumListItem 的封面在 $Cover TextureRect
				var cover_rect: TextureRect = item.get_node_or_null("Cover")
				if cover_rect and cover_rect.texture:
					covers.append(cover_rect.texture)
			if not covers.is_empty():
				return covers[randi() % covers.size()]
	# 回退：数据层取第一个可用封面
	var data_mgr := DataMGR
	var fs_mgr := FileSystemManager.instance
	if not data_mgr or not fs_mgr:
		return null
	var albums := data_mgr.get_all_albums()
	if albums.is_empty():
		return null
	var songs := data_mgr.get_songs_by_album(String(albums[0].get("id", "")))
	if songs.is_empty():
		return null
	var midis := data_mgr.get_midis_by_song(String(songs[0].get("id", "")))
	if midis.is_empty():
		return null
	return fs_mgr.get_cover_by_midiData(midis[0])

## 应用封面模糊 shader 到预览节点
## style 索引与 ViewBackground.COVER_BLUR_STYLES / 场景下拉项一致
func _apply_preview_cover_blur(blur_strength: float, style: int = 1) -> void:
	var shader := load(_PREVIEW_BG_BLUR_SHADER_PATH)
	if shader == null:
		%ImagePreviewTexture.material = null
		return
	# shader 靠 textureLod 做大半径降采样，纹理必须先有 mipmap
	%ImagePreviewTexture.texture = _ensure_preview_mipmap(%ImagePreviewTexture.texture)
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("style", style)
	mat.set_shader_parameter("blur_strength", clampf(blur_strength, 0.0, 1.0))
	%ImagePreviewTexture.material = mat

## 预览用：原纹理没有 mipmap 时生成一份带 mip 的副本（只影响预览，不动共享纹理）
func _ensure_preview_mipmap(tex: Texture2D) -> Texture2D:
	if tex == null:
		return null
	if tex == _preview_mip_texture:
		return tex
	var img := tex.get_image()
	if img == null or img.is_empty() or img.has_mipmaps():
		return tex
	img.generate_mipmaps()
	_preview_mip_texture = ImageTexture.create_from_image(img)
	_preview_mip_key = tex
	return _preview_mip_texture

## 从 ThemeManager 读取指定视图的背景配置，初始化弹窗控件
## view_name 为空时使用默认值（保持向后兼容）
func _init_image_controls_from_theme(view_name: String) -> void:
	# 默认值
	var bg_type_str := "default"
	var image_path := ""
	var image_stretch := "cover"
	var solid_color := "#0D1020"
	var gradient_top := "#0D1020"
	var gradient_bottom := "#0A0F1E"
	var gradient_from := Vector2(0.0, 0.0)
	var gradient_to := Vector2(0.0, 1.0)
	var cover_blur := 0.8
	var cover_style := ViewBackground.DEFAULT_COVER_STYLE

	if not view_name.is_empty() and ThemeMGR:
		var bg := ThemeMGR.get_view_background(view_name)
		bg_type_str = String(bg.get("type", bg_type_str))
		image_path = String(bg.get("image_path", image_path))
		image_stretch = String(bg.get("image_stretch", image_stretch))
		solid_color = String(bg.get("solid_color", solid_color))
		gradient_top = String(bg.get("gradient_top", gradient_top))
		gradient_bottom = String(bg.get("gradient_bottom", gradient_bottom))
		gradient_from = Vector2(
			float(bg.get("gradient_from_x", gradient_from.x)),
			float(bg.get("gradient_from_y", gradient_from.y))
		)
		gradient_to = Vector2(
			float(bg.get("gradient_to_x", gradient_to.x)),
			float(bg.get("gradient_to_y", gradient_to.y))
		)
		cover_blur = float(bg.get("cover_blur", cover_blur))
		cover_style = String(bg.get("cover_blur_style", cover_style))

	# 设置类型 OptionButton
	var type_idx := IMG_TYPE_DEFAULT
	match bg_type_str:
		"default": type_idx = IMG_TYPE_DEFAULT
		"image": type_idx = IMG_TYPE_IMAGE
		"gradient": type_idx = IMG_TYPE_GRADIENT
		"solid": type_idx = IMG_TYPE_SOLID
		"cover": type_idx = IMG_TYPE_COVER

	# 回填期间屏蔽信号：给 ColorPickerButton.color / LineEdit.text 赋值会各自触发
	# color_changed / text_changed，下面 8 处赋值会让 _update_image_preview 连跑 8 次
	# （每次都重建渐变纹理与模糊 shader）。屏蔽后末尾统一刷一次。
	var touched: Array[Control] = [
		%ImgType, %ImgName, %ImgFillMode,
		%SolidColorPicker, %StartColorPicker, %EndColorPicker,
		%FromXEdit, %FromYEdit, %ToXEdit, %ToYEdit, %CoverBlurEdit, %CoverStyleOption,
	]
	for c in touched:
		c.set_block_signals(true)

	%ImgType.selected = type_idx

	# 设置图片文件下拉：尝试选中 image_path
	var img_idx := -1
	for i in range(%ImgName.item_count):
		if %ImgName.get_item_text(i) == image_path:
			img_idx = i
			break
	if img_idx >= 0:
		%ImgName.selected = img_idx
	elif %ImgName.item_count > 0:
		%ImgName.selected = 0

	# 设置填充方式：cover→0, 其它→1
	%ImgFillMode.selected = 0 if image_stretch == "cover" else 1

	# 设置颜色
	if solid_color.is_valid_html_color():
		%SolidColorPicker.color = Color(solid_color)
	if gradient_top.is_valid_html_color():
		%StartColorPicker.color = Color(gradient_top)
	if gradient_bottom.is_valid_html_color():
		%EndColorPicker.color = Color(gradient_bottom)

	# 设置渐变坐标（Godot 原生 0~1 归一化）
	%FromXEdit.text = str(gradient_from.x)
	%FromYEdit.text = str(gradient_from.y)
	%ToXEdit.text = str(gradient_to.x)
	%ToYEdit.text = str(gradient_to.y)

	# 设置封面模糊强度 + 算法
	%CoverBlurEdit.text = str(cover_blur)
	%CoverStyleOption.selected = ViewBackground.cover_blur_style_index(cover_style)

	for c in touched:
		c.set_block_signals(false)
	# 预览刷新交给调用方 init_adjust 末尾统一做（它在"封面"回退之后，时机更准）

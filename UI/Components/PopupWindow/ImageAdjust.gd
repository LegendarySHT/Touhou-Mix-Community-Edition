extends HBoxContainer

class_name ImageAdjust

@onready var _image_texture_rect: TextureRect = $ImagePreview/TextureRect
@onready var _img_type_btn: OptionButton = $VBoxC/ImgType
@onready var _img_name_btn: TouchScrollOptionButton = $VBoxC/OtherOptions/ImgName
@onready var _img_fill_mode_btn: OptionButton = $VBoxC/OtherOptions/ImgFillMode
@onready var _start_color_btn: ColorPickerButton = $VBoxC/OtherOptions/StartColor/ColorPickerButton
@onready var _start_color_edit: LineEdit = $VBoxC/OtherOptions/StartColor/HexColor
@onready var _end_color_btn: ColorPickerButton = $VBoxC/OtherOptions/EndColor/ColorPickerButton
@onready var _end_color_edit: LineEdit = $VBoxC/OtherOptions/EndColor/HexColor
@onready var _from_x_edit: LineEdit = $VBoxC/OtherOptions/FromX/LineEdit
@onready var _from_y_edit: LineEdit = $VBoxC/OtherOptions/FromY/LineEdit
@onready var _to_x_edit: LineEdit = $VBoxC/OtherOptions/ToX/LineEdit
@onready var _to_y_edit: LineEdit = $VBoxC/OtherOptions/ToY/LineEdit
@onready var _solid_color_btn: ColorPickerButton = $VBoxC/OtherOptions/SolidColor/ColorPickerButton
@onready var _solid_color_edit: LineEdit = $VBoxC/OtherOptions/SolidColor/HexColor
# OtherOptions 子节点引用（用于显隐控制）
@onready var _img_name_label: Control = $VBoxC/OtherOptions/Label
@onready var _img_fill_mode_label: Control = $VBoxC/OtherOptions/Label2
@onready var _start_color_label: Control = $VBoxC/OtherOptions/Label3
@onready var _start_color_container: Control = $VBoxC/OtherOptions/StartColor
@onready var _end_color_label: Control = $VBoxC/OtherOptions/Label4
@onready var _end_color_container: Control = $VBoxC/OtherOptions/EndColor
@onready var _from_x_container: Control = $VBoxC/OtherOptions/FromX
@onready var _from_y_container: Control = $VBoxC/OtherOptions/FromY
@onready var _to_x_container: Control = $VBoxC/OtherOptions/ToX
@onready var _to_y_container: Control = $VBoxC/OtherOptions/ToY
@onready var _solid_color_label: Control = $VBoxC/OtherOptions/Label5
@onready var _solid_color_container: Control = $VBoxC/OtherOptions/SolidColor
# 封面模式相关节点（已在 tscn 中存在，默认 visible=false）
@onready var _cover_blur_label: Control = $VBoxC/OtherOptions/Label6
@onready var _cover_blur_edit: LineEdit = $VBoxC/OtherOptions/BlurIntensity

# ===== 图片设置页 =====
## 图片类型枚举（与 ImgType OptionButton 顺序一致）
## public（无下划线前缀）：SettingList 通过 ImageAdjust.IMG_TYPE_* 访问
const IMG_TYPE_IMAGE: int = 0
const IMG_TYPE_GRADIENT: int = 1
const IMG_TYPE_SOLID: int = 2
const IMG_TYPE_COVER: int = 3

const _PREVIEW_BG_BLUR_SHADER_PATH := "res://UI/Views/PlayView/Shaders/BackgroundBlur.gdshader"

func _ready() -> void:
	_start_color_btn.color_changed.connect(_on_color_picker_changed.bind(_start_color_edit))
	_start_color_edit.text_changed.connect(_on_hex_color_changed.bind(_start_color_btn))
	_end_color_btn.color_changed.connect(_on_color_picker_changed.bind(_end_color_edit))
	_end_color_edit.text_changed.connect(_on_hex_color_changed.bind(_end_color_btn))
	_solid_color_btn.color_changed.connect(_on_color_picker_changed.bind(_solid_color_edit))
	_solid_color_edit.text_changed.connect(_on_hex_color_changed.bind(_solid_color_btn))

## 由 PopupWindow.show_image_adjust 调用：
## view_name: 视图名称（main/store/score/play/track/midi/setting），用于从 ThemeManager 读取当前配置初始化控件
## allow_cover: 是否允许选择"封面"类型（仅 play 视图为 true）
func init_adjust(view_name: String = "", allow_cover: bool = false) -> void:
	# 刷新图片文件列表
	_refresh_image_options()
	# 根据 allow_cover 启用/禁用"封面"选项（item_3）
	_img_type_btn.set_item_disabled(IMG_TYPE_COVER, not allow_cover)
	# 从 ThemeManager 读取当前配置初始化控件
	_init_image_controls_from_theme(view_name)
	# 若禁用且当前选中是封面，切回默认（图片）
	if not allow_cover and _img_type_btn.selected == IMG_TYPE_COVER:
		_img_type_btn.selected = IMG_TYPE_IMAGE
	_update_image_options_visibility()
	_update_image_preview()

## 返回当前图片设置（供 PopupWindow.show_image_adjust 返回）
## 包含字段：
##   "type": int (0=图片, 1=渐变, 2=纯色, 3=封面)
##   "image_file": String (图片模式下选中的文件名)
##   "fill_mode": int (图片填充方式，0=覆盖, 1=适应)
##   "start_color": Color (渐变起始色)
##   "end_color": Color (渐变结束色)
##   "from": Vector2 (渐变起始坐标 0~1)
##   "to": Vector2 (渐变结束坐标 0~1)
##   "solid_color": Color (纯色)
##   "cover_blur": float (封面模糊强度 0~1)
func get_result() -> Dictionary:
	var img_type := _img_type_btn.selected
	return {
		"type": img_type,
		# 图片模式
		"image_file": _img_name_btn.get_item_text(_img_name_btn.selected) if _img_name_btn.item_count > 0 else "",
		"fill_mode": _img_fill_mode_btn.selected,
		# 渐变模式
		"start_color": _start_color_btn.color,
		"end_color": _end_color_btn.color,
		"from": Vector2(
			float(_from_x_edit.text) if _from_x_edit.text.is_valid_float() else 0.0,
			float(_from_y_edit.text) if _from_y_edit.text.is_valid_float() else 0.0
		),
		"to": Vector2(
			float(_to_x_edit.text) if _to_x_edit.text.is_valid_float() else 1.0,
			float(_to_y_edit.text) if _to_y_edit.text.is_valid_float() else 1.0
		),
		# 纯色模式
		"solid_color": _solid_color_btn.color,
		# 封面模式
		"cover_blur": float(_cover_blur_edit.text) if _cover_blur_edit.text.is_valid_float() else 0.35,
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
	_img_name_btn.clear()
	for f in image_files:
		_img_name_btn.add_item(f)

## 切换图片类型：控制相关字段显隐 + 更新预览
func _on_img_type_selected(_index: int) -> void:
	_update_image_options_visibility()
	_update_image_preview()

## 更新 OtherOptions 中各控件的显隐（根据当前 ImgType）
func _update_image_options_visibility() -> void:
	var img_type := _img_type_btn.selected
	var show_image := img_type == IMG_TYPE_IMAGE
	var show_gradient := img_type == IMG_TYPE_GRADIENT
	var show_solid := img_type == IMG_TYPE_SOLID
	var show_cover := img_type == IMG_TYPE_COVER
	# 图片模式
	_img_name_label.visible = show_image
	_img_name_btn.visible = show_image
	_img_fill_mode_label.visible = show_image
	_img_fill_mode_btn.visible = show_image
	# 渐变模式
	_start_color_label.visible = show_gradient
	_start_color_container.visible = show_gradient
	_end_color_label.visible = show_gradient
	_end_color_container.visible = show_gradient
	_from_x_container.visible = show_gradient
	_from_y_container.visible = show_gradient
	_to_x_container.visible = show_gradient
	_to_y_container.visible = show_gradient
	# 纯色模式
	_solid_color_label.visible = show_solid
	_solid_color_container.visible = show_solid
	# 封面模式（仅 cover 显示模糊输入）
	_cover_blur_label.visible = show_cover
	_cover_blur_edit.visible = show_cover

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
	var img_type := _img_type_btn.selected
	# 默认清除模糊 shader，仅 cover 分支重新设置
	_image_texture_rect.material = null
	match img_type:
		IMG_TYPE_IMAGE:
			if _img_name_btn.item_count > 0:
				var file_name := _img_name_btn.get_item_text(_img_name_btn.selected)
				if not file_name.is_empty():
					var tex: Texture2D = ThemeMGR.load_background_image(file_name)
					if tex:
						_image_texture_rect.texture = tex
			# 填充方式：0=覆盖（等比放大完全覆盖预览框，类似 CSS cover）
			#           1=适应（保证图片完全可见，类似 CSS contain）
			_image_texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED if _img_fill_mode_btn.selected == 0 else TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			_image_texture_rect.modulate = Color.WHITE
		IMG_TYPE_GRADIENT:
			var start := _start_color_btn.color
			var end := _end_color_btn.color
			# fill_from / fill_to 用 Godot 原生 0~1 归一化坐标：(0,0)=左上, (1,1)=右下
			var from := Vector2(
				clampf(float(_from_x_edit.text) if _from_x_edit.text.is_valid_float() else 0.0, 0.0, 1.0),
				clampf(float(_from_y_edit.text) if _from_y_edit.text.is_valid_float() else 0.0, 0.0, 1.0)
			)
			var to := Vector2(
				clampf(float(_to_x_edit.text) if _to_x_edit.text.is_valid_float() else 1.0, 0.0, 1.0),
				clampf(float(_to_y_edit.text) if _to_y_edit.text.is_valid_float() else 1.0, 0.0, 1.0)
			)
			_image_texture_rect.texture = _create_gradient_texture(start, end, from, to)
			_image_texture_rect.modulate = Color.WHITE
		IMG_TYPE_SOLID:
			var color := _solid_color_btn.color
			_image_texture_rect.texture = _create_solid_texture()
			_image_texture_rect.modulate = color
		IMG_TYPE_COVER:
			# 封面模式预览：随机取一个已渲染的专辑封面 + 模糊 shader
			# 预览用"适应"（保持比例、完整可见），避免"覆盖"裁切导致预览效果不佳
			var cover_tex := _get_preview_cover_texture()
			if cover_tex:
				_image_texture_rect.texture = cover_tex
				_image_texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				_image_texture_rect.modulate = Color.WHITE
				var blur_strength := float(_cover_blur_edit.text) if _cover_blur_edit.text.is_valid_float() else 0.35
				_apply_preview_cover_blur(blur_strength)
			else:
				# 无封面可用，显示占位
				_image_texture_rect.texture = null
				_image_texture_rect.modulate = Color(0.2, 0.2, 0.3, 1.0)

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
	if _img_type_btn.selected == IMG_TYPE_COVER:
		var blur_strength := float(_cover_blur_edit.text) if _cover_blur_edit.text.is_valid_float() else 0.35
		_apply_preview_cover_blur(blur_strength)

## 获取一个可用于预览的封面（随机从 AlbumList 已渲染的列表项中取一个封面纹理）
## 优先用界面已加载的封面，避免重复 IO；AlbumList 不可用时回退到数据层取第一个
func _get_preview_cover_texture() -> Texture2D:
	var album_list := get_node_or_null(PathRegistry.ALBUM_LIST)
	if album_list is BaseScrollList:
		var container: Container = album_list.container
		if container and container.get_child_count() > 0:
			# 收集所有有效封面，避免随机到空封面
			var covers: Array[Texture2D] = []
			for i in range(container.get_child_count()):
				var item: Node = container.get_child(i)
				if not is_instance_valid(item):
					continue
				# AlbumListItem 的封面在 $cover TextureRect
				var cover_rect: TextureRect = item.get_node_or_null("cover")
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
func _apply_preview_cover_blur(blur_strength: float) -> void:
	var shader := load(_PREVIEW_BG_BLUR_SHADER_PATH)
	if shader == null:
		_image_texture_rect.material = null
		return
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("blur_strength", clampf(blur_strength, 0.0, 1.0))
	_image_texture_rect.material = mat

## 从 ThemeManager 读取指定视图的背景配置，初始化弹窗控件
## view_name 为空时使用默认值（保持向后兼容）
func _init_image_controls_from_theme(view_name: String) -> void:
	# 默认值
	var bg_type_str := "image"
	var image_path := ""
	var image_stretch := "cover"
	var solid_color := "#0D1020"
	var gradient_top := "#0D1020"
	var gradient_bottom := "#0A0F1E"
	var gradient_from := Vector2(0.0, 0.0)
	var gradient_to := Vector2(0.0, 1.0)
	var cover_blur := 0.35

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

	# 设置类型 OptionButton
	var type_idx := IMG_TYPE_IMAGE
	match bg_type_str:
		"image": type_idx = IMG_TYPE_IMAGE
		"gradient": type_idx = IMG_TYPE_GRADIENT
		"solid": type_idx = IMG_TYPE_SOLID
		"cover": type_idx = IMG_TYPE_COVER

	# 回填期间屏蔽信号：给 ColorPickerButton.color / LineEdit.text 赋值会各自触发
	# color_changed / text_changed，下面 8 处赋值会让 _update_image_preview 连跑 8 次
	# （每次都重建渐变纹理与模糊 shader）。屏蔽后末尾统一刷一次。
	var touched: Array[Control] = [
		_img_type_btn, _img_name_btn, _img_fill_mode_btn,
		_solid_color_btn, _start_color_btn, _end_color_btn,
		_from_x_edit, _from_y_edit, _to_x_edit, _to_y_edit, _cover_blur_edit,
	]
	for c in touched:
		c.set_block_signals(true)

	_img_type_btn.selected = type_idx

	# 设置图片文件下拉：尝试选中 image_path
	var img_idx := -1
	for i in range(_img_name_btn.item_count):
		if _img_name_btn.get_item_text(i) == image_path:
			img_idx = i
			break
	if img_idx >= 0:
		_img_name_btn.selected = img_idx
	elif _img_name_btn.item_count > 0:
		_img_name_btn.selected = 0

	# 设置填充方式：cover→0, 其它→1
	_img_fill_mode_btn.selected = 0 if image_stretch == "cover" else 1

	# 设置颜色
	if solid_color.is_valid_html_color():
		_solid_color_btn.color = Color(solid_color)
	if gradient_top.is_valid_html_color():
		_start_color_btn.color = Color(gradient_top)
	if gradient_bottom.is_valid_html_color():
		_end_color_btn.color = Color(gradient_bottom)

	# 设置渐变坐标（Godot 原生 0~1 归一化）
	_from_x_edit.text = str(gradient_from.x)
	_from_y_edit.text = str(gradient_from.y)
	_to_x_edit.text = str(gradient_to.x)
	_to_y_edit.text = str(gradient_to.y)

	# 设置封面模糊强度
	_cover_blur_edit.text = str(cover_blur)

	for c in touched:
		c.set_block_signals(false)
	# 预览刷新交给调用方 init_adjust 末尾统一做（它在"封面"回退之后，时机更准）

class_name AvatarPreview
extends PanelContainer

## 头像预览节点：直接用 border 自身的 _draw 绘制图像，替代子 TextureRect + offset_transform。
## 原因：子 TextureRect 用 offset_transform 平移/缩放时，可见性裁剪盒（visibility clip rect）
## 会随变换一起移动，一旦越出屏幕，整段绘制会被 2D 渲染器 cull 掉，导致拖到边界时图像消失。
## 这里图像由本节点固定位置绘制（节点始终在屏幕上），偏移只体现在 draw 参数里，不受此问题影响。

## 编辑模式源图（用户选择图片后）：可平移/缩放
var source_image: Image = null
var _source_tex: ImageTexture = null
## 非编辑时显示的当前头像
var display_texture: Texture2D = null
## 缩放倍率与左上角偏移（缩放以画框左上角为锚点）
var scale_factor: float = 1.0
var offset: Vector2 = Vector2.ZERO
var _dragging: bool = false

## 设置待调整源图并复位平移缩放（进入编辑）
func set_source_image(img: Image) -> void:
	source_image = img
	_source_tex = ImageTexture.create_from_image(img) if img else null
	scale_factor = 1.0
	offset = Vector2.ZERO
	queue_redraw()

## 设置当前头像（非编辑展示，加载完成时调用）
func set_display_texture(tex: Texture2D) -> void:
	display_texture = tex
	queue_redraw()

## 缩放滑条回调：更新缩放并保持位置边界
func set_zoom(v: float) -> void:
	scale_factor = v
	_clamp_offset()
	queue_redraw()

## 退出编辑：清空待调整图，回到显示当前头像
func clear_preview() -> void:
	source_image = null
	_source_tex = null
	scale_factor = 1.0
	offset = Vector2.ZERO
	_dragging = false
	queue_redraw()

## 画框（可见裁剪区）尺寸，用于钳制与裁剪换算
func get_box_size() -> Vector2:
	if size.x > 0 and size.y > 0:
		return size
	return Vector2(350, 350)

func _draw() -> void:
	if source_image != null and _source_tex != null:
		var tsize := Vector2(_source_tex.get_width(), _source_tex.get_height())
		draw_texture_rect(_source_tex, Rect2(offset, tsize * scale_factor), false, Color.WHITE, false)
	elif display_texture != null:
		draw_texture_rect(display_texture, Rect2(Vector2.ZERO, size), false)
	# 边框（白色 10px，中心透明）在图片之上画出四边线
	draw_style_box(get_theme_stylebox("panel"), Rect2(Vector2.ZERO, size))

func _gui_input(event: InputEvent) -> void:
	if source_image == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		accept_event()
	elif event is InputEventMouseMotion and _dragging:
		offset += event.relative
		_clamp_offset()
		queue_redraw()
		accept_event()

## 平移/缩放后钳制（逐轴独立）：off 即缩放后图片左上角（默认与框左上角对齐）
func _clamp_offset() -> void:
	var view := get_box_size()
	var st := Vector2(source_image.get_width(), source_image.get_height()) * maxf(scale_factor, 0.0001)
	offset.x = _clamp_axis(offset.x, view.x, st.x)
	offset.y = _clamp_axis(offset.y, view.y, st.y)

func _clamp_axis(v: float, vw: float, sw: float) -> float:
	# 图超出画框 → 铺满可平移（范围 [画框-图寸, 0]，左上可越界露出右下）；未超框 → 居中
	if sw > vw:
		return clampf(v, vw - sw, 0.0)
	return (vw - sw) * 0.5

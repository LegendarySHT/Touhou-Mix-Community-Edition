## 圆角矩形贴图节点：内部持有 ImgRoundCorner 材质并自动同步遮罩参数，
## 尺寸变化、换图、stretch 裁剪（COVERED）/ 留白（KEEP_ASPECT_*）后圆角始终贴合最终可见图像
class_name RoundedTextureRect
extends TextureRect

@export var corner_radius: float = 10.0:
	set(v):
		corner_radius = v
		_set_mask_param("corner_radius", v)

func _ready() -> void:
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://UI/Components/ImgRoundCorner.gdshader")
	material = mat
	_set_mask_param("corner_radius", corner_radius)

func _notification(what: int) -> void:
	# 每次绘制前同步：尺寸 / 纹理 / stretch 模式的任何变化最终都会触发重绘，
	# 参数在真正渲染前写入材质，本帧即生效
	if what == NOTIFICATION_DRAW:
		_update_mask()

## 按当前 stretch 模式算出可见绘制区尺寸与 UV 区间（与引擎 texture_rect.cpp 同款算法）写入 shader
func _update_mask() -> void:
	var cs := size
	var drawn := cs
	var uv := Rect2(Vector2.ZERO, Vector2.ONE)
	var tex := texture
	if tex:
		var ts := tex.get_size()
		if ts.x > 0.0 and ts.y > 0.0:
			match stretch_mode:
				STRETCH_KEEP, STRETCH_KEEP_CENTERED:
					drawn = ts
				STRETCH_KEEP_ASPECT, STRETCH_KEEP_ASPECT_CENTERED:
					drawn = ts * minf(cs.x / ts.x, cs.y / ts.y)
				STRETCH_KEEP_ASPECT_COVERED:
					var sc := maxf(cs.x / ts.x, cs.y / ts.y)
					var inset := (ts * sc - cs).abs() / sc * 0.5 / ts
					uv = Rect2(inset, Vector2.ONE - inset * 2.0)
	_set_mask_param("rect_size", drawn)
	_set_mask_param("uv_rect", uv)

func _set_mask_param(param: StringName, value) -> void:
	var mat := material as ShaderMaterial
	if mat:
		mat.set_shader_parameter(param, value)

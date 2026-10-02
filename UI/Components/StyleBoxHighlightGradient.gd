class_name StyleBoxHighlightGradient
## 继承 StyleBox 基类自绘的渐变高光样式框。
## 属性命名沿用原生 StyleBoxFlat 的小写习惯（bg_color/corner_radius_*/border_*）。
## 用起来与 StyleBoxFlat 一致：只改 bg_color 即上色；额外 highlight_angle/strength/amount
## 控制高光方向与强度，运行时自动用 bg_color 算一个亮色做渐变。
extends StyleBox

@export var bg_color: Color = Color.WHITE:
	set(v):
		bg_color = v
		emit_changed()

@export var corner_radius_top_left: int = 0:
	set(v):
		corner_radius_top_left = v
		emit_changed()
@export var corner_radius_top_right: int = 0:
	set(v):
		corner_radius_top_right = v
		emit_changed()
@export var corner_radius_bottom_right: int = 0:
	set(v):
		corner_radius_bottom_right = v
		emit_changed()
@export var corner_radius_bottom_left: int = 0:
	set(v):
		corner_radius_bottom_left = v
		emit_changed()
@export_range(1, 32, 1) var corner_detail: int = 5:
	set(v):
		corner_detail = v
		emit_changed()

@export var border_color: Color = Color.BLACK:
	set(v):
		border_color = v
		emit_changed()
@export var border_width_left: int = 0:
	set(v):
		border_width_left = v
		emit_changed()
@export var border_width_top: int = 0:
	set(v):
		border_width_top = v
		emit_changed()
@export var border_width_right: int = 0:
	set(v):
		border_width_right = v
		emit_changed()
@export var border_width_bottom: int = 0:
	set(v):
		border_width_bottom = v
		emit_changed()

@export_range(0, 360, 1) var highlight_angle: float = 135.0:
	set(v):
		highlight_angle = v
		emit_changed()
@export_range(0, 1) var highlight_strength: float = 0.35:
	set(v):
		highlight_strength = v
		emit_changed()
@export_range(0, 1) var highlight_amount: float = 0.5:
	set(v):
		highlight_amount = v
		emit_changed()
@export_range(0, 1) var shadow_strength: float = 0.35:
	set(v):
		shadow_strength = v
		emit_changed()


func _draw(to_canvas_item: RID, rect: Rect2) -> void:
	var seg := _compute_segments(rect)
	var points := _build_round_rect_points(rect, seg)
	if points.size() >= 3:
		var colors := _build_gradient_colors(points, rect, bg_color)
		# 直接用传入的 canvas item RID 绘制，不依赖 get_current_item_drawn()（编辑器预览时序下可能为空）
		RenderingServer.canvas_item_add_polygon(to_canvas_item, PackedVector2Array(points), PackedColorArray(colors))

	_draw_borders(to_canvas_item, rect)


## 按 rect 尺寸自适应每边细分段数（渐变更平滑）。
func _compute_segments(rect: Rect2) -> int:
	var max_dim := maxf(rect.size.x, rect.size.y)
	return clampi(int(max_dim / 6.0), 4, 64)


## 沿 highlight_angle 方向给每个顶点按投影计算双向渐变：
## [0, highlight_amount] 段高光端从 bg_color 提亮；其余段向另一端加暗（shadow_strength）。
func _build_gradient_colors(points: Array, rect: Rect2, base: Color) -> PackedColorArray:
	var angle_rad := deg_to_rad(highlight_angle)
	var dir := Vector2(sin(angle_rad), -cos(angle_rad))
	var highlight := _lighten(base, highlight_strength)
	var shadow := base.darkened(shadow_strength)

	var corners := [
		rect.position,
		Vector2(rect.end.x, rect.position.y),
		rect.end,
		Vector2(rect.position.x, rect.end.y),
	]
	var t_min := INF
	var t_max := -INF
	for c in corners:
		var t: float = c.dot(dir)
		t_min = minf(t_min, t)
		t_max = maxf(t_max, t)
	var span := maxf(t_max - t_min, 0.0001)

	var colors := PackedColorArray()
	colors.resize(points.size())
	var mid := clampf(highlight_amount, 0.0, 1.0)
	for i in points.size():
		var t: float = (points[i].dot(dir) - t_min) / span  # 0=远离高光端 1=高光端
		if mid >= 1.0:
			colors[i] = base.lerp(highlight, t)
		elif t < mid:
			colors[i] = base.lerp(highlight, t / mid)
		else:
			var k := (t - mid) / (1.0 - mid)
			colors[i] = base.lerp(shadow, k)
	return colors


## 提高明度但保留色相/饱和度，避免 lightened() 向白混合造成的"偏白"；明度已近顶则退回混白兜底。
func _lighten(c: Color, amount: float) -> Color:
	var v := c.v + amount * (1.0 - c.v)
	if v >= 0.999:
		return c.lightened(amount)
	return Color.from_hsv(c.h, c.s, v)


## 构建圆角矩形周界点（顺时针，直边与圆角各自按 seg 细分），保证 Goraud 渐变平滑。
func _build_round_rect_points(rect: Rect2, seg: int) -> Array:
	var x0 := rect.position.x
	var y0 := rect.position.y
	var x1 := rect.end.x
	var y1 := rect.end.y
	var r_tl := float(corner_radius_top_left)
	var r_tr := float(corner_radius_top_right)
	var r_br := float(corner_radius_bottom_right)
	var r_bl := float(corner_radius_bottom_left)

	var pts: Array = []
	# 顺时针：顶边 → 右上角 → 右边 → 右下角 → 底边 → 左下角 → 左边 → 左上角
	_add_edge(pts, Vector2(x0 + r_tl, y0), Vector2(x1 - r_tr, y0), seg)
	_add_arc(pts, Vector2(x1 - r_tr, y0 + r_tr), r_tr, 270.0, 360.0, seg)
	_add_edge(pts, Vector2(x1, y0 + r_tr), Vector2(x1, y1 - r_br), seg)
	_add_arc(pts, Vector2(x1 - r_br, y1 - r_br), r_br, 0.0, 90.0, seg)
	_add_edge(pts, Vector2(x1 - r_br, y1), Vector2(x0 + r_bl, y1), seg)
	_add_arc(pts, Vector2(x0 + r_bl, y1 - r_bl), r_bl, 90.0, 180.0, seg)
	_add_edge(pts, Vector2(x0, y1 - r_bl), Vector2(x0, y0 + r_tl), seg)
	_add_arc(pts, Vector2(x0 + r_tl, y0 + r_tl), r_tl, 180.0, 270.0, seg)
	return pts


## 直边细分：从 from 到 to 追加 seg 个点（不含终点，终点由下一段承接）。
func _add_edge(pts: Array, from: Vector2, to: Vector2, seg: int) -> void:
	for i in seg:
		pts.append(from.lerp(to, float(i) / seg))


## 圆弧细分：以 arc_center 为圆心、半径 r 追加角度 [from_deg,to_deg] 的离散点（不含终点）。
func _add_arc(pts: Array, arc_center: Vector2, radius: float,
		from_deg: float, to_deg: float, segments: int) -> void:
	if radius <= 0.0:
		return
	for i in segments:
		var a := lerpf(from_deg, to_deg, float(i) / segments)
		pts.append(arc_center + Vector2(cos(deg_to_rad(a)), sin(deg_to_rad(a))) * radius)


## 按各边宽/色画简洁边框（四角不圆角化）。
func _draw_borders(canvas_rid: RID, rect: Rect2) -> void:
	var c := border_color
	var x0 := rect.position.x
	var y0 := rect.position.y
	var x1 := rect.end.x
	var y1 := rect.end.y
	if border_width_top > 0:
		RenderingServer.canvas_item_add_line(canvas_rid, Vector2(x0, y0 + border_width_top * 0.5), Vector2(x1, y0 + border_width_top * 0.5), c, border_width_top)
	if border_width_bottom > 0:
		RenderingServer.canvas_item_add_line(canvas_rid, Vector2(x0, y1 - border_width_bottom * 0.5), Vector2(x1, y1 - border_width_bottom * 0.5), c, border_width_bottom)
	if border_width_left > 0:
		RenderingServer.canvas_item_add_line(canvas_rid, Vector2(x0 + border_width_left * 0.5, y0), Vector2(x0 + border_width_left * 0.5, y1), c, border_width_left)
	if border_width_right > 0:
		RenderingServer.canvas_item_add_line(canvas_rid, Vector2(x1 - border_width_right * 0.5, y0), Vector2(x1 - border_width_right * 0.5, y1), c, border_width_right)

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


## 网格缓存：StyleBox 每次重绘都要重建顶点，而列表滚动时同一个框每帧都在重绘。
## key 命中就直接复用，省掉全部 GDScript 数学与顶点组装。
var _cache_key: Array = []
var _cache_pts: PackedVector2Array = PackedVector2Array()
var _cache_colors: PackedColorArray = PackedColorArray()
var _cache_idx: PackedInt32Array = PackedInt32Array()


func _draw(to_canvas_item: RID, rect: Rect2) -> void:
	_ensure_mesh(rect)
	if _cache_idx.size() > 0:
		# 手工扇形三角化：canvas_item_add_polygon 会对凹/凸多边形跑耳切法，
		# 512 点实测 479µs/次（列表滚动时每帧都在付）。圆角矩形是凸的，
		# 直接给索引走 triangle_array，三角化成本归零。
		RenderingServer.canvas_item_add_triangle_array(
			to_canvas_item, _cache_idx, _cache_pts, _cache_colors)

	_draw_borders(to_canvas_item, rect)


func _ensure_mesh(rect: Rect2) -> void:
	var key := [
		rect.position, rect.size, bg_color,
		corner_radius_top_left, corner_radius_top_right,
		corner_radius_bottom_right, corner_radius_bottom_left,
		highlight_angle, highlight_strength, highlight_amount, shadow_strength,
		corner_detail,
	]
	if key == _cache_key:
		return
	_cache_key = key
	_build_mesh(rect)


## 沿「折点线」把外环切成两半分别剖分。
func _split_at_kink(ring: PackedVector2Array, rect: Rect2) -> Array:
	var mid := clampf(highlight_amount, 0.0, 1.0)
	if mid <= 0.001 or mid >= 0.999:
		return [ring]  # 没有折点，整块就是一个线性渐变
	var dir := _gradient_dir()
	var _tr := _gradient_t_range(rect)
	var t_cut := _tr.x + mid * (_tr.y - _tr.x)

	var n := ring.size()
	var edges: Array[int] = []
	var cuts := PackedVector2Array()
	for i in n:
		var ta: float = ring[i].dot(dir) - t_cut
		var tb: float = ring[(i + 1) % n].dot(dir) - t_cut
		if (ta < 0.0) != (tb < 0.0):
			edges.append(i)
			cuts.append(ring[i].lerp(ring[(i + 1) % n], ta / (ta - tb)))
	# 凸多边形被直线切割恰好两个交点；退化情况（切点压在顶点上）保留整块，别硬切
	if edges.size() != 2:
		return [ring]

	var e0: int = edges[0]
	var e1: int = edges[1]
	var p0 := cuts[0]
	var p1 := cuts[1]

	var a := PackedVector2Array([p0])
	var i := (e0 + 1) % n
	while true:
		a.append(ring[i])
		if i == e1:
			break
		i = (i + 1) % n
	a.append(p1)

	var b := PackedVector2Array([p1])
	i = (e1 + 1) % n
	while true:
		b.append(ring[i])
		if i == e0:
			break
		i = (i + 1) % n
	b.append(p0)
	return [a, b]


func _build_mesh(rect: Rect2) -> void:
	_cache_pts = PackedVector2Array()
	_cache_colors = PackedColorArray()
	_cache_idx = PackedInt32Array()

	var ring := _build_round_rect_points(rect)
	if ring.size() < 3:
		return
	# 每半都是凸多边形 → 从首个顶点起扇三角化合法且零成本（不做耳切）
	for part in _split_at_kink(ring, rect):
		var poly: PackedVector2Array = part
		if poly.size() < 3:
			continue
		var b := _cache_pts.size()
		_cache_pts.append_array(poly)
		for i in range(1, poly.size() - 1):
			_cache_idx.append(b)
			_cache_idx.append(b + i)
			_cache_idx.append(b + i + 1)
	_cache_colors = _build_gradient_colors(_cache_pts, rect, bg_color)


## 直边不需要细分：线性渐变靠插值就是精确的（折点由 _split_at_kink 的切线交点承担）。
func _edge_segments(_length: float) -> int:
	return 1


## 圆弧细分：只为圆角轮廓，chord 误差 ≈ r·(1-cos(半角))，corner_detail 作下限。
func _arc_segments(radius: float) -> int:
	return clampi(maxi(corner_detail, int(radius / 1.5)), 4, 20)


func _gradient_dir() -> Vector2:
	var angle_rad := deg_to_rad(highlight_angle)
	return Vector2(sin(angle_rad), -cos(angle_rad))


## 返回 (t_min, t_max)：rect 四角在渐变方向上的投影范围
func _gradient_t_range(rect: Rect2) -> Vector2:
	var dir := _gradient_dir()
	var t_min := INF
	var t_max := -INF
	for c in [rect.position, Vector2(rect.end.x, rect.position.y), rect.end,
			Vector2(rect.position.x, rect.end.y)]:
		var t: float = (c as Vector2).dot(dir)
		t_min = minf(t_min, t)
		t_max = maxf(t_max, t)
	return Vector2(t_min, t_max)


## 沿 highlight_angle 方向给每个顶点按投影计算双向渐变：
## 远端(bg_color) → highlight_amount 处达到最亮 → 继续到另一端压暗(shadow_strength)。
## 折点两侧必须从同一颜色接上：以前后半段从 base 重新开始（跳变），
## 中间就裂成一条硬分界线，只是被粗糙面片的插值糊掉了。
func _build_gradient_colors(points: PackedVector2Array, rect: Rect2, base: Color) -> PackedColorArray:
	var dir := _gradient_dir()
	var highlight := _lighten(base, highlight_strength)
	var shadow := base.darkened(shadow_strength)

	var _tr := _gradient_t_range(rect)
	var t_min := _tr.x
	var span := maxf(_tr.y - _tr.x, 0.0001)

	var colors := PackedColorArray()
	colors.resize(points.size())
	var mid := clampf(highlight_amount, 0.0, 1.0)
	for i in points.size():
		var t: float = (points[i].dot(dir) - t_min) / span  # 0=远端 1=另一端
		if mid >= 0.999:
			colors[i] = base.lerp(highlight, t)
		elif t < mid:
			colors[i] = base.lerp(highlight, t / mid)
		else:
			# 从高光峰值继续向暗部过渡（不是从 base 重来），否则折点处就是一道硬分界
			var k := (t - mid) / (1.0 - mid)
			colors[i] = highlight.lerp(shadow, k)
	return colors


## 提高明度但保留色相/饱和度，避免 lightened() 向白混合造成的"偏白"；明度已近顶则退回混白兜底。
func _lighten(c: Color, amount: float) -> Color:
	var v := c.v + amount * (1.0 - c.v)
	if v >= 0.999:
		return c.lightened(amount)
	return Color.from_hsv(c.h, c.s, v)


## 构建圆角矩形周界点（顺时针，直边与圆角各自细分），保证 Goraud 渐变平滑。
## 半径先按短边一半夹紧——超过就会变成凹多边形，扇形三角化会出洞。
func _build_round_rect_points(rect: Rect2) -> PackedVector2Array:
	var x0 := rect.position.x
	var y0 := rect.position.y
	var x1 := rect.end.x
	var y1 := rect.end.y
	var half := minf(rect.size.x, rect.size.y) * 0.5
	var r_tl := clampf(float(corner_radius_top_left), 0.0, half)
	var r_tr := clampf(float(corner_radius_top_right), 0.0, half)
	var r_br := clampf(float(corner_radius_bottom_right), 0.0, half)
	var r_bl := clampf(float(corner_radius_bottom_left), 0.0, half)
	var sc := _arc_segments(maxf(maxf(r_tl, r_tr), maxf(r_br, r_bl)))

	var pts := PackedVector2Array()
	# 顺时针：顶边 → 右上角 → 右边 → 右下角 → 底边 → 左下角 → 左边 → 左上角
	_add_edge(pts, Vector2(x0 + r_tl, y0), Vector2(x1 - r_tr, y0), _edge_segments(x1 - x0 - r_tl - r_tr))
	_add_arc(pts, Vector2(x1 - r_tr, y0 + r_tr), r_tr, 270.0, 360.0, sc)
	_add_edge(pts, Vector2(x1, y0 + r_tr), Vector2(x1, y1 - r_br), _edge_segments(y1 - y0 - r_tr - r_br))
	_add_arc(pts, Vector2(x1 - r_br, y1 - r_br), r_br, 0.0, 90.0, sc)
	_add_edge(pts, Vector2(x1 - r_br, y1), Vector2(x0 + r_bl, y1), _edge_segments(x1 - x0 - r_br - r_bl))
	_add_arc(pts, Vector2(x0 + r_bl, y1 - r_bl), r_bl, 90.0, 180.0, sc)
	_add_edge(pts, Vector2(x0, y1 - r_bl), Vector2(x0, y0 + r_tl), _edge_segments(y1 - y0 - r_bl - r_tl))
	_add_arc(pts, Vector2(x0 + r_tl, y0 + r_tl), r_tl, 180.0, 270.0, sc)
	return pts


## 直边细分：从 from 到 to 追加 seg 个点（不含终点，终点由下一段承接）。
func _add_edge(pts: PackedVector2Array, from: Vector2, to: Vector2, seg: int) -> void:
	for i in seg:
		pts.append(from.lerp(to, float(i) / seg))


## 圆弧细分：以 arc_center 为圆心、半径 r 追加角度 [from_deg,to_deg] 的离散点（不含终点）。
func _add_arc(pts: PackedVector2Array, arc_center: Vector2, radius: float,
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

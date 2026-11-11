extends Control

## 判定分布条：按各判定的数量占比绘制一条分段圆角条，
## 用颜色宽度代替「五个数字排一行」的表格观感。
## 只负责画，数据由 ScoreView 通过 set_counts() 推入。

## 判定配色（与 PlayHud / 排行榜保持同一套语义色）
const JUDGE_COLORS: Array[Color] = [
	Color("#FF50FD"),  # Perfect
	Color("#FF7600"),  # Great
	Color("#0AE000"),  # Good
	Color("#1CB0FF"),  # Bad
	Color("#DC3450"),  # Miss
]
## 段与段之间的留白（像素）
const SEGMENT_GAP := 4.0
## 单段最小可见宽度占条高的比例（数量极少的判定也要看得见）
const MIN_SEGMENT_RATIO := 0.85

## 入场进度 0..1：入场时由 0 补间到 1，表现条形「生长」出来
var _reveal: float = 1.0

var _counts: PackedInt32Array = PackedInt32Array([0, 0, 0, 0, 0])
var _total: int = 0
var _colors: Array[Color] = []
var _sb_track := StyleBoxFlat.new()
var _sb_segment := StyleBoxFlat.new()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
	apply_theme()


func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)


## 主题刷新：槽底跟随板面层级，判定色在浅色模式下压暗一档保证对比度
func apply_theme() -> void:
	if ThemeMGR == null:
		return
	var is_light := ThemeMGR.get_appearance() == "light"
	var track: Color = ThemeMGR.get_color("surface_low")
	_sb_track.bg_color = Color(track.r, track.g, track.b, 0.55 if is_light else 1.0)
	_colors.clear()
	for c in JUDGE_COLORS:
		_colors.append(c.darkened(0.22) if is_light else c)
	queue_redraw()


## 设置入场生长进度（0 只画槽底，1 为完整条形）
func set_reveal(v: float) -> void:
	v = clampf(v, 0.0, 1.0)
	if is_equal_approx(v, _reveal):
		return
	_reveal = v
	queue_redraw()


## 推入判定数量（顺序固定：Perfect / Great / Good / Bad / Miss）
func set_counts(counts: PackedInt32Array) -> void:
	_counts = counts
	_total = 0
	for c in counts:
		_total += maxi(c, 0)
	queue_redraw()


func _draw() -> void:
	var h := size.y
	if h <= 0.0 or size.x <= 0.0:
		return
	var radius := int(h * 0.5)
	_sb_track.set_corner_radius_all(radius)
	draw_style_box(_sb_track, Rect2(Vector2.ZERO, size))
	if _total <= 0 or _reveal <= 0.0:
		return
	_sb_segment.set_corner_radius_all(radius)

	var widths := _compute_widths()
	var x := 0.0
	for i in widths.size():
		var w: float = widths[i] * _reveal
		if w <= 0.0:
			continue
		var color: Color = _colors[i] if i < _colors.size() else Color.WHITE
		_sb_segment.bg_color = Color(color.r, color.g, color.b, color.a)
		draw_style_box(_sb_segment, Rect2(x, 0.0, w, h))
		x += w + SEGMENT_GAP * _reveal


## 按数量占比分配各段宽度：先按比例分，再把过窄的段撑到最小可见宽度，
## 缺口从够宽的段里等比例扣回来，保证总宽不溢出。
func _compute_widths() -> PackedFloat32Array:
	var visible_idx: Array[int] = []
	for i in _counts.size():
		if _counts[i] > 0:
			visible_idx.append(i)
	var out := PackedFloat32Array()
	out.resize(_counts.size())
	if visible_idx.is_empty():
		return out
	var avail := size.x - SEGMENT_GAP * float(visible_idx.size() - 1)
	if avail <= 0.0:
		return out
	var min_w := size.y * MIN_SEGMENT_RATIO
	for i in visible_idx:
		out[i] = avail * float(_counts[i]) / float(_total)
	# 撑开过窄段
	var deficit := 0.0
	for i in visible_idx:
		if out[i] < min_w:
			deficit += min_w - out[i]
			out[i] = min_w
	if deficit <= 0.0:
		return out
	# 从还能让出空间的段里按当前宽度比例扣回
	var give_total := 0.0
	for i in visible_idx:
		if out[i] > min_w:
			give_total += out[i] - min_w
	if give_total <= 0.0:
		# 容器窄到连每段的最小宽度都放不下：退回纯比例分配，宁可变窄也不画出界
		for i in visible_idx:
			out[i] = avail * float(_counts[i]) / float(_total)
		return out
	var ratio := minf(deficit / give_total, 1.0)
	for i in visible_idx:
		if out[i] > min_w:
			out[i] -= (out[i] - min_w) * ratio
	return out

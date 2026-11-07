extends Control

## 评级构成环：按各评级的记录数占比绘制圆环扇段，环心文字由子节点负责
## 由 ProfileView 按路径引用，不注册全局类名

## 扇段列表：[{ "color": Color, "weight": float }]，weight 为记录数，0 的段不画
var _segments: Array = []

func set_segments(segments: Array) -> void:
	_segments = segments
	queue_redraw()

func _draw() -> void:
	var total := 0.0
	for seg in _segments:
		total += maxf(0.0, float(seg.get("weight", 0.0)))
	if total <= 0.0:
		return
	var side := minf(size.x, size.y)
	if side <= 8.0:
		return
	# 环宽按可用短边取比例，半径扣掉半个环宽，避免描边被节点边界切掉
	var thickness := side * 0.15
	var radius := side * 0.5 - thickness * 0.5 - 1.0
	var center := size * 0.5
	# 多段之间留一道缝，否则相邻颜色的分界会糊在一起；段太窄时不留缝，免得整段消失
	var gap := 0.025 if _segments.size() > 1 else 0.0
	var angle := 0.0
	for seg in _segments:
		var weight := maxf(0.0, float(seg.get("weight", 0.0)))
		if weight <= 0.0:
			continue
		var span := TAU * weight / total
		var g := gap if span > gap * 3.0 else 0.0
		var from := angle + g * 0.5
		var to := angle + span - g * 0.5
		if to > from:
			draw_arc(center, radius, from, to, maxi(6, int(ceil(span * 40.0))),
				seg.get("color", Color.WHITE), thickness, true)
		angle += span

shader_type canvas_item;

// 封面圆角遮罩：程序化把控件裁成圆角矩形，不需要任何贴图资源。
// 工作在节点自身 UV 空间，不受外部 skew / 嵌套裁剪影响（区别于 clip_children 的 backbuffer 方案）。
uniform float corner_radius = 10.0;                // 圆角半径（像素）
uniform vec2  rect_size     = vec2(120.0, 126.0);  // 控件尺寸（像素），由脚本在 resize 时写入

void fragment() {
	vec2 half_size = rect_size * 0.5;
	// 圆角矩形 SDF：dist < 0 在内部，> 0 在外部
	vec2 q = abs(UV * rect_size - half_size) - half_size + vec2(corner_radius);
	float dist = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - corner_radius;
	// 用屏幕导数做 1px 抗锯齿
	float aa = max(fwidth(dist), 0.0001);
	COLOR.a *= 1.0 - smoothstep(-aa * 0.5, aa * 0.5, dist);
}

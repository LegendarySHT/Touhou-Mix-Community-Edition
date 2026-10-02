shader_type canvas_item;

// 圆角遮罩：程序化把控件裁成圆角矩形，不需要任何贴图资源。
// 工作在节点自身 UV 空间，不受外部 skew / 嵌套裁剪影响（区别于 clip_children 的 backbuffer 方案）。
// stretch 模式若裁剪 / 留白（如 COVERED 走 region 绘制），UV 不再铺满 0~1，
// 需把可见绘制区的尺寸与 UV 区间写入下面两个 uniform，遮罩才能贴合最终图像；
// RoundedTextureRect 节点会自动维护，直接用材质的话需自行同步。
uniform float corner_radius = 10.0;                // 圆角半径（像素）
uniform vec2  rect_size     = vec2(120.0, 120.0);  // 可见绘制区尺寸（像素），由 RoundedTextureRect 在 resize / 换图时写入
uniform vec4  uv_rect       = vec4(0.0, 0.0, 1.0, 1.0); // 可见区域的 UV 矩形（xy 左上 / zw 尺寸，Rect2 转 vec4 即此布局）

void fragment() {
	vec2 uv = (UV - uv_rect.xy) / max(uv_rect.zw, vec2(1e-6));
	vec2 half_size = rect_size * 0.5;
	// 圆角矩形 SDF：dist < 0 在内部，> 0 在外部
	vec2 q = abs(uv * rect_size - half_size) - half_size + vec2(corner_radius);
	float dist = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - corner_radius;
	// 用屏幕导数做 1px 抗锯齿
	float aa = max(fwidth(dist), 0.0001);
	COLOR.a *= 1.0 - smoothstep(-aa * 0.5, aa * 0.5, dist);
}

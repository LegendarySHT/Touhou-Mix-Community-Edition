shader_type canvas_item;

// 背景合成着色器：在背景纹理之上依次叠加「暗化」与「判定闪光」。
// 这两步原先由独立的 DimOverlay 全屏 ColorRect 承担，会在背景之外多产生
// 一整层全屏 alpha 混合（2880×1800 约 5.18 Mpx 的读-改-写带宽）。
// 合并进背景自身后，全屏混合层数由 2 层降为 1 层。
// 输出与「背景 + 原 DimOverlay（普通 alpha 混合）」严格等价。

uniform vec4 dim_color : source_color = vec4(0.0, 0.0, 0.0, 0.5);
uniform vec4 flash_color : source_color = vec4(1.0);
uniform float flash_progress : hint_range(0.0, 1.0) = 0.0;
uniform float flash_radius : hint_range(0.3, 1.5) = 0.85;

void fragment() {
	// 与原 DimOverlay 的 fragment 一致：暗化色与闪光色按径向强度在 RGBA 上插值
	vec4 layer = dim_color;
	if (flash_progress > 0.0) {
		float dist = length(UV - vec2(0.5, 0.5));
		float radial = 1.0 - smoothstep(flash_radius * 0.35, flash_radius, dist);
		layer = mix(dim_color, flash_color, flash_progress * radial);
	}
	// 等价于该层再以普通 alpha 混合叠到背景之上
	COLOR = vec4(mix(COLOR.rgb, layer.rgb, layer.a), COLOR.a);
}
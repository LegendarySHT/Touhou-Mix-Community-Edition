shader_type canvas_item;

// 封面背景模糊。一次烘焙成静态纹理，算法靠 style 切换（只为挑效果，不追性能）。
//
// style 顺序必须与 ViewBackground.COVER_BLUR_STYLES、设置界面下拉项一致：
//   0 none      原图
//   1 gaussian  高斯（各向同性，最像系统亚克力）
//   2 box       盒式均值（最快，边缘略硬）
//   3 tent      三角/帐篷（两次盒式的等效，比 box 柔）
//   4 bokeh     圆盘散景（高光摊成碟，摄影感）
//   5 glass     磨砂玻璃（模糊 + 噪点 + 轻微色散）
//   6 pixelate  方块马赛克（硬边，强度 = 块边长）
//   7 soft      模糊马赛克（块间双线性过渡，块心仍是纯色）
//   8 cells     瓷砖马赛克（Voronoi 不规则块，没有方形硬角）
//
// 大半径靠 textureLod 降采样支撑：半径越大选越高 mip，单级内半径永远不超过
// LOD_STEP 个纹素，采样点不会稀疏。注意单点 LOD 采样会糊成色块（旧版"水彩糊"），
// 这里是「降采样 + 多点 gather」，两回事。
// 要求传入的纹理带 mipmap，否则 textureLod 恒返回 0 级、大半径会退化成稀疏噪声。

uniform int style : hint_range(0, 8) = 1;
uniform float blur_strength : hint_range(0.0, 1.0) = 0.8;
// 半径占画面宽度的比例（blur_strength = 1 时的基准）。0.09 ≈ 屏宽 9%。
// 仅对卷积类算法有效；马赛克的 blur_strength 语义是块边长，不看这个值。
uniform float radius_ratio : hint_range(0.0, 0.5) = 0.09;
// 模糊会拉平颜色分布（降饱和→发白），这里做饱和度恢复
uniform float saturation : hint_range(0.5, 2.0) = 1.06;
uniform float noise_amount : hint_range(0.0, 0.15) = 0.035;

const float JITTER_TAU = 6.28318530718;
const float GOLDEN_ANGLE = 2.399963229728653;
// 单级 LOD 内允许的最大半径（纹素）。越大采样越稀，8 是 64 采样下的安全值
const float LOD_STEP = 8.0;
const int MAX_TAPS = 128;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

vec4 tap(sampler2D tex, vec2 uv, vec2 off, float lod) {
	return textureLod(tex, uv + off, lod);
}

// 径向对称 gather。weight_mode: 0 均匀圆盘 / 1 高斯 / 2 三角
vec4 radial_gather(sampler2D tex, vec2 uv, float lr, float lod, int samples, int weight_mode, float jitter) {
	vec4 acc = vec4(0.0);
	float wsum = 0.0;
	float sigma = max(lr * 0.5, 1e-6);
	for (int i = 0; i < MAX_TAPS; i++) {
		if (i >= samples) { break; }
		float fi = float(i) + 0.5;
		// sqrt 让采样点按面积均匀铺在圆盘内，而不是中心挤成一团
		float t = sqrt(fi / float(samples));
		float r = t * lr;
		float a = float(i) * GOLDEN_ANGLE + jitter;
		vec4 c = tap(tex, uv, vec2(cos(a), sin(a)) * r, lod);
		float w = 1.0;
		if (weight_mode == 1) {
			w = exp(-(r * r) / (2.0 * sigma * sigma));
		} else if (weight_mode == 2) {
			w = 1.0 - t;
		}
		acc += c * w;
		wsum += w;
	}
	return acc / max(wsum, 1e-6);
}

// 圆盘散景：软边盘 + 亮度加权（高光贡献放大，摊成碟形）
vec4 f_bokeh(sampler2D tex, vec2 uv, float lr, float lod, float jitter) {
	const int N = 96;
	vec4 acc = vec4(0.0);
	float wsum = 0.0;
	for (int i = 0; i < MAX_TAPS; i++) {
		if (i >= N) { break; }
		float fi = float(i) + 0.5;
		float t = sqrt(fi / float(N));
		float r = t * lr;
		float a = float(i) * GOLDEN_ANGLE + jitter;
		vec4 c = tap(tex, uv, vec2(cos(a), sin(a)) * r, lod);
		float l = dot(c.rgb, vec3(0.299, 0.587, 0.114));
		// 软边盘：0.6R 内权重平坦，0.6R~R 平滑收到 0，无硬边环
		float edge = 1.0 - smoothstep(0.6, 1.0, t);
		float w = edge * (0.75 + l * 0.5);
		acc += c * w;
		wsum += w;
	}
	// 中心补少量原始细节，避免整块糊死
	float cw = 1.0 + lr * 8.0;
	acc += textureLod(tex, uv, lod) * cw;
	wsum += cw;
	return acc / wsum;
}

// 马赛克类按块大小选 mip：块越大 mip 越低，保证块内采样不稀疏、又不跨块取色
float block_lod(float block_uv, float tex_w) {
	return max(0.0, log2(max(block_uv * tex_w, 1.0) / LOD_STEP));
}

// 方块马赛克：块内统一取中心一色。多点采样会跨到邻块，块越大越混色（"颜色乱"）。
vec4 f_pixelate(sampler2D tex, vec2 uv, float block_uv, float lod) {
	vec2 block = vec2(block_uv);
	vec2 snapped = (floor(uv / block) + 0.5) * block;
	// 再降半级 mip：块心取的是块内平均色，不是某一个纹素
	return textureLod(tex, snapped, lod + 0.5);
}

// 模糊马赛克：块中心取色后按块内位置双线性插值，等于把缩小几倍的图放大回来。
// 块边界是渐变而非断面，大块时不会一格一格跳色。
vec4 f_pixelate_soft(sampler2D tex, vec2 uv, float block_uv, float lod) {
	vec2 g = uv / block_uv - 0.5;
	vec2 i = floor(g);
	vec2 f = g - i;
	// smoothstep：块心附近变化慢（纯色）、块边界附近变化快（过渡窄），
	// 纯线性插值会让块心也带坡度，整片糊成一块，看不出马赛克结构
	f = f * f * (3.0 - 2.0 * f);
	vec2 b = vec2(block_uv);
	vec4 c00 = textureLod(tex, (i + vec2(0.5, 0.5)) * b, lod);
	vec4 c10 = textureLod(tex, (i + vec2(1.5, 0.5)) * b, lod);
	vec4 c01 = textureLod(tex, (i + vec2(0.5, 1.5)) * b, lod);
	vec4 c11 = textureLod(tex, (i + vec2(1.5, 1.5)) * b, lod);
	return mix(mix(c00, c10, f.x), mix(c01, c11, f.x), f.y);
}

// 瓷砖马赛克：每格放一个随机偏移的特征点，整块取最近特征点所在格的颜色。
// 块形状是 Voronoi 多边形，没有方形硬角，比方格自然；块内仍只有一色，不跳色。
vec4 f_cells(sampler2D tex, vec2 uv, float block_uv, float lod) {
	vec2 g = uv / block_uv;
	vec2 base = floor(g);
	float best = 1e9;
	vec2 bestp = g;
	// 3x3 邻域足够：特征点偏移不超过半格，最近的必在相邻格内
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 cell = base + vec2(float(x), float(y));
			vec2 jit = vec2(hash12(cell), hash12(cell + vec2(17.3, 41.7))) - 0.5;
			vec2 p = cell + 0.5 + jit * 0.8;
			vec2 d = g - p;
			float dd = dot(d, d);
			if (dd < best) {
				best = dd;
				bestp = p;
			}
		}
	}
	return textureLod(tex, bestp * block_uv, lod);
}

// 磨砂玻璃：高斯打底 + 轻微色散（RGB 采样半径略不同）+ 颗粒
vec4 f_glass(sampler2D tex, vec2 uv, float lr, float lod, float jitter) {
	vec4 base = radial_gather(tex, uv, lr, lod, 64, 1, jitter);
	// 色散：红通道半径略小、蓝通道略大（等效一个很弱的棱镜）
	vec4 cr = radial_gather(tex, uv, lr * 0.92, lod, 24, 1, jitter);
	vec4 cb = radial_gather(tex, uv, lr * 1.08, lod, 24, 1, jitter);
	vec4 col = vec4(cr.r, base.g, cb.b, base.a);
	float n = hash12(uv * 900.0) - 0.5;
	col.rgb += n * noise_amount;
	return col;
}

void fragment() {
	float s = clamp(blur_strength, 0.0, 1.0);
	// 低段与旧版线性一致（0.8 处几乎不变），过了 SOFT_CAP 陡增到 RAMP 倍。
	// 旧版 1.0 只有 9% 屏宽，糊住了细节但轮廓还在；现在 1.0 ≈ 32%，只剩色块。
	const float SOFT_CAP = 0.75;
	const float RAMP = 3.6;
	float s_eff = s;
	if (s > SOFT_CAP) {
		float t = (s - SOFT_CAP) / (1.0 - SOFT_CAP);
		s_eff = SOFT_CAP + t * t * (RAMP - SOFT_CAP);
	}
	float r_uv = radius_ratio * s_eff;

	if (style == 0 || r_uv <= 1e-6) {
		// 不模糊：原图直出（fragment() 里不能 return，用 else 分段）
		COLOR = textureLod(TEXTURE, UV, 0.0);
	} else {
		float tex_w = 1.0 / TEXTURE_PIXEL_SIZE.x;
		// 半径用 uv 表达，屏幕上的实际尺度与纹理分辨率无关（纹理被拉伸多少都不会变）。
		// lod 只负责把采样点摊到足够低的 mip 层，让单级内半径不超过 LOD_STEP 纹素；
		// 绝不能拿 lod 去缩半径 —— 旧版 `lr = r_uv / exp2(lod)` 约分后等于 8/tex_w，
		// 半径恒定 8 纹素、与 blur_strength 完全脱钩，这才是"怎么都糊不动"的根因。
		float lod = max(0.0, log2(max(r_uv * tex_w, 1.0) / LOD_STEP));
		float lr = r_uv;
		// 抖动打散螺旋结构，否则大半径下能看出同心纹
		float jitter = hash12(UV * 1024.0) * JITTER_TAU;

		vec4 col;
		if (style == 1) {
			col = radial_gather(TEXTURE, UV, lr, lod, 64, 1, jitter);
		} else if (style == 2) {
			col = radial_gather(TEXTURE, UV, lr, lod, 48, 0, jitter);
		} else if (style == 3) {
			col = radial_gather(TEXTURE, UV, lr, lod, 48, 2, jitter);
		} else if (style == 4) {
			col = f_bokeh(TEXTURE, UV, lr, lod, jitter);
		} else if (style == 5) {
			col = f_glass(TEXTURE, UV, lr, lod, jitter);
		} else {
			// 马赛克类没有"半径"，用强度直接控制块边长：0.4% → 12.4% 屏宽（约 250 块 → 8 块）。
			// mip 按块大小单独选，否则块心会采样到别块的色，边缘渗透。
			float buv = 0.004 + s * 0.12;
			float blod = block_lod(buv, tex_w);
			if (style == 6) {
				col = f_pixelate(TEXTURE, UV, buv, blod);
			} else if (style == 7) {
				col = f_pixelate_soft(TEXTURE, UV, buv, blod);
			} else {
				col = f_cells(TEXTURE, UV, buv, blod);
			}
		}

		// 饱和度恢复（抵消模糊导致的发白）
		float lum = dot(col.rgb, vec3(0.299, 0.587, 0.114));
		col.rgb = mix(vec3(lum), col.rgb, saturation);
		COLOR = col;
	}
}

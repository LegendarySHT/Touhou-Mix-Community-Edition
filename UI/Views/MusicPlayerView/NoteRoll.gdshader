shader_type canvas_item;

// 播放头（毫秒，绝对时间）与视窗参数
uniform float u_pos_ms = 0.0;
uniform float u_view_h = 270.0;
uniform float u_span_ms = 1400.0;
uniform float u_min_note_h = 3.0;
uniform float u_bright_steps = 16.0;
uniform float u_bright_span = 500.0;
uniform float u_bright_min = 0.28;

// 顶点色（实例颜色 × 节点 modulate 链）与亮度 alpha，传给 fragment 自行相乘
varying vec4 modulate_chain;
varying float v_alpha;

void vertex() {
	modulate_chain = COLOR;
	v_alpha = 1.0;

	vec4 cd = INSTANCE_CUSTOM;              // (start_ms, end_ms, 0, 0)
	float k = u_view_h / u_span_ms;
	float y_head = u_view_h + (u_pos_ms - cd.x) * k;
	float y_tail = u_view_h + (u_pos_ms - cd.y) * k;

	// 亮度档位：离发声点越远越暗，到达发声点后保持全亮
	float lv = clamp(floor((cd.x - u_pos_ms) * u_bright_steps / u_bright_span),
			0.0, u_bright_steps);
	v_alpha = lv < 0.5 ? 1.0 : max(u_bright_min, 1.0 - lv / u_bright_steps);

	if (y_head < 0.0 || y_tail > u_view_h) {
		// 未进入顶部 / 已完全流出底部：四点退化为同一点，不产生像素
		VERTEX = vec2(0.0);
		v_alpha = 0.0;
	} else {
		float uv_y = VERTEX.y + 0.5;            // QuadMesh 1x1 以原点为中心
		float top = max(y_tail, 0.0);
		float nh = min(y_head, u_view_h) - top;
		if (nh < u_min_note_h) nh = u_min_note_h;
		VERTEX.y = top + nh * uv_y;
	}
}

void fragment() {
	COLOR = texture(TEXTURE, UV) * modulate_chain;
	COLOR.a *= v_alpha;
}

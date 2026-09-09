shader_type canvas_item;
render_mode unshaded;

uniform sampler2D weight_texture : filter_linear, repeat_disable;
uniform sampler2D blink_texture : source_color, hint_default_transparent, filter_linear, repeat_disable;
uniform vec2 portrait_size = vec2(650.0, 990.0);
uniform vec2 head_pivot = vec2(0.28, 0.4);
uniform float phase = 0.0;
uniform float breath = 2.2;
uniform float sway = 2.5;
uniform float hair = 4.0;
uniform float skirt = 5.0;
uniform float motion_scale = 1.0;
uniform float blink_amount : hint_range(0.0, 1.0) = 0.0;
varying vec4 portrait_tint;

void vertex() {
	portrait_tint = COLOR;
	vec3 weights = texture(weight_texture, UV).rgb;
	float head_weight = (1.0 - smoothstep(head_pivot.y - 0.06, head_pivot.y + 0.1, UV.y)) * (1.0 - weights.r);
	float angle = radians(sway) * sin(phase) * head_weight * motion_scale;
	vec2 pivot = (head_pivot - vec2(0.5)) * portrait_size;
	vec2 relative_position = VERTEX - pivot;
	VERTEX = pivot + mat2(vec2(cos(angle), sin(angle)), vec2(-sin(angle), cos(angle))) * relative_position;
	VERTEX.y -= sin(phase) * breath * (1.0 - UV.y) * motion_scale;
	VERTEX.x += (sin(phase + 0.8) * hair * weights.g + sin(phase - 0.7) * skirt * weights.b) * motion_scale;
}

void fragment() {
	vec4 portrait = texture(TEXTURE, UV);
	vec4 eyelids = texture(blink_texture, UV);
	COLOR = vec4(mix(portrait.rgb, eyelids.rgb, eyelids.a * blink_amount), portrait.a) * portrait_tint;
}

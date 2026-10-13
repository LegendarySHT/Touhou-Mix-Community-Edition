extends RefCounted
class_name NoteFallCalculator

## 计算音符下落速度（像素/毫秒）
## @param distance_px 下落距离（像素）
## @param fall_time_seconds 下落时间（秒）
## @return 速度（像素/毫秒）
func compute_speed_px_per_ms(distance_px: float, fall_time_seconds: float) -> float:
	var safe_time_ms = max(1.0, fall_time_seconds * 1000.0)
	return max(0.0001, distance_px) / safe_time_ms

## 根据距离与速度计算时长（秒）
## @param distance_px 距离（像素）
## @param speed_px_per_ms 速度（像素/毫秒）
## @return 时长（秒）
func compute_duration_seconds(distance_px: float, speed_px_per_ms: float) -> float:
	var safe_speed = max(0.0001, speed_px_per_ms)
	return max(0.0, distance_px) / safe_speed / 1000.0

## 计算判定线后下落时长（秒）
## @param distance_px 判定线后下落距离（像素）
## @param base_speed_px_per_ms 判定线前基础速度（像素/毫秒）
## @param after_speed_multiplier 判定线后速度倍率
## @return 时长（秒）
func compute_after_line_duration_seconds(distance_px: float, base_speed_px_per_ms: float, after_speed_multiplier: float) -> float:
	var safe_multiplier = max(0.01, after_speed_multiplier)
	var after_speed = max(0.0001, base_speed_px_per_ms) * safe_multiplier
	return compute_duration_seconds(distance_px, after_speed)

## 评估缓动曲线在指定进度的归一化位移（0~1）
## @param progress 归一化时间进度（0~1）
## @param trans Tween.TRANS_* 常量
## @param ease_ Tween.EASE_* 常量
## @return 归一化位移（0~1）
func evaluate_curve_progress(progress: float, trans: int, ease_: int) -> float:
	var safe_progress = clamp(progress, 0.0, 1.0)
	if trans == Tween.TRANS_LINEAR:
		return safe_progress
	var value = Tween.interpolate_value(0.0, 1.0, safe_progress, 1.0, trans, ease_)
	return clamp(float(value), 0.0, 1.0)

## 在指定缓动曲线下，计算保证“头部在开始时刻到线、尾部在持续时长后到线”的长条总高度（含头尾）
## @param pre_line_distance_px 普通音符从生成点到判定线的距离（像素）
## @param pre_line_fall_time_seconds 普通音符下落到判定线所需时间（秒）
## @param hold_duration_ms 长条持续时间（毫秒）
## @param trans Tween.TRANS_* 常量
## @param ease_ Tween.EASE_* 常量
## @param fallback_speed_px_per_ms 兜底线性速度（像素/毫秒）
## @return 长条总高度（像素，包含头尾）
func compute_long_total_height_with_easing(
	pre_line_distance_px: float,
	pre_line_fall_time_seconds: float,
	hold_duration_ms: float,
	trans: int,
	ease_: int,
	fallback_speed_px_per_ms: float,
	reference_offset_px: float = 0.0
) -> float:
	var safe_distance = max(0.0001, pre_line_distance_px)
	var safe_pre_time = max(0.001, pre_line_fall_time_seconds)
	var safe_hold_ms = max(0.0, hold_duration_ms)
	var safe_offset = max(0.0, reference_offset_px)

	if safe_hold_ms <= 0.0:
		return 0.0

	var hold_seconds = safe_hold_ms / 1000.0
	var alpha = safe_pre_time / (safe_pre_time + hold_seconds)
	var eased_alpha = evaluate_curve_progress(alpha, trans, ease_)

	if eased_alpha <= 0.0001:
		return max(0.0, max(0.0001, fallback_speed_px_per_ms) * safe_hold_ms + safe_offset)

	return max(0.0, (safe_distance + safe_offset) / eased_alpha - safe_distance)

## 计算长条主体高度（像素）
## @param duration_ms 长条持续时间（毫秒）
## @param speed_px_per_ms 基础下落速度（像素/毫秒）
## @param head_tail_total_px 头尾总高度（像素）
## @return 长条主体高度（像素）
func compute_long_body_height(duration_ms: float, speed_px_per_ms: float, head_tail_total_px: float) -> float:
	return max(0.0, speed_px_per_ms * max(0.0, duration_ms) - max(0.0, head_tail_total_px))

## 方案 A（屏幕固定映射）：贴图纵向一次性映射到 [0, ref_h] 屏幕区间，再按 body 区间裁剪。
## 结果：任意身体高度下缩放系数恒为 tex_h/ref_h，且同一屏幕高度处显示的贴图内容一致。
## @param x 绘制左缘（屏幕坐标）
## @param w 绘制宽度
## @param body_top body 顶部 y（屏幕坐标，绘制区间上界）
## @param body_h body 高度（<=0 视为不可见）
## @param ref_h 参考区间高度（通常为屏幕高度，<=0 视为无效）
## @param tex_w 贴图宽度（像素）
## @param tex_h 贴图高度（像素）
## @return {src: Rect2, dst: Rect2}；body 完全在参考区间外或参数无效时返回空 Dictionary（调用方跳过绘制）
static func compute_screen_span_rect(x: float, w: float, body_top: float, body_h: float,
		ref_h: float, tex_w: float, tex_h: float) -> Dictionary:
	if body_h <= 0.0 or ref_h <= 0.0 or tex_w <= 0.0 or tex_h <= 0.0:
		return {}
	# 屏幕 y → 贴图 v（线性，与屏幕高度绑定）
	var v0 := body_top / ref_h
	var v1 := (body_top + body_h) / ref_h
	# 越出参考区间的部分裁掉（该部分在屏幕外，本来就不可见）
	var cv0 := clampf(v0, 0.0, 1.0)
	var cv1 := clampf(v1, 0.0, 1.0)
	if cv1 - cv0 <= 0.0:
		return {}
	var span_ratio := cv1 - cv0
	var src := Rect2(0.0, cv0 * tex_h, tex_w, span_ratio * tex_h)
	# 裁剪后绘制区间的起点相应内缩（cv0 - v0 为顶部被裁掉的比例）
	var dst := Rect2(x, body_top + (cv0 - v0) * ref_h, w, span_ratio * ref_h)
	return {"src": src, "dst": dst}

## 方案 B（按实际长度映射）：贴图按 ref_len 固定比例纵向映射，贴图顶部对齐身体上端（尾端）。
## 结果：贴图缩放系数恒为 tex_h/ref_len，不随身体收缩变形；贴图随长条整体下移，
## 向下越出身体的部分（屏幕下方 / 被判定线吞掉）直接裁掉。
## 身体长度超过基准长度时（缓动拉长等），贴图会被拉伸填满身体，保证不留空洞。
## @param x 绘制左缘（屏幕坐标）
## @param w 绘制宽度
## @param body_top body 顶部 y（屏幕坐标）
## @param body_h body 高度（<=0 视为不可见）
## @param ref_len 映射基准长度（长条恒速下落时身体的自然像素长度）
## @param tex_w 贴图宽度（像素）
## @param tex_h 贴图高度（像素）
## @return {src: Rect2, dst: Rect2}；参数无效时返回空 Dictionary（调用方跳过绘制）
static func compute_length_span_rect(x: float, w: float, body_top: float, body_h: float,
		ref_len: float, tex_w: float, tex_h: float) -> Dictionary:
	if body_h <= 0.0 or ref_len <= 0.0 or tex_w <= 0.0 or tex_h <= 0.0:
		return {}
	var scale := tex_h / ref_len  # 贴图像素 / 屏幕像素（固定比例）
	var visible_tex_h := minf(body_h * scale, tex_h)
	# 贴图顶部锚定身体上端（尾端），随长条下移；向下越出的部分裁掉
	var src := Rect2(0.0, 0.0, tex_w, visible_tex_h)
	var dst := Rect2(x, body_top, w, body_h)
	return {"src": src, "dst": dst}

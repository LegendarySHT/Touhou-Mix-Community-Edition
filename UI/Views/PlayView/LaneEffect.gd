extends Control

## 轨道光效层（挂 Lane 节点）
## 单节点 _draw() 批量绘制全部流光柱（替代原 N 个 BeamNode 节点），
## 淡出由 _process 帧驱动 + 预计算 EASE_IN cubic LUT 查表（无逐轨道 Tween 对象）。
## 同时承载键盘模式轨道分隔线与键位标签（动态 Control 子节点）。
## 与 NoteBatchDrawer（音符）/ParticleBatchDrawer（粒子）的批量绘制架构一致。

# 轨道分隔线宽度（像素）
const SEPARATOR_WIDTH := 5.0

# 分隔线颜色：轨道之间白色，最左/最右边缘线黄色（突出轨道区域边界）
const SEPARATOR_COLOR := Color(1.0, 1.0, 1.0, 0.6)
const EDGE_SEPARATOR_COLOR := Color(1.0, 0.85, 0.0, 0.9)

# 光柱内层渐变收缩量 / 底部高亮横条高度
const CENTER_INSET := 20.0
const LIGHT_H := 3.0
## 淡出曲线 LUT 分辨率（EASE_IN cubic：1-(1-x)³，256 项对 0.4s 淡出足够平滑）
const _LUT_SIZE := 256

# 单光柱运行时状态（轻量内部类，非节点）
class BeamState:
	var color: Color = Color.WHITE  # 轨道色（light_lane 设置）
	var progress: float = 1.0       # 淡出进度 0→1（1=刚点亮，0=熄灭）
	var active: bool = false        # 是否处于淡出中

var play_view = null

var _beam_height: float = 0
var _beam_padding: int = 0
var _beam_lane_width: float = 0
var _beam_note_width: int = 0
var _mid_gap: int = 0             # 中间间距（init_beam 布局时保存，分隔线绘制用）
var _key_label_overlay: Control = null
var _beam_alpha_scale: float = 1.0    # 淡出起点不透明度（set_beam_alpha）
var _beam_fade_duration_sec: float = 0.4
var _lane_count: int = 0

# 分隔线渐变纹理缓存（同色共用一张，避免每条线各建纹理）
var _sep_tex_cache: Dictionary = {}

# ---- 光柱批量绘制状态 ----
var beam_size: Vector2 = Vector2.ZERO
var _lane_xs: PackedFloat32Array = PackedFloat32Array()  # 每光柱左缘 x（init_beam 布局后写入）
var _states: Array = []            # Array[BeamState]，与轨道数一致
var _outer_tex: GradientTexture2D = null
var _center_tex: GradientTexture2D = null
## 淡出曲线 LUT（EASE_IN cubic：alpha = _beam_alpha_scale * (1-(1-progress)³)，
## 与原 Tween.TRANS_CUBIC + EASE_IN 驱动 self_modulate:a 的曲线完全一致）
var _fade_lut: PackedFloat32Array = PackedFloat32Array()


func _ready() -> void:
	# 默认禁用 _process：无活跃光柱时零开销，light_lane 首个点亮时启用
	set_process(false)
	_build_fade_lut()


func init_beam(lane_count: int, parent_node) -> void:
	# 清空动态子节点（分隔线/键位标签）
	for ch in get_children():
		ch.free()
	_key_label_overlay = null
	play_view = parent_node
	_lane_count = lane_count

	var note_width: int   = play_view.flow_area.note_visual_width
	var padding: int      = play_view.lane_padding
	var window            := get_viewport().get_visible_rect().size
	var beam_h: float     = window.y - play_view.judge_line_offset_y
	# 轨道光效宽度模式 (0=跟随音符宽度, 1=跟随轨道宽度)
	var beam_width_mode = ConfigManager.instance.get_int("beam_width_mode", 0)
	var safe_width: float = max(1.0, window.x - 2.0 * float(padding))
	# 中间间距（键盘模式 + 偶数键位）：从可用宽度中扣除，再在中间插入，保证总宽不超屏幕
	var mid_gap: int = play_view.get_mid_lane_gap()
	_mid_gap = mid_gap
	# 模式 0 光柱宽（= 音符宽 + 20 边距）：同时是轨道中心距计算的固定基准。
	# 两种模式共用同一轨道中心（lane_step / lane_start_center_x），切模式只有光柱宽度变化、
	# 中心不动——否则光效/分界线会相对音符列整体偏移（mode 0 行为保持原样不变）
	var beam_w0: float = note_width + 20.0
	var lane_step: float = 0.0
	var lane_start_center_x: float = float(padding) + safe_width * 0.5
	if lane_count > 1:
		lane_step = max(0.0, (safe_width - float(mid_gap) - beam_w0) / float(lane_count - 1))
		lane_start_center_x = float(padding) + beam_w0 * 0.5
	# 光柱宽度：模式 0 = 音符宽+20；模式 1 = 轨道宽度（= 轨道中心距，无缝填满相邻轨道间隔；单轨 = 可玩区整行）
	var beam_w: float = beam_w0
	if beam_width_mode == 1:
		beam_w = lane_step if lane_count > 1 else (safe_width - float(mid_gap))
		beam_w = max(1.0, beam_w)

	_beam_height     = beam_h
	_beam_padding    = padding
	_beam_lane_width = lane_step
	_beam_note_width = note_width

	# 重建光柱状态与共享渐变纹理（单节点统一绘制，两张渐变纹理无重复 GPU 上传）
	beam_size = Vector2(beam_w, beam_h)
	_outer_tex = _make_gradient_tex(Color(1.0, 1.0, 1.0, 0.235), Color(0.754, 0.754, 0.754, 0.055))
	_center_tex = _make_gradient_tex(Color(1.0, 1.0, 1.0, 0.800), Color(1.0,   1.0,   1.0,   0.467))
	_lane_xs.resize(lane_count)
	_lane_xs.fill(0.0)
	_states.clear()
	for i in range(lane_count):
		_states.append(BeamState.new())
	set_process(false)
	queue_redraw()

	# 计算每光柱左缘 x（中间间距：右半侧整体右移，间距已在 lane_step 中扣除，总宽不超屏幕）
	for i in range(lane_count):
		var center_x: float = lane_start_center_x + lane_step * i
		if mid_gap > 0 and i >= int(lane_count / 2.0):
			center_x += mid_gap
		_lane_xs[i] = center_x - beam_w * 0.5

	# 轨道分隔线（仅键盘模式 + 选项开启时生成；开头已 free 全部动态子节点 = 自动清理）
	if play_view != null and play_view.get_lane_separator_enabled():
		_create_separator_lines()


func _make_gradient_tex(c_bottom: Color, c_top: Color) -> GradientTexture2D:
	var grad := Gradient.new()
	grad.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_CUBIC
	grad.colors = PackedColorArray([c_bottom, c_top])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill_from = Vector2(0.0, 1.0)
	tex.fill_to   = Vector2(0.0, 0.0)
	return tex


## 分隔线布局：
## - 相邻轨道之间：普通相邻（间距恒 = lane_step）→ 单线（两轨正中，白色）；
##   中间间距（mid_gap > 0 时唯一被拉开的相邻对：左半最后一根 ↔ 右半第一根）→ 双线
##   （左轨右缘线 + 右轨左缘线，各距轨道中心 lane_step/2，黄色）
## - 最左/最右外框线距轨道中心 lane_step/2（夹取到屏幕内，防止小轨道数越界）
func _create_separator_lines() -> void:
	if _lane_count <= 0:
		return
	# 单轨道：直接框住光束左右缘（两条都是边缘线 → 黄色）
	if _lane_count <= 1:
		_create_separator_line(_lane_xs[0], EDGE_SEPARATOR_COLOR)
		_create_separator_line(_lane_xs[0] + beam_size.x, EDGE_SEPARATOR_COLOR)
		return

	var sep_half: float = _beam_lane_width * 0.5
	var viewport_x: float = get_viewport().get_visible_rect().size.x
	var right_limit: float = maxf(SEPARATOR_WIDTH * 0.5, viewport_x - SEPARATOR_WIDTH * 0.5)

	# 最左外框：最左轨道左缘（距轨道中心 sep_half，边缘线 → 黄色）
	_create_separator_line(clampf(_center_x_of(0) - sep_half, SEPARATOR_WIDTH * 0.5, right_limit), EDGE_SEPARATOR_COLOR)

	# 相邻轨道之间：中间间距（mid_gap 拉开的唯一一对：左半最后一根 ↔ 右半第一根）→ 双线黄色；
	# 其余普通相邻（间距恒等于 lane_step）→ 单线白色。
	# 用确定性索引判断而非 spacing 浮点比较：原实现 `spacing <= sep_half*2`（阈值恰等于 lane_step）
	# 在浮点误差下会把普通相邻误判为双线，导致白线随机变黄
	var mid_split := int(_lane_count / 2.0) - 1
	for i in range(_lane_count - 1):
		if _mid_gap > 0 and i == mid_split:
			# 双线：左轨右缘线 + 右轨左缘线（间距拉开后各归各的，边缘线 → 黄色）
			_create_separator_line(_center_x_of(i) + sep_half, EDGE_SEPARATOR_COLOR)
			_create_separator_line(_center_x_of(i + 1) - sep_half, EDGE_SEPARATOR_COLOR)
		else:
			# 单线：两轨道正中（正常画法）
			_create_separator_line((_center_x_of(i) + _center_x_of(i + 1)) * 0.5)

	# 最右外框：最右轨道右缘（距轨道中心 sep_half，边缘线 → 黄色）
	_create_separator_line(clampf(_center_x_of(_lane_count - 1) + sep_half, SEPARATOR_WIDTH * 0.5, right_limit), EDGE_SEPARATOR_COLOR)


## 轨道光束中心 x（左缘 + 半宽）
func _center_x_of(lane_index: int) -> float:
	return _lane_xs[lane_index] + beam_size.x * 0.5


func _create_separator_line(x: float, color: Color = SEPARATOR_COLOR) -> void:
	var line := TextureRect.new()
	line.position = Vector2(x - SEPARATOR_WIDTH * 0.5, 0.0)
	line.size = Vector2(SEPARATOR_WIDTH, _beam_height)
	line.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	line.stretch_mode = TextureRect.STRETCH_SCALE
	line.texture = _get_separator_tex(color)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(line)


## 分隔线垂直渐变纹理：底部不透明 → 顶部透明（向上逐渐淡出；同色缓存复用）
func _get_separator_tex(color: Color) -> GradientTexture2D:
	if _sep_tex_cache.has(color):
		return _sep_tex_cache[color]
	var grad := Gradient.new()
	grad.colors = PackedColorArray([
		Color(color.r, color.g, color.b, color.a),  # 底部：不透明
		Color(color.r, color.g, color.b, 0.0),      # 顶部：透明
	])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill_from = Vector2(0.0, 1.0)  # 底部
	tex.fill_to   = Vector2(0.0, 0.0)  # 顶部
	_sep_tex_cache[color] = tex
	return tex


func init_key_display(key_map: Array[Key], display_names: Array[String] = []) -> void:
	if _key_label_overlay:
		_key_label_overlay.queue_free()
	_key_label_overlay = Control.new()
	_key_label_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_key_label_overlay)

	# key_map 为空时无需创建任何标签（也避免 label 泄漏）
	if key_map.is_empty():
		return

	var beam_width: float = _beam_note_width + 20.0

	for i in range(key_map.size()):
		var nl := Label.new()
		nl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		nl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
		nl.add_theme_font_size_override("font_size", 42)
		nl.custom_minimum_size  = Vector2(beam_width, 100)
		nl.size = Vector2(beam_width, 100)
		# 优先使用自定义显示名，为空则回退到按键默认名
		var custom_name := display_names[i] if i < display_names.size() else ""
		nl.text = custom_name if not custom_name.is_empty() else OS.get_keycode_string(key_map[i])
		# 标签以光柱中心为基准居中：标签宽固定为音符宽+20，光柱宽随 beam_width_mode 变化，
		# 直接左对齐光柱会在 mode 1（轨道宽度）下让字母相对轨道中心偏右，看起来轨道线也歪了
		var label_x := _lane_xs[i] + (beam_size.x - beam_width) * 0.5
		_key_label_overlay.add_child(nl)
		nl.position = Vector2(label_x, _beam_height)


# ========== 光柱 API ==========

## 轨道左缘 x（FlowArea 计算音符位置用）
func get_lane_x(lane_index: int) -> float:
	if lane_index < 0 or lane_index >= _lane_xs.size():
		return 0.0
	return _lane_xs[lane_index]


## 轨道宽度（= 光柱宽度；FlowArea 计算音符位置用）
func get_lane_width() -> float:
	return beam_size.x


func set_beam_alpha(alpha: float) -> void:
	# 淡出起点 alpha：light_lane 里从此值淡到 0（每光柱状态独立维护）
	_beam_alpha_scale = alpha


## 点亮指定轨道：颜色 + 重置淡出进度（原逐轨道 Tween 合并为单节点帧驱动）
func light_lane(lane_index: int, cl: Color = Color.WHITE) -> void:
	if lane_index < 0 or lane_index >= _states.size():
		return
	var st: BeamState = _states[lane_index]
	st.color = Color(cl.r, cl.g, cl.b, 1.0)
	st.progress = 1.0
	if not st.active:
		st.active = true
	if not is_processing():
		set_process(true)
	queue_redraw()


## 全部熄灭（重初始化/清场时调用）
func clear_beam() -> void:
	for st in _states:
		st.active = false
		st.progress = 0.0
	set_process(false)
	queue_redraw()


# ========== 帧驱动 + 批量绘制 ==========

func _process(delta: float) -> void:
	var step := delta / _beam_fade_duration_sec
	var any_active := false
	for st in _states:
		if not st.active:
			continue
		st.progress -= step
		if st.progress <= 0.0:
			st.progress = 0.0
			st.active = false
		else:
			any_active = true
	if not any_active:
		# 全部淡出结束：停 _process，避免每帧空跑
		set_process(false)
	queue_redraw()


func _draw() -> void:
	if _states.is_empty() or beam_size == Vector2.ZERO:
		return
	var bw := beam_size.x
	var bh := beam_size.y
	var inset := CENTER_INSET
	var light_h := LIGHT_H
	var lut_m1 := _fade_lut.size() - 1
	# 按纹理分批绘制（外层白渐变 → 内层着色渐变 → 底部高亮）：
	# 同纹理连续 N 次绘制利于 Godot CanvasItem 批处理（合并为更少的 draw call），
	# 交错绘制（每光柱 outer/center/rect 轮换）会打断同纹理连续性无法合批。
	# 每根光柱内部层序保持 outer < center < rect（底部高亮仍在最上）。
	# —— 第 1 遍：全部外层白色渐变光柱
	for i in _states.size():
		var st: BeamState = _states[i]
		if not st.active or st.progress <= 0.0:
			continue
		var x := _lane_xs[i]
		# 淡出曲线查表（EASE_IN cubic，O(1) 无插值；256 项对 0.4s 淡出不可见阶梯）
		var a := _beam_alpha_scale * _fade_lut[mini(int(st.progress * float(lut_m1)), lut_m1)]
		draw_texture_rect(_outer_tex, Rect2(x, 0.0, bw, bh), false, Color(1.0, 1.0, 1.0, a))
	# —— 第 2 遍：全部内层着色渐变光柱（颜色走 modulate，同为顶点属性可合批）
	for i in _states.size():
		var st: BeamState = _states[i]
		if not st.active or st.progress <= 0.0:
			continue
		var x := _lane_xs[i]
		var a := _beam_alpha_scale * _fade_lut[mini(int(st.progress * float(lut_m1)), lut_m1)]
		draw_texture_rect(_center_tex, Rect2(x + inset, 0.0, bw - inset * 2.0, bh), false,
			Color(st.color.r, st.color.g, st.color.b, a))
	# —— 第 3 遍：全部底部高亮横条，用纯色矩形代替原 StyleBoxFlat shadow（无 GPU 模糊开销）
	for i in _states.size():
		var st: BeamState = _states[i]
		if not st.active or st.progress <= 0.0:
			continue
		var a := _beam_alpha_scale * _fade_lut[mini(int(st.progress * float(lut_m1)), lut_m1)]
		draw_rect(Rect2(_lane_xs[i], bh - light_h, bw, light_h), Color(2.0, 2.0, 2.0, 0.9 * a))


## 预计算淡出曲线 LUT（EASE_IN cubic：1-(1-x)³）
func _build_fade_lut() -> void:
	_fade_lut.resize(_LUT_SIZE)
	for i in _LUT_SIZE:
		var x := float(i) / float(_LUT_SIZE - 1)
		var u := 1.0 - x
		_fade_lut[i] = 1.0 - u * u * u

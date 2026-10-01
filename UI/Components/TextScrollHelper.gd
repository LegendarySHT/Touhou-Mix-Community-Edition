## 文字滚动工具（自绘版）
## 附加到 Label 节点上即可自动启用超长单行文本的来回滚动效果（marquee）。
##
## 原理：
##   继承 Label，把引擎绘制的文字颜色改为透明（引擎 C++ 绘制无法拦截，
##   故用 theme override 让引擎文本不可见），自己用 draw_string 绘制文本。
##   裁剪窗口 = 节点自身矩形（静止），滚动偏移作用在文本绘制坐标上，
##   因此滚动时能看到被裁剪掉的内容，无需外层 clip Control，单节点即可。
##
## 用法：
##   将本脚本挂到 Label 的 "script" 属性即可，无需任何额外调用：
##     - 用 set_scroll_text() 设置文本（不要直接赋 label.text，否则不会触发滚动重算）
##     - 复用 Label 的 font / font_size 等 theme override；文字颜色用 _text_color
##     - 尺寸变化时自动重算
##     - 节点退出场景树时自动清理滚动
##
## 注意：
##   - 仅支持单行文本（不处理 autowrap / 富文本 / 省略号 / RTL）
##   - 需在场景中给 Label 固定宽度或 expand（本脚本不因文本撑大节点）
extends Label

## 滚动到端点后的停留时长
const PAUSE_DURATION := 1.0

## 滚动速度（像素/秒）：长文本与短文本统一像素速度，单程时长按滚动距离换算
@export var scroll_speed := 60.0
## 滚动缓动曲线：SINE 端点减速最温和，QUAD/CUBIC/QUART 端点减速逐级更明显
@export var transition: Tween.TransitionType = Tween.TRANS_QUAD

## 自绘文字颜色（默认取 theme 的 font_color，可被场景 theme override 覆盖）
@export var text_color: Color = Color(1, 1, 1, 1)
## 场景是否显式指定了 font_color（压在图片/封面上的固定色）：锁定后主题切换不刷新
var _locked_color: bool = false
## 锁定时捕获一次的显式色（后续透明 override 会覆盖原 override，故需缓存）
var _locked_text_color: Color = Color(1, 1, 1, 1)
## 描边宽度（0 = 不描边）
@export var outline_size := 0
## 描边颜色
@export var outline_color := Color(0, 0, 0, 1)
## 阴影颜色（alpha 为 0 时不画阴影）
@export var shadow_color := Color(0, 0, 0, 0)
## 阴影偏移
@export var shadow_offset := Vector2(1, 1)
## 滚动两端留出的空隙（像素）：起始文本左边、终点文本右边各留 end_padding，避免贴边界
@export var end_padding := 20.0

## 当前滚动偏移（像素，负值向左）
var _scroll_offset := 0.0
## 实际文本宽度（get_string_size），用于判断是否溢出
var _text_width := 0.0
var _tween: Tween = null
var _resized_callable: Callable


## 设置滚动文本并自动重算（外部必须用此函数，勿直接赋 label.text）
func set_scroll_text(v: String) -> void:
	super.set_text(v)
	_measure_and_scroll()


## 重算滚动（字号/尺寸变化后调用，重新测宽并启停滚动）
func refresh() -> void:
	_measure_and_scroll()


func _ready() -> void:
	# 让引擎 get_minimum_size 返回宽度 1（不因文本撑大节点），高度取字体高度
	clip_text = true
	# 场景若显式指定 font_color（如压在封面/图片上的固定色文字），锁定该色，主题切换时保持不变；
	# 否则跟随主题，外观/主题色切换时重新解析。
	_locked_color = has_theme_color_override("font_color")
	# 锁定时缓存一次显式色：后续透明 override 会覆盖原 override，若每次都读会读到透明
	if _locked_color:
		_locked_text_color = get_theme_color("font_color")
	# 记录文字颜色，再让引擎文字透明（引擎绘制无法拦截，靠透明隐藏）
	_refresh_text_color()
	if not _resized_callable.is_valid():
		_resized_callable = _on_resized
		resized.connect(_resized_callable)
	# 注册为主题应用者：外观/主题色切换时重新解析文字色（否则自绘文字会停留在旧颜色）
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
	call_deferred("_measure_and_scroll")


## 主题刷新回调：重新解析文字颜色并重绘
func apply_theme() -> void:
	_refresh_text_color()


## 解析当前文字色并让引擎文本透明隐藏。
## 引擎文本靠 font_color 透明 override 隐藏：未锁定时先移除 override 读取真实主题色、
## 再写回透明 override；锁定色（场景显式 font_color，压在图片上）则用缓存的显式色自绘，
## 同样写透明 override 把引擎文字藏起来，避免「原始白字」残留。
func _refresh_text_color() -> void:
	begin_bulk_theme_override()
	if _locked_color:
		text_color = _locked_text_color
	else:
		remove_theme_color_override("font_color")
		text_color = get_theme_color("font_color")
	add_theme_color_override("font_color", Color(0, 0, 0, 0))
	end_bulk_theme_override()
	queue_redraw()


func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)
	if _resized_callable.is_valid() and resized.is_connected(_resized_callable):
		resized.disconnect(_resized_callable)
	_kill_tween()


## 尺寸变化时重算滚动
func _on_resized() -> void:
	_measure_and_scroll()


## 引擎绘制通知：追加自绘文本（引擎文字已透明，不会叠加显示）
func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAW:
		# 静止裁剪窗口 = 节点自身矩形
		RenderingServer.canvas_item_set_clip(get_canvas_item(), true)
		_draw_scroll_text()


## 测量文本宽度并启动/停止滚动
func _measure_and_scroll() -> void:
	_kill_tween()
	_scroll_offset = 0.0

	var font := get_theme_font("font")
	var font_size := get_theme_font_size("font_size")
	_text_width = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x

	# 文字未溢出（含两端填充）：不滚动，避免刚好能塞下却顶着左边
	if _text_width + 2 * end_padding <= size.x:
		queue_redraw()
		return

	# 文字溢出：来回滚动
	# 滚动范围含 2*end_padding：起始文本左边留 end_padding，终点文本右边留 end_padding，两端对称
	var max_offset := _text_width - size.x + 2 * end_padding
	# 单程时长按滚动距离换算，保证不同长度文本像素速度一致
	var duration := max_offset / scroll_speed
	var tween := AniMGR.create_managed_tween(self).set_loops()
	tween.set_ease(Tween.EASE_IN_OUT).set_trans(transition)
	tween.tween_method(_set_scroll_offset, 0.0, -max_offset, duration)
	tween.tween_interval(PAUSE_DURATION)
	tween.tween_method(_set_scroll_offset, -max_offset, 0.0, duration)
	tween.tween_interval(PAUSE_DURATION)
	_tween = tween


## tween 回调：更新滚动偏移并重绘（仅当本节点位于视口内才重绘，视口外节点省去绘制开销）
func _set_scroll_offset(offset: float) -> void:
	_scroll_offset = offset
	if _is_in_viewport():
		queue_redraw()


## 自身矩形是否与视口可见区域相交（视口外不可见，跳过绘制）
func _is_in_viewport() -> bool:
	if not is_visible_in_tree():
		return false
	return get_global_rect().intersects(Rect2(Vector2.ZERO, get_viewport_rect().size))


## 自绘单行文本（含滚动偏移、阴影、描边）
func _draw_scroll_text() -> void:
	var font := get_theme_font("font")
	var font_size := get_theme_font_size("font_size")

	# 垂直对齐：按 vertical_alignment 计算基线 y
	var font_h := font.get_height(font_size)
	var ascent := font.get_ascent(font_size)
	var top := (size.y - font_h) * 0.5
	match vertical_alignment:
		VERTICAL_ALIGNMENT_TOP:
			top = 0.0
		VERTICAL_ALIGNMENT_BOTTOM:
			top = size.y - font_h
	var base_y := top + ascent

	# 水平起点：滚动时左对齐 + 起始留空隙（默认左对齐会贴左边，这里空出左侧）；
	# 非滚动时按 horizontal_alignment 对齐
	var x := 0.0
	if _tween != null and _tween.is_valid():
		x = end_padding
	else:
		match horizontal_alignment:
			HORIZONTAL_ALIGNMENT_CENTER:
				x = (size.x - _text_width) * 0.5
			HORIZONTAL_ALIGNMENT_RIGHT:
				x = size.x - _text_width
			_:
				x = end_padding
	x += _scroll_offset
	var pos := Vector2(x, base_y)

	# 先画阴影（偏移重绘一层）
	if shadow_color.a > 0.0:
		draw_string(font, pos + shadow_offset, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, shadow_color)

	# 再画描边
	if outline_size > 0:
		draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, outline_size, outline_color)

	# 最后画主文本
	draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, text_color)


## 清理当前滚动 tween 并复位
func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null

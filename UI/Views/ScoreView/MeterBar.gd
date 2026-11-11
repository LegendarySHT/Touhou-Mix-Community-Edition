extends Control

## 横向计量条：单色填充（连击保持率）与居中发散（Early / Late 偏移分布）两种模式。
## 自绘而不复用 ProgressBar，避免改动全局 Theme 里的进度条样式。

## Early / Late 配色（与 PlayView 的偏移指示保持一致）
const EARLY_COLOR := Color("#6FC3FF")
const LATE_COLOR := Color("#FF7B7B")

## 填充色取用的主题令牌（primary / warning / success 等），随主题刷新
@export var fill_role: String = "primary"
## 单色模式填充比例 0..1
var _ratio: float = 0.0
## 发散模式两侧数值
var _early: int = 0
var _late: int = 0
## 是否发散模式
var _diverging: bool = false
## 入场生长进度 0..1
var _reveal: float = 1.0

var _track_color: Color = Color(0, 0, 0, 0.4)
## 零点刻度色
var _center_color: Color = Color(1, 1, 1, 0.5)
var _fill_color: Color = Color.WHITE
var _early_color: Color = EARLY_COLOR
var _late_color: Color = LATE_COLOR
var _sb := StyleBoxFlat.new()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
	apply_theme()


func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)


func apply_theme() -> void:
	if ThemeMGR == null:
		return
	var is_light := ThemeMGR.get_appearance() == "light"
	# 槽底：深色下用凹陷板面，浅色下用半透明黑，保证在浅色板面上仍有层次
	_track_color = Color(0, 0, 0, 0.12) if is_light else ThemeMGR.get_color("surface_low")
	_center_color = ThemeMGR.get_color("border")
	var role: Color = ThemeMGR.get_color(fill_role)
	# 浅色板面上提亮填充、压暗偏移色，避免饱和色在浅底上刺眼
	_fill_color = role.lightened(0.12) if is_light else role
	_early_color = EARLY_COLOR.darkened(0.35) if is_light else EARLY_COLOR
	_late_color = LATE_COLOR.darkened(0.3) if is_light else LATE_COLOR
	queue_redraw()


## 设置单色填充比例（0..1）
func set_ratio(v: float) -> void:
	_ratio = clampf(v, 0.0, 1.0)
	_diverging = false
	queue_redraw()


## 设置发散模式：以条中点为零，Early 向左、Late 向右按各自占比铺开
func set_diverging(early: int, late: int) -> void:
	_diverging = true
	_early = maxi(early, 0)
	_late = maxi(late, 0)
	queue_redraw()


## 入场生长进度（0 时只显示槽底）
func set_reveal(v: float) -> void:
	_reveal = clampf(v, 0.0, 1.0)
	queue_redraw()


func _draw() -> void:
	var h := size.y
	if h <= 0.0 or size.x <= 0.0:
		return
	var radius := int(h * 0.5)
	_sb.set_corner_radius_all(radius)
	_sb.bg_color = _track_color
	draw_style_box(_sb, Rect2(Vector2.ZERO, size))
	if _reveal <= 0.0:
		return
	if _diverging:
		_draw_diverging(h, radius)
	else:
		_draw_single(h, radius)


func _draw_single(h: float, radius: int) -> void:
	if _ratio <= 0.0:
		return
	var w := size.x * _ratio * _reveal
	# 圆角半径不能超过半宽，否则极小的填充会画不出来
	_sb.set_corner_radius_all(mini(radius, int(w * 0.5)))
	_sb.bg_color = _fill_color
	draw_style_box(_sb, Rect2(0.0, 0.0, maxf(w, float(radius)), h))


func _draw_diverging(h: float, radius: int) -> void:
	var total := _early + _late
	# 中线刻度：无偏移时的零点位置，两侧都没有偏移时它就是唯一的视觉元素
	var center := size.x * 0.5
	_sb.set_corner_radius_all(mini(radius, 2))
	_sb.bg_color = _center_color
	draw_style_box(_sb, Rect2(center - 1.0, 0.0, 2.0, h))
	if total <= 0:
		return
	var early_w := center * float(_early) / float(total) * _reveal
	var late_w := center * float(_late) / float(total) * _reveal
	_sb.set_corner_radius_all(radius)
	if early_w > 0.0:
		_sb.bg_color = _early_color
		draw_style_box(_sb, Rect2(center - early_w, 0.0, early_w, h))
	if late_w > 0.0:
		_sb.bg_color = _late_color
		draw_style_box(_sb, Rect2(center, 0.0, late_w, h))

extends Node
## VirtualKeyboardGuard — Android 软键盘遮挡输入框的通用修复
##
## 背景：导出预设启用了 screen/immersive_mode=true（edge-to-edge），
## 弹出软键盘时 Android 不再压缩窗口（adjustResize 失效），键盘直接盖在画面上层，
## 视口不缩小 => ScrollContainer.follow_focus 无法把输入框抬到键盘之上
## （引擎只暴露 DisplayServer.virtual_keyboard_get_height()，不会自动上移内容）。
##
## 做法：任意 text 控件（LineEdit / TextEdit，含 PopupWindow 内输入框）获焦时，
## 只把“当前输入框底边”抬到虚拟键盘顶边之上所需的最小量（pan-to-reveal），
## 输入框本就位于键盘可视区内时上移量为 0（上部内容不会因此被顶出屏幕）；
## 失焦或键盘收起后平滑还原。仅 Android 生效，不影响桌面/其它平台。

## 键盘上方保留的额外安全间距（设计像素），避免输入框贴边
const SAFE_MARGIN := 24.0

## 当前是否聚焦在 text 输入控件上
var _text_focused := false
## 当前持有焦点的 text 控件（用于计算其几何位置）
var _focused_ctl: Control = null
## 目前已施加的（向上的）偏移量（设计像素，>=0）
var _offset := 0.0

## 被上移的宿主控件（根 UI = Main）
var _host: Control = null

func _ready() -> void:
	var root := get_tree().get_root()
	root.gui_focus_changed.connect(_on_focus_changed)

func _is_android() -> bool:
	return OS.get_name() == "Android"

func _on_focus_changed(focus: Control) -> void:
	if not _is_android():
		return
	_text_focused = focus != null and _is_text_control(focus)
	_focused_ctl = focus if _text_focused else null
	if _text_focused:
		# 记录宿主：从焦点控件向上回溯到最外层 Control（即 Main 根），使其整体上移
		_host = _find_ui_host(focus)

func _is_text_control(node: Object) -> bool:
	return node is LineEdit or node is TextEdit or node is CodeEdit

## 向上回溯最外层 Control 作为整体移动的宿主（Main 根控件）
func _find_ui_host(focus: Control) -> Control:
	var host: Control = focus
	var n: Node = focus
	while n != null and not (n is Window):
		if n is Control:
			host = n
		n = n.get_parent()
	return host

func _process(_delta: float) -> void:
	if not _is_android():
		return

	# 未聚焦 text / 未记录宿主：回归原位（宿主为空时仅复位变量，避免空调用）
	if _host == null:
		_offset = 0.0
		return
	if not _text_focused:
		_apply_offset(0.0, 60.0)
		return

	var vk := DisplayServer.virtual_keyboard_get_height()
	if vk <= 0:
		_apply_offset(0.0, 80.0)
		return

	var window_h := DisplayServer.window_get_size().y
	if window_h <= 0:
		return
	# 键盘占用物理高度的比例 → 对应的设计像素覆盖高度（换算基准）
	var visible_h := _host.get_viewport().get_visible_rect().size.y
	var keyboard_overlap := visible_h * (vk / float(window_h))
	var keyboard_top := visible_h - keyboard_overlap  # 键盘顶边（设计坐标，0 在顶部）

	# 输入框“未上移时”的底边（设计坐标）：当前 global_rect 已含 -_offset，补回即还原
	var b0 := _focused_ctl.get_global_rect().end.y + _offset

	# 只需把输入框底边抬到键盘顶边之上：上部内容本就在可视区时 target 为 0，不会顶出屏幕
	var target := maxf(b0 + SAFE_MARGIN - keyboard_top, 0.0)
	_apply_offset(target, 0.35)

## 平滑逼近目标偏移量（设计像素），并对宿主整体生效
func _apply_offset(target: float, speed: float) -> void:
	if absf(_offset - target) < 0.5 and absf(target - 0.0) > 0.01:
		_offset = target
	elif speed > 0.0 and speed < 1.0:
		_offset = lerpf(_offset, target, speed)
	else:
		_offset = move_toward(_offset, target, speed)
	_host.position = Vector2(_host.position.x, -_offset)
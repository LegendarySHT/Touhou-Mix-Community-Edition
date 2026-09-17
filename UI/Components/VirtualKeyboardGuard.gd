extends Node
## VirtualKeyboardGuard — Android 软键盘遮挡输入框的通用修复
##
## 背景：导出预设启用了 screen/immersive_mode=true（edge-to-edge），
## 弹出软键盘时 Android 不再压缩窗口（adjustResize 失效），键盘直接盖在画面上层，
## 视口不缩小 => ScrollContainer.follow_focus 无法把输入框抬到键盘之上
## （引擎只暴露 DisplayServer.virtual_keyboard_get_height()，不会自动上移内容）。
##
## 做法：任意 text 控件（LineEdit / TextEdit / CodeEdit，含 PopupWindow 弹窗内输入框）获焦时，
## 只把“当前输入框底边”抬到虚拟键盘顶边之上所需的最小量（pan-to-reveal）：
## - 主窗口内的输入框 → 整体上移根 UI（Main），上移量为 0 时不动（上部内容不被顶出屏幕）；
## - PopupWindow（PopupPanel 子窗口）内的输入框 → 整体上移弹窗窗口本身（含背景边框）。
## 失焦或键盘收起后平滑还原。仅 Android 生效，不影响桌面/其它平台。

## 键盘上方保留的额外安全间距（设计像素），避免输入框贴边
const SAFE_MARGIN := 24.0

## 当前是否聚焦在 text 输入控件上
var _text_focused := false
## 当前持有焦点的 text 控件（用于计算其几何位置）
var _focused_ctl: Control = null
## 目前已施加的（向上的）偏移量（设计像素，>=0）
var _offset := 0.0

## 主窗口内被上移的宿主控件（根 UI = Main）；与 _popup_target 二选一
var _host: Control = null
## 弹窗场景被上移的目标窗口（PopupPanel）及其初始 Y（归位基准）
var _popup_target: Window = null
var _popup_base_y := 0.0

func _ready() -> void:
	var root := get_tree().get_root()
	root.gui_focus_changed.connect(_on_focus_changed)
	# PopupWindow 是 Main 下子节点，_ready 时序晚于本节点，延迟连接
	call_deferred("_connect_popup_window")

func _connect_popup_window() -> void:
	var popup := PopupWindow.instance
	if popup == null:
		return
	# 弹窗是独立 Window（Viewport），内部焦点变化只发在弹窗自己的 gui_focus_changed 上，
	# 根视口的信号不会触发 —— 必须单独连接，否则弹窗内输入框不会触发防挡
	if not popup.gui_focus_changed.is_connected(_on_focus_changed):
		popup.gui_focus_changed.connect(_on_focus_changed)
	if not popup.about_to_popup.is_connected(_on_popup_about_to_show):
		popup.about_to_popup.connect(_on_popup_about_to_show)
	if not popup.popup_hide.is_connected(_on_popup_hidden):
		popup.popup_hide.connect(_on_popup_hidden)

func _is_android() -> bool:
	return OS.get_name() == "Android"

func _on_popup_about_to_show() -> void:
	# 弹窗即将重新定位/弹出，先归位（此前若有自动 grab_focus，已在旧位置武装，作废）
	_reset_pan()
	# popup() 弹出后会以最终位置重新定位；若焦点已自动落在弹窗内输入框（如存储位置弹窗
	# init_adjust 在 popup() 前就 grab_focus），弹出期间不会再有新的 gui_focus_changed，
	# 需在下帧按弹窗当前实际位置重新武装，否则该输入框不触发防挡
	call_deferred("_rearm_focus_after_popup")

## 弹窗弹出后重查其视口焦点：仍是 text 控件则重新武装（此时弹窗位置已定，基准正确）
func _rearm_focus_after_popup() -> void:
	var popup := PopupWindow.instance
	if popup == null or not popup.visible:
		return
	var owner := popup.gui_get_focus_owner()
	if owner != null:
		_on_focus_changed(owner)

func _on_popup_hidden() -> void:
	_reset_pan()

func _on_focus_changed(focus: Control) -> void:
	if not _is_android():
		return
	_text_focused = focus != null and _is_text_control(focus)
	_focused_ctl = focus if _text_focused else null
	if not _text_focused:
		return
	var win := _find_window_of(focus)
	if win != null and win != get_tree().get_root():
		# 焦点在弹窗内：整体移动弹窗窗口（含背景）
		# 基准只在目标窗口变化时捕获一次（弹窗每次打开重新定位前由 about_to_popup 清空），
		# 避免同一次弹窗内连续聚焦不同输入框时把“已上移位置”误当基准
		if _popup_target != win:
			_popup_target = win
			_popup_base_y = win.position.y
		_host = null
	else:
		# 焦点在主窗口内：整体移动根 UI（Main）
		_popup_target = null
		_host = _find_ui_host(focus)

func _find_window_of(node: Node) -> Window:
	var n: Node = node
	while n != null:
		if n is Window:
			return n
		n = n.get_parent()
	return null

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

func _reset_pan() -> void:
	_offset = 0.0
	_text_focused = false
	_focused_ctl = null
	if _host:
		_host.position.y = 0.0
		_host = null
	if _popup_target:
		_popup_target.position.y = _popup_base_y
		_popup_target = null

func _process(_delta: float) -> void:
	if not _is_android():
		return

	if _host == null and _popup_target == null:
		_offset = 0.0
		return
	if not _text_focused or _focused_ctl == null:
		_apply_offset(0.0, 60.0)
		return

	var vk := DisplayServer.virtual_keyboard_get_height()
	if vk <= 0:
		_apply_offset(0.0, 80.0)
		return

	var window_h := DisplayServer.window_get_size().y
	if window_h <= 0:
		return
	# 键盘覆盖的根视口设计高度（弹窗也绘制在根窗口画布内，统一用根视口换算）
	var visible_h := get_tree().get_root().get_visible_rect().size.y
	var keyboard_overlap := visible_h * (vk / float(window_h))
	var keyboard_top := visible_h - keyboard_overlap  # 键盘顶边（设计坐标，0 在顶部）

	# 输入框“未上移时”在根画布坐标系的底边：
	# - 主窗口内：get_global_rect() 是根画布坐标且已含 -_offset，补回 _offset 即还原；
	# - 弹窗内：get_global_rect() 是弹窗局部坐标（引擎只在绘制时叠加窗口位置），
	#   需加 _popup_base_y（未上移的窗口 Y）换算到根画布
	var b0 := _focused_ctl.get_global_rect().end.y
	if _popup_target:
		b0 += _popup_base_y
	else:
		b0 += _offset

	# 只需把输入框底边抬到键盘顶边之上：输入框本就在可视区时 target 为 0，不移动
	var target := maxf(b0 + SAFE_MARGIN - keyboard_top, 0.0)
	_apply_offset(target, 0.35)

## 平滑逼近目标偏移量（设计像素），并对目标（根 UI 或弹窗窗口）整体生效
func _apply_offset(target: float, speed: float) -> void:
	if absf(_offset - target) < 0.5 and absf(target - 0.0) > 0.01:
		_offset = target
	elif speed > 0.0 and speed < 1.0:
		_offset = lerpf(_offset, target, speed)
	else:
		_offset = move_toward(_offset, target, speed)
	if _host:
		_host.position = Vector2(_host.position.x, -_offset)
	elif _popup_target:
		_popup_target.position.y = _popup_base_y - _offset

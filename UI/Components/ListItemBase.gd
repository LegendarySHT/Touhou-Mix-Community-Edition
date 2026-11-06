## UI列表项的基类
## 所有列表项（专辑、歌曲、MIDI）都应继承此类
extends Control

class_name ListItemBase

## 列表项所代表的数据ID
var item_id: String = ""

## 列表项的索引
var item_index: int = -1

## 列表项类型（"album"、"song"、"midi"等）
var item_type: String = ""

## 是否被选中
var is_selected: bool = false

## 列表项的按钮
var button

## 选中动画相关
var _enable_ani: bool = false
var _item_btn: Button
var pulse_tween: Tween
var press_tween: Tween

var _mouse_press: bool = false
var _mouse_press_pos:Vector2 = Vector2.ZERO

var _pass_focus: bool = false

var parent_node: Node = null

signal btn_toggled(toggled_on: bool)
signal btn_confirmed(index: int)

## 初始化函数
func enable_selected_animation(btn: Button, parent) -> void:
	init_btn(btn, parent)
	_enable_ani = true
	offset_transform_enabled = true

func init_btn(btn: Button, parent) -> void:
	if _item_btn:
		return

	_item_btn = btn
	parent_node = parent
	
	# 连接按钮信号
	_item_btn.button_down.connect(_on_button_down)
	_item_btn.button_up.connect(_on_button_up)
	_item_btn.toggled.connect(_on_toggled)

	if parent.has_method("on_item_button_confirmed"):
		btn_confirmed.connect(parent.on_item_button_confirmed)
	if has_method("on_item_button_toggled"):
		btn_toggled.connect(self.on_item_button_toggled)

	# 自动选择聚焦的项
	button.focus_entered.connect(_on_focus_entered)

func _on_focus_entered():
	if _pass_focus:
		_pass_focus = false
		return

	# 焦点落到未选中的项上时把它选中（列表整体由焦点路由接管时走 select，
	# 这里是鼠标点击、以及焦点被引擎自带导航移动时的兜底）。
	var list = parent_node
	var snapped_off_target := false
	if list is BaseScrollList and list.is_snapping() \
			and list.selected_item >= 0 \
			and not list.is_item_visible(list.selected_item):
		snapped_off_target = true

	await get_tree().process_frame
	if not button.button_pressed and _mouse_press_pos == Vector2.ZERO:
		if snapped_off_target:
			return  # 进入焦点时吸附目标未进视口，忽略本次按键选择
		if is_instance_valid(parent_node):
			parent_node.select_item(item_index)

func _on_button_down():
	_mouse_press_pos = get_global_mouse_position()
	_mouse_press = true
	if not _enable_ani:
		return

	# 按下效果
	if press_tween:
		press_tween.kill()
	if pulse_tween:
		pulse_tween.kill()

	press_tween = AniMGR.create_managed_tween(self)
	press_tween.tween_property(self, "offset_transform_scale", Vector2(0.96, 0.96), 0.07).set_ease(Tween.EASE_OUT)

func _on_button_up():
	if not _enable_ani:
		return

	# 松开弹起效果
	if press_tween:
		press_tween.kill()
	
	press_tween = AniMGR.create_managed_tween(self)
	press_tween.tween_property(self, "offset_transform_scale", Vector2(1.03, 1.03), 0.06).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BOUNCE)
	
	press_tween.tween_property(self, "offset_transform_scale", Vector2(0.98, 0.98), 0.34).set_ease(Tween.EASE_IN_OUT)

	press_tween.finished.connect(func ():
		_pulse_animation(is_selected)
	)

func _on_toggled(toggled_on: bool):
	# 切换选中状态
	var dis = get_global_mouse_position().distance_to(_mouse_press_pos)
	var final: bool = false
	if dis < 30 or not _mouse_press:
		final = toggled_on

	var temp = is_selected
	is_selected = final
	_pass_focus = final
	# 仅鼠标驱动的选中才抢焦点回选中项：键盘导航时焦点已经在该项上（_on_focus_entered 触发的选中），
	# 抢焦点会把焦点从新聚焦的项拉回选中项，导致按键选择回退/来回跳（吸附动画中尤其明显）
	var was_mouse_press := _mouse_press
	await get_tree().process_frame
	if is_selected and was_mouse_press and self != get_viewport().gui_get_focus_owner():
		button.grab_focus()
	_mouse_press_pos = Vector2.ZERO
	_mouse_press = false

	if final and temp:
		btn_confirmed.emit(item_index)
	else:
		btn_toggled.emit(final)

	if _enable_ani:
		await get_tree().create_timer(0.4).timeout
		_pulse_animation(final)
	

	
func _pulse_animation(enable: bool):
	if pulse_tween:
		pulse_tween.kill()
		pulse_tween = null
	
	if enable:
		pulse_tween = AniMGR.create_managed_tween(self)
		pulse_tween.set_loops()
		
		# 柔和的脉冲
		pulse_tween.tween_property(self, "offset_transform_scale", Vector2(1.01, 1.01), 0.8).set_ease(Tween.EASE_IN_OUT)
		
		pulse_tween.tween_property(self, "offset_transform_scale", Vector2(0.99, 0.99), 0.8).set_ease(Tween.EASE_IN_OUT)
	else:
		AniMGR.create_managed_tween(self).tween_property(self, "offset_transform_scale", Vector2.ONE, 0.2).set_ease(Tween.EASE_IN_OUT)

## 程序化选中前清理残留的鼠标按压标记
## 拖拽滚动时 Godot 经 SCROLL_BEGIN 清掉按钮内部 press 状态却不会发 button_up，
## 该列表项的 _mouse_press/_mouse_press_pos 会残留旧按位置，导致随后的吸附选中触发
## _on_toggled 时把 final 判成 false 而不展开。程序化选中前主动复位，保证展开判定正确。
func clear_mouse_press_state() -> void:
	_mouse_press = false
	_mouse_press_pos = Vector2.ZERO

## 虚函数：初始化列表项
func initialize(id: String, type: String) -> void:
	item_id = id
	item_type = type

## DelView 统一列表行（组行 / 子行 / 扁平行共用同一场景）
##
## 原来是 TreeRoot(80px) 与 TreeItem(60px) 两个场景，行高不一致导致列表无法用单一行高
## 做虚拟化（算不出"滚到第几行"）。合并后统一 72px，层级靠**缩进 + 字号**区分：
##   - 组行 / 扁平行：无缩进，字号 40 / 38
##   - 子行：缩进 80px，字号 34 / 30
##
## 本脚本只管"长什么样"，数据填充由 DelView 在换绑时通过 set_content() 完成。
## 行是池化复用的，任何"属于某条数据"的状态都不能存在节点里 —— 一律走
## node.get_meta(&"row_index") 反查（见 VirtualList 的说明）。
extends HBoxContainer
class_name TreeRow

const CHILD_INDENT := 80.0
const GROUP_FONT_SIZE := 40
const CHILD_FONT_SIZE := 34
const GROUP_SUB_SIZE := 38
const CHILD_SUB_SIZE := 30

@onready var _indent := $Indent as Control
@onready var _checkbox := $CheckBox as CheckBox
@onready var _left_label := $LeftLabel as Label
@onready var _right_label := $RightLabel as Label

## 当前是否为子行样式（影响缩进与字号）
var is_child_row: bool = false


func _ready() -> void:
	apply_style(false)


## 切换组行 / 子行样式。样式相同的重绑不重复改字号（换字号会触发字形重排）
func apply_style(child: bool) -> void:
	if is_child_row == child and _indent != null and _indent.visible == child:
		return
	is_child_row = child
	if _indent:
		_indent.visible = child
		_indent.custom_minimum_size.x = CHILD_INDENT if child else 0.0
	if _left_label:
		_left_label.add_theme_font_size_override("font_size",
			CHILD_FONT_SIZE if child else GROUP_FONT_SIZE)
	if _right_label:
		_right_label.add_theme_font_size_override("font_size",
			CHILD_SUB_SIZE if child else GROUP_SUB_SIZE)


## 填文本（走 TextScrollHelper 的滚动文本，超长自动滚）
func set_content(left_text: String, right_text: String) -> void:
	if _left_label:
		_left_label.set_scroll_text(left_text)
	if _right_label:
		_right_label.set_scroll_text(right_text)


## 设置勾选态（不触发 toggled 信号）
func set_checked(on: bool) -> void:
	if _checkbox:
		_checkbox.set_pressed_no_signal(on)


## 设置半选态（组内部分选中）
func set_indeterminate(on: bool) -> void:
	if _checkbox == null:
		return
	if on:
		_checkbox.self_modulate = Color(0.5, 0.5, 0.5, 1.0)
		_checkbox.tooltip_text = "部分选中"
	else:
		_checkbox.self_modulate = Color.WHITE
		_checkbox.tooltip_text = ""


## 复选框是否禁用（内置资源不可删）
func set_check_disabled(on: bool) -> void:
	if _checkbox:
		_checkbox.disabled = on


var checkbox: CheckBox:
	get:
		return _checkbox

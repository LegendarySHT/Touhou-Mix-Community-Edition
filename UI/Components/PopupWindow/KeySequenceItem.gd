extends Button

class_name KeySequenceItem

## 单个键位项的数据
## 注意：属性名用 binding_token 而非 token，避免与内置概念混淆
## 绑定 token 的编码见 ConfigParser（键盘键 / MIDI 音符 / 鼠标键 / 手柄按钮与轴共用）
var binding_token: int = ConfigParser.BINDING_NONE
var display_name: String = ""
var item_index: int = -1

## 选中信号（被点击时触发，由父容器监听并切换右侧详情面板）
signal item_selected(item: KeySequenceItem)
## 拖拽开始信号
signal drag_started(item: KeySequenceItem)
## 拖拽过程中悬停在某个 item 上时触发（用于刷新 InsertPlace 位置）
signal drag_over(target: KeySequenceItem, at_pos: Vector2)
## 拖拽释放到目标 item 上时触发
signal drop_received(target: KeySequenceItem, dragged: KeySequenceItem)
## 拖拽结束（无论是否成功 drop）— 用于兜底隐藏 InsertPlace
signal drag_ended(source: KeySequenceItem)

## 拖拽预览的常态不透明度（进入删除区时换成警示色，见 set_drag_delete_state）
const PREVIEW_ALPHA: float = 0.85

## 拖拽预览节点：引擎在拖拽结束后回收，引用只在这期间有效
var _drag_preview: Label = null

## 是否是本次拖拽的发起者：NOTIFICATION_DRAG_END 会广播给视口内所有控件，
## 只有发起者才该回传 drag_ended，否则每个键位都会被当成「刚被拖过」
var _as_drag_source: bool = false

func _ready() -> void:
	# button_group 已在 tscn 中设置（互斥单选）；pressed 仅在从未选中→选中时触发
	pressed.connect(_on_pressed)

## 写入数据并刷新文本
func set_data(token: int, _name: String, idx: int) -> void:
	binding_token = token
	display_name = _name
	item_index = idx
	refresh_text()

## 刷新按钮显示文本：自定义名称优先，否则用绑定的默认名（键名 / 音名 / 鼠标键 / 手柄键）；都未设置时显示"未设置"
func refresh_text() -> void:
	if binding_token == ConfigParser.BINDING_NONE:
		text = "未设置"
		return
	if not display_name.is_empty():
		text = display_name
	else:
		text = ConfigParser.binding_to_display_name(binding_token)

# ===== 拖拽 =====

func _get_drag_data(_at_pos: Vector2) -> Variant:
	# 创建预览 Label 跟随光标；描边保证在深浅两种底色上都读得清
	var preview := Label.new()
	preview.text = text
	preview.add_theme_font_size_override("font_size", 32)
	preview.add_theme_color_override("font_color", ThemeMGR.get_color("text_primary"))
	preview.add_theme_constant_override("outline_size", 6)
	preview.add_theme_color_override("font_outline_color", ThemeMGR.get_color("surface"))
	preview.modulate.a = PREVIEW_ALPHA
	_drag_preview = preview
	_as_drag_source = true
	set_drag_preview(preview)
	drag_started.emit(self)
	return self

## 拖拽进入「框外删除」区时把预览染成警示色：松手之前就能看出这一放是删除
func set_drag_delete_state(active: bool) -> void:
	if not is_instance_valid(_drag_preview):
		return
	if active:
		var danger := ThemeMGR.get_color("danger")
		_drag_preview.modulate = Color(danger.r, danger.g, danger.b, 1.0)
	else:
		_drag_preview.modulate = Color(1, 1, 1, PREVIEW_ALPHA)

func _can_drop_data(at_pos: Vector2, data: Variant) -> bool:
	var can = data is KeySequenceItem and data != self
	if can:
		drag_over.emit(self, at_pos)
	return can

func _drop_data(_at_pos: Vector2, data: Variant) -> void:
	if data is KeySequenceItem and data != self:
		drop_received.emit(self, data)

func _notification(what: int) -> void:
	# 拖拽结束（释放或取消）时引擎通知视口内的所有控件，只有发起者负责回传
	if what == NOTIFICATION_DRAG_END and _as_drag_source:
		_as_drag_source = false
		_drag_preview = null
		drag_ended.emit(self)

# ===== 内部 =====

func _on_pressed() -> void:
	item_selected.emit(self)

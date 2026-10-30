## MidiView 收藏夹面板
## 嵌入 RightArea 区域，显示所有收藏夹列表
## 点击收藏夹项切换当前 MIDI 的收藏状态
extends PanelContainer

class_name MidiFavorPanel

const FAVOR_ITEM_SCENE := preload("res://UI/Components/ShortCutMenu/favorListItem.tscn")

var current_midi: MidiData = null
var _is_creating: bool = false
var _create_edit: LineEdit = null

@onready var favor_list_container: VBoxContainer = $VBoxC/FavorList/VBoxC
@onready var favor_list: ScrollContainer = $VBoxC/FavorList
@onready var create_list: VBoxContainer = $VBoxC/CreateList
@onready var add_btn: Button = $VBoxC/CreateList/AddBtn

const FAVOR_LIST_DEFAULT_HEIGHT := 500
const FAVOR_LIST_CREATE_HEIGHT := 400


func _ready() -> void:
	add_btn.pressed.connect(_on_add_btn_pressed)
	# 连接收藏夹相关信号以实时刷新
	EvtBus.favorites_loaded.connect(_refresh)
	EvtBus.favorites_updated.connect(_refresh)
	EvtBus.favorite_list_created.connect(_refresh)
	EvtBus.favorite_list_deleted.connect(_refresh)
	EvtBus.favorite_list_renamed.connect(_refresh)
	EvtBus.favorite_midi_changed.connect(_refresh)


## 显示面板，传入当前选中的 MIDI
func show_with_midi(midi: MidiData) -> void:
	current_midi = midi
	_refresh()


## 刷新收藏夹列表
func _refresh(_arg1 = null, _arg2 = null, _arg3 = null) -> void:
	if not current_midi or not FavoriteManager.instance:
		return
	# 记录当前持有焦点的收藏夹项，重建后恢复焦点（避免点击切换后焦点丢失）
	var focused_fav_id := ""
	var focus_owner := get_viewport().gui_get_focus_owner()
	if focus_owner:
		var item := _find_favor_item(focus_owner)
		if item:
			focused_fav_id = item.favorite_id
	# 清空现有列表项
	for child in favor_list_container.get_children():
		child.queue_free()
	# 重新填充
	for fav in FavoriteManager.instance.favorites:
		var item = FAVOR_ITEM_SCENE.instantiate()
		favor_list_container.add_child(item)
		item.setup(fav, FavorListItem.Mode.MANAGE, current_midi)
		item.favor_midi_toggled.connect(_on_favor_midi_toggled)
		if fav.id == focused_fav_id:
			# 等旧节点释放、新节点就绪后再恢复焦点
			item.grab_focus.call_deferred()


## 从焦点控件向上查找其所属的收藏夹列表项
func _find_favor_item(node: Node) -> FavorListItem:
	var cur: Node = node
	while cur:
		if cur is FavorListItem:
			return cur
		cur = cur.get_parent()
	return null


## 切换当前 MIDI 在收藏夹中的状态
func _on_favor_midi_toggled(fav_id: String) -> void:
	if FavoriteManager.instance.is_midi_in_favorite(fav_id, current_midi):
		FavoriteManager.instance.remove_midi_from_favorite(fav_id, current_midi)
	else:
		FavoriteManager.instance.add_midi_to_favorite(fav_id, current_midi)
	# _refresh 会被 favorite_midi_changed 信号触发


## 重命名/删除由 FavorListItem 组件自行落盘，宿主不再转发（三个复用点抄同一段就会漏）


# ========== 新建收藏夹 ==========

func _on_add_btn_pressed() -> void:
	if _is_creating:
		_confirm_create()
	else:
		_enter_create_mode()


func _enter_create_mode() -> void:
	_is_creating = true
	# 缩小 FavorList 高度为 LineEdit 腾出空间
	favor_list.custom_minimum_size.y = FAVOR_LIST_CREATE_HEIGHT
	_create_edit = LineEdit.new()
	_create_edit.placeholder_text = "输入收藏夹名称"
	_create_edit.custom_minimum_size = Vector2(400, 60)
	_create_edit.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_create_edit.text_submitted.connect(func(_t): _confirm_create())
	# 插入到 CreateList 内部 AddBtn 上方
	create_list.add_child(_create_edit)
	create_list.move_child(_create_edit, 0)
	add_btn.icon.region = Rect2(0, 80, 80, 80)
	_create_edit.grab_focus()


func _confirm_create() -> void:
	if not _is_creating or not _create_edit:
		return
	var fav_name := _create_edit.text.strip_edges()
	_is_creating = false
	_create_edit.queue_free()
	_create_edit = null
	# 恢复 FavorList 高度
	favor_list.custom_minimum_size.y = FAVOR_LIST_DEFAULT_HEIGHT
	add_btn.icon.region = Rect2(160, 80, 80, 80)
	if not fav_name.is_empty():
		FavoriteManager.instance.create_favorite(fav_name)


func cancel_create() -> void:
	if not _is_creating:
		return
	_is_creating = false
	if _create_edit:
		_create_edit.queue_free()
		_create_edit = null
	# 恢复 FavorList 高度
	favor_list.custom_minimum_size.y = FAVOR_LIST_DEFAULT_HEIGHT
	add_btn.icon.region = Rect2(160, 80, 80, 80)

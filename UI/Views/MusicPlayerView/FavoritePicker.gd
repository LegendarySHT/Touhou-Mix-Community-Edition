extends Panel
## 收藏夹选择弹层
##
## 复用 ShortCutMenu 的 favorListItem 组件（视觉风格一致），以 BROWSE 模式实例化——
## 该模式下点击整项发 favor_item_clicked，不会误触发「切换收藏状态」。

const FAVOR_ITEM_SCENE := preload("res://UI/Components/ShortCutMenu/favorListItem.tscn")

## 选中收藏夹的 id；取消选择时为空串
signal picked(fav_id: String)

@onready var _list: VBoxContainer = $FpColumn/FpScroll/FpList
@onready var _empty: Label = $FpColumn/FpScroll/FpList/FpEmpty
@onready var _shader: ColorRect = $"../PopupWindowShader"

## 打开弹层。pending 为 true 时表示"待加入"，标题不同
func open(pending: bool) -> void:
	$FpColumn/FpTitle.text = "选择收藏夹" if pending else "选择歌单"
	visible = true
	_shader.visible = true
	_rebuild()

func close() -> void:
	visible = false
	_shader.visible = false

func _ready() -> void:
	EvtBus.favorites_loaded.connect(_rebuild)
	EvtBus.favorites_updated.connect(_rebuild)
	EvtBus.favorite_list_created.connect(_rebuild)
	EvtBus.favorite_list_deleted.connect(_rebuild)
	visible = false

func _rebuild() -> void:
	if not visible:
		return
	for c in _list.get_children():
		if c != _empty:
			c.queue_free()
	var fav_mgr := FavoriteManager.instance
	if fav_mgr == null or fav_mgr.favorites.is_empty():
		_empty.visible = true
		return
	_empty.visible = false
	for f in fav_mgr.favorites:
		var item := FAVOR_ITEM_SCENE.instantiate()
		_list.add_child(item)
		item.setup(f, item.Mode.BROWSE)
		item.favor_item_clicked.connect(_on_item_clicked)

func _on_item_clicked(fav_id: String) -> void:
	picked.emit(fav_id)
	close()


## 点遮罩 = 关闭弹窗。必须在【松开】时才关：按下瞬间把自己藏掉的话，
## mouse_focus 失效，这次点击的 release 会被引擎重新派发给当前位置的控件，
## 造成点击穿透（关掉弹窗的同时点到了底下的东西）
func _on_shader_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and not event.pressed:
		close()

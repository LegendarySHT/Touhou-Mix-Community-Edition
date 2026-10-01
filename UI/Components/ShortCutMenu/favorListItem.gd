## 收藏夹列表项
## 支持两种交互模式：
## - BROWSE: AlbumView 中点击列表项，跳转到 SortedMidiView 浏览收藏夹内容
## - MANAGE: MidiView 弹窗中点击列表项，切换当前 MIDI 的收藏状态
## 根节点为 Button：提供焦点效果 + 点击主操作（pressed 信号），替代旧 _gui_input 触摸点击判定
extends Button

class_name FavorListItem

enum Mode { BROWSE, MANAGE }

## 列表项点击（BROWSE 模式）
signal favor_item_clicked(fav_id: String)
## 当前 MIDI 收藏状态切换（MANAGE 模式）
signal favor_midi_toggled(fav_id: String)
## 请求重命名收藏夹
signal favor_item_renamed(fav_id: String, new_name: String)
## 请求删除收藏夹
signal favor_item_deleted(fav_id: String)

var mode: Mode = Mode.BROWSE
var favorite_id: String = ""
var current_midi: MidiData = null

@onready var cover: TextureRect = $HBox/Cover
@onready var name_label: Label = $HBox/Detail/name
@onready var midi_count_label: Label = $HBox/Detail/midiCount
@onready var name_edit: LineEdit = $HBox/Detail/nameEdit
@onready var action_icon_wrap: Control = $HBox/Cover/ActionIconWrap
@onready var action_icon: TextureRect = $HBox/Cover/ActionIconWrap/ActionIcon
@onready var delete_btn: Button = $HBox/DeleteBtn

# 点击 vs 滚动 判定阈值
# 移动距离超过此值视为滚动（非点击），用于避免滚动收藏夹时误触
const TAP_MOVE_THRESHOLD := 15.0

# 名称完整文本（用于重命名交互）
var _name_full_text: String = ""

# 名称触摸追踪状态：用于区分“点击重命名”与“滚动拖拽”
var _touch_start_pos: Vector2 = Vector2.ZERO
var _touch_pending: bool = false   # 是否有待释放的触摸

func _ready() -> void:
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()
	# 圆角遮罩：shader 拿不到 Control 尺寸，resize 时把尺寸传入
	cover.resized.connect(_update_cover_mask)
	_update_cover_mask()

## 应用主题色：根按钮四态随主题改色（原本写死的深色在浅色模式下会残留）
## normal 用 surface_low：ShortCutMenu 面板是 surface_high、MidiFavorPanel 面板是 surface，
## 只有 surface_low 能同时与其拉开层次；边框用 border 增强轮廓。
func apply_theme() -> void:
	if not ThemeMGR:
		return
	var sl := ThemeMGR.get_color("surface_low")
	var shv := ThemeMGR.get_color("surface_hover")
	var p := ThemeMGR.get_color("primary")
	var border := ThemeMGR.get_color("border")
	var bg_map := {"normal": sl, "hover": shv, "pressed": p, "focus": shv}
	var border_map := {"normal": border, "hover": border, "pressed": p, "focus": p}
	for state in bg_map:
		var sb := get_theme_stylebox(state)
		if sb is StyleBoxFlat:
			sb.bg_color = bg_map[state]
			sb.border_color = border_map[state]

func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)

## 点击名称区域：进入重命名模式
## 仅在"按下后未发生明显移动"时才判定为点击，避免滚动误触
## name Label 设为 MOUSE_FILTER_STOP，事件被其消费后不再冒泡到根 Button，
## 因此点击名称只会进入重命名，不会同时触发列表项主操作
func _on_name_label_gui_input(event: InputEvent) -> void:
	if not (event is InputEventScreenTouch):
		return
	if event.pressed:
		_touch_start_pos = event.position
		_touch_pending = true
	elif _touch_pending:
		_touch_pending = false
		if _is_tap(event.position):
			_enter_rename_mode()


## 判定触摸释放是否构成有效点击（移动距离小于阈值）
func _is_tap(release_pos: Vector2) -> bool:
	return release_pos.distance_to(_touch_start_pos) <= TAP_MOVE_THRESHOLD


# ========== 键盘快捷键（根节点聚焦时） ==========

## 聚焦到列表项时拦截按键：
## - Del / Backspace → 触发删除按钮（_on_delete_pressed）
## - F2 / R → 触发重命名（_enter_rename_mode）
## 说明：定义 _gui_input 不会覆盖 Button 原生处理（_call_gui_input 中 GDVIRTUAL 调用后
## 仍会调原生 gui_input），仅对拦截的按键 accept_event()，其余事件继续传给原生逻辑（点击照常触发 pressed）
func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	if not event.pressed or event.echo:
		return
	# 重命名编辑中不响应（name_edit 已 grab_focus，按键走 LineEdit；此守卫兜底）
	if name_edit.visible:
		return
	match event.keycode:
		KEY_DELETE, KEY_BACKSPACE:
			_on_delete_pressed()
			accept_event()
		KEY_F2, KEY_R:
			_enter_rename_mode()
			accept_event()


## 初始化列表项
func setup(fav: FavoriteListData, p_mode: Mode, p_midi: MidiData = null) -> void:
	favorite_id = fav.id
	mode = p_mode
	current_midi = p_midi
	# 需要等节点准备好
	if not is_node_ready():
		await ready
	_name_full_text = fav.name
	name_label.set_scroll_text(fav.name)
	midi_count_label.text = "%d midis" % fav.midi_ids.size()
	# 封面：最近添加的 midi（midi_ids 末尾）
	_load_cover(fav)
	# 模式切换
	_apply_mode()


## 把 Cover 尺寸写入圆角遮罩 shader（见 CoverRound.gdshader）
func _update_cover_mask() -> void:
	var mat := cover.material as ShaderMaterial
	if mat:
		mat.set_shader_parameter("rect_size", cover.size)


func _load_cover(fav: FavoriteListData) -> void:
	# 空收藏夹保留场景里的占位纹理
	if fav.midi_ids.is_empty():
		return
	# 封面路径走磁盘索引反查（与 FavoriteManager._validate_favorites 一致）：
	# 不依赖 DataMGR/ChartDB 水合出 MidiData，谱面未加载 / DB 不可用时仍能取到封面；
	# 未命中时 _cover_path_from_chart 内部已回退默认封面，避免直接置 null 导致空白。
	var fs := FileSystemManager.instance
	var key: String = fav.midi_ids.back()
	cover.texture = fs.load_cover_with_cache(fs.get_cover_path_by_ids(key, key))


func _apply_mode() -> void:
	var show_action := (mode == Mode.MANAGE) and current_midi != null
	# 切换 Wrap 可见性即可控制图标整体显隐（含黑色背景），ActionIcon 默认可见
	action_icon_wrap.visible = show_action
	if show_action:
		var in_fav := FavoriteManager.instance.is_midi_in_favorite(favorite_id, current_midi)
		action_icon.texture.region = (Rect2(240, 80, 80, 80) if in_fav else Rect2(160, 80, 80, 80))


# ========== 文字滚动动画 ==========

## 重命名时文本不滚动（由脚本自动滚动，此处仅保持左对齐约定）
## 视觉规范：名称始终左对齐（与协作者微调一致）


# ========== 重命名交互 ==========

func _enter_rename_mode() -> void:
	name_edit.text = _name_full_text
	name_label.visible = false
	name_edit.visible = true
	name_edit.grab_focus()
	name_edit.select_all()


func _on_rename_submitted(_new_name: String) -> void:
	_confirm_rename()


func _on_rename_focus_exited() -> void:
	_confirm_rename()


## 收尾重命名中标记：grab_focus 会触发 name_edit 的 focus_exited 重入 _confirm_rename，此守卫防止重复处理
var _finalizing_rename: bool = false

func _confirm_rename() -> void:
	if not name_edit.visible:
		return
	if _finalizing_rename:
		return
	_finalizing_rename = true
	var new_name := name_edit.text.strip_edges()
	# 先转移焦点回列表项根 Button 再隐藏 name_edit：
	# 隐藏持有焦点的控件会让引擎释放焦点（viewport 对不可见焦点项 release_focus）；
	# 且列表重建时 _refresh_favor_list 依赖该项的焦点状态来定位并恢复焦点
	grab_focus()
	# grab_focus 使 name_edit 同步触发 focus_exited → _on_rename_focus_exited → _confirm_rename，由上述守卫拦截
	name_edit.visible = false
	name_label.visible = true
	if not new_name.is_empty() and new_name != _name_full_text:
		favor_item_renamed.emit(favorite_id, new_name)
	else:
		# 恢复显示并重启滚动
		_name_full_text = name_label.text
		name_label.set_scroll_text(name_label.text)
	_finalizing_rename = false


# ========== 删除交互 ==========

func _on_delete_pressed() -> void:
	favor_item_deleted.emit(favorite_id)


# ========== 主操作（根 Button pressed） ==========

## 点击列表项主体触发主操作（替换旧 _gui_input 触摸点击判定）
## DeleteBtn 是独立 Button（MOUSE_FILTER_STOP），其自身 pressed 已连接 _on_delete_pressed，
## 触摸事件在 DeleteBtn 处被消费，不会冒泡到根 Button，故无需再拦截删除按钮触摸
func _on_favor_list_item_pressed() -> void:
	# 重命名编辑中不响应点击（name_edit 为 LineEdit 会消费事件，此守卫兜底）
	if name_edit.visible:
		return
	if mode == Mode.BROWSE:
		favor_item_clicked.emit(favorite_id)
	else:
		favor_midi_toggled.emit(favorite_id)

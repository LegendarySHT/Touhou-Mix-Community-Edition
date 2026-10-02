## 专辑列表项组件
## 继承自 CoverListItemBase，显示专辑信息
## 两阶段构建：bind_with_dict（Phase A 绑定身份，不查 ChartDB/不刷新显示）→ fill_display（Phase B 填内容）
class_name AlbumListItem
extends CoverListItemBase

## 引用节点路径
@onready var album_name_label: Label = $AlbumName
@onready var abbr_label: Label = $Abbr
@onready var line: Control = $Line
@onready var song_count_label: Label = $SongCount
# cover_texture 继承自 CoverListItemBase，在 _ready() 中赋值

## 专辑轻量投影数据（ChartDB.GetSortedAlbumItems 返回的字典）
var item_dict: Dictionary = {}

## 展开动画补间
var expand_tween: Tween

## 是否已 ready 且填充过显示（fill_display 后置 true；bind 阶段保持 false 等待 Phase B）
var _has_ready: bool = false

func _ready() -> void:
	cover_texture = $C/cover
	# 显示填充由 fill_display() 统一驱动（Phase B），_ready 不再阻塞等待信号
	if name == "SelectedAlbum" and self.button_pressed:
		on_item_button_toggled(true)

## 绑定专辑身份（两阶段构建 Phase A：仅设身份字段与按钮装配，不查 ChartDB、不刷新显示）
func bind_with_dict(parent: AlbumView, d: Dictionary, index: int, bg: ButtonGroup) -> void:
	item_dict = d
	item_id = String(d.get("id", ""))
	item_type = "album"
	item_index = index

	button = self
	button.button_group = bg

	enable_selected_animation(button, parent)

## 填充显示（两阶段构建 Phase B：标签/封面/名称滚动；复用项同时复位展开/选中动画态）
func fill_display() -> void:
	_refresh_display()
	_has_ready = true

## 兼容入口：bind + fill 一次完成（外部调用方仍可用；AlbumView 两阶段构建分开调用）
func setup_with_dict(parent: AlbumView, d: Dictionary, index: int, bg: ButtonGroup) -> void:
	bind_with_dict(parent, d, index, bg)
	fill_display()

## 设置显示的专辑内容（静态 SelectedAlbum 头部卡片用：不接按钮组、不绑定列表，仅填充显示）
## 头部卡片恒为展开态：若处于收起态（点击返回 AlbumView 后）先复位展开再刷内容
func set_display_album(d: Dictionary) -> void:
	item_dict = d
	item_id = String(d.get("id", ""))
	if not is_inside_tree() or album_name_label == null:
		return
	_refresh_labels()
	switch_cover_data()
	start_cover_load()

## 更新名称/计数标签（新建与复用共用）
func _refresh_labels() -> void:
	if item_dict.is_empty():
		push_error("AlbumListItem: Missing album data")
		return
	album_name_label.set_scroll_text(" %s" % String(item_dict.get("name", "")) if item_dict.get("name", "") else "Unknown")
	# Abbr：专辑有 abbr 字段则显示，否则隐藏
	var abbr := String(item_dict.get("abbr", ""))
	if abbr.is_empty():
		abbr_label.visible = false
	else:
		abbr_label.visible = true
		abbr_label.text = abbr
	song_count_label.text = "%d" % item_dict.get("song_count", 0)

## 复用刷新：重置展开/选中动画态 + 更新显示 + 重新加载封面
## 保留旧封面显示直到新封面加载完成（switch_cover_data 不清空 texture）
func _refresh_display() -> void:
	_refresh_labels()

	# 清理残留动画/选中态（展开动画改过尺寸/字号/NameBox 透明度，需复位到折叠默认）
	if expand_tween:
		expand_tween.kill()
		expand_tween = null
	if pulse_tween:
		pulse_tween.kill()
		pulse_tween = null
	if press_tween:
		press_tween.kill()
		press_tween = null
	offset_transform_scale = Vector2.ONE
	# 两阶段构建中，当前选中项可能已被 toggle 展开（select_item 置位 selected_item）。
	# Phase B 分批填充走到该项时需保留展开态，否则会被复位成折叠（表现为"展开后自动收起"）。
	var keep_expanded: bool = parent_node != null \
		and parent_node.selected_item == item_index \
		and button.button_pressed
	if keep_expanded:
		custom_minimum_size = Vector2(950, 400)
		album_name_label.add_theme_font_size_override("font_size", 45)
		line.self_modulate.a = 1.0
		abbr_label.offset_transform_scale = Vector2.ONE * 1.5
		button.set_pressed_no_signal(true)
		is_selected = true
	else:
		custom_minimum_size = Vector2(600, 150)
		album_name_label.add_theme_font_size_override("font_size", 25)
		line.self_modulate.a = 0.0
		abbr_label.offset_transform_scale = Vector2.ONE
		button.set_pressed_no_signal(false)
		is_selected = false

	switch_cover_data()

## 重写基类虚函数：返回专辑封面 Texture2D
## 选择专辑下首个歌曲的首个 MIDI 的封面，否则由 FileSystemManager 返回默认封面
func _get_cover_texture() -> Texture2D:
	if item_dict.is_empty():
		return null
	var fs_mgr := FileSystemManager.instance
	if not fs_mgr:
		return null
	return fs_mgr.load_cover_with_cache(fs_mgr.default_cover_if_missing(ChartDB.GetAlbumCoverPath(String(item_dict.get("id", "")))))

## 重写基类虚函数：返回封面文件路径（主线程调用，供异步加载器使用）
## 路径查询在主线程完成，后台线程只负责读盘
func _resolve_cover_path() -> String:
	if item_dict.is_empty():
		return ""
	var fs_mgr := FileSystemManager.instance
	if not fs_mgr:
		return ""
	return fs_mgr.default_cover_if_missing(ChartDB.GetAlbumCoverPath(String(item_dict.get("id", ""))))

## 专辑按钮切换回调
func on_item_button_toggled(toggled_on: bool) -> void:
	if expand_tween:
		expand_tween.kill()
	
	expand_tween = AniMGR.create_managed_tween(self)
	expand_tween.set_ease(Tween.EASE_OUT)
	expand_tween.set_trans(Tween.TRANS_SINE)
	expand_tween.set_parallel(true)
	
	var expa: int = 1 if toggled_on else 0
	expand_tween.tween_property(self,"custom_minimum_size",Vector2(600 + expa*350, 150 + 250*expa),0.15)
	expand_tween.tween_property(album_name_label,"theme_override_font_sizes/font_size",25 + 20*expa,0.15)
	expand_tween.tween_property(line, "self_modulate:a", float(expa), 0.15)
	# abbr 标签：展开放大到 1.5，收起还原 1
	expand_tween.tween_property(abbr_label, "offset_transform_scale", Vector2.ONE * (1.0 + 0.5 * expa), 0.15)

	if toggled_on and parent_node:
		parent_node.selected_item = item_index
	
	expand_tween.finished.connect(func ():
		expand_tween.kill()
		expand_tween = null
		# 字号变化后重算滚动布局
		album_name_label.refresh()
	)

	# 因为塞在tween里的话，节点在屏幕外似乎无法触发，所以就成下面这样了
	await get_tree().create_timer(0.15).timeout
	if toggled_on and parent_node and parent_node.selected_item == item_index:
		parent_node.need_snap = true


func _on_selected_album_pressed() -> void:
	UiStatMGR.change_state(UiStatMGR.UIState.ALBUM_VIEW)

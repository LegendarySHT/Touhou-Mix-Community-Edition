## 资源管理页的小卡片：左侧封面/预览，中间名称/副标题/元信息，右侧状态角标。
##
## 与商店卡片不同，这里不展开详情：歌曲页点击 = 加入/移出待操作列表；
## 资源页点击 = 交给 ResourceView 弹确认框删除。
extends Button

signal clicked(item: Dictionary)

const StoreIconsLib := preload("res://UI/Views/StoreView/StoreIcons.gd")

const CardVisualKind := {
	"song": "song",
	"skin": "skin",
	"effect": "effect",
	"soundfont": "soundfont",
	"background": "background",
}

var item: Dictionary = {}
var _selected := false
var _has_ready := false
var _cover_version := 0
var _press_pos := Vector2.INF


func _ready() -> void:
	_has_ready = true
	button_down.connect(func() -> void: _press_pos = get_global_mouse_position())
	pressed.connect(_on_pressed)
	%SelectedMark.texture = StoreIconsLib.check()
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()
	if not item.is_empty():
		_apply(false)


func setup(p_item: Dictionary, selected: bool = false, animate_in: bool = false) -> void:
	item = p_item
	_selected = selected
	if not _has_ready:
		return
	_apply(animate_in)


func set_selected(on: bool) -> void:
	_selected = on
	if _has_ready:
		_apply_selected()


func _apply(animate_in: bool) -> void:
	if item.is_empty():
		return
	%Title.set_scroll_text(str(item.get("title", "未命名")))
	%Sub.set_scroll_text(str(item.get("subtitle", "")))
	%Meta.set_scroll_text(str(item.get("meta", "")))
	%Badge.text = str(item.get("badge", ""))
	%Badge.visible = not %Badge.text.is_empty()
	_apply_selected()
	_load_cover()
	if animate_in:
		modulate.a = 0.0
		var tw := AniMGR.create_managed_tween(self, "resource_card_in_%d" % get_instance_id())
		if tw:
			tw.tween_property(self, "modulate:a", 1.0, 0.2) \
				.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	else:
		modulate.a = 1.0


func set_cover_path(path: String) -> void:
	if str(item.get("cover_path", "")) == path:
		return
	item["cover_path"] = path
	if _has_ready:
		_load_cover()


func _apply_selected() -> void:
	%SelectedBorder.visible = _selected
	%SelectedMark.visible = _selected
	if ThemeMGR:
		%SelectedMark.modulate = ThemeMGR.get_color("primary_dark") \
			if ThemeMGR.get_appearance() == "light" else ThemeMGR.get_color("primary_light")
	else:
		%SelectedMark.modulate = Color.WHITE


func _load_cover() -> void:
	_cover_version += 1
	var version := _cover_version
	var is_skin := str(item.get("kind", "")) == "skin"
	%NotePreview.visible = is_skin
	%Cover.visible = not is_skin
	if is_skin:
		%Cover.texture = null
		%Placeholder.visible = false
		%NotePreview.call("setup", item)
		return
	%NotePreview.call("clear")
	%Cover.texture = null
	%Placeholder.visible = true
	%Placeholder.texture = _placeholder_icon(str(item.get("kind", "")))

	var local_tex = item.get("cover_tex")
	if local_tex is Texture2D:
		%Cover.texture = local_tex
		%Placeholder.visible = false
		return

	var cover_path := str(item.get("cover_path", ""))
	if cover_path.is_empty():
		return
	if cover_path.begins_with("res://"):
		if ResourceLoader.exists(cover_path):
			var builtin_tex := load(cover_path) as Texture2D
			if builtin_tex and version == _cover_version:
				%Cover.texture = builtin_tex
				%Placeholder.visible = false
		return
	var item_id := "resource_card_%d" % get_instance_id()
	CoverLoader.request_load(item_id, cover_path, func(_path: String, tex: Texture2D, _v: int) -> void:
		if not is_instance_valid(self) or version != _cover_version:
			return
		if tex:
			%Cover.texture = tex
			%Placeholder.visible = false
	)


func _placeholder_icon(kind: String) -> Texture2D:
	match CardVisualKind.get(kind, ""):
		"skin": return StoreIconsLib.skin()
		"effect": return StoreIconsLib.effect()
		"soundfont": return StoreIconsLib.soundfont()
		"background": return StoreIconsLib.atlas(3, 240, 0)
		_: return StoreIconsLib.song()


func _on_pressed() -> void:
	var dragging := _press_pos != Vector2.INF \
		and get_global_mouse_position().distance_to(_press_pos) > 12.0
	_press_pos = Vector2.INF
	if dragging or item.is_empty():
		return
	clicked.emit(item)


func apply_theme() -> void:
	if not _has_ready or not ThemeMGR:
		return
	var is_light := ThemeMGR.get_appearance() == "light"
	%Placeholder.modulate = ThemeMGR.get_color("text_secondary") if is_light else ThemeMGR.get_color("text_dim")
	%Placeholder.modulate.a = 0.5
	_apply_selected()


func _exit_tree() -> void:
	CoverLoader.cancel("resource_card_%d" % get_instance_id())
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)

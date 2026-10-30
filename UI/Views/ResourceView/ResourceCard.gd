## 资源管理页的小卡片：左侧封面/预览，中间名称/副标题/元信息，右侧状态角标。
##
## 与商店卡片不同，这里不展开详情：歌曲页点击 = 加入/移出待操作列表；
## 资源页点击 = 交给 ResourceView 弹确认框删除。
extends Button

signal clicked(item: Dictionary)

const StoreIconsLib := preload("res://UI/Views/StoreView/StoreIcons.gd")

## 同场景实例共享 tscn 子资源，共享样式按主题版本只改一次
static var _shared_style_revision := -1
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

@onready var _cover: RoundedTextureRect = $Margin/HBox/CoverWrap/Cover
@onready var _cover_placeholder: TextureRect = $Margin/HBox/CoverWrap/Placeholder
@onready var _cover_wrap: Panel = $Margin/HBox/CoverWrap
@onready var _note_preview: Control = $Margin/HBox/CoverWrap/NotePreview
@onready var _title: Label = $Margin/HBox/Info/Title
@onready var _sub: Label = $Margin/HBox/Info/Sub
@onready var _meta: Label = $Margin/HBox/Info/Meta
@onready var _badge: Label = $Margin/HBox/Right/Badge
@onready var _selected_mark: TextureRect = $Margin/HBox/Right/SelectedMark
@onready var _selected_border: Panel = $SelectedBorder


func _ready() -> void:
	_has_ready = true
	button_down.connect(func() -> void: _press_pos = get_global_mouse_position())
	pressed.connect(_on_pressed)
	_selected_mark.texture = StoreIconsLib.check()
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
	_title.set_scroll_text(str(item.get("title", "未命名")))
	_sub.set_scroll_text(str(item.get("subtitle", "")))
	_meta.set_scroll_text(str(item.get("meta", "")))
	_badge.text = str(item.get("badge", ""))
	_badge.visible = not _badge.text.is_empty()
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
	_selected_border.visible = _selected
	_selected_mark.visible = _selected
	if ThemeMGR:
		_selected_mark.modulate = ThemeMGR.get_color("primary_dark") \
			if ThemeMGR.get_appearance() == "light" else ThemeMGR.get_color("primary_light")
	else:
		_selected_mark.modulate = Color.WHITE


func _load_cover() -> void:
	_cover_version += 1
	var version := _cover_version
	var is_skin := str(item.get("kind", "")) == "skin"
	_note_preview.visible = is_skin
	_cover.visible = not is_skin
	if is_skin:
		_cover.texture = null
		_cover_placeholder.visible = false
		_note_preview.call("setup", item)
		return
	_note_preview.call("clear")
	_cover.texture = null
	_cover_placeholder.visible = true
	_cover_placeholder.texture = _placeholder_icon(str(item.get("kind", "")))

	var local_tex = item.get("cover_tex")
	if local_tex is Texture2D:
		_cover.texture = local_tex
		_cover_placeholder.visible = false
		return

	var cover_path := str(item.get("cover_path", ""))
	if cover_path.is_empty():
		return
	if cover_path.begins_with("res://"):
		if ResourceLoader.exists(cover_path):
			var builtin_tex := load(cover_path) as Texture2D
			if builtin_tex and version == _cover_version:
				_cover.texture = builtin_tex
				_cover_placeholder.visible = false
		return
	var item_id := "resource_card_%d" % get_instance_id()
	CoverLoader.request_load(item_id, cover_path, func(_path: String, tex: Texture2D, _v: int) -> void:
		if not is_instance_valid(self) or version != _cover_version:
			return
		if tex:
			_cover.texture = tex
			_cover_placeholder.visible = false
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
	var surface_high := ThemeMGR.get_color("surface_high")
	var surface_hover := ThemeMGR.get_color("surface_hover")
	var surface_low := ThemeMGR.get_color("surface_low")
	var border := ThemeMGR.get_color("border")
	var primary := ThemeMGR.get_color("primary")
	var primary_light := ThemeMGR.get_color("primary_light")
	var primary_dark := ThemeMGR.get_color("primary_dark")
	var is_light := ThemeMGR.get_appearance() == "light"
	var accent := primary_dark if is_light else primary_light

	# 共享 StyleBox 只改一次（同一 tscn 的所有卡片共用）
	if _shared_style_revision != ThemeMGR.theme_revision:
		_shared_style_revision = ThemeMGR.theme_revision
		for spec in [
			["normal", surface_high, border, 0.94],
			["hover", surface_hover, primary, 0.98],
			["pressed", surface_low, primary_light, 1.0],
		]:
			var sb := get_theme_stylebox(spec[0]) as StyleBoxFlat
			if sb:
				sb.bg_color = ThemeMGR._tint_keep_alpha(spec[1], spec[3])
				sb.border_color = ThemeMGR._tint_keep_alpha(spec[2], 0.85)
		var focus_sb := get_theme_stylebox("focus") as StyleBoxFlat
		if focus_sb:
			focus_sb.border_color = ThemeMGR._tint_keep_alpha(accent, 0.9)
		var cover_sb := _cover_wrap.get_theme_stylebox("panel") as StyleBoxFlat
		if cover_sb:
			cover_sb.bg_color = ThemeMGR.get_color("surface_high") if is_light else surface_low
			cover_sb.border_color = border
		var border_sb := _selected_border.get_theme_stylebox("panel") as StyleBoxFlat
		if border_sb:
			border_sb.border_color = ThemeMGR._tint_keep_alpha(accent, 0.95)
		var badge_sb := _badge.get_theme_stylebox("normal") as StyleBoxFlat
		if badge_sb:
			badge_sb.bg_color = ThemeMGR._tint_keep_alpha(primary_dark, 0.9)

	# 实例级颜色
	_badge.add_theme_color_override("font_color", Color.WHITE)
	_cover_placeholder.modulate = ThemeMGR.get_color("text_secondary") if is_light \
		else ThemeMGR.get_color("text_dim")
	_cover_placeholder.modulate.a = 0.5
	_apply_selected()


func _exit_tree() -> void:
	CoverLoader.cancel("resource_card_%d" % get_instance_id())
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)

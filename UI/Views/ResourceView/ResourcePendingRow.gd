## 待操作列表的单行（纯文字 + 右侧移除按钮）。池化复用，只按 row_index 取当前项。
extends Button

signal remove_requested(item: Dictionary)

const StoreIconsLib := preload("res://UI/Views/StoreView/StoreIcons.gd")

static var _shared_style_revision := -1

var item: Dictionary = {}
var _has_ready := false

@onready var _name: Label = $Margin/HBox/Name
@onready var _remove_btn: Button = $Margin/HBox/RemoveBtn


func _ready() -> void:
	_has_ready = true
	_remove_btn.icon = StoreIconsLib.close()
	_remove_btn.pressed.connect(func() -> void: remove_requested.emit(item))
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()
	if not item.is_empty():
		_apply()


func setup(p_item: Dictionary) -> void:
	item = p_item
	if _has_ready:
		_apply()


func _apply() -> void:
	_name.set_scroll_text(str(item.get("title", "未命名")))


func apply_theme() -> void:
	if not _has_ready or not ThemeMGR:
		return
	var surface := ThemeMGR.get_color("surface")
	var surface_hover := ThemeMGR.get_color("surface_hover")
	var surface_low := ThemeMGR.get_color("surface_low")
	var border := ThemeMGR.get_color("border_soft")
	if _shared_style_revision != ThemeMGR.theme_revision:
		_shared_style_revision = ThemeMGR.theme_revision
		for spec in [
			["normal", surface, border, 0.25],
			["hover", surface_hover, border, 0.65],
			["pressed", surface_low, border, 0.9],
		]:
			var sb := get_theme_stylebox(spec[0]) as StyleBoxFlat
			if sb:
				sb.bg_color = ThemeMGR._tint_keep_alpha(spec[1], spec[3])
				sb.border_color = ThemeMGR._tint_keep_alpha(spec[2], 0.6)
		var focus_sb := get_theme_stylebox("focus") as StyleBoxFlat
		if focus_sb:
			focus_sb.border_color = ThemeMGR.get_color("primary_dark") \
				if ThemeMGR.get_appearance() == "light" else ThemeMGR.get_color("primary_light")
	_remove_btn.icon = StoreIconsLib.close()
	_remove_btn.add_theme_color_override("icon_normal_color", ThemeMGR.get_color("text_secondary"))
	_remove_btn.add_theme_color_override("icon_hover_color", ThemeMGR.get_color("danger"))
	_remove_btn.add_theme_color_override("icon_pressed_color", ThemeMGR.get_color("danger"))


func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)

## 待操作列表的单行（纯文字 + 右侧移除按钮）。池化复用，只按 row_index 取当前项。
extends Button

signal remove_requested(item: Dictionary)

const StoreIconsLib := preload("res://UI/Views/StoreView/StoreIcons.gd")

var item: Dictionary = {}
var _has_ready := false


func _ready() -> void:
	_has_ready = true
	%RemoveBtn.icon = StoreIconsLib.close()
	%RemoveBtn.pressed.connect(func() -> void: remove_requested.emit(item))
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
	%Name.set_scroll_text(str(item.get("title", "未命名")))


func apply_theme() -> void:
	if not _has_ready or not ThemeMGR:
		return
	%RemoveBtn.icon = StoreIconsLib.close()
	%RemoveBtn.add_theme_color_override("icon_normal_color", ThemeMGR.get_color("text_secondary"))
	%RemoveBtn.add_theme_color_override("icon_hover_color", ThemeMGR.get_color("danger"))
	%RemoveBtn.add_theme_color_override("icon_pressed_color", ThemeMGR.get_color("danger"))


func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)

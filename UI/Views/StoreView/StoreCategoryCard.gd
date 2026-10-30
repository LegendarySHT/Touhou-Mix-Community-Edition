## 商店分类卡片（皮肤 / 特效 / 音源）：左侧大图预览 + 右侧标题/简介 + 单个下载按钮。
##
## 与歌曲卡片的差异只有内容字段与默认状态：分类资源当前没有远端下发接口，
## 列表来自本地资源索引（已安装），按钮呈「已安装」状态；详情弹窗结构完全复用。
class_name StoreCategoryCard
extends Button

static var _shared_style_revision := -1

const StoreIconsLib := preload("res://UI/Views/StoreView/StoreIcons.gd")

signal detail_requested(item: Dictionary, source_rect: Rect2)
signal download_requested(item: Dictionary)

## 本卡片“已安装”状态（分类资源专用，与 ResourceManager.DownloadState 不冲突）
const STATE_INSTALLED := 100

var item: Dictionary = {}

var _has_ready := false
var _cover_version := 0
var _press_pos := Vector2.INF

var _dl_normal: StyleBoxFlat
var _dl_hover: StyleBoxFlat
var _dl_pressed: StyleBoxFlat
var _dl_focus: StyleBoxFlat

@onready var _cover: RoundedTextureRect = $Margin/HBox/CoverWrap/Cover
@onready var _cover_placeholder: TextureRect = $Margin/HBox/CoverWrap/Placeholder
@onready var _cover_wrap: Panel = $Margin/HBox/CoverWrap
@onready var _kind_chip: Label = $Margin/HBox/CoverWrap/KindChip
@onready var _type_label: Label = $Margin/HBox/Info/Type
@onready var _title: Label = $Margin/HBox/Info/Title
@onready var _desc: Label = $Margin/HBox/Info/Desc
@onready var _meta: Label = $Margin/HBox/Info/Meta
@onready var _download_btn: Button = $Margin/HBox/RightCol/DownloadBtn
@onready var _state_label: Label = $Margin/HBox/RightCol/StateLabel


func _ready() -> void:
	_has_ready = true
	_dl_normal = _duplicate_stylebox("normal")
	_dl_hover = _duplicate_stylebox("hover")
	_dl_pressed = _duplicate_stylebox("pressed")
	_dl_focus = _duplicate_stylebox("focus")
	if _dl_normal:
		_download_btn.add_theme_stylebox_override("normal", _dl_normal)
	if _dl_hover:
		_download_btn.add_theme_stylebox_override("hover", _dl_hover)
	if _dl_pressed:
		_download_btn.add_theme_stylebox_override("pressed", _dl_pressed)
	if _dl_focus:
		_download_btn.add_theme_stylebox_override("focus", _dl_focus)

	button_down.connect(func() -> void: _press_pos = get_global_mouse_position())
	pressed.connect(_on_pressed)
	_download_btn.pressed.connect(_on_download_pressed)

	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()
	if not item.is_empty():
		_apply_item(false)


func _duplicate_stylebox(state: String) -> StyleBoxFlat:
	var sb := _download_btn.get_theme_stylebox(state) as StyleBoxFlat
	return sb.duplicate() as StyleBoxFlat if sb else null


func set_item(p_item: Dictionary, animate_in: bool = false) -> void:
	item = p_item
	if not _has_ready:
		return
	_apply_item(animate_in)


func refresh_download_state() -> void:
	if item.is_empty() or not _has_ready:
		return
	_apply_state()


func _apply_item(animate_in: bool) -> void:
	if item.is_empty():
		return
	var kind := str(item.get("kind", ""))
	_type_label.text = str(item.get("type_label", _type_label_text(kind)))
	_title.set_scroll_text(str(item.get("title", "未命名")))
	var desc := str(item.get("desc", ""))
	_desc.text = desc if not desc.is_empty() else _default_desc(kind)
	var meta := str(item.get("author", ""))
	var size_text := str(item.get("size_text", ""))
	if not size_text.is_empty():
		meta = ("%s · %s" % [meta, size_text]) if not meta.is_empty() else size_text
	_meta.set_scroll_text(meta)
	_kind_chip.text = "内置" if bool(item.get("is_builtin", false)) else "本地"
	_kind_chip.visible = true

	_load_cover(kind)
	_apply_state()

	if animate_in:
		modulate.a = 0.0
		var tw := AniMGR.create_managed_tween(self, "store_card_in_%d" % get_instance_id())
		if tw:
			tw.tween_property(self, "modulate:a", 1.0, 0.24) \
				.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	else:
		modulate.a = 1.0


func _type_label_text(kind: String) -> String:
	match kind:
		"skin": return "音符皮肤"
		"effect": return "判定特效"
		"soundfont": return "音源库"
	return "商店资源"


func _default_desc(kind: String) -> String:
	match kind:
		"skin": return "替换演奏界面的音符、长条与判定光效外观。"
		"effect": return "替换 Perfect / Great / Good / Bad 的粒子表现。"
		"soundfont": return "演奏与播放时使用的音源库（.sf2）。"
	return "商店资源。"


func _load_cover(kind: String) -> void:
	_cover_version += 1
	_cover.texture = null
	_cover_placeholder.visible = true
	_cover_placeholder.texture = _placeholder_icon(kind)
	if ThemeMGR:
		_cover_placeholder.modulate = ThemeMGR.get_color("text_dim")
		_cover_placeholder.modulate.a = 0.55
	else:
		_cover_placeholder.modulate = Color(1, 1, 1, 0.55)

	var local_tex = item.get("cover_tex")
	if local_tex is Texture2D:
		_cover.texture = local_tex
		_cover_placeholder.visible = false


func _placeholder_icon(kind: String) -> Texture2D:
	match kind:
		"skin": return StoreIconsLib.skin()
		"effect": return StoreIconsLib.effect()
		"soundfont": return StoreIconsLib.soundfont()
	return StoreIconsLib.download_cloud()


func _apply_state() -> void:
	var state := int(item.get("state", STATE_INSTALLED))
	var base := ThemeMGR.get_color("success") if ThemeMGR else Color("#2FA66A")
	var icon: Texture2D = StoreIconsLib.check()
	var text := "已安装"
	var tip := "该资源已在本地"
	match state:
		ResourceManager.DownloadState.NOT_DOWNLOADED:
			base = ThemeMGR.get_color("primary") if ThemeMGR else Color("#2E55C8")
			icon = StoreIconsLib.download()
			text = "获取"
			tip = "下载该资源"
		ResourceManager.DownloadState.DOWNLOADING:
			base = ThemeMGR.get_color("warning") if ThemeMGR else Color("#D89A2A")
			icon = StoreIconsLib.download_cloud()
			text = "下载中"
			tip = "正在下载…"
		ResourceManager.DownloadState.FAILED:
			base = ThemeMGR.get_color("danger") if ThemeMGR else Color("#C7303F")
			icon = StoreIconsLib.close()
			text = "重试"
			tip = "下载失败，点击重试"
	_download_btn.icon = icon
	_download_btn.tooltip_text = tip
	_state_label.text = text
	_set_download_colors(base)


func _set_download_colors(base: Color) -> void:
	if _dl_normal:
		_dl_normal.bg_color = ThemeMGR._tint_keep_alpha(base.darkened(0.12), 0.92) if ThemeMGR else base
		_dl_normal.border_color = base.lightened(0.35)
	if _dl_hover:
		_dl_hover.bg_color = ThemeMGR._tint_keep_alpha(base, 1.0) if ThemeMGR else base
		_dl_hover.border_color = base.lightened(0.55)
	if _dl_pressed:
		_dl_pressed.bg_color = base.darkened(0.2)
		_dl_pressed.border_color = base
	if _dl_focus:
		var light := ThemeMGR != null and ThemeMGR.get_appearance() == "light"
		_dl_focus.border_color = base.darkened(0.08) if light else base.lightened(0.5)
		_dl_focus.shadow_color = Color(base.r, base.g, base.b, 0.4)
	_state_label.add_theme_color_override("font_color",
		ThemeMGR.get_color("text_secondary") if ThemeMGR else Color(0.7, 0.75, 0.85))


func _on_pressed() -> void:
	var dragging := _press_pos != Vector2.INF \
		and get_global_mouse_position().distance_to(_press_pos) > 14.0
	_press_pos = Vector2.INF
	if dragging:
		return
	detail_requested.emit(item, get_global_rect())


func _on_download_pressed() -> void:
	var state := int(item.get("state", STATE_INSTALLED))
	if state == STATE_INSTALLED \
			or state == ResourceManager.DownloadState.DOWNLOADING \
			or state == ResourceManager.DownloadState.DOWNLOADED:
		return
	download_requested.emit(item)


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
			var focus_color := primary_dark if is_light else primary_light
			focus_sb.border_color = ThemeMGR._tint_keep_alpha(focus_color, 0.9)
			focus_sb.shadow_color = Color(primary.r, primary.g, primary.b, 0.35)

		var cover_sb := _cover_wrap.get_theme_stylebox("panel") as StyleBoxFlat
		if cover_sb:
			cover_sb.bg_color = ThemeMGR.get_color("surface_high") if is_light else surface_low
			cover_sb.border_color = border

	_type_label.add_theme_color_override("font_color", primary_dark if is_light else primary_light)
	_desc.add_theme_color_override("font_color",
		ThemeMGR.get_color("text_secondary") if is_light else ThemeMGR.get_color("text_dim"))
	# 分类角标固定深蓝底，字色必须固定白色（不能跟随主题的深色正文）
	_kind_chip.add_theme_color_override("font_color", Color.WHITE)
	_cover_placeholder.modulate = ThemeMGR.get_color("text_secondary") if is_light \
		else ThemeMGR.get_color("text_dim")
	_cover_placeholder.modulate.a = 0.55

	_apply_state()


func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)

## 商店分类卡片（皮肤 / 特效 / 音源）：左侧大图预览 + 右侧标题/简介 + 单个下载按钮。
##
## 与歌曲卡片的差异只有内容字段与默认状态：分类资源当前没有远端下发接口，
## 列表来自本地资源索引（已安装），按钮呈「已安装」状态；详情弹窗结构完全复用。
class_name StoreCategoryCard
extends Button

const StoreIconsLib := preload("res://UI/Views/StoreView/StoreIcons.gd")

signal detail_requested(item: Dictionary, source_rect: Rect2)
signal download_requested(item: Dictionary)

## 本卡片“已安装”状态（分类资源专用，与 ResourceManager.DownloadState 不冲突）
const STATE_INSTALLED := 100

var item: Dictionary = {}

var _has_ready := false
var _cover_version := 0
var _press_pos := Vector2.INF

func _ready() -> void:
	_has_ready = true

	button_down.connect(func() -> void: _press_pos = get_global_mouse_position())
	pressed.connect(_on_pressed)
	%DownloadBtn.pressed.connect(_on_download_pressed)

	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()
	if not item.is_empty():
		_apply_item(false)


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
	%Type.text = str(item.get("type_label", _type_label_text(kind)))
	%Title.set_scroll_text(str(item.get("title", "未命名")))
	var desc := str(item.get("desc", ""))
	%Desc.text = desc if not desc.is_empty() else _default_desc(kind)
	var meta := str(item.get("author", ""))
	var size_text := str(item.get("size_text", ""))
	if not size_text.is_empty():
		meta = ("%s · %s" % [meta, size_text]) if not meta.is_empty() else size_text
	%Meta.set_scroll_text(meta)
	%KindChip.text = "内置" if bool(item.get("is_builtin", false)) else "本地"
	%KindChip.visible = true

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
	%Cover.texture = null
	%Placeholder.visible = true
	%Placeholder.texture = _placeholder_icon(kind)
	if ThemeMGR:
		%Placeholder.modulate = ThemeMGR.get_color("text_dim")
		%Placeholder.modulate.a = 0.55
	else:
		%Placeholder.modulate = Color(1, 1, 1, 0.55)

	var local_tex = item.get("cover_tex")
	if local_tex is Texture2D:
		%Cover.texture = local_tex
		%Placeholder.visible = false


func _placeholder_icon(kind: String) -> Texture2D:
	match kind:
		"skin": return StoreIconsLib.skin()
		"effect": return StoreIconsLib.effect()
		"soundfont": return StoreIconsLib.soundfont()
	return StoreIconsLib.download_cloud()


func _apply_state() -> void:
	var state := int(item.get("state", STATE_INSTALLED))
	var variant := &"ButtonDownloadDone"
	var icon_tex: Texture2D = StoreIconsLib.check()
	var label_text := "已安装"
	var tip := "该资源已在本地"
	match state:
		ResourceManager.DownloadState.NOT_DOWNLOADED:
			variant = &"ButtonDownloadIdle"
			icon_tex = StoreIconsLib.download()
			label_text = "获取"
			tip = "下载该资源"
		ResourceManager.DownloadState.DOWNLOADING:
			variant = &"ButtonDownloadBusy"
			icon_tex = StoreIconsLib.download_cloud()
			label_text = "下载中"
			tip = "正在下载…"
		ResourceManager.DownloadState.FAILED:
			variant = &"ButtonDownloadError"
			icon_tex = StoreIconsLib.close()
			label_text = "重试"
			tip = "下载失败，点击重试"
	%DownloadBtn.icon = icon_tex
	%DownloadBtn.tooltip_text = tip
	%StateLabel.text = label_text
	%DownloadBtn.theme_type_variation = variant
	%StateLabel.add_theme_color_override("font_color",
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
	var is_light := ThemeMGR.get_appearance() == "light"

	# Type / Desc 走 LabelAccent / LabelMuted 变体
	# 分类角标固定深蓝底，字色必须固定白色（LabelOnAccent 变体，tscn 里挂）
	%Placeholder.modulate = ThemeMGR.get_color("text_secondary") if is_light \
		else ThemeMGR.get_color("text_dim")
	%Placeholder.modulate.a = 0.55

	_apply_state()


func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)

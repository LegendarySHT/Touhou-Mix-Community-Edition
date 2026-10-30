## 下载管理列表行：只显示名字 / 作者 / 状态（封面留给顶部正在下载的主卡）。
## 走 VirtualList 池化，行高固定 84。
class_name StoreDownloadRow
extends Button

const StoreIconsLib := preload("res://UI/Views/StoreView/StoreIcons.gd")

signal detail_requested(item: Dictionary, source_rect: Rect2)

## 批量队列里的等待项（不是 ResourceManager 的状态）
const STATE_QUEUED := 101

var item: Dictionary = {}

var _press_pos := Vector2.INF
var _has_ready := false

@onready var _status_icon: TextureRect = $Margin/HBox/StatusIcon
@onready var _name: Label = $Margin/HBox/Name
@onready var _status: Label = $Margin/HBox/Status


func _ready() -> void:
	_has_ready = true
	button_down.connect(func() -> void: _press_pos = get_global_mouse_position())
	pressed.connect(_on_pressed)
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()
	if not item.is_empty():
		_apply()


func set_entry(p_item: Dictionary, state: int, stage: int = -1, percent: float = -1.0) -> void:
	item = p_item
	item["_row_state"] = state
	item["_row_stage"] = stage
	item["_row_percent"] = percent
	if not _has_ready:
		return
	_apply()


func _apply() -> void:
	_name.set_scroll_text(str(item.get("title", "未命名")))
	var state := int(item.get("_row_state", STATE_QUEUED))
	var stage := int(item.get("_row_stage", -1))
	var percent := float(item.get("_row_percent", -1.0))
	var is_light := ThemeMGR != null and ThemeMGR.get_appearance() == "light"
	var muted := ThemeMGR.get_color("text_secondary") if is_light \
		else (ThemeMGR.get_color("text_dim") if ThemeMGR else Color(0.6, 0.65, 0.72))
	var color := muted
	var icon: Texture2D = StoreIconsLib.download_cloud()
	var text := "等待中"
	match state:
		STATE_QUEUED:
			text = "等待中"
			color = muted
			icon = StoreIconsLib.download_cloud()
		ResourceManager.DownloadState.DOWNLOADING:
			text = _stage_text(stage)
			if percent >= 0.0:
				text = "%s %d%%" % [text, int(round(percent * 100.0))]
			color = ThemeMGR.get_color("warning") if ThemeMGR else color
			icon = StoreIconsLib.download_cloud()
		ResourceManager.DownloadState.DOWNLOADED:
			text = "已完成"
			color = ThemeMGR.get_color("success") if ThemeMGR else color
			icon = StoreIconsLib.check()
		ResourceManager.DownloadState.FAILED:
			text = "下载失败"
			color = ThemeMGR.get_color("danger") if ThemeMGR else color
			icon = StoreIconsLib.close()
		_:
			text = "—"
	_status.text = text
	_status.add_theme_color_override("font_color", color)
	_status_icon.texture = icon
	_status_icon.modulate = color


func _stage_text(stage: int) -> String:
	match stage:
		ResourceManager.DownloadStage.METADATA: return "获取谱面信息"
		ResourceManager.DownloadStage.COVER: return "下载封面"
		ResourceManager.DownloadStage.MIDI: return "下载 MIDI"
		ResourceManager.DownloadStage.JSON: return "写入谱面信息"
		ResourceManager.DownloadStage.RESCAN: return "刷新曲库"
		ResourceManager.DownloadStage.VOCAL: return "下载人声"
	return "下载中"


func _on_pressed() -> void:
	var dragging := _press_pos != Vector2.INF \
		and get_global_mouse_position().distance_to(_press_pos) > 14.0
	_press_pos = Vector2.INF
	if dragging or item.is_empty():
		return
	detail_requested.emit(item, get_global_rect())


func apply_theme() -> void:
	if not _has_ready or not ThemeMGR:
		return
	var surface := ThemeMGR.get_color("surface")
	var surface_hover := ThemeMGR.get_color("surface_hover")
	var surface_low := ThemeMGR.get_color("surface_low")
	var border := ThemeMGR.get_color("border_soft")
	var primary := ThemeMGR.get_color("primary")

	for spec in [
		["normal", surface, border, 0.42],
		["hover", surface_hover, primary, 0.7],
		["pressed", surface_low, primary, 0.9],
	]:
		var sb := get_theme_stylebox(spec[0]) as StyleBoxFlat
		if sb:
			sb.bg_color = ThemeMGR._tint_keep_alpha(spec[1], spec[3])
			sb.border_color = ThemeMGR._tint_keep_alpha(spec[2], 0.55)
	var focus_sb := get_theme_stylebox("focus") as StyleBoxFlat
	if focus_sb:
		var focus_color := ThemeMGR.get_color("primary_dark") \
			if ThemeMGR.get_appearance() == "light" else ThemeMGR.get_color("primary_light")
		focus_sb.border_color = ThemeMGR._tint_keep_alpha(focus_color, 0.9)

	_apply()


func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)

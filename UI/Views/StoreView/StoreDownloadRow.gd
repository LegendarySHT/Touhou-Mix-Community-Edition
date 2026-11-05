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


func _ready() -> void:
	_has_ready = true
	button_down.connect(func() -> void: _press_pos = get_global_mouse_position())
	pressed.connect(_on_pressed)
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()
	if not item.is_empty():
		apply_theme()


func set_entry(p_item: Dictionary, state: int, stage: int = -1, percent: float = -1.0) -> void:
	item = p_item
	item["_row_state"] = state
	item["_row_stage"] = stage
	item["_row_percent"] = percent
	if not _has_ready:
		return
	apply_theme()


func apply_theme() -> void:
	if not _has_ready or not ThemeMGR:
		return

	%Name.set_scroll_text(str(item.get("title", "未命名")))
	var state := int(item.get("_row_state", STATE_QUEUED))
	var stage := int(item.get("_row_stage", -1))
	var percent := float(item.get("_row_percent", -1.0))
	var is_light := ThemeMGR != null and ThemeMGR.get_appearance() == "light"
	var muted := ThemeMGR.get_color("text_secondary") if is_light \
		else (ThemeMGR.get_color("text_dim") if ThemeMGR else Color(0.6, 0.65, 0.72))
	var color := muted
	var status_icon_tex: Texture2D = StoreIconsLib.download_cloud()
	var status_text := "等待中"
	match state:
		STATE_QUEUED:
			status_text = "等待中"
			color = muted
			status_icon_tex = StoreIconsLib.download_cloud()
		ResourceManager.DownloadState.DOWNLOADING:
			status_text = _stage_text(stage)
			if percent >= 0.0:
				status_text = "%s %d%%" % [status_text, int(round(percent * 100.0))]
			color = ThemeMGR.get_color("warning") if ThemeMGR else color
			status_icon_tex = StoreIconsLib.download_cloud()
		ResourceManager.DownloadState.DOWNLOADED:
			status_text = "已完成"
			color = ThemeMGR.get_color("success") if ThemeMGR else color
			status_icon_tex = StoreIconsLib.check()
		ResourceManager.DownloadState.FAILED:
			status_text = "下载失败"
			color = ThemeMGR.get_color("danger") if ThemeMGR else color
			status_icon_tex = StoreIconsLib.close()
		_:
			status_text = "—"
	%Status.text = status_text
	%Status.add_theme_color_override("font_color", color)
	%StatusIcon.texture = status_icon_tex
	%StatusIcon.modulate = color


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

func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)

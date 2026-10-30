## 商店歌曲卡片：左封面 + 中信息 + 右侧单个下载按钮。
##
## 交互约定：
##   - 点卡片任意非按钮区域（或键盘确认）→ 请求打开详情弹窗（detail_requested）
##   - 点右下角下载按钮 → 只触发下载（download_requested），不打开详情
## 卡片本身是 Button（键盘焦点 + 四态主题样式），子控件统一 mouse_filter=IGNORE/PASS。
##
## 该节点由 `VirtualList` 池化复用：位置/尺寸/offset_transform 全部由池模块接管，
## 这里只负责「换绑数据」与「状态样式」。
class_name StoreSongCard
extends Button

static var _shared_style_revision := -1

const StoreIconsLib := preload("res://UI/Views/StoreView/StoreIcons.gd")

## 请求查看详情：item = 规范化条目字典，source_rect = 卡片当前全局矩形（供弹窗做展开动画）
signal detail_requested(item: Dictionary, source_rect: Rect2)
## 请求下载/重试
signal download_requested(item: Dictionary)

const TAB_SONG := "song"

## 当前绑定的条目（规范化字典，见 StoreView._make_song_item）
var item: Dictionary = {}

var _has_ready := false
var _cover_version := 0
## 鼠标按下位置：用于区分「点击卡片」与「拖动滚动」（触摸滚动时不要误开详情）
var _press_pos := Vector2.INF

var _dl_normal: StyleBoxFlat
var _dl_hover: StyleBoxFlat
var _dl_pressed: StyleBoxFlat
var _dl_focus: StyleBoxFlat

@onready var _cover: RoundedTextureRect = $Margin/HBox/CoverWrap/Cover
@onready var _cover_placeholder: TextureRect = $Margin/HBox/CoverWrap/Placeholder
@onready var _cover_wrap: Panel = $Margin/HBox/CoverWrap
@onready var _duration: Label = $Margin/HBox/CoverWrap/Duration
@onready var _title: Label = $Margin/HBox/Info/Title
@onready var _author: Label = $Margin/HBox/Info/Author
@onready var _song_line: Label = $Margin/HBox/Info/SongLine
@onready var _uploader: Label = $Margin/HBox/Info/Uploader
@onready var _stats: HBoxContainer = $Margin/HBox/Info/Stats
@onready var _stat_downloads: HBoxContainer = $Margin/HBox/Info/Stats/Downloads
@onready var _stat_downloads_count: Label = $Margin/HBox/Info/Stats/Downloads/Count
@onready var _stat_plays: HBoxContainer = $Margin/HBox/Info/Stats/Plays
@onready var _stat_plays_count: Label = $Margin/HBox/Info/Stats/Plays/Count
@onready var _stat_likes: HBoxContainer = $Margin/HBox/Info/Stats/Likes
@onready var _stat_likes_count: Label = $Margin/HBox/Info/Stats/Likes/Count
@onready var _download_btn: Button = $Margin/HBox/RightCol/DownloadBtn
@onready var _state_label: Label = $Margin/HBox/RightCol/StateLabel


func _ready() -> void:
	_has_ready = true
	# 下载按钮的状态样式按卡片自己的下载状态着色，必须实例独立（场景子资源默认共享）
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

	button_down.connect(_on_button_down)
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


## 池换绑入口：animate_in 仅在数据整体刷新后的首次绑定为 true
func set_item(p_item: Dictionary, animate_in: bool = false) -> void:
	item = p_item
	if not _has_ready:
		return
	_apply_item(animate_in)


## 重新按当前下载状态刷按钮（下载完成/失败时由 StoreView 调用）
func refresh_download_state() -> void:
	if item.is_empty() or not _has_ready:
		return
	_apply_download_state()


func _apply_item(animate_in: bool) -> void:
	if item.is_empty():
		return

	var title := str(item.get("title", ""))
	var author := str(item.get("author", ""))
	var song := str(item.get("song", ""))
	var album := str(item.get("album", ""))
	var uploader := str(item.get("uploader", ""))
	_title.set_scroll_text(title if not title.is_empty() else "未命名谱面")
	_author.set_scroll_text(author if not author.is_empty() else "未知作者")
	var line := ""
	if not song.is_empty() and not album.is_empty():
		line = "%s · %s" % [song, album]
	else:
		line = song if not song.is_empty() else album
	_song_line.set_scroll_text(line if not line.is_empty() else "未知专辑")
	_uploader.set_scroll_text(("由 %s 上传" % uploader) if not uploader.is_empty() else "本地谱面")

	_apply_duration_label()

	_update_stat(_stat_downloads, _stat_downloads_count, int(item.get("downloads", -1)))
	_update_stat(_stat_plays, _stat_plays_count, int(item.get("plays", -1)))
	_update_stat(_stat_likes, _stat_likes_count, int(item.get("likes", -1)))

	_load_cover()
	_apply_download_state()

	if animate_in:
		modulate.a = 0.0
		var tw := AniMGR.create_managed_tween(self, "store_card_in_%d" % get_instance_id())
		if tw:
			tw.tween_property(self, "modulate:a", 1.0, 0.24) \
				.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	else:
		modulate.a = 1.0


## 封面右下角的状态行：有无人声 + 曲长（无人声时只显示时长）
func _apply_duration_label() -> void:
	var duration_sec := int(item.get("duration_sec", 0))
	var has_vocal := bool(item.get("has_vocal", false))
	var time_text := StoreIconsLib.format_duration(duration_sec)
	if duration_sec > 0:
		_duration.text = ("有人声 " + time_text) if has_vocal else time_text
		_duration.visible = true
	elif has_vocal:
		_duration.text = "有人声"
		_duration.visible = true
	else:
		_duration.text = ""
		_duration.visible = false


func _update_stat(row: HBoxContainer, label: Label, value: int) -> void:
	# 本地资源没有在线计数：整行隐藏，避免一排破折号
	row.visible = value >= 0
	label.text = StoreIconsLib.format_count(value)


func _load_cover() -> void:
	_cover_version += 1
	var version := _cover_version
	_cover.texture = null
	_cover_placeholder.visible = true
	_cover_placeholder.texture = StoreIconsLib.song()

	# 本地分类条目会直接带 Texture（皮肤/粒子预览图），远程谱面走 URL
	var local_tex = item.get("cover_tex")
	if local_tex is Texture2D:
		_cover.texture = local_tex
		_cover_placeholder.visible = false
		return
	var url := str(item.get("cover_url", ""))
	if url.is_empty():
		return
	HttpImageLoader.load(url, self, func(tex: Texture2D) -> void:
		if not is_instance_valid(self) or version != _cover_version:
			return
		if tex:
			_cover.texture = tex
			_cover_placeholder.visible = false
	)


## 下载状态 → 按钮图标/文案/主色
func _apply_download_state() -> void:
	if not _has_ready:
		return
	var state := int(item.get("state", ResourceManager.DownloadState.NOT_DOWNLOADED))
	var base := ThemeMGR.get_color("primary") if ThemeMGR else Color("#2E55C8")
	var icon: Texture2D = StoreIconsLib.download()
	var text := "下载"
	var tip := "下载该谱面"
	match state:
		ResourceManager.DownloadState.DOWNLOADING:
			base = ThemeMGR.get_color("warning") if ThemeMGR else Color("#D89A2A")
			icon = StoreIconsLib.download_cloud()
			text = "下载中"
			tip = "正在下载…"
		ResourceManager.DownloadState.DOWNLOADED:
			base = ThemeMGR.get_color("success") if ThemeMGR else Color("#2FA66A")
			icon = StoreIconsLib.check()
			text = "已下载"
			tip = "已下载到本地"
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


# ── 输入 ──────────────────────────────────────────────

func _on_button_down() -> void:
	_press_pos = get_global_mouse_position()


func _on_pressed() -> void:
	# 触摸拖动滚动时按钮也会收到 release：位移超过阈值就当成拖拽，不打开详情
	var dragging := _press_pos != Vector2.INF \
		and get_global_mouse_position().distance_to(_press_pos) > 14.0
	_press_pos = Vector2.INF
	if dragging:
		return
	detail_requested.emit(item, get_global_rect())


func _on_download_pressed() -> void:
	var state := int(item.get("state", ResourceManager.DownloadState.NOT_DOWNLOADED))
	if state == ResourceManager.DownloadState.DOWNLOADING \
			or state == ResourceManager.DownloadState.DOWNLOADED:
		return
	download_requested.emit(item)


# ── 主题 ──────────────────────────────────────────────

func apply_theme() -> void:
	if not _has_ready or not ThemeMGR:
		return
	var surface_high := ThemeMGR.get_color("surface_high")
	var surface_hover := ThemeMGR.get_color("surface_hover")
	var surface_low := ThemeMGR.get_color("surface_low")
	var border := ThemeMGR.get_color("border")
	var primary := ThemeMGR.get_color("primary")
	var primary_light := ThemeMGR.get_color("primary_light")
	var is_light := ThemeMGR.get_appearance() == "light"
	var muted_text := ThemeMGR.get_color("text_secondary") if is_light \
		else ThemeMGR.get_color("text_dim")

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
			var focus_color := ThemeMGR.get_color("primary_dark") if is_light else primary_light
			focus_sb.border_color = ThemeMGR._tint_keep_alpha(focus_color, 0.9)
			focus_sb.shadow_color = Color(primary.r, primary.g, primary.b, 0.35)

		var cover_sb := _cover_wrap.get_theme_stylebox("panel") as StyleBoxFlat
		if cover_sb:
			# 浅色模式封面框比卡片略深一档：白底上白色音符/长条的预览才看得见
			cover_sb.bg_color = ThemeMGR.get_color("surface_high") if is_light else surface_low
			cover_sb.border_color = border

	for label in [_stat_downloads_count, _stat_plays_count, _stat_likes_count]:
		label.add_theme_color_override("font_color", muted_text)
	for icon in _stats.find_children("*", "TextureRect", true, false):
		(icon as TextureRect).modulate = muted_text
	_cover_placeholder.modulate = muted_text
	_cover_placeholder.modulate.a = 0.4

	_apply_download_state()


func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)

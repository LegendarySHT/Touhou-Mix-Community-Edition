## 商店歌曲卡片：左封面 + 中信息 + 右侧单个下载按钮。
##
## 交互约定：
##   - 点卡片任意非按钮区域（或键盘确认）→ 请求打开详情弹窗（detail_requested）
##   - 点右下角下载按钮 → 未下载 / 失败时触发下载（download_requested）；
##     已下载时请求跳到该谱面的 MidiView（open_requested）；两者都不打开详情
## 卡片本身是 Button（键盘焦点 + 四态主题样式），子控件统一 mouse_filter=IGNORE/PASS。
##
## 该节点由 `VirtualList` 池化复用：位置/尺寸/offset_transform 全部由池模块接管，
## 这里只负责「换绑数据」与「状态样式」。
class_name StoreSongCard
extends Button

const StoreIconsLib := preload("res://UI/Views/StoreView/StoreIcons.gd")

## 请求查看详情：item = 规范化条目字典，source_rect = 卡片当前全局矩形（供弹窗做展开动画）
signal detail_requested(item: Dictionary, source_rect: Rect2)
## 请求下载/重试
signal download_requested(item: Dictionary)
## 已下载：请求跳到该谱面的 MidiView（导航由 StoreView 负责）
signal open_requested(item: Dictionary)

const TAB_SONG := "song"

## 当前绑定的条目（规范化字典，见 StoreView._make_song_item）
var item: Dictionary = {}

var _has_ready := false
var _cover_version := 0
## 当前挂着的远程封面 URL（换绑时用来撤掉上一个请求）
var _pending_cover_url := ""
## 鼠标按下位置：用于区分「点击卡片」与「拖动滚动」（触摸滚动时不要误开详情）
var _press_pos := Vector2.INF

func _ready() -> void:
	_has_ready = true
	button_down.connect(_on_button_down)
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


## 重新按当前下载状态刷按钮（下载完成/失败时由 StoreView 调用）
func refresh_download_state() -> void:
	if item.is_empty() or not _has_ready:
		return
	_apply_download_state()


## 详情页评价成功后只刷点赞行：整卡重绑会触发封面重载，弹窗收起时会闪一下
func refresh_reaction_counts(like_count: int) -> void:
	if item.is_empty() or not _has_ready:
		return
	_update_stat(%Likes, %LikesCount, like_count)


func _apply_item(animate_in: bool) -> void:
	if item.is_empty():
		return

	var title := str(item.get("title", ""))
	var author := str(item.get("author", ""))
	var song := str(item.get("song", ""))
	var album := str(item.get("album", ""))
	var uploader := str(item.get("uploader", ""))
	%Title.set_scroll_text(title if not title.is_empty() else "未命名谱面")
	%Author.set_scroll_text(author if not author.is_empty() else "未知作者")
	var line := ""
	if not song.is_empty() and not album.is_empty():
		line = "%s · %s" % [song, album]
	else:
		line = song if not song.is_empty() else album
	%SongLine.set_scroll_text(line if not line.is_empty() else "未知专辑")
	%Uploader.set_scroll_text(("由 %s 上传" % uploader) if not uploader.is_empty() else "本地谱面")

	_apply_duration_label()

	_update_stat(%Downloads, %DownloadsCount, int(item.get("downloads", -1)))
	_update_stat(%Plays, %PlaysCount, int(item.get("plays", -1)))
	_update_stat(%Likes, %LikesCount, int(item.get("likes", -1)))

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
		%Duration.text = ("有人声 " + time_text) if has_vocal else time_text
		%Duration.visible = true
	elif has_vocal:
		%Duration.text = "有人声"
		%Duration.visible = true
	else:
		%Duration.text = ""
		%Duration.visible = false


func _update_stat(row: HBoxContainer, label: Label, value: int) -> void:
	# 本地资源没有在线计数：整行隐藏，避免一排破折号
	row.visible = value >= 0
	label.text = StoreIconsLib.format_count(value)


func _load_cover() -> void:
	_cover_version += 1
	var version := _cover_version
	%Cover.texture = null
	%Placeholder.visible = true
	%Placeholder.texture = StoreIconsLib.song()

	# 本地分类条目会直接带 Texture（皮肤/粒子预览图），远程谱面走 URL
	var local_tex = item.get("cover_tex")
	if local_tex is Texture2D:
		%Cover.texture = local_tex
		%Placeholder.visible = false
		return
	# 已下载的谱面直接用本地封面：省一次网络请求，也和曲库 / 播放页看到的是同一张
	var local_path := ResourceManager.instance.get_local_cover_path(str(item.get("hash", "")))
	if not local_path.is_empty():
		_release_pending_remote("")
		CoverLoader.request_load("store_card_%d" % get_instance_id(), local_path,
			func(_path: String, tex: Texture2D, _ver: int) -> void:
				if not is_instance_valid(self) or version != _cover_version:
					return
				if tex:
					%Cover.texture = tex
					%Placeholder.visible = false
		)
		return
	var url := str(item.get("cover_url", ""))
	if url.is_empty():
		_release_pending_remote("")
		return
	# 谱面封面 URL 里带谱面 hash，内容不会原地变：本地有缓存就直接读，
	# 翻页回来不再逐张发请求（一页 24 张就是 24 次往返，快慢全看网络抖动）
	_release_pending_remote(url)
	var on_cover := func(tex: Texture2D) -> void:
		if not is_instance_valid(self) or version != _cover_version:
			return
		if tex:
			%Cover.texture = tex
			%Placeholder.visible = false
	HttpImageLoader.load(url, self, on_cover)


## 卡片换绑后，上一张封面的请求就别再占着并发槽位了（排队中的直接撤掉）
func _release_pending_remote(next_url: String) -> void:
	if _pending_cover_url.is_empty() or _pending_cover_url == next_url:
		_pending_cover_url = next_url
		return
	HttpImageLoader.cancel(_pending_cover_url, self)
	_pending_cover_url = next_url


## 下载状态 → 按钮图标/文案/主色
func _apply_download_state() -> void:
	if not _has_ready:
		return
	var state := int(item.get("state", ResourceManager.DownloadState.NOT_DOWNLOADED))
	var needs_vocal := bool(item.get("needs_vocal", false))
	var variant := &"ButtonDownloadIdle"
	var icon_tex: Texture2D = StoreIconsLib.download()
	var label_text := "下载"
	var tip := "下载该谱面"
	if needs_vocal:
		# 谱面已在本地但缺人声（「下载人声」开启）：仍然给下载按钮，点一下只补人声
		icon_tex = StoreIconsLib.mic()
		label_text = "下载人声"
		tip = "本地缺人声，点击补下"
	match state:
		ResourceManager.DownloadState.DOWNLOADING:
			variant = &"ButtonDownloadBusy"
			icon_tex = StoreIconsLib.download_cloud()
			label_text = "下载中"
			tip = "正在下载…"
		ResourceManager.DownloadState.DOWNLOADED:
			variant = &"ButtonDownloadDone"
			icon_tex = StoreIconsLib.check()
			label_text = "已下载"
			tip = "已下载到本地"
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
	# 状态按 hash 实时取，避免卡片里缓存的 state 落后于实际下载结果
	# （排队中的谱面在 ResourceManager 眼里仍是未下载，这种情况保留卡片上的「下载中」）
	var state := int(item.get("state", ResourceManager.DownloadState.NOT_DOWNLOADED))
	var hash_str := str(item.get("hash", ""))
	if not hash_str.is_empty() and state != ResourceManager.DownloadState.DOWNLOADING:
		state = ResourceManager.instance.get_download_state(hash_str)
	if bool(item.get("needs_vocal", false)):
		state = ResourceManager.DownloadState.NOT_DOWNLOADED
	match state:
		ResourceManager.DownloadState.DOWNLOADING:
			return
		ResourceManager.DownloadState.DOWNLOADED:
			open_requested.emit(item)
			return
	download_requested.emit(item)


# ── 主题 ──────────────────────────────────────────────

func apply_theme() -> void:
	if not _has_ready or not ThemeMGR:
		return
	var is_light := ThemeMGR.get_appearance() == "light"
	var muted_text := ThemeMGR.get_color("text_secondary") if is_light \
		else ThemeMGR.get_color("text_dim")

	for icon_node in %Stats.find_children("*", "TextureRect", true, false):
		(icon_node as TextureRect).modulate = muted_text
	%Placeholder.modulate = muted_text
	%Placeholder.modulate.a = 0.4

	_apply_download_state()


func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)

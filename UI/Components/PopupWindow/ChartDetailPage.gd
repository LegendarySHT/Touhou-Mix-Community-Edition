## 谱面详情页（PopupWindow 的一个页面）
##
## 内容与旧的内嵌详情面板一致：左上封面 + 排行榜 / 右侧简介 + 统计 + 底部操作按钮。
## 外壳（遮罩、标题栏、关闭按钮、开合动画、焦点）由 PopupWindow 统一提供，
## 本页只负责填充数据、下载状态机与跳转。
##
## Mode.STORE   商店：按钮承载下载状态机，未下载时发 download_requested 交由宿主处理
## Mode.LIBRARY 曲库 / 游玩记录等非商店入口：不发起下载，仅当谱面在本地时提供跳转
class_name ChartDetailPage
extends Control

const StoreIconsLib := preload("res://UI/Views/StoreView/StoreIcons.gd")

signal download_requested(item: Dictionary)
## 即将跳转 MIDI_VIEW 时通知宿主（跳转本身由本页完成）
signal open_requested(item: Dictionary)

enum Mode { STORE, LIBRARY }

var _item: Dictionary = {}
var _mode: int = Mode.STORE
var _cover_version := 0
var _req_version := 0

func _ready() -> void:
	%DownloadBtn.pressed.connect(_on_download_pressed)
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()

func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)

## 换一份数据重填（每次打开详情页调用）
func setup(item: Dictionary, mode: int = Mode.STORE) -> void:
	_req_version += 1
	_item = item
	_mode = mode
	_fill_content()
	_load_cover()
	_load_rank()

## 当前数据（弹窗标题用）
func get_item() -> Dictionary:
	return _item

func refresh_download_state() -> void:
	if str(_item.get("kind", "")) == "song":
		_apply_download_state()

# ── 内容 ──────────────────────────────────────────────

func _fill_content() -> void:
	%Sub.set_scroll_text(_subtitle())

	var desc := str(_item.get("desc", "")).strip_edges()
	if desc.is_empty():
		desc = _desc_fallback()
	%Desc.text = ""
	%Desc.add_text(desc)

	var downloads := int(_item.get("downloads", -1))
	var plays := int(_item.get("plays", -1))
	var likes := int(_item.get("likes", -1))
	var dislikes := int(_item.get("dislikes", -1))
	%DownloadsCount.text = StoreIconsLib.format_count(downloads)
	%PlaysCount.text = StoreIconsLib.format_count(plays)
	%LikeBtn.text = "  " + StoreIconsLib.format_count(likes)
	%DislikeBtn.text = "  " + StoreIconsLib.format_count(dislikes)
	var is_song := str(_item.get("kind", "")) == "song"
	# 分类资源没有在线点赞/游玩统计：整行统计隐藏，信息由左下「资源信息」承担
	%Stats.visible = is_song
	%CdDivider.visible = is_song
	%LikeBtn.visible = is_song
	%DislikeBtn.visible = is_song
	%LikeBtn.disabled = not is_song
	%DislikeBtn.disabled = not is_song

	var uploaded := str(_item.get("uploaded_at", ""))
	if uploaded.is_empty():
		%Date.text = ""
	else:
		%Date.text = "上传于 " + uploaded.replace("T", " ").substr(0, 16)

	var size_bytes := int(_item.get("size_bytes", 0))
	var size_text := StoreIconsLib.format_size(size_bytes) if size_bytes > 0 else str(_item.get("size_text", "—"))
	var extra: Array[String] = []
	var duration_sec := int(_item.get("duration_sec", 0))
	if duration_sec > 0:
		extra.append(StoreIconsLib.format_duration(duration_sec))
	if bool(_item.get("has_vocal", false)):
		extra.append("含人声")
	if str(_item.get("difficulty", "")) != "":
		extra.append("难度 " + str(_item.get("difficulty")))
	# 歌曲显示「文件 6.2 MB」，本地分类直接显示其自带的尺寸描述（如「10 张贴图」）
	%SizeLabel.text = ("文件 " + size_text) if size_bytes > 0 else size_text
	if not extra.is_empty():
		%SizeLabel.text += "  ·  " + "  ·  ".join(extra)

	_apply_download_state()

func _kind_text() -> String:
	match str(_item.get("kind", "")):
		"song": return "谱面"
		"skin": return "音符皮肤"
		"effect": return "判定特效"
		"soundfont": return "音源库"
	return "商店资源"

func _subtitle() -> String:
	var parts: Array[String] = []
	for key in ["author", "album", "song"]:
		var v := str(_item.get(key, ""))
		if not v.is_empty():
			parts.append(v)
	if parts.is_empty():
		var uploader := str(_item.get("uploader", ""))
		if not uploader.is_empty():
			parts.append("由 %s 上传" % uploader)
	return "  ·  ".join(parts)

func _desc_fallback() -> String:
	match str(_item.get("kind", "")):
		"skin": return "音符皮肤包，可替换演奏界面的音符、长条与判定光效外观。"
		"effect": return "判定特效包，可替换 Perfect / Great / Good / Bad 的粒子表现。"
		"soundfont": return "音源库（.sf2），用于演奏与音乐播放时的音色合成。"
	return "暂无简介。"

func _load_cover() -> void:
	_cover_version += 1
	var version := _cover_version
	%Cover.texture = null
	%Placeholder.visible = true
	%Placeholder.texture = _kind_icon()
	var local_tex = _item.get("cover_tex")
	if local_tex is Texture2D:
		%Cover.texture = local_tex
		%Placeholder.visible = false
		return
	# 已下载的谱面直接用本地封面，省一次网络请求（与商店卡片同一口径）
	var local_path := ResourceManager.instance.get_local_cover_path(str(_item.get("hash", "")))
	if not local_path.is_empty():
		CoverLoader.request_load("chart_detail_%d" % get_instance_id(), local_path,
			func(_path: String, tex: Texture2D, _ver: int) -> void:
				if not is_instance_valid(self) or version != _cover_version:
					return
				if tex:
					%Cover.texture = tex
					%Placeholder.visible = false
		)
		return
	var url := str(_item.get("cover_url", ""))
	if url.is_empty():
		return
	var on_cover := func(tex: Texture2D) -> void:
		if not is_instance_valid(self) or version != _cover_version:
			return
		if tex:
			%Cover.texture = tex
			%Placeholder.visible = false
	HttpImageLoader.load(url, self, on_cover)

func _kind_icon() -> Texture2D:
	match str(_item.get("kind", "")):
		"song": return StoreIconsLib.song()
		"skin": return StoreIconsLib.skin()
		"effect": return StoreIconsLib.effect()
		"soundfont": return StoreIconsLib.soundfont()
	return StoreIconsLib.download_cloud()

func _load_rank() -> void:
	_clear_rank_list()
	var version := _req_version
	var kind := str(_item.get("kind", ""))
	if kind != "song":
		%RankTitle.text = "资源信息"
		_add_info_row("类型", _kind_text())
		_add_info_row("大小", StoreIconsLib.format_size(int(_item.get("size_bytes", 0))) \
			if int(_item.get("size_bytes", 0)) > 0 else str(_item.get("size_text", "—")))
		_add_info_row("来源", "本地已安装" if bool(_item.get("is_builtin", false)) else "本地资源")
		return

	%RankTitle.text = "排行榜"
	var hash_str := str(_item.get("hash", ""))
	if hash_str.is_empty() or NetManager.instance == null or not NetManager.instance.is_online \
			or ScoreManager.instance == null:
		_add_rank_message("暂无排行数据")
		return
	_add_rank_message("加载中…")
	var result: Dictionary = await ScoreManager.instance.get_leaderboard(hash_str, 5, 0)
	if not is_inside_tree() or version != _req_version:
		return
	_clear_rank_list()
	if not result.get("ok", false):
		_add_rank_message("排行榜加载失败")
		return
	var data = result.get("data")
	if not data is Dictionary:
		_add_rank_message("暂无排行数据")
		return
	var scores: Array = data.get("scores", [])
	if scores.is_empty():
		_add_rank_message("暂无排行数据")
		return
	var i := 0
	for s in scores:
		i += 1
		if not s is Dictionary:
			continue
		_add_rank_row(i,
			str(s.get("username", "Anonymous")),
			int(s.get("totalScore", 0)),
			str(s.get("rank", "")))

# ── 排行榜 / 信息行 ──────────────────────────────────

func _clear_rank_list() -> void:
	for child in %RankList.get_children():
		%RankList.remove_child(child)
		child.queue_free()

func _add_rank_message(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 20)
	var is_light := ThemeMGR != null and ThemeMGR.get_appearance() == "light"
	label.add_theme_color_override("font_color",
		ThemeMGR.get_color("text_secondary") if is_light else (ThemeMGR.get_color("text_dim") if ThemeMGR else Color(0.6, 0.65, 0.72)))
	%RankList.add_child(label)

func _add_rank_row(rank: int, player: String, score: int, grade: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var rank_label := Label.new()
	rank_label.text = "%d" % rank
	rank_label.custom_minimum_size = Vector2(24, 0)
	rank_label.add_theme_font_size_override("font_size", 22)
	var rank_color := ThemeMGR.get_color("text_dim") if ThemeMGR else Color(0.6, 0.65, 0.72)
	if ThemeMGR:
		if rank == 1:
			rank_color = ThemeMGR.get_color("warning")
		elif rank == 2:
			rank_color = ThemeMGR.get_color("primary_dark") \
				if ThemeMGR.get_appearance() == "light" else ThemeMGR.get_color("primary_light")
		elif rank == 3:
			rank_color = ThemeMGR.get_color("info")
	rank_label.add_theme_color_override("font_color", rank_color)
	row.add_child(rank_label)

	var name_label := Label.new()
	name_label.text = player
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.clip_text = true
	name_label.add_theme_font_size_override("font_size", 20)
	name_label.add_theme_color_override("font_color",
		ThemeMGR.get_color("text_secondary") if ThemeMGR else Color(0.8, 0.84, 0.9))
	row.add_child(name_label)

	var score_label := Label.new()
	score_label.text = StoreIconsLib.format_score(score)
	score_label.add_theme_font_size_override("font_size", 20)
	score_label.add_theme_color_override("font_color",
		ThemeMGR.get_color("text_primary") if ThemeMGR else Color.WHITE)
	row.add_child(score_label)

	if not grade.is_empty():
		var grade_label := Label.new()
		grade_label.text = grade
		grade_label.add_theme_font_size_override("font_size", 20)
		grade_label.add_theme_color_override("font_color", rank_color)
		row.add_child(grade_label)

	%RankList.add_child(row)

func _add_info_row(key: String, value: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	var key_label := Label.new()
	key_label.text = key
	key_label.custom_minimum_size = Vector2(56, 0)
	key_label.add_theme_font_size_override("font_size", 20)
	var is_light := ThemeMGR != null and ThemeMGR.get_appearance() == "light"
	key_label.add_theme_color_override("font_color",
		ThemeMGR.get_color("text_secondary") if is_light else (ThemeMGR.get_color("text_dim") if ThemeMGR else Color(0.6, 0.65, 0.72)))
	row.add_child(key_label)
	var value_label := Label.new()
	value_label.text = value
	value_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value_label.clip_text = true
	value_label.add_theme_font_size_override("font_size", 20)
	value_label.add_theme_color_override("font_color",
		ThemeMGR.get_color("text_primary") if is_light else (ThemeMGR.get_color("text_secondary") if ThemeMGR else Color(0.8, 0.84, 0.9)))
	row.add_child(value_label)
	%RankList.add_child(row)

# ── 下载状态 ──────────────────────────────────────────

func _apply_download_state() -> void:
	if not is_inside_tree():
		return
	if _mode == Mode.LIBRARY:
		_apply_library_action()
		return
	var is_song := str(_item.get("kind", "")) == "song"
	if not is_song:
		%DownloadBtn.text = "已安装"
		%DownloadBtn.icon = StoreIconsLib.check()
		%DownloadBtn.tooltip_text = "本地资源已安装"
		%DownloadBtn.disabled = true
		%DownloadBtn.theme_type_variation = &"ButtonDownloadDone"
		return

	var state := _resolve_state()
	var variant := &"ButtonDownloadIdle"
	var icon: Texture2D = StoreIconsLib.download()
	var text := "下载谱面"
	var tip := "下载该谱面"
	%DownloadBtn.disabled = false
	match state:
		ResourceManager.DownloadState.DOWNLOADING:
			variant = &"ButtonDownloadBusy"
			icon = StoreIconsLib.download_cloud()
			text = "正在下载…"
			tip = "正在下载…"
		ResourceManager.DownloadState.DOWNLOADED:
			if bool(_item.get("needs_vocal", false)):
				# 谱面已在本地但缺人声（「下载人声」开启）：按钮回到下载态，点一下只补人声
				variant = &"ButtonDownloadIdle"
				icon = StoreIconsLib.mic()
				text = "下载人声"
				tip = "本地缺人声，点击补下"
			else:
				# 本地已有：按钮改成「进入曲库查看」，不再是终止态
				variant = &"ButtonDownloadDone"
				icon = StoreIconsLib.song()
				text = "查看谱面"
				tip = "在曲库中打开该谱面"
		ResourceManager.DownloadState.FAILED:
			variant = &"ButtonDownloadError"
			icon = StoreIconsLib.close()
			text = "重试下载"
			tip = "下载失败，点击重试"
	%DownloadBtn.text = text
	%DownloadBtn.icon = icon
	%DownloadBtn.tooltip_text = tip
	%DownloadBtn.theme_type_variation = variant

## 谱面当前状态：商店页会把「已进下载队列」的条目也标成 DOWNLOADING，这里以它为准；
## 但本地已经失败时必须按失败走，否则下载记录里点进来的详情会永远停在「正在下载」
func _resolve_state() -> int:
	var state := int(_item.get("state", ResourceManager.DownloadState.NOT_DOWNLOADED))
	var hash_str := str(_item.get("hash", ""))
	if hash_str.is_empty():
		return state
	var local_state := ResourceManager.instance.get_download_state(hash_str)
	if state == ResourceManager.DownloadState.DOWNLOADING \
			and local_state != ResourceManager.DownloadState.FAILED:
		return state
	return local_state

## 非商店入口：不参与下载状态机，只按本地曲库有无该谱面决定按钮是否可跳
func _apply_library_action() -> void:
	var hash_str := str(_item.get("hash", ""))
	var available := not hash_str.is_empty() and DataMGR.get_midi_by_id(hash_str) != null
	%DownloadBtn.disabled = not available
	%DownloadBtn.text = "查看谱面" if available else "本地没有该谱面"
	%DownloadBtn.icon = StoreIconsLib.song() if available else StoreIconsLib.close()
	%DownloadBtn.tooltip_text = "在曲库中打开该谱面" if available else "该谱面不在本地曲库中"
	if available:
		%DownloadBtn.theme_type_variation = &"ButtonDownloadDone"

func _on_download_pressed() -> void:
	if str(_item.get("kind", "")) != "song":
		return
	if _mode == Mode.LIBRARY:
		_open_midi_view()
		return
	var state := _resolve_state()
	if state == ResourceManager.DownloadState.DOWNLOADING:
		return
	if state == ResourceManager.DownloadState.DOWNLOADED \
			and not bool(_item.get("needs_vocal", false)):
		_open_midi_view()
		return
	download_requested.emit(_item)

## 按 hash 反查本地曲库后进 MIDI_VIEW。有专辑 / 歌曲归属时走标准导航，
## 让 MidiView 带出同歌曲的其它谱面并把返回链落在歌曲 / 专辑层级；
## 归属失效时退回直达路径，保证点击一定有响应。
## 弹窗是全屏层，必须先收起再切视图，否则会盖住新页面。
func _open_midi_view() -> void:
	var hash_str := str(_item.get("hash", ""))
	if hash_str.is_empty():
		return
	var midi: MidiData = DataMGR.get_midi_by_id(hash_str)
	if midi == null:
		GLogger.warning("谱面已标记本地可用但曲库查不到: %s" % hash_str, "ChartDetailPage")
		return
	open_requested.emit(_item)
	if PopupWindow.instance != null and is_instance_valid(PopupWindow.instance):
		PopupWindow.instance.close_chart_detail()
	if not midi.album_id.is_empty() and not midi.song_id.is_empty():
		UiStatMGR.navigate_to_album_song(midi.album_id, midi.song_id, midi.id)
		if UiStatMGR.current_state != UIStateManager.UIState.MIDI_VIEW:
			UiStatMGR.change_state(UIStateManager.UIState.MIDI_VIEW)
			EvtBus.emit_midi_selected(midi.id, midi)
	else:
		UiStatMGR.change_state(UIStateManager.UIState.MIDI_VIEW)
		EvtBus.emit_midi_selected(midi.id, midi)

# ── 主题 ──────────────────────────────────────────────

func apply_theme() -> void:
	if not ThemeMGR:
		return
	var surface_low := ThemeMGR.get_color("surface_low")
	var surface_high := ThemeMGR.get_color("surface_high")
	var border := ThemeMGR.get_color("border")
	var primary := ThemeMGR.get_color("primary")
	var is_light := ThemeMGR.get_appearance() == "light"
	var muted_text := ThemeMGR.get_color("text_secondary") if is_light else ThemeMGR.get_color("text_dim")

	var cover_sb: StyleBoxFlat = %CoverWrap.get_theme_stylebox("panel")
	cover_sb.bg_color = surface_high if is_light else surface_low
	cover_sb.border_color = border

	var rank_sb: StyleBoxFlat = %RankBox.get_theme_stylebox("panel")
	rank_sb.bg_color = surface_low
	rank_sb.border_color = ThemeMGR.get_color("border_soft")

	# Sub / SizeLabel / DownloadsCount / PlaysCount 走 LabelMuted 变体、
	# RankTitle 走 LabelAccent 变体（字色在主题里按明暗模式统一给）
	%Desc.add_theme_color_override("default_color", ThemeMGR.get_color("text_secondary"))
	%Placeholder.modulate = muted_text
	%Placeholder.modulate.a = 0.4
	for icon in %Stats.find_children("*", "TextureRect", true, false):
		(icon as TextureRect).modulate = muted_text

	# 赞踩按钮的字色
	for btn: Button in [%LikeBtn, %DislikeBtn]:
		btn.add_theme_color_override("font_color", ThemeMGR.get_color("text_secondary"))
		btn.add_theme_color_override("font_hover_color", ThemeMGR.get_color("text_primary"))
		btn.add_theme_color_override("icon_normal_color", ThemeMGR.get_color("text_secondary"))
		btn.add_theme_color_override("icon_hover_color", ThemeMGR.get_color("text_primary"))
		btn.add_theme_color_override("icon_pressed_color", primary)
		btn.add_theme_color_override("icon_disabled_color", muted_text)

	# 下载按钮：六态样式与白字白图标全在 ButtonDownload* 变体里，这里只需按状态切换变体
	_apply_download_state()

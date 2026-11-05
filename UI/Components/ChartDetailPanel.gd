## 谱面详情弹窗（通用组件）：从列表项矩形「放大」成整块面板，关闭时缩回。
##
## 结构：左上封面 + 封面下的排行榜 / 右上简介 + 底部统计与操作按钮。
## 打开/关闭动画、封面与排行榜拉取、角按钮离台、返回键消费、跳 MIDI_VIEW 都在组件内完成，
## 宿主只需 open(item, source_rect) 并按需接下面三个信号；任何视图都能直接实例化本场景。
##
## Mode.STORE   商店：按钮承载下载状态机，未下载时发 download_requested 交由宿主处理
## Mode.LIBRARY 曲库 / 游玩记录等非商店入口：不发起下载，仅当谱面在本地时提供跳转
class_name ChartDetailPanel
extends Control

const StoreIconsLib := preload("res://UI/Views/StoreView/StoreIcons.gd")

signal download_requested(item: Dictionary)
## 即将跳转 MIDI_VIEW 时通知宿主（跳转本身由组件完成，宿主无需再实现）
signal open_requested(item: Dictionary)
signal closed

enum Mode { STORE, LIBRARY }

const DETAIL_SIZE := Vector2(1280, 760)

var _item: Dictionary = {}
var _mode: int = Mode.STORE
var _open := false
var _source_rect := Rect2()
var _open_target_rect := Rect2()
var _cover_version := 0
var _req_version := 0

func _ready() -> void:
	visible = false
	%Panel.pivot_offset = Vector2.ZERO
	%CloseBtn.pressed.connect(close)
	%DownloadBtn.pressed.connect(_on_download_pressed)
	%Dim.gui_input.connect(_on_dim_input)
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()


func is_open() -> bool:
	return _open


## 从列表项矩形展开到居中的详情面板。source_rect 为源节点的全局矩形。
## p_mode 决定底部按钮语义，见文件头 Mode 说明。
##
## 用「整块面板缩放」而不是「改面板尺寸」做展开：
##   面板始终按目标尺寸布局（子节点不重排、文本不回流），只把 offset_transform 的
##   位置/缩放从卡片矩形补到零。这样动画期间内容不会溢出面板、也没有每帧重排的开销。
func open(p_item: Dictionary, source_rect: Rect2, p_mode: int = Mode.STORE) -> void:
	_req_version += 1
	_item = p_item
	_mode = p_mode
	# 右下 / 左上全局角按钮 z_index 高于本层，打开期间先播退场移开
	_set_nav_buttons_hidden(true)
	# 卡片矩形是全局坐标；本层铺满宿主视图，换算成本层局部坐标后才能做共享元素动画
	var origin := get_global_rect().position
	_source_rect = Rect2(source_rect.position - origin, source_rect.size)
	# 目标矩形先算出来：下面要用它判断源矩形是不是「宽条」
	var target := _target_rect()
	# 下载管理行是整行宽的（约 1800x84），直接拿整行矩形做起点会让面板从左边缘飞进来。
	# 对这种过宽的源矩形，围绕「被点行的中心」收成紧凑卡片大小再展开。
	var target_aspect := target.size.x / maxf(target.size.y, 1.0)
	var source_aspect := _source_rect.size.x / maxf(_source_rect.size.y, 1.0)
	if source_aspect > target_aspect * 1.8:
		var compact_w := minf(_source_rect.size.x, target.size.x * 0.45)
		var compact_h := maxf(compact_w / target_aspect, 120.0)
		var compact_center := _source_rect.get_center()
		_source_rect = Rect2(compact_center - Vector2(compact_w, compact_h) * 0.5,
			Vector2(compact_w, compact_h))

	_open = true
	visible = true
	%Dim.color = Color(0, 0, 0, 0)
	%Content.modulate.a = 0.15
	_open_target_rect = target
	%Panel.position = target.position
	%Panel.size = target.size
	%Panel.pivot_offset = Vector2.ZERO
	%Panel.offset_transform_enabled = true
	%Panel.offset_transform_visual_only = false
	%Panel.offset_transform_position = _source_rect.position - target.position
	%Panel.offset_transform_scale = Vector2(
		maxf(_source_rect.size.x / maxf(target.size.x, 1.0), 0.01),
		maxf(_source_rect.size.y / maxf(target.size.y, 1.0), 0.01)
	)

	_fill_content()
	_load_cover()
	_load_rank()

	var tw := AniMGR.create_managed_tween(%Panel, "store_detail_anim")
	if tw == null:
		_finish_open(target)
		return
	tw.set_parallel(true)
	tw.tween_property(%Dim, "color:a", 0.62, 0.22).set_trans(Tween.TRANS_CUBIC)
	tw.tween_property(%Panel, "offset_transform_position", Vector2.ZERO, 0.34) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(%Panel, "offset_transform_scale", Vector2.ONE, 0.34) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(%Content, "modulate:a", 1.0, 0.28) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	%CloseBtn.grab_focus.call_deferred()


func _finish_open(target: Rect2) -> void:
	%Dim.color.a = 0.62
	%Panel.position = target.position
	%Panel.size = target.size
	%Panel.offset_transform_position = Vector2.ZERO
	%Panel.offset_transform_scale = Vector2.ONE
	%Content.modulate.a = 1.0


func close() -> void:
	if not _open:
		return
	_open = false
	_req_version += 1
	var target := _open_target_rect
	if target.size.x <= 0.0:
		target = _target_rect()
	var tw := AniMGR.create_managed_tween(%Panel, "store_detail_anim")
	if tw == null:
		_finish_close()
		return
	tw.set_parallel(true)
	tw.tween_property(%Dim, "color:a", 0.0, 0.18).set_trans(Tween.TRANS_CUBIC)
	tw.tween_property(%Content, "modulate:a", 0.0, 0.12)
	tw.tween_property(%Panel, "offset_transform_position",
		_source_rect.position - target.position, 0.24) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tw.tween_property(%Panel, "offset_transform_scale", Vector2(
		maxf(_source_rect.size.x / maxf(target.size.x, 1.0), 0.01),
		maxf(_source_rect.size.y / maxf(target.size.y, 1.0), 0.01)
	), 0.24).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(_finish_close)


func _finish_close() -> void:
	visible = false
	%Panel.position = Vector2.ZERO
	%Panel.size = DETAIL_SIZE
	%Panel.offset_transform_position = Vector2.ZERO
	%Panel.offset_transform_scale = Vector2.ONE
	_set_nav_buttons_hidden(false)
	closed.emit()


## 立即收起（不播动画）：跳转视图后兜底，宿主未关时避免详情残留
func _close_now() -> void:
	if not _open:
		return
	_open = false
	_req_version += 1
	_finish_close()


## 宿主的全局返回键钩子：详情打开时先关详情，返回 true 表示事件已被消费
func handle_back_request() -> bool:
	if not _open:
		return false
	close()
	return true


## 模态离台 / 回台交给角按钮自己的位移补间，直接改 visible 会突兀消失
func _set_nav_buttons_hidden(need_hidden: bool) -> void:
	for btn in [GlobalNodes.rb_btn, GlobalNodes.lt_btn]:
		if is_instance_valid(btn) and btn.has_method("set_modal_hidden"):
			btn.set_modal_hidden(need_hidden)


func _target_rect() -> Rect2:
	var limit := size - Vector2(60, 60)
	var target_size := Vector2(minf(DETAIL_SIZE.x, limit.x), minf(DETAIL_SIZE.y, limit.y))
	var pos := (size - target_size) * 0.5
	return Rect2(pos, target_size)


# ── 内容 ──────────────────────────────────────────────

func _fill_content() -> void:
	var title := str(_item.get("title", "未命名")).strip_edges()
	%Title.set_scroll_text(title if not title.is_empty() else "未命名")
	%Kind.text = _kind_text()
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
	%Divider.visible = is_song
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
	var url := str(_item.get("cover_url", ""))
	if url.is_empty():
		return
	HttpImageLoader.load(url, self, func(tex: Texture2D) -> void:
		if not is_instance_valid(self) or version != _cover_version:
			return
		if tex:
			%Cover.texture = tex
			%Placeholder.visible = false
	)


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
	if not _open or version != _req_version:
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

func refresh_download_state() -> void:
	if _open and str(_item.get("kind", "")) == "song":
		_apply_download_state()


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

	var hash_str := str(_item.get("hash", ""))
	var state := int(_item.get("state", ResourceManager.DownloadState.NOT_DOWNLOADED))
	if not hash_str.is_empty():
		state = ResourceManager.instance.get_download_state(hash_str)
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
	var state := int(_item.get("state", ResourceManager.DownloadState.NOT_DOWNLOADED))
	var hash_str := str(_item.get("hash", ""))
	if not hash_str.is_empty():
		state = ResourceManager.instance.get_download_state(hash_str)
	if state == ResourceManager.DownloadState.DOWNLOADING:
		return
	if state == ResourceManager.DownloadState.DOWNLOADED:
		_open_midi_view()
		return
	download_requested.emit(_item)


## 按 hash 反查本地曲库后进 MIDI_VIEW。有专辑 / 歌曲归属时走标准导航，
## 让 MidiView 带出同歌曲的其它谱面并把返回链落在歌曲 / 专辑层级；
## 归属失效时退回直达路径，保证点击一定有响应
func _open_midi_view() -> void:
	var hash_str := str(_item.get("hash", ""))
	if hash_str.is_empty():
		return
	var midi: MidiData = DataMGR.get_midi_by_id(hash_str)
	if midi == null:
		GLogger.warning("谱面已标记本地可用但曲库查不到: %s" % hash_str, "ChartDetailPanel")
		return
	open_requested.emit(_item)
	if not midi.album_id.is_empty() and not midi.song_id.is_empty():
		UiStatMGR.navigate_to_album_song(midi.album_id, midi.song_id, midi.id)
		if UiStatMGR.current_state != UIStateManager.UIState.MIDI_VIEW:
			UiStatMGR.change_state(UIStateManager.UIState.MIDI_VIEW)
			EvtBus.emit_midi_selected(midi.id, midi)
	else:
		UiStatMGR.change_state(UIStateManager.UIState.MIDI_VIEW)
		EvtBus.emit_midi_selected(midi.id, midi)
	# 收起放到帧末：宿主在状态切换时已自行关闭，这里只兜底没有关闭机制的第三方使用方
	_close_now.call_deferred()


func _on_dim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		close()


# ── 主题 ──────────────────────────────────────────────

func apply_theme() -> void:
	if not ThemeMGR:
		return
	var surface := ThemeMGR.get_color("surface")
	var surface_low := ThemeMGR.get_color("surface_low")
	var surface_high := ThemeMGR.get_color("surface_high")
	var border := ThemeMGR.get_color("border")
	var primary := ThemeMGR.get_color("primary")
	var primary_light := ThemeMGR.get_color("primary_light")
	var primary_dark := ThemeMGR.get_color("primary_dark")
	var is_light := ThemeMGR.get_appearance() == "light"
	var accent_text := primary_dark if is_light else primary_light
	var muted_text := ThemeMGR.get_color("text_secondary") if is_light else ThemeMGR.get_color("text_dim")

	var bg_sb: StyleBoxFlat = %BG.get_theme_stylebox("panel")
	bg_sb.bg_color = ThemeMGR._tint_keep_alpha(surface, 0.98)
	bg_sb.border_color = ThemeMGR._tint_keep_alpha(primary, 0.55 if is_light else 0.45)
	bg_sb.shadow_color = Color(0, 0, 0, 0.45 if is_light else 0.55)

	%Accent.get_theme_stylebox("panel").bg_color = accent_text

	var cover_sb: StyleBoxFlat = %CoverWrap.get_theme_stylebox("panel")
	cover_sb.bg_color = surface_high if is_light else surface_low
	cover_sb.border_color = border

	var rank_sb: StyleBoxFlat = %RankBox.get_theme_stylebox("panel")
	rank_sb.bg_color = surface_low
	rank_sb.border_color = ThemeMGR.get_color("border_soft")

	# Kind / Date / SizeLabel / DownloadsCount / PlaysCount 走 LabelMuted 变体、
	# RankTitle 走 LabelAccent 变体（字色在主题里按明暗模式统一给）
	%Desc.add_theme_color_override("default_color", ThemeMGR.get_color("text_secondary"))
	%Placeholder.modulate = muted_text
	%Placeholder.modulate.a = 0.4
	for icon in %Stats.find_children("*", "TextureRect", true, false):
		(icon as TextureRect).modulate = muted_text

	# 详情里的按钮样式按主题重新着色（与卡片独立的资源，直接改色安全）
	for btn in [%CloseBtn]:
		var btn_sb: StyleBoxFlat = (btn as Button).get_theme_stylebox("normal")
		btn_sb.bg_color = surface_low
		btn_sb.border_color = border
		var hover_sb: StyleBoxFlat = (btn as Button).get_theme_stylebox("hover")
		hover_sb.bg_color = ThemeMGR.get_color("surface_hover")
		hover_sb.border_color = primary

	# 关闭按钮/赞踩按钮的图标是白色贴图：浅色模式下不染色会直接消失
	%CloseBtn.add_theme_color_override("icon_normal_color", ThemeMGR.get_color("text_secondary"))
	%CloseBtn.add_theme_color_override("icon_hover_color", ThemeMGR.get_color("text_primary"))
	%CloseBtn.add_theme_color_override("icon_pressed_color", primary)
	%CloseBtn.add_theme_color_override("icon_focus_color", primary)
	for btn: Button in [%LikeBtn, %DislikeBtn]:
		btn.add_theme_color_override("font_color", ThemeMGR.get_color("text_secondary"))
		btn.add_theme_color_override("font_hover_color", ThemeMGR.get_color("text_primary"))
		btn.add_theme_color_override("icon_normal_color", ThemeMGR.get_color("text_secondary"))
		btn.add_theme_color_override("icon_hover_color", ThemeMGR.get_color("text_primary"))
		btn.add_theme_color_override("icon_pressed_color", primary)
		btn.add_theme_color_override("icon_disabled_color", muted_text)

	# 下载按钮：六态样式与白字白图标全在 ButtonDownload* 变体里，这里只需按状态切换变体

	_apply_download_state()


func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)

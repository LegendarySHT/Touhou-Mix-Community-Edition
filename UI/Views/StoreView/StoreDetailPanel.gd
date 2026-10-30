## 商店详情弹窗：从卡片矩形“放大”成整块面板（共享元素展开动画），关闭时缩回卡片。
##
## 结构：左上封面 + 封面下的排行榜 / 右上简介 + 底部点赞与下载操作。
## 歌曲的排行榜与下载状态取真实服务；皮肤/特效/音源等本地分类条目走「资源信息」占位，
## 详情布局与动画完全一致。
class_name StoreDetailPanel
extends Control

const StoreIconsLib := preload("res://UI/Views/StoreView/StoreIcons.gd")

signal download_requested(item: Dictionary)
signal closed

const DETAIL_SIZE := Vector2(1280, 760)

var _item: Dictionary = {}
var _open := false
var _source_rect := Rect2()
var _open_target_rect := Rect2()
var _cover_version := 0
var _req_version := 0

var _dl_normal: StyleBoxFlat
var _dl_hover: StyleBoxFlat
var _dl_pressed: StyleBoxFlat
var _dl_disabled: StyleBoxFlat
var _dl_focus: StyleBoxFlat

@onready var _dim: ColorRect = $Dim
@onready var _panel: Control = $Panel
@onready var _bg: Panel = $Panel/BG
@onready var _accent: Panel = $Panel/Accent
@onready var _content: VBoxContainer = $Panel/Margin/VBox
@onready var _title: Label = $Panel/Margin/VBox/Header/Title
@onready var _kind: Label = $Panel/Margin/VBox/Header/Kind
@onready var _close_btn: Button = $Panel/Margin/VBox/Header/CloseBtn
@onready var _cover: RoundedTextureRect = $Panel/Margin/VBox/Body/LeftCol/CoverWrap/Cover
@onready var _cover_placeholder: TextureRect = $Panel/Margin/VBox/Body/LeftCol/CoverWrap/Placeholder
@onready var _cover_wrap: Panel = $Panel/Margin/VBox/Body/LeftCol/CoverWrap
@onready var _rank_box: PanelContainer = $Panel/Margin/VBox/Body/LeftCol/RankBox
@onready var _rank_title: Label = $Panel/Margin/VBox/Body/LeftCol/RankBox/RankMargin/RankCol/RankTitle
@onready var _rank_list: VBoxContainer = $Panel/Margin/VBox/Body/LeftCol/RankBox/RankMargin/RankCol/RankList
@onready var _sub: Label = $Panel/Margin/VBox/Body/RightCol/Sub
@onready var _desc: RichTextLabel = $Panel/Margin/VBox/Body/RightCol/Desc
@onready var _stats: HBoxContainer = $Panel/Margin/VBox/Body/RightCol/Stats
@onready var _divider: ColorRect = $Panel/Margin/VBox/Body/RightCol/Divider
@onready var _like_btn: Button = $Panel/Margin/VBox/Body/RightCol/Stats/LikeBtn
@onready var _dislike_btn: Button = $Panel/Margin/VBox/Body/RightCol/Stats/DislikeBtn
@onready var _downloads_count: Label = $Panel/Margin/VBox/Body/RightCol/Stats/Downloads/Count
@onready var _plays_count: Label = $Panel/Margin/VBox/Body/RightCol/Stats/Plays/Count
@onready var _date_label: Label = $Panel/Margin/VBox/Body/RightCol/Stats/Date
@onready var _size_label: Label = $Panel/Margin/VBox/Body/RightCol/Actions/SizeLabel
@onready var _download_btn: Button = $Panel/Margin/VBox/Body/RightCol/Actions/DownloadBtn


func _ready() -> void:
	visible = false
	_panel.pivot_offset = Vector2.ZERO
	# 下载按钮的状态色随当前谱面状态变化，必须实例独立（场景子资源默认共享）
	_dl_normal = _duplicate_stylebox(_download_btn, "normal")
	_dl_hover = _duplicate_stylebox(_download_btn, "hover")
	_dl_pressed = _duplicate_stylebox(_download_btn, "pressed")
	_dl_disabled = _duplicate_stylebox(_download_btn, "disabled")
	_dl_focus = _duplicate_stylebox(_download_btn, "focus")
	if _dl_normal:
		_download_btn.add_theme_stylebox_override("normal", _dl_normal)
	if _dl_hover:
		_download_btn.add_theme_stylebox_override("hover", _dl_hover)
	if _dl_pressed:
		_download_btn.add_theme_stylebox_override("pressed", _dl_pressed)
	if _dl_disabled:
		_download_btn.add_theme_stylebox_override("disabled", _dl_disabled)
	if _dl_focus:
		_download_btn.add_theme_stylebox_override("focus", _dl_focus)

	_close_btn.pressed.connect(close)
	_download_btn.pressed.connect(_on_download_pressed)
	_dim.gui_input.connect(_on_dim_input)
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()


func _duplicate_stylebox(btn: Button, state: String) -> StyleBoxFlat:
	var sb := btn.get_theme_stylebox(state) as StyleBoxFlat
	return sb.duplicate() as StyleBoxFlat if sb else null


func is_open() -> bool:
	return _open


## 从卡片矩形展开到居中的详情面板。source_rect 为卡片的全局矩形（本层与商店同坐标）
##
## 用「整块面板缩放」而不是「改面板尺寸」做展开：
##   面板始终按目标尺寸布局（子节点不重排、文本不回流），只把 offset_transform 的
##   位置/缩放从卡片矩形补到零。这样动画期间内容不会溢出面板、也没有每帧重排的开销。
func open(p_item: Dictionary, source_rect: Rect2) -> void:
	_req_version += 1
	_item = p_item
	# 卡片矩形是全局坐标；本层铺满商店，换算成本层局部坐标后才能做共享元素动画
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
	_dim.color = Color(0, 0, 0, 0)
	_content.modulate.a = 0.15
	_open_target_rect = target
	_panel.position = target.position
	_panel.size = target.size
	_panel.pivot_offset = Vector2.ZERO
	_panel.offset_transform_enabled = true
	_panel.offset_transform_visual_only = false
	_panel.offset_transform_position = _source_rect.position - target.position
	_panel.offset_transform_scale = Vector2(
		maxf(_source_rect.size.x / maxf(target.size.x, 1.0), 0.01),
		maxf(_source_rect.size.y / maxf(target.size.y, 1.0), 0.01)
	)

	_fill_content()
	_load_cover()
	_load_rank()

	var tw := AniMGR.create_managed_tween(_panel, "store_detail_anim")
	if tw == null:
		_finish_open(target)
		return
	tw.set_parallel(true)
	tw.tween_property(_dim, "color:a", 0.62, 0.22).set_trans(Tween.TRANS_CUBIC)
	tw.tween_property(_panel, "offset_transform_position", Vector2.ZERO, 0.34) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(_panel, "offset_transform_scale", Vector2.ONE, 0.34) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(_content, "modulate:a", 1.0, 0.28) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_close_btn.grab_focus.call_deferred()


func _finish_open(target: Rect2) -> void:
	_dim.color.a = 0.62
	_panel.position = target.position
	_panel.size = target.size
	_panel.offset_transform_position = Vector2.ZERO
	_panel.offset_transform_scale = Vector2.ONE
	_content.modulate.a = 1.0


func close() -> void:
	if not _open:
		return
	_open = false
	_req_version += 1
	var target := _open_target_rect
	if target.size.x <= 0.0:
		target = _target_rect()
	var tw := AniMGR.create_managed_tween(_panel, "store_detail_anim")
	if tw == null:
		_finish_close()
		return
	tw.set_parallel(true)
	tw.tween_property(_dim, "color:a", 0.0, 0.18).set_trans(Tween.TRANS_CUBIC)
	tw.tween_property(_content, "modulate:a", 0.0, 0.12)
	tw.tween_property(_panel, "offset_transform_position",
		_source_rect.position - target.position, 0.24) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tw.tween_property(_panel, "offset_transform_scale", Vector2(
		maxf(_source_rect.size.x / maxf(target.size.x, 1.0), 0.01),
		maxf(_source_rect.size.y / maxf(target.size.y, 1.0), 0.01)
	), 0.24).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(_finish_close)


func _finish_close() -> void:
	visible = false
	_panel.position = Vector2.ZERO
	_panel.size = DETAIL_SIZE
	_panel.offset_transform_position = Vector2.ZERO
	_panel.offset_transform_scale = Vector2.ONE
	closed.emit()


func _target_rect() -> Rect2:
	var limit := size - Vector2(60, 60)
	var target_size := Vector2(minf(DETAIL_SIZE.x, limit.x), minf(DETAIL_SIZE.y, limit.y))
	var pos := (size - target_size) * 0.5
	return Rect2(pos, target_size)


# ── 内容 ──────────────────────────────────────────────

func _fill_content() -> void:
	var title := str(_item.get("title", "未命名")).strip_edges()
	_title.set_scroll_text(title if not title.is_empty() else "未命名")
	_kind.text = _kind_text()
	_sub.set_scroll_text(_subtitle())

	var desc := str(_item.get("desc", "")).strip_edges()
	if desc.is_empty():
		desc = _desc_fallback()
	_desc.text = ""
	_desc.add_text(desc)

	var downloads := int(_item.get("downloads", -1))
	var plays := int(_item.get("plays", -1))
	var likes := int(_item.get("likes", -1))
	var dislikes := int(_item.get("dislikes", -1))
	_downloads_count.text = StoreIconsLib.format_count(downloads)
	_plays_count.text = StoreIconsLib.format_count(plays)
	_like_btn.text = "  " + StoreIconsLib.format_count(likes)
	_dislike_btn.text = "  " + StoreIconsLib.format_count(dislikes)
	var is_song := str(_item.get("kind", "")) == "song"
	# 分类资源没有在线点赞/游玩统计：整行统计隐藏，信息由左下「资源信息」承担
	_stats.visible = is_song
	_divider.visible = is_song
	_like_btn.visible = is_song
	_dislike_btn.visible = is_song
	_like_btn.disabled = not is_song
	_dislike_btn.disabled = not is_song

	var uploaded := str(_item.get("uploaded_at", ""))
	if uploaded.is_empty():
		_date_label.text = ""
	else:
		_date_label.text = "上传于 " + uploaded.replace("T", " ").substr(0, 16)

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
	_size_label.text = ("文件 " + size_text) if size_bytes > 0 else size_text
	if not extra.is_empty():
		_size_label.text += "  ·  " + "  ·  ".join(extra)

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
	_cover.texture = null
	_cover_placeholder.visible = true
	_cover_placeholder.texture = _kind_icon()
	var local_tex = _item.get("cover_tex")
	if local_tex is Texture2D:
		_cover.texture = local_tex
		_cover_placeholder.visible = false
		return
	var url := str(_item.get("cover_url", ""))
	if url.is_empty():
		return
	HttpImageLoader.load(url, self, func(tex: Texture2D) -> void:
		if not is_instance_valid(self) or version != _cover_version:
			return
		if tex:
			_cover.texture = tex
			_cover_placeholder.visible = false
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
		_rank_title.text = "资源信息"
		_add_info_row("类型", _kind_text())
		_add_info_row("大小", StoreIconsLib.format_size(int(_item.get("size_bytes", 0))) \
			if int(_item.get("size_bytes", 0)) > 0 else str(_item.get("size_text", "—")))
		_add_info_row("来源", "本地已安装" if bool(_item.get("is_builtin", false)) else "本地资源")
		return

	_rank_title.text = "排行榜"
	var hash := str(_item.get("hash", ""))
	if hash.is_empty() or NetManager.instance == null or not NetManager.instance.is_online \
			or ScoreManager.instance == null:
		_add_rank_message("暂无排行数据")
		return
	_add_rank_message("加载中…")
	var result: Dictionary = await ScoreManager.instance.get_leaderboard(hash, 5, 0)
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
	for child in _rank_list.get_children():
		_rank_list.remove_child(child)
		child.queue_free()


func _add_rank_message(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 20)
	var is_light := ThemeMGR != null and ThemeMGR.get_appearance() == "light"
	label.add_theme_color_override("font_color",
		ThemeMGR.get_color("text_secondary") if is_light \
		else (ThemeMGR.get_color("text_dim") if ThemeMGR else Color(0.6, 0.65, 0.72)))
	_rank_list.add_child(label)


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

	_rank_list.add_child(row)


func _add_info_row(key: String, value: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	var key_label := Label.new()
	key_label.text = key
	key_label.custom_minimum_size = Vector2(56, 0)
	key_label.add_theme_font_size_override("font_size", 20)
	var is_light := ThemeMGR != null and ThemeMGR.get_appearance() == "light"
	key_label.add_theme_color_override("font_color",
		ThemeMGR.get_color("text_secondary") if is_light \
		else (ThemeMGR.get_color("text_dim") if ThemeMGR else Color(0.6, 0.65, 0.72)))
	row.add_child(key_label)
	var value_label := Label.new()
	value_label.text = value
	value_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value_label.clip_text = true
	value_label.add_theme_font_size_override("font_size", 20)
	value_label.add_theme_color_override("font_color",
		ThemeMGR.get_color("text_primary") if is_light \
		else (ThemeMGR.get_color("text_secondary") if ThemeMGR else Color(0.8, 0.84, 0.9)))
	row.add_child(value_label)
	_rank_list.add_child(row)


# ── 下载状态 ──────────────────────────────────────────

func refresh_download_state() -> void:
	if _open and str(_item.get("kind", "")) == "song":
		_apply_download_state()


func _apply_download_state() -> void:
	if not is_inside_tree():
		return
	var is_song := str(_item.get("kind", "")) == "song"
	if not is_song:
		_download_btn.text = "已安装"
		_download_btn.icon = StoreIconsLib.check()
		_download_btn.disabled = true
		_set_download_colors(ThemeMGR.get_color("success") if ThemeMGR else Color("#2FA66A"))
		return

	var hash := str(_item.get("hash", ""))
	var state := int(_item.get("state", ResourceManager.DownloadState.NOT_DOWNLOADED))
	if ResMGR != null and not hash.is_empty():
		state = ResMGR.get_download_state(hash)
	var base := ThemeMGR.get_color("primary") if ThemeMGR else Color("#2E55C8")
	var icon: Texture2D = StoreIconsLib.download()
	var text := "下载谱面"
	_download_btn.disabled = false
	match state:
		ResourceManager.DownloadState.DOWNLOADING:
			base = ThemeMGR.get_color("warning") if ThemeMGR else Color("#D89A2A")
			icon = StoreIconsLib.download_cloud()
			text = "正在下载…"
		ResourceManager.DownloadState.DOWNLOADED:
			base = ThemeMGR.get_color("success") if ThemeMGR else Color("#2FA66A")
			icon = StoreIconsLib.check()
			text = "已下载"
		ResourceManager.DownloadState.FAILED:
			base = ThemeMGR.get_color("danger") if ThemeMGR else Color("#C7303F")
			icon = StoreIconsLib.close()
			text = "重试下载"
	_download_btn.text = text
	_download_btn.icon = icon
	_set_download_colors(base)


func _set_download_colors(base: Color) -> void:
	if _dl_normal:
		_dl_normal.bg_color = ThemeMGR._tint_keep_alpha(base.darkened(0.15), 0.92) \
			if ThemeMGR else base.darkened(0.15)
		_dl_normal.border_color = base.lightened(0.35)
	if _dl_hover:
		_dl_hover.bg_color = base
		_dl_hover.border_color = base.lightened(0.55)
	if _dl_pressed:
		_dl_pressed.bg_color = base.darkened(0.22)
		_dl_pressed.border_color = base
	if _dl_focus:
		var light := ThemeMGR != null and ThemeMGR.get_appearance() == "light"
		_dl_focus.border_color = base.darkened(0.08) if light else base.lightened(0.5)
		_dl_focus.shadow_color = Color(base.r, base.g, base.b, 0.4)


func _on_download_pressed() -> void:
	var state := int(_item.get("state", ResourceManager.DownloadState.NOT_DOWNLOADED))
	var hash := str(_item.get("hash", ""))
	if ResMGR != null and not hash.is_empty():
		state = ResMGR.get_download_state(hash)
	if str(_item.get("kind", "")) != "song" \
			or state == ResourceManager.DownloadState.DOWNLOADED \
			or state == ResourceManager.DownloadState.DOWNLOADING:
		return
	download_requested.emit(_item)


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
	var muted_text := ThemeMGR.get_color("text_secondary") if is_light \
		else ThemeMGR.get_color("text_dim")

	var bg_sb := _bg.get_theme_stylebox("panel") as StyleBoxFlat
	if bg_sb:
		bg_sb.bg_color = ThemeMGR._tint_keep_alpha(surface, 0.98)
		bg_sb.border_color = ThemeMGR._tint_keep_alpha(primary, 0.55 if is_light else 0.45)
		bg_sb.shadow_color = Color(0, 0, 0, 0.45 if is_light else 0.55)
	var accent_sb := _accent.get_theme_stylebox("panel") as StyleBoxFlat
	if accent_sb:
		accent_sb.bg_color = accent_text

	var cover_sb := _cover_wrap.get_theme_stylebox("panel") as StyleBoxFlat
	if cover_sb:
		cover_sb.bg_color = surface_high if is_light else surface_low
		cover_sb.border_color = border
	var rank_sb := _rank_box.get_theme_stylebox("panel") as StyleBoxFlat
	if rank_sb:
		rank_sb.bg_color = surface_low
		rank_sb.border_color = ThemeMGR.get_color("border_soft")

	_kind.add_theme_color_override("font_color", muted_text)
	_desc.add_theme_color_override("default_color", ThemeMGR.get_color("text_secondary"))
	_date_label.add_theme_color_override("font_color", muted_text)
	_size_label.add_theme_color_override("font_color", muted_text)
	_downloads_count.add_theme_color_override("font_color", muted_text)
	_plays_count.add_theme_color_override("font_color", muted_text)
	_rank_title.add_theme_color_override("font_color", accent_text)
	_cover_placeholder.modulate = muted_text
	_cover_placeholder.modulate.a = 0.4
	for icon in _stats.find_children("*", "TextureRect", true, false):
		(icon as TextureRect).modulate = muted_text

	# 详情里的按钮样式按主题重新着色（与卡片独立的资源，直接改色安全）
	for btn in [_close_btn]:
		var btn_sb := (btn as Button).get_theme_stylebox("normal") as StyleBoxFlat
		if btn_sb:
			btn_sb.bg_color = surface_low
			btn_sb.border_color = border
		var hover_sb := (btn as Button).get_theme_stylebox("hover") as StyleBoxFlat
		if hover_sb:
			hover_sb.bg_color = ThemeMGR.get_color("surface_hover")
			hover_sb.border_color = primary
	# 关闭按钮/赞踩按钮的图标是白色贴图：浅色模式下不染色会直接消失
	_close_btn.add_theme_color_override("icon_normal_color", ThemeMGR.get_color("text_secondary"))
	_close_btn.add_theme_color_override("icon_hover_color", ThemeMGR.get_color("text_primary"))
	_close_btn.add_theme_color_override("icon_pressed_color", primary)
	_close_btn.add_theme_color_override("icon_focus_color", primary)
	for btn in [_like_btn, _dislike_btn]:
		var b := btn as Button
		b.add_theme_color_override("font_color", ThemeMGR.get_color("text_secondary"))
		b.add_theme_color_override("font_hover_color", ThemeMGR.get_color("text_primary"))
		b.add_theme_color_override("icon_normal_color", ThemeMGR.get_color("text_secondary"))
		b.add_theme_color_override("icon_hover_color", ThemeMGR.get_color("text_primary"))
		b.add_theme_color_override("icon_pressed_color", primary)
		b.add_theme_color_override("icon_disabled_color", muted_text)

	# 下载按钮底色是主题色，字与图标统一白色；禁用态（本地分类）走灰底 + 深色字
	for state in ["font_color", "font_hover_color", "font_pressed_color"]:
		_download_btn.add_theme_color_override(state, Color.WHITE)
	for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color"]:
		_download_btn.add_theme_color_override(state, Color.WHITE)
	_download_btn.add_theme_color_override("font_disabled_color",
		ThemeMGR.get_color("text_secondary") if is_light else ThemeMGR.get_color("text_dim"))
	_download_btn.add_theme_color_override("icon_disabled_color",
		ThemeMGR.get_color("text_secondary") if is_light else ThemeMGR.get_color("text_dim"))
	if _dl_disabled:
		_dl_disabled.bg_color = surface_high if is_light else surface_low
		_dl_disabled.border_color = border

	_apply_download_state()


func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)

extends ListItemBase
class_name RecordListItem

## 记录列表项（ProfilePage History 页三个 tab 共用）
## 按 RecordMode 自动调整 MainInfo 显示内容与分数旁 PP 标签的可见性

## 记录列表类型（对应 History/List 的三个 tab）
enum RecordMode { RECENT, BEST, MOST }

# ========== 显示节点 ==========
@onready var cover_rect: TextureRect = $HBox/Cover
@onready var midi_name_label: Label = $HBox/Info/MidiName
@onready var midi_author_label: Label = $HBox/Info/MidiAuthor
@onready var date_label: Label = $HBox/Info/Date
@onready var score_label: Label = $HBox/VBox/Score/Score
@onready var pp_label: Label = $HBox/VBox/Score/PP
@onready var max_combo_label: Label = $HBox/VBox/Count/MaxCombo
@onready var perfect_label: Label = $HBox/VBox/Count/Perfect
@onready var great_label: Label = $HBox/VBox/Count/Great
@onready var bad_label: Label = $HBox/VBox/Count/Bad
@onready var good_label: Label = $HBox/VBox/Count/Good
@onready var miss_label: Label = $HBox/VBox/Count/Miss
@onready var main_info_label: Label = $HBox/MainInfo

## 当前列表类型：决定 MainInfo 显示内容与 PP 标签可见性
var record_mode: int = RecordMode.RECENT
## 当前记录的 MidiHash（用于下载封面）
var _midi_hash: String = ""

func _ready() -> void:
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()

## 应用主题色：根面板随主题翻浅/翻深（否则浅色模式下会残留写死的深色卡片）
func apply_theme() -> void:
	if not ThemeMGR:
		return
	var sb := get_theme_stylebox("panel")
	if sb is StyleBoxFlat:
		sb.bg_color = ThemeMGR._tint_keep_alpha(ThemeMGR.get_color("surface_high"), sb.bg_color.a)
		sb.border_color = ThemeMGR.get_color("border_soft")

func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)

## 设置列表类型（列表加载器在 setup_record 前调用，或直接传给 setup_record 的 mode）
func set_mode(mode: int) -> void:
	record_mode = mode

## 填充一条记录
## data 字段（camelCase，与服务端 DTO 对齐）：
##   midiName / songName  谱面名
##   authorName           谱面作者
##   playedAt             游玩时间（ISO 8601 字符串）
##   totalScore / score   总分
##   pp                   pp 值
##   maxCombo             最大连击
##   perfectCount / greatCount / goodCount / badCount / missCount  各判定数
##   playCount            游玩次数（仅 MOST 模式用）
##   rank                 评级（可选，"W" = 中途退出，整体半透明）
## mode: RecordMode，传 -1 沿用 set_mode 设置的值
func setup_record(data: Dictionary, mode: int = -1) -> void:
	if mode >= 0:
		record_mode = mode

	_midi_hash = str(data.get("midiHash", ""))

	midi_name_label.set_scroll_text(_pick_str(data, ["midiName", "songName"], "—"))
	midi_author_label.set_scroll_text(_pick_str(data, ["authorName"], "—"))
	date_label.text = _format_played_at(_pick_str(data, ["playedAt"], ""))

	score_label.text = _format_number(int(_pick(data, ["totalScore", "score"], 0)))
	var pp := float(data.get("pp", 0.0))
	pp_label.text = "%.2f pp" % pp

	max_combo_label.text = str(int(data.get("maxCombo", 0)))
	perfect_label.text = str(int(data.get("perfectCount", 0)))
	great_label.text = str(int(data.get("greatCount", 0)))
	bad_label.text = str(int(data.get("badCount", 0)))
	good_label.text = str(int(data.get("goodCount", 0)))
	miss_label.text = str(int(data.get("missCount", 0)))

	# W 评级（中途退出）整体半透明
	set_withdraw_state(str(data.get("rank", "")) == "W")

	_update_main_info(pp, int(data.get("playCount", 0)))

	# 加载远程封面（仅当 Chart 存在封面时）
	if bool(data.get("hasCover", false)) and not _midi_hash.is_empty():
		_load_remote_cover(_midi_hash)

## 设置中途退出（W 评级）状态：整体半透明以区分正常完成记录
func set_withdraw_state(withdraw: bool) -> void:
	modulate.a = 0.4 if withdraw else 1.0

## 从服务端加载曲包封面（GET /api/charts/{hash}/cover）
func _load_remote_cover(chart_hash: String) -> void:
	if NetManager.instance == null or not NetManager.instance.is_online:
		return
	# 先隐藏默认封面，避免加载失败时显示占位图
	cover_rect.texture = null
	var cover_url := "%s/api/charts/%s/cover" % [NetManager.instance.server_url, chart_hash]
	HttpImageLoader.load(cover_url, self, func(tex: Texture2D) -> void:
		if not is_instance_valid(self):
			return
		if tex:
			cover_rect.texture = tex
	)

## 按 RecordMode 调整 MainInfo 显示内容与 PP 标签可见性
func _update_main_info(pp: float, play_count: int) -> void:
	match record_mode:
		RecordMode.RECENT:
			# 最近游玩：右侧不显示额外信息
			main_info_label.visible = false
			pp_label.visible = true
		RecordMode.BEST:
			# 最佳记录：分数旁不再重复显示 pp，改用 MainInfo 显示
			pp_label.visible = false
			main_info_label.visible = true
			main_info_label.text = "%.2f pp" % pp
		RecordMode.MOST:
			# 最多游玩：MainInfo 只显示游玩次数
			pp_label.visible = true
			main_info_label.visible = true
			main_info_label.text = "%d 次" % play_count

## 取 data 中第一个存在的键值（Variant）
func _pick(data: Dictionary, keys: Array, default: Variant) -> Variant:
	for k in keys:
		if data.has(k) and data[k] != null:
			return data[k]
	return default

## 取 data 中第一个存在的键值（String）
func _pick_str(data: Dictionary, keys: Array, default: String) -> String:
	return str(_pick(data, keys, default))

## 千位分隔格式化（999999999 → "999,999,999"）
func _format_number(n: int) -> String:
	var neg := n < 0
	var s := str(abs(n))
	var out := ""
	var cnt := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		cnt += 1
		if cnt % 3 == 0 and i > 0:
			out = "," + out
	return ("-" if neg else "") + out

## ISO 8601 时间 → "YYYY-MM-DD HH:MM:SS"（容忍 T/毫秒/时区后缀）
func _format_played_at(played_at: String) -> String:
	if played_at.is_empty():
		return ""
	var s := played_at.replace("T", " ")
	if s.contains("."):
		s = s.substr(0, s.find("."))
	if s.length() > 19:
		s = s.substr(0, 19)
	return s

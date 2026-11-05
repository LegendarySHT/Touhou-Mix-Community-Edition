extends ListItemBase
class_name RecordListItem

## 记录列表项（ProfileView History 页三个 tab 共用）
## 按 RecordMode 自动调整 MainInfo 显示内容与分数旁 PP 标签的可见性

## 记录列表类型（对应 History/List 的三个 tab）
enum RecordMode { RECENT, BEST, MOST }

## 点击整行：请求查看该条记录对应谱面的详情（source_rect 供展开动画，source 供关闭后还焦点）
signal detail_requested(record: Dictionary, source_rect: Rect2, source: Control)

## 当前列表类型：决定 MainInfo 显示内容与 PP 标签可见性
var record_mode: int = RecordMode.RECENT
## 当前记录的 MidiHash（用于下载封面）
var _midi_hash: String = ""
## 当前绑定的原始记录（点击时原样带回，避免从控件反查字段）
var _record: Dictionary = {}

func _ready() -> void:
	%Button.pressed.connect(_on_detail_pressed)

func _on_detail_pressed() -> void:
	detail_requested.emit(_record, get_global_rect(), %Button)

## 设置列表类型（列表加载器在 setup_record 前调用，或直接传给 setup_record 的 mode）
func set_mode(mode: int) -> void:
	record_mode = mode

## 填充一条记录
## data 字段（camelCase，与服务端 DTO 对齐）：
##   midiName / songName  谱面名
##   midiAuthor           MIDI 作者（MIG-1：原 authorName 实为 MIDI 作者，随服务端字段二合一改名）
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

	_record = data
	_midi_hash = str(data.get("midiHash", ""))

	%MidiName.set_scroll_text(_pick_str(data, ["midiName", "songName"], "—"))
	%MidiAuthor.set_scroll_text(_pick_str(data, ["midiAuthor"], "—"))
	%RecordDate.text = _format_played_at(_pick_str(data, ["playedAt"], ""))

	%Score.text = _format_number(int(_pick(data, ["totalScore", "score"], 0)))
	var pp := float(data.get("pp", 0.0))
	%PP.text = "%.2f pp" % pp

	%MaxCombo.text = str(int(data.get("maxCombo", 0)))
	%Perfect.text = str(int(data.get("perfectCount", 0)))
	%Great.text = str(int(data.get("greatCount", 0)))
	%Bad.text = str(int(data.get("badCount", 0)))
	%Good.text = str(int(data.get("goodCount", 0)))
	%Miss.text = str(int(data.get("missCount", 0)))

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
	%Cover.texture = null
	var cover_url := "%s/api/charts/%s/cover" % [NetManager.instance.server_url, chart_hash]
	HttpImageLoader.load(cover_url, self, func(tex: Texture2D) -> void:
		if not is_instance_valid(self):
			return
		if tex:
			%Cover.texture = tex
	)

## 按 RecordMode 调整 MainInfo 显示内容与 PP 标签可见性
func _update_main_info(pp: float, play_count: int) -> void:
	match record_mode:
		RecordMode.RECENT:
			# 最近游玩：右侧不显示额外信息
			%MainInfo.visible = false
			%PP.visible = true
		RecordMode.BEST:
			# 最佳记录：分数旁不再重复显示 pp，改用 MainInfo 显示
			%PP.visible = false
			%MainInfo.visible = true
			%MainInfo.text = "%.2f pp" % pp
		RecordMode.MOST:
			# 最多游玩：MainInfo 只显示游玩次数
			%PP.visible = true
			%MainInfo.visible = true
			%MainInfo.text = "%d 次" % play_count

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

extends VBoxContainer

## 结算统计区：判定卡片（Perfect/Great/Good/Bad/Miss）+ 判定构成条 + 连击 / 偏移指标卡。

const MeterBarScript := preload("res://UI/Views/ScoreView/MeterBar.gd")

## 判定顺序（与 ScoreData.count 的键、场景里五组卡片节点一一对应）
const JUDGE_KEYS: Array[String] = ["Perfect", "Great", "Good", "Bad", "Miss"]
## 判定配色（与 PlayHud / 排行榜保持同一套语义色）
const JUDGE_COLORS: Array[Color] = [
	Color("#FF50FD"),  # Perfect
	Color("#FF7600"),  # Great
	Color("#0AE000"),  # Good
	Color("#1CB0FF"),  # Bad
	Color("#DC3450"),  # Miss
]
## 数值位数偏多时降一档字号，避免撑破卡片
const CHIP_FONT_SIZE := 42
const CHIP_FONT_SIZE_SMALL := 30
const METRIC_FONT_SIZE := 25
const METRIC_FONT_SIZE_SMALL := 20
## 入场生长动画的延迟与时长（秒）
const REVEAL_DELAY := 0.25
const REVEAL_DURATION := 0.6

# ---- 数据 ----
var _counts: PackedInt32Array = PackedInt32Array([0, 0, 0, 0, 0])
var _early: int = 0
var _late: int = 0
var _max_combo: int = 0
var _total_notes: int = 0

# ---- 场景节点引用 ----
var _chips: Array[Dictionary] = []
# 两个自绘组件没有 class_name（避免依赖编辑器生成的全局类缓存），统一用 call 调其方法
var _bar: Control = null
var _combo_meter: Control = null
var _timing_meter: Control = null
var _combo_value: Label = null
var _early_value: Label = null
var _late_value: Label = null
var _total_label: Label = null
var _metric_sbs: Array[StyleBoxFlat] = []
var _captions: Array[Label] = []
## 入场生长进度：0 表示数字与比例条尚未展开
var _reveal_t: float = 1.0
var _reveal_tween: Tween = null
## 是否已取到场景节点（数据可能早于入树到达，先存着等就绪再刷）
var _bound: bool = false
## 数据是否已到达：入场动画早于 set_result 时要等数据到位再生长，否则会长成空条
var _has_data: bool = false
## 已请求但还没播放的入场动画
var _reveal_pending: bool = false


func _ready() -> void:
	_bind_nodes()
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
	apply_theme()
	_refresh_views()


func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)
	_kill_reveal()


## 取场景里的静态节点，并按判定顺序组装成易遍历的表
func _bind_nodes() -> void:
	_chips.clear()
	for i in JUDGE_KEYS.size():
		var key := JUDGE_KEYS[i]
		var chip := get_node("%" + key + "Chip") as PanelContainer
		_chips.append({
			"sb": chip.get_theme_stylebox("panel") as StyleBoxFlat,
			"dot_sb": (get_node("%" + key + "Dot") as Panel).get_theme_stylebox("panel") as StyleBoxFlat,
			"title": get_node("%" + key + "Title") as Label,
			"value": get_node("%" + key + "Value") as Label,
		})
	_bar = get_node("%Bar")
	_total_label = get_node("%TotalNotes")
	_combo_value = get_node("%Value") as Label
	_combo_meter = get_node("%ComboMeter")
	_timing_meter = get_node("%TimingMeter")
	_early_value = get_node("%EarlyLabel") as Label
	_late_value = get_node("%LateLabel") as Label

	# 指标卡底样式与说明文字：主题切换时要逐个重着色，先在场景里收齐
	_metric_sbs.clear()
	for card_name in ["ComboCard", "TimingCard"]:
		var card := get_node("%" + card_name) as PanelContainer
		_metric_sbs.append(card.get_theme_stylebox("panel") as StyleBoxFlat)
	_captions.clear()
	for scope_name in ["RatioCaption", "ComboCaption", "TimingCaption", "TimingSep"]:
		_captions.append(get_node("%" + scope_name) as Label)
	_bound = true


## 主题刷新：卡片底色/描边、判定色与文字色全部按当前调色板重算
func apply_theme() -> void:
	if not _bound or ThemeMGR == null:
		return
	var is_light := ThemeMGR.get_appearance() == "light"
	var text_primary: Color = ThemeMGR.get_color("text_primary")
	var text_dim: Color = ThemeMGR.get_color("text_dim")
	var border: Color = ThemeMGR.get_color("border")
	# 指标卡比判定卡更"沉"一层，让上方判定卡片成为视觉主体
	var metric_bg: Color = ThemeMGR.get_color("surface_low")
	for i in _chips.size():
		var chip: Dictionary = _chips[i]
		var accent := _judge_color(i, is_light)
		var sb: StyleBoxFlat = chip.sb
		# 卡片底色用判定色的淡染：深色下压得很淡（避免高饱和色块抢戏），浅色下稍浓
		sb.bg_color = Color(accent.r, accent.g, accent.b, 0.18 if is_light else 0.10)
		sb.border_color = Color(accent.r, accent.g, accent.b, 0.45 if is_light else 0.32)
		(chip.dot_sb as StyleBoxFlat).bg_color = accent
		(chip.title as Label).add_theme_color_override("font_color", accent)
		(chip.value as Label).add_theme_color_override("font_color", text_primary)
	for sb in _metric_sbs:
		sb.bg_color = Color(metric_bg.r, metric_bg.g, metric_bg.b, 0.55)
		sb.border_color = Color(border.r, border.g, border.b, 0.5 if is_light else 0.45)
	if _combo_value:
		_combo_value.add_theme_color_override("font_color", text_primary)
	# 偏移数值用计量条同款色相，浅色下压得更深以保证与浅底的对比
	if _early_value:
		_early_value.add_theme_color_override("font_color",
			MeterBarScript.EARLY_COLOR.darkened(0.45) if is_light else MeterBarScript.EARLY_COLOR)
	if _late_value:
		_late_value.add_theme_color_override("font_color",
			MeterBarScript.LATE_COLOR.darkened(0.3) if is_light else MeterBarScript.LATE_COLOR)
	for caption in _captions:
		caption.add_theme_color_override("font_color", text_dim)


## 推入本局数据。已展开过则直接显示最终值，否则交给 play_reveal() 生长。
func set_result(counts: PackedInt32Array, early: int, late: int,
		max_combo: int, total_notes: int) -> void:
	_counts = counts
	_early = early
	_late = late
	_max_combo = max_combo
	_total_notes = total_notes
	_has_data = true
	_refresh_views()
	if _reveal_pending:
		_reveal_pending = false
		play_reveal()


## 把当前数据刷进各子控件（节点就绪前调用只更新数据）
func _refresh_views() -> void:
	if not _bound:
		return
	_bar.call("set_counts", _counts)
	_combo_meter.call("set_ratio",
		0.0 if _total_notes <= 0 else float(_max_combo) / float(_total_notes))
	_timing_meter.call("set_diverging", _early, _late)
	_combo_value.text = "%d / %d" % [_max_combo, _total_notes]
	# 偏离常规量级的数字降一档字号，保证长数字不撑破卡片
	_set_font_size(_combo_value,
		METRIC_FONT_SIZE if _combo_value.text.length() <= 12 else METRIC_FONT_SIZE_SMALL)
	_early_value.text = "Early %d" % _early
	_late_value.text = "Late %d" % _late
	# 偏移两侧各占卡片一半：任一侧过长时整行一起降档，避免压到卡片描边
	var timing_len := maxi(_early_value.text.length(), _late_value.text.length())
	var timing_size := METRIC_FONT_SIZE if timing_len <= 8 else METRIC_FONT_SIZE_SMALL
	_set_font_size(_early_value, timing_size)
	_set_font_size(_late_value, timing_size)
	_total_label.text = "%d NOTES" % _total_notes
	_commit_counts(_reveal_t)


## 仅在字号真正变化时写 override，避免逐帧重复插入
func _set_font_size(label: Label, font_size: int) -> void:
	if label.get_theme_font_size("font_size") != font_size:
		label.add_theme_font_size_override("font_size", font_size)


## 入场动效：数字由 0 滚到终值，判定构成条与计量条从零生长
func play_reveal() -> void:
	if not _bound:
		return
	if not _has_data:
		# 入场动画先到：等 set_result 拿到本局数据后再生长
		_reveal_pending = true
		return
	_reveal_pending = false
	_kill_reveal()
	_reveal_t = 0.0
	_commit_counts(0.0)
	_bar.call("set_reveal", 0.0)
	_combo_meter.call("set_reveal", 0.0)
	_timing_meter.call("set_reveal", 0.0)
	_reveal_tween = create_tween()
	_reveal_tween.set_trans(Tween.TRANS_CUBIC)
	_reveal_tween.set_ease(Tween.EASE_OUT)
	# 延后启动：等底部面板自身滑入淡入接近完成，数字生长才不会被半透明位移盖住
	_reveal_tween.tween_interval(REVEAL_DELAY)
	_reveal_tween.tween_method(_apply_reveal, 0.0, 1.0, REVEAL_DURATION)


func _apply_reveal(t: float) -> void:
	_reveal_t = t
	_bar.call("set_reveal", t)
	_combo_meter.call("set_reveal", t)
	_timing_meter.call("set_reveal", t)
	_commit_counts(t)


## 直接把统计区置为完整终态
func _finish_reveal() -> void:
	_reveal_t = 1.0
	_bar.call("set_reveal", 1.0)
	_combo_meter.call("set_reveal", 1.0)
	_timing_meter.call("set_reveal", 1.0)
	_commit_counts(1.0)


## 按进度写入卡片数字；位数多的判定数降一档字号，避免撑破卡片
func _commit_counts(t: float) -> void:
	for i in _chips.size():
		var v := 0 if i >= _counts.size() else _counts[i]
		var label := _chips[i].value as Label
		label.text = str(roundi(float(v) * t))
		_set_font_size(label, CHIP_FONT_SIZE if label.text.length() <= 4 else CHIP_FONT_SIZE_SMALL)


## 结束入场动画并归位到终态（离开页面时调用，避免下次进入停在半截规模）
func stop_reveal() -> void:
	_kill_reveal()
	_finish_reveal()


func _kill_reveal() -> void:
	if _reveal_tween:
		_reveal_tween.kill()
		_reveal_tween = null


## 判定色在浅色板面上压暗两档，保证标题在淡染底上仍有对比
func _judge_color(idx: int, is_light: bool) -> Color:
	var c: Color = JUDGE_COLORS[idx] if idx < JUDGE_COLORS.size() else Color.WHITE
	return c.darkened(0.32) if is_light else c

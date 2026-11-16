## 分数计算器（唯一计分真源）
## 负责游戏中的打分、准度、PP、等级评定
## 所有计分逻辑集中于此，PlayView 和 ScoreView 仅消费快照
extends Node

class_name ScoreCalculator

## ServiceHub 服务声明：id 与依赖，注册时自动读取（见 Services/ServiceHub.gd）
const SERVICE_ID := "ScoreCalculator"
const SERVICE_DEPS := ["DataMGR"]

# ============================================================
#  常量 & 枚举
# ============================================================

## 判定等级
enum Judgment { PERFECT, GREAT, GOOD, BAD, MISS }

## 键型（与 KeySequenceManager.BlockType / FlowNote.NoteType 保持同名同值）
enum BlockType { Block = 0, Slide = 1, Long = 2 }

## 判定窗口（秒）
const JUDGE_WINDOWS: Dictionary = {
	Judgment.PERFECT: 0.05,
	Judgment.GREAT:   0.15,
	Judgment.GOOD:    0.20,
	Judgment.BAD:     0.50,
}

## 准度权重
const ACCURACY_WEIGHTS: Dictionary = {
	Judgment.PERFECT: 300,
	Judgment.GREAT:   200,
	Judgment.GOOD:    100,
	Judgment.BAD:      50,
	Judgment.MISS:      0,
}

## 评级阈值（降序）
const RANK_THRESHOLDS: Array = [
	[1.0000, "Ω"],
	[0.9990, "SSS"],
	[0.9970, "SS"],
	[0.9900, "S"],
	[0.9700, "A+"],
	[0.9300, "A"],
	[0.9000, "A-"],
	[0.8700, "B+"],
	[0.8300, "B"],
	[0.8000, "B-"],
	[0.7700, "C+"],
	[0.7300, "C"],
	[0.7000, "C-"],
	[0.6700, "D+"],
	[0.6300, "D"],
	[0.6000, "D-"],
]

## 基础分
const SCORE_BASE: float = 100.0

## 滑块(Slide) 初始衰减系数 & 衰减因子
const SLIDE_INITIAL_MULTIPLIER: float = 0.5
const SLIDE_DECAY_FACTOR: float = 0.6

## 长条(Long) 首判 → 续判 → 衰减
const LONG_FIRST_MULTIPLIER: float = 1.0
const LONG_SECOND_MULTIPLIER: float = 0.2
const LONG_DECAY_FACTOR: float = 0.6

# ============================================================
#  单例
# ============================================================
static var _score_regex: RegEx = null
static var instance: ScoreCalculator

# ============================================================
#  运行时状态
# ============================================================

## 总分
var total_score: float = 0.0

## 连击
var combo: int = 0
var max_combo: int = 0

## 判定计数
var judge_counts: Dictionary = {
	Judgment.PERFECT: 0,
	Judgment.GREAT: 0,
	Judgment.GOOD: 0,
	Judgment.BAD: 0,
	Judgment.MISS: 0,
}

## 准度因子累加
var accuracy_factor: float = 0.0
var perfect_accuracy_factor: float = 0.0

## Early / Late
var early_count: int = 0
var late_count: int = 0

## 总音符数（由 PlayView 在开局时设置）
var total_notes: int = 0

## 滑块(Slide) 衰减追踪：当前 SLIDE 乘数
var _slide_current_multiplier: float = SLIDE_INITIAL_MULTIPLIER

## 长条(Long) 衰减追踪：long_instance_id → 当前乘数
var _long_multipliers: Dictionary = {}

# ============================================================
#  生命周期
# ============================================================

func _ready() -> void:
	if instance == null:
		instance = self
	else:
		queue_free()
	add_to_group("singleton")

# ============================================================
#  公共 API
# ============================================================

## 根据偏差秒数（绝对值）返回判定等级
static func judge_from_timing(abs_timing_sec: float) -> Judgment:
	if abs_timing_sec <= JUDGE_WINDOWS[Judgment.PERFECT]:
		return Judgment.PERFECT
	elif abs_timing_sec <= JUDGE_WINDOWS[Judgment.GREAT]:
		return Judgment.GREAT
	elif abs_timing_sec <= JUDGE_WINDOWS[Judgment.GOOD]:
		return Judgment.GOOD
	elif abs_timing_sec <= JUDGE_WINDOWS[Judgment.BAD]:
		return Judgment.BAD
	else:
		return Judgment.MISS

## 记录一次判定（核心入口）
## block_type: BlockType 枚举值
## timing_sec: 偏差绝对值（秒），用于 timingMultiplier
## signed_offset_sec: 带符号偏差（>0 = Early, <0 = Late），仅用于 Early/Late 统计
## is_long_sustain: 是否为 LONG 的持续判定（非首判），不参与 accuracy，也不改变 combo（只加分）
## long_instance_id: 同一条长条的唯一标识，用于独立衰减链
func record_judgment(judgment: Judgment, block_type: int, timing_sec: float,
		signed_offset_sec: float = 0.0, is_long_sustain: bool = false,
		long_instance_id: int = -1) -> Dictionary:

	# 1. 判定计数（LONG 持续判定也计入判定总数但不计入 accuracy）
	judge_counts[judgment] += 1

	# 2. Combo（LONG 持续判定只加分、不改变 combo，保证实际 max_combo 不超过理论值）
	if not is_long_sustain:
		if judgment == Judgment.BAD or judgment == Judgment.MISS:
			if combo > max_combo:
				max_combo = combo
			combo = 0
		else:
			combo += 1
			if combo > max_combo:
				max_combo = combo

	# 3. Early / Late（Miss 无偏移方向）
	if judgment != Judgment.MISS:
		if signed_offset_sec > 0:
			early_count += 1
		elif signed_offset_sec < 0:
			late_count += 1

	# 4. 准度（LONG 持续判定不参与）
	if not is_long_sustain:
		accuracy_factor += ACCURACY_WEIGHTS[judgment]
		perfect_accuracy_factor += ACCURACY_WEIGHTS[Judgment.PERFECT]

	# 5. 计分
	var note_score = _calculate_note_score(judgment, block_type, timing_sec,
			is_long_sustain, long_instance_id)
	total_score += note_score

	# 6. 发射快照
	var snap = get_snapshot()
	snap["last_score_add"] = note_score
	return snap

## 记录 Miss（未击打，简化入口）
func record_miss() -> Dictionary:
	return record_judgment(Judgment.MISS, BlockType.Block, 1.0)

## 记录 LONG 持续 tick（简化入口）
## judgment: 持续 tick 的判定等级（通常为 PERFECT）
func record_long_sustain(judgment: Judgment, long_instance_id: int) -> Dictionary:
	return record_judgment(judgment, BlockType.Long, 0.0, 0.0, true, long_instance_id)

## 获取当前准度（0.0 ~ 1.0）
func get_accuracy() -> float:
	if perfect_accuracy_factor <= 0:
		return 1.0  # 尚无判定时显示 100%
	return accuracy_factor / perfect_accuracy_factor

## 获取 PP
func get_pp() -> float:
	var acc = get_accuracy()
	return log(1.0 + total_score) * pow(acc, 2)

## 获取评级
func get_rank() -> String:
	var acc = get_accuracy()
	for threshold in RANK_THRESHOLDS:
		if acc >= threshold[0]:
			return threshold[1]
	return "F"

## 获取格式化分数字符串（千分位逗号）
func get_formatted_score() -> String:
	var s = str(int(total_score))
	if _score_regex == null:
		_score_regex = RegEx.new()
		_score_regex.compile("(\\d)(?=(\\d{3})+(?!\\d))")
	return _score_regex.sub(s, "$1,", true)
func get_snapshot() -> Dictionary:
	return {
		"total_score": int(total_score),
		"combo": combo,
		"max_combo": max_combo,
		"accuracy": get_accuracy(),
		"accuracy_text": "%0.2f%%" % (get_accuracy() * 100),
		"pp": get_pp(),
		"pp_text": "%0.2fpp" % get_pp(),
		"rank": get_rank(),
		"formatted_score": get_formatted_score(),
		"judge_counts": judge_counts.duplicate(),
		"early_count": early_count,
		"late_count": late_count,
		"total_notes": total_notes,
		"last_score_add": 0,
	}

## 重置（新一局开始时调用）
func reset() -> void:
	total_score = 0.0
	combo = 0
	max_combo = 0
	judge_counts = {
		Judgment.PERFECT: 0,
		Judgment.GREAT: 0,
		Judgment.GOOD: 0,
		Judgment.BAD: 0,
		Judgment.MISS: 0,
	}
	accuracy_factor = 0.0
	perfect_accuracy_factor = 0.0
	early_count = 0
	late_count = 0
	total_notes = 0
	_slide_current_multiplier = SLIDE_INITIAL_MULTIPLIER
	_long_multipliers.clear()

# ============================================================
#  内部计算
# ============================================================

## noteScore = scoreBase × blockTypeMultiplier × timingMultiplier × comboMultiplier
func _calculate_note_score(judgment: Judgment, block_type: int, timing_sec: float,
		is_long_sustain: bool, long_instance_id: int) -> float:
	if judgment == Judgment.MISS:
		return 0.0

	var block_mult = _get_block_type_multiplier(block_type, is_long_sustain, long_instance_id)
	var timing_mult = _get_timing_multiplier(timing_sec)
	var combo_mult = _get_combo_multiplier()

	return max(1.0, SCORE_BASE * block_mult * timing_mult * combo_mult)

## blockTypeMultiplier
func _get_block_type_multiplier(block_type: int, _is_long_sustain: bool, long_instance_id: int) -> float:
	match block_type:
		BlockType.Block:
			# 命中点块(Block)时重置滑块(Slide)衰减
			_slide_current_multiplier = SLIDE_INITIAL_MULTIPLIER
			return 1.0

		BlockType.Slide:
			var mult = _slide_current_multiplier
			# 后续滑块(Slide)递减
			_slide_current_multiplier *= SLIDE_DECAY_FACTOR
			return mult

		BlockType.Long:
			if long_instance_id < 0:
				return LONG_FIRST_MULTIPLIER

			if not _long_multipliers.has(long_instance_id):
				# 首判
				_long_multipliers[long_instance_id] = LONG_SECOND_MULTIPLIER
				return LONG_FIRST_MULTIPLIER
			else:
				# 续判（第二次 0.2，之后每次 ×0.6）
				var mult = _long_multipliers[long_instance_id]
				_long_multipliers[long_instance_id] = mult * LONG_DECAY_FACTOR
				return mult

		_:
			return 1.0

## timingMultiplier = 1.06 * exp(-7.16 * timing)
func _get_timing_multiplier(timing_sec: float) -> float:
	return 1.06 * exp(-7.16 * timing_sec)

## comboMultiplier = 0.0809 + 0.199 * ln(combo)
func _get_combo_multiplier() -> float:
	if combo <= 1:
		return 1.0  # combo=0/1 时给基础值，避免 ln(0) 问题
	return 0.0809 + 0.199 * log(combo)

## 清理已结束的长条(Long)实例追踪（可在长条结束时调用）
func clear_long_instance(long_instance_id: int) -> void:
	_long_multipliers.erase(long_instance_id)

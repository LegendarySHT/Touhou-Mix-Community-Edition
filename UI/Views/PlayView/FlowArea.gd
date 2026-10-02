extends Panel

class_name FlowArea

# 判定线
@onready var jl: HSeparator = $JudgeLine
@onready var ui: UIStateManager = UiStatMGR
@onready var _particle_drawer: ParticleBatchDrawer = $ParticleBatchDrawer

########## 配置参数 #############
var auto_mode: bool = false
# 判定有效区时间窗（毫秒），0 = 垂直全幅（筛选音符时不受时间限制）
var judge_window_ms: int = 0
# 判定有效区选项 -> 时间窗(ms) 映射（索引与设置页 "judge_window_ms" 选项顺序一致）
const _JUDGE_WINDOW_OPTIONS: Array[int] = [0, 1000, 500, 250]
var note_judge_width: int = 100  # 统一判定宽度，从 Judge/block_judging_width 配置读取
var note_visual_width: int = 200  # 从 Appearance/block_size 配置读取
var glow_intensity: float = 1.0
var glow_size: float = 20.0
var check_slide_when_finger_up: bool = false  # Judge/check_instant_blocks_when_finger_up
var only_perfect_slides: bool = false  # Judge/only_perfect_instant_blocks_before_judge
var note_judger: NoteJudger = NoteJudger.new()

# 音符下落动画
var trans_before_line: int = Tween.TRANS_LINEAR as int
var ease_before_line: int = Tween.EASE_IN_OUT as int
var trans_after_line: int = Tween.TRANS_LINEAR as int
var ease_after_line: int = Tween.EASE_OUT as int

var note_color_short: Color = Color.DEEP_PINK
var note_color_slide: Color = Color.CYAN
var note_color_long: Color = Color.DARK_ORANGE

# 当前皮肤的完整配置（来自 skin.ini 新结构）
# {general:{enable_glow,custom_color}, short:{...}, instant:{...}, long:{...}}（skin 键名保持旧格式：short=点块 Block、instant=滑块 Slide）
var _skin_config: Dictionary = {}

# 光效总开关（来自 [general] enable_glow）
var _is_glow_enabled: bool = false

# long-f 中部贴图应用方式："repeat"（水平拉伸+垂直重复）或 "stretch"（竖直拉伸）
var _long_f_mode: String = "repeat"

# 长条连接模式："edge"（边缘连接，默认）或 "center"（中心连接）
var _long_connect_mode: String = "edge"
var _long_connect_center: bool = false  # 缓存 _long_connect_mode=="center"，热路径避免每帧字符串比较

# 随机颜色（由 PlayView 在 _prepare_game 时生成并传入）
# 结构: {note_type_key: Color}，仅在该类型启用 random_color 时存在对应键
var _random_colors: Dictionary = {}

# 全局随机颜色（非键盘模式 + 皮肤 custom_color 关闭时生效）
# 由 PlayView 在 _prepare_game 时生成并传入，结构同 _random_colors
var _global_random_colors: Dictionary = {}

## 设置随机颜色（PlayView 在 _prepare_game 生成后调用，不再直接写内部字段）
## is_global=true 写入全局随机调色板（非键盘模式），false 写入皮肤内随机颜色
func set_random_colors(colors: Dictionary, is_global: bool) -> void:
	if is_global:
		_global_random_colors = colors
	else:
		_random_colors = colors

# 最终解析出的音符颜色（结合 custom_color 主开关 + enable_color + random_color）
# 结构: {note_type_key: Color}，键为 "short"/"instant"/"long"（short=点块 Block、instant=滑块 Slide）
var _resolved_colors: Dictionary = {}

# 判定参数（毫秒）- 与 ScoreCalculator.JUDGE_WINDOWS（秒）对应
var judge_windows: Dictionary = {
	"perfect": 50,    # < 0.05s
	"great": 150,     # < 0.15s
	"good": 200,      # < 0.20s
	"bad": 500        # < 0.50s
}

# 音符生成提前量（毫秒） - 确保音符在到达判定线前有足够时间显示 - 调下落速度也是用它
var note_generation_lead_time: float = 1000.0

# 下落参数
var _note_fall_time_seconds: float = 1.0
var _note_fall_speed_after_judge_multiplier: float = 1.0
# 渲染裁剪参数：仅影响可见性，不影响判定/时序
var _note_cull_margin_top: float = 120.0
var _note_cull_margin_bottom: float = 180.0
var spark_presets: Dictionary = {}
var spark_emitters: Dictionary = {}
var spark_scalings: Dictionary = {}
var spark_alphas: Dictionary = {}
var spark_emitter_scales: Dictionary = {}
## 判定类型（与判定特效配置键 {j}_spark_* 一一对应）
const _JUDGE_TYPES: Array[String] = ["Perfect", "Great", "Good", "Bad"]
###################################

## note_judged(result: String, offset: String, block_type: int, timing_sec: float, signed_offset_sec: float)
## block_type: KeySequenceManager.BlockType 值 (0=Block=点块,1=Slide=滑块,2=Long=长条)
## 与 FlowNote.NoteType / ScoreCalculator.BlockType 同名同值，可直接透传
## timing_sec: 偏差绝对值(秒)  signed_offset_sec: 带符号偏差(秒)
signal note_judged(result: String, offset: String, block_type: int, timing_sec: float, signed_offset_sec: float)
## long_holding(long_instance_id: int) - 长条持续加分 tick
signal long_holding(long_instance_id: int)

# 音符相关
var lane_width: float = 0
# 音符按 类型(Block/Slide/Long) → 颜色 → Array[int] 三级分桶存储
# 桶元素为 seq 索引（而非对象），_draw/_process 免逐音符类型分发；同色音符同桶连续绘制利于贴图批处理
const _TYPE_ORDER: Array = [FlowNote.NoteType.Block, FlowNote.NoteType.Slide, FlowNote.NoteType.Long]
## _process 热路径遍历用：Block/Slide 共用 _update_block_note_fall，避免每帧分配 [Block, Slide] 数组
const _BLOCK_SLIDE_TYPES: Array = [FlowNote.NoteType.Block, FlowNote.NoteType.Slide]
var _note_buckets: Dictionary = {
	FlowNote.NoteType.Block: {},
	FlowNote.NoteType.Slide: {},
	FlowNote.NoteType.Long: {},
}
var _active_note_count: int = 0  # 活跃音符计数
var _notes_by_lane: Dictionary = {}  # 按轨道分组索引：{lane: Array[int]}，加速音符判定查找


# Block/Slide/Long 音符批量绘制器（PlayView.tscn 场景节点，Node2D _draw 替代 N 个 Control 节点）
@onready var _note_drawer: NoteBatchDrawer = $NoteBatchDrawer

# 手动触发音符的 NoteOff 调度器（演奏模式，按播放位置驱动）
var _manual_off_scheduler = ManualNoteOffScheduler.new()

var _note_fall_calculator: NoteFallCalculator = NoteFallCalculator.new()

var parent_node: Node = null

# 【方案C】从PlayView同步的当前播放时间（毫秒）
## 这个时间来自 MidiPlaybackManager.get_position_ms()，已包含缓冲补偿
## 用于确保note判定与MIDI播放位置完全同步
var _synced_current_time: float = 0.0

# 渲染时钟（毫秒）：来自 PlayView 的平滑视觉墙钟，仅用于计算音符显示位置。
# 判定（过线/Miss/长条结束/滑过认领）仍用 _synced_current_time（音频钟），保证判定与声音对齐。
var _render_time_ms: float = 0.0

# ===== 平行数组（彻底无 FlowNote 对象，直接消费 C# 静态数据 + 本地运行态数组）=====
# 索引 = C# KeySequenceCore 的 seq 索引。静态数据（时间/时长/类型/轨道）在 build_seq_data() 时
# 从 C# 一次快照进 _st_* ；运行态（坐标/判定标志/长条状态）存于 _rt_*。
# 只按索引写数组元素，全程不创建任何音符对象，内存与活动音符数解耦（数组长度=序列总条数，固定分配一次）。
var _st_type: PackedByteArray = PackedByteArray()        # 0=Block 1=Slide 2=Long（与 FlowNote.NoteType 同名同值）
var _st_start: PackedFloat32Array = PackedFloat32Array()
var _st_dur: PackedFloat32Array = PackedFloat32Array()
var _st_lane: PackedInt32Array = PackedInt32Array()
var _count: int = 0                                     # 序列总数（=数组长度）

# 运行态标志位打包到一个字节（_rt_flags）：
const F_REMOVED := 1      # 已从绘制列表移除
const F_JUDGED := 2       # 已被判定过
const F_CAN_JUDGE := 4    # 滑块可被认领（键盘模式）
const F_HELD := 8         # 长条被按住
const F_PASSED := 16      # 已过判定线
var _rt_flags: PackedByteArray = PackedByteArray()
var _rt_x: PackedFloat32Array = PackedFloat32Array()            # cached_x（左缘）
var _rt_cx: PackedFloat32Array = PackedFloat32Array()            # cached_center_x（判定/绘制用）
var _rt_cy: PackedFloat32Array = PackedFloat32Array()            # cached_center_y（每帧更新）
var _rt_half: PackedFloat32Array = PackedFloat32Array()          # Block/Slide 半高
var _rt_color: PackedColorArray = PackedColorArray()             # 每音符颜色（轨道交替色/皮肤解析色）
var _rt_x_base: PackedFloat32Array = PackedFloat32Array()        # Long spawn 基准左缘 x（拖动手势偏移基准）
var _rt_head_cy: PackedFloat32Array = PackedFloat32Array()       # Long 头部中心 y
var _rt_tail_cy: PackedFloat32Array = PackedFloat32Array()       # Long 尾部中心 y
var _rt_head_half: PackedFloat32Array = PackedFloat32Array()     # Long 头部半高
var _rt_tail_half: PackedFloat32Array = PackedFloat32Array()     # Long 尾部半高
var _rt_body_top: PackedFloat32Array = PackedFloat32Array()      # Long body 顶部 y
var _rt_body_h: PackedFloat32Array = PackedFloat32Array()        # Long body 高度
var _rt_cooldown: PackedFloat32Array = PackedFloat32Array()      # 长按触发计时器
var _rt_hold_press_x: PackedFloat32Array = PackedFloat32Array()  # 长按记录触摸 x（NAN=非触摸来源）
var _rt_long_id: PackedInt32Array = PackedInt32Array()           # 长条唯一实例 ID
var _rt_claimed: PackedInt32Array = PackedInt32Array()           # 认领该滑块的触点 ID（-1=无）
var _rt_held_by: PackedInt32Array = PackedInt32Array()           # 按住长条的触点 ID（-1=无）
var _needs_bucket_sweep: bool = false                            # 本帧是否有移除待清理分桶
var _next_long_id: int = 0                                       # 长条唯一实例 ID 生成器

## 唯一长条实例 ID（原 FlowNote._gen_long_id，供 ScoreCalculator 独立衰减链）
func _alloc_long_id() -> int:
	_next_long_id += 1
	return _next_long_id

# ========== 静态数据快照 / 运行态数组生命周期 ==========

## 全量预建：开局前由 PlayView 调用，一次性把 C# KeySequenceCore 全部序列的静态数据
## （时间/时长/类型/轨道）快照进 _st_*，并预分配运行态数组。此后游戏内零对象、零新建。
func build_seq_data() -> void:
	var ksm = KeySequenceManager.instance
	var cnt := ksm.seq_count()
	_count = cnt
	_st_type.resize(cnt)
	_st_start.resize(cnt)
	_st_dur.resize(cnt)
	_st_lane.resize(cnt)
	_rt_flags.resize(cnt)
	_rt_x.resize(cnt)
	_rt_cx.resize(cnt)
	_rt_cy.resize(cnt)
	_rt_half.resize(cnt)
	_rt_color.resize(cnt)
	_rt_x_base.resize(cnt)
	_rt_head_cy.resize(cnt)
	_rt_tail_cy.resize(cnt)
	_rt_head_half.resize(cnt)
	_rt_tail_half.resize(cnt)
	_rt_body_top.resize(cnt)
	_rt_body_h.resize(cnt)
	_rt_cooldown.resize(cnt)
	_rt_hold_press_x.resize(cnt)
	_rt_long_id.resize(cnt)
	_rt_claimed.resize(cnt)
	_rt_held_by.resize(cnt)
	var lc = parent_node.get_lane_count()
	for i in cnt:
		var lane: int = ksm.seq_lane(i)
		if lane < 0:
			lane = ksm.seq_pitch(i) % lc
		_st_lane[i] = lane
		_st_start[i] = ksm.seq_start_ms(i)
		_st_dur[i] = ksm.seq_dur_ms(i)
		_st_type[i] = _seq_type_to_int(ksm.seq_type(i))
		_rt_claimed[i] = -1
		_rt_held_by[i] = -1
		_rt_long_id[i] = -1
	note_idx = 0

## C# BlockType → FlowNote.NoteType（三种枚举已统一同名同值，仅做防御性映射）
func _seq_type_to_int(t: int) -> int:
	match t:
		KeySequenceManager.BlockType.Block:
			return FlowNote.NoteType.Block
		KeySequenceManager.BlockType.Slide:
			return FlowNote.NoteType.Slide
		_:
			return FlowNote.NoteType.Long

## 序列总数（= _st_* 数组长度），供 PlayView 结算统计用
func get_sequence_count() -> int:
	return _count

## 清空全部平行数组（clear_flow_area 调用；build_seq_data 会重新分配）
func _reset_seq_arrays() -> void:
	_count = 0
	_st_type.clear()
	_st_start.clear()
	_st_dur.clear()
	_st_lane.clear()
	for arr in [
		_rt_flags, _rt_x, _rt_cx, _rt_cy, _rt_half, _rt_color,
		_rt_x_base, _rt_head_cy, _rt_tail_cy, _rt_head_half, _rt_tail_half,
		_rt_body_top, _rt_body_h, _rt_cooldown, _rt_hold_press_x,
		_rt_long_id, _rt_claimed, _rt_held_by
	]:
		arr.clear()

var note_idx: int = 0  # 生成游标

# 多点触控支持
var touch_positions: Dictionary = {}  # 存储每个触摸点的位置
var active_holds: Dictionary = {}     # 存储正在按住长条音符的触摸点ID和对应的音符（触摸ID -> seq 索引）

# 触点手势状态（滑动事件跟踪）：touch_id -> {
#   "press_pos": Vector2,
#   "press_time_ms": float,
#   "last_pos": Vector2,
#   "last_time_ms": float,
#   "lanes": Array,           # 手指当前覆盖的轨道集合（轨道宽度=音符宽度，可多轨）
# }
# 滑键判定 = 点按(rule 1) + 滑动事件(rule 2/3/4)：
# - rule 1 点按：按 Block 判掉一个音符，同时视为滑入轨道（rule 3 接住列内其余已过线滑键）。
# - rule 2 过线：滑块到判定线瞬间，手指覆盖其轨道 / 键盘键按住 → 判掉（hold-catch）。
# - rule 3 滑入：覆盖集合新增某轨道 → 判掉该轨道已过线且仍在 great 窗口内的滑块。
# - rule 4 滑出/抬手：覆盖集合退出某轨道或抬手 → 判掉该轨道未过线但在 perfect 窗口内的滑块。
# 轨道宽度 = 音符判定宽度：12 轨窄轨下手指可同时覆盖多个轨道，集合差集即滑入/滑出；4 轨宽轨时退化为单轨。
# rule 5 抬手门控：位移 ≥ 一个音符宽度即视为滑出轨道。
var _gestures: Dictionary = {}

# 输入去重：防止桌面环境下鼠标与触摸事件双触发导致一次点击判定多个音符
const _PRESS_DEDUP_MS: float = 5.0
const _PRESS_DEDUP_DISTANCE: float = 6.0
var _last_press_time_ms: float = -1000000.0
var _last_press_pos: Vector2 = Vector2(-1000000.0, -1000000.0)
var _last_press_was_mouse: bool = false

var pressed_keys: Dictionary = {}

func init_flow_area():
	clear_flow_area()
	# 分桶模型：drawer 直接遍历 _note_buckets（按引用共享字典），增删无需再同步到 drawer
	_note_drawer.set_notes_source(_note_buckets)
	# 注入本对象引用（drawer/GlowLayer 分桶现在存 int 索引，需经本对象读平行数组）
	_note_drawer.flow_area = self
	# NoteJudger 平行数组版同样需要宿主读取 _rt_cx/_rt_cy/_rt_flags
	note_judger.flow_area = self
	note_idx = 0

	# 清空手动 NoteOff 挂起队列（上一局的定时器/代数不应残留到下一局）
	_manual_off_scheduler.reset()

	if EvtBus and not EvtBus.config_changed.is_connected(_on_config_changed):
		EvtBus.config_changed.connect(_on_config_changed)

	auto_mode = ConfigManager.instance.get_int("Playback", "auto_mode", 0) == 1
	
	# 从配置读取判定有效区（时间窗）
	var judge_window_idx = ConfigManager.instance.get_int("Judge", "judge_window_ms", 0)
	judge_window_ms = _JUDGE_WINDOW_OPTIONS[clampi(judge_window_idx, 0, _JUDGE_WINDOW_OPTIONS.size() - 1)]
	check_slide_when_finger_up = ConfigManager.instance.get_int("Judge", "check_instant_blocks_when_finger_up", 0) == 1
	only_perfect_slides = ConfigManager.instance.get_int("Judge", "only_perfect_instant_blocks_before_judge", 0) == 1

	# 从配置读取比例系数
	var block_size_ratio = ConfigManager.instance.get_float("Appearance", "block_size", 6.5)
	var block_judge_ratio = ConfigManager.instance.get_float("Judge", "block_judging_width", 1.0)
	
	_apply_note_fall_config_from_settings()
	var lc = parent_node.get_lane_count()
	
	# 计算可游玩区域宽度
	var safe_width: float = max(1.0, get_viewport().get_visible_rect().size.x - 2.0 * float(parent_node.lane_padding))
	
	# 根据比例计算音符宽度（最小10px防止过小）
	note_visual_width = max(10.0, safe_width / block_size_ratio)
	note_judge_width = max(10.0, note_visual_width * block_judge_ratio)
	
	# 计算轨道间距（中间间距从可用宽度扣除，与 LaneEffect 布局一致，触摸估算不溢出）
	var mid_gap: float = float(parent_node.get_mid_lane_gap())
	if lc <= 1:
		lane_width = safe_width
	else:
		lane_width = max(1.0, (safe_width - mid_gap - float(note_visual_width)) / float(lc - 1))
	
	# 设置判定线位置
	_apply_judge_line_thickness()
	_apply_judge_line_position()
	
	# 配置初始化（基础粒子/散射粒子 preset + 整体缩放/不透明度/发射器缩放）
	_reload_spark_config()
	_init_note_pool()
	# 应用解析后的颜色（由 load_note_skin + PlayView 随机颜色生成共同决定）
	# 新音符颜色在 _spawn_note 时经 _get_note_color → _resolved_colors 应用，此处只刷新已存在音符
	refresh_note_colors()

	set_note_width(note_visual_width)

	# 同步 drawer 的裁剪参数和视口高度
	# 同时初始化 _cached_viewport_height：避免首帧 _process 之前若被其他路径调用 _spawn_note
	# 读到默认 0.0 导致 after_distance 计算错误
	_cached_viewport_height = get_viewport().get_visible_rect().size.y
	if _note_drawer:
		_note_drawer.set_cull_margins(_note_cull_margin_top, _note_cull_margin_bottom)
		_note_drawer.set_viewport_height(_cached_viewport_height)

	# 预计算下落距离和速度
	_recompute_fall_constants()

func _apply_judge_line_position() -> void:
	var viewport_height: float = get_viewport().get_visible_rect().size.y
	var offset: int = parent_node.judge_line_offset_y if parent_node else 200
	jl.position.y = viewport_height - max(0, offset)
	_judge_line_y = jl.position.y
	_recompute_fall_constants()

func _apply_judge_line_thickness() -> void:
	var thickness : int = max(1, ConfigManager.instance.get_int("Appearance", "judge_line_thickness", 2))
	var base_style: StyleBox = jl.get_theme_stylebox("separator")
	if base_style is StyleBoxLine:
		var line_style: StyleBoxLine = (base_style as StyleBoxLine).duplicate() as StyleBoxLine
		line_style.thickness = thickness
		jl.add_theme_stylebox_override("separator", line_style)

func _apply_note_fall_config_from_settings() -> void:
	var note_fall_time = ConfigManager.instance.get_float("Generator", "note_fall_time", 1.5)
	note_generation_lead_time = max(1.0, note_fall_time * 1000.0)

	var note_fall_mode = ConfigManager.instance.get_int("Generator", "note_fall_mode", 0)
	var note_fall_speed_after_judge_multiplier = ConfigManager.instance.get_float("Generator", "note_fall_speed_after_judge_multiplier", -1.0)
	if note_fall_speed_after_judge_multiplier <= 0.0:
		note_fall_speed_after_judge_multiplier = ConfigManager.instance.get_float("Appearance", "grace_time", 1.0)

	match note_fall_mode:
		0:
			var uniform_config = EasingMapper.get_preset_config(0)
			trans_before_line = EasingMapper.string_to_trans(uniform_config["before_func"])
			ease_before_line = EasingMapper.string_to_ease(uniform_config["before_phase"])
			trans_after_line = EasingMapper.string_to_trans(uniform_config["after_func"])
			ease_after_line = EasingMapper.string_to_ease(uniform_config["after_phase"])
		1:
			var accelerate_config = EasingMapper.get_preset_config(1)
			trans_before_line = EasingMapper.string_to_trans(accelerate_config["before_func"])
			ease_before_line = EasingMapper.string_to_ease(accelerate_config["before_phase"])
			trans_after_line = EasingMapper.string_to_trans(accelerate_config["after_func"])
			ease_after_line = EasingMapper.string_to_ease(accelerate_config["after_phase"])
		2:
			var before_func = ConfigManager.instance.get_string("Generator", "note_fall_easing_before_func", "LINEAR")
			var before_phase = ConfigManager.instance.get_string("Generator", "note_fall_easing_before_phase", "IN")
			var after_func = ConfigManager.instance.get_string("Generator", "note_fall_easing_after_func", "LINEAR")
			var after_phase = ConfigManager.instance.get_string("Generator", "note_fall_easing_after_phase", "IN")

			trans_before_line = EasingMapper.string_to_trans(before_func)
			ease_before_line = EasingMapper.string_to_ease(before_phase)
			trans_after_line = EasingMapper.string_to_trans(after_func)
			ease_after_line = EasingMapper.string_to_ease(after_phase)
		_:
			var fallback_config = EasingMapper.get_preset_config(0)
			trans_before_line = EasingMapper.string_to_trans(fallback_config["before_func"])
			ease_before_line = EasingMapper.string_to_ease(fallback_config["before_phase"])
			trans_after_line = EasingMapper.string_to_trans(fallback_config["after_func"])
			ease_after_line = EasingMapper.string_to_ease(fallback_config["after_phase"])

	_note_fall_time_seconds = note_fall_time
	_note_fall_speed_after_judge_multiplier = max(0.01, note_fall_speed_after_judge_multiplier)
	# 预计算下落窗口毫秒并重建缓动查表（每音符每帧的缓动从 O(easing 计算) 降到 O(1) 查表）
	_note_fall_pre_ms = max(1.0, _note_fall_time_seconds * 1000.0)
	_rebuild_curve_luts()

func _on_config_changed(key: String, section: String, value: Variant) -> void:
	if section == "Playback" and key == "auto_mode":
		auto_mode = int(value) == 1
		GLogger.info("FlowArea auto_mode updated: %s" % ("ON" if auto_mode else "OFF"), "FlowArea")
		return

	if section == "Judge":
		if key == "judge_window_ms":
			var idx = clampi(int(value), 0, _JUDGE_WINDOW_OPTIONS.size() - 1)
			judge_window_ms = _JUDGE_WINDOW_OPTIONS[idx]
			return
		if key == "judge_line_position":
			_apply_judge_line_position()
			return
		if key == "block_judging_width":
			# 需要重新计算音符尺寸
			_recalculate_note_dimensions()
			return
		if key == "check_instant_blocks_when_finger_up":
			check_slide_when_finger_up = int(value) == 1
			return
		if key == "only_perfect_instant_blocks_before_judge":
			only_perfect_slides = int(value) == 1
			return

	if section == "Appearance" and key == "judge_line_thickness":
		_apply_judge_line_thickness()
		return

	if section == "Appearance" and key == "block_size":
		# 需要重新计算音符尺寸
		_recalculate_note_dimensions()
		return

	# 粒子特效配置（Lane 段 spark_*）：热更新，暂停中调整立即生效
	if section == "Lane" and (key.ends_with("_spark_preset") or key.ends_with("_spark_emitter")
			or key.ends_with("_spark_scaling") or key.ends_with("_spark_alpha")
			or key.ends_with("_spark_emitter_scaling")):
		_reload_spark_config()
		return

	if section != "Generator":
		return

	if key in [
		"note_fall_time",
		"note_fall_mode",
		"note_fall_speed_after_judge_multiplier",
		"note_fall_easing_before_func",
		"note_fall_easing_before_phase",
		"note_fall_easing_after_func",
		"note_fall_easing_after_phase"
	]:
		_apply_note_fall_config_from_settings()
		_recompute_fall_constants()
		GLogger.info("Note fall config hot-reloaded: [%s] %s=%s" % [section, key, str(value)], "FlowArea")

## 重新计算音符尺寸（根据比例系数）
func _recalculate_note_dimensions() -> void:
	var block_size_ratio = ConfigManager.instance.get_float("Appearance", "block_size", 6.5)
	var block_judge_ratio = ConfigManager.instance.get_float("Judge", "block_judging_width", 1.0)
	var safe_width: float = max(1.0, get_viewport().get_visible_rect().size.x - 2.0 * float(parent_node.lane_padding))
	
	note_visual_width = max(10.0, safe_width / block_size_ratio)
	note_judge_width = max(10.0, note_visual_width * block_judge_ratio)
	
	set_note_width(note_visual_width)
	GLogger.info("Note dimensions recalculated: visual_width=%d, judge_width=%d" % [int(note_visual_width), int(note_judge_width)], "FlowArea")

# 修改音符皮肤 数组顺序[短块图片，短块上色区图片，滑块。。。，长条（从头到尾）]
func set_note_texture(texture_array: Array):
	# 直接同步到批量绘制器（drawer 为场景节点始终存在；缺失贴图由 drawer 内部回退透明纹理）
	if _note_drawer:
		_note_drawer.set_textures(texture_array[0] if texture_array.size() > 0 else null,
			texture_array[1] if texture_array.size() > 1 else null,
			texture_array[2] if texture_array.size() > 2 else null,
			texture_array[3] if texture_array.size() > 3 else null)
		_note_drawer.set_long_textures(texture_array[4] if texture_array.size() > 4 else null,
			texture_array[5] if texture_array.size() > 5 else null,
			texture_array[6] if texture_array.size() > 6 else null,
			texture_array[7] if texture_array.size() > 7 else null,
			texture_array[8] if texture_array.size() > 8 else null,
			texture_array[9] if texture_array.size() > 9 else null)
		_note_drawer.set_long_body_mode(_long_f_mode)
		# 贴图变化会重算各类型半高：同步刷新最大全高，保证 _note_fall_distance/速度在换肤后不过期
		_note_max_size_y = _note_drawer.get_max_half_height() * 2.0
		_recompute_fall_constants()

# 加载并应用指定皮肤的贴图
func load_note_skin(skin_name: String = SkinManager.DEFAULT_SKIN_PRESET) -> void:
	# 获取皮肤贴图字典
	var skin_textures = {}
	if SkinMGR:
		skin_textures = SkinMGR.get_skin_textures(skin_name)
		# 加载皮肤完整配置（新结构）
		_skin_config = SkinMGR.get_skin_config(skin_name)
		# 读取光效总开关与长条连接模式
		_is_glow_enabled = SkinMGR.is_glow_enabled(skin_name)
		_long_connect_mode = SkinMGR.get_long_connect_mode(skin_name)
		_long_connect_center = _long_connect_mode == "center"

	# 构建纹理数组，按顺序: short(点块Block), short_core, instant(滑块Slide), instant_core, long_b, long_b_core, long_f, long_f_core, long_t, long_t_core
	var texture_array = [
		skin_textures.get("short"),
		skin_textures.get("short_core"),
		skin_textures.get("instant"),
		skin_textures.get("instant_core"),
		skin_textures.get("long_b"),
		skin_textures.get("long_b_core"),
		skin_textures.get("long_f"),
		skin_textures.get("long_f_core"),
		skin_textures.get("long_t"),
		skin_textures.get("long_t_core")
	]

	# 应用贴图
	set_note_texture(texture_array)

	# 应用 long-f 中部贴图模式（repeat / stretch）
	_apply_long_f_mode()

	# 解析音符颜色（基于新皮肤配置 + 已有 _random_colors）
	# 每音符颜色在 _spawn_note 时由 _get_note_color → _resolved_colors 应用，无需模板
	_resolve_note_colors()

	# 同步光效开关到 drawer（Long 与 Block/Slide 同走批量绘制，无需重建对象池）
	if _note_drawer:
		_note_drawer.set_glow_enabled(_is_glow_enabled)

	GLogger.info("Loaded note skin: %s, glow=%s, connect_mode=%s" % [skin_name, _is_glow_enabled, _long_connect_mode], "FlowArea")

## 根据 _skin_config + _random_colors + _global_random_colors 解析出最终音符颜色。
## 规则实现集中在 SkinManager.resolve_note_colors（与 NoteSkinAdjust 皮肤预览共用，避免两份逻辑漂移）
func _resolve_note_colors() -> void:
	var keyboard_mode: bool = parent_node != null and bool(parent_node.get("keyboard_mode"))
	_resolved_colors = SkinManager.resolve_note_colors(_skin_config, keyboard_mode,
		_random_colors, _global_random_colors)

## 重新解析颜色并同步到所有活跃音符（用于随机颜色刷新等场景）
## 每音符颜色在 _spawn_note 时由 _get_note_color 应用，此处只刷新已生成仍绘制的音符
func refresh_note_colors() -> void:
	_resolve_note_colors()
	# 分桶模型：换色的音符从旧色桶移到新色桶（跳过已移除，避免与挂起的延迟删除竞态）
	for type_key in _TYPE_ORDER:
		var color_keys: Array = _note_buckets[type_key].keys()  # 拷贝，允许遍历中增删 key
		for color_key in color_keys:
			var bucket: Array = _note_buckets[type_key][color_key]
			var snapshot: Array = bucket.duplicate()  # 快照，遍历中 _move_note_to_bucket 安全
			for idx in snapshot:
				if _rt_flags[idx] & F_REMOVED:
					continue
				var new_color: Color = _get_note_color(_st_type[idx], _st_lane[idx])
				if new_color != _rt_color[idx]:
					_move_note_to_bucket(idx, new_color)
	if _note_drawer:
		_note_drawer.request_redraw()

# 根据皮肤配置设置 long-f 中部贴图的应用方式
# repeat → 水平拉伸+垂直重复（drawer 分条绘制）；stretch → 竖直拉伸
func _apply_long_f_mode() -> void:
	var mode = "repeat"
	if _skin_config.has("long") and _skin_config["long"].has("long_f_mode"):
		mode = _skin_config["long"]["long_f_mode"]
	_long_f_mode = mode
	# 同步到批量绘制器（皮肤热切换时实时更新）
	if _note_drawer:
		_note_drawer.set_long_body_mode(_long_f_mode)

# 修改音符宽度
func set_note_width(wid: float):
	# 模板 Control 已移除：宽度同步给 drawer，由 drawer 按纹理比例派生各类型半高
	if _note_drawer:
		_note_drawer.set_note_width(wid)
		# 最大音符全高（下落距离用，保证音符在屏幕外生成/消失）
		_note_max_size_y = _note_drawer.get_max_half_height() * 2.0

func clear_flow_area():
	# 清空运行态分桶/索引/手势/平行数组（静态数据 _st_* 由 build_seq_data 重建，此处随数组一并清空）
	if _note_drawer:
		_note_drawer.clear()

	# 清空批绘粒子的活跃列表
	if _particle_drawer:
		_particle_drawer.clear()

	for type_key in _TYPE_ORDER:
		_note_buckets[type_key].clear()
	_active_note_count = 0
	_clear_lane_index()
	active_holds.clear()
	touch_positions.clear()
	_gestures.clear()
	pressed_keys.clear()
	note_idx = 0
	_needs_bucket_sweep = false
	_reset_seq_arrays()

	# 释放尚未触发的手动 NoteOff（游戏结束/清场时，避免音符一直挂在合成器上）
	_manual_off_scheduler.process(_synced_current_time, true)
	_manual_off_scheduler.reset()

## 检查是否还有活跃音符（用于游戏结束后等待音符自然消除）
func has_active_notes() -> bool:
	return _active_note_count > 0


var _note_max_size_y: float = 0
var _note_fall_speed: float = 0
var _note_fall_distance: float = 0

# 性能优化缓存：每帧热点路径避免重复读取节点属性 / 调用缓动计算
var _judge_line_y: float = 0.0  # jl.position.y 缓存（_apply_judge_line_position 维护）
var _note_fall_pre_ms: float = 1000.0  # _note_fall_time_seconds*1000（clamp 后），下落窗口时长
var _after_speed_px_per_ms_inv: float = 0.0  # 判定线后下落速度的倒数 = 1.0 / (_note_fall_speed * 倍率)
const _CURVE_LUT_SIZE: int = 1024  # 缓动曲线查表分辨率（对 BACK/ELASTIC 等振荡曲线足够平滑）
var _curve_lut_before: PackedFloat32Array = PackedFloat32Array()  # 判定线前缓动曲线 LUT
var _curve_lut_after: PackedFloat32Array = PackedFloat32Array()   # 判定线后缓动曲线 LUT

## 根据 NoteType 返回 _resolved_colors 中对应的颜色
func _get_resolved_color_for_type(tp: FlowNote.NoteType) -> Color:
	match tp:
		FlowNote.NoteType.Block:
			# skin 键名保持旧格式：short=点块(Block)
			return _resolved_colors.get("short", Color.WHITE)
		FlowNote.NoteType.Slide:
			# skin 键名保持旧格式：instant=滑块(Slide)
			return _resolved_colors.get("instant", Color.WHITE)
		FlowNote.NoteType.Long:
			return _resolved_colors.get("long", Color.WHITE)
	return Color.WHITE

## 获取音符最终颜色：交替轨道颜色开启（键盘模式）时优先轨道色，否则回退皮肤解析色
func _get_note_color(tp: FlowNote.NoteType, lane_idx: int) -> Color:
	var lane_cl = parent_node.get_lane_color(lane_idx)
	return lane_cl if lane_cl != null else _get_resolved_color_for_type(tp)

## 生成音符：静态数据已快照在 _st_*，此处只初始化运行态坐标/半高/颜色/长条专属字段，
## 并加入分桶与轨道索引。全程不创建任何对象。
func _spawn_note(note_index: int) -> void:
	if note_index >= _count:
		return

	var tp: int = _st_type[note_index]
	var lane: int = _st_lane[note_index]

	# 计算音符位置（轨道几何由 LaneEffect 提供：左缘 x + 光柱宽度）
	# 音符始终以轨道中心为基准居中：margin 可为负（音符宽于光柱时两端对称溢出），
	# 保证音符中心恒等于光柱中心/轨道中心（否则音符宽于光柱时左对齐会导致光效相对偏左）
	var lane_area = parent_node.lane_area
	var beam_margin : float= (lane_area.get_lane_width() - note_visual_width) / 2.0
	var start_x : float = lane_area.get_lane_x(lane) + beam_margin

	_rt_x[note_index] = start_x
	_rt_cx[note_index] = start_x + note_visual_width * 0.5
	_rt_color[note_index] = _get_note_color(tp, lane)

	if tp == FlowNote.NoteType.Long:
		_rt_x_base[note_index] = start_x  # 拖动手势偏移基准（按住时随触摸平移）
		_rt_head_half[note_index] = _note_drawer.get_long_head_half_height()
		_rt_tail_half[note_index] = _note_drawer.get_long_tail_half_height()
		_rt_held_by[note_index] = -1
	else:
		_rt_half[note_index] = _note_drawer.get_half_height(tp)
		_rt_claimed[note_index] = -1
	_add_to_bucket(note_index)
	_add_note_to_lane_index(note_index)
	_update_block_note_fall(note_index, _synced_current_time, _render_time_ms)

## 集中刷新下落常量：距离 / 速度 / 线后速度（判定线 Y、音符尺寸、下落配置变化时调用）
func _recompute_fall_constants() -> void:
	_note_fall_distance = _judge_line_y + _note_max_size_y
	_note_fall_speed = _note_fall_calculator.compute_speed_px_per_ms(_note_fall_distance, _note_fall_time_seconds)
	_after_speed_px_per_ms_inv = 1.0 / max(0.0001, _note_fall_speed * _note_fall_speed_after_judge_multiplier)

## 重建两条缓动曲线的查表（配置变化时调用一次；热路径只查表）
func _rebuild_curve_luts() -> void:
	_curve_lut_before = _build_curve_lut(trans_before_line, ease_before_line)
	_curve_lut_after = _build_curve_lut(trans_after_line, ease_after_line)

func _build_curve_lut(trans: int, ease_: int) -> PackedFloat32Array:
	var lut := PackedFloat32Array()
	lut.resize(_CURVE_LUT_SIZE)
	for i in _CURVE_LUT_SIZE:
		lut[i] = _note_fall_calculator.evaluate_curve_progress(float(i) / float(_CURVE_LUT_SIZE - 1), trans, ease_)
	return lut

## Block/Slide 音符的 synced time 驱动位置更新 (替代 Tween)
## 每帧由 _process 调用, 根据 _synced_current_time 计算音符位置
## 同时处理过线回调 (Slide 检查/auto_mode) 和 Miss 判定
## 平行数组版：写 _rt_cy[note_index]，drawer 在 _draw 中读取
## current_time_ms = 判定时钟（音频），render_time_ms = 渲染时钟（平滑视觉，可选）
## 热路径：内联 _compute_center_y_by_judge_time + _evaluate_lut（每音符每帧 3 次函数调用 → 0）
func _update_block_note_fall(note_index: int, current_time_ms: float, render_time_ms: float = -1.0) -> void:
	if _rt_flags[note_index] & F_REMOVED:
		return
	if render_time_ms < 0.0:
		render_time_ms = current_time_ms

	var half_height = _rt_half[note_index]
	var judge_time_ms = _st_start[note_index]
	var pre_ms = _note_fall_pre_ms
	var spawn_time_ms : float = judge_time_ms - pre_ms
	var center_y: float
	
	var lut_m1 := _CURVE_LUT_SIZE - 1
	
	# 内联 _compute_center_y_by_judge_time
	if render_time_ms <= judge_time_ms:
		if render_time_ms < spawn_time_ms:
			# 提前生成时继续保持匀速下落，避免音符在顶端静止等待
			center_y = _judge_line_y - _note_fall_distance - (spawn_time_ms - render_time_ms) * _note_fall_speed
		else:
			var progress : float = clampf((render_time_ms - spawn_time_ms) / pre_ms, 0.0, 1.0)
			
			# 内联 _evaluate_lut
			var scaled := progress * float(lut_m1)
			var idx := int(scaled)
			var eased: float
			if idx >= lut_m1:
				eased = _curve_lut_before[lut_m1]
			else:
				eased = _curve_lut_before[idx] + (_curve_lut_before[idx + 1] - _curve_lut_before[idx]) * (scaled - float(idx))
			center_y = _judge_line_y - _note_fall_distance + eased * _note_fall_distance
	else:
		var after_distance := maxf(_cached_viewport_height - _judge_line_y + half_height, 1.0)
		var after_time_ms := maxf(after_distance * _after_speed_px_per_ms_inv, 1.0)
		var after_progress : float = clampf((render_time_ms - judge_time_ms) / after_time_ms, 0.0, 1.0)
		
		# 内联 _evaluate_lut
		var scaled := after_progress * float(lut_m1)
		var idx := int(scaled)
		var eased_after: float
		if idx >= lut_m1:
			eased_after = _curve_lut_after[lut_m1]
		else:
			eased_after = _curve_lut_after[idx] + (_curve_lut_after[idx + 1] - _curve_lut_after[idx]) * (scaled - float(idx))
		center_y = _judge_line_y + eased_after * after_distance

	_rt_cy[note_index] = center_y

	# 过线回调: 音符首次到达/超过判定线时触发
	if not (_rt_flags[note_index] & F_PASSED) and current_time_ms >= judge_time_ms:
		_rt_flags[note_index] |= F_PASSED
		if _rt_flags[note_index] & F_JUDGED or _rt_flags[note_index] & F_REMOVED:
			return
		if _st_type[note_index] == FlowNote.NoteType.Slide and _check_slide_stat(note_index):
			return
		if auto_mode:
			_auto_click(note_index)

	# Miss 判定: 音符超出窗口底部且未被击打 (原第二 Tween.finished 逻辑)
	if not (_rt_flags[note_index] & F_JUDGED) and not (_rt_flags[note_index] & F_REMOVED) and center_y >= _cached_viewport_height:
		_remove_note(note_index)
		note_judged.emit("Miss", "", _st_type[note_index], 1.0, 0.0)

## current_time_ms = 判定时钟（音频），render_time_ms = 渲染时钟（平滑视觉，可选）
## 平行数组版：写 _rt_head_cy/_rt_tail_cy/_rt_body_* 缓存字段，drawer 在 _draw 中读取绘制
## 热路径：内联 _evaluate_lut + 常量预读
func _update_long_note_fall(note_index: int, current_time_ms: float, render_time_ms: float = -1.0) -> void:
	if _rt_flags[note_index] & F_REMOVED:
		return
	if render_time_ms < 0.0:
		render_time_ms = current_time_ms

	var head_half = _rt_head_half[note_index]
	var tail_half = _rt_tail_half[note_index]
	var pre_ms = _note_fall_pre_ms
	var lut_m1 := _CURVE_LUT_SIZE - 1

	# 按住时长条头部钉在判定线，跳过缓动计算（原实现先算再覆盖，浪费一次 easing）
	var head_center: float
	if _rt_flags[note_index] & F_HELD:
		head_center = _judge_line_y
	else:
		head_center = _compute_center_y_inlined(_st_start[note_index], render_time_ms, head_half, pre_ms, lut_m1)
	var tail_center = _compute_center_y_inlined(_st_start[note_index] + max(0.0, _st_dur[note_index]), render_time_ms, tail_half, pre_ms, lut_m1)

	_rt_head_cy[note_index] = head_center
	_rt_tail_cy[note_index] = tail_center
	_rt_cy[note_index] = head_center  # 判定/特效用代表中心（NoteJudger / hit_pos）

	# 长条连接模式：edge（边缘连接，body 从 tail_bottom 到 head_top）
	# 或 center（中心连接，body 从 tail_center 到 head_center，head/tail 各向 body 偏移半高）
	# 两种模式下 head/tail 矩形相同（head 半高居中于 head_center，tail 半高居中于 tail_center）
	if _long_connect_center:
		_rt_body_top[note_index] = tail_center
		_rt_body_h[note_index] = max(0.0, head_center - tail_center)
	else:
		# 边缘连接（默认）：body 从 tail_bottom（tail_center+tail_half）到 head_top（head_center-head_half）
		_rt_body_top[note_index] = tail_center + tail_half
		_rt_body_h[note_index] = max(0.0, (head_center - head_half) - (tail_center + tail_half))

	if not (_rt_flags[note_index] & F_JUDGED) and not (_rt_flags[note_index] & F_HELD) and _rt_held_by[note_index] < 0:
		if tail_center >= _cached_viewport_height:
			_remove_note(note_index)
			note_judged.emit("Miss", "", FlowNote.NoteType.Long, 1.0, 0.0)

## 内联辅助：长条更新用（保留 _compute_center_y_by_judge_time 逻辑，但接收预计算常量避免重复取值）
## 等价于 _compute_center_y_by_judge_time(judge_time_ms, render_time_ms, half_height)，
## 但把 _note_fall_pre_ms / _CURVE_LUT_SIZE-1 作为参数传入，让调用方共享读取
func _compute_center_y_inlined(judge_time_ms: float, render_time_ms: float, half_height: float,
		pre_ms: float, lut_m1: int) -> float:
	var spawn_time_ms := judge_time_ms - pre_ms
	
	var scaled : float = 0.0
	var idx : int = 0
	if render_time_ms <= judge_time_ms:
		if render_time_ms < spawn_time_ms:
			return _judge_line_y - _note_fall_distance - (spawn_time_ms - render_time_ms) * _note_fall_speed
		var progress := clampf((render_time_ms - spawn_time_ms) / pre_ms, 0.0, 1.0)
		scaled = progress * float(lut_m1)
		idx = int(scaled)
		if idx >= lut_m1:
			return _judge_line_y - _note_fall_distance + _curve_lut_before[lut_m1] * _note_fall_distance
		var eased := _curve_lut_before[idx] + (_curve_lut_before[idx + 1] - _curve_lut_before[idx]) * (scaled - float(idx))
		return _judge_line_y - _note_fall_distance + eased * _note_fall_distance
	var after_distance := maxf(_cached_viewport_height - _judge_line_y + half_height, 1.0)
	var after_time_ms := maxf(after_distance * _after_speed_px_per_ms_inv, 1.0)
	var after_progress := clampf((render_time_ms - judge_time_ms) / after_time_ms, 0.0, 1.0)
	scaled = after_progress * float(lut_m1)
	idx = int(scaled)
	var eased_after: float
	if idx >= lut_m1:
		eased_after = _curve_lut_after[lut_m1]
	else:
		eased_after = _curve_lut_after[idx] + (_curve_lut_after[idx + 1] - _curve_lut_after[idx]) * (scaled - float(idx))
	return _judge_line_y + eased_after * after_distance

var _auto_hold_idx: int = 0
## AUTO 模式自动判定：
## - 点块/长条：按自然类型计分；
## - 滑块：完美滑块判定(only_perfect_slides)开启时按滑动触发（Slide，进入滑块衰减链）计分；
##   关闭时与手动点击滑块一致，按点块(Block)计分（固定倍率并重置滑块衰减链）。
## 传入 _synced_current_time 作为 input_time_ms：跳过 _get_realtime_position_ms 实时查询，
## 与 _update_block_note_fall 触发本函数的判定时钟一致（auto 模式无需音频钟精确同步）
func _auto_click(note_index: int):
	if parent_node.play_mode:
		_manual_off_scheduler.trigger_from_sequence(KeySequenceManager.instance, note_index)
	if _st_type[note_index] == FlowNote.NoteType.Long:
		_judge_note(note_index, false, _synced_current_time)
		_hold_long_note(_auto_hold_idx + 666, note_index)
		_auto_hold_idx += 1
	elif _st_type[note_index] == FlowNote.NoteType.Slide and not only_perfect_slides:
		_judge_note(note_index, false, _synced_current_time, FlowNote.NoteType.Block)
	else:
		_judge_note(note_index, false, _synced_current_time)

# 因为在for循环遍历时erase会导致漏元素，所以推迟元素的移除
func _delay_free(list, item_to_free):
	if list != null:
		list.erase(item_to_free)

# ========== 颜色分桶维护（桶元素为 seq 索引） ==========

## 把音符索引加入其 (type, color) 对应的颜色桶
func _add_to_bucket(note_index: int) -> void:
	var type_bucket: Dictionary = _note_buckets[_st_type[note_index]]
	var color_key: Color = _rt_color[note_index]
	if not type_bucket.has(color_key):
		type_bucket[color_key] = []
	type_bucket[color_key].append(note_index)
	_active_note_count += 1

## 全量预热：把本局判定特效引用的粒子包精灵图在开局前加载（ParticleMGR 模板/纹理缓存），
## 首次判定 spawn 粒子时的同步 load() + GPU 上传前移到面板遮罩期。
## spark_presets/spark_emitters 已由 init_flow_area → _reload_spark_config 解析，本方法直接取用。
func prewarm_spark_packs() -> void:
	for judge in _JUDGE_TYPES:
		var preset: String = spark_presets.get(judge, "")
		var emitter: String = spark_emitters.get(judge, "")
		if not preset.is_empty():
			ParticleMGR.get_layer_template(preset, ParticleMGR.ROLE_BASE)
		if not emitter.is_empty():
			ParticleMGR.get_layer_template(emitter, ParticleMGR.ROLE_EMITTER)

## 换色：从旧颜色桶移除并加入新颜色桶（refresh_note_colors 用）
func _move_note_to_bucket(note_index: int, new_color: Color) -> void:
	var type_key: int = _st_type[note_index]
	var old_color: Color = _rt_color[note_index]
	var old_bucket: Array = _note_buckets[type_key].get(old_color, [])
	old_bucket.erase(note_index)
	_active_note_count -= 1  # 平衡 _add_to_bucket 的 +1（换色净计数不变）
	_rt_color[note_index] = new_color
	_add_to_bucket(note_index)

func set_glow_params(intensity: float, size_val: float) -> void:
	glow_intensity = clampf(intensity, 0.0, 2.0)
	glow_size = clampf(size_val, 1.0, 30.0)
	# 同步到 drawer（Block/Slide 光效由 drawer 管理）
	if _note_drawer:
		_note_drawer.set_glow_params(glow_intensity, glow_size)

func _init_note_pool() -> void:
	"""初始化 NoteBatchDrawer（PlayView.tscn 场景节点，此处仅同步运行状态）"""
	_note_drawer.set_note_width(note_visual_width)
	_note_drawer.set_glow_enabled(_is_glow_enabled)
	_note_drawer.set_glow_params(glow_intensity, glow_size)
	_note_drawer.set_cull_margins(_note_cull_margin_top, _note_cull_margin_bottom)
	_note_drawer.set_viewport_height(get_viewport().get_visible_rect().size.y)

func _remove_note(note_index: int) -> void:
	if _rt_flags[note_index] & F_REMOVED:
		return
	_rt_flags[note_index] |= F_REMOVED
	# 分桶模型：drawer 遍历的就是 _note_buckets（同引用），此处只触发重绘立即清除画面；按 F_REMOVED 跳过绘制
	if _note_drawer:
		_note_drawer.request_redraw()
	_active_note_count -= 1  # F_REMOVED 守卫后重复调用不会二次递减（幂等）
	# 从颜色桶/轨道索引的移除推迟到帧末执行（见 _sweep_removed_from_buckets）
	_needs_bucket_sweep = true

	# 若是被按住的长条音符，清理触摸点
	if _rt_flags[note_index] & F_HELD and _rt_held_by[note_index] in active_holds:
		call_deferred("_delay_free", active_holds, _rt_held_by[note_index])

## 帧末清理已移除音符：从全部颜色桶移除（F_REMOVED 已置位，避免遍历中 mutate 数组）
func _sweep_removed_from_buckets() -> void:
	for type_key in _TYPE_ORDER:
		var color_keys: Array = _note_buckets[type_key].keys()
		for color_key in color_keys:
			var bucket: Array = _note_buckets[type_key][color_key]
			if bucket.is_empty():
				continue
			var alive: Array = []
			for idx in bucket:
				if _rt_flags[idx] & F_REMOVED == 0:
					alive.append(idx)
			_note_buckets[type_key][color_key] = alive
	_needs_bucket_sweep = false

# ========== 轨道索引维护（用于加速音符判定） ==========
func _add_note_to_lane_index(note_index: int) -> void:
	var lane: int = _st_lane[note_index]
	if not _notes_by_lane.has(lane):
		_notes_by_lane[lane] = []
	_notes_by_lane[lane].append(note_index)

func _remove_note_from_lane_index(note_index: int) -> void:
	var lane: int = _st_lane[note_index]
	if _notes_by_lane.has(lane):
		_notes_by_lane[lane].erase(note_index)

func _clear_lane_index() -> void:
	_notes_by_lane.clear()

## 获取触摸位置附近的轨道音符索引列表（当前轨道 ± 相邻轨道）
func _get_notes_near_lane(lane: int) -> Array:
	var result: Array = []
	for offset in [-1, 0, 1]:
		var check_lane = lane + offset
		if _notes_by_lane.has(check_lane):
			result.append_array(_notes_by_lane[check_lane])
	return result

## 根据触摸X坐标估算轨道索引
func _estimate_lane_from_x(x: float) -> int:
	var lc = parent_node.get_lane_count()
	if lc <= 1:
		return 0
	var safe_start = float(parent_node.lane_padding)
	var relative_x = x - safe_start
	# 中间间距：偶数键位时右半侧整体右移，估算前先减去间距对齐
	var mid_gap: int = parent_node.get_mid_lane_gap()
	var half := int(lc / 2)
	if mid_gap > 0 and relative_x >= float(half) * lane_width:
		relative_x -= mid_gap
	var lane = int(relative_x / lane_width)
	return clampi(lane, 0, lc - 1)

func _gui_input(event: InputEvent) -> void:
	if parent_node.is_pause:
		accept_event()
		return

	var event_time_ms := _get_realtime_position_ms()
	if event is InputEventScreenTouch:
		if event.pressed:
			# 手指按下
			touch_positions[event.index] = event.position
			_handle_press(event.index, event.position, event_time_ms)
		else:
			# 手指松开
			if event.index in touch_positions:
				touch_positions.erase(event.index)
				_handle_release(event.index, event_time_ms)
			elif event.index >= 0:
				# 诊断：收到释放事件但无对应按下记录（可能是极快轻触导致按下事件被丢弃）
				push_warning("[FlowArea] Orphan touch release: index=%d, no corresponding press found" % event.index)
	
	# 处理触摸拖动
	elif event is InputEventScreenDrag:
		touch_positions[event.index] = event.position
		_handle_touch_drag(event.index, event.position)

	# 拖动时跟踪轨道切换，触发滑键滑动判定（rule 3 滑入 / rule 4 滑出）
	if event is InputEventScreenDrag and event.index in touch_positions:
		_handle_slide_drag(event.index, touch_positions[event.index], event_time_ms)

func _input(event: InputEvent) -> void:

	if ui.current_state == ui.UIState.PLAY_VIEW and event is InputEventKey:
		accept_event()
		if event.is_echo():
			return

		if parent_node.key_map and event.keycode in parent_node.key_map:
			if parent_node.is_pause:
				accept_event()
				return

			if event.pressed:
				var idx = parent_node.key_map.find(event.keycode)
				var event_time_ms := _get_realtime_position_ms()
				pressed_keys[event.keycode] = idx
				# 使用统一的判定函数，支持所有音符类型
				var bn := judge_note_at_lane(idx, idx, event_time_ms)
				if bn >= 0:
					if _st_type[bn] == FlowNote.NoteType.Long:
						_hold_long_note(event.keycode, bn)
				else:
					parent_node.lane_area.light_lane(idx)
			else:
				pressed_keys.erase(event.keycode)
				var released_lane = parent_node.key_map.find(event.keycode)
				_handle_release(event.keycode, _get_realtime_position_ms(), released_lane)
		elif event.keycode == KEY_ESCAPE and event.pressed:
			parent_node.show_or_hide_menu()

# ========== 触摸/键盘判定 ==========

## 处理触摸按下（平行数组版：候选为 seq 索引数组，判定结果写 _rt_*）
func _handle_press(touch_id: int, pos: Vector2, input_time_ms: float = -1.0) -> void:
	var judge_time_ms := input_time_ms
	if judge_time_ms < 0.0:
		judge_time_ms = _get_realtime_position_ms()

	# 去重逻辑：部分 Android 设备单次触摸会同时发送鼠标+触摸双事件
	var should_dedup := false
	if touch_id == -1:
		should_dedup = abs(judge_time_ms - _last_press_time_ms) <= _PRESS_DEDUP_MS and pos.distance_to(_last_press_pos) <= _PRESS_DEDUP_DISTANCE
	else:
		should_dedup = _last_press_was_mouse and abs(judge_time_ms - _last_press_time_ms) <= _PRESS_DEDUP_MS and pos.distance_to(_last_press_pos) <= _PRESS_DEDUP_DISTANCE
	_last_press_was_mouse = touch_id == -1
	_last_press_time_ms = judge_time_ms
	_last_press_pos = pos
	if should_dedup:
		return

	# 新建手势状态（记录按下/当前覆盖轨道集合，供拖动 rule 3/4 差集检测与抬手门控）
	var g: Dictionary = {
		"press_pos": pos,
		"press_time_ms": judge_time_ms,
		"last_pos": pos,
		"last_time_ms": judge_time_ms,
		"lanes": _finger_lanes(pos.x),
	}
	_gestures[touch_id] = g

	var estimated_lane := _estimate_lane_from_x(pos.x)
	var candidate_notes: Array = _get_notes_near_lane(estimated_lane)
	candidate_notes = candidate_notes.filter(func(i):
		return not (_rt_flags[i] & F_JUDGED) and not (_rt_flags[i] & F_REMOVED) \
			and not (_rt_flags[i] & F_HELD) and _rt_claimed[i] < 0
	)
	if candidate_notes.is_empty():
		return

	var note_index := note_judger.find_best_note_index(pos, candidate_notes, note_judge_width)
	if note_index < 0:
		return

	# 完美滑块模式：点击滑块不按点块判——仅当处于完美窗口内才以滑块(Perfect)计分，
	# 否则跳过本次点击（不判定其他音符）
	if only_perfect_slides and _st_type[note_index] == FlowNote.NoteType.Slide:
		if abs(_st_start[note_index] - judge_time_ms) > float(judge_windows["perfect"]):
			return
		if parent_node.play_mode:
			_manual_off_scheduler.trigger_from_sequence(KeySequenceManager.instance, note_index)
		_judge_note(note_index, true, judge_time_ms, -1, "Perfect")
		return

	if parent_node.play_mode:
		_manual_off_scheduler.trigger_from_sequence(KeySequenceManager.instance, note_index)
	if _st_type[note_index] == FlowNote.NoteType.Slide:
		# 点击滑块按点块(Block)计分（固定倍率并重置滑块衰减链）
		_judge_note(note_index, true, judge_time_ms, FlowNote.NoteType.Block)
	else:
		_judge_note(note_index, true, judge_time_ms)
	if _st_type[note_index] == FlowNote.NoteType.Long:
		_hold_long_note(touch_id, note_index, pos.x)
	# 同时视为滑入轨道（rule 3）：接住列内其余已过线仍在 great 窗口的滑键
	# 完美滑块模式下滑键仅按滑动判定，点击不接
	if not only_perfect_slides:
		for lane in g["lanes"]:
			_judge_slides_entering_lane(lane, pos, judge_time_ms)

## 处理触摸松开 释放长条音符
func _handle_release(touch_id: int, input_time_ms: float = -1.0, released_lane: int = -1) -> void:
	var judge_time_ms := input_time_ms if input_time_ms >= 0.0 else _get_realtime_position_ms()

	# rule 4（抬手 = 滑出轨道）：判定当前轨道「未过线但在 perfect 窗口内」的滑键。
	# 键盘抬手（released_lane >= 0）不参与：键盘点击滑键已即时判定，无触摸滑动逻辑
	if released_lane < 0 and check_slide_when_finger_up:
		_judge_slides_on_lift(touch_id, judge_time_ms)
	_clear_gesture(touch_id)

	if touch_id not in active_holds:
		return

	var note_index: int = active_holds[touch_id]
	_rt_flags[note_index] &= ~F_HELD

	# 移除音符
	_remove_note(note_index)
	active_holds.erase(touch_id)

# 处理触摸拖动
func _handle_touch_drag(touch_id: int, pos: Vector2) -> void:
	if touch_id not in active_holds:
		return

	var note_index: int = active_holds[touch_id]
	if not (_rt_flags[note_index] & F_HELD) or _rt_held_by[note_index] != touch_id:
		return

	if is_nan(_rt_hold_press_x[note_index]):
		return  # 非触摸来源（键盘/自动模式）不跟踪手势

	# 批量绘制版：平移 cached_x（相对 spawn 基准偏移），drawer 在 _draw 中读取
	_rt_x[note_index] = _rt_x_base[note_index] + (pos.x - _rt_hold_press_x[note_index])
	_rt_cx[note_index] = _rt_x[note_index] + note_visual_width * 0.5
	if _note_drawer:
		_note_drawer.request_redraw()

# 按住长条音符
# 注意：调用方负责在调用此函数之前已通过 _judge_note() 完成判定
func _hold_long_note(touch_id: int, note_index: int, press_x: float = NAN) -> void:
	# 兜底：长条进入按住态后不应再走未判定 Miss 分支
	_rt_flags[note_index] |= F_JUDGED
	_rt_flags[note_index] |= F_HELD
	_rt_held_by[note_index] = touch_id
	_rt_hold_press_x[note_index] = press_x  # NAN 表示非触摸来源（键盘/自动模式），_handle_touch_drag 将跳过
	# 为新长条分配唯一实例 ID（用于 ScoreCalculator 独立衰减链）
	if _rt_long_id[note_index] < 0:
		_rt_long_id[note_index] = _alloc_long_id()
	active_holds[touch_id] = note_index

# ========== 滑键滑动判定（事件驱动模型 rule 2/3/4） ==========

## 结束触点手势（抬起时调用）
func _clear_gesture(touch_id: int) -> void:
	_gestures.erase(touch_id)

## 以 Slide 类型判定一个滑键（进入滑块衰减链）
## 滑动事件（rule 2/3/4）与 rule 1 点按的「视为滑入」均走此入口
func _judge_slide_as_slide(note_index: int, judge_time_ms: float) -> void:
	if _rt_flags[note_index] & (F_JUDGED | F_REMOVED | F_HELD):
		return
	if parent_node.play_mode:
		_manual_off_scheduler.trigger_from_sequence(KeySequenceManager.instance, note_index)
	_judge_note(note_index, false, judge_time_ms)

## 滑键是否可被滑动判定：Slide 类型 + 未判/未移除/未按住 + 手指在判定列内（半宽 = note_judge_width/2）
func _is_slide_catchable(note_index: int, pos: Vector2) -> bool:
	if _st_type[note_index] != FlowNote.NoteType.Slide:
		return false
	if _rt_flags[note_index] & (F_JUDGED | F_REMOVED | F_HELD):
		return false
	if abs(pos.x - _rt_cx[note_index]) > note_judge_width * 0.5:
		return false
	return true

## rule 3 滑入：判定该轨道已过线但仍在 great 窗口内的滑键（仅本轨道，不扫相邻轨）
func _judge_slides_entering_lane(lane: int, pos: Vector2, judge_time_ms: float) -> void:
	var great := float(judge_windows["great"])
	for note_index in _notes_by_lane.get(lane, []):
		if not _is_slide_catchable(note_index, pos):
			continue
		if judge_time_ms < _st_start[note_index] or judge_time_ms > _st_start[note_index] + great:
			continue
		_judge_slide_as_slide(note_index, judge_time_ms)

## rule 4 滑出/抬手：判定该轨道未过线但在 perfect 窗口内的滑键（仅本轨道，不扫相邻轨）
func _judge_slides_exiting_lane(lane: int, pos: Vector2, judge_time_ms: float) -> void:
	var perfect := float(judge_windows["perfect"])
	for note_index in _notes_by_lane.get(lane, []):
		if not _is_slide_catchable(note_index, pos):
			continue
		if judge_time_ms >= _st_start[note_index] or judge_time_ms < _st_start[note_index] - perfect:
			continue
		_judge_slide_as_slide(note_index, judge_time_ms)

## 手指拖动：覆盖轨道集合差集触发 rule 3/4（新进入=滑入，退出=滑出）
func _handle_slide_drag(touch_id: int, pos: Vector2, input_time_ms: float = -1.0) -> void:
	if not _gestures.has(touch_id):
		return
	var judge_time_ms := input_time_ms
	if judge_time_ms < 0.0:
		judge_time_ms = _get_realtime_position_ms()
	var g: Dictionary = _gestures[touch_id]
	# 覆盖集合变化前的旧位置（手指仍在旧轨道内），rule 4 用它判断手指是否在该滑键列内
	var prev_pos: Vector2 = g["last_pos"]
	g["last_pos"] = pos
	g["last_time_ms"] = judge_time_ms

	var new_lanes: Array = _finger_lanes(pos.x)
	var old_lanes: Array = g["lanes"]
	if new_lanes == old_lanes:
		return
	for lane in new_lanes:
		if not lane in old_lanes:
			_judge_slides_entering_lane(lane, pos, judge_time_ms)
	for lane in old_lanes:
		if not lane in new_lanes:
			_judge_slides_exiting_lane(lane, prev_pos, judge_time_ms)
	g["lanes"] = new_lanes

## 手指当前覆盖的轨道集合：轨道宽度 = 音符判定宽度（默认即音符宽度），窄轨下可同时覆盖多轨
func _finger_lanes(x: float) -> Array:
	var lc: int = parent_node.get_lane_count()
	if lc <= 1:
		return [0]
	var half_judge := note_judge_width * 0.5
	var lanes: Array = []
	for lane in range(lc):
		if abs(_note_center_x_for_lane(lane) - x) <= half_judge:
			lanes.append(lane)
	return lanes

## 轨道 lane 内音符的统一中心 X（与 cached_center_x 公式一致；音符始终以轨道中心为基准居中）
func _note_center_x_for_lane(lane: int) -> float:
	var lane_area = parent_node.lane_area
	return lane_area.get_lane_x(lane) + (lane_area.get_lane_width() - note_visual_width) / 2.0 + note_visual_width * 0.5

## 滑键到达判定线的瞬间回调（rule 2 hold-catch）：手指/键盘键覆盖其轨道即接住
## 返回是否被判定。由 _update_block_note_fall 过线分支调用，每音符仅触发一次
func _check_slide_stat(note_index: int) -> bool:
	# 键盘：对应轨道有按键被按住 → 过线接住
	for keycode in pressed_keys:
		if pressed_keys[keycode] == _st_lane[note_index]:
			if parent_node.play_mode:
				_manual_off_scheduler.trigger_from_sequence(KeySequenceManager.instance, note_index)
			if only_perfect_slides:
				_judge_note(note_index, false, _st_start[note_index], -1, "Perfect")
			else:
				_judge_note(note_index)
			return true

	# 触摸 hold-catch（rule 2）：手指覆盖音符所在轨道即接住
	for candidate_touch_id in touch_positions:
		if not _gestures.has(candidate_touch_id):
			continue
		if not _st_lane[note_index] in _finger_lanes(touch_positions[candidate_touch_id].x):
			continue
		_judge_slide_as_slide(note_index, _synced_current_time)
		return true
	return false

## 抬手判定：判定当前所在轨道「未过线但在 perfect 窗口内」的滑键（含原地抬手）
## 由「抬手时判定滑块」设置控制的入口（_handle_release 中调用）
func _judge_slides_on_lift(touch_id: int, input_time_ms: float = -1.0) -> void:
	if not _gestures.has(touch_id):
		return
	var g: Dictionary = _gestures[touch_id]
	var judge_time_ms := input_time_ms
	if judge_time_ms < 0.0:
		judge_time_ms = _get_realtime_position_ms()
	# 抬手即判定所在轨道未过线但在完美窗口内的滑键（含原地抬手）
	for lane in _finger_lanes(g["last_pos"].x):
		_judge_slides_exiting_lane(lane, g["last_pos"], judge_time_ms)

## 键盘模式专用：在指定轨道范围内查找最合适的音符并完成判定
## 触摸模式请使用 _handle_press()（通过 NoteJudger 实现）
## 返回判定的 seq 索引（-1=未判定）
func judge_note_at_lane(lane_l: int, lane_r: int, input_time_ms: float = -1.0) -> int:
	var best_note: int = -1
	var best_score: float = INF

	# 使用轨道索引加速：只遍历目标轨道范围内的音符
	var candidate_notes: Array = []
	for lane in range(lane_l, lane_r + 1):
		if _notes_by_lane.has(lane):
			candidate_notes.append_array(_notes_by_lane[lane])

	for i in candidate_notes:
		if _rt_flags[i] & (F_HELD | F_JUDGED | F_REMOVED | F_CAN_JUDGE):
			continue

		# 代表 Y 坐标：Long 与 Block/Slide 统一用 _rt_cy
		var note_y: float = _rt_cy[i]

		# 先现先判：选最靠近底部（note_y 最大）的音符
		var score: float = -note_y
		if score < best_score:
			best_score = score
			best_note = i

	if best_note >= 0:
		if parent_node.play_mode:
			_manual_off_scheduler.trigger_from_sequence(KeySequenceManager.instance, best_note)
		# 完美滑块模式：点击滑块不按点块判——仅处于完美窗口内以滑块(Perfect)计分，否则跳过本次点击
		if only_perfect_slides and _st_type[best_note] == FlowNote.NoteType.Slide:
			var eff_time := input_time_ms if input_time_ms >= 0.0 else _get_realtime_position_ms()
			if abs(_st_start[best_note] - eff_time) > float(judge_windows["perfect"]):
				return -1
			_judge_note(best_note, true, input_time_ms, -1, "Perfect")
		elif _st_type[best_note] == FlowNote.NoteType.Slide:
			# 键盘点击滑块按点块(Block)计分（重置滑块衰减链）；与滑过接住（Slide 计分）路径互斥
			_judge_note(best_note, true, input_time_ms, FlowNote.NoteType.Block)
		else:
			_judge_note(best_note, true, input_time_ms)
	return best_note

func _trigger_touch_vibration() -> void:
	if not Input.has_method("vibrate_handheld"):
		return
	if not (OS.has_feature("mobile") or OS.has_feature("android") or OS.has_feature("ios")):
		return
	if ConfigManager.instance.get_int("Playback", "vibrate_on_touch", 1) != 1:
		return
	var duration_ms = max(1.0, ConfigManager.instance.get_int("Playback", "vibration_duration", 20))
	Input.vibrate_handheld(duration_ms, 0.5)

func _generate_particle(type: String, pos: Vector2) -> void:
	# 取基础/散射粒子包键（_reload_spark_config 已按名字解析好，空=该层关闭，此处防御性校验）
	var base_key: String = spark_presets.get(type, "")
	var emitter_key: String = spark_emitters.get(type, "")
	if base_key.is_empty() and emitter_key.is_empty():
		return
	_particle_drawer.spawn(base_key, emitter_key, pos,
		spark_scalings.get(type, 1.0), spark_alphas.get(type, 1.0), spark_emitter_scales.get(type, 1.5))

## 读取全部判定特效配置（基础粒子/散射粒子 preset + 整体缩放/不透明度/发射器缩放）
## 供 init_flow_area 初始化与 config_changed 热更新共用
func _reload_spark_config() -> void:
	for judge in _JUDGE_TYPES:
		var jl_str := judge.to_lower()
		spark_presets[judge] = ParticleMGR.get_particle_pack_by_name(
			ConfigManager.instance.get_string("Lane", jl_str + "_spark_preset", ""))
		spark_emitters[judge] = ParticleMGR.get_particle_pack_by_name(
			ConfigManager.instance.get_string("Lane", jl_str + "_spark_emitter", ""))
		# 配置存百分比，预换算为倍率/不透明度（0-1），spawn 热路径直接取用免除法
		spark_scalings[judge] = ConfigManager.instance.get_float("Lane", jl_str + "_spark_scaling", 100) / 100.0
		spark_alphas[judge] = ConfigManager.instance.get_float("Lane", jl_str + "_spark_alpha", 100) / 100.0
		spark_emitter_scales[judge] = ConfigManager.instance.get_float("Lane", jl_str + "_spark_emitter_scaling", 150) / 100.0

## 核心判定入口（平行数组版）：note_index 为 seq 索引
func _judge_note(note_index: int, trigger_vibration: bool = false, input_time_ms: float = -1.0,
		block_type_override: int = -1, result_override: String = ""):
	# 防止重复判定：如果该 note 已被判定过，直接返回
	if _rt_flags[note_index] & F_JUDGED:
		return

	# input_time_ms 来自 _get_realtime_position_ms() 或 note.start_time（与 current_time 同坐标系）
	var judge_time_ms := input_time_ms if input_time_ms >= 0.0 else _get_realtime_position_ms()
	var time_diff = _st_start[note_index] - judge_time_ms  # 毫秒，优先使用事件时刻的实时播放位置
	var abs_diff = abs(time_diff)
	var result: String = result_override

	if result.is_empty():
		var jw := judge_windows
		var perfect_thr := float(jw["perfect"])
		if abs_diff <= perfect_thr:
			result = "Perfect"
		elif abs_diff <= float(jw["great"]):
			result = "Great"
		elif abs_diff <= float(jw["good"]):
			result = "Good"
		else:
			result = "Bad"

	# 转换为秒，传递给 ScoreCalculator 所需的数据
	var timing_sec: float = abs_diff / 1000.0
	var signed_offset_sec: float = time_diff / 1000.0
	# NoteType 与 BlockType 已统一同名同值；点击滑块时 override 为 Block（按点块计分）
	var block_type: int = block_type_override if block_type_override >= 0 else _st_type[note_index]

	# 标记该 note 已被判定，防止重复
	_rt_flags[note_index] |= F_JUDGED
	var hit_pos := Vector2(_rt_cx[note_index], _rt_cy[note_index])

	note_judged.emit(result, "%s%.1f ms" % ["+" if time_diff>=0 else "", time_diff],
		block_type, timing_sec, signed_offset_sec)
	if trigger_vibration:
		_trigger_touch_vibration()
	if _st_type[note_index] != FlowNote.NoteType.Long:
		_remove_note(note_index)

	# 特效（轨道光束颜色与音符一致：交替轨道颜色开启时按轨道色点亮）
	get_parent().lane_area.light_lane(_st_lane[note_index], _rt_color[note_index])

	var preset = spark_presets.get(result, "")
	var emitter = spark_emitters.get(result, "")
	if (not preset.is_empty() or not emitter.is_empty()) and _st_type[note_index] != FlowNote.NoteType.Long and hit_pos != Vector2.ZERO:
		_generate_particle(result, hit_pos)

var _is_pause: bool = false
var _cached_viewport_height: float = 0.0

func _notification(what: int) -> void:
	# 视口尺寸变化时更新缓存（全屏锚定，size == 视口大小），_process 不再每帧查询
	if what == NOTIFICATION_RESIZED:
		_cached_viewport_height = size.y
		if _note_drawer:
			_note_drawer.set_viewport_height(_cached_viewport_height)

## 【方案C】同步当前播放时间（毫秒）
## 由 PlayView._process() 每帧调用。time_ms = 音频钟（判定用）；render_time_ms = 渲染钟（平滑视觉，可选）
func set_current_time(time_ms: float, render_time_ms: float = -1.0) -> void:
	_synced_current_time = time_ms
	_render_time_ms = render_time_ms if render_time_ms >= 0.0 else time_ms

func _get_realtime_position_ms() -> float:
	var playback_mgr = MidiPlaybackManager.instance
	if playback_mgr:
		return playback_mgr.get_realtime_position_ms()
	return _synced_current_time

func _process(delta: float) -> void:
	if not parent_node:
		return

	# 暂停处理（音符下落由 _process 时间驱动，暂停时下方提前 return 即冻结）
	if parent_node.is_pause and not _is_pause:
		_is_pause = true
	elif not parent_node.is_pause and _is_pause:
		_is_pause = false

	if _is_pause:
		return

	# 驱动手动音符的 NoteOff（按播放位置触发，暂停时自动停）
	_manual_off_scheduler.process(_synced_current_time)

	# 生成音符（从 _st_* 按 start_time 判断是否进入下落提前量窗口）
	while note_idx < _count and _st_start[note_idx] < parent_node.current_time + note_generation_lead_time:
		_spawn_note(note_idx)
		note_idx += 1

	# 每帧更新所有活跃音符位置
	# Block/Slide/Long 统一写 _rt_* 数组，drawer 在 _draw 中批量绘制
	# 按类型分桶遍历：免逐音符类型分发；同步/渲染时间提升为局部变量
	for type_key in _BLOCK_SLIDE_TYPES:
		for color_key in _note_buckets[type_key]:
			for note_index in _note_buckets[type_key][color_key]:
				_update_block_note_fall(note_index, _synced_current_time, _render_time_ms)
	for color_key in _note_buckets[FlowNote.NoteType.Long]:
		for note_index in _note_buckets[FlowNote.NoteType.Long][color_key]:
			# 自动模式
			if auto_mode and not (_rt_flags[note_index] & F_HELD):
				if _synced_current_time + 5 >= _st_start[note_index]:
					_auto_click(note_index)

			_update_long_note_fall(note_index, _synced_current_time, _render_time_ms)

	# 位置已更新，通知 Node2D 批量绘制器重绘
	if _note_drawer and has_active_notes():
		_note_drawer.request_redraw()

	# 帧末清理已移除音符（延迟到遍历结束后，避免遍历中 mutate 数组）
	if _needs_bucket_sweep:
		_sweep_removed_from_buckets()

	# 更新长条音符的按住进度和显示
	for touch_id in active_holds.keys():
		var note_index: int = active_holds[touch_id]
		if not (_rt_flags[note_index] & F_HELD):
			continue

		var long_end_time = _st_start[note_index] + max(0.0, _st_dur[note_index])
		# 结束跟随渲染时钟（而非补偿判定钟）：补偿后判定钟在曲终被钳制到不满 delay，
		# 会让长条尾部提前/无法按视觉滑完而残留、回缩。用渲染钟保证"尾巴滑到判定线即收尾"。
		if _render_time_ms >= long_end_time:
			if not spark_presets.get("Perfect", "").is_empty() or not spark_emitters.get("Perfect", "").is_empty():
				_generate_particle("Perfect", Vector2(_rt_cx[note_index], _rt_tail_cy[note_index]))
			_remove_note(note_index)
			active_holds.erase(touch_id)
			continue

		# 加分（长条持续 tick 只加分，不加 combo；combo 仅由首判增加）
		if _rt_cooldown[note_index] > 0.25: # 0.25是触发频率
			_rt_cooldown[note_index] = 0
			long_holding.emit(_rt_long_id[note_index])
		else:
			_rt_cooldown[note_index] += delta

## 键序列管理器（薄封装）
## 完整算法与输出存储已迁移到 C# KeySequenceCore；本节点只保留：
##   - 配置加载 / 单任务槽 / 全量生成 / 缓存
##   - 向 GDScript 消费方（PlayView/FlowArea/ManualNoteOffScheduler/MidiPlaybackManager）暴露 C# 输出的只读访问器
## 输出（game sequences / 背景 / 手动 / 自动）全部以紧凑平行数组存放于 C#，消除 GDScript 数万对象开销
class_name KeySequenceManager
extends Node

## 单例实例
static var instance: KeySequenceManager

## 块类型枚举（与 ScoreCalculator.BlockType / FlowNote.NoteType 保持同名同值）
enum BlockType {
	Block = 0,  # 点块（duration <= short_block_threshold）
	Slide = 1,  # 滑块（duration <= instant_block_threshold）
	Long = 2    # 长条（duration > short_block_threshold，需按住）
}

## ========== 屏幕/键位 ==========
var screen_width: float = 1920.0
var key_width: float = 40.0

## ========== 键生成配置参数 ==========
var lane_count: int = 12
var density_cap_per_sec: int = 8
var instant_block_threshold: float = 0.2
var short_block_threshold: float = 1.0
var min_tap_interval: float = 1.0
var cooldown_seconds: float = 2.0
var max_touch_move_velocity: float = 300.0
var max_touch_count: int = 2
var generate_instant_connect: bool = true
var generate_short_connect: bool = true
var max_instant_connect_seconds: float = 1.0
var min_block_spacing: int = 1
var hand_model_enabled: bool = true

## ========== C# 核心与运行态 ==========
var _core: KeySequenceCore = null
var _cache_key: String = ""
## 单任务槽（唯一 join 点见 _finalize_task；多等待方只轮询槽）
var _generate_task_id: int = -1

func _ready() -> void:
	if instance == null:
		instance = self
	else:
		queue_free()
		return
	add_to_group("singleton")
	_load_config_parameters()
	if EvtBus:
		EvtBus.config_changed.connect(_on_config_changed)

func set_screen_size(width: float) -> void:
	screen_width = width

func _get_core() -> KeySequenceCore:
	if _core == null:
		_core = KeySequenceCore.new()
	return _core

## 将当前配置 + 时间参数写入 C# 核心（worker 线程调用；每次运行前应用）
func _configure_core(core: KeySequenceCore, timebase: int, bpm_timeline_data: Array) -> void:
	core.Configure(lane_count, density_cap_per_sec, instant_block_threshold, short_block_threshold,
		min_tap_interval, cooldown_seconds, max_touch_move_velocity, max_touch_count,
		generate_instant_connect, generate_short_connect, max_instant_connect_seconds,
		min_block_spacing, hand_model_enabled, key_width, screen_width)
	var bpm_ticks := PackedInt32Array()
	var bpm_values := PackedFloat32Array()
	for e in bpm_timeline_data:
		bpm_ticks.append(int(e.get("tick", 0)))
		bpm_values.append(float(e.get("bpm", 120.0)))
	core.SetMidiTimeParameters(timebase if timebase > 0 else 480, bpm_ticks, bpm_values)

## ========== 单任务槽 ==========
## join 指定任务并清空槽（幂等：仅当该任务仍是当前槽任务时 join + 清槽）
func _finalize_task(task_id: int) -> void:
	if task_id == -1:
		return
	if _generate_task_id == task_id:
		WorkerThreadPool.wait_for_task_completion(task_id)
		_generate_task_id = -1

func _launch_generate_task(run: Callable) -> int:
	while _generate_task_id != -1:
		# 槽内任务已完成但消费者被中断/放弃未 finalize：就地释放，避免后续生成永久等待槽
		if WorkerThreadPool.is_task_completed(_generate_task_id):
			_generate_task_id = -1
			break
		await Engine.get_main_loop().process_frame
	var task_id := WorkerThreadPool.add_task(run, false, "KSM generate_keys")
	_generate_task_id = task_id
	return task_id

func await_generate_keys(task_id: int) -> void:
	if task_id == -1:
		return
	while not WorkerThreadPool.is_task_completed(task_id):
		await Engine.get_main_loop().process_frame
	_finalize_task(task_id)
	while _generate_task_id != -1:
		await Engine.get_main_loop().process_frame

## ========== 键序列生成（worker 线程）==========
## SOA 输入：arrays = [pitches, velocities, start_ticks, durations, track_indices, channels]
## enabled_indices: PackedInt32Array，SOA 索引（start_tick 升序），即启用子集
## 全量生成：worker 内一次 RunGenerateGather 完成全部序列，完成后返回（不再流式抢先）
func _run_generate(arrays: Array, enabled_indices: PackedInt32Array,
		cache_key: String, timebase: int, bpm_timeline_data: Array) -> void:
	var core := _get_core()
	_configure_core(core, timebase, bpm_timeline_data)
	# RunGenerateGather 参数顺序：soaStartTick, soaDurTick, soaPitch, soaVelocity, soaTrack, soaChannel
	core.RunGenerateGather(arrays[2], arrays[3], arrays[0], arrays[1], arrays[4], arrays[5], enabled_indices)
	_cache_key = cache_key
	GLogger.debug("KSM generate done, seq=%d" % core.GameSeqCount, "KSM")

func _build_cache_key(midi_id: String, enabled_indices: PackedInt32Array) -> String:
	# 自定义 Godot 构建的 PackedInt32Array 无 hash()；用手动滚动哈希（确定性，同内容必同键）
	var h: int = 2166136261
	for i in enabled_indices.size():
		h = (h * 16777619) ^ (enabled_indices[i] & 0xFFFFFFFF)
	# 配置指纹进 cache_key：生成参数变更（轨道数/阈值/冷却等）后旧缓存必须整体失效，
	# 否则同 midi + 同启用子集仍命中旧配置的过期序列；也消除 _on_config_changed 无法可靠
	# 拦截进行中 worker 写回旧键的竞态（旧键带旧指纹，与新配置请求永不匹配）
	return _config_fingerprint() + "|" + midi_id + str(h)

## 生成参数指纹（cache_key 组成部分）：任一生成相关配置变更即视为全新缓存域
func _config_fingerprint() -> String:
	return "%d_%d_%d_%d_%.4f_%.4f_%.4f_%.4f_%.4f_%d_%d_%.4f_%d_%.2f_%.1f" % [
		lane_count, density_cap_per_sec, max_touch_count, min_block_spacing,
		instant_block_threshold, short_block_threshold, min_tap_interval,
		cooldown_seconds, max_touch_move_velocity,
		int(generate_instant_connect), int(generate_short_connect), max_instant_connect_seconds,
		int(hand_model_enabled), key_width, screen_width
	]

## 启动键序列生成（WorkerThreadPool 后台线程），返回 task_id
## 返回约定：-1=无启用音符或命中缓存（直接完成）；>=0=独立启动的任务，须经 await_generate_keys 等待完成
func generate_keys_async(soa_arrays: Array, enabled_indices: Array,
		midi_id: String = "", timebase: int = -1, bpm_timeline_data: Array = []) -> int:
	if enabled_indices.is_empty():
		_get_core().ClearOutput()
		_cache_key = ""
		return -1
	var packed := PackedInt32Array(enabled_indices)
	var cache_key := _build_cache_key(midi_id, packed)
	# 命中缓存：直接复用 C# 已保存输出，无需重新生成
	if cache_key == _cache_key and _get_core().GameSeqCount > 0:
		# 槽内若有进行中任务，其完成时会覆盖共享输出与 _cache_key：
		# 此时不能再当命中直接返回（命中方可能读到该任务刚写出的其他键序列），
		# 降级为 miss 重新排队生成本键，等槽释放后产出正确输出
		if _generate_task_id != -1:
			return await _launch_generate_task(func():
				_run_generate(soa_arrays, packed, cache_key, timebase, bpm_timeline_data)
			)
		GLogger.debug("KSM generate HIT cache, seq=%d" % _get_core().GameSeqCount, "KSM")
		return -1
	return await _launch_generate_task(func():
		_run_generate(soa_arrays, packed, cache_key, timebase, bpm_timeline_data)
	)

## ========== C# 输出访问器（只读）==========
func seq_count() -> int:
	return _get_core().GameSeqCount if _core else 0
func seq_key_id(i: int) -> int: return _core.SeqKeyId(i)
func seq_pitch(i: int) -> int: return _core.SeqPitch(i)
func seq_start_ms(i: int) -> float: return _core.SeqStartMs(i)
func seq_dur_ms(i: int) -> float: return _core.SeqDurMs(i)
func seq_type(i: int) -> int: return _core.SeqType(i)
func seq_lane(i: int) -> int: return _core.SeqLane(i)

## 输入（enabled 子集）音符访问器
func input_pitch_at(i: int) -> int: return _core.InputPitchAt(i)
func input_velocity_at(i: int) -> int: return _core.InputVelocityAt(i)
func input_track_at(i: int) -> int: return _core.InputTrackAt(i)
func input_channel_at(i: int) -> int: return _core.InputChannelAt(i)
func input_start_tick_at(i: int) -> int: return _core.InputStartTickAt(i)

## 分类访问器（manual/auto/背景 索引均指向 enabled 输入数组）
func manual_count() -> int: return _core.ManualCount
func manual_at(i: int) -> int: return _core.ManualAt(i)
func auto_count() -> int: return _core.AutoCount
func auto_at(i: int) -> int: return _core.AutoAt(i)
func bg_count() -> int: return _core.BgNoteCount
func bg_at(i: int) -> int: return _core.BgNoteAt(i)

## ========== 配置 ==========
func _validate_min_block_spacing(value: int) -> int:
	return 1 if (value < 0 or value >= lane_count) else value

func _load_config_parameters() -> void:
	var cfg = ConfigManager.instance
	lane_count = cfg.get_int("Lane", "lane_count", 12)
	var gen_cfg = "Generator"
	instant_block_threshold = cfg.get_float(gen_cfg, "instant_block_max_time", 0.2)
	short_block_threshold = cfg.get_float(gen_cfg, "short_block_max_time", 1.0)
	max_touch_count = cfg.get_int(gen_cfg, "max_simultaneous_blocks", 2)
	min_tap_interval = cfg.get_float(gen_cfg, "min_tap_interval", 1.0)
	cooldown_seconds = cfg.get_float(gen_cfg, "min_touch_cooldown_time", 2.0)
	max_touch_move_velocity = cfg.get_float(gen_cfg, "max_touch_move_speed", 300.0)
	density_cap_per_sec = cfg.get_int(gen_cfg, "max_block_coalesce_time", 8)
	min_block_spacing = _validate_min_block_spacing(cfg.get_int("Judge", "min_block_spacing", 1))
	var app_cfg = "Appearance"
	generate_short_connect = cfg.get_bool(app_cfg, "generate_short_connect", true)
	generate_instant_connect = cfg.get_bool(app_cfg, "generate_instant_connect", true)
	max_instant_connect_seconds = cfg.get_float(app_cfg, "instant_connect_max_time", 1.0)
	key_width = cfg.get_float(app_cfg, "block_size", key_width)
	var keyboard_mode = cfg.get_int("Lane", "keyboard_mode", 0) == 1
	if keyboard_mode:
		max_touch_move_velocity = 999999.0
		hand_model_enabled = false
		var keys = ConfigParser.parse_keyboard_keys(cfg.get_string("Lane", "keyboard_mode_keys", "A,S,D,F,J,K,L,;"))
		if keys.size() > 0:
			lane_count = keys.size()

## 配置变更：清除缓存并要求重新生成
func _on_config_changed(key: String, section: String, value: Variant) -> void:
	_cache_key = ""
	match section:
		"Lane":
			match key:
				"lane_count":
					lane_count = int(value)
				"keyboard_mode":
					var km = int(value) == 1
					if km:
						max_touch_move_velocity = 999999.0
						hand_model_enabled = false
						var keys = ConfigParser.parse_keyboard_keys(ConfigManager.instance.get_string("Lane", "keyboard_mode_keys", "A,S,D,F,J,K,L,;"))
						if keys.size() > 0:
							lane_count = keys.size()
					else:
						max_touch_move_velocity = ConfigManager.instance.get_float("Generator", "max_touch_move_speed", 300.0)
						hand_model_enabled = true
						lane_count = ConfigManager.instance.get_int("Lane", "lane_count", 12)
				"keyboard_mode_keys":
					if ConfigManager.instance.get_int("Lane", "keyboard_mode", 0) == 1:
						var new_keys = ConfigParser.parse_keyboard_keys(str(value))
						if new_keys.size() > 0:
							lane_count = new_keys.size()
		"Generator":
			match key:
				"instant_block_max_time":
					instant_block_threshold = float(value)
				"short_block_max_time":
					short_block_threshold = float(value)
				"max_simultaneous_blocks":
					max_touch_count = int(value)
				"min_tap_interval":
					min_tap_interval = float(value)
				"min_touch_cooldown_time":
					cooldown_seconds = float(value)
				"max_touch_move_speed":
					if ConfigManager.instance.get_int("Lane", "keyboard_mode", 0) == 0:
						max_touch_move_velocity = float(value)
				"max_block_coalesce_time":
					density_cap_per_sec = int(value)
		"Appearance":
			match key:
				"generate_short_connect":
					generate_short_connect = ConfigManager.parse_bool(value, true)
				"generate_instant_connect":
					generate_instant_connect = ConfigManager.parse_bool(value, true)
				"instant_connect_max_time":
					max_instant_connect_seconds = float(value)
				"block_size":
					key_width = float(value)
		"Judge":
			if key == "min_block_spacing":
				min_block_spacing = _validate_min_block_spacing(int(value))

## 清空 C# 输出与缓存（PlayView/离开 MidiList 项时调用，释放常驻）
func clear_sequences() -> void:
	if _core:
		_get_core().ClearOutput()
	_cache_key = ""

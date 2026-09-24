## MIDI播放管理器
## 负责MIDI文件的加载、播放、轨道选择和音源管理
extends Node

class_name MidiPlaybackManager

## 单例实例
static var instance: MidiPlaybackManager

## MIDI播放器引用（唯一后端：MeltySynth C#）
var midi_player: MidiPlaybackInterface

## 当前加载的MIDI数据
var current_midi_data: MidiData

## 当前解析的音符列表
var current_notes: Array = []

## MIDI的BPM变化时间线 (用于精确时间计算)
var bpm_timeline: Array = []

## 缓存的轨道-通道乐器映射 (从 MIDI 文件中提取)
## 格式: {track_index: {channel: {bank: int, program: int}}}
var cached_track_channel_instruments: Dictionary = {}

## MIDI播放状态
var is_playing: bool = false
var is_paused: bool = false

## 当前播放位置（MIDI tick单位，NOT毫秒！）
## 注意：MidiPlayer.position使用tick单位。此属性直接来自MidiPlayer.position
## 要获取毫秒值，请使用 get_position_ms()
var position: float = 0.0

## 当前播放位置（毫秒，用于向后兼容 - 不推荐使用）
## ⚠️ 已弃用：使用 position 获取tick，或使用 get_position_ms() 获取毫秒值
var position_ms: float = 0.0

## MIDI时间基准 (ticks per beat)
var midi_timebase: int = 480

## 总时长（毫秒）
var duration_ms: float = 0.0

## 默认SoundFont路径
var default_soundfont_path: String = "res://Resources/Soundfont/GeneralUser-GS.sf2"

## 当前使用的SoundFont路径
var current_soundfont_path: String = ""
var _soundfont_preloaded_to_backend: bool = false

## 人声偏移量（毫秒）
var vocal_offset_ms: float = 0.0

## 人声是否已初始化（预卷支持）
var _vocal_initialized: bool = false
## 已加载到原生后端的 vocal 文件路径（避免重复 load）
var _vocal_loaded_path: String = ""

## 音频不同步阈值（毫秒）
var sync_threshold_ms: float = 200.0

## 音频校准延迟（毫秒，设置页音频校准写入 audio_playback_delay / audio_playback_delay_bt）
## 仅叠加到自动/背景音符与人声时钟，玩家手动触发（touch）的音符实时发声，不附加此延迟。
var _audio_delay_ms: float = 0.0

## 当前延迟预设是否为蓝牙（决定使用 audio_playback_delay_bt 还是 audio_playback_delay）
var _delay_using_bt: bool = false
## 是否已完成首次蓝牙状态检测（首次不触发音频桥重建：桥初始化时已用当前默认设备）
var _bt_state_initialized: bool = false

## 上次同步检查时的MIDI位置（毫秒）
var last_sync_check_pos_ms: float = 0.0

## MIDI播放器配置
var midi_player_config: Dictionary = {
	"max_polyphony": 96,
	"loop": false,
	"volume_db": -20.0
}

## Android 平台标志（用于降级音频复杂度）
var _is_android: bool = false

# 实时位置的同帧缓存: 避免同一帧多次调用后端导致 GetLatencyMs() 波动
# 使去重逻辑 (基于 judge_time_ms 差值) 失效
var _realtime_pos_cache: float = 0.0
var _realtime_pos_cache_frame: int = -1

# 上一帧的 raw MIDI 音频位置，用于检测 TrackView 的循环回绕。
# -1 表示尚未建立播放位置基线，避免加载新曲时把位置清零误判为循环。
var _last_raw_midi_position_ms: float = -1.0

## 信号：MIDI播放完成
signal midi_finished

func _ready() -> void:
	if instance == null:
		instance = self
	else:
		queue_free()
		return
	
	add_to_group("singleton")
	
	_initialize_backend()
	
	# 从配置文件加载音源设置
	_load_soundfont_from_config()

	# 加载音频校准延迟（按当前输出是否蓝牙选择对应预设）
	refresh_audio_delay()
	
	# 监听设置改变信号（用于动态切换MIDI后端和音源）
	if EvtBus:
		EvtBus.settings_changed.connect(_on_settings_changed)
		# 监听配置变更信号（新增，用于应对直接配置文件修改）
		EvtBus.config_changed.connect(_on_config_changed)

## 重新检测蓝牙输出并应用对应延迟预设。
## 蓝牙状态变化时（仅 Windows）重建音频桥，使输出跟随新的系统默认设备。
## 刷新时点：启动、应用焦点回归（Main._notification）、打开延迟校准窗口。
func refresh_audio_delay() -> void:
	var is_bt := AudioBtDetector.is_bluetooth_output(true)
	var state_changed := is_bt != _delay_using_bt
	var first_check := not _bt_state_initialized
	_bt_state_initialized = true
	_delay_using_bt = is_bt
	if state_changed and not first_check:
		GLogger.info("Audio output changed (bluetooth=%s), switching delay preset" % str(is_bt), "MidiPlaybackManager")
		# WASAPI 流绑定打开设备时的端点，需重建音频桥才跟随新默认设备。
		# Android 的 AAudio 独占模式 + 蓝牙初始化有风险，不重建（开局前已连蓝牙的场景初始即走蓝牙端点）。
		if OS.get_name() == "Windows" and midi_player != null:
			midi_player.recreate_audio_output()
	_apply_delay_preset()

## 按当前输出类型读取并应用延迟预设（蓝牙 → audio_playback_delay_bt，否则 audio_playback_delay）
func _apply_delay_preset() -> void:
	var key := "audio_playback_delay_bt" if _delay_using_bt else "audio_playback_delay"
	var default_value := 200 if _delay_using_bt else 0
	_audio_delay_ms = float(ConfigManager.instance.get_int("Gameplay", key, default_value))
	GLogger.info("Audio delay preset [%s] = %.0f ms" % [key, _audio_delay_ms], "MidiPlaybackManager")

## 处理设置改变信号回调（当退出SettingView时触发）
## @param setting_name: 改变的设置名 ("*" 表示所有设置)
## @param value: 设置的新值（此时未使用，因为我们直接从配置文件读取）
func _on_settings_changed(setting_name: String, value: Variant) -> void:
	GLogger.info("Settings changed event: setting_name='%s', value=%s" % [setting_name, value], "MidiPlaybackManager")

	# 如果是泛指信号或音源改变
	if setting_name == "*" or setting_name == "soundfont_select":
		# 重新读取音源配置
		GLogger.info("Reloading soundfont from settings", "MidiPlaybackManager")
		_load_soundfont_from_config()
		GLogger.info("Soundfont reloaded successfully", "MidiPlaybackManager")
	
	# 【修复D-4】如果是泛指信号或系统时钟设置改变
	if setting_name == "*" or setting_name == "use_system_stopwatch":
		GLogger.info("Applying system stopwatch setting", "MidiPlaybackManager")
		var use_system_stopwatch = ConfigManager.instance.get_int("Playback", "use_system_stopwatch", 0) == 1
		var backend = _get_active_backend()
		if backend != null:
			backend.set_use_system_stopwatch(use_system_stopwatch)
			GLogger.info("System stopwatch mode: %s" % ("ON" if use_system_stopwatch else "OFF"), "MidiPlaybackManager")

	# 最大复音数改变（需要重新加载SoundFont才能生效）
	if setting_name == "*" or setting_name == "max_polyphony":
		GLogger.info("Polyphony setting changed, reloading soundfont", "MidiPlaybackManager")

		# 获取当前是否正在播放
		var was_playing = is_playing
		var current_pos = get_position_ms()

		# 停止播放
		if was_playing:
			stop()

		# 重新设置复音数并重新加载SoundFont
		var backend = _get_active_backend()
		if backend != null:
			# 设置新的复音数
			var max_polyphony = ConfigManager.instance.get_int("Playback", "max_polyphony", 96)
			backend.set_max_polyphony(max_polyphony)
			GLogger.info("Updated max polyphony to: %d" % max_polyphony, "MidiPlaybackManager")

			# 重新加载SoundFont使设置生效
			_load_soundfont_from_config()
			GLogger.info("Soundfont reloaded with new audio settings", "MidiPlaybackManager")

			# 如果之前正在播放，恢复播放位置
			if was_playing and current_midi_data != null:
				seek(current_pos)
				play()
				GLogger.info("Resumed playback at %.2fms" % current_pos, "MidiPlaybackManager")


func _process(_delta: float) -> void:
	var backend = _get_active_backend()
	if not is_playing or backend == null:
		return

	# MeltySynth 后端：使用毫秒位置（叠加音频校准延迟，见 _audio_delay_ms）
	position_ms = backend.get_position_ms() - _audio_delay_ms
	# 将毫秒转为tick（使用BPM时间线）
	if midi_timebase > 0:
		position = calculate_tick_from_position_with_bpm_timeline(position_ms, midi_timebase)

	var raw_midi_position_ms: float = get_raw_position_ms()
	if raw_midi_position_ms < 0.0:
		_last_raw_midi_position_ms = -1.0
	elif _last_raw_midi_position_ms >= 0.0 and raw_midi_position_ms < _last_raw_midi_position_ms - 100.0:
		# MeltySynth 在 loop=true 时只回绕 sequencer，不发 finished 信号。
		# 人声已自然结束时必须在这里显式重新定位并启动，否则只能靠 UI 开关恢复。
		if get_loop():
			_restart_vocal_for_current_position()
		_last_raw_midi_position_ms = raw_midi_position_ms
	else:
		_last_raw_midi_position_ms = raw_midi_position_ms

	# 调用自动同步逻辑
	_sync_vocal_with_midi()

## 确保该 MIDI 的轨道配置已按简介完成初始化（幂等，仅主线程调用）
## 首次进入 MidiView（统计音符数 / MPP）前必须保证已调用，使统计口径与
## TrackView / PlayView 的"按简介推荐轨道"一致；已初始化时直接返回。
## 一次性完成：
## 1) 解析简介（提取音频偏移、推荐轨道）
## 2) 应用 vocal_offset_ms
## 3) 缓存 desc_recommended_tracks
## 4) 根据 notes 应用推荐轨道到 selected_track_configs（无推荐则启用全部）
## 5) 标记 _track_config_initialized=true
## 6) 立即持久化到 DB，避免下次启动重复解析简介
func ensure_track_config_initialized(midi_data: MidiData, notes: Array) -> void:
	if midi_data == null or midi_data.is_track_config_initialized():
		return
	var desc_parse = MidiDescriptionParser.parse(midi_data.description)
	GLogger.info("[DescParse] id=%s offset_ms=%d recommended=%s difficulties=%d" % [
		midi_data.id,
		desc_parse["audio_offset_ms"],
		desc_parse["recommended_tracks"],
		desc_parse["difficulties"].size()
	], "MidiPlaybackManager")

	# 应用音频偏移
	if desc_parse["audio_offset_ms"] >= 0:
		midi_data.vocal_offset_ms = desc_parse["audio_offset_ms"]

	# 缓存推荐轨道
	midi_data.desc_recommended_tracks.clear()
	for t in desc_parse["recommended_tracks"]:
		midi_data.desc_recommended_tracks.append(int(t))

	# 根据 notes 应用推荐轨道（优先走 SOA 枚举 (track,channel)，避免 materialize 全量 NoteEvent）
	midi_data.selected_track_configs.clear()
	var recommended := midi_data.desc_recommended_tracks
	var use_recommendation := not recommended.is_empty()
	_apply_recommended_pairs(midi_data, recommended, use_recommendation, notes)
	# 回退：推荐轨道均不存在于 MIDI 时启用全部，避免无音符可见
	if use_recommendation and midi_data.selected_track_configs.is_empty():
		_apply_recommended_pairs(midi_data, recommended, false, notes)
		GLogger.info("Recommended tracks %s not found in MIDI, fell back to enabling all" % [recommended], "MidiPlaybackManager")
	elif use_recommendation:
		GLogger.info("Enabled recommended tracks from description: %s" % [recommended], "MidiPlaybackManager")
	else:
		GLogger.info("Initialized selected_track_configs with all (track, channel) pairs for new MIDI", "MidiPlaybackManager")

	midi_data.set_track_config_initialized(true)
	# 立即持久化到 DB，避免下次启动重复解析简介
	_save_runtime_config(midi_data)

## 按启用策略批量设置 (track,channel) 对（SOA 优先，避免批量建对象）
func _apply_recommended_pairs(midi_data: MidiData, recommended: Array, use_recommendation: bool, notes: Array) -> void:
	# 注意 MidiData.set_track_channel_enabled 是幂等的（内部去重），重复调用安全
	if midi_data != null and midi_data.notes_soa != null and midi_data.notes_soa.size() > 0:
		var soa := midi_data.notes_soa
		for i in range(soa.size()):
			var should_enable := true
			if use_recommendation:
				should_enable = soa.track(i) in recommended
			midi_data.set_track_channel_enabled(soa.track(i), soa.channel(i), should_enable)
		return
	for note in notes:
		if note is MidiParser.NoteEvent:
			var should_enable := true
			if use_recommendation:
				should_enable = note.track_index in recommended
			midi_data.set_track_channel_enabled(note.track_index, note.channel, should_enable)

## 加载MIDI文件
## 返回: success (bool)
func load_midi(midi_data: MidiData) -> bool:
	if midi_data == null:
		push_error("MidiData is null")
		return false

	# 加载新曲前先停止当前播放（幂等）：
	# TrackView 循环播放中直接进入 PlayView 时，后端 sequencer/playing 状态可能残留
	# （实测：旧曲位置停留在 74s，pre-roll seek(-2000) 后 crossing-zero 状态机错乱，
	# 表现为判定时钟异常 + 位置冻结 + 游戏提前结束）。先 stop() 保证干净状态。
	stop()

	# 清理上一首歌的人声预加载资源（若新歌无人声或路径不同，旧 stream 会一直驻留）
	if current_midi_data != null and current_midi_data.vocal_file_path != midi_data.vocal_file_path:
		_vocal_initialized = false
		_vocal_loaded_path = ""
		var am := AudioManager.instance
		if am != null:
			am.unload_vocal()
	# 保存当前MIDI数据
	current_midi_data = midi_data
	
	# 使用FileSystemManager定位MIDI文件路径
	var midi_file_path = _locate_midi_file(midi_data)
	if midi_file_path.is_empty():
		push_error("Cannot locate MIDI file for: %s" % midi_data.id)
		return false
	
	# 存储路径
	current_midi_data.midi_file_path = midi_file_path
	
	# 解析MIDI文件（带缓存：retry 场景跳过重复解析）
	var track_infos: Array
	if midi_data.has_notes() and midi_data.midi_file_path == midi_file_path and not midi_data._runtime_track_infos.is_empty():
		# 缓存命中：跳过昂贵的 MIDI 解析
		current_notes = midi_data.parsed_notes
		bpm_timeline = midi_data.bpm_timeline.duplicate()
		midi_timebase = midi_data.midi_timebase
		track_infos = midi_data._runtime_track_infos
		duration_ms = midi_data.duration_ms
		GLogger.info("MIDI parse cache hit, skipping re-parse", "MidiPlaybackManager")
	else:
		var parse_result = MidiParser.load_and_parse_midi(midi_file_path)
		if not parse_result["success"]:
			push_error("Failed to parse MIDI file: %s" % midi_file_path)
			return false

		# 音符数据以 SOA 紧凑数组存储（不 materialize 全量 NoteEvent，20w+ 音符内存优化）
		# 单一授权点：SOA + 轨道-通道分组一并写入，保证与 notes_soa 强一致
		current_midi_data.set_parsed_soa(parse_result)
		bpm_timeline = parse_result.get("bpm_timeline", [])  # 获取BPM时间线
		midi_timebase = parse_result.get("timebase", 480)  # 保存timebase
		track_infos = parse_result["track_infos"]
		current_notes = []  # SOA 路径下不再持有全量对象；消费方按需经 SOA 取

		current_midi_data.track_count = track_infos.size()
		current_midi_data.duration_ms = parse_result["duration_ms"]
		current_midi_data.bpm_timeline = bpm_timeline.duplicate()
		current_midi_data.midi_timebase = midi_timebase
		current_midi_data._runtime_track_infos = track_infos
		current_midi_data.max_end_tick = float(parse_result.get("max_end_tick", 0))
		current_midi_data.track_channel_instruments = parse_result.get("track_instruments", {})
		duration_ms = parse_result["duration_ms"]

	# 从 C# MidiParserNative 一次性提取的 track_channel_instruments 中复用乐器信息
	# （C# 解析阶段已完成 control_change/program_change 提取，无需 GDScript 遍历 events）
	if cached_track_channel_instruments.is_empty():
		if not current_midi_data.track_channel_instruments.is_empty():
			cached_track_channel_instruments = current_midi_data.track_channel_instruments.duplicate()
			GLogger.info("Loaded instruments for %d tracks from C# parse result" % cached_track_channel_instruments.size(), "MidiPlaybackManager")
	else:
		GLogger.info("Instrument extraction cache hit, skipping re-extract", "MidiPlaybackManager")
	
	# 如果未选择轨道，则默认选择所有轨道
	if current_midi_data.selected_track_indices.is_empty():
		for i in range(current_midi_data.track_count):
			current_midi_data.selected_track_indices.append(i)

	# 首次需要轨道配置的入口（MidiView 统计 / TrackView / PlayView）前确保已按简介初始化
	ensure_track_config_initialized(current_midi_data, current_notes)

	# 轨道-通道分组已由 set_parsed_soa 与 SOA 一并构建（单一授权点），非空即与当前 SOA 强一致；
	# 命中缓存路径复用 preparse 写入的既有分组，无需在此重复 O(N) 重建。
	
	# 加载到活跃后端
	var backend = _get_active_backend()
	if backend != null:
		# load_midi 为接口契约方法（MeltySynth 后端唯一实现），不再做 has_method 动态探测
		backend.load_midi(midi_file_path)
	
	# 应用轨道-通道音量配置
	if midi_data.track_channel_volume_config and not midi_data.track_channel_volume_config.is_empty():
		for track_idx in midi_data.track_channel_volume_config.keys():
			for ch in midi_data.track_channel_volume_config[track_idx].keys():
				if backend != null:
					backend.set_track_channel_volume(track_idx, ch, midi_data.track_channel_volume_config[track_idx][ch])
		GLogger.info("Applied %d track volume configs" % midi_data.track_channel_volume_config.size(), "MidiPlaybackManager")
	else:
		# 未配置过轨道音量：统一按 TrackView 默认 50% 应用（只改后端，不改 MidiData），
		# 避免 PlayView（未配置默认 100%）与 TrackView（默认 50%）对同一新曲音量不一致
		var default_volume := 0.5
		var seen_pairs := {}
		var default_count := 0
		if current_midi_data != null and current_midi_data.notes_soa != null and current_midi_data.notes_soa.size() > 0:
			# SOA 路径：只枚举 (track,channel) 对，不建全量 NoteEvent
			var soa := current_midi_data.notes_soa
			for i in range(soa.size()):
				var pair_key := "%d_%d" % [soa.track(i), soa.channel(i)]
				if seen_pairs.has(pair_key):
					continue
				seen_pairs[pair_key] = true
				if backend != null:
					backend.set_track_channel_volume(soa.track(i), soa.channel(i), default_volume)
				default_count += 1
		else:
			for note in current_notes:
				if note is MidiParser.NoteEvent:
					var pair_key := "%d_%d" % [note.track_index, note.channel]
					if seen_pairs.has(pair_key):
						continue
					seen_pairs[pair_key] = true
					if backend != null:
						backend.set_track_channel_volume(note.track_index, note.channel, default_volume)
					default_count += 1
		if default_count > 0:
			GLogger.info("Applied %d default track volumes (50%%)" % default_count, "MidiPlaybackManager")
	
	# 清理旧乐器覆盖配置（双重保障：后端 set_file/load_midi 已清理，这里再次确认）
	# 注意：后端的 set_file/load_midi 方法已经清理了 track_channel_instruments
	# 这里的检查主要用于防御性编程，确保清理操作成功
	if backend != null and "track_channel_instruments" in backend:
		if backend.track_channel_instruments.size() > 0:
			GLogger.warning("Backend still has %d instrument overrides after file load, clearing..." % backend.track_channel_instruments.size(), "MidiPlaybackManager")
			backend.track_channel_instruments.clear()
	
	# 应用轨道-通道乐器覆盖配置
	if midi_data.track_channel_instrument_overrides and not midi_data.track_channel_instrument_overrides.is_empty():
		for track_idx in midi_data.track_channel_instrument_overrides.keys():
			for ch in midi_data.track_channel_instrument_overrides[track_idx].keys():
				var instr = midi_data.track_channel_instrument_overrides[track_idx][ch]
				if backend != null:
					backend.set_track_channel_instrument(track_idx, ch, instr["bank"], instr["program"])
		GLogger.info("Applied %d instrument overrides" % midi_data.track_channel_instrument_overrides.size(), "MidiPlaybackManager")
	
	# 同步轨道-通道静音状态（清理旧MIDI的残留静音）
	_apply_mute_state_to_backend(backend)
	
	# 应用系统时钟配置（后端实现了 set_use_system_stopwatch 即可）
	if backend != null:
		var use_system_stopwatch = ConfigManager.instance.get_int("Playback", "use_system_stopwatch", 0) == 1
		backend.set_use_system_stopwatch(use_system_stopwatch)
		GLogger.info("System stopwatch mode: %s" % ("ON" if use_system_stopwatch else "OFF"), "MidiPlaybackManager")
	
	# 发出信号

	# 预载人声到 miniaudio 后端（原生解码线程异步填充环形缓冲，消除 is_pause=false 时的解码卡顿）
	_preload_vocal_native()

	return true

## 显式卸载当前 MIDI 资源（释放原生人声、停止后端、清理引用）
## MidiData.parsed_notes 保留（由 DataManager 管理生命周期，用于 retry 跳过重复解析）
func unload_midi() -> void:
	_vocal_initialized = false
	_vocal_loaded_path = ""
	var am := AudioManager.instance
	if am != null:
		am.unload_vocal()
	# 停止后端
	var backend := _get_active_backend()
	if backend != null:
		backend.stop()
	# 清理引用（MidiData.parsed_notes 保留，由 DataManager 管理）
	current_midi_data = null
	current_notes = []
	bpm_timeline = []
	cached_track_channel_instruments.clear()
	midi_timebase = 480
	duration_ms = 0.0
	is_playing = false
	is_paused = false
	position = 0.0
	position_ms = 0.0

## 将 MIDI 运行时配置保存到 chart_runtime（权威 DB，替代 JSON 写回）
## 用于首次初始化后立即持久化，避免每次启动重复解析简介
func _save_runtime_config(midi_data: MidiData) -> void:
	var chart_id = midi_data.file_hash if not midi_data.file_hash.is_empty() else midi_data.id
	if ChartDB and ChartDB.IsOpen():
		var runtime_config = midi_data.export_runtime_config()
		ChartDB.SaveRuntime(chart_id, runtime_config)
		GLogger.info("Runtime config persisted to DB for MIDI %s (initialized=true, tracks=%d)" % [midi_data.id, midi_data.selected_track_configs.size()], "MidiPlaybackManager")
	else:
		push_error("[MidiPlaybackManager] ChartDB not open, cannot save runtime config for MIDI %s" % midi_data.id)

## 解析中的 MIDI 去重表：midi 实例 -> {"done": bool}
## MidiListItem 统计 / TrackView / PlayView 可能同时请求同一 MIDI 的解析；
## 只允许第一个请求方启动 worker，其余请求方等待同一解析完成，
## 避免对同一文件重复解析（浪费 I/O）或解析结果交错写入
var _preparse_inflight: Dictionary = {}

## 在 worker 线程中预解析 MIDI，使后续 load_midi() 命中缓存跳过同步解析
## 同时在 worker 中完成 track_channel_instruments 复用 + runtime_track_channel_notes 分组构建
## 主线程在 await 期间可继续渲染转场动画，避免首次进入 TrackView 时的解析卡顿
## 同一 MIDI 多请求方去重：若已有解析在进行（MidiView 统计或另一视图发起的），
## 本函数直接等待其完成，绝不重复启动解析
## TrackView._load_midi 在调用 load_midi 之前 await 本方法
func preparse_midi_async(midi_data: MidiData) -> bool:
	# 缓存命中检查（与 load_midi 内部条件一致）
	# 命中缓存时 runtime_track_channel_notes 已由本函数构建，TrackView._build_buckets 可直接复用
	if midi_data.has_notes() and not midi_data._runtime_track_infos.is_empty():
		# 缓存命中时也复用已构建的 cached_track_channel_instruments（避免 load_midi 重新提取）
		# 但 cached_track_channel_instruments 是 MidiPlaybackManager 单实例字段，切换 MIDI 时会被 clear
		# 此处不做特殊处理：load_midi 内部会判断 cached_track_channel_instruments 是否为空决定是否调用提取
		# 确保 (track,channel) 索引分组已就绪：某些路径（如 load_midi 直接设置 notes_soa、或复用旧实例）
		# 可能只重建了 SOA 而未建分组，缺则从 SOA 重建，保证 TrackView._build_buckets 总是能取到数据
		if midi_data.runtime_track_channel_notes.is_empty() \
				and midi_data.notes_soa != null and midi_data.notes_soa.size() > 0:
			midi_data.runtime_track_channel_notes = midi_data.notes_soa.grouped_indices()
		return true  # 已缓存，无需预解析

	# 同一 MIDI 已有解析在进行：单纯等待其完成（MidiListItem 的统计解析 / TrackView / PlayView 共享一次解析）
	if _preparse_inflight.has(midi_data):
		while _preparse_inflight.has(midi_data) and not _preparse_inflight[midi_data].get("done", false):
			await Engine.get_main_loop().process_frame
		# 解析完成（成功或失败）；失败时字段仍为空，按失败处理
		return (midi_data.has_notes() and not midi_data._runtime_track_infos.is_empty())

	var midi_file_path := _locate_midi_file(midi_data)
	if midi_file_path.is_empty():
		push_error("[MidiPlaybackManager] Cannot locate MIDI file for: %s" % midi_data.id)
		return false

	# 预先写入路径，让 load_midi 内部的缓存检查 (midi_data.midi_file_path == midi_file_path) 命中
	midi_data.midi_file_path = midi_file_path

	# 注册本次解析，后续同 MIDI 请求方走等待分支
	var inflight_entry := {"done": false}
	_preparse_inflight[midi_data] = inflight_entry

	# 在 worker 线程中执行 MIDI 解析（C# 纯 .NET + PackedArray marshalling，线程安全）
	# NoteEvent 重建与 track_channel_notes 分组在主线程完成（避免 worker 创建 66k RefCounted）
	var result_wrapper := {"parse": null, "instruments": null}
	var task_id := WorkerThreadPool.add_task(func():
		var _parse_result: Dictionary = MidiParser.load_and_parse_midi(midi_file_path)
		result_wrapper["parse"] = _parse_result
		if _parse_result.get("success", false):
			# 乐器信息由 C# MidiParserNative 一次性提取，直接复用（小 Dictionary，worker 安全）
			result_wrapper["instruments"] = _parse_result.get("track_instruments", {})
	, false, "MIDI Preparse")

	# 主线程轮询任务完成状态，期间继续渲染转场动画（非阻塞）
	while not WorkerThreadPool.is_task_completed(task_id):
		await Engine.get_main_loop().process_frame

	# 任务已完成，wait_for_task_completion 仅做线程 join（瞬时返回）
	WorkerThreadPool.wait_for_task_completion(task_id)

	var parse_result: Dictionary = result_wrapper["parse"]
	if not parse_result.get("success", false):
		_preparse_inflight.erase(midi_data)
		push_error("[MidiPlaybackManager] Failed to parse MIDI file: %s" % midi_file_path)
		return false

	# 音符数据以 SOA 紧凑数组存储（不 materialize 全量 NoteEvent，20w+ 音符内存优化）
	# 单一授权点：SOA + 轨道-通道分组一并写入，保证与 notes_soa 强一致
	midi_data.set_parsed_soa(parse_result)

	# 写入 midi_data 字段，load_midi 后续会命中缓存跳过同步解析
	# 与 load_midi 一致：duplicate() 防止后续修改影响原解析结果
	midi_data.bpm_timeline = parse_result.get("bpm_timeline", []).duplicate()
	midi_data.midi_timebase = parse_result.get("timebase", 480)
	midi_data._runtime_track_infos = parse_result["track_infos"]
	midi_data.track_count = parse_result["track_infos"].size()
	midi_data.duration_ms = parse_result["duration_ms"]
	midi_data.max_end_tick = float(parse_result.get("max_end_tick", 0))

	# 复用 worker 中已构建的乐器信息字典（避免 load_midi 重新提取，省 ~5-15ms）
	# C# MidiParserNative 一次性提取，直接复用
	cached_track_channel_instruments = result_wrapper["instruments"]
	midi_data.track_channel_instruments = cached_track_channel_instruments.duplicate()

	# SOA 来源数组已按 start_tick 升序排序，无需重复排序

	# 标记完成并移除在途记录（等待方在 while 循环里以 has() 守卫，erase 后立即退出循环）
	inflight_entry["done"] = true
	_preparse_inflight.erase(midi_data)

	var json_note_count: int = midi_data.notes_soa.size()
	GLogger.info("MIDI preparse completed (threaded): %d notes, duration=%.0fms, %d (track,channel) groups" % [
		json_note_count,
		midi_data.duration_ms,
		midi_data.runtime_track_channel_notes.size()
	], "MidiPlaybackManager")
	return true

## 预载人声到 miniaudio 后端（原生解码线程异步填充环形缓冲，不阻塞主线程）
func _preload_vocal_async() -> void:
	_preload_vocal_native()

## 原生预载：仅打开解码器并启动生产者线程，不开始播放
func _preload_vocal_native() -> void:
	if current_midi_data == null or current_midi_data.vocal_file_path.is_empty():
		return
	if not current_midi_data.vocal_enabled:
		return
	var path = current_midi_data.vocal_file_path
	if not FileAccess.file_exists(path):
		GLogger.warning("Vocal file does not exist, skip native preload: %s" % path, "MidiPlaybackMGR")
		return
	var backend = _get_active_backend()
	if backend == null:
		return
	if path != _vocal_loaded_path:
		var ok: bool = backend.load_vocal_file(_globalize_vocal_path(path))
		if ok:
			_vocal_loaded_path = path
			_vocal_initialized = false
			GLogger.info("Vocal preloaded to miniaudio backend: %s" % path, "MidiPlaybackManager")
		else:
			GLogger.warning("Vocal native preload failed: %s" % path, "MidiPlaybackMGR")

## 将 user:// / res:// 路径转换为原生文件系统路径（miniaudio C 解码器需要）
func _globalize_vocal_path(path: String) -> String:
	if path.begins_with("user://") or path.begins_with("res://"):
		return ProjectSettings.globalize_path(path)
	return path

## 音频中断恢复（安卓系统打断后整桥重建）：恢复声音、保留播放位置与音源
## 重建会丢失原生人声解码器，置 _vocal_initialized 标记以便 resume 时从当前播放位置重载人声
func recover_audio_output() -> void:
	if midi_player == null or current_midi_data == null:
		return
	if midi_player.has_method("recover_audio_output"):
		midi_player.call("recover_audio_output")
		_vocal_initialized = false
		# 设备重建后原始渲染时钟可能变化，重置 stall 缓存避免误判
		_last_raw_midi_position_ms = -1.0
		GLogger.info("Audio output bridge recreated for interruption recovery", "MidiPlaybackManager")

## 兼容性空流程：原生解码已在 load_midi 预载，无需等待 worker
func await_vocal_preload() -> void:
	pass

## 播放MIDI
func play() -> void:
	var backend = _get_active_backend()
	if backend == null:
		push_error("No MIDI backend initialized")
		return
	
	if current_midi_data == null:
		push_error("No MIDI loaded")
		return

	# 调试：打印启动时的当前音量（TrackView 起始入口）
	_log_volume_state("play()")

	# 设置音源
	if not _soundfont_preloaded_to_backend and not current_soundfont_path.is_empty():
		backend.set_soundfont(current_soundfont_path)
		_soundfont_preloaded_to_backend = true

	# 重置同步状态
	reset_sync_state()

	# 保留当前 seek 目标（可为负数 pre-roll），避免 play() 覆盖外部预设位置
	var start_position_ms = position_ms
	# 上次播放已自然结束（位置已到达/越过时长）时，重新播放从开头开始，
	# 避免复用末尾位置导致 play() 后立即 seek 到结尾并再次触发 finished
	if not is_paused and duration_ms > 0.0 and start_position_ms >= duration_ms - 100.0:
		start_position_ms = 0.0
		position_ms = 0.0
		position = 0.0

	backend.play()
	is_playing = true
	is_paused = false

	# 若存在预设起始位置（含负数 pre-roll），在启动后立即恢复到该位置
	if abs(start_position_ms) > 0.001:
		seek(start_position_ms)
	else:
		# 默认从 0 开始
		position = 0.0
		position_ms = 0.0

	# 启动人声播放（如果有人声文件）
	if not current_midi_data.vocal_file_path.is_empty():
		start_vocal_playback()
		GLogger.info("Started vocal playback: %s (offset: %d ms)" % [current_midi_data.vocal_file_path, vocal_offset_ms], "MidiPlaybackManager")
	else:
		GLogger.info("No vocal file configured (path: '%s')" % current_midi_data.vocal_file_path, "MidiPlaybackManager")

## 停止播放
func stop() -> void:
	_last_raw_midi_position_ms = -1.0
	var backend = _get_active_backend()
	if backend == null:
		return
	
	backend.stop()
	is_playing = false
	is_paused = false
	position = 0.0
	position_ms = 0.0

	# 停止人声播放
	stop_vocal_playback()

## 暂停播放
func pause() -> void:
	var backend = _get_active_backend()
	if backend == null:
		return
	
	backend.pause()
	is_playing = false
	is_paused = true

	# 暂停人声播放
	var audio_manager = AudioManager.instance
	if current_midi_data and audio_manager:
		audio_manager.set_vocal_playing(false)

## 继续播放
func resume() -> void:
	var backend = _get_active_backend()
	if backend == null:
		return

	backend.resume()
	is_playing = true
	is_paused = false

	# 恢复或启动人声播放
	if current_midi_data and not current_midi_data.vocal_file_path.is_empty() and current_midi_data.vocal_enabled:
		if not _vocal_initialized:
			start_vocal_playback()
		else:
			# 只有当 MIDI 已跨越人声起点才恢复人声播放
			# 预卷期间或 midi_position < vocal_offset_ms 时由 _sync_vocal_with_midi 负责在正确时机恢复
			if position_ms - vocal_offset_ms >= 0.0:
				var audio_manager = AudioManager.instance
				if audio_manager:
					audio_manager.set_vocal_playing(true)

## 设置循环播放
func set_loop(enabled: bool) -> void:
	var backend = _get_active_backend()
	if backend != null:
		backend.set_loop(enabled)
	
	# 同时更新配置
	midi_player_config["loop"] = enabled
	GLogger.info("Loop set to: %s" % enabled, "MidiPlaybackManager")

## 获取循环播放状态
func get_loop() -> bool:
	var backend = _get_active_backend()
	if backend != null:
		return backend.get_loop()
	return false

## 跳转到指定位置
## position: 位置（毫秒）
func seek(pos: float) -> void:
	position_ms = pos
	if midi_player == null:
		GLogger.warning("Seek failed: backend not available", "MidiPlaybackManager")
		return

	# 直接调用 C# 的 seek_ms 方法
	GLogger.info("Calling MeltySynth seek_ms(%.1f)" % pos, "MidiPlaybackManager")
	midi_player.seek_ms(pos)
	# 立即同步 position（从毫秒转 tick）
	if midi_timebase > 0:
		position = calculate_tick_from_position_with_bpm_timeline(pos, midi_timebase)

	# seek_ms is queued in the C# backend and is applied on its next _Process.
	# Submit the matching vocal target now instead of reading the still-old MIDI
	# clock from the caller immediately after seek().
	_last_raw_midi_position_ms = -1.0
	last_sync_check_pos_ms = pos
	_seek_vocal_to_midi_position(pos)

## 辅助函数：根据BPM时间线计算当前的实际播放时间（毫秒）
func _calculate_position_with_bpm_timeline(current_tick: float, timebase: int) -> float:
	if bpm_timeline.is_empty():
		# 如果没有BPM时间线，使用默认计算方式
		var seconds_per_tick: float = 60.0 / (120.0 * timebase)  # 默认120 BPM
		return current_tick * seconds_per_tick * 1000.0
	
	var cumulative_time_ms: float = 0.0
	
	# 遍历BPM时间线找到当前tick所在的段
	for i in range(bpm_timeline.size()):
		var entry = bpm_timeline[i]
		var entry_tick = entry["tick"]
		
		# 确定下一个BPM变化的tick
		var next_tempo_tick: float
		if i + 1 < bpm_timeline.size():
			next_tempo_tick = bpm_timeline[i + 1]["tick"]
		else:
			next_tempo_tick = current_tick + 1000000  # 大数字，表示无限远
		
		if current_tick < next_tempo_tick:
			# 当前tick在这个BPM段内
			var bpm = entry["bpm"]
			var tick_delta = current_tick - entry_tick
			var ms_per_tick = (60000.0 / bpm) / timebase
			var segment_time_ms = tick_delta * ms_per_tick
			
			return cumulative_time_ms + segment_time_ms
		else:
			# 继续下一个BPM段
			if i + 1 < bpm_timeline.size():
				var next_entry = bpm_timeline[i + 1]
				var bpm = entry["bpm"]
				var tick_delta = next_entry["tick"] - entry_tick
				var ms_per_tick = (60000.0 / bpm) / timebase
				var segment_time_ms = tick_delta * ms_per_tick
				cumulative_time_ms += segment_time_ms
	
	return cumulative_time_ms

## 辅助函数：根据BPM时间线计算从时间位置（毫秒）到tick的转换
## 公开供 noteDisplayer 等播放链路消费方使用（原下划线命名误导为私有，TMX-019）
func calculate_tick_from_position_with_bpm_timeline(target_time_ms: float, timebase: int) -> float:
	if bpm_timeline.is_empty():
		# 如果没有BPM时间线，使用默认计算方式
		var seconds_per_tick: float = 60.0 / (120.0 * timebase)  # 默认120 BPM
		return target_time_ms / 1000.0 / seconds_per_tick
	
	# 遍历BPM时间线找到目标时间所在的段
	for i in range(bpm_timeline.size()):
		var entry = bpm_timeline[i]
		var entry_tick = entry["tick"]
		var entry_time_ms = entry["time_ms"]
		
		# 确定下一个BPM变化
		var next_entry = null
		if i + 1 < bpm_timeline.size():
			next_entry = bpm_timeline[i + 1]
		
		if next_entry == null or target_time_ms <= next_entry["time_ms"]:
			# 目标时间在这个BPM段内
			var bpm = entry["bpm"]
			var time_in_segment = target_time_ms - entry_time_ms
			var ms_per_tick = (60000.0 / bpm) / timebase
			var tick_offset = time_in_segment / ms_per_tick
			
			return entry_tick + tick_offset
	
	# 不应该到达这里，返回最后的tick
	return bpm_timeline[-1]["tick"]

## 设置选中的轨道和通道（支持新格式）
## 接受 Array[Dictionary] 格式: [{"track": int, "channel": int}, ...]
## 或兼容旧 Array[int] 格式（仅按track选中所有channel）
func set_selected_tracks(tracks_data) -> void:
	if current_midi_data == null:
		return
	
	# 兼容旧格式 Array[int]
	if tracks_data is Array:
		if tracks_data.is_empty():
			current_midi_data.selected_track_configs.clear()
			return
		
		# 检查是否为新格式 Array[Dictionary]
		if tracks_data[0] is Dictionary:
			# 新格式：[{"track": int, "channel": int}, ...]
			current_midi_data.selected_track_configs.clear()
			for item in tracks_data:
				var track_idx = item.get("track", -1)
				var channel = item.get("channel", -1)
				if track_idx >= 0 and channel >= 0:
					current_midi_data.set_track_channel_enabled(track_idx, channel, true)
		else:
			# 旧格式：Array[int] - 为了兼容，将其转换为配置格式
			# 注：旧格式仅保留track信息，channel信息会丢失
			# 仅用于向后兼容，不推荐使用
			var track_indices = tracks_data as Array[int]
			current_midi_data.selected_track_indices = track_indices

## 预加载 SoundFont 到后端（启动时延迟调用）
func _preload_soundfont_to_backend() -> void:
	if _soundfont_preloaded_to_backend:
		return
	if midi_player == null or current_soundfont_path.is_empty():
		return

	GLogger.info("Pre-loading SoundFont: %s" % current_soundfont_path, "MidiPlaybackManager")
	midi_player.set_soundfont(current_soundfont_path)
	_soundfont_preloaded_to_backend = true
	GLogger.info("SoundFont pre-loaded successfully", "MidiPlaybackManager")

## 确保 SoundFont 已加载到后端合成器
## 供 trigger_note_on 等即时音符播放场景（如 DelayAdjust 校准）调用，
## 因为 set_soundfont() 在非播放状态不会立即加载到后端（懒加载机制）
func ensure_soundfont_loaded() -> void:
	_preload_soundfont_to_backend()

## 预热手动音符触发路径（演奏模式首次点击的一次性 JIT/通道分配成本移到开局准备期）
## 无声音、无副作用；后端不支持时静默跳过
func warmup_manual_path() -> void:
	var backend = _get_active_backend()
	if backend == null:
		return
	backend.warmup_manual_path(cached_track_channel_instruments)
	GLogger.info("Manual trigger path warmed up (%d tracks)" % cached_track_channel_instruments.size(), "MidiPlaybackManager")

## 设置音源文件
func set_soundfont(soundfont_name: String) -> bool:
	"""
	设置MIDI播放使用的音源文件
	
	优先级：
	1. user://files/Soundfont/{soundfont_name}.sf2
	2. res://Resources/Soundfont/{soundfont_name}.sf2
	3. 回退到内置默认 GeneralUser-GS.sf2
	
	Args:
		soundfont_name: 音源文件名（不含.sf2扩展名和[内置]标签）
	
	Returns:
		bool: 是否设置成功
	"""
	# 验证和定位soundfont文件
	var soundfont_path = _locate_soundfont(soundfont_name)
	
	if soundfont_path.is_empty():
		# 文件不存在，尝试回退到默认
		GLogger.warning("Soundfont '%s' not found, falling back to default" % soundfont_name, "MidiPlaybackManager")
		soundfont_path = _locate_soundfont("GeneralUser-GS")
		
		if soundfont_path.is_empty():
			# 默认文件也不存在，作为最后的回退
			soundfont_path = default_soundfont_path
			push_warning("[MidiPlaybackManager] Default soundfont also not found, using fallback: %s" % soundfont_path)
	
	current_soundfont_path = soundfont_path
	if current_midi_data != null:
		# 提取文件名用于存储（不带路径和扩展名）
		var file_name = soundfont_path.get_file().get_basename()
		current_midi_data.set_soundfont(file_name)
	
	# 如果正在播放，立即切换音源
	if is_playing and midi_player != null:
		midi_player.set_soundfont(soundfont_path)
		_soundfont_preloaded_to_backend = true
	else:
		_soundfont_preloaded_to_backend = false

	GLogger.info("Soundfont set to: %s" % soundfont_path, "MidiPlaybackManager")
	return true

## 初始化MIDI后端（唯一后端：MeltySynth C#）
## Android 上 MeltySynth 还能避免 addons 后端因大量 AudioStreamPlayer 触发的
## StringName 引用计数竞态崩溃（"Unreferenced static string to 0"）
func _initialize_backend() -> bool:
	if _is_android and not _is_csharp_available():
		push_warning("[MidiPlaybackManager] Android: C# not available - MeltySynth backend cannot init")
		push_warning("[MidiPlaybackManager] Android: Consider exporting with .NET support for stable MIDI playback")
	return _initialize_meltysynth_backend()

## 初始化MeltySynth后端（C#）
## 返回: bool - 初始化是否成功
func _initialize_meltysynth_backend() -> bool:
	if midi_player != null:
		GLogger.info("MeltySynth backend already initialized, skipping", "MidiPlaybackManager")
		return true  # 已经初始化
	
	# 尝试加载预制场景
	var scene_path = "res://CSharp/MeltySynthPlayer.tscn"
	GLogger.info("Attempting to load MeltySynth scene: %s" % scene_path, "MidiPlaybackManager")
	
	if not ResourceLoader.exists(scene_path):
		push_error("[MidiPlaybackManager] MeltySynth scene path does not exist: %s" % scene_path)
		return false
	
	var scene = load(scene_path) as PackedScene
	if scene == null:
		push_error("[MidiPlaybackManager] Failed to load MeltySynth PackedScene from: %s" % scene_path)
		return false
	
	GLogger.info("MeltySynth scene loaded successfully", "MidiPlaybackManager")
	
	var wrapper = scene.instantiate() as MidiPlaybackInterface
	if wrapper == null:
		push_error("[MidiPlaybackManager] Failed to instantiate MeltySynth wrapper as MidiPlaybackInterface")
		return false
	
	GLogger.info("MeltySynth wrapper instantiated successfully", "MidiPlaybackManager")
	
	# 获取 C# 后端子节点
	var csharp_backend = wrapper.get_node_or_null("CSharpBackend")
	if csharp_backend == null:
		push_error("[MidiPlaybackManager] CSharpBackend child node not found in MeltySynth wrapper")
		wrapper.queue_free()
		return false
	
	GLogger.info("CSharpBackend child node found", "MidiPlaybackManager")
	
	# 设置 wrapper 持有的 C# 后端子节点引用
	wrapper.set("meltysynth_player", csharp_backend)
	GLogger.info("Set meltysynth_player property on wrapper", "MidiPlaybackManager")

	# 添加为子节点
	add_child(wrapper as Node)
	GLogger.info("Added wrapper as child node", "MidiPlaybackManager")

	# 配置播放器参数
	wrapper.set("max_polyphony", midi_player_config["max_polyphony"])
	wrapper.set_loop(midi_player_config["loop"])
	GLogger.info("Set playback parameters", "MidiPlaybackManager")

	wrapper.set_volume_db(midi_player_config["volume_db"])
	GLogger.info("Called set_volume_db", "MidiPlaybackManager")

	wrapper.set_bus("Master")
	GLogger.info("Called set_bus", "MidiPlaybackManager")

	# 初始化系统时钟配置
	var use_system_stopwatch = ConfigManager.instance.get_int("Playback", "use_system_stopwatch", 0) == 1
	wrapper.set_use_system_stopwatch(use_system_stopwatch)
	GLogger.info("Set system stopwatch mode: %s" % ("ON" if use_system_stopwatch else "OFF"), "MidiPlaybackManager")

	# 设置最大复音数
	wrapper.set("max_polyphony", ConfigManager.instance.get_int("Playback", "max_polyphony", 96))
	GLogger.info("Set max polyphony: %d" % wrapper.max_polyphony, "MidiPlaybackManager")

	# 连接信号
	if wrapper.has_signal("finished"):
		wrapper.finished.connect(_on_midi_finished)
		GLogger.info("Connected finished signal", "MidiPlaybackManager")
	if wrapper.has_signal("vocal_finished"):
		wrapper.vocal_finished.connect(_on_vocal_finished)
		GLogger.info("Connected vocal_finished signal", "MidiPlaybackManager")

	# 保存引用
	midi_player = wrapper
	GLogger.info("MeltySynth C# backend initialized successfully", "MidiPlaybackManager")
	GLogger.info("MeltySynth backend initialization complete", "MidiPlaybackManager")

	return true

## 检查C#支持（兼容导出包）
## 旧方法检查 .csproj 文件，但导出的 APK 不包含此文件
## 新方法：检查 C# 运行时 + MeltySynth 场景是否存在
func _is_csharp_available() -> bool:
	# 1. 检查 Godot C# 运行时是否可用（仅 Mono 构建版本有此类）
	if not ClassDB.class_exists(&"CSharpScript"):
		GLogger.warning("C# runtime not available (non-Mono build)", "MidiPlaybackManager")
		return false
	# 2. 检查 MeltySynth 场景是否存在
	if not ResourceLoader.exists("res://CSharp/MeltySynthPlayer.tscn"):
		GLogger.warning("MeltySynth scene not found", "MidiPlaybackManager")
		return false
	GLogger.info("C# runtime and MeltySynth scene available", "MidiPlaybackManager")
	return true

## 获取活跃的MIDI播放器（唯一后端：MeltySynth）
func _get_active_backend() -> MidiPlaybackInterface:
	return midi_player

## 辅助函数：定位soundfont文件（用户目录优先）
func _locate_soundfont(soundfont_name: String) -> String:
	"""
	定位soundfont文件，用户目录优先于res://
	
	Args:
		soundfont_name: 文件名不含.sf2扩展名
	
	Returns:
		String: 完整文件路径，若不存在返回空字符串
	"""
	# 第一步：检查用户音源目录
	var user_path = PathHelper.get_soundfont_dir().path_join(soundfont_name + ".sf2")
	if FileAccess.file_exists(user_path):
		return user_path

	# 第二步：检查res://Resources/Soundfont/
	# 注意：SF2 不是 Godot 注册的资源类型，必须用 FileAccess.file_exists() 检查
	# ResourceLoader.exists() 对 SF2 永远返回 false，会导致内置音源定位失败
	var res_path = "res://Resources/Soundfont/".path_join(soundfont_name + ".sf2")
	if FileAccess.file_exists(res_path):
		return res_path

	return ""


## 设置音量
func set_volume_db(volume: float) -> void:
	var backend = _get_active_backend()
	if backend == null:
		return

	# 应用到活跃后端
	backend.set_volume_db(volume)

	midi_player_config["volume_db"] = volume

## MIDI 主音量映射系数：UI 线性值(0~1) × 本系数 = 后端线性增益。
## 4.0 ⇒ 50% = +6dB、100% = +12dB（合成器输出响度天然低于成品人声母带，需放大上限才能与人声拉平）
const MIDI_VOLUME_GAIN: float = 8.0
## 音量下限(dB)：linear_to_db(0) 为 -inf，统一钳到此值表示静音
const MIN_VOLUME_DB: float = -80.0

## 统一把 UI 线性音量应用到后端（TrackView / MidiConfigPersistence / PlayView 共用），
## 避免多处各自硬编码系数导致视图间音量不一致
func apply_ui_midi_volume(ui_linear: float) -> void:
	set_volume_db(maxf(linear_to_db(ui_linear * MIDI_VOLUME_GAIN), MIN_VOLUME_DB))

## 统一解析 MIDI 主音量：per-midi 显式值优先，未配置（midi_volume < 0，约定 -1）回退全局
## default_midi_volume，并 clamp 到 [0,1]。0.5 现在是合法显式值（用户设为 50% 不再被当作哨兵）。
## 供 TrackView/PlayView 共用，保证同一 MIDI 在各视图音量一致
func get_effective_midi_volume(midi_volume: float) -> float:
	var vol := midi_volume
	if vol < 0.0:
		var cfg := ConfigManager.instance.get_float("Gameplay", "default_midi_volume", 0.5)
		if cfg > 1.0:
			cfg /= 100.0  # 兼容旧版 0-100 配置
		vol = cfg
	return clampf(vol, 0.0, 1.0)

## 调试：打印当前音量状态（诊断 TrackView/PlayView 音量不一致）
## TrackView 起始走 play()，PlayView 起始走 is_pause=false → resume()，
## 两个入口各打一次，对比即可看出各视图启动时的实际后端音量。
func _log_volume_state(tag: String) -> void:
	var backend = _get_active_backend()
	var db_cfg: float = midi_player_config.get("volume_db", 0.0)
	var db_backend: float = db_cfg
	if backend != null:
		db_backend = backend.get_volume_db()
	var midi_vol: float = current_midi_data.midi_volume if current_midi_data else 0.0
	var eff: float = get_effective_midi_volume(midi_vol) if current_midi_data else 0.0
	var track_entries: int = current_midi_data.track_channel_volume_config.size() if current_midi_data else 0
	GLogger.info("%s | volume_db(cfg)=%.1f volume_db(backend)=%.1f midi_volume=%.2f effective_midi_volume=%.2f track_cfg_entries=%d" % [
		tag, db_cfg, db_backend, midi_vol, eff, track_entries,
	], "MidiPlaybackManager")

## 设置特定(track, channel)对的音量（线性值0.0-1.0）
## 立即生效到正在播放的Note
func set_track_channel_volume(track_index: int, channel: int, volume_linear: float) -> void:
	var backend = _get_active_backend()
	if backend == null:
		return

	var clamped_volume = clamp(volume_linear, 0.0, 1.0)

	# 通过后端抽象调用
	backend.set_track_channel_volume(track_index, channel, clamped_volume)

	GLogger.info("Track %d Channel %d volume set to: %.1f%%" %
		[track_index, channel, clamped_volume * 100.0], "MidiPlaybackManager")

## 获取特定(track, channel)对的音量
func get_track_channel_volume(track_index: int, channel: int) -> float:
	var backend = _get_active_backend()
	if backend == null:
		return 1.0
	return backend.get_track_channel_volume(track_index, channel)

## 设置人声音量
func set_vocal_volume_db(volume_db: float) -> void:
	var backend = _get_active_backend()
	if backend != null:
		backend.set_vocal_volume(db_to_linear(volume_db))
		GLogger.info("Set vocal volume to %.2f dB" % volume_db, "MidiPlaybackManager")
	else:
		push_error("[MidiPlaybackManager] AudioManager not available")

## ========== (Track, Channel) 静音接口 ==========

## 设置 (track, channel) 对的静音状态（立即生效）
## 参数: track_index (0+), channel (0-15), muted (true=静音, false=取消静音)
func set_track_channel_mute(track_index: int, channel: int, muted: bool) -> void:
	if current_midi_data == null:
		push_error("[MidiPlaybackManager] Cannot mute: no MIDI data")
		return
	
	if channel < 0 or channel > 15:
		push_error("[MidiPlaybackManager] Invalid channel: %d (should be 0-15)" % channel)
		return
	
	# 1. 检查状态是否改变（优化：避免重复操作）
	var previous_state = current_midi_data.get_track_channel_mute(track_index, channel)
	if previous_state == muted:
		GLogger.info("Channel %d already %s, skipping" % [channel, "muted" if muted else "unmuted"], "MidiPlaybackManager")
		return
	
	# 2. 更新 MidiData 中的状态
	current_midi_data.set_track_channel_mute(track_index, channel, muted)

	# 3. 通知后端（MeltySynth 的 set_track_channel_mute 内部会停止该通道正在播放的音符）
	var backend = _get_active_backend()
	if backend != null:
		backend.set_track_channel_mute(track_index, channel, muted)

## 仅在运行时设置 (track, channel) 的静音状态（不写入MidiData）
## 用于独奏或临时静音
func set_track_channel_mute_runtime(track_index: int, channel: int, muted: bool) -> void:
	if channel < 0 or channel > 15:
		push_error("[MidiPlaybackManager] Invalid channel: %d (should be 0-15)" % channel)
		return

	var backend = _get_active_backend()
	if backend != null:
		backend.set_track_channel_mute(track_index, channel, muted)

## 查询 (track, channel) 对的静音状态
func is_track_channel_muted(track_index: int, channel: int) -> bool:
	if current_midi_data == null:
		return false
	return current_midi_data.get_track_channel_mute(track_index, channel)

## 取消所有 (track, channel) 的静音
func unmute_all_channels() -> void:
	if current_midi_data == null:
		return
	
	current_midi_data.clear_all_mutes()
	GLogger.info("All channels unmuted", "MidiPlaybackManager")

## 获取已选中轨道对应的Note
func get_selected_track_notes() -> Array:
	if current_midi_data == null:
		return []
	# SOA 路径：按 selected_track_indices 从 SOA 按需构建 NoteEvent 子集（不 materialize 全量）
	if current_midi_data.notes_soa != null and current_midi_data.notes_soa.size() > 0:
		var soa := current_midi_data.notes_soa
		var selected := current_midi_data.selected_track_indices
		var notes: Array = []
		for i in range(soa.size()):
			if soa.track(i) in selected:
				notes.append(soa.note(i))
		return notes
	if current_notes.is_empty():
		return []
	return MidiParser.extract_notes_by_track(current_notes, current_midi_data.selected_track_indices)

## 获取可用的乐器预设列表
func get_presets_list() -> Array:
	var backend = _get_active_backend()
	if backend == null:
		return []
	return backend.get_presets_list()
	
## 获取指定 bank/program 的乐器名称
func get_preset_name(program: int, bank: int = 0) -> String:
	var backend = _get_active_backend()
	if backend == null:
		return "Unknown"
	return backend.get_preset_name(program, bank)
	
## 获取指定 (track, channel) 的乐器信息
func get_track_channel_instrument(track_index: int, channel: int) -> Dictionary:
	if cached_track_channel_instruments.has(track_index) and cached_track_channel_instruments[track_index].has(channel):
		return cached_track_channel_instruments[track_index][channel]

	# 缓存未命中（如 Addon 后端运行期才登记的新通道），回退到后端维护的信息
	var backend = _get_active_backend()
	if backend != null:
		var result = backend.get_track_channel_instrument(track_index, channel)
		if not result.is_empty():
			return result

	return _get_default_instrument(channel)

## 获取 MIDI 文件中的原始乐器配置（不考虑用户覆盖）
func get_original_track_channel_instrument(track_index: int, channel: int) -> Dictionary:
	return _get_instrument_from_cache(track_index, channel)

## 设置轨道通道的乐器
func set_track_channel_instrument(track_index: int, channel: int, bank: int, program: int) -> void:
	var backend = _get_active_backend()
	if backend != null:
		backend.set_track_channel_instrument(track_index, channel, bank, program)

## 从缓存中获取乐器信息
func _get_instrument_from_cache(track_index: int, channel: int) -> Dictionary:
	if cached_track_channel_instruments.has(track_index):
		if cached_track_channel_instruments[track_index].has(channel):
			return cached_track_channel_instruments[track_index][channel]
	
	# 返回默认值
	return _get_default_instrument(channel)

## 获取默认乐器配置（用于不维护乐器映射的后端）
func _get_default_instrument(channel: int) -> Dictionary:
	# Channel 9 (索引) 是鼓组，使用 Standard Drum Kit
	if channel == 9:
		return {"bank": 128, "program": 0}  # Bank 128 = 鼓组
	else:
		return {"bank": 0, "program": 0}    # Grand Piano

## 同步轨道-通道静音状态到后端（清理旧MIDI残留）
func _apply_mute_state_to_backend(backend: MidiPlaybackInterface) -> void:
	if backend == null:
		return
	
	# 优先使用缓存的(track, channel)映射，确保覆盖所有实际通道
	for track_idx in cached_track_channel_instruments.keys():
		var channels = cached_track_channel_instruments[track_idx]
		for channel in channels.keys():
			var muted = current_midi_data.get_track_channel_mute(track_idx, channel)
			backend.set_track_channel_mute(track_idx, channel, muted)
	
	GLogger.info("Applied mute state for %d tracks" % cached_track_channel_instruments.size(), "MidiPlaybackManager")

## 辅助函数：定位MIDI文件路径
func _locate_midi_file(midi_data: MidiData) -> String:
	# 使用FileSystemManager的反向索引来定位MIDI文件（O(1)，统一匹配 id / file_hash / hash）
	var filesystem_manager = FileSystemManager.instance
	if filesystem_manager == null:
		push_error("FileSystemManager not initialized")
		return ""

	var lookup = filesystem_manager.lookup_chart(
		midi_data.chart_key if not midi_data.chart_key.is_empty() else midi_data.id)
	if lookup.is_empty() and not midi_data.file_hash.is_empty():
		lookup = filesystem_manager.lookup_chart(midi_data.file_hash)
	if lookup.is_empty():
		return ""
	var metadata: ChartMetadata = lookup["metadata"]
	var folder_name: String = lookup["folder_name"]
	var chart_id: String = metadata.id
	# 首选使用索引中缓存的路径
	var chart_path: String = metadata.path
	if chart_path.is_empty():
		chart_path = FileSystemManager.CHARTS_DIR.path_join(folder_name)
	# 0) 标准命名 song.mid（导入/下载新格式）优先
	var std_path: String = chart_path.path_join("song.mid")
	if FileAccess.file_exists(std_path):
		return std_path
	# 1) 按 chart_id 命名的mid
	var midi_file_path: String = chart_path.path_join(chart_id + ".mid")
	if FileAccess.file_exists(midi_file_path):
		return midi_file_path
	# 2) 按 midi_data.id 命名的mid（旧格式）
	var alt_id_path: String = chart_path.path_join(midi_data.id + ".mid")
	if FileAccess.file_exists(alt_id_path):
		return alt_id_path
	# 3) 按 midi_data.file_hash 命名的mid（若提供）
	if not midi_data.file_hash.is_empty():
		var hash_path: String = chart_path.path_join(midi_data.file_hash + ".mid")
		if FileAccess.file_exists(hash_path):
			return hash_path
	# 4) 作为后备，尝试 res:// 目录同名路径
	var res_chart_path: String = FileSystemManager.DEFAULT_CHARTS_SRC.path_join(folder_name)
	var res_candidates = [
		res_chart_path.path_join("song.mid"),
		res_chart_path.path_join(chart_id + ".mid"),
		res_chart_path.path_join(midi_data.id + ".mid"),
		res_chart_path.path_join(midi_data.file_hash + ".mid") if not midi_data.file_hash.is_empty() else ""
	]
	for candidate in res_candidates:
		if candidate != "" and FileAccess.file_exists(candidate):
			return candidate

	return ""

## 回调：MIDI播放完成
func _on_midi_finished() -> void:
	is_playing = false
	# 同步停止人声播放，避免 MIDI 结束后人声继续响
	stop_vocal_playback()
	midi_finished.emit()

## 回调：人声自然结束
func _on_vocal_finished() -> void:
	_vocal_initialized = false
	GLogger.info("Vocal playback finished naturally", "MidiPlaybackManager")

## 获取当前MIDI的轨道信息列表
func get_track_infos() -> Array:
	if current_midi_data == null:
		return []
	# 优先使用 load_midi() 中已缓存的 _runtime_track_infos，避免重复解析 MIDI 文件
	# （MIDI 解析是同步文件 I/O + 数据结构构建，开销很大）
	if not current_midi_data._runtime_track_infos.is_empty():
		return current_midi_data._runtime_track_infos

	# 回退：缓存缺失时才重新解析
	var parse_result = MidiParser.load_and_parse_midi(current_midi_data.midi_file_path)
	if parse_result["success"]:
		current_midi_data._runtime_track_infos = parse_result["track_infos"]
		return parse_result["track_infos"]

	return []

## ========== Note分类接口 ==========
## 将解析的note分为两类：自动播放和手动控制
## 该方法当前仅为占位，待后续将Touhou Mix原有生成逻辑移植过来
## @param	all_notes				所有已解析的 NoteEvent 列表
## @param	manual_track_indices	需要手动控制的轨道索引数组
## @return 返回 {auto_play_notes: Array[NoteEvent], manual_control_notes: Array[NoteEvent]}
func classify_notes(all_notes: Array, manual_track_indices: Array[int] = []) -> Dictionary:
	var result = {
		"auto_play_notes": [],
		"manual_control_notes": []
	}
	
	if all_notes.is_empty():
		return result
	
	# 创建manual轨道集合便于快速查询
	var manual_tracks_set = {}
	for track_idx in manual_track_indices:
		manual_tracks_set[track_idx] = true
	
	# ========== 预留分类逻辑 ==========
	# 此处将在后续实现具体的分类算法
	# 目前暂时将所有note划为自动播放，待游戏逻辑完成后填充
	#
	# 当前暂时实现方案：
	for note in all_notes:
		if note is MidiParser.NoteEvent:
			# 检查note的轨道是否在手动控制列表中
			if note.track_index in manual_tracks_set:
				# 手动控制音符：播放器端通过 set_manually_controlled_notes 标记跳过自动播放，
				# 由游戏逻辑直接调用 trigger_note_on/off，无需额外的 Note 子类
				result["manual_control_notes"].append(note)
			else:
				# 自动播放音符
				result["auto_play_notes"].append(note)
		else:
			# 非NoteEvent类型，默认为自动播放
			result["auto_play_notes"].append(note)
	
	GLogger.info("Classified notes: %d auto-play, %d manual-control" % 
		[result["auto_play_notes"].size(), result["manual_control_notes"].size()], "MidiPlaybackManager")
	
	return result

## 从 KeySequenceCore（ksm 访问器）读取手动控制音符（C# 保存数据，索引指向 enabled 输入数组）
func set_manual_control_from_core(ksm) -> void:
	if ksm == null or midi_player == null:
		return
	var manually_controlled: Dictionary = {}
	for i in range(ksm.manual_count()):
		var input_idx = ksm.manual_at(i)
		var track_index = ksm.input_track_at(input_idx)
		var channel = ksm.input_channel_at(input_idx)
		var pitch = ksm.input_pitch_at(input_idx)
		var start_tick = ksm.input_start_tick_at(input_idx)
		if not manually_controlled.has(track_index):
			manually_controlled[track_index] = {}
		if not manually_controlled[track_index].has(channel):
			manually_controlled[track_index][channel] = {}
		if not manually_controlled[track_index][channel].has(pitch):
			manually_controlled[track_index][channel][pitch] = {}
		var tick_map = manually_controlled[track_index][channel][pitch]
		tick_map[start_tick] = int(tick_map.get(start_tick, 0)) + 1
	midi_player.set_manually_controlled_notes(manually_controlled)
	GLogger.info("Set manual control from core: %d notes" % ksm.manual_count(), "MidiPlaybackManager")

## 清除所有手动控制note标记（恢复所有notes自动播放）
## 当退出PlayView返回TrackView等场景时调用
func clear_manual_control_notes() -> void:
	
	# 传递空字典给MidiPlayer，清除所有手动控制标记
	if midi_player:
		midi_player.set_manually_controlled_notes({})
		GLogger.info("Cleared all manual control notes, restored auto-play", "MidiPlaybackManager")

## ========== 位置单位转换工具 ==========
## 将tick位置转换为毫秒（使用BPM时间线）
func tick_to_ms(tick: float) -> float:
	return _calculate_position_with_bpm_timeline(tick, midi_timebase)

## 获取当前播放位置（毫秒）
## 这是对position_ms的替代方法，更明确地表示返回值的单位
func get_position_ms() -> float:
	return position_ms

## 后端实际总时长（毫秒，midiFile.Length；播放位置被 clamp 的目标值）
## 解析器 duration_ms 可能与其不一致，曲终/进度条判断以本值为准
func get_backend_duration_ms() -> float:
	var backend = _get_active_backend()
	if backend == null:
		return 0.0
	return backend.get_duration_ms()

## 获取音频回调已渲染的 MIDI 原始位置（毫秒）
## 人声同步必须使用该时钟，避免与 get_position_ms() 的设备延迟补偿混用
func get_raw_position_ms() -> float:
	var backend = _get_active_backend()
	if backend != null:
		return float(backend.get_raw_position_ms())
	return position_ms

## 实时获取当前播放位置（毫秒），绕过 _process 缓存
## 用于触摸判定等对时效性敏感的场景，消除帧级输入延迟
## 同帧缓存: 同一帧内多次调用返回相同值, 避免 GetLatencyMs() 动态波动
## 导致去重逻辑失效 (如 Android 触摸+鼠标模拟事件对)
func get_realtime_position_ms() -> float:
	var current_frame = Engine.get_process_frames()
	if current_frame == _realtime_pos_cache_frame:
		return _realtime_pos_cache
	_realtime_pos_cache_frame = current_frame
	var backend = _get_active_backend()
	if backend != null:
		_realtime_pos_cache = backend.get_position_ms() - _audio_delay_ms
	else:
		_realtime_pos_cache = position_ms
	return _realtime_pos_cache

## 获取当前播放位置（tick）
## 这是对position的替代方法，更明确地表示返回值的单位
func get_position_tick() -> float:
	return position

## 从配置文件加载音源设置
## 优先级：user://files/settings.ini > res://Resources/Config/config.ini > 默认值
func _load_soundfont_from_config() -> void:
	var config_manager = ConfigManager.instance
	
	# 从当前活跃配置获取 soundfont（用户配置 > 默认配置）
	var soundfont_name = config_manager.get_value("Gameplay", "soundfont_file", "GeneralUser-GS.sf2")
	
	if not soundfont_name.is_empty():
		# 去掉 .sf2 扩展名和 [内置] 标签（如果有）
		soundfont_name = soundfont_name.replace(".sf2", "").replace("[内置]", "").strip_edges()
		GLogger.info("Loading soundfont from config: %s" % soundfont_name, "MidiPlaybackManager")
		if set_soundfont(soundfont_name):
			return
	
	# 使用硬编码的默认值（如果加载失败）
	GLogger.info("Using hardcoded default soundfont", "MidiPlaybackManager")
	current_soundfont_path = default_soundfont_path

## ========== 人声同步相关方法 ==========

## 设置人声偏移量（毫秒）
func set_vocal_offset_ms(offset_ms: float) -> void:
	vocal_offset_ms = offset_ms

## 应用人声偏移（重新调整人声播放位置）
func apply_vocal_offset() -> void:
	# Used when the latency setting changes while playback continues.
	# 人声走音频渲染时钟，必须用 get_raw_position_ms()（不含视觉用的校准延迟）
	_seek_vocal_to_midi_position(get_raw_position_ms())

## Seek vocal to a MIDI position without relying on a stale position_ms read.
## The vocal decoder position is relative to the configured vocal offset.
func _seek_vocal_to_midi_position(midi_position_ms: float) -> void:
	if current_midi_data == null or current_midi_data.vocal_file_path.is_empty():
		return
	if not current_midi_data.vocal_enabled:
		return
	# _vocal_initialized is cleared on natural EOF. The native decoder remains
	# loaded, so a later user seek must be allowed to re-arm it.
	if _vocal_loaded_path != current_midi_data.vocal_file_path:
		return
	var audio_manager = AudioManager.instance
	if audio_manager == null:
		return

	_vocal_initialized = true
	# 调用方传入的是音频渲染时钟（get_raw_position_ms），已与人声消费帧对齐，无需再扣别的延迟
	var vocal_position_ms := midi_position_ms - vocal_offset_ms
	if vocal_position_ms < 0.0:
		audio_manager.set_vocal_playing(false)
		audio_manager.seek_vocal(0.0)
		return

	audio_manager.seek_vocal(vocal_position_ms)
	# Preserve the manager's paused state. When playing, explicitly resume so a
	# seek from a stale/finished native state cannot leave vocal playback stopped.
	audio_manager.set_vocal_playing(is_playing)

## 启动人声播放并同步（原生 miniaudio 统一输出链路）
func start_vocal_playback() -> void:
	if current_midi_data == null or current_midi_data.vocal_file_path.is_empty():
		return
	if not current_midi_data.vocal_enabled:
		return

	var audio_manager = AudioManager.instance
	if audio_manager == null:
		return

	var vocal_file_path = current_midi_data.vocal_file_path
	# 用音频渲染时钟（get_raw_position_ms）定位人声，与 MIDI 合成器同一时钟，避免叠加视觉校准延迟造成错位
	var expected_vocal_position = get_raw_position_ms() - vocal_offset_ms
	var start_position_ms = max(0.0, expected_vocal_position)

	audio_manager.set_vocal_volume_db(linear_to_db(current_midi_data.vocal_volume))
	if not audio_manager.play_vocal_file(vocal_file_path, start_position_ms):
		_vocal_initialized = false
		return
	_vocal_initialized = true

	# 如果 MIDI 还没到人声起点（预卷阶段或 midi_position < vocal_offset_ms），
	# 立即暂停人声：解码器已就绪但位置不推进，等 _sync_vocal_with_midi 跨越起点时取消暂停
	if expected_vocal_position < 0.0:
		audio_manager.set_vocal_playing(false)

## 预启动人声播放（兼容接口：原生解码在 load_midi 时已预载，无需 worker）
func prepare_vocal_playback() -> void:
	if current_midi_data == null:
		return
	if current_midi_data.vocal_file_path.is_empty() or not current_midi_data.vocal_enabled:
		return
	start_vocal_playback()

## 停止人声播放（保留已加载文件，便于快速重播）
func stop_vocal_playback() -> void:
	_vocal_initialized = false
	var audio_manager = AudioManager.instance
	if audio_manager != null:
		audio_manager.stop_vocal()

## ========== 人声门面方法（AudioManager 转发到本管理器，再调用后端） ==========

## 加载并播放人声文件（offset_ms 为人声自身起始位置）
func play_vocal_file(path: String, offset_ms: float) -> bool:
	if path.is_empty():
		return false
	var backend = _get_active_backend()
	if backend == null:
		return false

	if path != _vocal_loaded_path:
		if not FileAccess.file_exists(path):
			GLogger.warning("Vocal file does not exist, skipping vocal playback: %s" % path, "MidiPlaybackMGR")
			return false
		var ok: bool = backend.load_vocal_file(_globalize_vocal_path(path))
		if not ok:
			GLogger.warning("Vocal native load failed: %s" % path, "MidiPlaybackMGR")
			return false
		_vocal_loaded_path = path

	# Always seek, including zero. Reusing a native decoder must not depend on the
	# previous stop/EOF state; this also makes retry and loop restart deterministic.
	backend.seek_vocal(max(0.0, offset_ms))
	backend.resume_vocal()
	_vocal_initialized = true
	return true

func _restart_vocal_for_current_position() -> void:
	if current_midi_data == null or current_midi_data.vocal_file_path.is_empty():
		return
	if not current_midi_data.vocal_enabled:
		return
	start_vocal_playback()

## 停止人声（保持文件已加载，位置归零）
func stop_vocal_file() -> void:
	var backend = _get_active_backend()
	if backend != null:
		backend.stop_vocal()

## 卸载人声资源（释放原生 decoder/ring buffer）
func unload_vocal() -> void:
	_vocal_loaded_path = ""
	_vocal_initialized = false
	var backend = _get_active_backend()
	if backend != null:
		backend.unload_vocal()

## 暂停 / 恢复人声
func set_vocal_playing(playing: bool) -> void:
	var backend = _get_active_backend()
	if backend == null:
		return
	if playing:
		backend.resume_vocal()
	elif not playing:
		backend.pause_vocal()

## 获取人声播放进度（毫秒，与 MIDI 同一输出时钟）
func get_vocal_position() -> float:
	var backend = _get_active_backend()
	if backend != null:
		return backend.get_vocal_position_ms()
	return 0.0

## 跳转人声播放进度（毫秒）
func seek_vocal(vocal_position_ms: float) -> void:
	var backend = _get_active_backend()
	if backend != null:
		backend.seek_vocal(vocal_position_ms)

## 人声是否正在播放（自然结束返回 false）
func is_vocal_playing() -> bool:
	var backend = _get_active_backend()
	if backend != null:
		return backend.is_vocal_playing()
	return false

## 人声是否已自然结束
func is_vocal_finished() -> bool:
	var backend = _get_active_backend()
	if backend != null:
		return backend.is_vocal_finished()
	return false

## 人声环形缓冲区欠载次数（诊断用，验证统一时钟架构下欠载是否被根治）
func get_vocal_underrun_count() -> int:
	var backend = _get_active_backend()
	if backend != null and backend.has_method("get_vocal_underrun_count"):
		return backend.get_vocal_underrun_count()
	return 0

## 音频调试诊断信息（延迟分解 / 慢回调统计 / 人声欠载 / 外推量）
func get_audio_debug_info() -> Dictionary:
	var backend = _get_active_backend()
	if backend != null and backend.has_method("get_audio_debug_info"):
		return backend.get_audio_debug_info()
	return {}

## 自动同步人声与MIDI（在_process中每帧调用）
func _sync_vocal_with_midi() -> void:
	var audio_manager = AudioManager.instance
	if audio_manager == null:
		return
	if current_midi_data == null or not current_midi_data.vocal_enabled:
		# vocal 被禁用时确保不残留播放
		if audio_manager.is_vocal_playing():
			audio_manager.set_vocal_playing(false)
		_vocal_initialized = false
		return

	# 自然结束后不再尝试恢复，等待下次 start_vocal_playback
	if _vocal_initialized and audio_manager.is_vocal_finished():
		_vocal_initialized = false
		return

	# 人声是音频流，与 MIDI 合成器共用音频渲染时钟（get_raw_position_ms）。
	# 不要用 get_position_ms()（含视觉判定用的校准/设备延迟），否则会把校准延迟叠进人声导致错位。
	var midi_position_ms: float = get_raw_position_ms()
	var expected_vocal_position = midi_position_ms - vocal_offset_ms

	# 如果人声已初始化但未播放（预卷期间被暂停，或刚 start_vocal_playback）
	if _vocal_initialized and not audio_manager.is_vocal_playing():
		# 只有当 MIDI 已跨越人声起点（vocal_offset_ms）才恢复播放
		if expected_vocal_position >= 0.0:
			audio_manager.set_vocal_playing(true)
			last_sync_check_pos_ms = midi_position_ms
		return

	if not audio_manager.is_vocal_playing():
		return

	# 如果 MIDI 退回到人声起点之前（如 seek 操作），暂停人声防止错位播放
	if expected_vocal_position < 0.0:
		audio_manager.set_vocal_playing(false)
		audio_manager.seek_vocal(0.0)
		return

	# 检查是否需要同步（时间间隔 > 100ms）
	if abs(midi_position_ms - last_sync_check_pos_ms) < 100.0:
		return

	# 获取人声当前播放进度
	var vocal_position = audio_manager.get_vocal_position()
	var diff = abs(vocal_position - expected_vocal_position)

	# 如果差值超过阈值，进行同步调整
	if diff > sync_threshold_ms:
		audio_manager.seek_vocal(expected_vocal_position)
		GLogger.info("Vocal sync adjusted: diff=%.0f ms, target=%.0f ms" % [diff, expected_vocal_position], "MidiPlaybackManager")

	# 更新上次同步检查的位置
	last_sync_check_pos_ms = midi_position_ms

## 设置音频同步阈值（毫秒）
func set_sync_threshold(threshold_ms: float) -> void:
	sync_threshold_ms = clamp(threshold_ms, 1.0, 100000.0)

## 重置同步检查位置（在开始新播放时调用）
# 设为负数确保播放开始后第一次 _sync_vocal_with_midi 就会立即检查同步
# 而不是等 100ms 间隔过去，避免 MIDI/人声启动延迟差异在前 100ms 内不被纠正
func reset_sync_state() -> void:
	last_sync_check_pos_ms = -1000.0

## 配置变更回调（新增）
func _on_config_changed(key: String, section: String, value: Variant) -> void:
	# 处理 Gameplay 部分的配置变更
	if section == "Gameplay":
		if key == "audio_sync_threshold":
			# SettingView emits this after saving. Apply it to the live sync loop
			# so returning from settings does not require starting another game.
			set_sync_threshold(float(value))
			GLogger.info("Audio sync threshold changed to %.0f ms" % sync_threshold_ms, "MidiPlaybackManager")
			return

		# 音频校准延迟变化（设置页 DelayAdjust 保存后触发），实时生效
		# 双预设：普通/蓝牙各存一套；仅当变更的是当前激活预设时才应用
		if key == "audio_playback_delay" or key == "audio_playback_delay_bt":
			if key == ("audio_playback_delay_bt" if _delay_using_bt else "audio_playback_delay"):
				_audio_delay_ms = float(value)
				GLogger.info("Audio playback delay changed to %.0f ms" % _audio_delay_ms, "MidiPlaybackManager")
			else:
				GLogger.info("Audio playback delay preset '%s' updated (inactive, not applied)" % key, "MidiPlaybackManager")

		# 处理音源文件配置变更
		if key == "soundfont_file":
			var soundfont_name = str(value).replace(".sf2", "").strip_edges()
			if not soundfont_name.is_empty():
				set_soundfont(soundfont_name)

	# 处理 Playback 部分的配置变更
	if section == "Playback":
		# 最大复音数改变（需要重新加载SoundFont才能生效）
		if key == "max_polyphony":
			GLogger.info("Polyphony setting changed via config: %s = %s" % [key, value], "MidiPlaybackManager")

			# 获取当前是否正在播放
			var was_playing = is_playing
			var current_pos = get_position_ms()

			# 停止播放
			if was_playing:
				stop()

			# 重新设置复音数并重新加载SoundFont
			var backend = _get_active_backend()
			if backend != null:
				# 设置新的复音数
				var max_polyphony = int(value) if value is int else ConfigManager.instance.get_int("Playback", "max_polyphony", 96)
				backend.set_max_polyphony(max_polyphony)
				GLogger.info("Updated max polyphony to: %d" % max_polyphony, "MidiPlaybackManager")

				# 重新加载SoundFont使设置生效
				_load_soundfont_from_config()
				GLogger.info("Soundfont reloaded with new audio settings", "MidiPlaybackManager")

				# 如果之前正在播放，恢复播放位置
				if was_playing and current_midi_data != null:
					seek(current_pos)
					play()
					GLogger.info("Resumed playback at %.2fms" % current_pos, "MidiPlaybackManager")
			return

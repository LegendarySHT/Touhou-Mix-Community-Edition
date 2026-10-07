## 播放显示层（autoload，全局名 PlaybackDisplay）
##
## 只做「当前曲的显示数据」：MidiData 水合、SOA/notes、BPM 时间线、轨道配置初始化、
## 位置↔tick 换算。**不持有任何播放真值**——是否在播/暂停/位置/当前曲/列表 全在 C# MeltySynth。
##
## 驱动方式：MeltySynth 换曲后发 current_song_changed(key)，这里水合并重建显示数据，
## 再发 display_song_changed 给 UI。熄屏后台期间 C# 自行换曲，回前台第一帧由 C# 补发信号，
## 显示侧据此补齐（不再有 reconcile 双轨）。
extends Node

static var instance: PlaybackDisplay

## PlaybackTypes 的显式 preload 引用（而非直接用全局类名 PlaybackTypes）。
##
## 【为什么不用全局类】Godot 的全局类表来自 `.godot/global_script_class_cache.cfg`，而
## EditorFileSystem::_update_script_classes() 只会把**本次有变更**的脚本重新注册进
## ScriptServer 的映射，再把整张映射写回缓存 —— 即"新加的 class_name 文件"若因故没进那次
## 变更集，就会永久缺失，直到手改文件或删缓存。实测本分支的 PlaybackTypes 就掉过：
## 一旦缺失，所有引用它的脚本在**解析期**就报 "Identifier not declared"，
## 整个 autoload 加载失败 = 游戏起不来。改成 preload 常量后，解析期不再依赖全局类表，
## 任何缓存状态下都能正常启动（类名本身仍保留，供编辑器与其它地方正常使用）。
const PlaybackTypesLib := preload("res://Game/PlaybackTypes.gd")

## 换曲后显示数据已重建（UI/音符可视化据此刷新）
signal display_song_changed(data: MidiData)

# ===== 以下信号为 C# MeltySynth 的转发（保持旧 PlaybackDisplay 的订阅点名不变） =====
signal playback_state_changed
signal transport_changed
signal current_song_changed(data: MidiData)
signal playlist_changed
signal playlist_index_changed(index: int)
signal repeat_mode_changed(mode: int)
signal playlist_user_edited
signal deferred_play_resumed
signal soundfont_reload_completed
signal midi_finished
signal vocal_finished
## 音频焦点变化（Android）：0=GAIN / 1=LOSS_TRANSIENT / 2=DUCK / 3=LOSS
signal audio_focus_changed(state: int)
## 音频设备被播放器判定为已失效（reason 见 C# DEVICE_LOST_REASON_*）。
## 播放器已自行尝试恢复；上层只需表现"声音断了"（如暂停并提示），**不要自己恢复设备**。
signal audio_device_lost(reason: int)
## 设备已恢复（rebuilt=true 表示走了整桥重建）。
signal audio_device_recovered(rebuilt: bool)

## 当前曲的显示数据
var current_midi_data: MidiData = null
var current_notes: Array = []
var bpm_timeline: Array = []
var midi_timebase: int = 480
var duration_ms: float = 0.0
## 从 C# 解析缓存取到的乐器表
var cached_track_channel_instruments: Dictionary = {}

## 解析结果（SOA）限量驻留：只留最近 2 首 + 正在播放的那首
const PARSED_NOTES_CACHE_MAX := 2

func _ready() -> void:
	if instance == null:
		instance = self
	else:
		queue_free()
		return
	add_to_group("singleton")
	process_mode = Node.PROCESS_MODE_ALWAYS
	# C# 传输层换曲 → 重建显示
	if MeltySynth != null and MeltySynth.has_signal("current_song_changed"):
		MeltySynth.current_song_changed.connect(_on_current_song_changed)
	# 转发 C# 信号，订阅点名与旧 PlaybackDisplay 一致
	_forward(MeltySynth, "playback_state_changed", func(): playback_state_changed.emit())
	_forward(MeltySynth, "transport_changed", func(): transport_changed.emit())
	_forward(MeltySynth, "playlist_changed", func(): playlist_changed.emit())
	_forward(MeltySynth, "playlist_user_edited", func(): playlist_user_edited.emit())
	_forward(MeltySynth, "deferred_play_resumed", func(): deferred_play_resumed.emit())
	_forward(MeltySynth, "soundfont_reload_completed", func(): soundfont_reload_completed.emit())
	_forward(MeltySynth, "midi_finished", func(): midi_finished.emit())
	_forward(MeltySynth, "vocal_finished", func(): vocal_finished.emit())
	_forward(MeltySynth, "playlist_index_changed", func(i): playlist_index_changed.emit(i))
	_forward(MeltySynth, "repeat_mode_changed", func(m): repeat_mode_changed.emit(m))
	# 音频焦点（Android AudioManager）：Java → C# → GDScript。
	# 上层据此在"焦点丢失瞬间"暂停、在"焦点归还瞬间"恢复 —— 后者是恢复音频设备唯一可能成功的时刻。
	_forward(MeltySynth, "audio_focus_changed", func(state): audio_focus_changed.emit(state))
	# 音频设备健康（由播放器自己判定与恢复）：上层只消费"断了/回来了"，不自己尝试恢复设备。
	_forward(MeltySynth, "audio_device_lost", func(reason): audio_device_lost.emit(reason))
	_forward(MeltySynth, "audio_device_recovered", func(rebuilt): audio_device_recovered.emit(rebuilt))
	# 全局配置与校准延迟都不在这里读：本 autoload 的 _ready 早于 ConfigManager 加载用户配置，
	# 此刻读只会拿到默认值、并给每个键附一条 "Config key not found" 告警。
	# Main 在配置加载完成后会调 push_global_playback_config() + refresh_audio_delay()
	# ——那才是旧实现（手动单例，_ready 晚于配置加载）的等价时点。
	# 输出设备变化（蓝牙/有线插拔）事件订阅：Android 由 Java AudioDeviceCallback 触发，
	# 立刻重算延迟预设（息屏/后台也不会漏）。
	# 【必须有这条订阅】旧实现只在事件通路不可用时才轮询兜底；若事件通路就绪却没人订阅，
	# 事件发了也无人处理，而轮询又主动让位 → 播放中插拔蓝牙彻底没人响应。
	if AudioBtDetector != null and AudioBtDetector.has_signal("output_changed"):
		if not AudioBtDetector.output_changed.is_connected(_on_audio_output_changed):
			AudioBtDetector.output_changed.connect(_on_audio_output_changed)

## 输出设备变化（插拔蓝牙/有线）：立刻重算延迟预设
func _on_audio_output_changed() -> void:
	GLogger.info("Audio output device changed, refreshing delay preset", "PlaybackDisplay")
	refresh_audio_delay()

## 把全局播放配置推给 C# 播放器（启动、配置加载完成、相关配置变更时调用）。
##
## 【为什么必须"推送"】ConfigManager 是 GDScript 懒创建单例，只 add_to_group("singletons")、
## **从不加入场景树**（见 Utilities/ConfigManager.gd 的 static instance getter）。
## C# 侧 `GetNodeOrNull("/root/ConfigManager")` 恒为 null —— 重构时那套"C# 每帧自己读配置并缓存"
## 的实现其实从未生效，三项设置因此静默失效：默认MIDI音量（永远 0.5）、
## 系统时钟 use_system_stopwatch（永远关，而配置默认是开）、人声同步阈值（从不应用）。
## 改为由显示侧推纯标量：C# 不依赖场景树、不需要跨语言轮询，后台换曲线程也能安全读。
func push_global_playback_config() -> void:
	if MeltySynth == null or not MeltySynth.has_method("set_global_playback_config"):
		return
	var cfg := ConfigManager.instance
	if cfg == null:
		return
	MeltySynth.set_global_playback_config(
		float(cfg.get_float("Gameplay", "default_midi_volume", 50.0)),
		cfg.get_int("Playback", "use_system_stopwatch", 1) != 0,
		float(cfg.get_int("Gameplay", "audio_sync_threshold", 30)),
		float(cfg.get_float("Gameplay", "default_vocal_volume", 50.0)))
	# 恢复"播放器页音量"（本页音量优先于全局默认）—— 不接这一步，存进 [Playback] 的值永远读不回来
	_load_player_volumes()

func _forward(src: Object, sig: String, cb: Callable) -> void:
	if src != null and src.has_signal(sig):
		src.connect(sig, cb)

func _on_current_song_changed(key: String) -> bool:
	if key.is_empty():
		return false
	var data: MidiData = DataMGR.get_midi_by_id(key)
	if data == null:
		GLogger.warning("PlaybackDisplay: no MidiData for key=%s" % key, "PlaybackDisplay")
		return false
	if not set_current(data):
		return false
	display_song_changed.emit(data)
	current_song_changed.emit(data)
	return true

## 确保 MidiCore 的解析缓存里确有这首曲子（没有就补一次解析）。
##
## 【为什么不能只信 midi_data.has_notes()】音符数据在 MidiData 里是一份**快照**（notes_soa 自持
## 平行数组），而 MidiCore 的解析缓存只留 2 首（LRU，见 ParseCacheMax）。浏览过别的谱面之后，
## 这首的快照还在、C# 缓存却已被挤掉 —— 此时所有"直读 C# 缓存"的消费方全部拿不到数据：
##   GetEnabledIndices / GetAllIndices / GetPairs / soa_pairs_of → 空
##   KeySequenceCore.RunGenerateGatherFromPath → TryGetSoa 失败 → 序列数为 0
## 表现就是"进 MidiView 转一圈再打歌，一个音符都没有"，以及轨道配置被初始化成空集。
## 本函数把"快照就绪"与"C# 缓存就绪"合并成同一个前提。
func ensure_parse_cache(midi_data: MidiData) -> bool:
	if midi_data == null:
		return false
	var path := midi_data.midi_file_path
	if path.is_empty():
		path = _locate_midi_file(midi_data)
		if path.is_empty():
			return false
		midi_data.midi_file_path = path
	if MidiCore.HasParsed(path):
		return true
	var pp := _resolve_parse_paths(path)
	if not MidiCore.HasParsed(pp["key"]):
		MidiCore.ParseChartFile(pp["read"], pp["key"])
	if not MidiCore.HasParsed(pp["key"]):
		return false
	GLogger.info("PlaybackDisplay: re-parsed %s (C# parse cache had evicted it)" % path.get_file(), "PlaybackDisplay")
	return true

## 水合并构建某曲的显示数据（不含音频侧；音频换曲由 C# 完成）
func set_current(midi_data: MidiData) -> bool:
	if midi_data == null:
		return false
	VocalTrackController.resolve_vocal_path(midi_data)
	current_midi_data = midi_data

	var midi_file_path := _locate_midi_file(midi_data)
	if midi_file_path.is_empty():
		GLogger.warning("PlaybackDisplay: cannot locate midi for %s" % midi_data.id, "PlaybackDisplay")
		return false
	midi_data.midi_file_path = midi_file_path

	# 快照与 C# 解析缓存都必须就绪：下面的 ensure_track_config_initialized 会用
	# soa_pairs_of()（直读 C# 缓存）枚举轨道；缓存缺失时它会枚举出空集并把
	# "已初始化 + 空选择"持久化下去（轨道全灭）。
	if midi_data.has_notes() and midi_data.track_count > 0 and ensure_parse_cache(midi_data):
		current_notes = midi_data.parsed_notes
		bpm_timeline = midi_data.bpm_timeline.duplicate()
		midi_timebase = midi_data.midi_timebase
		duration_ms = midi_data.duration_ms
	else:
		var pp := _resolve_parse_paths(midi_file_path)
		if not MidiCore.HasParsed(pp["key"]):
			MidiCore.ParseChartFile(pp["read"], pp["key"])
		if not MidiCore.HasParsed(pp["key"]):
			GLogger.warning("PlaybackDisplay: parse failed for %s" % midi_file_path, "PlaybackDisplay")
			return false
		bpm_timeline = MidiCore.GetBpmTimeline(pp["key"])
		midi_timebase = MidiCore.GetTimebase(pp["key"])
		midi_data.set_parsed_soa(pp["key"], midi_timebase, bpm_timeline)
		current_notes = []
		midi_data.track_count = MidiCore.GetTrackCount(pp["key"])
		midi_data.duration_ms = MidiCore.GetDurationMs(pp["key"])
		midi_data.bpm_timeline = bpm_timeline.duplicate()
		midi_data.midi_timebase = midi_timebase
		midi_data.max_end_tick = MidiCore.GetMaxEndTick(pp["key"])
		midi_data.track_channel_instruments = MidiCore.GetTrackInstruments(pp["key"])
		duration_ms = midi_data.duration_ms

	_cache_instruments_for(midi_data)

	if midi_data.selected_track_indices.is_empty():
		for i in range(midi_data.track_count):
			midi_data.selected_track_indices.append(i)

	ensure_track_config_initialized(midi_data, current_notes)
	return true

## 显式卸载显示数据（离开播放等）
func unload() -> void:
	current_midi_data = null
	current_notes = []
	bpm_timeline = []
	cached_track_channel_instruments.clear()
	_instr_cache_chart_key = ""
	midi_timebase = 480
	duration_ms = 0.0

## 解析得到的原始乐器表（"这首曲子原本用什么音色"）。
##
## 【为什么按 chart_key 记】refactor 前它是"只填一次、之后永不更新"的单槽缓存
## （旧实现的注释还写着"切换 MIDI 时会被 clear"，实际只在 unload_midi 里清），
## 于是切歌后 TrackView 的"原始乐器"显示与 warmup_manual_path 用的都是上一首的表。
## 改成按曲键判定：同一首不重复取，换曲必刷新。
var _instr_cache_chart_key: String = ""

func _cache_instruments_for(midi_data: MidiData) -> void:
	if midi_data == null:
		return
	var key := _key_of(midi_data)
	if key == _instr_cache_chart_key and not cached_track_channel_instruments.is_empty():
		return
	var src: Dictionary = midi_data.track_channel_instruments
	if src.is_empty():
		var path := midi_data.midi_file_path
		if not path.is_empty() and MidiCore.HasParsed(path):
			src = MidiCore.GetTrackInstruments(path)
	if src.is_empty():
		return
	_instr_cache_chart_key = key
	cached_track_channel_instruments = src.duplicate(true)

# ===================== 解析 =====================

func ensure_parsed(midi_data: MidiData) -> bool:
	if midi_data == null:
		return false
	# 快照就绪 **且** C# 解析缓存里确实有它，才算"已解析"。
	# 只看 has_notes() 会在缓存被 LRU 挤掉后误判为已就绪，导致下游
	# （GetEnabledIndices / KeySequenceCore 直读缓存）全部拿不到数据。
	if midi_data.has_notes() and midi_data.track_count > 0 and ensure_parse_cache(midi_data):
		if midi_data.runtime_track_channel_notes.is_empty() \
				and midi_data.notes_soa != null and midi_data.notes_soa.size() > 0:
			midi_data.runtime_track_channel_notes = midi_data.notes_soa.grouped_indices()
		return true

	var midi_file_path := _locate_midi_file(midi_data)
	if midi_file_path.is_empty():
		GLogger.warning("PlaybackDisplay: cannot locate MIDI for: %s" % midi_data.id, "PlaybackDisplay")
		return false
	midi_data.midi_file_path = midi_file_path

	var pp := _resolve_parse_paths(midi_file_path)
	if not MidiCore.HasParsed(pp["key"]):
		MidiCore.ParseChartFile(pp["read"], pp["key"])
	if not MidiCore.HasParsed(pp["key"]):
		GLogger.warning("PlaybackDisplay: parse failed: %s" % midi_file_path, "PlaybackDisplay")
		return false

	var tl: Array = MidiCore.GetBpmTimeline(pp["key"])
	midi_data.set_parsed_soa(pp["key"], MidiCore.GetTimebase(pp["key"]), tl)
	midi_data.bpm_timeline = tl.duplicate()
	midi_data.midi_timebase = MidiCore.GetTimebase(pp["key"])
	midi_data.track_count = MidiCore.GetTrackCount(pp["key"])
	midi_data.duration_ms = MidiCore.GetDurationMs(pp["key"])
	midi_data.max_end_tick = MidiCore.GetMaxEndTick(pp["key"])
	cached_track_channel_instruments = MidiCore.GetTrackInstruments(pp["key"])
	midi_data.track_channel_instruments = cached_track_channel_instruments.duplicate(true)
	_instr_cache_chart_key = _key_of(midi_data)
	_trim_parsed_notes_cache()
	return true

func _trim_parsed_notes_cache() -> void:
	var entries: Array[MidiData] = []
	for m in DataMGR.midis.values():
		if m is MidiData and m != current_midi_data and m.has_notes():
			entries.append(m)
	if entries.size() > PARSED_NOTES_CACHE_MAX:
		entries.sort_custom(func(a: MidiData, b: MidiData) -> bool:
			return a.notes_parsed_at < b.notes_parsed_at)
		for i in range(entries.size() - PARSED_NOTES_CACHE_MAX):
			entries[i].clear_parsed_notes()

## 从 C# 解析缓存取去重 (track, channel) 对
func soa_pairs_of(midi_data: MidiData) -> Array:
	var out: Array = []
	if midi_data == null:
		return out
	var path := midi_data.midi_file_path
	if path.is_empty() or not MidiCore.HasParsed(path):
		return out
	var pairs: PackedInt32Array = MidiCore.GetPairs(path)
	for k in pairs:
		out.append([k >> 8, k & 0xFF])
	return out

func get_track_count() -> int:
	if current_midi_data == null or current_midi_data.midi_file_path.is_empty():
		return 0
	return MidiCore.GetTrackCount(current_midi_data.midi_file_path)

# ===================== 轨道配置初始化 =====================

func ensure_track_config_initialized(midi_data: MidiData, notes: Array) -> void:
	if midi_data == null or midi_data.is_track_config_initialized():
		return
	var desc_parse = MidiDescriptionParser.parse(midi_data.description)
	if desc_parse["audio_offset_ms"] >= 0:
		midi_data.vocal_offset_ms = desc_parse["audio_offset_ms"]
	midi_data.desc_recommended_tracks.clear()
	for t in desc_parse["recommended_tracks"]:
		midi_data.desc_recommended_tracks.append(int(t))
	midi_data.selected_track_configs.clear()
	var recommended := midi_data.desc_recommended_tracks
	var use_recommendation := not recommended.is_empty()
	_apply_recommended_pairs(midi_data, recommended, use_recommendation)
	if use_recommendation and midi_data.selected_track_configs.is_empty():
		_apply_recommended_pairs(midi_data, recommended, false)
	midi_data.set_track_config_initialized(true)
	var chart_id_cfg = midi_data.file_hash if not midi_data.file_hash.is_empty() else midi_data.id
	if MidiCore != null and not MidiCore.EnsureDefaultsOnce(chart_id_cfg, midi_data.export_runtime_config()):
		pass

func _apply_recommended_pairs(midi_data: MidiData, recommended: Array, use_recommendation: bool) -> void:
	for pair in soa_pairs_of(midi_data):
		var should_enable := true
		if use_recommendation:
			should_enable = pair[0] in recommended
		midi_data.set_track_channel_enabled(pair[0], pair[1], should_enable)

func set_selected_tracks(tracks_data) -> void:
	if current_midi_data == null:
		return
	if tracks_data is Array:
		if tracks_data.is_empty():
			current_midi_data.selected_track_configs.clear()
			return
		if tracks_data[0] is Dictionary:
			current_midi_data.selected_track_configs.clear()
			for item in tracks_data:
				var track_idx = item.get("track", -1)
				var channel = item.get("channel", -1)
				if track_idx >= 0 and channel >= 0:
					current_midi_data.set_track_channel_enabled(track_idx, channel, true)
		else:
			current_midi_data.selected_track_indices = tracks_data as Array[int]

# ===================== 位置 ↔ tick =====================

func tick_to_ms(tick: float) -> float:
	return _calculate_position_with_bpm_timeline(tick, midi_timebase)

func _calculate_position_with_bpm_timeline(current_tick: float, timebase: int) -> float:
	if bpm_timeline.is_empty():
		var seconds_per_tick: float = 60.0 / (120.0 * timebase)
		return current_tick * seconds_per_tick * 1000.0
	var cumulative_time_ms: float = 0.0
	for i in range(bpm_timeline.size()):
		var entry = bpm_timeline[i]
		var entry_tick = entry["tick"]
		var next_tempo_tick: float
		if i + 1 < bpm_timeline.size():
			next_tempo_tick = bpm_timeline[i + 1]["tick"]
		else:
			next_tempo_tick = current_tick + 1000000
		if current_tick < next_tempo_tick:
			var bpm = entry["bpm"]
			var tick_delta = current_tick - entry_tick
			var ms_per_tick = (60000.0 / bpm) / timebase
			return cumulative_time_ms + tick_delta * ms_per_tick
		else:
			if i + 1 < bpm_timeline.size():
				var next_entry = bpm_timeline[i + 1]
				var bpm2 = entry["bpm"]
				var tick_delta2 = next_entry["tick"] - entry_tick
				cumulative_time_ms += tick_delta2 * ((60000.0 / bpm2) / timebase)
	return cumulative_time_ms

func calculate_tick_from_position_with_bpm_timeline(target_time_ms: float, timebase: int) -> float:
	if bpm_timeline.is_empty():
		var seconds_per_tick: float = 60.0 / (120.0 * timebase)
		return target_time_ms / 1000.0 / seconds_per_tick
	var lo := 0
	var hi := bpm_timeline.size() - 1
	var seg := 0
	while lo <= hi:
		var mid := (lo + hi) >> 1
		if float(bpm_timeline[mid]["time_ms"]) <= target_time_ms:
			seg = mid
			lo = mid + 1
		else:
			hi = mid - 1
	var entry = bpm_timeline[seg]
	var time_in_segment = target_time_ms - entry["time_ms"]
	var ms_per_tick = (60000.0 / entry["bpm"]) / timebase
	return entry["tick"] + time_in_segment / ms_per_tick

# ===================== 音量（UI 侧统一口径） =====================

## 统一解析 MIDI 主音量：per-midi 显式值优先，未配置（<0）回退全局，clamp 到 [0,1]
func get_effective_midi_volume(midi_volume: float) -> float:
	# 全局默认的读取与回退都在 C#（播放侧唯一口径），GDScript 只转发
	if MeltySynth != null and MeltySynth.has_method("get_effective_midi_volume"):
		return float(MeltySynth.get_effective_midi_volume(midi_volume))
	return clampf(midi_volume, 0.0, 1.0)

## 统一把 UI 线性音量应用到后端合成器（TrackView / MidiConfigPersistence / PlayView 共用）
func apply_ui_midi_volume(ui_linear: float) -> void:
	if MeltySynth == null:
		return
	MeltySynth.set_volume_db(maxf(linear_to_db(ui_linear * PlaybackTypesLib.MIDI_VOLUME_GAIN), PlaybackTypesLib.MIN_VOLUME_DB))

# ===================== 路径定位 =====================

func _resolve_parse_paths(path: String) -> Dictionary:
	if FileAccess.file_exists(path):
		return {"read": path, "key": path}
	var files_dir := PathHelper.get_files_dir()
	if not files_dir.is_empty() and path.begins_with(files_dir):
		var fb := path.replace(files_dir, "res://Resources/")
		if FileAccess.file_exists(fb):
			return {"read": fb, "key": path}
	return {"read": path, "key": path}

func _locate_midi_file(midi_data: MidiData) -> String:
	var filesystem_manager = FileSystemManager.instance
	if filesystem_manager == null:
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
	var chart_path: String = metadata.path
	if chart_path.is_empty():
		chart_path = FileSystemManager.CHARTS_DIR.path_join(folder_name)
	var std_path: String = chart_path.path_join("song.mid")
	if FileAccess.file_exists(std_path):
		return std_path
	var midi_file_path: String = chart_path.path_join(chart_id + ".mid")
	if FileAccess.file_exists(midi_file_path):
		return midi_file_path
	var alt_id_path: String = chart_path.path_join(midi_data.id + ".mid")
	if FileAccess.file_exists(alt_id_path):
		return alt_id_path
	if not midi_data.file_hash.is_empty():
		var hash_path: String = chart_path.path_join(midi_data.file_hash + ".mid")
		if FileAccess.file_exists(hash_path):
			return hash_path
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

# ===================== 音源（定位在 GDScript，下发到 C#） =====================

var current_soundfont_path: String = ""
const DEFAULT_SOUNDFONT_PATH := "res://Resources/Soundfont/GeneralUser-GS.sf2"
## MIDI 播放参数的**初值投影**（兼容旧 MidiPlaybackManager 的同名字段名）。
## 只保留 `max_polyphony`（由 set_max_polyphony 维护，与 C# 同步）；
## 原先还有 `volume_db`，已删除：它永远是 -20（重构后没人再同步它），
## 而 DelayAdjust / TrackView 都曾拿它当"当前音量"用 —— DelayAdjust 因此在校准结束时
## 把用户音量冲成 -20dB。真值一律用 get_backend_volume_db() 读 C#。
var midi_player_config: Dictionary = {"max_polyphony": 96}

## 后端当前 MIDI 音量（dB）。真值在 C#（ApplyChartMidiVolume / 播放器页滑块都会改写）。
func get_backend_volume_db() -> float:
	return MeltySynth.get_volume_db() if MeltySynth != null else -20.0

func load_soundfont_from_config() -> void:
	var name: String = str(ConfigManager.instance.get_value("Gameplay", "soundfont_file", "GeneralUser-GS.sf2"))
	name = name.replace(".sf2", "").replace("[内置]", "").strip_edges()
	if not name.is_empty() and set_soundfont(name):
		return
	current_soundfont_path = DEFAULT_SOUNDFONT_PATH

func set_soundfont(soundfont_name: String) -> bool:
	var path := _locate_soundfont(soundfont_name)
	if path.is_empty():
		path = _locate_soundfont("GeneralUser-GS")
		if path.is_empty():
			path = DEFAULT_SOUNDFONT_PATH
	current_soundfont_path = path
	if MeltySynth != null:
		MeltySynth.set_soundfont(path)
	return true

func _locate_soundfont(soundfont_name: String) -> String:
	var user_path: String = PathHelper.get_soundfont_dir().path_join(soundfont_name + ".sf2")
	if FileAccess.file_exists(user_path):
		return user_path
	var res_path: String = "res://Resources/Soundfont/".path_join(soundfont_name + ".sf2")
	if FileAccess.file_exists(res_path):
		return res_path
	return ""

## 启动时预加载音源到后端（异步解析，不阻塞主线程）
func preload_soundfont() -> void:
	if current_soundfont_path.is_empty() or MeltySynth == null:
		return
	MeltySynth.set_soundfont(current_soundfont_path)

## 供即时音符（DelayAdjust 校准等）确保音源已加载
func ensure_soundfont_loaded() -> void:
	preload_soundfont()

# ===================== 手动音符（从 KeySequenceCore 组装下发 C#） =====================

func set_manual_control_from_core(ksm) -> void:
	if ksm == null or MeltySynth == null:
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
	MeltySynth.set_manually_controlled_notes(manually_controlled)

func clear_manual_control_notes() -> void:
	if MeltySynth != null:
		MeltySynth.set_manually_controlled_notes({})

# ===================== 音频校准延迟（视觉位置补偿） =====================

var audio_delay_ms: float = 0.0
var _bt_state_initialized: bool = false
var _delay_using_bt: bool = false

## 刷新输出类型与对应延迟预设。触发：启动、焦点回归、校准窗、播放中兜底轮询。
## 结果下发 C#（MeltySynth.get_visual_position_ms() 用它扣减）。
##
## 注意这里**不因"输出类型没变"就整体早退**：校准值可能刚被设置页改过（同一个输出类型下），
## 早退会让新校准值永远不生效，必须每次都重读一次配置（一次 ConfigManager.get_int，可忽略）。
## 只有"输出类型变化引发的重建音频桥"才需要按变化与否去重。
func refresh_audio_delay() -> void:
	var is_bt := AudioBtDetector.is_bluetooth_output(true)
	var first_check := not _bt_state_initialized
	var output_changed := is_bt != _delay_using_bt
	_bt_state_initialized = true
	_delay_using_bt = is_bt
	if output_changed and not first_check and OS.get_name() == "Windows" and MeltySynth != null:
		# 输出端点换了：WASAPI 流绑定的是打开时的默认设备，必须重建才能跟随。
		# 走统一内核：它会先试就地重启、失败再整桥重建，并还原 MIDI 位置
		#（旧写法先 recreate 再 play_transport，位置会丢 —— 这是"换输出后从头播"的来源）。
		MeltySynth.evaluate_audio_device_health("endpoint_change", false, true)
	_apply_delay_preset()

## 延迟预设被改动时调用（设置页保存 audio_playback_delay[_bt] 之后）。
## 与 refresh_audio_delay 的区别：不做蓝牙重新检测、不重建音频桥，只把"当前激活预设"的
## 新数值下发一次。调用方需保证改的确实是激活预设，否则会把非激活预设的值错误应用。
func apply_audio_delay_from_config() -> void:
	_apply_delay_preset()

## 当前生效的延迟预设键（供调用方判断"这次改的是不是激活预设"）
func active_delay_key() -> String:
	return "audio_playback_delay_bt" if _delay_using_bt else "audio_playback_delay"

func _apply_delay_preset() -> void:
	var key := "audio_playback_delay_bt" if _delay_using_bt else "audio_playback_delay"
	var default_value := 200 if _delay_using_bt else 0
	audio_delay_ms = float(ConfigManager.instance.get_int("Gameplay", key, default_value))
	if MeltySynth != null:
		MeltySynth.set_audio_delay_ms(audio_delay_ms)
	# 生效值只在"预设键或数值变化"时打一条：设备切换后能直接从 logcat 看到最终生效的延迟
	if key != _last_delay_log_key or not is_equal_approx(audio_delay_ms, _last_delay_log_ms):
		_last_delay_log_key = key
		_last_delay_log_ms = audio_delay_ms
		GLogger.info("Audio delay preset [%s] = %.0f ms" % [key, audio_delay_ms], "PlaybackDisplay")

# ===================== 传输门面（转发 C# MeltySynth，保持旧调用点） =====================

var is_playing: bool:
	get: return MeltySynth.is_playing() if MeltySynth != null else false
var is_paused: bool:
	get: return MeltySynth.is_paused() if MeltySynth != null else false
var position_ms: float:
	get: return MeltySynth.get_visual_position_ms() if MeltySynth != null else 0.0
var position: float:
	get:
		if MeltySynth == null or midi_timebase <= 0:
			return 0.0
		return calculate_tick_from_position_with_bpm_timeline(MeltySynth.get_visual_position_ms(), midi_timebase)
var repeat_mode: int:
	get: return MeltySynth.get_repeat_mode() if MeltySynth != null else 0
var playlist_index: int:
	get: return MeltySynth.get_playlist_index() if MeltySynth != null else -1
var deferred_play_pending: bool:
	get: return MeltySynth.get_deferred_play_pending() if MeltySynth != null else false
var midi_player: Node:
	get: return MeltySynth

# ---- 传输 ----
func play() -> void:
	request_audio_focus()
	if MeltySynth != null: MeltySynth.play_transport()
func pause() -> void:
	if MeltySynth != null: MeltySynth.pause_with_vocal()
## 【设备恢复的唯一入口】上层在"可能出问题"的时机调它，由 C# 自己判断该不该恢复、怎么恢复。
##
## 为什么要收敛成这一个：此前"顺序 try 就地 Play、失败再整桥重建"这段逻辑被复制到
## Main 回前台 / resume / 停滞检测 / 焦点归还 四处，每处漏一个条件就是一个 bug
## （典型：曲终后误判成待恢复、预卷期间误启动设备导致假曲终）。
## 现在上层只负责"在正确的时机触发"，判断与执行都在 C# 内部。
func evaluate_audio_device_health(trigger: String) -> bool:
	if MeltySynth == null or not MeltySynth.has_method("evaluate_audio_device_health"):
		return false
	return bool(MeltySynth.evaluate_audio_device_health(trigger, true, true))

# ===================== 播放状态快照（重构阶段 0 引入） =====================
#
# 设计见 Doc/architecture/player_intent_api.md §5.2。目的：让 GDScript 一次拿到完整状态，
# 不再靠 is_playing/is_paused 两个布尔去猜"现在是预卷、在播、还是设备已失效"。
#
# 【枚举镜像：数值即契约】C# 侧快照字段一律是 int，GDScript 用下面这些同序常量比较，
# 不依赖任何跨语言的枚举名解析。**改 C# 枚举时必须同步改这里**（顺序即数值，不可重排）。

## PlaybackPhase（对应 CSharp/PlaybackEnums.cs）
const PHASE_IDLE := 0
const PHASE_PREPARING := 1
const PHASE_PRE_ROLLING := 2
const PHASE_PLAYING := 3
const PHASE_PAUSED := 4
const PHASE_ENDED := 5
const PHASE_STOPPED := 6

## AudioDeviceState（对应 CSharp/PlaybackEnums.cs）
const DEVICE_STATE_ABSENT := 0
const DEVICE_STATE_STOPPED := 1
const DEVICE_STATE_RUNNING := 2
const DEVICE_STATE_START_FAILED := 3

## PlaybackInterruptReason（对应 CSharp/PlaybackEnums.cs）
const INTERRUPT_NONE := 0
const INTERRUPT_AUDIO_FOCUS_LOSS := 1
const INTERRUPT_DEVICE_LOST := 2
const INTERRUPT_APP_BACKGROUNDED := 3
const INTERRUPT_OUTPUT_ENDPOINT_CHANGED := 4

## 一次取全当前播放状态（C# `PlaybackSnapshot`，[GlobalClass] + [Export] 字段可直读）。
##
## ⚠️ 每次调用会**新建一个 RefCounted**：请在每帧开头取一次并缓存整个对象，
## 不要在每个判定入口里现取（判定入口每帧可能调用多次）。
## 返回 null 表示播放器尚未就绪。
func get_playback_snapshot() -> RefCounted:
	if MeltySynth == null or not MeltySynth.has_method("get_playback_snapshot"):
		return null
	return MeltySynth.get_playback_snapshot()

## 只要位置时用这个（同样每次新建对象，理由同上）
func get_playback_position() -> RefCounted:
	if MeltySynth == null or not MeltySynth.has_method("get_playback_position"):
		return null
	return MeltySynth.get_playback_position()

func resume() -> void:
	request_audio_focus()
	# 【不要在 GDScript 侧决定"要不要拉起音频设备"】C# 的 resume() 自己已经分好了：
	#   - 预卷中（_currentOffsetMs < 0）：故意不碰设备，等预卷跨零点由 _Process 统一起播
	#   - 正常续播：PrepareAudioOutputForPlaybackStart() + _audioOutput.Play() 自己起设备
	# 曾经在这里加过一句 resume_audio_output_in_place_or_recreate()，结果在预卷期间把设备
	# 提前拉起来 → 回调渲染全 0 → 被判成 end-of-sequence → 一进打歌页就被抬去结算。
	# 设备恢复只属于"打断/焦点归还"语境，那是 C# 与焦点监听的事。
	if MeltySynth != null: MeltySynth.resume_with_vocal()
func stop() -> void:
	if MeltySynth != null: MeltySynth.stop_transport()
	abandon_audio_focus()

# ---- 音频焦点（Android）----
#
# 本应用此前**没有焦点会话**，所以系统拿走音频焦点时无人通知，只能靠"音频钟停滞 0.5s"
# 事后推断 → 反复拆桥重建、且通话期间必然全部启动失败（空转一整个通话）。
# 现在改成：起播时申请焦点、停播时释放，焦点事件回送到 PlayView 决定暂停/恢复。
const _ANDROID_FOCUS_GAIN := 0
const _ANDROID_FOCUS_LOSS_LIKE := [1, 2, 3]   # TRANSIENT / DUCK / LOSS 都按"该停"处理

## 焦点事件是否已订阅（AndroidBridge 插件注册晚于本 autoload，故每次起播都幂等地试一次）
var _focus_listener_ready: bool = false

func _android_bridge() -> Object:
	if not Engine.has_singleton("AndroidBridge"):
		return null
	return Engine.get_singleton("AndroidBridge")

func request_audio_focus() -> void:
	_ensure_focus_listener()
	var bridge := _android_bridge()
	if bridge == null:
		return
	# 【不要用 has_method 判断 Java 插件能力】JNISingleton 只重写了 callp，
	# 对 Java 插件对象 has_method 恒为 false（C# 侧同款坑，见 MeltySynthPlayer.Transport.cs）。
	bridge.call("request_audio_focus")

## 供打歌页调用：PlayView 开局走的是"seek + resume"而不是本门面的 play()，
## 若不显式申请焦点，打歌期间就没有焦点会话 —— 来电时依旧只有事后停滞检测。
func ensure_audio_focus() -> void:
	request_audio_focus()

func abandon_audio_focus() -> void:
	var bridge := _android_bridge()
	if bridge == null:
		return
	bridge.call("abandon_audio_focus")

func _ensure_focus_listener() -> void:
	if _focus_listener_ready:
		return
	var bridge := _android_bridge()
	if bridge == null:
		return
	if not bridge.has_signal("audio_focus_changed"):
		return
	if not bridge.is_connected("audio_focus_changed", _on_java_audio_focus_changed):
		var err: int = bridge.connect("audio_focus_changed", _on_java_audio_focus_changed)
		if err != OK:
			return
	_focus_listener_ready = true
	GLogger.info("Audio focus listener attached (AndroidBridge.audio_focus_changed)", "PlaybackDisplay")

## Java 侧焦点事件 → 本 autoload 信号（PlayView 消费）
func _on_java_audio_focus_changed(state: int) -> void:
	GLogger.info("Audio focus changed: state=%d (%s)" % [
		state,
		"GAIN" if state == _ANDROID_FOCUS_GAIN else ("LOSS" if state == 3 else "LOSS_TRANSIENT/DUCK"),
	], "PlaybackDisplay")
	audio_focus_changed.emit(state)

## 主动回收托管堆（C# CoreCLR）。供 Core/MemoryGC.gd 在后台内存压力时调用。
## 停顿在几十毫秒级，只在后台/无实时性要求的时机调用。
func collect_managed_garbage() -> void:
	if MeltySynth != null and MeltySynth.has_method("collect_managed_garbage"):
		MeltySynth.collect_managed_garbage()

func seek(pos: float) -> void:
	if MeltySynth != null: MeltySynth.seek_ms(pos)
func handle_media_command(action: String, pos_ms: float = -1.0) -> bool:
	return MeltySynth.handle_media_command(action, pos_ms) if MeltySynth != null else false
func get_position_ms() -> float:
	return MeltySynth.get_visual_position_ms() if MeltySynth != null else 0.0
func get_realtime_position_ms() -> float:
	return MeltySynth.get_visual_position_ms() if MeltySynth != null else 0.0
func get_raw_position_ms() -> float:
	return MeltySynth.get_raw_position_ms() if MeltySynth != null else 0.0
func get_visual_position_ms() -> float:
	return MeltySynth.get_visual_position_ms() if MeltySynth != null else 0.0
func get_backend_duration_ms() -> float:
	return MeltySynth.get_duration_ms() if MeltySynth != null else 0.0
func get_position_tick() -> float:
	return position

# ---- 换曲 / 列表 ----
func play_playlist_index(index: int) -> void:
	if MeltySynth != null: MeltySynth.play_index(index)
func play_next(user_initiated: bool = true) -> bool:
	return MeltySynth.play_next(user_initiated) if MeltySynth != null else false
func play_previous() -> bool:
	return MeltySynth.play_previous() if MeltySynth != null else false
func play_by_key(key: String) -> bool:
	return MeltySynth.play_by_key(key) if MeltySynth != null else false
func shuffle_playlist_from_head() -> bool:
	return MeltySynth.shuffle_playlist_from_head() if MeltySynth != null else false
func playlist_count() -> int:
	return MeltySynth.playlist_count() if MeltySynth != null else 0
func playlist_keys() -> Array:
	return MeltySynth.playlist_keys() if MeltySynth != null else []
func has_playlist() -> bool:
	return MeltySynth.has_playlist() if MeltySynth != null else false
func playlist_has_key(k: String) -> bool:
	return MeltySynth.playlist_has_key(k) if MeltySynth != null else false
func playlist_has_midi(m: MidiData) -> bool:
	return MeltySynth.playlist_has_midi(m) if MeltySynth != null else false
func append_to_playlist(items: Array) -> void:
	if MeltySynth != null: MeltySynth.append_to_playlist(items)
func insert_next_in_playlist(data: MidiData) -> bool:
	return MeltySynth.insert_next_in_playlist(data) if MeltySynth != null else false
func remove_from_playlist(index: int) -> void:
	if MeltySynth != null: MeltySynth.remove_from_playlist(index)
func move_in_playlist(from_idx: int, to_idx: int) -> void:
	if MeltySynth != null: MeltySynth.move_in_playlist(from_idx, to_idx)
func clear_playlist() -> void:
	if MeltySynth != null: MeltySynth.clear_playlist()
func set_playlist_keys(keys: Array, start_index: int = 0) -> void:
	if MeltySynth != null: MeltySynth.set_playlist_keys(keys, start_index)
func restore_playlist() -> void:
	if MeltySynth != null: MeltySynth.restore_playlist()
func ensure_user_playlist() -> void:
	if MeltySynth != null: MeltySynth.ensure_user_playlist()
func adopt_single_into_playlist() -> bool:
	return MeltySynth.adopt_single_into_playlist() if MeltySynth != null else false
func begin_user_session() -> void:
	if MeltySynth != null: MeltySynth.begin_user_session()
func end_user_session() -> void:
	if MeltySynth != null: MeltySynth.end_user_session()
func enter_user_playlist_from_head() -> bool:
	return MeltySynth.enter_user_playlist_from_head() if MeltySynth != null else false
func align_index_to_current() -> void:
	if MeltySynth != null: MeltySynth.align_index_to_current()
## 开始一次会话。
## 【新代码请用下面的意图方法】本方法把"哪种会话"编码成两个位置布尔（persist/loop_file），
## 而 loop_file 恰好决定"曲终干什么"，传错就是结算页里从头再放一遍。意图方法把语义写进名字。
## 保留本方法仅为过渡期兼容。
func start_session(items: Array, start_index: int = 0, persist: bool = true, loop_file: bool = true) -> void:
	if MeltySynth != null: MeltySynth.start_session(items, start_index, persist, loop_file)

# ---- 意图化的会话装配（三个消费方的唯一区别就是这两维，故收敛成三个方法名）----
## 打歌一局：写单曲槽 B（不落盘、不碰用户列表 A），曲终即曲终、不循环 → 交给结算
func start_performance(items: Array, start_index: int = 0) -> void:
	if MeltySynth != null: MeltySynth.start_performance(items, start_index)
## 音轨试听：写单曲槽 B（不落盘），文件级循环（单曲原地重播）
func start_preview(items: Array, start_index: int = 0) -> void:
	if MeltySynth != null: MeltySynth.start_preview(items, start_index)
## 播放器页会话：用户列表 A 生效（可落盘/可推进），文件级循环
func start_player_session(items: Array, start_index: int = 0) -> void:
	if MeltySynth != null: MeltySynth.start_player_session(items, start_index)

## 消费方（FlowArea）解析完音符配置后推来"生成提前量"（= 下落窗口时长，毫秒）
func set_note_generation_lead_ms(ms: float) -> void:
	if MeltySynth != null and MeltySynth.has_method("set_note_generation_lead_ms"):
		MeltySynth.set_note_generation_lead_ms(ms)
## 开局预卷时长（正值 = 提前量，毫秒）。由 C# 按"生成窗口 + 余量"推出，见 C# 侧说明。
func get_pre_roll_duration_ms() -> float:
	if MeltySynth != null and MeltySynth.has_method("get_pre_roll_duration_ms"):
		return float(MeltySynth.get_pre_roll_duration_ms())
	return 1500.0

func start_session_keys(keys: Array, start_index: int = 0) -> void:
	if MeltySynth != null: MeltySynth.start_session_keys(keys, start_index)
func set_repeat_mode(mode: int) -> void:
	if MeltySynth != null: MeltySynth.set_repeat_mode(mode)
func cycle_repeat_mode() -> void:
	if MeltySynth != null: MeltySynth.cycle_repeat_mode()

# ---- 音量 / 轨道 ----
func set_volume_db(db: float) -> void:
	if MeltySynth != null: MeltySynth.set_volume_db(db)
func get_volume_db() -> float:
	return MeltySynth.get_volume_db() if MeltySynth != null else 0.0
const PLAYER_VOL_SECTION := "Playback"
const PLAYER_MIDI_KEY := "player_midi_linear"
const PLAYER_VOCAL_KEY := "player_vocal_db"

## 设置播放器页音量：midi 为 UI 线性(0-1)，vocal 为 dB。
## 立即生效（改的是"实际听到的音量"）+ 缓存给后台换曲（C# 读不到本层）+ 持久化。
func set_player_volumes(midi_linear: float, vocal_db: float) -> void:
	var m := clampf(midi_linear, 0.0, 1.0)
	var v := clampf(vocal_db, -80.0, 12.0)
	apply_ui_midi_volume(m)
	set_vocal_volume_db(v)
	if MeltySynth != null:
		MeltySynth.set_player_volumes(m, clampf(db_to_linear(v), 0.0, 4.0))
	var cfg := ConfigManager.instance
	if cfg != null:
		cfg.set_value(PLAYER_VOL_SECTION, PLAYER_MIDI_KEY, m)
		cfg.set_value(PLAYER_VOL_SECTION, PLAYER_VOCAL_KEY, v)
		_vol_save_pending = true
		_vol_save_timer = 0.0

## 启动时恢复上次的播放器页音量（没有存过则不覆盖，走全局默认/0dB）
func _load_player_volumes() -> void:
	var cfg := ConfigManager.instance
	if cfg == null or MeltySynth == null:
		return
	var m := cfg.get_float(PLAYER_VOL_SECTION, PLAYER_MIDI_KEY, -1.0)
	if m < 0.0:
		GLogger.info("Player volume: nothing stored yet (using global default)", "PlaybackDisplay")
		return
	var v := cfg.get_float(PLAYER_VOL_SECTION, PLAYER_VOCAL_KEY, 0.0)
	MeltySynth.set_player_volumes(clampf(m, 0.0, 1.0), clampf(db_to_linear(clampf(v, -80.0, 12.0)), 0.0, 4.0))
	GLogger.info("Player volume loaded: midi=%.2f vocal=%.1fdB" % [m, v], "PlaybackDisplay")

## 音量落盘防抖：拖动会高频触发，合并成 1 秒后一次整文件写
var _vol_save_pending: bool = false
# 延迟生效值日志的去重状态（只在预设键或值变化时打一条，避免每次焦点回归都刷）
var _last_delay_log_key: String = ""
var _last_delay_log_ms: float = -1.0
var _vol_save_timer: float = 0.0

## 蓝牙输出轮询兜底：Android 正常由 Java AudioDeviceCallback 事件驱动（见 AudioBtDetector），
## 仅在事件通路不可用（插件尚未注册/旧版本）时轮询。没有这条兜底的话，播放中途连上蓝牙
## 不会被发现，延迟预设不切换、进度与可视化错位。Windows 检测要起 MTA 线程，不在此轮询
## （靠焦点回归刷新）。
const BT_POLL_INTERVAL_SEC := 5.0
var _bt_poll_accum: float = 0.0

func _process(delta: float) -> void:
	_tick_bluetooth_fallback(delta)
	_tick_volume_save(delta)

func _tick_bluetooth_fallback(delta: float) -> void:
	if not is_playing or OS.get_name() != "Android":
		return
	if AudioBtDetector.has_output_listener():
		return
	_bt_poll_accum += delta
	if _bt_poll_accum < BT_POLL_INTERVAL_SEC:
		return
	_bt_poll_accum = 0.0
	refresh_audio_delay()

func _tick_volume_save(delta: float) -> void:
	if not _vol_save_pending:
		return
	_vol_save_timer += delta
	if _vol_save_timer < 1.0:
		return
	_vol_save_pending = false
	GLogger.info("Player volume saved: midi=%.2f vocal=%.1fdB" % [
		ConfigManager.instance.get_float(PLAYER_VOL_SECTION, PLAYER_MIDI_KEY, -1.0),
		ConfigManager.instance.get_float(PLAYER_VOL_SECTION, PLAYER_VOCAL_KEY, 0.0)], "PlaybackDisplay")
	var cfg := ConfigManager.instance
	if cfg != null:
		cfg.save_config(ConfigManager.USER_CONFIG_PATH, cfg.get_current_config())

## 播放器页 MIDI 音量（UI 线性值）；尚未由页面设置过时回退全局默认（与滑块初值同源）
func get_player_midi_linear() -> float:
	var v: float = float(MeltySynth.get_player_midi_linear()) if MeltySynth != null else -1.0
	return v if v >= 0.0 else get_effective_midi_volume(-1.0)

## 播放器页人声音量（dB）
func get_player_vocal_db() -> float:
	return MeltySynth.get_player_vocal_db() if MeltySynth != null else 0.0
func set_vocal_volume_db(db: float) -> void:
	if MeltySynth != null: MeltySynth.set_vocal_volume_db(db)
func get_vocal_volume_db() -> float:
	return MeltySynth.get_vocal_volume_db() if MeltySynth != null else -80.0
func set_track_channel_volume(track_index: int, channel: int, volume_linear: float) -> void:
	if MeltySynth != null: MeltySynth.set_track_channel_volume(track_index, channel, volume_linear)
func get_track_channel_volume(track_index: int, channel: int) -> float:
	return MeltySynth.get_track_channel_volume(track_index, channel) if MeltySynth != null else 1.0
func set_track_channel_mute_runtime(track_index: int, channel: int, muted: bool) -> void:
	if MeltySynth != null: MeltySynth.set_track_channel_mute(track_index, channel, muted)
func set_track_channel_instrument(track_index: int, channel: int, bank: int, program: int) -> void:
	if MeltySynth != null: MeltySynth.set_track_channel_instrument(track_index, channel, bank, program)
func get_track_channel_instrument(track_index: int, channel: int) -> Dictionary:
	return MeltySynth.get_track_channel_instrument(track_index, channel) if MeltySynth != null else {}
func get_presets_list() -> Array:
	return MeltySynth.get_presets_list() if MeltySynth != null else []
func get_preset_name(program: int, bank: int = 0) -> String:
	return MeltySynth.get_preset_name(program, bank) if MeltySynth != null else ""
func set_max_polyphony(v: int) -> void:
	midi_player_config["max_polyphony"] = v
	if MeltySynth != null: MeltySynth.set_max_polyphony(v)

## 按当前音源重建合成器并保住播放位置/播放态（复音数等创建期参数改完后调用）
func reload_soundfont_preserving_position() -> void:
	if MeltySynth != null: MeltySynth.reload_soundfont_preserving_position()
func warmup_manual_path() -> void:
	if MeltySynth != null: MeltySynth.warmup_manual_path(cached_track_channel_instruments)
func trigger_note_on(pitch: int, velocity: int, channel: int, track_index: int = 0) -> void:
	if MeltySynth != null: MeltySynth.trigger_note_on(pitch, velocity, channel, track_index)
func trigger_note_off(pitch: int, velocity: int, channel: int, track_index: int = 0) -> void:
	if MeltySynth != null: MeltySynth.trigger_note_off(pitch, velocity, channel, track_index)
func trigger_notes_on(events: Array) -> void:
	if MeltySynth != null: MeltySynth.trigger_notes_on(events)

# ---- 轨道静音（显示侧同时更新 MidiData 状态） ----
func set_track_channel_mute(track_index: int, channel: int, muted: bool) -> void:
	if current_midi_data != null:
		current_midi_data.set_track_channel_mute(track_index, channel, muted)
	if MeltySynth != null:
		MeltySynth.set_track_channel_mute(track_index, channel, muted)

func get_original_track_channel_instrument(track_index: int, channel: int) -> Dictionary:
	if cached_track_channel_instruments.has(track_index):
		var ch_map: Dictionary = cached_track_channel_instruments[track_index]
		if ch_map.has(channel):
			return ch_map[channel]
	return {}

# ---- 人声 ----
func set_vocal_offset_ms(offset_ms: float) -> void:
	if MeltySynth != null: MeltySynth.set_vocal_offset_ms(offset_ms)
func get_vocal_position() -> float:
	return MeltySynth.get_vocal_position() if MeltySynth != null else 0.0
func seek_vocal(position_ms: float) -> void:
	if MeltySynth != null: MeltySynth.seek_vocal(position_ms)
func set_vocal_playing(on: bool) -> void:
	if MeltySynth != null: MeltySynth.set_vocal_playing(on)
func play_vocal_file(path: String, offset_ms: float = 0.0) -> bool:
	return MeltySynth.play_vocal_file(path, offset_ms) if MeltySynth != null else false
func stop_vocal_file() -> void:
	if MeltySynth != null: MeltySynth.stop_vocal_file()
func unload_vocal() -> void:
	if MeltySynth != null: MeltySynth.unload_vocal()
func is_vocal_playing() -> bool:
	return MeltySynth.is_vocal_playing() if MeltySynth != null else false
func is_vocal_finished() -> bool:
	return MeltySynth.is_vocal_finished() if MeltySynth != null else false
func get_vocal_length_ms() -> float:
	return MeltySynth.get_vocal_length_ms() if MeltySynth != null else -1.0
func get_vocal_underrun_count() -> int:
	return MeltySynth.get_vocal_underrun_count() if MeltySynth != null else 0
func get_audio_debug_info() -> Dictionary:
	return MeltySynth.get_audio_debug_info() if MeltySynth != null else {}
func reset_sync_state() -> void:
	if MeltySynth != null: MeltySynth.reset_vocal_sync()

## 列表导航 / 杂项
## 人声漂移同步阈值（毫秒）：真值在 C#，这里只读。
## 旧实现是普通 var，重构后没人再写它 —— 留着普通 var 会变成"看着像真值、其实是常量"的陷阱。
var sync_threshold_ms: float:
	get: return float(MeltySynth.get_sync_threshold_ms()) if MeltySynth != null else 200.0
const default_soundfont_path := "res://Resources/Soundfont/GeneralUser-GS.sf2"
## 偏移设置变化而播放继续时重新对齐人声（TrackView 的延迟输入框提交后调用）。
## 守卫与旧实现的 _seek_vocal_to_midi_position 一致：没配置/未启用人声时什么都不做，
## 否则"改一下偏移"会把用户已禁用的人声又放出来。
func apply_vocal_offset() -> void:
	var data: MidiData = current_midi_data
	if data == null or data.vocal_file_path.is_empty() or not data.vocal_enabled:
		return
	if MeltySynth != null: MeltySynth.apply_vocal_offset()

## 播放中启用/导入人声后立即对齐起播（TrackView 的人声按钮与人声导入用）。
## 偏移与路径由显示侧传入：TrackView 刚改过的人声可能还没落盘到 chart_runtime，
## 而"该用哪个文件"此刻只有显示侧的 MidiData 知道。起始位置默认取当前原始播放位置。
func start_vocal_playback(start_ms_override: float = -1.0) -> void:
	if MeltySynth == null:
		return
	# 先解除"用户已关闭人声"的抑制，否则后续自动同步不会把人声拉回来
	if MeltySynth.has_method("set_vocal_enabled_runtime"):
		MeltySynth.set_vocal_enabled_runtime(true)
	var data: MidiData = current_midi_data
	if data == null or data.vocal_file_path.is_empty():
		return
	var pos: float = start_ms_override if start_ms_override >= 0.0 else get_raw_position_ms()
	MeltySynth.start_vocal_at(data.vocal_file_path, float(data.vocal_offset_ms), pos)

## 关闭人声（TrackView 的人声开关）。除了停播，还要抑制自动同步把人声又拉起来
## ——旧实现靠检查 MidiData.vocal_enabled 达到同一效果。
func stop_vocal_playback() -> void:
	if MeltySynth == null:
		return
	if MeltySynth.has_method("set_vocal_enabled_runtime"):
		MeltySynth.set_vocal_enabled_runtime(false)
	else:
		MeltySynth.stop_vocal_playback()

## 人声预加载：音频侧在 load_midi → apply_chart_audio_config 里已按权威配置装载并起播人声
## （含偏移门控），故这里无需再做任何事；保留空实现只为兼容既有调用点。
func prepare_vocal_playback() -> void:
	pass

# ---- 页面生命周期（旧 SystemMediaSession 语义：注册=通知可见，注销=退出播放并撤下通知）----
## 注册播放页面：立刻推一次媒体状态，让通知/锁屏卡片马上出现
## （否则要等 TickTransport 的下一个 0.5s 节拍）
func register_view(view: Node = null) -> void:
	# 注册 = 允许推送媒体状态（旧 SystemMediaSession.has_view() 的等价物）；
	# C# 侧置位后立刻推一次，并让周期推送重新生效。
	if view != null:
		claim_session(view)
	if MeltySynth == null:
		return
	if MeltySynth.has_method("register_media_view"):
		MeltySynth.register_media_view()
	elif MeltySynth.has_method("refresh_media_state"):
		MeltySynth.refresh_media_state()

## 注销播放页面：停播 + **撤下媒体通知**。
## 旧 SystemMediaSession.unregister_view 在 stop() 之后还会调后端 clear()；
## 重构后只 stop()，通知会以 STOPPED 状态一直挂在通知栏（前台服务也不退）。
func unregister_view(view: Node = null) -> void:
	# 注销自己时一并交出会话所有权（别的页面接管时会自行 claim）
	if view != null and _session_owner != null and _session_owner.get_ref() == view:
		_session_owner = null
	stop()
	if MeltySynth != null and MeltySynth.has_method("clear_media_notification"):
		MeltySynth.clear_media_notification()

# ---- 会话所有权 ----------------------------------------------------------
#
# 【为什么需要它】后端事件（`midi_finished`、设备类信号）是**全局**的，不区分是谁在放；
# 而"谁在放"至少有三种合法情形（打歌页 / 音轨试听 / 播放器页背景播放）。
# 之前各页面只能靠 `current_state == 本页` 去猜"这个事件归不归我管"，
# 于是 PlayView 常驻订阅 `midi_finished` 就把播放器页的"播完自动下一首"杀死了。
#
# 【判据是"会话所有权"而不是"页面是否可见"】后台播放时页面可以不可见却仍归它管；
# 反过来页面可见时播放也可能归别人管（媒体命令/后台推进）。故显式记录"谁起的这次会话"。
#
# 【谁该 claim】在"页面开始驱动播放"的那一步：PlayView._prepare_game（装配一局）、
# TrackView 打开/重载、MusicPlayerView 激活页与接管用户会话。
# 本类里所有"起会话"的转发（start_session / begin_user_session / prepare_vocal_playback）
# 会自动把最近一次发起者记为 owner，调用方不必额外写。

var _session_owner: WeakRef = null

## 认领当前播放会话（谁起会话谁调用）。多次调用以最后一次为准。
func claim_session(view: Node) -> void:
	if view == null:
		return
	_session_owner = weakref(view)

## 当前这次播放是否归 `view` 管。后端全局信号的 handler 应据此门控。
##
## 判据顺序：
##   1. 有页面显式 claim 过 → 只认它（页面接管场景，如播放器页接管用户会话）
##   2. 无人 claim（典型：后端被媒体命令/后台推进自行起播）→ **当前活跃页即 owner**
## 第 2 条退化的意义：正常路径永远不被误挡，而"非活跃页"仍然会被挡下 ——
## 这正是要修的那类跨页误触发（PlayView 曾常驻订阅，把播放器页的自动切歌杀死）。
func is_session_owner(view: Node) -> bool:
	if view == null:
		return false
	if _session_owner != null:
		var owner: Node = _session_owner.get_ref() as Node
		if owner != null:
			return owner == view
		_session_owner = null   # 页面已释放
	if UiStatMGR == null or not ("work_state" in view):
		return false
	return UiStatMGR.current_state == view.work_state

## 会话是否已被任何页面认领（诊断用）
func has_session_owner() -> bool:
	return _session_owner != null and _session_owner.get_ref() != null


# ---- 杂项后端 ----
# 【已移除 recover_audio_output() / recreate_audio_output() 两个转发】
# 设备恢复只有 evaluate_audio_device_health() 一个入口：上层在正确时机触发，
# 由 C# 判断"就地重启还是整桥重建"。留着这两个转发等于给设备决策又开了后门。
func set_sync_threshold(ms: float) -> void:
	if MeltySynth != null: MeltySynth.set_sync_threshold(ms)
func is_soundfont_reload_pending() -> bool:
	return MeltySynth.is_soundfont_reload_pending() if MeltySynth != null else false
## 载入某曲：显示侧重建 + 音频侧（C#）载入并应用谱面配置。起播仍由调用方 play()。
func load_midi(midi_data: MidiData, _display_only: bool = false) -> bool:
	if not set_current(midi_data):
		return false
	if MeltySynth != null and not midi_data.midi_file_path.is_empty():
		MeltySynth.load_midi(midi_data.midi_file_path)
		MeltySynth.apply_chart_audio_config(_key_of(midi_data))
	return true

func _key_of(m: MidiData) -> String:
	if m == null:
		return ""
	return m.chart_key if not m.chart_key.is_empty() else m.id

## 显式卸载当前 MIDI 资源（释放原生人声、停止后端、清理显示数据）。
## 与旧实现的 unload_midi 对齐：旧版会 AudioManager.unload_vocal() 释放原生 decoder /
## ring buffer，重构后只 stop_transport，人声资源会一直驻留到下次换曲。
func unload_midi() -> void:
	if MeltySynth != null:
		MeltySynth.stop_transport()
		MeltySynth.unload_vocal()
	unload()
## 对账：把显示侧对齐到 C# 的当前曲。
##
## 熄屏/深后台期间 Godot 主循环停摆，C# 自行换曲时发的 current_song_changed 没人处理；
## 回前台若只依赖那一次补发信号，就可能出现「通知栏已是新歌、点开页面还显示旧歌」的时序窗口
## （UI 状态切换发生在 _Process 补发之前）。故进入播放器页等时机显式对账一次。
## 幂等：两边一致时零开销直接返回。
func reconcile_current_song() -> bool:
	if MeltySynth == null or not MeltySynth.has_method("get_current_key"):
		return false
	var key: String = str(MeltySynth.get_current_key())
	if key.is_empty():
		return false
	if current_midi_data != null and _key_of(current_midi_data) == key:
		return false
	return _on_current_song_changed(key)

func sync_display_if_needed() -> void:
	reconcile_current_song()
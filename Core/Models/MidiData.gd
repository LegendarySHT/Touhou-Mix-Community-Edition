## MIDI 谱面数据模型
## 代表一个单独的MIDI谱面记录
class_name MidiData
extends Resource

## 唯一标识符
var id: String

## 规范键（ChartDb 主键 = folder_name），水合时由 DataMGR._ensure_midi 填充；
## 跨模块 ID 传递应优先使用此字段，避免 id / file_hash 别名混用（TMX-020）
var chart_key: String = ""

## 谱面名称
var name: String

## 谱面描述
var description: String

## 谱面状态 (PENDING, APPROVED, INCLUDED, DEAD)
var status: String

## 作曲者名字
var artist_name: String

## 上传者名字
var uploader_name: String

## 原曲作者
var author_name: String

## 规范化搜索副本（简繁日互搜用；水合时由 C# ChartDB 预计算，不持久化）
## 谱面名/原曲名/专辑名/歌手/原曲作者/上传者 6 字段（简介除外）都可能含日文
## （忠于原始的标题、声优名、幻乐团等），统一归一后 简/繁/日 三种写法互搜，避免「简体搜不到繁体」。
var search_song_name: String = ""
var search_author_name: String = ""
var search_album_name: String = ""
var search_artist_name: String = ""
var search_name: String = ""
var search_uploader_name: String = ""

## 上传日期
var uploaded_date: String

## 所属歌曲 id / 名称（DB chart 文档扁平字段，替代原 SongData 对象水合）
var song_id: String = ""
var song_name: String = ""

## 所属专辑 id / 名称（DB chart 文档扁平字段，替代原 AlbumData 对象水合）
var album_id: String = ""
var album_name: String = ""

## 统计数据 - 试玩数
var trial_count: int = 0

## 统计数据 - 下载数
var download_count: int = 0

## 统计数据 - 好评数
var up_count: int = 0

## 统计数据 - 差评数
var down_count: int = 0

## 统计数据 - 平均准确率
var avg_accuracy: float = 0.0

## 统计数据 - 通关人数
var pass_count: int = 0

## 统计数据 - 失败人数
var fail_count: int = 0

## 评级分布
var rank_distribution: Dictionary = {
	"S": 0,
	"A": 0,
	"B": 0,
	"C": 0,
	"D": 0,
	"F": 0
}

## MIDI文件哈希（MD5）
var file_hash: String = ""

## ========== MIDI播放相关字段 ==========

## MIDI文件完整路径
var midi_file_path: String = ""

## MIDI轨道总数
var track_count: int = 1

## 已选中的轨道索引列表（支持多轨选择）
var selected_track_indices: Array[int] = []

## 已选中的轨道和通道配置 (格式: {track_idx: [ch0, ch1, ...], ...})
var selected_track_configs: Dictionary = {}

## (track, channel) 对的 mute 状态映射 (格式: {track_idx: {channel: bool}})
var track_channel_mute_state: Dictionary = {}

## 已选中的音源文件名（默认为空表示使用系统默认）
var use_soundfont: String = ""

## 已解析的MIDI音符数据（SOA 规范形态，见 notes_soa）
## 说明：音符数据唯一事实来源是 notes_soa（紧凑并行数组），不再 materialize 全量 NoteEvent。
## parsed_notes 仅在极少数仍需全量对象的兼容路径下按需构建（调用方构建后自行释放引用）。
var parsed_notes: Array = []

## SOA 只读访问器（6 个并行紧凑数组），音符数据唯一事实来源
## 由 MidiPlaybackManager.ensure_parsed / load_midi 构建；为空 = 尚未解析
## Android 大谱面内存优化：22w 音符 = 6 个 PackedInt32Array，而非 22w NoteEvent 对象
var notes_soa: NoteSoa = null

## notes_soa 的最近构建时刻（毫秒）。浏览列表时每个可见项都会预解析，
## 而清理只挂在"选中切换"上，只滚动不点选的歌曲会永久滞留；
## MidiPlaybackManager 据此按最近使用顺序淘汰（见 _trim_parsed_notes_cache）
var notes_parsed_at: int = 0

## 缓存的 (track, channel) → 索引分组（运行时缓存，不持久化）
## 由 ensure_parsed 一次性构建，TrackView._build_buckets 直接复用
## 避免主线程 O(N) 遍历 SOA 重新分组，进入 TrackView 时主线程仅做 O(Buckets) 转换
## 格式：{ "track:channel": PackedInt32Array（notes_soa 索引，按 start_tick 升序）, ... }
var runtime_track_channel_notes: Dictionary = {}

## MIDI总时长（毫秒）
var duration_ms: float = 0.0

## MIDI BPM 变化时间线（解析后缓存，供预览计算使用）
## 格式：[{tick, bpm, time_ms}, ...]
var bpm_timeline: Array = []

## MIDI 时间基准（ticks per quarter note），解析后缓存
var midi_timebase: int = 480

## MIDI 最大 end_tick（所有音符结束 tick 的最大值，解析后缓存）
## 用于 NoteDisplayer ct 异常保护，避免循环播放时 ct 越界导致 active_notes 累积
## 类型为 float 与 NoteEvent.start_time / NoteState.start_tick 对齐，避免比较时隐式转换
var max_end_tick: float = 0.0

## MIDI 解析时提取的 (track, channel) → {bank, program} 乐器映射（运行时缓存，不持久化）
## 由 C# MidiParserNative 一次性提取，替代原 extract_track_channel_instruments 的 GDScript 遍历
## 缓存命中时 MidiPlaybackManager.load_midi 直接复用此字段，无需重新解析
var track_channel_instruments: Dictionary = {}

## ========== 用户配置字段（运行时可修改，需持久化）==========

## MIDI播放音量（线性 0.0-1.0；UI→增益映射系数见 MidiPlaybackManager.MIDI_VOLUME_GAIN，0.5=+6dB；-1=未配置，使用全局 default_midi_volume）
## 注意：0.5 是合法显式值（用户设 50%），不再兼任"未配置"哨兵
var midi_volume: float = -1.0

## 人声音量（线性 0.0-1.0）
var vocal_volume: float = 0.5

## 人声文件路径（完整路径或相对路径）
var vocal_file_path: String = ""

## 人声音频偏移量（毫秒）
var vocal_offset_ms: int = 0

## 人声启用/禁用状态（默认禁用，需在TrackView中手动启用）
var vocal_enabled: bool = false

## 轨道-通道音量配置 {track_idx: {ch_idx: float(0.0-1.0)}}
var track_channel_volume_config: Dictionary = {}

## 独奏状态 (track:channel -> true)
var solo_pairs: Dictionary = {}

## 用户自定义的轨道-通道音色覆盖 {track_idx: {channel: {bank: int, program: int, name: String}}}
## 专门存储用户覆盖配置（持久化到 JSON）；MIDI 解析的原始乐器值由 MidiPlaybackManager.cached_track_channel_instruments 持有
var track_channel_instrument_overrides: Dictionary = {}

## 标记：音轨配置是否曾被初始化过（用于区分"新MIDI"和"所有音轨禁用"两种情况）
## 该标记在第一次配置时被设为true，保存到JSON中，使得重新加载时不会误把禁用状态视为新MIDI
var _track_config_initialized: bool = false

## 查询音轨配置是否已初始化（外部读取统一走此方法，避免跨类直读私有字段，TMX-019）
func is_track_config_initialized() -> bool:
	return _track_config_initialized

## 设置音轨配置初始化标记（外部写入统一走此方法，TMX-019）
func set_track_config_initialized(value: bool) -> void:
	_track_config_initialized = value

## 从简介解析出的推荐轨道索引（仅首次加载时填充，运行时缓存，不持久化）
## 用于 TrackView 首次初始化时设置默认启用的轨道；为空表示简介无推荐，按原逻辑启用全部
var desc_recommended_tracks: Array[int] = []

## 从JSON数据构造MIDI数据
## chart_key：规范键（folder_name）。用于从 MidiCore（配置权威）读取运行时配置；
## 留空则回退 json_data 里的 _runtime 注入字段（兼容旧调用方式）。
func from_json(json_data: Dictionary, chart_key: String = "") -> void:
	id = json_data.get("_id", "")
	name = json_data.get("name", "")
	description = json_data.get("desc", "")
	status = json_data.get("status", "PENDING")
	artist_name = json_data.get("artistName", "")
	uploader_name = json_data.get("uploaderName", "")

	var author_val = json_data.get("author", "")
	if author_val is String:
		author_name = author_val
	elif author_val is Dictionary:
		author_name = author_val.get("name", "")

	uploaded_date = json_data.get("uploadedDate", "")

	# 所属歌曲/专辑（扁平字段，来自 GetChartJson 的 song_id/song_name/album_id/album_name，不再水合 SongData/AlbumData）
	song_id = json_data.get("song_id", "")
	song_name = json_data.get("song_name", "")
	album_id = json_data.get("album_id", "")
	album_name = json_data.get("album_name", "")

	# 规范化搜索副本（C# ChartDB 在 GetChartJson 注入，简繁日互搜用）
	search_song_name = json_data.get("_search_song_name", "")
	search_author_name = json_data.get("_search_author_name", "")
	search_album_name = json_data.get("_search_album_name", "")
	search_artist_name = json_data.get("_search_artist_name", "")
	search_name = json_data.get("_search_name", "")
	search_uploader_name = json_data.get("_search_uploader_name", "")
	
	# 处理两种格式的字段名
	trial_count = json_data.get("trialCount", 0)
	download_count = json_data.get("downloadCount", 0)
	up_count = json_data.get("upCount", 0)
	down_count = json_data.get("downCount", 0)
	
	# 平均准确率可能有不同字段名（优先 avgAccuracy，兼容 avg_accuracy）
	avg_accuracy = json_data.get("avgAccuracy", json_data.get("avg_accuracy", 0.0))
	
	pass_count = json_data.get("passCount", 0)
	fail_count = json_data.get("failCount", 0)
	file_hash = json_data.get("hash", "")
	
	# 处理评级分布
	rank_distribution["S"] = json_data.get("sCount", 0)
	rank_distribution["A"] = json_data.get("aCount", 0)
	rank_distribution["B"] = json_data.get("bCount", 0)
	rank_distribution["C"] = json_data.get("cCount", 0)
	rank_distribution["D"] = json_data.get("dCount", 0)
	rank_distribution["F"] = json_data.get("fCount", 0)
	
	# 读取用户运行时配置。
	#
	# 来源是 MidiCore（配置权威），不是 json_data 里的 _runtime 注入——后者是第二条
	# 水合路径，两条并存会分歧。传入 chart_key 时从权威取；未传则回退旧注入字段
	# （调用方若不提供 key，至少仍能按原路径水合，不会静默丢配置）。
	var runtime_config: Variant = {}
	if not chart_key.is_empty() and MidiCore != null:
		var cfg: Variant = MidiCore.GetConfig(chart_key)
		if cfg is Dictionary:
			runtime_config = cfg
	else:
		runtime_config = json_data.get("_runtime", {})
	if runtime_config is Dictionary:
		midi_volume = float(runtime_config.get("midi_volume", -1.0))
		# 迁移：历史版本把"未配置"存成 0.5（默认值落盘），与显式 50% 无法区分。
		# 由于旧代码下显式 0.5 也总是回退全局默认，迁移为 -1（未配置）与原行为一致，
		# 且修复了"用户显式设 50% 被全局默认覆盖"的问题（此后显式值才真正生效）。
		if midi_volume == 0.5:
			midi_volume = -1.0
		vocal_volume = float(runtime_config.get("vocal_volume", 0.5))
		# 兼容旧版 0-100 存值：大于 1 视为旧百分比，折算为 0-1
		if midi_volume > 1.0:
			midi_volume /= 100.0
		if vocal_volume > 1.0:
			vocal_volume /= 100.0
		vocal_enabled = runtime_config.get("vocal_enabled", false)
		
		# 恢复轨道选择配置
		var saved_track_indices = runtime_config.get("selected_track_indices", [])
		if saved_track_indices is Array and not saved_track_indices.is_empty():
			selected_track_indices.clear()
			for idx in saved_track_indices:
				selected_track_indices.append(int(idx))
		
		# 恢复轨道静音状态（处理JSON中的字符串键）
		var saved_mute_state = runtime_config.get("track_channel_mute_state", {})
		if saved_mute_state is Dictionary:
			track_channel_mute_state.clear()
			for track_key in saved_mute_state.keys():
				var track_idx = int(track_key)  # JSON中的整数键被转换为字符串
				var channels = saved_mute_state[track_key]
				if channels is Dictionary:
					track_channel_mute_state[track_idx] = {}
					for ch_key in channels.keys():
						var channel = int(ch_key)
						track_channel_mute_state[track_idx][channel] = channels[ch_key]
		
		# 恢复轨道音量配置（处理JSON中的字符串键）
		var saved_track_volumes = runtime_config.get("track_channel_volume_config", {})
		if saved_track_volumes is Dictionary:
			track_channel_volume_config.clear()
			for track_key in saved_track_volumes.keys():
				var track_idx = int(track_key)  # JSON中的整数键被转换为字符串
				var channels = saved_track_volumes[track_key]
				if channels is Dictionary:
					track_channel_volume_config[track_idx] = {}
					for ch_key in channels.keys():
						var channel = int(ch_key)
						track_channel_volume_config[track_idx][channel] = float(channels[ch_key])
		
		var saved_soundfont = runtime_config.get("use_soundfont", "")
		if saved_soundfont is String:
			use_soundfont = saved_soundfont
		
		# 恢复独奏状态
		var saved_solo_pairs = runtime_config.get("solo_pairs", {})
		if saved_solo_pairs is Dictionary:
			solo_pairs = saved_solo_pairs.duplicate()
		
		# 恢复音轨配置初始化标记
		_track_config_initialized = runtime_config.get("_track_config_initialized", false)
		
		# 恢复音轨启用状态（处理JSON中的字符串键）
		# 关键：区分"从未保存过"和"保存的配置为空（所有禁用）"
		if runtime_config.has("selected_track_configs"):
			# 该MIDI已经配置过，恢复保存的配置（可能是空）
			var saved_track_configs = runtime_config.get("selected_track_configs", {})
			if saved_track_configs is Dictionary:
				selected_track_configs.clear()
				for track_key in saved_track_configs.keys():
					var track_idx = int(track_key)  # JSON中的整数键被转换为字符串
					var channels = saved_track_configs[track_key]
					if channels is Array:
						# 将数组中的元素转换为整数（通道编号）
						selected_track_configs[track_idx] = []
						for ch in channels:
							selected_track_configs[track_idx].append(int(ch))
				# selected_track_configs 可能为空，这表示用户禁用了所有音轨（正常行为）
			_track_config_initialized = true  # 标记为已配置
		else:
			# 第一次加载此MIDI，没有保存过配置：保持 selected_track_configs 为空。
			# "未初始化"（_track_config_initialized == false）的语义是"默认全部启用"，
			# 由 MidiPlaybackManager.load_midi / MidiListItem 等消费方按此处理。
			# 不要写入 {0:[0]} 占位：会让 MidiListItem 误以为仅启用 track0/ch0，
			# 导致音符全在第 1 轨之后的谱面在 MidiView 首次显示 0 音符（issue #62）。
			pass
		
		# 恢复人声文件路径
		var saved_vocal_path = runtime_config.get("vocal_file_path", "")
		if saved_vocal_path is String:
			vocal_file_path = saved_vocal_path

		# 恢复人声偏移量
		var saved_vocal_offset = runtime_config.get("vocal_offset_ms", 0)
		if saved_vocal_offset is int:
			vocal_offset_ms = saved_vocal_offset
		elif saved_vocal_offset is float:
			vocal_offset_ms = int(saved_vocal_offset)
		
		# 恢夏用户自定义的乐器覆盖（处理 JSON 中的字符串键）
		var saved_instrument_overrides = runtime_config.get("track_channel_instrument_overrides", {})
		if saved_instrument_overrides is Dictionary:
			track_channel_instrument_overrides.clear()
			for track_key in saved_instrument_overrides.keys():
				var track_idx = int(track_key)
				var channels = saved_instrument_overrides[track_key]
				if channels is Dictionary:
					track_channel_instrument_overrides[track_idx] = {}
					for ch_key in channels.keys():
						var channel = int(ch_key)
						var instr_data = channels[ch_key]
						if instr_data is Dictionary:
							track_channel_instrument_overrides[track_idx][channel] = {
								"bank": instr_data.get("bank", 0),
								"program": instr_data.get("program", 0),
								"name": instr_data.get("name", "")
							}

	# 简介解析与推荐轨道应用统一在 MidiPlaybackManager.load_midi 中完成
	# - 首次进入 TrackView 时解析简介、设置 vocal_offset_ms、应用推荐轨道、标记 _track_config_initialized=true 并持久化
	# - from_json 只读取 _track_config_initialized（用于 MidiPlaybackManager 判断是否需要初始化）
	# 这样避免 DataManager 加载阶段（每次启动）重复解析简介

## 设置选中的轨道
func set_selected_tracks(track_indices: Array[int]) -> void:
	selected_track_indices = track_indices

## 检查指定的(track, channel)是否被选中
func is_track_channel_selected(track_idx: int, channel: int) -> bool:
	if not selected_track_configs.has(track_idx):
		return false
	return channel in selected_track_configs[track_idx]

## 获取扁平化的 (track, channel) 启用对，键格式为 "track:channel"，值固定为 true
## 用于 KeySequenceManager.generate_keys 的 cache_key 一致性（MidiListItem 与 PlayView 必须用同一格式）
## 注意：返回空字典时，调用方需结合 _track_config_initialized 判断语义：
##   - _track_config_initialized == true → 用户主动禁用了所有轨道（显示 0 / 报错）
##   - _track_config_initialized == false → 从未进过 TrackView，应视为"全部启用"
func get_enabled_pairs_flat() -> Dictionary:
	var pairs: Dictionary = {}
	for track_index in selected_track_configs.keys():
		var channels = selected_track_configs[track_index]
		if channels is Array:
			for ch in channels:
				pairs["%d:%d" % [int(track_index), int(ch)]] = true
	return pairs

## 启用 (track, channel) 对 → 编码数组（track<<8|channel），供 C# 侧一次性过滤音符
## （C# MidiCore.GetEnabledIndices 用它返回启用子集的 SOA 索引，替代 GDScript 的 O(N) 遍历+排序）
func get_enabled_pair_keys() -> PackedInt32Array:
	var keys := PackedInt32Array()
	for track_index in selected_track_configs.keys():
		var channels = selected_track_configs[track_index]
		if channels is Array:
			for ch in channels:
				keys.append((int(track_index) << 8) | (int(ch) & 0xFF))
	return keys

## 设置指定(track, channel)的启用状态
func set_track_channel_enabled(track_idx: int, channel: int, enabled: bool) -> void:
	if enabled:
		if not selected_track_configs.has(track_idx):
			selected_track_configs[track_idx] = []
		if channel not in selected_track_configs[track_idx]:
			selected_track_configs[track_idx].append(channel)
	else:
		if selected_track_configs.has(track_idx):
			selected_track_configs[track_idx].erase(channel)
			# 如果该轨道已无通道被选中，删除该轨道的条目
			if selected_track_configs[track_idx].is_empty():
				selected_track_configs.erase(track_idx)

## 设置音源
func set_soundfont(soundfont_name: String) -> void:
	use_soundfont = soundfont_name

## 音符数据是否已就绪（SOA 规范形态；兼容旧字段 parsed_notes）
func has_notes() -> bool:
	return (notes_soa != null and notes_soa.size() > 0) or not parsed_notes.is_empty()

## 单一授权点：解析完成后一次性构建 SOA 紧凑数组 + 轨道-通道分组缓存。
## 所有解析入口（MidiPlaybackManager.ensure_parsed / load_midi）统一经此写入，
## 保证 notes_soa 与 runtime_track_channel_notes 强一致、永不脱节；消费方只读共享不再各自推导。
## 这是 SOA 唯一的构建时机——"读取 MIDI 一次建好，其余地方等解析完毕直接取用"。
##
## 数组本身由 C# MidiCore 解析缓存提供（NoteSoa.from_core 直读，不经中间字典）；
## timebase / bpm_timeline 由调用方给出（bpm_timeline 仍留在 GDScript 侧）。
func set_parsed_soa(midi_path: String, timebase: int, bpm_timeline: Array) -> void:
	notes_soa = NoteSoa.from_core(midi_path, timebase, bpm_timeline)
	notes_parsed_at = Time.get_ticks_msec()
	# 轨道-通道分组与 SOA 同步构建（来源数组已按 start_tick 升序，逐元素追加即有序）
	runtime_track_channel_notes = notes_soa.grouped_indices()
	# SOA 路径下不再持有全量对象；消费方按需经 SOA 取
	parsed_notes = []

## 清空已解析的音符数据与轨道信息（释放内存）
## 保留 bpm_timeline/duration_ms/midi_timebase 等轻量字段，下次 load_midi 时
## 仅需重新解析 MIDI 文件填充 notes_soa（SOA 数组本身在 C# 解析缓存里，不计在此）
## 调用时机：TrackView/PlayView 退出后，且无人需要原始 Note 数据时
func clear_parsed_notes() -> void:
	parsed_notes.clear()
	notes_soa = null
	# track_count 也清零：它是"已解析"的判据之一（load_midi 缓存命中分支会看它）
	track_count = 0
	runtime_track_channel_notes.clear()

## ========== (Track, Channel) 静音接口 ==========

## 设置 (track, channel) 对的 mute 状态
func set_track_channel_mute(track_index: int, channel: int, muted: bool) -> void:
	if not track_channel_mute_state.has(track_index):
		track_channel_mute_state[track_index] = {}
	track_channel_mute_state[track_index][channel] = muted
	GLogger.info("Track %d Channel %d: %s" % [track_index, channel, "muted" if muted else "unmuted"], "MidiData")

## 查询 (track, channel) 对是否被静音
func get_track_channel_mute(track_index: int, channel: int) -> bool:
	if track_channel_mute_state.has(track_index):
		if track_channel_mute_state[track_index].has(channel):
			return track_channel_mute_state[track_index][channel]
	return false

## 清除所有 mute 状态
func clear_all_mutes() -> void:
	track_channel_mute_state.clear()

## 设置特定(track, channel)对的音量
func set_track_channel_volume(track_index: int, channel: int, volume: float) -> void:
	if not track_channel_volume_config.has(track_index):
		track_channel_volume_config[track_index] = {}
	track_channel_volume_config[track_index][channel] = clamp(volume, 0.0, 1.0)

## 获取特定(track, channel)对的音量
func get_track_channel_volume(track_index: int, channel: int) -> float:
	if track_channel_volume_config.has(track_index):
		return track_channel_volume_config[track_index].get(channel, 1.0)
	return 1.0

## 导出用户运行时配置为字典
func export_runtime_config() -> Dictionary:
	return {
		"midi_volume": midi_volume,
		"vocal_volume": vocal_volume,
		"vocal_file_path": vocal_file_path,
		"vocal_offset_ms": vocal_offset_ms,
		"vocal_enabled": vocal_enabled,
		"selected_track_indices": selected_track_indices.duplicate(),
		"selected_track_configs": selected_track_configs.duplicate(),
		"track_channel_mute_state": track_channel_mute_state.duplicate(),
		"track_channel_volume_config": track_channel_volume_config.duplicate(),
		"track_channel_instrument_overrides": track_channel_instrument_overrides.duplicate(),
		"solo_pairs": solo_pairs.duplicate(),
		"use_soundfont": use_soundfont,
		"_track_config_initialized": _track_config_initialized,
		"saved_at": Time.get_ticks_msec()
	}

## ========== 用户乐器覆盖接口 ==========

## 设置用户自定义的轨道-通道乐器覆盖
func set_track_channel_instrument_override(track_idx: int, channel: int, bank: int, program: int, nm: String = "") -> void:
	if not track_channel_instrument_overrides.has(track_idx):
		track_channel_instrument_overrides[track_idx] = {}
	track_channel_instrument_overrides[track_idx][channel] = {
		"bank": bank,
		"program": program,
		"name": nm
	}
	GLogger.info("Track %d Channel %d: 覆盖乐器 %s (Bank %d Program %d)" % [track_idx, channel, name, bank, program], "MidiData")

## 获取用户自定义的轨道-通道乐器覆盖
func get_track_channel_instrument_override(track_idx: int, channel: int) -> Dictionary:
	if track_channel_instrument_overrides.has(track_idx):
		if track_channel_instrument_overrides[track_idx].has(channel):
			return track_channel_instrument_overrides[track_idx][channel]
	return {}

## 清除特定轨道-通道的乐器覆盖
func clear_track_channel_instrument_override(track_idx: int, channel: int) -> void:
	if track_channel_instrument_overrides.has(track_idx):
		track_channel_instrument_overrides[track_idx].erase(channel)
		if track_channel_instrument_overrides[track_idx].is_empty():
			track_channel_instrument_overrides.erase(track_idx)
	GLogger.info("Track %d Channel %d: 已清除乐器覆盖" % [track_idx, channel], "MidiData")

## 清除所有乐器覆盖
func clear_all_instrument_overrides() -> void:
	track_channel_instrument_overrides.clear()
	GLogger.info("已清除所有乐器覆盖", "MidiData")

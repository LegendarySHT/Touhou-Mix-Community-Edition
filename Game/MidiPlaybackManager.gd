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

## 因音源仍在后台加载/切换而推迟的续播/播放：音源就绪前人声与轨道显示不启动，
## 待 _on_backend_soundfont_changed 再统一从起点对齐启动，避免错位于从头重播的 MIDI
var deferred_play_pending: bool = false

## 音源就绪后需在下一帧按 C# 实际位置重新对齐人声（覆盖推迟启动与播放中重载两种情形）
var deferred_vocal_resync_pending: bool = false

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
## 是否已向后端派发过一次异步加载（避免 play() 每次都回调 set_soundfont 触发线程 Join 卡顿）
var _soundfont_preload_dispatched: bool = false
## 由设置退出触发的音源重载是否仍在进行（TrackView 借此判断是否需要等重载完成再续播）
var _settings_reload_pending: bool = false

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
## 播放中的蓝牙输出轮询间隔（秒），仅在平台没有事件订阅时作为兜底使用
const BT_POLL_INTERVAL_SEC := 5.0
var _bt_poll_accum: float = 0.0

## 上次同步检查时的MIDI位置（毫秒）
var last_sync_check_pos_ms: float = 0.0

## 人声音量（dB），供 UI 回填滑条
var _vocal_volume_db: float = 0.0

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

## 信号：MIDI播放完成
signal midi_finished

## 信号：因音源未就绪而推迟的续播/播放在音源就绪后真正开始（供视图延迟启动轨道显示）
signal deferred_play_resumed

## 信号：由设置退出触发的音源重载已完成（TrackView 据此在重载后再续播，避免人声被重启）
signal soundfont_reload_completed

## 信号：播放状态/位置发生外部可见变化（供 SystemMediaSession 同步系统媒体控制）
signal playback_state_changed

## 信号：播放列表内容或顺序发生变化
signal playlist_changed

## 信号：播放模式变化（repeat_all / repeat_one / shuffle / sequential）
signal repeat_mode_changed
## 信号：换曲（切到另一首）。data 为新曲，null 表示播放已停止
signal current_song_changed(data)
## 信号：媒体控件/页面下发命令后播放状态发生变化（播放、暂停、停止、seek）
signal transport_changed

## 播放列表播放模式
enum RepeatMode {
	SEQUENTIAL,   ## 顺序：按列表顺序播，末尾回到第一首
	REPEAT_ALL,   ## 列表循环（末尾同样回到第一首；保留与顺序区分仅为兼容已存配置）
	REPEAT_ONE,   ## 单曲循环
	SHUFFLE,      ## 随机（播完一轮回到开头，不重洗）
}

## 播放列表条目数变化 / 当前索引变化时发出
@warning_ignore("unused_signal")
signal playlist_index_changed(index: int)

## ===== 播放列表 =====
## 权威状态（keys 顺序 / 当前索引 / 模式 / 落盘 / 剪枝）在 C# MidiCore；这里只做
## 「读 key → 水合 MidiData → 起播」与「算好顺序推给 MidiCore」。
## 列表本体不在 Godot 侧驻留 MidiData 数组，避免大歌单整表水合占内存。
## 下标经属性透传读取：后台推进改了 C# 索引时，这里读到的也是最新值。

## 当前播放下标（权威在 MidiCore）
var playlist_index: int:
	get:
		return MidiCore.GetIndex() if MidiCore != null else -1

## 播放模式缓存（与 MidiCore 同步；读取频繁，缓存避免反复跨语言调用）
var repeat_mode: int = RepeatMode.SEQUENTIAL

## 两份排列快照（存 chart_key）：随机/顺序模式各自记住自己的列表排列，
## 切换模式 = 在两份排列间交换，当前曲跟随到新位置。
## 随机排列只在「生成时机」重新打乱：本会话首次切到随机、「打乱列表」按钮、新会话进入。
## 用无类型 Array 承载：keys 来自 C#，避免 typed Array 赋值的运行时校验开销/报错
var _seq_order: Array = []
var _shuf_order: Array = []

## 播放模式（随机/顺序开关）持久化到用户配置
const REPEAT_CFG_SECTION := "Playback"
const REPEAT_CFG_KEY := "repeat_mode"

## 当前曲的 chart_key（列表里存的就是它）
func _current_key() -> String:
	if current_midi_data == null:
		return ""
	return current_midi_data.chart_key if not current_midi_data.chart_key.is_empty() else current_midi_data.id

## MidiData → 列表 key（规范键优先）
func _key_of(m: MidiData) -> String:
	if m == null:
		return ""
	return m.chart_key if not m.chart_key.is_empty() else m.id

## MidiData 数组 → key 数组（无类型 Array，交给 MidiCore 转换）
func _keys_of(items: Array) -> Array:
	var out: Array = []
	for m in items:
		if m is MidiData:
			var k := _key_of(m)
			if not k.is_empty():
				out.append(k)
	return out

## 播完/回绕时是否该推进用户播放列表：单曲槽会话永不推进；
## 用户列表多于一首且非单曲循环才前进。
## 模式一律以 C# 那份为准（后台推进也是用它决策）：两份读值来源不同（GDScript 读配置、
## C# 读播放列表 meta），一旦分裂就会"前台按配置切歌、后台只单曲循环"这种行为不一致。
func _should_advance_on_end() -> bool:
	if MidiCore.IsSessionSingle():
		return false
	var mode_c: int = MidiCore.GetRepeatMode()
	if mode_c != repeat_mode:
		GLogger.warning("Repeat mode mismatch: gdscript=%d csharp=%d (以 C# 为准)" % [repeat_mode, mode_c], "MidiPlaybackManager")
		repeat_mode = mode_c
	return MidiCore.GetCount() > 1 and mode_c != RepeatMode.REPEAT_ONE

## 统一的「这次要播什么」入口：设列表 + 设当前曲的文件级循环 + 指定写到哪个槽。
## persist=true  → 写用户播放列表（面板展示 / 编辑 / 落盘都作用于它），本次会话要落盘；
## persist=false → 只写单曲槽（正常通道），用户播放列表原样不动、也不落盘。
## 只设列表不起播：是否立刻播放由调用方决定。
func start_session(items: Array[MidiData], start_index: int = 0, persist: bool = true,
		loop_file: bool = false) -> void:
	set_loop(loop_file)
	var keys := _keys_of(items)
	if persist:
		MidiCore.SetPersistEnabled(true)
		MidiCore.SetSessionSingle(false)
		set_playlist_keys(keys, start_index)
		return
	# 正常通道：不碰用户列表，也不落盘；只记单曲槽(B)
	MidiCore.SetPersistEnabled(false)
	MidiCore.SetSessionSingle(true)
	MidiCore.SetSessionKey(keys[0] if not keys.is_empty() else "")

## 用户播放列表为空且无落盘记录时，把单曲槽那首借用过来当当前列表。
## 只改内存、仍不落盘；用户一旦编辑列表，_mark_user_edited 会把它转为可落盘。
func adopt_single_into_playlist() -> bool:
	if MidiCore.GetCount() > 0:
		return false
	var k: String = MidiCore.GetSessionKey()
	if k.is_empty():
		return false
	MidiCore.SetSessionSingle(false)
	set_playlist_keys([k], 0)
	return true

## 离开播放器页：活动会话交还给单曲槽(B)，把当前曲放进去。
## A 的内容留在 MidiCore（下次进页面还在），只是不再是"当前会话"——这样之后播完/回绕
## 不会再去推进 A，与"进页面才开始播 A"的门闩语义对称。
func end_user_session() -> void:
	if MidiCore.IsSessionSingle() or current_midi_data == null:
		return
	MidiCore.SetSessionSingle(true)
	MidiCore.SetSessionKey(_current_key())
	MidiCore.SetPersistEnabled(false)

## 确保用户播放列表已就绪：C# 侧为空先读回磁盘；仍为空则借用单曲槽那一首。
## 播放器页进入、系统媒体上下首都走这里，保证"要用 A 时 A 一定是可用的"。
func ensure_user_playlist() -> void:
	if MidiCore.GetCount() == 0:
		restore_playlist()
	if MidiCore.GetCount() == 0:
		adopt_single_into_playlist()   # 借来的单曲先不落盘，等用户编辑再转正式
		return
	# A 已是正式内容（读盘恢复 / 用户选自收藏夹）→ 允许落盘
	MidiCore.SetPersistEnabled(true)
	MidiCore.SetSessionSingle(false)

## 播放器页之外经媒体控件上/下一首进入用户列表会话：从头播第一首。
## 随机模式下这是新会话进入 → 记下顺序排列（若还没记），列表已是随机序不再重洗。
func enter_user_playlist_from_head() -> bool:
	if MidiCore.GetCount() == 0:
		return false
	MidiCore.SetPersistEnabled(true)
	MidiCore.SetSessionSingle(false)
	if repeat_mode == RepeatMode.SHUFFLE and _seq_order.is_empty():
		_seq_order = MidiCore.GetKeys()
	play_playlist_index(0)
	return true

## 设置播放列表（会重置索引，不自动播放）。整表替换 = 全新会话：
## 两份排列快照作废；随机模式下快照顺序排列、生成随机排列并从头播。
## 顺序/打乱算法留在 GDScript（Godot 管顺序调整），算好后把 keys 推给 MidiCore 持有。
func set_playlist_keys(keys: Array, start_index: int = 0) -> void:
	_seq_order.clear()
	_shuf_order.clear()
	var k: Array = []
	for s in keys:
		var ks := str(s)
		if not ks.is_empty():
			k.append(ks)
	if repeat_mode == RepeatMode.SHUFFLE and not k.is_empty():
		_seq_order = k.duplicate()
		_shuffle_keys(k)
		_shuf_order = k.duplicate()
		MidiCore.SetKeys(k, 0)
	else:
		MidiCore.SetKeys(k, start_index)
	playlist_changed.emit()

## 列表变更 → 落盘（受 MidiCore 的 persist 门控）
func _on_playlist_changed_persist() -> void:
	MidiCore.Save()

## 从存储恢复播放列表（启动 / 播放器页进入时调用）。只填列表不自动起播。
## 权威存储是 ChartDB meta，由 MidiCore 读回并剪枝；这里只处理随机模式的启动重洗。
func restore_playlist() -> void:
	if not MidiCore.EnsureLoaded():
		return
	MidiCore.Prune()
	if MidiCore.GetCount() == 0:
		return
	# 恢复出的是磁盘上的正式列表，属于「要记住」的会话
	MidiCore.SetPersistEnabled(true)
	MidiCore.SetSessionSingle(false)
	# 随机模式：每次启动重新洗、从头播（顺序模式保留磁盘顺序与进度）
	if repeat_mode == RepeatMode.SHUFFLE:
		_seq_order = MidiCore.GetKeys()
		var k: Array = _seq_order.duplicate()
		_shuffle_keys(k)
		_shuf_order = k.duplicate()
		MidiCore.SetKeys(k, 0)
	playlist_changed.emit()

## 把当前下标对齐到正在播放的曲目（在列表里时）。静默：不发 playlist_index_changed。
func align_index_to_current() -> void:
	if current_midi_data == null:
		return
	var i: int = MidiCore.IndexOf(_current_key())
	if i >= 0:
		MidiCore.SetIndex(i)

## 后台推进后回前台对账：C# 在熄屏/深后台已把当前曲换成下一首（纯音频、无音符显示与
## 轨道配置），这里按 C# 的索引把 SOA/轨道配置/人声/UI 补齐，并定位到后台已播到的位置。
## 与当前曲一致（前台换曲或未换过）时不动。
##
## 判定不依赖 is_playing：后台推进发生后用户可能在熄屏上先按了暂停，等到回前台时
## 播放态已是 paused，若据此提前 return，current_midi_data 会停在旧曲——之后任何
## push_state（含暂停那条）都会拿旧曲元数据覆盖系统卡片，表现为"按暂停就退回切歌前"。
## 改用「本侧已有当前曲（存在会话）」而非「正在播」，并保留原播放态。
func reconcile_current_song() -> void:
	# 本侧没有当前曲 = 没有会话，绝不能凭 C# 的键凭空起播
	if current_midi_data == null:
		return
	# 单曲槽会话（TrackView 试听等）从不推进用户列表，C# 也不会在后台切歌：
	# 此时 MidiCore 的当前键属于用户列表，与正在播的那首无关，绝不能按它"对账"
	if MidiCore.IsSessionSingle():
		return
	var key: String = MidiCore.GetCurrentKey()
	var cur_key := _current_key()
	if key.is_empty() or cur_key == key:
		# 无换曲：后台期间 GDScript 停摆，显示面（歌名/时长量程）可能停在旧态，
		# 回前台按当前曲刷一次。留一条低噪日志——后台明明换了曲却走到这里，
		# 就说明 C# 索引没推进（key 仍是旧曲），问题在后台推进而不在显示。
		GLogger.info("Reconcile: no song change (csharp=%s gd=%s)" % [key, cur_key], "MidiPlaybackManager")
		transport_changed.emit()
		return
	var data: MidiData = DataMGR.get_midi_by_id(key)
	if data == null:
		GLogger.warning("Reconcile failed: no MidiData for key=%s" % key, "MidiPlaybackManager")
		return
	var live_pos := 0.0
	if _get_active_backend() != null:
		live_pos = maxf(0.0, get_raw_position_ms())
	# 走与手动"下一首"完全相同的换曲路径（play_playlist_index → load_midi → play →
	# current_song_changed），保证 current_midi_data / 信号 / 后端三者一致；
	# 结束后再按原播放态恢复，熄屏期间按过暂停的不会被这次对账重新起播。
	var was_playing := is_playing
	GLogger.info("Reconcile after background advance: %s @ %.0fms (was_playing=%s)" % [key, live_pos, was_playing], "MidiPlaybackManager")
	play_playlist_index(MidiCore.IndexOf(key))
	if live_pos > 0.5:
		seek(live_pos)
	if not was_playing:
		pause()

## 按标识播放：给定 chart_key / id / file_hash 任一别名，命中则在列表中定位并播放。
## 返回是否命中。用于「从曲库点歌」「媒体控件换曲」这类只拿到标识的场景。
func play_by_key(chart_key: String) -> bool:
	if chart_key.is_empty():
		return false
	var i: int = MidiCore.IndexOf(chart_key)
	if i < 0:
		# 别名（id / file_hash）先解析成规范键再找
		var resolved := DataMGR.resolve_chart_key(chart_key)
		if not resolved.is_empty():
			i = MidiCore.IndexOf(resolved)
	if i < 0:
		# 列表里没有：水合后加入并播放
		var data: MidiData = DataMGR.get_midi_by_id(chart_key)
		if data == null:
			return false
		MidiCore.AppendKey(_key_of(data))
		playlist_changed.emit()
		i = MidiCore.GetCount() - 1
	play_playlist_index(i)
	return true

## 用户手动改过列表（增/删/移/清空）→ 通知面板把"歌单选择"复位，
## 并解除收藏夹关联：列表内容已不再等同于那个歌单，继续显示会造成歧义。
signal playlist_user_edited

## 用户手动改过列表 → 本次会话转为要落盘：临时列表一旦被编辑就该被记住
## （对应旧实现里"单曲临时态一旦列表变长就恢复正常落盘"的行为）
func _mark_user_edited() -> void:
	MidiCore.SetPersistEnabled(true)
	MidiCore.SetSourceFavId("")
	playlist_user_edited.emit()

## 向列表尾部追加
func append_to_playlist(items: Array[MidiData]) -> void:
	_mark_user_edited()
	for item in items:
		var k := _key_of(item)
		if not k.is_empty():
			MidiCore.AppendKey(k)
	playlist_changed.emit()

## 插到当前曲之后（"下一首播放"）。已在列表中则不动。返回是否插入。
func insert_next_in_playlist(data: MidiData) -> bool:
	var k := _key_of(data)
	if k.is_empty() or MidiCore.Has(k):
		return false
	_mark_user_edited()
	MidiCore.InsertAt(MidiCore.GetIndex() + 1, k)
	playlist_changed.emit()
	return true

## 从列表中移除指定下标。被移除的歌同时从两份排列快照里清掉。
## 移除的是正在播的歌：切到接管其位置的那首继续播（末首被移除则退到新的末首），
## 列表被移空则停止播放
func remove_from_playlist(index: int) -> void:
	if index < 0 or index >= MidiCore.GetCount():
		return
	_mark_user_edited()
	var removed_key: String = MidiCore.GetKeyAt(index)
	var was_current: bool = index == MidiCore.GetIndex()
	_seq_order.erase(removed_key)
	_shuf_order.erase(removed_key)
	MidiCore.RemoveAt(index)
	playlist_changed.emit()
	if was_current:
		if MidiCore.GetCount() == 0:
			stop()
		else:
			play_playlist_index(MidiCore.GetIndex())
	else:
		playlist_index_changed.emit(MidiCore.GetIndex())

## 调整列表中两项的顺序。播放下标在 MidiCore.Move 内一起挪位，保证"正在播放"仍指着同一首。
func move_in_playlist(from_idx: int, to_idx: int) -> void:
	if from_idx < 0 or from_idx >= MidiCore.GetCount():
		return
	if from_idx == clampi(to_idx, 0, MidiCore.GetCount() - 1):
		return
	_mark_user_edited()
	MidiCore.Move(from_idx, to_idx)
	# 随机模式下拖拽 = 编辑随机排列本身，快照跟着刷新（顺序快照在下次进入随机时重拍）
	if repeat_mode == RepeatMode.SHUFFLE:
		_shuf_order = MidiCore.GetKeys()
	playlist_changed.emit()
	playlist_index_changed.emit(MidiCore.GetIndex())

## 清空列表
func clear_playlist() -> void:
	_mark_user_edited()
	_seq_order.clear()
	_shuf_order.clear()
	MidiCore.ClearAll()
	playlist_changed.emit()

## 列表是否为空
func has_playlist() -> bool:
	return MidiCore.GetCount() > 0

## 进入播放器页 = 开始播用户播放列表(A)：显式结束单曲槽会话。
## 否则 A 明明有内容、却仍被当作"单曲槽会话"而永不推进——表现为播完只原地循环不切歌。
func begin_user_session() -> void:
	if MidiCore.GetCount() == 0:
		return
	MidiCore.SetPersistEnabled(true)
	MidiCore.SetSessionSingle(false)

## 列表条目数（面板/媒体侧只读投影用）
func playlist_count() -> int:
	return MidiCore.GetCount()

## 列表全部 keys（面板重建签名用；轻量字符串数组，不水合 MidiData）
func playlist_keys() -> Array:
	return MidiCore.GetKeys()

## 列表是否已含某 key（曲库"加入播放列表"判重）
func playlist_has_key(chart_key: String) -> bool:
	return MidiCore.Has(chart_key)

## 列表是否已含某 MidiData（曲库"加入播放列表"判重）
func playlist_has_midi(m: MidiData) -> bool:
	return MidiCore.Has(_key_of(m))

## 用 keys 直接开用户列表会话（选收藏夹，免去把整表水合成 MidiData 再起播）
func start_session_keys(keys: Array, start_index: int = 0, loop_file: bool = false) -> void:
	set_loop(loop_file)
	MidiCore.SetPersistEnabled(true)
	MidiCore.SetSessionSingle(false)
	set_playlist_keys(keys, start_index)

## 切换播放模式 = 在两份排列快照间交换显示与播放顺序（当前曲跟随到新位置）。
## 随机排列不会重新打乱——只在生成时机（首次切到随机/「打乱列表」按钮/新会话）生成；
## 顺序排列在每次进入随机时按当前列表快照。模式标记持久化到用户配置
func set_repeat_mode(mode: int) -> void:
	if mode == repeat_mode:
		return
	var was := repeat_mode
	repeat_mode = mode
	MidiCore.SetRepeatMode(mode)
	if MidiCore.GetCount() == 0:
		repeat_mode_changed.emit(mode)
		_schedule_repeat_save()
		return
	if mode == RepeatMode.SHUFFLE:
		# 进入随机：按当前列表快照顺序排列（供切回时还原），
		# 已有随机排列就恢复它（只换排列不打乱），没有才现场生成
		_seq_order = MidiCore.GetKeys()
		if _shuf_order.is_empty():
			_become_shuffled()
		else:
			_apply_arrangement(_shuf_order)
	elif was == RepeatMode.SHUFFLE:
		# 切回顺序：还原顺序排列
		_apply_arrangement(_seq_order)
	repeat_mode_changed.emit(mode)
	playlist_changed.emit()
	if ConfigManager.instance != null:
		ConfigManager.instance.set_value(REPEAT_CFG_SECTION, REPEAT_CFG_KEY, mode)
		# 落盘防抖：save_config 是同步整文件写（目录检查+打开+序列化 ~9ms），
		# 连续切换时合并成 1 秒后一次
		_schedule_repeat_save()

var _repeat_save_pending: bool = false

func _schedule_repeat_save() -> void:
	if _repeat_save_pending:
		return
	_repeat_save_pending = true
	await get_tree().create_timer(1.0).timeout
	_repeat_save_pending = false
	if ConfigManager.instance != null:
		ConfigManager.instance.save_config(ConfigManager.instance.USER_CONFIG_PATH)

## 循环切换播放模式（媒体控件的"循环"按钮语义：列表循环 → 单曲 → 关闭）
func cycle_repeat_mode() -> void:
	match repeat_mode:
		RepeatMode.SEQUENTIAL:
			set_repeat_mode(RepeatMode.REPEAT_ALL)
		RepeatMode.REPEAT_ALL:
			set_repeat_mode(RepeatMode.REPEAT_ONE)
		_:
			set_repeat_mode(RepeatMode.SHUFFLE)

## C# 唯一曲终/回绕检测回调（loop=true 时音频回调检测到 sequencer 回绕）。
## 回绕点即"播完"判定点：用户列表还有下一首就走换曲逻辑（与手动上下首同一条路），
## 单曲槽会话（TrackView 试听等）或单曲循环才原地重播当前曲。
## 检测放音频回调里，因此熄屏/深后台也不会漏（执行仍走 GDScript 的常规范换曲路径）。
func _on_loop_wrapped() -> void:
	if not is_playing:
		return
	# 每次回绕都留一条（含判定输入）：若曲终后连这条都没有，说明检测根本没触发，
	# 那问题在"检测/主循环是否在跑"，而不是在推进决策。
	GLogger.info("Loop wrap: count=%d idx=%d repeat=%d single=%s next=%s" % [
		MidiCore.GetCount(), MidiCore.GetIndex(), MidiCore.GetRepeatMode(),
		str(MidiCore.IsSessionSingle()), MidiCore.NextKey()
	], "MidiPlaybackManager")
	if _should_advance_on_end() and play_next(false):
		GLogger.info("Loop point advanced to next song (playlist mode)", "MidiPlaybackManager")
	else:
		# 未推进：区分"确实该原地循环(单曲循环/单曲槽)"与"状态不对导致不切歌"
		GLogger.info("Loop restart (no advance): should_advance=%s" % str(_should_advance_on_end()), "MidiPlaybackManager")
		_restart_vocal_for_current_position()

## 从用户配置恢复播放模式。键不存在时保持当前值不动。
## 刻意不走 set_repeat_mode（那会广播 playlist_changed，启动时先于列表恢复执行会把用户存的单覆盖掉）。
## 随机模式的启动重洗放在 restore_playlist（那时列表才有内容）。
func _load_repeat_mode() -> void:
	if ConfigManager.instance == null:
		return
	var saved := ConfigManager.instance.get_int(REPEAT_CFG_SECTION, REPEAT_CFG_KEY, repeat_mode)
	# 无条件推给 C#：C# 启动时会先从播放列表 meta 读回一份 repeat_mode，那份与用户配置
	# 历史上是分开落盘的，可能不一致。不一致就会出现"前台按配置会切歌、后台（C# 决策）
	# 只单曲循环"这种前后台行为分裂，所以这里必须覆盖它。
	MidiCore.SetRepeatMode(saved)
	if saved == repeat_mode:
		return
	repeat_mode = saved
	repeat_mode_changed.emit(saved)

## 统一处理系统媒体控件与页面按钮下发的播放命令。
##
## 命令执行刻意放在这里而非各页面：这样页面切换、后台、失焦都不影响播放控制，
## 页面只需订阅状态信号刷新界面。返回 true 表示命令已被消费。
func handle_media_command(action: String, pos_ms: float = -1.0) -> bool:
	match action:
		"play":
			# play 键语义为"确保在播放"，已在播则不重复触发
			if is_paused:
				resume()
			else:
				return false
		"toggle":
			if is_playing:
				pause()
			else:
				resume()
		"pause":
			if not is_playing:
				return false
			pause()
		"stop":
			stop()
		"seek":
			if pos_ms < 0.0:
				return false
			seek(pos_ms)
		"next":
			if MidiCore.GetCount() == 0:
				return false
			return play_next(true)
		"prev":
			if MidiCore.GetCount() == 0:
				return false
			return play_previous()
		"repeat":
			cycle_repeat_mode()
		"shuffle":
			set_repeat_mode(RepeatMode.SHUFFLE)
		_:
			return false
	transport_changed.emit()
	return true

## 跳转到列表中的指定曲目并播放。index 越界时自动夹取。
## 所有换曲（手动上下首 / 播完自动前进 / 点歌单 / 选收藏夹）的必经点。
## 起播必须同步完成（人声周期提前由 start_vocal_playback 内部申请），不能用
## SceneTree 定时器"等一会再播"——切歌那刻若被切后台/熄屏，主循环停摆会让定时器
## 烧不到点，表现为"切完歌停在开头、回前台才继续"
func play_playlist_index(index: int) -> void:
	if MidiCore.GetCount() == 0:
		return
	MidiCore.SetIndex(index)
	var i: int = MidiCore.GetIndex()
	playlist_index_changed.emit(i)
	var data: MidiData = DataMGR.get_midi_by_id(MidiCore.GetKeyAt(i))
	if data == null:
		return
	if not load_midi(data):
		return
	# 换曲的必经点在此发信号：手动上下首 / 播完自动前进 / 点歌单 都汇到这里，
	# 页面（歌名/封面/可视化）只订这个信号即可，不必各自监听多条路径
	current_song_changed.emit(data)
	play()
	# 起播后由后端补一次"与拖动进度条等价"的原地 seek（对齐）：
	# 交给音频回调按帧数计时——后台起播时 Godot 主循环停摆，GDScript 侧等不了
	var backend := _get_active_backend()
	if backend != null:
		backend.request_startup_align()

## 下一首。user_initiated=true 时不受单曲循环限制
## （媒体控件的"下一首"按钮应能跳出单曲循环）
func play_next(user_initiated: bool = true) -> bool:
	if MidiCore.GetCount() == 0:
		return false
	# 单曲循环下的自动续播：重播本曲
	if not user_initiated and repeat_mode == RepeatMode.REPEAT_ONE:
		seek(0.0)
		play()
		return true
	var i: int = MidiCore.IndexOf(MidiCore.NextKey())
	if i < 0:
		return false
	play_playlist_index(i)
	return true

## 上一首。直接切到前一首——不做"距开头不足 3 秒才切歌、否则先回本曲开头"的二次语义
## （想回开头拖进度条即可）。列表首项的前一首 = 列表末尾，与 NextKey 的末尾回绕对称
func play_previous() -> bool:
	if MidiCore.GetCount() == 0:
		return false
	var i: int = MidiCore.IndexOf(MidiCore.PrevKey())
	if i < 0:
		return false
	play_playlist_index(i)
	return true

## 当前是否还有下一首（末尾一律回绕，故非空列表恒为 true）
func has_next() -> bool:
	return MidiCore.GetCount() > 0

## 当前是否还有上一首（首项会回绕到列表末尾，故非空列表恒为 true）
func has_previous() -> bool:
	return MidiCore.GetCount() > 0

## 「打乱列表」按钮：重新生成随机排列（_shuf_order 快照同步更新，_seq_order 不动——
## 切回顺序仍是原顺序）并从头播
func shuffle_playlist_from_head() -> bool:
	if MidiCore.GetCount() == 0:
		return false
	_become_shuffled()
	MidiCore.SetIndex(0)
	play_playlist_index(0)
	playlist_changed.emit()
	return true

## 整表 Fisher-Yates 打乱（作用在 key 数组上；顺序算法留在 GDScript）
func _shuffle_keys(arr: Array) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str(get_instance_id()) + str(Time.get_ticks_usec()))
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp

## 生成新的随机排列并推给 MidiCore，当前曲跟随到新位置
func _become_shuffled() -> void:
	var cur: String = MidiCore.GetCurrentKey()
	var k: Array = MidiCore.GetKeys()
	_shuffle_keys(k)
	_shuf_order = k.duplicate()
	var idx := k.find(cur)
	MidiCore.SetKeys(k, idx if idx >= 0 else 0)

## 把列表切换为给定排列快照（key 调和：快照里没有的新增歌接到尾部、
## 已被删除的歌自动落空），当前曲跟随到新位置
func _apply_arrangement(arrangement: Array) -> void:
	var cur: String = MidiCore.GetCurrentKey()
	var have := {}
	for k in arrangement:
		if not k.is_empty():
			have[k] = true
	var arranged: Array = []
	for k in arrangement:
		if not k.is_empty() and have.has(k):
			arranged.append(k)
	var current_keys: Array = MidiCore.GetKeys()
	for k in current_keys:
		if not have.has(k):
			arranged.append(k)
	var idx := arranged.find(cur)
	if idx < 0:
		idx = MidiCore.GetIndex()
	MidiCore.SetKeys(arranged, idx)

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

	# 恢复上次的播放模式（随机/顺序开关）。deferred 跑，等 ConfigManager 就绪
	_load_repeat_mode.call_deferred()

	# 加载音频校准延迟（按当前输出是否蓝牙选择对应预设）
	refresh_audio_delay()
	# 输出设备变化（蓝牙/有线插拔）由 AudioBtDetector 事件驱动：有事件订阅时立刻切换预设，
	# 息屏/后台也不会漏；无事件能力的平台仍靠焦点回归 + 播放中的兜底轮询
	if not AudioBtDetector.output_changed.is_connected(refresh_audio_delay):
		AudioBtDetector.output_changed.connect(refresh_audio_delay)
	
	# 监听设置改变信号（用于动态切换MIDI后端和音源）
	if EvtBus:
		EvtBus.settings_changed.connect(_on_settings_changed)
		# 监听配置变更信号（新增，用于应对直接配置文件修改）
		EvtBus.config_changed.connect(_on_config_changed)
	# 播放列表权威在 C# MidiCore：变更后落盘，跨重启由 restore_playlist 读回。
	playlist_changed.connect(_on_playlist_changed_persist)
	playlist_index_changed.connect(func(_i: int): MidiCore.Save())

## 刷新输出类型与对应延迟预设。
## 触发时点：启动、应用焦点回归、打开延迟校准窗，以及播放中的周期性轮询
## （息屏/后台没有焦点事件，中途连上或断开蓝牙只能靠轮询发现；不切换的话
## 进度条/音符可视化会与蓝牙输出的实际声音错位）。
## 状态未变时直接返回：不重读配置也不刷日志，轮询可高频调用。
func refresh_audio_delay() -> void:
	var is_bt := AudioBtDetector.is_bluetooth_output(true)
	var first_check := not _bt_state_initialized
	if not first_check and is_bt == _delay_using_bt:
		return
	_bt_state_initialized = true
	_delay_using_bt = is_bt
	if not first_check:
		GLogger.info("Audio output changed (bluetooth=%s), switching delay preset" % str(is_bt), "MidiPlaybackManager")
		# WASAPI 流绑定打开设备时的端点，需重建音频桥才跟随新默认设备。
		# Android 的 AAudio 独占模式 + 蓝牙初始化有风险，不重建（开局前已连蓝牙的场景初始即走蓝牙端点）。
		# 只在设备真的变化时重建。FOCUS_IN（媒体浮层夺焦后还焦、系统弹窗等）也会走到
		# 这里，而设备并未变——无条件重建会销毁正在渲染的 miniaudio 设备，把 play()
		# 打断，表现为「点了播放没反应」。重建后恢复播放。
		if OS.get_name() == "Windows" and midi_player != null:
			var was_playing := is_playing
			midi_player.recreate_audio_output()
			if was_playing and current_midi_data != null:
				play()
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

	# 仅当音源或复音数实际变化时才重载合成器：避免"从设置返回"时无条件重载把播放位置清零
	# （从头重播），也避免重载完成回调误重启人声（"多放一下"）。其余设置变更保留当前合成器。
	var soundfont_changed := false
	if setting_name == "*" or setting_name == "soundfont_select":
		var new_sf : String = ConfigManager.instance.get_value("Gameplay", "soundfont_file", "GeneralUser-GS.sf2")
		new_sf = new_sf.replace(".sf2", "").replace("[内置]", "").strip_edges()
		if new_sf != current_soundfont_path.get_file().get_basename():
			soundfont_changed = true

	# 【修复D-4】如果是泛指信号或系统时钟设置改变（轻量，无需重载）
	if setting_name == "*" or setting_name == "use_system_stopwatch":
		GLogger.info("Applying system stopwatch setting", "MidiPlaybackManager")
		var use_system_stopwatch = ConfigManager.instance.get_int("Playback", "use_system_stopwatch", 0) == 1
		var backend = _get_active_backend()
		if backend != null:
			backend.set_use_system_stopwatch(use_system_stopwatch)
			GLogger.info("System stopwatch mode: %s" % ("ON" if use_system_stopwatch else "OFF"), "MidiPlaybackManager")

	# 最大复音数改变（需要重新加载SoundFont才能生效）
	var polyphony_changed := false
	if setting_name == "*" or setting_name == "max_polyphony":
		var new_polyphony := ConfigManager.instance.get_int("Playback", "max_polyphony", 96)
		if new_polyphony != int(midi_player_config.get("max_polyphony", 96)):
			polyphony_changed = true

	# 音源或复音数真正变化时才重载：保留当前合成器（播放位置不被重置），
	# 返回 TrackView 后能原位置续播；且重载完成回调不会误重启人声。
	# 用 _settings_reload_pending 去重：config_changed 已触发重载时会先置位，此处跳过，避免二次重载
	# （两次 finalize 会让第二次把位置清零的合成器换入，导致"先回到原位置又从头重播"）。
	if (soundfont_changed or polyphony_changed) and not _settings_reload_pending:
		GLogger.info("Soundfont/polyphony changed, reloading", "MidiPlaybackManager")
		# 标记设置触发的重载进行中：TrackView 返回时会据此等重载完成再 resume，
		# 否则重载完成回调在已启动的人声之上再次重启人声（"多放一下"）。
		if midi_player != null:
			_settings_reload_pending = true
		if polyphony_changed:
			var backend = _get_active_backend()
			if backend != null:
				var max_polyphony = ConfigManager.instance.get_int("Playback", "max_polyphony", 96)
				backend.set_max_polyphony(max_polyphony)
				midi_player_config["max_polyphony"] = max_polyphony
				GLogger.info("Updated max polyphony to: %d" % max_polyphony, "MidiPlaybackManager")
		_load_soundfont_from_config()
		GLogger.info("Soundfont reloaded successfully", "MidiPlaybackManager")


func _process(delta: float) -> void:
	var backend = _get_active_backend()
	if not is_playing or backend == null:
		return

	# 蓝牙输出轮询兜底：Android 正常由 Java AudioDeviceCallback 事件驱动（见 AudioBtDetector），
	# 仅在事件通路不可用（插件未注册/旧版本）时轮询。Windows 的检测要起 MTA 线程，不轮询，
	# 靠焦点回归刷新。没有这条兜底的话息屏中途连蓝牙不会被发现，延迟不切换、进度/可视化错位
	if OS.get_name() == "Android" and not AudioBtDetector.has_output_listener():
		_bt_poll_accum += delta
		if _bt_poll_accum >= BT_POLL_INTERVAL_SEC:
			_bt_poll_accum = 0.0
			refresh_audio_delay()

	# MeltySynth 后端：使用毫秒位置（叠加音频校准延迟，见 _audio_delay_ms）
	position_ms = backend.get_position_ms() - _audio_delay_ms
	# 将毫秒转为tick（使用BPM时间线）
	if midi_timebase > 0:
		position = calculate_tick_from_position_with_bpm_timeline(position_ms, midi_timebase)

	# 曲终/回绕检测不在这里做：统一由 C# 音频回调检测（loop=true 时 sequencer 自己回绕、
	# 永不发 finished），经 loop_wrapped 信号回调 _on_loop_wrapped。此处只做位置换算。

	# 调用自动同步逻辑
	_sync_vocal_with_midi()

	# 音源重载完成后的下一帧：按 C# 当前实际位置重新对齐人声，抵消重载引入的固定错位。
	# 延后一帧确保 C# 已在 FinalizeSoundfontLoad/切换后启动并定位到正确位置。
	if deferred_vocal_resync_pending and is_playing and current_midi_data != null:
		deferred_vocal_resync_pending = false
		var live_pos: float = get_raw_position_ms()
		if live_pos < 0.0:
			live_pos = 0.0
		reset_sync_state()
		start_vocal_playback(live_pos)

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
	# 立即持久化到 DB，避免下次启动重复解析简介。
	# 经 MidiCore.EnsureDefaultsOnce：守卫内置在 C# 侧（读 DB 的 _track_config_initialized），
	# 不依赖内存副本——换一份水合来源守卫就会失效，那正是原先 is_track_config_initialized() 的隐患。
	# 传完整 export_runtime_config（与原先 _save_runtime_config 写入的内容一致），
	# 不做字段裁剪：首次初始化时其余字段也需一并落盘（默认值即彼时的内存状态）。
	var chart_id_cfg = midi_data.file_hash if not midi_data.file_hash.is_empty() else midi_data.id
	if MidiCore != null and not MidiCore.EnsureDefaultsOnce(chart_id_cfg, midi_data.export_runtime_config()):
		GLogger.info("[DescParse] defaults already initialized in DB, skipped re-persist: %s" % midi_data.id, "MidiPlaybackManager")

## 从 C# 解析缓存取去重 (track, channel) 对，解码为 [[track, channel], ...]。
## 过去枚举轨道对要遍历整份 SOA（O(N) + 逐音符字符串格式化），现在由 C# 一次性给出小列表。
func soa_pairs_of(midi_data: MidiData) -> Array:
	var out: Array = []
	if midi_data == null:
		return out
	var path := midi_data.midi_file_path
	if path.is_empty() or not MidiCore.HasParsed(path):
		return out
	# C# 返回值在 GDScript 侧是 Variant：先落到显式类型再迭代，避免类型推断/遍历报错
	var pairs: PackedInt32Array = MidiCore.GetPairs(path)
	for k in pairs:
		out.append([k >> 8, k & 0xFF])
	return out

## 按启用策略批量设置 (track,channel) 对（SOA 优先，避免批量建对象）
func _apply_recommended_pairs(midi_data: MidiData, recommended: Array, use_recommendation: bool, notes: Array) -> void:
	# 注意 MidiData.set_track_channel_enabled 是幂等的（内部去重），重复调用安全
	for pair in soa_pairs_of(midi_data):
		var should_enable := true
		if use_recommendation:
			should_enable = pair[0] in recommended
		midi_data.set_track_channel_enabled(pair[0], pair[1], should_enable)

## 加载MIDI文件
## 返回: success (bool)
func load_midi(midi_data: MidiData) -> bool:
	if midi_data == null:
		push_error("MidiData is null")
		return false
	# 人声路径修复：MidiData.vocal_file_path 可能是 DB 配置里存的旧绝对路径
	# （谱面库搬家后失效）。TrackView 有同款修复，但播放列表换曲不经过 TrackView，
	# 所以统一在加载前修一次（resolve_vocal_path 内部会校验存在性并回填）。
	VocalTrackController.resolve_vocal_path(midi_data)

	# 加载新曲前先停止当前播放（幂等）：
	# TrackView 循环播放中直接进入 PlayView 时，后端 sequencer/playing 状态可能残留
	# （实测：旧曲位置停留在 74s，pre-roll seek(-2000) 后 crossing-zero 状态机错乱，
	# 表现为判定时钟异常 + 位置冻结 + 游戏提前结束）。先 stop() 保证干净状态。
	# 这是换曲的中转步骤，不广播播放态（否则系统媒体通知会闪暂停态、封面硬切）
	_suppress_state_signal = true
	stop()
	_suppress_state_signal = false

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
	# 缓存命中的判据是"SOA 已就绪 + 路径一致 + 有过解析标量"（track_count>0）。
	# 过去还看 _runtime_track_infos 非空，但那份数组已随TrackInfo 一并删除。
	if midi_data.has_notes() and midi_data.midi_file_path == midi_file_path and midi_data.track_count > 0:
		# 缓存命中：跳过昂贵的 MIDI 解析
		current_notes = midi_data.parsed_notes
		bpm_timeline = midi_data.bpm_timeline.duplicate()
		midi_timebase = midi_data.midi_timebase
		duration_ms = midi_data.duration_ms
		GLogger.info("MIDI parse cache hit, skipping re-parse", "MidiPlaybackManager")
	else:
		# 解析：主体在 C# MidiCore 缓存（按路径幂等），此处只取标量并组装显示侧字段。
		# 不再经 Utilities/MidiParser.gd 的中间字典（那层只是把 C# 结果重拼一遍）。
		var pp := _resolve_parse_paths(midi_file_path)
		if not MidiCore.HasParsed(pp.key):
			MidiCore.ParseChartFile(pp.read, pp.key)
		if not MidiCore.HasParsed(pp.key):
			push_error("Failed to parse MIDI: %s" % midi_file_path)
			return false

		# 音符数据以 SOA 紧凑数组存储（不 materialize 全量 NoteEvent，20w+ 音符内存优化）
		# 单一授权点：SOA + 轨道-通道分组一并写入，保证与 notes_soa 强一致
		bpm_timeline = MidiCore.GetBpmTimeline(pp.key)
		midi_timebase = MidiCore.GetTimebase(pp.key)
		current_midi_data.set_parsed_soa(pp.key, midi_timebase, bpm_timeline)
		current_notes = []  # SOA 路径下不再持有全量对象；消费方按需经 SOA 取

		current_midi_data.track_count = MidiCore.GetTrackCount(pp.key)
		current_midi_data.duration_ms = MidiCore.GetDurationMs(pp.key)
		current_midi_data.bpm_timeline = bpm_timeline.duplicate()
		current_midi_data.midi_timebase = midi_timebase

		current_midi_data.max_end_tick = MidiCore.GetMaxEndTick(pp.key)
		current_midi_data.track_channel_instruments = MidiCore.GetTrackInstruments(pp.key)
		duration_ms = current_midi_data.duration_ms


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
		var default_count := 0
		for pair in soa_pairs_of(current_midi_data):
			if backend != null:
				backend.set_track_channel_volume(pair[0], pair[1], default_volume)
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

	# 应用随 MIDI 保存的运行时配置（主音量/持久化静音/solo/启用通道门控/人声偏移）：
	# 播放器页直接起播时播放效果与 TrackView 一致（这些此前只在 PlayView/TrackView 各自应用）
	apply_midi_runtime_config(midi_data)
	
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
	playback_state_changed.emit()

## 预解析 MIDI，使后续 load_midi() 命中缓存跳过同步解析。
##
## 同步执行：解析主体是 C# MidiCore.ParseChartFile（纯 .NET、无场景树访问），
## 主循环没有必须等待的理由。此前用 WorkerThreadPool + `while ... await process_frame`
## 轮询是因为 GDScript 无法阻塞等待线程——那层等待只是GDScript 的妥协，
## 解析本身并不需要异步。调用方改为普通调用。
func ensure_parsed(midi_data: MidiData) -> bool:
	# 缓存命中检查（与 load_midi 内部条件一致）
	# 命中缓存时 runtime_track_channel_notes 已由本函数构建，TrackView._build_buckets 可直接复用
	if midi_data.has_notes() and midi_data.track_count > 0:
		# 确保 (track,channel) 索引分组已就绪：某些路径（如 load_midi 直接设置 notes_soa、或复用旧实例）
		# 可能只重建了 SOA 而未建分组，缺则从 SOA 重建，保证 TrackView._build_buckets 总是能取到数据
		if midi_data.runtime_track_channel_notes.is_empty() \
				and midi_data.notes_soa != null and midi_data.notes_soa.size() > 0:
			midi_data.runtime_track_channel_notes = midi_data.notes_soa.grouped_indices()
		return true  # 已缓存，无需预解析

	var midi_file_path := _locate_midi_file(midi_data)
	if midi_file_path.is_empty():
		push_error("[MidiPlaybackManager] Cannot locate MIDI file for: %s" % midi_data.id)
		return false

	# 预先写入路径，让 load_midi 内部的缓存检查 (midi_data.midi_file_path == midi_file_path) 命中
	midi_data.midi_file_path = midi_file_path

	# 解析主体在 C#（按路径幂等，命中即跳过读盘）。
	# 读路径与缓存键分开：读路径可为 PCK 内 res://Resources 回退，键始终是原路径。
	var pp := _resolve_parse_paths(midi_file_path)
	if not MidiCore.HasParsed(pp.key):
		MidiCore.ParseChartFile(pp.read, pp.key)
	if not MidiCore.HasParsed(pp.key):
		push_error("[MidiPlaybackManager] Failed to parse MIDI file: %s" % midi_file_path)
		return false

	# 音符数据以 SOA 紧凑数组存储（不 materialize 全量 NoteEvent，20w+ 音符内存优化）
	# 单一授权点：SOA + 轨道-通道分组一并写入，保证与 notes_soa 强一致
	var tl: Array = MidiCore.GetBpmTimeline(pp.key)
	midi_data.set_parsed_soa(pp.key, MidiCore.GetTimebase(pp.key), tl)

	# 写入 midi_data 字段，load_midi 后续会命中缓存跳过同步解析
	# 与 load_midi 一致：duplicate() 防止后续修改影响原解析结果
	midi_data.bpm_timeline = tl.duplicate()
	midi_data.midi_timebase = MidiCore.GetTimebase(pp.key)

	midi_data.track_count = MidiCore.GetTrackCount(pp.key)
	midi_data.duration_ms = MidiCore.GetDurationMs(pp.key)
	midi_data.max_end_tick = MidiCore.GetMaxEndTick(pp.key)

	# 复用 C# 解析阶段一次性提取的乐器信息（避免 load_midi 重新遍历事件，省 ~5-15ms）
	cached_track_channel_instruments = MidiCore.GetTrackInstruments(pp.key)
	midi_data.track_channel_instruments = cached_track_channel_instruments.duplicate()

	_trim_parsed_notes_cache()

	# SOA 来源数组已按 start_tick 升序排序，无需重复排序

	var json_note_count: int = midi_data.notes_soa.size()
	GLogger.info("MIDI preparse completed: %d notes, duration=%.0fms, %d (track,channel) groups" % [
		json_note_count,
		midi_data.duration_ms,
		midi_data.runtime_track_channel_notes.size()
	], "MidiPlaybackManager")
	return true

## 解析结果（SOA，约 28 字节/音符，大谱面数 MB）限量驻留。
## 浏览列表时每个滚入视野的项都会预解析，而清理只挂在"选中切换"上，
## 只滚动不点选的歌曲会永久滞留（实测 native heap 数百 MB）。
## 按最近构建时间淘汰：重解析很快，只留最近 2 首（当前 + 上一首）+ 正在播放的那首。
const PARSED_NOTES_CACHE_MAX := 2

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
		GLogger.info("Audio output bridge recreated for interruption recovery", "MidiPlaybackManager")

## 兼容性空流程：原生解码已在 load_midi 预载，无需等待 worker
func await_vocal_preload() -> void:
	pass

## 播放MIDI
func play() -> void:
	var backend  = _get_active_backend()
	if backend == null:
		push_error("No MIDI backend initialized")
		return
	
	if current_midi_data == null:
		push_error("No MIDI loaded")
		return

	deferred_play_pending = false

	# 调试：打印启动时的当前音量（TrackView 起始入口）
	_log_volume_state("play()")

	# 设置音源：未就绪时只派发一次后台异步加载，不阻塞等待；
	# 后端 play() 会在加载完成后由 C# 侧自动续播（见 MeltySynthPlayer._pendingPlayAfterLoad）
	if not _soundfont_preloaded_to_backend and not _soundfont_preload_dispatched and not current_soundfont_path.is_empty():
		if backend != null:
			backend.set_soundfont(current_soundfont_path)
		_soundfont_preload_dispatched = true

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

	# 主动调用 C# play()：真正启动返回 true；音源仍在加载/切换而推迟时返回 false。
	var actually_started: bool = backend.play()
	is_playing = true
	is_paused = false

	# 若存在预设起始位置（含负数 pre-roll），在启动后立即恢复到该位置
	if abs(start_position_ms) > 0.001:
		seek(start_position_ms)
	else:
		# 默认从 0 开始
		position = 0.0
		position_ms = 0.0

	# C# 推迟播放时人声也推迟，待 _on_backend_soundfont_changed 从起点对齐启动，避免人声先按旧位置播放导致错位。
	if not actually_started:
		deferred_play_pending = current_midi_data != null and not current_midi_data.vocal_file_path.is_empty() and current_midi_data.vocal_enabled
		playback_state_changed.emit()
		return

	# 启动人声播放（如果有人声文件）
	if not current_midi_data.vocal_file_path.is_empty():
		start_vocal_playback()
		GLogger.info("Started vocal playback: %s (offset: %d ms)" % [current_midi_data.vocal_file_path, vocal_offset_ms], "MidiPlaybackManager")
	else:
		GLogger.info("No vocal file configured (path: '%s')" % current_midi_data.vocal_file_path, "MidiPlaybackManager")

	playback_state_changed.emit()

## 内部换曲清理阶段（为 true 时 stop() 不广播播放态）。
## 换曲开头要 stop() 清场，那只是中转步骤；广播 playing=false 会让系统媒体
## 通知/卡片闪一下暂停态，也会打断系统对封面的切换过渡（看起来就是封面硬切）
var _suppress_state_signal: bool = false

## 停止播放
func stop() -> void:
	deferred_play_pending = false
	deferred_vocal_resync_pending = false
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

	if not _suppress_state_signal:
		playback_state_changed.emit()

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

	playback_state_changed.emit()

## 继续播放
func resume() -> void:
	var backend = _get_active_backend()
	if backend == null:
		return

	deferred_play_pending = false

	# 主动调用 C# resume()：真正续播返回 true；音源仍在加载/切换而推迟时返回 false。
	var actually_resumed: bool = backend.resume()
	is_playing = true
	is_paused = false

	# C# 推迟时人声也推迟，待 _on_backend_soundfont_changed 从起点对齐启动。
	if not actually_resumed:
		deferred_play_pending = current_midi_data != null and not current_midi_data.vocal_file_path.is_empty() and current_midi_data.vocal_enabled
		playback_state_changed.emit()
		return

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

	playback_state_changed.emit()

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

## 听歌降耗档已移除：它靠页面进出切换音频缓冲，收益可忽略却带来切页重构音频桥、
## 人声位置读数量化导致持续 seek 等问题。音频 period 固定为低延迟档（256×2）。

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
	last_sync_check_pos_ms = pos
	_seek_vocal_to_midi_position(pos)

	playback_state_changed.emit()

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
	
	# 二分定位所在 BPM 段（time_ms 升序）
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

	# 目标时间落在该段内；超出末段时取末段，与线性扫的收尾行为一致
	var entry = bpm_timeline[seg]
	var time_in_segment = target_time_ms - entry["time_ms"]
	var ms_per_tick = (60000.0 / entry["bpm"]) / timebase
	return entry["tick"] + time_in_segment / ms_per_tick

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
	# 后台线程异步解析（约 3-5s），不阻塞主线程；加载完成后由 soundfont_changed 信号置位 _soundfont_preloaded_to_backend
	midi_player.set_soundfont(current_soundfont_path)
	_soundfont_preload_dispatched = true
	GLogger.info("SoundFont pre-load dispatched (async)", "MidiPlaybackManager")

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
		_soundfont_preload_dispatched = true
	else:
		# 非播放态切换音源：提前在后台异步预加载（约 3-5s），避免首次播放时再卡一次；
		# 加载完成由 soundfont_changed 信号置位 _soundfont_preloaded_to_backend。
		if midi_player != null:
			midi_player.set_soundfont(soundfont_path)
		_soundfont_preloaded_to_backend = false
		_soundfont_preload_dispatched = true

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
	# C# 唯一曲终/回绕检测：loop=true 时 sequencer 自己回绕、永不发 finished，
	# 列表前进只能挂在这个信号上
	if wrapper.has_signal("loop_wrapped"):
		wrapper.loop_wrapped.connect(_on_loop_wrapped)
		GLogger.info("Connected loop_wrapped signal", "MidiPlaybackManager")

	# 后台加载完成（含异步预加载）时标记已就绪，play() 不再重复触发加载
	if wrapper.has_signal("soundfont_changed"):
		wrapper.soundfont_changed.connect(_on_backend_soundfont_changed)
		GLogger.info("Connected soundfont_changed signal", "MidiPlaybackManager")

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
	else:
		push_error("[MidiPlaybackManager] AudioManager not available")
	_vocal_volume_db = volume_db
	GLogger.info("Set vocal volume to %.2f dB" % volume_db, "MidiPlaybackManager")

## 读取人声音量（dB），供 UI 回填滑条位置
func get_vocal_volume_db() -> float:
	return _vocal_volume_db


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
##
## 必须遍历 C# 的 (track,channel) 列表（soa_pairs_of），不能用
## cached_track_channel_instruments：那个缓存只在解析分支填充，缓存命中分支不填，
## 而 unload_midi 会 clear()它——于是"解析过→卸载→再加载"后这里遍历空字典、
## 静音完全不生效。
func _apply_mute_state_to_backend(backend: MidiPlaybackInterface) -> void:
	if backend == null:
		return

	# 先清掉上一首残留的静音，再按当前曲目的持久化状态下发
	var pairs := soa_pairs_of(current_midi_data)
	for pair in pairs:
		var muted: bool = current_midi_data.get_track_channel_mute(pair[0], pair[1])
		backend.set_track_channel_mute(pair[0], pair[1], muted)

	GLogger.info("Applied mute state for %d track-channel pairs" % pairs.size(), "MidiPlaybackManager")

## 应用随 MIDI 保存的运行时配置。
## 轨道音量/乐器覆盖已在 load_midi 应用，此处补齐其余项，并新增启用通道门控
##
## 唯一权威实现：TrackView / PlayView / MusicPlayerView 三处播放入口都经此下发，
## 保证同一谱面听感一致（PlayView 曾有一份副本，缺少启用通道门控，会播放
## TrackView 里已禁用的通道；已删除，统一走这里）。
func apply_midi_runtime_config(midi_data: MidiData) -> void:
	if midi_data == null:
		return

	# MIDI 主音量（映射系数见 MIDI_VOLUME_GAIN: 0.5=+6dB, 1.0=+12dB；
	# -1=未配置，回退全局 default_midi_volume，与 TrackView 一致）
	apply_ui_midi_volume(get_effective_midi_volume(midi_data.midi_volume))

	# 持久化的轨道-通道静音状态
	if not midi_data.track_channel_mute_state.is_empty():
		for track_idx in midi_data.track_channel_mute_state.keys():
			var channels = midi_data.track_channel_mute_state[track_idx]
			if channels is Dictionary:
				for channel in channels.keys():
					set_track_channel_mute(track_idx, channel, channels[channel])

	# solo（Additive Solo，与 TrackView._apply_solo_state 一致）：
	# 独奏轨保持上面的持久化静音状态，非独奏轨运行时静音（不写 MidiData，避免污染持久化配置）
	if not midi_data.solo_pairs.is_empty():
		for pair in soa_pairs_of(midi_data):
			if not midi_data.solo_pairs.has("%d:%d" % [pair[0], pair[1]]):
				set_track_channel_mute_runtime(pair[0], pair[1], true)

	# 启用/禁用通道（TrackView 的音轨启用开关）：未启用的通道运行时静音。
	# 此前启用状态只影响音符显示，从不进合成器——这里补上音频侧
	for pair in soa_pairs_of(midi_data):
		if not midi_data.is_track_channel_selected(pair[0], pair[1]):
			set_track_channel_mute_runtime(pair[0], pair[1], true)

	# 人声偏移量
	set_vocal_offset_ms(midi_data.vocal_offset_ms)
	GLogger.info("MIDI runtime config applied: mute_states=%d, solo_pairs=%d" %
		[midi_data.track_channel_mute_state.size(), midi_data.solo_pairs.size()], "MidiPlaybackManager")

## 解析用路径：key 始终是原路径（缓存键，后续查询都用它）；
## read 在谱面目录不可读时回退到 PCK 内 res://Resources 副本。
func _resolve_parse_paths(path: String) -> Dictionary:
	if FileAccess.file_exists(path):
		return {"read": path, "key": path}
	var files_dir := PathHelper.get_files_dir()
	if not files_dir.is_empty() and path.begins_with(files_dir):
		var fb := path.replace(files_dir, "res://Resources/")
		if FileAccess.file_exists(fb):
			return {"read": fb, "key": path}
	return {"read": path, "key": path}

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
	playback_state_changed.emit()
	midi_finished.emit()

## 回调：人声自然结束
func _on_vocal_finished() -> void:
	_vocal_initialized = false
	GLogger.info("Vocal playback finished naturally", "MidiPlaybackManager")

## 回调：C# 后端 SoundFont 加载完成（含启动期异步预加载与设置切换）
## 标记已就绪，使 play() 不再重复触发加载。
func _on_backend_soundfont_changed(_path: String) -> void:
	_soundfont_preloaded_to_backend = true
	_soundfont_preload_dispatched = true

	var was_deferred: bool = deferred_play_pending
	var vocal_relevant: bool = current_midi_data != null and not current_midi_data.vocal_file_path.is_empty() and current_midi_data.vocal_enabled

	# 音源就绪后若正在播放且人声本应处于活动状态（已推迟启动，或重载前已在响），
	# 在下一帧按 C# 实际位置重新对齐人声：覆盖"从头续播"与"播放中切换音源"两种情形，
	# 避免重载后人声固定错位（拖动进度条也是同样的对齐效果）。
	if is_playing and vocal_relevant and (was_deferred or _vocal_initialized):
		deferred_vocal_resync_pending = true

	if was_deferred:
		deferred_play_pending = false
		deferred_play_resumed.emit()

	# 设置触发的音源重载已完成：通知等待中的视图（TrackView）可以安全续播了。
	if _settings_reload_pending:
		_settings_reload_pending = false
		soundfont_reload_completed.emit()

## 获取当前 MIDI 的轨道数量（C# 解析缓存直接给）。
## 过去这里返回 Array[TrackInfo] 供 UI 取轨道名，但那份name 从未被填充、
## 恒为 "Track %d"，而消费方 TrackView 自己也用同样的字符串兜底——
## 故只保留数量，轨道名统一由调用方按 "Track %d" 生成。
func get_track_count() -> int:
	if current_midi_data == null or current_midi_data.midi_file_path.is_empty():
		return 0
	return MidiCore.GetTrackCount(current_midi_data.midi_file_path)

## ========== Note分类接口 ==========
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

## 设置触发的音源重载是否仍在进行（TrackView 返回时据此决定等待或立即续播）
func is_soundfont_reload_pending() -> bool:
	return _settings_reload_pending

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
## start_ms_override >= 0 时忽略当前 MIDI 位置，强制从指定毫秒启动（用于音源就绪后从头对齐续播）
func start_vocal_playback(start_ms_override: float = -1.0) -> void:
	if current_midi_data == null or current_midi_data.vocal_file_path.is_empty():
		return
	if not current_midi_data.vocal_enabled:
		return

	var audio_manager = AudioManager.instance
	if audio_manager == null:
		return

	var vocal_file_path = current_midi_data.vocal_file_path
	# 用音频渲染时钟（get_raw_position_ms）定位人声，与 MIDI 合成器同一时钟，避免叠加视觉校准延迟造成错位
	var raw_pos := get_raw_position_ms() if start_ms_override < 0.0 else start_ms_override
	var expected_vocal_position = raw_pos - vocal_offset_ms
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

	# 音源未就绪、续播处于推迟等待期间：人声保持静音，不读取冻结的 MIDI 位置去“从旧位置续播”，
	# 否则人声会比 MIDI 先响（_on_backend_soundfont_changed 会在音源就绪后从起点统一启动）。
	if deferred_play_pending:
		if audio_manager.is_vocal_playing():
			audio_manager.set_vocal_playing(false)
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

	# 只有"误差持续超阈"才纠正，且纠正后冷却一段时间。
	# 输出缓冲大时（听歌降耗档 4096×3）人声位置读数本身有 ~80ms 量化，单次四五十毫秒的
	# 误差会一直触发 seek —— 每秒纠正数次，听感就是卡顿并刷满日志。
	if diff > sync_threshold_ms:
		_vocal_sync_offense += 1
	else:
		_vocal_sync_offense = 0
	var now_ms := Time.get_ticks_msec()
	if _vocal_sync_offense >= VOCAL_SYNC_OFFENSE_NEEDED \
			and now_ms - _last_vocal_sync_ms >= VOCAL_SYNC_COOLDOWN_MS:
		audio_manager.seek_vocal(expected_vocal_position)
		_last_vocal_sync_ms = now_ms
		_vocal_sync_offense = 0
		GLogger.info("Vocal sync adjusted: diff=%.0f ms, target=%.0f ms" % [diff, expected_vocal_position], "MidiPlaybackManager")

	# 更新上次同步检查的位置
	last_sync_check_pos_ms = midi_position_ms

## 人声同步节流参数：连续 N 次超阈 + 冷却期内只纠正一次
const VOCAL_SYNC_OFFENSE_NEEDED := 2
const VOCAL_SYNC_COOLDOWN_MS := 1500
var _vocal_sync_offense: int = 0
var _last_vocal_sync_ms: int = 0

## 设置音频同步阈值（毫秒）
func set_sync_threshold(threshold_ms: float) -> void:
	sync_threshold_ms = clamp(threshold_ms, 1.0, 100000.0)

## 重置同步检查位置（在开始新播放时调用）
# 设为负数确保播放开始后第一次 _sync_vocal_with_midi 就会立即检查同步
# 而不是等 100ms 间隔过去，避免 MIDI/人声启动延迟差异在前 100ms 内不被纠正
func reset_sync_state() -> void:
	last_sync_check_pos_ms = -1000.0
	# 同步节流状态随新播放清零，避免上一首遗留的计数立刻触发一次 seek
	_vocal_sync_offense = 0
	_last_vocal_sync_ms = 0

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
				# 置位去重标记：与 settings_changed('*') 共用，确保只触发一次重载
				if midi_player != null:
					_settings_reload_pending = true
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
				# 置位去重标记：与 settings_changed('*') 共用，确保只触发一次重载
				if midi_player != null:
					_settings_reload_pending = true
				# 设置新的复音数
				var max_polyphony = int(value) if value is int else ConfigManager.instance.get_int("Playback", "max_polyphony", 96)
				backend.set_max_polyphony(max_polyphony)
				midi_player_config["max_polyphony"] = max_polyphony
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

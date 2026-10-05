## 播放列表持久化存储
##
## 只负责「存 / 取」两件事，不持有列表语义——列表本体是 MidiPlaybackManager.playlist，
## 这里是它跨重启的落点。manager 监听 playlist_changed 写盘，故本页不再另存一份副本：
## 早期版本同时维护 keys 与 playlist 两份并手动同步，那层同步正是多处 bug 的来源。
##
## 存储位置：ChartDb 的 meta 集合（_id="playlist"），随谱面库一起加载，无需处理时序。
##
## 水合（keys → MidiData）是重活（每键一次 DB 读 + 文件探测），上千键时同步做会卡住
## 调用线程数秒。因此全表水合放在 _process 分帧进行（每帧限时），起播所需的头部
## 若干项由 load_midis 同步取用，全表完成后经 hydration_finished 送达调用方回填。
extends Node
class_name PlaylistManager

static var instance: PlaylistManager

## 上次保存的播放位置（下次 restore 时用）
var saved_index: int = 0
## 上次保存的播放模式
var saved_repeat_mode: int = 0
## 当前列表来源的收藏夹 id；用户手动增删后置空（面板显示"未选择歌单"）
var source_fav_id: String = ""

## 本次会话是否允许落盘。由统一入口 MidiPlaybackManager.start_session(persist) 设置：
## 「正常播放场景」（如媒体控件把当前曲设为列表）传 false——那只表达"现在要播什么"，
## 不该覆盖用户存的列表；进播放器页恢复、选收藏夹等要记住的场景传 true。
var persist_enabled: bool = true

## 全表水合完成（midis 与 _saved_keys 顺序一致，已剔除失效项）
signal hydration_finished(midis: Array[MidiData])

var _loaded: bool = false
var _pruned: bool = false
var _data_ready: bool = false

## 水合结果与进度。_hydrated_src 记录每项对应的 _saved_keys 下标，
## 供 saved_index 在剔除过项的列表里重新定位
var _hydrated: Array[MidiData] = []
var _hydrated_src: Array[int] = []
## 本次水合基于的 keys 快照；落盘 keys 变了就整体重水合
var _hydrated_keys: Array[String] = []
var _hydrate_from: int = 0
var _hydrating: bool = false

func _ready() -> void:
	instance = self
	set_process(false)
	EvtBus.data_loaded_complete.connect(_on_data_loaded_complete)

## 懒加载：启动不读库，首次实际用到（存/取播放列表）或数据就绪时再补做
func ensure_loaded() -> void:
	if _loaded and _pruned:
		return
	if ChartDB == null or not ChartDB.IsOpen():
		return
	if not _loaded:
		_load()
	if _loaded and not _pruned and _data_ready:
		_prune()
		_pruned = true

func _on_data_loaded_complete() -> void:
	_data_ready = true
	ensure_loaded()
	_start_hydration()

func is_hydrating() -> bool:
	return _hydrating

## 开始 / 重启全表水合。keys 与上次一致时不动，保留已完成的结果
func _start_hydration() -> void:
	if _hydrated_keys == _saved_keys and (_hydrating or _hydrate_from >= _saved_keys.size()):
		return
	_hydrated_keys = _saved_keys.duplicate()
	_hydrated = []
	_hydrated_src = []
	_hydrate_from = 0
	_hydrating = not _saved_keys.is_empty()
	set_process(_hydrating)

## 每帧限时水合，避免数千键的逐键 DB 水合卡住主循环
func _process(_delta: float) -> void:
	# 游戏对局中让路，一帧几毫秒也是抖动
	if UiStatMGR.current_state == UIStateManager.UIState.PLAY_VIEW:
		return
	var t0 := Time.get_ticks_usec()
	while _hydrate_from < _saved_keys.size():
		var m: MidiData = DataMGR.get_midi_by_id(_saved_keys[_hydrate_from])
		if m != null:
			_hydrated.append(m)
			_hydrated_src.append(_hydrate_from)
		_hydrate_from += 1
		if Time.get_ticks_usec() - t0 > 6000:
			return
	_hydrating = false
	set_process(false)
	GLogger.info("Playlist hydrated: %d songs" % _hydrated.size(), "PlaylistMGR")
	hydration_finished.emit(_hydrated)

# ── 存 ────────────────────────────────────────────────

## 由 MidiPlaybackManager 在列表/下标变化时调用
func save(mgr) -> void:
	ensure_loaded()
	if not _loaded:
		# 未成功载入过就不写，避免用空列表覆盖磁盘
		return
	if mgr == null or ChartDB == null or not ChartDB.IsOpen():
		return
	# 「正常播放场景」的临时列表不落盘：否则下次恢复成"上次随手播的那首"，覆盖用户的列表
	if not persist_enabled:
		return
	saved_index = mgr.playlist_index
	saved_repeat_mode = mgr.repeat_mode
	var keys: Array[String] = []
	for m in mgr.playlist:
		if m is MidiData:
			keys.append(_key_of(m))
	ChartDB.SavePlaylist(keys, saved_index, saved_repeat_mode, source_fav_id)
	_saved_keys = keys
	_start_hydration()

## 覆盖整个列表（选收藏夹、清空等场景）
func save_keys(new_keys: Array, index: int, fav_id: String) -> void:
	ensure_loaded()
	if not _loaded:
		return
	if ChartDB == null or not ChartDB.IsOpen():
		return
	saved_index = index
	source_fav_id = fav_id
	ChartDB.SavePlaylist(new_keys, index, saved_repeat_mode, source_fav_id)
	var keys: Array[String] = []
	for k in new_keys:
		var s := str(k)
		if not s.is_empty():
			keys.append(s)
	_saved_keys = keys
	_start_hydration()

func _key_of(m: MidiData) -> String:
	return m.chart_key if not m.chart_key.is_empty() else m.id

# ── 取 ────────────────────────────────────────────────

func _load() -> void:
	if ChartDB == null or not ChartDB.IsOpen():
		return   # DB 未就绪：留待 data_loaded_complete
	var raw: Dictionary = ChartDB.GetPlaylist()
	var arr: Array = raw.get("keys", [])
	_saved_keys.clear()
	for k in arr:
		var s := str(k)
		if not s.is_empty():
			_saved_keys.append(s)
	saved_index = int(raw.get("index", 0))
	saved_repeat_mode = int(raw.get("repeat_mode", 0))
	source_fav_id = str(raw.get("source_fav_id", ""))
	_loaded = true
	GLogger.info("PlaylistMeta loaded: %d songs" % _saved_keys.size(), "PlaylistMGR")

var _saved_keys: Array[String] = []

## 取可立即使用的播放列表水合结果。
## 全表已就绪 → {midis=全表, start=saved_index 对应下标}；
## 仍在后台水合 → 只同步水合自 saved_index 起的头部 head_count 项（起播够用），
## 全表完成后经 hydration_finished 送达，由调用方回填。
func load_midis(head_count: int = 16) -> Dictionary:
	ensure_loaded()
	var n := _saved_keys.size()
	if n == 0:
		return {"midis": [] as Array[MidiData], "start": 0}
	var start := clampi(saved_index, 0, n - 1)
	if not _hydrating and _hydrate_from >= n:
		# 全表就绪：saved_index 在剔除过项的列表里重新定位
		var pos := _locate(start)
		return {"midis": _hydrated.duplicate(), "start": pos}
	var out: Array[MidiData] = []
	var end := mini(start + maxi(head_count, 1), n)
	for i in range(start, end):
		var m: MidiData = DataMGR.get_midi_by_id(_saved_keys[i])
		if m != null:
			out.append(m)
	return {"midis": out, "start": 0}

## saved_keys 下标 → _hydrated 下标（取第一个 >= target 的项）
func _locate(target: int) -> int:
	var lo := 0
	var hi := _hydrated_src.size()
	while lo < hi:
		var mid := (lo + hi) >> 1
		if _hydrated_src[mid] < target:
			lo = mid + 1
		else:
			hi = mid
	return lo

## 剔除已删除的曲子。DB 未打开时跳过——用户数据唯一副本在此，不能因数据层
## 临时不可用而误删
func _prune() -> void:
	if ChartDB == null or not ChartDB.IsOpen():
		return
	# 一次性取全库规范键做集合过滤：逐键 LookupChartKey 在数千键时要在调用
	# 线程上跑好几秒（进播放器页卡顿的元凶）
	var valid := {}
	for k in ChartDB.GetAllChartKeys():
		valid[k] = true
	var kept: Array[String] = []
	var dropped := false
	for k in _saved_keys:
		if valid.has(k):
			kept.append(k)
		else:
			# 旧数据可能存的是别名（id / file_hash），逐键兜底解析
			var canonical: String = ChartDB.LookupChartKey(k)
			if canonical.is_empty():
				dropped = true
			else:
				kept.append(canonical)
				dropped = true
	if not dropped:
		return
	_saved_keys = kept
	if saved_index >= _saved_keys.size():
		saved_index = maxi(0, _saved_keys.size() - 1)
	var arr: Array = []
	for k in _saved_keys:
		arr.append(k)
	ChartDB.SavePlaylist(arr, saved_index, saved_repeat_mode, source_fav_id)
	GLogger.info("PlaylistMeta pruned: %d songs remain" % _saved_keys.size(), "PlaylistMGR")

# ── 歌单来源 ──────────────────────────────────────────

## 载入某收藏夹的歌曲为播放列表（返回 chart_key 数组，交给 manager.set_playlist）
func keys_of_favorite(fav_id: String) -> Array:
	var fav_mgr := FavoriteManager.instance
	if fav_mgr == null:
		return []
	var out: Array = []
	for m in fav_mgr.get_midis_of_favorite(fav_id):
		out.append(_key_of(m))
	return out

## 歌单来源名称；未关联时为空
func source_fav_name() -> String:
	if source_fav_id.is_empty():
		return ""
	var fav_mgr := FavoriteManager.instance
	if fav_mgr == null:
		return ""
	for f in fav_mgr.favorites:
		if f.id == source_fav_id:
			return f.name
	return ""

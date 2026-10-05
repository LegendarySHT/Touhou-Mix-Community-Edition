## 收藏夹管理单例
## 负责收藏夹的 CRUD 操作和持久化
## 数据以 JSON 格式存储在 user://files/favorites.json，用户可直接编辑
extends Node

class_name FavoriteManager

static var instance: FavoriteManager

const FAVORITES_FILE = "favorites.json"
const DEFAULT_FAVORITE_NAME = "默认收藏夹"

## 所有收藏夹列表
var favorites: Array[FavoriteListData] = []


func _ready() -> void:
	instance = self
	EvtBus.data_loaded_complete.connect(_on_data_loaded_complete)
	EvtBus.midi_deleted.connect(_on_midi_deleted)
	EvtBus.midis_deleted.connect(_on_midis_deleted)
	# 先加载收藏夹数据（不依赖 DataManager）
	_load_favorites()
	# 提前通知 UI 加载收藏夹列表（无需等待 MIDI 扫描完成）
	# 使用 call_deferred 确保 ShortCutMenu 等 UI 已实例化并连接信号
	call_deferred("_notify_favorites_loaded_early")


# ========== 持久化 ==========

## 加载收藏夹数据
func _load_favorites() -> void:
	var path := _get_favorites_path()
	if not FileAccess.file_exists(path):
		_create_default_favorite()
		_save_favorites()
		return
	var data: Dictionary = ConfigManager.instance.load_json_file(path)
	favorites.clear()
	var raw_favorites = data.get("favorites", [])
	for fav_dict in raw_favorites:
		favorites.append(FavoriteListData.from_dict(fav_dict))
	# 确保至少有默认收藏夹
	if favorites.is_empty():
		_create_default_favorite()
		_save_favorites()


## 保存收藏夹数据（带缩进，用户可读）
func _save_favorites() -> bool:
	var path := _get_favorites_path()
	PathHelper.ensure_dir_exists(PathHelper.get_files_dir())
	var data := {"favorites": []}
	for fav in favorites:
		data["favorites"].append(fav.to_dict())
	# 带缩进的 JSON，方便用户直接编辑
	var json_str := JSON.stringify(data, "\t")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		GLogger.error("Failed to save favorites: %s" % path, "FavMGR")
		return false
	file.store_string(json_str)
	file.close()
	return true


func _get_favorites_path() -> String:
	return PathHelper.get_files_dir() + FAVORITES_FILE


## 提前通知收藏夹已加载（在 MIDI 扫描完成之前）
## UI 可立即显示收藏夹列表，封面图片在 MIDI 扫描完成后通过 favorites_updated 补充
func _notify_favorites_loaded_early() -> void:
	EvtBus.favorites_loaded.emit()


## DataManager 加载完成后验证，清理已不存在的 midi 引用
func _on_data_loaded_complete() -> void:
	_validate_favorites()


func _validate_favorites() -> void:
	# 数据源不可用（DB 未打开，如 charts.ldb 被占用导致初始化失败）时跳过清理：
	# 收藏是用户数据，唯一副本在 favorites.json，绝不能因数据层临时不可用而误删并覆盖写回
	if ChartDB == null or not ChartDB.IsOpen():
		GLogger.warning("Favorites validation skipped (ChartDB not open)", "FavoriteMGR")
		EvtBus.favorites_updated.emit()
		return

	var fsm := FileSystemManager.instance
	var changed := false
	for fav in favorites:
		var original_size := fav.midi_ids.size()
		# 以磁盘扫描结果为准校验存在性（charts_index 来自磁盘目录扫描），而非 DB 水合：
		# DB 与磁盘不一致时（启动失败重建中 / 缓存过期）以磁盘为准，避免误删
		# 同时把别名（id / file_hash / hash）统一迁移为规范键 folder_name（TMX-020）
		var canonical_ids: Array[String] = []
		for raw_id in fav.midi_ids:
			if fsm == null:
				canonical_ids.append(raw_id)
				continue
			var lookup := fsm.lookup_chart(raw_id)
			if lookup.is_empty():
				continue  # 磁盘上不存在，清理引用
			var key: String = lookup["folder_name"]
			if key not in canonical_ids:
				canonical_ids.append(key)
		fav.midi_ids = canonical_ids
		if fav.midi_ids.size() != original_size:
			changed = true
	if changed:
		_save_favorites()
	EvtBus.favorites_updated.emit()


## MIDI 删除时同步清理收藏夹中的引用
func _on_midi_deleted(midi_id: String) -> void:
	_erase_ids_from_favorites([midi_id])

## 批量 MIDI 删除时同步清理收藏夹中的引用（一次写盘，避免逐 id N 次 _save_favorites）
func _on_midis_deleted(midi_ids: Array) -> void:
	_erase_ids_from_favorites(midi_ids)

## 从所有收藏夹中擦除指定 id（单条/批量共用；有变更才写盘一次）
func _erase_ids_from_favorites(ids: Array) -> void:
	var changed := false
	for fav in favorites:
		var original_size := fav.midi_ids.size()
		for midi_id in ids:
			# midi_id 可能是 id 或 file_hash（取决于 emit 处），多次 erase 安全
			fav.midi_ids.erase(midi_id)
		if fav.midi_ids.size() != original_size:
			changed = true
	if changed:
		_save_favorites()
		EvtBus.favorites_updated.emit()


# ========== CRUD 操作 ==========

## 创建新收藏夹
## 返回新收藏夹的 id
func create_favorite(fav_name: String) -> String:
	if fav_name.is_empty():
		fav_name = "新收藏夹"
	var fav := FavoriteListData.new(_generate_id(), fav_name, [])
	favorites.append(fav)
	_save_favorites()
	EvtBus.favorite_list_created.emit(fav.id)
	return fav.id


## 删除收藏夹
func delete_favorite(fav_id: String) -> void:
	for i in range(favorites.size()):
		if favorites[i].id == fav_id:
			favorites.remove_at(i)
			_save_favorites()
			EvtBus.favorite_list_deleted.emit(fav_id)
			return


## 重命名收藏夹
func rename_favorite(fav_id: String, new_name: String) -> void:
	if new_name.is_empty():
		return
	for fav in favorites:
		if fav.id == fav_id:
			fav.name = new_name
			_save_favorites()
			EvtBus.favorite_list_renamed.emit(fav_id, new_name)
			return


## 添加 MIDI 到收藏夹
func add_midi_to_favorite(fav_id: String, midi: MidiData) -> void:
	add_id_to_favorite(fav_id, chart_id_of(midi))


## 按 chart_id 直加（列表投影只有 id，免水合 MidiData）。去重，加入才落盘
func add_id_to_favorite(fav_id: String, chart_id: String) -> void:
	for fav in favorites:
		if fav.id == fav_id:
			if not chart_id in fav.midi_ids:
				fav.midi_ids.append(chart_id)
				_save_favorites()
				EvtBus.favorite_midi_changed.emit(fav_id, chart_id, true)
			return


## 批量按 chart_id 加收藏：整体去重、只落盘一次、发一次 favorites_updated
## （favorite_midi_changed 的监听方是整表刷新型，逐条发会让它们重建 N 遍）
func add_ids_to_favorite(fav_id: String, chart_ids: Array) -> void:
	for fav in favorites:
		if fav.id != fav_id:
			continue
		var added := false
		for cid in chart_ids:
			var cid_s := str(cid)
			if cid_s.is_empty() or cid_s in fav.midi_ids:
				continue
			fav.midi_ids.append(cid_s)
			added = true
		if added:
			_save_favorites()
			EvtBus.favorites_updated.emit()
		return


## 从收藏夹移除 MIDI
func remove_midi_from_favorite(fav_id: String, midi: MidiData) -> void:
	var chart_id := chart_id_of(midi)
	for fav in favorites:
		if fav.id == fav_id:
			fav.midi_ids.erase(chart_id)
			_save_favorites()
			EvtBus.favorite_midi_changed.emit(fav_id, chart_id, false)
			return


## 检查 MIDI 是否在收藏夹中
func is_midi_in_favorite(fav_id: String, midi: MidiData) -> bool:
	var chart_id := chart_id_of(midi)
	for fav in favorites:
		if fav.id == fav_id:
			return chart_id in fav.midi_ids
	return false


# ========== 查询接口 ==========

## 获取收藏夹
func get_favorite(fav_id: String) -> FavoriteListData:
	for fav in favorites:
		if fav.id == fav_id:
			return fav
	return null


## 获取收藏夹中的所有 MidiData
func get_midis_of_favorite(fav_id: String) -> Array[MidiData]:
	var result: Array[MidiData] = []
	var fav := get_favorite(fav_id)
	if not fav:
		return result
	for chart_id in fav.midi_ids:
		var midi := DataMGR.get_midi_by_id(chart_id)
		if midi:
			result.append(midi)
	return result


# ========== 内部工具 ==========

## MidiData → 收藏条目 id（规范键 folder_name 优先，其次 file_hash，最后 id，TMX-020）
func chart_id_of(midi: MidiData) -> String:
	return midi.chart_key if not midi.chart_key.is_empty() \
		else (midi.file_hash if not midi.file_hash.is_empty() else midi.id)


func _generate_id() -> String:
	return str(Time.get_unix_time_from_system()) + "_" + str(randi() % 1000000)


func _create_default_favorite() -> void:
	favorites.append(FavoriteListData.new(_generate_id(), DEFAULT_FAVORITE_NAME, []))

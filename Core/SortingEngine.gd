## 排序引擎
## 负责多维度MIDI谱面排序
extends Node

class_name SortingEngine

## 排序方向枚举
enum SortDirection {
	ASCENDING,  # 升序
	DESCENDING  # 降序
}

## 数据排序字段枚举
enum SortDataField {
	DEFAULT,            # 默认顺序（按专辑）
	DOWNLOAD_COUNT,    # 按下载数排序
	UP_COUNT,          # 按好评数排序
	TRIAL_COUNT,       # 按试玩数排序
	UPLOADED_DATE     # 按上传时间排序
}

## 状态排序字段枚举
enum SortStatField {
	ALL, 
	PENDING,
	APPROVED,
	INCLUDED,
	DEAD
}

## 初始化函数
func _ready() -> void:
	add_to_group("singleton")

## 排序配置
var current_sort_field: SortDataField = SortDataField.DEFAULT
var current_sort_stat_field: SortStatField = SortStatField.ALL
var current_sort_direction: SortDirection = SortDirection.DESCENDING

## 缓存排序结果，避免重复排序
var sort_cache: Dictionary = {}
var cache_key: String = ""

const FILTER_BATCH_SIZE := 100

## 排序任务状态
var _sort_request_id: int = 0
var is_sorting_active: bool = false

## 当前的midi列表
var current_midis: Array[MidiData] = []

## 当前排序结果的轻量投影（DB 路径，列表项直接消费；字段见 ChartDB.ListItemDict）
## 与 current_midis 并存：DB 路径填 items，显式传入 midis 的内存路径填 current_midis
var current_items: Array = []

## 停止排序任务
func stop_sorting() -> void:
	_sort_request_id += 1
	is_sorting_active = false

## 检查排序请求是否已失效
func _is_sort_cancelled(request_id: int) -> bool:
	return request_id != _sort_request_id or not is_inside_tree()

## 协程步骤之间让出一帧，保持UI响应
func _yield_for_sort_step(request_id: int) -> bool:
	var tree := get_tree()
	if tree == null:
		return true
	await tree.process_frame
	return _is_sort_cancelled(request_id)

## 获取排序后的MIDI列表
func _sort_midis(midis: Array[MidiData], 
					   sort_field: SortDataField = SortDataField.DEFAULT,
					   sort_direction: SortDirection = SortDirection.DESCENDING) -> Array[MidiData]:
	# 更新排序配置
	current_sort_field = sort_field
	current_sort_direction = sort_direction
	
	# 执行排序
	var sorted_result: Array[MidiData] = midis.duplicate()
	
	# 使用显式配置进行排序，避免依赖全局状态
	sorted_result.sort_custom(func(a: MidiData, b: MidiData) -> bool:
		return _compare_midis(a, b, sort_field, sort_direction)
	)
	
	# 缓存结果
	# sort_cache[cache_key] = sorted_result
	
	return sorted_result

## 比较两个MIDI谱面
func _compare_midis(
	midi_a: MidiData,
	midi_b: MidiData,
	sort_field: SortDataField,
	sort_direction: SortDirection
) -> bool:
	var sort_ascending = sort_direction == SortDirection.ASCENDING
	var result: int = 0
	
	match sort_field:
		SortDataField.DOWNLOAD_COUNT:
			result = _compare_int(midi_a.download_count, midi_b.download_count)
		
		SortDataField.UP_COUNT:
			result = _compare_int(midi_a.up_count, midi_b.up_count)
		
		SortDataField.TRIAL_COUNT:
			result = _compare_int(midi_a.trial_count, midi_b.trial_count)
		
		SortDataField.UPLOADED_DATE:
			result = _compare_string(midi_a.uploaded_date, midi_b.uploaded_date)
		
		SortDataField.DEFAULT:
			# 默认排序：按专辑名->歌曲名->谱面名（扁平字段，MidiData 直接持有）
			result = _compare_string(midi_a.album_name, midi_b.album_name)
			if result == 0:
				result = _compare_string(midi_a.song_name, midi_b.song_name)
			if result == 0:
				result = _compare_string(midi_a.name, midi_b.name)
	
	# 根据排序方向返回结果
	return result < 0 if sort_ascending else result > 0

## 比较整数
func _compare_int(a: int, b: int) -> int:
	if a < b:
		return -1
	elif a > b:
		return 1
	else:
		return 0

## 比较字符串
func _compare_string(a: String, b: String) -> int:
	if a < b:
		return -1
	elif a > b:
		return 1
	else:
		return 0

## 将状态枚举映射为数据中的字符串
func _get_status_name(status: SortStatField) -> String:
	match status:
		SortStatField.PENDING:
			return "PENDING"
		SortStatField.APPROVED:
			return "APPROVED"
		SortStatField.INCLUDED:
			return "INCLUDED"
		SortStatField.DEAD:
			return "DEAD"
		_:
			return ""

## 可读化排序配置（调试用）：状态/字段/方向全打印，便于确认筛选面板切换时的完整生效状态
func _describe_sort(status: SortStatField, field: SortDataField, direction: SortDirection) -> String:
	var field_names := ["默认(专辑名)", "下载数", "好评数", "试玩数", "上传时间"]
	var stat_name := _get_status_name(status)
	if stat_name.is_empty():
		stat_name = "ALL"
	var field_name: String = field_names[int(field)] if int(field) < field_names.size() else str(int(field))
	var dir_name := "升序" if direction == SortDirection.ASCENDING else "降序"
	return "状态=%s 字段=%s 方向=%s" % [stat_name, field_name, dir_name]

## 按状态过滤MIDI列表（协程批量处理版本）
func _filter_midis_by_status(
	midis: Array[MidiData],
	status: SortStatField,
	request_id: int,
	batch_size: int = FILTER_BATCH_SIZE
) -> Array[MidiData]:
	if status == SortStatField.ALL:
		return midis
	
	var status_name := _get_status_name(status)
	var result: Array[MidiData] = []
	
	for i in range(0, midis.size(), batch_size):
		if _is_sort_cancelled(request_id):
			return []
		
		var end_index = min(i + batch_size, midis.size())
		for j in range(i, end_index):
			var midi = midis[j]
			if midi.status == status_name:
				result.append(midi)
		
		if end_index < midis.size() and await _yield_for_sort_step(request_id):
			return []
	
	return result

## 给UI获取Midi列表用
func get_midis() -> Array[MidiData]:
	GLogger.info("当前midi数量: %d" % current_midis.size(), "SortEngine")
	return current_midis

## 获取当前排序结果的轻量投影（DB 路径，SortedMidiView 直接消费）
func get_items() -> Array:
	return current_items

## 设置排序模式
func set_sort_mode(status: SortStatField = SortStatField.ALL,
					sort_field: SortDataField = SortDataField.DEFAULT,
					sort_direction: SortDirection = SortDirection.DESCENDING,
					midis = null):
	_sort_request_id += 1
	var request_id := _sort_request_id
	is_sorting_active = true
	_sort_mode_task(request_id, status, sort_field, sort_direction, midis)

## 用搜索词重新跑当前排序（DB 路径：状态过滤 + 字段排序 + 搜索全在 C# FilterSearch 完成）
func set_sort_mode_with_query(query: String) -> void:
	_sort_request_id += 1
	var request_id := _sort_request_id
	is_sorting_active = true
	_sort_mode_task(request_id, current_sort_stat_field, current_sort_field, current_sort_direction, null, query)

## 排序任务收尾
func _finish_sort_task(request_id: int, should_emit_signal: bool) -> void:
	if request_id != _sort_request_id:
		return
	
	is_sorting_active = false
	if should_emit_signal:
		_emit_sort_finished()

## 按状态和排序过滤MIDI列表（协程任务）
## 数据源：ChartDb（状态过滤 + 字段排序 + 可选搜索词在 C# 一次完成，返回有序轻量投影）
## 列表项直接消费投影，不再全量水合 MidiData（点击时才水合单条）
## 仅当调用方显式传入 midis（自定义列表）时退回内存排序路径保持兼容
func _sort_mode_task(
	request_id: int,
	status: SortStatField = SortStatField.ALL,
	sort_field: SortDataField = SortDataField.DEFAULT,
	sort_direction: SortDirection = SortDirection.DESCENDING,
	midis = null,
	query: String = ""
) -> void:
	current_sort_field = sort_field
	current_sort_direction = sort_direction
	current_sort_stat_field = status

	# 兼容路径：显式传入的 midis 列表走原内存排序
	if midis != null:
		GLogger.info("开始排序任务(内存): %s" % _describe_sort(status, sort_field, sort_direction), "SortEngine")
		var source_midis: Array = midis
		if await _yield_for_sort_step(request_id):
			return
		var temp_list = await _filter_midis_by_status(source_midis, status, request_id)
		if _is_sort_cancelled(request_id):
			return
		temp_list = _sort_midis(temp_list, sort_field, sort_direction)
		if _is_sort_cancelled(request_id):
			return
		current_midis = temp_list
		_finish_sort_task(request_id, true)
		return

	GLogger.info("开始排序任务(DB): %s 搜索=[%s]" % [_describe_sort(status, sort_field, sort_direction), query], "SortEngine")

	# DB 全量排序：状态过滤 + 字段排序 +（可选）搜索词在 C# 一次完成，返回有序轻量投影
	# 列表项直接消费（不再全量水合 MidiData，点击时才水合单条）
	# 走线程池版本：2333 项全表查询实测 ~230ms，同步调用会把转场/开曲库那一帧直接卡死
	var status_str := _get_status_name(status)
	ChartDB.RequestSortedMidiListItemsAsync(status_str, int(sort_field), int(sort_direction), query,
		_on_sorted_items_ready)


## DB 排序结果回到主线程。C# 侧已保证只有最新一次请求会回调（旧任务直接丢弃），
## 这里不必再有 tag：到达即最新。
func _on_sorted_items_ready(items: Array) -> void:
	if not is_inside_tree():
		return
	current_items = items
	GLogger.info("DB 排序返回 %d 个项" % items.size(), "SortEngine")
	_finish_sort_task(_sort_request_id, true)

## 发射排序完成信号
func _emit_sort_finished() -> void:
	GLogger.info("排序完成", "SortEngine")
	EvtBus.sort_finished.emit()

## 清空缓存
func clear_cache() -> void:
	sort_cache.clear()
	cache_key = ""

## 搜索MIDI（按原名/专辑名/谱面名/歌手/原曲作者/上传者/描述，多关键字 AND 匹配）
## 6 个字段（谱面名/原曲名/专辑名/歌手/原曲作者/上传者，简介除外）走简繁日规范化匹配：
## query 经 ChartDB.NormalizeForSearch 归一，命中水合时预计算的 search_* 副本 ——
## 简/繁/日 三种写法互搜，另保原文匹配兜底；简介保持原文匹配。
## 在传入的（已筛选+已排序）列表内过滤并保持原序 —— 兼容 SortedMidiView 等当前集搜索
## 全库搜索请用 DataMGR.search_all_midis（DB 驱动，DelView 扁平搜索用）
func search_midis(midis: Array[MidiData], query: String) -> Array[MidiData]:
	if query.is_empty():
		return midis

	var keywords = query.to_lower().split(" ", false)
	# 规范化查询（词典未就绪时返回原文，退化为普通匹配）
	var norm_query = ChartDB.NormalizeForSearch(query).to_lower()
	var norm_keywords = norm_query.split(" ", false)
	var result: Array[MidiData] = []

	for midi in midis:
		var midi_name = midi.name.to_lower()
		var song_name = midi.song_name.to_lower()
		var album_name = midi.album_name.to_lower()
		var artist_name = midi.artist_name.to_lower()
		var author_name = midi.author_name.to_lower()
		var uploader_name = midi.uploader_name.to_lower()
		var description = midi.description.to_lower()
		# 规范化副本（水合时由 C# 预计算；缺省回退原字段）
		var norm_song = midi.search_song_name.to_lower() if not midi.search_song_name.is_empty() else song_name
		var norm_author = midi.search_author_name.to_lower() if not midi.search_author_name.is_empty() else author_name
		var norm_album = midi.search_album_name.to_lower() if not midi.search_album_name.is_empty() else album_name
		var norm_artist = midi.search_artist_name.to_lower() if not midi.search_artist_name.is_empty() else artist_name
		var norm_name = midi.search_name.to_lower() if not midi.search_name.is_empty() else midi_name
		var norm_uploader = midi.search_uploader_name.to_lower() if not midi.search_uploader_name.is_empty() else uploader_name

		var all_keywords_match = true
		for i in range(keywords.size()):
			var kw = keywords[i]
			var nkw = norm_keywords[i] if i < norm_keywords.size() else kw
			if not (midi_name.contains(kw) or norm_name.contains(nkw) or
				song_name.contains(kw) or norm_song.contains(nkw) or
				album_name.contains(kw) or norm_album.contains(nkw) or
				artist_name.contains(kw) or norm_artist.contains(nkw) or
				author_name.contains(kw) or norm_author.contains(nkw) or
				uploader_name.contains(kw) or norm_uploader.contains(nkw) or
				description.contains(kw)):
				all_keywords_match = false
				break

		if all_keywords_match:
			result.append(midi)

	return result

## 场景退出时的清理
func _exit_tree() -> void:
	# 停止排序任务
	stop_sorting()

	# 清理缓存
	clear_cache()

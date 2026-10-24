extends Node
class_name ResourceManager

## 资源下载管理器：管理 MIDI 等资源的下载、状态追踪
## 通过 project.godot autoload 注册为单例 ResMGR

## 下载状态枚举
enum DownloadState { NOT_DOWNLOADED, DOWNLOADING, DOWNLOADED, FAILED }

## 下载阶段枚举（进度上报用，UI 侧映射为中文文案）。
## VOCAL 追加在末尾（2026-10-24 人声下载）：保持既有数值稳定
enum DownloadStage { METADATA, COVER, MIDI, JSON, RESCAN, VOCAL }

## 下载进度轮询间隔（秒）：引擎 HTTPRequest 无下载进度信号，
## 只能定时轮询 get_downloaded_bytes() 逼近（完成回调的最大附加延迟即此值）
const PROGRESS_POLL_INTERVAL := 0.15

static var instance: ResourceManager

## 下载状态缓存 {hash: DownloadState}
var _download_states: Dictionary = {}

## 封面并行下载信箱（download_chart 与 _on_cover_downloaded 回调之间传递结果）。
## _cover_done 初始 true（无任务），启动封面下载时置 false，回调置 true 并写 _cover_result。
var _cover_done := true
var _cover_result: Dictionary = {"ok": false, "error": "not_started"}

## 元数据 / MIDI 并行下载信箱（三请求并行路径用，语义同封面信箱）
var _meta_done := true
var _meta_result: Dictionary = {"ok": false, "error": "not_started"}
var _midi_done := true
var _midi_result: Dictionary = {"ok": false, "error": "not_started"}

## 人声并行下载信箱（第四路，语义同封面信箱；设置关闭或谱面无人声时初始 true 不参与 join）
var _vocal_done := true
var _vocal_result: Dictionary = {"ok": false, "error": "not_started"}

func _ready() -> void:
	if instance == null:
		instance = self
	else:
		queue_free()
		return
	# 初始化本地已下载状态
	_refresh_local_states()

## 刷新本地下载状态：扫描 FileSystemManager._hash_to_folder
func _refresh_local_states() -> void:
	_download_states.clear()
	if FileSystemManager.instance == null:
		return
	for hash_key in FileSystemManager.instance._hash_to_folder:
		_download_states[hash_key] = DownloadState.DOWNLOADED

# ========== MIDI 资源 API ==========

## 获取 MIDI 列表（分页 + 搜索 + 排序）
## sort: uploaded_at(默认) | download_count | play_count | like_count
## order: desc(默认) | asc
## 返回 {ok, data: {charts: [], total: int}}
func get_chart_list(page: int = 1, limit: int = 20, search: String = "",
		sort: String = "", order: String = "") -> Dictionary:
	if NetManager.instance == null or not NetManager.instance.is_online:
		return {"ok": false, "error": "offline"}
	var url := "%s/api/charts?page=%d&limit=%d&search=%s&sort=%s&order=%s" % [
		NetManager.instance.server_url, page, limit,
		search.uri_encode(), sort.uri_encode(), order.uri_encode()
	]
	return await NetManager.instance._request("GET", url, null)

## 下载 MIDI 到本地
## on_progress: 可选进度回调 Callable(stage: int, percent: float)——阶段见 DownloadStage，
##               percent < 0 表示该阶段无字节进度（仅阶段文案）。主线程定时调用，需保持轻量。
## hint: 可选列表项预取字段（ChartResponse 全量：fileSize/hasCover/songName/difficulty，
##        另含人声三键 hasVocal/vocalSize/vocalFormat）。
##        四键齐全时走**并行流程**（元数据/MIDI/封面同时发起，省一次元数据 TTFB；
##        人声在有且设置开启时第四路并行）；否则回退串行流程（元数据前置）。
##        商店入口传 hint，其他调用方可不传。
## 返回 {"ok": bool, "error": String}
func download_chart(chart_hash: String, on_progress: Callable = Callable(),
		hint: Dictionary = {}) -> Dictionary:
	if NetManager.instance == null or not NetManager.instance.is_online:
		return {"ok": false, "error": "offline"}
	if chart_hash.is_empty():
		return {"ok": false, "error": "hash_empty"}
	
	var safe_hash := _sanitize_hash(chart_hash)
	if safe_hash.is_empty():
		_download_states[chart_hash] = DownloadState.FAILED
		return {"ok": false, "error": "invalid_hash"}
	
	_download_states[chart_hash] = DownloadState.DOWNLOADING

	if _hint_is_valid(hint):
		return await _download_chart_parallel(chart_hash, safe_hash, on_progress, hint)
	return await _download_chart_sequential(chart_hash, safe_hash, on_progress)

## 并行下载路径：元数据/MIDI/封面互不依赖同时发起，人声（可选）第四路并行后 join。
## 前置条件：hint 四键齐全（fileSize/hasCover/songName/difficulty）——目录可先行建立，
## MIDI 的期望大小与封面的有无也不必等元数据。人声三键（hasVocal/vocalSize/vocalFormat）
## 随 hint 附带：设置开启且有 vocal 时并行下载，失败不阻塞整体流程。
func _download_chart_parallel(chart_hash: String, safe_hash: String,
		on_progress: Callable, hint: Dictionary) -> Dictionary:
	var base_url := NetManager.instance.server_url
	var meta_url := "%s/api/charts/%s" % [base_url, safe_hash]
	var midi_url := "%s/media/charts/%s.mid" % [base_url, safe_hash]
	var cover_url := "%s/api/charts/%s/cover" % [base_url, safe_hash]

	# 1. 先用 hint 建目录。目录名仅人类可读：FileSystemManager 按 info.json 的
	#    hash 字段识别目录（_hash_to_folder），songName 变化不影响映射
	var folder_name := _folder_name_for(safe_hash, hint)
	var chart_dir := FileSystemManager.CHARTS_DIR.path_join(folder_name)
	var mkdir_err := DirAccess.make_dir_recursive_absolute(chart_dir)
	if mkdir_err != OK:
		_download_states[chart_hash] = DownloadState.FAILED
		return {"ok": false, "error": "mkdir_failed"}
	var created_files: Array[String] = []
	var cover_path := chart_dir.path_join("cover.jpg")
	var midi_path := chart_dir.path_join("song.mid")

	# 2. 三路同时发起（均为语句形式 Callable 启动 + 信箱回调回收结果，
	#    见下方 _fetch_metadata / _on_*_downloaded 注释）
	_report_progress(on_progress, DownloadStage.METADATA, -1.0)
	_meta_done = false
	_meta_result = {"ok": false, "error": "not_started"}
	Callable(self, "_fetch_metadata").call(meta_url, Callable(self, "_on_metadata_downloaded"))

	var cover_needed := bool(hint.get("hasCover", false))
	_cover_done = not cover_needed
	if cover_needed:
		Callable(self, "_download_file").call(cover_url, cover_path, 0, 3,
			Callable(self, "_on_cover_downloaded"), on_progress, DownloadStage.COVER)

	_midi_done = false
	_midi_result = {"ok": false, "error": "not_started"}
	_report_download(safe_hash)  # beacon 与文件下载并行，不等待
	Callable(self, "_download_file").call(midi_url, midi_path,
		int(hint.get("fileSize", 0)), 3,
		Callable(self, "_on_midi_downloaded"), on_progress, DownloadStage.MIDI)

	# 2.5 人声（可选第四路，2026-10-24）：设置开启且 hint 表明有 vocal 才发起。
	#     与封面同策略——失败不阻塞整体流程（本地可玩，只是没人声）。
	#     vocalFormat 为空（脏数据）时跳过：无法推定本地文件名 vocal.<ext>
	var vocal_needed := _vocal_download_enabled() and bool(hint.get("hasVocal", false))
	var vocal_format := str(hint.get("vocalFormat", ""))
	var vocal_path := ""
	if vocal_needed and vocal_format.is_empty():
		vocal_needed = false
		GLogger.warning("hasVocal but vocalFormat empty for %s, skip vocal" % safe_hash, "ResMGR")
	_vocal_done = not vocal_needed
	if vocal_needed:
		vocal_path = chart_dir.path_join("vocal.%s" % vocal_format)
		var vocal_url := "%s/media/charts/%s.vocal" % [base_url, safe_hash]
		Callable(self, "_download_file").call(vocal_url, vocal_path,
			int(hint.get("vocalSize", 0)), 3,
			Callable(self, "_on_vocal_downloaded"), on_progress, DownloadStage.VOCAL)

	# 3. join 四路：先判断后轮询，任一先完成都不会漏等待（信箱见成员变量区）
	while not (_meta_done and _midi_done and _cover_done and _vocal_done):
		await get_tree().create_timer(0.05).timeout

	# 4. 元数据失败 → 清理（三路均已收尾，无文件写入竞态）
	if not _meta_result.get("ok", false):
		return _fail_download(chart_hash, chart_dir, created_files,
			"metadata_fetch_failed: %s" % str(_meta_result.get("error", "")))
	var chart_data: Dictionary = _meta_result.get("data", {})

	# 元数据与 hint 的 songName/difficulty 不一致（极端脏数据）：目录名保持已建版本
	# （识别靠 info.json hash），仅 warning；info.json 内容以元数据为准
	var meta_folder := _folder_name_for(safe_hash, chart_data)
	if meta_folder != folder_name:
		GLogger.warning("hint/metadata folder mismatch: %s vs %s (keep %s)" % [
			folder_name, meta_folder, folder_name], "ResMGR")

	if not _midi_result.get("ok", false):
		return _fail_download(chart_hash, chart_dir, created_files,
			"midi_download_failed: %s" % str(_midi_result.get("error", "")))
	created_files.append(midi_path)

	if cover_needed:
		if _cover_result.get("ok", false):
			created_files.append(cover_path)
		else:
			# 封面下载失败不阻塞整体流程
			GLogger.warning("Cover download failed for %s: %s" % [safe_hash, str(_cover_result.get("error", ""))], "ResMGR")

	if vocal_needed:
		if _vocal_result.get("ok", false):
			created_files.append(vocal_path)
		else:
			# 人声下载失败不阻塞整体流程（与封面同策略）
			GLogger.warning("Vocal download failed for %s: %s" % [safe_hash, str(_vocal_result.get("error", ""))], "ResMGR")

	return await _finalize_download(chart_hash, chart_data, chart_dir, created_files, on_progress)

## 串行下载路径（回退）：无列表项上下文时元数据前置，再并行下载封面/MIDI。
## 保留给非商店入口（如未来的人声/其他调用方）与 hint 不完整时使用。
func _download_chart_sequential(chart_hash: String, safe_hash: String,
		on_progress: Callable) -> Dictionary:
	# 1. 获取元数据
	_report_progress(on_progress, DownloadStage.METADATA, -1.0)
	var meta_url := "%s/api/charts/%s" % [NetManager.instance.server_url, safe_hash]
	var meta_result := await NetManager.instance._request("GET", meta_url, null)
	if not meta_result.get("ok", false):
		_download_states[chart_hash] = DownloadState.FAILED
		return {"ok": false, "error": "metadata_fetch_failed: %s" % str(meta_result.get("error", ""))}
	
	var chart_data: Dictionary = meta_result.data

	# 2. 构建本地文件夹路径并确保目录存在
	var folder_name := _folder_name_for(safe_hash, chart_data)
	var chart_dir := FileSystemManager.CHARTS_DIR.path_join(folder_name)
	var mkdir_err := DirAccess.make_dir_recursive_absolute(chart_dir)
	if mkdir_err != OK:
		_download_states[chart_hash] = DownloadState.FAILED
		return {"ok": false, "error": "mkdir_failed"}
	# 记录本次已写入的文件，下载失败时清理
	var created_files: Array[String] = []

	# 3. 封面与 MIDI 并行下载（互不依赖；封面失败不阻塞整体流程）
	var cover_path := chart_dir.path_join("cover.jpg")
	var cover_needed := bool(chart_data.get("hasCover", false))
	_cover_done = not cover_needed
	if cover_needed:
		var cover_url := "%s/api/charts/%s/cover" % [NetManager.instance.server_url, safe_hash]
		# ⚠️ 必须用**语句形式**调用（丢弃返回值）：把协程状态对象
		# （GDScriptFunctionState）赋值给变量会触发引擎运行时错误
		# "Trying to call an async function without await"（gdscript_vm.cpp
		# 对 call_ret 且返回协程对象的检查）。下载结果经 on_done 回调回收。
		Callable(self, "_download_file").call(cover_url, cover_path, 0, 3,
			Callable(self, "_on_cover_downloaded"), on_progress, DownloadStage.COVER)

	# 3.5 人声（可选，2026-10-24）：设置开启且元数据表明有 vocal 时与封面并联发起。
	#     与封面同策略——失败不阻塞整体流程；vocalFormat 为空（脏数据）时跳过
	var vocal_needed := _vocal_download_enabled() and bool(chart_data.get("hasVocal", false))
	var vocal_format := str(chart_data.get("vocalFormat", ""))
	var vocal_path := ""
	if vocal_needed and vocal_format.is_empty():
		vocal_needed = false
		GLogger.warning("hasVocal but vocalFormat empty for %s, skip vocal" % safe_hash, "ResMGR")
	_vocal_done = not vocal_needed
	if vocal_needed:
		vocal_path = chart_dir.path_join("vocal.%s" % vocal_format)
		var vocal_url := "%s/media/charts/%s.vocal" % [NetManager.instance.server_url, safe_hash]
		Callable(self, "_download_file").call(vocal_url, vocal_path,
			int(chart_data.get("vocalSize", 0)), 3,
			Callable(self, "_on_vocal_downloaded"), on_progress, DownloadStage.VOCAL)

	# 4. 下载 MIDI：走可缓存媒体路径 /media/charts/{hash}.mid（CF 边缘命中 ~2s），
	#    计数用并行 beacon 上报（不等待、失败静默）
	var midi_url := "%s/media/charts/%s.mid" % [NetManager.instance.server_url, safe_hash]
	var midi_path := chart_dir.path_join("song.mid")
	_report_download(safe_hash)
	var midi_result: Dictionary = await _download_file(midi_url, midi_path,
		int(chart_data.get("fileSize", 0)), 3, Callable(), on_progress, DownloadStage.MIDI)

	# 等封面收尾再处理 MIDI 成败（避免失败清理目录与封面写入竞态）。
	# _cover_done 先判断后等待：封面即使先于 MIDI 完成也不会漏等待。
	while not _cover_done:
		await get_tree().create_timer(0.05).timeout
	# 人声同理：收尾后再做失败清理（vocal.<ext> 写入与目录删除不能竞态）
	while not _vocal_done:
		await get_tree().create_timer(0.05).timeout
	if cover_needed:
		if _cover_result.get("ok", false):
			created_files.append(cover_path)
		else:
			# 封面下载失败不阻塞整体流程
			GLogger.warning("Cover download failed for %s: %s" % [safe_hash, str(_cover_result.get("error", ""))], "ResMGR")
	if vocal_needed:
		if _vocal_result.get("ok", false):
			created_files.append(vocal_path)
		else:
			# 人声下载失败不阻塞整体流程（与封面同策略）
			GLogger.warning("Vocal download failed for %s: %s" % [safe_hash, str(_vocal_result.get("error", ""))], "ResMGR")

	if not midi_result.get("ok", false):
		return _fail_download(chart_hash, chart_dir, created_files, "midi_download_failed: %s" % str(midi_result.get("error", "")))
	created_files.append(midi_path)

	return await _finalize_download(chart_hash, chart_data, chart_dir, created_files, on_progress)

## 下载收尾（并行/串行路径共用）：写 info.json + 刷新本地曲库索引
func _finalize_download(chart_hash: String, chart_data: Dictionary, chart_dir: String,
		created_files: Array, on_progress: Callable) -> Dictionary:
	# 5. 写入元数据 JSON（白名单结构，匹配 ChartNormalizer / ChartDb 派生）
	_report_progress(on_progress, DownloadStage.JSON, -1.0)
	var json_data := _build_local_json(chart_data)
	# 类型清理：整数 float → int，字符串字段 null → ""
	ChartNormalizer.cleanup_types_recursive(json_data)
	var json_path := chart_dir.path_join("info.json")
	var json_content := JSON.stringify(json_data, "\t", false)
	var f := FileAccess.open(json_path, FileAccess.WRITE)
	if f == null:
		return _fail_download(chart_hash, chart_dir, created_files, "json_write_failed")
	created_files.append(json_path)
	f.store_string(json_content)
	f.close()
	
	# 6. 刷新 FileSystemManager 索引
	_report_progress(on_progress, DownloadStage.RESCAN, -1.0)
	if FileSystemManager.instance:
		await FileSystemManager.instance.rescan_resources()
	
	_download_states[chart_hash] = DownloadState.DOWNLOADED
	GLogger.info("Chart downloaded: %s" % str(chart_data.get("hash", "")), "ResMGR")
	return {"ok": true}

## hint 有效性：四键齐全才允许三请求并行（目录先行建立 + MIDI 期望大小已知）。
## songName 允许空串（按 has() 判断而非真值——空串是合法谱面名）
func _hint_is_valid(hint: Dictionary) -> bool:
	return hint.has("fileSize") and hint.has("hasCover") \
		and hint.has("songName") and hint.has("difficulty")

## 由 chart 数据派生本地目录名（并行路径用 hint、串行路径用元数据，同一函数保证一致）
func _folder_name_for(safe_hash: String, chart_data: Dictionary) -> String:
	var song_name := _sanitize_folder_name(str(chart_data.get("songName", "unknown")))
	var difficulty := _sanitize_folder_name(str(chart_data.get("difficulty", "Normal")))
	return "%s_%s_%s" % [safe_hash, song_name, difficulty]

## 校验下载 hash 是否可安全用于本地路径（仅允许 URL-safe 字符，拒绝分隔符/点号/控制字符）
func _sanitize_hash(chart_hash: String) -> String:
	if chart_hash.is_empty() or chart_hash.length() > 128:
		return ""
	for c in chart_hash:
		var code := c.unicode_at(0)
		var is_alnum := (code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122)
		if not is_alnum and c != "_" and c != "-":
			return ""
	return chart_hash

## 下载失败清理：删除本次已写入的部分文件；目录为空时一并删除
func _fail_download(chart_hash: String, chart_dir: String, created_files: Array, error_msg: String) -> Dictionary:
	for file_path in created_files:
		if FileAccess.file_exists(file_path):
			DirAccess.remove_absolute(file_path)
	# 清理下载中间产物（.part/.part.tmp），否则非空目录删除会失败、留下垃圾目录
	DirAccess.remove_absolute(chart_dir.path_join("song.mid.part"))
	DirAccess.remove_absolute(chart_dir.path_join("song.mid.part.tmp"))
	DirAccess.remove_absolute(chart_dir.path_join("cover.jpg.part"))
	DirAccess.remove_absolute(chart_dir.path_join("cover.jpg.part.tmp"))
	# 人声扩展名不固定（vocal.ogg/.wav/.mp3/.flac），按前缀扫描清理
	var fail_dir := DirAccess.open(chart_dir)
	if fail_dir != null:
		for part_file in fail_dir.get_files():
			if part_file.begins_with("vocal.") and \
					(part_file.ends_with(".part") or part_file.ends_with(".part.tmp")):
				DirAccess.remove_absolute(chart_dir.path_join(part_file))
	DirAccess.remove_absolute(chart_dir)  # 非空目录删除会失败，忽略
	_download_states[chart_hash] = DownloadState.FAILED
	return {"ok": false, "error": error_msg}

## 构建本地 JSON 元数据（白名单结构，camelCase 键，对齐 ChartNormalizer / ChartDb 派生）
func _build_local_json(chart_data: Dictionary) -> Dictionary:
	return {
		"hash": str(chart_data.get("hash", "")),
		"uploaderId": str(chart_data.get("uploaderId", "")),
		"uploaderName": str(chart_data.get("uploaderName", "")),
		"uploaderAvatarUrl": str(chart_data.get("uploaderAvatarUrl", "")),
		"name": str(chart_data.get("title", "")),
		"desc": str(chart_data.get("description", "")),
		# MIG-1（2026-10-22）：服务端字段改名为 midiAuthor/midiAuthorUrl；
		# 本地 info.json 仍用旧键 artistName/artistUrl（ChartDb/MidiData 本地管线未变）
		"artistName": str(chart_data.get("midiAuthor", "")),
		"artistUrl": str(chart_data.get("midiAuthorUrl", "")),
		"coverHash": str(chart_data.get("coverHash", "")),
		"uploadedDate": str(chart_data.get("uploadedAt", "")),
		"approvedDate": str(chart_data.get("approvedAt", "")),
		"status": str(chart_data.get("status", "APPROVED")),
		"downloadCount": int(chart_data.get("downloadCount", 0)),
		"trialCount": int(chart_data.get("trialCount", 0)),
		"upCount": int(chart_data.get("upCount", 0)),
		"downCount": int(chart_data.get("downCount", 0)),
		# 嵌套 song/album 供 ChartNormalizer/ChartDb 派生读取；author 写入 song.author（不在顶层）
		"song": {
			"_id": str(chart_data.get("songId", "")),
			"name": str(chart_data.get("songName", "")),
			"author": str(chart_data.get("authorName", ""))
		},
		"album": {
			"_id": str(chart_data.get("albumId", "")),
			"name": str(chart_data.get("albumName", ""))
		}
	}

## 下载二进制文件到本地路径（流式落盘 + 自适应超时 + 断点续传）
## on_done: 可选完成回调，供「即发即弃」式并行启动回收结果——语句形式调用协程
## 拿不到返回值（且引擎禁止把协程状态对象赋值给变量，见 download_chart 注释），
## 结果经此回调传出；直接 await 调用时回调同样触发（无害）。
## on_progress: 可选进度回调 Callable(stage, percent)，经 _download_file_impl 轮询上报；
## stage: 进度上报时标注的下载阶段（DownloadStage）
func _download_file(url: String, save_path: String, expected_size: int = 0,
		max_attempts: int = 3, on_done: Callable = Callable(),
		on_progress: Callable = Callable(), stage: int = DownloadStage.MIDI) -> Dictionary:
	var result := await _download_file_impl(url, save_path, expected_size, max_attempts, on_progress, stage)
	if on_done.is_valid():
		on_done.call(result)
	return result

func _download_file_impl(url: String, save_path: String, expected_size: int, max_attempts: int,
		on_progress: Callable = Callable(), stage: int = DownloadStage.MIDI) -> Dictionary:
	var part_path := save_path + ".part"
	var tmp_path := save_path + ".part.tmp"
	var attempt := 0
	while attempt < max_attempts:
		attempt += 1
		
		# 断点续传：从 .part 已落盘字节处继续（URL 内容寻址，旧片段永远有效）
		var resumed_from := 0
		if FileAccess.file_exists(part_path):
			resumed_from = _file_size(part_path)
		
		# 自适应超时：剩余字节按 100KB/s 保守估算 ×1.5 余量，封顶 300s。
		# MB 级文件走 CF 边缘命中时几秒完成，回源慢时也不至于被固定 60s 掐断
		var timeout := 60.0
		if expected_size > resumed_from:
			timeout = clampf((expected_size - resumed_from) / 100000.0 * 1.5, 60.0, 300.0)
		
		var headers := PackedStringArray()
		if resumed_from > 0:
			headers.append("Range: bytes=%d-" % resumed_from)
		
		if FileAccess.file_exists(tmp_path):
			DirAccess.remove_absolute(tmp_path)
		
		var http := HTTPRequest.new()
		add_child(http)
		http.timeout = timeout
		# Godot 的 download_file 以截断方式打开目标文件：206 片段先落临时文件，
		# 成功后再拼接进 .part，避免 Range 尾巴覆写文件头部
		http.download_file = tmp_path
		# 先上报一次阶段文案（percent=-1）：请求秒失败时 UI 也知道当前在下什么
		_report_progress(on_progress, stage, -1.0)
		var err := http.request(url, headers)
		if err != OK:
			http.queue_free()
			if attempt >= max_attempts:
				return {"ok": false, "error": "request_failed: %d" % err}
			continue

		# 等待完成：带进度回调时轮询上报（HTTPRequest 无进度信号），否则直接 await 信号
		var resp: Array
		if on_progress.is_valid():
			resp = await _await_completed_with_progress(http, on_progress, stage, expected_size, resumed_from)
		else:
			resp = await http.request_completed
		http.queue_free()
		var result_code = resp[0]
		var response_code = resp[1]
		
		if result_code != HTTPRequest.RESULT_SUCCESS:
			# 超时/连接失败：引擎已自动删除未完成的临时文件；保留 .part 下一轮续传
			if attempt >= max_attempts:
				return {"ok": false, "error": "download_failed: result=%d" % result_code}
			continue
		
		if response_code == 416:
			# .part 超出服务端范围：丢弃重新全量下载（内容寻址下不应发生）
			DirAccess.remove_absolute(part_path)
			if attempt >= max_attempts:
				return {"ok": false, "error": "http_416"}
			continue
		
		if response_code != 200 and response_code != 206:
			# 4xx 直接失败；5xx（边缘瞬时错误）可重试
			if response_code >= 500 and attempt < max_attempts:
				continue
			return {"ok": false, "error": "http_%d" % response_code}
		
		# 空响应（如误配 200 空体）按失败处理，避免落下 0 字节文件
		if _file_size(tmp_path) == 0:
			return {"ok": false, "error": "empty_response"}
		
		# 200 = 服务端未理会 Range，返回全量：整体替换 .part；
		# 206 = Range 片段：追加到 .part 末尾
		if response_code == 200:
			if FileAccess.file_exists(part_path):
				DirAccess.remove_absolute(part_path)
			if DirAccess.rename_absolute(tmp_path, part_path) != OK:
				return {"ok": false, "error": "rename_failed"}
		else:
			var part_handle := FileAccess.open(part_path, FileAccess.READ_WRITE)
			if part_handle == null:
				return {"ok": false, "error": "part_open_failed"}
			part_handle.seek_end()
			var chunk_file := FileAccess.open(tmp_path, FileAccess.READ)
			if chunk_file == null:
				part_handle.close()
				return {"ok": false, "error": "tmp_read_failed"}
			part_handle.store_buffer(chunk_file.get_buffer(chunk_file.get_length()))
			chunk_file.close()
			part_handle.close()
			DirAccess.remove_absolute(tmp_path)
		
		# 大小校验（期望值已知时）：不符则重下（内容寻址下不应发生）
		if expected_size > 0 and _file_size(part_path) != expected_size:
			if attempt >= max_attempts:
				DirAccess.remove_absolute(part_path)
				return {"ok": false, "error": "size_mismatch"}
			continue
		# 校验通过必须 break 跳出重试循环（去循环外执行 .part → 正式路径重命名）。
		# ⚠️ 曾缺此 break：校验通过后循环进入下一轮，.part 已满 → 服务端 416 →
		# 丢弃重下，每次下载白白多传 2 倍字节（最终 ok=true，冒烟测不出）
		break

	# 成功：.part → 正式路径
	if DirAccess.rename_absolute(part_path, save_path) != OK:
		return {"ok": false, "error": "rename_failed"}
	return {"ok": true}

## 下载计数上报（beacon）：与文件下载并行触发，不等待结果。
## 大文件改走可缓存媒体路径后，/file 的服务端权威计数不在下载路径上，
## 计数由本端点上报；失败/丢失仅影响商店排序，可接受。
## ⚠️ NetManager._request 是协程：此处为**语句形式**调用（丢弃返回值）即发即弃，
## 是合法姿势；切勿改成 `var r = _request(...)`——那会触发引擎运行时错误
## "Trying to call an async function without await"。
func _report_download(chart_hash: String) -> void:
	if NetManager.instance == null or not NetManager.instance.is_online:
		return
	var url := "%s/api/charts/%s/downloaded" % [NetManager.instance.server_url, chart_hash]
	NetManager.instance._request("POST", url, null)

## 封面并行下载完成回调（经 _download_file 的 on_done 触发）：置位信箱，
## 唤醒 download_chart 中的 join 轮询
func _on_cover_downloaded(result: Dictionary) -> void:
	_cover_result = result
	_cover_done = true

## 元数据并行拉取完成回调（经 _fetch_metadata 的 on_done 触发）
func _on_metadata_downloaded(result: Dictionary) -> void:
	_meta_result = result
	_meta_done = true

## MIDI 并行下载完成回调（经 _download_file 的 on_done 触发）
func _on_midi_downloaded(result: Dictionary) -> void:
	_midi_result = result
	_midi_done = true

## 人声并行下载完成回调（经 _download_file 的 on_done 触发）：置位信箱，
## 唤醒 download_chart 中的 join 轮询（第四路）
func _on_vocal_downloaded(result: Dictionary) -> void:
	_vocal_result = result
	_vocal_done = true

## 是否随谱面一并下载人声：[General] download_vocal（0=关，1=开，默认开）。
## 与 config.ini 默认值一致——ConfigManager 不可用（单测/极早期初始化）时按开启处理。
## 关闭时仅影响「随谱面一并下载」，不影响 download_vocal() 单独补下入口
func _vocal_download_enabled() -> bool:
	if ConfigManager.instance == null:
		return true
	return ConfigManager.instance.get_int("General", "download_vocal", 1) == 1

## 拉取谱面元数据（供三请求并行路径使用）：完成时经 on_done 回调回收结果。
## ⚠️ 由 download_chart 以**语句形式** Callable 启动（协程状态禁止赋值给变量，
## 见 download_chart 注释），结果经 on_done 传回信箱
func _fetch_metadata(meta_url: String, on_done: Callable) -> void:
	var result: Dictionary = await NetManager.instance._request("GET", meta_url, null)
	if on_done.is_valid():
		on_done.call(result)

## 上报下载进度（on_progress 无效时静默跳过——无调用方关心进度时零开销）
func _report_progress(on_progress: Callable, stage: int, percent: float) -> void:
	if on_progress.is_valid():
		on_progress.call(stage, percent)

## 轮询等待 HTTPRequest 完成，期间周期性上报下载进度。
## 引擎 HTTPRequest 只有 request_completed 信号（无下载进度信号），且经 call_deferred 发射，
## 故用「连接信号置完成标记 + 定时轮询字节数」实现：信号到达后下一轮询 tick 退出，
## 完成回调的最大附加延迟为一个轮询间隔（PROGRESS_POLL_INTERVAL）。
## expected_size: 元数据里的整文件字节数（0=未知）；base_bytes: 本次续传前已落盘的字节数
## ⚠️ 完成状态必须经 Dictionary（引用类型）传递，不能直接写协程局部变量：
## GDScript 协程内 lambda 对外层局部变量的写回不可靠（Godot 4.7.2 实测：
## lambda 里 `done = true` 后外层 while 永远看不到，轮询停住→下载卡死），
## 而改 Dictionary 内容（引用共享）可正常可见（探针验证）。resp 同理。
func _await_completed_with_progress(http: HTTPRequest, on_progress: Callable,
		stage: int, expected_size: int, base_bytes: int) -> Array:
	var state := {"resp": [], "finished": false}
	http.request_completed.connect(func(result: int, response_code: int,
			_headers: PackedStringArray, _body: PackedByteArray) -> void:
		state["resp"] = [result, response_code]
		state["finished"] = true
	)
	while not state["finished"]:
		await get_tree().create_timer(PROGRESS_POLL_INTERVAL).timeout
		if state["finished"]:
			break
		# 总量优先取元数据 fileSize；未知时用响应头 Content-Length + 已续传字节推算
		# （206 的 Content-Length 只是剩余片段，需加 base_bytes 才是整文件总量）
		var total_expected := expected_size
		if total_expected <= 0:
			var body_len := http.get_body_size()
			if body_len > 0:
				total_expected = base_bytes + body_len
		if total_expected > 0:
			var downloaded := base_bytes + http.get_downloaded_bytes()
			_report_progress(on_progress, stage,
				clampf(float(downloaded) / float(total_expected), 0.0, 1.0))
		else:
			# 无 Content-Length（chunked）且元数据缺 fileSize：仅报阶段
			_report_progress(on_progress, stage, -1.0)
	return state["resp"]

## 取文件字节数（不存在返回 0）
func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var size := f.get_length()
	f.close()
	return size

## 清理文件夹名中的非法字符
func _sanitize_folder_name(folder_name: String) -> String:
	var illegal := ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]
	var result := folder_name
	for c in illegal:
		result = result.replace(c, "_")
	return result

## 检查 MIDI 是否已下载
func is_chart_downloaded(chart_hash: String) -> bool:
	return get_download_state(chart_hash) == DownloadState.DOWNLOADED

## 获取下载状态
func get_download_state(chart_hash: String) -> DownloadState:
	if _download_states.has(chart_hash):
		var cached: int = _download_states[chart_hash]
		# 本地谱面删除后（MidiView 删除曲包 / DelView 批量删除 / 外部删除后重扫），
		# 缓存的 DOWNLOADED 会残留，导致 StoreView 仍显示"已下载"且点击无反应。
		# 已下载状态以文件系统索引为准：命中缓存时再校验 _hash_to_folder，不存在则自愈回落。
		if cached == DownloadState.DOWNLOADED:
			if FileSystemManager.instance and FileSystemManager.instance._hash_to_folder.has(chart_hash):
				return cached as DownloadState
			_download_states.erase(chart_hash)
			return DownloadState.NOT_DOWNLOADED
		return cached as DownloadState
	# 检查 FileSystemManager 是否有该 hash
	if FileSystemManager.instance and FileSystemManager.instance._hash_to_folder.has(chart_hash):
		_download_states[chart_hash] = DownloadState.DOWNLOADED
		return DownloadState.DOWNLOADED
	return DownloadState.NOT_DOWNLOADED

# ========== 预留接口（未来实现） ==========

## 下载人声音频到本地**已下载**谱面的目录（vocal.{格式}，2026-10-24 实装）。
## 服务端权威：先拉元数据取 hasVocal/vocalFormat/vocalSize，无人声直接返回。
## StoreView 下载流程内的「一并下载」走 _download_chart_* 的并联逻辑，不经此函数；
## 本函数供「已下载谱面从服务端单独补下人声」的 UI 调用（当前无入口，接口就绪）。
## 幂等：本地 vocal.<ext> 已存在且字节数与服务端一致时直接返回 ok。
## 返回 {"ok": bool, "error": String}
func download_vocal(target_hash: String) -> Dictionary:
	if NetManager.instance == null or not NetManager.instance.is_online:
		return {"ok": false, "error": "offline"}
	var safe_hash := _sanitize_hash(target_hash)
	if safe_hash.is_empty():
		return {"ok": false, "error": "invalid_hash"}
	# 本地必须已有该谱面目录：本函数是「补下」，不负责谱面本体
	var folder_name := ""
	if FileSystemManager.instance and FileSystemManager.instance._hash_to_folder.has(safe_hash):
		folder_name = str(FileSystemManager.instance._hash_to_folder[safe_hash])
	if folder_name.is_empty():
		return {"ok": false, "error": "chart_not_downloaded"}
	var chart_dir := FileSystemManager.CHARTS_DIR.path_join(folder_name)

	# 元数据：hasVocal / vocalFormat / vocalSize（与列表/详情同源）
	var meta_url := "%s/api/charts/%s" % [NetManager.instance.server_url, safe_hash]
	var meta_result: Dictionary = await NetManager.instance._request("GET", meta_url, null)
	if not meta_result.get("ok", false):
		return {"ok": false, "error": "metadata_fetch_failed: %s" % str(meta_result.get("error", ""))}
	var chart_data: Dictionary = meta_result.data
	if not bool(chart_data.get("hasVocal", false)):
		return {"ok": false, "error": "no_vocal"}
	var vocal_format := str(chart_data.get("vocalFormat", ""))
	if vocal_format.is_empty():
		return {"ok": false, "error": "vocal_format_missing"}
	var vocal_path := chart_dir.path_join("vocal.%s" % vocal_format)

	# 幂等：已有同字节数文件视为已下载
	if FileAccess.file_exists(vocal_path) and _file_size(vocal_path) == int(chart_data.get("vocalSize", 0)):
		return {"ok": true}

	var vocal_url := "%s/media/charts/%s.vocal" % [NetManager.instance.server_url, safe_hash]
	var result: Dictionary = await _download_file(vocal_url, vocal_path,
		int(chart_data.get("vocalSize", 0)), 3)
	if not result.get("ok", false):
		return result

	# 刷新本地索引（vocal_files_index / DB audio_files），让 MidiData 立刻指到新人声
	if FileSystemManager.instance:
		await FileSystemManager.instance.rescan_resources()
	GLogger.info("Vocal downloaded: %s (%s)" % [safe_hash, vocal_format], "ResMGR")
	return {"ok": true}

## 下载 SF2 音源（预留接口）
func download_soundfont(_id: String) -> Dictionary:
	return {"ok": false, "error": "not_implemented"}

## 下载皮肤包（预留接口）
func download_skin(_id: String) -> Dictionary:
	return {"ok": false, "error": "not_implemented"}

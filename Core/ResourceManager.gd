extends Node
class_name ResourceManager

## 资源下载管理器：管理 MIDI 等资源的下载、状态追踪
## 通过 project.godot autoload 注册为单例 ResMGR

## 下载状态枚举
enum DownloadState { NOT_DOWNLOADED, DOWNLOADING, DOWNLOADED, FAILED }

static var instance: ResourceManager

## 下载状态缓存 {hash: DownloadState}
var _download_states: Dictionary = {}

## 封面并行下载信箱（download_chart 与 _on_cover_downloaded 回调之间传递结果）。
## _cover_done 初始 true（无任务），启动封面下载时置 false，回调置 true 并写 _cover_result。
var _cover_done := true
var _cover_result: Dictionary = {"ok": false, "error": "not_started"}

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
## 返回 {"ok": bool, "error": String}
func download_chart(chart_hash: String) -> Dictionary:
	if NetManager.instance == null or not NetManager.instance.is_online:
		return {"ok": false, "error": "offline"}
	if chart_hash.is_empty():
		return {"ok": false, "error": "hash_empty"}
	
	var safe_hash := _sanitize_hash(chart_hash)
	if safe_hash.is_empty():
		_download_states[chart_hash] = DownloadState.FAILED
		return {"ok": false, "error": "invalid_hash"}
	
	_download_states[chart_hash] = DownloadState.DOWNLOADING
	
	# 1. 获取元数据
	var meta_url := "%s/api/charts/%s" % [NetManager.instance.server_url, safe_hash]
	var meta_result := await NetManager.instance._request("GET", meta_url, null)
	if not meta_result.get("ok", false):
		_download_states[chart_hash] = DownloadState.FAILED
		return {"ok": false, "error": "metadata_fetch_failed: %s" % str(meta_result.get("error", ""))}
	
	var chart_data: Dictionary = meta_result.data
	
	# 2. 构建本地文件夹路径
	var song_name := str(chart_data.get("songName", "unknown"))
	var difficulty := str(chart_data.get("difficulty", "Normal"))
	# 清理文件名中的非法字符
	song_name = _sanitize_folder_name(song_name)
	difficulty = _sanitize_folder_name(difficulty)
	var folder_name := "%s_%s_%s" % [safe_hash, song_name, difficulty]
	var chart_dir := FileSystemManager.CHARTS_DIR.path_join(folder_name)
	
	# 确保目录存在
	var mkdir_err := DirAccess.make_dir_recursive_absolute(chart_dir)
	if mkdir_err != OK:
		_download_states[chart_hash] = DownloadState.FAILED
		return {"ok": false, "error": "mkdir_failed"}
	# 记录本次已写入的文件，下载失败时清理
	var created_files: Array[String] = []
	
	# 3. 封面与 MIDI 并行下载（互不依赖；封面失败不阻塞整体流程）
	var cover_path := chart_dir.path_join("cover.jpg")
	_cover_done = not bool(chart_data.get("hasCover", false))
	if not _cover_done:
		var cover_url := "%s/api/charts/%s/cover" % [NetManager.instance.server_url, safe_hash]
		# ⚠️ 必须用**语句形式**调用（丢弃返回值）：把协程状态对象
		# （GDScriptFunctionState）赋值给变量会触发引擎运行时错误
		# "Trying to call an async function without await"（gdscript_vm.cpp
		# 对 call_ret 且返回协程对象的检查）。下载结果经 on_done 回调回收。
		Callable(self, "_download_file").call(cover_url, cover_path, 0, 3,
			Callable(self, "_on_cover_downloaded"))

	# 4. 下载 MIDI：走可缓存媒体路径 /media/charts/{hash}.mid（CF 边缘命中 ~2s），
	#    计数用并行 beacon 上报（不等待、失败静默）
	var midi_url := "%s/media/charts/%s.mid" % [NetManager.instance.server_url, safe_hash]
	var midi_path := chart_dir.path_join("song.mid")
	_report_download(safe_hash)
	var midi_result: Dictionary = await _download_file(midi_url, midi_path, int(chart_data.get("fileSize", 0)))

	# 等封面收尾再处理 MIDI 成败（避免失败清理目录与封面写入竞态）。
	# _cover_done 先判断后等待：封面即使先于 MIDI 完成也不会漏等待。
	while not _cover_done:
		await get_tree().create_timer(0.05).timeout
	if _cover_result.get("ok", false):
		created_files.append(cover_path)
	else:
		# 封面下载失败不阻塞整体流程
		GLogger.warning("Cover download failed for %s: %s" % [safe_hash, str(_cover_result.get("error", ""))], "ResMGR")

	if not midi_result.get("ok", false):
		return _fail_download(chart_hash, chart_dir, created_files, "midi_download_failed: %s" % str(midi_result.get("error", "")))
	created_files.append(midi_path)
	
	# 5. 写入元数据 JSON（白名单结构，匹配 ChartNormalizer / ChartDb 派生）
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
	if FileSystemManager.instance:
		await FileSystemManager.instance.rescan_resources()
	
	_download_states[chart_hash] = DownloadState.DOWNLOADED
	GLogger.info("Chart downloaded: %s" % safe_hash, "ResMGR")
	return {"ok": true}

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

## 下载二进制文件到本地路径（流式落盘 + 自适应超时 + 断点续传重试）
## expected_size: 期望字节数（0 = 未知），用于按文件大小自适应超时
## 返回 {"ok": bool, "error": String}
## 下载二进制文件到本地路径（流式落盘 + 自适应超时 + 断点续传）
## on_done: 可选完成回调，供「即发即弃」式并行启动回收结果——语句形式调用协程
## 拿不到返回值（且引擎禁止把协程状态对象赋值给变量，见 download_chart 注释），
## 结果经此回调传出；直接 await 调用时回调同样触发（无害）。
func _download_file(url: String, save_path: String, expected_size: int = 0,
		max_attempts: int = 3, on_done: Callable = Callable()) -> Dictionary:
	var result := await _download_file_impl(url, save_path, expected_size, max_attempts)
	if on_done.is_valid():
		on_done.call(result)
	return result

func _download_file_impl(url: String, save_path: String, expected_size: int, max_attempts: int) -> Dictionary:
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
		var err := http.request(url, headers)
		if err != OK:
			http.queue_free()
			if attempt >= max_attempts:
				return {"ok": false, "error": "request_failed: %d" % err}
			continue
		
		var resp = await http.request_completed
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

## 下载人声音频（预留接口）
func download_vocal(_target_hash: String) -> Dictionary:
	return {"ok": false, "error": "not_implemented"}

## 下载 SF2 音源（预留接口）
func download_soundfont(_id: String) -> Dictionary:
	return {"ok": false, "error": "not_implemented"}

## 下载皮肤包（预留接口）
func download_skin(_id: String) -> Dictionary:
	return {"ok": false, "error": "not_implemented"}

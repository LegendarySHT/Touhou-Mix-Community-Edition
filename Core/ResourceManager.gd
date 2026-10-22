extends Node
class_name ResourceManager

## 资源下载管理器：管理 MIDI 等资源的下载、状态追踪
## 通过 project.godot autoload 注册为单例 ResMGR

## 下载状态枚举
enum DownloadState { NOT_DOWNLOADED, DOWNLOADING, DOWNLOADED, FAILED }

static var instance: ResourceManager

## 下载状态缓存 {hash: DownloadState}
var _download_states: Dictionary = {}

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
	
	# 3. 下载 MIDI 文件
	var midi_url := "%s/api/charts/%s/file" % [NetManager.instance.server_url, safe_hash]
	var midi_path := chart_dir.path_join("song.mid")
	var midi_result := await _download_file(midi_url, midi_path)
	if not midi_result.get("ok", false):
		return _fail_download(chart_hash, chart_dir, created_files, "midi_download_failed: %s" % str(midi_result.get("error", "")))
	created_files.append(midi_path)
	
	# 4. 下载封面（如有）
	var has_cover := bool(chart_data.get("hasCover", false))
	if has_cover:
		var cover_url := "%s/api/charts/%s/cover" % [NetManager.instance.server_url, safe_hash]
		var cover_path := chart_dir.path_join("cover.jpg")
		var cover_result := await _download_file(cover_url, cover_path)
		if not cover_result.get("ok", false):
			# 封面下载失败不阻塞整体流程
			GLogger.warning("Cover download failed for %s: %s" % [safe_hash, str(cover_result.get("error", ""))], "ResMGR")
		else:
			created_files.append(cover_path)
	
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

## 下载二进制文件到本地路径
func _download_file(url: String, save_path: String) -> Dictionary:
	var http := HTTPRequest.new()
	add_child(http)
	# 文件下载可能较大，设置较长超时
	http.timeout = 60.0
	var err := http.request(url)
	if err != OK:
		http.queue_free()
		return {"ok": false, "error": "request_failed: %d" % err}
	var resp = await http.request_completed
	http.queue_free()
	var result_code = resp[0]
	var response_code = resp[1]
	var response_body = resp[3]
	if result_code != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "error": "download_failed: result=%d" % result_code}
	if response_code != 200:
		return {"ok": false, "error": "http_%d" % response_code}
	if not response_body is PackedByteArray or response_body.size() == 0:
		return {"ok": false, "error": "empty_response"}
	var f := FileAccess.open(save_path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "error": "file_open_failed: %s" % save_path}
	f.store_buffer(response_body)
	f.close()
	return {"ok": true}

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

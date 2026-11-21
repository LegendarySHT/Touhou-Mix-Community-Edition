extends Node
class_name NetManager

## ServiceHub 服务声明：id 与依赖，注册时自动读取（见 Services/ServiceHub.gd）
const SERVICE_ID := "NetManager"
const SERVICE_DEPS := ["KeySequenceManager"]

## 在线管理器：HTTP 请求封装、服务端连接管理、延迟测量
## 通过 Main.gd 手动 add_child，使用 ServiceHub.net 访问

static var instance: NetManager = null

## 连接状态
enum ConnectState {
	OFFLINE_MODE,   # 在线模式关闭
	CONNECTING,     # 正在连接（快速尝试中或定期重试中）
	ONLINE,         # 已连接
	FAILED          # 连接失败（等待定期重试）
}

## 服务器地址（从 ConfigManager [General] server_address 读取）
var server_url: String = ""

## 配置地址缺失/清空时的回退地址：必须是线上正式地址。
## 早期这里写的是 http://localhost:5000，配合 Configuration 的「用户配置无条件覆盖默认值」，
## 玩家只要把设置页的「服务器地址」清空保存，游戏就会永久连 localhost，服务端连日志都没有；
## 而浏览器打开官网一切正常，报障看起来就像「只有游戏连不上」。联调请显式填 localhost:5000，
## _normalize_server_url 会为它补 http 前缀，不受本回退影响。
const FALLBACK_SERVER_URL: String = "https://thmixce.org"

## 当前是否在线（服务端可达）
var is_online: bool = false

## 当前连接状态
var connect_state: ConnectState = ConnectState.OFFLINE_MODE

## 最近一次延迟（毫秒），-1 表示未知
var _latency_ms: int = -1

## 读取最近一次连接延迟（毫秒；-1 = 未知/未连接，外部只读统一走此方法，TMX-019）
func get_latency_ms() -> int:
	return _latency_ms

## 最近一次连接失败的简短原因（中文，供 UI 直接展示）与原始诊断码。
## 诊断用：Android 玩家拿不到应用私有目录下的日志，界面上这句原因往往是
## 唯一能回传的证据；必须能区分「解析失败 / 连不上 / 证书 / 超时 / 被拒」。
var _last_fail_reason: String = ""
var _last_fail_detail: String = ""

## 读取最近一次失败原因（空串 = 当前无失败记录或已连接成功）
func get_last_fail_reason() -> String:
	return _last_fail_reason

## 读取最近一次失败的原始诊断码（result 枚举 + HTTP 状态 + 目标地址）
func get_last_fail_detail() -> String:
	return _last_fail_detail

## online_mode 开关
var _online_mode_enabled: bool = false

## 请求超时（秒）
const REQUEST_TIMEOUT: float = 10.0
## 上传类请求超时（秒）：请求体是 base64 图片，服务端还要解码缩放，
## 按普通接口的超时容易在慢网络上白等一次失败
const UPLOAD_REQUEST_TIMEOUT: float = 60.0

## 谱面草稿上传超时（秒）：要传 MIDI（≤50MB）+ 人声（≤20MB）+ 封面（≤5MB），
## 走 CF 边缘 + 家庭宽带上行时 60s 必然掐断（实测 6.6MB 回源 24~36s）。
## 300s 与 ResourceManager 的下载重试上限同量级，仍然是一次请求（HTTPRequest 无分片上传）。
const DRAFT_UPLOAD_TIMEOUT: float = 300.0

## 草稿上传的本地文件体积上限（字节），必须与后端 ChartService 的常量一致，
## 否则会出现「本地上传跑了 3 分钟，服务端 400 拒绝」。
## 对应 ChartService.MaxMidiBytes / MaxVocalBytes / MaxCoverBytes。
const DRAFT_MAX_MIDI_BYTES: int = 50 * 1024 * 1024
const DRAFT_MAX_VOCAL_BYTES: int = 20 * 1024 * 1024
const DRAFT_MAX_COVER_BYTES: int = 5 * 1024 * 1024

## 启动时快速尝试次数
const QUICK_RETRY_TIMES: int = 3
## 快速尝试间隔（秒）
const QUICK_RETRY_INTERVAL: float = 1.0
## 定期重试间隔（秒）
const PERIODIC_RETRY_INTERVAL: float = 30.0
## 延迟测量间隔（秒）
const LATENCY_UPDATE_INTERVAL: float = 10.0

# Timer 节点（运行时动态创建）
var _quick_retry_timer: Timer = null
var _quick_retry_count: int = 0
var _periodic_retry_timer: Timer = null
var _latency_timer: Timer = null
# 标记是否正在执行连接尝试，防止重入
var _connecting: bool = false
## 挂起来源集合：非空即挂起。仅停定时探测（健康检查/延迟测量），不拦截 _request，
## 成绩上传等业务请求仍需照常发出。
var _suspend_reasons: Dictionary = {}
## 上次广播的在线布尔值（online_status_changed 只在此值翻转时发射）
var _last_emitted_online: bool = false

func _ready() -> void:
	if instance == null:
		instance = self
	else:
		queue_free()
		return
	add_to_group("singleton")
	_load_server_url()
	if EvtBus:
		EvtBus.config_changed.connect(_on_config_changed)
	GLogger.info("NetManager initialized, server_url=%s" % server_url, "NetMGR")

## 从配置加载服务器地址
func _load_server_url() -> void:
	var addr = ServiceHub.config.get_string("server_address", FALLBACK_SERVER_URL)
	server_url = _normalize_server_url(addr)
	GLogger.info("Server URL loaded: %s" % server_url, "NetMGR")

## 规范化服务器地址：去除首尾空白/引号；无协议前缀时按主机自动补全。
## 本机地址（localhost/127.0.0.1）用 http，其余域名默认 https，避免裸域名被静默改写成 localhost。
func _normalize_server_url(addr: String) -> String:
	var url := addr.strip_edges()
	if url.length() >= 2 and url.begins_with("\"") and url.ends_with("\""):
		url = url.substr(1, url.length() - 2).strip_edges()
	if url.is_empty():
		return FALLBACK_SERVER_URL
	if url.begins_with("http://") or url.begins_with("https://"):
		if _is_valid_host(_extract_host(url)):
			return url
		GLogger.warning("Invalid server address (bad host), falling back to %s: %s" % [FALLBACK_SERVER_URL, addr], "NetMGR")
		return FALLBACK_SERVER_URL
	if url.begins_with("localhost") or url.begins_with("127.0.0.1") or url.begins_with("0.0.0.0"):
		return "http://" + url
	if _is_valid_host(url):
		return "https://" + url
	GLogger.warning("Invalid server address, falling back to %s: %s" % [FALLBACK_SERVER_URL, addr], "NetMGR")
	return FALLBACK_SERVER_URL

## 从 URL 中提取主机部分（去掉 scheme 与路径/端口校验前的部分）
func _extract_host(url: String) -> String:
	var rest := url
	if rest.begins_with("http://"):
		rest = rest.trim_prefix("http://")
	elif rest.begins_with("https://"):
		rest = rest.trim_prefix("https://")
	return rest.split("/")[0]

## 主机有效性：非空、无空白；本机/IP 或含点号的域名视为有效
func _is_valid_host(host: String) -> bool:
	var h := host.strip_edges()
	if h.is_empty() or h.contains(" ") or h.contains("\t"):
		return false
	if h.begins_with("localhost") or h.begins_with("127.0.0.1") or h.begins_with("0.0.0.0") or h.begins_with("["):
		return true
	return "." in h

## 谱面在服务端的存在性（本地 hash 与服务端 Charts 表比对结果）
## UNKNOWN：尚未探测 / 离线 / 请求出错——调用方不得据此猜测，按「两边都不显示」处理
enum ChartRemoteState {
	UNKNOWN,
	EXISTS,
	MISSING,
}

## 存在性探测结果缓存 {hash: {"state": int, "at": int}}（毫秒时间戳）
## 简介展开时会随选中项反复询问同一批 hash，每次真发请求既慢又浪费配额。
var _chart_remote_cache: Dictionary = {}
## 在途探测集合 {hash: true}：同一 hash 并发询问时后来者等待首个结果，不叠请求
var _chart_remote_inflight: Dictionary = {}

## 存在性缓存有效期（毫秒）：谱面可能在此后被上传/删除，过期后重新探测
const CHART_REMOTE_CACHE_TTL_MS: int = 300000
## 等待在途探测的上限（秒）：超过按 UNKNOWN 返回，不无限挂住 UI
const CHART_REMOTE_WAIT_TIMEOUT: float = 15.0

## 查询某 MIDI hash 是否存在于服务端（权威判据，供「在网页查看 / 上传歌曲」按钮分流）
## 返回 ChartRemoteState；离线、未联网、请求失败一律 UNKNOWN，绝不猜测。
## 说明：服务端 Charts.Hash 是上传 MIDI 文件的 MD5，与客户端 info.json 的 hash 同源，
## 因此可用本地 file_hash 直接比对，不依赖任何本地元数据（status/album/uploader）推断。
func probe_chart_remote_state(chart_hash: String) -> int:
	var h := chart_hash.strip_edges().to_lower()
	if h.is_empty() or server_url.is_empty():
		return ChartRemoteState.UNKNOWN
	# 未联网时不做判断：调用方据此隐藏按钮，避免把离线状态误判成「服务端没有」
	if not _online_mode_enabled or not is_online:
		return ChartRemoteState.UNKNOWN

	var now := Time.get_ticks_msec()
	if _chart_remote_cache.has(h):
		var entry: Dictionary = _chart_remote_cache[h]
		if now - int(entry.get("at", 0)) < CHART_REMOTE_CACHE_TTL_MS:
			return int(entry.get("state", ChartRemoteState.UNKNOWN))
		_chart_remote_cache.erase(h)

	# 已有探测在途：等它出结果，避免同一 hash 连发多次请求
	if _chart_remote_inflight.has(h):
		var start := Time.get_ticks_msec()
		while _chart_remote_inflight.has(h) \
				and Time.get_ticks_msec() - start < int(CHART_REMOTE_WAIT_TIMEOUT * 1000.0):
			await get_tree().process_frame
		if _chart_remote_cache.has(h):
			return int((_chart_remote_cache[h] as Dictionary).get("state", ChartRemoteState.UNKNOWN))
		return ChartRemoteState.UNKNOWN

	_chart_remote_inflight[h] = true
	var url := "%s/api/charts/%s" % [server_url, h.uri_encode()]
	var result: Dictionary = await _request("GET", url, null)
	_chart_remote_inflight.erase(h)

	var state := ChartRemoteState.UNKNOWN
	if bool(result.get("ok", false)):
		state = ChartRemoteState.EXISTS
	elif int(result.get("status", 0)) == 404:
		# 404 是服务端明确的「没有这张谱面」；其余（超时/5xx/解析失败）无法判断
		state = ChartRemoteState.MISSING
	if state != ChartRemoteState.UNKNOWN:
		_chart_remote_cache[h] = {"state": state, "at": Time.get_ticks_msec()}
	return state

## 同步读取已缓存的存在性结果（未命中/已过期/离线 → UNKNOWN）。
## 供 UI 在发起异步探测前先按已知结果即时渲染，避免按钮「先隐藏再出现」的闪烁。
func get_cached_chart_remote_state(chart_hash: String) -> int:
	var h := chart_hash.strip_edges().to_lower()
	if h.is_empty():
		return ChartRemoteState.UNKNOWN
	if not _online_mode_enabled or not is_online:
		return ChartRemoteState.UNKNOWN
	if not _chart_remote_cache.has(h):
		return ChartRemoteState.UNKNOWN
	var entry: Dictionary = _chart_remote_cache[h]
	if Time.get_ticks_msec() - int(entry.get("at", 0)) >= CHART_REMOTE_CACHE_TTL_MS:
		_chart_remote_cache.erase(h)
		return ChartRemoteState.UNKNOWN
	return int(entry.get("state", ChartRemoteState.UNKNOWN))

## 作废某个 hash 的存在性缓存（上传成功后调用：刚传上去的谱面马上就该显示「在网页查看」）
func invalidate_chart_remote_state(chart_hash: String) -> void:
	var h := chart_hash.strip_edges().to_lower()
	if h.is_empty():
		# 空参数 = 全部作废（服务器地址切换等场景）
		_chart_remote_cache.clear()
		return
	_chart_remote_cache.erase(h)

## 谱面 Web 详情页地址（服务端路由：/charts/{hash}）
## 服务端未提供“按 hash 查询详情页地址”的独立接口，这里按站点约定拼接。
## 返回空串表示暂无可用链接：调用方保留按钮，但点击时提示尚未开放。
func get_chart_web_url(chart_hash: String) -> String:
	var hash_str := chart_hash.strip_edges()
	if hash_str.is_empty() or server_url.is_empty():
		return ""
	var base := server_url
	while base.ends_with("/"):
		base = base.substr(0, base.length() - 1)
	if base.is_empty():
		return ""
	return "%s/charts/%s" % [base, hash_str.uri_encode()]

## 上传本地谱面为**草稿**（song.mid + 人声 + 封面，后两者存在才一并上传）
## 对应服务端 POST /api/drafts（ChartDraftsController.Create），字段名严格对齐：
##   midiFile(必填) / title / description / midiAuthor / midiAuthorUrl /
##   authorName / songName / albumName / coverFile / vocalFile
## 同一账号重复上传同一 MIDI = 覆盖更新草稿，不占新额度。
## 返回 {"ok": bool, "error": String, "code": String, "status": int, "data": Variant}
##   code 取服务端 409 的 error 字段：chart_exists / draft_limit / draft_conflict
func upload_chart_draft(midi: MidiData) -> Dictionary:
	if midi == null:
		return {"ok": false, "error": "midi_null", "code": "", "status": 0, "data": null}
	if ServiceHub.auth == null or not ServiceHub.auth.is_logged_in:
		return {"ok": false, "error": "not_logged_in", "code": "", "status": 0, "data": null}
	if server_url.is_empty():
		return {"ok": false, "error": "server_unavailable", "code": "", "status": 0, "data": null}
	if not await ServiceHub.auth.ensure_valid_token():
		return {"ok": false, "error": "token_expired", "code": "", "status": 0, "data": null}

	var chart_key := midi.chart_key if not midi.chart_key.is_empty() \
		else (midi.file_hash if not midi.file_hash.is_empty() else midi.id)
	var fs_mgr := ServiceHub.fs

	# ---- MIDI 文件（必填）----
	var midi_path := midi.midi_file_path
	if midi_path.is_empty() and fs_mgr != null:
		var folder := fs_mgr.get_chart_folder_path(chart_key)
		if not folder.is_empty():
			midi_path = folder.path_join("song.mid")
	if midi_path.is_empty() or not FileAccess.file_exists(midi_path):
		GLogger.warning("草稿上传失败：找不到 MIDI 文件 midi=%s" % midi_path, "NetMGR")
		return {"ok": false, "error": "midi_missing", "code": "", "status": 0, "data": null}
	var midi_bytes := FileAccess.get_file_as_bytes(midi_path)
	if midi_bytes.is_empty():
		return {"ok": false, "error": "midi_unreadable", "code": "", "status": 0, "data": null}
	if midi_bytes.size() > DRAFT_MAX_MIDI_BYTES:
		return {"ok": false, "error": "midi_too_large", "code": "", "status": 0, "data": null}

	# ---- 人声（可选）----
	var vocal_path := midi.vocal_file_path
	if vocal_path.is_empty() and fs_mgr != null:
		vocal_path = fs_mgr.get_vocal_path(chart_key)
	var vocal_bytes := PackedByteArray()
	if not vocal_path.is_empty() and FileAccess.file_exists(vocal_path):
		vocal_bytes = FileAccess.get_file_as_bytes(vocal_path)
		if vocal_bytes.size() > DRAFT_MAX_VOCAL_BYTES:
			# 超限不静默丢弃：玩家会以为人声传上去了，网页上却听不到
			return {"ok": false, "error": "vocal_too_large", "code": "", "status": 0, "data": null}

	# ---- 封面（可选）----
	# 本地无封面时 FileSystemManager 会回退到内置默认封面（DEFAULT_COVER_PATH），
	# 把那张图传上去会变成所有人的封面 —— 必须判等跳过。
	var cover_bytes := PackedByteArray()
	var cover_ext := ""
	if fs_mgr != null:
		var cover_path := fs_mgr.get_cover_path_by_midiData(midi)
		if not cover_path.is_empty() and cover_path != FileSystemManager.DEFAULT_COVER_PATH \
				and FileAccess.file_exists(cover_path):
			cover_bytes = FileAccess.get_file_as_bytes(cover_path)
			cover_ext = cover_path.get_extension().to_lower()
			if cover_bytes.size() > DRAFT_MAX_COVER_BYTES:
				cover_bytes = PackedByteArray()
				cover_ext = ""

	# ---- 组装 multipart ----
	var parts: Array = []
	parts.append({"name": "midiFile", "filename": "song.mid",
		"content_type": "audio/midi", "data": midi_bytes})
	parts.append({"name": "title", "value": _draft_title_of(midi, midi_path)})
	parts.append({"name": "description", "value": midi.description})
	parts.append({"name": "midiAuthor", "value": midi.artist_name})
	# MidiData 没有 MIDI 作者链接字段（本地 info.json 的 artistUrl 由服务端下发后落盘，
	# 但 MidiData.from_json 未映射），只能到网页上补 —— 需求允许「可到网页修改」。
	parts.append({"name": "midiAuthorUrl", "value": ""})
	parts.append({"name": "authorName", "value": midi.author_name})
	parts.append({"name": "songName", "value": midi.song_name})
	parts.append({"name": "albumName", "value": midi.album_name})
	if not vocal_bytes.is_empty():
		var vocal_format := vocal_path.get_extension().to_lower()
		if vocal_format.is_empty():
			vocal_format = "ogg"
		parts.append({"name": "vocalFile", "filename": "vocal.%s" % vocal_format,
			"content_type": _audio_content_type(vocal_format), "data": vocal_bytes})
	if not cover_bytes.is_empty():
		var cover_type := "image/png" if cover_ext == "png" else "image/jpeg"
		var cover_name := "cover.%s" % ("png" if cover_ext == "png" else "jpg")
		parts.append({"name": "coverFile", "filename": cover_name,
			"content_type": cover_type, "data": cover_bytes})

	var url := "%s/api/drafts" % server_url
	var result := await _request_multipart(url, parts, ServiceHub.auth.current_user.access_token,
		DRAFT_UPLOAD_TIMEOUT)

	if bool(result.get("ok", false)):
		GLogger.info("草稿上传成功：midi=%s vocal=%s cover=%s" % [
			midi_path,
			"有(%d B)" % vocal_bytes.size() if not vocal_bytes.is_empty() else "无",
			"有(%d B)" % cover_bytes.size() if not cover_bytes.is_empty() else "无"], "NetMGR")
		return {"ok": true, "error": "", "code": "", "status": int(result.get("status", 0)),
			"data": result.get("data")}

	# 失败：把服务端的 error 码透出给调用方做分支提示（409 的 chart_exists / draft_limit）
	var code := ""
	var data: Variant = result.get("data")
	if data is Dictionary:
		code = str(data.get("error", ""))
	GLogger.warning("草稿上传失败：status=%d code=%s error=%s" % [
		int(result.get("status", 0)), code, str(result.get("error", ""))], "NetMGR")
	return {"ok": false, "error": str(result.get("error", "")), "code": code,
		"status": int(result.get("status", 0)), "data": data}


## 草稿标题：优先谱面名，回退到 MIDI 文件名（与服务端「title 为空时取文件名」同口径）
func _draft_title_of(midi: MidiData, midi_path: String) -> String:
	var title := midi.name.strip_edges()
	if not title.is_empty():
		return title
	return midi_path.get_file().get_basename()


## 人声音频扩展名 → MIME（与后端 ChartVocal.ContentTypes 一致）
func _audio_content_type(ext: String) -> String:
	match ext.to_lower():
		"ogg": return "audio/ogg"
		"wav": return "audio/wav"
		"mp3": return "audio/mpeg"
		"flac": return "audio/flac"
		_: return "application/octet-stream"


## multipart/form-data 请求。
## 为什么不能复用 _request()：它硬写 Content-Type: application/json，且 body 走
## String —— 二进制 MIDI 会被当作 UTF-8 文本处理而损坏。这里必须用
## HTTPRequest.request_raw()（body 是 PackedByteArray，原样发送）。
## parts: Array[Dictionary]，每项两种形态：
##   {"name": String, "value": String}                                     纯文本段
##   {"name": String, "filename": String, "content_type": String,
##    "data": PackedByteArray}                                              文件段
## 文本值原样按 UTF-8 进 body（中文标题不需要任何编码）；文件名只出现在 header 里，
## 统一用 ASCII 安全名，避免非 ASCII 文件名触发服务端 multipart 解析边界问题。
## 返回与 _request 同构：{ ok, status, data, result_code, error }
func _request_multipart(url: String, parts: Array, auth_token: String = "",
		timeout: float = 0.0) -> Dictionary:
	var boundary := "----ThmixDraft%d%d" % [Time.get_ticks_usec(), randi()]
	var body := PackedByteArray()
	for part in parts:
		if not (part is Dictionary):
			continue
		var item: Dictionary = part
		var name := str(item.get("name", ""))
		if name.is_empty():
			continue
		var head := "--%s\r\nContent-Disposition: form-data; name=\"%s\"" % [boundary, name]
		if item.has("filename"):
			head += "; filename=\"%s\"" % str(item.get("filename", "file.bin"))
			head += "\r\nContent-Type: %s" % str(item.get("content_type", "application/octet-stream"))
		head += "\r\n\r\n"
		body.append_array(head.to_utf8_buffer())
		if item.has("data"):
			var raw: Variant = item.get("data")
			if raw is PackedByteArray:
				body.append_array(raw)
		else:
			body.append_array(str(item.get("value", "")).to_utf8_buffer())
		body.append_array("\r\n".to_utf8_buffer())
	body.append_array(("--%s--\r\n" % boundary).to_utf8_buffer())

	var headers := PackedStringArray()
	headers.append("Content-Type: multipart/form-data; boundary=%s" % boundary)
	headers.append("Accept: application/json")
	if not auth_token.is_empty():
		headers.append("Authorization: Bearer %s" % auth_token)

	var http := HTTPRequest.new()
	add_child(http)
	http.timeout = timeout if timeout > 0.0 else UPLOAD_REQUEST_TIMEOUT

	EvtBus.online_request_started.emit(url)
	# 第 3 个参数是 method，第 4 个是 PackedByteArray body（request() 的 body 是 String）
	var err := http.request_raw(url, headers, _method_to_http_client("POST"), body)
	if err != OK:
		EvtBus.online_request_finished.emit(url, false)
		http.queue_free()
		return {"ok": false, "status": 0, "data": null, "result_code": -1,
			"error": "request_failed: %d" % err}

	var resp = await http.request_completed
	var result_code = resp[0]
	var response_code = resp[1]
	var response_body: PackedByteArray = resp[3]
	http.queue_free()

	var data: Variant = null
	var json_parse_failed := false
	var raw_text := ""
	if response_body.size() > 0:
		raw_text = response_body.get_string_from_utf8()
		data = JSON.parse_string(raw_text)
		if data == null and not raw_text.strip_edges().is_empty():
			json_parse_failed = true
			GLogger.warning("Draft response is not valid JSON (status=%d, first 200 chars): %s" % [
				response_code, raw_text.substr(0, 200)], "NetMGR")

	var ok: bool = result_code == HTTPRequest.RESULT_SUCCESS \
		and response_code >= 200 and response_code < 300 and not json_parse_failed
	EvtBus.online_request_finished.emit(url, ok)
	return {
		"ok": ok,
		"status": response_code,
		"data": data,
		"result_code": result_code,
		"error": "" if ok else ("invalid_json_response" if json_parse_failed
			else "HTTP %d (result=%d)" % [response_code, result_code])
	}

## 配置变更：server_address 修改后立即生效（无需重启）
func _on_config_changed(key: String, _value: Variant) -> void:
	if key == "server_address":
		_load_server_url()
		# 换了服务器，旧地址上的存在性结论全部作废（否则同名 hash 在新服判据会错）
		invalidate_chart_remote_state("")
		if _online_mode_enabled:
			# 地址变化后重建连接（旧连接基于旧地址，需重新握手）
			_stop_all_timers()
			is_online = false
			_start_quick_retry()

## 查询在线模式是否启用（离线时不联网；供 UI 隐藏在线相关组件，静态便捷入口）
static func is_online_mode() -> bool:
	return instance != null and instance._online_mode_enabled

## 设置在线模式开关（由 Main.gd 在初始化和配置变更时调用）
func set_online_mode(enabled: bool) -> void:
	_online_mode_enabled = enabled
	if enabled:
		GLogger.info("Online mode enabled, starting quick retry", "NetMGR")
		_start_quick_retry()
	else:
		GLogger.info("Online mode disabled, stopping all network activity", "NetMGR")
		_stop_all_timers()
		is_online = false
		_latency_ms = -1
		_set_connect_state(ConnectState.OFFLINE_MODE)

## 挂起/恢复定时网络探测（可嵌套：各调用方登记自己的 reason，全部撤销才真正恢复）
## 用于打歌、播放器等对帧预算敏感的界面：健康检查成功会广播 online_status_changed，
## 触发资料/头像重新拉取并在主线程解码图片，造成掉帧。
## 注意：只停定时器，不拦截 _request —— 成绩上传等业务请求照常发出。
func set_activity_suspended(suspended: bool, reason: String = "default") -> void:
	if suspended:
		if _suspend_reasons.has(reason):
			return
		_suspend_reasons[reason] = true
		if _suspend_reasons.size() == 1:
			_stop_all_timers()
			GLogger.info("Network probing suspended (%s)" % reason, "NetMGR")
	else:
		if not _suspend_reasons.has(reason):
			return
		_suspend_reasons.erase(reason)
		if _suspend_reasons.is_empty():
			GLogger.info("Network probing resumed (%s)" % reason, "NetMGR")
			_resume_activity()

## 是否处于挂起状态
func is_activity_suspended() -> bool:
	return not _suspend_reasons.is_empty()

## 恢复时按当前状态重启对应定时器：已在线只需继续测延迟，未在线重新走快速尝试。
## 挂起期间 is_online / connect_state 保持不变，UI 不会闪烁。
func _resume_activity() -> void:
	if not _online_mode_enabled:
		return
	if is_online:
		_start_latency_timer()
	else:
		_start_quick_retry()

## 启动快速重试：启动时连续尝试 3 次（每次间隔 1 秒）
func _start_quick_retry() -> void:
	if is_activity_suspended():
		return
	_stop_all_timers()
	_quick_retry_count = 0
	_set_connect_state(ConnectState.CONNECTING)
	_quick_retry_timer = _create_timer(QUICK_RETRY_INTERVAL, false)
	_quick_retry_timer.timeout.connect(_on_quick_retry_timeout)
	# 立即触发第一次尝试，不必等待首个 interval
	_quick_retry_timer.start()


func _on_quick_retry_timeout() -> void:
	if _connecting or is_activity_suspended():
		return
	_quick_retry_count += 1
	var ok := await _do_connect_attempt()
	if not _online_mode_enabled or is_activity_suspended():
		return
	if ok:
		_stop_all_timers()
		_set_connect_state(ConnectState.ONLINE)
		_start_latency_timer()
		return
	# 失败
	if _quick_retry_count >= QUICK_RETRY_TIMES:
		# 快速尝试用尽，转入定期重试
		if _quick_retry_timer:
			_quick_retry_timer.queue_free()
			_quick_retry_timer = null
		_set_connect_state(ConnectState.FAILED)
		_start_periodic_retry()
	else:
		# 继续下一次快速尝试（保持 CONNECTING）
		_set_connect_state(ConnectState.CONNECTING)


## 启动定期重试：每隔 30 秒重试一次
func _start_periodic_retry() -> void:
	if is_activity_suspended():
		return
	if _periodic_retry_timer:
		return
	_periodic_retry_timer = _create_timer(PERIODIC_RETRY_INTERVAL, false)
	_periodic_retry_timer.timeout.connect(_on_periodic_retry_timeout)
	_periodic_retry_timer.start()


func _on_periodic_retry_timeout() -> void:
	if _connecting or is_activity_suspended():
		return
	_set_connect_state(ConnectState.CONNECTING)
	var ok := await _do_connect_attempt()
	if not _online_mode_enabled or is_activity_suspended():
		return
	if ok:
		# 连接成功，停止定期重试，启动延迟测量
		if _periodic_retry_timer:
			_periodic_retry_timer.queue_free()
			_periodic_retry_timer = null
		_set_connect_state(ConnectState.ONLINE)
		_start_latency_timer()
	else:
		# 仍然失败，继续定期重试
		_set_connect_state(ConnectState.FAILED)


## 启动延迟测量定时器：在线时每 10 秒测量一次延迟
func _start_latency_timer() -> void:
	if is_activity_suspended():
		return
	if _latency_timer:
		return
	_latency_timer = _create_timer(LATENCY_UPDATE_INTERVAL, false)
	_latency_timer.timeout.connect(_on_latency_timer_timeout)
	_latency_timer.start()


func _on_latency_timer_timeout() -> void:
	if _connecting or is_activity_suspended():
		return
	var ok := await _do_connect_attempt()
	if not _online_mode_enabled or is_activity_suspended():
		return
	if ok:
		# 仅更新延迟数值，状态保持 ONLINE
		EvtBus.online_state_changed.emit(connect_state, _latency_ms)
	else:
		# 连接丢失，停止延迟测量，转入定期重试
		if _latency_timer:
			_latency_timer.queue_free()
			_latency_timer = null
		_set_connect_state(ConnectState.FAILED)
		_start_periodic_retry()


## 执行一次连接尝试并测量延迟（私有）
## 返回 true 表示连接成功
func _do_connect_attempt() -> bool:
	if is_activity_suspended():
		return is_online
	_connecting = true
	var start := Time.get_ticks_msec()
	var result: Dictionary = await check_health()
	var elapsed := Time.get_ticks_msec() - start
	_connecting = false
	if result.get("ok", false):
		_latency_ms = elapsed
		is_online = true
		_last_fail_reason = ""
		_last_fail_detail = ""
		GLogger.info("Connection ok (latency=%dms, url=%s)" % [elapsed, server_url], "NetMGR")
	else:
		_latency_ms = -1
		is_online = false
		_last_fail_reason = _describe_failure(result)
		_last_fail_detail = "result=%d http=%d err=%s url=%s/api/health" % [
			int(result.get("result_code", -1)),
			int(result.get("status", 0)),
			str(result.get("error", "")),
			server_url,
		]
		# 玩家报障只能拿到这一行：失败原因必须落到日志，否则无法区分
		# DNS 污染 / 进程被拦 / 证书 / IPv6 超时 / 边缘质询 这几种完全不同的根因
		GLogger.warning("Connection failed: %s | %s" % [_last_fail_reason, _last_fail_detail], "NetMGR")
	return is_online

## 把 _request 的失败结果翻译成玩家能看懂、且足以判断根因的短句
func _describe_failure(result: Dictionary) -> String:
	var code := int(result.get("result_code", -1))
	var status := int(result.get("status", 0))
	var err := str(result.get("error", ""))
	match code:
		HTTPRequest.RESULT_CANT_RESOLVE:
			return "域名解析失败"
		HTTPRequest.RESULT_CANT_CONNECT:
			return "无法建立连接"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "安全连接握手失败"
		HTTPRequest.RESULT_TIMEOUT:
			return "连接超时"
		HTTPRequest.RESULT_NO_RESPONSE:
			return "服务器无响应"
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return "连接被中断"
		HTTPRequest.RESULT_REQUEST_FAILED:
			return "请求发送失败"
	if err == "invalid_json_response":
		return "服务器响应异常（HTTP %d）" % status
	if status == 403:
		return "服务器拒绝访问（403）"
	if status == 429:
		return "请求过于频繁（429）"
	if status >= 500:
		return "服务器错误（%d）" % status
	if status == 0:
		return "未知网络错误"
	return "服务器返回异常（HTTP %d）" % status


## 统一设置连接状态并发射信号
func _set_connect_state(state: ConnectState) -> void:
	connect_state = state
	_emit_online_status()
	# online_state_changed: 含连接状态枚举和延迟，供 LeftTopBtn 使用
	EvtBus.online_state_changed.emit(connect_state, _latency_ms)

## 广播在线状态，仅在布尔值真正翻转时发射。
## 原来每次 CONNECTING→ONLINE 都发一次，订阅方（PlayerInfoContent）会重新拉资料并重下、
## 重解码头像；服务器不稳定时每 10~30 秒来一轮，正好砸在打歌帧上。
func _emit_online_status() -> void:
	if is_online == _last_emitted_online:
		return
	_last_emitted_online = is_online
	EvtBus.online_status_changed.emit(is_online, "")


## 停止并销毁所有 Timer
func _stop_all_timers() -> void:
	if _quick_retry_timer:
		_quick_retry_timer.queue_free()
		_quick_retry_timer = null
	if _periodic_retry_timer:
		_periodic_retry_timer.queue_free()
		_periodic_retry_timer = null
	if _latency_timer:
		_latency_timer.queue_free()
		_latency_timer = null
	_connecting = false


## 创建 Timer 辅助方法
func _create_timer(interval: float, one_shot: bool) -> Timer:
	var timer := Timer.new()
	timer.wait_time = interval
	timer.one_shot = one_shot
	timer.autostart = false
	add_child(timer)
	return timer

## 健康检查：GET /api/health
## 返回 { ok, status, data, error }
func check_health() -> Dictionary:
	var url = "%s/api/health" % server_url
	return await _request("GET", url, {})

## 通用请求方法
## method: "GET"/"POST"/"PUT"/"PATCH"/"DELETE"
## url: 完整 URL
## body: Dictionary（自动 JSON 序列化）或 null
## headers: 额外请求头
## auth_token: 可选 Bearer token
## timeout: 自定义超时（秒），<=0 时用 REQUEST_TIMEOUT
## 返回：{ "ok": bool, "status": int, "data": Variant, "error": String }
func _request(method: String, url: String, body: Variant, headers: PackedStringArray = PackedStringArray(), auth_token: String = "", timeout: float = 0.0) -> Dictionary:
	var http = HTTPRequest.new()
	add_child(http)
	http.timeout = timeout if timeout > 0.0 else REQUEST_TIMEOUT

	var all_headers = headers.duplicate()
	all_headers.append("Content-Type: application/json")
	if not auth_token.is_empty():
		all_headers.append("Authorization: Bearer %s" % auth_token)

	var body_str = ""
	if body is Dictionary and not body.is_empty():
		body_str = JSON.stringify(body)

	EvtBus.online_request_started.emit(url)

	var err = http.request(url, all_headers, _method_to_http_client(method), body_str)
	if err != OK:
		EvtBus.online_request_finished.emit(url, false)
		http.queue_free()
		# result_code 用 -1 表示「没能发起请求」，与 HTTPRequest.Result 的取值区间区分开
		return { "ok": false, "status": 0, "data": null, "result_code": -1, "error": "request_failed: %d" % err }

	var resp = await http.request_completed
	var result_code = resp[0]
	var response_code = resp[1]
	var response_body = resp[3]

	http.queue_free()

	var data: Variant = null
	var json_parse_failed := false
	var raw_text := ""
	if response_body is PackedByteArray and response_body.size() > 0:
		raw_text = response_body.get_string_from_utf8()
		data = JSON.parse_string(raw_text)
		if data == null:
			json_parse_failed = true
			GLogger.warning("Response is not valid JSON (status=%d, first 200 chars): %s" % [response_code, raw_text.substr(0, 200)], "NetMGR")

	var ok = result_code == HTTPRequest.RESULT_SUCCESS and response_code >= 200 and response_code < 300 and not json_parse_failed
	EvtBus.online_request_finished.emit(url, ok)
	return {
		"ok": ok,
		"status": response_code,
		"data": data,
		"result_code": result_code,
		"error": "" if ok else ("invalid_json_response" if json_parse_failed else "HTTP %d (result=%d)" % [response_code, result_code])
	}

func _method_to_http_client(method: String) -> int:
	match method:
		"GET": return HTTPClient.METHOD_GET
		"POST": return HTTPClient.METHOD_POST
		"PUT": return HTTPClient.METHOD_PUT
		"PATCH": return HTTPClient.METHOD_PATCH
		"DELETE": return HTTPClient.METHOD_DELETE
		_: return HTTPClient.METHOD_GET

## 手动重试（设置页「网络连接」项的按钮）
## 与自动重试的区别：自动流程是「3 次快速尝试 → 30 秒定期重试」，玩家点按钮要的是立刻有反馈，
## 因此这里先切到 CONNECTING（界面马上变「连接中…」），马上发一次探测，再按结果落到
## ONLINE（转延迟测量）或 FAILED（转定期重试）——后续状态与自动流程保持一致，不会互相打架。
## 返回值：当前是否在线。在线模式关闭 / 已有探测在途时直接返回，不叠加请求。
func retry_now() -> bool:
	if not _online_mode_enabled or _connecting:
		return is_online
	if is_activity_suspended():
		GLogger.info("Manual retry ignored: network probing suspended", "NetMGR")
		return is_online
	_stop_all_timers()
	_set_connect_state(ConnectState.CONNECTING)
	var ok := await _do_connect_attempt()
	if not _online_mode_enabled:
		return is_online
	if ok:
		_set_connect_state(ConnectState.ONLINE)
		_start_latency_timer()
	else:
		_set_connect_state(ConnectState.FAILED)
		_start_periodic_retry()
	return ok

## 手动测试连接
## 更新 is_online 状态并发射信号
func test_connection() -> bool:
	var ok := await _do_connect_attempt()
	if _online_mode_enabled:
		if ok:
			# 手动测试成功，同步状态
			if connect_state != ConnectState.ONLINE:
				_stop_all_timers()
				_set_connect_state(ConnectState.ONLINE)
				_start_latency_timer()
		else:
			# 手动测试失败，若当前不是 ONLINE 则保持原状态
			if connect_state == ConnectState.ONLINE:
				# 在线状态下突然失败，转入重试
				_stop_all_timers()
				_set_connect_state(ConnectState.FAILED)
				_start_periodic_retry()
	else:
		# 在线模式关闭时，仅发射兼容信号（同样只在翻转时发）
		_emit_online_status()
	return is_online

func _exit_tree() -> void:
	_stop_all_timers()

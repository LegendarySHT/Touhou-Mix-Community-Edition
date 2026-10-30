extends Node
class_name NetManager

## 在线管理器：HTTP 请求封装、服务端连接管理、延迟测量
## 通过 Main.gd 手动 add_child，使用 NetManager.instance 访问

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

## 配置地址无效时的回退地址（开发默认，与 config.ini 默认一致）
const FALLBACK_SERVER_URL: String = "http://localhost:5000"

## 当前是否在线（服务端可达）
var is_online: bool = false

## 当前连接状态
var connect_state: ConnectState = ConnectState.OFFLINE_MODE

## 最近一次延迟（毫秒），-1 表示未知
var _latency_ms: int = -1

## 读取最近一次连接延迟（毫秒；-1 = 未知/未连接，外部只读统一走此方法，TMX-019）
func get_latency_ms() -> int:
	return _latency_ms

## online_mode 开关
var _online_mode_enabled: bool = false

## 请求超时（秒）
const REQUEST_TIMEOUT: float = 10.0

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
	var addr = ConfigManager.instance.get_string("server_address", "thmix.org")
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

## 配置变更：server_address 修改后立即生效（无需重启）
func _on_config_changed(key: String, _value: Variant) -> void:
	if key == "server_address":
		_load_server_url()
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
	var result = await check_health()
	var elapsed := Time.get_ticks_msec() - start
	_connecting = false
	if result.get("ok", false):
		_latency_ms = elapsed
		is_online = true
	else:
		_latency_ms = -1
		is_online = false
	GLogger.info("Connection attempt: %s (latency=%dms)" % ["ok" if is_online else "fail", _latency_ms], "NetMGR")
	return is_online


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
## 返回：{ "ok": bool, "status": int, "data": Variant, "error": String }
func _request(method: String, url: String, body: Variant, headers: PackedStringArray = PackedStringArray(), auth_token: String = "") -> Dictionary:
	var http = HTTPRequest.new()
	add_child(http)
	http.timeout = REQUEST_TIMEOUT

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
		return { "ok": false, "status": 0, "data": null, "error": "request_failed: %d" % err }

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

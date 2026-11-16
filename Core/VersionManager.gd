## 版本与更新历史管理器（按需单例 ServiceHub.version）
##
## 不是 autoload：只有「关于」页读版本号与更新历史，没必要占启动时的实例化与 JSON 解析。
## 首次访问 .instance 时由 ServiceHub 创建并挂到懒服务挂载点（见 Services/ServiceHub.gd）。
##
## 单一事实来源：游戏当前版本 + 更新历史都来自 Resources/Config/version_history.json。
## 其它地方（关于页版本号、导出配置里的版本号）一律从这里或这个 JSON 派生，
## 改版本只改这一个 JSON 文件即可（见 tools/sync_version.py 与 git pre-commit 钩子）。
##
## 设计为「可联网扩展」：
##   - 更新历史 entries 是自由结构字典，本地历史保持离线可用。
##   - 远程更新清单由后端只读接口提供（schema=1，按 platforms.windows / platforms.android 区分平台），
##     二进制安装包放在 GitHub Releases，客户端只向本服务要几 KB 的清单，避免占用服务器上行带宽。

class_name VersionManager
extends Node

## ServiceHub 服务声明：id 与依赖，注册时自动读取（见 Services/ServiceHub.gd）
const SERVICE_ID := "VersionManager"
const SERVICE_DEPS := []

# ============ 按需单例 ============

## 首次访问时由 ServiceHub 创建并挂到懒挂载点
static var instance: VersionManager:
	get:
		if _instance == null:
			_instance = ServiceHub.service("VersionManager") as VersionManager
		return _instance

static var _instance: VersionManager = null

# ============ 常量 ============
const HISTORY_PATH := "res://Resources/Config/version_history.json"

## 解析不到历史文件时的兜底版本（避免关于页 / 导出全空）
const FALLBACK_VERSION := "1.0.0.0"
const FALLBACK_BUILD := 1

# ============ 内部状态 ============
var _data: Dictionary = {}
var _loaded: bool = false

## 远程更新清单地址覆盖值。为空时读 config.ini 的 update_manifest_url，
## 再为空则用官方地址。刻意不跟随用户可改的 server_address：
## 社区服务器可以提供服务，但更新信任源不能跟着服务器地址漂移。
var _manifest_url: String = ""

## idle / checking。同一时刻只允许一个检查请求，防止连点导致回调错乱。
var _check_state: String = "idle"
## 最近一次检查结果（供关于页重新进入时回显，不参与版本比较）
var _last_result: Dictionary = {}

# ============ 信号 ============
## 发现新版本时发射（info 含 latest / current / has_update 等）
signal update_available(info: Dictionary)
## 一次检查结束（无论有无更新 / 是否失败）都发射，供 UI 收尾（关 loading、显示结果）
signal update_check_finished(result: Dictionary)

func _ready() -> void:
	add_to_group("singleton")
	ensure_loaded()

# ============ 加载 ============
func ensure_loaded() -> void:
	if _loaded:
		return
	if ServiceHub.config != null:
		_data = ServiceHub.config.load_json_file(HISTORY_PATH)
	else:
		_data = {}
	_loaded = true
	if _data.is_empty():
		GLogger.warning("版本历史文件缺失或解析失败: %s（将使用兜底版本）" % HISTORY_PATH, "VerMGR")

# ============ 当前版本（展示用） ============
## 纯版本号，如 "1.0.0.645"（不含 v 前缀）
func get_version_string() -> String:
	ensure_loaded()
	return _data.get("current", FALLBACK_VERSION)

## 关于页展示用的带 v 前缀版本号，如 "v1.0.0.645"
func get_version_label() -> String:
	return "v" + get_version_string()

## Android version/name 用（与 get_version_string 相同，语义字段名便于阅读）
func get_version_name() -> String:
	return get_version_string()

## 构建号（Android version/code / Windows file_version 末段）。优先取 current 对应 entry 的 build，
## 否则取 entries[0].build，再否则兜底 1。
func get_build_number() -> int:
	ensure_loaded()
	var cur := get_version_string()
	var entry := get_entry(cur)
	if not entry.is_empty() and entry.has("build"):
		return int(entry["build"])
	var entries: Array = _data.get("entries", [])
	if not entries.is_empty() and entries[0].has("build"):
		return int(entries[0]["build"])
	return FALLBACK_BUILD

# ============ 历史 ============
## 返回更新历史（默认最新在前）。每条是一个字典，结构见 version_history.json。
## 结构可自由扩展：除内置字段外多出的字段（download_url / mandatory / size_mb …）原样保留。
func get_history(newest_first: bool = true) -> Array:
	ensure_loaded()
	var entries: Array = _data.get("entries", [])
	if not (entries is Array):
		return []
	if newest_first:
		return entries.duplicate()
	var reversed: Array = entries.duplicate()
	reversed.reverse()
	return reversed

## 按版本号取某条历史；找不到返回空字典
func get_entry(version: String) -> Dictionary:
	ensure_loaded()
	for e in _data.get("entries", []):
		if e is Dictionary and str(e.get("version", "")) == str(version):
			return e
	return {}

## 当前安装版本对应的历史条目
func get_current_entry() -> Dictionary:
	return get_entry(get_version_string())

## 历史里最新的一条（通常等于当前版本）
func get_latest_entry() -> Dictionary:
	ensure_loaded()
	var entries: Array = _data.get("entries", [])
	if entries.is_empty():
		return {}
	return entries[0] if entries[0] is Dictionary else {}

# ============ 版本号工具 ============
## 把 "1.0.0.645" 解析为 {major, minor, patch, build}
static func parse_version(ver: String) -> Dictionary:
	var parts := str(ver).strip_edges().split(".")
	var nums := [0, 0, 0, 0]
	for i in mini(parts.size(), 4):
		nums[i] = int(parts[i])
	return {"major": nums[0], "minor": nums[1], "patch": nums[2], "build": nums[3]}

## 比较版本号 a 与 b：a>b 返回 1，相等返回 0，a<b 返回 -1（按 主.次.修.构建 字典序）
static func compare_versions(a: String, b: String) -> int:
	var pa := parse_version(a)
	var pb := parse_version(b)
	for key in ["major", "minor", "patch", "build"]:
		if pa[key] > pb[key]:
			return 1
		if pa[key] < pb[key]:
			return -1
	return 0

## 远程版本是否比当前更新
func is_newer(remote_version: String) -> bool:
	return compare_versions(remote_version, get_version_string()) > 0

# ============ 联网更新 ============
## 官方更新清单地址（后端只读接口，几 KB JSON）。自建镜像/本地调试可用
## config.ini 的 update_manifest_url 覆盖；不读 server_address。
const DEFAULT_UPDATE_MANIFEST_URL := "https://thmixce.org/api/update/beta"
const UPDATE_TIMEOUT_SEC := 8.0
const HTTPS_PREFIX := "https://"

func set_update_manifest_url(url: String) -> void:
	_manifest_url = url.strip_edges()

func get_update_manifest_url() -> String:
	if not _manifest_url.is_empty():
		return _manifest_url
	if ServiceHub.config != null:
		return ServiceHub.config.get_string("update_manifest_url", DEFAULT_UPDATE_MANIFEST_URL).strip_edges()
	return DEFAULT_UPDATE_MANIFEST_URL

func is_checking() -> bool:
	return _check_state == "checking"

## 最近一次检查结果（空字典 = 本次会话还没检查过）。UI 重新进入关于页时用它回显。
func get_last_result() -> Dictionary:
	return _last_result.duplicate(true)

## 当前运行平台在清单里的键名（与后端 platforms 的键一致）
static func get_platform_key() -> String:
	match OS.get_name():
		"Windows":
			return "windows"
		"Android":
			return "android"
		"iOS":
			return "ios"
		"macOS":
			return "macos"
		"Linux":
			return "linux"
		_:
			return OS.get_name().to_lower()

## 异步检查更新（结果同时通过 update_check_finished 信号广播，调用方也可 await 取返回值）。
## 返回结果字典：
##   { ok, has_update, forced, current, current_build, latest, latest_build,
##     latest_entry(平台条目，已过滤非法链接), platform, reason(失败/无平台时), checked_at }
func check_for_updates() -> Dictionary:
	if is_checking():
		return {"ok": false, "has_update": false, "reason": "busy", "current": get_version_string()}

	var url := get_update_manifest_url()
	if url.is_empty():
		return _finish_check({"ok": false, "has_update": false, "reason": "disabled",
			"current": get_version_string()})
	if not url.begins_with(HTTPS_PREFIX):
		# 只允许 HTTPS：清单与下载地址都可能被中间人替换，明文 HTTP 直接拒绝。
		return _finish_check({"ok": false, "has_update": false, "reason": "invalid_manifest_url",
			"current": get_version_string()})

	_check_state = "checking"
	var http := HTTPRequest.new()
	http.timeout = UPDATE_TIMEOUT_SEC
	add_child(http)
	var err := http.request(url)
	if err != OK:
		http.queue_free()
		return _finish_check({"ok": false, "has_update": false,
			"reason": "request_failed:%d" % err, "current": get_version_string()})

	var resp: Array = await http.request_completed
	http.queue_free()
	return _finish_check(_evaluate_response(resp))

## 收尾：落状态、记录最近结果、按需发信号
func _finish_check(result: Dictionary) -> Dictionary:
	_check_state = "idle"
	result["checked_at"] = Time.get_datetime_string_from_system(false, true)
	_last_result = result.duplicate(true)
	if result.get("has_update", false):
		update_available.emit(result)
	update_check_finished.emit(result)
	return result

## 把 HTTPRequest 的 4 元返回转成结果字典
func _evaluate_response(resp: Array) -> Dictionary:
	var base := {"current": get_version_string(), "current_build": get_build_number()}
	var result_code: int = int(resp[0])
	var response_code: int = int(resp[1])
	var body: PackedByteArray = resp[3]
	if result_code != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		var http_fail := base.duplicate()
		http_fail["ok"] = false
		http_fail["has_update"] = false
		http_fail["reason"] = "HTTP %d (result=%d)" % [response_code, result_code]
		return http_fail

	var remote: Variant = JSON.parse_string(body.get_string_from_utf8())
	if remote == null or not (remote is Dictionary):
		var json_fail := base.duplicate()
		json_fail["ok"] = false
		json_fail["has_update"] = false
		json_fail["reason"] = "invalid_json"
		return json_fail
	var remote_dict: Dictionary = remote
	return _evaluate_manifest(remote_dict, base)

## 按后端清单 schema（schema=1，platforms.{windows,android,...}）解析并比较版本
func _evaluate_manifest(remote: Dictionary, base: Dictionary) -> Dictionary:
	if int(remote.get("schema", 0)) <= 0:
		return _manifest_error(base, "manifest_missing_schema")

	var platforms: Variant = remote.get("platforms", null)
	if not (platforms is Dictionary):
		return _manifest_error(base, "manifest_missing_platforms")

	var platform_key := get_platform_key()
	var entry: Variant = platforms.get(platform_key, null)
	if not (entry is Dictionary):
		# 清单合法但没收录当前平台：属于正常状态，不当作失败
		var no_platform := base.duplicate()
		no_platform["ok"] = true
		no_platform["has_update"] = false
		no_platform["platform"] = platform_key
		no_platform["reason"] = "platform_not_listed"
		return no_platform
	var entry_dict: Dictionary = entry

	var latest := str(entry_dict.get("version", "")).strip_edges()
	var latest_build := int(entry_dict.get("build", 0))
	if latest.is_empty() or latest_build <= 0:
		return _manifest_error(base, "manifest_invalid_entry")

	var local_build: int = int(base["current_build"])
	var has_update := latest_build > local_build
	var min_supported_build := int(entry_dict.get("min_supported_build", 0))
	var result := base.duplicate()
	result["ok"] = true
	result["has_update"] = has_update
	# 当前版本已低于最低支持版本时标记为强制更新（只在确实有新版本可升时成立）
	result["forced"] = has_update and min_supported_build > 0 and local_build < min_supported_build
	result["latest"] = latest
	result["latest_build"] = latest_build
	result["platform"] = platform_key
	result["latest_entry"] = _sanitize_entry(entry_dict)
	return result

func _manifest_error(base: Dictionary, reason: String) -> Dictionary:
	var result := base.duplicate()
	result["ok"] = false
	result["has_update"] = false
	result["reason"] = reason
	return result

## 只保留可安全展示/打开的内容：下载链接与镜像必须是 HTTPS
func _sanitize_entry(entry: Dictionary) -> Dictionary:
	var out := entry.duplicate(true)
	var url := str(out.get("url", "")).strip_edges()
	out["url"] = url if url.begins_with(HTTPS_PREFIX) else ""

	var mirrors := []
	var raw_mirrors: Variant = out.get("mirrors", [])
	if raw_mirrors is Array:
		for m in raw_mirrors:
			var mirror := str(m).strip_edges()
			if mirror.begins_with(HTTPS_PREFIX):
				mirrors.append(mirror)
	out["mirrors"] = mirrors

	var changes := []
	var raw_changes: Variant = out.get("changes", [])
	if raw_changes is Array:
		for c in raw_changes:
			var line := str(c).strip_edges()
			if not line.is_empty():
				changes.append(line)
	out["changes"] = changes

	out["sha256"] = str(out.get("sha256", "")).strip_edges().to_lower()
	return out

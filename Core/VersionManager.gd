## 版本与更新历史管理器（按需单例 ServiceHub.version）
##
## 不是 autoload：只有「关于」页读版本号与更新历史，没必要占启动时的实例化与 JSON 解析。
## 首次访问 .instance 时由 ServiceHub 创建并挂到懒服务挂载点（见 Services/ServiceHub.gd）。
##
## 当前版本号的事实来源是 Resources/Config/version_history.json 的 current（导出配置里的版本号、
## Android versionName/versionCode、Windows 文件版本都从这里派生，见 tools/sync_version.py）。
## 该文件只保留 current，不再内嵌历史条目——版本历史只有远端一个来源：
##   - 远端：后端从 GitHub Releases 派生出的清单里的 history[]，发一次 Release 自动多一条。
##   - 缓存：最近一次成功拉取的 history[] 写入 OnlineContentCache（meta 命名空间），
##     冷启动/断网时先展示这份快照，由下一次联网结果覆盖（stale-while-revalidate）。
##   - 两者都没有时，关于页明确显示「未能获取版本信息」，不再用内置的假条目兜底。
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

## 版本历史的本地快照：走 OnlineContentCache 的 meta 命名空间。
## 隔离键用清单地址（而不是 server_address）——更新信任源不随自建服务器漂移，
## 因此换服务器后仍能看到上次同步的版本历史；换渠道（beta/stable）则各存各的。
const HISTORY_CACHE_NAMESPACE := OnlineContentCache.DIR_META
const HISTORY_CACHE_KEY := "version_history"
const HISTORY_CACHE_SCOPE_PREFIX := "update_manifest_"

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

## 版本历史条目（后端从 GitHub Releases 派生，或来自本地缓存快照）。
## 为空表示「本次既没联网拿到、也没有缓存」，关于页据此显示未获取提示。
var _remote_history: Array = []
## 历史来源："network" 本次会话联网拿到 / "cache" 读自本地快照 / "" 都没有
var _history_source: String = ""
## 历史对应的快照时间（unix 秒，0 = 未知）
var _history_cached_at: int = 0
## 是否已经尝试过读缓存（只读一次，失败也不反复读盘）
var _cache_loaded: bool = false

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
		GLogger.warning("版本文件缺失或解析失败: %s（关于页将显示版本信息未获取）" % HISTORY_PATH, "VerMGR")

# ============ 当前版本（展示用） ============
## 纯版本号，如 "1.0.0.645"（不含 v 前缀）。读不到或格式非法时返回空串，
## 由 UI 显示「版本信息未获取」——不再编一个 0.0.0 / 645 这样的假版本号。
func get_version_string() -> String:
	ensure_loaded()
	var current := str(_data.get("current", "")).strip_edges()
	return current if _is_valid_version(current) else ""

## 关于页展示用的带 v 前缀版本号，如 "v1.0.0.645"；未知版本返回空串
func get_version_label() -> String:
	var version := get_version_string()
	return "" if version.is_empty() else "v" + version

## Android version/name 用（与 get_version_string 相同，语义字段名便于阅读）
func get_version_name() -> String:
	return get_version_string()

## 构建号（Android version/code / Windows file_version 末段）。
## 优先取本地版本号第 4 段（build = git 提交数，由 sync_version.py 写入，最可信）；
## 版本号不足 4 段时才回退到历史条目里的 build（远端数据只作补充来源）。
func get_build_number() -> int:
	ensure_loaded()
	var parts := get_version_string().split(".")
	if parts.size() >= 4 and str(parts[3]).is_valid_int():
		return int(parts[3])
	var entry := get_current_entry()
	if not entry.is_empty() and entry.has("build"):
		return int(entry["build"])
	return 0

## 版本号合法性：2~4 段纯数字（"1.0.0.645" / "1.0"）
static func _is_valid_version(version: String) -> bool:
	if version.is_empty():
		return false
	var parts := version.split(".")
	if parts.size() < 2 or parts.size() > 4:
		return false
	for part in parts:
		if not str(part).is_valid_int():
			return false
	return true

# ============ 历史 ============
## 返回更新历史（默认最新在前）。来源只两种：本次联网拿到的，或上次成功拉取的本地快照；
## 两者都没有时返回空数组，由关于页显示「未能获取版本信息」。
## 条目结构：version/build/date/channel/title/changes/download_url（后端已对齐）。
func get_history(newest_first: bool = true) -> Array:
	_ensure_history_cache()
	var entries: Array = _remote_history.duplicate(true)
	if newest_first:
		return entries
	entries.reverse()
	return entries

## 本次会话是否已经联网拿到过历史（决定进入关于页要不要静默补拉一次；
## 只有缓存也算「未刷新」，仍然要拉）。
func has_fresh_history() -> bool:
	_ensure_history_cache()
	return _history_source == "network"

## 是否有一份可展示的历史（联网或缓存都算）
func has_remote_history() -> bool:
	_ensure_history_cache()
	return not _remote_history.is_empty()

## 历史是否来自本地缓存快照（关于页据此标注数据时效）
func history_is_cached() -> bool:
	_ensure_history_cache()
	return _history_source == "cache"

## 历史快照对应的 unix 时间（0 = 未知）
func get_history_cached_at() -> int:
	_ensure_history_cache()
	return _history_cached_at

## 记下远端清单里的历史，并写入本地快照。结构不对就整段忽略。
func _capture_remote_history(remote: Dictionary) -> void:
	var entries := _sanitize_history(remote.get("history", []))
	if entries.is_empty():
		return
	_remote_history = entries
	_history_source = "network"
	_history_cached_at = int(Time.get_unix_time_from_system())
	# 已有更新的数据，不必再读旧快照（也避免之后被旧缓存覆盖）
	_cache_loaded = true
	_write_history_cache(entries, _history_cached_at)

## 过滤掉结构不对的历史条目（必须有非空 version）
func _sanitize_history(raw: Variant) -> Array:
	if not (raw is Array):
		return []
	var entries: Array = []
	for item in raw:
		if item is Dictionary and not str(item.get("version", "")).strip_edges().is_empty():
			entries.append(item)
	return entries

# ============ 历史缓存（OnlineContentCache / meta） ============

## 缓存隔离键：清单地址哈希。换渠道不会串，换服务器照旧能读。
func _history_cache_scope() -> String:
	return HISTORY_CACHE_SCOPE_PREFIX + get_update_manifest_url().md5_text().substr(0, 12)

## 首次访问时尝试读本地快照；依赖未就绪则不置位，下次再试。
func _ensure_history_cache() -> void:
	if _cache_loaded:
		return
	if ServiceHub.config == null:
		return
	_cache_loaded = true
	var entry := OnlineContentCache.read(
		HISTORY_CACHE_NAMESPACE, HISTORY_CACHE_KEY, false, _history_cache_scope())
	if entry.is_empty():
		return
	var payload: Variant = OnlineContentCache.payload_of(entry, null)
	if not (payload is Dictionary):
		return
	var payload_dict: Dictionary = payload
	var entries := _sanitize_history(payload_dict.get("history", []))
	if entries.is_empty():
		return
	_remote_history = entries
	_history_source = "cache"
	_history_cached_at = int(payload_dict.get("fetched_at", entry.get("fetched_at", 0)))

func _write_history_cache(entries: Array, cached_at: int) -> void:
	OnlineContentCache.write(
		HISTORY_CACHE_NAMESPACE,
		HISTORY_CACHE_KEY,
		{
			"fetched_at": cached_at,
			"manifest_url": get_update_manifest_url(),
			"history": entries,
		},
		false,
		_history_cache_scope())

## 按版本号取某条历史；找不到返回空字典
func get_entry(version: String) -> Dictionary:
	for e in get_history(true):
		if e is Dictionary and str(e.get("version", "")) == str(version):
			return e
	return {}

## 当前安装版本对应的历史条目（当前版本号未知时返回空字典）
func get_current_entry() -> Dictionary:
	var version := get_version_string()
	return {} if version.is_empty() else get_entry(version)

## 历史里最新的一条
func get_latest_entry() -> Dictionary:
	var entries: Array = get_history(true)
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

	# 历史列表与当前平台无关：先收下历史，即使后面的平台校验失败也不白跑一趟
	_capture_remote_history(remote)

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

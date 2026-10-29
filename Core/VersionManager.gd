## 版本与更新历史管理器（单例 / 自动加载 VerMGR）
##
## 单一事实来源：游戏当前版本 + 更新历史都来自 Resources/Config/version_history.json。
## 其它地方（关于页版本号、导出配置里的版本号）一律从这里或这个 JSON 派生，
## 改版本只改这一个 JSON 文件即可（见 tools/sync_version.py 与 git pre-commit 钩子）。
##
## 设计为「可联网扩展」：
##   - 更新历史 entries 是自由结构字典，未来可直接从服务端拉取同名结构。
##   - check_for_updates() 已留出异步联网检查骨架（默认未配置 manifest_url 时直接返回，
##     不会触发任何网络请求），接入后端时只需 set_update_manifest_url() 即可。

class_name VersionManager
extends Node

# ============ 常量 ============
const HISTORY_PATH := "res://Resources/Config/version_history.json"

## 解析不到历史文件时的兜底版本（避免关于页 / 导出全空）
const FALLBACK_VERSION := "1.0.0.0"
const FALLBACK_BUILD := 1

# ============ 内部状态 ============
var _data: Dictionary = {}
var _loaded: bool = false

## 远程更新清单地址。留空 = 不联网（check_for_updates 直接返回 disabled）。
## 接入后端时调用 set_update_manifest_url("https://.../update_manifest.json") 即可，
## 远程 JSON 结构与本地 version_history.json 一致（至少含 current / entries[0].version）。
var _manifest_url: String = ""

# ============ 信号 ============
## 发现新版本时发射（info 含 latest / current / has_update 等）
signal update_available(info: Dictionary)
## 一次检查结束（无论有无更新 / 是否失败）都发射，供 UI 收尾（关 loading、显示结果）
signal update_check_finished(result: Dictionary)

func _ready() -> void:
	add_to_group("singletons")
	ensure_loaded()

# ============ 加载 ============
func ensure_loaded() -> void:
	if _loaded:
		return
	if ConfigManager != null:
		_data = ConfigManager.instance.load_json_file(HISTORY_PATH)
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

# ============ 联网更新（骨架，默认关闭） ============
func set_update_manifest_url(url: String) -> void:
	_manifest_url = url.strip_edges()

func get_update_manifest_url() -> String:
	return _manifest_url

## 异步检查更新。
## 未配置 manifest_url → 立即返回 {ok:false, reason:"disabled"}，不发起任何网络请求。
## 已配置 → GET 远程清单（与本地同构），与当前版本比对，发射 update_available / update_check_finished。
## 返回结果字典（调用方也可用 await 拿结果）：
##   { ok, has_update, current, latest, latest_entry(若有), reason(若失败) }
func check_for_updates() -> Dictionary:
	if _manifest_url.is_empty():
		var r := {"ok": false, "has_update": false, "reason": "disabled", "current": get_version_string()}
		update_check_finished.emit(r)
		return r
	var http := HTTPRequest.new()
	add_child(http)
	http.timeout = 10.0
	var err := http.request(_manifest_url)
	if err != OK:
		http.queue_free()
		var r := {"ok": false, "has_update": false, "reason": "request_failed:%d" % err, "current": get_version_string()}
		update_check_finished.emit(r)
		return r
	var resp = await http.request_completed
	http.queue_free()
	var result_code: int = resp[0]
	var response_code: int = resp[1]
	var body: PackedByteArray = resp[3]
	if result_code != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		var r := {"ok": false, "has_update": false, "reason": "HTTP %d (result=%d)" % [response_code, result_code], "current": get_version_string()}
		update_check_finished.emit(r)
		return r
	var text := body.get_string_from_utf8()
	var remote: Variant = JSON.parse_string(text)
	if remote == null or not (remote is Dictionary):
		var r := {"ok": false, "has_update": false, "reason": "invalid_json", "current": get_version_string()}
		update_check_finished.emit(r)
		return r
	var remote_current: String = str(remote.get("current", ""))
	var remote_entries: Array = remote.get("entries", [])
	if not remote_current.is_empty() and not remote_entries.is_empty():
		remote_current = str(remote_entries[0].get("version", remote_current))
	var has_update := not remote_current.is_empty() and is_newer(remote_current)
	var r := {
		"ok": true,
		"has_update": has_update,
		"current": get_version_string(),
		"latest": remote_current,
	}
	if has_update and not remote_entries.is_empty():
		r["latest_entry"] = remote_entries[0]
	if has_update:
		update_available.emit(r)
	update_check_finished.emit(r)
	return r

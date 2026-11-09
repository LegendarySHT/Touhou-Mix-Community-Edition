## 在线内容缓存（stale-while-revalidate 的本地快照层）
##
## 职责单一：只负责「按 key 存/取一份在线响应的快照」，不发起任何网络请求、
## 不参与视图渲染。各视图保持原有在线请求不变，自行决定：
##   ① 进入时 read() → 命中就立刻渲染；
##   ② 照常 await 原来的在线请求；
##   ③ ok 且代次校验通过后覆盖渲染，并 write() 回写；失败则保留 ① 的内容。
##
## 开关 cache_online_content 关闭时 read() 恒为空、write() 恒不落盘，
## 因此调用方只要把「读缓存 / 写缓存 / 失败时保留缓存」三处都包进 is_enabled()，
## 就能保证与未实装本功能前的行为逐字节等价。
##
## 隔离：每条记录带 server（server_address 短哈希）与 user（账号短哈希）。
## 账号相关内容（myReaction/likedByMe/canInteract/totalPp/globalRank/历史成绩等）
## 必须传 account_scoped=true，读取时校验 user，切账号或登出即自然失效。
##
## 不做 TTL：SWR 语义下在线成功就会覆盖，缓存永不过期；fetched_at 只作为
## 快照元信息保留，容量淘汰按文件 mtime 进行。
extends RefCounted
class_name OnlineContentCache

const SCHEMA_VERSION := 1
const MAX_CACHE_BYTES := 32 * 1024 * 1024
const MAX_CACHE_FILES := 600
const TRIM_RATIO := 0.9
const HOUSEKEEPING_INTERVAL := 32

const DIR_CHARTS := "charts"
const DIR_STORE := "store"
const DIR_USERS := "users"
const NAMESPACES := [DIR_CHARTS, DIR_STORE, DIR_USERS]

static var _housekeeping_done: bool = false
static var _write_counter: int = 0


# ============ 开关 ============

## 主开关：默认开启。每次实时读取配置，不做静态缓存，保证设置页关闭后立即失效。
static func is_enabled() -> bool:
	return ConfigManager.instance.get_int("cache_online_content", 1) == 1


## 二级开关：线上模式关闭时是否仍显示缓存。默认 0（保持原有离线表现）。
## 开启只显示本地缓存，绝不发起联网请求。
static func show_when_offline() -> bool:
	return is_enabled() and ConfigManager.instance.get_int("cache_show_when_offline", 0) == 1


# ============ 读 / 写 ============

## 读取快照。未开启、无记录、已损坏、schema 或 server/user 不匹配一律返回空字典。
## 命中时返回 {"payload": Variant, "fetched_at": int}；payload 本身可以是空字典/空数组。
static func read(ns: String, key: String, account_scoped: bool = false) -> Dictionary:
	if not is_enabled() or key.is_empty():
		return {}
	var expected_user := _user_key() if account_scoped else ""
	if account_scoped and expected_user.is_empty():
		return {}
	_ensure_housekeeping()
	var path := _file_path(ns, key, expected_user)
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		return {}
	var rec: Dictionary = parsed
	if int(rec.get("v", 0)) != SCHEMA_VERSION:
		return {}
	if str(rec.get("server", "")) != _server_key():
		return {}
	if str(rec.get("user", "")) != expected_user:
		return {}
	if not rec.has("payload"):
		return {}
	return {
		"payload": rec.get("payload"),
		"fetched_at": int(rec.get("fetched_at", 0)),
	}


## 写入快照。只应由「在线请求成功且结构合法且代次校验通过」的路径调用。
static func write(ns: String, key: String, payload: Variant, account_scoped: bool = false) -> void:
	if not is_enabled() or key.is_empty():
		return
	var user := _user_key() if account_scoped else ""
	if account_scoped and user.is_empty():
		return
	var dir_path := _root().path_join(ns)
	if not PathHelper.ensure_dir_exists(dir_path):
		return
	var rec := {
		"v": SCHEMA_VERSION,
		"server": _server_key(),
		"user": user,
		"fetched_at": int(Time.get_unix_time_from_system()),
		"payload": payload,
	}
	var f := FileAccess.open(_file_path(ns, key, user), FileAccess.WRITE)
	if f == null:
		# 不用 GLogger：缓存层是纯静态工具，不该依赖 autoload 是否已初始化
		push_warning("[OnlineCache] write failed: %s" % key)
		return
	f.store_string(JSON.stringify(rec))
	f.close()
	_write_counter += 1
	if _write_counter % HOUSEKEEPING_INTERVAL == 0:
		_enforce_budget()


## 从 read() 的返回值里安全取 payload。
static func payload_of(entry: Dictionary, fallback: Variant = null) -> Variant:
	return entry.get("payload", fallback) if not entry.is_empty() else fallback


## 主动失效单条快照（例如服务端 404：谱面已不存在，不能继续展示旧计数）。
static func invalidate(ns: String, key: String, account_scoped: bool = false) -> void:
	if key.is_empty():
		return
	var user := _user_key() if account_scoped else ""
	if account_scoped and user.is_empty():
		return
	var path := _file_path(ns, key, user)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


# ============ 清除 / 容量 ============

## 清空所有快照文件（只删三个子目录第一层，保留目录本身）。
static func clear_all() -> void:
	var root := _root()
	for ns in NAMESPACES:
		var dir_path := root.path_join(ns)
		if not DirAccess.dir_exists_absolute(dir_path):
			continue
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		for file_name in dir.get_files():
			DirAccess.remove_absolute(dir_path.path_join(file_name))
	_housekeeping_done = false
	_write_counter = 0


static func total_size_bytes() -> int:
	var total := 0
	for entry in _collect_files():
		total += int(entry.get("size", 0))
	return total


static func format_size(bytes: int) -> String:
	if bytes < 1024:
		return "%d B" % bytes
	if bytes < 1024 * 1024:
		return "%.1f KB" % (float(bytes) / 1024.0)
	return "%.1f MB" % (float(bytes) / (1024.0 * 1024.0))


# ============ 内部实现 ============

static func _root() -> String:
	return PathHelper.get_online_cache_dir()


## 账号相关内容按 username 分键；未登录返回空串，使读写都被拒绝。
static func _user_key() -> String:
	if AuthManager.instance == null or not AuthManager.instance.is_logged_in:
		return ""
	var username := str(AuthManager.instance.current_user.get("username", ""))
	if username.is_empty():
		return ""
	return username.md5_text().substr(0, 12)


## 所有记录都带 server，改服务器地址后旧缓存自动失效（avatarUrl 是相对路径，
## 跨服务器复用会指向错误的图片）。
static func _server_key() -> String:
	var url := ""
	if NetManager.instance != null:
		url = str(NetManager.instance.server_url)
	if url.is_empty():
		url = ConfigManager.instance.get_string("server_address", "")
	return url.strip_edges().md5_text().substr(0, 12)


static func _file_path(ns: String, key: String, user: String) -> String:
	var file_name := key.md5_text()
	if not user.is_empty():
		file_name = "%s_%s" % [user, file_name]
	return _root().path_join(ns).path_join(file_name + ".json")


static func _collect_files() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var root := _root()
	for ns in NAMESPACES:
		var dir_path := root.path_join(ns)
		if not DirAccess.dir_exists_absolute(dir_path):
			continue
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		for file_name in dir.get_files():
			var path := dir_path.path_join(file_name)
			out.append({
				"path": path,
				"size": FileAccess.get_size(path),
				"mtime": FileAccess.get_modified_time(path),
			})
	return out


## 首次访问时清理 .tmp 残留并做一次容量淘汰；目录尚不存在则等下次再试。
static func _ensure_housekeeping() -> void:
	if _housekeeping_done:
		return
	if not DirAccess.dir_exists_absolute(_root()):
		return
	for entry in _collect_files():
		if str(entry.get("path", "")).ends_with(".tmp"):
			DirAccess.remove_absolute(str(entry.get("path", "")))
	_housekeeping_done = true
	_enforce_budget()


## 按 mtime 从旧到新淘汰到 90%（与 HttpImageLoader 的 WebCache 策略一致）。
static func _enforce_budget() -> void:
	var entries := _collect_files()
	var total := 0
	for entry in entries:
		total += int(entry.get("size", 0))
	var count := entries.size()
	var byte_target := int(MAX_CACHE_BYTES * TRIM_RATIO)
	var file_target := int(MAX_CACHE_FILES * TRIM_RATIO)
	if total <= MAX_CACHE_BYTES and count <= MAX_CACHE_FILES:
		return
	entries.sort_custom(func(a, b): return int(a.get("mtime", 0)) < int(b.get("mtime", 0)))
	for entry in entries:
		if total <= byte_target and count <= file_target:
			break
		if DirAccess.remove_absolute(str(entry.get("path", ""))) == OK:
			total -= int(entry.get("size", 0))
			count -= 1

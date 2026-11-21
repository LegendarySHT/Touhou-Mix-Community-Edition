extends Node
class_name DraftManager

## ServiceHub 服务声明：id 与依赖，注册时自动读取（见 Services/ServiceHub.gd）
const SERVICE_ID := "DraftManager"
const SERVICE_DEPS := ["NetManager", "AuthManager", "FileSystemManager"]

## 谱面草稿管理器（2026-11-21）：
## 缓存当前账号在服务端的草稿列表，过滤掉「该 MIDI 是否已在本地」，
## 并提供下载 / 撤销两种操作。ProfileView 只消费这里的结果，不自己发请求。
##
## 为什么单独一个服务而不是塞进 ProfileView：
##   ① ScoreManager 也要知道「这个 hash 是不是草稿」（成绩不上传的显式闸门）；
##   ② 草稿列表要在多个入口复用（个人页编辑 tab、MidiView 按钮状态）；
##   ③ 草稿是账号级数据，登出必须整体清空——集中在服务里更不容易漏。
##
## 后端契约（ChartDraftsController）：
##   GET    /api/drafts            → {drafts:[...], total, limit}
##   GET    /api/drafts/{hash}     → ChartDraftResponse
##   POST   /api/drafts            → multipart（NetManager.upload_chart_draft）
##   DELETE /api/drafts/{hash}     → 204
##   POST   /api/drafts/{hash}/publish → 201 ChartResponse
## 全部 [Authorize]，他人草稿按 404 处理（不泄露存在性）。

## 每账号草稿上限的兜底值：真正的数字由服务端 GET /api/drafts 的 limit 字段下发，
## 这里只在还没拉到列表时用于 UI 提前提示，绝不作为「能不能上传」的判据。
const DEFAULT_DRAFT_LIMIT := 10

## 本地草稿标记文件（user://）：记录"哪些本地谱面是草稿"。
## 刻意用独立文件而不是往 info.json 加字段：谱面状态机只有四个值，
## 加第五个状态会波及 ChartDB / DataMGR / 各 View（见 download_draft 注释）。
static func get_draft_hashes_file() -> String:
	return PathHelper.ensure_pinned_file("draft_hashes.json")

## 最近一次拉取的草稿列表（Array[Dictionary]，服务端原始 DTO）
var _drafts: Array = []
## 是否至少成功拉取过一次（失败时不要用空列表把已有 UI 刷成「暂无草稿」）
var _loaded: bool = false
## 拉取进行中（防并发重复请求）
var _loading: bool = false
## 服务端下发的每账号上限
var limit: int = DEFAULT_DRAFT_LIMIT

## 本地草稿 hash 集合（来自 draft_hashes.json，供 ScoreManager 同步查询）
var _local_draft_hashes: Dictionary = {}

## 缓存所属账号（切账号必须作废，否则会看到上一个账号的草稿）
var _owner: String = ""

## 草稿列表可用（至少拉取过一次）
var is_loaded: bool:
	get: return _loaded

## 当前草稿数
var count: int:
	get: return _drafts.size()

## 是否达到服务端上限
var is_full: bool:
	get: return _drafts.size() >= limit

func _ready() -> void:
	add_to_group("singleton")
	# 启动时可能已经是登录态（auth.json 会话恢复早于本服务）：先对齐 owner，
	# 否则首次 _on_auth_changed 会因 owner 相同而跳过清空（清空本身无害但要语义正确）
	_owner = _current_owner()
	_load_local_markers()
	if EvtBus:
		EvtBus.auth_changed.connect(_on_auth_changed)
	GLogger.info("DraftManager initialized, logged_in=%s local_draft_marks=%d" % [
		not _owner.is_empty(), _local_draft_hashes.size()], "DraftMGR")

## 登出 / 切账号：整体清空（含本地标记，避免下个账号看到上个账号的草稿清单）
func _on_auth_changed(_user_data: Variant) -> void:
	var owner := _current_owner()
	if owner == _owner:
		return
	_owner = owner
	_drafts = []
	_loaded = false
	_local_draft_hashes.clear()
	if owner.is_empty():
		# 登出：标记文件一并清掉（保留文件但内容空，避免下次登录读到旧账号残留）
		_write_local_markers()

func _current_owner() -> String:
	if ServiceHub.auth == null or not ServiceHub.auth.is_logged_in:
		return ""
	return str(ServiceHub.auth.current_user.get("username", ""))

# ========== 列表 ==========

## 拉取当前账号的草稿列表（服务端为准），成功后同步本地标记文件。
## force=false 时已有结果直接返回缓存，避免每次切 tab 都打一次接口。
## 返回 {"ok": bool, "error": String}
func refresh(force: bool = false) -> Dictionary:
	if ServiceHub.auth == null or not ServiceHub.auth.is_logged_in:
		return {"ok": false, "error": "not_logged_in"}
	if _loading:
		return {"ok": true, "error": ""}
	if _loaded and not force:
		return {"ok": true, "error": ""}

	_loading = true
	var result: Dictionary = await ServiceHub.auth.authed_request("GET", "/api/drafts")
	_loading = false

	var data: Variant = result.get("data")
	if not result.get("ok", false) or not data is Dictionary:
		GLogger.warning("草稿列表拉取失败: %s" % str(result.get("error", "")), "DraftMGR")
		return {"ok": false, "error": str(result.get("error", ""))}

	var payload: Dictionary = data
	var list: Variant = payload.get("drafts", [])
	_drafts = list if list is Array else []
	limit = int(payload.get("limit", DEFAULT_DRAFT_LIMIT))
	_loaded = true
	_owner = _current_owner()
	_sync_local_markers_from_list()
	return {"ok": true, "error": ""}

## 取草稿列表的只读副本（UI 渲染用）
func get_drafts() -> Array:
	return _drafts.duplicate()

## 某个 hash 是否在服务端草稿里
func has_draft(chart_hash: String) -> bool:
	var h := chart_hash.strip_edges().to_lower()
	if h.is_empty():
		return false
	for d in _drafts:
		if d is Dictionary and str(d.get("hash", "")).strip_edges().to_lower() == h:
			return true
	return false

## 某个 hash 是否是「本地已有的草稿」（供 ScoreManager 同步判断，不依赖网络）。
## 与 has_draft 的区别：这个看的是本地落盘的谱面里哪些是草稿（打歌时才知道 hash，
## 此时列表可能还没拉取过），因此读的是标记文件而不是内存列表。
func is_local_draft(chart_hash: String) -> bool:
	var h := chart_hash.strip_edges().to_lower()
	if h.is_empty():
		return false
	return _local_draft_hashes.has(h)

# ========== 操作 ==========

## 撤销服务端草稿（需求：ProfileView 的「删除」= 撤销草稿，**不动本地文件**；
## 真正删本地曲包仍在 MidiView 的「删除曲包」）。
## 返回 {"ok": bool, "error": String}
func delete_draft(chart_hash: String) -> Dictionary:
	if ServiceHub.auth == null or not ServiceHub.auth.is_logged_in:
		return {"ok": false, "error": "not_logged_in"}
	var h := chart_hash.strip_edges()
	if h.is_empty():
		return {"ok": false, "error": "hash_empty"}

	var result: Dictionary = await ServiceHub.auth.authed_request(
		"DELETE", "/api/drafts/%s" % h.uri_encode())
	# 404 视为已不存在（可能被别的设备删了 / 已被正式发布清空）：幂等成功
	var status := int(result.get("status", 0))
	if not result.get("ok", false) and status != 404:
		return {"ok": false, "error": str(result.get("error", ""))}

	_remove_from_memory(h)
	_unmark_local(h)
	EvtBus.chart_drafts_changed.emit()
	return {"ok": true, "error": ""}

## 下载自己上传的草稿到本地曲库。
## 返回 {"ok": bool, "error": String}
func download_draft(chart_hash: String, on_progress: Callable = Callable()) -> Dictionary:
	if ServiceHub.resource == null:
		return {"ok": false, "error": "resource_manager_missing"}
	var result: Dictionary = await ServiceHub.resource.download_draft(chart_hash, on_progress)
	if result.get("ok", false):
		# 下载成功即标记为本地草稿：之后打这首歌的成绩不再上传（见 ScoreManager）
		_mark_local(chart_hash)
		# 下载会触发曲库重载，存在性缓存不受影响（hash 在服务端本就是 MISSING），
		# 但 MidiView 的按钮要看登录态+本地状态，通知一次让它重算
		EvtBus.chart_drafts_changed.emit()
	return result

## 把草稿正式发布（网页侧也有同样的入口；客户端这里只提供一步直达的能力，
## 发布后所有账号的同 hash 草稿都会被服务端清空）。
## 返回 {"ok": bool, "error": String, "data": Variant}
func publish_draft(chart_hash: String) -> Dictionary:
	if ServiceHub.auth == null or not ServiceHub.auth.is_logged_in:
		return {"ok": false, "error": "not_logged_in"}
	var h := chart_hash.strip_edges()
	if h.is_empty():
		return {"ok": false, "error": "hash_empty"}
	var result: Dictionary = await ServiceHub.auth.authed_request(
		"POST", "/api/drafts/%s/publish" % h.uri_encode())
	if result.get("ok", false):
		_remove_from_memory(h)
		_unmark_local(h)
		# 发布后该 hash 已在谱面库，作废存在性缓存让 MidiView 立刻改显示「在网页查看」
		if ServiceHub.net != null:
			ServiceHub.net.invalidate_chart_remote_state(h)
		EvtBus.chart_drafts_changed.emit()
	return {"ok": bool(result.get("ok", false)),
		"error": str(result.get("error", "")), "data": result.get("data")}

## 上传成功后由 MidiView 调用：把新草稿并入内存列表（避免立刻整份重拉）
func note_uploaded(chart_hash: String, draft_data: Variant = null) -> void:
	var h := chart_hash.strip_edges().to_lower()
	if h.is_empty():
		return
	_unmark_local(h)  # 刚上传的草稿，本地谱面本身不是"下载来的草稿"
	if draft_data is Dictionary:
		var entry: Dictionary = draft_data
		# 同一 hash 先移除旧条目，再插到最前（服务端按 UpdatedAt DESC 排序）
		_remove_from_memory(h)
		_drafts.insert(0, entry)
		_loaded = true
		limit = maxi(limit, _drafts.size())
	# 两个信号各有明确消费方，都要发：
	#   chart_draft_uploaded → ProfileView 重拉列表（服务端才是唯一真相）
	#   chart_drafts_changed → MidiView 重探按钮（发布后按钮要换成「在网页查看」）
	EvtBus.chart_draft_uploaded.emit(chart_hash)
	EvtBus.chart_drafts_changed.emit()

## 重新拉取并作废 MidiView 的存在性缓存（发布相关场景用）
func refresh_and_invalidate() -> void:
	if ServiceHub.net != null:
		ServiceHub.net.invalidate_chart_remote_state("")
	await refresh(true)

# ========== 内部 ==========

func _remove_from_memory(chart_hash: String) -> void:
	var h := chart_hash.strip_edges().to_lower()
	var kept: Array = []
	for d in _drafts:
		if d is Dictionary and str(d.get("hash", "")).strip_edges().to_lower() == h:
			continue
		kept.append(d)
	_drafts = kept

## 列表拉取成功后，把服务端草稿里「本地已有」的那些写进标记文件。
## 只处理本地存在的：本地没有的草稿本来就不会被游玩，谈不上成绩上传。
func _sync_local_markers_from_list() -> void:
	_local_draft_hashes.clear()
	if ServiceHub.fs == null:
		return
	for d in _drafts:
		if not (d is Dictionary):
			continue
		var entry: Dictionary = d
		var h := str(entry.get("hash", "")).strip_edges().to_lower()
		if h.is_empty():
			continue
		if ServiceHub.fs.chart_exists_on_disk(h):
			_local_draft_hashes[h] = true
	_write_local_markers()

func _mark_local(chart_hash: String) -> void:
	var h := chart_hash.strip_edges().to_lower()
	if h.is_empty():
		return
	_local_draft_hashes[h] = true
	_write_local_markers()

func _unmark_local(chart_hash: String) -> void:
	var h := chart_hash.strip_edges().to_lower()
	if h.is_empty() or not _local_draft_hashes.has(h):
		return
	_local_draft_hashes.erase(h)
	_write_local_markers()

## 读取本地标记文件（启动时；账号隔离由登录态变化时清空保证）
func _load_local_markers() -> void:
	_local_draft_hashes.clear()
	var data: Variant = ServiceHub.config.load_json_file(get_draft_hashes_file())
	if not data is Dictionary:
		return
	var payload: Dictionary = data
	var hashes: Variant = payload.get("hashes", [])
	if not hashes is Array:
		return
	for h in hashes:
		var s := str(h).strip_edges().to_lower()
		if not s.is_empty():
			_local_draft_hashes[s] = true

func _write_local_markers() -> void:
	ServiceHub.config.save_json_file(get_draft_hashes_file(), {
		"hashes": _local_draft_hashes.keys(),
		"saved_at": Time.get_unix_time_from_system(),
	})

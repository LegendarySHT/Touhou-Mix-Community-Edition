extends Node
class_name CommunityManager

## MIDI 社区功能管理器：评价、评论、评论点赞与赞踩计数缓存。
## 通过 Main.gd 手动 add_child，使用 CommunityManager.instance 访问。

static var instance: CommunityManager = null

## 新脚本一律 preload 后按常量调用，不依赖 .godot/global_script_class_cache.cfg
const OnlineCache := preload("res://Core/OnlineContentCache.gd")

const COMMENTS_LIMIT: int = 50


func _ready() -> void:
	if instance == null:
		instance = self
	else:
		queue_free()
		return
	add_to_group("singleton")
	GLogger.info("CommunityManager initialized", "CommunityMGR")


## 获取社区汇总。登录用户优先携带鉴权，以取得 myReaction/canInteract；
## token 明确失效时退化为公开读取，仍可展示在线计数。
func get_summary(midi_hash: String) -> Dictionary:
	if midi_hash.is_empty():
		return _error_result("midi_hash_empty")
	var path := "/api/charts/%s/community" % midi_hash.uri_encode()
	var result: Dictionary = await _read_request(path)
	if result.get("ok", false):
		var data = result.get("data")
		if data is Dictionary:
			_save_summary_cache(midi_hash, data)
	elif int(result.get("status", 0)) == 404:
		delete_cached_counts(midi_hash)
	return result


## 获取最新评论列表（公开可读；登录时携带鉴权以取得 likedByMe）。
func get_comments(midi_hash: String, limit: int = COMMENTS_LIMIT, offset: int = 0) -> Dictionary:
	if midi_hash.is_empty():
		return _error_result("midi_hash_empty")
	var path := "/api/charts/%s/comments?limit=%d&offset=%d" % [
		midi_hash.uri_encode(), clampi(limit, 1, 100), maxi(offset, 0)
	]
	var result: Dictionary = await _read_request(path)
	if int(result.get("status", 0)) == 404:
		delete_cached_counts(midi_hash)
	return result


## 设置目标评价状态。reaction 为 "like"、"dislike" 或 null。
func set_reaction(midi_hash: String, reaction: Variant) -> Dictionary:
	var result: Dictionary = await _write_request(
		"PUT",
		"/api/charts/%s/community/reaction" % midi_hash.uri_encode(),
		{ "reaction": reaction }
	)
	if result.get("ok", false):
		var data = result.get("data")
		if data is Dictionary:
			_save_summary_cache(midi_hash, data)
	elif int(result.get("status", 0)) == 404:
		delete_cached_counts(midi_hash)
	return result


func create_comment(midi_hash: String, content: String) -> Dictionary:
	var result: Dictionary = await _write_request(
		"POST",
		"/api/charts/%s/comments" % midi_hash.uri_encode(),
		{ "content": content }
	)
	if int(result.get("status", 0)) == 404:
		delete_cached_counts(midi_hash)
	return result


func set_comment_like(comment_id: int, liked: bool) -> Dictionary:
	return await _write_request(
		"PUT",
		"/api/comments/%d/like" % comment_id,
		{ "liked": liked }
	)


## 读取本地缓存；无缓存返回空字典。
## 在线内容缓存开启时以统一层为准，只缓存公开的 likeCount/dislikeCount
## （myReaction / canInteract 是账号态，一律以在线响应为准，不落盘）。
## ChartDB 旧表保留作一次性回退源，兼容升级前已写入的数据，不删不改。
func get_cached_counts(midi_hash: String) -> Dictionary:
	if midi_hash.is_empty():
		return {}
	if OnlineCache.is_enabled():
		var entry := OnlineCache.read("charts", midi_hash + "|community")
		if not entry.is_empty():
			var payload: Variant = OnlineCache.payload_of(entry, null)
			if payload is Dictionary:
				var d: Dictionary = payload
				return {
					"like_count": int(d.get("likeCount", 0)),
					"dislike_count": int(d.get("dislikeCount", 0)),
				}
	if ChartDB == null or not ChartDB.IsOpen():
		return {}
	return ChartDB.GetCommunityCounts(midi_hash)


func delete_cached_counts(midi_hash: String) -> void:
	if midi_hash.is_empty():
		return
	if OnlineCache.is_enabled():
		OnlineCache.invalidate("charts", midi_hash + "|community")
	if ChartDB != null and ChartDB.IsOpen():
		ChartDB.DeleteCommunityCounts(midi_hash)


## 公开读取在登录态下优先附带 token。仅凭证明确不可用时降级为匿名请求；
## 网络和 5xx 错误不二次请求，避免故障时制造重复流量。
func _read_request(path: String) -> Dictionary:
	if not _is_online_ready():
		return _error_result("offline")
	if AuthManager.instance != null and AuthManager.instance.is_logged_in:
		var authed: Dictionary = await AuthManager.instance.authed_request("GET", path)
		if authed.get("ok", false) or int(authed.get("status", 0)) == 404:
			return authed
		var error := str(authed.get("error", ""))
		var status := int(authed.get("status", 0))
		if status != 401 and error not in ["not_logged_in", "token_expired"]:
			return authed
	return await NetManager.instance._request(
		"GET", "%s%s" % [NetManager.instance.server_url, path], null
	)


func _write_request(method: String, path: String, body: Dictionary) -> Dictionary:
	if not _is_online_ready():
		return _error_result("offline")
	if AuthManager.instance == null:
		return _error_result("auth_not_ready")
	return await AuthManager.instance.authed_request(method, path, body)


func _save_summary_cache(midi_hash: String, data: Dictionary) -> void:
	# 开启时写统一缓存层（公开计数）；关闭时完全沿用原有 ChartDB 落盘，行为不变
	if OnlineCache.is_enabled():
		OnlineCache.write("charts", midi_hash + "|community", {
			"likeCount": maxi(int(data.get("likeCount", 0)), 0),
			"dislikeCount": maxi(int(data.get("dislikeCount", 0)), 0),
		})
		return
	if ChartDB == null or not ChartDB.IsOpen():
		return
	ChartDB.SaveCommunityCounts(
		midi_hash,
		maxi(int(data.get("likeCount", 0)), 0),
		maxi(int(data.get("dislikeCount", 0)), 0),
		int(Time.get_unix_time_from_system())
	)


func _is_online_ready() -> bool:
	return NetManager.instance != null \
		and NetManager.instance.connect_state == NetManager.ConnectState.ONLINE \
		and NetManager.instance.is_online


func _error_result(error: String) -> Dictionary:
	return { "ok": false, "status": 0, "data": null, "error": error }


func _exit_tree() -> void:
	if instance == self:
		instance = null

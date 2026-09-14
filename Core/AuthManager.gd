extends Node
class_name AuthManager

## 认证管理器：登录态、token 持久化、带认证的请求
## 通过 Main.gd 手动 add_child，使用 AuthManager.instance 访问

static var instance: AuthManager = null

## Token 文件路径（随存储根迁移）
static func get_token_file() -> String:
	return PathHelper.get_files_dir() + "auth.json"

## 当前用户数据（null 表示未登录）
## 结构：{ "username": "...", "access_token": "...", "refresh_token": "...",
##         "expires_at": int, "refresh_expires_at": int, "role": "..." }
var current_user: Variant = null

## 是否已登录
var is_logged_in: bool:
	get:
		return current_user != null and not current_user.get("access_token", "").is_empty()

## 本次启动是否曾处于登录态（用于区分「从未登录/已主动登出」与「登录后异常掉线」）
## 匿名上传成绩时，仅从未登录或主动登出走匿名；曾登录但会话异常丢失则提示重新登录
var ever_authenticated: bool = false

## 是否正在执行 refresh（防止重复续期）
var _is_refreshing: bool = false

func _ready() -> void:
	if instance == null:
		instance = self
	else:
		queue_free()
		return
	add_to_group("singleton")
	_load_session()
	GLogger.info("AuthManager initialized, logged_in=%s" % is_logged_in, "AuthMGR")

## 从本地加载已保存的会话
func _load_session() -> void:
	var data = ConfigManager.instance.load_json_file(get_token_file())
	if data.is_empty():
		return
	var expires_at = data.get("expires_at", 0)
	var refresh_expires_at = data.get("refresh_expires_at", 0)
	var now = Time.get_unix_time_from_system()
	if expires_at > 0 and now > expires_at:
		# access token 过期，检查 refresh token 是否有效
		if refresh_expires_at > 0 and now < refresh_expires_at:
			# refresh token 仍有效，暂存 current_user 供 _try_refresh 使用，异步续期
			current_user = data
			ever_authenticated = true
			_try_refresh()  # 不 await（_ready 中不能阻塞）
			return
		else:
			_clear_session()
			return
	current_user = data
	ever_authenticated = true
	EvtBus.auth_changed.emit(current_user)

## 保存会话到本地
func _save_session(data: Dictionary) -> void:
	current_user = data
	ever_authenticated = true
	ConfigManager.instance.save_json_file(get_token_file(), data, true)
	EvtBus.auth_changed.emit(current_user)

## 清除本地会话
func _clear_session() -> void:
	current_user = null
	if FileAccess.file_exists(get_token_file()):
		DirAccess.remove_absolute(get_token_file())
	EvtBus.auth_changed.emit(null)

## 尝试用 refresh token 续期 access token
## 返回 true 表示续期成功。内置重入保护：并发调用会等待首次完成。
func _try_refresh() -> bool:
	if _is_refreshing:
		# 已有 refresh 进行中，等待完成
		while _is_refreshing:
			await get_tree().process_frame
			if not is_instance_valid(self):
				return false
		return is_logged_in
	_is_refreshing = true
	var refresh_token := ""
	if current_user != null:
		refresh_token = current_user.get("refresh_token", "")
	if refresh_token.is_empty():
		_is_refreshing = false
		_clear_session()
		return false
	var result = await NetManager.instance._request(
		"POST",
		"%s/api/auth/refresh" % NetManager.instance.server_url,
		{ "refreshToken": refresh_token }
	)
	if not result.ok or result.data == null or not result.data is Dictionary:
		_is_refreshing = false
		# 网络/服务端临时故障（status==0 或 5xx）保留本地会话，待网络恢复后由后续请求重试续期；
		# 仅当服务端明确拒绝凭证（401/400，如 refresh token 失效）时才清除会话，避免误登出
		var status := int(result.get("status", 0))
		if status == 401 or status == 400:
			_clear_session()
		return false
	var data: Dictionary = result.data
	var session := {
		"username": data.get("username", current_user.get("username", "")),
		"access_token": data.get("accessToken", ""),
		"refresh_token": data.get("refreshToken", ""),
		"expires_at": data.get("expiresAt", 0),
		"refresh_expires_at": data.get("refreshExpiresAt", 0),
		"role": data.get("role", "user")
	}
	_save_session(session)
	_is_refreshing = false
	GLogger.info("Token refreshed: %s" % session.username, "AuthMGR")
	return true

## 确保当前 access token 有效，过期则自动续期
## 供 ScoreManager / authed_request 在发请求前调用
func ensure_valid_token() -> bool:
	if not is_logged_in:
		return false
	var now = Time.get_unix_time_from_system()
	var expires_at = current_user.get("expires_at", 0)
	# access token 仍有效（留 10 秒缓冲避免请求途中过期）
	if expires_at == 0 or now < expires_at - 10:
		return true
	# access token 过期或即将过期，尝试 refresh
	return await _try_refresh()

## 注册
## 返回 { "ok": bool, "error": String }
func register(username: String, password: String) -> Dictionary:
	var result = await NetManager.instance._request(
		"POST",
		"%s/api/auth/register" % NetManager.instance.server_url,
		{ "username": username, "password": password }
	)
	if not result.ok:
		return { "ok": false, "error": result.error }
	return { "ok": true, "error": "" }

## 登录
## 成功后自动保存 token
func login(username: String, password: String) -> Dictionary:
	var result = await NetManager.instance._request(
		"POST",
		"%s/api/auth/login" % NetManager.instance.server_url,
		{ "username": username, "password": password }
	)
	if not result.ok:
		return { "ok": false, "error": result.error }
	var data = result.data
	if data == null or not data is Dictionary:
		return { "ok": false, "error": "invalid_response" }
	var session = {
		"username": data.get("username", username),
		"access_token": data.get("accessToken", ""),
		"refresh_token": data.get("refreshToken", ""),
		"expires_at": data.get("expiresAt", 0),
		"refresh_expires_at": data.get("refreshExpiresAt", 0),
		"role": data.get("role", "user")
	}
	_save_session(session)
	GLogger.info("Login successful: %s" % username, "AuthMGR")
	return { "ok": true, "error": "" }

## 登出
func logout() -> void:
	ever_authenticated = false
	_clear_session()
	GLogger.info("Logged out", "AuthMGR")

## 带认证的请求（封装 NetManager._request，自动附加 token + 自动续期）
func authed_request(method: String, path: String, body: Variant = null) -> Dictionary:
	if not is_logged_in:
		return { "ok": false, "status": 0, "data": null, "error": "not_logged_in" }
	# 确保 access token 有效（过期则自动 refresh）
	if not await ensure_valid_token():
		return { "ok": false, "status": 0, "data": null, "error": "token_expired" }
	var url = "%s%s" % [NetManager.instance.server_url, path]
	return await NetManager.instance._request(
		method, url, body, PackedStringArray(), current_user.access_token
	)

## 验证当前 token 是否有效：GET /api/auth/me
func verify_token() -> bool:
	if not is_logged_in:
		return false
	var result = await authed_request("GET", "/api/auth/me")
	var valid = result.ok
	if not valid:
		_clear_session()
	return valid

# ========== 资料管理 ==========

## 获取当前用户资料：GET /api/users/me
func get_profile() -> Dictionary:
	return await authed_request("GET", "/api/users/me")

## 更新昵称/简介（传 null 表示不修改该字段）：PATCH /api/users/me
func update_profile(display_name: Variant, bio: Variant) -> Dictionary:
	var body := {}
	if display_name != null:
		body["displayName"] = display_name
	if bio != null:
		body["bio"] = bio
	return await authed_request("PATCH", "/api/users/me", body)

## 修改密码：PATCH /api/users/me/password
func change_password(old_password: String, new_password: String) -> Dictionary:
	return await authed_request("PATCH", "/api/users/me/password", {
		"oldPassword": old_password,
		"newPassword": new_password
	})

## 上传头像（base64 编码）：POST /api/users/me/avatar
func upload_avatar(image_base64: String, content_type: String = "") -> Dictionary:
	var body := { "imageBase64": image_base64 }
	if not content_type.is_empty():
		body["contentType"] = content_type
	return await authed_request("POST", "/api/users/me/avatar", body)

## 获取当前用户统计：GET /api/users/me/stats
func get_user_stats() -> Dictionary:
	return await authed_request("GET", "/api/users/me/stats")

## 获取最近游玩记录：GET /api/users/me/scores/recent?limit=&offset=
func get_recent_scores(limit: int = 20, offset: int = 0) -> Dictionary:
	return await authed_request("GET", "/api/users/me/scores/recent?limit=%d&offset=%d" % [limit, offset])

## 获取最佳记录（按 MIDI 去重）：GET /api/users/me/scores/best?limit=&offset=
func get_best_scores(limit: int = 20, offset: int = 0) -> Dictionary:
	return await authed_request("GET", "/api/users/me/scores/best?limit=%d&offset=%d" % [limit, offset])

## 获取最多游玩：GET /api/users/me/scores/most?limit=&offset=
func get_most_played(limit: int = 20, offset: int = 0) -> Dictionary:
	return await authed_request("GET", "/api/users/me/scores/most?limit=%d&offset=%d" % [limit, offset])

extends TabContainer
class_name PlayerInfoContent

## PlayerInfo 的内容容器，管理 MiniInfo / LogInPage / Summary 三个 tab；
## 全屏的 ProfileView 是 Main 下的独立视图，不在此处。
## 负责表单交互、个人信息填充等页面内逻辑；
## 状态切换、面板几何动画由 PlayerInfoPanel 处理。

signal login_submitted()
signal logout_submitted()
signal expand_toggled()
## 统计数据刷新完成（pp/等级/进度条等），通知外部视图（如 ScoreView）同步更新
signal stats_refreshed()

# 玩家数据（登录后从 AuthManager.current_user + 服务端 profile/stats 填充）
# 玩家数据（登录后从 AuthManager.current_user + 服务端 profile/stats 填充）
var _player_data := {
	"name": "Anonymous Player",
	"display_name": "",
	"bio": "",
	"avatar_url": "",
	"level": 1,
	"pp": 0.0,
	"rank": 0,
	"total_plays": 0,
	"accuracy": 0.0,
	"max_combo": 0,
	"play_duration_ms": 0,
	"level_progress": 0.0,
	"grades": {"S": 0, "A": 0, "B": 0, "C": 0, "D": 0, "F": 0},
	"recent_scores": [],
}

## 读取玩家数据副本（外部只读请用此方法，避免跨类直读私有字段，TMX-019）
func get_player_data() -> Dictionary:
	return _player_data.duplicate()

# 被外部引用
@onready var tip: Control = %MiniTip
@onready var mini_avatar_rect: TextureRect = %MiniAvatarTexture

# ProfileView（Main 下的独立全屏详情视图，懒加载：首次进入详情页才实例化）
var profile_view: ProfileView = null
## 当前头像纹理（懒加载的 ProfileView 创建后据此回填）
var _avatar_texture: Texture2D = null
## 头像请求代次：切换账号/登出时递增，用于丢弃过期结果
var _avatar_load_token: int = 0

## 提交进行中（防止重复点击）
var _submitting: bool = false

func _ready() -> void:
	_reset_login_form()
	# 监听认证状态变化，自动同步显示
	if not EvtBus.auth_changed.is_connected(_on_auth_changed):
		EvtBus.auth_changed.connect(_on_auth_changed)
	# 监听网络状态变化：连接成功后若已登录，重新拉取资料/统计
	if not EvtBus.online_status_changed.is_connected(_on_online_status_changed):
		EvtBus.online_status_changed.connect(_on_online_status_changed)
	# 监听成绩上传成功，刷新统计
	if not EvtBus.score_uploaded.is_connected(_on_score_uploaded):
		EvtBus.score_uploaded.connect(_on_score_uploaded)
	# ProfileView 是懒加载视图：已经存在就直接绑定，否则等它首次实例化
	if not UiStatMGR.view_loaded.is_connected(_on_lazy_view_loaded):
		UiStatMGR.view_loaded.connect(_on_lazy_view_loaded)
	profile_view = get_node_or_null(PathRegistry.PROFILE_VIEW) as ProfileView
	_bind_profile_view()
	# 启动时若已登录（从本地恢复会话），立即填充
	_sync_from_auth.call_deferred()
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()

func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)

# ========== 懒加载视图绑定 ==========

## 懒加载视图实例化完成：只关心 ProfileView
func _on_lazy_view_loaded(state: UIStateManager.UIState, node: Node) -> void:
	if state != UIStateManager.UIState.PROFILE_VIEW:
		return
	profile_view = node as ProfileView
	_bind_profile_view()

## 连接 ProfileView 的信号，并把当前玩家数据灌进去。
## 视图可能在登录态变化之后才创建，所以这里要补一次全量回填。
func _bind_profile_view() -> void:
	if profile_view == null:
		return
	if not profile_view.profile_updated.is_connected(_fetch_profile_and_stats_async):
		profile_view.profile_updated.connect(_fetch_profile_and_stats_async)
	if not profile_view.avatar_uploaded.is_connected(_on_avatar_uploaded):
		profile_view.avatar_uploaded.connect(_on_avatar_uploaded)
	# 头像由本节点统一加载：视图晚于头像就绪创建时用已有纹理回填
	if _avatar_texture:
		profile_view.set_avatar_texture(_avatar_texture)
	profile_view.update_display(_player_data)

# ========== 主题色应用 ==========

## 跟随主题色的部分：头像外圈描边 +「前往网页注册」链接按钮字色。
## 圆角本身由 ImgRoundCorner shader 做，与主题无关。
func apply_theme() -> void:
	var ring: Color = ThemeMGR.get_color("primary") \
		if ThemeMGR.get_appearance() == "light" else ThemeMGR.get_color("primary_light")
	_set_border_keep_alpha(%MiniAvatar, ring)
	_set_border_keep_alpha(%ProfileAvatarPanel, ring)
	_apply_register_link_theme()

## 「前往网页注册」链接按钮的字色：浅色底用 primary_dark（深一档），
## 深色底用 primary_light；hover/pressed 在此基础上做明暗反馈。
func _apply_register_link_theme() -> void:
	var is_light := ThemeMGR.get_appearance() == "light"
	var base: Color = ThemeMGR.get_color("primary_dark") \
		if is_light else ThemeMGR.get_color("primary_light")
	var hover: Color = base.darkened(0.18) if is_light else base.lightened(0.22)
	var pressed: Color = base.darkened(0.32) if is_light else base.darkened(0.08)
	%RegisterBtn.add_theme_color_override("font_color", base)
	%RegisterBtn.add_theme_color_override("font_hover_color", hover)
	%RegisterBtn.add_theme_color_override("font_pressed_color", pressed)
	%RegisterBtn.add_theme_color_override("font_focus_color", hover)

## 改 panel 描边色，保留原 alpha（tscn 里是 0.9，是刻意调过的，不能被冲掉）
func _set_border_keep_alpha(node: Control, border: Color) -> void:
	var sb := node.get_theme_stylebox("panel")
	if sb is StyleBoxFlat:
		sb.border_color = Color(border.r, border.g, border.b, sb.border_color.a)

## 头像上屏：MiniInfo / Summary，以及已加载的 ProfileView
func _apply_avatar_texture(tex: Texture2D) -> void:
	_avatar_texture = tex
	mini_avatar_rect.texture = tex
	%ProfileAvatar.texture = tex
	if profile_view:
		profile_view.set_avatar_texture(tex)

## 重置为默认头像（登出/无头像）
func _apply_default_avatar() -> void:
	_avatar_load_token += 1
	_apply_avatar_texture(load("res://Resources/icon/NoAvatar.jpg") as Texture2D)

## 按 _player_data.avatar_url 拉头像：先本地缓存立即上屏，再联网刷新。
## 头像属于玩家数据，不能依赖懒加载的 ProfileView 是否存在。
func _load_avatar_async() -> void:
	var avatar_url := str(_player_data.get("avatar_url", ""))
	if avatar_url.is_empty() or NetManager.instance == null:
		return
	var full_url := "%s%s" % [NetManager.instance.server_url, avatar_url]
	_avatar_load_token += 1
	var my_token := _avatar_load_token
	HttpImageLoader.load_cached(full_url, self, func(tex: Texture2D) -> void:
		if my_token != _avatar_load_token or tex == null:
			return
		_apply_avatar_texture(tex)
	)
	if not NetManager.instance.is_online:
		return
	HttpImageLoader.load(full_url, self, func(tex: Texture2D) -> void:
		if my_token != _avatar_load_token or tex == null:
			return
		_apply_avatar_texture(tex)
	)

## 头像上传成功：直接用返回的新 URL 加载，不必等资料拉取往返
func _on_avatar_uploaded(url: String) -> void:
	if url.is_empty():
		return
	_player_data.avatar_url = url
	_load_avatar_async()

## 认证状态变化回调
func _on_auth_changed(_user_data: Variant) -> void:
	_sync_from_auth()

## 网络状态变化回调：连接成功后若已登录，自动拉取资料/统计
func _on_online_status_changed(online: bool, _latency: String) -> void:
	if online and AuthManager.instance != null and AuthManager.instance.is_logged_in:
		_fetch_profile_and_stats_async()

## 成绩上传成功回调：刷新统计
func _on_score_uploaded(_midi_hash: String) -> void:
	if AuthManager.instance != null and AuthManager.instance.is_logged_in:
		_fetch_stats_async()

## 从 AuthManager 同步登录态到本地显示，并拉取资料/统计
func _sync_from_auth() -> void:
	if AuthManager.instance != null and AuthManager.instance.is_logged_in:
		var username := str(AuthManager.instance.current_user.get("username", ""))
		_player_data.name = username
		# 先用上次已知的资料（本地缓存）占位：昵称/简介/头像 URL 立刻有值，
		# 头像可直接命中 WebCache 上屏；网络返回后再覆盖，避免每次都先闪一遍默认头像
		var cached := _load_cached_profile(username)
		if _player_data.display_name.is_empty() or _player_data.display_name == _player_data.name:
			var cached_name := str(cached.get("displayName", ""))
			_player_data.display_name = cached_name if not cached_name.is_empty() else username
		if _player_data.bio.is_empty():
			_player_data.bio = str(cached.get("bio", ""))
		if _player_data.avatar_url.is_empty():
			_player_data.avatar_url = str(cached.get("avatarUrl", ""))
		populate_profile()
		populate_mini_info()
		if profile_view:
			profile_view.update_display(_player_data)
		# 先用缓存 URL 把头像显示出来，不依赖详情页是否已打开
		if _player_data.avatar_url.is_empty():
			_apply_default_avatar()
		else:
			_load_avatar_async()
		# 异步拉取服务端资料与统计
		_fetch_profile_and_stats_async()
	else:
		HttpImageLoader.clear_cache()
		_player_data.name = "Anonymous Player"
		_player_data.display_name = ""
		_player_data.bio = ""
		_player_data.avatar_url = ""
		_player_data.pp = 0.0
		_player_data.accuracy = 0.0
		_player_data.total_plays = 0
		_player_data.max_combo = 0
		_player_data.play_duration_ms = 0
		_player_data.grades = {"S": 0, "A": 0, "B": 0, "C": 0, "D": 0, "F": 0}
		# 重置头像为默认
		_apply_default_avatar()
		populate_profile()
		populate_mini_info()
		if profile_view:
			profile_view.update_display(_player_data)
			# 清空历史列表（退出登录时）
			profile_view.clear_history_lists()

## 异步拉取用户资料（昵称/简介/头像）并刷新显示
func _fetch_profile_and_stats_async() -> void:
	if AuthManager.instance == null or not AuthManager.instance.is_logged_in:
		return
	if NetManager.instance == null or not NetManager.instance.is_online:
		return
	# 拉取资料
	var profile_result: Dictionary = await AuthManager.instance.get_profile()
	if profile_result.get("ok", false) and profile_result.data is Dictionary:
		var p: Dictionary = profile_result.data
		_player_data.display_name = str(p.get("displayName", _player_data.name))
		if _player_data.display_name.is_empty():
			_player_data.display_name = _player_data.name
		var bio_val = p.get("bio", "")
		_player_data.bio = str(bio_val) if bio_val != null and not str(bio_val).is_empty() else "还没有填写简介..."
		var avatar_val = p.get("avatarUrl", "")
		_player_data.avatar_url = str(avatar_val) if avatar_val != null else ""
		populate_profile()
		populate_mini_info()
		if profile_view:
			profile_view.update_display(_player_data)
		_load_avatar_async()
		_save_cached_profile()
	# 拉取统计
	_fetch_stats_async()

# ========== 资料本地缓存（启动时先显示上次的昵称/简介/头像） ==========

## 读取指定账号上次的资料；无缓存返回空字典
func _load_cached_profile(username: String) -> Dictionary:
	if username.is_empty():
		return {}
	var all := ConfigManager.instance.load_json_file(PathHelper.get_profile_cache_file())
	var users: Variant = all.get("users", {})
	if not users is Dictionary:
		return {}
	var entry: Variant = (users as Dictionary).get(username, {})
	return entry if entry is Dictionary else {}

## 写回当前账号的资料快照（服务端资料拉取成功后调用）
## 按 username 分别存，切换账号不会互相覆盖
func _save_cached_profile() -> void:
	if AuthManager.instance == null or not AuthManager.instance.is_logged_in:
		return
	var username := str(AuthManager.instance.current_user.get("username", ""))
	if username.is_empty():
		return
	var path := PathHelper.get_profile_cache_file()
	var all := ConfigManager.instance.load_json_file(path)
	var users: Variant = all.get("users", {})
	var cache_users: Dictionary = users if users is Dictionary else {}
	cache_users[username] = {
		"displayName": _player_data.display_name,
		"bio": _player_data.bio,
		"avatarUrl": _player_data.avatar_url,
	}
	if not PathHelper.ensure_dir_exists(PathHelper.get_boot_dir()):
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		GLogger.warning("Profile cache write failed: %s" % path, "PlayerInfo")
		return
	f.store_string(JSON.stringify({"users": cache_users}, "\t"))
	f.close()

## 异步拉取用户统计并刷新显示
func _fetch_stats_async() -> void:
	if AuthManager.instance == null or not AuthManager.instance.is_logged_in:
		return
	if NetManager.instance == null or not NetManager.instance.is_online:
		return
	var stats_result: Dictionary = await AuthManager.instance.get_user_stats()
	if not stats_result.get("ok", false) or not stats_result.data is Dictionary:
		return
	var s: Dictionary = stats_result.data
	_player_data.pp = float(s.get("totalPp", 0))
	_player_data.accuracy = float(s.get("avgAccuracy", 0)) * 100.0
	_player_data.total_plays = int(s.get("totalPlays", 0))
	_player_data.max_combo = int(s.get("maxCombo", 0))
	_player_data.play_duration_ms = int(s.get("playDurationMs", 0))
	# 解析评级分布并按 UI 分类分组（S/A/B/C/D/F）
	_player_data.grades = _group_grades(s.get("gradeDistribution", {}))
	populate_profile()
	populate_mini_info()
	if profile_view:
		profile_view.update_display(_player_data)
		# 通知 ProfileView 刷新历史列表（成绩上传后会触发此路径）
		profile_view.refresh_history_lists()
	# 通知外部视图（如 ScoreView）统计已刷新，可同步更新显示
	stats_refreshed.emit()

## 将服务端返回的原始评级分布按字母前缀分组为 UI 用的 6 类（S/A/B/C/D/F）
## Ω/SSS/SS/S → S，A+/A/A- → A，以此类推；F 单独归 F
func _group_grades(raw_dist: Variant) -> Dictionary:
	var grouped := {"S": 0, "A": 0, "B": 0, "C": 0, "D": 0, "F": 0}
	if not raw_dist is Dictionary:
		return grouped
	var dist := raw_dist as Dictionary
	for rank_key in dist:
		var count := int(dist[rank_key])
		var rank_str := str(rank_key).to_upper()
		# Ω 及所有 S 开头的评级归入 S
		if rank_str == "Ω" or rank_str.begins_with("S"):
			grouped["S"] += count
		elif rank_str.begins_with("A"):
			grouped["A"] += count
		elif rank_str.begins_with("B"):
			grouped["B"] += count
		elif rank_str.begins_with("C"):
			grouped["C"] += count
		elif rank_str.begins_with("D"):
			grouped["D"] += count
		elif rank_str.begins_with("F"):
			grouped["F"] += count
	return grouped

# ========== 内容可见性（供 PlayerInfo 调用） ==========

## 收起状态切换 MiniInfo 内部可见性
func apply_mini_visibility(show_tip: bool) -> void:
	%TipText.visible = show_tip
	%MiniAvatar.visible = not show_tip
	%MiniData.visible = not show_tip

## 概要页切换（tab 2）：full 仅用于切换按钮文案，
## 全屏详情由 Main 下的 ProfileView 独立承担。
func apply_profile_visibility(full: bool) -> void:
	current_tab = 2
	%ExpandBtn.text = "收起详情" if full else "展开详情"

# ========== 登录表单 ==========
# 注册已下线到网页（2026-10-30）：服务端的注册接口强制 Cloudflare Turnstile 人机验证，
# 而 Godot 的 HTTPRequest 没有浏览器环境，解不出验证码——这是刻意的，不是缺陷。
# 客户端因此只负责"把人送到网页"和"登录"，不再收集注册信息。

## 站点地址与注册页。服务端有 /register 路由，会直接展开注册弹窗。
const WEBSITE_URL := "https://thmixce.org"
const REGISTER_URL := WEBSITE_URL + "/register"
## ErrorText 兼作提示条：错误为红（场景里定义），提示为蓝。
const HINT_COLOR := Color(0.45, 0.75, 1.0, 1.0)

## 「前往网页注册」：打开系统浏览器，登录表单保持原样。
func _on_register_btn_pressed() -> void:
	var err := OS.shell_open(REGISTER_URL)
	if err != OK:
		GLogger.warning("打开注册页失败(%d): %s" % [err, REGISTER_URL], "PlayerInfo")
		_show_hint("无法打开浏览器，请手动访问 %s" % REGISTER_URL, true)
		return
	_show_hint("已在浏览器打开注册页，注册完成后回到这里登录即可", false)

func _reset_login_form() -> void:
	%SubmitBtn.text = "登录"
	_show_hint("", false)

## 统一写 ErrorText：红色表示失败，蓝色表示提示。两处都不是"错误"的场景别再各写一套。
func _show_hint(text: String, is_error: bool) -> void:
	%ErrorText.text = text
	%ErrorText.add_theme_color_override("font_color", HINT_COLOR if not is_error else Color(1, 0.3, 0.3, 1.0))

func _on_submit_btn_pressed() -> void:
	if _submitting:
		return
	if AuthManager.instance == null:
		_show_hint("认证服务未就绪", true)
		return
	if NetManager.instance == null or not NetManager.instance.is_online:
		_show_hint("未连接服务器", true)
		return
	var account: String = %AccountEdit.text.strip_edges()
	var pwd: String = %PwdEdit.text
	if account.is_empty() or pwd.is_empty():
		_show_hint("帐号和密码不能为空", true)
		return

	_submitting = true
	%SubmitBtn.disabled = true
	_show_hint("处理中...", false)

	var result: Dictionary = await AuthManager.instance.login(account, pwd)
	var ok: bool = result.ok

	_submitting = false
	%SubmitBtn.disabled = false

	if ok:
		_clear_login_form()
		login_submitted.emit()
	else:
		var code := str(result.get("code", ""))
		var message := str(result.get("message", ""))
		if code == "login_requires_web":
			# 连续失败被人机验证挡住：客户端过不了验证码，只能引导去网页登录一次。
			# 网页登录成功后该账号的失败计数清零，回来即可正常登录。
			_show_hint("此账号需要安全验证，请用浏览器打开 %s 登录一次后再回来" % WEBSITE_URL, true)
		elif not message.is_empty():
			# 服务端的中文提示比"HTTP 401"有用得多
			_show_hint(message, true)
		else:
			_show_hint(_format_error(str(result.get("error", ""))), true)

## 登出按钮
func _on_logout_btn_pressed() -> void:
	if AuthManager.instance == null:
		return
	AuthManager.instance.logout()
	logout_submitted.emit()

## 将服务端错误码转为中文提示
func _format_error(err: String) -> String:
	match err:
		"username_taken":
			return "用户名已被占用"
		"invalid_credentials":
			return "用户名或密码错误"
		"network_error", "timeout":
			return "网络错误，请重试"
		_:
			return "操作失败: %s" % err if not err.is_empty() else "操作失败"

func _clear_login_form() -> void:
	%AccountEdit.text = ""
	%PwdEdit.text = ""
	%ErrorText.text = ""

# ========== 个人信息页面 ==========

## 从 _player_data 填充 Summary 的所有 label
func populate_profile() -> void:
	%ProfileName.text = _player_data.display_name if not _player_data.display_name.is_empty() else _player_data.name
	# 等级 = floor(sqrt(pp))，升级进度 = (pp - level²) / ((level+1)² - level²)
	var lvl := calc_level(_player_data.pp)
	var lvl_progress := calc_level_progress(_player_data.pp, lvl)
	_player_data.level = lvl
	_player_data.level_progress = lvl_progress
	%ProfileLevel.text = "Level %d" % lvl
	%ProfilePp.text = "%.2f pp" % _player_data.pp
	if _player_data.rank > 0:
		%ProfileRank.text = "Global Rank: #%d" % _player_data.rank
	else:
		%ProfileRank.text = "Unranked"
	%ProfileProgress.value = lvl_progress * 100.0
	# 个人简介
	%ProfileBio.text = _player_data.bio if not _player_data.bio.is_empty() else "还没有填写简介..."
	%TotalPlaysLabel.text = "Total Plays: %d" % _player_data.total_plays
	%AccuracyLabel.text = "Accuracy: %.2f%%" % _player_data.accuracy
	%MaxComboLabel.text = "Max Combo: %d" % _player_data.max_combo
	%PlayTimeLabel.text = "Play Time: %s" % _format_play_time(_player_data.play_duration_ms)

## 从 _player_data 填充 MiniData 的 label（收起状态显示）
func populate_mini_info() -> void:
	%MiniName.text = _player_data.display_name if not _player_data.display_name.is_empty() else _player_data.name
	# 等级与进度条同步
	var lvl := calc_level(_player_data.pp)
	var lvl_progress := calc_level_progress(_player_data.pp, lvl)
	%MiniLevel.text = "Lv%d" % lvl
	%MiniPp.text = "%.2f pp" % _player_data.pp
	%MiniProgress.value = lvl_progress * 100.0

## 计算等级：level = floor(sqrt(pp))
func calc_level(pp: float) -> int:
	return int(floor(sqrt(max(0.0, pp))))

## 计算从当前等级到下一级的升级进度（0.0 ~ 1.0）
## progress = (pp - level²) / ((level+1)² - level²)
func calc_level_progress(pp: float, level: int) -> float:
	var current_threshold := float(level) * float(level)
	var next_threshold := float(level + 1) * float(level + 1)
	var diff := next_threshold - current_threshold
	if diff <= 0.0:
		return 0.0
	return clamp((pp - current_threshold) / diff, 0.0, 1.0)

## 格式化游玩时长：不足 1 小时显示分钟，超过显示小时
func _format_play_time(ms: int) -> String:
	var total_minutes := int(ms / 60000.0)
	if total_minutes < 60:
		return "%dm" % total_minutes
	var hours := int(total_minutes / 60.0)
	return "%dh" % hours

func _on_expand_btn_pressed() -> void:
	expand_toggled.emit()

## 更新玩家数据并刷新显示
func update_player_data(player_data: Dictionary) -> void:
	for key in player_data:
		_player_data[key] = player_data[key]
	populate_profile()
	populate_mini_info()

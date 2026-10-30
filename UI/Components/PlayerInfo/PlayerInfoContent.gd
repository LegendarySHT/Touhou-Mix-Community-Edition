extends TabContainer
class_name PlayerInfoContent

## PlayerInfo 的内容容器，管理 MiniInfo / LogIn / ProfileView / ProfilePage 四个 tab。
## 负责表单交互、个人信息填充等页面内逻辑；
## 状态切换、面板几何动画由 PlayerInfo.gd 处理。

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

# MiniInfo（收起状态）
@onready var tip: Control = $MiniInfo/Tip
@onready var tip_label: Label = $MiniInfo/Tip/Label
@onready var avatar: Panel = $MiniInfo/Avatar
@onready var mini_avatar_rect: TextureRect = $MiniInfo/Avatar/TextureRect
@onready var profile_avatar_rect: TextureRect = $ProfileView/Header/AvatarBig/TextureRect
@onready var data: VBoxContainer = $MiniInfo/Data
@onready var mini_name: Label = $MiniInfo/Data/name
@onready var mini_level: Label = $MiniInfo/Data/level
@onready var mini_pp: Label = $MiniInfo/Data/pp
@onready var mini_progress: ProgressBar = $MiniInfo/Data/MC/ProgressBar
# LogIn（登录/注册表单）
@onready var login_tab: Button = $C/Skew/LogIn/ModeToggle/LoginTab
@onready var signup_tab: Button = $C/Skew/LogIn/ModeToggle/SignUpTab
@onready var account_edit: LineEdit = $C/Skew/LogIn/AccountLineEdit
@onready var pwd_edit: LineEdit = $C/Skew/LogIn/PwdLineEdit
@onready var confirm_pwd_label: Label = $C/Skew/LogIn/ConfirmPassword
@onready var confirm_pwd_edit: LineEdit = $C/Skew/LogIn/ConfirmPwdLineEdit
@onready var submit_btn: Button = $C/Skew/LogIn/SubmitBtn
@onready var error_msg: Label = $C/Skew/LogIn/ErrorMsg
# ProfileView（个人信息概要，半展开状态）
@onready var profile_name: Label = $ProfileView/Header/NameLevelVBox/NameLabel
@onready var profile_level: Label = $ProfileView/Header/NameLevelVBox/HBox/VBox/HBox/LevelLabel
@onready var profile_pp: Label = $ProfileView/Header/NameLevelVBox/HBox/VBox/HBox/PPLabel
@onready var profile_rank: Label = $ProfileView/Header/NameLevelVBox/HBox/RankLabel
@onready var profile_desc: Label = $ProfileView/Header/NameLevelVBox/HBox/VBox/Desc
@onready var level_progress: ProgressBar = $ProfileView/ProgressMC/LevelProgressBar
@onready var total_plays_label: Label = $ProfileView/StatsGrid/TotalPlaysLabel
@onready var accuracy_label: Label = $ProfileView/StatsGrid/AccuracyLabel
@onready var max_combo_label: Label = $ProfileView/StatsGrid/MaxComboLabel
@onready var play_time_label: Label = $ProfileView/StatsGrid/PlayTimeLabel
@onready var expand_btn: Button = $ProfileView/ExpandBtn
@onready var logout_btn: Button = $ProfileView/LogoutBtn
# ProfilePage（详情页，tab 3）
@onready var profile_page: ProfilePage = $ProfilePage

## 提交进行中（防止重复点击）
var _submitting: bool = false

func _ready() -> void:
	_set_login_mode()
	# 监听认证状态变化，自动同步显示
	if not EvtBus.auth_changed.is_connected(_on_auth_changed):
		EvtBus.auth_changed.connect(_on_auth_changed)
	# 监听网络状态变化：连接成功后若已登录，重新拉取资料/统计
	if not EvtBus.online_status_changed.is_connected(_on_online_status_changed):
		EvtBus.online_status_changed.connect(_on_online_status_changed)
	# 监听成绩上传成功，刷新统计
	if not EvtBus.score_uploaded.is_connected(_on_score_uploaded):
		EvtBus.score_uploaded.connect(_on_score_uploaded)
	# ProfilePage 资料更新后刷新
	if profile_page and not profile_page.profile_updated.is_connected(_fetch_profile_and_stats_async):
		profile_page.profile_updated.connect(_fetch_profile_and_stats_async)
	# ProfilePage 头像加载完成后，同步到 MiniInfo 和 ProfileView 的头像
	if profile_page and not profile_page.avatar_loaded.is_connected(_on_avatar_loaded):
		profile_page.avatar_loaded.connect(_on_avatar_loaded)
	# 启动时若已登录（从本地恢复会话），立即填充
	_sync_from_auth()

## ProfilePage 头像加载完成回调：同步到 MiniInfo/ProfileView 的头像
func _on_avatar_loaded(tex: Texture2D) -> void:
	if mini_avatar_rect:
		mini_avatar_rect.texture = tex
	if profile_avatar_rect:
		profile_avatar_rect.texture = tex

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
		profile_page.update_display(_player_data)
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
		var default_tex := load("res://Resources/icon/NoAvatar.jpg")
		if mini_avatar_rect:
			mini_avatar_rect.texture = default_tex
		if profile_avatar_rect:
			profile_avatar_rect.texture = default_tex
		if profile_page:
			profile_page.profile_avatar_rect.texture = default_tex
			profile_page.avatar_border.set_display_texture(default_tex)
		populate_profile()
		populate_mini_info()
		profile_page.update_display(_player_data)
		# 清空历史列表（退出登录时）
		profile_page.clear_history_lists()

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
		profile_page.update_display(_player_data)
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
	profile_page.update_display(_player_data)
	# 通知 ProfilePage 刷新历史列表（成绩上传后会触发此路径）
	profile_page.refresh_history_lists()
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
	tip_label.visible = show_tip
	avatar.visible = not show_tip
	data.visible = not show_tip

## ProfileView 详情切换：
## full=false（LOGGED_IN_EXPANDED）→ tab 2 概要页
## full=true （FULL_EXPANDED）      → tab 3 ProfilePage 详情页
func apply_profile_visibility(full: bool) -> void:
	current_tab = 3 if full else 2
	expand_btn.text = "收起详情" if full else "展开详情"

# ========== 登录表单 ==========
# 注册已下线到网页（2026-10-30）：服务端的注册接口强制 Cloudflare Turnstile 人机验证，
# 而 Godot 的 HTTPRequest 没有浏览器环境，解不出验证码——这是刻意的，不是缺陷。
# 客户端因此只负责"把人送到网页"和"登录"，不再收集注册信息。

## 站点地址与注册页。服务端有 /register 路由，会直接展开注册弹窗。
const WEBSITE_URL := "https://thmixce.org"
const REGISTER_URL := WEBSITE_URL + "/register"
## ErrorMsg 兼作提示条：错误为红（场景里定义），提示为蓝。
const HINT_COLOR := Color(0.45, 0.75, 1.0, 1.0)

func _on_login_tab_pressed() -> void:
	_set_login_mode()

## 「去网页注册」：打开系统浏览器，并保留当前登录表单（不切换模式）。
func _on_signup_tab_pressed() -> void:
	_set_login_mode()
	var err := OS.shell_open(REGISTER_URL)
	if err != OK:
		GLogger.warning("打开注册页失败(%d): %s" % [err, REGISTER_URL], "PlayerInfo")
		_show_hint("无法打开浏览器，请手动访问 %s" % REGISTER_URL, true)
		return
	_show_hint("已在浏览器打开注册页，注册完成后回到这里登录即可", false)

func _set_login_mode() -> void:
	login_tab.button_pressed = true
	signup_tab.button_pressed = false
	# 注册模式下才需要的「确认密码」保留在场景里但恒不显示（隐藏节点仍在，不影响布局）
	confirm_pwd_label.visible = false
	confirm_pwd_edit.visible = false
	submit_btn.text = "登录"
	_show_hint("", false)

## 统一写 ErrorMsg：红色表示失败，蓝色表示提示。两处都不是"错误"的场景别再各写一套。
func _show_hint(text: String, is_error: bool) -> void:
	error_msg.text = text
	error_msg.add_theme_color_override("font_color", HINT_COLOR if not is_error else Color(1, 0.3, 0.3, 1.0))

func _on_submit_btn_pressed() -> void:
	if _submitting:
		return
	if AuthManager.instance == null:
		_show_hint("认证服务未就绪", true)
		return
	if NetManager.instance == null or not NetManager.instance.is_online:
		_show_hint("未连接服务器", true)
		return
	var account := account_edit.text.strip_edges()
	var pwd := pwd_edit.text
	if account.is_empty() or pwd.is_empty():
		_show_hint("帐号和密码不能为空", true)
		return

	_submitting = true
	submit_btn.disabled = true
	_show_hint("处理中...", false)

	var result: Dictionary = await AuthManager.instance.login(account, pwd)
	var ok: bool = result.ok

	_submitting = false
	submit_btn.disabled = false

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
	account_edit.text = ""
	pwd_edit.text = ""
	confirm_pwd_edit.text = ""
	error_msg.text = ""

# ========== 个人信息页面 ==========

## 从 _player_data 填充 ProfileView 的所有 label
func populate_profile() -> void:
	profile_name.text = _player_data.display_name if not _player_data.display_name.is_empty() else _player_data.name
	# 等级 = floor(sqrt(pp))，升级进度 = (pp - level²) / ((level+1)² - level²)
	var lvl := calc_level(_player_data.pp)
	var lvl_progress := calc_level_progress(_player_data.pp, lvl)
	_player_data.level = lvl
	_player_data.level_progress = lvl_progress
	profile_level.text = "Level %d" % lvl
	profile_pp.text = "%.2f pp" % _player_data.pp
	if _player_data.rank > 0:
		profile_rank.text = "Global Rank: #%d" % _player_data.rank
	else:
		profile_rank.text = "Unranked"
	level_progress.value = lvl_progress * 100.0
	# 个人简介
	profile_desc.text = _player_data.bio if not _player_data.bio.is_empty() else "还没有填写简介..."
	total_plays_label.text = "Total Plays: %d" % _player_data.total_plays
	accuracy_label.text = "Accuracy: %.2f%%" % _player_data.accuracy
	max_combo_label.text = "Max Combo: %d" % _player_data.max_combo
	play_time_label.text = "Play Time: %s" % _format_play_time(_player_data.play_duration_ms)

## 从 _player_data 填充 MiniInfo/Data 的 label（收起状态显示）
func populate_mini_info() -> void:
	mini_name.text = _player_data.display_name if not _player_data.display_name.is_empty() else _player_data.name
	# 等级与进度条同步
	var lvl := calc_level(_player_data.pp)
	var lvl_progress := calc_level_progress(_player_data.pp, lvl)
	mini_level.text = "Lv%d" % lvl
	mini_pp.text = "%.2f pp" % _player_data.pp
	mini_progress.value = lvl_progress * 100.0

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

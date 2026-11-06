extends ViewBase
class_name ProfileView

## 个人信息详情页：Profile / History / Edit 三页切换
## Profile 页显示资料，Edit 页提供修改功能

## 资料更新成功后通知外部刷新（PlayerInfoContent 监听）
signal profile_updated()
## 头像上传成功后的新 URL（PlayerInfoContent 据此立即刷新各处头像）
signal avatar_uploaded(url: String)

# 被 PlayerInfoPanel 直接访问（pv.page_content.modulate.a）
@onready var page_content: TabContainer = %PageContent
# 需要调用 AvatarPreview 的专有方法
@onready var avatar_preview: AvatarPreview = %AvatarPreviewBorder

# PageContent tab 索引
const TAB_PROFILE := 0
const TAB_HISTORY := 1
const TAB_EDIT := 2
# History/List tab 索引
const LIST_RECENT := 0
const LIST_BEST := 1
const LIST_MOST := 2

# 记录列表项场景（preload 避免每次加载）
const RECORD_ITEM_SCENE := preload("res://UI/Views/ProfileView/recordListItem.tscn")
## 详情弹窗是通用组件，这里用 LIBRARY 模式（不下载，只提供本地谱面跳转）
const ChartDetailPageLib := preload("res://UI/Components/PopupWindow/ChartDetailPage.gd")
# 单页记录数
const RECORD_PAGE_LIMIT := 20
## 排名卡片「-」：未上榜 / 未登录 / 离线 / 接口失败
const RANK_PLACEHOLDER := "-"

## 操作进行中（防止重复点击）
var _busy: bool = false
## 打开详情的那条记录的按钮：关闭后把焦点还回去
## 头像 FileDialog（运行时创建）
var _avatar_file_dialog: FileDialog = null
## 待保存头像源图（本地选图解码后，保存时裁剪方形区域）
var _pending_avatar: Image = null

# 三个列表的懒加载状态标记
var _recent_loaded: bool = false
var _best_loaded: bool = false
var _most_loaded: bool = false
# 列表加载进行中（每列表独立，防止切换 tab 时互相阻塞导致加载被静默丢弃）
var _recent_loading: bool = false
var _best_loading: bool = false
var _most_loading: bool = false

# 年度排名：缓存 key = 账号 + 当前 pp（pp 变化即名次可能变化），避免资料/统计多次刷新重复打接口
var _ranks_busy: bool = false
var _ranks_cache_key: String = ""
var _ranks_cache: Array = []
var _last_pp: float = -1.0

func _on_view_ready() -> void:
	%ProfileBtn.pressed.connect(_on_navi_profile_pressed)
	%HistoryBtn.pressed.connect(_on_navi_history_pressed)
	%EditBtn.pressed.connect(_on_navi_edit_pressed)
	%RecentPlayBtn.pressed.connect(_on_recent_play_pressed)
	%BestPlayBtn.pressed.connect(_on_best_play_pressed)
	%MostPlayBtn.pressed.connect(_on_most_play_pressed)
	_sync_navi_selection(%PageContent.current_tab)
	_sync_topbtn_z_index(%RecentPlayBtn)
	# 密码输入框设为密文
	%PasswordEdit.secret = true
	%NewPasswordEdit.secret = true
	_reset_avatar_adjust()
	_setup_focus_tabs()
	# 头像卡（Border 整块卡片框）点击进入 Chara_View：卡片框接收点击，头像图透传
	%CharaCardBorder.gui_input.connect(_on_card_border_gui_input)
	# 角色展示：初始加载当前人物，并监听切换（选中角色后刷新）
	_load_chara_display()
	EvtBus.config_changed.connect(_on_config_changed)
	# 排名缓存失效源：成绩上传 / 网络状态 / 登录态变化。随后到来的资料刷新会重新拉取年度名次
	if not EvtBus.score_uploaded.is_connected(_on_rank_score_uploaded):
		EvtBus.score_uploaded.connect(_on_rank_score_uploaded)
	if not EvtBus.online_status_changed.is_connected(_on_rank_online_changed):
		EvtBus.online_status_changed.connect(_on_rank_online_changed)
	if not EvtBus.auth_changed.is_connected(_on_rank_auth_changed):
		EvtBus.auth_changed.connect(_on_rank_auth_changed)
	_init_rank_year_labels()
	# FileSystemManager 由 Main._ready 创建（晚于本节点 _ready），故延迟一帧再连扫描完成信号，
	# 保证启动扫描完成后能按最终选中的角色加载一次
	call_deferred("_connect_scan_ready")

	_setup_focus_tabs()

## 顶部导航按钮是资料页的标签栏：Tab / Shift+Tab 切换三页，页内控件交给方向键
func _setup_focus_tabs() -> void:
	var bar := FocusTabBar.new()
	bar.root = %ProfileBtn.get_parent()
	bar.page_root = self
	bar.buttons_fn = func() -> Array: return [%ProfileBtn, %HistoryBtn, %EditBtn]
	bar.current_fn = func() -> int: return %PageContent.current_tab
	bar.select_fn = func(i: int) -> void:
		%PageContent.current_tab = clampi(i, TAB_PROFILE, TAB_EDIT)
		_sync_navi_selection(%PageContent.current_tab)
	FocusMGR.register_tab_bar(bar)

func _connect_scan_ready() -> void:	if FileSystemManager.instance and not FileSystemManager.instance.resources_ready.is_connected(_load_chara_display):
		FileSystemManager.instance.resources_ready.connect(_load_chara_display)

## 角色切换（[Chara] chara_id）时刷新展示
func _on_config_changed(key: String, _value: Variant) -> void:
	if key == "chara_id":
		_load_chara_display()

## 加载当前选中角色的立绘、背景与名字/作者到 Displayer
func _load_chara_display() -> void:
	var key := CharaMGR.get_current_chara_key()
	if key.is_empty():
		return
	var data: Dictionary = CharaMGR.get_chara_data(key)
	var tex := CharaMGR.get_portrait(key, 0)
	if tex:
		%CharaPortrait.texture = tex
	var bg := CharaMGR.get_background(key)
	if bg:
		%CharaBackground.texture = bg
	# 名字与作者
	%CharaInfoName.text = str(data.get("name", key))
	%CharaInfoAuthor.text = "by %s" % str(data.get("author", ""))

## 头像卡点击：进入 CHARA_VIEW（标准视图导航，返回键经 UiState 栈回 PROFILE_VIEW）
func _on_card_border_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		UiStatMGR.change_state(UIStateManager.UIState.CHARA_VIEW)

## 出场：底栏下滑 + 内容区淡出，播完后隐藏（独立视图，避免盖住其它页面）
func _play_exit() -> Tween:
	if PopupWindow.instance != null:
		PopupWindow.instance.close_chart_detail()
	var navi := %Navi
	if navi:
		AniMGR.animate_offset_to(navi, Vector2(0, navi.size.y), 0.3, "ProfileNaviOut")
	var content := %PageContent
	if content == null:
		return null
	var tw := AniMGR.animate_fade_out(content, 0.3, "%s_out" % name)
	if tw and tw.is_valid():
		tw.finished.connect(func() -> void:
			if is_instance_valid(self) and UiStatMGR.current_state != UIStateManager.UIState.PROFILE_VIEW:
				visible = false
		)
	return tw

## 入场：底栏上滑 + 内容区淡入
func _play_enter() -> Tween:
	# 每次进入详情页强制刷一次年度名次：别人的成绩也会改变我的名次，不能只靠本机 pp 变化判断
	_refresh_yearly_ranks(true)
	var navi := %Navi
	if navi:
		navi.offset_transform_position = Vector2(0, navi.size.y)
		AniMGR.animate_offset_back(navi, 0.3, "ProfileNaviIn")
	var content := %PageContent
	if content == null:
		return null
	content.modulate.a = 0.0
	return AniMGR.animate_fade_in(content, 0.35, "%s_in" % name)

# ========== 主题色应用 ==========

func apply_theme() -> void:
	var p: Color = ThemeMGR.get_color("primary")
	var surface: Color = ThemeMGR.get_color("surface")
	var surface_high: Color = ThemeMGR.get_color("surface_high")
	var surface_hover: Color = ThemeMGR.get_color("surface_hover")
	var border: Color = ThemeMGR.get_color("border")
	var accent_border: Color = Color(p.r, p.g, p.b, 0.6)

	# 页面底色为 InfoPanelBtn 的 surface；本页内容面板统一用 surface_high 浮起（简介与最近游玩共享同一 StyleBox）
	_set_panel(%CharaInfoPanel, surface_high, accent_border)   # 角色立绘旁的信息栏
	_set_panel(%ProfileHeaderPanel, surface_high, border)      # 头像 / 昵称 / 等级头部
	_set_panel(%RecentPlayPanel, surface_high, border)         # 最近游玩列表
	_set_panel(%RankTotal, surface_high, accent_border)        # 总排名卡片
	# Navi 面板
	_set_panel(%Navi, surface, border)                         # 底栏与页面底色一致
	# History 顶部面板
	_set_panel_border(%HistoryPanel, border)
	# Navi 底栏三个按钮共用同一组 StyleBox，改 %ProfileBtn 即同步全部：
	#   normal  → 与所在底栏面板同色（surface），平时与底栏融为一体
	#   pressed → 与内容面板同色（surface_high，选中项并入内容区；浅色模式下即「略微变暗」）
	#   hover_pressed → 保持与 pressed 同色，避免选中项 hover 时闪回普通态
	_set_btn(%ProfileBtn, "normal", surface, border)
	_set_btn(%ProfileBtn, "pressed", surface_high, border)
	_set_btn(%ProfileBtn, "hover", surface_hover, accent_border)
	_set_btn(%ProfileBtn, "hover_pressed", surface_high, border)
	_set_btn(%ProfileBtn, "focus", surface, p)
	# History TopBtns
	_set_btn_border(%RecentPlayBtn, "pressed", p)
	_set_btn_border(%RecentPlayBtn, "hover", p)
	# MostPlay hover 用单独 StyleBox
	_set_btn_border(%MostPlayBtn, "hover", p)
	# Edit 页面 ConfirmBtn / UploadBtn（共享 StyleBox）
	_set_btn(%NicknameConfirmBtn, "normal", p.darkened(0.1), p)
	_set_btn(%NicknameConfirmBtn, "pressed", p.darkened(0.3), p)
	_set_btn(%NicknameConfirmBtn, "hover", p, p)
	# 圆角头像 / 角色卡的外圈细描边：tscn 里硬编码成淡蓝 #93B4FF（= primary_light 的初值），
	# 换主题色后仍是蓝的。这里按外观模式取强调色：深色用 primary_light（亮，暗底上才看得见），
	# 浅色用 primary（深，浅底上才看得见）。
	# 共 3 个空心描边 StyleBox：资料页大头像 / 编辑页头像预览框 / 角色展示卡。
	_set_panel_border_keep_alpha(%ProfileAvatarBorder, _avatar_ring_color())
	_set_panel_border_keep_alpha(avatar_preview, _avatar_ring_color())
	_set_panel_border_keep_alpha(%CharaCardBorder, _avatar_ring_color())

## 设置面板 bg + border
func _set_panel(node: Control, bg: Color, border: Color) -> void:
	if not node:
		return
	var sb := node.get_theme_stylebox("panel")
	sb.bg_color = bg
	sb.border_color = border

## 仅设置面板 border（保留原 bg）
func _set_panel_border(node: Control, border: Color) -> void:
	if not node:
		return
	node.get_theme_stylebox("panel").border_color = border

## 仅设置面板 border，并保留该 StyleBox 原有的 border alpha。
## 头像描边的 alpha 是刻意调过的（头像 0.9 / 角色卡 0.7），刷主题色时不能被冲掉。
func _set_panel_border_keep_alpha(node: Control, border: Color) -> void:
	if not node:
		return
	var sb := node.get_theme_stylebox("panel")
	sb.border_color = Color(border.r, border.g, border.b, sb.border_color.a)

## 头像/角色卡外圈描边的颜色：深色用亮调强调色，浅色用强调色本身
func _avatar_ring_color() -> Color:
	if ThemeMGR.get_appearance() == "light":
		return ThemeMGR.get_color("primary")
	return ThemeMGR.get_color("primary_light")

## 设置按钮某状态的 bg + border
func _set_btn(btn: Button, state: String, bg: Color, border: Color) -> void:
	if not btn:
		return
	var sb := btn.get_theme_stylebox(state)
	sb.bg_color = bg
	sb.border_color = border

## 仅设置按钮某状态的 border（保留原 bg 和 border alpha）
func _set_btn_border(btn: Button, state: String, border: Color) -> void:
	if not btn:
		return
	var sb := btn.get_theme_stylebox(state)
	sb.border_color = Color(border.r, border.g, border.b, sb.border_color.a)

# ========== Navi → PageContent 切换 ==========

func _on_navi_profile_pressed() -> void:
	%PageContent.current_tab = TAB_PROFILE

func _on_navi_history_pressed() -> void:
	%PageContent.current_tab = TAB_HISTORY

func _on_navi_edit_pressed() -> void:
	%PageContent.current_tab = TAB_EDIT

func _sync_navi_selection(tab_idx: int) -> void:
	%ProfileBtn.button_pressed = (tab_idx == TAB_PROFILE)
	%HistoryBtn.button_pressed = (tab_idx == TAB_HISTORY)
	%EditBtn.button_pressed = (tab_idx == TAB_EDIT)

# ========== History TopBar → List 切换 + z_index ==========

func _on_recent_play_pressed() -> void:
	_switch_history_list(LIST_RECENT, %RecentPlayBtn)
	if not _recent_loaded:
		_load_recent_scores()

func _on_best_play_pressed() -> void:
	_switch_history_list(LIST_BEST, %BestPlayBtn)
	if not _best_loaded:
		_load_best_scores()

func _on_most_play_pressed() -> void:
	_switch_history_list(LIST_MOST, %MostPlayBtn)
	if not _most_loaded:
		_load_most_played()

## 切换 History/List 的 tab，并把激活按钮 z_index 抬到 1，其余压回 0
## 避免相邻按钮 stylebox 超边界部分被遮挡
func _switch_history_list(tab_idx: int, active_btn: Button) -> void:
	if tab_idx < %HistoryTabs.get_tab_count():
		%HistoryTabs.current_tab = tab_idx
	_sync_topbtn_z_index(active_btn)

func _sync_topbtn_z_index(active_btn: Button) -> void:
	%RecentPlayBtn.z_index = 1 if %RecentPlayBtn == active_btn else 0
	%BestPlayBtn.z_index = 1 if %BestPlayBtn == active_btn else 0
	%MostPlayBtn.z_index = 1 if %MostPlayBtn == active_btn else 0

# ========== 资料显示（由 PlayerInfoContent 调用） ==========

## 从 PlayerInfoContent 传入玩家数据，更新 Profile 页显示
func update_display(data: Dictionary) -> void:
	var display_name_raw = data.get("display_name", "")
	var display_name := str(display_name_raw) if display_name_raw != null else ""
	if display_name.is_empty() or display_name == "<null>":
		var name_raw = data.get("name", "Anonymous Player")
		display_name = str(name_raw) if name_raw != null else "Anonymous Player"
	%ProfileNameText.text = display_name
	%ProfilePPText.text = "%.2f pp" % float(data.get("pp", 0.0))
	var bio_raw = data.get("bio", "")
	var bio := str(bio_raw) if bio_raw != null else ""
	%ProfileDescription.text = bio if not bio.is_empty() and bio != "<null>" else "还没有填写简介..."
	# 同步 History 页统计：总 pp + 各评级数量
	%HistoryPp.text = "%.2f pp" % float(data.get("pp", 0.0))
	var grades = data.get("grades", {})
	if grades == null:
		grades = {}
	%GradeCountS.text = str(int(grades.get("S", 0)))
	%GradeCountA.text = str(int(grades.get("A", 0)))
	%GradeCountB.text = str(int(grades.get("B", 0)))
	%GradeCountC.text = str(int(grades.get("C", 0)))
	%GradeCountD.text = str(int(grades.get("D", 0)))
	%GradeCountF.text = str(int(grades.get("F", 0)))
	# 同步 Edit 页输入框为当前值
	%NicknameEdit.text = display_name
	%DescEdit.text = bio
	_update_level(data)
	_update_total_rank(data)
	_last_pp = float(data.get("pp", 0.0))
	_refresh_yearly_ranks()

# ========== 等级进度条与排名卡片 ==========

## 等级进度条：等级/进度公式与 PlayerInfoContent.calc_level / calc_level_progress 同源
## （优先直接复用其实例，避免公式两处维护；实例未就绪时用同一公式兜底）。
## 数值驱动方式参考 Main.tscn 的 ProcessTip/ProcessProgress —— FileSystemManager.show_progress_ui
## 设 min=0 / max=100 / value / show_percentage，进度条自带百分比文字。
func _update_level(data: Dictionary) -> void:
	var pp := maxf(0.0, float(data.get("pp", 0.0)))
	var lvl := 0
	var progress := 0.0
	var pic := GlobalNodes.player_info_tabs as PlayerInfoContent
	if pic:
		lvl = pic.calc_level(pp)
		progress = clampf(pic.calc_level_progress(pp, lvl), 0.0, 1.0)
	else:
		lvl = int(floor(sqrt(pp)))
		var threshold := float(lvl) * float(lvl)
		var span := float(lvl + 1) * float(lvl + 1) - threshold
		progress = clampf((pp - threshold) / span, 0.0, 1.0) if span > 0.0 else 0.0
	%ProfileLevelText.text = "Level %d" % lvl
	var bar: ProgressBar = %ProfileLevelingBar
	bar.min_value = 0.0
	bar.max_value = 100.0
	bar.value = progress * 100.0
	bar.show_percentage = true

## 总榜名次来自 me/stats 的 globalRank（PlayerInfoContent 写入 _player_data.rank）
func _update_total_rank(data: Dictionary) -> void:
	%RankTotalValue.text = _format_rank(data.get("rank", 0))

## 未上榜（null / 0 / 非正数）统一显示「-」
func _format_rank(value: Variant) -> String:
	if value == null:
		return RANK_PLACEHOLDER
	var r := int(value)
	return "#%d" % r if r > 0 else RANK_PLACEHOLDER

## 年度榜按服务端 UTC+8 自然年划分，本地先按同一口径摆好「当前年 + 上一年」占位年份；
## 接口返回后再用响应里的年份覆盖（服务端才是年份真相）。
func _init_rank_year_labels() -> void:
	var y := _current_utc8_year()
	%RankPastYear.text = str(y)
	%RankPast2Year.text = str(y - 1)

func _current_utc8_year() -> int:
	# get_datetime_dict_from_unix_time 没有 utc 形参（4.7）：时间戳本身按 UTC 解释，
	# 因此先 +8h 再取年份，得到的就是 UTC+8 的当前年，与服务端年度榜划分一致。
	var shifted := int(Time.get_unix_time_from_system()) + 8 * 3600
	return int(Time.get_datetime_dict_from_unix_time(shifted).get("year", 2026))

## 排名缓存失效：只清 key，等随后必然到来的 update_display 重新拉取，避免同一次刷新打两次接口
func _on_rank_score_uploaded(_midi_hash: String) -> void:
	_ranks_cache_key = ""

func _on_rank_auth_changed(_user_data: Variant) -> void:
	_ranks_cache_key = ""

func _on_rank_online_changed(online: bool, _message: String) -> void:
	_ranks_cache_key = ""
	if not online:
		_set_yearly_rank_values(RANK_PLACEHOLDER, RANK_PLACEHOLDER)

## 拉取当前用户最近两年的年度名次。force 用于每次进入详情页时绕过缓存取新值。
func _refresh_yearly_ranks(force: bool = false) -> void:
	if _ranks_busy:
		return
	var logged_in := AuthManager.instance != null and AuthManager.instance.is_logged_in
	var online := NetManager.instance != null and NetManager.instance.is_online
	if not logged_in or not online:
		_ranks_cache_key = ""
		_ranks_cache = []
		_set_yearly_rank_values(RANK_PLACEHOLDER, RANK_PLACEHOLDER)
		return
	var username := str(AuthManager.instance.current_user.get("username", ""))
	var key := "%s|%s" % [username, "%.2f" % _last_pp]
	if not force and key == _ranks_cache_key:
		_apply_yearly_ranks(_ranks_cache)
		return
	_ranks_busy = true
	# 语句形式调用协程＝合法的即发即忘；结果由函数内部异步处理
	_fetch_yearly_ranks(key, username)

func _fetch_yearly_ranks(key: String, username: String) -> void:
	var result: Dictionary = await AuthManager.instance.get_my_rankings()
	_ranks_busy = false
	if not is_instance_valid(self):
		return
	# 请求期间切换账号 / 登出：丢弃过期结果
	var current := ""
	if AuthManager.instance and AuthManager.instance.is_logged_in:
		current = str(AuthManager.instance.current_user.get("username", ""))
	if current != username:
		return
	if not result.get("ok", false) or not result.data is Dictionary:
		GLogger.warning("Failed to load yearly rankings: %s" % str(result.get("error", "")), "ProfileView")
		# 失败也记下这一代 key，避免同一次资料刷新里反复重试；网络/登录态变化会重新失效
		_ranks_cache_key = key
		_ranks_cache = []
		_set_yearly_rank_values(RANK_PLACEHOLDER, RANK_PLACEHOLDER)
		return
	var raw: Variant = result.data.get("ranks", null)
	var ranks: Array = []
	if raw is Array:
		ranks = raw
	_ranks_cache = ranks
	_ranks_cache_key = key
	_apply_yearly_ranks(_ranks_cache)

## 名次按年份降序：ranks[0] = 当前年，ranks[1] = 上一年
func _apply_yearly_ranks(ranks: Array) -> void:
	var first: Dictionary = {}
	var second: Dictionary = {}
	if ranks.size() > 0 and ranks[0] is Dictionary:
		first = ranks[0]
	if ranks.size() > 1 and ranks[1] is Dictionary:
		second = ranks[1]
	if not first.is_empty():
		%RankPastYear.text = str(int(first.get("year", 0)))
	if not second.is_empty():
		%RankPast2Year.text = str(int(second.get("year", 0)))
	_set_yearly_rank_values(_format_rank(first.get("rank", null)),
		_format_rank(second.get("rank", null)))

func _set_yearly_rank_values(current_year_rank: String, previous_year_rank: String) -> void:
	%RankPastValue.text = current_year_rank
	%RankPast2Value.text = previous_year_rank

## 头像上屏：Profile 页大图 + Edit 页预览。
## 头像由 PlayerInfoContent 统一加载（MiniInfo/Summary 也要用），这里只负责显示。
func set_avatar_texture(tex: Texture2D) -> void:
	if tex == null:
		return
	%ProfileAvatar.texture = tex
	avatar_preview.set_display_texture(tex)

# ========== Edit 页面：资料修改 ==========

## 保存昵称
func _on_save_nickname_btn_pressed() -> void:
	if _busy:
		return
	if AuthManager.instance == null or not AuthManager.instance.is_logged_in:
		return
	var new_name := (%NicknameEdit as LineEdit).text.strip_edges()
	if new_name.is_empty():
		return
	_busy = true
	%NicknameConfirmBtn.disabled = true
	var result: Dictionary = await AuthManager.instance.update_profile(new_name, null)
	_busy = false
	%NicknameConfirmBtn.disabled = false
	if result.get("ok", false):
		GLogger.info("Nickname updated: %s" % new_name, "ProfileView")
		profile_updated.emit()
	else:
		GLogger.warning("Nickname update failed: %s" % str(result.get("error", "")), "ProfileView")

## 保存简介
func _on_save_desc_btn_pressed() -> void:
	if _busy:
		return
	if AuthManager.instance == null or not AuthManager.instance.is_logged_in:
		return
	var new_bio := (%DescEdit as LineEdit).text.strip_edges()
	_busy = true
	%DescConfirmBtn.disabled = true
	var result: Dictionary = await AuthManager.instance.update_profile(null, new_bio)
	_busy = false
	%DescConfirmBtn.disabled = false
	if result.get("ok", false):
		GLogger.info("Bio updated", "ProfileView")
		profile_updated.emit()
	else:
		GLogger.warning("Bio update failed: %s" % str(result.get("error", "")), "ProfileView")

## 修改密码
func _on_save_pwd_btn_pressed() -> void:
	if _busy:
		return
	if AuthManager.instance == null or not AuthManager.instance.is_logged_in:
		return
	var old_pwd: String = %PasswordEdit.text
	var new_pwd: String = %NewPasswordEdit.text
	if old_pwd.is_empty() or new_pwd.is_empty():
		return
	if new_pwd.length() < 6:
		%NewPasswordEdit.text = ""
		return
	_busy = true
	%PasswordConfirmBtn.disabled = true
	var result: Dictionary = await AuthManager.instance.change_password(old_pwd, new_pwd)
	_busy = false
	%PasswordConfirmBtn.disabled = false
	if result.get("ok", false):
		GLogger.info("Password changed", "ProfileView")
		%PasswordEdit.text = ""
		%NewPasswordEdit.text = ""
	else:
		GLogger.warning("Password change failed: %s" % str(result.get("error", "")), "ProfileView")
		%PasswordEdit.text = ""

## 上传头像：弹出 FileDialog 选择图片
func _on_upload_avatar_btn_pressed() -> void:
	if _busy:
		return
	if AuthManager.instance == null or not AuthManager.instance.is_logged_in:
		return
	if NetManager.instance == null or not NetManager.instance.is_online:
		return
	if _avatar_file_dialog == null:
		_avatar_file_dialog = FileDialog.new()
		_avatar_file_dialog.use_native_dialog = true
		_avatar_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_avatar_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_avatar_file_dialog.filters = PackedStringArray(["*.png ; PNG Image", "*.jpg ; JPEG Image", "*.jpeg ; JPEG Image"])
		_avatar_file_dialog.title = "选择头像图片"
		add_child(_avatar_file_dialog)
		_avatar_file_dialog.file_selected.connect(_on_avatar_file_selected)
	_avatar_file_dialog.popup_centered_clamped(Vector2i(800, 600))

## 保存头像：裁剪预览方形区域 → PNG 编码 → 上传
func _on_save_avatar_btn_pressed() -> void:
	if _busy:
		return
	if _pending_avatar == null:
		GLogger.info("No avatar selected to save", "ProfileView")
		return
	if AuthManager.instance == null or not AuthManager.instance.is_logged_in:
		return
	if NetManager.instance == null or not NetManager.instance.is_online:
		return
	# 由预览偏移/缩放反推方形裁剪区（源图像素坐标），缩放以左上角为锚点
	var img := _pending_avatar
	var s: float = %AvatarZoomSlider.value
	if s <= 0.0:
		return
	var view := avatar_preview.get_box_size()
	var off := avatar_preview.offset
	# STRETCH_KEEP + 左上角锚：off 即缩放后图片左上角，源图像素 q=(p-off)/s，
	# 屏幕 [0, view] 对应源图区域 = -off/s + (view/s)
	var crop_rect := Rect2(-off / s, view / s)
	crop_rect = crop_rect.intersection(Rect2(0, 0, img.get_width(), img.get_height()))
	if crop_rect.size.x < 1 or crop_rect.size.y < 1:
		GLogger.warning("Avatar crop region empty", "ProfileView")
		return
	var square := img.get_region(Rect2i(crop_rect))
	# 限制输出最长边 <= 512，避免上传超大图
	var max_side := maxi(square.get_width(), square.get_height())
	if max_side > 512:
		var ratio := 512.0 / max_side
		square.resize(maxi(1, int(square.get_width() * ratio)), maxi(1, int(square.get_height() * ratio)))
	var png := square.save_png_to_buffer()
	if png.is_empty():
		GLogger.warning("Avatar PNG encode failed", "ProfileView")
		return
	_busy = true
	%AvatarSaveBtn.disabled = true
	var image_base64 := Marshalls.raw_to_base64(png)
	var result: Dictionary = await AuthManager.instance.upload_avatar(image_base64, "image/png")
	_busy = false
	%AvatarSaveBtn.disabled = false
	if result.get("ok", false):
		GLogger.info("Avatar uploaded", "ProfileView")
		# 上传响应里的新头像 URL 交给 PlayerInfoContent 统一加载，避免等一次资料拉取
		if result.data is Dictionary:
			var av = result.data.get("avatarUrl", "")
			var av_url := str(av) if av != null else ""
			if not av_url.is_empty():
				avatar_uploaded.emit(av_url)
		profile_updated.emit()
		# 保存成功：复位预览变换并隐藏调整控件（回到「仅显示当前头像」）
		_reset_avatar_adjust()
	else:
		GLogger.warning("Avatar upload failed: %s" % str(result.get("error", "")), "ProfileView")

## FileDialog 选择图片后：解码载入预览（保存时再裁剪上传）
func _on_avatar_file_selected(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() == 0:
		return
	# 源图过大时直接拒绝（解码占用内存）
	if bytes.size() > 8 * 1024 * 1024:
		GLogger.warning("Avatar too large (>%d bytes), skipping" % (8 * 1024 * 1024), "ProfileView")
		return
	var img := Image.new()
	var ext := path.get_extension().to_lower()
	var err := OK
	if ext == "jpg" or ext == "jpeg":
		err = img.load_jpg_from_buffer(bytes)
		if err != OK:
			err = img.load_png_from_buffer(bytes)
	else:
		err = img.load_png_from_buffer(bytes)
		if err != OK:
			err = img.load_jpg_from_buffer(bytes)
	if err != OK or img.get_width() <= 0 or img.get_height() <= 0:
		GLogger.warning("Avatar image decode failed (not PNG/JPG): %s" % path, "ProfileView")
		return
	# 过长边降到 2048 内，避免预览/记忆体浪费
	var max_side := maxi(img.get_width(), img.get_height())
	if max_side > 2048:
		var ratio := 2048.0 / max_side
		img.resize(maxi(1, int(img.get_width() * ratio)), maxi(1, int(img.get_height() * ratio)))
	_show_avatar_preview(img)
	GLogger.info("Avatar loaded for preview: %s" % path, "ProfileView")

## 载入源图到预览：交给 Border 自绘（可平移/缩放）
func _show_avatar_preview(img: Image) -> void:
	_pending_avatar = img
	avatar_preview.set_source_image(img)
	%AvatarZoomSlider.value = 1.0
	%AvatarZoomSlider.visible = true

## 缩放滑条：更新缩放并保持位置边界
func _on_avatar_zoom_changed(value: float) -> void:
	if _pending_avatar == null:
		return
	avatar_preview.set_zoom(value)

## 回到「仅显示当前头像」状态：清除待调整图、隐藏滑条
## 拖拽/缩放/裁剪状态由 Border 内部持有，退出详情页时清空即可恢复显示当前头像
func _reset_avatar_adjust() -> void:
	_pending_avatar = null
	avatar_preview.clear_preview()
	%AvatarZoomSlider.value = 1.0
	%AvatarZoomSlider.visible = false

# ========== History 页成绩列表加载 ==========

## 加载最近游玩记录
func _load_recent_scores() -> void:
	if _recent_loading:
		return
	if AuthManager.instance == null or not AuthManager.instance.is_logged_in:
		return
	if NetManager.instance == null or not NetManager.instance.is_online:
		return
	_recent_loading = true
	var result: Dictionary = await AuthManager.instance.get_recent_scores(RECORD_PAGE_LIMIT, 0)
	_recent_loading = false
	if not is_instance_valid(self):
		return
	if not result.get("ok", false) or not result.data is Dictionary:
		GLogger.warning("Failed to load recent scores: %s" % str(result.get("error", "")), "ProfileView")
		return
	_populate_records(%RecentPlayList, result.data.get("records", []), RecordListItem.RecordMode.RECENT)
	_recent_loaded = true

## 加载最佳记录（按 MIDI 去重）
func _load_best_scores() -> void:
	if _best_loading:
		return
	if AuthManager.instance == null or not AuthManager.instance.is_logged_in:
		return
	if NetManager.instance == null or not NetManager.instance.is_online:
		return
	_best_loading = true
	var result: Dictionary = await AuthManager.instance.get_best_scores(RECORD_PAGE_LIMIT, 0)
	_best_loading = false
	if not is_instance_valid(self):
		return
	if not result.get("ok", false) or not result.data is Dictionary:
		GLogger.warning("Failed to load best scores: %s" % str(result.get("error", "")), "ProfileView")
		return
	_populate_records(%BestPlayList, result.data.get("records", []), RecordListItem.RecordMode.BEST)
	_best_loaded = true

## 加载最多游玩记录
func _load_most_played() -> void:
	if _most_loading:
		return
	if AuthManager.instance == null or not AuthManager.instance.is_logged_in:
		return
	if NetManager.instance == null or not NetManager.instance.is_online:
		return
	_most_loading = true
	var result: Dictionary = await AuthManager.instance.get_most_played(RECORD_PAGE_LIMIT, 0)
	_most_loading = false
	if not is_instance_valid(self):
		return
	if not result.get("ok", false) or not result.data is Dictionary:
		GLogger.warning("Failed to load most played: %s" % str(result.get("error", "")), "ProfileView")
		return
	_populate_records(%MostPlayList, result.data.get("records", []), RecordListItem.RecordMode.MOST)
	_most_loaded = true

## 清空 VBox 并填充记录项
func _populate_records(vbox: VBoxContainer, records: Array, mode: int) -> void:
	for child in vbox.get_children():
		child.queue_free()
	for record in records:
		var item := RECORD_ITEM_SCENE.instantiate() as RecordListItem
		vbox.add_child(item)
		item.detail_requested.connect(_on_record_detail_requested)
		item.setup_record(record, mode)


# ========== 记录详情 ==========

func _on_record_detail_requested(record: Dictionary, source_rect: Rect2, _source: Control) -> void:
	var hash_str := str(record.get("midiHash", ""))
	if hash_str.is_empty():
		return
	PopupWindow.instance.show_chart_detail(_item_for_record(record, hash_str),
		ChartDetailPageLib.Mode.LIBRARY, source_rect)


## 记录 DTO + 本地 MidiData 拼成详情条目（字段口径与商店归一化一致）
func _item_for_record(record: Dictionary, hash_str: String) -> Dictionary:
	var midi: MidiData = DataMGR.get_midi_by_id(hash_str)
	var server := NetManager.instance.server_url if NetManager.instance else ""
	var has_cover := bool(record.get("hasCover", false))
	return {
		"kind": "song",
		"hash": hash_str,
		"title": _first_non_empty([
			midi.name if midi else "", record.get("midiName", ""),
		], "未命名谱面"),
		"author": _first_non_empty([
			midi.author_name if midi else "",
			midi.artist_name if midi else "",
			record.get("midiAuthor", ""),
		], ""),
		"album": midi.album_name if midi else "",
		"song": midi.song_name if midi else "",
		"desc": midi.description if midi else "",
		"uploaded_at": midi.uploaded_date if midi else "",
		"downloads": midi.download_count if midi else -1,
		"plays": midi.trial_count if midi else -1,
		"likes": midi.up_count if midi else -1,
		"dislikes": midi.down_count if midi else -1,
		"cover_url": ("%s/api/charts/%s/cover" % [server, hash_str]) \
			if (has_cover and not server.is_empty()) else "",
	}


func _first_non_empty(values: Array, fallback: String) -> String:
	for v in values:
		if v == null:
			continue
		var s := str(v).strip_edges()
		if not s.is_empty() and s != "<null>":
			return s
	return fallback


## Main 的全局返回键调用：详情打开时先关详情
func handle_back_request() -> bool:
	if PopupWindow.instance != null and PopupWindow.instance.is_chart_detail_open():
		PopupWindow.instance.close_chart_detail()
		return true
	return false


## 刷新所有历史列表（成绩上传后调用）：清空已加载标记并重新加载当前 Tab
func refresh_history_lists() -> void:
	_recent_loaded = false
	_best_loaded = false
	_most_loaded = false
	# 重新加载当前可见的 Tab
	match %HistoryTabs.current_tab:
		LIST_RECENT:
			_load_recent_scores()
		LIST_BEST:
			_load_best_scores()
		LIST_MOST:
			_load_most_played()

## 清空所有历史列表（退出登录时调用）
func clear_history_lists() -> void:
	for child in %RecentPlayList.get_children():
		child.queue_free()
	for child in %BestPlayList.get_children():
		child.queue_free()
	for child in %MostPlayList.get_children():
		child.queue_free()
	_recent_loaded = false
	_best_loaded = false
	_most_loaded = false

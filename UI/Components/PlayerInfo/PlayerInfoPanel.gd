extends Control

# ========== 状态 ==========
# LOGGED_OUT:          未登录 mini 收起，只显示 Tip/Label
# LOGGED_IN:           已登录收起，显示 Avatar + Data
# EXPANDED:            未登录展开（登录/注册表单）
# LOGGED_IN_EXPANDED:  已登录半展开，显示个人信息概要
# FULL_EXPANDED:       全屏展开，显示个人信息详情
enum State { LOGGED_OUT, LOGGED_IN, EXPANDED, LOGGED_IN_EXPANDED, FULL_EXPANDED }

# ========== 常量 ==========
const SKEW_COLLAPSED := 0.55
const SKEW_EXPANDED := 0.268
const TIP_WIDTH_LOGGED_OUT := 100.0
const TIP_WIDTH_LOGGED_IN := 0.0
const MINI_COLLAPSE_OFFSET := Vector2(-370, -200)
const COLLAPSE_OFFSET := Vector2(-850, -200)
const EXPAND_OFFSET := Vector2(-1050, -680)
const ANIM_DURATION := 0.35
# 完全展开时面板高度额外加 8，防止露出顶上边界线
const FULL_EXPAND_EXTRA_HEIGHT := 8.0
# TabC 展开状态的额外左偏移（相对 margin）和顶偏移
const TAB_OFFSET_LEFT_EXPANDED := 50.0
const TAB_OFFSET_LEFT_FULL := 150.0
const TAB_OFFSET_TOP_EXPANDED := 50.0
const TAB_OFFSET_TOP_COLLAPSED := 10.0
# TabC 右侧预留（给 RB_Btn 等留位置）
const TAB_RIGHT_RESERVE_NORM := 150.0

# ========== 节点 ==========
@onready var info_panel_btn: SkewButton = $InfoPanelBtn
@onready var info_tab_c: PlayerInfoContent = $InfoPanelBtn/TabC
@onready var _btn_styleboxes: Array[StyleBoxFlat] = [
	info_panel_btn.get_theme_stylebox("normal"),
	info_panel_btn.get_theme_stylebox("pressed"),
	info_panel_btn.get_theme_stylebox("hover"),
]
@onready var shader_overlay: ColorRect = $ExpandPanelShader
@onready var shortcut_menu = get_node_or_null(PathRegistry.SHORTCUT_MENU)
@onready var rb_btn = get_node_or_null(PathRegistry.RB_BTN)

# ========== 运行时 ==========
var _state: State = State.LOGGED_OUT
var _tween: Tween = null
var _login_result: bool = false
var _saved_rb_stat = -1

func _ready() -> void:
	# 跨场景信号：内容容器的登录提交 / 登出 / 详情切换 → 状态机
	info_tab_c.login_submitted.connect(set_logged_in)
	info_tab_c.logout_submitted.connect(set_logged_out)
	info_tab_c.expand_toggled.connect(_on_expand_toggled)
	# 监听认证状态变化（AuthManager 在 Main._ready 中才创建，
	# 其 _ready 恢复会话后 emit auth_changed，此处需要响应）
	if not EvtBus.auth_changed.is_connected(_on_auth_changed):
		EvtBus.auth_changed.connect(_on_auth_changed)
	UiStatMGR.state_changed.connect(_on_ui_state_changed)
	# 启动时若已登录（AuthManager 可能已恢复会话），直接进入已登录状态
	if AuthManager.instance != null and AuthManager.instance.is_logged_in:
		_animate_to_state(State.LOGGED_IN)
	else:
		_animate_to_state(State.LOGGED_OUT)

## 认证状态变化回调：根据登录态切换 UI 状态
func _on_auth_changed(user_data: Variant) -> void:
	if user_data != null and user_data is Dictionary:
		# 已登录
		if _state == State.LOGGED_OUT or _state == State.EXPANDED:
			set_logged_in()
	else:
		# 未登录
		set_logged_out()

# ========== 状态应用 ==========

func _animate_to_state(s: State) -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
	# 离开 ProfilePage 详情页（FULL_EXPANDED）时复位头像调整区，恢复首次进入时的状态
	if _state == State.FULL_EXPANDED and s != State.FULL_EXPANDED:
		info_tab_c.profile_page._reset_avatar_adjust()
	_tween = AniMGR.create_managed_tween(self)
	_tween.set_parallel(true)
	_tween.set_ease(Tween.EASE_OUT)
	_tween.set_trans(Tween.TRANS_CUBIC)

	_apply_content_visibility(s)
	_animate_panel_geometry(s, _tween)
	_animate_tip(s, _tween)
	_animate_overlay(s, _tween)

	match s:
		State.LOGGED_OUT, State.LOGGED_IN:
			if UiStatMGR.current_state != UIStateManager.UIState.NONE:
				_play_shortcut_menu_enter()
			_setup_rb_btn_for_state(s)
		State.EXPANDED, State.LOGGED_IN_EXPANDED, State.FULL_EXPANDED:
			_play_shortcut_menu_exit()
			_setup_rb_btn_for_state(s)

	# 全屏详情（FULL_EXPANDED）对应用户模型 PROFILE_VIEW 状态：进入/退出走 UIState 栈，
	# 让 PROFILE → CHARA → 返回等导航复用标准 change_state/go_back，无需特判
	if s == State.FULL_EXPANDED:
		if UiStatMGR.current_state != UIStateManager.UIState.PROFILE_VIEW:
			var pp := info_tab_c.profile_page
			if pp:
				pp.page_content.modulate.a = 0.0
				var navi := pp.get_node_or_null("Navi")
				if navi:
					navi.offset_transform_enabled = true
					navi.offset_transform_position = Vector2(0, navi.size.y)
			UiStatMGR.change_state(UIStateManager.UIState.PROFILE_VIEW, true)
	elif _state == State.FULL_EXPANDED:
		if UiStatMGR.current_state == UIStateManager.UIState.PROFILE_VIEW:
			UiStatMGR.go_back()

	_state = s

# ========== 内容可见性 ==========

func _is_expanded(s: State) -> bool:
	return s == State.EXPANDED or s == State.LOGGED_IN_EXPANDED or s == State.FULL_EXPANDED

## 3-way 内容切换：用 TabContainer.current_tab 切换 MiniInfo / LogIn / ProfileView / ProfilePage
func _apply_content_visibility(s: State) -> void:
	if not _is_expanded(s):
		# 收起状态：MiniInfo (tab 0)
		info_tab_c.current_tab = 0
		info_tab_c.apply_mini_visibility(s == State.LOGGED_OUT)
	elif s == State.EXPANDED:
		# 登录/注册表单 (tab 1)
		info_tab_c.current_tab = 1
	else:
		# LOGGED_IN_EXPANDED → tab 2 概要页；FULL_EXPANDED → tab 3 ProfilePage
		info_tab_c.apply_profile_visibility(s == State.FULL_EXPANDED)

# ========== 面板几何 ==========

func _get_skew_margin(skew_x: float, target_h: float) -> float:
	return abs(skew_x) * target_h * 0.5

## 获取状态对应的几何参数：skew、offset、margin、tab_left_extra、tab_top
## FULL_EXPANDED 动态计算：矩形 = 屏幕宽度 + 两侧 skew_margin，高度 = 屏幕高度 + 8
func _get_geometry_params(s: State) -> Dictionary:
	var skew: float
	var offset: Vector2
	var tab_left_extra: float = 0.0
	var tab_top: float
	var screen_w: float = 0.0
	if s == State.FULL_EXPANDED:
		skew = SKEW_EXPANDED
		var screen_size := get_viewport_rect().size
		screen_w = screen_size.x
		offset.y = -(screen_size.y + FULL_EXPAND_EXTRA_HEIGHT)
		tab_left_extra = TAB_OFFSET_LEFT_FULL
		tab_top = TAB_OFFSET_TOP_EXPANDED
	elif s == State.EXPANDED or s == State.LOGGED_IN_EXPANDED:
		skew = SKEW_EXPANDED
		offset = EXPAND_OFFSET
		tab_left_extra = TAB_OFFSET_LEFT_EXPANDED
		tab_top = TAB_OFFSET_TOP_EXPANDED
	elif s == State.LOGGED_IN:
		skew = SKEW_COLLAPSED
		offset = COLLAPSE_OFFSET
		tab_top = TAB_OFFSET_TOP_COLLAPSED
	else:  # LOGGED_OUT
		skew = SKEW_COLLAPSED
		offset = MINI_COLLAPSE_OFFSET
		tab_top = TAB_OFFSET_TOP_COLLAPSED
	var margin := _get_skew_margin(skew, abs(offset.y))
	if s == State.FULL_EXPANDED:
		offset.x = -(screen_w + 2.0 * margin)
	return {
		"skew": skew,
		"offset": offset,
		"margin": margin,
		"tab_left_extra": tab_left_extra,
		"tab_top": tab_top,
	}

func _animate_panel_geometry(s: State, t: Tween) -> void:
	var p := _get_geometry_params(s)
	t.tween_property(info_panel_btn, "offset_transform_position", Vector2(p.margin, 0), ANIM_DURATION)
	t.tween_property(info_panel_btn, "offset_left", p.offset.x-10, ANIM_DURATION)
	t.tween_property(info_panel_btn, "offset_top", p.offset.y, ANIM_DURATION)
	for sb in _btn_styleboxes:
		t.tween_property(sb, "skew", Vector2(p.skew, 0), ANIM_DURATION)
	t.tween_property(info_panel_btn, "skew_x", p.skew, ANIM_DURATION)
	t.tween_property(info_tab_c, "offset_top", p.tab_top, ANIM_DURATION)
	t.tween_property(info_tab_c, "offset_bottom", 0, ANIM_DURATION)
	t.tween_property(info_tab_c, "offset_left", p.margin + p.tab_left_extra, ANIM_DURATION)
	t.tween_property(info_tab_c, "offset_right", -p.margin - max(TAB_RIGHT_RESERVE_NORM, p.tab_left_extra), ANIM_DURATION)

# ========== Tip ==========

func _animate_tip(s: State, t: Tween) -> void:
	match s:
		State.LOGGED_OUT:
			t.tween_property(info_tab_c.tip, "custom_minimum_size:x", TIP_WIDTH_LOGGED_OUT, ANIM_DURATION)
		State.LOGGED_IN:
			t.tween_property(info_tab_c.tip, "custom_minimum_size:x", TIP_WIDTH_LOGGED_IN, ANIM_DURATION)
		_:
			pass

# ========== 遮罩 ==========

func _animate_overlay(s: State, t: Tween) -> void:
	if not shader_overlay:
		return
	if _is_expanded(s):
		shader_overlay.visible = true
		t.tween_property(shader_overlay, "modulate:a", 1.0, ANIM_DURATION)
	else:
		t.tween_property(shader_overlay, "modulate:a", 0.0, ANIM_DURATION)
		t.chain().tween_callback(func() -> void:
			if not _is_expanded(_state) and shader_overlay:
				shader_overlay.visible = false
		)

# ========== ShortCutMenu 联动 ==========

func _play_shortcut_menu_exit() -> void:
	# 若快捷菜单内部面板（排序/收藏页）已展开，先自动收起再整体退场
	if shortcut_menu and shortcut_menu.has_method("collapse_panel"):
		shortcut_menu.collapse_panel()
	if shortcut_menu and shortcut_menu.visible and shortcut_menu.has_method("play_transition_animation"):
		shortcut_menu.play_transition_animation(true)

func _play_shortcut_menu_enter() -> void:
	# 仅当前视图确实挂载快捷菜单（Album/Song/Sorted）时才入场。
	# 导航恢复到 MidiView 等无菜单视图后，迟到的登录态变化（如在线模式连接成功
	# 触发的 token 续期 → auth_changed）不应再把已隐藏的菜单拉出来。
	var st := UiStatMGR.current_state
	if st != UIStateManager.UIState.ALBUM_VIEW and st != UIStateManager.UIState.SONG_VIEW and st != UIStateManager.UIState.SORTED_VIEW:
		return
	if shortcut_menu and not shortcut_menu.visible and shortcut_menu.has_method("play_transition_animation"):
		shortcut_menu.play_transition_animation(false)

# ========== RB_Btn 联动 ==========

## 根据目标状态设置 RB_Btn：
## 展开状态 → 保存当前状态，切到 BACK_BTN，设置 pressed_override
## 收起状态 → 恢复 RB_Btn 到展开前的状态
func _setup_rb_btn_for_state(s: State) -> void:
	if not rb_btn:
		return
	if _is_expanded(s):
		# 仅在首次进入展开时保存原始状态（避免展开↔半展开之间切换时覆盖）
		if _saved_rb_stat < 0:
			_saved_rb_stat = rb_btn.get_current_stat()
		# FULL_EXPANDED 作为 PROFILE_VIEW 视图，右下角用正常返回键（go_back），不再接管回调
		if s == State.FULL_EXPANDED:
			rb_btn.pressed_override = Callable()
		else:
			rb_btn.pressed_override = Callable(self, "_collapse")
		rb_btn.switch_display(rb_btn.ShowStat.BACK_BTN)
	else:
		rb_btn.pressed_override = Callable()
		if _saved_rb_stat >= 0:
			rb_btn.switch_display(_saved_rb_stat)
			_saved_rb_stat = -1

# ========== 点击逻辑 ==========

func _on_expand_panel_pressed() -> void:
	match _state:
		State.LOGGED_OUT:
			_login_result = false
			_animate_to_state(State.EXPANDED)
		State.LOGGED_IN:
			_animate_to_state(State.LOGGED_IN_EXPANDED)

func _on_shader_overlay_gui_input(event: InputEvent) -> void:
	if not _is_expanded(_state):
		return
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	_collapse()

## 完全收起：遮罩点击 / RB_Btn（非 FULL_EXPANDED）
## EXPANDED → LOGGED_IN（登录成功）或 LOGGED_OUT（未登录）
## LOGGED_IN_EXPANDED / FULL_EXPANDED → LOGGED_IN
func _collapse() -> void:
	var target_state: State
	if _state == State.EXPANDED:
		target_state = State.LOGGED_IN if _login_result else State.LOGGED_OUT
	else:
		target_state = State.LOGGED_IN
	_animate_to_state(target_state)

## UIState 变化：离开 PROFILE_VIEW（返回基础视图 / 去 CHARA 返回基础）时收起全屏面板
func _on_ui_state_changed(_old_state: UIStateManager.UIState, new_state: UIStateManager.UIState) -> void:
	if _state == State.FULL_EXPANDED and new_state != UIStateManager.UIState.PROFILE_VIEW and new_state != UIStateManager.UIState.CHARA_VIEW:
		_animate_to_state(State.LOGGED_IN)

## ProfileView 展开/收起详情按钮（由 PlayerInfoContent.expand_toggled 触发）
func _on_expand_toggled() -> void:
	if _state == State.LOGGED_IN_EXPANDED:
		_animate_to_state(State.FULL_EXPANDED)
	elif _state == State.FULL_EXPANDED:
		_animate_to_state(State.LOGGED_IN_EXPANDED)

# ========== 公共 API ==========

func set_login_result(success: bool) -> void:
	_login_result = success

## 强制切到已登录状态（供登录成功后外部直接调用 / login_submitted 信号触发）
func set_logged_in() -> void:
	_login_result = true
	if _state == State.EXPANDED:
		_animate_to_state(State.LOGGED_IN_EXPANDED)
	else:
		_animate_to_state(State.LOGGED_IN)

## 切到未登录状态（登出时调用）
func set_logged_out() -> void:
	_login_result = false
	_animate_to_state(State.LOGGED_OUT)

## 切到全屏展开状态
func expand_full() -> void:
	_animate_to_state(State.FULL_EXPANDED)

## 更新玩家数据并刷新显示
func update_player_data(data: Dictionary) -> void:
	info_tab_c.update_player_data(data)

extends PopupPanel

class_name PopupWindow

static var instance: PopupWindow

signal window_close
## 详情页点了下载（宿主决定是否真的开始下载）
signal chart_download_requested(item: Dictionary)

var _confirm: bool = false
## 窗口内遮罩（场景里的 %WindowDim）：面板外的暗化与点击都由它承担
var _dim: ColorRect = null

## 窗口弹出动画时长（秒，与 _window_popup_animate 中 animate_offset_scale 的 duration 一致）
## ParticleAdjust 等子脚本不需要此常量，仅在 PopupWindow 内使用；show_particle_adjust 用它等待动画完成
const _POPUP_ANIM_DURATION: float = 0.4

const _WINDOW_SIZE: Array[Vector2] = [
	Vector2(850, 600),
	Vector2(1500, 700),
	Vector2(950, 850),
	Vector2(1300, 840)
	]

## 收藏夹列表项（与快捷菜单同一套视觉）
const FAVOR_ITEM_SCENE := preload("res://UI/Components/ShortCutMenu/favorListItem.tscn")

## 默认入场：从中心稍稍放大（不需要指定来源位置时的通用表现）
const _ENTRY_SCALE := Vector2(0.9, 0.9)
## 窗口内自带遮罩的不透明度（与原 Main 的 %PopupWindowShader 一致）
const _DIM_ALPHA := 0.72
## 面板四周留给阴影的边距（与 %WindowBG 在场景里的 offset 一致）
const _SHADOW_MARGIN := 20.0

## 各页标题。标题栏由窗口本身提供，页面里不再各写一份。
const PAGE_TITLES := {
	0: "提示",
	1: "延迟校准",
	2: "音符皮肤",
	3: "判定特效",
	4: "背景图片",
	5: "键盘模式",
	6: "音符下落",
	7: "资源存储位置",
	8: "存储目录冲突",
	9: "选择收藏夹",
	10: "谱面详情",
}

## title 为空时取 PAGE_TITLES；closable=false 时隐藏右上角关闭按钮（强制提示不给绕过入口）
## from_rect：全局矩形，给了就从那里飞出（卡片详情）；默认从中心放大
func _pop_up_window(page: int = 0, window_title: String = "", closable: bool = true,
		from_rect: Rect2 = Rect2()) -> void:
	_entry_rect = from_rect
	# 每次开新页前无条件解除模态：exclusive 只在 show_message(force=true) 期间为 true，
	# 由那个协程自己复位。一旦协程在 await window_close 处被丢弃（节点释放、切场景、
	# 信号没等到），复位语句就永远不执行，之后所有弹窗点外部都关不掉 = 玩家没法中止操作。
	# 这里按"打开即恢复可取消"兜底，force 页在 popup 前再置 true。
	exclusive = false
	# 重开时清掉上一次的关闭中状态：关闭动画可能被新动画顶掉，finished 不会触发
	_closing = false
	%CloseBtn.visible = closable
	# 先切页再设标题：切页会触发 tab_changed 把标题重置成本页默认标题
	%Tabs.current_tab = page
	%WindowTitle.text = window_title if not window_title.is_empty() else PAGE_TITLES.get(page, "")
	var panel_size: Vector2
	if page in [2, 3, 4, 5]:
		panel_size = _WINDOW_SIZE[1]
	elif page in [6]:
		panel_size = _WINDOW_SIZE[2]
	elif page == 10:
		panel_size = _WINDOW_SIZE[3]
	else:
		panel_size = _WINDOW_SIZE[0]
	%Window.custom_minimum_size = panel_size
	_layout_fullscreen_window()
	await get_tree().process_frame
	# await get_tree().create_timer(0.1).timeout
	popup()
	# popup() 会按 initial_position 重算位置，落地后再摆一次
	_layout_fullscreen_window()
	call_deferred(&"_focus_current_page")

## 窗口铺满主视口，面板在窗口内居中。
## 注意：Popup 会把自己的 Control 子节点强制铺满窗口（wrap_controls / _update_child_rects），
## 所以定位放在 %Window 的下一层 %WindowBG 上，而不是 %Window。
func _layout_fullscreen_window() -> void:
	var screen := _screen_size()
	size = Vector2i(screen)
	position = Vector2i.ZERO
	wrap_controls = false
	var panel_size: Vector2 = %Window.custom_minimum_size
	%WindowBG.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	# %WindowBG 的坐标相对 %Window，而 %Window 的 rect 由 Popup 管着、起点不一定是 0
	%WindowBG.position = ((screen - panel_size) * 0.5).floor() \
		- Vector2(_SHADOW_MARGIN, _SHADOW_MARGIN) - %Window.position
	%WindowBG.size = panel_size + Vector2(_SHADOW_MARGIN, _SHADOW_MARGIN) * 2.0
	%WindowBG.pivot_offset = %WindowBG.size * 0.5

func _screen_size() -> Vector2:
	# 用主界面的 size（Control 逻辑坐标）：root.get_visible_rect() 是物理像素，
	# canvas_items 缩放后两者不等，直接用它会在屏幕两侧留下没被遮罩盖住的缝
	var main := GlobalNodes.main
	if main != null and is_instance_valid(main) and main.size.x > 1.0 and main.size.y > 1.0:
		return main.size
	return get_tree().root.get_visible_rect().size

## 窗口级设置：铺满主视口、遮罩接管面板外点击、Esc 由自己处理
func _setup_fullscreen_layer() -> void:
	initial_position = Window.WINDOW_INITIAL_POSITION_ABSOLUTE
	# Popup 默认在 ui_cancel / 点窗口外时直接 hide()，窗口已不可见，退场动画等于没播；
	# 关掉后由 _input 与 WindowDim 统一走 _request_close()
	popup_window = false
	# %Window 只是个铺满窗口的布局壳，默认 mouse_filter=STOP 会吃掉面板外的点击
	%Window.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dim = %WindowDim
	_dim.color = Color(0, 0, 0, _DIM_ALPHA)
	_dim.gui_input.connect(_on_dim_input)

## 点击面板外关闭（exclusive 时不可跳过）
func _on_dim_input(event: InputEvent) -> void:
	if exclusive:
		return
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		_request_close()

## 关闭中标志：退场动画播放期间挡住重复触发
var _closing := false

## 统一关闭入口：先播退场动画，播完再真正 hide()。
## 直接 hide() 的话窗口在 popup_hide 时已经不可见，退场动画看不到。
func _request_close() -> void:
	if not visible or _closing:
		return
	_closing = true
	var tween := _window_popup_animate(false)
	if tween == null:
		hide()
		return
	tween.finished.connect(hide, CONNECT_ONE_SHOT)

## 入场来源矩形（全局坐标），Rect2() 表示从中心放大
var _entry_rect := Rect2()


## 键盘 / 手柄打开时把焦点放进页面：提示页落在确认按钮，其它页落在页面里第一个可聚焦控件。
## 鼠标 / 触摸打开时不动焦点，避免触摸操作冒出焦点描边。
func _focus_current_page(force: bool = false) -> void:
	if not FocusMGR or not visible:
		return
	if not force and not FocusMGR.is_keyboard_mode():
		return
	var page: Node = %Tabs.get_current_tab_control()
	if page == null:
		return
	var target: Control = null
	if %Tabs.current_tab == 0 and %MessageConfirmBtn.is_visible_in_tree():
		target = %MessageConfirmBtn
	if target == null:
		target = FocusMGR.first_focusable_in(page)
	if target != null:
		target.grab_focus()

## 弹窗是独立窗口，主窗口的焦点路由收不到这里的按键；
## 页内还没有控件持有焦点时，第一次按方向键 / Tab 就把焦点放进当前页
func _input(event: InputEvent) -> void:
	if not visible:
		return
	# 页内控件（如按键录入）先消费的话不抢
	if get_viewport().is_input_handled():
		return
	# Esc / 返回键：走统一关闭路径，才能和按钮关闭一样有退场动画
	if event.is_action_pressed(&"ui_cancel", true, true):
		_request_close()
		get_viewport().set_input_as_handled()
		return
	if get_viewport().gui_get_focus_owner() != null:
		return
	if not (event is InputEventKey or event is InputEventJoypadButton or event is InputEventJoypadMotion):
		return
	for action in [&"ui_up", &"ui_down", &"ui_left", &"ui_right", &"ui_focus_next", &"ui_focus_prev"]:
		if event.is_action_pressed(action, true, true):
			_focus_current_page(true)
			get_viewport().set_input_as_handled()
			return

func _ready() -> void:
	instance = self
	_setup_fullscreen_layer()
	%WindowTitle.text = PAGE_TITLES.get(%Tabs.current_tab, "")
	# 默认窗口按钮
	%MessageCancelBtn.pressed.connect(_on_cancel_pressed)
	%MessageConfirmBtn.pressed.connect(_on_confirm_pressed)
	# 标题栏关闭按钮：等同于取消，各页结果值由各自脚本的默认值决定（未选择即取消）
	%CloseBtn.pressed.connect(_request_close)
	# DelayAdjust 校准完成 → 隐藏窗口（→ popup_hide → 退出动画 → window_close）
	%DelayAdjust.finish_requested.connect(_request_close)
	# StorageLocationAdjust 确认/取消 → 隐藏窗口（必须关闭整个弹窗，不能只隐藏 tab 页）
	%StorageLocationAdjust.finish_requested.connect(_request_close)
	# StorageConflictAdjust 选择 → 隐藏窗口
	%StorageConflictAdjust.finish_requested.connect(_request_close)
	# 判定类型切换时页面把新标题回传给窗口，标题栏始终只有一处来源
	%ParticleAdjust.title_changed.connect(set_window_title)
	# 页面之间直接跳转（例如存储路径校验失败后切回列表）时标题跟随页签
	%Tabs.tab_changed.connect(_on_tab_changed)
	# 详情页的下载请求转给宿主
	%ChartDetailPage.download_requested.connect(func(item: Dictionary) -> void:
		chart_download_requested.emit(item)
	)

	# 监听内置 popup 生命周期信号
	about_to_popup.connect(func() -> void: _window_popup_animate(true))
	# 任何路径的 hide() 都会到这里：收尾、复位状态并通知调用方
	popup_hide.connect(func() -> void:
		# 任何关闭路径都把模态解除（force 提示的协程可能已被丢弃，不能指望它复位）
		exclusive = false
		%DelayAdjust.stop_calibration()
		%ParticleAdjust.stop_preview()
		%KBModeAdjust._cancel_recording()
		%FallingAdjust.stop_preview()
		# 退场动画已在 _request_close 播过；这里只收尾并通知调用方
		_closing = false
		_dim.visible = false
		window_close.emit()
	)

	# 注册主题应用者并首次着色
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()

## 改标题栏文字（子页需要动态改标题时用，例如切换判定类型）
func set_window_title(text: String) -> void:
	%WindowTitle.text = text

func _on_tab_changed(tab: int) -> void:
	set_window_title(PAGE_TITLES.get(tab, ""))
	call_deferred(&"_focus_current_page")

## 应用主题色（由 ThemeManager 广播调用 + _ready 首次自调）
func apply_theme() -> void:
	var is_light := ThemeMGR.get_appearance() == "light"
	var primary := ThemeMGR.get_color("primary")

	# 窗体：中性面板 + 强调色细描边 + 投影；顶部装饰线与标题栏分隔线跟随强调色层次
	var sb: StyleBoxFlat = (%WindowBG as Panel).get_theme_stylebox("panel")
	sb.bg_color = ThemeMGR._tint_keep_alpha(ThemeMGR.get_color("surface"), 0.98)
	sb.border_color = ThemeMGR._tint_keep_alpha(primary, 0.55 if is_light else 0.45)
	sb.shadow_color = Color(0, 0, 0, 0.45 if is_light else 0.55)
	var accent_text := ThemeMGR.get_color("primary_dark") if is_light else ThemeMGR.get_color("primary_light")
	(%Accent as Panel).get_theme_stylebox("panel").bg_color = accent_text
	(%HeaderLine as Panel).get_theme_stylebox("panel").bg_color = \
		ThemeMGR._tint_keep_alpha(ThemeMGR.get_color("border_soft"), 0.9)

	# KBModeAdjust/AddBtn — 强调色主按钮；该按钮在 tscn 里有自己的 normal/pressed/hover 样式框，
	# 因此可就地改色而不影响共享的 R12NoBorder 主题
	ThemeMGR._style_button_set_bg_color(%KBModeAdjustAddBtn, primary)
	_style_default_option_button()

## 默认弹窗里的选项按钮：tscn 内写死了深色 hover/pressed，浅色模式下会变成一块很黑/纯黑，
## 这里按主题重刷三态底色。字色交给 MainTheme 的 OptionButton/font_*（已是 text_primary），
## 只有「按下态底色是实心强调色」需要白字，单独覆盖。
func _style_default_option_button() -> void:
	var surface_low := ThemeMGR.get_color("surface_low")
	var surface_hover := ThemeMGR.get_color("surface_hover")
	var primary := ThemeMGR.get_color("primary")
	var border := ThemeMGR.get_color("border")
	var pressed_text := Color.WHITE

	for spec in [
		["normal", surface_low, border],
		["hover", surface_hover, primary],
		["pressed", primary, primary],
	]:
		if not ThemeMGR.has_local_stylebox(%MessageOption, spec[0]):
			continue
		var sb: StyleBoxFlat = %MessageOption.get_theme_stylebox(spec[0])
		sb.draw_center = true
		sb.bg_color = ThemeMGR._tint_keep_alpha(spec[1], sb.bg_color.a if sb.bg_color.a > 0.0 else 0.95)
		sb.border_color = ThemeMGR._tint_keep_alpha(spec[2], 0.85)
	%MessageOption.add_theme_color_override("font_pressed_color", pressed_text)
	%MessageOption.add_theme_color_override("font_hover_pressed_color", pressed_text)

func _exit_tree() -> void:
	if ThemeMGR:
		ThemeMGR.unregister_theme_applier(self)

func _on_cancel_pressed() -> void:
	_confirm = false
	_request_close()

func _on_confirm_pressed() -> void:
	_confirm = true
	_request_close()

func _window_popup_animate(is_popup: bool) -> Tween:
	if _dim == null:
		return null
	# 同一 id：重复开关时旧动画连同回调一起作废
	var tween := AniMGR.create_managed_tween(self, "popup_anim")
	if tween == null:
		# 没有动画系统时至少保证关闭信号不被吞（调用方可能正在 await window_close）
		if not is_popup:
			window_close.emit()
		return null
	tween.set_ease(Tween.EASE_OUT)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_parallel(true)
	%WindowBG.offset_transform_enabled = true

	# 入场与退场共用同一个起点：有来源矩形就缩回那里，否则原地小幅缩放
	var entry := _entry_transform()
	var entry_pos: Vector2 = entry[0]
	var entry_scale: Vector2 = entry[1]

	if is_popup:
		_confirm = false
		%WindowBG.offset_transform_position = entry_pos
		%WindowBG.offset_transform_scale = entry_scale
		%WindowBG.modulate.a = 0.0
		_dim.visible = true
		_dim.color.a = 0.0
		tween.tween_property(_dim, "color:a", _DIM_ALPHA, 0.3)
		tween.tween_property(%WindowBG, "offset_transform_position", Vector2.ZERO, 0.4)
		tween.tween_property(%WindowBG, "offset_transform_scale", Vector2.ONE, 0.4)
		tween.tween_property(%WindowBG, "modulate:a", 1.0, 0.3)
		return tween

	# 退场：缩回起点并淡出。只缩不淡会像「缩一下然后突然消失」；
	# 用 EASE_OUT 而不是 EASE_IN —— 后者前半程几乎不动，看起来像没缩
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_property(_dim, "color:a", 0.0, 0.25)
	tween.tween_property(%WindowBG, "offset_transform_position", entry_pos, 0.28)
	tween.tween_property(%WindowBG, "offset_transform_scale", entry_scale, 0.28)
	tween.tween_property(%WindowBG, "modulate:a", 0.0, 0.26)
	return tween

## 入场 / 退场起点：有来源矩形就用它的中心与相对尺寸，否则原地缩到 _ENTRY_SCALE
func _entry_transform() -> Array:
	if _entry_rect.size.x > 1.0 and _entry_rect.size.y > 1.0:
		var panel_center: Vector2 = %WindowBG.position + %WindowBG.size * 0.5
		return [_entry_rect.get_center() - panel_center, _entry_rect.size / %WindowBG.size]
	return [Vector2.ZERO, _ENTRY_SCALE]

func _set_option(options: Array):
	%MessageOption.clear()
	var idx: int = 0
	for i in options:
		%MessageOption.add_item(i, idx)
		idx += 1

	%MessageOption.visible = true if idx else false

# ===== 公共 API =====

# 设置默认窗口的选项
func get_selected() -> String:
	return %MessageOption.get_item_text(%MessageOption.get_selected_id())

# 用默认窗口显示消息，要获取确认状态需await
## force=true 时弹窗为强制模态（exclusive）：无法点击外部关闭，只能通过按钮/返回键处理，
## 用于"迁移后必须重启"等不可跳过的提示（这种情况下不显示标题栏的关闭按钮）
## title 留空时标题栏显示"提示"
func show_message(message: String, cancel_visible: bool = false, options: Array = [], force: bool = false,
		window_title: String = "") -> bool:
	%MessageText.text = message
	%MessageCancelBtn.modulate.a = 0 if not cancel_visible else 1
	_set_option(options)

	_pop_up_window(0, window_title, not force)
	if force:
		exclusive = true  # 模态：点击弹窗外区域不会关闭（popup 失去焦点不隐藏）
	await window_close
	if force:
		exclusive = false
	return _confirm

# 弹出延迟校准窗口
# 返回 Dictionary: {"delay": 校准/输入的延迟值(ms), "bt_auto_off_performing": 蓝牙自动关闭弹奏模式开关(0/1)}
func show_delay_adjust(current_delay: int = 0) -> Dictionary:
	%DelayAdjust.start_calibration(current_delay)

	_pop_up_window(1)
	await window_close
	# 兜底停止（popup_hide 已会调用，此处再保险一次）
	%DelayAdjust.stop_calibration()
	return %DelayAdjust.get_result()

# 弹出皮肤修改窗口
func show_note_skin_adjust() -> String:
	%NoteSkinAdjust.init_adjust()
	
	_pop_up_window(2)
	await window_close
	# 关闭时持久化皮肤配置（颜色/光效/长条模式等）并触发 FlowArea 重载
	%NoteSkinAdjust.save_config()
	return %NoteSkinAdjust.get_selected_skin()

# 弹出粒子设置窗口
# judge_type: Perfect / Great / Good / Bad，决定编辑哪个判定类型的特效
# 返回 Dictionary 字段见 ParticleAdjust.get_result
func show_particle_adjust(judge_type: String = "Perfect") -> Dictionary:
	%ParticleAdjust.init_adjust(judge_type)
	
	_pop_up_window(3, "%s 特效设定" % judge_type)
	await get_tree().create_timer(_POPUP_ANIM_DURATION).timeout
	%ParticleAdjust.start_preview()
	await window_close
	%ParticleAdjust.stop_preview()
	return %ParticleAdjust.get_result()

# 弹出图片设置窗口
## view_name: 视图名称（main/store/score/play/track/midi/setting），用于从 ThemeManager 读取当前配置初始化控件
## allow_cover: 是否允许选择"封面"类型（仅 play 视图为 true）
## 返回 Dictionary 字段见 ImageAdjust.get_result
func show_image_adjust(view_name: String = "", allow_cover: bool = false) -> Dictionary:
	%ImageAdjust.init_adjust(view_name, allow_cover)
	
	_pop_up_window(4)
	await window_close
	return %ImageAdjust.get_result()

# 弹出键位设置窗口
## current_keys / current_display_names：由调用方从 pending 配置传入，未传则回退到配置文件
## current_kb_mode / current_gap：键盘模式开关与左右间距；current_alt_*：交替轨道颜色
## current_lane_sep：轨道分隔线开关（0/1，仅键盘模式生效）
## 返回 Dictionary: {"keys": "A,M60,MB2,JB0,JA0+,...", "display_names": "P1,,,...",
##                    "keyboard_mode": 0/1, "keyboard_mode_gap": int,
##                    "alt_color": 0/1, "alt_count": int, "alt_colors": "#rrggbb,...",
##                    "lane_separator": 0/1}
## 关闭即返回当前编辑状态（无取消路径，调用方不应依赖空返回值判断取消）
func show_kb_mode_adjust(current_keys: String = "", current_display_names: String = "",
		current_kb_mode: Variant = 1, current_alt_color: Variant = 1, current_alt_count: Variant = 2,
		current_alt_colors: String = "#ff0000,#0000ff", current_gap: Variant = 0,
		current_lane_sep: Variant = 0) -> Dictionary:
	# 优先使用传入的 pending 值；为空时回退到配置文件（兼容直接调用）
	var keys_str := current_keys if not current_keys.is_empty() else \
		ConfigManager.instance.get_string("keyboard_mode_keys", "A,S,D,F,J,K,L,;")
	var names_str := current_display_names if not current_display_names.is_empty() else \
		ConfigManager.instance.get_string("keyboard_mode_display_names", "")
	%KBModeAdjust.init_adjust(keys_str, names_str, current_kb_mode, current_alt_color, current_alt_count, current_alt_colors, current_gap, current_lane_sep)
	
	_pop_up_window(5)
	await window_close
	# 兜底取消录入状态（popup_hide 已调用，此处再保险一次）
	%KBModeAdjust._cancel_recording()
	return %KBModeAdjust.get_result()

# 弹出下落模式设置窗口
## 关闭时由 FallingAdjust 内部 save_config 即时写入 ConfigManager 并触发 config_changed
## 返回 Dictionary 字段见 FallingAdjust.get_result（供 SettingList 同步 _pending_config）
func show_falling_adjust() -> Dictionary:
	# 等 _pop_up_window 内部 popup() 完成（弹窗可见）后再初始化并启动下落预览：
	# init_adjust 末尾会 await 一帧后调用 _start_preview_loop，其依赖 is_visible_in_tree() 为真
	await _pop_up_window(6)
	%FallingAdjust.init_adjust()
	await window_close
	# 兜底停止预览（popup_hide 已调用，此处再保险一次）
	%FallingAdjust.stop_preview()
	# 关闭时持久化下落参数并触发 FlowArea 热重载
	%FallingAdjust.save_config()
	return %FallingAdjust.get_result()

# 弹出存储位置设置窗口
## current_path：当前存储路径（为空时弹窗显示 PathHelper.get_storage_root()）
## 返回 Dictionary: {"action": "confirmed"|"cancelled", "path": String}
## 确认后由调用方（SettingList）执行路径校验与迁移
func show_storage_location_adjust(current_path: String = "") -> Dictionary:
	%StorageLocationAdjust.init_adjust(current_path)

	_pop_up_window(7)
	await window_close
	return %StorageLocationAdjust.get_result()

# 弹出存储迁移冲突处理窗口（目标目录已存在游戏数据时，决定听哪一侧）
## merge_dirs: 目标已存在的资源目录；conflict_files: 目标已存在的顶层文件
## 返回 int（StorageConflictAdjust.Choice）：-1=未选择/取消，0=保留目标（合并补缺），1=覆盖目标
func show_storage_conflict_adjust(merge_dirs: Array, conflict_files: Array) -> int:
	%StorageConflictAdjust.init_adjust(merge_dirs, conflict_files)

	_pop_up_window(8)
	await window_close
	return %StorageConflictAdjust.get_result()

# 弹出收藏夹选择窗口
## 选中某个收藏夹后关闭，返回其 id；取消（关闭按钮 / 点遮罩）返回空串
func show_favorite_picker() -> String:
	_favor_result = ""
	_rebuild_favor_list()
	_pop_up_window(9)
	await window_close
	return _favor_result

## 选择结果：空串表示取消
var _favor_result: String = ""

## 重建收藏夹列表（复用快捷菜单的列表项，BROWSE 模式下点击只发 favor_item_clicked）
func _rebuild_favor_list() -> void:
	for child in %FpList.get_children():
		if child != %FpEmpty:
			child.queue_free()
	var fav_mgr := FavoriteManager.instance
	if fav_mgr == null or fav_mgr.favorites.is_empty():
		%FpEmpty.visible = true
		return
	%FpEmpty.visible = false
	for f in fav_mgr.favorites:
		var item := FAVOR_ITEM_SCENE.instantiate()
		%FpList.add_child(item)
		item.setup(f, item.Mode.BROWSE)
		item.favor_item_clicked.connect(_on_favor_item_clicked)

func _on_favor_item_clicked(fav_id: String) -> void:
	_favor_result = fav_id
	_request_close()

# 弹出谱面详情页
## from_rect：卡片在屏幕上的矩形，给了就从卡片位置展开
func show_chart_detail(item: Dictionary, origin_mode: int = 0, from_rect: Rect2 = Rect2()) -> void:
	%ChartDetailPage.setup(item, origin_mode)
	var window_title := str(item.get("title", "")).strip_edges()
	_pop_up_window(10, window_title if not window_title.is_empty() else "谱面详情", true, from_rect)
	await window_close

## 当前是否停在谱面详情页
func is_chart_detail_open() -> bool:
	return visible and %Tabs.current_tab == 10

## 下载状态变化时刷新详情页按钮（页面没开着就忽略）
func refresh_chart_detail_state() -> void:
	if is_chart_detail_open():
		%ChartDetailPage.refresh_download_state()

## 收起详情页（宿主切视图前调用）
func close_chart_detail() -> void:
	if is_chart_detail_open():
		_request_close()

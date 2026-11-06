extends PopupPanel

class_name PopupWindow

static var instance: PopupWindow

signal window_close

var _confirm: bool = false

## 窗口弹出动画时长（秒，与 _window_popup_animate 中 animate_offset_scale 的 duration 一致）
## ParticleAdjust 等子脚本不需要此常量，仅在 PopupWindow 内使用；show_particle_adjust 用它等待动画完成
const _POPUP_ANIM_DURATION: float = 0.4

const _WINDOW_SIZE: Array[Vector2] = [
	Vector2(850, 600),
	Vector2(1500, 700),
	Vector2(950, 850)
	]

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
}

## title 为空时取 PAGE_TITLES；closable=false 时隐藏右上角关闭按钮（强制提示不给绕过入口）
func _pop_up_window(page: int = 0, window_title: String = "", closable: bool = true) -> void:
	# 每次开新页前无条件解除模态：exclusive 只在 show_message(force=true) 期间为 true，
	# 由那个协程自己复位。一旦协程在 await window_close 处被丢弃（节点释放、切场景、
	# 信号没等到），复位语句就永远不执行，之后所有弹窗点外部都关不掉 = 玩家没法中止操作。
	# 这里按"打开即恢复可取消"兜底，force 页在 popup 前再置 true。
	exclusive = false
	%CloseBtn.visible = closable
	# 先切页再设标题：切页会触发 tab_changed 把标题重置成本页默认标题
	%Tabs.current_tab = page
	%WindowTitle.text = window_title if not window_title.is_empty() else PAGE_TITLES.get(page, "")
	if page in [2, 3, 4, 5]:
		%Window.custom_minimum_size = _WINDOW_SIZE[1]
	elif page in [6]:
		%Window.custom_minimum_size = _WINDOW_SIZE[2]
	else:
		%Window.custom_minimum_size = _WINDOW_SIZE[0]
	%Window.size = Vector2.ZERO
	size = Vector2.ZERO
	await get_tree().process_frame
	# await get_tree().create_timer(0.1).timeout
	popup()

func _ready() -> void:
	instance = self
	%WindowTitle.text = PAGE_TITLES.get(%Tabs.current_tab, "")
	# 默认窗口按钮
	%MessageCancelBtn.pressed.connect(_on_cancel_pressed)
	%MessageConfirmBtn.pressed.connect(_on_confirm_pressed)
	# 标题栏关闭按钮：等同于取消，各页结果值由各自脚本的默认值决定（未选择即取消）
	%CloseBtn.pressed.connect(hide)
	# DelayAdjust 校准完成 → 隐藏窗口（→ popup_hide → 退出动画 → window_close）
	%DelayAdjust.finish_requested.connect(hide)
	# StorageLocationAdjust 确认/取消 → 隐藏窗口（必须关闭整个弹窗，不能只隐藏 tab 页）
	%StorageLocationAdjust.finish_requested.connect(hide)
	# StorageConflictAdjust 选择 → 隐藏窗口
	%StorageConflictAdjust.finish_requested.connect(hide)
	# 判定类型切换时页面把新标题回传给窗口，标题栏始终只有一处来源
	%ParticleAdjust.title_changed.connect(set_window_title)
	# 页面之间直接跳转（例如存储路径校验失败后切回列表）时标题跟随页签
	%Tabs.tab_changed.connect(_on_tab_changed)

	# 监听内置 popup 生命周期信号
	about_to_popup.connect(func() -> void: _window_popup_animate(true))
	# 点击窗口外部时 Godot 会自动隐藏 popup 并发出 popup_hide，此处兜底处理
	popup_hide.connect(func() -> void:
		# 任何关闭路径都把模态解除（force 提示的协程可能已被丢弃，不能指望它复位）
		exclusive = false
		%DelayAdjust.stop_calibration()
		%ParticleAdjust.stop_preview()
		%KBModeAdjust._cancel_recording()
		%FallingAdjust.stop_preview()
		_window_popup_animate(false)
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
	hide()

func _on_confirm_pressed() -> void:
	_confirm = true
	hide()

func _window_popup_animate(is_popup: bool) -> Tween:
	var popup_tween : Tween = null
	if is_popup:
		_confirm = false
		# 窗口内容
		for nd in get_children():
			if nd is Control:
				nd.offset_transform_scale = Vector2.ZERO if is_popup else Vector2.ONE
				AniMGR.animate_offset_scale(nd, Vector2.ZERO if not is_popup else Vector2.ONE, 0.4, "popup_%s_scale" % nd.name)

		# 背景
		popup_tween = AniMGR.animate_fade_in(%PopupWindowShader, 0.3, "popup_bg_fade")
	else:
		popup_tween = AniMGR.animate_fade_out(%PopupWindowShader, 0.3, "popup_bg_fade")
		popup_tween.finished.connect(func() -> void: window_close.emit())
	return popup_tween

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

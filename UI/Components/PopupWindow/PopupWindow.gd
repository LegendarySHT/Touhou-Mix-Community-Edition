extends PopupPanel

class_name PopupWindow

static var instance: PopupWindow

@onready var _window_bg_shader: ColorRect = get_parent().get_node_or_null("PopupWindowShader")
@onready var _tab_c: TabContainer = $TabC
@onready var _ani: AnimationManager = AniMGR

# 默认页
@onready var _message: Label = $TabC/Default/Content/Label
@onready var _cancel_btn: Button = $TabC/Default/Btns/Cancel
@onready var _confirm_btn: Button = $TabC/Default/Btns/Confirm
@onready var _option_btn: OptionButton = $TabC/Default/Content/OptionButton

# 各功能页子脚本引用
@onready var _delay_adjust: DelayAdjust = $TabC/DelayAdjust
@onready var _note_skin_adjust: NoteSkinAdjust = $TabC/NoteSkinAdjust
@onready var _particle_adjust: ParticleAdjust = $TabC/ParticleAdjust
@onready var _image_adjust: ImageAdjust = $TabC/ImageAdjust
@onready var _kb_mode_adjust: KBModeAdjust = $TabC/KBModeAdjust
@onready var _falling_adjust: FallingAdjust = $TabC/FallingAdjust
@onready var _storage_location_adjust: StorageLocationAdjust = $TabC/StorageLocationAdjust

signal window_close

var _confirm: bool = false

## 窗口弹出动画时长（秒，与 _window_popup_animate 中 animate_offset_scale 的 duration 一致）
## ParticleAdjust 等子脚本不需要此常量，仅在 PopupWindow 内使用；show_particle_adjust 用它等待动画完成
const _POPUP_ANIM_DURATION: float = 0.4

func _pop_up_window(page: int) -> void:
	_tab_c.current_tab = page
	match page:
		1:
			size = Vector2(850, 600)
		2:
			size = Vector2(1500, 700)
		3:
			size = Vector2(1500, 700)
		4:
			size = Vector2(1500, 700)
		5:
			size = Vector2(1500, 800)
		6:
			size = Vector2(1300, 950)
		7:
			size = Vector2(900, 600)
		_:
			size = Vector2(850, 600)
	await get_tree().create_timer(0.1).timeout
	popup()

func _ready() -> void:
	instance = self
	# 默认窗口按钮
	_cancel_btn.pressed.connect(_on_cancel_pressed)
	_confirm_btn.pressed.connect(_on_confirm_pressed)
	# DelayAdjust 校准完成 → 隐藏窗口（→ popup_hide → 退出动画 → window_close）
	_delay_adjust.finish_requested.connect(hide)
	# StorageLocationAdjust 确认/取消 → 隐藏窗口（必须关闭整个弹窗，不能只隐藏 tab 页）
	_storage_location_adjust.finish_requested.connect(hide)

	# 监听内置 popup 生命周期信号
	about_to_popup.connect(func() -> void: _window_popup_animate(true))
	# 点击窗口外部时 Godot 会自动隐藏 popup 并发出 popup_hide，此处兜底处理
	popup_hide.connect(func() -> void:
		_delay_adjust.stop_calibration()
		_particle_adjust.stop_preview()
		_kb_mode_adjust._cancel_recording()
		_falling_adjust.stop_preview()
		_window_popup_animate(false)
	)

	# 注册主题应用者并首次着色
	if ThemeMGR:
		ThemeMGR.register_theme_applier(self)
		apply_theme()

## 应用主题色（由 ThemeManager 广播调用 + _ready 首次自调）
func apply_theme() -> void:
	# WindowBG — 主题深色（保留 tscn 预设的圆角/边框，alpha 固定 0.6）
	var window_bg := get_node_or_null("WindowBG") as PanelContainer
	if window_bg:
		var sb := window_bg.get_theme_stylebox("panel")
		if sb is StyleBoxFlat:
			var pd := ThemeMGR.get_color("primary_dark")
			sb.bg_color = Color(pd.r, pd.g, pd.b, 0.6)
	# KBModeAdjust/AddBtn — primary 色调（内联 stylebox，不走共享 theme）
	var kb_add_btn := get_node_or_null("TabC/KBModeAdjust/KeySequence/VFlowC/AddBtn") as Button
	if kb_add_btn:
		ThemeMGR._style_button_set_bg_color(kb_add_btn, ThemeMGR.get_color("primary"))

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
				_ani.animate_offset_scale(nd, Vector2.ZERO if not is_popup else Vector2.ONE, 0.4, "popup_%s_scale" % nd.name)

		# 背景
		popup_tween = _ani.animate_fade_in(_window_bg_shader, 0.3, "popup_bg_fade")
	else:
		popup_tween = _ani.animate_fade_out(_window_bg_shader, 0.3, "popup_bg_fade")
		popup_tween.finished.connect(func() -> void: window_close.emit())
	return popup_tween

func _set_option(options: Array):
	_option_btn.clear()
	var idx: int = 0
	for i in options:
		_option_btn.add_item(i, idx)
		idx += 1

	_option_btn.visible = true if idx else false

# ===== 公共 API =====

# 设置默认窗口的选项
func get_selected() -> String:
	return _option_btn.get_item_text(_option_btn.get_selected_id())

# 用默认窗口显示消息，要获取确认状态需await
## force=true 时弹窗为强制模态（exclusive）：无法点击外部关闭，只能通过按钮/返回键处理，
## 用于"迁移后必须重启"等不可跳过的提示
func show_message(message: String, cancel_visible: bool = false, options: Array = [], force: bool = false) -> bool:
	_message.text = message
	_cancel_btn.modulate.a = 0 if not cancel_visible else 1
	_set_option(options)

	_pop_up_window(0)
	if force:
		exclusive = true  # 模态：点击弹窗外区域不会关闭（popup 失去焦点不隐藏）
	await window_close
	if force:
		exclusive = false
	return _confirm

# 弹出延迟校准窗口
# 返回 Dictionary: {"delay": 校准/输入的延迟值(ms), "bt_auto_off_performing": 蓝牙自动关闭弹奏模式开关(0/1)}
func show_delay_adjust(current_delay: int = 0) -> Dictionary:
	_delay_adjust.start_calibration(current_delay)

	_pop_up_window(1)
	await window_close
	# 兜底停止（popup_hide 已会调用，此处再保险一次）
	_delay_adjust.stop_calibration()
	return _delay_adjust.get_result()

# 弹出皮肤修改窗口
func show_note_skin_adjust() -> String:
	_note_skin_adjust.init_adjust()
	
	_pop_up_window(2)
	await window_close
	# 关闭时持久化皮肤配置（颜色/光效/长条模式等）并触发 FlowArea 重载
	_note_skin_adjust.save_config()
	return _note_skin_adjust.get_selected_skin()

# 弹出粒子设置窗口
# judge_type: Perfect / Great / Good / Bad，决定编辑哪个判定类型的特效
# 返回 Dictionary 字段见 ParticleAdjust.get_result
func show_particle_adjust(judge_type: String = "Perfect") -> Dictionary:
	_particle_adjust.init_adjust(judge_type)
	
	_pop_up_window(3)
	await get_tree().create_timer(_POPUP_ANIM_DURATION).timeout
	_particle_adjust.start_preview()
	await window_close
	_particle_adjust.stop_preview()
	return _particle_adjust.get_result()

# 弹出图片设置窗口
## view_name: 视图名称（main/store/score/play/track/midi/setting），用于从 ThemeManager 读取当前配置初始化控件
## allow_cover: 是否允许选择"封面"类型（仅 play 视图为 true）
## 返回 Dictionary 字段见 ImageAdjust.get_result
func show_image_adjust(view_name: String = "", allow_cover: bool = false) -> Dictionary:
	_image_adjust.init_adjust(view_name, allow_cover)
	
	_pop_up_window(4)
	await window_close
	return _image_adjust.get_result()

# 弹出键位设置窗口
## current_keys / current_display_names：由调用方从 pending 配置传入，未传则回退到配置文件
## current_kb_mode / current_gap：键盘模式开关与左右间距；current_alt_*：交替轨道颜色
## current_lane_sep：轨道分隔线开关（0/1，仅键盘模式生效）
## 返回 Dictionary: {"keys": "A,S,D,F,...", "display_names": "P1,,,...",
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
		ConfigManager.instance.get_string("Lane", "keyboard_mode_keys", "A,S,D,F,J,K,L,;")
	var names_str := current_display_names if not current_display_names.is_empty() else \
		ConfigManager.instance.get_string("Lane", "keyboard_mode_display_names", "")
	_kb_mode_adjust.init_adjust(keys_str, names_str, current_kb_mode, current_alt_color, current_alt_count, current_alt_colors, current_gap, current_lane_sep)
	
	_pop_up_window(5)
	await window_close
	# 兜底取消录入状态（popup_hide 已调用，此处再保险一次）
	_kb_mode_adjust._cancel_recording()
	return _kb_mode_adjust.get_result()

# 弹出下落模式设置窗口
## 关闭时由 FallingAdjust 内部 save_config 即时写入 ConfigManager 并触发 config_changed
## 返回 Dictionary 字段见 FallingAdjust.get_result（供 SettingList 同步 _pending_config）
func show_falling_adjust() -> Dictionary:
	# 等 _pop_up_window 内部 popup() 完成（弹窗可见）后再初始化并启动下落预览：
	# init_adjust 末尾会 await 一帧后调用 _start_preview_loop，其依赖 is_visible_in_tree() 为真
	await _pop_up_window(6)
	_falling_adjust.init_adjust()
	await window_close
	# 兜底停止预览（popup_hide 已调用，此处再保险一次）
	_falling_adjust.stop_preview()
	# 关闭时持久化下落参数并触发 FlowArea 热重载
	_falling_adjust.save_config()
	return _falling_adjust.get_result()

# 弹出存储位置设置窗口
## current_path：当前存储路径（为空时弹窗显示 PathHelper.get_storage_root()）
## 返回 Dictionary: {"action": "confirmed"|"cancelled", "path": String}
## 确认后由调用方（SettingList）执行路径校验与迁移
func show_storage_location_adjust(current_path: String = "") -> Dictionary:
	_storage_location_adjust.init_adjust(current_path)

	_pop_up_window(7)
	await window_close
	return _storage_location_adjust.get_result()

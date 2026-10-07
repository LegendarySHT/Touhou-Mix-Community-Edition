extends HBoxContainer

class_name FallingAdjust

## 音符下落设置弹窗脚本
## 左侧预览区实时预览音符下落动画（含皮肤、下落时间、缓动曲线）
## 右侧设置区配置下落模式、时间、速度倍率、缓动函数/相位

# ===== 节点引用 =====
@onready var _preview_panel: Panel = $FallingPreview
@onready var _preview_block: TextureRect = $FallingPreview/block
@onready var _judge_line: PanelContainer = $FallingPreview/Line
@onready var _mode_option: OptionButton = $VBoxC/OptionButton
@onready var _fall_duration_edit: LineEdit = $VBoxC/OtherOptions/FallDuration/LineEdit
@onready var _fall_func_btn: OptionButton = $VBoxC/OtherOptions/FallFunc
@onready var _fall_phase_btn: OptionButton = $VBoxC/OtherOptions/FallPhase
@onready var _fall_speed_edit: LineEdit = $VBoxC/OtherOptions/FallSpeed/LineEdit
@onready var _fall_func2_btn: OptionButton = $VBoxC/OtherOptions/FallFunc2
@onready var _fall_phase2_btn: OptionButton = $VBoxC/OtherOptions/FallPhase2

# ===== 预览动画状态 =====
var _preview_tween: Tween = null
var _is_initialized: bool = false

# 缓动函数/相位的 UI 索引映射（与 PopupWindow.tscn 中 OptionButton 的 popup/item 顺序一致）
const _FUNC_NAMES: Array[String] = [
	"LINEAR", "QUAD", "CUBIC", "QUART", "QUINT",
	"SINE", "CIRC", "ELASTIC", "BACK", "BOUNCE"
]
const _PHASE_NAMES: Array[String] = ["IN", "OUT", "IN_OUT"]

# 下落时间/速度倍率的输入范围
const _FALL_TIME_MIN: float = 0.2
const _FALL_TIME_MAX: float = 5.0
const _SPEED_MULT_MIN: float = 0.1
const _SPEED_MULT_MAX: float = 5.0

## 由 PopupWindow.show_falling_adjust 调用：初始化控件值并启动预览
func init_adjust() -> void:
	# 从配置读取初始值
	var fall_mode := ConfigManager.instance.get_int("Generator", "note_fall_mode")
	var fall_time := ConfigManager.instance.get_float("Generator", "note_fall_time")
	var fall_speed_mult := ConfigManager.instance.get_float("Generator", "note_fall_speed_after_judge_multiplier")
	var before_func := ConfigManager.instance.get_string("Generator", "note_fall_easing_before_func", "LINEAR")
	var before_phase := ConfigManager.instance.get_string("Generator", "note_fall_easing_before_phase", "IN")
	var after_func := ConfigManager.instance.get_string("Generator", "note_fall_easing_after_func", "LINEAR")
	var after_phase := ConfigManager.instance.get_string("Generator", "note_fall_easing_after_phase", "IN")

	# 同步到 UI
	_mode_option.select(clampi(fall_mode, 0, 2))
	_fall_duration_edit.text = str(fall_time)
	_fall_speed_edit.text = str(fall_speed_mult)
	_select_func(_fall_func_btn, before_func)
	_select_phase(_fall_phase_btn, before_phase)
	_select_func(_fall_func2_btn, after_func)
	_select_phase(_fall_phase2_btn, after_phase)

	# 应用当前皮肤到预览 block
	_apply_current_skin_to_preview()

	# 根据模式更新缓动选项可用性
	_update_easing_controls_state()

	_is_initialized = true

	# 等一帧让布局稳定（确保 block.size 和 judge_line.position 已计算），然后启动预览
	await get_tree().process_frame
	_start_preview_loop()

## 停止预览动画 — 由 PopupWindow 在 popup_hide / window_close 时调用
func stop_preview() -> void:
	_stop_preview()

## 保存配置到 ConfigManager 并触发 FlowArea 热重载
## 由 PopupWindow 在 window_close 后调用
## 无条件写入 _current_config（不依赖值变化检测），然后统一 emit 一次信号
## FlowArea._on_config_changed 收到信号后调用 _apply_note_fall_config_from_settings 读取全部字段
func save_config() -> void:
	var result := get_result()
	var cm := ConfigManager.instance
	# 无条件写入，确保 _current_config 与 UI 一致
	cm.set_value("Generator", "note_fall_mode", int(result["note_fall_mode"]))
	cm.set_value("Generator", "note_fall_time", float(result["note_fall_time"]))
	cm.set_value("Generator", "note_fall_speed_after_judge_multiplier", float(result["note_fall_speed_after_judge_multiplier"]))
	cm.set_value("Generator", "note_fall_easing_before_func", String(result["note_fall_easing_before_func"]))
	cm.set_value("Generator", "note_fall_easing_before_phase", String(result["note_fall_easing_before_phase"]))
	cm.set_value("Generator", "note_fall_easing_after_func", String(result["note_fall_easing_after_func"]))
	cm.set_value("Generator", "note_fall_easing_after_phase", String(result["note_fall_easing_after_phase"]))
	# 统一 emit 一次信号，触发 FlowArea 热重载
	EvtBus.config_changed.emit("note_fall_mode", "Generator", int(result["note_fall_mode"]))

## 返回当前编辑结果（供 PopupWindow.show_falling_adjust 返回给 SettingList）
func get_result() -> Dictionary:
	return {
		"note_fall_mode": _mode_option.selected,
		"note_fall_time": _get_current_fall_time(),
		"note_fall_speed_after_judge_multiplier": _get_current_fall_speed_mult(),
		"note_fall_easing_before_func": _FUNC_NAMES[_fall_func_btn.selected] if _fall_func_btn.selected >= 0 else "LINEAR",
		"note_fall_easing_before_phase": _PHASE_NAMES[_fall_phase_btn.selected] if _fall_phase_btn.selected >= 0 else "IN",
		"note_fall_easing_after_func": _FUNC_NAMES[_fall_func2_btn.selected] if _fall_func2_btn.selected >= 0 else "LINEAR",
		"note_fall_easing_after_phase": _PHASE_NAMES[_fall_phase2_btn.selected] if _fall_phase2_btn.selected >= 0 else "IN",
	}

# ===== 内部实现 =====

func _select_func(btn: OptionButton, func_name: String) -> void:
	var idx := _FUNC_NAMES.find(func_name.to_upper())
	btn.select(maxi(0, idx))

func _select_phase(btn: OptionButton, phase_name: String) -> void:
	var idx := _PHASE_NAMES.find(phase_name.to_upper())
	btn.select(maxi(0, idx))

## 应用当前选中的音符皮肤到预览 block（使用 short 类型的贴图）
func _apply_current_skin_to_preview() -> void:
	var skin_name := ConfigManager.instance.get_string("Appearance", "block_skin_preset", SkinManager.DEFAULT_SKIN_PRESET)
	var skin_textures := SkinMGR.get_skin_textures(skin_name)
	var transparent := _create_transparent_texture()
	_preview_block.texture = skin_textures.get("short", transparent)
	_preview_block.get_node("core").texture = skin_textures.get("short_core", transparent)

func _create_transparent_texture(width: int = 64, height: int = 64) -> Texture2D:
	var image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	return ImageTexture.create_from_image(image)

## 仅自定义模式 (mode=2) 时启用缓动选项；匀速/加速下落使用预设值
## 匀速/加速模式：同步把 4 个按钮的选中项设为预设值，让用户能直观看到预定义的缓动参数
func _update_easing_controls_state() -> void:
	var mode := _mode_option.selected
	var is_custom := mode == 2
	_fall_func_btn.disabled = not is_custom
	_fall_phase_btn.disabled = not is_custom
	_fall_func2_btn.disabled = not is_custom
	_fall_phase2_btn.disabled = not is_custom
	# 匀速/加速模式：把按钮选中项同步到预设值（不触发信号，避免递归）
	if not is_custom:
		var preset := EasingMapper.get_preset_config(mode)
		_select_func(_fall_func_btn, preset["before_func"])
		_select_phase(_fall_phase_btn, preset["before_phase"])
		_select_func(_fall_func2_btn, preset["after_func"])
		_select_phase(_fall_phase2_btn, preset["after_phase"])

func _on_setting_changed(_v) -> void:
	if not _is_initialized:
		return
	_update_easing_controls_state()
	_start_preview_loop()

# ===== 缓动参数解析（根据模式选择预设或自定义值）=====

func _get_current_trans_before() -> int:
	match _mode_option.selected:
		0: return EasingMapper.string_to_trans(EasingMapper.get_preset_config(0)["before_func"])
		1: return EasingMapper.string_to_trans(EasingMapper.get_preset_config(1)["before_func"])
		_:
			var idx := _fall_func_btn.selected if _fall_func_btn.selected >= 0 else 0
			return EasingMapper.string_to_trans(_FUNC_NAMES[idx])

func _get_current_ease_before() -> int:
	match _mode_option.selected:
		0: return EasingMapper.string_to_ease(EasingMapper.get_preset_config(0)["before_phase"])
		1: return EasingMapper.string_to_ease(EasingMapper.get_preset_config(1)["before_phase"])
		_:
			var idx := _fall_phase_btn.selected if _fall_phase_btn.selected >= 0 else 0
			return EasingMapper.string_to_ease(_PHASE_NAMES[idx])

func _get_current_trans_after() -> int:
	match _mode_option.selected:
		0: return EasingMapper.string_to_trans(EasingMapper.get_preset_config(0)["after_func"])
		1: return EasingMapper.string_to_trans(EasingMapper.get_preset_config(1)["after_func"])
		_:
			var idx := _fall_func2_btn.selected if _fall_func2_btn.selected >= 0 else 0
			return EasingMapper.string_to_trans(_FUNC_NAMES[idx])

func _get_current_ease_after() -> int:
	match _mode_option.selected:
		0: return EasingMapper.string_to_ease(EasingMapper.get_preset_config(0)["after_phase"])
		1: return EasingMapper.string_to_ease(EasingMapper.get_preset_config(1)["after_phase"])
		_:
			var idx := _fall_phase2_btn.selected if _fall_phase2_btn.selected >= 0 else 0
			return EasingMapper.string_to_ease(_PHASE_NAMES[idx])

func _get_current_fall_time() -> float:
	var text := _fall_duration_edit.text.strip_edges()
	if text.is_valid_float():
		return clampf(text.to_float(), _FALL_TIME_MIN, _FALL_TIME_MAX)
	return 1.0

func _get_current_fall_speed_mult() -> float:
	var text := _fall_speed_edit.text.strip_edges()
	if text.is_valid_float():
		return clampf(text.to_float(), _SPEED_MULT_MIN, _SPEED_MULT_MAX)
	return 1.0

# ===== 预览动画 =====

## 启动循环预览动画：block 从顶部下落到判定线，再继续下落到底部之外，循环
func _start_preview_loop() -> void:
	_stop_preview()
	if not is_visible_in_tree():
		return

	var fall_time := _get_current_fall_time()
	var trans_before := _get_current_trans_before()
	var ease_before := _get_current_ease_before()
	var trans_after := _get_current_trans_after()
	var ease_after := _get_current_ease_after()
	var speed_mult := _get_current_fall_speed_mult()

	# 读取 block 和判定线的布局参数
	var block_height := _preview_block.size.y
	var block_initial_y := _preview_block.position.y  # 由 anchor+offset 决定的基础位置（顶部锚定）
	var block_initial_center_y := block_initial_y + block_height * 0.5

	var line_y := _judge_line.position.y
	var line_height := _judge_line.size.y
	var line_center_y := line_y + line_height * 0.5

	var preview_height := _preview_panel.size.y

	# block 中心的目标 y 坐标（相对 FallingPreview）
	var start_center_y := block_initial_center_y  # 初始位置（顶部之外）
	var line_center_target := line_center_y       # 判定线位置
	var end_center_y := preview_height + block_height * 0.5  # 底部之外

	# 转换为 offset_transform_position.y 偏移量
	# block 中心 y = block_initial_center_y + offset_transform_position.y
	# 所以 offset = target_center_y - block_initial_center_y
	var start_offset := start_center_y - block_initial_center_y  # = 0
	var line_offset := line_center_target - block_initial_center_y
	var end_offset := end_center_y - block_initial_center_y

	# 计算过线后时间
	# 判定线前速度 = distance_before / fall_time
	# 判定线后速度 = speed * speed_mult
	# 判定线后时间 = distance_after / (speed * speed_mult)
	var distance_before := line_offset - start_offset
	var distance_after := end_offset - line_offset
	var speed = distance_before / max(0.001, fall_time)
	var after_time = distance_after / max(0.001, speed * speed_mult)

	# 设置初始位置
	_preview_block.offset_transform_position.y = start_offset

	_preview_tween = AniMGR.create_managed_tween(self)
	_preview_tween.set_loops()
	# 第一段：从顶部下落到判定线（判定线前缓动）
	_preview_tween.tween_property(_preview_block, "offset_transform_position:y", line_offset, fall_time) \
		.set_trans(trans_before).set_ease(ease_before)
	# 第二段：从判定线继续下落到底部之外（判定线后缓动）
	_preview_tween.tween_property(_preview_block, "offset_transform_position:y", end_offset, after_time) \
		.set_trans(trans_after).set_ease(ease_after)
	# 短暂停顿
	_preview_tween.tween_interval(0.3)
	# 瞬间重置回起始位置，避免 set_loops 时第一段从底部反向回到判定线
	_preview_tween.tween_callback(func() -> void: _preview_block.offset_transform_position.y = start_offset)

func _stop_preview() -> void:
	if _preview_tween and _preview_tween.is_valid():
		_preview_tween.kill()
	_preview_tween = null

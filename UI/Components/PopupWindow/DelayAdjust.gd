extends VBoxContainer

class_name DelayAdjust

## 校准完成信号（连续 N 个稳定样本后触发），由 PopupWindow 监听并 hide()
signal finish_requested

@onready var _delay_indicator: Panel = $DelayIndicator
@onready var _center_line: PanelContainer = $DelayIndicator/CenterLine
@onready var _adjust_line: PanelContainer = $DelayIndicator/AdjustLine
@onready var _shadow_line: PanelContainer = $DelayIndicator/ShadowLine
@onready var _delay_value: LineEdit = $HBoxC/Value
@onready var delay_btn: Button = $Button
@onready var _bt_status: Label = $BtStatus
@onready var _bt_toggle: CheckButton = $BtToggle

# ===== 延迟校准状态 =====
## 校准是否进行中
var _calib_active: bool = false
## 已采集的延迟样本（单位：ms，正=音频延迟需正向补偿，负=负向补偿）
var _calib_samples: Array[float] = []
## AdjustLine 循环动画 Tween 引用
var _adjust_line_tween: Tween = null
## ShadowLine 残影淡出 Tween 引用（点击校准时复用 ShadowLine 显示残影，避免动态创建节点）
var _shadow_tween: Tween = null
## 连续稳定样本计数（与前一个样本差值 ≤ _STABLE_MAX_DIFF 的连续次数）
var _stable_count: int = 0
## 上一个样本值（用于差值计算）
var _last_sample: float = NAN
## 上一个有效的延迟输入文本（用于过滤非法字符后回退）
var _prev_delay_text: String = "0"
## 程序化设置 _delay_value.text 时的递归守卫标志，避免触发 text_changed 重复更新
var _setting_delay_text: bool = false
## 程序化设置 _bt_toggle.button_pressed 时的递归守卫标志，避免触发 toggled 重复写配置
var _setting_bt_toggle: bool = false

## AdjustLine 单向运动范围（绝对值，单位：像素）
const _ADJUST_LINE_RANGE: float = 310
## 单段时间（每拍 0.5s，4 拍循环 = 3 轻 + 1 重 = 2.0s）
const _BEAT_SEGMENT_SEC: float = 0.5
## 动画速度 = RANGE/2 ÷ SEGMENT = 155/0.5 = 310px/s，用于 px↔ms 互转
const _ANIM_SPEED: float = _ADJUST_LINE_RANGE * 0.5 / _BEAT_SEGMENT_SEC
## 延迟显示范围（±ms），超过此范围的延迟值会被 clamp 到边界
const _MAX_DELAY_MS: float = 300.0
## 进入稳定状态所需连续稳定次数（3个连续样本 = _stable_count >= 2 时开始移动 CenterLine 和 LineEdit）
const _STABLE_START_THRESHOLD: int = 2
## 校准完成所需连续稳定次数（8个连续样本 = _stable_count >= 7 时完成）
const _CALIB_DONE_STABLE: int = 7
## 样本间允许的最大差值（ms），超过则视为不稳定
const _STABLE_MAX_DIFF: float = 50.0

# ===== 节拍音配置（GM 鼓组，channel 9）=====
# 重拍：Closed Hi-Hat（清脆响亮，穿透力强）；轻拍：Side Stick（军鼓击边，短促轻巧）
const _BEAT_CHANNEL: int = 9           # GM 标准鼓组通道
const _BEAT_TRACK: int = 0
const _BEAT_HARD_PITCH: int = 42       # Closed Hi-Hat（重拍，清脆响亮）
const _BEAT_HARD_VEL: int = 115
const _BEAT_SOFT_PITCH: int = 37       # Side Stick（轻拍，军鼓击边短促）
const _BEAT_SOFT_VEL: int = 60
const _BEAT_DURATION_SEC: float = 0.12 # 单拍发声时长（note_off 延迟，避免叠音）
# 待清理的 note_off entry 列表（stop_calibration 时强制停音）
# 每个 entry = {pitch, done, mp}，done 标志防止 SceneTreeTimer 自然超时重复触发 note_off
var _beat_off_timers: Array = []
# 校准前保存的 MidiPlaybackManager 音量（dB），stop_calibration 时恢复
# 避免校准期间修改的全局音量污染后续 PlayView 播放
var _saved_volume_db: float = NAN

# 启动校准：重置数据 + 启动 AdjustLine 单向循环动画
func start_calibration(current_delay: int = 0) -> void:
	_calib_active = true
	_calib_samples.clear()
	_stable_count = 0
	_last_sample = NAN

	# 刷新蓝牙输出检测提示与开关初始状态（调用方已强制刷新过检测，此处读缓存）
	_update_bt_status()

	_delay_value.text = str(current_delay)
	_prev_delay_text = _delay_value.text
	_update_center_line(float(_delay_value.text))

	# 确保 SoundFont 已加载到后端合成器（trigger_note_on 依赖 SoundFont）
	# 设置页打开 DelayAdjust 时未调用 play()，SoundFont 可能尚未懒加载到 synth
	var mp = MidiPlaybackManager.instance
	if mp:
		mp.ensure_soundfont_loaded()
		_saved_volume_db = mp.midi_player_config.get("volume_db", -20.0)
		# 走与 TrackView/PlayView 同一套映射（系数见 MidiPlaybackManager.MIDI_VOLUME_GAIN）
		mp.apply_ui_midi_volume(mp.get_effective_midi_volume(-1.0))
	# 启动 AdjustLine 单向循环动画
	# AdjustLine 本身不可见，仅作为位置跟踪器，点击时在当前位置生成残影
	if _adjust_line_tween and _adjust_line_tween.is_valid():
		_adjust_line_tween.kill()
	_adjust_line_tween = AniMGR.create_sequence("popup_adjust_line_loop")
	_adjust_line_tween.set_loops()
	_adjust_line.offset_transform_position.x = 0
	_adjust_line_tween.set_trans(Tween.TRANS_LINEAR)

	# 4 拍循环：轻-轻-轻-重
	_adjust_line_tween.tween_property(_adjust_line, "offset_transform_position:x", -_ADJUST_LINE_RANGE / 2, _BEAT_SEGMENT_SEC)
	_adjust_line_tween.tween_callback(func(): _play_beat_sound(false))
	_adjust_line_tween.tween_property(_adjust_line, "offset_transform_position:x", - _ADJUST_LINE_RANGE, _BEAT_SEGMENT_SEC)
	_adjust_line_tween.tween_callback(func(): _play_beat_sound(false))
	_adjust_line_tween.tween_callback(func(): _adjust_line.offset_transform_position.x = _ADJUST_LINE_RANGE)
	_adjust_line_tween.tween_property(_adjust_line, "offset_transform_position:x", _ADJUST_LINE_RANGE / 2, _BEAT_SEGMENT_SEC)
	_adjust_line_tween.tween_callback(func(): _play_beat_sound(false))
	_adjust_line_tween.tween_property(_adjust_line, "offset_transform_position:x", 0, _BEAT_SEGMENT_SEC)
	_adjust_line_tween.tween_callback(func(): _on_hard_beat_triggered())
	
# 停止校准：终止动画 + 停止所有节拍音 + 恢复音量
func stop_calibration() -> void:
	if not _calib_active:
		return
	_calib_active = false
	if _adjust_line_tween and _adjust_line_tween.is_valid():
		_adjust_line_tween.kill()
		_adjust_line_tween = null
	# 清理残影 tween + 隐藏 ShadowLine，防止弹窗关闭时残影残留
	if _shadow_tween and _shadow_tween.is_valid():
		_shadow_tween.kill()
	_shadow_tween = null
	_shadow_line.visible = false
	_shadow_line.modulate.a = 1.0
	_stop_all_beat_sounds()
	# 恢复校准前的全局音量，避免污染后续 PlayView 播放
	if not is_nan(_saved_volume_db):
		var mp = MidiPlaybackManager.instance
		if mp:
			mp.set_volume_db(_saved_volume_db)
		_saved_volume_db = NAN

# 停止所有节拍音：对每个未完成的 entry 直接触发 note_off 并标记 done
# done 标志防止 SceneTreeTimer 自然超时时重复触发 note_off（会导致 _manualActiveVoiceCount 变负）
func _stop_all_beat_sounds() -> void:
	for entry in _beat_off_timers:
		if entry["done"]:
			continue
		entry["done"] = true
		if is_instance_valid(entry["mp"]) and entry["mp"].midi_player:
			entry["mp"].midi_player.call("trigger_note_off", entry["pitch"], 0, _BEAT_CHANNEL, _BEAT_TRACK)
	_beat_off_timers.clear()

## 播放节拍音：通过 MidiPlaybackManager 实时合成 GM 鼓组
## 与 PlayView 演奏模式音符走同一音频路径（trigger_note_on），确保延迟特性一致
func _play_beat_sound(hard: bool = false) -> void:
	var mp = MidiPlaybackManager.instance
	if not mp or not mp.midi_player:
		return
	var pitch: int = _BEAT_HARD_PITCH if hard else _BEAT_SOFT_PITCH
	var vel: int = _BEAT_HARD_VEL if hard else _BEAT_SOFT_VEL
	mp.midi_player.call("trigger_note_on", pitch, vel, _BEAT_CHANNEL, _BEAT_TRACK)
	# 延迟 note_off，避免叠音；用 SceneTreeTimer 不依赖本节点生命周期
	var timer := get_tree().create_timer(_BEAT_DURATION_SEC)
	# entry 持有 pitch/done/mp，done 标志防止自然超时与 _stop_all_beat_sounds 重复触发
	var entry := {"pitch": pitch, "done": false, "mp": mp}
	_beat_off_timers.append(entry)
	timer.timeout.connect(func() -> void:
		if entry["done"]:
			return
		entry["done"] = true
		_beat_off_timers.erase(entry)
		if is_instance_valid(mp) and mp.midi_player:
			mp.midi_player.call("trigger_note_off", pitch, 0, _BEAT_CHANNEL, _BEAT_TRACK)
	)

## 获取当前延迟值（用于 PopupWindow.show_delay_adjust 返回）
# 容错：空文本或非法输入回退为 0，并 clamp 到 ±_MAX_DELAY_MS
func get_delay_value() -> int:
	var text := _delay_value.text.strip_edges()
	if text.is_empty() or text == "-":
		return 0
	return clampi(text.to_int(), -int(_MAX_DELAY_MS), int(_MAX_DELAY_MS))

## 获取窗口完整结果（PopupWindow.show_delay_adjust 返回给设置页）
# {"delay": 校准/输入的延迟值, "bt_auto_off_performing": 蓝牙自动关闭弹奏模式开关}
func get_result() -> Dictionary:
	return {
		"delay": get_delay_value(),
		"bt_auto_off_performing": 1 if _bt_toggle.button_pressed else 0,
	}

# ===== 蓝牙输出检测提示与开关 =====
# 刷新顶部蓝牙输出状态提示；窗口每次打开（start_calibration）都会调用
func _update_bt_status() -> void:
	var is_bt := AudioBtDetector.is_bluetooth_output()
	var status := AudioBtDetector.get_status_text()
	_bt_status.text = "当前音频输出：%s" % status
	if is_bt:
		_bt_status.text += "｜正在校准蓝牙延迟预设"
	# 开关初始状态从配置读取（默认开启）
	var auto_off := ConfigManager.instance.get_int("Gameplay", "bt_auto_disable_performing_mode", 1) == 1
	_setting_bt_toggle = true
	_bt_toggle.button_pressed = auto_off
	_setting_bt_toggle = false

# 蓝牙自动关闭弹奏模式开关切换：即时写回运行时配置（对齐 FallingAdjust 即时应用模式）
# 持久化由调用方（SettingList._popup_delay_adjust）经 _pending_config 退出设置页时保存
func _on_bt_auto_off_toggled(pressed: bool) -> void:
	if _setting_bt_toggle:
		return
	ConfigManager.instance.set_value_and_notify("Gameplay", "bt_auto_disable_performing_mode", 1 if pressed else 0)

# 重拍触发：播放重拍音（用户应在此刻点击）
# 重拍在 AdjustLine 中心(0) 触发，点击时用 AdjustLine 位置算延迟，与动画完全同步
func _on_hard_beat_triggered() -> void:
	_play_beat_sound(true)

# 点击校准按钮：用 AdjustLine 当前位置换算延迟，px → ms 由 _ANIM_SPEED 转换
func _on_delay_btn_pressed() -> void:
	if not _calib_active:
		return
	var click_x: float = _adjust_line.offset_transform_position.x
	# 生成残影：直接用 AdjustLine 当前位置，残影直观反映点击时刻 AdjustLine 的位置
	_spawn_adjust_line_ghost(click_x)
	# px → ms：取反使 x<0→正值（汇总符号规范：左=正，即音频偏晚=正向补偿）
	# 用户在听到节拍时才点击：音频输出偏晚 → 点击落在重拍位置左侧（click_x<0）→ 应得正向补偿
	var delay: float = -click_x / _ANIM_SPEED * 1000.0
	# 样本与显示/保存范围保持一致（±_MAX_DELAY_MS），避免越界均值（如 ±700ms）与保存时的 clamp 矛盾
	delay = clampf(delay, -_MAX_DELAY_MS, _MAX_DELAY_MS)
	_calib_samples.append(delay)
	# 稳定性检测：与前一个样本的差值 ≤ 50ms → 计数器 +1，否则归零
	if not is_nan(_last_sample):
		if abs(delay - _last_sample) <= _STABLE_MAX_DIFF:
			_stable_count += 1
		else:
			_stable_count = 0
	_last_sample = delay
	# 进入稳定状态（连续3个样本稳定，即 _stable_count >= 2）→ 开始更新 CenterLine 和 LineEdit
	if _stable_count >= _STABLE_START_THRESHOLD:
		var avg: float = _compute_stable_average()
		_set_delay_value(avg)
	# 连续8个样本稳定（_stable_count >= 7）→ 校准完成
	if _stable_count >= _CALIB_DONE_STABLE:
		_finish_calibration()

# ===== 手动输入延迟值（LineEdit 信号处理）=====
# text_changed：实时校验输入，过滤非法字符，并同步 CenterLine 位置
func _on_delay_text_changed(new_text: String) -> void:
	if _setting_delay_text:
		return
	# 合法输入：空、单独 '-'、或 [-]?数字（≤4 字符）
	if new_text.is_empty() or new_text == "-" or (new_text.is_valid_int() and new_text.length() <= 4):
		_prev_delay_text = new_text
		# 有效整数时同步 CenterLine；空或 '-' 时保留上次位置
		if new_text.is_valid_int() and not new_text.is_empty():
			_update_center_line(float(new_text.to_int()))
	else:
		# 非法输入，回退到上一个有效文本
		_setting_delay_text = true
		_delay_value.text = _prev_delay_text
		_delay_value.caret_column = _prev_delay_text.length()
		_setting_delay_text = false

# text_submitted（回车）：完成编辑，clamp 并格式化
func _on_delay_text_submitted(_submitted_text: String) -> void:
	_finalize_delay_text()
	# 回车后释放焦点，避免 LineEdit 持续拦截 Space 等按键（按钮的快捷键）
	_delay_value.release_focus()

# focus_exited：失焦时完成编辑
func _on_delay_focus_exited() -> void:
	_finalize_delay_text()

# 完成编辑：空值或单独 '-' 置 0，超范围 clamp，重新写回文本与 CenterLine
func _finalize_delay_text() -> void:
	var text := _delay_value.text.strip_edges()
	if text.is_empty() or text == "-":
		_setting_delay_text = true
		_delay_value.text = "0"
		_setting_delay_text = false
		_prev_delay_text = "0"
		_update_center_line(0.0)
		return
	var val: int = clampi(text.to_int(), -int(_MAX_DELAY_MS), int(_MAX_DELAY_MS))
	_setting_delay_text = true
	_delay_value.text = str(val)
	_setting_delay_text = false
	_prev_delay_text = _delay_value.text
	_update_center_line(float(val))

# 在指定位置显示 AdjustLine 残影（点击瞬间的视觉反馈，1秒淡出）
# 复用预先存在的 ShadowLine 节点，避免动态 duplicate + queue_free 在手机上因 tween 被杀导致节点累积
func _spawn_adjust_line_ghost(pos_x: float) -> void:
	# 杀掉上一次未完成的残影 tween，避免新旧 tween 同时改 modulate 冲突
	if _shadow_tween and _shadow_tween.is_valid():
		_shadow_tween.kill()
	_shadow_line.offset_transform_position = Vector2(pos_x, 0)
	_shadow_line.modulate.a = 1.0
	_shadow_line.visible = true
	_shadow_tween = AniMGR.create_managed_tween(self)
	_shadow_tween.tween_property(_shadow_line, "modulate:a", 0.0, 1.0)
	_shadow_tween.finished.connect(func() -> void:
		_shadow_line.visible = false
		_shadow_line.modulate.a = 1.0
	)

# 计算当前稳定窗口内样本的平均值（窗口 = _stable_count + 1 个连续稳定样本）
func _compute_stable_average() -> float:
	var window_size: int = _stable_count + 1
	var start: int = maxi(0, _calib_samples.size() - window_size)
	var sum: float = 0.0
	for i in range(start, _calib_samples.size()):
		sum += _calib_samples[i]
	return sum / float(_calib_samples.size() - start)

# 更新 CenterLine 位置（坐标映射与 _on_delay_btn_pressed 互逆）
# 符号规范统一：左=正（音频偏晚=正向补偿）。
# 音频偏晚时用户"听到节拍再点"会落在左侧，中心线提示条也应在左侧提示正确的点击位置
# clamp 到 ±_MAX_DELAY_MS 避免越出 DelayIndicator 容器边界
func _update_center_line(delay_ms: float) -> void:
	var clamped: float = clampf(delay_ms, -_MAX_DELAY_MS, _MAX_DELAY_MS)
	# ms → px：取反使正延迟落在左侧，与 _on_delay_btn_pressed 的"左=正"一致
	_center_line.offset_transform_position = Vector2(-clamped * _ANIM_SPEED / 1000.0, 0)

# 统一设置延迟值：更新 LineEdit 和 CenterLine（程序化设置，避开 text_changed 重复更新）
func _set_delay_value(delay_ms: float) -> void:
	_setting_delay_text = true
	_delay_value.text = str(roundi(delay_ms))
	_setting_delay_text = false
	_prev_delay_text = _delay_value.text
	_update_center_line(delay_ms)

# 手动拖动 DelayIndicator：在面板范围内点击/拖动 → CenterLine 移动到手指位置并更新延迟
# 注意：TabContainer 切换到本页时本节点 visible=true；PopupWindow hide() 不改子节点 visible，
# 因此用 is_visible_in_tree() 综合判断窗口实际可见性
func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if not (event is InputEventScreenTouch or event is InputEventScreenDrag):
		return
	# 忽略松开事件
	if event is InputEventScreenTouch and not event.pressed:
		return
	var rect := _delay_indicator.get_global_rect()
	if not rect.has_point(event.position):
		return
	# 计算手指相对于 DelayIndicator 中心的 x 偏移（px，下转 ms）
	var local_x: float = event.position.x - rect.get_center().x
	# px → ms：左侧→正延迟，与按钮点击/中心线的"左=正"约定一致
	var delay: float = -local_x / _ANIM_SPEED * 1000.0
	delay = clampf(delay, -_MAX_DELAY_MS, _MAX_DELAY_MS)
	_set_delay_value(delay)

# 校准完成：停止动画并请求 PopupWindow 隐藏
func _finish_calibration() -> void:
	stop_calibration()
	finish_requested.emit()

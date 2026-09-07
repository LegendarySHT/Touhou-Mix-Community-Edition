## 交互人物适配（挂载 Main/Chara/CharaBtn）
## 负责：
##   - 命中测试：只有点中人物实际绘制像素才响应（重写 has_point）
##   - 点击交互：人物跳跃 + 呼出对话气泡 + 短暂切换表情
##   - 立绘来源：CharaMGR 合成当前选中人物
extends TextureButton

## 命中测试：像素 alpha 低于该值视为透明空隙（不响应点击）
const ALPHA_THRESHOLD := 0.1
## 对话气泡停留时长（秒）
const DIALOG_HOLD_TIME := 2.6

## 当前纹理对应的原始图像（hit test 用）
var _hit_img: Image = null
## 当前人物键
var _chara_key: String = ""
## 对话气泡节点（Chara 下的兄弟 Label）
var _dialog: Label = null
var _press_tween: Tween = null
var _dialog_tween: Tween = null
var _portrait: DynamicPortrait
var _host_horizontal_offsets := Vector2.ZERO

func _ready() -> void:
	var host := get_parent() as Control
	_host_horizontal_offsets = Vector2(host.offset_left, host.offset_right)
	# 装饰性交互元素，不参与键盘焦点导航
	focus_mode = Control.FOCUS_NONE
	pressed.connect(_on_pressed)
	button_down.connect(_on_button_down)
	button_up.connect(_on_button_up)
	_portrait = DynamicPortrait.new()
	add_child(_portrait)
	_portrait.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	self_modulate.a = 0.0
	stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	EvtBus.config_changed.connect(_on_config_changed)
	UiStatMGR.state_changed.connect(_on_state_changed)

	_dialog = get_node_or_null("../Dialog")
	if _dialog != null:
		_dialog.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# FileSystemManager 手动单例在 Main._ready 才创建，此处延后到其可用后再初始化立绘
	call_deferred("_init_chara")

## 延迟初始化：等启动扫描结束后合成立绘
func _init_chara() -> void:
	# 扫描合并完成（charas_index 已有数据）
	if not CharaMGR.charas_index.is_empty():
		_apply_chara()
		return
	# 手动单例尚未创建，下帧重试
	if FileSystemManager.instance == null:
		call_deferred("_init_chara")
		return
	# 扫描进行中：订阅 resources_ready（扫描合并完成后才 emit，故不会错过）
	if not FileSystemManager.instance.resources_ready.is_connected(_apply_chara):
		FileSystemManager.instance.resources_ready.connect(_apply_chara, CONNECT_ONE_SHOT)

## 应用当前选中的人物立绘（默认表情 0）
func _apply_chara() -> void:
	_cancel_interaction()
	var key := CharaMGR.get_current_chara_key()
	_chara_key = key
	_portrait.show_character(key)
	texture_normal = null
	_hit_img = null
	set_chara_emotion(0)
	_sync_state()

func _on_config_changed(key: String, section: String, _value: Variant) -> void:
	if section == "Chara" and key == "chara_id":
		_apply_chara()

func _on_state_changed(_old_state: UIStateManager.UIState, _new_state: UIStateManager.UIState) -> void:
	_sync_state()

func _sync_state() -> void:
	var state := UiStatMGR.current_state
	var active := state in [UIStateManager.UIState.ALBUM_VIEW, UIStateManager.UIState.SONG_VIEW, UIStateManager.UIState.SORTED_VIEW, UIStateManager.UIState.STORE_VIEW]
	_portrait.set_active(active)
	disabled = not active or _chara_key.is_empty()
	if not active:
		_cancel_interaction()
		_revert_emotion()
	else:
		var host := get_parent() as Control
		var in_store := state == UIStateManager.UIState.STORE_VIEW
		host.z_index = 11 if in_store else 0
		host.offset_transform_scale = Vector2.ONE * (0.42 if in_store else 1.0)
		var horizontal_margin := 300.0 if in_store else 0.0
		host.offset_left = _host_horizontal_offsets.x - horizontal_margin
		host.offset_right = _host_horizontal_offsets.y - horizontal_margin

func _cancel_interaction() -> void:
	AniMGR.stop_tween(_tween_id("press"))
	AniMGR.stop_tween(_tween_id("dialog"))
	offset_transform_scale = Vector2.ONE
	if _dialog != null:
		_dialog.hide()

func _exit_tree() -> void:
	_cancel_interaction()
	_portrait.set_active(false)

func _tween_id(suffix: String) -> String:
	return "chara_interact_%d_%s" % [get_instance_id(), suffix]

## 切换人物表情（合成对应表情立绘并缓存原始图像用于命中测试）
func set_chara_emotion(emotion: int) -> void:
	if _chara_key.is_empty():
		return
	var tex := CharaMGR.get_portrait(_chara_key, emotion)
	if tex == null:
		return
	texture_normal = tex
	_hit_img = tex.get_image()
	_portrait.set_emotion(emotion)

## 命中测试：把点映射回纹理实际绘制区域（居中等比缩放），按 alpha 判断是否点中人物本身
func has_point(point: Vector2) -> bool:
	if _hit_img == null:
		return _in_drawn_area(point)
	var tsize := Vector2(_hit_img.get_width(), _hit_img.get_height())
	var bsize := size
	if tsize.x <= 0.0 or tsize.y <= 0.0 or bsize.x <= 0.0 or bsize.y <= 0.0:
		return false
	# 与 stretch_mode = keep_aspect_centered 一致的缩放 + 居中
	var scale := minf(bsize.x / tsize.x, bsize.y / tsize.y)
	var dw := tsize.x * scale
	var dh := tsize.y * scale
	var origin := (bsize - Vector2(dw, dh)) * 0.5
	var local := point - origin
	if local.x < 0.0 or local.y < 0.0 or local.x >= dw or local.y >= dh:
		return false
	var ix := clampi(int(local.x / scale), 0, _hit_img.get_width() - 1)
	var iy := clampi(int(local.y / scale), 0, _hit_img.get_height() - 1)
	return _hit_img.get_pixel(ix, iy).a > ALPHA_THRESHOLD

## 无纹理时的兜底命中区（整块）
func _in_drawn_area(point: Vector2) -> bool:
	return point.x >= 0.0 and point.y >= 0.0 and point.x <= size.x and point.y <= size.y

## 点击：随机对话气泡 + 短暂切换表情后复原
func _on_pressed() -> void:
	if _chara_key.is_empty():
		return
	var dialog := CharaMGR.get_dialog(_chara_key)
	if not dialog.text.is_empty():
		# 先切到对话对应表情，气泡结束后回到默认表情
		set_chara_emotion(int(dialog.emotion))
		_show_dialog(dialog.text, Callable(self, "_revert_emotion"))

## 按下：y 轴缩放为 0.99
func _on_button_down() -> void:
	_press_tween = AniMGR.create_managed_tween(self, _tween_id("press"))
	_press_tween.tween_property(self, "offset_transform_scale:y", 0.99, 0.08).set_ease(Tween.EASE_OUT)

## 松手：弹回 1.02 再恢复 1
func _on_button_up() -> void:
	_press_tween = AniMGR.create_managed_tween(self, _tween_id("press"))
	_press_tween.tween_property(self, "offset_transform_scale:y", 1.02, 0.12).set_ease(Tween.EASE_OUT)
	_press_tween.tween_property(self, "offset_transform_scale:y", 1.0, 0.2).set_ease(Tween.EASE_OUT)

## 显示对话气泡，停留后淡出
func _show_dialog(text: String, on_done: Callable) -> void:
	if _dialog == null:
		return
	_dialog.text = text
	_dialog.visible = true
	_dialog.modulate.a = 0.0
	_dialog_tween = AniMGR.create_managed_tween(self, _tween_id("dialog"))
	_dialog_tween.tween_property(_dialog, "modulate:a", 1.0, 0.15).set_ease(Tween.EASE_OUT)
	_dialog_tween.tween_interval(DIALOG_HOLD_TIME)
	_dialog_tween.tween_property(_dialog, "modulate:a", 0.0, 0.2).set_ease(Tween.EASE_IN)
	_dialog_tween.tween_callback(func() -> void:
		_dialog.visible = false
		if on_done.is_valid():
			on_done.call()
	)

## 对话结束后回到默认表情（无对话时不触发，故幂等）
func _revert_emotion() -> void:
	if _chara_key.is_empty() or _hit_img == null:
		return
	set_chara_emotion(0)

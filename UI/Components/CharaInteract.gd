## 交互人物适配（挂载 Main/Chara/CharaBtn）
## 负责：
##   - 命中测试：只有点中人物实际绘制像素才响应（重写 has_point）
##   - 点击交互：人物跳跃 + 呼出对话气泡 + 短暂切换表情
##   - 立绘来源：CharaMGR 合成当前选中人物
extends TextureButton

## 命中测试：像素 alpha 低于该值视为透明空隙（不响应点击）
const ALPHA_THRESHOLD := 0.1
## 立绘浮动振幅（px）与周期（s）
const FLOAT_AMPLITUDE := 10.0
const FLOAT_DURATION := 1.5
## 对话气泡停留时长（秒）
const DIALOG_HOLD_TIME := 2.6

## 当前纹理对应的原始图像（hit test 用）
var _hit_img: Image = null
## 当前人物键
var _chara_key: String = ""
## 对话气泡节点（Chara 下的兄弟 Label）
var _dialog: Label = null
var _press_tween: Tween = null
var _float_tween: Tween = null
var _dialog_tween: Tween = null

func _ready() -> void:
	# 装饰性交互元素，不参与键盘焦点导航
	focus_mode = Control.FOCUS_NONE
	pressed.connect(_on_pressed)
	button_down.connect(_on_button_down)
	button_up.connect(_on_button_up)

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
	var key := CharaMGR.get_current_chara_key()
	if key.is_empty():
		return
	_chara_key = key
	set_chara_emotion(0)
	_start_floating()

## 切换人物表情（合成对应表情立绘并缓存原始图像用于命中测试）
func set_chara_emotion(emotion: int) -> void:
	if _chara_key.is_empty():
		return
	var tex := CharaMGR.get_portrait(_chara_key, emotion)
	if tex == null:
		return
	texture_normal = tex
	_hit_img = tex.get_image()

## 命中测试：把点映射回纹理实际绘制区域（居中等比缩放），按 alpha 判断是否点中人物本身
func has_point(point: Vector2) -> bool:
	if _hit_img == null:
		return _in_drawn_area(point)
	var tsize := Vector2(_hit_img.get_width(), _hit_img.get_height())
	var bsize := size
	if tsize.x <= 0.0 or tsize.y <= 0.0 or bsize.x <= 0.0 or bsize.y <= 0.0:
		return false
	# 与 stretch_mode = keep_aspect_centered 一致的缩放 + 居中
	var fit_scale := minf(bsize.x / tsize.x, bsize.y / tsize.y)
	var dw := tsize.x * fit_scale
	var dh := tsize.y * fit_scale
	var origin := (bsize - Vector2(dw, dh)) * 0.5
	var local := point - origin
	if local.x < 0.0 or local.y < 0.0 or local.x >= dw or local.y >= dh:
		return false
	var ix := clampi(int(local.x / fit_scale), 0, _hit_img.get_width() - 1)
	var iy := clampi(int(local.y / fit_scale), 0, _hit_img.get_height() - 1)
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
	if _press_tween != null:
		_press_tween.kill()
	_press_tween = create_tween()
	_press_tween.tween_property(self, "offset_transform_scale:y", 0.99, 0.08).set_ease(Tween.EASE_OUT)

## 松手：弹回 1.02 再恢复 1
func _on_button_up() -> void:
	if _press_tween != null:
		_press_tween.kill()
	_press_tween = create_tween()
	_press_tween.tween_property(self, "offset_transform_scale:y", 1.02, 0.12).set_ease(Tween.EASE_OUT)
	_press_tween.tween_property(self, "offset_transform_scale:y", 1.0, 0.2).set_ease(Tween.EASE_OUT)

## 立绘上下浮动无限循环动画
func _start_floating() -> void:
	_stop_floating()
	_float_tween = AniMGR.animate_floating(self, FLOAT_AMPLITUDE, FLOAT_DURATION, "main_chara_float")

func _stop_floating() -> void:
	if _float_tween and _float_tween.is_valid():
		_float_tween.kill()
		_float_tween = null
	offset_transform_position = Vector2.ZERO

## 显示对话气泡，停留后淡出
func _show_dialog(text: String, on_done: Callable) -> void:
	if _dialog == null:
		return
	_dialog.text = text
	_dialog.visible = true
	if _dialog_tween != null:
		_dialog_tween.kill()
	_dialog.modulate.a = 0.0
	_dialog_tween = create_tween()
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

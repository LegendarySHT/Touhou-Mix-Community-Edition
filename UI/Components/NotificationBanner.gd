## 顶部横幅通知（Main 常驻，PathRegistry.NOTI_BANNER）
## 收到消息后从屏幕上方下滑入场 → 停留 HOLD_DURATION 秒 → 上滑出场。
## 显示期间再来消息则排队，等上一条走完依次弹出；鼠标悬停时暂停倒计时。
##
## 外部调用（二选一）：
##   EvtBus.notify("已保存", func(): print("clicked"))
##   get_node_or_null(PathRegistry.NOTI_BANNER).notify("已保存", func(): print("clicked"))
extends PanelContainer

## 点击横幅（回调之外额外广播，便于埋点/联动）
signal clicked(text: String)
## 一条通知完整走完（出场上滑结束）
signal closed

## 停留时长（秒）
const HOLD_DURATION := 5.0
## 入场 / 出场时长（秒）
const SLIDE_IN_DURATION := 0.35
const SLIDE_OUT_DURATION := 0.26
## 相邻两条通知之间的间隔（秒）
const QUEUE_GAP := 0.12
## 出场滑出屏幕的额外余量（px）
const SLIDE_MARGIN := 16.0
## 横幅最大宽度（占视口比例），超出按省略号截断
const MAX_WIDTH_RATIO := 0.8
## 按钮高亮圆角与各态不透明度
const BTN_CORNER_RADIUS := 18
const BTN_STATE_ALPHA := {"hover": 0.06, "pressed": 0.12, "hover_pressed": 0.08}

@onready var btn: Button = $btn

## 场景里配置的默认图标
var _default_icon: Texture2D = null
## 当前显示中的条目 {text, on_click, icon}
var _current: Dictionary = {}
## 待显示队列
var _queue: Array[Dictionary] = []
## 入场 → 停留 → 出场整条补间（悬停暂停用）
var _tween: Tween = null
var _playing := false
## 当前这条是否带点击回调：不带则不给手型光标与 hover 高亮，避免暗示可点
var _clickable := false

func _ready() -> void:
	_default_icon = btn.icon
	visible = false
	offset_transform_position = Vector2.ZERO
	btn.pressed.connect(_on_btn_pressed)
	btn.mouse_entered.connect(_pause_tween)
	btn.mouse_exited.connect(_resume_tween)
	EvtBus.notify_requested.connect(_on_notify_requested)
	ThemeMGR.register_theme_applier(self)
	apply_theme()

func _exit_tree() -> void:
	ThemeMGR.unregister_theme_applier(self)

## 弹一条通知
## on_click: 点击横幅后的回调（可选）
## icon: 覆盖场景默认图标（可选）
func notify(text: String, on_click: Callable = Callable(), icon: Texture2D = null) -> void:
	if text.strip_edges().is_empty():
		return
	var item := {"text": text, "on_click": on_click, "icon": icon}
	if _playing:
		_queue.append(item)
	else:
		_play_item(item)

## 立即收起当前通知（队列里的继续弹）
func dismiss() -> void:
	_slide_out(true)

## 清空队列并收起
func clear() -> void:
	_queue.clear()
	dismiss()

## 主题刷新
func apply_theme() -> void:
	var panel := get_theme_stylebox("panel")
	if panel is StyleBoxFlat:
		var flat: StyleBoxFlat = panel.duplicate()
		flat.bg_color = ThemeMGR.get_color("surface_high")
		flat.border_color = ThemeMGR.get_color("border")
		flat.set_border_width_all(1)
		add_theme_stylebox_override("panel", flat)
	_apply_btn_states()
	btn.add_theme_color_override("font_color", ThemeMGR.get_color("text_primary"))
	btn.add_theme_color_override("font_hover_color", ThemeMGR.get_color("text_primary"))
	btn.add_theme_color_override("font_pressed_color", ThemeMGR.get_color("primary_light"))
	btn.add_theme_color_override("font_focus_color", ThemeMGR.get_color("text_primary"))

# ========== 内部 ==========

func _on_notify_requested(text: String, on_click: Callable) -> void:
	notify(text, on_click)

func _play_item(item: Dictionary) -> void:
	_playing = true
	_current = item
	btn.text = str(item["text"])
	var icon: Texture2D = item["icon"]
	btn.icon = icon if icon != null else _default_icon
	var cb: Variant = item["on_click"]
	_clickable = cb is Callable and cb.is_valid()
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if _clickable else Control.CURSOR_ARROW
	_apply_btn_states()
	visible = true
	_apply_text_layout(str(item["text"]))

	if _tween != null and _tween.is_valid():
		_tween.kill()
	# 起点在屏幕上方外
	offset_transform_position = Vector2(0.0, -(get_combined_minimum_size().y + SLIDE_MARGIN))
	_tween = create_tween()
	_tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_tween.tween_property(self, "offset_transform_position:y", 0.0, SLIDE_IN_DURATION)
	_tween.tween_interval(HOLD_DURATION)
	_tween.tween_callback(_slide_out.bind(false))

## 上滑出场
## from_chain=true 表示由入场补间链的尾回调触发，此时旧补间已走完无需 kill
func _slide_out(from_chain: bool) -> void:
	if not _playing:
		return
	if not from_chain and _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_CUBIC)
	_tween.tween_property(self, "offset_transform_position:y", -(size.y + SLIDE_MARGIN), SLIDE_OUT_DURATION)
	_tween.tween_interval(QUEUE_GAP)
	_tween.tween_callback(_on_closed)

func _on_closed() -> void:
	_playing = false
	_current = {}
	visible = false
	offset_transform_position = Vector2.ZERO
	closed.emit()
	if not _queue.is_empty():
		_play_item(_queue.pop_front())

func _on_btn_pressed() -> void:
	var text := str(_current.get("text", ""))
	var cb: Variant = _current.get("on_click", null)
	clicked.emit(text)
	# 回调先执行：回调里再 notify 会被排到队尾，随本次收起一起弹出
	if cb is Callable and cb.is_valid():
		cb.call()
	_slide_out(true)

func _pause_tween() -> void:
	if _tween != null and _tween.is_valid() and _tween.is_running():
		_tween.pause()

func _resume_tween() -> void:
	if _tween != null and _tween.is_valid() and not _tween.is_running():
		_tween.play()

## 按视口比例限制宽度，超长文本用省略号截断
func _apply_text_layout(text: String) -> void:
	var font := btn.get_theme_font("font")
	var font_size := btn.get_theme_font_size("font_size")
	var text_w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var icon_w: float = float(btn.icon.get_width() + btn.get_theme_constant("h_separation")) if btn.icon != null else 0.0
	var padding := get_theme_stylebox("panel").get_minimum_size().x
	var max_w := get_viewport_rect().size.x * MAX_WIDTH_RATIO
	if text_w + icon_w + padding > max_w:
		btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		size = Vector2(max_w, size.y)
	else:
		btn.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
		reset_size()

## flat 按钮在 hover/pressed 仍会画主题方角样式，统一换成贴合胶囊的圆角高亮。
## 无回调的通知不给高亮：整条只是展示，点它也只是提前收起
func _apply_btn_states() -> void:
	var tint := ThemeMGR.get_color("text_primary")
	for state in ["normal", "pressed", "hover", "hover_pressed", "disabled", "focus"]:
		if _clickable and BTN_STATE_ALPHA.has(state):
			var flat := StyleBoxFlat.new()
			flat.set_corner_radius_all(BTN_CORNER_RADIUS)
			flat.bg_color = Color(tint.r, tint.g, tint.b, BTN_STATE_ALPHA[state])
			btn.add_theme_stylebox_override(state, flat)
		else:
			btn.add_theme_stylebox_override(state, StyleBoxEmpty.new())

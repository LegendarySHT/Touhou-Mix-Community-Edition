extends Button
class_name RB_Btn

static var instance: RB_Btn

enum ShowStat {
	NONE = 0,
	BACK_BTN,
	STORE_BTN,
	DELVIEW_BACK,
	CHARA_BTN,
}

@onready var ani:AnimationManager = AniMGR
@onready var ui:UIStateManager = UiStatMGR
@onready var eb: EventBus = EvtBus

@onready var vboxc: VBoxContainer = $VBoxC

func _ready():
	instance = self
	ui.state_changed.connect(_on_state_change)

	eb.page_right.connect(func ():
		if ui.current_state == ui.UIState.SETTINGS_VIEW:
			switch_display(ShowStat.BACK_BTN)
	)
	eb.page_left.connect(func ():
		if ui.current_state == ui.UIState.SETTINGS_VIEW:
			switch_display(ShowStat.DELVIEW_BACK)
	)

func _on_state_change(_old_state, new_state: UIStateManager.UIState):
	if new_state in [ui.UIState.ALBUM_VIEW]:
		switch_display(ShowStat.STORE_BTN)
	elif new_state in [ui.UIState.PLAY_VIEW, ui.UIState.MUSIC_PLAYER_VIEW]:
		switch_display(ShowStat.NONE)
	else:
		switch_display(ShowStat.BACK_BTN)

var _current_stat: ShowStat = ShowStat.STORE_BTN

## 读取当前显示状态（外部只读统一走此方法，避免跨类直读私有字段，TMX-019）
func get_current_stat() -> ShowStat:
	return _current_stat

var _visible: bool = true

# 文本输入时禁用快捷键，避免字母键触发跳转（由 LeftTopBtn 统一驱动）
var _saved_shortcut: Shortcut = null

## 按钮点击的覆盖回调：设置后点击按钮优先调用此回调，用于外部接管（如 PlayerInfo 展开时）
var pressed_override: Callable = Callable()

## 禁用/恢复自身快捷键（禁用时移除 shortcut，恢复时还原）
func _set_shortcut_enabled(enabled: bool) -> void:
	if enabled:
		if _saved_shortcut:
			shortcut = _saved_shortcut
			_saved_shortcut = null
	else:
		if shortcut:
			_saved_shortcut = shortcut
			shortcut = null

func switch_display(content_to_show: ShowStat = ShowStat.NONE):
	# 离线模式下不显示商店图标：请求 STORE_BTN 时改为显示离线专用按钮（CHARA_BTN），其它图标正常入场
	if content_to_show == ShowStat.STORE_BTN and not NetManager.is_online_mode():
		content_to_show = ShowStat.CHARA_BTN
	if content_to_show == _current_stat:
		return

	# 控制按钮框架是否可见
	if content_to_show == ShowStat.NONE:
		if _visible:
			ani.animate_offset_to(self, Vector2(500, 134), 0.5, "RB_VISBLE")
			_visible = false
	else:
		if not _visible:
			ani.animate_offset_back(self, 0.5, "RB_VISBLE")
			_visible = true

	var event = InputEventKey.new()
	# 控制内容显示
	match content_to_show:
		ShowStat.BACK_BTN:
			ani.animate_offset_to(vboxc, Vector2(0, -430))
			event.keycode = KEY_ESCAPE
		ShowStat.STORE_BTN:
			ani.animate_offset_to(vboxc, Vector2(0, 0))
			event.keycode = KEY_O
		ShowStat.DELVIEW_BACK:
			ani.animate_offset_to(vboxc, Vector2(0, -430))
			event.keycode = KEY_RIGHT
		ShowStat.CHARA_BTN:
			ani.animate_offset_to(vboxc, Vector2(0, -860))
			event.keycode = KEY_O
	
	# 快捷键：shortcut 被禁用时更新到 _saved_shortcut，恢复后即生效
	var target := shortcut if shortcut else _saved_shortcut
	if target:
		if target.events.is_empty():
			target.events = [event]
		else:
			target.events[0] = event
	_current_stat = content_to_show

func _on_button_pressed() -> void:
	if pressed_override.is_valid():
		pressed_override.call()
		return
	match _current_stat:
		ShowStat.BACK_BTN:
			UiStatMGR.go_back()
		ShowStat.STORE_BTN:
			UiStatMGR.change_state(UiStatMGR.UIState.STORE_VIEW)
		ShowStat.DELVIEW_BACK:
			eb.page_right.emit()
		ShowStat.CHARA_BTN:
			UiStatMGR.change_state(UiStatMGR.UIState.CHARA_VIEW)

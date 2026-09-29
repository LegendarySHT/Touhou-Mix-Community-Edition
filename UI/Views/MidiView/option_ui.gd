extends VBoxContainer

# 模式设置 (自动/普通 模式)
@onready var mode_btn: OptionButton = $TabView/Mode/HFlowC/Mode
# 限制设置 (无限制/FC/AP)
@onready var limit_btn: OptionButton = $TabView/Mode/HFlowC/Limit
# 游戏模式 （普通/扫描线）
@onready var gamme_mode_btn: OptionButton = $TabView/Mode/HFlowC/GameMode
# 难度预设 (Easy/Normal/Hard/Lunatic/Custom)
@onready var difficulty_btn: OptionButton = $TabView/Mode/HFlowC/Difficulty

const MODE_NORMAL_ID: int = 0
const MODE_AUTO_ID: int = 1

# 难度预设：difficulty_id → {setting_id: value}（Custom 不在此表中，沿用配置现有值）
const DIFFICULTY_PRESETS: Dictionary = {
	0: {"max_simultaneous_blocks": 2, "min_tap_interval": 0.3, "min_touch_cooldown_time": 0.3, "max_touch_move_speed": 800, "max_block_coalesce_time": 5},
	1: {"max_simultaneous_blocks": 2, "min_tap_interval": 0.15, "min_touch_cooldown_time": 0.15, "max_touch_move_speed": 1200, "max_block_coalesce_time": 8},
	2: {"max_simultaneous_blocks": 3, "min_tap_interval": 0.15, "min_touch_cooldown_time": 0.1, "max_touch_move_speed": 99999, "max_block_coalesce_time": 12},
	3: {"max_simultaneous_blocks": 8, "min_tap_interval": 0.0, "min_touch_cooldown_time": 0.0, "max_touch_move_speed": 99999, "max_block_coalesce_time": 0},
}
const DIFFICULTY_CUSTOM_ID: int = 4
const DIFFICULTY_CFG_SECTION: String = "Generator"
const DIFFICULTY_CFG_KEY: String = "difficulty"

var _is_syncing_mode_ui: bool = false
var _is_syncing_difficulty_ui: bool = false


func _ready():
	# 连接选项卡按钮
	for i in get_node("TabBtn").get_children():
		if i is Button:
			i.toggled.connect(_on_button_toggled.bind(i))
			i.focus_entered.connect(func ():
				if not i.button_pressed:
					i.button_pressed = true
			)
	
	for i in [mode_btn, limit_btn, gamme_mode_btn, difficulty_btn]:
		i.get_popup().about_to_popup.connect(_on_popup_menu_popup.bind(i.get_popup()))

	_sync_mode_from_config()
	_sync_difficulty_from_config()

func _sync_mode_from_config() -> void:
	var is_auto := ConfigManager.instance.get_int("Playback", "auto_mode", 0) == 1
	var target_id := MODE_AUTO_ID if is_auto else MODE_NORMAL_ID
	var target_index := mode_btn.get_item_index(target_id)

	if target_index < 0:
		target_index = 0

	_is_syncing_mode_ui = true
	mode_btn.select(target_index)
	_is_syncing_mode_ui = false

func _on_mode_selected(index: int) -> void:
	if _is_syncing_mode_ui:
		return

	var selected_id := mode_btn.get_item_id(index)
	var is_auto := selected_id == MODE_AUTO_ID
	var value := 1 if is_auto else 0

	ConfigManager.instance.set_value_and_notify("Playback", "auto_mode", value)
	var save_ok := ConfigManager.instance.save_config(ConfigManager.USER_CONFIG_PATH)
	if not save_ok:
		GLogger.warning("Failed to persist Playback.auto_mode to user config", "OptionUI")
	else:
		GLogger.info("Playback.auto_mode set to %d" % value, "OptionUI")

## 从配置恢复难度 OptionButton 选中态
func _sync_difficulty_from_config() -> void:
	var difficulty_id := ConfigManager.instance.get_int(DIFFICULTY_CFG_SECTION, DIFFICULTY_CFG_KEY, 1)
	var idx := difficulty_btn.get_item_index(difficulty_id)
	if idx < 0:
		idx = 1  # 回退 Normal
	_is_syncing_difficulty_ui = true
	difficulty_btn.select(idx)
	_is_syncing_difficulty_ui = false

## 难度切换：写预设值到配置 + 锁定设置项（Custom 仅解锁，不覆盖值）
func _on_difficulty_selected(index: int) -> void:
	if _is_syncing_difficulty_ui:
		return
	var difficulty_id: int = difficulty_btn.get_item_id(index)
	# 先写 5 个预设值（触发 KeySequenceManager 运行时更新），最后写 difficulty
	# 保证 SettingList 的 difficulty 监听器触发时 5 个值已就位
	if difficulty_id != DIFFICULTY_CUSTOM_ID:
		var preset: Dictionary = DIFFICULTY_PRESETS.get(difficulty_id, {})
		for setting_id in preset:
			var mapping = SettingsMapper.mappings.get(setting_id)
			if mapping == null:
				continue
			ConfigManager.instance.set_value_and_notify(mapping.section, mapping.key, preset[setting_id])
	ConfigManager.instance.set_value_and_notify(DIFFICULTY_CFG_SECTION, DIFFICULTY_CFG_KEY, difficulty_id)
	var save_ok := ConfigManager.instance.save_config(ConfigManager.USER_CONFIG_PATH)
	if not save_ok:
		GLogger.warning("Failed to persist difficulty to user config", "OptionUI")
	else:
		GLogger.info("Difficulty set to %d" % difficulty_id, "OptionUI")

# 修改popupmenu的弹出位置
func _on_popup_menu_popup(popup_menu: PopupMenu) -> void:
	await get_tree().process_frame
	popup_menu.position.y += 20
	popup_menu.position.x -= 60

## 选项卡切换回调
func _on_button_toggled(toggle_on, button):
	
	if toggle_on:
		var t_page = get_node("TabView/%s" % button.name)
		if t_page.visible:
			return
		t_page.visible = true
		AniMGR.animate_fade_in(t_page, 0.2, "tabSwitch")


func _on_game_mode_selected(index: int) -> void:
	pass # Replace with function body.


func _on_limit_selected(index: int) -> void:
	pass # Replace with function body.

## 设置映射器
## 负责 SettingList 的配置ID与 config.ini 的 section/key 之间的双向映射
class_name SettingsMapper

## 配置映射表：setting_id → {section, key, default_value, value_type}
## value_type: "int", "float", "bool", "string", "color"
static var mappings: Dictionary = {
	# ========== 浏览设置 ==========
	"album_sort_method": {"section": "Browse", "key": "album_sort_method", "value_type": "string"},
	"album_sort_direction": {"section": "Browse", "key": "album_sort_direction", "value_type": "string"},
	
	# ========== 常规设置 ==========
	"online_mode": {"section": "General", "key": "online_mode", "value_type": "int"},
	"auto_upload_score": {"section": "General", "key": "auto_upload_score", "value_type": "int"},
	"display_debug_info": {"section": "General", "key": "display_debug_info", "value_type": "int"},
	"show_advanced_settings": {"section": "General", "key": "show_advanced_settings", "value_type": "int"},
	"language": {"section": "General", "key": "language", "value_type": "int"},
	"server_address": {"section": "General", "key": "server_address", "value_type": "string"},

	# ========== 存储设置 ==========
	"storage_location": {"section": "Storage", "key": "custom_storage_path", "value_type": "string"},

	# ========== 播放设置 ==========
	"performing_mode": {"section": "Playback", "key": "performing_mode", "value_type": "int"},
	"play_ready_animation": {"section": "Playback", "key": "play_ready_animation", "value_type": "int"},
	"playback_speed_scaling": {"section": "Playback", "key": "playback_speed_scaling", "value_type": "float"},
	"vibrate_on_touch": {"section": "Playback", "key": "vibrate_on_touch", "value_type": "int"},
	"vibration_duration": {"section": "Playback", "key": "vibration_duration", "value_type": "int"},
	"use_system_stopwatch": {"section": "Playback", "key": "use_system_stopwatch", "value_type": "int"},
	"max_polyphony": {"section": "Playback", "key": "max_polyphony", "value_type": "int"},
	
	# ========== 音源设置 ==========
	"soundfont_select": {"section": "Gameplay", "key": "soundfont_file", "value_type": "string"},
	"default_midi_volume": {"section": "Gameplay", "key": "default_midi_volume", "value_type": "int"},
	"default_vocal_volume": {"section": "Gameplay", "key": "default_vocal_volume", "value_type": "int"},
	"audio_sync_threshold": {"section": "Gameplay", "key": "audio_sync_threshold", "value_type": "int"},
	"audio_playback_delay": {"section": "Gameplay", "key": "audio_playback_delay", "value_type": "int"},
	"audio_playback_delay_bt": {"section": "Gameplay", "key": "audio_playback_delay_bt", "value_type": "int"},
	"bt_auto_disable_performing_mode": {"section": "Gameplay", "key": "bt_auto_disable_performing_mode", "value_type": "int"},

	"lane_count": {"section": "Lane", "key": "lane_count", "value_type": "int"},
	"keyboard_mode": {"section": "Lane", "key": "keyboard_mode", "value_type": "int"},
	"keyboard_mode_keys": {"section": "Lane", "key": "keyboard_mode_keys", "value_type": "string"},
	"keyboard_mode_display_names": {"section": "Lane", "key": "keyboard_mode_display_names", "value_type": "string"},
	"keyboard_alt_color": {"section": "Lane", "key": "keyboard_alt_color", "value_type": "int"},
	"keyboard_alt_color_count": {"section": "Lane", "key": "keyboard_alt_color_count", "value_type": "int"},
	"keyboard_alt_colors": {"section": "Lane", "key": "keyboard_alt_colors", "value_type": "string"},
	"keyboard_mode_gap": {"section": "Lane", "key": "keyboard_mode_gap", "value_type": "int"},
	"keyboard_lane_separator": {"section": "Lane", "key": "keyboard_lane_separator", "value_type": "int"},
	"flash_alpha": {"section": "Lane", "key": "flash_alpha", "value_type": "float"},
	"perfect_spark_preset": {"section": "Lane", "key": "perfect_spark_preset", "value_type": "string"},
	"perfect_spark_emitter": {"section": "Lane", "key": "perfect_spark_emitter", "value_type": "string"},
	"perfect_spark_scaling": {"section": "Lane", "key": "perfect_spark_scaling", "value_type": "int"},
	"perfect_spark_alpha": {"section": "Lane", "key": "perfect_spark_alpha", "value_type": "int"},
	"perfect_spark_emitter_scaling": {"section": "Lane", "key": "perfect_spark_emitter_scaling", "value_type": "int"},
	"great_spark_preset": {"section": "Lane", "key": "great_spark_preset", "value_type": "string"},
	"great_spark_emitter": {"section": "Lane", "key": "great_spark_emitter", "value_type": "string"},
	"great_spark_scaling": {"section": "Lane", "key": "great_spark_scaling", "value_type": "int"},
	"great_spark_alpha": {"section": "Lane", "key": "great_spark_alpha", "value_type": "int"},
	"great_spark_emitter_scaling": {"section": "Lane", "key": "great_spark_emitter_scaling", "value_type": "int"},
	"good_spark_preset": {"section": "Lane", "key": "good_spark_preset", "value_type": "string"},
	"good_spark_emitter": {"section": "Lane", "key": "good_spark_emitter", "value_type": "string"},
	"good_spark_scaling": {"section": "Lane", "key": "good_spark_scaling", "value_type": "int"},
	"good_spark_alpha": {"section": "Lane", "key": "good_spark_alpha", "value_type": "int"},
	"good_spark_emitter_scaling": {"section": "Lane", "key": "good_spark_emitter_scaling", "value_type": "int"},
	"bad_spark_preset": {"section": "Lane", "key": "bad_spark_preset", "value_type": "string"},
	"bad_spark_emitter": {"section": "Lane", "key": "bad_spark_emitter", "value_type": "string"},
	"bad_spark_scaling": {"section": "Lane", "key": "bad_spark_scaling", "value_type": "int"},
	"bad_spark_alpha": {"section": "Lane", "key": "bad_spark_alpha", "value_type": "int"},
	"bad_spark_emitter_scaling": {"section": "Lane", "key": "bad_spark_emitter_scaling", "value_type": "int"},
	
	# ========== 判定设置 ==========
	"judge_window_ms": {"section": "Judge", "key": "judge_window_ms", "value_type": "int"},
	"check_instant_blocks_when_finger_up": {"section": "Judge", "key": "check_instant_blocks_when_finger_up", "value_type": "int"},
	"only_perfect_instant_blocks_before_judge": {"section": "Judge", "key": "only_perfect_instant_blocks_before_judge", "value_type": "int"},
	"judge_line_position": {"section": "Judge", "key": "judge_line_position", "value_type": "int"},
	"block_judging_width": {"section": "Judge", "key": "block_judging_width", "value_type": "float"},
	"min_block_spacing": {"section": "Judge", "key": "min_block_spacing", "value_type": "int"},
	"canvas_horizontal_padding": {"section": "Judge", "key": "canvas_horizontal_padding", "value_type": "int"},
	"perfect_time": {"section": "Judge", "key": "perfect_time", "value_type": "float"},
	"great_time": {"section": "Judge", "key": "great_time", "value_type": "float"},
	"good_time": {"section": "Judge", "key": "good_time", "value_type": "float"},
	"bad_time": {"section": "Judge", "key": "bad_time", "value_type": "float"},
	
	# ========== 生成设置 ==========
	"instant_block_max_time": {"section": "Generator", "key": "instant_block_max_time", "value_type": "float"},
	"short_block_max_time": {"section": "Generator", "key": "short_block_max_time", "value_type": "float"},
	"max_simultaneous_blocks": {"section": "Generator", "key": "max_simultaneous_blocks", "value_type": "int"},
	"min_tap_interval": {"section": "Generator", "key": "min_tap_interval", "value_type": "float"},
	"min_touch_cooldown_time": {"section": "Generator", "key": "min_touch_cooldown_time", "value_type": "float"},
	"max_touch_move_speed": {"section": "Generator", "key": "max_touch_move_speed", "value_type": "int"},
	"max_block_coalesce_time": {"section": "Generator", "key": "max_block_coalesce_time", "value_type": "int"},
	"note_fall_time": {"section": "Generator", "key": "note_fall_time", "value_type": "float"},
	
	# ========== 外观设置 ==========
	
		# ========== 音符下落方式 ==========
		"note_fall_mode": {"section": "Generator", "key": "note_fall_mode", "value_type": "int"},
		"note_fall_speed_after_judge_multiplier": {"section": "Generator", "key": "note_fall_speed_after_judge_multiplier", "value_type": "float"},
		"note_fall_easing_before_func": {"section": "Generator", "key": "note_fall_easing_before_func", "value_type": "string"},
		"note_fall_easing_before_phase": {"section": "Generator", "key": "note_fall_easing_before_phase", "value_type": "string"},
		"note_fall_easing_after_func": {"section": "Generator", "key": "note_fall_easing_after_func", "value_type": "string"},
		"note_fall_easing_after_phase": {"section": "Generator", "key": "note_fall_easing_after_phase", "value_type": "string"},
	"custom_block_skin_texture_filter_mode": {"section": "Appearance", "key": "custom_block_skin_texture_filter_mode", "value_type": "int"},
	"block_skin_preset": {"section": "Appearance", "key": "block_skin_preset", "value_type": "string"},
	"block_size": {"section": "Appearance", "key": "block_size", "value_type": "float"},
	"note_glow_intensity": {"section": "Appearance", "key": "note_glow_intensity", "value_type": "float"},
	"note_glow_size": {"section": "Appearance", "key": "note_glow_size", "value_type": "float"},
	"randomize_block_color": {"section": "Appearance", "key": "randomize_block_color", "value_type": "int"},
	"sync_color_across_block_type": {"section": "Appearance", "key": "sync_color_across_block_type", "value_type": "int"},
	"short_block_color": {"section": "Appearance", "key": "short_block_color", "value_type": "color"},
	"instant_block_color": {"section": "Appearance", "key": "instant_block_color", "value_type": "color"},
	"long_block_color": {"section": "Appearance", "key": "long_block_color", "value_type": "color"},
	"background_image_flash_color": {"section": "Appearance", "key": "background_image_flash_color", "value_type": "color"},
	"background_dim_color": {"section": "Appearance", "key": "background_dim_color", "value_type": "color"},
		"beam_width_mode": {"section": "Appearance", "key": "beam_width_mode", "value_type": "int"},
	"judge_line_thickness": {"section": "Appearance", "key": "judge_line_thickness", "value_type": "int"},
	"generate_short_connect": {"section": "Appearance", "key": "generate_short_connect", "value_type": "int"},
	"generate_instant_connect": {"section": "Appearance", "key": "generate_instant_connect", "value_type": "int"},
	"instant_connect_max_time": {"section": "Appearance", "key": "instant_connect_max_time", "value_type": "float"},
}

## 将 INI 配置转换为 SettingList 格式的字典
## @param config INI格式的配置字典 {section: {key: value}}
## @return SettingList格式的配置字典 {setting_id: value}
static func ini_to_settings(config: Dictionary) -> Dictionary:
	var result = {}
	
	for setting_id in mappings.keys():
		var mapping = mappings[setting_id]
		var section = mapping["section"]
		var key = mapping["key"]
		var value_type = mapping["value_type"]
		
		# 从 config 中读取值
		var value = null
		if config.has(section) and config[section].has(key):
			value = config[section][key]
		
		# 类型转换
		if value != null:
			match value_type:
				"int":
					result[setting_id] = str(int(value))
				"float":
					result[setting_id] = str(float(value))
				"bool":
					var bool_val = false
					if value is String:
						bool_val = value.to_lower() in ["true", "1", "yes"]
					else:
						bool_val = bool(value)
					result[setting_id] = "1" if bool_val else "0"
				"color":
					if value is String:
						result[setting_id] = value
					elif value is Color:
						result[setting_id] = value.to_html()
				"string":
					result[setting_id] = str(value)
	
	# 特殊处理：Browse 设置从字符串值转换为选项索引（顺序: creation_time=0, download_time=1）
	if result.has("album_sort_method"):
		if result["album_sort_method"] == "download_time":
			result["album_sort_method"] = "1"
		else:
			result["album_sort_method"] = "0"
	
	if result.has("album_sort_direction"):
		result["album_sort_direction"] = "0" if result["album_sort_direction"] == "asc" else "1"

	return result

## 将 SettingList 格式的字典转换为 INI 配置
## @param settings SettingList格式的配置字典 {setting_id: value}
## @return INI格式的配置字典 {section: {key: value}}
static func settings_to_ini(settings: Dictionary) -> Dictionary:
	var result = {}
	
	for setting_id in settings.keys():
		if not mappings.has(setting_id):
			if setting_id in ["theme_preset"]:
				continue
			push_warning("[SettingsMapper] Unknown setting_id: %s" % setting_id)
			continue
		
		var mapping = mappings[setting_id]
		var section = mapping["section"]
		var key = mapping["key"]
		var value_type = mapping["value_type"]
		var value = settings[setting_id]
		
		# 确保section存在
		if not result.has(section):
			result[section] = {}
		
		# 类型转换
		match value_type:
			"int":
				result[section][key] = int(value)
			"float":
				result[section][key] = float(value)
			"bool":
				var bool_val = false
				if value is String:
					bool_val = value in ["1", "true", "True", "yes", "Yes"]
				else:
					bool_val = bool(value)
				result[section][key] = bool_val
			"color":
				if value is String:
					result[section][key] = value
				elif value is Color:
					result[section][key] = value.to_html()
			"string":
				result[section][key] = str(value)
	
	# 特殊处理：Browse 设置从选项索引转换为字符串值
	if result.has("Browse") and result["Browse"] is Dictionary:
		var browse: Dictionary = result["Browse"]
		if browse.has("album_sort_method"):
			var idx = int(browse["album_sort_method"])
			browse["album_sort_method"] = ["creation_time", "download_time"][clamp(idx, 0, 1)]
		if browse.has("album_sort_direction"):
			var idx = int(browse["album_sort_direction"])
			browse["album_sort_direction"] = "asc" if idx == 0 else "desc"
	
	return result

## 验证配置值的有效性
## @param setting_id 配置项ID
## @param value 配置值
## @return 是否有效
static func validate_value(setting_id: String, value: Variant) -> bool:
	# 基本验证规则
	match setting_id:
		"lane_count":
			return int(value) > 0 and int(value) <= 24
		"audio_sync_threshold":
			return int(value) >= 1 and int(value) <= 100000
		"playback_speed_scaling":
			return float(value) > 0.0 and float(value) <= 3.0
		"flash_alpha":
			return float(value) >= 0.0 and float(value) <= 1.0
		"vibration_duration":
			return int(value) >= 0
		"judge_line_position":
			return int(value) >= 0
		"judge_line_thickness":
			return int(value) >= 1 and int(value) <= 32
		"block_judging_width":
			return float(value) > 0.0
		"perfect_time", "great_time", "good_time", "bad_time":
			return float(value) > 0.0
	
	# 默认通过验证
	return true

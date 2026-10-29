## 设置映射器
## 负责 SettingList 的配置ID与 config.ini 的 section/key 之间的双向映射
##
## 默认值不在这里 —— config.ini 是默认值的唯一来源，本表只声明「存到哪」和「什么类型」。
## section 与 config.ini 的 section 一一对应，分组顺序也一致，方便两边对拍。
class_name SettingsMapper

## 配置映射表：setting_id → {section, key, value_type}
## value_type: "int", "float", "bool", "string", "color"
static var mappings: Dictionary = {
	# ========== 常规设置（General）==========
	"show_advanced_settings": {"section": "General", "key": "show_advanced_settings", "value_type": "int"},
	"display_debug_info": {"section": "General", "key": "display_debug_info", "value_type": "int"},
	"language": {"section": "General", "key": "language", "value_type": "int"},
	"album_sort_method": {"section": "General", "key": "album_sort_method", "value_type": "string"},
	"album_sort_direction": {"section": "General", "key": "album_sort_direction", "value_type": "string"},
	"online_mode": {"section": "General", "key": "online_mode", "value_type": "int"},
	"auto_upload_score": {"section": "General", "key": "auto_upload_score", "value_type": "int"},
	"download_vocal": {"section": "General", "key": "download_vocal", "value_type": "int"},
	"server_address": {"section": "General", "key": "server_address", "value_type": "string"},
	"storage_location": {"section": "General", "key": "custom_storage_path", "value_type": "string"},

	# ========== 音频设置（Audio）==========
	"soundfont_select": {"section": "Audio", "key": "soundfont_file", "value_type": "string"},
	"playback_speed_scaling": {"section": "Audio", "key": "playback_speed_scaling", "value_type": "float"},
	"max_polyphony": {"section": "Audio", "key": "max_polyphony", "value_type": "int"},
	"default_midi_volume": {"section": "Audio", "key": "default_midi_volume", "value_type": "int"},
	"default_vocal_volume": {"section": "Audio", "key": "default_vocal_volume", "value_type": "int"},
	"audio_playback_delay": {"section": "Audio", "key": "audio_playback_delay", "value_type": "int"},
	"audio_sync_threshold": {"section": "Audio", "key": "audio_sync_threshold", "value_type": "int"},
	"audio_playback_delay_bt": {"section": "Audio", "key": "audio_playback_delay_bt", "value_type": "int"},
	"bt_auto_disable_performing_mode": {"section": "Audio", "key": "bt_auto_disable_performing_mode", "value_type": "int"},

	# ========== 生成设置（Gameplay）==========
	"lane_count": {"section": "Gameplay", "key": "lane_count", "value_type": "int"},
	"min_block_spacing": {"section": "Gameplay", "key": "min_block_spacing", "value_type": "int"},
	"perfect_time": {"section": "Gameplay", "key": "perfect_time", "value_type": "float"},
	"great_time": {"section": "Gameplay", "key": "great_time", "value_type": "float"},
	"good_time": {"section": "Gameplay", "key": "good_time", "value_type": "float"},
	"bad_time": {"section": "Gameplay", "key": "bad_time", "value_type": "float"},
	"instant_block_max_time": {"section": "Gameplay", "key": "instant_block_max_time", "value_type": "float"},
	"short_block_max_time": {"section": "Gameplay", "key": "short_block_max_time", "value_type": "float"},
	"long_block_max_time": {"section": "Gameplay", "key": "long_block_max_time", "value_type": "float"},
	"long_block_length_scaling": {"section": "Gameplay", "key": "long_block_length_scaling", "value_type": "float"},
	"max_simultaneous_blocks": {"section": "Gameplay", "key": "max_simultaneous_blocks", "value_type": "int"},
	"min_tap_interval": {"section": "Gameplay", "key": "min_tap_interval", "value_type": "float"},
	"min_touch_cooldown_time": {"section": "Gameplay", "key": "min_touch_cooldown_time", "value_type": "float"},
	"max_touch_move_speed": {"section": "Gameplay", "key": "max_touch_move_speed", "value_type": "int"},
	"max_block_coalesce_time": {"section": "Gameplay", "key": "max_block_coalesce_time", "value_type": "int"},
	"generate_short_connect": {"section": "Gameplay", "key": "generate_short_connect", "value_type": "int"},
	"generate_instant_connect": {"section": "Gameplay", "key": "generate_instant_connect", "value_type": "int"},
	"instant_connect_max_time": {"section": "Gameplay", "key": "instant_connect_max_time", "value_type": "float"},

	# ========== 演奏设置（Performance）==========
	"performing_mode": {"section": "Performance", "key": "performing_mode", "value_type": "int"},
	"play_ready_animation": {"section": "Performance", "key": "play_ready_animation", "value_type": "int"},
	"keyboard_mode_keys": {"section": "Performance", "key": "keyboard_mode_keys", "value_type": "string"},
	"use_system_stopwatch": {"section": "Performance", "key": "use_system_stopwatch", "value_type": "int"},
	"note_fall_time": {"section": "Performance", "key": "note_fall_time", "value_type": "float"},
	"note_fall_mode": {"section": "Performance", "key": "note_fall_mode", "value_type": "int"},
	"note_fall_speed_after_judge_multiplier": {"section": "Performance", "key": "note_fall_speed_after_judge_multiplier", "value_type": "float"},
	"note_fall_easing_before_func": {"section": "Performance", "key": "note_fall_easing_before_func", "value_type": "string"},
	"note_fall_easing_before_phase": {"section": "Performance", "key": "note_fall_easing_before_phase", "value_type": "string"},
	"note_fall_easing_after_func": {"section": "Performance", "key": "note_fall_easing_after_func", "value_type": "string"},
	"note_fall_easing_after_phase": {"section": "Performance", "key": "note_fall_easing_after_phase", "value_type": "string"},
	"block_size": {"section": "Performance", "key": "block_size", "value_type": "float"},
	"block_judging_width": {"section": "Performance", "key": "block_judging_width", "value_type": "float"},
	"judge_window_ms": {"section": "Performance", "key": "judge_window_ms", "value_type": "int"},
	"check_instant_blocks_when_finger_up": {"section": "Performance", "key": "check_instant_blocks_when_finger_up", "value_type": "int"},
	"only_perfect_instant_blocks_before_judge": {"section": "Performance", "key": "only_perfect_instant_blocks_before_judge", "value_type": "int"},
	"canvas_horizontal_padding": {"section": "Performance", "key": "canvas_horizontal_padding", "value_type": "int"},
	"judge_line_position": {"section": "Performance", "key": "judge_line_position", "value_type": "int"},
	"judge_line_thickness": {"section": "Performance", "key": "judge_line_thickness", "value_type": "int"},
	"vibrate_on_touch": {"section": "Performance", "key": "vibrate_on_touch", "value_type": "int"},
	"vibration_duration": {"section": "Performance", "key": "vibration_duration", "value_type": "int"},
	"keyboard_mode": {"section": "Performance", "key": "keyboard_mode", "value_type": "int"},
	"keyboard_mode_display_names": {"section": "Performance", "key": "keyboard_mode_display_names", "value_type": "string"},
	"keyboard_alt_color": {"section": "Performance", "key": "keyboard_alt_color", "value_type": "int"},
	"keyboard_alt_color_count": {"section": "Performance", "key": "keyboard_alt_color_count", "value_type": "int"},
	"keyboard_alt_colors": {"section": "Performance", "key": "keyboard_alt_colors", "value_type": "string"},
	"keyboard_mode_gap": {"section": "Performance", "key": "keyboard_mode_gap", "value_type": "int"},
	"keyboard_lane_separator": {"section": "Performance", "key": "keyboard_lane_separator", "value_type": "int"},

	# ========== 外观设置（Appearance）==========
	"block_skin_preset": {"section": "Appearance", "key": "block_skin_preset", "value_type": "string"},
	"note_draw_order": {"section": "Appearance", "key": "note_draw_order", "value_type": "int"},
	"custom_block_skin_texture_filter_mode": {"section": "Appearance", "key": "custom_block_skin_texture_filter_mode", "value_type": "int"},
	"randomize_block_color": {"section": "Appearance", "key": "randomize_block_color", "value_type": "int"},
	"sync_color_across_block_type": {"section": "Appearance", "key": "sync_color_across_block_type", "value_type": "int"},
	"instant_block_color": {"section": "Appearance", "key": "instant_block_color", "value_type": "color"},
	"short_block_color": {"section": "Appearance", "key": "short_block_color", "value_type": "color"},
	"long_block_color": {"section": "Appearance", "key": "long_block_color", "value_type": "color"},
	"note_glow_intensity": {"section": "Appearance", "key": "note_glow_intensity", "value_type": "float"},
	"note_glow_size": {"section": "Appearance", "key": "note_glow_size", "value_type": "float"},
	"perfect_spark_preset": {"section": "Appearance", "key": "perfect_spark_preset", "value_type": "string"},
	"perfect_spark_emitter": {"section": "Appearance", "key": "perfect_spark_emitter", "value_type": "string"},
	"perfect_spark_scaling": {"section": "Appearance", "key": "perfect_spark_scaling", "value_type": "int"},
	"perfect_spark_alpha": {"section": "Appearance", "key": "perfect_spark_alpha", "value_type": "int"},
	"perfect_spark_emitter_scaling": {"section": "Appearance", "key": "perfect_spark_emitter_scaling", "value_type": "int"},
	"great_spark_preset": {"section": "Appearance", "key": "great_spark_preset", "value_type": "string"},
	"great_spark_emitter": {"section": "Appearance", "key": "great_spark_emitter", "value_type": "string"},
	"great_spark_scaling": {"section": "Appearance", "key": "great_spark_scaling", "value_type": "int"},
	"great_spark_alpha": {"section": "Appearance", "key": "great_spark_alpha", "value_type": "int"},
	"great_spark_emitter_scaling": {"section": "Appearance", "key": "great_spark_emitter_scaling", "value_type": "int"},
	"good_spark_preset": {"section": "Appearance", "key": "good_spark_preset", "value_type": "string"},
	"good_spark_emitter": {"section": "Appearance", "key": "good_spark_emitter", "value_type": "string"},
	"good_spark_scaling": {"section": "Appearance", "key": "good_spark_scaling", "value_type": "int"},
	"good_spark_alpha": {"section": "Appearance", "key": "good_spark_alpha", "value_type": "int"},
	"good_spark_emitter_scaling": {"section": "Appearance", "key": "good_spark_emitter_scaling", "value_type": "int"},
	"bad_spark_preset": {"section": "Appearance", "key": "bad_spark_preset", "value_type": "string"},
	"bad_spark_emitter": {"section": "Appearance", "key": "bad_spark_emitter", "value_type": "string"},
	"bad_spark_scaling": {"section": "Appearance", "key": "bad_spark_scaling", "value_type": "int"},
	"bad_spark_alpha": {"section": "Appearance", "key": "bad_spark_alpha", "value_type": "int"},
	"bad_spark_emitter_scaling": {"section": "Appearance", "key": "bad_spark_emitter_scaling", "value_type": "int"},
	"flash_alpha": {"section": "Appearance", "key": "flash_alpha", "value_type": "float"},
	"beam_width_mode": {"section": "Appearance", "key": "beam_width_mode", "value_type": "int"},
	"background_image_flash_color": {"section": "Appearance", "key": "background_image_flash_color", "value_type": "color"},
	"background_dim_color": {"section": "Appearance", "key": "background_dim_color", "value_type": "color"}
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
	
	# 特殊处理：专辑排序两项在 UI 里是选项索引，写盘要换成字符串。
	# section 不写死（它们现在在 General），统一从映射表取，避免以后搬组时再次失效。
	var sort_sec: String = mappings["album_sort_method"].section
	if result.has(sort_sec) and result[sort_sec] is Dictionary:
		var sort_sec_data: Dictionary = result[sort_sec]
		if sort_sec_data.has("album_sort_method"):
			var idx := int(sort_sec_data["album_sort_method"])
			sort_sec_data["album_sort_method"] = ["creation_time", "download_time"][clamp(idx, 0, 1)]
		if sort_sec_data.has("album_sort_direction"):
			var dir_idx := int(sort_sec_data["album_sort_direction"])
			sort_sec_data["album_sort_direction"] = "asc" if dir_idx == 0 else "desc"
	
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
		"long_block_max_time":
			return float(value) >= 0.0
		"long_block_length_scaling":
			# 取值范围 [10, 100]（小于等于 100%）：100 = 不缩放（允许），下限 10 防退化
			return float(value) >= 10.0 and float(value) <= 100.0
	
	# 默认通过验证
	return true

## 设置映射器
## 负责 SettingList 的配置 ID 与 config.ini 的**键名/类型**之间的对应
##
## 默认值不在这里 —— config.ini 是默认值的唯一来源，本表只声明「存到哪个键」和「什么类型」。
## 也不声明 section —— 配置键在整份 ini 里全局唯一（ConfigManager.validate_defaults 自检），
## 读写只按 key 走，section 由 config.ini 自己排版。所以设置页怎么分组、
## ini 里的 section 怎么重排，都跟这张表和业务代码无关。
class_name SettingsMapper

## 配置映射表：setting_id → {section, key, value_type}
## value_type: "int", "float", "bool", "string", "color"
static var mappings: Dictionary = {
	# ========== 常规设置（General）==========
	"show_advanced_settings": {"key": "show_advanced_settings", "value_type": "int"},
	"display_debug_info": {"key": "display_debug_info", "value_type": "int"},
	"language": {"key": "language", "value_type": "int"},
	"album_sort_method": {"key": "album_sort_method", "value_type": "string"},
	"album_sort_direction": {"key": "album_sort_direction", "value_type": "string"},
	"online_mode": {"key": "online_mode", "value_type": "int"},
	"auto_upload_score": {"key": "auto_upload_score", "value_type": "int"},
	"download_vocal": {"key": "download_vocal", "value_type": "int"},
	"server_address": {"key": "server_address", "value_type": "string"},
	"storage_location": {"key": "custom_storage_path", "value_type": "string"},

	# ========== 音频设置（Audio）==========
	"soundfont_select": {"key": "soundfont_file", "value_type": "string"},
	"playback_speed_scaling": {"key": "playback_speed_scaling", "value_type": "float"},
	"max_polyphony": {"key": "max_polyphony", "value_type": "int"},
	"default_midi_volume": {"key": "default_midi_volume", "value_type": "int"},
	"default_vocal_volume": {"key": "default_vocal_volume", "value_type": "int"},
	"audio_playback_delay": {"key": "audio_playback_delay", "value_type": "int"},
	"audio_sync_threshold": {"key": "audio_sync_threshold", "value_type": "int"},
	"audio_playback_delay_bt": {"key": "audio_playback_delay_bt", "value_type": "int"},
	"bt_auto_disable_performing_mode": {"key": "bt_auto_disable_performing_mode", "value_type": "int"},

	# ========== 生成设置（Gameplay）==========
	"lane_count": {"key": "lane_count", "value_type": "int"},
	"min_block_spacing": {"key": "min_block_spacing", "value_type": "int"},
	"perfect_time": {"key": "perfect_time", "value_type": "float"},
	"great_time": {"key": "great_time", "value_type": "float"},
	"good_time": {"key": "good_time", "value_type": "float"},
	"bad_time": {"key": "bad_time", "value_type": "float"},
	"instant_block_max_time": {"key": "instant_block_max_time", "value_type": "float"},
	"short_block_max_time": {"key": "short_block_max_time", "value_type": "float"},
	"long_block_max_time": {"key": "long_block_max_time", "value_type": "float"},
	"long_block_length_scaling": {"key": "long_block_length_scaling", "value_type": "float"},
	"max_simultaneous_blocks": {"key": "max_simultaneous_blocks", "value_type": "int"},
	"min_tap_interval": {"key": "min_tap_interval", "value_type": "float"},
	"min_touch_cooldown_time": {"key": "min_touch_cooldown_time", "value_type": "float"},
	"max_touch_move_speed": {"key": "max_touch_move_speed", "value_type": "int"},
	"max_block_coalesce_time": {"key": "max_block_coalesce_time", "value_type": "int"},
	"generate_short_connect": {"key": "generate_short_connect", "value_type": "int"},
	"generate_instant_connect": {"key": "generate_instant_connect", "value_type": "int"},
	"instant_connect_max_time": {"key": "instant_connect_max_time", "value_type": "float"},

	# ========== 演奏设置（Performance）==========
	"performing_mode": {"key": "performing_mode", "value_type": "int"},
	"play_ready_animation": {"key": "play_ready_animation", "value_type": "int"},
	"keyboard_mode_keys": {"key": "keyboard_mode_keys", "value_type": "string"},
	"use_system_stopwatch": {"key": "use_system_stopwatch", "value_type": "int"},
	"note_fall_time": {"key": "note_fall_time", "value_type": "float"},
	"note_fall_mode": {"key": "note_fall_mode", "value_type": "int"},
	"note_fall_speed_after_judge_multiplier": {"key": "note_fall_speed_after_judge_multiplier", "value_type": "float"},
	"note_fall_easing_before_func": {"key": "note_fall_easing_before_func", "value_type": "string"},
	"note_fall_easing_before_phase": {"key": "note_fall_easing_before_phase", "value_type": "string"},
	"note_fall_easing_after_func": {"key": "note_fall_easing_after_func", "value_type": "string"},
	"note_fall_easing_after_phase": {"key": "note_fall_easing_after_phase", "value_type": "string"},
	"block_size": {"key": "block_size", "value_type": "float"},
	"block_judging_width": {"key": "block_judging_width", "value_type": "float"},
	"judge_window_ms": {"key": "judge_window_ms", "value_type": "int"},
	"check_instant_blocks_when_finger_up": {"key": "check_instant_blocks_when_finger_up", "value_type": "int"},
	"only_perfect_instant_blocks_before_judge": {"key": "only_perfect_instant_blocks_before_judge", "value_type": "int"},
	"canvas_horizontal_padding": {"key": "canvas_horizontal_padding", "value_type": "int"},
	"judge_line_position": {"key": "judge_line_position", "value_type": "int"},
	"judge_line_thickness": {"key": "judge_line_thickness", "value_type": "int"},
	"vibrate_on_touch": {"key": "vibrate_on_touch", "value_type": "int"},
	"vibration_duration": {"key": "vibration_duration", "value_type": "int"},
	"keyboard_mode": {"key": "keyboard_mode", "value_type": "int"},
	"keyboard_mode_display_names": {"key": "keyboard_mode_display_names", "value_type": "string"},
	"keyboard_alt_color": {"key": "keyboard_alt_color", "value_type": "int"},
	"keyboard_alt_color_count": {"key": "keyboard_alt_color_count", "value_type": "int"},
	"keyboard_alt_colors": {"key": "keyboard_alt_colors", "value_type": "string"},
	"keyboard_mode_gap": {"key": "keyboard_mode_gap", "value_type": "int"},
	"keyboard_lane_separator": {"key": "keyboard_lane_separator", "value_type": "int"},

	# ========== 外观设置（Appearance）==========
	"block_skin_preset": {"key": "block_skin_preset", "value_type": "string"},
	"note_draw_order": {"key": "note_draw_order", "value_type": "int"},
	"custom_block_skin_texture_filter_mode": {"key": "custom_block_skin_texture_filter_mode", "value_type": "int"},
	"randomize_block_color": {"key": "randomize_block_color", "value_type": "int"},
	"sync_color_across_block_type": {"key": "sync_color_across_block_type", "value_type": "int"},
	"instant_block_color": {"key": "instant_block_color", "value_type": "color"},
	"short_block_color": {"key": "short_block_color", "value_type": "color"},
	"long_block_color": {"key": "long_block_color", "value_type": "color"},
	"note_glow_intensity": {"key": "note_glow_intensity", "value_type": "float"},
	"note_glow_size": {"key": "note_glow_size", "value_type": "float"},
	"perfect_spark_preset": {"key": "perfect_spark_preset", "value_type": "string"},
	"perfect_spark_emitter": {"key": "perfect_spark_emitter", "value_type": "string"},
	"perfect_spark_scaling": {"key": "perfect_spark_scaling", "value_type": "int"},
	"perfect_spark_alpha": {"key": "perfect_spark_alpha", "value_type": "int"},
	"perfect_spark_emitter_scaling": {"key": "perfect_spark_emitter_scaling", "value_type": "int"},
	"great_spark_preset": {"key": "great_spark_preset", "value_type": "string"},
	"great_spark_emitter": {"key": "great_spark_emitter", "value_type": "string"},
	"great_spark_scaling": {"key": "great_spark_scaling", "value_type": "int"},
	"great_spark_alpha": {"key": "great_spark_alpha", "value_type": "int"},
	"great_spark_emitter_scaling": {"key": "great_spark_emitter_scaling", "value_type": "int"},
	"good_spark_preset": {"key": "good_spark_preset", "value_type": "string"},
	"good_spark_emitter": {"key": "good_spark_emitter", "value_type": "string"},
	"good_spark_scaling": {"key": "good_spark_scaling", "value_type": "int"},
	"good_spark_alpha": {"key": "good_spark_alpha", "value_type": "int"},
	"good_spark_emitter_scaling": {"key": "good_spark_emitter_scaling", "value_type": "int"},
	"bad_spark_preset": {"key": "bad_spark_preset", "value_type": "string"},
	"bad_spark_emitter": {"key": "bad_spark_emitter", "value_type": "string"},
	"bad_spark_scaling": {"key": "bad_spark_scaling", "value_type": "int"},
	"bad_spark_alpha": {"key": "bad_spark_alpha", "value_type": "int"},
	"bad_spark_emitter_scaling": {"key": "bad_spark_emitter_scaling", "value_type": "int"},
	"flash_alpha": {"key": "flash_alpha", "value_type": "float"},
	"beam_width_mode": {"key": "beam_width_mode", "value_type": "int"},
	"background_image_flash_color": {"key": "background_image_flash_color", "value_type": "color"},
	"background_dim_color": {"key": "background_dim_color", "value_type": "color"}
}

## 将 INI 配置转换为 SettingList 格式的字典
## 取值只看 key，不看 section：ini 里的分组是纯排版，怎么重排都不影响本函数。
## @param config INI格式的配置字典 {section: {key: value}}
## @return SettingList格式的配置字典 {setting_id: value}
static func ini_to_settings(config: Dictionary) -> Dictionary:
	var result = {}
	
	# 摊平成 {key: value}。key 全局唯一，跨 section 不会撞车。
	var flat := {}
	for section in config.keys():
		var sec_data = config[section]
		if not (sec_data is Dictionary):
			continue
		for k in sec_data.keys():
			if not flat.has(k):
				flat[k] = sec_data[k]
	
	for setting_id in mappings.keys():
		var mapping = mappings[setting_id]
		var key = mapping["key"]
		var value_type = mapping["value_type"]
		
		if not flat.has(key):
			continue
		var value = flat[key]
		
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

class_name MidiConfigPersistence
extends Node

## MIDI 配置持久化控制器：从 TrackView 提取的保存/恢复配置逻辑

var _track_view: TrackView = null


func setup(track_view: TrackView) -> void:
	_track_view = track_view


## 是否有「用户显式改动」尚未落盘。
##
## 只有编辑回调（音量/静音/独奏/启用/乐器/人声…）会置位；单纯进出页面不置位。
## 因此退出本页时不会把"其实没改过"的整份配置再写一遍，符合"改了才保存"的语义。
var _dirty: bool = false

## 保存当前MIDI配置到 chart_runtime（权威 DB，替代 JSON 写回）
##
## 只在有显式改动时真正写库：LiteDB 写是同步的，退场那帧写盘会顶掉出场动画的首帧
## （表现为"出场动画基本没有"）。只是看了看、按了返回的退出不该产生任何写入。
func save_midi_config() -> void:
	if not _dirty:
		GLogger.debug("[TrackView] MIDI config not edited, skip DB write", "TrackView")
		return
	var current_midi_data = _track_view.current_midi_data
	if current_midi_data == null:
		push_warning("[TrackView] No MIDI data to save")
		return

	# 更新人声文件路径
	current_midi_data.vocal_file_path = _track_view._vocal_controller.vocal_file_path

	# 更新独奏状态
	current_midi_data.solo_pairs = _track_view.solo_pairs.duplicate()

	# 更新音轨启用状态（从所有轨道UI控件收集）
	# selected_track_configs 由各个 MidiTrack 项通过 _on_track_enable_toggled 更新
	# 这里只需确保 current_midi_data.selected_track_configs 已是最新状态
	# 导出运行时配置
	var runtime_config = current_midi_data.export_runtime_config()

	# 保存到 chart_runtime（权威 DB）。经 MidiCore.UpdateConfig 走配置权威入口，
	# 与播放侧/后台换曲读的是同一份数据。
	var chart_id = current_midi_data.file_hash if not current_midi_data.file_hash.is_empty() else current_midi_data.id

	# 脏检查：与上次真正落盘的内容一致就什么都不做
	var sig := _config_signature(runtime_config)
	if chart_id == _last_saved_chart_id and sig == _last_saved_sig:
		_dirty = false
		GLogger.debug("[TrackView] MIDI config unchanged, skip DB write", "TrackView")
		return

	var t0 := Time.get_ticks_usec()
	if MidiCore != null and MidiCore.UpdateConfig(chart_id, runtime_config):
		_dirty = false
		_last_saved_chart_id = chart_id
		_last_saved_sig = sig
		# 音量按百分比打印（-1% 表示"未配置/跟随全局默认"），避免 %d 截断后 17%/33% 都显示 0
		GLogger.info("MIDI config saved to DB in %.1f ms (volume: %.0f%%/%.0f%%, solo: %d, track_enabled: %s, vocal: %s)" %
			[(Time.get_ticks_usec() - t0) / 1000.0, current_midi_data.midi_volume * 100.0, current_midi_data.vocal_volume * 100.0,
			_track_view.solo_pairs.size(), current_midi_data.selected_track_configs, _track_view._vocal_controller.vocal_file_path], "TrackView")
	else:
		push_error("[TrackView] MidiCore.UpdateConfig failed for: %s" % current_midi_data.id)


## 上次真正写入 DB 的曲子与内容签名
var _last_saved_chart_id: String = ""
var _last_saved_sig: String = ""

## 落盘延迟（秒）：页内编辑的去抖窗口。拖动音量滑块时每个 value_changed 都重新计时，
## 松手（或停止编辑）0.6s 后才真正写一次库，避免拖动过程中反复写。
## 本页退出/切后台/退出应用不走这个窗口，见 flush_save()。
const SAVE_DELAY_SEC := 0.6
const SAVE_TWEEN_ID := "track_cfg_save"

## 去抖落盘：编辑过程中使用
func schedule_save_midi_config() -> void:
	_dirty = true
	if AniMGR != null:
		AniMGR.delay_call(save_midi_config, SAVE_DELAY_SEC, SAVE_TWEEN_ID)
	else:
		save_midi_config.call_deferred()

## 立即落盘（丢弃待执行的去抖保存）。
## 离开本页/切后台/退出应用用：此刻之后配置随时会被读走（PlayView 起播、重新水合）
## 或随进程消失，不能等去抖窗口，否则用户改动看起来"永远没保存"。
## 没有任何显式改动时直接返回，不写库（退出页面不再"顺手保存整份配置"）。
func flush_save() -> void:
	if AniMGR != null:
		AniMGR.stop_tween(SAVE_TWEEN_ID)
	if not _dirty:
		return
	save_midi_config()

## 换曲/重新水合：上一首未落盘的改动不再属于当前曲，丢弃脏标记与待执行的去抖保存。
## 调用方（TrackView._load_midi）在换曲前已先 flush_save()，故不会丢用户改动。
func reset_dirty() -> void:
	if AniMGR != null:
		AniMGR.stop_tween(SAVE_TWEEN_ID)
	_dirty = false

## 把运行时配置压成与键序无关、与时间戳无关的稳定字符串，用于"内容是否变了"的比较。
## 必须排除 saved_at：它每次导出都不同，带上就永远判定为"有变化"。
func _config_signature(cfg: Dictionary) -> String:
	var keys: Array = cfg.keys()
	keys.sort()
	var parts := PackedStringArray()
	for k in keys:
		var key := str(k)
		if key == "saved_at":
			continue
		parts.append("%s=%s" % [key, _value_signature(cfg[k])])
	return "|".join(parts)

## 单个值的稳定表示：嵌套字典同样按键排序递归展开（轨道号是 int 键，先转字符串再排）
func _value_signature(v) -> String:
	if v is Dictionary:
		var keys: Array = (v as Dictionary).keys()
		keys.sort()
		var parts := PackedStringArray()
		for k in keys:
			parts.append("%s:%s" % [str(k), _value_signature((v as Dictionary)[k])])
		return "{" + ",".join(parts) + "}"
	if v is Array:
		var parts := PackedStringArray()
		for e in (v as Array):
			parts.append(_value_signature(e))
		return "[" + ",".join(parts) + "]"
	return str(v)


## 全局默认人声音量（线性 0-1）。归一化规则与 C# set_global_playback_config 一致：
## >1 视为百分数（旧存值），<=0 视为 dB。优先取设置页当前值，取不到再回落到配置单例。
func _global_default_vocal_volume() -> float:
	var raw := 50.0
	var setting_view = _track_view.get_node_or_null(PathRegistry.SETTING_VIEW)
	if setting_view and setting_view.has_method("get_setting_value"):
		var v = setting_view.get_setting_value("default_vocal_volume")
		if v != null:
			raw = float(v)
	elif ConfigManager != null and ConfigManager.instance != null:
		raw = ConfigManager.instance.get_float("Audio", "default_vocal_volume")
	var vol := raw
	if vol > 1.0:
		vol /= 100.0
	elif vol <= 0.0:
		vol = db_to_linear(vol)
	return clampf(vol, 0.0, 1.0)


## 恢复MIDI配置的数据部分（音量、进度条、独奏状态）
## 在_load_midi中早期调用，此时list_items还未创建
func restore_midi_data_config() -> void:
	var current_midi_data = _track_view.current_midi_data
	if current_midi_data == null:
		return
	# 新一轮水合：进入本页时没有任何"用户显式改动"，退出时不该无条件写库
	reset_dirty()

	var midi_vol_slider = _track_view.midi_vol_slider
	var vocal_vol_slider = _track_view.vocal_vol_slider
	var midi_playback_manager = _track_view.midi_playback_manager
	var progress_bar = _track_view.progress_bar
	var current_time = _track_view.current_time

	midi_vol_slider.set_block_signals(true)
	vocal_vol_slider.set_block_signals(true)

	# 获取音量值，未配置(-1)时回退全局 default_midi_volume（与 PlayView 统一解析，并 clamp 到滑块范围）
	var midi_vol = midi_playback_manager.get_effective_midi_volume(current_midi_data.midi_volume)
	var vocal_vol = current_midi_data.vocal_volume

	if vocal_vol < 0.0:  # 未配置：回退全局 default_vocal_volume
		vocal_vol = _global_default_vocal_volume()

	midi_vol_slider.value = midi_vol
	vocal_vol_slider.value = vocal_vol

	# 记录载入时的生效值（取滑块赋值后的值，规避滑块 step 量化差异）+ 配置原值（-1=未配置）：
	# 滑块改动时立即按这两个值判断是否要还原原值，见 TrackView._on_midi_volume_changed。
	_track_view.midi_volume_at_load = midi_vol_slider.value
	_track_view.midi_volume_cfg_at_load = current_midi_data.midi_volume
	# 人声音量同构：生效值 + 配置原值（-1=未配置）。改动回到生效值时还原原值，
	# 不把"等于全局默认"的值钉进配置，见 TrackView._on_vocal_volume_changed。
	_track_view.vocal_volume_at_load = vocal_vol_slider.value
	_track_view.vocal_volume_cfg_at_load = current_midi_data.vocal_volume

	_track_view._set_display_midi_volume(midi_vol_slider.value)
	_track_view._vocal_controller.set_display_vocal_volume(vocal_vol_slider.value)

	midi_vol_slider.set_block_signals(false)
	vocal_vol_slider.set_block_signals(false)

	# 同步静音按钮按下状态（静音 = 音量条 0）：切换 MIDI 时须重置，避免沿用上一个 MIDI 的按下态
	_track_view.midi_vol_btn.set_pressed_no_signal(midi_vol_slider.value <= 0.0)
	_track_view.vocal_vol_btn.set_pressed_no_signal(vocal_vol_slider.value <= 0.0)

	# 应用实际的播放音量，不只是更新UI
	# MIDI音量映射系数见 PlaybackTypes.MIDI_VOLUME_GAIN（0.5=+6dB, 1.0=+12dB）
	midi_playback_manager.apply_ui_midi_volume(midi_vol)

	# 人声音量1:1映射
	var vocal_volume_db = linear_to_db(vocal_vol)
	midi_playback_manager.set_vocal_volume_db(vocal_volume_db)

	# 恢复进度条位置和最大值（初始化为0）
	progress_bar.set_block_signals(true)
	progress_bar.value = 0.0
	progress_bar.max_value = current_midi_data.duration_ms
	progress_bar.set_block_signals(false)
	current_time.text = _track_view._format_time(0.0)

	# 恢复独奏状态（到内存，后续UI恢复会用到）
	_track_view.solo_pairs = current_midi_data.solo_pairs.duplicate()

	# 初始化音轨启用状态：如果是新MIDI（从未配置过），则默认全部启用
	# 这很重要，因为restore_midi_ui_config()会检查这个值来显示enable按钮状态
	if not current_midi_data.is_track_config_initialized():
		# 新MIDI：等待All_Notes加载后进行初始化（在_init_master_note_displayer中）
		# 但这里需要先设置一个占位符，否则restore_midi_ui_config会显示"禁用"
		GLogger.info("New MIDI detected (not initialized), will initialize in _init_master_note_displayer", "TrackView")
	else:
		# 旧MIDI：selected_track_configs已从JSON恢复（可能为空或有配置），将在restore_midi_ui_config中应用
		GLogger.info("Existing MIDI config restored: %d tracks have enabled channels" %
			current_midi_data.selected_track_configs.size(), "TrackView")

	GLogger.info("Restored MIDI data config: midi_volume=%d%%, vocal_volume=%d%%, solo_count=%d" %
		[int(round(midi_vol * 100.0)), int(round(vocal_vol * 100.0)), _track_view.solo_pairs.size()], "TrackView")

	# 恢复轨道级音量配置（从保存的配置）
	if not current_midi_data.track_channel_volume_config.is_empty():
		for track_index in current_midi_data.track_channel_volume_config.keys():
			var channels = current_midi_data.track_channel_volume_config[track_index]
			for channel in channels.keys():
				var volume = channels[channel]
				# 立即应用到播放器（转换track_index和channel为int）
				midi_playback_manager.set_track_channel_volume(int(track_index), int(channel), volume)
		GLogger.info("Restored track volumes: %d tracks" % current_midi_data.track_channel_volume_config.size(), "TrackView")

	# 恢复轨道-通道乐器覆盖配置（从保存的配置）
	if not current_midi_data.track_channel_instrument_overrides.is_empty():
		for track_index in current_midi_data.track_channel_instrument_overrides.keys():
			var channels = current_midi_data.track_channel_instrument_overrides[track_index]
			for channel in channels.keys():
				var instr = channels[channel]
				# 立即应用到MidiPlayer
				if midi_playback_manager.midi_player:
					midi_playback_manager.midi_player.set_track_channel_instrument(
						int(track_index),
						int(channel),
						instr.get("bank", 0),
						instr.get("program", 0)
					)
		GLogger.info("Restored instrument overrides: %d tracks" % current_midi_data.track_channel_instrument_overrides.size(), "TrackView")


## 恢复MIDI配置的UI部分（按钮状态、音量值）
## 在_create_track_views之后调用，此时list_items已有内容
func restore_midi_ui_config() -> void:
	var current_midi_data = _track_view.current_midi_data
	if current_midi_data == null:
		return

	# 更新所有轨道按钮的UI状态（启用按钮、静音按钮、独奏按钮、音量滑块）
	for track_item in _track_view.list_items:
		if track_item is MidiTrack:
			var track_idx = track_item.track_index
			var channel = track_item.track_channel

			# 更新启用按钮状态
			# 新MIDI时，尚未初始化配置，应该默认显示"启用"
			var is_enabled = current_midi_data.is_track_channel_selected(track_idx, channel)
			if not current_midi_data.is_track_config_initialized():
				# 新MIDI的情况：默认认为所有轨道启用（待_init_master_note_displayer正式初始化）
				is_enabled = true

			if track_item.enable_btn:
				track_item.enable_btn.set_block_signals(true)
				track_item.enable_btn.button_pressed = is_enabled
				track_item.enable_btn.set_block_signals(false)
				# 更新UI显示
				if track_item.enable_btn.text:
					track_item.enable_btn.text = "已启用" if is_enabled else "已禁用"
				if track_item.note_display:
					track_item.note_display.note_color = track_item.color_normal if is_enabled else track_item.color_dark
					track_item.note_display.update_color()

			# 更新静音按钮状态
			var is_muted = current_midi_data.get_track_channel_mute(track_idx, channel)
			if track_item.mute_btn:
				track_item.mute_btn.set_block_signals(true)
				track_item.mute_btn.button_pressed = is_muted
				track_item.mute_btn.set_block_signals(false)
				track_item.mute_btn.texture_normal.region = Rect2(0, 240, 80, 80) if is_muted else Rect2(0, 160, 80, 80)

			# 更新独奏按钮状态
			var is_soloed = _track_view.solo_pairs.has("%d:%d" % [track_idx, channel])
			if track_item.solo_btn:
				track_item.solo_btn.set_block_signals(true)
				track_item.solo_btn.button_pressed = is_soloed
				track_item.solo_btn.set_block_signals(false)
				# 贴图规则：本轨独奏/全局无独奏 → 麦克风；他人独奏中而本轨未开 → 斜杠麦克风
				track_item.refresh_solo_icon()

			# 更新音量滑块和标签
			if track_item.volume_slider:
				# 从saved配置中获取音量值，如果没有保存过则使用默认值1.0（100%）
				var saved_volume = current_midi_data.get_track_channel_volume(track_idx, channel)
				var slider_value = saved_volume  # 滑块已是线性 0-1 值

				track_item.volume_slider.set_block_signals(true)
				track_item.volume_slider.value = slider_value
				track_item.volume_slider.set_block_signals(false)

				# 更新音量标签显示
				if track_item.volume_label:
					track_item.volume_label.text = "%.2fdB" % linear_to_db(saved_volume)

	if not _track_view.solo_pairs.is_empty():
		GLogger.info("Restored solo pairs: %d channels are soloed" % _track_view.solo_pairs.size(), "TrackView")
		# 【关键】恢复UI后，立即应用独奏状态到后端（包括mute状态和快照）
		_track_view._capture_solo_snapshot()
		_track_view._apply_solo_state()

	if current_midi_data.is_track_config_initialized():
		if not current_midi_data.selected_track_configs.is_empty():
			GLogger.info("Restored enable states: %d tracks with enabled channels" % current_midi_data.selected_track_configs.size(), "TrackView")
		else:
			GLogger.info("Restored enable states: All tracks are DISABLED", "TrackView")
	else:
		GLogger.info("New MIDI: All tracks shown as enabled, will be finalized in _init_master_note_displayer", "TrackView")

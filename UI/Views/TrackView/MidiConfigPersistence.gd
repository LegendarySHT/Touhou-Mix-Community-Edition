class_name MidiConfigPersistence
extends Node

## MIDI 配置持久化控制器：从 TrackView 提取的保存/恢复配置逻辑

var _track_view: TrackView = null


func setup(track_view: TrackView) -> void:
	_track_view = track_view


## 保存当前MIDI配置到 chart_runtime（权威 DB，替代 JSON 写回）
func save_midi_config() -> void:
	var current_midi_data = _track_view.current_midi_data
	if current_midi_data == null:
		push_warning("[TrackView] No MIDI data to save")
		return

	# 更新MidiData中的音量值（滑块为线性 0-1）
	current_midi_data.midi_volume = _track_view.midi_vol_slider.value
	current_midi_data.vocal_volume = _track_view.vocal_vol_slider.value

	# 更新人声文件路径
	current_midi_data.vocal_file_path = _track_view._vocal_controller.vocal_file_path

	# 更新独奏状态
	current_midi_data.solo_pairs = _track_view.solo_pairs.duplicate()

	# 更新音轨启用状态（从所有轨道UI控件收集）
	# selected_track_configs 由各个 MidiTrack 项通过 _on_track_enable_toggled 更新
	# 这里只需确保 current_midi_data.selected_track_configs 已是最新状态
	# 导出运行时配置
	var runtime_config = current_midi_data.export_runtime_config()

	# 保存到 chart_runtime（优先使用file_hash，如果为空则使用id）
	var chart_id = current_midi_data.file_hash if not current_midi_data.file_hash.is_empty() else current_midi_data.id
	if ChartDB and ChartDB.IsOpen():
		ChartDB.SaveRuntime(chart_id, runtime_config)
		GLogger.info("Successfully saved MIDI config to DB (volume: %d/%d, solo: %d, track_enabled: %s, vocal: %s)" %
			[current_midi_data.midi_volume, current_midi_data.vocal_volume, _track_view.solo_pairs.size(), current_midi_data.selected_track_configs, _track_view._vocal_controller.vocal_file_path], "TrackView")
	else:
		push_error("[TrackView] ChartDB not open, cannot save MIDI config for: %s" % current_midi_data.id)


## 恢复MIDI配置的数据部分（音量、进度条、独奏状态）
## 在_load_midi中早期调用，此时list_items还未创建
func restore_midi_data_config() -> void:
	var current_midi_data = _track_view.current_midi_data
	if current_midi_data == null:
		return

	var midi_vol_slider = _track_view.midi_vol_slider
	var vocal_vol_slider = _track_view.vocal_vol_slider
	var midi_playback_manager = _track_view.midi_playback_manager
	var progress_bar = _track_view.progress_bar
	var current_time = _track_view.current_time

	midi_vol_slider.set_block_signals(true)
	vocal_vol_slider.set_block_signals(true)

	# 获取音量值，默认值(0.5)时回退全局 default_midi_volume（与 PlayView 统一解析，并 clamp 到滑块范围）
	var midi_vol = midi_playback_manager.get_effective_midi_volume(current_midi_data.midi_volume)
	var vocal_vol = current_midi_data.vocal_volume

	if vocal_vol == 0.5:  # 默认值
		var setting_view = _track_view.get_node_or_null(PathRegistry.SETTING_VIEW)
		if setting_view and setting_view.has_method("get_setting_value"):
			var global_vocal_vol = setting_view.get_setting_value("default_vocal_volume")
			if global_vocal_vol != null:
				vocal_vol = float(global_vocal_vol)
				if vocal_vol > 1.0:
					vocal_vol /= 100.0  # 兼容旧版 0-100 配置

	midi_vol_slider.value = midi_vol
	vocal_vol_slider.value = vocal_vol

	_track_view._set_display_midi_volume(midi_vol_slider.value)
	_track_view._vocal_controller.set_display_vocal_volume(vocal_vol_slider.value)

	midi_vol_slider.set_block_signals(false)
	vocal_vol_slider.set_block_signals(false)

	# 同步静音按钮按下状态（静音 = 音量条 0）：切换 MIDI 时须重置，避免沿用上一个 MIDI 的按下态
	_track_view.midi_vol_btn.set_pressed_no_signal(midi_vol_slider.value <= 0.0)
	_track_view.vocal_vol_btn.set_pressed_no_signal(vocal_vol_slider.value <= 0.0)

	# 应用实际的播放音量，不只是更新UI
	# MIDI音量映射系数见 MidiPlaybackManager.MIDI_VOLUME_GAIN（0.5=+6dB, 1.0=+12dB）
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
				if track_item.enable_btn_text:
					track_item.enable_btn_text.text = "已启用" if is_enabled else "已禁用"
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
				track_item.solo_btn.texture_normal.region = Rect2(80, 160, 80, 80) if is_soloed else Rect2(80, 240, 80, 80)

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

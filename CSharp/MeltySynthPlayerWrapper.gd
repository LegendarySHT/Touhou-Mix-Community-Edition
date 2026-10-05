## MeltySynthPlayer 的 GDScript 包装
## 将 C# 对象包装为 GDScript MidiPlaybackInterface 接口
extends MidiPlaybackInterface
class_name MeltySynthPlayerWrapper

signal vocal_finished

@export var meltysynth_player: Node

# 最大复音数
var max_polyphony: int = 96:
	set(value):
		max_polyphony = value
		if meltysynth_player != null and meltysynth_player.has_method("set_max_polyphony"):
			meltysynth_player.call("set_max_polyphony", value)

func _ready() -> void:
	if meltysynth_player != null and meltysynth_player.has_signal("finished"):
		meltysynth_player.connect("finished", Callable(self, "_on_finished"))
	if meltysynth_player != null and meltysynth_player.has_signal("vocal_finished"):
		meltysynth_player.connect("vocal_finished", Callable(self, "_on_vocal_finished"))
	if meltysynth_player != null and meltysynth_player.has_signal("soundfont_changed"):
		meltysynth_player.connect("soundfont_changed", Callable(self, "_on_soundfont_changed"))

## 转发 C# 自然结束信号，供 MidiPlaybackManager.midi_finished → PlayView 结算
func _on_finished() -> void:
	finished.emit()

## 转发 C# 音源加载完成信号，供 MidiPlaybackManager 在推迟播放下从此起点对齐启动人声
func _on_soundfont_changed(path: String) -> void:
	soundfont_changed.emit(path)

## 设置最大复音数（走属性 setter，由其驱动 C# 调用统一生效）
func set_max_polyphony(value: int) -> void:
	max_polyphony = value

## 听歌降耗档：把音频缓冲切到省电档（Android period 4096×3，听歌无所谓延迟，缓冲拉长更省电）。
## 仅供播放器页面听歌开启；打歌/音轨用回 256 保持低延迟。
func set_listening_profile(enabled: bool) -> void:
	if meltysynth_player != null and meltysynth_player.has_method("set_listening_profile"):
		meltysynth_player.call("set_listening_profile", enabled)

func _on_vocal_finished() -> void:
	vocal_finished.emit()
	# 尽管 meltysynth_player 是 C# 对象，我们可以通过 call() 和方法名称与之交互
	pass

## 加载 MIDI 文件
func load_midi(file_path: String) -> bool:
	if meltysynth_player == null:
		return false
	return meltysynth_player.call("load_midi", file_path)

## 播放。返回 C# 结果：true=已真正启动，false=音源仍在加载/切换、已推迟。
func play() -> bool:
	if meltysynth_player == null:
		return false
	var result = meltysynth_player.call("play")
	return result if result is bool else true

## 暂停
func pause() -> void:
	if meltysynth_player == null:
		return
	meltysynth_player.call("pause")

## 恢复。返回 C# 结果：true=已真正续播，false=音源仍在加载/切换、已推迟。
func resume() -> bool:
	if meltysynth_player == null:
		return false
	var result = meltysynth_player.call("resume")
	return result if result is bool else true

## 停止
func stop() -> void:
	if meltysynth_player == null:
		return
	meltysynth_player.call("stop")

## 寻找位置（毫秒）
func seek(position_ms: float) -> void:
	if meltysynth_player == null:
		return
	meltysynth_player.call("seek", position_ms)

## 获取当前位置（毫秒）
func get_position_ms() -> float:
	if meltysynth_player == null:
		return 0.0
	return meltysynth_player.call("get_position_ms")

## 获取音频回调已渲染的 MIDI 原始位置（毫秒）
## 该时钟不做设备延迟补偿，用于与人声消费帧直接比较
func get_raw_position_ms() -> float:
	if meltysynth_player == null:
		return 0.0
	if not meltysynth_player.has_method("get_raw_position_ms"):
		return get_position_ms()
	var result = meltysynth_player.call("get_raw_position_ms")
	return float(result) if result is float or result is int else get_position_ms()

## 获取总长度（毫秒）
func get_duration_ms() -> float:
	if meltysynth_player == null:
		return 0.0
	return meltysynth_player.call("get_duration_ms")

## 设置音量（dB）
func set_volume_db(db: float) -> void:
	if meltysynth_player == null:
		return
	meltysynth_player.call("set_volume_db", db)

## 获取当前音量（dB）
func get_volume_db() -> float:
	if meltysynth_player == null:
		return 0.0
	var result = meltysynth_player.call("get_volume_db")
	return result if result is float else 0.0

## 设置音频总线
func set_bus(bus_name: String) -> void:
	if meltysynth_player == null:
		return
	meltysynth_player.call("set_bus", bus_name)

## 设置音色库
func set_soundfont(path: String) -> bool:
	if meltysynth_player == null:
		return false
	meltysynth_player.call("set_soundfont", path)
	return true

## 设置轨道/通道的音量
func set_track_channel_volume(track_index: int, channel: int, volume: float) -> void:
	if meltysynth_player == null:
		return
	meltysynth_player.call("set_track_channel_volume", track_index, channel, volume)

## 设置轨道/通道的静音状态
func set_track_channel_mute(track_index: int, channel: int, muted: bool) -> void:
	if meltysynth_player == null:
		return
	meltysynth_player.call("set_track_channel_mute", track_index, channel, muted)

## 设置轨道/通道的乐器
func set_track_channel_instrument(track_index: int, channel: int, bank: int, program: int) -> void:
	if meltysynth_player == null:
		return
	meltysynth_player.call("set_track_channel_instrument", track_index, channel, bank, program)

## 获取音色预设列表
func get_presets_list() -> Array:
	if meltysynth_player == null:
		return []
	var result = meltysynth_player.call("get_presets_list")
	if result is PackedStringArray:
		return Array(result)
	return result if result is Array else []

## 获取指定索引的音色预设名称
func get_preset_name(program: int, bank: int = 0) -> String:
	if meltysynth_player == null:
		return ""
	return meltysynth_player.call("get_preset_name", program, bank)

## 触发按键（Note On）
func trigger_note_on(pitch: int, velocity: int, channel: int, track_index: int = 0) -> void:
	if meltysynth_player == null:
		return
	meltysynth_player.call("trigger_note_on", pitch, velocity, channel, track_index)

## 批量触发按键（Note On，演奏模式一次判定单次跨语言调用）
func trigger_notes_on(events: Array) -> void:
	if meltysynth_player == null:
		return
	meltysynth_player.call("trigger_notes_on", events)

## 预热手动音符触发路径（无声音，消除首次点击的一次性 JIT/通道分配成本）
func warmup_manual_path(track_channel_instruments: Dictionary = {}) -> void:
	if meltysynth_player == null:
		return
	meltysynth_player.call("warmup_manual_path", track_channel_instruments)

## 释放按键（Note Off）
func trigger_note_off(pitch: int, velocity: int, channel: int, track_index: int = 0) -> void:
	if meltysynth_player == null:
		return
	meltysynth_player.call("trigger_note_off", pitch, velocity, channel, track_index)

## 获取轨道/通道的音量
func get_track_channel_volume(track_index: int, channel: int) -> float:
	if meltysynth_player == null:
		return 1.0
	var result = meltysynth_player.call("get_track_channel_volume", track_index, channel)
	return result if result is float else 1.0

## 获取轨道/通道的乐器信息
func get_track_channel_instrument(track_index: int, channel: int) -> Dictionary:
	if meltysynth_player == null:
		return {}
	var result = meltysynth_player.call("get_track_channel_instrument", track_index, channel)
	return result if result is Dictionary else {}

## 检查是否正在播放
func is_playing() -> bool:
	if meltysynth_player == null:
		return false
	var result = meltysynth_player.call("is_playing")
	return result if result is bool else false

## 设置手动控制的 note 列表
func set_manually_controlled_notes(manually_controlled: Dictionary) -> void:
	if meltysynth_player == null:
		return
	meltysynth_player.call("set_manually_controlled_notes", manually_controlled)

## 设置循环播放
func set_loop(enabled: bool) -> void:
	if meltysynth_player == null:
		return
	meltysynth_player.call("set_loop", enabled)

## 获取循环播放状态
func get_loop() -> bool:
	if meltysynth_player == null:
		return false
	var result = meltysynth_player.call("get_loop")
	return result if result is bool else false

## 设置是否启用系统时钟模式
func set_use_system_stopwatch(enabled: bool) -> void:
	if meltysynth_player == null:
		return
	meltysynth_player.call("set_use_system_stopwatch", enabled)

## 获取系统时钟模式状态
func get_use_system_stopwatch() -> bool:
	if meltysynth_player == null:
		return false
	var result = meltysynth_player.call("get_use_system_stopwatch")
	return result if result is bool else false

## 跳转到指定位置（毫秒）
func seek_ms(position_ms: float) -> void:
	if meltysynth_player == null:
		return
	meltysynth_player.call("seek_ms", position_ms)

## 设置音频缓冲区大小（帧）
func set_audio_buffer_frames(frames: int) -> void:
	if meltysynth_player == null:
		return
	meltysynth_player.call("set_audio_buffer_frames", frames)

## 强制重建音频输出设备（跟随当前系统默认输出端点；用于蓝牙耳机连接/断开后重路由音频）
func recreate_audio_output() -> void:
	if meltysynth_player == null:
		return
	meltysynth_player.call("recreate_audio_output")

## 人声文件加载 (miniaudio 统一输出链路)
func load_vocal_file(path: String) -> bool:
	if meltysynth_player == null:
		return false
	var result = meltysynth_player.call("load_vocal_file", path)
	return result if result is bool else false

func unload_vocal() -> void:
	if meltysynth_player == null:
		return
	meltysynth_player.call("unload_vocal")

func play_vocal() -> void:
	if meltysynth_player == null:
		return
	meltysynth_player.call("play_vocal")

func pause_vocal() -> void:
	if meltysynth_player == null:
		return
	meltysynth_player.call("pause_vocal")

func resume_vocal() -> void:
	if meltysynth_player == null:
		return
	meltysynth_player.call("resume_vocal")

func stop_vocal() -> void:
	if meltysynth_player == null:
		return
	meltysynth_player.call("stop_vocal")

func seek_vocal(position_ms: float) -> void:
	if meltysynth_player == null:
		return
	meltysynth_player.call("seek_vocal", position_ms)

func set_vocal_volume(volume_linear: float) -> void:
	if meltysynth_player == null:
		return
	meltysynth_player.call("set_vocal_volume", volume_linear)

func get_vocal_position_ms() -> float:
	if meltysynth_player == null:
		return 0.0
	var result = meltysynth_player.call("get_vocal_position_ms")
	return result if result is float else 0.0

func get_vocal_length_ms() -> float:
	if meltysynth_player == null:
		return -1.0
	var result = meltysynth_player.call("get_vocal_length_ms")
	return result if result is float else -1.0

func is_vocal_playing() -> bool:
	if meltysynth_player == null:
		return false
	var result = meltysynth_player.call("is_vocal_playing")
	return result if result is bool else false

func is_vocal_finished() -> bool:
	if meltysynth_player == null:
		return false
	var result = meltysynth_player.call("is_vocal_finished")
	return result if result is bool else false

func get_vocal_underrun_count() -> int:
	if meltysynth_player == null:
		return 0
	var result = meltysynth_player.call("get_vocal_underrun_count")
	return result if result is int else 0

func get_audio_debug_info() -> Dictionary:
	if meltysynth_player == null:
		return {}
	var result = meltysynth_player.call("get_audio_debug_info")
	return result if result is Dictionary else {}

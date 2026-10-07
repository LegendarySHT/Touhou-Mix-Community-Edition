## 音频管理器
## 负责人声播放的门面层：所有 vocal 控制转发到 PlaybackDisplay 的 miniaudio 后端
extends Node

class_name AudioManager

## 单例实例
static var instance: AudioManager

func _ready() -> void:
	if instance == null:
		instance = self
	else:
		queue_free()
	add_to_group("singleton")

## ========== 人声相关方法（miniaudio 统一输出链路） ==========

## 播放人声文件（path 支持 user:// / res:// / 绝对路径，offset_ms 为毫秒）
func play_vocal_file(path: String, offset_ms: float = 0.0) -> bool:
	if path.is_empty() or MeltySynth == null:
		return false
	return MeltySynth.play_vocal_file(path, offset_ms)

## 停止人声（保留已加载文件）
func stop_vocal() -> void:
	if MeltySynth != null:
		MeltySynth.stop_vocal_file()

## 卸载人声资源
func unload_vocal() -> void:
	if MeltySynth != null:
		MeltySynth.unload_vocal()

## 暂停 / 恢复人声
func set_vocal_playing(is_playing: bool) -> void:
	if MeltySynth != null:
		MeltySynth.set_vocal_playing(is_playing)

## 获取人声播放进度（毫秒）
func get_vocal_position() -> float:
	return MeltySynth.get_vocal_position() if MeltySynth != null else 0.0

## 跳转人声播放进度（毫秒）
func seek_vocal(position_ms: float) -> void:
	if MeltySynth != null:
		MeltySynth.seek_vocal(position_ms)

## 设置人声音量（dB）
func set_vocal_volume_db(volume_db: float) -> void:
	if MeltySynth != null:
		MeltySynth.set_vocal_volume_db(volume_db)

## 检查人声是否正在播放
func is_vocal_playing() -> bool:
	return MeltySynth != null and MeltySynth.is_vocal_playing()

## 检查人声是否已自然结束
func is_vocal_finished() -> bool:
	return MeltySynth != null and MeltySynth.is_vocal_finished()

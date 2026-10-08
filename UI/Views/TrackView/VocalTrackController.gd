class_name VocalTrackController
extends Node

## 人声子系统控制器：从 TrackView 提取的人声导入/启用/音量/检测逻辑

var _track_view: TrackView = null
var _file_dialog: FileDialog = null
var _vocal_import_btn: TextureButton = null
var _vocal_enable_btn: Button = null
var _vocal_vol_btn: TextureButton = null
var _vocal_vol_slider: HSlider = null
var _vocal_vol_label: Label = null

## 人声音频路径（由本控制器管理，TrackView 通过 vocal_file_path 访问）
var vocal_file_path: String = ""


func setup(track_view: TrackView, file_dialog: FileDialog, vocal_import_btn: TextureButton,
		vocal_enable_btn: Button, vocal_vol_btn: TextureButton,
		vocal_vol_slider: HSlider, vocal_vol_label: Label) -> void:
	_track_view = track_view
	_file_dialog = file_dialog
	_vocal_import_btn = vocal_import_btn
	_vocal_enable_btn = vocal_enable_btn
	_vocal_vol_btn = vocal_vol_btn
	_vocal_vol_slider = vocal_vol_slider
	_vocal_vol_label = vocal_vol_label


## 惰性创建并获取 FileDialog
## 首次调用时同步初始化原生对话框（Windows 上 shell 组件初始化约 2-3 秒），
## 因此推迟到用户首次点击"导入人声"时才创建，避免 TrackView._ready 卡顿
func _ensure_file_dialog() -> FileDialog:
	if _file_dialog and is_instance_valid(_file_dialog):
		return _file_dialog
	_file_dialog = FileDialog.new()
	_file_dialog.name = "VocalFileDialog"
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.use_native_dialog = true
	_file_dialog.filters = PackedStringArray(["Audio Files (*.mp3,*.wav,*.ogg,*.flac) ; *.mp3,*.wav,*.ogg,*.flac", "All Files ; *"])
	# file_selected 信号连接（动态创建节点，无法在 tscn 中连接）
	_file_dialog.file_selected.connect(on_vocal_file_selected)
	_track_view.add_child(_file_dialog)
	return _file_dialog


## 打开FileDialog导入人声文件
func on_vocal_import_btn_pressed() -> void:
	var current_midi_data = _track_view.current_midi_data
	if not current_midi_data:
		push_warning("[TrackView] No MIDI data loaded, cannot import vocal file")
		return

	# 惰性创建 FileDialog（首次调用时初始化，之后复用）
	var file_dialog := _ensure_file_dialog()

	# 获取当前曲包文件夹路径
	var filesystem_mgr = FileSystemManager.instance
	var chart_id = current_midi_data.file_hash if not current_midi_data.file_hash.is_empty() else current_midi_data.id
	var chart_folder = filesystem_mgr.get_chart_folder_path(chart_id)

	if chart_folder.is_empty():
		push_warning("[TrackView] Cannot locate chart folder for MIDI: %s" % chart_id)
		# 回退到Charts目录
		chart_folder = FileSystemManager.CHARTS_DIR

	# 配置FileDialog
	file_dialog.current_dir = chart_folder
	file_dialog.current_file = ""
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.filters = PackedStringArray(["Audio Files (*.mp3,*.wav,*.ogg,*.flac) ; *.mp3,*.wav,*.ogg,*.flac", "All Files ; *"])

	# 显示对话框（对于原生对话框，直接调用popup_centered_clamped）
	file_dialog.popup_centered_clamped(Vector2(1024, 768), 0.7)

	GLogger.info("Opening vocal import dialog at: %s" % chart_folder, "TrackView")


## 检查文件名扩展名是否为有效音频格式
## 根据文件头部 magic bytes 检测音频格式，返回扩展名
func detect_audio_format(buffer: PackedByteArray) -> String:
	# OGG: "OggS"
	if buffer.size() >= 4 and buffer[0] == 0x4F and buffer[1] == 0x67 and buffer[2] == 0x67 and buffer[3] == 0x53:
		return "ogg"
	# WAV: "RIFF"
	if buffer.size() >= 4 and buffer[0] == 0x52 and buffer[1] == 0x49 and buffer[2] == 0x46 and buffer[3] == 0x46:
		return "wav"
	# FLAC: "fLaC"
	if buffer.size() >= 4 and buffer[0] == 0x66 and buffer[1] == 0x4C and buffer[2] == 0x61 and buffer[3] == 0x43:
		return "flac"
	# MP3: 0xFF 0xFB or 0xFF 0xFA or 0xFF 0xF3 or ID3 tag
	if buffer.size() >= 3:
		if (buffer[0] == 0xFF and (buffer[1] & 0xE0) == 0xE0):
			return "mp3"
		# ID3v2 tag: "ID3"
		if buffer[0] == 0x49 and buffer[1] == 0x44 and buffer[2] == 0x33:
			return "mp3"
	return ""


## 处理文件选择完成
func on_vocal_file_selected(file_path: String) -> void:
	if file_path.is_empty():
		return

	var selected_file = file_path
	var is_content_uri := selected_file.begins_with("content://")

	var current_midi_data = _track_view.current_midi_data
	if not current_midi_data:
		push_warning("[TrackView] No MIDI data loaded, cannot import vocal file")
		return

	# 获取目标曲包文件夹
	var filesystem_mgr = FileSystemManager.instance
	var chart_id = current_midi_data.file_hash if not current_midi_data.file_hash.is_empty() else current_midi_data.id
	var chart_folder = filesystem_mgr.get_chart_folder_path(chart_id)

	if chart_folder.is_empty():
		push_warning("[TrackView] Cannot locate chart folder for MIDI: %s" % chart_id)
		GLogger.warning("Cannot locate chart folder for MIDI: %s" % chart_id, "TrackView")
		return

	# 确保目标文件夹存在
	if not DirAccess.dir_exists_absolute(chart_folder):
		var error = DirAccess.make_dir_absolute(chart_folder)
		if error != OK:
			push_error("[TrackView] Failed to create chart folder: %s (error code: %d)" % [chart_folder, error])
			GLogger.error("Failed to create chart folder: %s" % chart_folder, "TrackView")
			return

	# 读取源文件
	var src_file = FileAccess.open(selected_file, FileAccess.READ)
	if src_file == null:
		push_error("[TrackView] Failed to open file: %s" % selected_file)
		GLogger.error("Failed to open audio file: %s" % selected_file, "TrackView")
		return

	var file_size = src_file.get_length()
	if file_size < 1024:
		push_error("[TrackView] Audio file too small: %d bytes" % file_size)
		src_file.close()
		return

	var buffer = src_file.get_buffer(file_size)
	src_file.close()

	# 确定目标文件名
	var source_file_name: String
	if not is_content_uri:
		source_file_name = selected_file.get_file()
	else:
		# Android SAF 无法直接拿到文件名，用 magic bytes 检测格式
		var ext := detect_audio_format(buffer)
		if ext.is_empty():
			push_warning("[TrackView] Cannot detect audio format from content: %s" % selected_file)
			GLogger.warning("Cannot detect audio format from content URI", "TrackView")
			return
		source_file_name = chart_id + "_vocal." + ext

	var destination_path = chart_folder.path_join(source_file_name)

	# 写入本地文件
	var dst_file = FileAccess.open(destination_path, FileAccess.WRITE)
	if dst_file == null:
		push_error("[TrackView] Failed to create destination file: %s" % destination_path)
		return

	dst_file.store_buffer(buffer)
	dst_file.close()

	# 保存路径到 MidiData
	vocal_file_path = destination_path
	if current_midi_data:
		current_midi_data.vocal_file_path = destination_path

	# 刷新UI显示
	init_vocal_btn_display()

	# 如果 MIDI 正在播放，立即启动人声同步播放
	var midi_playback_manager = _track_view.midi_playback_manager
	if midi_playback_manager and midi_playback_manager.is_playing:
		midi_playback_manager.start_vocal_playback()

	GLogger.info("Vocal file imported successfully: %s -> %s" % [selected_file, destination_path], "TrackView")
	GLogger.info("Vocal file imported to: %s" % destination_path, "VocalTrackController")


## 人声启用/禁用按钮回调
func on_vocal_enable_btn_toggled(toggle_on: bool) -> void:
	_vocal_enable_btn.text = "人声已启用" if not toggle_on else "人声已关闭"

	var current_midi_data = _track_view.current_midi_data
	if current_midi_data:
		current_midi_data.vocal_enabled = not toggle_on
		var midi_playback_manager = _track_view.midi_playback_manager
		if midi_playback_manager and midi_playback_manager.is_playing:
			if current_midi_data.vocal_enabled:
				midi_playback_manager.start_vocal_playback()
			else:
				midi_playback_manager.stop_vocal_playback()


## 检测并定位人声文件（MidiView 显示 / TrackView 共用同一检测逻辑）
## 优先级：1. MidiData.vocal_file_path（已保存的路径）
##        2. FileSystemManager 扫描到的音频文件（.ogg/.mp3/.wav/.flac）
## 返回解析到的人声路径（未找到返回空串），并回填 midi_data.vocal_file_path
static func resolve_vocal_path(midi_data: MidiData) -> String:
	if not midi_data:
		return ""

	# 检查是否已有保存的人声文件路径
	if not midi_data.vocal_file_path.is_empty():
		if FileAccess.file_exists(midi_data.vocal_file_path):
			GLogger.info("Vocal file restored from saved config: %s" % midi_data.vocal_file_path, "TrackView")
			return midi_data.vocal_file_path
		# 如果保存的路径已不存在，继续扫描
		GLogger.warning("Saved vocal file no longer exists: %s" % midi_data.vocal_file_path, "TrackView")
		midi_data.vocal_file_path = ""

	# 从 FileSystemManager 的反向索引查找对应谱面（O(1)，统一匹配 id / file_hash / hash）
	var filesystem_mgr = FileSystemManager.instance
	var chart_id = midi_data.chart_key if not midi_data.chart_key.is_empty() \
		else (midi_data.file_hash if not midi_data.file_hash.is_empty() else midi_data.id)

	# 先走人声速查索引（扫描时构建，标准 vocal.<ext> 优先；内存未命中回退 DB 速查库）
	var indexed_vocal := "" if filesystem_mgr == null else filesystem_mgr.get_vocal_path(chart_id)
	if not indexed_vocal.is_empty():
		midi_data.vocal_file_path = indexed_vocal
		GLogger.info("Vocal file resolved from index: %s" % indexed_vocal, "TrackView")
		return indexed_vocal

	var lookup = filesystem_mgr.lookup_chart(chart_id)
	if not lookup.is_empty():
		var metadata: ChartMetadata = lookup["metadata"]
		var audio_path = metadata.audio_path
		if not audio_path.is_empty() and FileAccess.file_exists(audio_path):
			midi_data.vocal_file_path = audio_path
			GLogger.info("Vocal file detected from chart metadata: %s" % audio_path, "TrackView")
			return audio_path
		elif not audio_path.is_empty():
			GLogger.warning("Vocal file in chart metadata no longer exists: %s" % audio_path, "TrackView")

	# 未找到人声文件
	GLogger.info("No vocal file found for MIDI: %s" % chart_id, "TrackView")
	return ""


# 在这个函数执行前需要先检查有无人声音频
func init_vocal_btn_display() -> void:
	var latency_container = _track_view.get_node("MC/VBox/VolumeView/HBoxC/VBoxC2/HBoxC")
	var enable: bool = vocal_file_path != ""

	# 设置组件可见性
	_vocal_import_btn.visible = not enable

	latency_container.visible = enable
	_vocal_enable_btn.visible = enable

	_vocal_vol_btn.visible = enable
	_vocal_vol_slider.visible = enable
	_vocal_vol_label.visible = enable

	# 如果有人声文件，恢复音量设置
	var current_midi_data = _track_view.current_midi_data
	if enable and current_midi_data:
		_vocal_vol_slider.value = current_midi_data.vocal_volume
		set_display_vocal_volume(current_midi_data.vocal_volume)
		_vocal_enable_btn.button_pressed = not current_midi_data.vocal_enabled
		_vocal_enable_btn.text = "人声已启用" if current_midi_data.vocal_enabled else "人声已关闭"


func set_display_vocal_volume(value: float) -> void:
	_vocal_vol_slider.set_block_signals(true)
	_vocal_vol_slider.value = value
	_vocal_vol_slider.set_block_signals(false)

	_vocal_vol_label.text = "%d%%" % int(round(value * 100.0))

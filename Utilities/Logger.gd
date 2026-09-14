## 日志系统
## 用于统一的日志记录和调试输出
class_name GameLogger
extends Node

## 日志级别
enum LogLevel {
	DEBUG = 0,
	INFO = 1,
	WARNING = 2,
	ERROR = 3
}

## 当前日志级别（低于此级别的日志会被忽略）
var current_level: LogLevel = LogLevel.DEBUG

## 是否输出到文件
var log_to_file: bool = true

## 是否输出到控制台
var log_to_console: bool = true

## 日志文件路径（会在 _ready 中初始化）
var log_file_path: String = ""

## 日志文件句柄（复用，避免每次写入都重新打开文件）
var _log_file: FileAccess = null

## 日志前缀映射
var level_names = {
	LogLevel.DEBUG: "[DEBUG]",
	LogLevel.INFO: "[INFO]",
	LogLevel.WARNING: "[WARN]",
	LogLevel.ERROR: "[ERROR]"
}

## 日志颜色映射
var level_colors = {
	LogLevel.DEBUG: "#CCCCCC",
	LogLevel.INFO: "#FFFFFF",
	LogLevel.WARNING: "#FFFF00",
	LogLevel.ERROR: "#FF0000"
}

func _ready() -> void:
	add_to_group("singleton")
	_init_log_path()

## 初始化日志文件路径（含日期）并确保目录存在
func _init_log_path() -> void:
	var date = Time.get_date_string_from_system()
	var logs_dir = PathHelper.get_logs_dir()  # 通过 PathHelper 获取平台自适应路径

	log_file_path = logs_dir.path_join("game_%s.log" % date)

	_ensure_log_directory()

## 自定义存储根生效后刷新日志路径（Logs/ 随存储根迁移）
## 关闭旧句柄，重新解析到当前存储根下的 Logs/ 目录并重建文件
func refresh_log_path() -> void:
	if _log_file:
		_log_file.close()
		_log_file = null
	log_file_path = ""
	_init_log_path()

## 确保日志目录存在
func _ensure_log_directory() -> void:
	# 获取日志目录路径
	var log_dir = log_file_path.get_base_dir()
	
	# 使用 PathHelper 创建目录（兼容 Android 绝对路径）
	if not PathHelper.ensure_dir_exists(log_dir):
		push_error("Failed to create logs directory: %s" % log_dir)
		return
	
	# 确保日志文件存在，或者追加到现有文件
	if not FileAccess.file_exists(log_file_path):
		var file = FileAccess.open(log_file_path, FileAccess.WRITE)
		if file == null:
			push_error("Failed to create log file: %s" % log_file_path)
		else:
			file.store_line("=== Game Logger Started at %s ===" % Time.get_datetime_string_from_system())
			file.close()
	else:
		# 文件已存在，追加一个会话开始标记
		var file = FileAccess.open(log_file_path, FileAccess.READ_WRITE)
		if file:
			file.seek_end()
			file.store_line("\n=== New Session Started at %s ===" % Time.get_datetime_string_from_system())
			file.close()


## 调试日志
func debug(message: String, context: String = "") -> void:
	_log(LogLevel.DEBUG, message, context)

## 信息日志
func info(message: String, context: String = "") -> void:
	_log(LogLevel.INFO, message, context)

## 警告日志
func warning(message: String, context: String = "") -> void:
	_log(LogLevel.WARNING, message, context)

## 错误日志
func error(message: String, context: String = "") -> void:
	_log(LogLevel.ERROR, message, context)

## 内部日志实现
func _log(level: LogLevel, message: String, context: String = "") -> void:
	# 检查日志级别
	if level < current_level:
		return

	# worker 线程保护：print() 和 FileAccess 在 worker 线程调用会导致 StringName 引用计数损坏
	# （Android ARM 弱内存模型下表现为 BUG: Unreferenced static string，累积后稳定崩溃）
	# 检测非主线程时转交主线程执行
	if Thread.is_main_thread():
		_emit_log(level, message, context)
	else:
		call_deferred("_emit_log", level, message, context)

## 实际输出日志（仅主线程调用）
func _emit_log(level: LogLevel, message: String, context: String) -> void:
	# 构建日志消息
	var timestamp = Time.get_datetime_string_from_system()
	var level_prefix = level_names[level]
	var full_message = "%s %s [%s] %s" % [timestamp, level_prefix, context, message]

	# 控制台输出
	if log_to_console:
		print(full_message)

	# 文件输出
	if log_to_file:
		_write_to_file(full_message)

## 写入到日志文件
func _write_to_file(message: String) -> void:
	if log_file_path.is_empty():
		return
	if _log_file == null:
		_log_file = FileAccess.open(log_file_path, FileAccess.READ_WRITE)
		if _log_file == null:
			# 文件不存在时尝试创建
			_log_file = FileAccess.open(log_file_path, FileAccess.WRITE)
		if _log_file == null:
			push_error("Failed to open or create log file: %s" % log_file_path)
			return
		if _log_file.get_length() > 0:
			_log_file.seek_end()
	_log_file.store_line(message)

## 刷新并释放文件句柄（退出/读文件前调用）
func _flush_log_file() -> void:
	if _log_file:
		_log_file.flush()
		_log_file = null

func _exit_tree() -> void:
	_flush_log_file()

## 设置日志级别
func set_log_level(level: LogLevel) -> void:
	current_level = level

## 清空日志文件
func clear_log_file() -> void:
	_flush_log_file()
	var file = FileAccess.open(log_file_path, FileAccess.WRITE)
	if file:
		file.truncate_64(0)
		file.close()

## 获取日志文件内容
func get_log_contents() -> String:
	_flush_log_file()
	var file = FileAccess.open(log_file_path, FileAccess.READ)
	if file == null:
		return ""
	var content := file.get_as_text()
	file.close()
	return content

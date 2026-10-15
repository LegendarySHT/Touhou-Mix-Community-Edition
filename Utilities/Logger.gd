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

## 日志前缀表（Array 下标 = LogLevel 数值；刻意不用 Dictionary——worker 线程持锁拼行时
## 要避开 Dictionary/StringName 查找，这是本类可被任意线程安全调用的前提之一）
var _level_prefixes := ["[DEBUG]", "[INFO]", "[WARN]", "[ERROR]"]

## 串行化所有日志输出（控制台 + 文件）
var _mutex := Mutex.new()

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
	_mutex.lock()
	_close_log_file_locked()
	log_file_path = ""
	_init_log_path()
	_mutex.unlock()

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

## 内部日志实现（任意线程可调用）
func _log(level: LogLevel, message: String, context: String = "") -> void:
	# 检查日志级别（锁外读取，int 赋值原子，无需保护）
	if level < current_level:
		return

	# 任意线程直接输出，由 _mutex 串行化
	_mutex.lock()
	_emit_log(level, message, context)
	_mutex.unlock()

## 实际输出日志（任意线程可调用；调用方必须已持有 _mutex）
func _emit_log(level: LogLevel, message: String, context: String) -> void:
	# 构建日志消息
	var timestamp = Time.get_datetime_string_from_system()
	var full_message = "%s %s [%s] %s" % [timestamp, _level_prefixes[level], context, message]

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
	# 立即 flush：FileAccess 的 store_line 是带缓冲的，不 flush 时进程在后台被 LMK
	# 杀掉会整缓冲丢失（实验项目 bg_append.log 因此产出 0 行）
	_log_file.flush()

## 刷新并释放文件句柄（退出/读文件前调用；持锁执行）
func _flush_log_file() -> void:
	_mutex.lock()
	_close_log_file_locked()
	_mutex.unlock()

## 关闭句柄（调用方必须已持有 _mutex；flush 后置 null，FileAccess 引用归零时自动 close）。
## GDScript 的 Mutex 非递归，已持锁的路径必须走本函数而非 _flush_log_file，否则死锁。
func _close_log_file_locked() -> void:
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
	_mutex.lock()
	_close_log_file_locked()
	var file = FileAccess.open(log_file_path, FileAccess.WRITE)
	if file:
		file.truncate_64(0)
		file.close()
	_mutex.unlock()

## 获取日志文件内容
func get_log_contents() -> String:
	_mutex.lock()
	_close_log_file_locked()
	var file = FileAccess.open(log_file_path, FileAccess.READ)
	if file == null:
		_mutex.unlock()
		return ""
	var content := file.get_as_text()
	file.close()
	_mutex.unlock()
	return content

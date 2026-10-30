## 日志系统
## 用于统一的日志记录和调试输出
##
## 线程模型（生产者 / 消费者）：
##   任意线程调用 info/debug/... → 格式化 + 入队 + sem.post（微秒级）
##   专职 writer 线程 → 排空队列 → print + store_line + flush（所有 IO 都在这里）
## 为什么：Android 上一次真实磁盘写（store_line + flush）实测 ~6ms；`print` 走 logcat
## 也是一次同步写。放主线程就是每几百毫秒一记 6ms 尖峰，对 16.6ms 帧预算直接掉帧。
## 注意：不能用信号/call_deferred 代替本线程 —— 信号默认同步直连，CONNECT_DEFERRED 与
## call_deferred 都靠 SceneTree::process 冲刷，而主循环正是后台被冻结的那一个。
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

## 日志文件句柄。只允许两种持有者：writer 线程本身，或「writer 已停止」时的调用线程。
var _log_file: FileAccess = null

## 合并窗口：writer 被唤醒后先等这么久，把同一波日志攒成一次落盘，
## 否则一行一次 flush（高日志量时反而比原来更糟）。ERROR 级跳过本窗口。
const _COALESCE_MS := 30
## 合并窗口的切片粒度：停止线程时最坏只等这么久
const _COALESCE_SLICE_MS := 5

## 待写行（_mutex 保护）
var _pending: Array[String] = []
## 有待写 ERROR，writer 跳过合并窗口立即落盘
var _urgent := false

var _writer: Thread = null
var _writer_running := false
var _stop_writer := false
var _wake := Semaphore.new()

## 日志前缀表（Array 下标 = LogLevel 数值；刻意不用 Dictionary——该表会在任意线程的
## _log 里查，避开 Dictionary/StringName 查找是本类可被任意线程调用的前提之一）
var _level_prefixes := ["[DEBUG]", "[INFO]", "[WARN]", "[ERROR]"]

## 串行化队列状态与文件句柄归属
var _mutex := Mutex.new()

func _ready() -> void:
	add_to_group("singleton")
	_init_log_path()
	_start_writer_thread()

## 初始化日志文件路径（含日期）并确保目录存在
func _init_log_path() -> void:
	var date = Time.get_date_string_from_system()
	var logs_dir = PathHelper.get_logs_dir()  # 通过 PathHelper 获取平台自适应路径

	log_file_path = logs_dir.path_join("game_%s.log" % date)

	_ensure_log_directory()

## 自定义存储根生效后刷新日志路径（Logs/ 随存储根迁移）
## 关闭旧句柄，重新解析到当前存储根下的 Logs/ 目录并重建文件
func refresh_log_path() -> void:
	_stop_writer_thread()
	_mutex.lock()
	_close_file()
	log_file_path = ""
	_init_log_path()
	_mutex.unlock()
	_start_writer_thread()

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

## 内部日志实现（任意线程可调用；落到这里只做格式化 + 入队）
func _log(level: LogLevel, message: String, context: String = "") -> void:
	# 检查日志级别（锁外读取，int 赋值原子，无需保护）
	if level < current_level:
		return
	if not log_to_console and not log_to_file:
		return

	var timestamp = Time.get_datetime_string_from_system()
	var full_message = "%s %s [%s] %s" % [timestamp, _level_prefixes[level], context, message]

	_mutex.lock()
	if _writer_running:
		_pending.append(full_message)
		if level >= LogLevel.ERROR:
			_urgent = true
		_mutex.unlock()
		_wake.post()
	else:
		# writer 未启动（_ready 之前 / 已停止）：退化为主线程直写，保证日志不丢
		_emit_sync(full_message)
		_mutex.unlock()

## 同步输出一行（调用方必须已持有 _mutex；仅 writer 停止时走这里）
func _emit_sync(full_message: String) -> void:
	if log_to_console:
		print(full_message)
	if log_to_file:
		if not _ensure_file_open():
			return
		_log_file.store_line(full_message)
		_log_file.flush()

# ===== writer 线程 =====

func _start_writer_thread() -> void:
	if _writer_running:
		return
	_stop_writer = false
	_writer = Thread.new()
	# 先置位再 start：否则 start 到置位之间的日志会走同步直写，与刚起来的 writer 抢句柄
	_mutex.lock()
	_writer_running = true
	_mutex.unlock()
	if _writer.start(_writer_loop) != OK:
		push_error("Failed to start log writer thread; falling back to synchronous writes")
		_writer = null
		_mutex.lock()
		_writer_running = false
		_write_batch(_pending)
		_pending.clear()
		_urgent = false
		_mutex.unlock()

## 停止 writer：排空队列、flush、关句柄。退出/重开日志/切后台兜底用
func _stop_writer_thread() -> void:
	if _writer_running:
		_stop_writer = true
		_wake.post()
		if _writer != null:
			# 别在等 join 时持锁：writer 收尾要拿 _mutex
			_writer.wait_to_finish()
			_writer = null
		_mutex.lock()
		_writer_running = false
		# join 期间生产者仍可能入队（那时 _writer_running 还是 true），这里补写
		if not _pending.is_empty():
			_write_batch(_pending)
			_pending.clear()
		_urgent = false
		_mutex.unlock()
	_mutex.lock()
	_close_file()
	_mutex.unlock()

func _writer_loop() -> void:
	while true:
		_wake.wait()
		if _stop_writer:
			_drain()
			break
		# 合并窗口：把同一波日志攒进同一次落盘。ERROR 来了就别等
		if not _urgent:
			var waited := 0
			while waited < _COALESCE_MS and not _stop_writer and not _urgent:
				OS.delay_msec(_COALESCE_SLICE_MS)
				waited += _COALESCE_SLICE_MS
		_drain()

## 排空队列并一次性落盘（仅 writer 线程调用）
func _drain() -> void:
	_mutex.lock()
	if _pending.is_empty():
		_urgent = false
		_mutex.unlock()
		return
	var batch := _pending.duplicate()
	_pending.clear()
	_urgent = false
	_mutex.unlock()
	_write_batch(batch)

## 输出一批行：先控制台，再一次性 store_line + flush（仅 writer 线程 / 已停 writer 的调用线程）
func _write_batch(batch: Array) -> void:
	if log_to_console:
		for line in batch:
			print(line)
	if log_to_file:
		if not _ensure_file_open():
			return
		for line in batch:
			_log_file.store_line(line)
		# 整批一次 flush：一次真实磁盘写 ~6ms，攒批才划算
		_log_file.flush()

## 打开日志文件并定位到末尾（仅单线程持有句柄时调用）
func _ensure_file_open() -> bool:
	if _log_file != null:
		return true
	if log_file_path.is_empty():
		return false
	_log_file = FileAccess.open(log_file_path, FileAccess.READ_WRITE)
	if _log_file == null:
		# 文件不存在时尝试创建
		_log_file = FileAccess.open(log_file_path, FileAccess.WRITE)
	if _log_file == null:
		push_error("Failed to open or create log file: %s" % log_file_path)
		return false
	if _log_file.get_length() > 0:
		_log_file.seek_end()
	return true

## 关闭句柄（flush 后置 null，FileAccess 引用归零时自动 close）
func _close_file() -> void:
	if _log_file:
		_log_file.flush()
		_log_file = null

## 把队列吃干净并释放句柄（切后台/失焦/退出时调用）
## Android 进后台后所有线程都会被 freezer 冻住，留着待写队列等于丢日志。
func _flush_log_file() -> void:
	if _writer_running:
		_stop_writer_thread()
		_start_writer_thread()
		return
	_mutex.lock()
	_close_file()
	_mutex.unlock()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED \
			or what == NOTIFICATION_WM_CLOSE_REQUEST \
			or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_flush_log_file()

func _exit_tree() -> void:
	_stop_writer_thread()

## 设置日志级别
func set_log_level(level: LogLevel) -> void:
	current_level = level

## 清空日志文件
func clear_log_file() -> void:
	_stop_writer_thread()
	_mutex.lock()
	_close_file()
	var file = FileAccess.open(log_file_path, FileAccess.WRITE)
	if file:
		file.truncate_64(0)
		file.close()
	_mutex.unlock()
	_start_writer_thread()

## 获取日志文件内容
func get_log_contents() -> String:
	_stop_writer_thread()
	_mutex.lock()
	_close_file()
	var content := ""
	var file = FileAccess.open(log_file_path, FileAccess.READ)
	if file != null:
		content = file.get_as_text()
		file.close()
	_mutex.unlock()
	_start_writer_thread()
	return content

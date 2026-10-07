## 封面纹理异步加载器
## 共享线程池 + 任务队列模式，避免主线程 Image.load_from_file 同步阻塞
##
## 使用方式（主线程调用）：
##   CoverLoader.request_load(item_id, path, callback)
##   callback 签名: func(path: String, texture: Texture2D, version: int) -> void
##   CoverLoader.cancel(item_id)  # 取消在途/等待任务（版本号失效）
##
## 按路径去重共享：同一 path 只保留一个在途后台任务；其余请求该路径的项登记为"等待者"，
## 任务完成时主线程只创建一份 ImageTexture 并统一写入 FileSystemManager 缓存，
## 再广播给该路径的所有等待者——实现同一封面全局只存在一份纹理（消除并发重复解码/上传）。
##
## 线程安全：
##   - _task_queue / _result_queue 仅通过 _mutex 访问
##   - _pending_callbacks / _item_versions / _waiters_by_path / _inflight 仅主线程访问
##   - 后台线程只读 LoadTask 字段，只写 LoadResult.image，不访问任何 Node/Resource/Singleton
##   - Image.load_from_file 在 Godot 4.x 线程安全
extends Node

class_name CoverLoaderClass

## 后台线程数（Android 8 核够用，2 个即可消费封面加载任务）
const THREAD_COUNT := 2

## 默认封面路径（res:// 走 ResourceLoader，由调用方处理同步加载分支）
const DEFAULT_COVER_PATH := "res://Resources/song_cover/1.jpg"


## 加载任务（只按 path 入队，去重以 path 为键，不再携带 item_id/version）
class LoadTask:
	var path: String


## 加载结果
class LoadResult:
	var path: String
	var image: Image  # 失败时为 null


## 后台线程
var _threads: Array[Thread] = []
## 任务队列（Mutex 保护）
var _task_queue: Array[LoadTask] = []
## 结果队列（Mutex 保护）
var _result_queue: Array[LoadResult] = []
var _mutex: Mutex = Mutex.new()
var _semaphore: Semaphore = Semaphore.new()
## 线程运行标志（shutdown 时置 false）
var _running: bool = true

## item_id → 最新版本号（主线程访问，用于取消）
## 每次 request_load / cancel 递增，使在途任务结果作废
var _item_versions: Dictionary = {}
## item_id → 回调 Callable（主线程访问）
var _pending_callbacks: Dictionary = {}
## path → true：已有该路径的后台任务在队列/执行中（Mutex 保护）
## 按路径去重：同一 path 只入队一个后台任务，其余请求登记为等待者
var _queued_paths: Dictionary = {}
## path → Array[ {item_id,version} ]：等待该路径结果的项（主线程访问）
## 任务完成时主线程只创建一份纹理并广播给这里的所有等待者
var _path_requests: Dictionary = {}


func _ready() -> void:
	# 启动后台线程
	for i in THREAD_COUNT:
		var t := Thread.new()
		var err := t.start(_thread_loop)
		if err != OK:
			GLogger.error("CoverLoader: Failed to start thread %d (err=%d)" % [i, err], "CoverLoader")
		else:
			_threads.append(t)
	set_process(true)


## 请求加载封面（主线程调用）
## item_id: 列表项标识（用于回调校验和取消）
## path: 封面文件绝对路径
## callback: 签名 func(path: String, texture: Texture2D, version: int) -> void
## 按路径去重：同一 path 只入队一个后台任务；后续请求登记为等待者，
## 任务完成时主线程统一创建一份纹理并广播给该路径所有等待者
func request_load(item_id: String, path: String, callback: Callable) -> void:
	# 递增版本号，使在途任务结果作废
	var version: int = int(_item_versions.get(item_id, 0)) + 1
	_item_versions[item_id] = version
	_pending_callbacks[item_id] = callback

	# 登记为该路径等待者（主线程访问）
	if not _path_requests.has(path):
		_path_requests[path] = []
	_path_requests[path].append({"item_id": item_id, "version": version})

	# 仅当该路径无在途后台任务时才入队新任务；否则共享已有的，不再重复解码/上传
	var need_task := false
	_mutex.lock()
	if not _queued_paths.has(path):
		_queued_paths[path] = true
		need_task = true
	_mutex.unlock()
	if not need_task:
		return

	var task := LoadTask.new()
	task.path = path

	_mutex.lock()
	_task_queue.append(task)
	_mutex.unlock()

	_semaphore.post()


## 取消在途任务（主线程调用）
## 递增版本号使在途任务结果作废，并清理回调引用避免内存泄漏
## 注：不主动从 _task_queue 移除任务（后台线程会自然消费并丢弃），
##     共享后台任务仍会完成，仅本等待者不再接收回调
func cancel(item_id: String) -> void:
	if not _item_versions.has(item_id):
		return
	_item_versions.erase(item_id)
	_pending_callbacks.erase(item_id)
	# 从各路径的等待者列表移除本项，避免结果到达时调用已取消回调
	for path in _path_requests.keys():
		var reqs: Array = _path_requests[path]
		var i := reqs.size() - 1
		while i >= 0:
			if reqs[i]["item_id"] == item_id:
				reqs.remove_at(i)
			i -= 1
		if reqs.is_empty():
			_path_requests.erase(path)


## 主线程每帧消费结果队列，触发回调
func _process(_delta: float) -> void:
	# 全程持锁访问 _result_queue，避免与后台线程 append 的数据竞争
	# （Array.is_empty() / append() 均非线程安全，无锁读取在 Godot 4.x 可能崩溃或读到中间态）
	_mutex.lock()
	if _result_queue.is_empty():
		_mutex.unlock()
		return

	# 一次性取出所有结果（减少锁竞争）
	var results := _result_queue.duplicate()
	_result_queue.clear()
	_mutex.unlock()

	for result in results:
		var r: LoadResult = result
		# 先释放路径槽（同 path 后续请求可重新入队）
		_mutex.lock()
		_queued_paths.erase(r.path)
		_mutex.unlock()

		var waiters: Array = _path_requests.get(r.path, [])
		_path_requests.erase(r.path)

		if r.image == null:
			# 读盘/解码失败：以 null 纹理触发回调，使等待者走默认封面回退逻辑，
			# 同时清理其回调/版本条目，避免泄漏与"一直等待不回包"卡死
			for req_ in waiters:
				_deliver_callback(req_["item_id"], req_["version"], r.path, null)
			continue

		# 主线程只创建一份纹理并写入 WeakRef 缓存（该路径全局共享）：
		# 若缓存已存在（重复任务/其他路径已加载同内容），直接复用，避免再上传一份 GPU 纹理
		var tex := _shared_texture(r.path, r.image)
		if tex == null:
			continue

		# 广播给该路径所有等待者
		for req_ in waiters:
			_deliver_callback(req_["item_id"], req_["version"], r.path, tex)


## 校验版本并向单个等待者投递结果（主线程）
## 版本不符（已取消/已被新请求覆盖）则不投递；clean 相关条目防泄漏
func _deliver_callback(item_id: String, version: int, path: String, tex: Texture2D) -> void:
	if _item_versions.get(item_id, -1) != version:
		return  # 已取消/已被新请求覆盖
	var cb: Variant = _pending_callbacks.get(item_id, null)
	_pending_callbacks.erase(item_id)
	_item_versions.erase(item_id)
	if cb == null or not (cb is Callable):
		return
	var callback: Callable = cb
	if not callback.is_valid():
		return
	callback.call(path, tex, version)


## 获取该路径全局共享的一份纹理（主线程）
## 缓存已存在 → 直接复用（消除同路径重复 GPU 上传）；否则创建并写入 WeakRef 缓存
func _shared_texture(path: String, image: Image) -> Texture2D:
	var fs_mgr := FileSystemManager.instance
	if fs_mgr:
		var cached := fs_mgr.get_cached_cover_texture(path)
		if cached:
			return cached
	var tex: Texture2D = ImageTexture.create_from_image(image)
	if fs_mgr:
		fs_mgr._cache_cover_texture(path, tex)
	return tex


## 后台线程主循环
func _thread_loop() -> void:
	while _running:
		_semaphore.wait()
		if not _running:
			return

		# 取任务
		_mutex.lock()
		var task: LoadTask = null
		if not _task_queue.is_empty():
			task = _task_queue.pop_front()
		_mutex.unlock()

		if task == null:
			continue  # 虚假唤醒，继续等

		# 执行磁盘 I/O（线程安全）
		var image: Image = _load_image(task.path)

		# 入结果队列
		var result := LoadResult.new()
		result.path = task.path
		result.image = image

		_mutex.lock()
		_result_queue.append(result)
		_mutex.unlock()


## 子线程读 Image(纯 I/O,无 Node/Resource 访问)
## 仅处理 user:// 路径(res:// 已在主线程同步加载)
## 失败返回 null
## 注:子线程不直接调 GLogger(非线程安全),错误信息通过 call_deferred 推到主线程
func _load_image(path: String) -> Image:
	if path.is_empty():
		return null

	# res:// 路径不应到达此处(主线程已处理),防御性返回 null
	if path.begins_with("res://"):
		return null

	if not FileAccess.file_exists(path):
		call_deferred("_log_warning", "CoverLoader: Cover file not found: %s" % path)
		return null
	var img := ImageUtil.load_image_file(path)
	if img == null:
		call_deferred("_log_warning", "CoverLoader: Failed to load cover image: %s" % path)
	return img


## 主线程日志(GLogger 非线程安全,子线程通过 call_deferred 调用此方法)
func _log_warning(msg: String) -> void:
	GLogger.warning(msg, "CoverLoader")


## 关闭线程池（Main 退出时调用）
## 幂等：重复调用安全（_threads.clear() 后循环不执行）
func shutdown() -> void:
	if _threads.is_empty() and not _running:
		return  # 已关闭,避免重复执行
	_running = false
	set_process(false)  # 停止 _process,避免空跑锁
	# 唤醒所有线程使其退出循环
	for i in _threads.size():
		_semaphore.post()
	# 等待所有线程退出。
	# 【必须无条件 wait_to_finish】Godot 的 Thread 只要没被 wait_to_finish 过，
	# 销毁时就报 "A Thread object is being destroyed without its completion having been
	# realized" —— 包括"线程函数已自己跑完"的情况（此时 is_alive() 为 false，
	# 旧写法 if t.is_alive() 会跳过等待，于是退出时必留一条告警）。对已结束的线程
	# wait_to_finish 只是 join，安全且即时。
	for t in _threads:
		t.wait_to_finish()
	_threads.clear()
	# 清空队列与字典,释放 Callable 引用(可能绑定到已 freed 的节点)
	_mutex.lock()
	_task_queue.clear()
	_result_queue.clear()
	_queued_paths.clear()
	_mutex.unlock()
	_pending_callbacks.clear()
	_item_versions.clear()
	_path_requests.clear()


## _exit_tree 兜底：Main 未捕获的退出场景(编辑器停止运行、Android 强杀等)
## 确保 Thread 被 wait_to_finish,避免 Godot "Thread was never freed" 告警
func _exit_tree() -> void:
	shutdown()

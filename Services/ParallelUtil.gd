## 受限并行运行器
##
## 只用于「无 Node / 单例依赖的纯计算工作」（目录拷贝、哈希计算）。
## 基于 Godot 4 的 WorkerThreadPool，避免手写 Thread 生命周期管理。
##
## 用法（在 async 函数中，本类虽为 RefCounted，但通过 Engine 拿到主循环去轮询）：
##   await ParallelUtil.map(n, func(i: int): void)   # 元素并行，回调跨线程
##   await ParallelUtil.run(funcs)                    # N 个独立 Callable
##
## 注意：回调内在 worker 线程执行，禁止触碰场景树 / 渲染 / 播放；
##       需要回主线程的结果用 call_deferred。
class_name ParallelUtil
extends RefCounted


## 并行执行 n 个「按索引处理」的纯计算步骤。
##   handler : Callable(int) -> void
##   await 后全部完成。错误由回调内部自行兜底，避免中断其它任务。
static func map(n: int, handler: Callable) -> void:
	if n <= 0 or not handler.is_valid():
		return
	var gid := WorkerThreadPool.add_group_task(handler, n, -1, true, "ParallelUtil.map")
	await _wait_group(gid)


## 并行执行一组独立 Callable，并等待全部完成。
##   tasks : Array[Callable]，每个在 worker 线程运行一次。
static func run(tasks: Array) -> void:
	if tasks.is_empty():
		return
	var gids: Array = []
	for t in tasks:
		if not (t is Callable) or not (t as Callable).is_valid():
			continue
		gids.append(WorkerThreadPool.add_group_task(_one.bind(t), 1, 1, true, "ParallelUtil.run"))
	await _wait_groups(gids)


## 单个任务体（elements=1 保证每个回调只跑一次）
static func _one(cb: Callable, _unused: int) -> void:
	if cb.is_valid():
		cb.call()


## 取主循环（用于 await process_frame 轮询）
static func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


static func _wait_group(gid: int) -> void:
	while not WorkerThreadPool.is_group_task_completed(gid):
		await _tree().process_frame


static func _wait_groups(gids: Array) -> void:
	while not gids.is_empty():
		await _tree().process_frame
		var done: Array = []
		for gid in gids:
			if WorkerThreadPool.is_group_task_completed(gid):
				done.append(gid)
		for gid in done:
			gids.erase(gid)
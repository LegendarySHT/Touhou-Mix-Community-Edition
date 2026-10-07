using System.Collections.Concurrent;

/// <summary>
/// 线程安全的日志出口。
///
/// 【为什么需要】非主线程（音频回调 / 解析线程 / 看门狗线程）**不得调用任何 Godot 引擎 API**。
/// 打印/文件/节点访问都要拿引擎全局锁，而主线程可能正持着它并被系统长时间挂起 ——
/// 那样这些线程会一直阻塞。
///
/// 故：主线程直接打印；非主线程只入队，由主线程在 `_Process` 里 Flush。
/// 非主线程的全部日志都必须走这里；刻意**不**另写后台日志文件（那是额外的后台 I/O，也易与真实日志脱节）。
/// </summary>
internal static class ThreadSafeLog
{
	private static int _mainThreadId = -1;
	private static readonly ConcurrentQueue<string> _pending = new();

	/// <summary>主线程在 _Ready 里登记自身（只需一次）。</summary>
	public static void MarkMainThread()
	{
		_mainThreadId = System.Environment.CurrentManagedThreadId;
	}

	/// <summary>当前是否在主线程（后台线程不得调用任何 Godot 引擎 API）。</summary>
	public static bool IsMainThread => OnMainThread;

	// 【默认取"非主线程"（fail-closed）】MarkMainThread() 未登记时 _mainThreadId 为 -1，
	// 若把它当成"是主线程"，则所有后台/音频线程日志都会直接 GD.Print —— 正是本类要避免的
	// 10~30 秒冻结。反过来（默认非主线程）代价只是启动早期的主线程日志先入队、
	// 由主线程 _Process 的 Flush 补打，故这里刻意保守。
	private static bool OnMainThread =>
		_mainThreadId != -1 && System.Environment.CurrentManagedThreadId == _mainThreadId;

	public static void Print(string message)
	{
		if (OnMainThread)
		{
			Godot.GD.Print(message);
		}
		else
		{
			_pending.Enqueue(message);
		}
	}

	public static void PrintErr(string message)
	{
		if (OnMainThread)
		{
			Godot.GD.PrintErr(message);
		}
		else
		{
			_pending.Enqueue("[ERR] " + message);
		}
	}

	/// <summary>由主线程每帧调用：把后台线程攒下的日志真正打出去。</summary>
	public static void Flush()
	{
		while (_pending.TryDequeue(out var m))
		{
			Godot.GD.Print(m);
		}
	}
}

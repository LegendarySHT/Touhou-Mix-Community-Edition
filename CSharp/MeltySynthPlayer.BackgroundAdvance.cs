using Godot;
using MeltySynth;
using System;
using System.Diagnostics;
using System.Threading;

/// <summary>
/// MeltySynthPlayer 的「深度后台自动切歌」部分（partial class）。
///
/// 场景：熄屏/深后台时 Godot 主循环（含 C# 节点的 _Process）被挂起，只有音频回调与
/// 后台线程在跑。此时曲终/回绕若只靠 GDScript 推进，就会停摆——表现为"曲终后不切歌"。
///
/// 分工：
///   - 前台（主循环存活）：_Process 取走回绕标志 → EmitSignal(loop_wrapped) → GDScript 走
///     常规范换曲路径（重解析 SOA/轨道配置/人声/UI 对齐）。
///   - 后台（主循环停摆）：本文件的线程取走同一标志 → 在 C# 侧加载并起播下一首。
///     谱面音频配置（轨道音量/静音/solo/启用门控/乐器覆盖/人声）走的是与前台 load_midi
///     完全相同的 apply_chart_audio_config，故"后台换的那首"与"前台换的那首"听感一致；
///     回前台只需 GDScript 把显示侧（SOA/UI 信号）对账，不再重放。
///
/// 判定"主循环是否存活"用 _Process 刷新的时间戳：熄屏后它很快变陈旧。
/// </summary>
public partial class MeltySynthPlayer
{
	/// <summary>
	/// _Process 最近一次执行的时间戳（Stopwatch ticks）。
	///
	/// 【跨线程可见性】主线程每帧写、后台换曲线程读。C# 不允许 `volatile long`（CS0677），
	/// 故读写两侧统一走 Volatile.Read/Write（32 位平台下会退化为 Interlocked，天然原子）。
	///
	/// 【为什么不能省】非同步读可能拿到陈旧值，于是"主循环还活着"被误判成"已停摆"：
	/// 后台线程会去抢换曲，与主线程的曲终处理并行（闩锁用 Interlocked 保证不会双换，
	/// 但 LoadMidiFile / 配置重放 / 媒体状态推送会与前台同时跑）。时间戳只增不减，
	/// 陈旧读永远偏"更旧"，方向上就是往误判停摆那一侧倒。
	/// </summary>
	private long _lastProcessTicks;
	/// <summary>主循环判定为停摆的阈值（秒）。大于常见的主线程卡顿，避免误判成后台</summary>
	private const double MainLoopStaleSec = 1.5;
	/// <summary>后台轮询间隔（毫秒）</summary>
	private const int BgAdvancePollMs = 200;

	private Thread _bgAdvanceThread;
	private volatile bool _bgAdvanceStop;
	/// <summary>后台线程已完成换曲、待主循环回来通知 GDScript 对账显示（跨线程可见）</summary>
	private volatile bool _bgAdvancePending;

	/// <summary>
	/// 后台线程要用的 ChartDb 引用：节点/场景树只应主线程访问，故在 _Process 里缓存，
	/// 后台线程只拿它做纯数据读取（SQLite 元数据），不自己 GetNodeOrNull。
	///
	/// volatile：主线程写、后台线程读。陈旧读只可能是启动初期的 null（ChartDb 是 autoload，
	/// 身份永不变），而 null 会让后台换曲拿不到标题 → 媒体状态文件干脆不写，
	/// 表现就是"熄屏切歌后通知栏不更新"。一个关键字消除这种偶发，值。
	/// </summary>
	private volatile ChartDb _chartDbCached;

	/// <summary>_Process 每帧调用：刷新主循环活性时间戳</summary>
	/// <summary>看门狗阈值：每轮轮询 200ms，累计这么多次"回调数没变"就判设备已死（≈3s）</summary>
	private const int BgStallTicksForRecover = 15;
	/// <summary>已交棒给回调的 key（后台线程私有）：避免每轮重复解析同一首</summary>
	private string _handoffPreparedKey = "";
	private string[] _bgSnapshotSeenKeys;   // 上次见过的快照数组（引用比较即可判定"主线程是否重发过"）
	private int _bgLastCallbackCount = -1;
	private int _bgStallTicks = 0;



	/// <summary>
	/// 全局播放配置（默认MIDI音量 / 系统时钟 / 人声同步阈值），由显示侧推送后缓存在这里，
	/// 供 C# 换曲（含后台线程）与合成器重建使用。
	///
	/// 【为什么是"推送"而不是 C# 自己去读】ConfigManager 是 GDScript 懒创建单例，
	/// 只 `add_to_group("singletons")`、**从不加入场景树**（见 Utilities/ConfigManager.gd 的
	/// static instance getter），因此 C# 侧 `GetNodeOrNull("/root/ConfigManager")` 恒为 null。
	/// 之前那套"每帧从 ConfigManager 读并缓存"的实现**从未生效**，后果是三项设置静默失效：
	///   - 默认MIDI音量：永远回退 0.5，设置页改了没用；
	///   - 系统时钟 use_system_stopwatch：永远是关闭（配置默认值其实是开启，
	///     而它是低性能设备上缓解判定滞后的手段）；
	///   - 人声同步阈值：配置里的值从不应用。
	/// 改为由显示侧显式推送纯标量后：C# 不依赖场景树、不需要跨语言轮询，
	/// 后台换曲线程也能安全读取（这些字段是 volatile）。
	/// </summary>
	public void set_global_playback_config(double defaultMidiVolume, bool useSystemStopwatch, double syncThresholdMs,
		double defaultVocalVolume = 50.0)
	{
		// 兼容旧版 0-100 存值（与 GDScript 侧 get_effective_midi_volume 同规则）
		double vol = defaultMidiVolume > 1.0 ? defaultMidiVolume / 100.0 : defaultMidiVolume;
		if (!double.IsNaN(vol))
		{
			_cachedDefaultMidiVolume = (float)Math.Clamp(vol, 0.0, 1.0);
		}

		// 人声全局默认：兼容 0-100 百分数与 dB 两种历史存值（<=0 视为 dB）
		double vv = defaultVocalVolume;
		if (vv > 1.0) { vv /= 100.0; }
		else if (vv <= 0.0) { vv = Mathf.DbToLinear((float)vv); }
		if (!double.IsNaN(vv))
		{
			_cachedDefaultVocalLinear = (float)Math.Clamp(vv, 0.0, 1.0);
		}

		// 系统时钟模式切换会重写 sequencer 的时钟基准并与音频回调互斥，
		// 只能主线程做；非主线程调用（不该发生）时只更新缓存值，等下次前台应用。
		if (useSystemStopwatch != _cachedUseSystemStopwatch)
		{
			_cachedUseSystemStopwatch = useSystemStopwatch;
			if (ThreadSafeLog.IsMainThread)
			{
				set_use_system_stopwatch(useSystemStopwatch);
			}
		}

		int thr = (int)Math.Clamp(syncThresholdMs, 1.0, 100000.0);
		if (thr != _lastAppliedSyncThreshold)
		{
			_lastAppliedSyncThreshold = thr;
			set_sync_threshold(thr);
		}
	}

	private int _lastAppliedSyncThreshold = -1;

	/// <summary>
	/// 默认MIDI音量（0-1）。由 set_global_playback_config 推送后缓存，供 C# 换曲
	/// （含后台线程）解析"未显式配置音量的曲目"时使用。
	///
	/// 【为什么不由 C# 自己读配置】见 set_global_playback_config 的说明：
	/// ConfigManager 不入场景树，C# 按节点路径取不到它。另外 GDScript 解释器本身不保证线程安全
	/// （gdscript.cpp 的实例化路径带 "@TODO make thread safe"），后台线程更不该去调它。
	/// volatile：主线程推送、后台换曲线程读取。
	/// </summary>
	private volatile float _cachedDefaultMidiVolume = 0.5f;
	/// <summary>人声全局默认（线性 0-1），由 set_global_playback_config 推送</summary>
	private volatile float _cachedDefaultVocalLinear = 1.0f;


	private void StartBackgroundAdvanceThread()
	{
		if (_bgAdvanceThread != null)
		{
			return;
		}
		_bgAdvanceStop = false;   // 允许重启（_ExitTree 会置位并 join 后清空引用）
		_bgAdvanceThread = new Thread(BackgroundAdvanceLoop)
		{
			IsBackground = true,
			Name = "MidiBgAdvance",
		};
		_bgAdvanceThread.Start();
		ThreadSafeLog.Print("[MeltySynthPlayer] background advance thread started");
	}

	/// <summary>
	/// 请求后台换曲线程退出并 join。返回 true 表示**确认已停止**（或本来就没起过）；
	/// false 表示有界等待超时，线程可能仍在跑 —— 调用方（_ExitTree）据此决定能否安全清空
	/// 共享字段：置 null 会让在跑的线程裸读变 NRE，故超时就宁可留着引用。
	/// </summary>
	private bool StopBackgroundAdvanceThread()
	{
		_bgAdvanceStop = true;
		var t = _bgAdvanceThread;
		_bgAdvanceThread = null;
		if (t == null)
		{
			return true;
		}
		// 必须 join：紧接着 _ExitTree 就会 Dispose 音频桥并把 _sequencer/_synth 置 null，
		// 而后台线程可能正卡在 LoadMidiFile / apply_chart_audio_config / 写 media_state 里 ——
		// 不 join 就会在已释放对象上继续跑（退出期 NRE），Godot 也会报
		// "A Thread object is being destroyed without its completion having been realized"。
		// 有界等待：真卡在系统调用上时，宁可留下一条错误日志也不要挂死退出流程。
		try
		{
			if (!t.Join(1500))
			{
				ThreadSafeLog.PrintErr("[MeltySynthPlayer] background advance thread did not stop within 1500ms");
				return false;
			}
		}
		catch (Exception e)
		{
			ThreadSafeLog.PrintErr($"[MeltySynthPlayer] background advance thread join failed: {e.Message}");
			return false;
		}
		return true;
	}

	/// <summary>后台轮询：仅当主循环停摆且音频回调报过回绕时，接管"曲终→下一首"</summary>
	/// <summary>等待原因去重日志：只在原因变化时打一条，避免每 200ms 刷屏。</summary>
	private int _bgLastSkipReason = -1;
	private int _bgHeartbeat = 0;


	private void BackgroundAdvanceLoop()
	{
		while (!_bgAdvanceStop)
		{
			Thread.Sleep(BgAdvancePollMs);
			try
			{
				// 本线程只剩一件事：音频设备存活看门狗（换曲已全部由主线程负责）。
				if (!(_audioOutput is MiniaudioAudioOutputBridge))
				{
					continue;
				}
				if (!playing)
				{
					continue;
				}
				// 【音频存活看门狗】设备可能被系统停掉而 transport 仍是 playing（音频打断 / 输出切换 /
				// 上一次换曲起播失败）→ 静音但"进度条还在走"。深后台时主线程不跑，自愈只能在这里做，
				// 且只做纯原生操作：Play()（幂等、不阻塞）。
				if (!_paused)
				{
					int cb = (_audioOutput as MiniaudioAudioOutputBridge)?.PerfTotalCallbacks ?? -1;
					if (cb >= 0 && cb == _bgLastCallbackCount)
					{
						if (++_bgStallTicks >= BgStallTicksForRecover)
						{
							_bgStallTicks = 0;
							var maStall = _audioOutput as MiniaudioAudioOutputBridge;
							if (maStall != null && !maStall.IsPlaying)
							{
								ThreadSafeLog.Print("[MeltySynthPlayer] bg watchdog: device stopped while transport playing; restarting it");
								maStall.Play();
							}
						}
					}
					else
					{
						_bgLastCallbackCount = cb;
						_bgStallTicks = 0;
					}
				}
			}
			catch (ThreadInterruptedException)
			{
				break;
			}
			catch (Exception e)
			{
				ThreadSafeLog.PrintErr($"[MeltySynthPlayer] bg advance error: {e.Message}");
			}
		}
	}



	/// <summary>media_state.json 的发布版本号（每次发布自增），供 Java 侧判定换歌</summary>
	private static long _mediaStateVersionCounter;

	/// <summary>JSON 字符串值转义（与 Java 侧 extractJsonString 的解析约定对称）</summary>
	private static string EscapeJsonString(string s)
	{
		return s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n");
	}

	/// <summary>
	/// 取曲目显示名，字段与 GDScript 侧（SystemMediaSession._build_metadata）严格一致：
	/// 优先 song_name（歌名），空则回退 name（谱面名）。
	/// 只用 name 会让"后台换曲写进卡片的歌名"和"seek/前台推送的歌名"不一样。
	/// </summary>
	private static string ResolveChartTitle(ChartDb db, string key)
	{
		if (db == null)
		{
			return "";
		}
		// 纯 C# 字段读取：可能与后台换曲线程同处一条路径，不能构建 Godot Dictionary
		var songName = db.GetChartFieldPlain(key, "song_name");
		if (!string.IsNullOrEmpty(songName))
		{
			return songName;
		}
		return db.GetChartFieldPlain(key, "name");
	}

	/// <summary>
	/// 按 ChartDb 元数据解析谱面 MIDI 文件路径（后台换曲线程用）。
	/// 与前台 ResolveMidiPath 同源：先把 ChartDb 的引擎风格 path 换算成原生路径
	/// （主线程缓存的前缀，任意线程安全），再用 FileExistsSafe（绝对路径走 System.IO，
	/// 不碰 Godot 文件 API 的全局锁）。
	/// </summary>
	private string ResolveMidiPathBg(ChartDb db, string key)
	{
		var folder = db.GetFolderPath(key);
		if (string.IsNullOrEmpty(folder))
		{
			return "";
		}
		folder = GlobalizeNativePath(folder);
		var candidates = new System.Collections.Generic.List<string>
		{
			"song.mid",
			key + ".mid",
		};
		// 旧命名：FileSystemManager 用 folder_name 的首段（"_" 之前）作 chart_id，
		// 谱面文件即 <chart_id>.mid。与前台 _locate_midi_file 保持一致。
		int sep = key.IndexOf('_');
		if (sep > 0)
		{
			candidates.Add(key.Substring(0, sep) + ".mid");
		}
		// 纯 C# 字段读取（不构建 Godot Dictionary）：后台线程不能碰 Godot 容器
		foreach (var field in new[] { "_id", "file_hash", "hash" })
		{
			var s = db.GetChartFieldPlain(key, field);
			if (!string.IsNullOrEmpty(s))
			{
				candidates.Add(s + ".mid");
			}
		}
		foreach (var name in candidates)
		{
			var p = folder.PathJoin(name);
			// 后台线程：绝对路径走 System.IO（不碰 Godot 文件 API 的全局锁）；
			// 落到 res:// 时 FileExistsSafe 只在主线程回退引擎，后台一律安全返回 false。
			if (FileExistsSafe(p))
			{
				return p;
			}
		}
		return "";
	}

	/// <summary>
	/// user:// / res:// 转原生路径 —— 实现见 MeltySynthPlayer.cs 的 GlobalizeNativePath
	/// （只用主线程缓存的前缀做字符串拼接，后台线程调用亦安全）。
	/// </summary>
}
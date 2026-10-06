using Godot;
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
///   - 后台（主循环停摆）：本文件的线程取走同一标志 → 在 C# 侧加载并起播下一首（纯音频，
///     不做音符显示/轨道配置），回前台由 GDScript reconcile_current_song() 补齐并定位。
///
/// 判定"主循环是否存活"用 _Process 刷新的时间戳：熄屏后它很快变陈旧。
/// </summary>
public partial class MeltySynthPlayer
{
	/// <summary>_Process 最近一次执行的时间戳（Stopwatch ticks）</summary>
	private long _lastProcessTicks;
	/// <summary>主循环判定为停摆的阈值（秒）。大于常见的主线程卡顿，避免误判成后台</summary>
	private const double MainLoopStaleSec = 1.5;
	/// <summary>后台轮询间隔（毫秒）</summary>
	private const int BgAdvancePollMs = 200;

	private Thread _bgAdvanceThread;
	private volatile bool _bgAdvanceStop;
	/// <summary>推进重入保护（0=空闲 1=进行中）</summary>
	private int _bgAdvancing;

	/// <summary>
	/// 后台线程要用的 ChartDb 引用：节点/场景树只应主线程访问，故在 _Process 里缓存，
	/// 后台线程只拿它做纯数据读取（SQLite 元数据），不自己 GetNodeOrNull。
	/// </summary>
	private ChartDb _chartDbCached;

	/// <summary>_Process 每帧调用：刷新主循环活性时间戳</summary>
	private void MarkMainLoopAlive()
	{
		_lastProcessTicks = Stopwatch.GetTimestamp();
	}

	/// <summary>_Process 每帧调用：把后台线程所需的主线程侧依赖缓存好</summary>
	private void MaintainBackgroundDeps()
	{
		if (_chartDbCached == null || !IsInstanceValid(_chartDbCached))
		{
			_chartDbCached = GetNodeOrNull<ChartDb>("/root/ChartDB");
		}
		CacheDefaultMidiVolume();
	}

	/// <summary>
	/// 全局 default_midi_volume（未配置时的回退值），由主线程读 GDScript 配置后缓存，
	/// 供后台换曲线程使用。
	///
	/// 【为什么不直接在后台调 ConfigManager】gdscript.cpp 里 GDScript 实例化路径带着
	/// "@TODO make thread safe"，解释器本身不保证线程安全；而 ConfigManager.get_value
	/// 在 key 缺失时会调 GLogger.warning，那条路径又要call_deferred——主循环后台停摆时
	/// 永远不执行，等于把日志调用变成静默挂起。故主线程读一次存缓存，后台只读标量。
	/// </summary>
	private float _cachedDefaultMidiVolume = 0.5f;

	private void CacheDefaultMidiVolume()
	{
		var cfg = GetNodeOrNull("/root/ConfigManager");
		if (cfg != null && cfg.HasMethod("get_float"))
		{
			var v = cfg.Call("get_float", "Gameplay", "default_midi_volume", 0.5).AsDouble();
			if (!double.IsNaN(v))
			{
				// 兼容旧版 0-100 存值（与 GDScript get_effective_midi_volume 同规则）
				_cachedDefaultMidiVolume = (float)(v > 1.0 ? v / 100.0 : v);
			}
		}
	}

	/// <summary>主循环是否存活。尚未起跑（时间戳为 0）时按存活处理，避免启动即抢占</summary>
	private bool IsMainLoopAlive()
	{
		if (_lastProcessTicks == 0L)
		{
			return true;
		}
		double elapsed = (Stopwatch.GetTimestamp() - _lastProcessTicks) / (double)Stopwatch.Frequency;
		return elapsed < MainLoopStaleSec;
	}

	private void StartBackgroundAdvanceThread()
	{
		if (_bgAdvanceThread != null)
		{
			return;
		}
		_bgAdvanceThread = new Thread(BackgroundAdvanceLoop)
		{
			IsBackground = true,
			Name = "MidiBgAdvance",
		};
		_bgAdvanceThread.Start();
		GD.Print("[MeltySynthPlayer] background advance thread started");
	}

	private void StopBackgroundAdvanceThread()
	{
		_bgAdvanceStop = true;
	}

	/// <summary>后台轮询：仅当主循环停摆且音频回调报过回绕时，接管"曲终→下一首"</summary>
	private void BackgroundAdvanceLoop()
	{
		while (!_bgAdvanceStop)
		{
			Thread.Sleep(BgAdvancePollMs);
			try
			{
				if (IsMainLoopAlive())
				{
					continue;   // 前台：标志留给 _Process → loop_wrapped，由 GDScript 推进
				}
				if (!(_audioOutput is MiniaudioAudioOutputBridge ma))
				{
					continue;
				}
				// 后台 _Process 不跑：回绕后人声重启（ApplyPendingVocalRestart）平时由 _Process 做，
				// 这里代劳。否则 loop 自回绕后第二遍只剩 MIDI、人声没了（听起来就是"只播 midi"）。
				ma.ApplyPendingVocalRestart();
				if (!playing)
				{
					continue;
				}
				// 只窥视不消费：换曲真正落地后才清标志。中途任何一步失败（DB 未就绪 / 文件缺失）
				// 都要把标志留着——主循环停摆期间无人接手，吃掉就表现为"曲终后一直原地循环"。
				if (!ma.HasLoopWrapDetected)
				{
					continue;   // 没回绕
				}
				if (Interlocked.CompareExchange(ref _bgAdvancing, 1, 0) != 0)
				{
					continue;   // 上一次还没跑完
				}
				try
				{
					if (AdvanceToNextInBackground())
					{
						ma.ConsumeLoopWrapDetected();
					}
				}
				finally
				{
					Interlocked.Exchange(ref _bgAdvancing, 0);
				}
			}
			catch (ThreadInterruptedException)
			{
				break;
			}
			catch (Exception e)
			{
				GD.PrintErr($"[MeltySynthPlayer] bg advance error: {e.Message}");
			}
		}
	}

	/// <summary>
	/// 音频侧接管换曲：解析下一首并起播（纯音频），索引推进由 MidiCore 权威记录。
	/// </summary>
	/// <returns>
	/// true 表示本次已处理完毕（换曲成功，或本就该原地循环），调用方据此消费回绕标志；
	/// false 表示前提未就绪而放弃，标志必须留给回前台后的 _Process 接手。
	/// </returns>
	private bool AdvanceToNextInBackground()
	{
		var core = MidiCore.Instance;
		if (core == null)
		{
			return false;
		}
		var key = core.ResolveAdvanceKey();
		if (string.IsNullOrEmpty(key))
		{
			// 单曲槽会话 / 单曲循环 / 列表为空：音频已自行循环，无需切歌。
			// 这里带上判定输入，便于区分"确实该原地循环"与"列表状态不对导致不切歌"
			GD.Print($"[MeltySynthPlayer] bg advance skipped: count={core.GetCount()} idx={core.GetIndex()} "
				+ $"repeat={core.GetRepeatMode()} single={core.IsSessionSingle()}");
			return true;
		}
		if (_sequencer == null)
		{
			return false;
		}
		var db = _chartDbCached;
		if (db == null || !db.IsOpen())
		{
			// 回前台后由 _Process 走常规范换曲路径；此处保留标志
			GD.Print("[MeltySynthPlayer] bg advance deferred: ChartDb not ready");
			return false;
		}
		var midiPath = ResolveMidiPathBg(db, key);
		if (string.IsNullOrEmpty(midiPath))
		{
			GD.PrintErr($"[MeltySynthPlayer] bg advance: midi path not found for key={key}");
			return true;   // 找不到文件：消费标志，避免每 200ms 重试刷屏
		}

		// 换曲整体放进「设备静止」窗口：LoadMidiFile 会重置 sequencer 与轨道状态，
		// 人声解码器也要整体替换，两者都与正在运行的音频回调冲突。
		// 前台 load_midi 同样是先 stop() 再 load_midi（见 MidiPlaybackManager.load_midi），
		// 这里复用同一时序：停设备 → 换 MIDI/人声/轨道配置 → 起播。
		// 必须在 LoadMidiFile 之前停：它会重置 sequencer/音量等并重设合成器引用。
		bool resumeDevice = _audioOutput.IsPlaying;
		if (resumeDevice)
		{
			// ma_device_stop 会等音频 worker 线程退出后才返回，回调彻底结束
			_audioOutput.Stop();
		}

		// 重活在锁外：LoadMidiFile 读文件 + 解析整个 SMF（与 SoundFont 后台加载同理）。
		// 它同时负责复位播放标志、清洁轨道/通道残留与回绕基准。
		var prevMidiFile = _midiFile;
		_file = midiPath;
		try
		{
			LoadMidiFile(midiPath);
			// 音源仍在异步构建时 LoadMidiFile 会直接返回（谱面没被替换）：此时若继续 Play
			// 会把旧曲从头重播，必须放弃并把标志留给回前台后的正规路径。
			if (_midiFile == null || _sequencer == null || ReferenceEquals(_midiFile, prevMidiFile))
			{
				GD.Print("[MeltySynthPlayer] bg advance deferred: midi load did not take effect");
				return false;
			}

			WithSynthLock(() =>
			{
				_sequencer.Play(_midiFile, loop);
				_sequencerStarted = true;
				ApplyInstrumentOverridesToSynth();
			});
			InvalidateJudgeClock();
			if (_audioOutput is MiniaudioAudioOutputBridge maWrap)
			{
				maWrap.ResetLoopWrapBaseline();
			}

			// 轨道音量/静音：LoadMidiFile 清过 _virtualChannelVolumes，
			// 不重设的话新曲会沿用不到任何轨道音量（音量全丢）或串用上一首的静音状态
			ApplyTrackConfigForBackgroundAdvance(db, key);

			// MIDI 主音量（复刻前台 apply_ui_midi_volume：线性值 ×8 增益转 dB，
			// 下限 -80；per-midi 未配置则用主线程缓存的全局默认）
			ApplyMidiVolumeForBackgroundAdvance(db, key);

			// 人声：换解码器必须在设备静止时做（详见 LoadVocalForBackgroundAdvance）
			LoadVocalForBackgroundAdvance(db, key);
		}
		finally
		{
			// 无论成败都要恢复设备，否则永久静音
			if (resumeDevice)
			{
				_audioOutput.Play();
			}
		}

		// 索引推进（C# 权威）；回前台由 GDScript 对账重建显示与轨道配置
		var idx = core.IndexOf(key);
		if (idx >= 0)
		{
			core.SetIndex(idx);
		}
		core.Save();
		// 后台换曲后把新曲元数据写给 Java 侧（通知区歌名/时长、进度条量程）。
		// 熄屏时 GDScript 无法下发 update_state，Java ticker 读不到就一直是旧歌信息。
		PublishMediaStateForAndroid(db, key);
		GD.Print($"[MeltySynthPlayer] background advanced to next song: {key}");
		return true;
	}

	/// <summary>
	/// 后台换曲后向 Android 通知区发布曲目元数据。
	/// 走文件契约而非跨语言调用：C# 没有公开的 Engine.GetSingleton 封装去调
	/// Java 插件，而主循环在后台挂起、GDScript 也发不了 update_state。
	/// 文件落在固定引导目录（不随玩家自定义存储根迁移），Java 侧按同一路径读取。
	/// 写入用临时文件 + 原子改名，避免 Java 读到半截JSON。
	/// </summary>
	private void PublishMediaStateForAndroid(ChartDb db, string key)
	{
		if (OS.GetName() != "Android")
		{
			return;
		}
		if (_midiFile == null)
		{
			return;
		}
		string title = ResolveChartTitle(db, key);
		if (string.IsNullOrEmpty(title))
		{
			return;
		}
		double durationMs = _midiFile.Length.TotalMilliseconds;
		if (double.IsNaN(durationMs) || durationMs <= 0.0)
		{
			return;
		}
		var info = db.GetChartJson(key);
		string album = info.Count > 0 && info.TryGetValue("album_name", out var av) ? av.AsString() : "";
		string coverPath = db.GetCoverPath(key);
		if (!string.IsNullOrEmpty(coverPath)
				&& (coverPath.StartsWith("user://") || coverPath.StartsWith("res://")))
		{
			coverPath = ProjectSettings.GlobalizePath(coverPath);
		}
		string dir = "/storage/emulated/0/Android/data/com.touhoumix.ce/files";
		string json = "{\"title\":\"" + EscapeJsonString(title)
			+ "\",\"album\":\"" + EscapeJsonString(album)
			+ "\",\"cover_path\":\"" + EscapeJsonString(coverPath)
			+ "\",\"duration_ms\":" + durationMs.ToString("F0")
			+ ",\"position_ms\":0}";
		string tmpPath = dir.PathJoin("media_state.json.tmp");
		string finalPath = dir.PathJoin("media_state.json");
		try
		{
			using var f = Godot.FileAccess.Open(tmpPath, Godot.FileAccess.ModeFlags.Write);
			if (f == null)
			{
				GD.PrintErr($"[MeltySynthPlayer] media state: cannot open {tmpPath}");
				return;
			}
			f.StoreString(json);
			f.Close();
			// 改名交付：改动不频繁，Java 侧以 mtime 判变更。改名失败时退回直接写正式文件
			// （Java 读半截文件会跳过并在下个 tick 重试，故非原子写也可接受）。
			var err = Godot.DirAccess.RenameAbsolute(tmpPath, finalPath);
			if (err != Godot.Error.Ok)
			{
				GD.PrintErr($"[MeltySynthPlayer] media state: rename failed {err}, writing in place");
				using var f2 = Godot.FileAccess.Open(finalPath, Godot.FileAccess.ModeFlags.Write);
				if (f2 == null)
				{
					GD.PrintErr($"[MeltySynthPlayer] media state: cannot open {finalPath}");
					return;
				}
				f2.StoreString(json);
				f2.Close();
			}
			GD.Print($"[MeltySynthPlayer] media state published: {title} ({durationMs:F0}ms)");
		}
		catch (Exception e)
		{
			GD.PrintErr($"[MeltySynthPlayer] media state write failed: {e.Message}");
		}
	}

	/// <summary>JSON 字符串值转义（与 Java 侧 extractJsonString 的解析约定对称）</summary>
	private static string EscapeJsonString(string s)
	{
		return s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n");
	}

	/// <summary>取谱面曲名（ChartDb 的 GetChartJson 已含 name 字段）</summary>
	private static string ResolveChartTitle(ChartDb db, string key)
	{
		var json = db.GetChartJson(key);
		return json.Count > 0 && json.TryGetValue("name", out var v) ? v.AsString() : "";
	}

	/// <summary>
	/// 后台换曲的轨道音量/静音恢复（对齐前台 apply_midi_runtime_config 中纯音频的部分）。
	/// 只碰 C# 侧的 ConcurrentDictionary 状态，线程安全。
	/// 配置从 MidiCore（权威）读，不再直连 ChartDb。
	/// </summary>
	private void ApplyTrackConfigForBackgroundAdvance(ChartDb db, string key)
	{
		var core = MidiCore.Instance;
		var cfg = core?.GetConfig(key);
		if (cfg == null || cfg.Count == 0)
		{
			return;
		}

		// 轨道-通道音量
		if (cfg.TryGetValue("track_channel_volume_config", out var volVar)
				&& volVar.VariantType == Variant.Type.Dictionary)
		{
			foreach (var trackEntry in volVar.AsGodotDictionary())
			{
				if (!TryParseTrackIndex(trackEntry.Key, out int trackIdx)
						|| trackEntry.Value.VariantType != Variant.Type.Dictionary)
				{
					continue;
				}
				foreach (var chanEntry in trackEntry.Value.AsGodotDictionary())
				{
					if (TryParseChannelIndex(chanEntry.Key, out int chan))
					{
						set_track_channel_volume(trackIdx, chan, (float)chanEntry.Value.AsDouble());
					}
				}
			}
		}

		// 轨道-通道静音（solo / 未启用通道在前台还会额外叠加运行时静音，
		// 那部分依赖 MidiData 的 selected/solo 状态，同样留给回前台 reconcile）
		if (cfg.TryGetValue("track_channel_mute_state", out var muteVar)
				&& muteVar.VariantType == Variant.Type.Dictionary)
		{
			foreach (var trackEntry in muteVar.AsGodotDictionary())
			{
				if (!TryParseTrackIndex(trackEntry.Key, out int trackIdx)
						|| trackEntry.Value.VariantType != Variant.Type.Dictionary)
				{
					continue;
				}
				foreach (var chanEntry in trackEntry.Value.AsGodotDictionary())
				{
					if (TryParseChannelIndex(chanEntry.Key, out int chan))
					{
						set_track_channel_mute(trackIdx, chan, chanEntry.Value.AsBool());
					}
				}
			}
		}
	}

	/// <summary>
	/// 后台换曲的 MIDI 主音量（复刻前台 apply_ui_midi_volume +
	/// get_effective_midi_volume：per-midi 显式值优先，未配置（<0，约定 -1）回退
	/// 主线程缓存的全局 default_midi_volume；UI 线性值 × 8 增益后转 dB，下限 -80）。
	/// </summary>
	private void ApplyMidiVolumeForBackgroundAdvance(ChartDb db, string key)
	{
		double vol = -1.0;
		var cfg = MidiCore.Instance?.GetConfig(key);
		if (cfg != null && cfg.TryGetValue("midi_volume", out var mv))
		{
			vol = mv.AsDouble();
		}
		if (vol < 0.0)
		{
			vol = _cachedDefaultMidiVolume;
		}
		if (double.IsNaN(vol))
		{
			return;
		}
		vol = Math.Clamp(vol, 0.0, 1.0);
		const double gain = 8.0;
		const double minDb = -80.0;
		set_volume_db((float)Math.Max(Mathf.LinearToDb(vol * gain), minDb));
	}

	/// <summary>runtime 配置的字典键可能是 int 或字符串（JSON 往返会转字符串），两种都认</summary>
	private static bool TryParseTrackIndex(Variant key, out int index)
	{
		if (key.VariantType == Variant.Type.Int)
		{
			index = key.AsInt32();
			return true;
		}
		return int.TryParse(key.AsString(), out index);
	}

	/// <summary>通道号同上（int / 字符串皆可）</summary>
	private static bool TryParseChannelIndex(Variant key, out int index)
	{
		if (key.VariantType == Variant.Type.Int)
		{
			index = key.AsInt32();
			return index >= 0 && index <= 15;
		}
		if (!int.TryParse(key.AsString(), out index))
		{
			return false;
		}
		return index >= 0 && index <= 15;
	}

	/// <summary>按 ChartDb 元数据解析谱面 MIDI 文件路径（复刻 GDScript _locate_midi_file 的命名规则）</summary>
	private static string ResolveMidiPathBg(ChartDb db, string key)
	{
		var folder = db.GetFolderPath(key);
		if (string.IsNullOrEmpty(folder))
		{
			return "";
		}
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
		var json = db.GetChartJson(key);
		if (json.Count > 0)
		{
			foreach (var field in new[] { "_id", "file_hash", "hash" })
			{
				if (json.TryGetValue(field, out var v))
				{
					var s = v.AsString();
					if (!string.IsNullOrEmpty(s))
					{
						candidates.Add(s + ".mid");
					}
				}
			}
		}
		foreach (var name in candidates)
		{
			var p = folder.PathJoin(name);
			if (Godot.FileAccess.FileExists(p))
			{
				return p;
			}
		}
		return "";
	}

	/// <summary>
	/// 后台换曲的人声处理：读取该曲的运行时配置（启用/路径/音量），加载并从头起播。
	///
	/// 【线程模型】调用方（AdvanceToNextInBackground）已把设备停掉、音频回调彻底退出，
	/// 故这里换解码器是安全的：ma_bridge_vocal_load 会先 ma_bridge_vocal_unload 释放
	/// vocalRing 并重置 vocalLoaded/vocalDecoderValid 等字段，而这些字段【不持 vocalLock】，
	/// 设备在播时直接换会与回调的 vocal_mix 争用同一批内存（use-after-free，
	/// 实测表现为 ErrUnsupported 或人声静默无声）。不能在本函数内再自行停/起播设备。
	///
	/// 【为什么忽略 vocal_offset_ms】后台没有主循环跑人声同步循环，无法等 MIDI 走到偏移点
	/// 再开播；直接从头播保证熄屏期间人声不缺失。回前台由 GDScript 对账到精确位置。
	/// </summary>
	private void LoadVocalForBackgroundAdvance(ChartDb db, string key)
	{
		if (!(_audioOutput is MiniaudioAudioOutputBridge ma))
		{
			return;
		}
		bool enabled = true;   // 未配置过 vocal_enabled 时默认跟随"是否有音频"（与 DataManager 一致）
		string path = "";
		float vol = _vocalVolumeLinear;
		double offsetMs = 0.0;
		var cfg = MidiCore.Instance?.GetConfig(key);
		if (cfg != null)
		{
			if (cfg.TryGetValue("vocal_enabled", out var ev))
			{
				enabled = ev.AsBool();
			}
			if (cfg.TryGetValue("vocal_file_path", out var pv))
			{
				path = pv.AsString();
			}
			if (cfg.TryGetValue("vocal_volume", out var vv))
			{
				vol = (float)vv.AsDouble();
			}
			if (cfg.TryGetValue("vocal_offset_ms", out var ov))
			{
				offsetMs = ov.AsDouble();
			}
		}
		// 存的人声路径可能已失效（谱面库搬家）：与前台 VocalTrackController.resolve_vocal_path
		// 同语义——校验存在性，失效则回退到谱面元数据的 audio_path，而不是直接放弃。
		if (!enabled || string.IsNullOrEmpty(path) || !Godot.FileAccess.FileExists(path))
		{
			path = db.GetAudioPath(key);
			enabled = !string.IsNullOrEmpty(path) && Godot.FileAccess.FileExists(path);
		}
		if (!enabled)
		{
			ma.UnloadVocal();
			return;
		}
		// miniaudio 的 C 解码器只认原生文件系统路径（前台 _globalize_vocal_path 的等价物）
		path = GlobalizeVocalPath(path);

		// 调用方已把设备停在静音窗口内（见 AdvanceToNextInBackground），
		// 此处可直接换解码器：音频回调已退出，vocal_mix 不再并发读写 vocalRing。
		if (!ma.LoadVocalFile(path))
		{
			GD.PrintErr($"[MeltySynthPlayer] bg advance: vocal load failed: {path}");
			return;
		}
		ma.SetVocalVolume(vol);
		ma.SeekVocal(0.0);
		// 偏移门控：MIDI 未走到 vocal_offset_ms 时人声保持静音，由音频回调放行。
		// 必须在 PlayVocal 之前设置——门控未放行时它会自行起播。
		ma.SetVocalOffsetMs(offsetMs);
		ma.ResetVocalOffsetGate();
		if (offsetMs <= 0.0)
		{
			ma.PlayVocal();
		}
		GD.Print($"[MeltySynthPlayer] bg advance vocal started: {path} (offset={offsetMs:F0}ms)");
	}

	/// <summary>user:// / res:// 转原生路径（复刻 GDScript _globalize_vocal_path）</summary>
	private static string GlobalizeVocalPath(string path)
	{
		if (path.StartsWith("user://") || path.StartsWith("res://"))
		{
			return ProjectSettings.GlobalizePath(path);
		}
		return path;
	}
}
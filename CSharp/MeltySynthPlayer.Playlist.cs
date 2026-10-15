using Godot;
using System;
using System.Collections.Generic;

/// <summary>
/// MeltySynthPlayer 的「用户播放列表编排」部分（partial class）。
/// keys/索引/模式/落盘的权威在 MidiCore；这里持有随机/顺序两份排列快照与编辑算法，
/// 并对外暴露 UI 直调的门面（原 GDScript MidiPlaybackManager 的列表方法）。
/// </summary>
public partial class MeltySynthPlayer
{
	private readonly List<string> _seqOrder = new();
	private readonly List<string> _shufOrder = new();

	/// <summary>
	/// 当前会话是否「文件级循环」（曲终原地重播）。
	///
	/// 这个区分在 55b11058 里是 `start_session(..., loop_file)` 参数，三个消费方语义各不相同：
	///   - 打歌页 PlayView：**false**（旧注释："关闭文件级循环"）→ 曲终就是曲终，交给结算流程；
	///   - 音轨页 TrackView：**true**（旧注释："+ 文件级循环"）→ 试听时单曲循环；
	///   - 播放器页：循环（旧实现用 set_loop(true)），列表多首时仍由列表前进接管。
	/// 重构把参数删掉后只剩一种行为（单曲槽一律原地重播），于是**打完一首歌会在结算界面里
	/// 从头再放一遍**（PlayView 在 midi_finished 回调里调的 stop() 还会被重启分支覆盖）。
	/// 默认 true：保持 TrackView / 播放器页原有行为，只有 PlayView 显式传 false。
	/// </summary>
	private volatile bool _sessionLoopFile = true;

	private static string KeyOfVariant(Variant m)
	{
		if (m.VariantType == Variant.Type.Object)
		{
			var o = m.AsGodotObject();
			if (o == null)
			{
				return "";
			}
			var ck = o.Get("chart_key").AsString();
			return !string.IsNullOrEmpty(ck) ? ck : o.Get("id").AsString();
		}
		return m.AsString();
	}

	private Godot.Collections.Array KeysOfItems(Godot.Collections.Array items)
	{
		var outArr = new Godot.Collections.Array();
		if (items == null)
		{
			return outArr;
		}
		foreach (var it in items)
		{
			var k = KeyOfVariant(it);
			if (!string.IsNullOrEmpty(k))
			{
				outArr.Add(k);
			}
		}
		return outArr;
	}

	private void MarkUserEdited()
	{
		var core = MidiCore.Instance;
		core?.SetPersistEnabled(true);
		core?.SetSourceFavId("");
		EmitSignal(SignalName.playlist_user_edited);
	}

	// ===== 会话 =====

	public void set_playlist_keys(Godot.Collections.Array keys, int startIndex = 0)
	{
		_seqOrder.Clear();
		_shufOrder.Clear();
		MidiCore.Instance?.SetKeys(keys, startIndex);
		EmitSignal(SignalName.playlist_changed);
	}

	/// <summary>开始一次播放会话。
	///
	/// 【新代码请用下面的意图方法，不要直接调本方法】本方法把"哪种会话"编码成两个位置布尔
	/// （`persist` / `loopFile`），调用方必须知道第几个参数是什么；而 `loopFile` 恰好决定
	/// "曲终干什么"，传错就是结算页里从头再放一遍。意图方法把语义写进方法名，页面不必再数参数。
	/// 保留本方法仅为过渡期兼容。</summary>
	public void start_session(Godot.Collections.Array items, int startIndex = 0, bool persist = true, bool loopFile = true)
	{
		var keys = KeysOfItems(items);
		var core = MidiCore.Instance;
		_sessionLoopFile = loopFile;
		if (persist)
		{
			core?.SetPersistEnabled(true);
			core?.SetSessionSingle(false);
			set_playlist_keys(keys, startIndex);
			return;
		}
		core?.SetPersistEnabled(false);
		core?.SetSessionSingle(true);
		core?.SetSessionKey(keys.Count > 0 ? keys[0].AsString() : "");
	}

	// ===== 意图化的会话装配 =====
	//
	// 三个消费方的真正区别只有两维：写不写用户列表 A（persist）、曲终要不要文件级循环（loopFile）。
	// 组合本来是 4 种，业务上只有 3 种，故收敛成三个方法名：

	/// <summary>打歌一局：写单曲槽 B（不落盘、不碰用户列表 A），曲终即曲终、不循环。
	/// 曲终交给结算流程（非循环会话会 latch end-of-sequence）。</summary>
	public void start_performance(Godot.Collections.Array items, int startIndex = 0)
		=> start_session(items, startIndex, persist: false, loopFile: false);

	/// <summary>音轨试听：写单曲槽 B（不落盘），文件级循环（试听时单曲原地重播）。</summary>
	public void start_preview(Godot.Collections.Array items, int startIndex = 0)
		=> start_session(items, startIndex, persist: false, loopFile: true);

	/// <summary>播放器页会话：用户列表 A 生效（可落盘/可推进），文件级循环；
	/// 列表多于一首时仍由列表前进接管。</summary>
	public void start_player_session(Godot.Collections.Array items, int startIndex = 0)
		=> start_session(items, startIndex, persist: true, loopFile: true);

	public void start_session_keys(Godot.Collections.Array keys, int startIndex = 0)
	{
		MidiCore.Instance?.SetPersistEnabled(true);
		MidiCore.Instance?.SetSessionSingle(false);
		set_playlist_keys(keys, startIndex);
	}

	public bool adopt_single_into_playlist()
	{
		var core = MidiCore.Instance;
		if (core == null || core.GetCount() > 0)
		{
			return false;
		}
		var k = core.GetSessionKey();
		if (string.IsNullOrEmpty(k))
		{
			return false;
		}
		core.SetSessionSingle(false);
		var arr = new Godot.Collections.Array { k };
		set_playlist_keys(arr, 0);
		return true;
	}

	public void end_user_session()
	{
		var core = MidiCore.Instance;
		if (core == null || core.IsSessionSingle() || string.IsNullOrEmpty(_currentKey))
		{
			return;
		}
		core.SetSessionSingle(true);
		core.SetSessionKey(_currentKey);
		core.SetPersistEnabled(false);
	}

	public void begin_user_session()
	{
		var core = MidiCore.Instance;
		if (core == null || core.GetCount() == 0)
		{
			return;
		}
		core.SetPersistEnabled(true);
		core.SetSessionSingle(false);
		// 播放器页 = 文件级循环会话（列表多首时仍由列表前进接管）
		_sessionLoopFile = true;
	}

	public bool enter_user_playlist_from_head()
	{
		var core = MidiCore.Instance;
		if (core == null || core.GetCount() == 0)
		{
			return false;
		}
		core.SetPersistEnabled(true);
		core.SetSessionSingle(false);
		_sessionLoopFile = true;   // 播放器页会话：文件级循环
		if (core.GetRepeatMode() == MidiCore.REPEAT_SHUFFLE && _seqOrder.Count == 0)
		{
			_seqOrder.Clear();
			foreach (var k in core.GetKeys())
			{
				_seqOrder.Add(k);
			}
		}
		play_index(0);
		return true;
	}

	public void align_index_to_current()
	{
		if (string.IsNullOrEmpty(_currentKey))
		{
			return;
		}
		var core = MidiCore.Instance;
		int i = core != null ? core.IndexOf(_currentKey) : -1;
		if (i >= 0)
		{
			core.SetIndex(i);
		}
	}

	// ===== 编辑 =====

	public void append_to_playlist(Godot.Collections.Array items)
	{
		MarkUserEdited();
		var core = MidiCore.Instance;
		// 加之前列表是空的（典型：清空列表后又加歌）→ 加完直接起播新歌。
		// 没有"无曲可播"的界面状态：清空列表只清 A、不停当前曲，此时加歌若不起播，
		// 面板显示新歌、放的还是被清掉的那首，媒体卡片与播放器页长期和实际内容不一致。
		bool fromEmpty = core != null && core.GetCount() == 0;
		var keys = new List<string>();
		foreach (var it in items)
		{
			var k = KeyOfVariant(it);
			if (!string.IsNullOrEmpty(k)) keys.Add(k);
		}
		core?.AppendKeys(keys);
		core?.SetPersistEnabled(true);
		EmitSignal(SignalName.playlist_changed);
		if (fromEmpty && core != null && core.GetCount() > 0)
		{
			// 从空列表长出来的第一首必在 0 位；批量加入时播最先加入的那首
			play_index(0);
		}
	}

	public bool insert_next_in_playlist(Variant data)
	{
		var k = KeyOfVariant(data);
		var core = MidiCore.Instance;
		if (string.IsNullOrEmpty(k) || core == null || core.Has(k))
		{
			return false;
		}
		MarkUserEdited();
		bool fromEmpty = core.GetCount() == 0;
		core.InsertAt(core.GetIndex() + 1, k);
		EmitSignal(SignalName.playlist_changed);
		// 空列表（清空列表后插第一首）：索引为 -1，新歌落 0 位，直接起播——同 append
		if (fromEmpty && core.GetCount() > 0)
		{
			play_index(0);
		}
		return true;
	}

	public void remove_from_playlist(int index)
	{
		var core = MidiCore.Instance;
		if (core == null || index < 0 || index >= core.GetCount())
		{
			return;
		}
		MarkUserEdited();
		string removedKey = core.GetKeyAt(index);
		bool wasCurrent = index == core.GetIndex();
		_seqOrder.Remove(removedKey);
		_shufOrder.Remove(removedKey);
		core.RemoveAt(index);
		EmitSignal(SignalName.playlist_changed);
		if (wasCurrent)
		{
			if (core.GetCount() == 0)
			{
				stop();
			}
			else
			{
				play_index(core.GetIndex());
			}
		}
		else
		{
			EmitSignal(SignalName.playlist_index_changed, core.GetIndex());
		}
	}

	public void move_in_playlist(int fromIdx, int toIdx)
	{
		var core = MidiCore.Instance;
		if (core == null || fromIdx < 0 || fromIdx >= core.GetCount())
		{
			return;
		}
		if (fromIdx == Mathf.Clamp(toIdx, 0, core.GetCount() - 1))
		{
			return;
		}
		MarkUserEdited();
		core.Move(fromIdx, toIdx);
		if (core.GetRepeatMode() == MidiCore.REPEAT_SHUFFLE)
		{
			_shufOrder.Clear();
			foreach (var k in core.GetKeys())
			{
				_shufOrder.Add(k);
			}
		}
		EmitSignal(SignalName.playlist_changed);
		EmitSignal(SignalName.playlist_index_changed, core.GetIndex());
	}

	public bool playlist_has_midi(Variant m) => MidiCore.Instance?.Has(KeyOfVariant(m)) ?? false;

	public bool play_by_key(string chartKey)
	{
		if (string.IsNullOrEmpty(chartKey))
		{
			return false;
		}
		var core = MidiCore.Instance;
		if (core == null)
		{
			return false;
		}
		int i = core.IndexOf(chartKey);
		if (i < 0)
		{
			var db = GetNodeOrNull<ChartDb>("/root/ChartDB");
			var resolved = db != null ? db.LookupChartKey(chartKey) : "";
			if (!string.IsNullOrEmpty(resolved))
			{
				i = core.IndexOf(resolved);
			}
		}
		if (i < 0)
		{
			return false;
		}
		play_index(i);
		return true;
	}

	// ===== 播放模式 / 排列 =====

	/// <summary>把列表排列对齐「当前播放模式」。随机 → 打乱；非随机不动
	/// （盘里的顺序就是顺序排列）。
	///
	/// **读回磁盘列表后必须调一次**：盘里存的是"上次的排列 + 上次的模式"，两者可能不一致
	/// （模式记的是随机、盘里那版却是顺序排列）。不补这一步，面板/播放顺序会停在顺序排列，
	/// 用户得手动把模式切走再切回来（那一步会走 set_repeat_mode → BecomeShuffled）才对得上。
	///
	/// _seqOrder/_shufOrder 是本次运行的排列快照：非空表示本次运行已经排过，不重复打乱
	/// （同一进程内多次进页面不会每次都换顺序）。
	///
	/// 索引对齐对**所有模式**生效（曾经的 bug：对齐只写在随机分支里，非随机模式
	/// early-return，索引没人管）：无曲目在放、或当前曲不在歌单时归队首——与 EnsureLoaded
	/// 的"读回后一律从第一首开始"是同一条契约；有曲目在放时把 index 指到它在歌单里的位置，
	/// 随后 play_next/play_previous 从该位置推进，才是"下一首/上一首"的正确语义。
	/// 随机分支内部（BecomeShuffled/ApplyArrangement → SetArrangement）已按同样规则设过
	/// 索引，末尾这次对齐对随机模式是幂等的（值相同），行为零变化。</summary>
	public void ApplyRepeatModeArrangement()
	{
		var core = MidiCore.Instance;
		if (core == null || core.GetCount() == 0)
		{
			return;
		}
		// 排列仍只由随机模式做；但索引对齐不能再像过去那样随非随机模式一起 early-return——
		// EnsureLoaded 读盘后按契约把 index 置 0，冷启动从 TrackView 试听一首在歌单里
		// （位置 k）的歌后按"下一首"，play_next 的 advance 分支会从 index=0 取，播出
		// keys[1] 而非 keys[k+1]（"上一首"更是回绕到末首）。
		if (core.GetRepeatMode() == MidiCore.REPEAT_SHUFFLE)
		{
			if (_seqOrder.Count == 0)
			{
				// 记下"切回顺序时该还原成什么"：此刻盘里那版就是对照基准
				foreach (var k in core.GetKeys())
				{
					_seqOrder.Add(k);
				}
			}
			if (_shufOrder.Count == 0)
			{
				BecomeShuffled();
			}
			else
			{
				ApplyArrangement(_shufOrder);
			}
		}
		// 结束后索引归位（所有模式统一）：正在播放的曲目在歌单里 → index 指到它的位置，
		// 随后 play_next/play_previous 从该位置前进/后退，才是"下一首"的正确语义；
		// 不在（含冷启动什么都没在放）→ 回队首——与 EnsureLoaded 的"读回后一律从
		// 第一首开始"是同一条契约（随机模式下即打乱后的首项，上一轮已修，不回归）。
		int i = core.IndexOf(_currentKey);
		core.SetIndex(i >= 0 ? i : 0);
	}

	public void set_repeat_mode(int mode)
	{
		var core = MidiCore.Instance;
		if (core == null)
		{
			return;
		}
		int was = core.GetRepeatMode();
		if (mode == was)
		{
			return;
		}
		core.SetRepeatMode(mode);
		if (core.GetCount() == 0)
		{
			// 空列表也要广播：模式本身已由 MidiCore.SetRepeatMode → Save() 落盘到播放列表 meta
			EmitSignal(SignalName.repeat_mode_changed, mode);
			return;
		}
		if (mode == MidiCore.REPEAT_SHUFFLE)
		{
			_seqOrder.Clear();
			foreach (var k in core.GetKeys())
			{
				_seqOrder.Add(k);
			}
			if (_shufOrder.Count == 0)
			{
				BecomeShuffled();
			}
			else
			{
				ApplyArrangement(_shufOrder);
			}
		}
		else if (was == MidiCore.REPEAT_SHUFFLE)
		{
			ApplyArrangement(_seqOrder);
		}
		EmitSignal(SignalName.repeat_mode_changed, mode);
		EmitSignal(SignalName.playlist_changed);
	}

	public bool shuffle_playlist_from_head()
	{
		var core = MidiCore.Instance;
		if (core == null || core.GetCount() == 0)
		{
			return false;
		}
		BecomeShuffled();
		core.SetIndex(0);
		play_index(0);
		EmitSignal(SignalName.playlist_changed);
		return true;
	}

	private void BecomeShuffled()
	{
		var core = MidiCore.Instance;
		if (core == null)
		{
			return;
		}
		// "要保留的当前曲"只认**真正在放的那首**（_currentKey）。不能拿 core.GetCurrentKey()
		// （歌单 index 处的 key）凑数：读盘后 index 恒为 0，那只是 keys[0] 占位符——冷启动、
		// 或从 TrackView 试听一首不在用户歌单里的歌时，把它当"当前曲"会把队首项挪到洗牌后的
		// 中段并设 index，随后 play_next 的无基准分支就播放那一首，而不是打乱后的队首。
		// 播放中切随机模式时 _currentKey 就在歌单里，保留定位的语义不变。
		string cur = _currentKey;
		var keys = new List<string>();
		foreach (var k in core.GetKeys())
		{
			keys.Add(k);
		}
		var rng = new Random((int)(Time.GetTicksUsec() ^ (ulong)GetInstanceId()));
		for (int i = keys.Count - 1; i > 0; i--)
		{
			int j = rng.Next(i + 1);
			(keys[i], keys[j]) = (keys[j], keys[i]);
		}
		_shufOrder.Clear();
		_shufOrder.AddRange(keys);
		int idx = keys.IndexOf(cur);
		var arr = new Godot.Collections.Array();
		foreach (var k in keys)
		{
			arr.Add(k);
		}
		// SetArrangement：打乱是排列不是内容——不落盘，持久化歌单保持规范序
		core.SetArrangement(arr, idx >= 0 ? idx : 0);
	}

	private void ApplyArrangement(List<string> arrangement)
	{
		var core = MidiCore.Instance;
		if (core == null)
		{
			return;
		}
		// 同 BecomeShuffled：只认真正在放的曲目（_currentKey）；歌单 index 处的 key 在读盘后
		// 只是 keys[0] 占位符，不能拿来当"当前曲"定位。
		string cur = _currentKey;
		var have = new HashSet<string>();
		foreach (var k in arrangement)
		{
			if (!string.IsNullOrEmpty(k))
			{
				have.Add(k);
			}
		}
		var arranged = new List<string>();
		foreach (var k in arrangement)
		{
			if (have.Contains(k))
			{
				arranged.Add(k);
			}
		}
		foreach (var k in core.GetKeys())
		{
			if (!have.Contains(k))
			{
				arranged.Add(k);
			}
		}
		var arr = new Godot.Collections.Array();
		foreach (var k in arranged)
		{
			arr.Add(k);
		}
		int idx = arranged.IndexOf(cur);
		// 同 BecomeShuffled：排列提交不落盘
		core.SetArrangement(arr, idx >= 0 ? idx : 0);
	}
}

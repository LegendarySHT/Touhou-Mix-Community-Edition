using Godot;
using System;
using System.Collections.Generic;

/// <summary>
/// MidiCore — 播放列表的 C# 权威核心（autoload，参考 ChartDb 注册方式）。
///
/// 归属划分：Godot 只做显示与顺序编辑（拖拽/删除/追加/打乱等算法在 GDScript 里算完后
/// 经 SetKeys 推过来），这里负责「持有 keys 顺序 + 当前索引 + 模式 + 落盘 + 剪枝」，
/// 以及「下一首是谁」的决策——深度后台（Godot 主循环挂起）时由音频侧直接来这里问，
/// 不依赖任何 GDScript 回调。
///
/// 只存 chart_key（字符串），不存 MidiData：列表本体不水合，内存不随歌单长度膨胀。
/// GDScript 侧 MidiPlaybackManager 只保留自己的信号 API，方法调用后自行 emit，
/// 因此这里不声明 Godot 信号。
///
/// 【不要加 [GlobalClass]】autoload 键名与本类同名（MidiCore）：一旦注册为全局类，
/// GDScript 里的 `MidiCore` 会优先解析成"类"而不是 autoload 实例，调用实例方法会报
/// "Cannot call non-static function ... directly"。（ChartDb 无此问题是因为类名 ChartDb
/// 与 autoload 键 ChartDB 大小写不同。）
///
/// 随之而来的注意点：没有全局类注册，GDScript 侧拿不到本类的方法签名，所有调用返回值
/// 都是 Variant。因此 GDScript 里**不要**用 `:=` 接收本类的返回值（会报"Cannot infer the
/// type"），要用显式类型接收，例如 `var i: int = MidiCore.GetIndex()`。
/// </summary>
public partial class MidiCore : Node
{
    public static MidiCore Instance { get; private set; }

    // 播放模式（与 MidiPlaybackManager.RepeatMode 数值对齐）
    public const int REPEAT_SEQUENTIAL = 0;
    public const int REPEAT_ALL = 1;
    public const int REPEAT_ONE = 2;
    public const int REPEAT_SHUFFLE = 3;

    private readonly List<string> _keys = new();
    private int _index = -1;
    private int _repeat_mode = REPEAT_SEQUENTIAL;
    private string _source_fav_id = "";
    private bool _persist_enabled = true;
    private bool _session_single = false;
    private string _session_key = "";
    private bool _loaded = false;

    private ChartDb _chartDb;

    public override void _Ready()
    {
        Instance = this;
    }

    private ChartDb Db()
    {
        if (_chartDb == null || !IsInstanceValid(_chartDb))
        {
            _chartDb = GetNodeOrNull<ChartDb>("/root/ChartDB");
        }
        return _chartDb;
    }

    private bool DbReady()
    {
        var db = Db();
        return db != null && db.IsOpen();
    }

    // ── 加载 / 落盘 ────────────────────────────────────────

    /// <summary>懒加载：DB 就绪时读回磁盘列表。未就绪返回 false，调用方可稍后重试。</summary>
    public bool EnsureLoaded()
    {
        if (_loaded) return true;
        if (!DbReady()) return false;
        var raw = Db().GetPlaylist();
        _keys.Clear();
        var arr = raw.TryGetValue("keys", out var kv) ? kv.AsGodotArray() : new Godot.Collections.Array();
        foreach (var item in arr)
        {
            var s = item.AsString();
            if (!string.IsNullOrEmpty(s)) _keys.Add(s);
        }
        _index = raw.TryGetValue("index", out var iv) ? iv.AsInt32() : 0;
        _repeat_mode = raw.TryGetValue("repeat_mode", out var rv) ? rv.AsInt32() : REPEAT_SEQUENTIAL;
        _source_fav_id = raw.TryGetValue("source_fav_id", out var fv) ? fv.AsString() : "";
        if (_keys.Count == 0) _index = -1;
        else _index = Mathf.Clamp(_index, 0, _keys.Count - 1);
        _loaded = true;
        GD.Print($"[MidiCore] playlist loaded: {_keys.Count} songs, index={_index}");
        return true;
    }

    /// <summary>落盘（受 persist 门控）。未成功载入过不写，避免用空列表覆盖磁盘。</summary>
    public void Save()
    {
        if (!_persist_enabled || !_loaded) return;
        if (!DbReady()) return;
        var arr = new Godot.Collections.Array();
        foreach (var k in _keys) arr.Add(k);
        Db().SavePlaylist(arr, _index, _repeat_mode, _source_fav_id);
    }

    /// <summary>变更前保证已从磁盘读回：否则首次变更要么落盘被 _loaded 门挡掉，
    /// 要么后续 Save 用未读回的状态覆盖磁盘。</summary>
    private void PrepareForMutation()
    {
        if (!_loaded) EnsureLoaded();
    }

    /// <summary>剔除已删除的曲子。DB 无谱面时直接跳过——用户数据唯一副本在此，不能误删。</summary>
    public void Prune()
    {
        if (!DbReady()) return;
        var db = Db();
        // 空库（扫描未完成/DB 未就绪）时绝不剪枝，否则会把整表清空
        if (db.CountCharts() <= 0) return;
        var valid = new HashSet<string>();
        foreach (var k in db.GetAllChartKeys()) valid.Add(k);
        var kept = new List<string>();
        var dropped = false;
        foreach (var k in _keys)
        {
            if (valid.Contains(k)) { kept.Add(k); continue; }
            // 旧数据可能存的是别名（id / file_hash），逐键兜底解析
            var canonical = db.LookupChartKey(k);
            if (string.IsNullOrEmpty(canonical)) dropped = true;
            else { kept.Add(canonical); dropped = true; }
        }
        if (!dropped) return;
        _keys.Clear();
        _keys.AddRange(kept);
        if (_index >= _keys.Count) _index = Mathf.Max(0, _keys.Count - 1);
        if (_keys.Count == 0) _index = -1;
        Save();
        GD.Print($"[MidiCore] playlist pruned: {_keys.Count} songs remain");
    }

    // ── 查询 ──────────────────────────────────────────────

    public Godot.Collections.Array<string> GetKeys()
    {
        var outArr = new Godot.Collections.Array<string>();
        foreach (var k in _keys) outArr.Add(k);
        return outArr;
    }

    public int GetCount() => _keys.Count;

    public string GetKeyAt(int i)
    {
        if (i < 0 || i >= _keys.Count) return "";
        return _keys[i];
    }

    public int GetIndex() => _index;

    public string GetCurrentKey()
    {
        if (_index < 0 || _index >= _keys.Count) return "";
        return _keys[_index];
    }

    /// <summary>按 key 定位下标；未命中返回 -1。用于「当前曲是否在列表里」等判断。</summary>
    public int IndexOf(string key)
    {
        if (string.IsNullOrEmpty(key)) return -1;
        return _keys.IndexOf(key);
    }

    public bool Has(string key) => IndexOf(key) >= 0;

    // ── 变更（调用方负责随后 emit 自己的信号）────────────────

    public void SetIndex(int i)
    {
        if (_keys.Count == 0) { _index = -1; return; }
        _index = Mathf.Clamp(i, 0, _keys.Count - 1);
    }

    /// <summary>整表替换（选收藏夹 / 恢复会话 / 打乱后提交顺序）。会重置索引。</summary>
    public void SetKeys(Godot.Collections.Array keys, int index)
    {
        PrepareForMutation();
        _keys.Clear();
        foreach (var item in keys)
        {
            var s = item.AsString();
            if (!string.IsNullOrEmpty(s)) _keys.Add(s);
        }
        _index = _keys.Count == 0 ? -1 : Mathf.Clamp(index, 0, _keys.Count - 1);
        Save();
    }

    public void AppendKey(string key)
    {
        if (string.IsNullOrEmpty(key)) return;
        PrepareForMutation();
        _keys.Add(key);
        Save();
    }

    public void InsertAt(int i, string key)
    {
        if (string.IsNullOrEmpty(key)) return;
        PrepareForMutation();
        var at = Mathf.Clamp(i, 0, _keys.Count);
        _keys.Insert(at, key);
        if (_index >= at) _index += 1;   // 播放下标一起挪，保证仍指着同一首
        Save();
    }

    /// <summary>移除指定下标。移除的是当前曲时，索引落到接管其位置的那首（末首被移除则退一位）。</summary>
    public void RemoveAt(int i)
    {
        if (i < 0 || i >= _keys.Count) return;
        PrepareForMutation();
        var wasCurrent = i == _index;
        _keys.RemoveAt(i);
        if (_keys.Count == 0) _index = -1;
        else if (wasCurrent) _index = Mathf.Clamp(i, 0, _keys.Count - 1);
        else if (_index >= _keys.Count) _index = _keys.Count - 1;
        Save();
    }

    /// <summary>调整两项顺序，播放下标一起挪位（拖拽排序用）。</summary>
    public void Move(int fromIdx, int toIdx)
    {
        if (fromIdx < 0 || fromIdx >= _keys.Count) return;
        var to = Mathf.Clamp(toIdx, 0, _keys.Count - 1);
        if (fromIdx == to) return;
        PrepareForMutation();
        var item = _keys[fromIdx];
        var cur = _index;
        _keys.RemoveAt(fromIdx);
        _keys.Insert(to, item);
        if (cur >= 0)
        {
            if (fromIdx == cur) cur = to;            // 播的就是被拖的那首 → 跟到新位置
            else
            {
                if (fromIdx < cur) cur -= 1;         // 移除点在它前面 → 左移一位
                if (to <= cur) cur += 1;             // 插入点在它前面 → 右移一位
            }
            _index = Mathf.Clamp(cur, 0, _keys.Count - 1);
        }
        Save();
    }

    public void ClearAll()
    {
        PrepareForMutation();
        _keys.Clear();
        _index = -1;
        Save();
    }

    // ── 导航 ──────────────────────────────────────────────

    /// <summary>下一首 key（纯下标 +1，末尾回绕）。列表空返回空串。</summary>
    public string NextKey()
    {
        if (_keys.Count == 0) return "";
        var n = _index + 1;
        if (n < 0 || n >= _keys.Count) n = 0;
        return _keys[n];
    }

    /// <summary>上一首 key（纯下标 -1，首项回绕到末尾）。列表空返回空串。</summary>
    public string PrevKey()
    {
        if (_keys.Count == 0) return "";
        var p = _index - 1;
        if (p < 0) p = _keys.Count - 1;
        return _keys[p];
    }

    /// <summary>
    /// 播完/回绕时该接哪一首——深度后台由音频侧直接调用。
    /// 返回空串表示「不推进，原地重播当前曲」（单曲槽会话 / 单曲循环 / 列表为空）。
    /// </summary>
    public string ResolveAdvanceKey()
    {
        if (_keys.Count == 0 || _session_single) return "";
        if (_repeat_mode == REPEAT_ONE) return "";
        return NextKey();
    }

    // ── 模式 / 会话 / 持久化开关 ───────────────────────────

    public void SetRepeatMode(int mode)
    {
        PrepareForMutation();
        _repeat_mode = mode;
        Save();
    }

    public int GetRepeatMode() => _repeat_mode;

    public void SetSessionSingle(bool single) => _session_single = single;

    public bool IsSessionSingle() => _session_single;

    /// <summary>正常通道的单曲槽（B）：演奏 / 音轨试听 / 媒体控件播种，永不落盘。</summary>
    public void SetSessionKey(string key) => _session_key = key ?? "";

    public string GetSessionKey() => _session_key;

    public void SetPersistEnabled(bool enabled) => _persist_enabled = enabled;

    public bool IsPersistEnabled() => _persist_enabled;

    public void SetSourceFavId(string id) => _source_fav_id = id ?? "";

    public string GetSourceFavId() => _source_fav_id;

    // ── 运行时配置权威（chart_runtime） ─────────────────────────
    //
    // 播放侧（MeltySynthPlayer，含后台换曲线程）与显示侧（GDScript）都从这里取配置，
    // 不再各自水合一份。权威存储是 ChartDb 的 chart_runtime 集合（LiteDB）。
    //
    // 写入分两类入口，务必区分：
    //   UpdateConfig      —— 用户编辑，无守卫，不允许从加载路径调用
    //   EnsureDefaultsOnce —— 首次初始化的自动默认，自守卫，每首歌终身只写一次
    // 混用会导致每次加载都往 DB 写一份默认配置。

    /// <summary>读整份运行时配置（无则空字典）。返回 null 表示该曲从未存过配置。</summary>
    public Godot.Collections.Dictionary GetConfig(string chartKey)
    {
        if (!DbReady() || string.IsNullOrEmpty(chartKey)) return null;
        var db = Db();
        int rev = db.RuntimeRevision;
        lock (_parseLock)
        {
            if (_configCacheRevision == rev && _configCache.TryGetValue(chartKey, out var hit))
            {
                return hit;
            }
            _configCache.Clear();
            _configCacheRevision = rev;
        }
        var cfg = db.GetRuntime(chartKey);
        if (cfg == null) return null;
        lock (_parseLock)
        {
            // 期间可能有写入改了修订号——那种情况下不写入缓存，下个调用自然重建
            if (_configCacheRevision == db.RuntimeRevision)
            {
                _configCache[chartKey] = cfg;
            }
        }
        return cfg;
    }

    /// <summary>
    /// 用户编辑配置的合并写入：patch 里出现的键覆盖现有值，其余保持不变。
    /// 不做"一次性默认"语义——那由 EnsureDefaultsOnce 负责。
    /// </summary>
    public bool UpdateConfig(string chartKey, Godot.Collections.Dictionary patch)
    {
        if (!DbReady() || string.IsNullOrEmpty(chartKey) || patch == null || patch.Count == 0)
        {
            return false;
        }
        var current = Db().GetRuntime(chartKey) ?? new Godot.Collections.Dictionary();
        foreach (var kv in patch)
        {
            current[kv.Key] = kv.Value;
        }
        Db().SaveRuntime(chartKey, current);
        InvalidateConfigCache(chartKey);
        return true;
    }

    /// <summary>
    /// 读取配置字段（不存在时返回 fallback）。后台线程与 GDScript 共用的取数入口。
    /// </summary>
    public Variant GetConfigValue(string chartKey, string field, Variant fallback)
    {
        var cfg = GetConfig(chartKey);
        if (cfg != null && cfg.TryGetValue(field, out var v))
        {
            return v;
        }
        return fallback;
    }

    /// <summary>
    /// 一次性自动默认：仅当该曲从未初始化过时写入并落盘，返回是否真的执行了写入。
    ///
    /// 守卫内置在函数内部（而非调用点），这样无论多少调用方、无论调用顺序如何，
    /// 每首歌终身只会写一次 DB。替代原先 GDScript 侧
    /// `if (midi_data.is_track_config_initialized()) return` 的写法——那种守卫在
    /// 内存副本上，换一份水合来源就会失效。
    ///
    /// patch 只需包含要默认化的字段（vocal_offset_ms / selected_track_configs /
    /// desc_recommended_tracks / vocal_enabled / vocal_file_path 等）。
    /// </summary>
    public bool EnsureDefaultsOnce(string chartKey, Godot.Collections.Dictionary defaults)
    {
        if (!DbReady() || string.IsNullOrEmpty(chartKey) || defaults == null || defaults.Count == 0)
        {
            return false;
        }
        var current = Db().GetRuntime(chartKey) ?? new Godot.Collections.Dictionary();
        // 守卫：已初始化过就不再写。键缺失与显式 false 都要视为"已初始化"，
        // 因为 MidiView 的"删除设定"会显式写 false 后再 ClearRuntime。
        if (current.ContainsKey("_track_config_initialized")
            && current["_track_config_initialized"].AsBool())
        {
            return false;
        }
        foreach (var kv in defaults)
        {
            current[kv.Key] = kv.Value;
        }
        current["_track_config_initialized"] = true;
        Db().SaveRuntime(chartKey, current);
        InvalidateConfigCache(chartKey);
        GD.Print($"[MidiCore] defaults initialized once for {chartKey}");
        return true;
    }

    /// <summary>清空某曲的运行时配置（MidiView 的"删除设定"）。</summary>
    public void ClearConfig(string chartKey)
    {
        if (!DbReady() || string.IsNullOrEmpty(chartKey)) return;
        Db().ClearRuntime(chartKey);
        InvalidateConfigCache(chartKey);
    }

    private readonly Dictionary<string, Godot.Collections.Dictionary> _configCache = new();

    /// <summary>
    /// 进程内配置缓存。LiteDB 每次查询都要开锁+反序列化，而后台换曲线程每 200ms
    /// 轮询一次，不缓存会把 DB 变成瓶颈。
    ///
    /// 失效判据用 ChartDb.RuntimeRevision 而非逐处手动失效：chart_runtime 的写入点
    /// 分散在 ChartDb 内部的播种、删谱面、旧缓存迁移、键重整多处，逐处通知易漏，
    /// 漏一处就会读到陈旧配置（表现为"改了设置不生效"）。
    /// </summary>
    private int _configCacheRevision = -1;

    private void InvalidateConfigCache(string chartKey)
    {
        lock (_parseLock)
        {
            _configCache.Clear();
            // 置-1 强制下次重建：即便本次写入没走 ChartDb 的修订号（如直接改内存）也生效
            _configCacheRevision = -1;
        }
    }

    // ── 解析产物缓存：解析由 C# 持有，GDScript 按需取 ──────────────
    // MidiParserNative 本身无状态，旧实现每次都把整份 SOA 解析一遍再整体拷给 GDScript。
    // 这里按「实际 MIDI 文件路径」缓存解析结果（含进程内托管数组），Godot 只取它需要的部分：
    //   - 组装 MidiData 用原始结果（GetParsedNative）
    //   - 枚举轨道 / 生成启用索引（GetPairs / GetEnabledIndices / GetAllIndices），
    //     替代 GDScript 里 O(N) 的全量遍历与排序
    //   - KeySequenceCore 直接进程内读数组（TryGetSoa），省掉 6 条 Godot.PackedInt32Array 的来回拷贝
    private sealed class ParseEntry
    {
        public Godot.Collections.Dictionary Native;
        public int[] St, Du, Pt, Ve, Tr, Ch;   // 与 Native 同内容的托管数组（进程内直读）
        public int[] PairsFlat;                // 去重 (track<<8|channel)，按首次出现顺序
        public long Stamp;
    }

    private readonly Dictionary<string, ParseEntry> _parseCache = new();
    private readonly object _parseLock = new();
    /// <summary>缓存上限：单份 SOA 约数 MB（Native 的 PackedInt32Array + 托管 int[] 双份），
    /// 与 GDScript 侧 MidiData 只留 2 首的预算对齐，超出按最近使用淘汰。重解析约 20ms。</summary>
    private const int ParseCacheMax = 2;
    private long _parseStamp;

    private static int PairKey(int track, int channel) => (track << 8) | (channel & 0xFF);

    /// <summary>按「缓存键」解析并缓存（幂等：命中直接返回，不重复读盘/解析）。
    /// readPath = 实际可读文件路径；cacheKey = 缓存键。
    /// 两者分开是因为 GDScript 侧存在 res:// 回退路径：读取用回退路径，但缓存键统一用
    /// midi_data.midi_file_path，保证后续 GetPairs/GetEnabledIndices 查得到。
    /// 注意：签名不得给参数默认值——GDScript 调用 C# 方法必须严格匹配参数个数，
    /// 带默认值的方法在少传参调用时报 "Nonexistent function"（实测）。</summary>
    public bool ParseChartFile(string readPath, string cacheKey)
    {
        if (string.IsNullOrEmpty(readPath)) return false;
        var key = string.IsNullOrEmpty(cacheKey) ? readPath : cacheKey;
        lock (_parseLock)
        {
            if (_parseCache.TryGetValue(key, out var hit))
            {
                hit.Stamp = ++_parseStamp;
                return true;
            }
        }
        if (!Godot.FileAccess.FileExists(readPath)) return false;
        using var f = Godot.FileAccess.Open(readPath, Godot.FileAccess.ModeFlags.Read);
        if (f == null) return false;
        var bytes = f.GetBuffer((long)f.GetLength());
        f.Close();

        Godot.Collections.Dictionary native;
        try
        {
            native = new MidiParserNative().Parse(bytes);
        }
        catch (Exception e)
        {
            GD.PrintErr($"[MidiCore] MIDI parse failed ({readPath}): {e.Message}");
            return false;
        }
        if (native.Count == 0 || !native.TryGetValue("success", out var sv) || !sv.AsBool())
        {
            return false;
        }

        var entry = new ParseEntry { Native = native, Stamp = ++_parseStamp };
        entry.St = native["start_ticks"].AsInt32Array();
        entry.Du = native["durations"].AsInt32Array();
        entry.Pt = native["pitches"].AsInt32Array();
        entry.Ve = native["velocities"].AsInt32Array();
        entry.Tr = native["track_indices"].AsInt32Array();
        entry.Ch = native["channels"].AsInt32Array();
        entry.PairsFlat = BuildPairsFlat(entry);

        lock (_parseLock)
        {
            _parseCache[key] = entry;
            TrimParseCacheLocked();
        }
        GD.Print($"[MidiCore] parsed & cached: {entry.Pt.Length} notes, {entry.PairsFlat.Length} pairs ({key})");
        return true;
    }

    /// <summary>
    /// 取 SOA 的 9 个并行数组（6 音符 + 3 分组）供 GDScript 侧 NoteSoa 包装。
    /// 直接返回 PackedInt32Array 本身（GODOT 侧 COW 共享底层存储，不复制），
    /// 故 NoteRollView / TrackView 每帧读仍是零跨语言开销。
    /// 未解析过返回空字典。
    /// 注意：不用 out 参数——Godot 无法绑定 out 参数，GDScript 调用会报
    /// "Nonexistent function"（实测）。
    /// </summary>
    public Godot.Collections.Dictionary GetSoaArrays(string path)
    {
        if (string.IsNullOrEmpty(path)) return new Godot.Collections.Dictionary();
        ParseEntry e;
        lock (_parseLock)
        {
            if (!_parseCache.TryGetValue(path, out e)) return new Godot.Collections.Dictionary();
        }
        var n = e.Native;
        if (n == null || n.Count == 0) return new Godot.Collections.Dictionary();
        return new Godot.Collections.Dictionary
        {
            ["pitches"] = n["pitches"].AsInt32Array(),
            ["velocities"] = n["velocities"].AsInt32Array(),
            ["start_ticks"] = n["start_ticks"].AsInt32Array(),
            ["durations"] = n["durations"].AsInt32Array(),
            ["track_indices"] = n["track_indices"].AsInt32Array(),
            ["channels"] = n["channels"].AsInt32Array(),
            ["track_channel_groups_keys"] = ReadInt32(n, "track_channel_groups_keys"),
            ["track_channel_groups_offsets"] = ReadInt32(n, "track_channel_groups_offsets"),
            ["track_channel_groups_indices"] = ReadInt32(n, "track_channel_groups_indices"),
        };
    }

    /// <summary>
    /// 取 bpm 时间线，重建为 GDScript 侧期望的 Array[Dictionary] 形态
    /// （每项含 tick / bpm / time_ms，兼容 MidiData.bpm_timeline 的既有访问）。
    /// 过去由 Utilities/MidiParser.gd 从三个并行数组拼装，那层已删除。
    /// 未解析过返回空数组。
    /// </summary>
    public Godot.Collections.Array GetBpmTimeline(string path)
    {
        var outArr = new Godot.Collections.Array();
        if (string.IsNullOrEmpty(path)) return outArr;
        ParseEntry e;
        lock (_parseLock)
        {
            if (!_parseCache.TryGetValue(path, out e)) return outArr;
        }
        var n = e.Native;
        if (n == null || n.Count == 0) return outArr;
        if (!n.TryGetValue("bpm_timeline_ticks", out var ticksV)) return outArr;
        var ticks = ticksV.AsInt32Array();
        var bpms = ReadFloat32(n, "bpm_timeline_bpms");
        var times = ReadFloat32(n, "bpm_timeline_times_ms");
        for (int i = 0; i < ticks.Length; i++)
        {
            outArr.Add(new Godot.Collections.Dictionary
            {
                ["tick"] = ticks[i],
                ["bpm"] = i < bpms.Length ? (float)bpms[i] : 120.0f,
                ["time_ms"] = i < times.Length ? (float)times[i] : 0.0f,
            });
        }
        return outArr;
    }

    /// <summary>轨道/通道乐器映射（C# 解析阶段一次性提取，GD 侧不再遍历事件）</summary>
    public Godot.Collections.Dictionary GetTrackInstruments(string path)
    {
        if (string.IsNullOrEmpty(path)) return new Godot.Collections.Dictionary();
        ParseEntry e;
        lock (_parseLock)
        {
            if (!_parseCache.TryGetValue(path, out e)) return new Godot.Collections.Dictionary();
        }
        var n = e.Native;
        if (n == null || !n.TryGetValue("track_instruments", out var v)) return new Godot.Collections.Dictionary();
        return v.AsGodotDictionary();
    }

    /// <summary>解析出的轨道数（替代 GDScript 侧重建 track_infos 数组）</summary>
    public int GetTrackCount(string path)
    {
        if (string.IsNullOrEmpty(path)) return 0;
        ParseEntry e;
        lock (_parseLock)
        {
            if (!_parseCache.TryGetValue(path, out e)) return 0;
        }
        var n = e.Native;
        if (n != null && n.TryGetValue("track_count", out var v)) return v.AsInt32();
        return 0;
    }

    /// <summary>曲长（毫秒）</summary>
    public double GetDurationMs(string path)
    {
        if (string.IsNullOrEmpty(path)) return 0.0;
        ParseEntry e;
        lock (_parseLock)
        {
            if (!_parseCache.TryGetValue(path, out e)) return 0.0;
        }
        var n = e.Native;
        if (n != null && n.TryGetValue("duration_ms", out var v)) return v.AsDouble();
        return 0.0;
    }

    /// <summary>MIDI timebase（每四分音符 tick 数，默认 480）</summary>
    public int GetTimebase(string path)
    {
        if (string.IsNullOrEmpty(path)) return 480;
        ParseEntry e;
        lock (_parseLock)
        {
            if (!_parseCache.TryGetValue(path, out e)) return 480;
        }
        var n = e.Native;
        if (n != null && n.TryGetValue("timebase", out var v)) return v.AsInt32();
        return 480;
    }

    /// <summary>最大结束 tick（TrackView 自动滚动范围用，0 = 未知）</summary>
    public double GetMaxEndTick(string path)
    {
        if (string.IsNullOrEmpty(path)) return 0.0;
        ParseEntry e;
        lock (_parseLock)
        {
            if (!_parseCache.TryGetValue(path, out e)) return 0.0;
        }
        var n = e.Native;
        if (n != null && n.TryGetValue("max_end_tick", out var v)) return v.AsDouble();
        return 0.0;
    }

    /// <summary>解析结果里取 int32 数组；键缺失时给空数组（分组解析失败时NoteSoa 会走重算回退）</summary>
    private static int[] ReadInt32(Godot.Collections.Dictionary d, string key)
    {
        return d.TryGetValue(key, out var v) && v.VariantType == Variant.Type.PackedInt32Array
            ? v.AsInt32Array() : System.Array.Empty<int>();
    }

    /// <summary>解析结果里取 float32 数组；键缺失时给空数组</summary>
    private static float[] ReadFloat32(Godot.Collections.Dictionary d, string key)
    {
        return d.TryGetValue(key, out var v) && v.VariantType == Variant.Type.PackedFloat32Array
            ? v.AsFloat32Array() : System.Array.Empty<float>();
    }

    private static int[] BuildPairsFlat(ParseEntry e)
    {
        var seen = new HashSet<int>();
        var list = new List<int>();
        for (int i = 0; i < e.Pt.Length; i++)
        {
            var k = PairKey(e.Tr[i], e.Ch[i]);
            if (seen.Add(k)) list.Add(k);
        }
        return list.ToArray();
    }

    private void TrimParseCacheLocked()
    {
        while (_parseCache.Count > ParseCacheMax)
        {
            string oldest = null;
            long best = long.MaxValue;
            foreach (var kv in _parseCache)
            {
                if (kv.Value.Stamp < best) { best = kv.Value.Stamp; oldest = kv.Key; }
            }
            if (oldest == null) break;
            _parseCache.Remove(oldest);
        }
    }

    public bool HasParsed(string path)
    {
        lock (_parseLock) return _parseCache.ContainsKey(path);
    }

    /// <summary>释放某路径的解析缓存（缓存已满时由 LRU 自动淘汰，一般无需显式调用）</summary>
    public void DropParsed(string path)
    {
        lock (_parseLock) _parseCache.Remove(path);
    }

    /// <summary>GDScript 组装 MidiData 用的原始解析结果（与 MidiParserNative.Parse 同形态）</summary>
    public Godot.Collections.Dictionary GetParsedNative(string path)
    {
        lock (_parseLock)
        {
            return _parseCache.TryGetValue(path, out var e) ? e.Native : new Godot.Collections.Dictionary();
        }
    }

    public int GetNoteCount(string path)
    {
        lock (_parseLock) return _parseCache.TryGetValue(path, out var e) ? e.Pt.Length : 0;
    }

    /// <summary>去重 (track,channel) 对（编码 track&lt;&lt;8|channel），供 GDScript 枚举轨道。
    /// Godot C# 里 PackedInt32Array 映射为 int[]，GDScript 侧拿到的是 PackedInt32Array。</summary>
    public int[] GetPairs(string path)
    {
        lock (_parseLock)
        {
            return _parseCache.TryGetValue(path, out var e) ? e.PairsFlat : System.Array.Empty<int>();
        }
    }

    /// <summary>启用 (track,channel) 子集的 SOA 索引（升序，pairKeys 编码同上）。</summary>
    public int[] GetEnabledIndices(string path, int[] pairKeys)
    {
        lock (_parseLock)
        {
            if (!_parseCache.TryGetValue(path, out var e)) return System.Array.Empty<int>();
            int n = e.Pt.Length;
            var want = new HashSet<int>();
            if (pairKeys != null)
            {
                foreach (var v in pairKeys) want.Add(v);
            }
            // 空集或全选：直接 0..n-1（省掉逐音符判定）
            if (want.Count == 0 || want.Count >= e.PairsFlat.Length)
            {
                return AllIndices(n);
            }
            var list = new List<int>(n);
            for (int i = 0; i < n; i++)
            {
                if (want.Contains(PairKey(e.Tr[i], e.Ch[i]))) list.Add(i);
            }
            return list.ToArray();
        }
    }

    /// <summary>全量索引 0..n-1（"全部启用"场景，替代 GDScript O(N) 的 resize+填值）</summary>
    public int[] GetAllIndices(string path)
    {
        lock (_parseLock)
        {
            return _parseCache.TryGetValue(path, out var e) ? AllIndices(e.Pt.Length) : System.Array.Empty<int>();
        }
    }

    private static int[] AllIndices(int n)
    {
        var all = new int[n];
        for (int i = 0; i < n; i++) all[i] = i;
        return all;
    }

    /// <summary>进程内直读 SOA 六数组（供 KeySequenceCore 免跨语言拷贝）；未缓存返回 false</summary>
    public bool TryGetSoa(string path,
        out int[] startTick, out int[] durTick, out int[] pitch,
        out int[] velocity, out int[] track, out int[] channel)
    {
        lock (_parseLock)
        {
            if (_parseCache.TryGetValue(path, out var e))
            {
                startTick = e.St; durTick = e.Du; pitch = e.Pt;
                velocity = e.Ve; track = e.Tr; channel = e.Ch;
                return true;
            }
        }
        startTick = durTick = pitch = velocity = track = channel = null;
        return false;
    }
}
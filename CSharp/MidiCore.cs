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

    /// <summary>
    /// 播放列表状态（_keys/_index/_repeat_mode/_session_single/_loaded…）的互斥锁。
    ///
    /// 【为什么必须有】这份状态是双线程访问：
    ///   - 主线程：用户编辑（增删/拖拽排序/整表替换/打乱）、play_index、落盘；
    ///   - **后台换曲线程**：熄屏时 AdvanceToNextInBackground 会读 GetCount/GetIndex/
    ///     GetRepeatMode/IsSessionSingle/GetCurrentKey，并经 ResolveAdvanceKey→NextKey 读 _keys。
    /// List&lt;string&gt; 的读与"主线程正在增删"并发会抛 IndexOutOfRange 或读到撕裂状态；
    /// 而这是用户数据的唯一副本，损坏后果严重。锁只在微秒级，DB 写入也在锁内属可接受
    /// （ChartDb 自身有锁且从不回调 MidiCore，无反向加锁，不会死锁）。
    /// </summary>
    private readonly object _playlistLock = new();

    private volatile ChartDb _chartDb;

    public override void _Ready()
    {
        Instance = this;
    }

    /// <summary>
    /// 取 ChartDb 引用。
    ///
    /// 【后台线程绝不碰引擎】熄屏后台换曲会走到 Save()/SetIndex()，其链路上会经这里拿 DB。
    /// 而旧实现每次都调 IsInstanceValid（引擎调用，内部要拿 ObjectDB 的读写锁）——
    /// 主线程若正持锁被冻结，后台线程就会永久阻塞（正是"不切歌且彻底静音"的成因之一）。
    /// 故非主线程只返回**已缓存的引用**，不做有效性检查、更不 GetNodeOrNull：
    /// ChartDb 是 autoload，进程存活期内一直有效；真被释放时访问会抛异常，
    /// 由后台循环的 try/catch 兜住（不会拖死主线程）。
    /// </summary>
    private ChartDb Db()
    {
        var cached = _chartDb;
        if (cached != null)
        {
            if (!ThreadSafeLog.IsMainThread)
            {
                return cached;
            }
            if (IsInstanceValid(cached))
            {
                return cached;
            }
        }
        if (!ThreadSafeLog.IsMainThread)
        {
            return cached;   // 后台线程：拿不到就返回 null，由调用方判空（不碰引擎）
        }
        _chartDb = GetNodeOrNull<ChartDb>("/root/ChartDB");
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
        lock (_playlistLock)
        {
            if (_loaded) return true;
            if (!DbReady()) return false;
            var raw = Db().GetPlaylistPlain();
            _keys.Clear();
            _keys.AddRange(raw.keys);
            _index = raw.index;
            _repeat_mode = raw.repeatMode;
            _source_fav_id = raw.sourceFavId;
            if (_keys.Count == 0) _index = -1;
            else _index = 0;   // 位置不持久化：读回后一律从第一首开始
            _loaded = true;
            ThreadSafeLog.Print($"[MidiCore] playlist loaded: {_keys.Count} songs, index={_index}");
            return true;
        }
    }

    /// <summary>落盘（受 persist 门控）。未成功载入过不写，避免用空列表覆盖磁盘。
    /// 走 ChartDb 的纯托管入口：熄屏后台的换曲线程也会调到这里。</summary>
    public void Save()
    {
        lock (_playlistLock)
        {
            if (!_persist_enabled || !_loaded) return;
            if (!DbReady()) return;
            // 位置（播放到第几首）**不持久化**：列表每次都从头发起（随机模式本来每次都会重新打乱）。
            // 这样后台换曲也不需要任何落盘/写入 —— 少一处会与冻结的主线程争锁的写操作。
            Db().SavePlaylistPlain(_keys, 0, _repeat_mode, _source_fav_id);
        }
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
        lock (_playlistLock)
        {
            if (!DbReady()) return;
            var db = Db();
            // 空库（扫描未完成/DB 未就绪）时绝不剪枝，否则会把整表清空
            if (db.CountCharts() <= 0) return;
            var valid = new HashSet<string>();
            foreach (var k in db.GetAllChartKeysPlain()) valid.Add(k);
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
            ThreadSafeLog.Print($"[MidiCore] playlist pruned: {_keys.Count} songs remain");
        }
    }

    // ── 查询 ──────────────────────────────────────────────

    public Godot.Collections.Array<string> GetKeys()
    {
        lock (_playlistLock)
        {
            var outArr = new Godot.Collections.Array<string>();
            foreach (var k in _keys) outArr.Add(k);
            return outArr;
        }
    }

    public int GetCount()
    {
        lock (_playlistLock) return _keys.Count;
    }

    public string GetKeyAt(int i)
    {
        lock (_playlistLock)
        {
            if (i < 0 || i >= _keys.Count) return "";
            return _keys[i];
        }
    }

    public int GetIndex()
    {
        lock (_playlistLock) return _index;
    }

    public string GetCurrentKey()
    {
        lock (_playlistLock)
        {
            if (_index < 0 || _index >= _keys.Count) return "";
            return _keys[_index];
        }
    }

    /// <summary>按 key 定位下标；未命中返回 -1。用于「当前曲是否在列表里」等判断。</summary>
    public int IndexOf(string key)
    {
        if (string.IsNullOrEmpty(key)) return -1;
        lock (_playlistLock) return _keys.IndexOf(key);
    }

    public bool Has(string key) => IndexOf(key) >= 0;

    // ── 变更（调用方负责随后 emit 自己的信号）────────────────

    public void SetIndex(int i)
    {
        lock (_playlistLock)
        {
            if (_keys.Count == 0) { _index = -1; return; }
            _index = Mathf.Clamp(i, 0, _keys.Count - 1);
        }
    }

    /// <summary>整表替换（选收藏夹 / 恢复会话 / 打乱后提交顺序）。会重置索引。</summary>
    public void SetKeys(Godot.Collections.Array keys, int index)
    {
        lock (_playlistLock)
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
    }

    public void AppendKey(string key)
    {
        if (string.IsNullOrEmpty(key)) return;
        lock (_playlistLock)
        {
            PrepareForMutation();
            _keys.Add(key);
            Save();
        }
    }

    public void InsertAt(int i, string key)
    {
        if (string.IsNullOrEmpty(key)) return;
        lock (_playlistLock)
        {
            PrepareForMutation();
            var at = Mathf.Clamp(i, 0, _keys.Count);
            _keys.Insert(at, key);
            if (_index >= at) _index += 1;   // 播放下标一起挪，保证仍指着同一首
            Save();
        }
    }

    /// <summary>移除指定下标。移除的是当前曲时，索引落到接管其位置的那首（末首被移除则退一位）。</summary>
    public void RemoveAt(int i)
    {
        lock (_playlistLock)
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
    }

    /// <summary>调整两项顺序，播放下标一起挪位（拖拽排序用）。</summary>
    public void Move(int fromIdx, int toIdx)
    {
        lock (_playlistLock)
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
    }

    public void ClearAll()
    {
        lock (_playlistLock)
        {
            PrepareForMutation();
            _keys.Clear();
            _index = -1;
            Save();
        }
    }

    // ── 导航 ──────────────────────────────────────────────

    /// <summary>下一首 key（纯下标 +1，末尾回绕）。列表空返回空串。</summary>
    public string NextKey()
    {
        lock (_playlistLock)
        {
            if (_keys.Count == 0) return "";
            var n = _index + 1;
            if (n < 0 || n >= _keys.Count) n = 0;
            return _keys[n];
        }
    }

    /// <summary>上一首 key（纯下标 -1，首项回绕到末尾）。列表空返回空串。</summary>
    public string PrevKey()
    {
        lock (_playlistLock)
        {
            if (_keys.Count == 0) return "";
            var p = _index - 1;
            if (p < 0) p = _keys.Count - 1;
            return _keys[p];
        }
    }

    /// <summary>
    /// 播完/回绕时该接哪一首——深度后台由音频侧直接调用。
    /// 返回空串表示「不推进，原地重播当前曲」。
    ///
    /// 判定必须与前台 _should_advance_on_end 逐条对齐，否则前后台行为分裂：
    /// 列表只有一首时前台是原地循环（不重载），这里若返回同一首会让 C# 把这首整曲重载重播。
    /// </summary>
    public string ResolveAdvanceKey()
    {
        lock (_playlistLock)
        {
            if (_keys.Count <= 1 || _session_single) return "";
            if (_repeat_mode == REPEAT_ONE) return "";
            return NextKey();
        }
    }

    // ── 后台线程专用：无锁读取的纯数据快照 ──────────────────────────
    //
    // 【为什么不是"让后台拿锁"】后台换曲跑在独立线程，而主线程随时可能正持着 _playlistLock
    // （改列表 / EnsureLoaded / Save 里的 LiteDB 落盘）。真机实测：熄屏深后台时主线程会被
    // Android 整段挂起（日志里 192 秒），此时任何等锁的后台调用都会**陪冻**同样久 ——
    // `Playback started` 之后隔 192 秒才打印 `media state published`，而两行之间只有
    // IndexOf/SetIndex/Save 三步。表现成"后台曲终不切歌 / 拖进度条卡住"。
    //
    // 解法（即"进后台前把状态缓存好"）：主线程在**每次改动后**发布一份纯数据快照
    // （string[] 引用拷贝，2333 首也就微秒级），后台只 volatile 读这个引用 —— 不取锁、不碰 DB、
    // 不落盘。后台换曲成功后也只记一个"待收敛 key"，由主线程回前台后补索引与落盘。


    /// <summary>后台推进用的纯数据快照（volatile 发布：主线程写、后台线程读）</summary>








    // ── 模式 / 会话 / 持久化开关 ───────────────────────────

    public void SetRepeatMode(int mode)
    {
        lock (_playlistLock)
        {
            PrepareForMutation();
            _repeat_mode = mode;
            Save();
        }
    }

    public int GetRepeatMode()
    {
        lock (_playlistLock) return _repeat_mode;
    }

    public void SetSessionSingle(bool single)
    {
        lock (_playlistLock) _session_single = single;
    }

    public bool IsSessionSingle()
    {
        lock (_playlistLock) return _session_single;
    }

    /// <summary>正常通道的单曲槽（B）：演奏 / 音轨试听 / 媒体控件播种，永不落盘。</summary>
    public void SetSessionKey(string key)
    {
        lock (_playlistLock) _session_key = key ?? "";
    }

    public string GetSessionKey()
    {
        lock (_playlistLock) return _session_key;
    }

    public void SetPersistEnabled(bool enabled)
    {
        lock (_playlistLock) _persist_enabled = enabled;
    }

    public bool IsPersistEnabled()
    {
        lock (_playlistLock) return _persist_enabled;
    }

    public void SetSourceFavId(string id)
    {
        lock (_playlistLock) _source_fav_id = id ?? "";
    }

    public string GetSourceFavId()
    {
        lock (_playlistLock) return _source_fav_id;
    }

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

    // ── 纯 C# 配置投影（后台换曲线程用：零 Godot 接触） ────────────
    private readonly Dictionary<string, Dictionary<string, object>> _configPlainCache = new();
    private int _configPlainRev = -1;

    /// <summary>
    /// 纯 C# 形态的运行时配置（Dictionary/List/数值/字符串/布尔）。
    ///
    /// 【首次构建须在主线程】走 ChartDb/LiteDB 读 BSON 并转托管对象；命中缓存后任意线程可读。
    /// 后台换曲线程靠它在挂起期间读配置，避免碰 Godot 容器而阻塞主线程持有的锁。
    /// </summary>
    internal Dictionary<string, object> GetConfigPlain(string chartKey)
    {
        if (!DbReady() || string.IsNullOrEmpty(chartKey)) return null;
        var db = Db();
        int rev = db.RuntimeRevision;
        lock (_parseLock)
        {
            if (_configPlainRev != rev)
            {
                _configPlainCache.Clear();
                _configPlainRev = rev;
            }
            if (_configPlainCache.TryGetValue(chartKey, out var hit))
            {
                return hit;
            }
        }
        var plain = db.GetRuntimePlain(chartKey);
        lock (_parseLock)
        {
            // 期间若有写入改了修订号则不缓存，下个调用自然重建
            if (_configPlainRev == db.RuntimeRevision)
            {
                _configPlainCache[chartKey] = plain;
            }
        }
        return plain;
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
        ThreadSafeLog.Print($"[MidiCore] defaults initialized once for {chartKey}");
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
        public int[] St, Du, Pt, Ve, Tr, Ch;   // SOA 六数组
        public int[] PairsFlat;                // 去重 (track<<8|channel)，按首次出现顺序
        public int[] GroupKeys, GroupOffsets, GroupIndices;
        public int[] BpmTicks;
        public float[] BpmBpms, BpmTimesMs;
        public int Timebase, TrackCount, MaxEndTick;
        public double DurationMs;
        public System.Collections.Generic.Dictionary<int, System.Collections.Generic.Dictionary<int, (int bank, int program)>> Instruments;
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
        => ParseChartFileImpl(readPath, cacheKey, false);

    /// <summary>
    /// 与 ParseChartFile 相同，但绝对路径用 System.IO 读盘（完全不碰 Godot 文件 API）。
    ///
    /// 供熄屏/深后台的 C# 换曲线程按需解析：那边的主循环被冻结，若它此刻正持有引擎全局锁，
    /// 后台线程再调 Godot 文件 API 会永久阻塞（表现为"设备已停、不切歌、彻底静音"）。
    /// </summary>
    public bool ParseChartFileSystemIo(string filePath, string cacheKey)
        => ParseChartFileImpl(filePath, cacheKey, true);

    private bool ParseChartFileImpl(string readPath, string cacheKey, bool preferSystemIo)
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
        byte[] bytes;
        if (preferSystemIo && !readPath.StartsWith("res://") && !readPath.StartsWith("user://"))
        {
            try
            {
                bytes = System.IO.File.ReadAllBytes(readPath);
            }
            catch (Exception e)
            {
                ThreadSafeLog.PrintErr($"[MidiCore] System.IO read failed: {readPath} ({e.Message})");
                return false;
            }
        }
        else
        {
            if (!Godot.FileAccess.FileExists(readPath)) return false;
            using var f = Godot.FileAccess.Open(readPath, Godot.FileAccess.ModeFlags.Read);
            if (f == null) return false;
            bytes = f.GetBuffer((long)f.GetLength());
            f.Close();
        }

        MidiParseResult parsed;
        try
        {
            parsed = new MidiParserNative().ParsePlain(bytes);
        }
        catch (Exception e)
        {
            ThreadSafeLog.PrintErr($"[MidiCore] MIDI parse failed ({readPath}): {e.Message}");
            return false;
        }
        if (!parsed.Success)
        {
            return false;
        }

        var entry = new ParseEntry
        {
            Stamp = ++_parseStamp,
            Pt = parsed.Pitches,
            Ve = parsed.Velocities,
            St = parsed.StartTicks,
            Du = parsed.Durations,
            Tr = parsed.TrackIndices,
            Ch = parsed.Channels,
            GroupKeys = parsed.GroupKeys,
            GroupOffsets = parsed.GroupOffsets,
            GroupIndices = parsed.GroupIndices,
            BpmTicks = parsed.BpmTicks,
            BpmBpms = parsed.BpmBpms,
            BpmTimesMs = parsed.BpmTimesMs,
            Timebase = parsed.Timebase,
            TrackCount = parsed.TrackCount,
            MaxEndTick = parsed.MaxEndTick,
            DurationMs = parsed.DurationMs,
            Instruments = parsed.TrackInstruments,
        };
        entry.PairsFlat = BuildPairsFlat(entry);

        lock (_parseLock)
        {
            _parseCache[key] = entry;
            TrimParseCacheLocked();
        }
        // 走线程安全出口：后台换曲线程会调到这里解析谱面，而主线程冻结时直接 GD.Print 会阻塞
        ThreadSafeLog.Print($"[MidiCore] parsed & cached: {entry.Pt.Length} notes, {entry.PairsFlat.Length} pairs ({key})");
        return true;
    }

    /// <summary>
    /// 取 SOA 的 9 个并行数组（6 音符 + 3 分组）供 GDScript 侧 NoteSoa 包装。
    /// **仅主线程**：这里是解析产物里唯一会创建 Godot 容器的地方（PackedInt32Array），
    /// 而解析本身（ParseChartFileSystemIo）在熄屏后台可能由音频侧线程触发。
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
        return new Godot.Collections.Dictionary
        {
            ["pitches"] = e.Pt,
            ["velocities"] = e.Ve,
            ["start_ticks"] = e.St,
            ["durations"] = e.Du,
            ["track_indices"] = e.Tr,
            ["channels"] = e.Ch,
            ["track_channel_groups_keys"] = e.GroupKeys,
            ["track_channel_groups_offsets"] = e.GroupOffsets,
            ["track_channel_groups_indices"] = e.GroupIndices,
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
        var ticks = e.BpmTicks;
        var bpms = e.BpmBpms;
        var times = e.BpmTimesMs;
        if (ticks == null || ticks.Length == 0) return outArr;
        for (int i = 0; i < ticks.Length; i++)
        {
            outArr.Add(new Godot.Collections.Dictionary
            {
                ["tick"] = ticks[i],
                ["bpm"] = i < bpms.Length ? bpms[i] : 120.0f,
                ["time_ms"] = i < times.Length ? times[i] : 0.0f,
            });
        }
        return outArr;
    }

    /// <summary>轨道/通道乐器映射（C# 解析阶段一次性提取，GD 侧不再遍历事件）。
    /// **仅主线程**（会创建 Godot 容器）。</summary>
    public Godot.Collections.Dictionary GetTrackInstruments(string path)
    {
        var result = new Godot.Collections.Dictionary();
        if (string.IsNullOrEmpty(path)) return result;
        ParseEntry e;
        lock (_parseLock)
        {
            if (!_parseCache.TryGetValue(path, out e)) return result;
        }
        if (e.Instruments == null) return result;
        foreach (var trackPair in e.Instruments)
        {
            var trackDict = new Godot.Collections.Dictionary();
            foreach (var chPair in trackPair.Value)
            {
                trackDict[chPair.Key] = new Godot.Collections.Dictionary
                {
                    { "bank", chPair.Value.bank },
                    { "program", chPair.Value.program }
                };
            }
            result[trackPair.Key] = trackDict;
        }
        return result;
    }

    /// <summary>解析出的轨道数（替代 GDScript 侧重建 track_infos 数组）。任意线程可读。</summary>
    public int GetTrackCount(string path)
    {
        lock (_parseLock)
        {
            return _parseCache.TryGetValue(path ?? "", out var e) ? e.TrackCount : 0;
        }
    }

    /// <summary>曲长（毫秒）。任意线程可读。</summary>
    public double GetDurationMs(string path)
    {
        lock (_parseLock)
        {
            return _parseCache.TryGetValue(path ?? "", out var e) ? e.DurationMs : 0.0;
        }
    }

    /// <summary>MIDI timebase（每四分音符 tick 数，默认 480）。任意线程可读。</summary>
    public int GetTimebase(string path)
    {
        lock (_parseLock)
        {
            return _parseCache.TryGetValue(path ?? "", out var e) ? e.Timebase : 480;
        }
    }

    /// <summary>最大结束 tick（TrackView 自动滚动范围用，0 = 未知）。任意线程可读。</summary>
    public double GetMaxEndTick(string path)
    {
        lock (_parseLock)
        {
            return _parseCache.TryGetValue(path ?? "", out var e) ? e.MaxEndTick : 0.0;
        }
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

    /// <summary>
    /// worker 线程版"确保解析就绪"：缓存命中直接 true；未命中且路径是原生文件系统路径时
    /// 就地补一次解析（解析已是纯托管实现，绝对路径不必碰引擎）。
    ///
    /// 存在意义：解析缓存只留 2 首，而 <see cref="KeySequenceCore"/> 的生成跑在 worker 上，
    /// 从"主线程排队"到"worker 真去读数组"之间，主线程可能又解析了别的谱面把这首挤掉 ——
    /// 那时生成会静默产出 0 条序列（表现为打歌没有音符）。这里让 worker 自己兜住。
    /// res:// / user:// 这类需要引擎读盘的路径不在此处理（后台线程不得碰引擎），返回 false。
    /// </summary>
    public bool EnsureParsedForWorker(string path)
    {
        if (string.IsNullOrEmpty(path)) return false;
        lock (_parseLock)
        {
            if (_parseCache.ContainsKey(path)) return true;
        }
        if (path.StartsWith("res://") || path.StartsWith("user://")) return false;
        // ParseChartFileSystemIo 内部对纯原生路径走 System.IO，解析主体是纯托管代码
        return ParseChartFileSystemIo(path, path);
    }
}
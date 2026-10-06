using Godot;
using System.Collections.Generic;

/// <summary>
/// KeySequenceManager 的 C# 核心：完整键序列生成算法 + C# 端 SOA 输出存储。
/// 由 GDScript 薄封装（Game/KeySequenceManager.gd）在 worker 线程调用，纯计算不碰场景树。
/// 输出（game_sequences / 背景 / 手动 / 自动 分类）全部以紧凑平行数组保存于 C#，
/// 消除 GDScript 数万 GameSequence 对象 + 每序列一个 Array 的开销。
/// 块类型：0=Block 1=Slide 2=Long（与 GDScript BlockType 一致）。
/// </summary>
[GlobalClass]
public partial class KeySequenceCore : RefCounted
{
    // ===== 配置 =====
    private int _laneCount;
    private int _densityCapPerSec;
    private float _instantThr;
    private float _shortThr;
    private float _minTapInterval;
    private float _cooldownSec;
    private float _maxTouchVelocity;
    private int _maxTouchCount;
    private bool _genInstantConnect;
    private bool _genShortConnect;
    private float _maxInstantConnectSec;
    private int _minBlockSpacing;
    private bool _handModelEnabled;
    private float _keyWidth;
    private float _screenWidth;

    private const float HOME_BIAS_COEFF = 0.4f;
    private const float CROSS_HAND_PENALTY_MULT = 2.0f;
    private const float CHORD_TOLERANCE_MS = 10.0f;
    private const float DEFAULT_BPM = 120.0f;

    // ===== 时间线 =====
    private int _timebase;
    private readonly List<double> _bpmTick = new();   // BPM 段起点 tick
    private readonly List<double> _bpmValue = new();  // 每段 BPM
    private readonly List<double> _bpmCum = new();    // 每段起点累计毫秒

    // ===== 跨窗口状态 =====
    private readonly List<Touch> _touches = new();
    private float[] _laneLongEnd = System.Array.Empty<float>();  // 长条占用（结束时刻+冷却，供同轨抑制）
    private int _batchCounter;

    // ===== 输入音符（enabled 子集，SOA）=====
    private int[] _inStartTick;
    private int[] _inDurTick;
    private int[] _inPitch;
    private int[] _inVelocity;
    private int[] _inTrack;
    private int[] _inChannel;

    // ===== 输出（game sequences，SOA）=====
    private readonly List<int> _seqKeyId = new();
    private readonly List<int> _seqPitch = new();
    private readonly List<float> _seqStart = new();
    private readonly List<float> _seqDur = new();
    private readonly List<int> _seqType = new();
    private readonly List<int> _seqLane = new();

    // ===== 输出（背景 / 分类）=====
    private readonly List<int> _bgNoteIdx = new();
    private readonly List<int> _manualIdx = new();
    private readonly List<int> _autoIdx = new();
    private int _nextKeyId;

    // ========== 配置 ==========
    public void Configure(int laneCount, int densityCap, float instantThr, float shortThr,
        float minTapInterval, float cooldownSec, float maxTouchVelocity, int maxTouchCount,
        bool genInstantConnect, bool genShortConnect, float maxInstantConnectSec,
        int minBlockSpacing, bool handModelEnabled, float keyWidth, float screenWidth)
    {
        _laneCount = laneCount;
        _densityCapPerSec = densityCap;
        _instantThr = instantThr;
        _shortThr = shortThr;
        _minTapInterval = minTapInterval;
        _cooldownSec = cooldownSec;
        _maxTouchVelocity = maxTouchVelocity;
        _maxTouchCount = maxTouchCount;
        _genInstantConnect = genInstantConnect;
        _genShortConnect = genShortConnect;
        _maxInstantConnectSec = maxInstantConnectSec;
        _minBlockSpacing = ValidateMinSpacing(minBlockSpacing);
        _handModelEnabled = handModelEnabled;
        _keyWidth = keyWidth;
        _screenWidth = screenWidth;
    }

    private int ValidateMinSpacing(int v) => v < 0 || v >= _laneCount ? 1 : v;

    // ========== 时间参数 ==========
    public void SetMidiTimeParameters(int timebase, int[] bpmTicks, float[] bpmValues)
    {
        _timebase = timebase > 0 ? timebase : 480;
        _bpmTick.Clear(); _bpmValue.Clear(); _bpmCum.Clear();
        int n = bpmValues.Length;
        double cum = 0.0;
        for (int i = 0; i < n; i++)
        {
            double tk = bpmTicks[i];
            double bpm = bpmValues[i];
            _bpmTick.Add(tk); _bpmValue.Add(bpm); _bpmCum.Add(cum);
            if (i + 1 < n)
            {
                double nt = bpmTicks[i + 1];
                double mspt = (60000.0 / bpm) / _timebase;
                cum += (nt - tk) * mspt;
            }
        }
    }

    private float TickToMs(double tick)
    {
        int n = _bpmTick.Count;
        if (n == 0)
            return (float)((tick / _timebase) * (60000.0 / DEFAULT_BPM));
        // 首段前
        if (tick <= _bpmTick[0])
        {
            var mspt = (60000.0 / _bpmValue[0]) / _timebase;
            return (float)(_bpmCum[0] + (tick - _bpmTick[0]) * mspt);
        }
        // 末段后
        double lastT = _bpmTick[n - 1];
        if (tick >= lastT)
        {
            var mspt = (60000.0 / _bpmValue[n - 1]) / _timebase;
            return (float)(_bpmCum[n - 1] + (tick - lastT) * mspt);
        }
        // 二分找所在段
        int lo = 0, hi = n - 1;
        while (lo < hi)
        {
            int mid = (lo + hi + 1) >> 1;
            if (_bpmTick[mid] <= tick) lo = mid; else hi = mid - 1;
        }
        var mspt2 = (60000.0 / _bpmValue[lo]) / _timebase;
        return (float)(_bpmCum[lo] + (tick - _bpmTick[lo]) * mspt2);
    }

    private float TickDurToMs(double startTick, double durTick)
    {
        if (durTick <= 0.0) return 0.0f;
        float s = TickToMs(startTick), e = TickToMs(startTick + durTick);
        return System.Math.Max(0.0f, e - s);
    }

    private float CalcLaneX(int lane)
    {
        if (_laneCount <= 1) return _screenWidth * 0.5f;
        float ls = _keyWidth * 0.5f;
        float sp = (_screenWidth - _keyWidth) / (_laneCount - 1);
        return ls + lane * sp;
    }

    private int CalcLaneFromX(float x)
    {
        if (_laneCount <= 1) return 0;
        float ls = _keyWidth * 0.5f;
        float sp = (_screenWidth - _keyWidth) / (_laneCount - 1);
        if (sp <= 0.0f) return 0;
        int lane = (int)System.Math.Round((x - ls) / sp);
        return System.Math.Clamp(lane, 0, _laneCount - 1);
    }

    // ========== 一次性全量生成（worker 线程调用）==========
    public void RunGenerate(int[] startTick, int[] durTick,
        int[] pitch, int[] velocity,
        int[] track, int[] channel)
    {
        SetInput(startTick, durTick, pitch, velocity, track, channel);
        GenerateAll();
    }

    /// <summary>从全量 SOA + 启用索引一次性生成（worker 线程调用）。</summary>
    public void RunGenerateGather(int[] soaStartTick,
        int[] soaDurTick, int[] soaPitch,
        int[] soaVelocity, int[] soaTrack,
        int[] soaChannel, int[] enabledIdx)
    {
        SetInputGather(soaStartTick, soaDurTick, soaPitch, soaVelocity,
            soaTrack, soaChannel, enabledIdx);
        GenerateAll();
    }

    /// <summary>
    /// 从 MidiCore 的解析缓存直读 SOA 生成（worker 线程调用）。
    /// 免去把 6 条 PackedInt32Array 从 GDScript 拷进来再拷回去。返回 false 表示缓存缺失。
    /// </summary>
    public bool RunGenerateGatherFromPath(string path, int[] enabledIdx)
    {
        var core = MidiCore.Instance;
        if (core == null || string.IsNullOrEmpty(path))
        {
            return false;
        }
        if (!core.TryGetSoa(path, out var st, out var du, out var pt, out var ve, out var tr, out var ch))
        {
            return false;
        }
        RunGenerateGather(st, du, pt, ve, tr, ch, enabledIdx);
        return true;
    }

    // ========== 流式生成（worker 线程逐窗口调用）==========
    public void SetInput(int[] startTick, int[] durTick,
        int[] pitch, int[] velocity,
        int[] track, int[] channel)
    {
        _inStartTick = startTick; _inDurTick = durTick; _inPitch = pitch;
        _inVelocity = velocity; _inTrack = track; _inChannel = channel;
    }

    /// <summary>从全量 SOA 并行数组 + 启用索引装配输入（启用子集按 SOA 顺序=start_tick 升序）。</summary>
    public void SetInputGather(int[] soaStartTick,
        int[] soaDurTick, int[] soaPitch,
        int[] soaVelocity, int[] soaTrack,
        int[] soaChannel, int[] enabledIdx)
    {
        int n = enabledIdx.Length;
        var st = new int[n];
        var du = new int[n];
        var pt = new int[n];
        var ve = new int[n];
        var tr = new int[n];
        var ch = new int[n];
        for (int i = 0; i < n; i++)
        {
            int si = enabledIdx[i];
            st[i] = soaStartTick[si]; du[i] = soaDurTick[si]; pt[i] = soaPitch[si];
            ve[i] = soaVelocity[si]; tr[i] = soaTrack[si]; ch[i] = soaChannel[si];
        }
        _inStartTick = st; _inDurTick = du; _inPitch = pt;
        _inVelocity = ve; _inTrack = tr; _inChannel = ch;
    }

    /// <summary>一次性全量生成：清输出 → 建块/时长分类/密度削减/触点判定/输出 → 背景收尾。</summary>
    private void GenerateAll()
    {
        ResetGenerate();
        var allBlocks = new List<BlockInfo>();
        BuildChords(0, _inStartTick.Length, allBlocks); // 丢弃音符直接写 _bgNoteIdx
        // 先分配触点 + 降级（得最终 Type），密度削减读已降级 Type 计成本（Slide=0.33，不再误删准 Slide）
        AssignTouchAndDegrade(allBlocks);
        ReduceDensity(allBlocks);
        // 削减后再对幸存音符推导手指移动并钳位，避免在会删掉的音符上浪费几何计算
        RepositionSurvivors(allBlocks);
        ConvertToSequences(allBlocks);
        FinalizeBackgroundAndClassify();
    }

    private void ResetGenerate()
    {
        _laneLongEnd = new float[_laneCount];
        for (int k = 0; k < _laneCount; k++) _laneLongEnd[k] = -1.0f;
        _batchCounter = 0;
        _touches.Clear();
        InitTouches();
        // 清输出
        _seqKeyId.Clear(); _seqPitch.Clear(); _seqStart.Clear(); _seqDur.Clear();
        _seqType.Clear(); _seqLane.Clear(); _bgNoteIdx.Clear(); _manualIdx.Clear(); _autoIdx.Clear();
        _nextKeyId = 0;
    }

    private void InitTouches()
    {
        var caps = _maxTouchCount;
        if (!_handModelEnabled || caps <= 0)
        {
            for (int i = 0; i < caps; i++) { var t = NewTouch(i); t.Hand = -1; _touches.Add(t); }
            return;
        }
        int homePerHand = (int)System.Math.Ceiling(caps / 2.0);
        int halfLane = _laneCount / 2;
        var leftLanes = DistributeHomeLanes(0, halfLane - 1, homePerHand);
        var rightLanes = DistributeHomeLanes(halfLane, _laneCount - 1, homePerHand);
        var leftXs = new List<float>(); foreach (int l in leftLanes) leftXs.Add(CalcLaneX(l));
        var rightXs = new List<float>(); foreach (int l in rightLanes) rightXs.Add(CalcLaneX(l));

        if (caps == 1)
        {
            var t = NewTouch(0); t.Hand = -1; t.HomeX = CalcLaneX(_laneCount / 2);
            var all = new List<float>(); all.AddRange(leftXs); all.AddRange(rightXs);
            t.HandHomes = all.ToArray(); t.LastPressX = t.HomeX; _touches.Add(t);
            return;
        }
        int leftCount = (int)System.Math.Ceiling(caps / 2.0);
        int rightCount = caps - leftCount;
        for (int i = 0; i < leftCount; i++)
        {
            var t = NewTouch(_touches.Count); t.Hand = 0; t.HandHomes = leftXs.ToArray();
            t.HomeX = leftXs[System.Math.Min(i, leftXs.Count - 1)]; t.LastPressX = t.HomeX; _touches.Add(t);
        }
        for (int i = 0; i < rightCount; i++)
        {
            var t = NewTouch(_touches.Count); t.Hand = 1; t.HandHomes = rightXs.ToArray();
            t.HomeX = rightXs[System.Math.Min(i, rightXs.Count - 1)]; t.LastPressX = t.HomeX; _touches.Add(t);
        }
    }

    private static List<int> DistributeHomeLanes(int start, int end, int count)
    {
        var lanes = new List<int>();
        if (count <= 0 || end < start) return lanes;
        if (count == 1) { lanes.Add((start + end) / 2); return lanes; }
        int span = end - start;
        for (int i = 0; i < count; i++)
        {
            int lane = start + (int)System.Math.Round(i * (double)span / (count - 1));
            lanes.Add(System.Math.Clamp(lane, start, end));
        }
        return lanes;
    }

    private static Touch NewTouch(int idx)
    {
        var t = new Touch();
        t.Index = idx; t.IsFree = true; t.LastPressTimeMs = float.NegativeInfinity; t.Hand = -1;
        return t;
    }

    // ========== 滑动触点位置 ==========
    private float TouchCurrentX(int touchIdx, float atMs)
    {
        var t = _touches[touchIdx];
        if (float.IsNegativeInfinity(t.LastPressTimeMs)) return t.HomeX;
        if (!t.IsFree) return t.LastPressX;
        if (!_handModelEnabled || t.HandHomes.Length == 0) return t.LastPressX;
        float nearest = NearestHomeX(t, t.LastPressX);
        float elapsed = (atMs - t.LastPressTimeMs) / 1000.0f;
        if (elapsed <= 0.0f) return t.LastPressX;
        float maxOff = _maxTouchVelocity * elapsed;
        float dist = System.Math.Abs(nearest - t.LastPressX);
        if (dist <= maxOff) return nearest;
        return nearest > t.LastPressX ? t.LastPressX + maxOff : t.LastPressX - maxOff;
    }

    private static float NearestHomeX(Touch t, float fromX)
    {
        float nearest = t.HandHomes[0];
        float minD = System.Math.Abs(nearest - fromX);
        foreach (float hx in t.HandHomes)
        {
            float d = System.Math.Abs(hx - fromX);
            if (d < minD) { minD = d; nearest = hx; }
        }
        return nearest;
    }

    private int BlockHand(float x) => x < _screenWidth * 0.5f ? 0 : 1;

    // 指定手（0 左 / 1 右）的全部手指是否都在该时刻握长条（该侧手已被长条占满）
    private bool HandFullyHoldingLong(int hand, float atMs)
    {
        bool any = false;
        foreach (var f in _touches)
        {
            if (f.Hand != hand) continue;
            any = true;
            if (!f.HoldingLongAt(atMs)) return false;
        }
        return any;
    }

    // 指定手当前握持的长条总数是否已达该手全部手指数（无空闲手指可再握新长条）
    private bool HandHoldingCapacityFull(int hand)
    {
        int count = 0;
        foreach (var f in _touches)
        {
            if (f.Hand != hand) continue;
            count++;
            if (f.HoldingLongCount <= 0) return false;   // 有手指空闲（当前未握任何长条）
        }
        return count > 0;
    }

    // 音符是否明显远离中心 reachable 区（另一只手跨不过来到这个位置）
    private bool FarFromCenter(float x, int nh)
    {
        float center = _screenWidth * 0.5f;
        float reach = _keyWidth * 0.5f;
        return nh == 0 ? x < center - reach : x > center + reach;
    }

    // ========== Step A 建块（仅建块 + 同刻过载保护，不含 Long 状态写入）==========
    private void BuildChords(int from, int to, List<BlockInfo> allBlocks)
    {
        int n = to;
        int i = from;
        while (i < n)
        {
            float chordStart = TickToMs(_inStartTick[i]);

            // 同刻合并 + 同 lane 去重（保高音）
            var laneMap = new Dictionary<int, int>(); // lane -> note idx
            int j = i;
            while (j < n)
            {
                if (TickToMs(_inStartTick[j]) - chordStart > CHORD_TOLERANCE_MS) break;
                int lane = _inPitch[j] % _laneCount;
                if (laneMap.TryGetValue(lane, out int existing))
                {
                    if (_inPitch[j] > _inPitch[existing]) { _bgNoteIdx.Add(existing); laneMap[lane] = j; }
                    else _bgNoteIdx.Add(j);
                }
                else laneMap[lane] = j;
                j++;
            }
            i = j;
            if (laneMap.Count == 0) continue;

            var chordBlocks = new List<BlockInfo>();
            foreach (var kv in laneMap)
            {
                int lane = kv.Key, note = kv.Value;
                float startMs = TickToMs(_inStartTick[note]);
                float durMs = TickDurToMs(_inStartTick[note], _inDurTick[note]);
                var b = GetBlock();
                b.Batch = _batchCounter; b.Lane = lane; b.StartMs = startMs; b.EndMs = startMs + durMs;
                b.DurMs = durMs; b.MainPitch = _inPitch[note]; b.X = CalcLaneX(lane);
                b.Type = durMs / 1000.0f <= _instantThr ? 1 : (durMs / 1000.0f <= _shortThr ? 0 : 2); // 基线类型
                b.Notes.Clear(); b.Notes.Add(note);
                chordBlocks.Add(b);
            }
            chordBlocks = EnforceMinSpacing(chordBlocks);
            if (_maxTouchCount > 0 && chordBlocks.Count > _maxTouchCount)
                RemoveOverload(chordBlocks);
            if (chordBlocks.Count == 0) continue;
            foreach (var bb in chordBlocks) allBlocks.Add(bb);
            _batchCounter++;
        }
    }

    // 同刻过载保护：手指不够时按类型删除，普通 Block 优先删，珍贵 Slide/Long 后删；同类低音优先
    private void RemoveOverload(List<BlockInfo> chordBlocks)
    {
        int needRemove = chordBlocks.Count - _maxTouchCount;
        for (int pass = 0; pass < 3 && needRemove > 0; pass++)
        {
            var cand = new List<BlockInfo>();
            foreach (var bb in chordBlocks)
            {
                bool isOrdinary = bb.DurMs / 1000.0f > _instantThr && bb.DurMs / 1000.0f <= _shortThr;
                bool isSlide = bb.DurMs / 1000.0f <= _instantThr;
                if (pass == 0 && isOrdinary) cand.Add(bb);      // 普通 Block
                else if (pass == 1 && isSlide) cand.Add(bb);    // Slide
                else if (pass == 2) cand.Add(bb);               // 剩余 Long
            }
            cand.Sort((a, b) => a.MainPitch.CompareTo(b.MainPitch));
            foreach (var eb in cand)
            {
                if (needRemove <= 0) break;
                if (eb.Notes.Count > 0) _bgNoteIdx.Add(eb.Notes[0]);
                chordBlocks.Remove(eb); needRemove--;
            }
        }
    }

    private BlockInfo GetBlock()
    {
        // 池化：多数窗口块在窗口结束会被 Clear，这里只在新 window 内新建
        var b = new BlockInfo();
        return b;
    }

    private List<BlockInfo> EnforceMinSpacing(List<BlockInfo> blocks)
    {
        if (blocks.Count <= 1 || _minBlockSpacing <= 0) return blocks;
        var sorted = new List<BlockInfo>(blocks);
        sorted.Sort((a, b) => b.MainPitch.CompareTo(a.MainPitch));
        var kept = new List<BlockInfo>();
        foreach (var block in sorted)
        {
            bool conflict = false;
            foreach (var kb in kept)
                if (System.Math.Abs(block.Lane - kb.Lane) <= _minBlockSpacing) { conflict = true; break; }
            if (conflict) { if (block.Notes.Count > 0) _bgNoteIdx.Add(block.Notes[0]); }
            else kept.Add(block);
        }
        return kept;
    }

    // ========== Step C 触点匹配与降级 ==========
    // Phase A：分配触点 + 降级（最终 Type）+ 推进时序/握持状态；不移动位置（钳位推迟到 Phase B）
    private void AssignTouchAndDegrade(List<BlockInfo> blocks)
    {
        if (blocks.Count == 0) return;
        // 无触点（maxTouchCount==0）时任意批 nb > nt，提前返回避免 Enumerate 越界
        if (_touches.Count == 0) return;
        var byBatch = new Dictionary<int, List<BlockInfo>>();
        foreach (var b in blocks)
        {
            if (!byBatch.TryGetValue(b.Batch, out var list)) { list = new List<BlockInfo>(); byBatch[b.Batch] = list; }
            list.Add(b);
        }
        var batchIds = new List<int>(byBatch.Keys); batchIds.Sort();
        foreach (int bid in batchIds)
        {
            var batch = byBatch[bid];
            MatchBlocksToTouches(batch);
            foreach (var b in batch) DegradeBlockType(b);
        }
    }

    // Phase A 逐个降级：只判类型 + 推进时序/握持状态，不移动位置
    private void DegradeBlockType(BlockInfo b)
    {
        if (b.TouchIndex < 0 || b.TouchIndex >= _touches.Count) return;
        var t = _touches[b.TouchIndex];

        // 长条已到的块释放其握持状态（长条结束前其触点不再空闲）
        if (t.HoldingLongEnd >= 0 && b.StartMs >= t.HoldingLongEnd)
        {
            t.HoldingLongEnd = float.NegativeInfinity;
            t.HoldingLongCount = 0;   // 该触点握持的长条已全部结束，握持数清零
        }

        // 最终降级判定（按 StartMs 升序处理，天然有序；用原始 lane，不受钳位漂移影响）
        // 规则 A：同轨 Long 压制；规则 B：连点过密压制；规则 C：触点正在握长条（手指占用，无法再按）→ Slide
        if (_laneLongEnd[b.Lane] > b.StartMs) b.Type = 1;
        else if (t.HoldingLongAt(b.StartMs)) b.Type = 1;
        else if (t.LastPressTimeMs >= 0)
        {
            float gap = (b.StartMs - t.LastPressTimeMs) / 1000.0f;
            if (gap < _minTapInterval) b.Type = 1;
        }
        // 规则 D：所属那只手的全部手指都被长条占满（如左手两指都按住长条、左边又来 block），
        // 且音符远离中心、另一只手指跨不过来 → 该侧无法点到的 Block → Slide（仅普通 Block）
        if (b.Type == 0)
        {
            int nh = BlockHand(b.X);
            if (HandFullyHoldingLong(nh, b.StartMs) && FarFromCenter(b.X, nh)) b.Type = 1;
        }

        // 规则 E：音符是长条时，若所属那只手的握持长条数已达该手全部手指数（无指可握新长条），
        // 则新长条退化为 Block——两边手指都被长条占满时，中间无法再握更多长条
        if (b.Type == 2 && HandHoldingCapacityFull(BlockHand(b.X)))
            b.Type = 0;

        // 独占写入 Long 状态：仅最终 Type == 2 才写（被降级绝不写）
        if (b.Type == 2)
        {
            // 同轨长条压制：结束时间额外延长一个连点最小时间，让长条后紧接的同轨 block 也被当作被按住而降级
            _laneLongEnd[b.Lane] = b.EndMs + (_cooldownSec + _minTapInterval) * 1000.0f;
            t.HoldingLongEnd = b.EndMs;   // 该触点握持长条直到 EndMs
            t.HoldingLongCount++;         // 该触点握持的长条数 +1
        }

        // 更新手指状态（位置用原始 X，仅供后续触点匹配启发式，Phase B 会重推）
        if (!t.IsFree)
        {
            float occupyEnd = t.LastPressTimeMs + _cooldownSec * 1000.0f;
            if (b.StartMs > occupyEnd) t.IsFree = true;
        }
        t.IsFree = false;
        t.LastPressTimeMs = b.StartMs;
        t.LastPressX = b.X;
    }

    // ========== Step C-B 密度削减后：仅对幸存音符推导手指移动并钳位 ==========
    private void RepositionSurvivors(List<BlockInfo> blocks)
    {
        if (blocks.Count == 0) return;
        // 重置每个触点手指链到初始态，幸存音符按时间序构成链条，无需贯穿被删音符
        foreach (var t in _touches)
        {
            t.LastPressTimeMs = float.NegativeInfinity;
            t.LastPressX = t.HomeX;
            t.IsFree = true;
            t.HoldingLongEnd = float.NegativeInfinity;   // 清握持状态，避免 Phase B 后残留
            t.HoldingLongCount = 0;
        }
        var byTouch = new Dictionary<int, List<BlockInfo>>();
        foreach (var b in blocks)
        {
            if (b.TouchIndex < 0 || b.TouchIndex >= _touches.Count) continue;
            if (!byTouch.TryGetValue(b.TouchIndex, out var list)) { list = new List<BlockInfo>(); byTouch[b.TouchIndex] = list; }
            list.Add(b);
        }
        foreach (var kv in byTouch)
        {
            var list = kv.Value;
            var t = _touches[kv.Key];
            foreach (var b in list)
            {
                float tx = TouchCurrentX(t.Index, b.StartMs);
                float dt = (b.StartMs - t.LastPressTimeMs) / 1000.0f;
                float maxOff = _maxTouchVelocity * dt;
                float dist = System.Math.Abs(b.X - tx);
                if (dist > maxOff)
                {
                    b.X = b.X > tx ? tx + maxOff : tx - maxOff;
                    b.Lane = CalcLaneFromX(b.X);
                    b.X = CalcLaneX(b.Lane);
                    // 移动后 lane 已变，仅 Block 被钳进正在长条的轨道时降级 Slide（Long 保持原类型）
                    if (b.Type == 0 && _laneLongEnd[b.Lane] > b.StartMs) b.Type = 1;
                }
                t.LastPressTimeMs = b.StartMs;
                t.LastPressX = b.X;
            }
        }
        // 轨道重排后再按轨道复检连点间隔：音符被移/钳到新轨道后，
        // 需与"新轨道上其前一个音符"的时间差 >= 连点最小时间，否则降级 Slide。
        // 规则 B 只查同一手指的上一按，音符换轨后参照已失真，这里用轨道修正。
        var laneLast = new float[_laneCount];
        for (int k = 0; k < _laneCount; k++) laneLast[k] = float.NegativeInfinity;
        foreach (var b in blocks)   // blocks 至此已按 StartMs 有序（BuildChords 建成即有序，中间步骤不打乱）
        {
            // Long 换轨后若与同轨前一音符连点过密也降级 Slide，避免 BLock/Long 同轨紧接被跳过
            if (b.Type != 1 && b.StartMs - laneLast[b.Lane] < _minTapInterval * 1000.0f)
                b.Type = 1;
            laneLast[b.Lane] = b.StartMs;
        }
    }

    private void MatchBlocksToTouches(List<BlockInfo> group)
    {
        int nb = group.Count, nt = _touches.Count;
        var sorted = new List<BlockInfo>(group);
        sorted.Sort((a, b) => a.X.CompareTo(b.X));
        // nb <= nt 由 BuildChords 过载保护保证；_touches 为空（maxTouchCount==0）时已在入口提前返回
        var best = new int[nb];
        for (int i = 0; i < nb; i++) best[i] = -1;
        bool found = Enumerate(nb, nt, true, sorted, best);
        if (!found)
        {
            for (int i = 0; i < nb; i++) best[i] = -1;
            Enumerate(nb, nt, false, sorted, best);
        }
        sorted.Sort((a, b) => a.StartMs.CompareTo(b.StartMs));
        for (int i = 0; i < nb; i++) sorted[i].TouchIndex = best[i];
    }

    private float ComboCost(int k, int nt, List<BlockInfo> sorted, int[] combo)
    {
        float cost = 0.0f;
        for (int i = 0; i < k; i++)
        {
            var blk = sorted[i]; var t = _touches[combo[i]];
            float tx = TouchCurrentX(t.Index, blk.StartMs);
            float dist = System.Math.Abs(tx - blk.X);
            cost += dist;
            if (t.LastPressTimeMs >= 0)
            {
                float dt = (blk.StartMs - t.LastPressTimeMs) / 1000.0f;
                if (dt > 0)
                {
                    float maxFeas = _maxTouchVelocity * dt;
                    if (dist > maxFeas) cost += (dist - maxFeas) * 10.0f;
                }
            }
            if (_handModelEnabled && t.Hand >= 0 && _maxTouchCount >= 2)
            {
                if (BlockHand(blk.X) != t.Hand) cost += _screenWidth * CROSS_HAND_PENALTY_MULT;
                cost += System.Math.Abs(t.HomeX - blk.X) * HOME_BIAS_COEFF;
            }
        }
        return cost;
    }

    private bool HardConstraintOk(int k, List<BlockInfo> sorted, int[] combo)
    {
        for (int i = 0; i < k; i++)
        {
            var blk = sorted[i]; var t = _touches[combo[i]];
            // 触点正在握长条：该手指已被长条占用，不可再分配给其他块（被握到长条结束，非仅冷却）
            if (t.HoldingLongAt(blk.StartMs)) return false;
            if (t.LastPressTimeMs >= 0)
            {
                float occupyEnd = t.LastPressTimeMs + _cooldownSec * 1000.0f;
                if (blk.StartMs < occupyEnd) return false;
            }
            if (t.LastPressTimeMs >= 0)
            {
                float dt = (blk.StartMs - t.LastPressTimeMs) / 1000.0f;
                if (dt > 0)
                {
                    float tx = TouchCurrentX(t.Index, blk.StartMs);
                    float req = System.Math.Abs(blk.X - tx) / dt;
                    if (req > _maxTouchVelocity) return false;
                }
            }
        }
        return true;
    }

    private bool Enumerate(int k, int nTouches, bool hard, List<BlockInfo> sorted, int[] outMatch)
    {
        var combo = new int[k];
        for (int i = 0; i < k; i++) combo[i] = i;
        float minCost = float.PositiveInfinity;
        bool found = false;
        while (true)
        {
            if (hard && !HardConstraintOk(k, sorted, combo))
            {
                int skip = k - 1;
                while (skip >= 0 && combo[skip] == nTouches - k + skip) skip--;
                if (skip < 0) break;
                combo[skip]++;
                for (int j = skip + 1; j < k; j++) combo[j] = combo[j - 1] + 1;
                continue;
            }
            float c = ComboCost(k, nTouches, sorted, combo);
            if (c < minCost) { minCost = c; System.Array.Copy(combo, outMatch, k); found = true; }
            int idx = k - 1;
            while (idx >= 0 && combo[idx] == nTouches - k + idx) idx--;
            if (idx < 0) break;
            combo[idx]++;
            for (int j = idx + 1; j < k; j++) combo[j] = combo[j - 1] + 1;
        }
        return found;
    }

    // ========== Step 5.5 密度削减 ==========
    private void ReduceDensity(List<BlockInfo> allBlocks)
    {
        if (_densityCapPerSec <= 0 || allBlocks.Count == 0) return;
        float budget = _densityCapPerSec;
        var groupsByBatch = new Dictionary<int, (List<BlockInfo> blocks, float time, double cost, double prio, bool slideOnly)>();
        foreach (var b in allBlocks)
        {
            if (!groupsByBatch.TryGetValue(b.Batch, out var g)) g = (new List<BlockInfo>(), b.StartMs, 0, 0, false);
            g.blocks.Add(b);
            groupsByBatch[b.Batch] = g;
        }
        var secondGroups = new Dictionary<int, List<int>>(); // sec -> batch ids
        foreach (var kv in groupsByBatch)
        {
            var g = kv.Value;
            var m = ComputeMetrics(g.blocks);
            g.cost = m.cost; g.prio = m.prio; g.slideOnly = m.slideOnly;
            groupsByBatch[kv.Key] = g;
            int sec = (int)System.Math.Floor(g.time / 1000.0);
            if (!secondGroups.TryGetValue(sec, out var list)) { list = new List<int>(); secondGroups[sec] = list; }
            list.Add(kv.Key);
        }
        var keptBatches = new HashSet<int>();
        foreach (var kv in secondGroups)
        {
            int sec = kv.Key;
            var batchIds = kv.Value;
            float slotW = 1000.0f / budget;
            int nSlots = _densityCapPerSec;
            var skeleton = new Dictionary<int, int>(); // slot -> batch
            for (int idx = 0; idx < batchIds.Count; idx++)
            {
                int bid = batchIds[idx];
                var g = groupsByBatch[bid];
                float tInSec = g.time - sec * 1000.0f;
                int slot = (int)System.Math.Min(System.Math.Floor(tInSec / slotW), nSlots - 1);
                if (!skeleton.TryGetValue(slot, out int cur) || g.prio > groupsByBatch[cur].prio)
                    skeleton[slot] = bid;
            }
            var keptIdx = new HashSet<int>();
            double totalCost = 0;
            foreach (int bid in skeleton.Values) { keptIdx.Add(bid); totalCost += groupsByBatch[bid].cost; }
            if (totalCost > budget)
            {
                var slideEject = new List<int>(); var nonSlideEject = new List<int>();
                foreach (int bid in keptIdx)
                { if (groupsByBatch[bid].slideOnly) slideEject.Add(bid); else nonSlideEject.Add(bid); }
                slideEject.Sort((a, b) => groupsByBatch[a].prio.CompareTo(groupsByBatch[b].prio));
                foreach (int bid in slideEject)
                {
                    if (totalCost <= budget) break;
                    if (!keptIdx.Contains(bid)) continue;
                    keptIdx.Remove(bid); totalCost -= groupsByBatch[bid].cost;
                }
                if (totalCost > budget)
                {
                    nonSlideEject.Sort((a, b) => groupsByBatch[a].prio.CompareTo(groupsByBatch[b].prio));
                    foreach (int bid in nonSlideEject)
                    {
                        if (totalCost <= budget) break;
                        if (!keptIdx.Contains(bid)) continue;
                        keptIdx.Remove(bid); totalCost -= groupsByBatch[bid].cost;
                    }
                }
            }
            if (totalCost < budget)
            {
                double remainder = budget - totalCost;
                var candidates = new List<int>();
                foreach (int bid in batchIds)
                    if (!keptIdx.Contains(bid) && groupsByBatch[bid].cost <= remainder) candidates.Add(bid);
                candidates.Sort((a, b) => groupsByBatch[b].prio.CompareTo(groupsByBatch[a].prio));
                foreach (int bid in candidates)
                    if (groupsByBatch[bid].cost <= remainder) { keptIdx.Add(bid); remainder -= groupsByBatch[bid].cost; }
            }
            foreach (int bid in keptIdx)
                foreach (var b in groupsByBatch[bid].blocks) keptBatches.Add(b.Batch);
        }
        int w = 0;
        for (int i = 0; i < allBlocks.Count; i++)
        {
            var b = allBlocks[i];
            if (keptBatches.Contains(b.Batch)) allBlocks[w++] = b;
            else foreach (int note in b.Notes) _bgNoteIdx.Add(note);
        }
        allBlocks.RemoveRange(w, allBlocks.Count - w);
    }

    private (double cost, double prio, bool slideOnly) ComputeMetrics(List<BlockInfo> blocks)
    {
        int count = blocks.Count;
        if (count == 0) return (0, 0, false);
        double cost = 0; int velSum = 0, maxPitch = 0, nonSlide = 0;
        foreach (var b in blocks)
        {
            bool isSlide = b.Type == 1;
            cost += isSlide ? 0.33 : 1.0;
            if (!isSlide) nonSlide++;
            if (b.Notes.Count > 0) velSum += _inVelocity[b.Notes[0]];
            if (b.MainPitch > maxPitch) maxPitch = b.MainPitch;
        }
        double avgVel = velSum / (double)count;
        double prio = 1.5 * avgVel / 127.0 + 1.5 * maxPitch / 127.0;
        prio -= 0.3 * System.Math.Max(0, nonSlide - 1);
        return (cost, prio, nonSlide == 0);
    }

    // ========== Step 7 转 GameSequence（SOA 输出）+ 填充手动索引 ==========
    // 手动 = 全部 game 原音符；每 seq 恰 1 个音符（BuildChords 按 lane 去重），故 manual_at(seq_index) 即该 seq 原音符
    private void ConvertToSequences(List<BlockInfo> blocks)
    {
        foreach (var b in blocks)
        {
            if (b.Notes.Count == 0) continue;
            int main = b.Notes[0];
            int key = _nextKeyId++;
            _seqKeyId.Add(key);
            _seqPitch.Add(_inPitch[main]);
            _seqStart.Add(b.StartMs);
            _seqDur.Add(b.DurMs);
            _seqType.Add(b.Type);
            _seqLane.Add(b.Lane);
            foreach (int note in b.Notes) _manualIdx.Add(note);
        }
    }

    // ========== Step 8 背景排序 + 分类 ==========
    private void FinalizeBackgroundAndClassify()
    {
        // 背景单音符块（BuildChords/ReduceDensity 已直写 _bgNoteIdx），按 (时间, 音高) 排序
        var idx = new List<int>(_bgNoteIdx.Count);
        for (int i = 0; i < _bgNoteIdx.Count; i++) idx.Add(i);
        idx.Sort((a, b) =>
        {
            float ta = TickToMs(_inStartTick[_bgNoteIdx[a]]), tb = TickToMs(_inStartTick[_bgNoteIdx[b]]);
            if (ta == tb) return _inPitch[_bgNoteIdx[a]].CompareTo(_inPitch[_bgNoteIdx[b]]);
            return ta.CompareTo(tb);
        });
        var sorted = new List<int>(_bgNoteIdx.Count);
        foreach (int i in idx) sorted.Add(_bgNoteIdx[i]);
        _bgNoteIdx.Clear();
        _bgNoteIdx.AddRange(sorted);

        // 自动 = 背景（手动已在 ConvertToSequences 填充）
        _autoIdx.Clear();
        _autoIdx.AddRange(_bgNoteIdx);
    }

    // ========== 输出访问器 ==========
    public int GameSeqCount => _seqKeyId.Count;
    public int SeqKeyId(int i) => _seqKeyId[i];
    public int SeqPitch(int i) => _seqPitch[i];
    public float SeqStartMs(int i) => _seqStart[i];
    public float SeqDurMs(int i) => _seqDur[i];
    public int SeqType(int i) => _seqType[i];
    public int SeqLane(int i) => _seqLane[i];
    public int BgNoteCount => _bgNoteIdx.Count;
    public int BgNoteAt(int j) => _bgNoteIdx[j];
    public int ManualCount => _manualIdx.Count;
    public int ManualAt(int i) => _manualIdx[i];
    public int AutoCount => _autoIdx.Count;
    public int AutoAt(int i) => _autoIdx[i];

    // ========== 输入音符访问器（manual/auto 索引指向 enabled 输入数组）==========
    public int InputCount => _inStartTick.Length;
    public int InputStartTickAt(int i) => _inStartTick[i];
    public int InputPitchAt(int i) => _inPitch[i];
    public int InputVelocityAt(int i) => _inVelocity[i];
    public int InputTrackAt(int i) => _inTrack[i];
    public int InputChannelAt(int i) => _inChannel[i];

    /// <summary>清空输出（PlayView 退出时释放，避免单槽缓存常驻）</summary>
    public void ClearOutput()
    {
        _seqKeyId.Clear(); _seqPitch.Clear(); _seqStart.Clear(); _seqDur.Clear();
        _seqType.Clear(); _seqLane.Clear(); _bgNoteIdx.Clear(); _manualIdx.Clear(); _autoIdx.Clear();
    }

    private class Touch
    {
        public int Index;
        public bool IsFree = true;
        public float LastPressX;
        public float LastPressTimeMs = float.NegativeInfinity;
        public int Hand = -1;
        public float HomeX;
        public float[] HandHomes = System.Array.Empty<float>();

        // 该触点当前正在握持的长条绝对结束时刻（-inf 表示未握长条），用于"手指占用"判定
        public float HoldingLongEnd = float.NegativeInfinity;
        public bool HoldingLongAt(float t) => HoldingLongEnd >= t;
        // 该触点当前正握的长条数（跨批累计，规则 E 用：长条无指可握时退化为 Block）
        public int HoldingLongCount;
    }

    private class BlockInfo
    {
        public readonly List<int> Notes = new();
        public int Batch;
        public int Lane;
        public float X;
        public float StartMs;
        public float EndMs;
        public float DurMs;
        public int Type;        // 0 Block 1 Slide 2 Long（基线由 BuildChords 按时长赋，最终由降级判定覆盖）
        public int TouchIndex = -1;
        public int MainPitch;
    }
}
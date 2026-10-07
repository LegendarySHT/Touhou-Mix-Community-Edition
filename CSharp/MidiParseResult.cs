using System.Collections.Generic;

/// <summary>
/// <see cref="MidiParserNative.ParsePlain"/> 的解析产物：**纯托管**（零 Godot 对象），
/// 可安全跨线程传递与读取。
///
/// 之所以单独成类而不是沿用 Godot.Collections.Dictionary：
/// 熄屏/深后台时 Godot 主循环停摆，只有音频回调与后台线程在跑，后台线程接管「曲终 → 下一首」
/// 时必须按需解析谱面。Godot 容器（Dictionary / PackedInt32Array）跨线程创建会与冻结的主线程
/// 抢引擎全局锁，轻则卡住、重则未定义行为。故解析层只产出托管数组，
/// 需要喂给 GDScript 的容器包装改在**主线程按需**完成（见 MidiParserNative.Parse 与
/// MidiCore 的 GetSoaArrays / GetBpmTimeline / GetTrackInstruments）。
/// </summary>
public sealed class MidiParseResult
{
    /// <summary>解析是否成功；false 时仅 <see cref="Error"/> 有效</summary>
    public bool Success;

    /// <summary>失败原因（成功时为 null）</summary>
    public string Error;

    // ===== 6 个并行 SOA 数组（按 start_tick 升序）=====
    public int[] Pitches = System.Array.Empty<int>();
    public int[] Velocities = System.Array.Empty<int>();
    public int[] StartTicks = System.Array.Empty<int>();
    public int[] Durations = System.Array.Empty<int>();
    public int[] TrackIndices = System.Array.Empty<int>();
    public int[] Channels = System.Array.Empty<int>();

    // ===== 标量 =====
    public double Bpm = 120.0;
    public double DurationMs;
    public int Timebase = 480;
    public int MaxEndTick;
    public int TrackCount;

    // ===== BPM 时间线（三个并行数组）=====
    public int[] BpmTicks = System.Array.Empty<int>();
    public float[] BpmBpms = System.Array.Empty<float>();
    public float[] BpmTimesMs = System.Array.Empty<float>();

    // ===== (track, channel) 音符分组：组键 / 前缀和 offsets（长度 = 组数+1）/ 扁平索引 =====
    public int[] GroupKeys = System.Array.Empty<int>();
    public int[] GroupOffsets = System.Array.Empty<int>();
    public int[] GroupIndices = System.Array.Empty<int>();

    /// <summary>分组统计耗时（诊断用）</summary>
    public double GroupTimeMs;

    /// <summary>轨道 → 通道 → (bank, program)。纯托管嵌套字典，任意线程可读。</summary>
    public Dictionary<int, Dictionary<int, (int bank, int program)>> TrackInstruments = new();

    /// <summary>整体解析耗时（诊断用）</summary>
    public double ParseTimeMs;

    public static MidiParseResult Fail(string msg)
    {
        // 错误信息通过返回值传递给调用方（push_error/日志由调用方决定），不在 C# 侧调 GD.Print
        System.Diagnostics.Debug.WriteLine($"[MidiParserNative] {msg}");
        return new MidiParseResult { Success = false, Error = msg };
    }
}

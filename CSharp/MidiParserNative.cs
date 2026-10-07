using Godot;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;

/// <summary>
/// C# 原生 SMF 解析器 + 业务逻辑（note_on/off 配对 / BPM 时间线 / 排序 / 乐器提取）
/// 替代 GDScript 的 SMF.addon + MidiParser 业务层
///
/// 【线程模型】解析本身**纯 .NET**：<see cref="ParsePlain"/> 只产出托管数组（int[] / float[] /
/// 托管字典），可在任意线程执行，包括熄屏时接管换曲的后台线程。
/// 面向 GDScript 的 <see cref="Parse"/> 只是它的适配层，会把结果包成 Godot 容器
/// （Dictionary + PackedInt32Array），**必须主线程调用**。
/// 需要引擎容器的调用方请走主线程入口，后台路径一律用 ParsePlain。
/// </summary>
[GlobalClass]
public partial class MidiParserNative : RefCounted
{
    /// <summary>
    /// 面向 GDScript 的适配入口：解析后包装成 Godot 容器。
    /// **仅主线程调用**（会创建 Godot.Collections.Dictionary / PackedInt32Array）。
    /// </summary>
    public Godot.Collections.Dictionary Parse(byte[] bytes)
    {
        var r = ParsePlain(bytes);
        if (!r.Success)
        {
            return new Godot.Collections.Dictionary { { "success", false }, { "error_msg", r.Error } };
        }
        var godotInstruments = new Godot.Collections.Dictionary();
        foreach (var trackPair in r.TrackInstruments)
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
            godotInstruments[trackPair.Key] = trackDict;
        }
        return new Godot.Collections.Dictionary
        {
            { "success", true },
            { "pitches", r.Pitches },
            { "velocities", r.Velocities },
            { "start_ticks", r.StartTicks },
            { "durations", r.Durations },
            { "track_indices", r.TrackIndices },
            { "channels", r.Channels },
            { "bpm", r.Bpm },
            { "duration_ms", r.DurationMs },
            { "timebase", r.Timebase },
            { "bpm_timeline_ticks", r.BpmTicks },
            { "bpm_timeline_bpms", r.BpmBpms },
            { "bpm_timeline_times_ms", r.BpmTimesMs },
            { "track_channel_groups_keys", r.GroupKeys },
            { "track_channel_groups_offsets", r.GroupOffsets },
            { "track_channel_groups_indices", r.GroupIndices },
            { "track_channel_groups_time_ms", r.GroupTimeMs },
            { "max_end_tick", r.MaxEndTick },
            { "track_count", r.TrackCount },
            { "track_instruments", godotInstruments },
            { "parse_time_ms", r.ParseTimeMs },
        };
    }

    /// <summary>
    /// 解析 MIDI 字节流为**纯托管**结果（零 Godot 对象），任意线程可调用。
    /// internal：返回类型 MidiParseResult 不是 Godot 可编组类型，不该出现在 GDScript 绑定里。
    /// </summary>
    internal MidiParseResult ParsePlain(byte[] bytes)
    {
        var sw = Stopwatch.StartNew();
        try
        {
            using var stream = new MemoryStream(bytes);
            using var reader = new BinaryReader(stream, System.Text.Encoding.ASCII);

            // 1. 读 MThd 头
            var chunkType = ReadFourCC(reader);
            if (chunkType != "MThd")
                return MidiParseResult.Fail($"Invalid MThd header: '{chunkType}'");

            var headerSize = ReadInt32BigEndian(reader);
            if (headerSize < 6)
                return MidiParseResult.Fail("Invalid MThd size");

            var format = ReadInt16BigEndian(reader);
            if (format != 0 && format != 1)
                return MidiParseResult.Fail($"Unsupported MIDI format: {format}");

            var trackCount = ReadInt16BigEndian(reader);
            var resolution = ReadInt16BigEndian(reader);

            if (headerSize > 6)
                reader.BaseStream.Position += headerSize - 6;

            // 2. note_on pending map: {channel: {pitch: Queue<PendingNote>}}
            // 用 Queue (FIFO) 匹配原 GDScript pop_front 行为
            var noteOnMap = new Dictionary<int, Dictionary<int, Queue<PendingNote>>>();
            var notes = new List<NoteData>(65536);

            // BPM 时间线
            var bpmTicks = new List<int>();
            var bpmValues = new List<double>();
            var bpmTimesMs = new List<double>();
            double currentBpm = 120.0;
            bpmTicks.Add(0);
            bpmValues.Add(currentBpm);
            bpmTimesMs.Add(0.0);

            // 乐器提取
            var trackChannelBanks = new Dictionary<int, Dictionary<int, int>>();
            var trackInstruments = new Dictionary<int, Dictionary<int, (int bank, int program)>>();
            var trackChannelsSeen = new Dictionary<int, HashSet<int>>();

            int maxEndTick = 0;

            // 3. 逐 track 读 MTrk
            for (int trackIdx = 0; trackIdx < trackCount; trackIdx++)
            {
                var banks = new Dictionary<int, int>();
                for (int ch = 0; ch < 16; ch++)
                    banks[ch] = (ch == 9) ? 128 : 0;
                trackChannelBanks[trackIdx] = banks;
                trackInstruments[trackIdx] = new Dictionary<int, (int, int)>();
                trackChannelsSeen[trackIdx] = new HashSet<int>();

                var trkChunkType = ReadFourCC(reader);
                if (trkChunkType != "MTrk")
                    return MidiParseResult.Fail($"Invalid MTrk header: '{trkChunkType}' at track {trackIdx}");

                var trackEnd = (long)ReadInt32BigEndian(reader);
                trackEnd += reader.BaseStream.Position;

                int tick = 0;
                byte lastStatus = 0;

                while (reader.BaseStream.Position < trackEnd)
                {
                    var delta = ReadVariableLength(reader);
                    tick += delta;
                    var first = reader.ReadByte();

                    // Running status: MSB=0 表示数据字节，复用上次 status
                    if ((first & 0x80) == 0)
                    {
                        var command = lastStatus & 0xF0;
                        if (command == 0xC0 || command == 0xD0)
                        {
                            ProcessChannelEvent(lastStatus, first, 0, tick, trackIdx,
                                notes, noteOnMap, ref maxEndTick,
                                banks, trackInstruments[trackIdx], trackChannelsSeen[trackIdx]);
                        }
                        else
                        {
                            var data2 = reader.ReadByte();
                            ProcessChannelEvent(lastStatus, first, data2, tick, trackIdx,
                                notes, noteOnMap, ref maxEndTick,
                                banks, trackInstruments[trackIdx], trackChannelsSeen[trackIdx]);
                        }
                        continue;
                    }

                    switch (first)
                    {
                        case 0xF0:
                        case 0xF7:
                            DiscardData(reader);
                            break;

                        case 0xFF:
                            {
                                var metaType = reader.ReadByte();
                                if (metaType == 0x2F) // End of Track
                                {
                                    reader.ReadByte();
                                    if (reader.BaseStream.Position < trackEnd)
                                        reader.BaseStream.Position = trackEnd;
                                    goto trackDone;
                                }
                                else if (metaType == 0x51) // Tempo
                                {
                                    var tempoSize = ReadVariableLength(reader);
                                    if (tempoSize != 3)
                                    {
                                        reader.BaseStream.Position += tempoSize;
                                    }
                                    else
                                    {
                                        var b1 = reader.ReadByte();
                                        var b2 = reader.ReadByte();
                                        var b3 = reader.ReadByte();
                                        var microsPerBeat = (b1 << 16) | (b2 << 8) | b3;
                                        if (microsPerBeat > 0)
                                        {
                                            currentBpm = 60000000.0 / microsPerBeat;
                                            bpmTicks.Add(tick);
                                            bpmValues.Add(currentBpm);
                                        }
                                    }
                                }
                                else
                                {
                                    DiscardData(reader);
                                }
                                break;
                            }

                        default:
                            {
                                var command = first & 0xF0;
                                if (command == 0xC0 || command == 0xD0)
                                {
                                    var data1 = reader.ReadByte();
                                    ProcessChannelEvent(first, data1, 0, tick, trackIdx,
                                        notes, noteOnMap, ref maxEndTick,
                                        banks, trackInstruments[trackIdx], trackChannelsSeen[trackIdx]);
                                }
                                else
                                {
                                    var data1 = reader.ReadByte();
                                    var data2 = reader.ReadByte();
                                    ProcessChannelEvent(first, data1, data2, tick, trackIdx,
                                        notes, noteOnMap, ref maxEndTick,
                                        banks, trackInstruments[trackIdx], trackChannelsSeen[trackIdx]);
                                }
                                break;
                            }
                    }

                    // system/meta 事件 (0xF0–0xFF) 应重置 running status，
                    // 避免 data 字节被误当作 channel 事件复用旧 status
                    if (first < 0xF0)
                        lastStatus = first;
                }

                trackDone:;
            }

            // 4. 未匹配 note_on 兜底（duration = 100 tick）
            foreach (var channelPair in noteOnMap)
            {
                foreach (var pitchPair in channelPair.Value)
                {
                    foreach (var pending in pitchPair.Value)
                    {
                        notes.Add(new NoteData
                        {
                            pitch = pending.pitch,
                            velocity = pending.velocity,
                            startTick = pending.startTick,
                            duration = 100,
                            trackIndex = pending.trackIndex,
                            channel = pending.channel
                        });
                    }
                }
            }

            // 5. 排序（按 startTick 升序，同 tick 时按 track → channel → pitch 保证跨平台稳定）
            notes.Sort((a, b) =>
            {
                var c = a.startTick.CompareTo(b.startTick);
                if (c != 0) return c;
                c = a.trackIndex.CompareTo(b.trackIndex);
                if (c != 0) return c;
                c = a.channel.CompareTo(b.channel);
                if (c != 0) return c;
                return a.pitch.CompareTo(b.pitch);
            });

            // 6. BPM 时间线：多 track 的 Tempo 事件可能乱序，须先按 tick 全局归并排序，
            //    否则时间线非单调，时长换算/累积会取错 BPM 段（如误按全程默认 BPM 计算）
            {
                var merged = new List<KeyValuePair<int, double>>(bpmTicks.Count);
                for (int i = 0; i < bpmTicks.Count; i++)
                    merged.Add(new KeyValuePair<int, double>(bpmTicks[i], bpmValues[i]));
                merged.Sort((a, b) => a.Key.CompareTo(b.Key));
                var ticks = new List<int>(merged.Count);
                var vals = new List<double>(merged.Count);
                foreach (var kv in merged)
                {
                    if (ticks.Count > 0 && ticks[ticks.Count - 1] == kv.Key)
                        vals[vals.Count - 1] = kv.Value; // 同 tick 后者覆盖
                    else
                    {
                        ticks.Add(kv.Key);
                        vals.Add(kv.Value);
                    }
                }
                bpmTicks = ticks;
                bpmValues = vals;
            }

            // 7. BPM 时间线 time_ms 计算（累积）
            for (int i = 1; i < bpmTicks.Count; i++)
            {
                var tickDelta = bpmTicks[i] - bpmTicks[i - 1];
                var bpm = bpmValues[i - 1];
                var msPerTick = (60000.0 / bpm) / resolution;
                bpmTimesMs.Add(bpmTimesMs[i - 1] + tickDelta * msPerTick);
            }

            // 8. duration 计算（从 maxEndTick + bpm_timeline）
            double durationMs = CalculateDurationMs(maxEndTick, bpmTicks, bpmValues, resolution);

            // 9. 乐器提取：对没有 program_change 的通道补充默认值
            foreach (var trackPair in trackChannelsSeen)
            {
                var trackIdx = trackPair.Key;
                var instruments = trackInstruments[trackIdx];
                var banks = trackChannelBanks[trackIdx];
                foreach (var channel in trackPair.Value)
                {
                    if (!instruments.ContainsKey(channel))
                        instruments[channel] = (banks[channel], 0);
                }
            }

            // 10. 打包返回
            var count = notes.Count;
            var pitches = new int[count];
            var velocities = new int[count];
            var startTicks = new int[count];
            var durations = new int[count];
            var trackIndices = new int[count];
            var channels = new int[count];

            for (int i = 0; i < count; i++)
            {
                var n = notes[i];
                pitches[i] = n.pitch;
                velocities[i] = n.velocity;
                startTicks[i] = n.startTick;
                durations[i] = n.duration;
                trackIndices[i] = n.trackIndex;
                channels[i] = n.channel;
            }

            // 11. (track, channel) 音符分组——C# worker 一次性统计，供 GDScript 侧快速重建
            //     避免 GDScript 逐键 COW/字符串哈希（22w 音符下可慢到秒级）。notes 按 start_tick 升序，
            //     逐元素 push 的下标 i 即 SOA 索引，故各分组内保持升序，与原始 grouped_indices 语义一致。
            var swGrp = System.Diagnostics.Stopwatch.StartNew();
            var grpKeys = new List<int>();                 // 组键：track<<8|channel，按首次出现顺序
            var grpOrder = new Dictionary<int, int>();     // 组键 -> 组序号
            var grpLists = new List<List<int>>();          // 每组的 SOA 索引
            for (int i = 0; i < count; i++)
            {
                int gk = (notes[i].trackIndex << 8) | (notes[i].channel & 0xFF);
                if (!grpOrder.TryGetValue(gk, out int gi))
                {
                    gi = grpLists.Count;
                    grpOrder[gk] = gi;
                    grpKeys.Add(gk);
                    grpLists.Add(new List<int>());
                }
                grpLists[gi].Add(i);
            }
            int gCount = grpKeys.Count;
            var gKeys = new int[gCount];
            var gOffsets = new int[gCount + 1];            // 前缀和，len=组数+1（末尾哨兵）
            int gTotal = 0;
            for (int g = 0; g < gCount; g++)
            {
                gKeys[g] = grpKeys[g];
                gOffsets[g] = gTotal;
                gTotal += grpLists[g].Count;
            }
            gOffsets[gCount] = gTotal;
            var gIndices = new int[gTotal];
            int gW = 0;
            for (int g = 0; g < gCount; g++)
                foreach (var idx in grpLists[g]) gIndices[gW++] = idx;
            swGrp.Stop();

            var tlCount = bpmTicks.Count;
            var tlTicks = new int[tlCount];
            var tlBpms = new float[tlCount];
            var tlTimesMs = new float[tlCount];
            for (int i = 0; i < tlCount; i++)
            {
                tlTicks[i] = bpmTicks[i];
                tlBpms[i] = (float)bpmValues[i];
                tlTimesMs[i] = (float)bpmTimesMs[i];
            }

            sw.Stop();

            return new MidiParseResult
            {
                Success = true,
                Pitches = pitches,
                Velocities = velocities,
                StartTicks = startTicks,
                Durations = durations,
                TrackIndices = trackIndices,
                Channels = channels,
                Bpm = currentBpm,
                DurationMs = durationMs,
                Timebase = resolution,
                BpmTicks = tlTicks,
                BpmBpms = tlBpms,
                BpmTimesMs = tlTimesMs,
                GroupKeys = gKeys,
                GroupOffsets = gOffsets,
                GroupIndices = gIndices,
                GroupTimeMs = swGrp.Elapsed.TotalMilliseconds,
                MaxEndTick = maxEndTick,
                TrackCount = trackCount,
                TrackInstruments = trackInstruments,
                ParseTimeMs = sw.Elapsed.TotalMilliseconds,
            };
        }
        catch (Exception ex)
        {
            sw.Stop();
            return MidiParseResult.Fail($"Exception during parse: {ex.Message}");
        }
    }

    private struct PendingNote
    {
        public int pitch;
        public int velocity;
        public int startTick;
        public int trackIndex;
        public int channel;
    }

    private struct NoteData
    {
        public int pitch;
        public int velocity;
        public int startTick;
        public int duration;
        public int trackIndex;
        public int channel;
    }

    private void ProcessChannelEvent(
        byte status, int data1, int data2, int tick, int trackIdx,
        List<NoteData> notes, Dictionary<int, Dictionary<int, Queue<PendingNote>>> noteOnMap,
        ref int maxEndTick,
        Dictionary<int, int> banks,
        Dictionary<int, (int bank, int program)> instruments,
        HashSet<int> channelsSeen)
    {
        var channel = status & 0x0F;
        var command = status & 0xF0;

        channelsSeen.Add(channel);

        switch (command)
        {
            case 0x80: // note_off
                MatchNoteOff(noteOnMap, channel, data1, tick, notes);
                if (tick > maxEndTick) maxEndTick = tick;
                break;

            case 0x90: // note_on
                if (data2 > 0)
                {
                    if (!noteOnMap.ContainsKey(channel))
                        noteOnMap[channel] = new Dictionary<int, Queue<PendingNote>>();
                    if (!noteOnMap[channel].ContainsKey(data1))
                        noteOnMap[channel][data1] = new Queue<PendingNote>();
                    noteOnMap[channel][data1].Enqueue(new PendingNote
                    {
                        pitch = data1,
                        velocity = data2,
                        startTick = tick,
                        trackIndex = trackIdx,
                        channel = channel
                    });
                }
                else
                {
                    MatchNoteOff(noteOnMap, channel, data1, tick, notes);
                }
                if (tick > maxEndTick) maxEndTick = tick;
                break;

            case 0xB0: // control_change
                if (data1 == 0) // Bank Select MSB
                {
                    if (channel == 9)
                        banks[channel] = 128;
                    else
                        banks[channel] = (banks[channel] & 0x7F) | (data2 << 7);
                }
                else if (data1 == 32) // Bank Select LSB
                {
                    if (channel == 9)
                        banks[channel] = 128;
                    else
                        banks[channel] = (banks[channel] & 0x3F80) | (data2 & 0x7F);
                }
                break;

            case 0xC0: // program_change
                instruments[channel] = (banks[channel], data1);
                break;
        }
    }

    private void MatchNoteOff(
        Dictionary<int, Dictionary<int, Queue<PendingNote>>> noteOnMap,
        int channel, int pitch, int tick, List<NoteData> notes)
    {
        if (!noteOnMap.ContainsKey(channel)) return;
        var pitchMap = noteOnMap[channel];
        if (!pitchMap.ContainsKey(pitch)) return;
        var queue = pitchMap[pitch];
        if (queue.Count == 0) return;

        // FIFO: Dequeue 取最早的 NoteOn（与原 GDScript pop_front 行为一致）
        var pending = queue.Dequeue();
        var duration = tick - pending.startTick;
        notes.Add(new NoteData
        {
            pitch = pending.pitch,
            velocity = pending.velocity,
            startTick = pending.startTick,
            duration = duration,
            trackIndex = pending.trackIndex,
            channel = pending.channel
        });

        if (queue.Count == 0)
            pitchMap.Remove(pitch);
    }

    private double CalculateDurationMs(int maxTick, List<int> bpmTicks, List<double> bpmValues, int resolution)
    {
        // bpmTicks 在 Parse 中已初始化为 {0, 120.0}，Count 恒 ≥ 1
        double cumulativeMs = 0.0;

        for (int i = 0; i < bpmTicks.Count; i++)
        {
            var entryTick = bpmTicks[i];
            double nextTick;
            if (i + 1 < bpmTicks.Count)
                nextTick = bpmTicks[i + 1];
            else
                nextTick = maxTick + 1000000;

            if (maxTick < nextTick)
            {
                // maxTick 在当前 BPM 段内
                var bpm = bpmValues[i];
                var tickDelta = maxTick - entryTick;
                var msPerTick = (60000.0 / bpm) / resolution;
                return cumulativeMs + tickDelta * msPerTick;
            }
            else
            {
                // 累加当前完整段的时间
                if (i + 1 < bpmTicks.Count)
                {
                    var tickDelta = bpmTicks[i + 1] - entryTick;
                    var bpm = bpmValues[i];
                    var msPerTick = (60000.0 / bpm) / resolution;
                    cumulativeMs += tickDelta * msPerTick;
                }
            }
        }

        return cumulativeMs;
    }

    // ========== 大端读取辅助 ==========

    private static string ReadFourCC(BinaryReader reader)
    {
        var b1 = reader.ReadByte();
        var b2 = reader.ReadByte();
        var b3 = reader.ReadByte();
        var b4 = reader.ReadByte();
        return new string(new[] { (char)b1, (char)b2, (char)b3, (char)b4 });
    }

    private static short ReadInt16BigEndian(BinaryReader reader)
    {
        return (short)(reader.ReadByte() << 8 | reader.ReadByte());
    }

    private static int ReadInt32BigEndian(BinaryReader reader)
    {
        return reader.ReadByte() << 24 | reader.ReadByte() << 16 | reader.ReadByte() << 8 | reader.ReadByte();
    }

    private static int ReadVariableLength(BinaryReader reader)
    {
        int value = 0;
        for (int i = 0; i < 4; i++)
        {
            var b = reader.ReadByte();
            value = (value << 7) | (b & 0x7F);
            if ((b & 0x80) == 0) break;
        }
        return value;
    }

    private static void DiscardData(BinaryReader reader)
    {
        var size = ReadVariableLength(reader);
        reader.BaseStream.Position += size;
    }
}

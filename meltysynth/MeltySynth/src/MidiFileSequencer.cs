using System;
using System.Diagnostics;
using System.Collections.Generic;

namespace MeltySynth
{
    /// <summary>
    /// An instance of the MIDI file sequencer.
    /// </summary>
    /// <remarks>
    /// Note that this class does not provide thread safety.
    /// If you want to control playback and render the waveform in separate threads,
    /// you must make sure that the methods are not called at the same time.
    /// </remarks>
    public sealed class MidiFileSequencer : IAudioRenderer
    {
        private readonly Synthesizer synthesizer;

        private float speed;

        private MidiFile? midiFile;
        private bool loop;

        private int blockWrote;

        private TimeSpan currentTime;
        private int msgIndex;
        private int loopIndex;

        private bool useSystemClock;
        private bool isPaused;
        private long clockBaseTimestamp;
        private TimeSpan clockBasePosition;
        private TimeSpan pausePosition;
        private TimeSpan renderedTime;

        private bool diagnosticsEnabled;
        private double driftEmaMs;
        private double maxAbsDriftMs;
        private double latestDriftMs;
        private int driftSampleCount;

        private MessageHook? onSendMessage;

        /// <summary>
        /// Initializes a new instance of the sequencer.
        /// </summary>
        /// <param name="synthesizer">The synthesizer to be used by the sequencer.</param>
        public MidiFileSequencer(Synthesizer synthesizer)
        {
            if (synthesizer == null)
            {
                throw new ArgumentNullException(nameof(synthesizer));
            }

            this.synthesizer = synthesizer;

            speed = 1F;
            useSystemClock = false;
            isPaused = false;
            diagnosticsEnabled = false;
        }

        /// <summary>
        /// Plays the MIDI file.
        /// </summary>
        /// <param name="midiFile">The MIDI file to be played.</param>
        /// <param name="loop">If <c>true</c>, the MIDI file loops after reaching the end.</param>
        public void Play(MidiFile midiFile, bool loop)
        {
            if (midiFile == null)
            {
                throw new ArgumentNullException(nameof(midiFile));
            }

            this.midiFile = midiFile;
            this.loop = loop;

            blockWrote = synthesizer.BlockSize;

            currentTime = TimeSpan.Zero;
            msgIndex = 0;
            loopIndex = 0;
            pausePosition = TimeSpan.Zero;
            clockBasePosition = TimeSpan.Zero;
            clockBaseTimestamp = Stopwatch.GetTimestamp();
            renderedTime = TimeSpan.Zero;
            isPaused = false;
            ResetDiagnostics();

            synthesizer.Reset();
        }

        /// <summary>
        /// Stops playing.
        /// </summary>
        public void Stop()
        {
            midiFile = null;
            isPaused = false;
            currentTime = TimeSpan.Zero;
            pausePosition = TimeSpan.Zero;
            clockBasePosition = TimeSpan.Zero;
            renderedTime = TimeSpan.Zero;

            synthesizer.Reset();
        }

        /// <summary>
        /// Sets whether the sequencer position is driven by system clock.
        /// </summary>
        /// <param name="enabled">If <c>true</c>, system clock mode is enabled.</param>
        public void SetSystemClockMode(bool enabled)
        {
            if (useSystemClock == enabled)
            {
                return;
            }

            var position = Position;
            useSystemClock = enabled;
            currentTime = position;
            pausePosition = position;
            clockBasePosition = position;
            clockBaseTimestamp = Stopwatch.GetTimestamp();
            renderedTime = position;
        }

        /// <summary>
        /// Seeks to the specified playback position.
        /// </summary>
        /// <param name="position">Target position.</param>
        public void Seek(TimeSpan position)
        {
            if (midiFile == null)
            {
                return;
            }

            if (position < TimeSpan.Zero)
            {
                position = TimeSpan.Zero;
            }

            if (position > midiFile.Length)
            {
                position = midiFile.Length;
            }

            currentTime = position;
            pausePosition = position;
            clockBasePosition = position;
            clockBaseTimestamp = Stopwatch.GetTimestamp();
            // Keep the raw audio-callback clock at the seek target. Without
            // this, get_raw_position_ms() briefly exposes the pre-seek clock
            // after the queued seek is committed.
            renderedTime = position;

            var nextIndex = 0;
            var latestLoopIndex = 0;
            while (nextIndex < midiFile.Messages.Length)
            {
                if (midiFile.Times[nextIndex] >= position)
                {
                    break;
                }

                nextIndex++;
            }

            synthesizer.Reset();

            // 【seek 噪音修复】原实现会把目标位置之前的全部事件一次性重放：
            // 密集谱面中成千上万个 note-on/note-off 会在同一帧内集中触发，
            // 产生"seek 后大量音符同时爆发"的噪音。
            // 改为状态重建：只按序重放通道状态消息（Program/CC/PitchBend 等），
            // 音符仅对目标时刻仍在发声的键补发 note-on；已结束的音符直接跳过。
            latestLoopIndex = ReconstructSeekState(nextIndex);

            msgIndex = nextIndex;
            loopIndex = latestLoopIndex;
            blockWrote = synthesizer.BlockSize;
        }

        /// <summary>
        /// 状态重建式 seek：重建目标时刻的合成器状态而不触发历史音符。
        /// </summary>
        /// <param name="nextIndex">目标位置之后的第一个消息索引（不含目标时刻本身）。</param>
        /// <returns>目标位置之前最近的 LoopStart 索引（仅循环模式使用）。</returns>
        private int ReconstructSeekState(int nextIndex)
        {
            var latestLoopIndex = 0;

            // 每个虚拟通道中"当前按下且尚未释放"的键（按按下顺序）及其力度。
            var heldNotes = new Dictionary<int, List<(byte Key, byte Velocity)>>();

            for (var i = 0; i < nextIndex; i++)
            {
                var msg = midiFile.Messages[i];
                if (msg.Type == MidiFile.MessageType.LoopStart)
                {
                    if (loop)
                    {
                        latestLoopIndex = i;
                    }
                    continue;
                }

                if (msg.Type != MidiFile.MessageType.Normal)
                {
                    continue;
                }

                var virtualChannel = synthesizer.GetVirtualChannelId(msg.TrackIndex, msg.Channel);
                var command = msg.Command & 0xF0;
                var data1 = msg.Data1;
                var data2 = msg.Data2;

                if (command == 0x90 && data2 > 0) // Note On
                {
                    if (!heldNotes.TryGetValue(virtualChannel, out var held))
                    {
                        held = new List<(byte, byte)>();
                        heldNotes[virtualChannel] = held;
                    }

                    // 同键重复 note-on 视为重触发：移除旧记录后追加，保持按下顺序。
                    var index = held.FindIndex(p => p.Item1 == data1);
                    if (index >= 0)
                    {
                        held.RemoveAt(index);
                    }
                    held.Add((data1, data2));
                    continue; // 延后到末尾统一触发，避免历史音符爆发
                }

                if (command == 0x80 || (command == 0x90 && data2 == 0)) // Note Off
                {
                    if (heldNotes.TryGetValue(virtualChannel, out var held))
                    {
                        var index = held.FindIndex(p => p.Item1 == data1);
                        if (index >= 0)
                        {
                            held.RemoveAt(index);
                        }
                    }
                    continue; // 已结束的音符不再触发
                }

                if (command == 0xB0 && (data1 == 0x78 || data1 == 0x7B))
                {
                    // All Sound Off / All Notes Off：清空按住集合，并让合成器真正执行。
                    heldNotes.Remove(virtualChannel);
                    SendRaw(virtualChannel, msg.Command, data1, data2, midiFile.Ticks[i]);
                    continue;
                }

                // 通道状态消息（Program Change / CC / Pitch Bend / Pressure 等）
                // 按序重放以重建音色、音量、弯音等状态；不产生音符，开销可忽略。
                SendRaw(virtualChannel, msg.Command, data1, data2, midiFile.Ticks[i]);
            }

            // 补发目标时刻仍在发声的 note-on。此时通道状态（音色/音量/弯音）已就位；
            // 按最初按下顺序触发，与真实播放中的触发顺序一致。
            foreach (var channelPair in heldNotes)
            {
                foreach (var note in channelPair.Value)
                {
                    SendRaw(channelPair.Key, 0x90, note.Key, note.Velocity, 0);
                }
            }

            return latestLoopIndex;
        }

        private void SendRaw(int virtualChannel, int command, int data1, int data2, int tick)
        {
            if (onSendMessage == null)
            {
                synthesizer.ProcessMidiMessage(virtualChannel, command, data1, data2);
            }
            else
            {
                onSendMessage(synthesizer, virtualChannel, command, data1, data2, tick);
            }
        }

        /// <summary>
        /// Pauses playback time progression.
        /// </summary>
        public void Pause()
        {
            if (midiFile == null || isPaused)
            {
                return;
            }

            pausePosition = Position;
            currentTime = pausePosition;
            // Keep the raw callback clock at the last rendered sample. In system-clock
            // mode Position may be ahead of the device callback by output latency.
            if (!useSystemClock)
            {
                renderedTime = pausePosition;
            }
            isPaused = true;
        }

        /// <summary>
        /// Resumes playback time progression from paused position.
        /// </summary>
        public void Resume()
        {
            if (midiFile == null || !isPaused)
            {
                return;
            }

            currentTime = pausePosition;
            clockBasePosition = pausePosition;
            clockBaseTimestamp = Stopwatch.GetTimestamp();
            isPaused = false;
        }

        /// <inheritdoc/>
        public void Render(Span<float> left, Span<float> right)
        {
            if (left.Length != right.Length)
            {
                throw new ArgumentException("The output buffers for the left and right must be the same length.");
            }

            var wrote = 0;
            while (wrote < left.Length)
            {
                if (blockWrote == synthesizer.BlockSize)
                {
                    if (useSystemClock)
                    {
                        if (!isPaused)
                        {
                            currentTime = GetSystemClockPosition();
                            if (diagnosticsEnabled)
                            {
                                var driftMs = (currentTime - renderedTime).TotalMilliseconds;
                                UpdateDiagnostics(driftMs);
                            }
                        }
                        ProcessEvents();
                    }
                    else
                    {
                        ProcessEvents();
                        if (!isPaused)
                        {
                            currentTime += MidiFile.GetTimeSpanFromSeconds((double)speed * synthesizer.BlockSize / synthesizer.SampleRate);
                        }
                    }

                    blockWrote = 0;
                }

                var srcRem = synthesizer.BlockSize - blockWrote;
                var dstRem = left.Length - wrote;
                var rem = Math.Min(srcRem, dstRem);

                synthesizer.Render(left.Slice(wrote, rem), right.Slice(wrote, rem));

                blockWrote += rem;
                wrote += rem;

                if (!isPaused)
                {
                    renderedTime += MidiFile.GetTimeSpanFromSeconds((double)speed * rem / synthesizer.SampleRate);
                }
            }
        }

        private void ProcessEvents()
        {
            if (midiFile == null)
            {
                return;
            }

            while (msgIndex < midiFile.Messages.Length)
            {
                var time = midiFile.Times[msgIndex];
                var tick = midiFile.Ticks[msgIndex];
                var msg = midiFile.Messages[msgIndex];
                if (time <= currentTime)
                {
                    if (msg.Type == MidiFile.MessageType.Normal)
                    {
                        SendMessage(msg, tick);
                    }
                    else if (loop)
                    {
                        if (msg.Type == MidiFile.MessageType.LoopStart)
                        {
                            loopIndex = msgIndex;
                        }
						else if (msg.Type == MidiFile.MessageType.LoopEnd)
						{
							currentTime = midiFile.Times[loopIndex];
							// RenderedPosition is the audio-callback clock consumed by
							// vocal synchronization. Keep it loop-relative like currentTime;
							// otherwise loop detection sees a monotonic clock and cannot
							// restart a vocal track that reached EOF.
							renderedTime = currentTime;
							msgIndex = loopIndex;
							synthesizer.NoteOffAll(false);

                            if (useSystemClock && !isPaused)
                            {
                                clockBasePosition = currentTime;
                                clockBaseTimestamp = Stopwatch.GetTimestamp();
                            }
                        }
                    }
                    msgIndex++;
                }
                else
                {
                    break;
                }
            }

			if (msgIndex == midiFile.Messages.Length && loop)
			{
				currentTime = midiFile.Times[loopIndex];
				// See the LoopEnd path above: raw audio time must wrap with MIDI.
				renderedTime = currentTime;
				msgIndex = loopIndex;
                synthesizer.NoteOffAll(false);

                if (useSystemClock && !isPaused)
                {
                    clockBasePosition = currentTime;
                    clockBaseTimestamp = Stopwatch.GetTimestamp();
                }
            }
        }

        private void SendMessage(MidiFile.Message msg, int tick)
        {
            var virtualChannel = synthesizer.GetVirtualChannelId(msg.TrackIndex, msg.Channel);
            SendRaw(virtualChannel, msg.Command, msg.Data1, msg.Data2, tick);
        }


        private TimeSpan GetSystemClockPosition()
        {
            var elapsedTicks = Stopwatch.GetTimestamp() - clockBaseTimestamp;
            if (elapsedTicks <= 0)
            {
                return clockBasePosition;
            }

            var elapsedSeconds = elapsedTicks / (double)Stopwatch.Frequency;
            var scaledSeconds = elapsedSeconds * speed;
            var position = clockBasePosition + MidiFile.GetTimeSpanFromSeconds(scaledSeconds);

            if (midiFile != null && !loop && position > midiFile.Length)
            {
                return midiFile.Length;
            }

            return position;
        }

        private void ResetDiagnostics()
        {
            driftEmaMs = 0.0;
            maxAbsDriftMs = 0.0;
            latestDriftMs = 0.0;
            driftSampleCount = 0;
        }

        private void UpdateDiagnostics(double driftMs)
        {
            latestDriftMs = driftMs;
            var absDrift = Math.Abs(driftMs);
            if (absDrift > maxAbsDriftMs)
            {
                maxAbsDriftMs = absDrift;
            }

            const double alpha = 0.1;
            if (driftSampleCount == 0)
            {
                driftEmaMs = driftMs;
            }
            else
            {
                driftEmaMs = driftEmaMs + alpha * (driftMs - driftEmaMs);
            }

            driftSampleCount++;
        }
        /// <summary>
        /// Gets the synthesizer used by the sequencer.
        /// </summary>
        public Synthesizer Synthesizer => synthesizer;

        /// <summary>
        /// Gets the currently playing MIDI file.
        /// </summary>
        public MidiFile? MidiFile => midiFile;

        /// <summary>
        /// Gets the current playback position.
        /// </summary>
        public TimeSpan Position
        {
            get
            {
                if (midiFile == null)
                {
                    return currentTime;
                }

                if (useSystemClock && !isPaused)
                {
                    return GetSystemClockPosition();
                }

                return currentTime;
            }
        }

        /// <summary>
        /// Gets the position of the audio samples rendered by the audio callback.
        /// Unlike Position, this never uses the system stopwatch.
        /// </summary>
        public TimeSpan RenderedPosition => renderedTime;

        /// <summary>
        /// Gets a value that indicates whether the current playback position is at the end of the sequence.
        /// </summary>
        /// <remarks>
        /// If the <see cref="Play(MidiFile, bool)">Play</see> method has not yet been called, this value is true.
        /// This value will never be <c>true</c> when loop playback is enabled.
        /// </remarks>
        public bool EndOfSequence
        {
            get
            {
                if (midiFile == null)
                {
                    return true;
                }
                else
                {
                    return msgIndex == midiFile.Messages.Length;
                }
            }
        }

        /// <summary>
        /// Gets a value indicating whether a MIDI file is currently loaded into the sequencer.
        /// </summary>
        /// <remarks>
        /// True only after <see cref="Play(MidiFile, bool)">Play</see> has been called with a non-null file,
        /// and before <see cref="Stop">Stop</see> is called. This is the reliable discriminator between
        /// "a real song is playing" and "no song is loaded" (e.g. manual-note / latency-calibration direct
        /// mode), where <see cref="EndOfSequence"/> is permanently <c>true</c>.
        /// </remarks>
        public bool IsSongLoaded => midiFile != null;

        /// <summary>
        /// Gets or sets the playback speed.
        /// </summary>
        /// <remarks>
        /// The default value is 1.
        /// The tempo will be multiplied by this value.
        /// </remarks>
        public float Speed
        {
            get => speed;

            set
            {
                if (value >= 0)
                {
                    if (useSystemClock && midiFile != null && !isPaused)
                    {
                        currentTime = GetSystemClockPosition();
                        clockBasePosition = currentTime;
                        clockBaseTimestamp = Stopwatch.GetTimestamp();
                    }

                    speed = value;
                }
                else
                {
                    throw new ArgumentOutOfRangeException("The playback speed must be a non-negative value.");
                }
            }
        }

        /// <summary>
        /// Gets a value indicating whether system clock mode is enabled.
        /// </summary>
        public bool UseSystemClock => useSystemClock;

        /// <summary>
        /// Gets a value indicating whether the sequencer is paused.
        /// </summary>
        public bool IsPaused => isPaused;

        /// <summary>
        /// Enables or disables runtime drift diagnostics.
        /// </summary>
        public void SetDiagnosticsEnabled(bool enabled)
        {
            diagnosticsEnabled = enabled;
            if (!enabled)
            {
                ResetDiagnostics();
            }
        }

        /// <summary>
        /// Gets drift diagnostics between system-clock target time and rendered sample time.
        /// </summary>
        public string GetDiagnosticsSnapshot()
        {
            return $"samples={driftSampleCount}, latest={latestDriftMs:F3}ms, ema={driftEmaMs:F3}ms, maxAbs={maxAbsDriftMs:F3}ms";
        }

        /// <summary>
        /// Gets or sets the method for modifying MIDI messages during playback.
        /// If <c>null</c>, MIDI messages are sent to the synthesizer without any changes.
        /// </summary>
        public MessageHook? OnSendMessage
        {
            get => onSendMessage;
            set => onSendMessage = value;
        }



        /// <summary>
        /// Represents the method that is called each time a MIDI message is processed during playback.
        /// </summary>
        /// <param name="synthesizer">The synthesizer used by the sequencer.</param>
        /// <param name="channel">The channel to which the message will be sent.</param>
        /// <param name="command">The type of the message.</param>
        /// <param name="data1">The first data part of the message.</param>
        /// <param name="data2">The second data part of the message.</param>
        /// <param name="tick">The absolute MIDI tick of the message.</param>
        public delegate void MessageHook(Synthesizer synthesizer, int channel, int command, int data1, int data2, int tick);
    }
}

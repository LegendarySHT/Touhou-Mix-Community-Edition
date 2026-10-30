using System;
using System.Diagnostics;

/// <summary>
/// MeltySynthPlayer 的「开局预卷：时钟接力」部分（partial class）。
///
/// 任何"先倒计时、再进正片"的模式（打歌、未来的其他玩法）都该走这三件套，别自己算起播时刻：
///   begin_preroll(剩余毫秒) → 拉起设备 + 算出提前起播量
///   tick_preroll(剩余毫秒)  → 每帧喂一次，到点自行 play()
///   end_preroll()           → 兜底起播，并回答"音频钟是否已越过 0"
/// 上层只持有倒计时，不需要知道延迟是多少、也不需要读设备延迟。
///
/// 【为什么必须提前起播】get_visual_position_ms() 是两层钳零：
///     judge  = max(0, wall - 输出延迟)
///     visual = max(0, judge - 校准延迟)
/// 起播后要爬满"输出延迟 + 校准延迟"位置才 > 0，这段时间上层读到的永远是 0。
/// 若等倒计时归零才 play()，上层视觉钟在这段里只能跟着停 —— 音符在屏幕上完全静止，
/// 帧率却是满的，任何掉帧检测都抓不到。真机实测 141~149ms，观感就是"开局顿一下"；
/// 首音符 0ms 的谱面看起来是"点第一批音符时顿"，首音符晚的谱面是"下落途中顿一下"。
/// 提前这段时间起播，"听到的位置"仍在倒计时归零时到 0，音画不错位。
/// </summary>
public partial class MeltySynthPlayer
{
	// ===== 预卷状态 =====
	private bool _prerollActive;
	private bool _prerollIssued;
	private bool _prerollCrossed;
	private double _prerollAheadMs;
	private double _prerollCalibMs;
	private long _prerollPlayTicks;
	// 实测"起播 → 位置越过 0"的时长，跨曲目复用。绑定当时的校准延迟，校准一改立即作废，
	// 避免换输出（蓝牙/扬声器）后沿用旧值。
	private double _prerollLearnedAheadMs = -1.0;
	private double _prerollLearnedCalibMs;

	/// <summary>提前起播至少给倒计时留下这么多毫秒，防止链延迟接近/超过预卷时长时音画错位。</summary>
	private const double PrerollMinRemainingMs = 150.0;
	/// <summary>实测值只在"与解析式差 1.5 帧以上"时启用 —— 说明解析式漏了某段延迟。</summary>
	private const double PrerollLearnToleranceMs = 24.0;

	/// <summary>
	/// 开始预卷（倒计时起算时调用）。返回本次提前起播量，仅供上层打日志/调试，不参与逻辑。
	/// </summary>
	public double begin_preroll(double remaining_ms)
	{
		// 设备必须先跑起来才读得到真实链路延迟。_prepare_game 通常已预热过，这里是幂等兜底：
		// "菜单续播"路径可能在上次暂停时把设备停掉了。
		prewarm_audio_device();

		_prerollCalibMs = _audioDelayMs;
		double analytic = get_output_latency_ms() + _audioDelayMs;
		double want = analytic;
		if (_prerollLearnedAheadMs > 0.0
			&& Math.Abs(_prerollLearnedCalibMs - _prerollCalibMs) < 0.5
			&& Math.Abs(_prerollLearnedAheadMs - analytic) > PrerollLearnToleranceMs)
		{
			// 减 8ms 抵掉"越过 0 只能在帧边界被观测到"的向上取整：宁可差一点导致极短静止，
			// 也不要高估而在交接帧让音符往前跳（那比静止更显眼）。
			want = Math.Max(0.0, _prerollLearnedAheadMs - 8.0);
		}

		_prerollAheadMs = Math.Clamp(want, 0.0, Math.Max(0.0, remaining_ms - PrerollMinRemainingMs));
		_prerollActive = true;
		_prerollIssued = false;
		_prerollCrossed = false;
		return _prerollAheadMs;
	}

	/// <summary>
	/// 每帧喂一次剩余毫秒（递减之后的值）。到点自行起播，重复调用无副作用。
	/// </summary>
	public void tick_preroll(double remaining_ms)
	{
		if (!_prerollActive)
		{
			return;
		}
		if (!_prerollIssued && remaining_ms <= _prerollAheadMs)
		{
			IssuePrerollPlayback();
		}
		CheckPrerollCrossed();
	}

	/// <summary>
	/// 倒计时归零时调用：兜底起播并交还控制权。
	/// 返回 true = 位置已越过 0，上层视觉钟可以直接交回软锚；
	/// 返回 false = 位置仍被钳在 0，上层需保留一小段硬锚（提前量估小）。
	/// </summary>
	public bool end_preroll()
	{
		if (!_prerollActive)
		{
			// 未经过 begin_preroll（例如上层直接起播）：按当前位置如实回答
			return get_visual_position_ms() > 0.0;
		}
		if (!_prerollIssued)
		{
			IssuePrerollPlayback();
		}
		CheckPrerollCrossed();
		_prerollActive = false;
		return get_visual_position_ms() > 0.0;
	}

	/// <summary>放弃预卷（未起播就叫停）：不改变播放状态，只清调度标记。</summary>
	public void cancel_preroll()
	{
		_prerollActive = false;
	}

	private void IssuePrerollPlayback()
	{
		_prerollIssued = true;
		_prerollPlayTicks = Stopwatch.GetTimestamp();
		// 预卷期间（设备停着）native producer 已把 vocal ring 填满：起播首帧偏移门控一放行，
		// 人声就从 ring 头部满音量瞬入 —— 人声文件开头非静音的曲目，听感就是起播时"呲的一声"。
		// 起播前清掉预填，让这条路径与人声随解码平滑进入的路径同一起点。
		reset_vocal_prefill();
		play();
		// 与 play_transport() 同一语义：状态翻转要广播出去（播放器页按钮/状态显示依赖它）
		EmitSignal(SignalName.playback_state_changed);
	}

	/// <summary>
	/// 记录"起播 → 位置越过 0"的实测时长，供下一局兜底。
	///
	/// 判据刻意不用 get_position_ms()：那个方法带 _seekPositionHoldFrames 递减副作用，
	/// 而约定是"每帧只允许上层读一次"，预卷里再读一次会打乱它。
	/// 这里直接看渲染钟是否已爬过两层延迟，等价且无副作用。
	/// </summary>
	private void CheckPrerollCrossed()
	{
		if (_prerollCrossed || !_prerollIssued || _sequencer == null || !_sequencerStarted)
		{
			return;
		}
		double need = get_output_latency_ms() + _audioDelayMs;
		if (_sequencer.RenderedPosition.TotalMilliseconds <= need)
		{
			return;
		}
		_prerollCrossed = true;
		double crossMs = (Stopwatch.GetTimestamp() - _prerollPlayTicks) * 1000.0 / Stopwatch.Frequency;
		if (crossMs > 0.0 && crossMs < 1000.0)
		{
			_prerollLearnedAheadMs = crossMs;
			_prerollLearnedCalibMs = _prerollCalibMs;
		}
	}
}

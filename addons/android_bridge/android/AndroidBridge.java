package com.godot.game;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.media.AudioDeviceCallback;
import android.media.AudioDeviceInfo;
import android.media.AudioManager;
import android.media.MediaMetadata;
import android.media.session.MediaSession;
import android.media.session.PlaybackState;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.SignalInfo;
import org.godotengine.godot.plugin.UsedByGodot;

import java.util.HashSet;
import java.util.Set;

/**
 * Android 侧 Godot 插件总入口（模块 addons/android_bridge）。
 *
 * 本模块承载「需要随导出注入的 Android Java 代码」：addons/android_bridge/android/ 下的
 * 所有 .java 会在导出时被同步进 gradle 工程（见 android_export_plugin.gd），新增 Android
 * 能力直接往该目录加文件即可，不必新建插件模块。
 *
 * 当前能力：
 *   1) 系统媒体会话：音频由 miniaudio 原生设备直接输出、不经过 Godot AudioServer，
 *      引擎侧无媒体集成，需自行挂 MediaSession 才能出现在通知栏/锁屏媒体控制中，
 *      并接收系统媒体键；配套 MediaSessionService 前台服务保后台播放。
 *   2) 音频输出设备变化监听：蓝牙/有线插拔时发出 audio_output_changed，
 *      上层据此立刻重算音频延迟预设（息屏时没有焦点事件，事件驱动才不会漏）。
 *
 * 契约（消费方为 C# 播放器 CSharp/MeltySynthPlayer.Transport.cs，它已接管全部播放真值；
 * GDScript 侧 Game/PlaybackDisplay.gd 只转发信号）：
 *   signal command_received(String action, double position_ms)
 *   signal audio_output_changed()
 *   signal bg_idle_release()
 *   update_state(boolean playing, double position_ms, double duration_ms,
 *                String title, String album, byte[] cover_png)
 *   clear()
 *
 * 系统下发的命令经 emitSignal 送达（Java 侧在 UI 线程 emit）。C# 侧走 GodotObject.Connect
 * 直连 command_received（Java 插件信号是真正的 Godot 信号，与 C# 自己 [Signal] 的注册差异无关）。
 */
public class AndroidBridge extends GodotPlugin {

	private static final String TAG = "AndroidBridge";

	private static final String CHANNEL_ID = "media_playback";
	static final int NOTIFICATION_ID = 0x7A3;

	private static final SignalInfo COMMAND_RECEIVED =
			new SignalInfo("command_received", String.class, Double.class);
	/** 音频输出设备增删（蓝牙/有线插拔）：上层据此立刻重算延迟预设，无需轮询 */
	private static final SignalInfo AUDIO_OUTPUT_CHANGED =
			new SignalInfo("audio_output_changed");
	/** 后台空闲超时：退到后台持续 BG_IDLE_RELEASE_DELAY_MS 后发出，上层据此回收内存。
	 *  必须由 Java 侧计时——Android 切后台后 Godot 主循环挂起，GDScript 的 _process /
	 *  Timer 都不再运行，引擎侧无法自行判断"后台已持续多久"。 */
	private static final SignalInfo BG_IDLE_RELEASE =
			new SignalInfo("bg_idle_release");

	/** 后台空闲判定时长（毫秒），与 GDScript 侧 MemoryGC 的语义一致 */
	private static final long BG_IDLE_RELEASE_DELAY_MS = 30000L;

	@Nullable
	private MediaSession session;

	/** 插件实例。服务的静态 attach 可能早于插件注册，故缓存待认领 */
	@Nullable
	private static AndroidBridge s_instance;
	@Nullable
	private static MediaSessionService s_pending_service;
	/** 上次提交给前台服务的通知内容标识，内容不变则不重复提交 */
	private String lastNotifiedKey = "";
	/** 上次尝试拉起前台服务的时间戳与退避间隔（后台拉起必被拒，退避避免日志刷屏） */
	private long _lastFgsAttemptUptimeMs = 0L;
	private static final long FGS_RETRY_BACKOFF_MS = 5000L;

	private boolean lastPlaying = false;
	/**
	 * 是否需要前台服务承载通知：播放页注册（update_state）后为 true，注销（clear）后为 false。
	 * 刻意不跟随播放态：切歌过程中会出现一次 playing=false，若据此撤下前台，
	 * 新歌开始时应用已在后台，系统禁止后台重新进前台，服务回不去 —— 通知消失、
	 * 进程失去保护被冻结，表现为"切歌后通知没了、歌也卡住、回前台才恢复"。
	 */
	private boolean foregroundWanted = false;
	/** 应用是否已进入后台（onMainPause/onMainResume 维护）：bg_tick 只在此时才需要 ——
	 *  后台时 Godot 的帧回调（_Process/Timer）不跑，曲终推进得靠它叫醒主线程。 */
	private volatile boolean appPaused = false;
	/** 上次推送的播放态与时刻：位置交给系统按 (position, speed, updated) 自行外推，
	 *  只在播放态变化或超时（漂移校正）时才重推。 */
	private boolean lastPushedPlaying = false;
	private long lastPushUptimeMs = 0L;
	private double lastPositionMs = 0.0;
	private double lastDurationMs = 0.0;
	private String lastTitle = "";
	private String lastAlbum = "";
	/** 最近一次的封面 PNG 字节与解码结果（字节相同则跳过重复解码） */
	@Nullable
	private byte[] lastCoverPng;
	@Nullable
	private android.graphics.Bitmap lastCover;
	/** [诊断] 前台服务启动失败原因，供 GDScript 侧查询 */
	private String lastFgsError = "";

	// ===== 后台换曲的曲目元数据（文件契约） =====
	//
	// 熄屏/深后台时 Godot 主循环挂起，GDScript 无法再下发 update_state，
	// 而 C# 侧的后台推进线程已经把歌换掉了 —— 结果通知区一直显示旧歌、
	// 进度条按旧时长取模回绕。C# 无公开 API 可反向调本插件（Engine.GetSingleton
	// 未暴露给 C#），故改用文件契约：C# 换曲成功后写 media_state.json，
	// 本插件的墙钟 ticker 每次轮询时检查该文件是否变更。
	//
	// 放在固定引导目录（不随玩家自定义存储根迁移），两端都能确定推导：
	//   /storage/emulated/0/Android/data/com.touhoumix.ce/files/media_state.json
	private static final String MEDIA_STATE_FILE = "media_state.json";
	/**
	 * 上一次已处理的发布版本号（C# 每次发布自增）。
	 * 初值 -2 而不是 -1：-1 是"文件里没有 version 字段"的取值，留作旧版文件仍按内容比对。
	 */
	private long _mediaStateVersion = -2L;
	/** 上一次已解码的封面路径：路径未变就不重复解码位图 */
	private String _mediaStateCoverPath = "";
	/** 只打印一次目录诊断，避免 ticker 每 500ms 刷屏 */
	private boolean _mediaStateDirLogged = false;

	public AndroidBridge(@NonNull Godot godot) {
		super(godot);
	}

	@NonNull
	@Override
	public String getPluginName() {
		return "AndroidBridge";
	}

	@NonNull
	@Override
	public Set<SignalInfo> getPluginSignals() {
		Set<SignalInfo> signals = new HashSet<>();
		signals.add(COMMAND_RECEIVED);
		signals.add(AUDIO_OUTPUT_CHANGED);
		signals.add(BG_IDLE_RELEASE);
		return signals;
	}

	/** 是否已订阅输出设备变化（重复调用幂等；GDScript 侧以「信号已连接」判断事件通路可用） */
	private boolean audioDeviceCallbackRegistered = false;

	/**
	 * 订阅音频输出设备增删（蓝牙/有线插拔）。上层收到 audio_output_changed 后立刻
	 * 重算延迟预设，避免息屏/后台时靠轮询才发现输出变了。
	 */
	@UsedByGodot
	public void register_audio_device_listener() {
		if (audioDeviceCallbackRegistered) {
			return;
		}
		Context context = getContext();
		if (context == null) {
			return;
		}
		AudioManager audioManager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
		if (audioManager == null) {
			return;
		}
		try {
			audioManager.registerAudioDeviceCallback(new AudioDeviceCallback() {
				@Override
				public void onAudioDevicesAdded(AudioDeviceInfo[] addedDevices) {
					emitSignal(AUDIO_OUTPUT_CHANGED);
				}

				@Override
				public void onAudioDevicesRemoved(AudioDeviceInfo[] removedDevices) {
					emitSignal(AUDIO_OUTPUT_CHANGED);
				}
			}, new Handler(Looper.getMainLooper()));
			audioDeviceCallbackRegistered = true;
			Log.i(TAG, "Audio device callback registered");
		} catch (Exception e) {
			Log.w(TAG, "registerAudioDeviceCallback failed: " + e.getMessage());
		}
	}

	/**
	 * GodotPlugin.onMainCreate 返回插件视图（可为 null），此处不贡献视图，
	 * 只借此时机在主线程建立 MediaSession —— 必须在主线程创建。
	 */
	@Override
	public android.view.View onMainCreate(@Nullable android.app.Activity activity) {
		runOnUiThread(this::ensureSession);
		return null;
	}

	// ===== 后台空闲计时（内存回收触发） =====
	// Android 切后台后 Godot 主循环挂起（同 _ticker 的处境），引擎侧 _process / Timer 均不运行，
	// 因此"后台已持续多久"只能由 Java 侧墙钟判断。此处只做计时与发信号，不做任何回收动作，
	// 具体释放由 GDScript 侧 MemoryGC 在收到信号时执行。
	//
	// 进出后台的钩子用 GodotPlugin.onMainPause / onMainResume：
	// Godot.onPause(host)/onResume(host) 会遍历插件回调这两个方法（已核对 godot-lib 字节码），
	// 在 UI 线程于引擎挂起前/恢复后触发，是插件能拿到的最可靠时机。
	private final Handler _bgWatchdog = new Handler(Looper.getMainLooper());
	/** 看门狗是否已排期（pause 可能多次回调，避免重复堆叠） */
	private boolean _bgWatchdogArmed = false;

	private final Runnable _bgIdleRunnable = new Runnable() {
		@Override
		public void run() {
			_bgWatchdogArmed = false;
			Log.i(TAG, "[DIAG] background idle " + (BG_IDLE_RELEASE_DELAY_MS / 1000L)
					+ "s -> emit bg_idle_release");
			emitSignal(BG_IDLE_RELEASE);
		}
	};

	@Override
	public void onMainPause() {
		super.onMainPause();
		appPaused = true;
		// 进后台立刻就发一次：此刻引擎可能仍在跑（onMainPause 在引擎挂起前回调），
		// 赶上就地释放，才是真正"在后台压内存"；发不出去也无副作用（信号只是请求，释放幂等）。
		Log.i(TAG, "[DIAG] onMainPause -> emit bg_idle_release (immediate)");
		emitSignal(BG_IDLE_RELEASE);
		// 兜底：若即时那次没被引擎处理（引擎随即被冻结），30 秒后再发一次，
		// 届时会在引擎恢复运行时被处理
		scheduleBackgroundWatchdog();
	}

	@Override
	public void onMainResume() {
		super.onMainResume();
		appPaused = false;
		cancelBackgroundWatchdog();
	}

	/** 进入后台：排期一次后台空闲判定 */
	private void scheduleBackgroundWatchdog() {
		if (_bgWatchdogArmed) {
			return;
		}
		_bgWatchdogArmed = true;
		_bgWatchdog.postDelayed(_bgIdleRunnable, BG_IDLE_RELEASE_DELAY_MS);
		Log.i(TAG, "[DIAG] onMainPause -> bg idle watchdog armed (" + (BG_IDLE_RELEASE_DELAY_MS / 1000L) + "s)");
	}

	/** 回到前台：取消判定（后台时长未达阈值则不回收） */
	private void cancelBackgroundWatchdog() {
		if (_bgWatchdogArmed) {
			Log.i(TAG, "[DIAG] onMainResume -> bg idle watchdog cancelled");
		}
		_bgWatchdogArmed = false;
		_bgWatchdog.removeCallbacks(_bgIdleRunnable);
	}

	/**
	 * MediaSessionService 在 onCreate 时登记自身，销毁时传 null 解绑。
	 * 服务早于插件就绪时先挂起，待会话建立后补认领。
	 */
	public static void attachService(@Nullable MediaSessionService svc) {
		AndroidBridge plugin = s_instance;
		if (plugin == null) {
			s_pending_service = svc;
			return;
		}
		plugin.service = svc;
	}

	/**
	 * 前台服务 onStartCommand 回调：把通知刷新为当前播放状态。
	 *
	 * 通知由本插件（持有播放状态与封面位图）构建，不经 Intent 传递——封面位图较大，
	 * 走 Binder 容易触发 TransactionTooLargeException。插件尚未注册时无人能提供内容，
	 * 结束服务撤掉占位通知（插件就绪后播放时会重新拉起）。
	 */
	static void onServiceReady(MediaSessionService svc) {
		AndroidBridge plugin = s_instance;
		if (plugin == null) {
			svc.stopSelf();
			return;
		}
		plugin.service = svc;
		plugin.pushForegroundNotification();
	}

	/** 服务进入前台用的占位通知（真实内容随后由 pushForegroundNotification 刷新） */
	static Notification buildPlaceholderNotification(Context context) {
		ensureChannel(context);
		return new Notification.Builder(context, CHANNEL_ID)
				.setSmallIcon(android.R.drawable.ic_media_play)
				.setContentTitle("Touhou Mix")
				.build();
	}

	@Nullable
	private MediaSessionService service;

	private void ensureSession() {
		if (session != null) {
			return;
		}
		Context context = getContext();
		if (context == null) {
			return;
		}
		try {
			session = new MediaSession(context, "TouhouMixSession");
			session.setCallback(new MediaSession.Callback() {
				@Override
				public void onPlay() {
					emitCommand("play", -1.0);
				}

				@Override
				public void onPause() {
					emitCommand("pause", -1.0);
				}

				@Override
				public void onStop() {
					emitCommand("stop", -1.0);
				}

				@Override
				public void onSkipToPrevious() {
					emitCommand("prev", -1.0);
				}

				@Override
				public void onSkipToNext() {
					emitCommand("next", -1.0);
				}

				@Override
				public void onSeekTo(long positionMs) {
					emitCommand("seek", positionMs);
				}
			});
			session.setFlags(MediaSession.FLAG_HANDLES_MEDIA_BUTTONS
					| MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS);
			session.setActive(true);
			s_instance = this;
			if (s_pending_service != null) {
				MediaSessionService svc = s_pending_service;
				s_pending_service = null;
				attachService(svc);
			}
			pushState();
		} catch (Exception e) {
			Log.e(TAG, "Failed to create MediaSession", e);
		}
	}

	@Override
	public void onMainDestroy() {
		// 后台空闲看门狗随插件一起撤下
		cancelBackgroundWatchdog();
		if (session != null) {
			session.setActive(false);
			session.release();
			session = null;
		}
		if (service != null) {
			// 引擎退出（任务被划掉/应用结束）：音频已随引擎停止，
			// 撤下通知并结束服务，避免留下没有播放器的僵尸前台通知
			service.stopForegroundPlayback();
			service.stopSelf();
			service = null;
		}
		if (s_instance == this) {
			s_instance = null;
		}
		super.onMainDestroy();
	}

	private void emitCommand(String action, double positionMs) {
		emitSignal(COMMAND_RECEIVED, action, positionMs);
	}

	@UsedByGodot
	public void update_state(boolean playing, double positionMs, double durationMs,
			String title, String album, byte[] coverPng) {
		runOnUiThread(() -> {
			lastPlaying = playing;
			lastPositionMs = positionMs;
			lastDurationMs = durationMs;
			lastTitle = title == null ? "" : title;
			lastAlbum = album == null ? "" : album;
			foregroundWanted = true;
			setCoverPng(coverPng);
			pushState();
		});
	}

	/** 封面字节变化时才重新解码 Bitmap，避免每次位置刷新都重解码 */
	private void setCoverPng(byte[] png) {
		if (png == null || png.length == 0) {
			lastCover = null;
			return;
		}
		if (lastCoverPng != null && java.util.Arrays.equals(lastCoverPng, png)) {
			return;
		}
		lastCoverPng = png.clone();
		android.graphics.Bitmap decoded = android.graphics.BitmapFactory
				.decodeByteArray(png, 0, png.length);
		if (decoded != null) {
			lastCover = decoded;
		}
	}

	@UsedByGodot
	public void clear() {
		runOnUiThread(() -> {
			// 播放页注销（离开播放页=退出播放）：撤下前台与通知
			foregroundWanted = false;
			lastPlaying = false;
			lastPositionMs = 0.0;
			lastDurationMs = 0.0;
			lastTitle = "";
			lastAlbum = "";
			lastNotifiedKey = "";
			pushState();
			// 播放页注销：通知撤下，ticker 也可以停了（没有任何人再需要文件轮询）
			cancelPositionTick();
		});
	}

	/** 供 GDScript 侧判断后端是否真的可用 */
	@UsedByGodot
	public boolean is_available() {
		return session != null;
	}

	/**
	 * media_state.json 的绝对路径（C# 播放器在熄屏后台换曲时写入、本类 ticker 读取）。
	 *
	 * 由 Java 侧给出而不是让 C# 硬编码：外部存储根并不总是 /storage/emulated/0
	 * （工作资料 / 副用户下是 /storage/emulated/&lt;userId&gt;/...），硬编码会让
	 * "后台换曲后通知栏与封面更新"静默失效 —— 两端读写不同文件，谁都不报错。
	 * 拿不到时返回空串，C# 侧回退到硬编码路径。
	 */
	@UsedByGodot
	public String get_media_state_path() {
		android.app.Activity activity = getActivity();
		if (activity == null) {
			return "";
		}
		java.io.File dir = activity.getExternalFilesDir(null);
		if (dir == null) {
			return "";
		}
		return new java.io.File(dir, MEDIA_STATE_FILE).getAbsolutePath();
	}

	/** [诊断] 前台服务是否已进入前台（后台播放的前提） */
	@UsedByGodot
	public boolean is_foreground_service_running() {
		return service != null && service.isForeground();
	}

	/** [诊断] 最近一次前台服务启动失败原因，空串表示无失败记录 */
	@UsedByGodot
	public String get_foreground_error() {
		return lastFgsError;
	}

	/**
	 * Android 13+ 通知为运行时权限，未授予时前台服务虽能运行但通知不可见，
	 * 系统媒体控制卡片也会缺失。切到播放页时调用一次即可（已授予则直接返回）。
	 */
	@UsedByGodot
	public void ensure_notification_permission() {
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
			return;
		}
		android.app.Activity activity = getActivity();
		if (activity == null) {
			return;
		}
		if (activity.checkSelfPermission("android.permission.POST_NOTIFICATIONS")
				== android.content.pm.PackageManager.PERMISSION_GRANTED) {
			return;
		}
		activity.requestPermissions(
				new String[]{"android.permission.POST_NOTIFICATIONS"}, 0x7A4);
	}

	/** 同步 PlaybackState / Metadata，并在播放中拉起前台服务 */
	private void pushState() {
		if (session == null) {
			ensureSession();
			if (session == null) {
				return;
			}
		}

		// 以本次下发的 lastPositionMs 为墙钟新基准。必须在读取位置之前：
		// 外部（媒体控件 seek / 换曲 / 循环回绕）会经 update_state 更新 lastPositionMs，
		// 若基准未重置，currentPositionMs() 会从旧基准继续推进，导致进度条不反映新位置。
		resetTickBase();

		MediaMetadata.Builder metadata = new MediaMetadata.Builder()
				.putString(MediaMetadata.METADATA_KEY_TITLE, lastTitle)
				.putString(MediaMetadata.METADATA_KEY_ALBUM, lastAlbum);
		if (lastCover != null) {
			metadata.putBitmap(MediaMetadata.METADATA_KEY_ART, lastCover);
		}
		if (lastDurationMs > 0.0) {
			metadata.putLong(MediaMetadata.METADATA_KEY_DURATION, (long) lastDurationMs);
		}
		session.setMetadata(metadata.build());

		PlaybackState.Builder state = new PlaybackState.Builder()
				.setActions(PlaybackState.ACTION_PLAY
						| PlaybackState.ACTION_PAUSE
						| PlaybackState.ACTION_PLAY_PAUSE
						| PlaybackState.ACTION_STOP
						| PlaybackState.ACTION_SEEK_TO
						| PlaybackState.ACTION_SKIP_TO_PREVIOUS
						| PlaybackState.ACTION_SKIP_TO_NEXT);
		if (lastPlaying) {
			long pos = (long) currentPositionMs();
			state.setState(PlaybackState.STATE_PLAYING, pos, 1.0f);
		} else if (lastPositionMs > 0.0) {
			state.setState(PlaybackState.STATE_PAUSED, (long) lastPositionMs, 0.0f);
		} else {
			state.setState(PlaybackState.STATE_STOPPED, 0L, 0.0f);
		}
		session.setPlaybackState(state.build());

		// 每次下发都以 lastPositionMs 为新基准：外部 seek（含暂停态下的 seek）后
		// 墙钟必须重新起算，否则进度条会从旧基准继续推进而不反映 seek 结果。
		//
		// ticker 只要会话还在就**常驻**：它的职责已不只是走进度，还负责在熄屏后台轮询
		// media_state.json（C# 后台换曲写下的新曲目）。一旦停掉，后台又不会再有 update_state
		// 来把它拉起来，就会永远不再读文件 —— 表现为"歌切了、卡片信息没切，拖动一次才恢复"。
		// 暂停态它只轮询文件、不做进度外推，开销极低。只在播放页注销（clear）时才停。
		schedulePositionTick();

		if (foregroundWanted) {
			// 播放或暂停都保持前台与通知（暂停只把通知换成播放图标），
			// 只在播放页注销（clear）时才撤下
			startForegroundPlayback();
		} else if (service != null) {
			service.stopForegroundPlayback();
			lastNotifiedKey = "";
		}
	}

	// ===== 进度条自走 =====
	// Android 切后台后 Godot 主循环挂起，_process 停止，GDScript 侧不再下发位置；
	// 而 PlaybackState 的 position 只是"某一刻的快照 + playback_rate 外推"，
	// 外推是线性的，歌曲循环时进度条会一路冲过末尾而不回到 0。
	// 故此处自带墙钟：按 SystemClock 推进位置，并对时长取模实现回绕。
	private final Handler _ticker = new Handler(Looper.getMainLooper());
	private long _tickBasePositionMs = 0L;
	private long _tickBaseUptimeMs = 0L;

	// 1s：系统按 PlaybackState(speed/updated) 自行外推进度，推送无须更密（更密只是徒增 JNI/系统服务开销）
	private static final long POSITION_TICK_INTERVAL_MS = 1000L;

	/** 以当前 lastPositionMs 重置墙钟基准：外部 seek/换曲/回绕后进度外推必须重新起算。 */
	private void resetTickBase() {
		_tickBasePositionMs = (long) lastPositionMs;
		_tickBaseUptimeMs = android.os.SystemClock.elapsedRealtime();
	}

	/** 依据墙钟推算当前位置；已知时长时按时长取模回绕（loop 由上层语义保证） */
	private double currentPositionMs() {
		if (!lastPlaying) {
			return lastPositionMs;
		}
		long now = android.os.SystemClock.elapsedRealtime();
		if (_tickBaseUptimeMs == 0L) {
			_tickBasePositionMs = (long) lastPositionMs;
			_tickBaseUptimeMs = now;
			return _tickBasePositionMs;
		}
		long pos = _tickBasePositionMs + (now - _tickBaseUptimeMs);
		if (lastDurationMs > 0.0 && pos > (long) lastDurationMs) {
			// 循环回绕：超出时长则取模
			pos = pos % (long) lastDurationMs;
			_tickBasePositionMs = pos;
			_tickBaseUptimeMs = now;
		}
		return pos;
	}

	/**
	 * 读取 C# 后台推进写下的曲目元数据（media_state.json）。
	 *
	 * 换歌判定用文件里的 version 字段（C# 每次发布自增），不用 mtime：部分存储/文件系统上
	 * rename 改写后 mtime 不变（实测表现为"第一次换曲更新了、之后每次换曲都不再更新"）。
	 * 也不能只靠内容比对：前台时 GDScript 会持续下发 update_state，把后台写下的旧曲目
	 * 与新状态比对会把正确值覆盖成旧值。version 未变化即视为"非本文件的换歌"，直接跳过。
	 * 封面按路径变化才重新解码，避免每 tick 重复解码位图。
	 *
	 * @return true 表示确实更新了歌名/时长（调用方需重置墙钟基准并推一次状态）
	 */
	private boolean pollMediaStateFile() {
		// 必须用 getExternalFilesDir（= /storage/emulated/0/Android/data/<pkg>/files），
		// 与 PathHelper.get_base_dir() 同址；getFilesDir() 是内部私有目录，两端读不到同一文件。
		// activity 为 null（极少数生命周期边界）时直接放弃：ticker 会继续排期重试，
		// 不能让它抛 NPE —— 那会崩在 UI 线程上，整个后台播放链路一起挂掉。
		android.app.Activity activity = getActivity();
		if (activity == null) {
			return false;
		}
		java.io.File dir = activity.getExternalFilesDir(null);
		if (dir == null) {
			Log.w(TAG, "[media-state] getExternalFilesDir returned null");
			return false;
		}
		java.io.File f = new java.io.File(dir, MEDIA_STATE_FILE);
		if (!_mediaStateDirLogged) {
			_mediaStateDirLogged = true;
			Log.i(TAG, "[media-state] watching " + f.getAbsolutePath()
					+ " exists=" + f.exists());
		}
		if (!f.exists()) {
			return false;
		}
		String json;
		try {
			json = new String(java.nio.file.Files.readAllBytes(f.toPath()),
					java.nio.charset.StandardCharsets.UTF_8);
		} catch (Exception e) {
			return false;   // 读失败（可能是半写文件），下个 tick 再试
		}
		// 版本未变化 = 与上次已处理的同一份内容：跳过。
		// 前台时 GDScript 每 0.5s 直接下发 update_state，若不跳过就会拿这份旧曲目覆盖前台正确值。
		long version = (long) extractJsonNumber(json, "version");
		if (version == _mediaStateVersion) {
			return false;
		}
		// 极简字段解析：格式由 C# 固定为 "key":"value" 的扁平 JSON，
		// 歌名可能含引号/反斜杠，故只做转义还原而不引第三方库。
		String title = extractJsonString(json, "title");
		double duration = extractJsonNumber(json, "duration_ms");
		if (title == null || duration <= 0.0) {
			Log.w(TAG, "[media-state] bad payload in " + f.getAbsolutePath()
					+ " title=" + title + " duration=" + duration);
			return false;   // 不记录 version，下个 tick 重试
		}
		_mediaStateVersion = version;
		String album = extractJsonString(json, "album");
		if (album == null) {
			album = "";
		}
		boolean changed = !title.equals(lastTitle) || duration != lastDurationMs
				|| !album.equals(lastAlbum);
		if (changed) {
			Log.i(TAG, "[media-state] read: " + title + " / " + album + " (" + (long) duration
					+ "ms) from " + f.getAbsolutePath());
			lastTitle = title;
			lastDurationMs = duration;
			lastPositionMs = 0.0;
			lastAlbum = album;
		}
		// 封面：C# 给出谱面封面文件的绝对路径，这里直接解码（后台主循环停摆，
		// GDScript 侧发不出新封面字节，只能走文件）。路径未变则跳过解码；
		// 读不到就保留旧封面，不置空。
		String coverPath = extractJsonString(json, "cover_path");
		if (coverPath != null && !coverPath.isEmpty() && !coverPath.equals(_mediaStateCoverPath)) {
			_mediaStateCoverPath = coverPath;
			try {
				android.graphics.Bitmap bmp = android.graphics.BitmapFactory.decodeFile(coverPath);
				if (bmp != null) {
					lastCover = bmp;
					lastCoverPng = null;   // 与 setCoverPng 的字节缓存解耦，避免下次误判为未变
					changed = true;
				} else {
					Log.w(TAG, "[media-state] cover decode failed: " + coverPath);
				}
			} catch (Exception e) {
				Log.w(TAG, "[media-state] cover read failed: " + coverPath + " " + e.getMessage());
			}
		}
		if (changed) {
			// 换歌：墙钟基准必须重置，否则进度条从旧基准继续推进
			resetTickBase();
		}
		return changed;
	}

	/** 取扁平 JSON 里的字符串字段（含 \" \\ \n 转义还原）；不存在或格式不符返回 null */
	private static String extractJsonString(String json, String key) {
		String needle = "\"" + key + "\":\"";
		int start = json.indexOf(needle);
		if (start < 0) {
			return null;
		}
		int i = start + needle.length();
		StringBuilder sb = new StringBuilder();
		while (i < json.length()) {
			char c = json.charAt(i);
			if (c == '\\' && i + 1 < json.length()) {
				char n = json.charAt(i + 1);
				if (n == '"' || n == '\\') {
					sb.append(n);
					i += 2;
					continue;
				}
				if (n == 'n') {
					sb.append('\n');
					i += 2;
					continue;
				}
			}
			if (c == '"') {
				return sb.toString();
			}
			sb.append(c);
			i++;
		}
		return null;
	}

	/** 取扁平 JSON 里的数值字段；不存在返回 -1 */
	private static double extractJsonNumber(String json, String key) {
		String needle = "\"" + key + "\":";
		int start = json.indexOf(needle);
		if (start < 0) {
			return -1.0;
		}
		int i = start + needle.length();
		int begin = i;
		while (i < json.length()) {
			char c = json.charAt(i);
			if ((c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.'
					|| c == 'e' || c == 'E') {
				i++;
			} else {
				break;
			}
		}
		if (begin == i) {
			return -1.0;
		}
		try {
			return Double.parseDouble(json.substring(begin, i));
		} catch (NumberFormatException e) {
			return -1.0;
		}
	}

	private final Runnable _tickRunnable = new Runnable() {
		@Override
		public void run() {
			_tickScheduled = false;
			if (session == null) {
				// 会话还没建好也别让 ticker 死掉（否则之后再没人把它拉起来）
				postNextTick();
				return;
			}
			// 后台换曲：C# 推进线程换了歌但主循环挂起、无法下发 update_state，
			// 这里主动检测 C# 写下的元数据并同步（换歌时重推一次状态）。
			// 暂停态同样要轮询——换曲可能就发生在暂停/曲终那一刻。
			boolean mediaStateChanged = pollMediaStateFile();
			if (mediaStateChanged) {
				pushState();
			}

			// 【喂主线程】熄屏/后台时**只有帧回调（_Process / Timer）不跑**，Godot 主线程仍在派发信号
			// （媒体按钮就是这么生效的）。曲终推进改由这里每秒叫醒主线程去做 —— 于是"自动切歌"与
			// "点按钮切歌"最终走同一份同步代码，不需要独立的后台换曲线程，也不需要回调内换手。
			if (appPaused && lastPlaying) {
				emitSignal(COMMAND_RECEIVED, "bg_tick", (double) currentPositionMs());
			}			if (!lastPlaying) {
				// 暂停态：只继续轮询元数据文件，不写 PLAYING 的进度自走
					// 单链保证：本轮工作里 pushState() 的 schedulePositionTick() 可能已经重排过，
					// 这里再无脑排一条就成两条链（表现为每秒发两次 tick、彼此差几毫秒）。
					if (!_tickScheduled)
					{
						postNextTick();
					}
				return;
			}
			PlaybackState.Builder b = new PlaybackState.Builder()
					.setActions(PlaybackState.ACTION_PLAY
							| PlaybackState.ACTION_PAUSE
							| PlaybackState.ACTION_PLAY_PAUSE
							| PlaybackState.ACTION_STOP
							| PlaybackState.ACTION_SEEK_TO
							| PlaybackState.ACTION_SKIP_TO_PREVIOUS
							| PlaybackState.ACTION_SKIP_TO_NEXT)
					.setState(PlaybackState.STATE_PLAYING, (long) currentPositionMs(), 1.0f);
			// 位置由系统外推：只在播放态变化、或超过 30s 未推（漂移校正）时才重推。
			if (lastPlaying != lastPushedPlaying || android.os.SystemClock.elapsedRealtime() - lastPushUptimeMs > 30000L)
			{
				session.setPlaybackState(b.build());
				lastPushedPlaying = lastPlaying;
				lastPushUptimeMs = android.os.SystemClock.elapsedRealtime();
			}
			// 单链保证：本轮工作里 pushState() 的 schedulePositionTick() 可能已重排过，
			// 这里再无脑排一条就成两条链（每秒发两次 tick、彼此差几毫秒）。
			if (!_tickScheduled)
			{
				postNextTick();
			}
		}
	};

	/** ticker 是否已有待触发的回调，避免重复堆叠 */
	private boolean _tickScheduled = false;

	private void postNextTick() {
		_tickScheduled = true;
		_ticker.postDelayed(_tickRunnable, POSITION_TICK_INTERVAL_MS);
	}

	private void schedulePositionTick() {
		// 已在运行就不重排：位置推送同样每 0.5s 一次，若每次推送都 removeCallbacks 重排，
		// ticker 的到期时刻会被不断推迟而长期饿死，回绕检测随之静默失效
		if (_tickScheduled) {
			return;
		}
		postNextTick();
	}

	private void cancelPositionTick() {
		_ticker.removeCallbacks(_tickRunnable);
		_tickScheduled = false;
	}

	/**
	 * 拉起前台服务。服务未就绪才需要拉起（通知与刷新由服务侧回调本插件完成）。
	 *
	 * 注意不能以 service != null 作为"是否可以拉起服务"的前提：service 只在服务
	 * onCreate/onStartCommand 里才会被赋值，此前判断会导致服务永远拉不起来。
	 */
	private void startForegroundPlayback() {
		Context context = getContext();
		if (context == null) {
			return;
		}
		if (service != null && service.isForeground()) {
			// 已在前台：只需按需刷新通知内容（notify 后台也安全）
			if (!notificationKey().equals(lastNotifiedKey)) {
				pushForegroundNotification();
			}
			return;
		}
		// 服务不存在或已退出前台（暂停后重新播放）：拉起/重拉一次。
		// startForeground 只在服务的 onStartCommand 内调用——那是系统唯一放行的窗口，
		// 这里直接调会因应用处于后台而被拒并崩溃。后台发起的重拉本身会被拒绝，
		// 由退避 + try/catch 兜住，等回到前台自然恢复。
		long now = android.os.SystemClock.elapsedRealtime();
		if (now - _lastFgsAttemptUptimeMs < FGS_RETRY_BACKOFF_MS) {
			return;
		}
		_lastFgsAttemptUptimeMs = now;
		try {
			context.startForegroundService(new Intent(context, MediaSessionService.class));
		} catch (Exception e) {
			// Android 12+ 后台启动前台服务受限。此前这里只打 Log.w，导致失败完全静默
			// （dumpsys activity services 显示 (nothing) 却排查不到原因），必须显式暴露。
			Log.w(TAG, "startForegroundService rejected: " + e.getMessage());
			lastFgsError = e.getClass().getSimpleName() + ": " + e.getMessage();
			Log.w(TAG, "[DIAG] BACKGROUND PLAYBACK UNAVAILABLE: " + lastFgsError);
		}
	}

	/** 用当前播放状态刷新通知内容（服务已在前台时不重复调 startForeground） */
	private void pushForegroundNotification() {
		MediaSessionService svc = service;
		Context context = getContext();
		if (svc == null || context == null) {
			return;
		}
		ensureChannel(context);
		svc.updateNotification(buildNotification(context, pendingIntentFlags()));
		lastNotifiedKey = notificationKey();
	}

	/** 通知内容标识：曲目/播放态/封面任一变化都需要重新提交通知 */
	private String notificationKey() {
		return lastTitle + "\u0001" + lastAlbum + "\u0001" + lastPlaying
				+ "\u0001" + System.identityHashCode(lastCover);
	}

	private int pendingIntentFlags() {
		return PendingIntent.FLAG_UPDATE_CURRENT
				| (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M ? PendingIntent.FLAG_IMMUTABLE : 0);
	}

	static void ensureChannel(Context context) {
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
			return;
		}
		NotificationManager manager =
				(NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
		if (manager == null || manager.getNotificationChannel(CHANNEL_ID) != null) {
			return;
		}
		NotificationChannel channel = new NotificationChannel(
				CHANNEL_ID, "媒体播放", NotificationManager.IMPORTANCE_LOW);
		channel.setShowBadge(false);
		channel.setSound(null, null);
		manager.createNotificationChannel(channel);
	}

	/**
	 * 用 framework Notification.Builder 而非 NotificationCompat：本插件的 MediaSession 是
	 * framework 的 android.media.session.MediaSession，其 Token 与 NotificationCompat
	 * 期望的 MediaSessionCompat.Token 不通用，混用会编译不过。
	 * minSdk 24 >= 通知渠道所需 API 26 的降级由 ensureChannel 处理，故直接用 Builder(context, CHANNEL_ID)。
	 */
	private Notification buildNotification(Context context, int pendingFlags) {
		Intent launchIntent = context.getPackageManager()
				.getLaunchIntentForPackage(context.getPackageName());
		PendingIntent contentPending = null;
		if (launchIntent != null) {
			contentPending = PendingIntent.getActivity(context, 0, launchIntent, pendingFlags);
		}

		Notification.Builder builder = new Notification.Builder(context, CHANNEL_ID)
				.setSmallIcon(android.R.drawable.ic_media_play)
				.setContentTitle(lastTitle.isEmpty() ? "Touhou Mix" : lastTitle)
				.setContentText(lastAlbum)
				.setVisibility(Notification.VISIBILITY_PUBLIC)
				.setOngoing(lastPlaying);

		if (lastCover != null) {
			builder.setLargeIcon(lastCover);
		}

		if (contentPending != null) {
			builder.setContentIntent(contentPending);
		}

		// 通知按钮交由 MediaSession 自动填充：注册了 PlaybackState 动作后，
		// 系统会依据 MediaSession.Callback 生成对应 PendingIntent 并路由命令
		builder.addAction(new Notification.Action.Builder(
				android.R.drawable.ic_media_previous, "上一首", null).build());
		builder.addAction(new Notification.Action.Builder(
				android.R.drawable.ic_media_play, "播放", null).build());
		builder.addAction(new Notification.Action.Builder(
				android.R.drawable.ic_media_pause, "暂停", null).build());
		builder.addAction(new Notification.Action.Builder(
				android.R.drawable.ic_media_next, "下一首", null).build());
		builder.setStyle(new Notification.MediaStyle()
				.setMediaSession(session == null ? null : session.getSessionToken())
				.setShowActionsInCompactView(0, 1, 2, 3));
		return builder.build();
	}
}

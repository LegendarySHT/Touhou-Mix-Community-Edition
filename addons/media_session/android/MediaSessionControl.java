package com.godot.game;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
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
 * 系统媒体会话（Android）。
 *
 * 音频由 miniaudio 原生设备直接输出，不经过 Godot AudioServer，引擎侧无任何媒体
 * 集成，需自行挂 MediaSession 才能出现在通知栏/锁屏媒体控制中，并接收系统媒体键。
 *
 * 与 GDScript 侧 Game/SystemMediaSession.gd 的契约：
 *   signal command_received(String action, double position_ms)
 *   update_state(boolean playing, double position_ms, double duration_ms,
 *                String title, String album, byte[] cover_png)
 *   clear()
 *
 * 切后台后 Godot 主循环随渲染线程挂起而停止，_process 不再运行；此时位置由系统按
 * playback_rate 外推，返回前台后 GDScript 侧 push_state 校正。系统下发的命令经
 * emitSignal 仍会送达（渲染线程暂停前会先排空事件队列），故后台仍可暂停/续播。
 */
public class MediaSessionControl extends GodotPlugin {

	private static final String TAG = "MediaSessionControl";

	private static final String CHANNEL_ID = "media_playback";
	static final int NOTIFICATION_ID = 0x7A3;

	private static final SignalInfo COMMAND_RECEIVED =
			new SignalInfo("command_received", String.class, Double.class);

	@Nullable
	private MediaSession session;

	/** 插件实例。服务的静态 attach 可能早于插件注册，故缓存待认领 */
	@Nullable
	private static MediaSessionControl s_instance;
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
	private double lastPositionMs = 0.0;
	private double lastDurationMs = 0.0;
	private String lastTitle = "";
	private String lastAlbum = "";
	/** 上层声明的播完行为：0=无 1=原地重播（重启人声） 2=前进下一首。
	 *  后台主循环停摆、GDScript 侧回绕检测不运行，墙钟 ticker 据此在回绕时补发 track_end。 */
	private int lastEndAction = 0;
	/** 最近一次的封面 PNG 字节与解码结果（字节相同则跳过重复解码） */
	@Nullable
	private byte[] lastCoverPng;
	@Nullable
	private android.graphics.Bitmap lastCover;
	/** [诊断] 前台服务启动失败原因，供 GDScript 侧查询 */
	private String lastFgsError = "";

	public MediaSessionControl(@NonNull Godot godot) {
		super(godot);
	}

	@NonNull
	@Override
	public String getPluginName() {
		return "MediaSessionControl";
	}

	@NonNull
	@Override
	public Set<SignalInfo> getPluginSignals() {
		Set<SignalInfo> signals = new HashSet<>();
		signals.add(COMMAND_RECEIVED);
		return signals;
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

	/**
	 * MediaSessionService 在 onCreate 时登记自身，销毁时传 null 解绑。
	 * 服务早于插件就绪时先挂起，待会话建立后补认领。
	 */
	public static void attachService(@Nullable MediaSessionService svc) {
		MediaSessionControl plugin = s_instance;
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
		MediaSessionControl plugin = s_instance;
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
			String title, String album, byte[] coverPng, int endAction) {
		runOnUiThread(() -> {
			boolean songChanged = !lastTitle.equals(title == null ? "" : title);
			lastPlaying = playing;
			lastPositionMs = positionMs;
			lastDurationMs = durationMs;
			lastTitle = title == null ? "" : title;
			lastAlbum = album == null ? "" : album;
			lastEndAction = endAction;
			// 换曲时位置归零，上一 tick 的曲尾位置不再是有效比对基准
			if (songChanged) {
				_lastTickPos = -1L;
			}
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
		});
	}

	/** 供 GDScript 侧判断后端是否真的可用 */
	@UsedByGodot
	public boolean is_available() {
		return session != null;
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
		if (lastPlaying) {
			schedulePositionTick();
		} else {
			cancelPositionTick();
		}

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
	/** 上一次 tick 的外推位置，用于识别墙钟回绕 */
	private long _lastTickPos = -1L;

	private static final long POSITION_TICK_INTERVAL_MS = 500L;

	/** 以当前 lastPositionMs 重置墙钟基准。
	 *  不重置 _lastTickPos：位置推送本身每 0.5s 一次，若每次推送都把比对基准清掉，
	 *  ticker 就永远看不到"上一 tick 在曲尾"这个前提，回绕检测会时好时坏。
	 *  仅在换曲（update_state 检测到曲名变化）时清基准。 */
	private void resetTickBase() {
		_tickBasePositionMs = (long) lastPositionMs;
		_tickBaseUptimeMs = android.os.SystemClock.elapsedRealtime();
	}

	/** 依据墙钟推算当前位置；已知时长时按取模回绕（loop 由上层语义保证） */
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

	private final Runnable _tickRunnable = new Runnable() {
		@Override
		public void run() {
			_tickScheduled = false;
			if (session == null || !lastPlaying) {
				return;
			}
			long pos = (long) currentPositionMs();
			// 墙钟回绕检测：上次 tick 在曲尾附近、本次已回到开头，且上层声明了播完行为时，
			// 经命令通道补发 track_end（与 GDScript 侧逐帧回绕检测互为补充），
			// 驱动换曲或重启人声。
			if (lastEndAction != 0 && lastDurationMs > 0.0 && _lastTickPos >= 0L
					&& _lastTickPos >= lastDurationMs - 1500L
					&& pos + 1000L < _lastTickPos) {
				Log.i(TAG, "[DIAG] wall-clock wrap detected, endAction=" + lastEndAction);
				emitCommand("track_end", -1.0);
			}
			_lastTickPos = pos;
			PlaybackState.Builder b = new PlaybackState.Builder()
					.setActions(PlaybackState.ACTION_PLAY
							| PlaybackState.ACTION_PAUSE
							| PlaybackState.ACTION_PLAY_PAUSE
							| PlaybackState.ACTION_STOP
							| PlaybackState.ACTION_SEEK_TO
							| PlaybackState.ACTION_SKIP_TO_PREVIOUS
							| PlaybackState.ACTION_SKIP_TO_NEXT)
					.setState(PlaybackState.STATE_PLAYING, (long) currentPositionMs(), 1.0f);
			session.setPlaybackState(b.build());
			postNextTick();
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

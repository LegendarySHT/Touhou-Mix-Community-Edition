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
	/** 传递给 MediaSessionService 的通知 extra key（framework 无对应常量） */
	static final String EXTRA_NOTIFICATION = "com.godot.game.extra.NOTIFICATION";

	private static final SignalInfo COMMAND_RECEIVED =
			new SignalInfo("command_received", String.class, Double.class);

	@Nullable
	private MediaSession session;

	/** 插件实例。服务的静态 attach 可能早于插件注册，故缓存待认领 */
	@Nullable
	private static MediaSessionControl s_instance;
	@Nullable
	private static MediaSessionService s_pending_service;

	private boolean lastPlaying = false;
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
			lastPlaying = false;
			lastPositionMs = 0.0;
			lastDurationMs = 0.0;
			lastTitle = "";
			lastAlbum = "";
			pushState();
		});
	}

	/** 供 GDScript 侧判断后端是否真的可用 */
	@UsedByGodot
	public boolean is_available() {
		return session != null;
	}

	/** [诊断] 前台服务是否已成功拉起（后台播放的前提） */
	@UsedByGodot
	public boolean is_foreground_service_running() {
		return service != null;
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

		if (lastPlaying) {
			startForegroundPlayback();
		} else if (service != null) {
			service.stopForegroundPlayback();
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

	private static final long POSITION_TICK_INTERVAL_MS = 500L;

	/** 以当前 lastPositionMs 重置墙钟基准 */
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
			if (session == null || !lastPlaying) {
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
			session.setPlaybackState(b.build());
			_ticker.postDelayed(this, POSITION_TICK_INTERVAL_MS);
		}
	};

	private void schedulePositionTick() {
		// 基准已由 pushState 起始处的 resetTickBase 设好，此处只需重排定时器
		_ticker.removeCallbacks(_tickRunnable);
		_ticker.postDelayed(_tickRunnable, POSITION_TICK_INTERVAL_MS);
	}

	private void cancelPositionTick() {
		_ticker.removeCallbacks(_tickRunnable);
	}

	private void startForegroundPlayback() {
		Context context = getContext();
		if (context == null || service == null) {
			return;
		}
		ensureChannel(context);

		int flags = PendingIntent.FLAG_UPDATE_CURRENT
				| (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M ? PendingIntent.FLAG_IMMUTABLE : 0);
		Notification notification = buildNotification(context, flags);
		try {
			context.startForegroundService(
					new Intent(context, MediaSessionService.class)
							.putExtra(EXTRA_NOTIFICATION, notification));
		} catch (Exception e) {
			// Android 12+ 后台启动前台服务受限。此前这里只打 Log.w，导致失败完全静默
			// （dumpsys activity services 显示 (nothing) 却排查不到原因），必须显式暴露。
			Log.w(TAG, "startForegroundService rejected: " + e.getMessage());
			lastFgsError = e.getClass().getSimpleName() + ": " + e.getMessage();
			Log.w(TAG, "[DIAG] BACKGROUND PLAYBACK UNAVAILABLE: " + lastFgsError);
		}
	}

	private void ensureChannel(Context context) {
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

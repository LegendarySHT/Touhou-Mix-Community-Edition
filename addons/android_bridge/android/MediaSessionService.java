package com.godot.game;

import android.app.Notification;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;

import androidx.annotation.Nullable;

/**
 * 媒体播放前台服务。
 *
 * Android 8.0 起后台进程随时可能被回收，仅靠 Godot Activity 无法保证切后台后音频
 * 继续输出；承载 MediaStyle 通知的 foreground service 才能拿到 mediaPlayback 前台
 * 优先级，使 miniaudio 音频输出与系统媒体控制卡片继续存活。
 *
 * 通知内容不在 Intent 里传递（封面位图较大，走 Binder 易触发 TransactionTooLarge
 * Exception）。
 *
 * startForeground 只允许在 onStartCommand 里调用：那是 startForegroundService 授予的
 * 宽限窗口，必定被系统放行；曲目切换时的通知刷新一律走 updateNotification（notify），
 * 否则应用处于后台时会抛 ForegroundServiceStartNotAllowedException 直接崩溃。
 */
public class MediaSessionService extends Service {

	private static final String TAG = "MediaSessionService";

	private boolean foreground = false;

	@Override
	public void onCreate() {
		super.onCreate();
		AndroidBridge.attachService(this);
	}

	@Override
	public int onStartCommand(@Nullable Intent intent, int flags, int startId) {
		// 5 秒时限内进入前台，先用占位通知（真实曲目/封面由插件侧随后提交）
		if (!foreground && !startInForeground(AndroidBridge.buildPlaceholderNotification(this))) {
			// 进入前台被拒：结束服务，避免超过 5 秒时限抛 RemoteServiceException
			stopSelf();
			return START_NOT_STICKY;
		}
		// 插件持有最新播放状态与封面，由它刷新为真实通知内容
		AndroidBridge.onServiceReady(this);
		// 不自动重建：重建会丢失播放状态，由 GDScript 侧重新注册时再拉起
		return START_NOT_STICKY;
	}

	/** 进入前台并显示通知。失败返回 false（调用方需结束服务以规避超时崩溃） */
	private boolean startInForeground(Notification notification) {
		try {
			if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
				startForeground(AndroidBridge.NOTIFICATION_ID, notification,
						android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
			} else {
				startForeground(AndroidBridge.NOTIFICATION_ID, notification);
			}
			foreground = true;
			return true;
		} catch (Exception e) {
			Log.w(TAG, "startForeground rejected: " + e.getMessage());
			return false;
		}
	}

	/**
	 * 更新通知内容（不进入前台）。后台刷新必须走这里：notify 不受后台启动前台服务的限制，
	 * 而重复调 startForeground 在应用处于后台时会被系统拒绝。
	 */
	void updateNotification(Notification notification) {
		NotificationManager manager =
				(NotificationManager) getSystemService(NOTIFICATION_SERVICE);
		if (manager != null) {
			manager.notify(AndroidBridge.NOTIFICATION_ID, notification);
		}
	}

	boolean isForeground() {
		return foreground;
	}

	/** 停止播放时撤下通知，保留服务实例以便下次播放复用 */
	public void stopForegroundPlayback() {
		if (!foreground) {
			return;
		}
		stopForeground(STOP_FOREGROUND_REMOVE);
		foreground = false;
	}

	@Override
	public void onDestroy() {
		AndroidBridge.attachService(null);
		super.onDestroy();
	}

	@Nullable
	@Override
	public IBinder onBind(Intent intent) {
		return null;
	}
}
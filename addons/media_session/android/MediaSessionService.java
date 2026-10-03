package com.godot.game;

import android.app.Notification;
import android.app.Service;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;

import androidx.annotation.Nullable;

/**
 * 媒体播放前台服务。
 *
 * Android 8.0 起后台进程随时可能被回收，仅靠 Godot Activity 无法保证切后台后音频
 * 继续输出；承载 MediaStyle 通知的 foreground service 才能拿到 mediaPlayback 前台
 * 优先级，使 miniaudio 音频输出与系统媒体控制卡片继续存活。
 *
 * 通知内容与启停决策都在 MediaSessionControl，本类只负责前台生命周期。
 */
public class MediaSessionService extends Service {

	private boolean foreground = false;

	@Override
	public void onCreate() {
		super.onCreate();
		MediaSessionControl.attachService(this);
	}

	@Override
	public int onStartCommand(@Nullable Intent intent, int flags, int startId) {
		if (!foreground && intent != null) {
			Notification notification = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
					? intent.getParcelableExtra(MediaSessionControl.EXTRA_NOTIFICATION, Notification.class)
					: intent.getParcelableExtra(MediaSessionControl.EXTRA_NOTIFICATION);
			if (notification != null) {
				startInForeground(notification);
			}
		}
		// 不自动重建：重建会丢失播放状态，由 GDScript 侧重新注册时再拉起
		return START_NOT_STICKY;
	}

	private void startInForeground(Notification notification) {
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
			startForeground(MediaSessionControl.NOTIFICATION_ID, notification,
					android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
		} else {
			startForeground(MediaSessionControl.NOTIFICATION_ID, notification);
		}
		foreground = true;
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
		MediaSessionControl.attachService(null);
		super.onDestroy();
	}

	@Nullable
	@Override
	public IBinder onBind(Intent intent) {
		return null;
	}
}

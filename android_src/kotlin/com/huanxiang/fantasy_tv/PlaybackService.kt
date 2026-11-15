package com.huanxiang.fantasy_tv

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

/**
 * 后台播放保活（BG_SERVICE，2026-11-15）。
 *
 * 为什么需要它：播放**本身**已经不会因为切后台而暂停（见 `fullscreen_page.dart`
 * 的「切后台：只复位长按倍速并记进度，永不暂停」）。断流不是我们主动停的，
 * 是 Android 把「没有前台服务的后台进程」回收了 —— 表现出来就是「放着放着断了」。
 * 前台服务 + 常驻通知就是这个进程的护身符：有通知栏控件在，系统不会随手杀。
 *
 * 设计取舍（最小实现，刻意不做的事）：
 *   · 不引 MediaSessionCompat / androidx.media：通知栏控件直接用
 *     [Controller]（ExoPlayerPlugin 自己）回调和 PendingIntent 回服务，
 *     不新增任何依赖；
 *   · 不显示进度条：进度条要 `setProgress` 秒级刷新 + MediaSession 才自然，
 *     最小实现只放「播放/暂停」和「关闭」两个动作；
 *   · 不改变播放行为：这里的每个回调都只调 `player.play()/pause()`，
 *     暂停/播放的唯一决策者仍然是 Dart 侧；
 *   · 所有系统调用都包 try/catch：服务起不来最多是没有通知，
 *     **绝不能**因为保活把播放带崩。
 *
 * 生命周期：ExoPlayer open 成功后由 Dart → 原生 [start] 拉起；
 * 退出播放页 / 播放结束 / 用户在通知里点「关闭」/ 播放器 release → [stop]。
 * 停掉之后不留任何东西（不留通知、不留唤醒锁、不留服务），避免费电和被
 * 系统判为「后台常驻」。
 */
class PlaybackService : Service() {

    /**
     * 通知栏控件要能反控播放器，但本类不持有 ExoPlayer（依赖方向要单向：
     * 插件 → 服务）。所以由 [ExoPlayerPlugin] 实现这个接口并注册进来。
     */
    interface Controller {
        /** 当前是否真的在出声音（系统判断用，异常一律当「在播」）。 */
        fun isPlaying(): Boolean

        /** 播放/暂停互切；返回切换后是否在播。 */
        fun togglePlay(): Boolean

        /** 通知里点了「关闭」：停止播放并让服务退出。 */
        fun stopPlayback()
    }

    companion object {
        const val LOG_TAG = "FxBg"

        /** 唤醒锁 tag（adb shell dumpsys power | grep 可确认）。 */
        const val WAKE_LOCK_TAG = "Fx:Playback"

        const val CHANNEL_ID = "fx_playback"
        const val CHANNEL_NAME = "后台播放"
        const val NOTIFICATION_ID = 0x0B01

        const val ACTION_START = "com.huanxiang.fantasy_tv.playback.START"
        const val ACTION_TOGGLE = "com.huanxiang.fantasy_tv.playback.TOGGLE"
        const val ACTION_STOP = "com.huanxiang.fantasy_tv.playback.STOP"

        /** 服务自己的偏好文件：只存「一次性提示」「通知权限已问过」这类标记。 */
        const val PREFS = "fx_bg"

        /** 系统在后台压力下动过本进程（`onTrimMemory` 记的），下次启动提示一次。 */
        const val PREF_INTERRUPTED = "bg_interrupted"

        /** Android 13 通知权限只问一次，用户拒绝就不再骚扰。 */
        const val PREF_NOTIF_ASKED = "bg_notif_asked"

        @Volatile
        private var instance: PlaybackService? = null

        /** 当前注册的播放器控制器（同一个进程只有一个在播的实例）。 */
        @Volatile
        var controller: Controller? = null
            private set

        /** 服务是否正在前台运行。 */
        fun isRunning(): Boolean = instance != null

        /**
         * 起前台服务。[title] 是片名，[episode] > 0 时通知标题拼成「片名 · 第N集」。
         *
         * 重复调用是安全的（服务已在前台时只会刷新通知）。
         */
        fun start(context: Context, title: String, episode: Int, ctl: Controller) {
            try {
                controller = ctl
                val intent = Intent(context, PlaybackService::class.java).apply {
                    action = ACTION_START
                    putExtra("title", title)
                    putExtra("episode", episode)
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (error: Throwable) {
                // 起服务失败（后台启动限制 / 厂商 ROM 拦截）不影响播放本身。
                Log.w(
                    LOG_TAG,
                    "start 失败：${error.javaClass.simpleName}: ${error.message}"
                )
            }
        }

        /**
         * 停前台服务。
         *
         * [requester] 非空时做**身份校验**：换集 / 换线路会新建播放器实例，
         * 旧实例的 release 往往落在新实例 start 之后 —— 没有这道校验，
         * 旧实例的 release 会把刚起来的服务关掉，新一集就裸奔在后台。
         */
        fun stop(context: Context, requester: Controller? = null) {
            try {
                val current = controller
                if (requester != null && current != null && current !== requester) {
                    Log.i(LOG_TAG, "stop 忽略：调用方不是当前播放器（换集保活）")
                    return
                }
                controller = null
                context.stopService(Intent(context, PlaybackService::class.java))
            } catch (error: Throwable) {
                Log.w(LOG_TAG, "stop 失败：${error.javaClass.simpleName}: ${error.message}")
            }
        }

        /** 播放状态变了：刷新通知（按钮文案与状态行）。服务没跑就什么都不做。 */
        fun sync() {
            try {
                instance?.refreshNotification()
            } catch (error: Throwable) {
                Log.w(LOG_TAG, "sync 失败：${error.javaClass.simpleName}")
            }
        }

        /** 记一次「后台播放被系统动过」，下次启动一次性提示用户加白名单。 */
        fun markInterrupted(context: Context, why: String) {
            try {
                context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                    .edit()
                    .putBoolean(PREF_INTERRUPTED, true)
                    .apply()
                Log.w(LOG_TAG, "interrupt 候选：$why")
            } catch (error: Throwable) {
                Log.w(LOG_TAG, "markInterrupted 失败：${error.javaClass.simpleName}")
            }
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var title = ""
    private var episode = 0

    override fun onCreate() {
        super.onCreate()
        instance = this
        createChannel()
        acquireWakeLock()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 任何一条分支都不能把异常抛回系统（Service 主线程崩 = 整个进程崩）。
        try {
            when (intent?.action) {
                ACTION_TOGGLE -> {
                    val ctl = controller
                    if (ctl == null) {
                        stopSelfSafely()
                    } else {
                        ctl.togglePlay()
                        refreshNotification()
                    }
                }
                ACTION_STOP -> {
                    val ctl = controller
                    controller = null
                    try {
                        ctl?.stopPlayback()
                    } catch (error: Throwable) {
                        Log.w(LOG_TAG, "关闭播放失败：${error.javaClass.simpleName}")
                    }
                    stopSelfSafely()
                    return START_NOT_STICKY
                }
                else -> {
                    intent?.getStringExtra("title")?.let { if (it.isNotEmpty()) title = it }
                    val ep = intent?.getIntExtra("episode", 0) ?: 0
                    if (ep > 0) episode = ep
                    startInForeground()
                }
            }
        } catch (error: Throwable) {
            Log.w(LOG_TAG, "onStartCommand 异常：${error.javaClass.simpleName}", error)
            stopSelfSafely()
        }
        // 不要 START_STICKY：被杀之后系统不该在没有播放器的空壳里复活这个服务。
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        instance = null
        releaseWakeLock()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (error: Throwable) {
            Log.w(LOG_TAG, "stopForeground 失败：${error.javaClass.simpleName}")
        }
        super.onDestroy()
    }

    /**
     * 系统在内存/电量压力下会先给进程发这些回调。播放中收到
     * RUNNING_LOW / RUNNING_CRITICAL / BACKGROUND，说明「这个进程已经进了
     * 回收名单」—— 这是唯一能在被杀**之前**留下痕迹的时机。
     *
     * 记一个标记（下次启动由 Dart 一次性提示加电池白名单），不改任何播放行为。
     */
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        try {
            val pressured = level == ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW ||
                level == ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL ||
                level == ComponentCallbacks2.TRIM_MEMORY_BACKGROUND ||
                level == ComponentCallbacks2.TRIM_MEMORY_COMPLETE
            if (!pressured) return
            val playing = try {
                controller?.isPlaying() == true
            } catch (_: Throwable) {
                true
            }
            if (!playing) return
            markInterrupted(this, "onTrimMemory level=$level")
        } catch (error: Throwable) {
            Log.w(LOG_TAG, "onTrimMemory 失败：${error.javaClass.simpleName}")
        }
    }

    override fun onLowMemory() {
        super.onLowMemory()
        try {
            val playing = try {
                controller?.isPlaying() == true
            } catch (_: Throwable) {
                true
            }
            if (playing) markInterrupted(this, "onLowMemory")
        } catch (_: Throwable) {
        }
    }

    // ------------------------------------------------------------- internals

    private fun stopSelfSafely() {
        try {
            stopSelf()
        } catch (error: Throwable) {
            Log.w(LOG_TAG, "stopSelf 失败：${error.javaClass.simpleName}")
        }
    }

    private fun startInForeground() {
        val notification = buildNotification()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            Log.i(LOG_TAG, "前台服务已启动：$title ep=$episode")
        } catch (error: Throwable) {
            // Android 12+ 后台启动限制、或厂商 ROM 不给通知：退回去，播放照旧。
            Log.w(
                LOG_TAG,
                "startForeground 失败：${error.javaClass.simpleName}: ${error.message}"
            )
            stopSelfSafely()
        }
    }

    private fun refreshNotification() {
        if (instance == null) return
        try {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            manager?.notify(NOTIFICATION_ID, buildNotification())
        } catch (error: Throwable) {
            Log.w(LOG_TAG, "notify 失败：${error.javaClass.simpleName}")
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                ?: return
            if (manager.getNotificationChannel(CHANNEL_ID) != null) return
            // IMPORTANCE_LOW：不出声、不弹横幅，只在通知栏常驻。
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "后台播放时常驻，防止系统回收播放进程"
                setShowBadge(false)
                enableVibration(false)
                setSound(null, null)
            }
            manager.createNotificationChannel(channel)
        } catch (error: Throwable) {
            Log.w(LOG_TAG, "createChannel 失败：${error.javaClass.simpleName}")
        }
    }

    private fun isPlayingNow(): Boolean = try {
        controller?.isPlaying() == true
    } catch (_: Throwable) {
        true
    }

    private fun notificationTitle(): String {
        val name = title.trim().ifEmpty { "幻想影视" }
        return if (episode > 0) "$name · 第${episode}集" else name
    }

    @Suppress("DEPRECATION")
    private fun buildNotification(): Notification {
        val playing = isPlayingNow()
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        builder
            .setSmallIcon(R.drawable.ic_stat_fx_play)
            .setContentTitle(notificationTitle())
            .setContentText(if (playing) "后台播放中" else "已暂停")
            .setCategory(Notification.CATEGORY_TRANSPORT)
            .setVisibility(Notification.VISIBILITY_PUBLIC) // 锁屏也看得到
            .setOngoing(true) // 不可滑动清掉：清了就等于让系统回收进程
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            // 不显示进度条（最小实现，要进度条得配 MediaSession）。
            .setProgress(0, 0, false)

        openAppIntent()?.let { builder.setContentIntent(it) }
        builder.addAction(
            if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
            if (playing) "暂停" else "播放",
            actionIntent(ACTION_TOGGLE, 0x0B11)
        )
        builder.addAction(
            android.R.drawable.ic_menu_close_clear_cancel,
            "关闭",
            actionIntent(ACTION_STOP, 0x0B12)
        )
        return builder.build()
    }

    /** 通知栏按钮 → 回到本服务的 PendingIntent。 */
    private fun actionIntent(action: String, code: Int): PendingIntent? {
        return try {
            val intent = Intent(this, PlaybackService::class.java).setAction(action)
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or immutableFlag()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                // 服务已在跑时 startService 也合法；用 getForegroundService 是为了
                // 万一进程被系统降级过，点按钮还能走前台服务启动路径。
                PendingIntent.getForegroundService(this, code, intent, flags)
            } else {
                PendingIntent.getService(this, code, intent, flags)
            }
        } catch (error: Throwable) {
            Log.w(LOG_TAG, "actionIntent 失败：${error.javaClass.simpleName}")
            null
        }
    }

    /** 点通知正文：回到 App（不重新建任务栈，播放页还在前台栈里）。 */
    private fun openAppIntent(): PendingIntent? {
        return try {
            val launch = packageManager.getLaunchIntentForPackage(packageName) ?: return null
            launch.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP
            PendingIntent.getActivity(
                this,
                0x0B10,
                launch,
                PendingIntent.FLAG_UPDATE_CURRENT or immutableFlag()
            )
        } catch (error: Throwable) {
            Log.w(LOG_TAG, "openAppIntent 失败：${error.javaClass.simpleName}")
            null
        }
    }

    private fun immutableFlag(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0

    /**
     * 部分厂商 ROM 在**熄屏**时把网络连同 CPU 一起压掉，只有拿到
     * PARTIAL_WAKE_LOCK 才能保证分片继续拉。随服务一起申请 / 释放，
     * 服务停掉就不会有任何残留（不会变成「永久保活」）。
     */
    private fun acquireWakeLock() {
        try {
            val power = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
            val lock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG)
            lock.setReferenceCounted(false)
            lock.acquire()
            wakeLock = lock
            Log.i(LOG_TAG, "唤醒锁已获取：$WAKE_LOCK_TAG")
        } catch (error: Throwable) {
            Log.w(LOG_TAG, "唤醒锁获取失败：${error.javaClass.simpleName}")
        }
    }

    private fun releaseWakeLock() {
        try {
            val lock = wakeLock ?: return
            if (lock.isHeld) lock.release()
            wakeLock = null
            Log.i(LOG_TAG, "唤醒锁已释放：$WAKE_LOCK_TAG")
        } catch (error: Throwable) {
            Log.w(LOG_TAG, "唤醒锁释放失败：${error.javaClass.simpleName}")
        }
    }
}

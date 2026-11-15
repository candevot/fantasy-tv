package com.huanxiang.fantasy_tv

import android.app.ActivityManager
import android.app.Notification
import android.app.PendingIntent
import android.content.ComponentCallbacks2
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.CommandButton
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.MediaNotification
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.google.common.collect.ImmutableList
import java.io.File
import java.security.MessageDigest
import java.util.Collections
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * 后台播放 = **MediaSessionService + MediaSession**（MEDIA_SESSION，2026-11-15）。
 *
 * 为什么从「裸 Service + 自己画的常驻通知」换成 media3 的 MediaSessionService：
 *
 *   · 影视壳 / B 站之所以「切后台、锁屏、车机、耳机线控都能控制」，不是因为它
 *     画了个好看的常驻通知，而是因为它向系统注册了 **MediaSession** ——
 *     通知栏媒体卡片、锁屏媒体控件、负一屏 / 控制中心的播放器、蓝牙耳机按键、
 *     车机方向盘，全都是系统读 MediaSession 渲染出来的。没有 session，
 *     我们就永远只是一个「有个通知的前台服务」，系统不认。
 *   · 老实现（自己 build Notification + 两个 PendingIntent 回服务）只能做到
 *     「播放 / 暂停 / 关闭」三个按钮，没有封面、没有进度条、没有上/下一集，
 *     也不进锁屏和媒体中心。这次就是把它整体替换掉。
 *
 * 关键设计（每一条都对应一个具体的坑）：
 *
 *   1. **通知不自己画**：交给 media3 的 [DefaultMediaNotificationProvider]。
 *      它自带封面（[MediaMetadata.artworkUri]）、片名 / 副标题、上一集 / 播放暂停 /
 *      下一集三个按钮，并且 Compose / MediaStyle 的样式跟随系统版本 —— 自己画
 *      布局永远追不上系统（Android 13 的媒体卡片是 SystemUI 画的，不是通知自己）。
 *   2. **播放器实例不新建**：session 绑定的是 [ExoPlayerPlugin] 里那台
 *      ExoPlayer（[Controller.currentPlayer]），同一个实例、同一条播放链路。
 *      换集 / 换线路仍然走原来那套 `switchToSource`，播放逻辑一行没改。
 *   3. **上一集 / 下一集**：ExoPlayer 里只有「一个 MediaItem」（一集），
 *      `SEEK_TO_NEXT_MEDIA_ITEM` 天然不可用，通知上就不会出现下一集按钮。
 *      所以用 [SessionPlayer]（ForwardingPlayer）把四个「上/下一集」命令
 *      声明成可用，并把它们**拦下来转给 Dart** —— 集数、线路、播放地址只有
 *      Dart 那边知道，原生不能自己切。
 *   4. **通知交给 media3，前台由我们自己进**（BG_GATE，2026-11-15）：
 *      media3 的 `MediaSessionService` 会在播放开始时**在库内部**调
 *      `startForeground(...)`，那一段我们包不住 —— 它只吞
 *      `ForegroundServiceStartNotAllowedException`，其余
 *      （`MissingForegroundServiceTypeException` / `SecurityException`）
 *      原样抛回主线程，就是「点播放就闪退」。所以这里覆写
 *      `onUpdateNotification(session, false)`：**只让 media3 画通知**，
 *      进前台由 [enterForegroundGuarded] 带
 *      `FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK` 自己调，整句在 runCatching
 *      里，失败只记日志。
 *   5. **不留僵尸 session / 通知**：播放结束、出错、退出播放页、播放器实例
 *      被重建（解码失败重试）时都会 [releaseSessionQuietly]；播放器
 *      `release()` 之前一定要先把 session 摘掉，否则 media3 会在已释放的
 *      player 上读状态，主线程直接崩。
 *
 * 生命周期：ExoPlayer open 成功后由 Dart → 原生 [start] 拉起；
 * 退出播放页 / 播放结束 / 用户在通知里滑掉 / 播放器 release → [stop]。
 */
@OptIn(UnstableApi::class)
class PlaybackService : MediaSessionService() {

    /**
     * 通知栏 / 锁屏 / 车机要能反控播放器，但本服务不持有 ExoPlayer
     * （依赖方向单向：插件 → 服务）。所以由 [ExoPlayerPlugin] 实现这个接口
     * 并通过 [start] 注册进来。
     */
    interface Controller {
        /** 当前是否真的在出声音（系统判断用，异常一律当「在播」）。 */
        fun isPlaying(): Boolean

        /** 播放/暂停互切；返回切换后是否在播。 */
        fun togglePlay(): Boolean

        /** 通知里点了「关闭」/ 耳机长按：停止播放并让服务退出。 */
        fun stopPlayback()

        /**
         * 上一集 / 下一集（[delta] = -1 / +1）。
         *
         * 来自四个地方：通知栏按钮、锁屏媒体控件、耳机线控（含双击切集）、
         * 车机方向盘。真正的切集在 Dart 侧（只有它知道线路、集数、播放地址），
         * 这里只负责把「用户要切集」这件事转过去。
         */
        fun stepEpisode(delta: Int)

        /** 当前 ExoPlayer 实例（session 要绑的就是它，不新建）。 */
        fun currentPlayer(): Player?

        /**
         * 还有没有上一集 / 下一集（[delta] = -1 / +1）。
         *
         * 系统用这个决定**要不要显示**上一集 / 下一集按钮：第一集不显示上一集、
         * 最后一集不显示下一集、电影（单集）两个都不显示 —— 和 B 站一致。
         * 恒 true 会让最后一集上的「下一集」变成一个按了没反应的死按钮。
         */
        fun hasEpisodeStep(delta: Int): Boolean
    }

    companion object {
        const val LOG_TAG = "FxBg"

        /** 唤醒锁 tag（adb shell dumpsys power | grep 可确认）。 */
        const val WAKE_LOCK_TAG = "Fx:Playback"

        /**
         * 通知渠道沿用老 id：装过老版本的用户机器上这个渠道已经存在
         * （IMPORTANCE_LOW / 不出声 / 不弹横幅），media3 会直接复用，
         * 不会因为升级多出一个新渠道、也不会突然开始响。
         */
        const val CHANNEL_ID = "fx_playback"
        const val CHANNEL_NAME = "后台播放"

        /** 通知 id 沿用老值：升级后不会同时挂两条媒体通知。 */
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

        /** 封面缓存目录（cacheDir 下，系统清缓存会一起清掉，不会越攒越大）。 */
        private const val ART_DIR = "fx_art"

        /** 封面最大 4MB：再大的图做通知缩略图没有意义，也容易撑爆 binder。 */
        private const val ART_MAX_BYTES = 4L * 1024 * 1024

        @Volatile
        private var instance: PlaybackService? = null

        /** 当前注册的播放器控制器（同一个进程只有一个在播的实例）。 */
        @Volatile
        var controller: Controller? = null
            private set

        /** 封面下载队列：并发 1，绝不和起播抢带宽。 */
        private val artworkQueue: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "FxArtwork").also { it.isDaemon = true }
        }

        /** 正在下载的封面地址（去重：同一张图只下一次）。 */
        private val artworkInflight: MutableSet<String> =
            Collections.synchronizedSet(HashSet<String>())

        /** 服务是否正在运行（session 可能在，也可能还没建）。 */
        fun isRunning(): Boolean = instance != null

        // ------------------------------------------------ BG_GATE 前置条件采样

        /** Android 13+ 运行时权限名（字符串常量，避免被当成 33 以下的死代码）。 */
        const val PERMISSION_POST_NOTIFICATIONS = "android.permission.POST_NOTIFICATIONS"

        /** Android 14+ 前台服务类型权限名。 */
        const val PERMISSION_FGS_MEDIA_PLAYBACK =
            "android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"

        /**
         * App 现在是不是**前台**（决定 onIsPlayingChanged 那条路径能不能起服务）。
         *
         * 用 `RunningAppProcessInfo.importance`：Android 上只有它同时覆盖
         * 「有可见 Activity」「有前台服务但界面不在」两种状态，而且读自己进程
         * 不需要任何权限。读不到一律当「不在前台」——宁可晚一点起服务，
         * 也不在后台去撞 Android 12+ 的前台服务启动限制。
         */
        fun isAppInForeground(context: Context): Boolean {
            val app = context.applicationContext ?: context
            val value = BgSafe.value("isAppInForeground") {
                val manager = app.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                    ?: return@value false
                val pid = Process.myPid()
                manager.runningAppProcesses?.any {
                    it.pid == pid &&
                        it.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
                } ?: false
            }
            return value == true
        }

        /** 真机环境快照：服务实例不在时也能读（起服务前的门禁要用）。 */
        fun readEnv(context: Context): BgEnv {
            val app = context.applicationContext ?: context
            return BgSafe.value("readEnv") {
                BgEnv(
                    sdkInt = Build.VERSION.SDK_INT,
                    appForeground = isAppInForeground(app),
                    notificationPermission = hasNotificationPermission(app),
                    declaredForegroundTypes = declaredForegroundTypes(app),
                    mediaPlaybackPermission = hasPermission(app, PERMISSION_FGS_MEDIA_PLAYBACK),
                )
            } ?: BgEnv.UNKNOWN
        }

        /** 起服务前的门禁（ExoPlayerPlugin.startBackground 调用）。 */
        fun gateServiceStart(context: Context, requireForeground: Boolean): BgBlock =
            BgGate.checkServiceStart(readEnv(context), requireForeground)

        private fun hasNotificationPermission(context: Context): Boolean =
            if (Build.VERSION.SDK_INT < 33) {
                true
            } else {
                hasPermission(context, PERMISSION_POST_NOTIFICATIONS)
            }

        private fun hasPermission(context: Context, name: String): Boolean {
            if (Build.VERSION.SDK_INT < 23) return true
            val value = BgSafe.value("checkSelfPermission($name)") {
                context.checkSelfPermission(name)
            }
            return value == PackageManager.PERMISSION_GRANTED
        }

        /**
         * manifest 里给本服务声明的 foregroundServiceType 位掩码。
         *
         * Android 10（29）以下没有「类型」这个概念，按「已声明」返回，
         * 免得低版本被门禁挡住（BgGate 本身也只对 29+ 校验）。
         */
        private fun declaredForegroundTypes(context: Context): Int {
            if (Build.VERSION.SDK_INT < 29) return BgEnv.MEDIA_PLAYBACK_TYPE
            val value = BgSafe.value("getServiceInfo(PlaybackService)") {
                context.packageManager
                    .getServiceInfo(ComponentName(context, PlaybackService::class.java), 0)
                    .foregroundServiceType
            }
            return value ?: 0
        }

        /**
         * 起服务（可重复调用）。
         *
         * 用 `startService` 而不是 `startForegroundService`（BG_GATE，2026-11-15）：
         *
         *   · `startForegroundService` 带 5 秒义务 —— 起来之后 5 秒内没有
         *     `startForeground` 就是 `ForegroundServiceDidNotStartInTimeException`
         *     （不可捕获，直接闪退）。而「要不要进前台」取决于播放状态，
         *     用户暂停着点进来就必然超时；
         *   · 现在进前台由 [enterForegroundGuarded] 在**播放真的开始时**自己调，
         *     用的是普通 `startService`，没有 5 秒义务，也就没有那条闪退路径。
         */
        fun start(context: Context, title: String, episode: Int, ctl: Controller) {
            try {
                controller = ctl
                val existing = instance
                if (existing != null) {
                    // 已在跑：换集 / 换播放器实例时补一次绑定 + 一次通知刷新。
                    existing.ensureSession()
                    Log.d(LOG_TAG, "服务已在运行，刷新 session：$title ep=$episode")
                    return
                }
                val intent = Intent(context, PlaybackService::class.java).apply {
                    action = ACTION_START
                    putExtra("title", title)
                    putExtra("episode", episode)
                }
                context.startService(intent)
            } catch (error: Throwable) {
                // 起服务失败（后台启动限制 / 厂商 ROM 拦截）不影响播放本身。
                Log.w(BgSafe.TAG, "start 失败：${error.javaClass.simpleName}: ${error.message}")
            }
        }

        /**
         * 停服务（同时把 session 同步摘掉，不留僵尸通知）。
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
                // 同步释放：stopService 是异步的（onDestroy 稍后到主线程），
                // 而调用方紧接着就要 player.release() —— session 还挂着那台
                // 已释放的播放器时，media3 读状态会抛异常把主线程带走。
                releaseSessionNow()
                context.stopService(Intent(context, PlaybackService::class.java))
            } catch (error: Throwable) {
                Log.w(BgSafe.TAG, "stop 失败：${error.javaClass.simpleName}: ${error.message}")
            }
        }

        /**
         * 播放状态变了。
         *
         * media3 的 MediaSession 自己监听播放器事件刷通知（位置、缓冲、播放态
         * 都从 PlaybackState 走），这里**不需要**再手工 notify —— 留着这个函数
         * 只是让 ExoPlayerPlugin 的调用点不用改，真出问题时打一条排查日志。
         */
        fun sync() {
            try {
                if (instance?.mediaSession == null) return
                Log.d(LOG_TAG, "sync 忽略：通知由 MediaSession 自己刷新")
            } catch (error: Throwable) {
                Log.w(BgSafe.TAG, "sync 失败：${error.javaClass.simpleName}")
            }
        }

        /** 播放器实例被替换 / 重新建好：让 session 绑到新实例上。空调用无副作用。 */
        fun syncPlayer() {
            try {
                instance?.ensureSession()
            } catch (error: Throwable) {
                Log.w(BgSafe.TAG, "syncPlayer 失败：${error.javaClass.simpleName}")
            }
        }

        /**
         * **同步**释放 session（主线程调用；其他线程自动转主线程）。
         *
         * 必须在 `player.release()` 之前调：MediaSession 强引用着播放器，
         * 谁先坏都不行 —— 播放器先释放，session 读状态就抛
         * IllegalStateException（主线程崩）；session 不释放，通知会挂在那儿
         * 点什么都报错（僵尸通知）。
         */
        fun releaseSessionNow() {
            val service = instance ?: return
            val action = Runnable {
                try {
                    service.releaseSessionQuietly()
                } catch (error: Throwable) {
                    Log.w(BgSafe.TAG, "releaseSession 失败：${error.javaClass.simpleName}")
                }
            }
            if (Looper.myLooper() == Looper.getMainLooper()) {
                action.run()
            } else {
                service.mainHandler.post(action)
            }
        }

        /**
         * 通知栏 / 锁屏 / 媒体中心用的 [MediaMetadata]。
         *
         * 字段口径（和系统卡片、锁屏对上）：
         *   · title     = 片名（大字那一行）
         *   · artist    = 系统媒体卡片 / 锁屏的副标题（「第N集 · 线路名」）
         *   · albumTitle= 车机、Android Auto、部分 OEM 的副标题取这个字段
         *   · artworkUri= 封面（有本地缓存走 file://，没有就走 http，见 [artworkUriFor]）
         */
        fun buildMetadata(
            title: String,
            episode: Int,
            line: String,
            artworkUri: Uri?,
        ): MediaMetadata {
            val name = title.trim().ifEmpty { "幻想影视" }
            val sub = subtitleOf(episode, line)
            val builder = MediaMetadata.Builder()
                .setTitle(name)
                .setMediaType(MediaMetadata.MEDIA_TYPE_VIDEO)
                .setIsPlayable(true)
                .setIsBrowsable(false)
            if (sub.isNotEmpty()) {
                builder.setArtist(sub)
                builder.setAlbumTitle(sub)
            }
            if (artworkUri != null) builder.setArtworkUri(artworkUri)
            return builder.build()
        }

        /** 「第N集 · 线路名」；集号 / 线路名缺一个就少一段，两个都缺返回空串。 */
        fun subtitleOf(episode: Int, line: String): String {
            val name = line.trim()
            val ep = if (episode > 0) "第${episode}集" else ""
            return when {
                ep.isNotEmpty() && name.isNotEmpty() -> "$ep · $name"
                ep.isNotEmpty() -> ep
                else -> name
            }
        }

        /**
         * 封面 Uri：**优先本地缓存文件**（不依赖网络、不受防盗链影响、
         * 锁屏/通知重建时也不发请求），没缓存到就退化成 http 地址
         * （media3 的 BitmapLoader 能直接加载，失败只是没有封面，不影响播放）。
         *
         * 同时后台补一份到本地：这一集没赶上，下一集 / 下次播放就是文件了。
         */
        fun artworkUriFor(
            context: Context,
            coverUrl: String,
            headers: Map<String, String>? = null,
        ): Uri? {
            val url = coverUrl.trim()
            if (url.isEmpty()) return null
            if (!PlayerHttp.isHttpUrl(url)) {
                return try {
                    Uri.parse(url)
                } catch (_: Throwable) {
                    null
                }
            }
            val cached = artworkFile(context, url)
            if (cached.isFile && cached.length() > 0L) return Uri.fromFile(cached)
            warmArtwork(context, url, headers)
            return try {
                Uri.parse(url)
            } catch (_: Throwable) {
                null
            }
        }

        /**
         * 预下载封面到本地缓存（入队即返回，失败静默）。
         *
         * 为什么要提前暖：MediaMetadata 是跟着 MediaItem 在 `prepare()` 之前
         * 定下的，通知要显示封面时再去下载就晚了（而且那会儿正在抢起播带宽）。
         * Dart 在进入播放页 / 换集前调一次，等真正开播时文件已经在了。
         */
        fun warmArtwork(context: Context, coverUrl: String, headers: Map<String, String>? = null) {
            try {
                val url = coverUrl.trim()
                if (url.isEmpty() || !PlayerHttp.isHttpUrl(url)) return
                val file = artworkFile(context, url)
                if (file.isFile && file.length() > 0L) return
                if (!artworkInflight.add(url)) return
                val appContext = context.applicationContext
                artworkQueue.execute {
                    try {
                        downloadArtwork(appContext, url, headers ?: emptyMap(), file)
                    } catch (error: Throwable) {
                        Log.w(BgSafe.TAG, "封面下载失败：${error.javaClass.simpleName}: ${error.message}")
                    } finally {
                        artworkInflight.remove(url)
                    }
                }
            } catch (error: Throwable) {
                Log.w(BgSafe.TAG, "warmArtwork 失败：${error.javaClass.simpleName}")
            }
        }

        /** 记一次「后台播放被系统动过」，下次启动一次性提示用户加白名单。 */
        fun markInterrupted(context: Context, why: String) {
            try {
                context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                    .edit()
                    .putBoolean(PREF_INTERRUPTED, true)
                    .apply()
                Log.w(BgSafe.TAG, "interrupt 候选：$why")
            } catch (error: Throwable) {
                Log.w(BgSafe.TAG, "markInterrupted 失败：${error.javaClass.simpleName}")
            }
        }

        // ------------------------------------------------------- 封面缓存内部实现

        private fun artworkFile(context: Context, url: String): File =
            File(File(context.cacheDir, ART_DIR), hashName(url))

        private fun hashName(url: String): String {
            return try {
                val digest = MessageDigest.getInstance("SHA-1").digest(url.toByteArray())
                val hex = StringBuilder(digest.size * 2)
                for (byte in digest) hex.append(String.format("%02x", byte))
                hex.toString()
            } catch (_: Throwable) {
                // 极罕见（SHA-1 不可用）：用 hash 兜底，只要同一地址得到同一个名字。
                Integer.toHexString(url.hashCode())
            }
        }

        private fun downloadArtwork(
            context: Context,
            url: String,
            headers: Map<String, String>,
            file: File,
        ) {
            val request = okhttp3.Request.Builder().url(url).get()
            // Referer / UA 沿用播放链路那套：不少图床也认站内 Referer。
            for ((key, value) in PlayerHttp.requestHeaders(url, headers)) {
                try {
                    request.addHeader(key, value)
                } catch (_: Throwable) {
                }
            }
            PlayerHttp.client.newCall(request.build()).execute().use { response ->
                if (!response.isSuccessful) {
                    Log.w(BgSafe.TAG, "封面 HTTP ${response.code}：$url")
                    return
                }
                val body = response.body ?: return
                val length = body.contentLength()
                if (length > ART_MAX_BYTES) {
                    Log.w(BgSafe.TAG, "封面太大跳过 ${length}B：$url")
                    return
                }
                val bytes = body.bytes()
                if (bytes.isEmpty() || bytes.size > ART_MAX_BYTES) {
                    Log.w(BgSafe.TAG, "封面内容为空或过大 ${bytes.size}B：$url")
                    return
                }
                val dir = file.parentFile
                if (dir != null && !dir.isDirectory) dir.mkdirs()
                // 先写临时文件再重命名：半截文件被当成缓存图会更糟（通知上
                // 出现一条灰带）。rename 在同一目录下是原子的。
                val tmp = File(file.parentFile, file.name + ".tmp")
                tmp.writeBytes(bytes)
                if (!tmp.renameTo(file)) {
                    tmp.copyTo(file, overwrite = true)
                    tmp.delete()
                }
                Log.i(LOG_TAG, "封面已缓存 ${bytes.size}B -> ${file.name}")
            }
        }
    }

    private var mediaSession: MediaSession? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    /** media3 的 provider 最近一次产出的通知（进前台要用它的 id + Notification）。 */
    @Volatile
    private var lastMediaNotification: MediaNotification? = null

    /** 我们自己有没有进前台（media3 的 startedInForeground 不再被使用）。 */
    @Volatile
    private var foregroundStarted = false

    /** 上一次拦住的判定：同一原因只打一条日志，别每次 buffer 事件刷屏。 */
    @Volatile
    private var lastLoggedBlock: BgBlock? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        installNotificationProvider()
        acquireWakeLock()
        // Android 12+ 后台起前台服务被拦时 media3 会回调到这里：只记日志，
        // 播放照旧（通知晚一点出现而已），绝不因为保活把播放带崩。
        setListener(object : Listener {
            override fun onForegroundServiceStartNotAllowedException() {
                Log.w(BgSafe.TAG, "前台服务启动被系统拒绝（Android 12+ 后台限制），播放继续")
            }
        })
        // BG_GATE（2026-11-15）：把「这台机器到底能不能进前台」一次性打进日志。
        // 真机出事时用户拉一份 `adb logcat -s FxPlay` 就能看出缺哪一项，
        // 不用再猜是类型没声明、权限没给，还是 ROM 自己加的限制。
        val env = readEnv(this)
        Log.i(LOG_TAG, "前台服务自检：${BgGate.describe(env, BgGate.checkForeground(env))}")
        if (Build.VERSION.SDK_INT >= 29 &&
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK != BgEnv.MEDIA_PLAYBACK_TYPE
        ) {
            // 只可能是平台常量变了（历史上没变过）：判定逻辑要跟着改。
            Log.w(
                LOG_TAG,
                "平台 FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK=" +
                    "${ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK} 与 BgEnv " +
                    "(${BgEnv.MEDIA_PLAYBACK_TYPE}) 不一致",
            )
        }
        Log.i(LOG_TAG, "MediaSessionService 已创建")
    }

    /**
     * 通知样式：media3 默认的媒体通知（封面 + 片名 / 副标题 + 上一集 / 播放暂停 /
     * 下一集）。**不自己画布局** —— 系统会按版本把这条通知渲染成媒体卡片，
     * 自绘的 action 反而进不了锁屏 / 媒体中心。
     *
     * BG_GATE：provider 外面再包一层 [RecordingNotificationProvider]，目的只有
     * 一个 —— 拿到 media3 画好的那条 Notification，并**接管它的异步回调**。
     * 原生回调会走 `MediaSessionService.onNotificationUpdated()`，那条路在封面
     * 加载完成后会自己调 `startForeground(...)`（库内部，异常接不住）；换成我们
     * 自己的回调后，前台只由 [enterForegroundGuarded] 进。
     */
    private fun installNotificationProvider() {
        BgSafe.run("installNotificationProvider") {
            val provider = DefaultMediaNotificationProvider.Builder(this)
                .setChannelId(CHANNEL_ID)
                .setChannelName(R.string.fx_bg_channel)
                .setNotificationId(NOTIFICATION_ID)
                .build()
            // 小图标沿用老的那张单色播放三角（Android 要求通知小图标必须是
            // 单色 vector，否则状态栏上是一块白方块）。
            provider.setSmallIcon(R.drawable.ic_stat_fx_play)
            setMediaNotificationProvider(
                RecordingNotificationProvider(provider) { notification ->
                    onProviderNotification(notification)
                }
            )
        }
    }

    /**
     * 永远不把 `startInForegroundRequired = true` 交给 media3（BG_GATE）。
     *
     * 这是本次闪退的**根因所在的那一行**：传 true 时 media3 会在
     * `MediaNotificationManager.startForeground()` 里调
     * `Util.setForegroundServiceNotification(..., FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)`，
     * 而 `Util` 只 catch RuntimeException 之后**原样 rethrow**，
     * `MediaSessionService.onUpdateNotificationInternal()` 又只吞
     * `ForegroundServiceStartNotAllowedException` ——
     * `MissingForegroundServiceTypeException` / `SecurityException` 会直接落到
     * **主线程**，进程当场死。那一段在库内部，我们的 try/catch 包不到。
     *
     * 现在：通知仍然由 media3 的 provider 生成（封面 / 进度 / 上下一集不变），
     * 但**只发通知、不进前台**；进不进前台由 [enterForegroundGuarded] 决定，
     * 那里每一句系统调用都在 runCatching 里，失败只记日志。
     */
    override fun onUpdateNotification(session: MediaSession, startInForegroundRequired: Boolean) {
        BgSafe.run("onUpdateNotification") { super.onUpdateNotification(session, false) }
        val notification = lastMediaNotification ?: return
        if (startInForegroundRequired) {
            enterForegroundGuarded(notification)
        } else {
            exitForegroundGuarded()
        }
    }

    /** provider 产出的通知（首次 + 异步封面回填）：只负责记账 + 走我们自己的投递。 */
    private fun onProviderNotification(notification: MediaNotification) {
        lastMediaNotification = notification
        if (foregroundStarted) {
            // 已经在前台：用同一条通知刷新一次（内容 / 进度 / 封面回填）。
            enterForegroundGuarded(notification)
        }
    }

    /**
     * **唯一**的进前台入口（BG_GATE）。
     *
     * 三件事：① 先用 [BgGate] 判定前置条件（类型 / 权限 / 通知权限），不满足
     * 就一次都别调；② 显式带 `FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK`
     * （Android 14+ 不带就是 MissingForegroundServiceTypeException）；
     * ③ 整句包在 runCatching 里，失败只写 `Log.w("FxPlay", ...)`。
     *
     * 失败语义：**播放继续**，只是进程没有前台身份（切后台可能被系统回收）。
     */
    private fun enterForegroundGuarded(notification: MediaNotification) {
        val env = readEnv(this)
        val block = BgGate.checkForeground(env)
        if (block != BgBlock.NONE) {
            foregroundStarted = false
            if (lastLoggedBlock != block) {
                lastLoggedBlock = block
                Log.w(BgSafe.TAG, "不进前台（播放继续）：${BgGate.describe(env, block)}")
            }
            return
        }
        lastLoggedBlock = null
        val done = BgSafe.run("startForeground(type=mediaPlayback)") {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(
                    notification.notificationId,
                    notification.notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
                )
            } else {
                @Suppress("DEPRECATION")
                startForeground(notification.notificationId, notification.notification)
            }
        }
        val ok = done != null
        if (ok != foregroundStarted) {
            Log.i(
                LOG_TAG,
                if (ok) "已进前台（mediaPlayback）：$NOTIFICATION_ID"
                else "进前台失败，播放继续（见 FxPlay 日志）",
            )
        }
        foregroundStarted = ok
    }

    /** 退出前台（暂停 / 播放结束）：保留通知，只把前台身份摘掉。 */
    private fun exitForegroundGuarded() {
        if (!foregroundStarted) return
        foregroundStarted = false
        BgSafe.run("stopForeground(DETACH)") {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_DETACH)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(false)
            }
        }
    }

    /**
     * 系统（通知管理器 / 车机 / Android Auto / 系统媒体中心）来连 session。
     *
     * 返回 null = 现在没有播放器（进程刚被拉起、还没 open 过），
     * 这时不要硬造一个空 session —— 那会挂出一条点什么都报错的僵尸通知。
     */
    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? {
        return BgSafe.value("onGetSession") { ensureSession() }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 任何一条分支都不能把异常抛回系统（Service 主线程崩 = 整个进程崩）。
        try {
            if (intent == null) {
                // 系统「复活」服务（上次 START_STICKY 的残留）：没有播放器就没有
                // 意义，直接退出，绝不留下一个空转的前台服务。
                stopSelfSafely()
                return START_NOT_STICKY
            }
            when (intent.action) {
                ACTION_TOGGLE -> {
                    val ctl = controller
                    if (ctl == null) {
                        stopSelfSafely()
                    } else {
                        ctl.togglePlay()
                    }
                    return START_NOT_STICKY
                }
                ACTION_STOP -> {
                    val ctl = controller
                    controller = null
                    try {
                        ctl?.stopPlayback()
                    } catch (error: Throwable) {
                        Log.w(BgSafe.TAG, "关闭播放失败：${error.javaClass.simpleName}")
                    }
                    stopSelfSafely()
                    return START_NOT_STICKY
                }
                ACTION_START -> {
                    if (ensureSession() == null) {
                        // 没有播放器：不挂空 session，服务也不留。
                        stopSelfSafely()
                        return START_NOT_STICKY
                    }
                    Log.i(LOG_TAG, "服务已就绪：${intent.getStringExtra("title") ?: ""}")
                    return START_NOT_STICKY
                }
            }
            // 剩下的全是 media3 自己的事：耳机 / 蓝牙线控的 ACTION_MEDIA_BUTTON、
            // 通知按钮和锁屏控件的自定义 action。交给父类分派给 session。
            val result = super.onStartCommand(intent, flags, startId)
            if (mediaSession == null) {
                // 连 session 都建不起来（进程刚被线控拉起、还没有播放器）：
                // 立刻退出。否则 startForegroundService 的 5 秒义务会变成
                // ForegroundServiceDidNotStartInTimeException 闪退。
                stopSelfSafely()
                return START_NOT_STICKY
            }
            return result
        } catch (error: Throwable) {
            Log.w(BgSafe.TAG, "onStartCommand 异常：${error.javaClass.simpleName}", error)
            stopSelfSafely()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        instance = null
        foregroundStarted = false
        releaseSessionQuietly()
        releaseWakeLock()
        BgSafe.run("stopForeground(REMOVE)") {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        }
        Log.i(LOG_TAG, "MediaSessionService 已销毁")
        super.onDestroy()
    }

    /**
     * 系统在内存 / 电量压力下会先给进程发这些回调。播放中收到
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
            if (!isPlayingNow()) return
            markInterrupted(this, "onTrimMemory level=$level")
        } catch (error: Throwable) {
            Log.w(BgSafe.TAG, "onTrimMemory 失败：${error.javaClass.simpleName}")
        }
    }

    override fun onLowMemory() {
        super.onLowMemory()
        try {
            if (isPlayingNow()) markInterrupted(this, "onLowMemory")
        } catch (_: Throwable) {
        }
    }

    // ------------------------------------------------------------- internals

    /**
     * 拿到（必要时创建 / 换绑）当前 session。
     *
     * 三种情况：
     *   · 还没有 session → 用当前 ExoPlayer 建一个，并 [addSession]；
     *   · 有 session 且绑的就是当前播放器 → 原样返回（幂等）；
     *   · 有 session 但播放器换过了（解码失败重建渲染器那条路）→
     *     [MediaSession.setPlayer] 换绑；换绑失败就重建成新的。
     *
     * 注意：必须是主线程（MediaSession 的 application looper 就是主线程）。
     */
    private fun ensureSession(): MediaSession? {
        // BG_GATE（2026-11-15）：MediaSession 必须建在「和播放器同一个
        // applicationLooper」的线程上（media3 会用 `player.applicationLooper`
        // 建 Handler，并在这个 Looper 上回调）。它在 OkHttp / 预取 / 解码回调
        // 线程上被创建过一次，就是 `IllegalStateException: Can't create handler
        // inside thread that has not called Looper.prepare()` 的直接来源。
        // 这里统一钉死主线程：不在主线程就把活转过去，本次返回现有 session。
        if (Looper.myLooper() != Looper.getMainLooper()) {
            Log.w(BgSafe.TAG, "ensureSession 被背景线程调用（${Thread.currentThread().name}），已转主线程")
            BgSafe.run("ensureSession(postMain)") {
                mainHandler.post { BgSafe.run("ensureSession") { ensureSession() } }
            }
            return mediaSession
        }
        val player = controller?.currentPlayer()
        if (player == null) {
            Log.i(LOG_TAG, "ensureSession 跳过：当前没有播放器实例")
            return null
        }
        val existing = mediaSession
        if (existing != null) {
            val bound = (existing.player as? SessionPlayer)?.wrappedPlayer
            if (bound === player) return existing
            return try {
                existing.setPlayer(SessionPlayer(player) { delta -> onStepRequested(delta) })
                Log.i(LOG_TAG, "MediaSession 已换绑到新的播放器实例")
                existing
            } catch (error: Throwable) {
                Log.w(BgSafe.TAG, "setPlayer 失败，重建 session：${error.javaClass.simpleName}")
                releaseSessionQuietly()
                createSession(player)
            }
        }
        return createSession(player)
    }

    private fun createSession(player: Player): MediaSession? {
        return try {
            val builder = MediaSession.Builder(
                this,
                SessionPlayer(player) { delta -> onStepRequested(delta) },
            )
            // 点通知 / 点锁屏卡片 → 回 App（不重建任务栈，播放页还在栈里）。
            openAppIntent()?.let { builder.setSessionActivity(it) }
            val session = builder.build()
            mediaSession = session
            addSession(session)
            Log.i(LOG_TAG, "MediaSession 已创建（绑定同一个 ExoPlayer 实例）")
            session
        } catch (error: Throwable) {
            Log.w(BgSafe.TAG, "创建 MediaSession 失败：${error.javaClass.simpleName}", error)
            null
        }
    }

    /**
     * 通知栏 / 锁屏 / 耳机线控要求「上一集 / 下一集」。
     *
     * 只转发，不自己切：集数列表、线路、播放地址全在 Dart 侧。
     * 转发走 [ExoPlayerPlugin] 的事件通道 → `bgStepSeq` 变化 → 播放页切集。
     */
    private fun onStepRequested(delta: Int) {
        try {
            Log.i(LOG_TAG, "媒体控制：${if (delta < 0) "上一集" else "下一集"}")
            controller?.stepEpisode(delta)
        } catch (error: Throwable) {
            Log.w(BgSafe.TAG, "切集转发失败：${error.javaClass.simpleName}")
        }
    }

    private fun releaseSessionQuietly() {
        val session = mediaSession ?: return
        mediaSession = null
        try {
            if (isSessionAdded(session)) removeSession(session)
        } catch (error: Throwable) {
            Log.w(BgSafe.TAG, "removeSession 失败：${error.javaClass.simpleName}")
        }
        try {
            session.release()
            Log.i(LOG_TAG, "MediaSession 已释放")
        } catch (error: Throwable) {
            Log.w(BgSafe.TAG, "session.release 失败：${error.javaClass.simpleName}")
        }
    }

    private fun stopSelfSafely() {
        try {
            stopSelf()
        } catch (error: Throwable) {
            Log.w(BgSafe.TAG, "stopSelf 失败：${error.javaClass.simpleName}")
        }
    }

    private fun isPlayingNow(): Boolean = try {
        controller?.isPlaying() == true
    } catch (_: Throwable) {
        true
    }

    /** 点通知正文：回到 App（不重新建任务栈，播放页还在前台栈里）。 */
    private fun openAppIntent(): PendingIntent? {
        return try {
            val launch = packageManager.getLaunchIntentForPackage(packageName) ?: return null
            launch.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            PendingIntent.getActivity(
                this,
                0x0B10,
                launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        } catch (error: Throwable) {
            Log.w(BgSafe.TAG, "openAppIntent 失败：${error.javaClass.simpleName}")
            null
        }
    }

    /**
     * 部分厂商 ROM 在**熄屏**时把网络连同 CPU 一起压掉，只有拿到
     * PARTIAL_WAKE_LOCK 才能保证分片继续拉。随服务一起申请 / 释放，
     * 服务停掉就不会有任何残留（不会变成「永久保活」）。
     */
    private fun acquireWakeLock() {
        if (wakeLock != null) return
        try {
            val power = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
            val lock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG)
            lock.setReferenceCounted(false)
            lock.acquire()
            wakeLock = lock
            Log.i(LOG_TAG, "唤醒锁已获取：$WAKE_LOCK_TAG")
        } catch (error: Throwable) {
            Log.w(BgSafe.TAG, "唤醒锁获取失败：${error.javaClass.simpleName}")
        }
    }

    private fun releaseWakeLock() {
        try {
            val lock = wakeLock ?: return
            if (lock.isHeld) lock.release()
            wakeLock = null
            Log.i(LOG_TAG, "唤醒锁已释放：$WAKE_LOCK_TAG")
        } catch (error: Throwable) {
            Log.w(BgSafe.TAG, "唤醒锁释放失败：${error.javaClass.simpleName}")
        }
    }

    /**
     * 给 MediaSession 用的播放器包装：**保留同一个 ExoPlayer**，只补上
     * 「上一集 / 下一集」四个命令。
     *
     * 为什么要包装，而不是让 ExoPlayer 自己支持：
     *   · 播放器里永远只有**一个** MediaItem（一集一条 HLS 流，换集走
     *     `switchToSource`，实例都不重建）。所以 `hasNextMediaItem()` 恒为
     *     false，`COMMAND_SEEK_TO_NEXT_MEDIA_ITEM` 不可用 ——
     *     系统据此判断「这个 App 没有下一集」，通知和锁屏上就**不会出现**
     *     下一集按钮，耳机双击也不会切集。
     *   · 这里把四个命令声明成「可用」，然后把对应调用拦下来转给 Dart。
     *     注意是**拦截后不转给播放器**：ExoPlayer 在单集列表上 seekToNext
     *     会掉进「seek 到 0」或「什么都不做」，两个都不是用户想要的行为。
     *
     * 包装器对其它所有 Player 方法都是透明转发（[ForwardingPlayer]），
     * 所以位置、时长、缓冲、playWhenReady、错误码……系统读到的都是真值，
     * 进度条和缓冲状态没有任何变化。
     */
    private inner class SessionPlayer(
        player: Player,
        private val onStep: (Int) -> Unit,
    ) : ForwardingPlayer(player) {

        override fun getAvailableCommands(): Player.Commands {
            val builder = super.getAvailableCommands().buildUpon()
            if (stepAllowed(-1)) {
                builder.addAll(
                    Player.COMMAND_SEEK_TO_PREVIOUS,
                    Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
                )
            }
            if (stepAllowed(1)) {
                builder.addAll(
                    Player.COMMAND_SEEK_TO_NEXT,
                    Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
                )
            }
            return builder.build()
        }

        // 「有没有上一集 / 下一集」按真实集数边界回答（第一集 / 最后一集 /
        // 电影会各缺一个或两个按钮）。注意这是**单集列表**的播放器，
        // ExoPlayer 自己永远答 false —— 不覆写的话系统媒体控件上这三个按钮
        // 一个都不会出现。
        override fun hasPreviousMediaItem(): Boolean = stepAllowed(-1)

        override fun hasNextMediaItem(): Boolean = stepAllowed(1)

        /** 边界由 Dart 决定（只有它知道集数表和当前第几集）。 */
        private fun stepAllowed(delta: Int): Boolean = try {
            controller?.hasEpisodeStep(delta) == true
        } catch (_: Throwable) {
            true
        }

        // 下面四个是系统实际会调到的入口。注意只拦不转：
        // ExoPlayer 在单集列表上 seekToNext / seekToPrevious 会掉进「seek 到
        // 片头」或者什么都不做，两个都不是用户按下一集想要的结果。
        override fun seekToPrevious() {
            onStep(-1)
        }

        override fun seekToPreviousMediaItem() {
            onStep(-1)
        }

        override fun seekToNext() {
            onStep(1)
        }

        override fun seekToNextMediaItem() {
            onStep(1)
        }
    }
}

/**
 * 后台播放链路的**唯**异常出口（BG_GATE，2026-11-15）。
 *
 * 为什么要有它：这次「任意剧点播放就闪退」的教训不是「少写了一个 try」，
 * 而是**异常最后落在哪个线程**。Service 的 onCreate / onStartCommand /
 * 通知更新 / 播放器回调全在主线程，主线程上任何未捕获异常 = 进程当场死，
 * 没有报错页、没有 toast，用户只看到闪退。所以后台播放链路里每一句系统
 * 调用都必须经过这里：失败只写日志，返回值用 null 表示「没成功」。
 *
 * 日志 tag 固定 `FxPlay`，用户侧一条命令就能取证：
 *   `adb logcat -s FxPlay FxBg FxCrash`
 */
internal object BgSafe {
    const val TAG = "FxPlay"

    /** 跑一段可能失败的逻辑；失败记日志并返回 null。 */
    inline fun <T> run(where: String, block: () -> T): T? {
        return try {
            block()
        } catch (error: Throwable) {
            try {
                Log.w(TAG, "$where 失败：${error.javaClass.simpleName}: ${error.message}", error)
            } catch (_: Throwable) {
                // 连日志都写不出去（极罕见）：也绝不外抛。
            }
            null
        }
    }

    /** [run] 的别名，用在「读一个值」的地方（语义更清楚）。 */
    inline fun <T> value(where: String, block: () -> T): T? = run(where, block)
}

/**
 * 把 media3 的 [MediaNotification.Provider] 包一层（BG_GATE，2026-11-15）。
 *
 * 只做两件事：
 *   1. 记住 media3 画好的那条 Notification —— 进前台时要原样交给
 *      `startForeground(id, notification, type)`，这样通知栏 / 锁屏 / 车机
 *      看到的仍然是 media3 的媒体卡片（封面、进度、上下一集），不是自绘的；
 *   2. **接管异步回调**：封面是异步加载的，media3 默认会把「通知变了」回调给
 *      `MediaSessionService.onNotificationUpdated()`，而那条路会自己
 *      `startForeground(...)`（库内部，异常接不住）。换成我们的回调以后，
 *      前台只从 [PlaybackService.enterForegroundGuarded] 进。
 */
@OptIn(UnstableApi::class)
private class RecordingNotificationProvider(
    private val delegate: MediaNotification.Provider,
    private val onNotification: (MediaNotification) -> Unit,
) : MediaNotification.Provider {

    override fun createNotification(
        session: MediaSession,
        customLayout: ImmutableList<CommandButton>,
        actionFactory: MediaNotification.ActionFactory,
        callback: MediaNotification.Provider.Callback,
    ): MediaNotification {
        val created = delegate.createNotification(session, customLayout, actionFactory) { updated ->
            BgSafe.run("providerCallback") { onNotification(updated) }
        }
        BgSafe.run("providerCreated") { onNotification(created) }
        return created
    }

    override fun handleCustomCommand(session: MediaSession, action: String, extras: Bundle): Boolean =
        BgSafe.value("providerCustomCommand") {
            delegate.handleCustomCommand(session, action, extras)
        } ?: false
}

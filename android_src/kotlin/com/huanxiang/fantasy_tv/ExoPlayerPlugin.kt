package com.huanxiang.fantasy_tv

import android.app.Activity
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.net.Uri
import android.os.Build
import android.util.Log
import android.content.Context
import android.content.Intent
import android.os.PowerManager
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.SeekParameters
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.source.LoadEventInfo
import androidx.media3.exoplayer.source.MediaLoadData
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.ui.PlayerView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * 重试策略（ALIGN_FONGMI 2026-11-15）：**不再自定义**，用 media3 默认
 * [androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy]。
 *
 * 为什么不自己写（原来的 FAST_FAIL_HTTP 已删除）：
 *   · FongMi/TV 的 `ExoMediaSourceFactory.setLoadErrorHandlingPolicy()` 是
 *     空实现（`return this;`），也就是说壳里跑的就是 media3 默认策略；
 *   · 默认策略：任意错误重试 3 次，退避 0 / 1s / 2s（上限 5s），不按状态码
 *     区别对待 —— 5xx / 403 这种 CDN 抖动是常态，壳靠重试吃掉，一次就判死
 *     反而把「等一下就能播」的分片变成「整条线路失败」；
 *   · 我们之前的自定义策略把它们判死，Dart 救援链随即换线路重来 ——
 *     这就是「壳秒开、我们卡」的一部分：同一片我们多花一整轮重开。
 *
 * 死地址不再是威胁：连接 / 读超时已经抬到 30s（对齐壳的 OkHttp），
 * 真正的死地址会在 3 次重试后由 `onPlayerError` 回到 Dart，最多一个超时周期。
 */

/**
 * ExoPlayer（Media3）内核桥接。
 *
 * 为什么不用 better_player / video_player：
 *   它们自带 widget 层和生命周期管理，跟 FxPlayer 现有的救援链、看门狗、
 *   一起看同步会打架。这里只做「最小内核」—— 只管播放，画面用 PlatformView
 *   交给 Flutter 叠控制层，控制权完全在 FxPlayer 手里。
 *
 * 关键配置（ALIGN_FONGMI 2026-11-15：逐项对齐 FongMi/TV 的 ExoPlayer 取值）：
 *   · LoadControl 50s/50s/1s/2s + backBuffer 0（壳 media3 fork 的默认值）
 *   · 传输层走 OkHttp（TRANSPORT_OKHTTP，2026-11-15）：全 App 一个
 *     OkHttpClient，HTTP/2 + 全局连接池 + trust-all + 兜底 UA，见 [PlayerHttp]；
 *     connect / read 超时 30s 挂在 client 上，跟随 302 跨协议重定向
 *   · 不自定义 LoadErrorHandlingPolicy（壳跑 media3 默认 3 次重试）
 *   · HLS 的 http 源先做一次清单预归并（master → variant，800ms 上限）
 *   · 播放路径只读缓存，落盘交给预取线程（壳 setCacheWriteDataSinkFactory(null)）
 *   · 预取在首帧之后才开灌、并从下一片起，播放缓冲时让路
 *   · seek 静音闸 1200ms，首帧回来恢复音量
 *   · DefaultHlsPlaylistParser 原生认 #EXT-X-ENDLIST，不会误判成直播
 *   · MediaCodecSelector 自动选硬解，4K HEVC 走硬件解码
 */
@OptIn(UnstableApi::class)
class ExoPlayerPlugin(private val context: Context) : MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler, PlaybackService.Controller {

    companion object {
        /** 真机 logcat 过滤标签：`adb logcat -s FxExo`。 */
        const val LOG_TAG = "FxExo"

        const val METHOD_CHANNEL = "fantasy_tv/exo_player"
        const val EVENT_CHANNEL = "fantasy_tv/exo_player_events"
        const val VIEW_TYPE = "fantasy_tv/exo_view"

        /**
         * seek 静音闸兜底时长（按逆向报告 §10 改动 3，取值 1200ms）。
         *
         * 拖动瞬间把音量压到 0，首帧回来再恢复；万一没出帧，这里无条件恢复，
         * 否则播放器会永久静音。
         */
        const val SEEK_AUDIO_GATE_TIMEOUT_MS = 1200L

        /**
         * 实时网速的推送间隔：1 秒（NET_SPEED 2026-11-15）。
         *
         * 用户的要求是「每秒推一次到 Dart，Dart 只负责显示」。原来只有
         * 事件驱动 + Dart 侧 250ms 轮询，缓冲中位置不动、也没有任何播放事件，
         * 网速那一行就永远停在首帧前的 0 —— 现在由原生按秒推一次。
         */
        const val NET_TICK_MS = 1000L

        /**
         * POST_NOTIFICATIONS 的请求码（BG_SERVICE，2026-11-15）。
         *
         * 只用来区分结果，不用管值；与 MainActivity 里存储权限的请求码
         * （0x2101 一类）错开即可。
         */
        const val REQUEST_NOTIFICATION_PERMISSION = 0x0B02

        /**
         * 分片磁盘缓存上限：1.5 GiB（逆向报告的取值区间 1.5–2 GiB）。
         *
         * 对方把 2 GiB 写成常量却用了 NoOpCacheEvictor（永不淘汰，这是他们的
         * 漏洞）；这里用 LRU，缓存满了自动淘汰最久未用的分片。
         */
        const val CACHE_MAX_BYTES = 1536L * 1024 * 1024

        /**
         * 首页续播预取的读缓冲：64KB（和 [SegmentPreloader.BUFFER_SIZE] 一致）。
         *
         * 预取只是「把播放器马上要的那一片提前落盘」，读得比播放器快没有意义，
         * 反而会和首屏请求抢带宽，所以按同一档大小串行读。
         */
        const val PREFETCH_BUFFER_SIZE = 64 * 1024

        /**
         * 播放数据源的连接 / 读超时（ALIGN_FONGMI 2026-11-15：30s / 30s）。
         *
         * 壳的取值就是 30 秒：`catvod/net/OkHttp.java` 里
         * `TIMEOUT = TimeUnit.SECONDS.toMillis(30)`，player 用的那个 OkHttpClient
         * 是 connectTimeout / readTimeout / writeTimeout 全 30s。
         *
         * 我们原来压到 6s / 8s（FAST_FAIL_HTTP 那版）：移动网络下 CDN 边缘
         * 抖一下、首片要等回源，8 秒就断，断掉之后 Dart 救援链换线路重来，
         * 用户看到的就是「明明能播却一直转圈」。死地址不再靠短超时兜，
         * 靠 media3 默认的 3 次重试 + onPlayerError 把错误交回 Dart。
         *
         * TRANSPORT_OKHTTP（2026-11-15）：这两个值现在**挂在 OkHttpClient 上**
         * （[PlayerHttp.client]），DataSource.Factory 侧不再有对应开关；
         * 常量留在这里是给日志 / 文档做单一取值来源，改超时只改 PlayerHttp。
         */
        const val HTTP_CONNECT_TIMEOUT_MS = 30_000
        const val HTTP_READ_TIMEOUT_MS = 30_000

        /**
         * 播放层分级重试上限（改动 ⑤）：同一集同一线路最多重试 2 次。
         *
         * 第 1 次：IO / HTTP 类错误 → 让 Dart 重新 resolve 地址 + 本地重开；
         * 第 2 次：解码类错误 → 切换解码模式（硬解 ↔ 软解）再 prepare；
         * 超过这次数才把错误交回 Dart，由救援链换线路。
         *
         * 为什么是 2 而不是 3：media3 内部对分片本身已经有 3 次退避重试，
         * 真正冒到 onPlayerError 的，是「整条清单/首片都不行」这种级别，
         * 再叠加两轮换地址 / 换解码器就够了，再多只是在拖时间。
         */
        const val MAX_LAYER_RETRIES = 2

        /**
         * 下一集预载的触发延时（改动 ⑥）：首帧之后、播放稳定 3 秒才开灌。
         *
         * 起播这 3 秒里播放器的缓冲 / 首个分片要独占带宽，抢在前面预载下一集
         * 只会让首屏更慢。
         */
        const val NEXT_PRELOAD_STABLE_MS = 3_000L

        /**
         * IQ_CODEC（2026-11-15）：解码器表扫一次就够。
         *
         * `MediaCodecList(REGULAR_CODECS)` 在一次进程生命周期里不会变，
         * 而起播路径上任何一次多余扫描都是几十毫秒的用户等待，所以结果
         * 缓存到进程退出。null = 还没扫过。
         */
        @Volatile
        private var hevcHardwareCache: Boolean? = null

        /**
         * 这台机器能不能**硬解** HEVC（爱奇艺线路 1080P 码流）。
         *
         * 判据只有一条：解码器表里存在支持 `video/hevc` 且
         * `isHardwareAccelerated` 的解码器。软解不算 —— 1080P HEVC 软解在
         * 手机上直接掉到个位数帧率，用户看到的是「画质好了但卡成幻灯片」，
         * 比给 896×504 的 H.264 更糟。
         *
         * 任何异常（个别 ROM 的 MediaCodecList 会抛）都按「不支持」处理：
         * 走 AVC 永远播得出来。
         */
        fun supportsHevcHardware(): Boolean {
            hevcHardwareCache?.let { return it }
            var supported = false
            try {
                val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
                loop@ for (info in list.codecInfos) {
                    if (info.isEncoder) continue
                    for (type in info.supportedTypes) {
                        if (!type.equals("video/hevc", ignoreCase = true)) continue
                        if (!isHardwareCodec(info)) continue
                        supported = true
                        break@loop
                    }
                }
            } catch (error: Throwable) {
                Log.i(LOG_TAG, "supportsHevc 探测失败：${error.javaClass.simpleName}")
                supported = false
            }
            hevcHardwareCache = supported
            Log.i(LOG_TAG, "supportsHevc=$supported")
            return supported
        }

        /**
         * 这个解码器是不是**硬件**解码器。
         *
         * `MediaCodecInfo.isHardwareAccelerated` 是 API 29 才有的，而本项目
         * minSdk 23：直接调用在老机器上是 NoSuchMethodError（被外层 catch
         * 兜住就永远返回 false，等于把能硬解的机器也降成 AVC）。
         * API 29 以下按命名判：`OMX.google.*` / `c2.android.*` 是 Google 的
         * 软解，其余（OMX.qcom / OMX.MTK / c2.qti …）都是厂商硬解。
         */
        private fun isHardwareCodec(info: MediaCodecInfo): Boolean {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                return info.isHardwareAccelerated
            }
            val name = info.name.lowercase()
            if (name.startsWith("omx.google.") || name.startsWith("c2.android.")) {
                return false
            }
            return !name.contains("software") && !name.contains("sw.decoder")
        }

        /**
         * 视频编码短名：`hevc` / `avc` / `av1` / `vp9` …（'' = 还没有视频轨）。
         *
         * 诊断浮层的「编码」行用它 —— 请求参数只说明我们**要**什么，
         * 内核解出来的轨道才说明服务端**给**了什么（HEVC 起播失败降级成
         * AVC 时，两者不一样）。
         */
        fun codecNameOf(mime: String?): String {
            val m = (mime ?: return "").lowercase()
            if (m.isEmpty()) return ""
            return when {
                m.contains("hevc") || m.contains("h265") -> "hevc"
                m.contains("avc") || m.contains("h264") -> "avc"
                m.contains("av01") || m.contains("av1") -> "av1"
                m.contains("vp9") -> "vp9"
                m.contains("vp8") -> "vp8"
                else -> m.substringAfter('/', m)
            }
        }
    }

    private var player: ExoPlayer? = null
    /// TEXTURE_VIEW（2026-11-14）：画面必须用 TextureView，不能用 SurfaceView。
    ///
    /// PlayerView 默认 surface_type=surface_view。SurfaceView 有独立图层，
    /// 在 Flutter 的混合合成 PlatformView 里不参与合成，于是「声音正常、
    /// 画面全黑」—— 用户反复报的就是这个。
    /// TextureView 走正常的 View 绘制流程，能被合成进 PlatformView。
    private var videoView: android.view.TextureView? = null
    private var events: EventChannel.EventSink? = null

    /// 分片磁盘缓存：拖回已看过的地方不再回源（CDN 有 429 限流）。
    private var mediaCache: SimpleCache? = null

    /// 分片预取器：和播放器共用同一份 [mediaCache]（同一个 cacheKey），
    /// 所以预取过的分片对播放器来说就是缓存命中（改动 ②）。
    private var preloader: SegmentPreloader? = null

    /// 等首帧再开灌的预取请求（PRELOAD_AFTER_FIRST_FRAME，ALIGN_FONGMI 2026-11-15）。
    ///
    /// `open` 只记录，不下载；[Player.Listener.onRenderedFirstFrame] 里才真正交给
    /// [SegmentPreloader] —— 起播阶段那一片只留给播放器自己。
    private var pendingPreload: PreloadRequest? = null

    /** 一次待执行的预取：源地址 + 请求头 + 本次 open 的起始位置。 */
    private class PreloadRequest(
        val url: String,
        val headers: Map<String, String>,
        val startPositionMs: Long,
    )

    private var lastError: String? = null

    /**
     * 「真失败」码（SLOW_NET 2026-11-15，Dart 侧 `fatalError` 字段）。
     *
     * 空串 = 没有真失败（可能只是网慢）。非空就是这条线路**真的**不能播：
     * ```
     * http_401 / http_403 / http_404 / http_410 / http_500 / http_502 / http_503
     * dns_error         DNS 解析不到主机
     * connect_refused   TCP 连接被拒
     * tls_error         证书 / 握手失败
     * manifest_invalid  清单不是 #EXTM3U / 解析不了
     * no_segments       清单里 0 个分片 / 所有分片都 4xx
     * ```
     * Dart 拿到它**不等任何窗口**，立刻换下一条 —— 这些错误不可能是网慢。
     */
    private var fatalErrorCode: String = ""

    /** 上一次报给 Dart 的真失败码（同一个错误只处理一次）。 */
    private var reportedFatalCode: String = ""

    // ------------------------------------------------ 下一集预载（改动 ⑥）

    /// 下一集预载器（和播放器同一份 [mediaCache]，只写不读）。
    private var nextPreloader: NextEpisodePreloader? = null

    /// 已经预载过的下一集地址，避免同一集重复灌。
    private var nextPreloadUrl = ""

    // ------------------------------------------------ 分级重试（改动 ⑤）

    /// 当前打开源的参数：重试要用同一份（url / headers / isHls）。
    private class OpenedItem(
        val url: String,
        val headers: Map<String, String>,
        val isHls: Boolean,
    )

    private var openedItem: OpenedItem? = null

    /// 重试计数器的键（url|isHls）：换集 / 换线路换了地址就重新计数。
    private var retryKey = ""

    /// 已经重试过几次（只针对 [retryKey] 这一条）。
    private var retryCount = 0

    /// 最近一次重试原因："" / "io" / "decode"（快照字段，Dart 侧日志用）。
    @Volatile
    private var retryReason = ""

    /**
     * 重新 resolve 播放地址的请求号（快照字段）。
     *
     * 原生侧没法自己解析播放地址（那是 Dart 的 /api/play），所以第 1 次
     * IO 重试时把它 +1：Dart 看到变化就拿新地址重新 open，地址过期这条
     * 才算真的被修掉。原生同时用原地址重开一次兜底，两条路谁先到都算修复。
     */
    @Volatile
    private var retryResolveToken = 0L

    /// 出错前最后已知的播放位置：重开时从这里接着播，不回到片头。
    @Volatile
    private var lastKnownPositionMs = 0L

    /// 是否已经切到「优先软解」的渲染器（改动 ⑦ 的落点）。
    @Volatile
    private var softDecoderPreferred = false

    /**
     * 「播放器正在缓冲」的**主线程快照**（CRASH_FIX 2026-11-15）。
     *
     * 为什么需要这个字段（真机闪退根因）：
     * 两个预取器（[SegmentPreloader] / [NextEpisodePreloader]）都跑在
     * 自己的后台线程上，它们的 `pauseGate` 回调原来直接读
     * `player.playbackState`。而 media3 的 `ExoPlayer.getPlaybackState()`
     * 第一件事就是 `verifyApplicationThread()`：**非应用线程访问会抛
     * IllegalStateException**。那个异常在后台线程里没人接，直接
     * `FATAL EXCEPTION: PreloaderHls` 把进程带走 —— 用户看到的就是
     * 「一点播放就闪退」。
     *
     * 正确做法：播放器状态只在主线程读，读到的结果写进这个 volatile
     * 字段，后台线程只看字段（纯内存读，不碰播放器）。取值在
     * [refreshBufferingFlag] / [snapshot] 里刷新（两者都只在主线程执行）。
     */
    @Volatile
    private var playerBuffering: Boolean = true

    /// 首页续播预取的单线程队列（并发 = 1，和 [SegmentPreloader] 同一策略）。
    ///
    /// 为什么不由 [SegmentPreloader] 代劳：那个预取器属于「当前播放的那个源」，
    /// 首页可能还没创建过播放器，而且它的代际号会被播放页的 seek 作废。
    /// 首页预取只做「把一个已知分片写进同一份缓存」，独立队列最简单，
    /// 也绝不打断播放器自己的预取。
    private val prefetchQueue: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "FxPrefetch").also { it.isDaemon = true }
    }

    /// 清单预归并（MANIFEST_MERGE，2026-11-15）的串行队列。
    ///
    /// 为什么单独一条线程：`open()` 是在 MethodChannel 的主线程上调进来的，
    /// 而归并要发一次网络请求（最多 800ms）。放主线程 = 起播先卡一次；
    /// 放在这里跑完再 post 回主线程，播放器 API 仍然只在主线程调。
    /// 单线程足够了 —— 归并只在 open 时发生，用户换线路也不会撞在一起。
    private val manifestQueue: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "FxManifest").also { it.isDaemon = true }
    }

    /// 当前 open 的代际号（只在主线程读写）。
    ///
    /// 归并是异步的：A 地址的归并还没回来，用户又点了 B 地址，A 的结果回来
    /// 时不能再去 setMediaSource（否则就是「点了 B 播出来 A」）。用代际号作废。
    private var openGeneration = 0

    // ---- seek 音频闸（改动 ③）：拖动时静音，首帧回来再恢复 ----
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var seekGateActive = false
    private var volumeBeforeSeekGate = 1f
    private val seekGateTimeout = Runnable { endSeekAudioGate() }

    /**
     * 每秒推一次快照（NET_SPEED 2026-11-15）。
     *
     * 为什么需要它：缓冲阶段既没有播放事件，位置 / 缓冲时长也不动，光靠
     * 「事件驱动 + Dart 250ms 轮询」时，网速那一行在首帧前长时间是同一个数
     * （原来干脆恒 0）。这里由原生按秒算一次速率并推给 Dart —— 界面只负责显示。
     *
     * 只在有监听方时才自转：`onCancel` / [dispose] 会把它摘掉，不留空转。
     */
    private val netTicker = object : Runnable {
        override fun run() {
            try {
                // 先算速率：即使没有 Dart 监听方，`[FxNet]` 日志也照打，
                // 真机 `adb logcat -s FxExo` 能直接核对网速在动。
                FxNet.speedPerSec()
                if (player != null && events != null) emit()
            } catch (error: Throwable) {
                Log.w(LOG_TAG, "NET tick 失败：${error.javaClass.simpleName}")
            }
            mainHandler.postDelayed(this, NET_TICK_MS)
        }
    }

    /**
     * 是否已经真正渲染出过一帧（FIRST_FRAME，2026-11-14）。
     *
     * 这个值是 Dart 侧加载层唯一的显隐判据。以前 Dart 用
     * `buffering == false` / `playing == true` / 「拿到视频宽高」判断，
     * 三种都可能在首帧上屏之前成立 —— 用户看到「缓冲层消失、画面还黑」。
     *
     * `open` / `seek` 都会把它重置成 false，直到 [Player.Listener.onRenderedFirstFrame]
     * 再次回调才变 true。
     */
    @Volatile
    private var firstFrameRendered = false

    // ------------------------------------------------ 播放诊断（DIAGNOSTICS 2026-11-15）

    /**
     * 累计丢帧数（[AnalyticsListener.onDroppedVideoFrames]）。
     *
     * 用户「看着卡」和「解码跟不上」是两件事：前者是缓冲，后者是丢帧。
     * 诊断浮层把丢帧数摆出来，才能区分「网慢」和「机器解码不动」。
     */
    @Volatile
    private var droppedFrameCount = 0L

    /**
     * 播放器自己那次「清单加载完成」花了多少毫秒（-1 = 还没到）。
     *
     * 和 [FxTiming] 的 `manifest_merged` 是两个不同的点：
     *   · manifest_merged = 我们（代理 / 预归并）已经拿到清单；
     *   · 这个值 = media3 解析完清单、可以往外选分片的耗时。
     * 两个都摆出来，才能看出「是我们慢还是播放器解析慢」。
     */
    @Volatile
    private var playerManifestLoadMs = -1L

    /** 当前 open 是否走了本地清单代理（诊断 / 日志用）。 */
    @Volatile
    private var manifestProxied = false

    /** 拖动开始时刻（nanoTime）：0 = 当前没有待量的 seek。 */
    @Volatile
    private var seekStartedNanos = 0L

    /**
     * 上一次拖动到出画用了多少毫秒（-1 = 还没拖过）。
     *
     * 目标：拖动响应 ≤ 500ms 出画面。起播分段计时量不到这一档，但用户
     * 「拖动半天不出画面」的体感和起播慢是同一类问题，所以单独记一笔：
     * `adb logcat -s FxTiming` 会打 `seek_first_frame out=XXXms`。
     */
    @Volatile
    private var lastSeekOutMs = -1L

    fun attach(messenger: BinaryMessenger) {
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(this)
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(this)
        // TRANSPORT_WARMUP（2026-11-15）：OkHttp client 的 lazy 初始化会建
        // SSLContext（trust-all）。它第一次如果发生在后台线程（清单预归并的
        // FxManifest、预取的 PreloaderHls），就把「第一次 TLS 初始化」放到了
        // 一条没人兜异常的线程上。这里在主线程先热一次，之后所有线程只是读
        // 一个已经建好的对象。
        try {
            PlayerHttp.warmUp()
        } catch (error: Throwable) {
            Log.w(LOG_TAG, "传输层预热失败：${error.javaClass.simpleName}")
        }
    }

    fun dispose() {
        // BG_SERVICE：播放器实例没了，前台服务也不能留着（留 = 空保活，费电）。
        // MEDIA_SESSION：先同步把 MediaSession 摘掉 —— 它强引用着下面这台
        // 播放器，播放器先释放、session 后释放的话，media3 会去读一个已释放
        // 的 player 并抛 IllegalStateException，直接把主线程带走。
        PlaybackService.releaseSessionNow()
        stopBackground()
        mainHandler.removeCallbacks(seekGateTimeout)
        // NET_SPEED：网速 ticker 随播放器一起收掉（没人看就不用每秒算）。
        mainHandler.removeCallbacks(netTicker)
        seekGateActive = false
        pendingPreload = null
        // 下一集预载随播放器一起收掉（它只会往缓存里写，但线程要停）。
        nextPreloader?.release()
        nextPreloader = null
        nextPreloadUrl = ""
        preloader?.release()
        preloader = null
        player?.clearVideoSurface()
        player?.release()
        player = null
        events = null
        try { mediaCache?.release() } catch (_: Exception) {}
        mediaCache = null
    }

    // ------------------------------- 后台播放保活 / 媒体会话（BG_SERVICE）

    /**
     * 为什么在原生侧持有 player 引用，而不是让通知走广播回 Dart：
     *   · 通知按钮必须在 0.1 秒内响应，绕一圈 MethodChannel 回来会晚一拍；
     *   · 切后台后 Dart 侧可能被冻结（Android 12+ 的 App Freeze），
     *     广播回去的 pause 有可能没人接；
     *   · 播放器本来就在这个类里，直接调 `player.pause()` 最简单。
     *
     * MEDIA_SESSION（2026-11-15）：通知不再由我们手画，而是 media3 的
     * [PlaybackService]（MediaSessionService）把**这台播放器**包成 MediaSession
     * 交给系统 —— 通知栏媒体卡片、锁屏、负一屏媒体中心、耳机线控、车机
     * 读的都是它。播放/暂停仍然直连 player；只有「上一集 / 下一集」需要
     * 绕回 Dart（集数与线路只有 Dart 知道），走 [stepEpisode] 的请求号。
     *
     * 切后台继续播的行为完全没变：这里不改任何暂停逻辑。
     */
    private var bgTitle = ""
    private var bgEpisode = 0

    /** 当前线路名（通知副标题「第N集 · 线路名」的后半段，由 Dart 传）。 */
    private var bgLine = ""

    /** 封面地址（通知 / 锁屏的封面图，由 Dart 传；封面缓存见 PlaybackService）。 */
    private var bgCover = ""

    /**
     * 当前这一集还有没有上一集 / 下一集（由 Dart 传，默认都有）。
     *
     * 系统据此决定通知栏 / 锁屏上要不要显示那两个按钮：第一集不显示上一集、
     * 最后一集不显示下一集、电影两个都不显示。否则最后一集上的「下一集」
     * 是个按了没反应的死按钮。
     */
    @Volatile
    private var bgHasPrev = true

    @Volatile
    private var bgHasNext = true

    private var bgStarted = false

    /**
     * 上一集 / 下一集请求号（MEDIA_SESSION，2026-11-15）。
     *
     * 通知栏按钮、锁屏控件、耳机线控、车机方向盘的「上一集 / 下一集」落到
     * 原生之后，切集本身只能在 Dart 侧做（它才知道集数列表、线路、播放地址）。
     * 这里沿用 [retryResolveToken] 那套约定：请求号 +1 并推一次快照，
     * Dart 看到 `bgStepSeq` 变化就按 `bgStepDelta`（-1 / +1）切集。
     *
     * 为什么不用广播 / 新通道：事件通道本来就是「原生 → Dart」的唯一出路，
     * 而且快照里混一个计数器比多开一条通道更容易排查（ADB 上一眼能看）。
     */
    @Volatile
    private var bgStepSeq = 0L

    @Volatile
    private var bgStepDelta = 0


    override fun isPlaying(): Boolean = try {
        player?.isPlaying == true
    } catch (_: Throwable) {
        true
    }

    override fun togglePlay(): Boolean {
        val p = player ?: return false
        return try {
            if (p.isPlaying) {
                p.pause()
                false
            } else {
                p.play()
                true
            }
        } catch (error: Throwable) {
            Log.w(LOG_TAG, "通知栏切换失败：${error.javaClass.simpleName}")
            false
        }
    }

    override fun stopPlayback() {
        bgStarted = false
        try {
            player?.pause()
        } catch (error: Throwable) {
            Log.w(LOG_TAG, "通知栏关闭播放失败：${error.javaClass.simpleName}")
        }
        stopBackground()
    }

    /** Dart 在 open 之前把片名 / 集号 / 线路名 / 封面交进来（通知与锁屏的元数据）。 */
    fun setBackgroundMedia(
        title: String,
        episode: Int,
        line: String = "",
        cover: String = "",
        hasPrev: Boolean = true,
        hasNext: Boolean = true,
    ) {
        bgHasPrev = hasPrev
        bgHasNext = hasNext
        val name = title.trim()
        // 换片（片名变了）时集号必须归零：电影 / 上一部片的「第5集」
        // 不该留在这一部片的通知副标题里。同一部片换集则保留传入的集号。
        if (name.isNotEmpty() && name != bgTitle) {
            bgTitle = name
            bgEpisode = 0
        }
        if (episode > 0) bgEpisode = episode
        bgLine = line.trim()
        bgCover = cover.trim()
    }

    /**
     * 通知栏 / 锁屏 / 耳机线控 / 车机的「上一集 / 下一集」。
     *
     * 这里只记一次请求并把事件推给 Dart，**不**动播放器：ExoPlayer 里只有
     * 一个 MediaItem（一集），原生既不知道下一集在哪条线路，也没有它的地址。
     * 播放页收到后走原来的 `_switchEpisode`，换集流程和手动点下一集完全一致。
     */
    override fun stepEpisode(delta: Int) {
        bgStepDelta = if (delta < 0) -1 else 1
        bgStepSeq += 1
        Log.i(
            LOG_TAG,
            "媒体控制：${if (bgStepDelta < 0) "上一集" else "下一集"}（seq=$bgStepSeq）",
        )
        mainHandler.post { emit() }
    }

    /** session 要绑的就是这台播放器（不新建实例）。 */
    override fun currentPlayer(): Player? = player

    /** 还有没有上一集 / 下一集（系统据此显示或隐藏通知栏那两个按钮）。 */
    override fun hasEpisodeStep(delta: Int): Boolean =
        if (delta < 0) bgHasPrev else bgHasNext

    /**
     * 后台保活总开关。
     *
     * BG_SERVICE_ENABLED（2026-11-15）：事故当晚它是 `false`（整段旁路，
     * 先保证能播）。根因查清后恢复成 `true` —— 崩溃点不在「起服务」这件事，
     * 而在 media3 库内部自己调 `startForeground` 时抛出的异常没人接
     * （详见 docs/BACKGROUND-PLAYBACK.md §1）。现在前台由
     * [PlaybackService.enterForegroundGuarded] 接管、其余全部 runCatching，
     * 这条链路**再也没有能抛到主线程的路径**。留着这个开关是给真机兜底：
     * 万一某台 ROM 还有别的惊喜，改回 `false` 就退回「能播但没后台保活」。
     */
    private val BG_SERVICE_ENABLED = true

    /**
     * 起后台播放服务（可重复调用：已在跑时只刷新 session / 通知）。
     *
     * BG_GATE（2026-11-15）：两条调用路径的前置条件不一样 ——
     *
     *   · `open()` 之后那条：open 刚回来，App 一定在前台，可以直接起；
     *   · `onIsPlayingChanged(true)` 那条：恢复播放可能发生在**后台**
     *     （用户从通知栏 / 耳机按键里点继续），这时起服务会撞上 Android 12+
     *     的「后台不允许启动前台服务」。所以那条路径传
     *     `requireForeground = true`，先确认
     *     `RunningAppProcessInfo.importance == IMPORTANCE_FOREGROUND`。
     *
     * 被门禁挡住 = 只是「这一拍没有后台保活」，播放本身完全不受影响：
     * 下一次 open / 回到前台时自然会补上。
     */
    fun startBackground(requireForeground: Boolean = false) {
        if (bgTitle.isEmpty()) return // 没有片名 = 不是正式播放，不挂保活
        if (!BG_SERVICE_ENABLED) {
            bgStarted = false
            return
        }
        val block = PlaybackService.gateServiceStart(context, requireForeground)
        if (block != BgBlock.NONE) {
            bgStarted = false
            Log.w(
                BgSafe.TAG,
                "后台服务跳过（播放继续）：$block " +
                    BgGate.describe(PlaybackService.readEnv(context), block),
            )
            return
        }
        bgStarted = true
        BgSafe.run("PlaybackService.start") {
            PlaybackService.start(context, bgTitle, bgEpisode, this)
        } ?: run { bgStarted = false }
    }

    /** 停前台服务（[PlaybackService.stop] 内部有实例身份校验）。 */
    fun stopBackground() {
        bgStarted = false
        BgSafe.run("PlaybackService.stop") { PlaybackService.stop(context, this) }
    }

    /**
     * 电池优化白名单入口。**只在用户从「设置」里点时调用**，
     * 不在启动 / 播放时弹系统对话框（那样很烦，而且用户不知道是干嘛的）。
     *
     * 返回 true = 已经在白名单里或已把系统页面拉起来。
     */
    private fun requestIgnoreBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        val pkg = context.packageName
        try {
            val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
            if (power?.isIgnoringBatteryOptimizations(pkg) == true) return true
        } catch (error: Throwable) {
            Log.w(LOG_TAG, "读取电池优化状态失败：${error.javaClass.simpleName}")
        }
        // ① 优先用「本应用的电池优化」直连弹窗（设置页里主动点的，不算骚扰）；
        // ② 部分 ROM 没有这个 action，退到「电池优化应用列表」让用户自己找。
        for (action in arrayOf(
            android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            android.provider.Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS,
        )) {
            try {
                val intent = Intent(action)
                if (action == android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS) {
                    intent.data = android.net.Uri.parse("package:$pkg")
                }
                if (context !is Activity) intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                context.startActivity(intent)
                return true
            } catch (error: Throwable) {
                Log.w(
                    LOG_TAG,
                    "打开电池优化页面失败 action=$action：${error.javaClass.simpleName}",
                )
            }
        }
        return false
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        return try {
            val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
            power?.isIgnoringBatteryOptimizations(context.packageName) == true
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * 一次性提示的取用（读后即清）：上次在后台播放时被系统压过内存，
     * 就在下次启动时提示用户加电池白名单。返回 true = 需要提示。
     */
    private fun consumeInterruptHint(): Boolean {
        return try {
            val prefs = context.getSharedPreferences(PlaybackService.PREFS, Context.MODE_PRIVATE)
            val pending = prefs.getBoolean(PlaybackService.PREF_INTERRUPTED, false)
            if (pending) {
                prefs.edit().putBoolean(PlaybackService.PREF_INTERRUPTED, false).apply()
                Log.i(LOG_TAG, "一次性提示：后台播放曾被系统中断")
            }
            pending
        } catch (error: Throwable) {
            Log.w(LOG_TAG, "读取一次性提示失败：${error.javaClass.simpleName}")
            false
        }
    }

    /**
     * Android 13 起通知必须运行时授权，否则通知栏只有「点进去才看得见」的
     * 沉默通知 —— 也就是前台服务起来了但用户看不到控件。
     *
     * 只问一次（用户拒绝就记住，不再弹）；拒绝也不影响播放，只是没通知。
     */
    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < 33) return
        try {
            val activity = context as? Activity ?: return
            val granted = activity.checkSelfPermission(
                "android.permission.POST_NOTIFICATIONS",
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
            if (granted) return
            val prefs = context.getSharedPreferences(PlaybackService.PREFS, Context.MODE_PRIVATE)
            if (prefs.getBoolean(PlaybackService.PREF_NOTIF_ASKED, false)) return
            prefs.edit().putBoolean(PlaybackService.PREF_NOTIF_ASKED, true).apply()
            activity.requestPermissions(
                arrayOf("android.permission.POST_NOTIFICATIONS"),
                REQUEST_NOTIFICATION_PERMISSION,
            )
            Log.i(LOG_TAG, "已请求 POST_NOTIFICATIONS")
        } catch (error: Throwable) {
            Log.w(LOG_TAG, "请求通知权限失败：${error.javaClass.simpleName}")
        }
    }

    // ---------------- EventChannel ----------------

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        events = sink
        player?.let { bindListener(it) }
        // NET_SPEED：开始按秒推快照（重复 onListen 时先摘掉旧的，避免多份）。
        mainHandler.removeCallbacks(netTicker)
        mainHandler.postDelayed(netTicker, NET_TICK_MS)
    }

    override fun onCancel(arguments: Any?) {
        events = null
        mainHandler.removeCallbacks(netTicker)
    }

    // ---------------- MethodChannel ----------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        // CRASH_GUARD（2026-11-15）：MethodChannel 的回调跑在**主线程**上，
        // 这里任何未捕获的异常（IllegalArgumentException / IllegalStateException
        // / NoClassDefFoundError）都会直接把进程带走 —— 用户看到的就是
        // 「点播放 / 拖动进度条直接闪退」，而且 logcat 里只有一行
        // AndroidRuntime: FATAL EXCEPTION: main，看不出是哪一家的锅。
        // 现在兜住 Throwable，一律回 result.error，由 Dart 侧走救援链。
        try {
            handleMethod(call, result)
        } catch (error: Throwable) {
            Log.e(
                LOG_TAG,
                "通道方法 ${call.method} 异常：${error.javaClass.simpleName}: ${error.message}",
                error,
            )
            try {
                result.error(
                    "plugin_error",
                    error.message ?: error.javaClass.simpleName,
                    null,
                )
            } catch (ignored: Throwable) {
                // 已经回过话（重复 reply）时 result.error 会抛：忽略即可。
            }
        }
    }

    private fun handleMethod(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> {
                ensurePlayer()
                result.success(true)
            }
            "open" -> {
                val url = (call.argument<String>("url") ?: "").trim()
                // URL_GUARD（2026-11-15）：空串 / 非法的地址**绝不能**交给
                // ExoPlayer。media3 在 setMediaSource 里对空 Uri 会抛
                // IllegalArgumentException，而那条路径在主线程上 —— 又是一次
                // 「点播放直接闪退」。这里提前拦掉，回一句可读的话。
                if (url.isEmpty()) {
                    result.error("bad_url", "这一集没有播放地址，换一条线路试试", null)
                    return
                }
                if (!PlayerHttp.isPlayableUrl(url)) {
                    result.error("bad_url", "播放地址不合法（$url），换一条线路试试", null)
                    return
                }
                val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
                val isHls = call.argument<Boolean>("isHls") ?: true
                // RESUME_START：续播 / 跟进度打开时带起始位置，prepare 之前就落位。
                val startMs = call.argument<Number>("startPositionMs")?.toLong() ?: 0L
                // TIMING_PROBE（2026-11-15）：Dart 解析播放地址（hxparse 302 /
                // 换签名）花掉的时间。它发生在 open 之前，但属于用户等待，
                // 必须并进同一条时间线，否则首帧那 1.x 秒会被低估。
                val resolveMs = call.argument<Number>("resolveMs")?.toLong() ?: 0L
                // MEDIA_SESSION（2026-11-15）：通知 / 锁屏要的片名、集号、线路名、
                // 封面跟着 open 一起进来。必须在 open 之前登记 ——
                // MediaMetadata 要在 prepare 之前挂到 MediaItem 上，
                // prepare 之后再改就得换 source（等于重新起播），改不了。
                val bgName = (call.argument<String>("bgTitle") ?: "").trim()
                if (bgName.isNotEmpty()) {
                    setBackgroundMedia(
                        bgName,
                        call.argument<Number>("bgEp")?.toInt() ?: 0,
                        call.argument<String>("bgLine") ?: "",
                        call.argument<String>("bgCover") ?: "",
                        call.argument<Boolean>("bgHasPrev") ?: true,
                        call.argument<Boolean>("bgHasNext") ?: true,
                    )
                }
                open(url, headers, isHls, startMs, result, resolveMs = resolveMs)
            }
            "play" -> { player?.play(); result.success(true) }
            "pause" -> { player?.pause(); result.success(true) }
            "seek" -> {
                val ms = call.argument<Number>("positionMs")?.toLong() ?: 0L
                // 先闸音量再 seek：避免「画面还在旧帧、声音已经跳过去」（改动 ③）。
                beginSeekAudioGate()
                // FIRST_FRAME：拖动后旧帧已经作废，加载层要重新压住，
                // 等 onRenderedFirstFrame 再放开（否则就是「缓冲没了但黑屏」）。
                firstFrameRendered = false
                // TIMING_PROBE：拖动计时起点（下一次首帧就是「出画面」）。
                seekStartedNanos = System.nanoTime()
                Log.i(LOG_TAG, "SEEK ${ms}ms，首帧标记重置")
                player?.seekTo(ms)
                // 预取改道：代际 +1，旧任务立刻作废，从目标分片往后灌（改动 ②）。
                preloader?.seekTo(ms)
                emit()
                result.success(true)
            }
            "rate" -> {
                val r = call.argument<Number>("rate")?.toFloat() ?: 1f
                player?.setPlaybackSpeed(r)
                result.success(true)
            }
            // 镜像：PlatformView 不能用 Flutter 的 Transform.flip，
            // 混合合成下原生视图不跟随变换。直接翻视图自身的 scale。
            "mirror" -> {
                val fx = call.argument<Boolean>("flipX") ?: false
                val fy = call.argument<Boolean>("flipY") ?: false
                val v = videoView
                if (v != null) {
                    v.scaleX = if (fx) -1f else 1f
                    v.scaleY = if (fy) -1f else 1f
                }
                result.success(true)
            }
            // 首页「继续观看」预取：把一个分片写进播放器同一份 SimpleCache。
            // 入队即返回 true（下载在自己的线程里跑），Dart 侧不等结果。
            "prefetchSegment" -> {
                val url = call.argument<String>("url") ?: ""
                val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
                val maxBytes = call.argument<Number>("maxBytes")?.toLong() ?: 0L
                prefetchSegment(url, headers, maxBytes, result)
            }
            // IQ_CODEC（2026-11-15）：设备能不能硬解 HEVC。
            // Dart 侧首次查询后自己也会缓存，这里再缓存一层（见
            // supportsHevcHardware 的说明）。
            "supportsHevc" -> result.success(supportsHevcHardware())
            "state" -> result.success(snapshot())
            // NEXT_EPISODE_PRELOAD（改动 ⑥）：首帧 + 播放稳定 3 秒后，
            // Dart 把下一集的清单地址交进来，原生把清单 + 前 2 个分片
            // 写进播放器同一份缓存（只写不读）。入队即返回，不阻塞 Dart。
            "preloadNext" -> {
                val url = call.argument<String>("url") ?: ""
                val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
                result.success(preloadNextEpisode(url, headers))
            }
            // 换集 / 换线路时取消上一轮预载（原生 open 也会顺手取消一次，
            // 这条是给「只换集不 open」的边界情况兜底）。
            "cancelPreload" -> {
                nextPreloader?.cancel()
                nextPreloadUrl = ""
                result.success(true)
            }
            "release" -> { dispose(); result.success(true) }
            // BG_SERVICE（2026-11-15）：后台播放保活。
            //
            // 这里**只登记**片名 / 集号，真正的 startForeground 由
            // 「首次 onIsPlayingChanged(true) / 首帧渲染」触发 —— 地址打不开
            // 就永远不会起服务，不会留下一个空转的前台服务。
            "bgStart" -> {
                val title = (call.argument<String>("title") ?: "").trim()
                val ep = call.argument<Number>("ep")?.toInt() ?: 0
                setBackgroundMedia(
                    title,
                    ep,
                    call.argument<String>("line") ?: "",
                    call.argument<String>("cover") ?: "",
                    call.argument<Boolean>("hasPrev") ?: true,
                    call.argument<Boolean>("hasNext") ?: true,
                )
                requestNotificationPermissionIfNeeded()
                result.success(true)
            }
            "bgStop" -> {
                stopBackground()
                result.success(true)
            }
            // MEDIA_SESSION：通知 / 锁屏的封面提前暖到本地。
            //
            // 为什么要单独一个方法：MediaMetadata 的 artworkUri 在 prepare 之前
            // 就定死了，等通知要显示封面再去下载已经来不及（而且抢起播带宽）。
            // Dart 在进播放页 / 换集前调一次，开播时封面文件通常已经在了。
            "warmArtwork" -> {
                val cover = (call.argument<String>("url") ?: "").trim()
                if (cover.isNotEmpty()) {
                    PlaybackService.warmArtwork(
                        context,
                        cover,
                        call.argument<Map<String, String>>("headers") ?: emptyMap(),
                    )
                }
                result.success(true)
            }
            // 电池优化白名单：只在「设置」里由用户点，不发系统对话框骚扰。
            "bgBattery" -> result.success(requestIgnoreBatteryOptimizations())
            "bgBatteryIgnoring" -> result.success(isIgnoringBatteryOptimizations())
            // 一次性提示：上次后台播放被系统压过内存 → 这次启动提示一次。
            "bgConsumeHint" -> result.success(consumeInterruptHint())
            else -> result.notImplemented()
        }
    }

    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    private fun ensurePlayer() {
        if (player != null) return
        // LOAD_CONTROL（ALIGN_FONGMI 2026-11-15）。
        //
        // 壳的确切取值来自 FongMi 的 media3 fork（`FongMi/media` 分支 release，
        // `libraries/exoplayer/.../DefaultLoadControl.java`）：
        //   DEFAULT_MIN_BUFFER_MS              = 50_000
        //   DEFAULT_MAX_BUFFER_MS              = 50_000
        //   DEFAULT_BUFFER_FOR_PLAYBACK_MS     = 1_000
        //   DEFAULT_BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS = 2_000
        //   DEFAULT_BACK_BUFFER_DURATION_MS    = 0
        //   DEFAULT_PRIORITIZE_TIME_OVER_SIZE_THRESHOLDS = false
        // 而 `ExoUtil.buildLoadControl()` 只把 min/max 乘一个「缓冲档位」倍数
        // （`PlayerSetting.getBuffer()`，默认 1，范围 1~10），
        // bufferForPlayback / afterRebuffer 原样透传，优先级开关根本不碰。
        //
        // 所以我们按「档位 1」对齐：50s / 50s / 1s / 2s + backBuffer 0，
        // 并且**删掉** setPrioritizeTimeOverSizeThresholds(true) ——
        // 壳用的是默认 false（按字节阈值优先），我们之前那行是自己的发明。
        //
        // 和原来的 15s / 60s 比：min=max=50s 表示「一直往 50 秒灌」，
        // 不留 60s 那种「灌满就停、掉到 15s 才续」的空档，弱网下更不容易断粮。
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                50_000,   // minBufferMs
                50_000,   // maxBufferMs
                1_000,    // bufferForPlaybackMs
                2_000     // bufferForPlaybackAfterRebufferMs
            )
            .setBackBuffer(0, false)
            .build()
        // DECODER_FALLBACK（2026-11-14，用户报「声音出来了、画面还是黑屏卡缓冲」）：
        // 画面解不出来但音频正常，是视频轨硬解失败 —— 4K/HEVC 在某些机型上
        // MediaCodec 不支持或初始化失败，播放器不断重试，状态一直卡在
        // BUFFERING，Dart 侧就永远显示「缓冲中」。
        // 打开解码器回退后，硬解失败会自动切到软解，画面才能出来。
        //
        // 改动 ⑦：渲染器改由 [buildRenderers] 建 —— 解码失败重试时要把
        // 「优先软解」的 MediaCodecSelector 换进去，所以必须能重建。
        val renderers = buildRenderers()
        player = ExoPlayer.Builder(context, renderers)
            .setLoadControl(loadControl)
            .build()
        // ALIGN_EXO（2026-11-14，参考 FongMi/TV 的 ExoUtil.buildPlayer）：
        //   · setAudioAttributes(..., true)：申请音频焦点，来电/其它 App 播放时
        //     自动压低或暂停，而不是两边一起响
        //   · setHandleAudioBecomingNoisy(true)：拔耳机自动暂停
        // 这两条是各家播放器的默认行为，我们之前没设。
        player!!.setAudioAttributes(
            androidx.media3.common.AudioAttributes.DEFAULT,
            true
        )
        player!!.setHandleAudioBecomingNoisy(true)
        // 播放器可能晚于视图创建，这里补一次绑定
        videoView?.let { player!!.setVideoTextureView(it) }
        // 精确 seek 要从前一个关键帧开始解码，大分片 4K 上很慢；
        // 对齐到最近关键帧是各视频 App 的常规做法，拖动手感快很多。
        player!!.setSeekParameters(SeekParameters.CLOSEST_SYNC)
        bindListener(player!!)
        bindAnalytics(player!!)
        // PRELOADER（改动 ②）：线程池在这里随播放器一起建好 ——
        // 「预取随播放器创建即启动」，拿到源地址（open）后立刻开始灌分片，
        // 不等 prepare 完成、不等用户点播放。
        ensurePreloader()
        // MEDIA_SESSION：播放器实例（可能刚被重建）同步给 session。
        // 服务没跑时是个空调用；服务在跑但绑的还是上一台实例时这里换绑。
        PlaybackService.syncPlayer()
    }

    // ------------------------------------------- 渲染器 / 解码器降级（改动 ⑦）

    /**
     * 建渲染器工厂。
     *
     * [softDecoderPreferred] = false 时就是原来的行为（media3 自动选，硬解优先，
     * 硬解失败由 `setEnableDecoderFallback(true)` 自动回退）；
     * 置 true 后把 `MediaCodecSelector` 换成「软解（softwareOnly）排前面」——
     * 这是解码失败重试时唯一能真正改变解码路径的开关。
     */
    private fun buildRenderers(): androidx.media3.exoplayer.DefaultRenderersFactory {
        val factory = androidx.media3.exoplayer.DefaultRenderersFactory(context)
            .setEnableDecoderFallback(true)
        if (softDecoderPreferred) {
            factory.setMediaCodecSelector { mimeType, requiresSecureDecoder, requiresTunnelingDecoder ->
                val infos = androidx.media3.exoplayer.mediacodec.MediaCodecUtil.getDecoderInfos(
                    mimeType,
                    requiresSecureDecoder,
                    requiresTunnelingDecoder,
                )
                // 软解排前面；硬解仍在列表里（软解不支持时可回退）。
                infos.sortedBy { if (it.softwareOnly) 0 else 1 }
            }
        }
        return factory
    }

    /**
     * 重建 renderers 后再 prepare 一次（改动 ⑦ / ⑤ 第 2 次重试）。
     *
     * 只重建**播放器 + 渲染器**：磁盘缓存、预取器、画面视图（TextureView）
     * 全部保留 —— 换集本身（改动 ④）不重建实例，只有解码器这条死路才重建。
     */
    private fun rebuildRenderersAndReopen(item: OpenedItem) {
        val old = player
        val positionMs = lastKnownPositionMs.coerceAtLeast(0)
        // MEDIA_SESSION：这台播放器实例马上要被释放，session 必须先摘下来
        // （它强引用着 player）。重建之后 ensurePlayer → syncPlayer 会用一个
        // 绑到新实例的新 session 顶上，通知不会一直是死的。
        PlaybackService.releaseSessionNow()
        try { old?.stop() } catch (_: Throwable) {}
        try { old?.clearVideoSurface() } catch (_: Throwable) {}
        try { old?.release() } catch (_: Throwable) {}
        player = null
        // ensurePlayer 会用新的 softDecoderPreferred 重建渲染器，
        // 并把音频焦点 / seek 参数 / 监听器 / 纹理视图重新绑好。
        ensurePlayer()
        Log.i(
            LOG_TAG,
            "RENDERERS 重建 softFirst=$softDecoderPreferred pos=${positionMs}ms",
        )
        open(item.url, item.headers, item.isHls, positionMs, NoopResult, fromRetry = true)
    }

    // ------------------------------------------- 分级重试（改动 ⑤）

    /** HTTP / IO 类错误：地址可能过期、CDN 抖动、302 链路断。 */
    private fun isIoOrSourceError(error: PlaybackException): Boolean {
        // media3 的 errorCode 分段：1xxx 通用、2xxx IO、3xxx 解析、4xxx 解码。
        return error.errorCode in 2000..3999
    }

    /** 解码类错误：硬解初始化失败 / 解码失败。 */
    private fun isDecodeError(error: PlaybackException): Boolean {
        if (error.errorCode in 4000..4999) return true
        // 少数机型把解码失败报成 ERROR_CODE_UNSPECIFIED，用异常链兜一层。
        var cause: Throwable? = error.cause
        var depth = 0
        while (cause != null && depth < 4) {
            if (cause is android.media.MediaCodec.CodecException) return true
            cause = cause.cause
            depth++
        }
        return false
    }

    /**
     * 把一次播放错误归类成「真失败」码（SLOW_NET 2026-11-15）。
     *
     * 返回空串 = 不是真失败（可能只是网慢 / 抖动），交给重试与 Dart 的
     * 「有没有进展」判定；非空 = 这条线路真的不能播，Dart 立刻换下一条。
     *
     * 判定顺序刻意「先具体后笼统」：HTTP 状态码最硬（OkHttp / media3 都会
     * 带 `InvalidResponseCodeException`），其次是 DNS / 连接 / TLS 这三类
     * 传输层异常，最后才是错误码名（清单解析类）。
     */
    private fun classifyFatal(error: PlaybackException): String {
        val fatalStatus = setOf(401, 403, 404, 410, 500, 502, 503)
        var cause: Throwable? = error
        var depth = 0
        while (cause != null && depth < 6) {
            if (cause is HttpDataSource.InvalidResponseCodeException) {
                val code = cause.responseCode
                if (code in fatalStatus) return "http_$code"
            }
            val simple = cause.javaClass.simpleName
            val message = (cause.message ?: "").lowercase()
            if (cause is java.net.UnknownHostException ||
                message.contains("unable to resolve host") ||
                message.contains("no address associated") ||
                message.contains("name or service not known")
            ) {
                return "dns_error"
            }
            if (cause is java.net.ConnectException ||
                message.contains("connection refused") ||
                message.contains("failed to connect")
            ) {
                return "connect_refused"
            }
            if (cause is javax.net.ssl.SSLException || message.contains("handshake") ||
                message.contains("certificate")
            ) {
                return "tls_error"
            }
            if (simple.contains("UnrecognizedInputFormat") ||
                simple.contains("ParserException") || simple.contains("Malformed")
            ) {
                return "manifest_invalid"
            }
            if (simple.contains("HttpDataSource")) {
                val code = Regex("(?:invalid response code|response code):?\\s*(\\d{3})")
                    .find(message)?.groupValues?.getOrNull(1)?.toIntOrNull()
                if (code != null && code in fatalStatus) return "http_$code"
            }
            cause = cause.cause
            depth++
        }
        val name = error.errorCodeName
        return when {
            name.contains("PARSING_MANIFEST") ||
                name.contains("PARSING_CONTAINER") ||
                name == "ERROR_CODE_IO_INVALID_HTTP_CONTENT_TYPE" -> "manifest_invalid"
            else -> ""
        }
    }

    /**
     * 播放层分级重试（在 [Player.Listener.onPlayerError] 里调用）。
     *
     * 返回 true = 本次错误已经在原生侧吃掉重试，**不要**上报给 Dart
     * （否则救援链会立刻换线路，等于跳过了分级重试）；
     * 返回 false = 重试用完了，把错误交回 Dart 换线路。
     */
    private fun tryLayerRetry(error: PlaybackException): Boolean {
        val item = openedItem ?: return false
        if (retryCount >= MAX_LAYER_RETRIES) {
            Log.i(
                LOG_TAG,
                "retry=giveup 已重试 $retryCount 次，上报 Dart 换线路 code=${error.errorCodeName}",
            )
            return false
        }
        retryCount++
        // 出错前的位置：重开从这里接着播，别回到片头。
        val positionMs = (player?.currentPosition ?: 0L).coerceAtLeast(0L)
        if (positionMs > 0) lastKnownPositionMs = positionMs

        if (isDecodeError(error)) {
            // 第 2 档：解码错误 → 切解码模式（硬解 ↔ 软解）再 prepare。
            retryReason = "decode"
            softDecoderPreferred = !softDecoderPreferred
            Log.i(
                LOG_TAG,
                "retry=$retryCount reason=decode softFirst=$softDecoderPreferred " +
                    "code=${error.errorCodeName} pos=${positionMs}ms",
            )
            // 重开放到回调外执行：在 onPlayerError 里同步 release / prepare
            // 播放器会和 media3 内部的错误处理重入。
            mainHandler.post { rebuildRenderersAndReopen(item) }
            return true
        }

        // 第 1 档：IO / HTTP（含解析）→ 重新 resolve 播放地址再 prepare。
        // 原生拿不到 /api/play，所以先让 Dart 刷新地址（token +1），
        // 同时本地用原地址重开一次兜底：谁先回来都算恢复，
        // Dart 拿到新地址会再 open 覆盖这次（open 幂等、旧请求会被取代）。
        retryReason = "io"
        retryResolveToken++
        Log.i(
            LOG_TAG,
            "retry=$retryCount reason=io resolveToken=$retryResolveToken " +
                "kind=${if (isIoOrSourceError(error)) "source" else "other"} " +
                "code=${error.errorCodeName} pos=${positionMs}ms url=${item.url}",
        )
        mainHandler.post {
            open(item.url, item.headers, item.isHls, positionMs, NoopResult, fromRetry = true)
        }
        return true
    }

    /// 重试时复用的空 result：复用 [open] 全流程（含传输层数据源构造 /
    /// 缓存工厂 / MediaSource 构造），不重复实现一遍，也不用给 Dart 回包。
    private object NoopResult : MethodChannel.Result {
        override fun success(result: Any?) {}
        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}
        override fun notImplemented() {}
    }

    /// 建立（或复用）预取器与它共用的磁盘缓存。
    ///
    /// 缓存初始化失败时返回 null，预取和磁盘缓存一起退化成「不启用」，
    /// 播放本身不受影响 —— 这条兜底是之前踩过的坑：SimpleCache 初始化
    /// 抛的是 Error（NoClassDefFoundError）而不是 Exception。
    private fun ensurePreloader(): SegmentPreloader? {
        preloader?.let { return it }
        val cache = ensureMediaCache() ?: return null
        val created = SegmentPreloader(
            context = context,
            cache = cache,
            log = { message -> android.util.Log.d("FxExo", message) },
            // PRIORITY（ALIGN_FONGMI）：播放器处于 BUFFERING 时预取让路。
            //
            // 壳用 media3 的 `PriorityTaskManager`（ExoDiskPreload 里
            // `player.setPriorityTaskManager(priorityTaskManager)`）保证
            // 「播放的请求永远先于预载的请求」。我们这边单线程预取，
            // 用一条「播放器在缓冲就暂停」的判据达到同样效果：播放器缺数据时
            // 预取线程不占连接、不占带宽，缓冲结束再接着灌。
            pauseGate = { playerBuffering },
        )
        preloader = created
        return created
    }

    /**
     * 把「是否正在缓冲」同步到 [playerBuffering]（**只在主线程调用**）。
     *
     * 后台预取线程绝不直接读播放器：media3 的 ExoPlayer 有线程亲和性检查，
     * 跨线程读 `playbackState` 会抛 IllegalStateException 并把进程干掉
     * （CRASH_FIX：原来就是这么闪退的）。读一次、缓存进 volatile 字段，
     * 后台只读字段。
     */
    private fun refreshBufferingFlag(p: ExoPlayer? = player) {
        playerBuffering = p == null || p.playbackState == Player.STATE_BUFFERING
    }

    /// 首帧之后才真正开灌（PRELOAD_AFTER_FIRST_FRAME）。
    ///
    /// 幂等：`open` 之后可能多次触发（首帧、seek、重开），只有还挂着请求时才动。
    private fun startPendingPreload() {
        val request = pendingPreload ?: return
        pendingPreload = null
        if (!firstFrameRendered) return
        ensurePreloader()?.start(request.url, request.headers, request.startPositionMs)
    }

    private fun ensureMediaCache(): SimpleCache? {
        mediaCache?.let { return it }
        return try {
            val dir = File(context.cacheDir, "exo_media_cache")
            if (!dir.exists()) dir.mkdirs()
            val created = SimpleCache(
                dir,
                // LRU：缓存满 1.5GiB 就淘汰最久未用的分片。
                LeastRecentlyUsedCacheEvictor(CACHE_MAX_BYTES),
                StandaloneDatabaseProvider(context)
            )
            mediaCache = created
            created
        } catch (error: Throwable) {
            android.util.Log.w("FxExo", "磁盘缓存不可用，退化为直连: ${error.javaClass.simpleName}")
            null
        }
    }

    // ------------------------------------------------ seek 音频闸（改动 ③）

    /// 拖动瞬间闸掉音量。仅在正在播时生效 —— 暂停状态拖动没有音画撕裂，
    /// 动音量会让用户下次播放「没声音」。
    private fun beginSeekAudioGate() {
        val p = player ?: return
        if (seekGateActive) return
        if (!p.isPlaying) return
        seekGateActive = true
        volumeBeforeSeekGate = p.volume
        p.volume = 0f
        mainHandler.removeCallbacks(seekGateTimeout)
        mainHandler.postDelayed(seekGateTimeout, SEEK_AUDIO_GATE_TIMEOUT_MS)
    }

    /// 首帧回来 / 超时兜底：恢复拖动前的音量（幂等）。
    private fun endSeekAudioGate() {
        mainHandler.removeCallbacks(seekGateTimeout)
        if (!seekGateActive) return
        seekGateActive = false
        player?.volume = volumeBeforeSeekGate
    }

    /**
     * 播放诊断用的分析器（DIAGNOSTICS 2026-11-15）。
     *
     * 只**读**播放器状态，不改变任何播放行为：
     *   · 丢帧数 → 区分「网慢」和「解码跟不上」；
     *   · 播放器自己那次清单加载的耗时 → 和代理的 manifest_merged 对比；
     *   · 音频轨真正起来的时刻 → 打 `audio_started` 计时点
     *     （有些片子首帧和声音不是一起到的）。
     */
    private fun bindAnalytics(p: ExoPlayer) {
        p.addAnalyticsListener(object : AnalyticsListener {
            override fun onDroppedVideoFrames(
                eventTime: AnalyticsListener.EventTime,
                droppedFrames: Int,
                elapsedMs: Long,
            ) {
                if (droppedFrames > 0) droppedFrameCount += droppedFrames
            }

            override fun onLoadCompleted(
                eventTime: AnalyticsListener.EventTime,
                loadEventInfo: LoadEventInfo,
                mediaLoadData: MediaLoadData,
            ) {
                if (mediaLoadData.dataType != C.DATA_TYPE_MANIFEST) return
                if (playerManifestLoadMs >= 0) return
                playerManifestLoadMs = loadEventInfo.loadDurationMs
                FxTiming.mark("manifest_loaded")
                Log.i(
                    LOG_TAG,
                    "MANIFEST_LOADED ${loadEventInfo.loadDurationMs}ms（播放器侧清单加载完成）",
                )
            }

            // NET_SPEED（2026-11-15）：media3 自己测出来的带宽（bit/s）。
            // 只当 [FxNet] 的兜底：某一窗口一个字节都没数到、但播放器仍在
            // 下载时用它，比界面挂着 0 更接近真实。
            override fun onBandwidthEstimate(
                eventTime: AnalyticsListener.EventTime,
                elapsedMs: Int,
                bytes: Long,
                bitrateEstimate: Long,
            ) {
                FxNet.onBandwidthEstimate(bitrateEstimate)
            }

            override fun onAudioInputFormatChanged(
                eventTime: AnalyticsListener.EventTime,
                format: androidx.media3.common.Format,
                decoderReuseEvaluation: androidx.media3.exoplayer.DecoderReuseEvaluation?,
            ) {
                // 音频轨配置完成 = 用户第一次听到声音的时刻。
                FxTiming.mark("audio_started")
            }
        })
    }

    private fun bindListener(p: ExoPlayer) {
        p.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                // CRASH_GUARD2（2026-11-15）：media3 的 listener 都在主线程回调，
                // 这里抛异常就是 FATAL EXCEPTION: main —— 直接闪退。
                // 状态回调里的动作（收音频闸 / 停后台服务 / 发快照）全是「尽力而为」，
                // 失败只记日志，不影响播放。
                try {
                // 拖动后播到结尾 / 被停掉：闸必须收掉，否则会一直静音。
                if (state == Player.STATE_IDLE || state == Player.STATE_ENDED) {
                    endSeekAudioGate()
                }
                // BG_SERVICE：播到结尾就收服务（此时进程没有理由留在后台）。
                // STATE_IDLE 不收：换集 / 换线路会先 stop 再 prepare，收掉会让
                // 新一集的保活晚一拍（下一帧 onIsPlayingChanged 又会把它拉起来）。
                if (state == Player.STATE_ENDED) stopBackground()
                // CRASH_FIX：缓冲状态只在主线程读，写进 volatile 给预取线程看。
                playerBuffering = state == Player.STATE_BUFFERING
                emit()
                } catch (error: Throwable) {
                    Log.e(LOG_TAG, "listener state 异常 ${error.javaClass.simpleName}", error)
                }
            }
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                // CRASH_GUARD2：起前台服务的 API 在 Android 12+ 会抛
                // ForegroundServiceStartNotAllowedException / SecurityException
                // （没有通知权限），主线程上一抛就是闪退。播放本身不受影响 ——
                // 后台保活失败只意味着"切到后台可能被系统回收"，不是播放失败。
                try {
                    // BG_SERVICE：第一次真的出声才算「在播放」→ 起前台服务；
                    // 之后每次状态变化只刷新通知（暂停 / 继续的按钮文案）。
                    // BG_GATE：这条路径可能发生在后台（从通知栏 / 耳机恢复播放），
                    // 必须先确认 App 在前台，否则 Android 12+ 不许起前台服务。
                    if (isPlaying) startBackground(requireForeground = true)
                    else PlaybackService.sync()
                    emit()
                } catch (error: Throwable) {
                    Log.e(LOG_TAG, "listener playing 异常 ${error.javaClass.simpleName}", error)
                }
            }
            override fun onRenderedFirstFrame() {
                // CRASH_GUARD2：首帧回调里既有预取（磁盘 / 网络）也有统计，
                // 任何一步抛异常都会把进程带走；首帧标记本身必须置上。
                firstFrameRendered = true
                try {
                // FIRST_FRAME：只有这里才把首帧标记置 true。
                // Dart 的加载层就是靠它收起的，别再拿 buffering / playing 猜。
                firstFrameRendered = true
                // RETRY（改动 ⑤）：重试成功（重新出帧）= 这一轮恢复正常，
                // 把重试预算还回去。否则一次偶发错误之后，这一集的后续错误
                // 会直接被判死交给 Dart 换线路。
                if (retryCount > 0) {
                    Log.i(LOG_TAG, "retry=recovered 首帧恢复，重试预算归零")
                    retryCount = 0
                    retryReason = ""
                }
                Log.i(LOG_TAG, "FIRST_FRAME 已渲染，pos=${player?.currentPosition}ms")
                // TIMING_PROBE：拖动出画面（目标 ≤500ms）。和起播分开记，
                // 免得一次拖动把起播时间线搅乱。
                if (seekStartedNanos > 0L) {
                    val out = (System.nanoTime() - seekStartedNanos) / 1_000_000L
                    seekStartedNanos = 0L
                    lastSeekOutMs = out
                    Log.i(LOG_TAG, "t=${FxTiming.elapsedMs()}ms seek_first_frame out=${out}ms")
                }
                // TIMING_PROBE：首帧 = 用户真正「看到画面」的时刻，起播计时到这里收尾。
                FxTiming.mark("first_frame")
                // CONNECTS（TRANSPORT_OKHTTP，2026-11-15）：起播这一段一共建了
                // 几条连接（EventListener.connectStart 计数）。同一个源、同一个
                // 连接池，改造后应该是 1 —— 清单一条，variant 和后面的分片全部
                // 复用；改造前每次 302 换域都要重新 TCP + TLS，这个数会往上爬。
                Log.i(LOG_TAG, "connects=${PlayerHttp.connectCount()}（起播连接建立次数）")
                FxTiming.finish(PlayerHttp.connectCount())
                // 首帧到了：拖动闸放开（对方确证的结束条件之一）。
                endSeekAudioGate()
                // PRELOAD_AFTER_FIRST_FRAME（ALIGN_FONGMI）：首帧上屏之后
                // 才开始往后预取 —— 起播那一片只留给播放器，不和它抢。
                startPendingPreload()
                emit()
                } catch (error: Throwable) {
                    Log.e(LOG_TAG, "listener first_frame 异常 ${error.javaClass.simpleName}", error)
                }
            }
            override fun onPlayerError(error: PlaybackException) {
                // CRASH_GUARD2：错误回调是最容易被死线路触发的一条路径
                // （404 清单 / 空 variant / 非法地址）。这里抛异常 = 闪退，
                // 而用户只是选了一条坏线路 —— 必须降级成"这条线路失败"。
                try {
                lastError = error.errorCodeName + ": " + (error.message ?: "")
                endSeekAudioGate()
                // SLOW_NET（2026-11-15，用户口径）：先判「真失败」。
                // 401/403/404/410/500/502/503、DNS 不通、连接被拒、TLS 失败、
                // 清单非法、0 分片 —— 这些重试没有任何意义，直接给 Dart 一个
                // fatalError 码，让它**立刻**换下一条，不等 8 秒窗口。
                val fatal = classifyFatal(error)
                if (fatal.isNotEmpty() && fatal != reportedFatalCode) {
                    fatalErrorCode = fatal
                    reportedFatalCode = fatal
                    Log.i(
                        LOG_TAG,
                        "fatal=$fatal code=${error.errorCodeName} → 直接换线路 " +
                            "(不重试) url=${openedItem?.url ?: "-"}",
                    )
                    emit()
                    return
                }
                // LAYERED_RETRY（改动 ⑤）：同一集同一线路最多在原生侧重试 2 次
                // （IO → 重新 resolve 地址；解码 → 切解码模式）。
                //
                // 重试期间**不**把错误写进快照：Dart 侧看到 error 就进救援链
                // 换线路，那等于跳过了分级重试。
                if (tryLayerRetry(error)) {
                    lastError = null
                    emit()
                    return
                }
                // 两次都失败：把错误交回 Dart，由救援链换线路。
                emit()
                } catch (nested: Throwable) {
                    Log.e(LOG_TAG, "listener error 异常 ${nested.javaClass.simpleName}", nested)
                    try {
                        emit()
                    } catch (_: Throwable) {
                        // 连 emit 都失败：播放器已经不可用，Dart 侧看门狗会兜底。
                    }
                }
            }
        })
    }

    private fun snapshot(): Map<String, Any?> {
        val p = player ?: run {
            playerBuffering = true
            return mapOf(
            "positionMs" to 0, "durationMs" to 0, "bufferedMs" to 0,
            "preloadedMs" to 0L,
            "playing" to false, "buffering" to true, "error" to null,
            "firstFrameRendered" to false,
            "width" to 0, "height" to 0, "ended" to false, "state" to 1,
            // RETRY（改动 ⑤）：Dart 侧用这几个字段区分「原生在重试」和
            // 「真的失败了」，以及是否该去重新 resolve 播放地址。
            "retryAttempt" to retryCount,
            "retryReason" to retryReason,
            "retryResolveToken" to retryResolveToken,
            // MEDIA_SESSION：通知栏 / 锁屏 / 耳机线控的上一集下一集
            // （bgStepSeq 变化 = 用户按了，bgStepDelta 是方向）。
            "bgStepSeq" to bgStepSeq,
            "bgStepDelta" to bgStepDelta,
            "connectCount" to 0,
            "bufferedAheadMs" to 0L,
            "droppedFrames" to 0L,
            "bitrateKbps" to 0,
            "measuredKbps" to 0,
            "playerManifestMs" to -1L,
            "manifestProxied" to false,
            "timing" to FxTiming.summary(),
            "transportInfo" to "",
            // IQ_CODEC：没有播放器时编码信息一律空，界面显示 "--"。
            "videoCodec" to "",
            "iqCodec" to IqProbe.codec,
            "iqQuality" to IqProbe.quality,
            // SLOW_NET：没有播放器 = 一个字节都没收到。
            "bytesLoaded" to FxNet.totalBytes(),
            "bytesLoadedPerSec" to 0,
            "isLoading" to true,
            "fatalError" to fatalErrorCode,
            )
        }
        // 画面尺寸：FxPlayer 的 value.width/height 和分辨率胶囊都靠它，
        // 拿不到就一直显示 "0x0"。format 在 READY 之后才有值。
        val buffering = p.playbackState == Player.STATE_BUFFERING
        playerBuffering = buffering
        val fmt = p.videoFormat
        val rotation = fmt?.rotationDegrees ?: 0
        var w = fmt?.width ?: 0
        var h = fmt?.height ?: 0
        if (rotation == 90 || rotation == 270) {
            val t = w; w = h; h = t
        }
        // RETRY（改动 ⑤）：顺便记下最后已知位置 —— 出错时用它重开，
        // 不能回到片头（重开一次等于整集重新起播）。
        if (p.playbackState != Player.STATE_IDLE && p.currentPosition > 0) {
            lastKnownPositionMs = p.currentPosition
        }
        return mapOf(
            "positionMs" to p.currentPosition,
            "durationMs" to p.duration.coerceAtLeast(0),
            "bufferedMs" to p.bufferedPosition,
            // 磁盘预取估算（改动 ②）：从当前分片往后连续已落盘的时长。
            // Dart 侧 buffered 取 max(Exo buffered, 这个值) —— 用户看到的
            // 灰条就是「已经下到磁盘的段」，拖动条观感才是「大半条灰」。
            "preloadedMs" to (preloader?.continuousCachedMs(p.currentPosition) ?: 0L),
            "playing" to p.isPlaying,
            // 同一次主线程读，顺手把后台预取线程要看的快照刷新（CRASH_FIX）。
            "buffering" to buffering,
            // FIRST_FRAME：Dart 加载层只认这一个字段（open / seek 会重置）。
            "firstFrameRendered" to firstFrameRendered,
            "error" to lastError,
            "width" to w,
            "height" to h,
            "ended" to (p.playbackState == Player.STATE_ENDED),
            "state" to p.playbackState,
            // RETRY（改动 ⑤）：原生分层重试进度。retryAttempt=0 表示这次
            // 打开还没重试过；retryResolveToken 变化 = 请 Dart 重新 resolve
            // 播放地址（地址过期这条只有 Dart 能修）。
            "retryAttempt" to retryCount,
            "retryReason" to retryReason,
            "retryResolveToken" to retryResolveToken,
            // MEDIA_SESSION：通知栏 / 锁屏 / 耳机线控的上一集下一集
            // （bgStepSeq 变化 = 用户按了，bgStepDelta 是方向）。
            "bgStepSeq" to bgStepSeq,
            "bgStepDelta" to bgStepDelta,
            // DIAGNOSTICS（2026-11-15）：播放诊断浮层的全部数据来源。
            // 都是「这一段（本次 open）」的统计，换源会归零。
            "connectCount" to PlayerHttp.connectCount(),
            "bufferedAheadMs" to (p.bufferedPosition - p.currentPosition).coerceAtLeast(0L),
            "droppedFrames" to droppedFrameCount,
            // Format.bitrate 单位 bit/s，未声明时是 C.RATE_UNSET_INT（-1）。
            "bitrateKbps" to ((fmt?.bitrate ?: -1) / 1000).coerceAtLeast(0),
            "measuredKbps" to PlayerHttp.measuredKbps(),
            "playerManifestMs" to playerManifestLoadMs,
            "manifestProxied" to manifestProxied,
            // 拖动响应：上一次 seek → 出画面（≤500ms 是目标）。
            "seekOutMs" to lastSeekOutMs,
            // TIMING_PROBE：分段耗时（相对「用户点播放」）。
            "timing" to FxTiming.summary(),
            // 传输层诊断摘要：DNS 命中 / 本地清单代理统计，方便用户截图反馈。
            "transportInfo" to (FxDns.stats() + " " + ManifestProxy.stats()),
            // IQ_CODEC（2026-11-15）：诊断浮层「编码」行的数据源。
            //   videoCodec：内核解出来的轨道编码（最可信）；
            //   iqCodec / iqQuality：爱奇艺解析服务的响应头
            //   `X-Iq-Codec` / `X-Iq-Quality`（清单抓取时顺手记下）。
            "videoCodec" to codecNameOf(fmt?.sampleMimeType),
            "iqCodec" to IqProbe.codec,
            "iqQuality" to IqProbe.quality,
            // SLOW_NET（2026-11-15）：界面「实时网速」和「慢网 / 卡死」判定
            // 的全部数据来源。
            //   bytesLoaded        本次 open 累计收到的正文字节（按块累加，
            //                      慢网下也是一直在涨的）
            //   bytesLoadedPerSec  滚动 1 秒窗口的真实速率（B/s），口径见
            //                      [FxNet]：media3 数据源按块回调 + 官方带宽估算兜底
            //   isLoading          正在缓冲**且**用户没按暂停
            "bytesLoaded" to FxNet.totalBytes(),
            "bytesLoadedPerSec" to FxNet.speedPerSec(),
            "isLoading" to (buffering && p.playWhenReady),
            "fatalError" to fatalErrorCode,
        )
    }

    private fun emit() {
        events?.success(snapshot())
    }

    private fun open(
        url: String,
        headers: Map<String, String>,
        isHls: Boolean,
        startPositionMs: Long,
        result: MethodChannel.Result,
        /// true = 这次 open 来自原生分级重试（改动 ⑤）：不取消下一集预载、
        /// 也不重置重试计数，其余流程与用户触发的 open 完全一致。
        fromRetry: Boolean = false,
        /// Dart 侧解析播放地址的耗时（TIMING_PROBE，2026-11-15）。
        resolveMs: Long = 0L,
    ) {
        ensurePlayer()
        lastError = null
        // SLOW_NET：新的一次 open = 新的失败现场，别把上一条线路的
        // 真失败码带过来（否则一开播就被判死）。
        fatalErrorCode = ""
        reportedFatalCode = ""
        // TIMING_PROBE：开一条新时间线。t=0 = 用户点播放（含 Dart 解析段）。
        FxTiming.begin(url, resolveMs)
        // CONNECTS：清零连接计数 / 吞吐统计，首帧回来时打 connects=N。
        PlayerHttp.resetConnectCount()
        // NET_SPEED：新的一次 open = 新的网速窗口，上一集的速率不能留在界面上。
        FxNet.reset()
        // IQ_CODEC：新的一次 open = 新的一条码流，上一集的编码 / 分辨率
        // 不能留在诊断浮层上（否则降级之后那一行还写着上一集的 HEVC，
        // 看上去像「降级没生效」）。
        IqProbe.reset()
        // 播放诊断里「解析」段的落点：Dart 侧已经算好，这里只记日志。
        if (resolveMs > 0) {
            Log.i(LOG_TAG, "TIMING resolve=${resolveMs}ms（hxparse 302 → 最终地址）")
        }
        val generation = ++openGeneration
        if (!isHls || !PlayerHttp.isHttpUrl(url)) {
            // 本地文件 / 非 HLS：没有清单可归并，直接开。
            manifestProxied = false
            logTransport(url, url, headers, "raw")
            startPlayback(url, url, headers, isHls, startPositionMs, result, fromRetry = fromRetry)
            return
        }
        // MANIFEST_PROXY（2026-11-15）：**起播前置动作清零**。
        //
        // 旧路径是「先在 FxManifest 线程上把 master 抓回来（最多 800ms），
        // 拿到 variant 再 prepare」—— 用户在起播最前面白等一段串行网络。
        // 现在交给本地清单代理：proxyUrl() 只绑端口 + 建会话（微秒级），
        // 清单在代理自己的线程里抓，播放器随后 GET 127.0.0.1 就能命中。
        // 抓不到时代理回 302 到原始地址，播放行为与改造前完全一致。
        val proxied = ManifestProxy.proxyUrl(url, headers)
        if (proxied.isNotEmpty() && PlayerHttp.isPlayableUrl(proxied)) {
            manifestProxied = true
            ManifestProxy.prefetch(url, headers)
            logTransport(url, proxied, headers, "proxy")
            startPlayback(
                proxied,
                url,
                headers,
                isHls,
                startPositionMs,
                result,
                fromRetry = fromRetry,
                // 请求头按上游地址推导：Referer 不能变成 127.0.0.1。
                headerUrl = url,
            )
            return
        }
        manifestProxied = false
        try {
            manifestQueue.execute {
                // 归并对调用方的承诺是「不抛异常、永远返回地址」；这里再兜一层，
                // 万一真漏出来，也不能让这条线程静默死掉 —— 那会让 result 永远
                // 不回话，Dart 的 open Future 挂死、UI 一直转圈。
                val merged = try {
                    PlayerHttp.mergeMasterPlaylist(url, headers) { message ->
                        Log.i(LOG_TAG, message)
                    }
                } catch (error: Throwable) {
                    Log.w(LOG_TAG, "清单预归并异常 ${error.javaClass.simpleName}，用原始地址")
                    url
                }
                // TIMING_PROBE：清单就绪（这条是代理不可用时的兜底路径）。
                FxTiming.mark("manifest_merged")
                mainHandler.post {
                    if (generation != openGeneration) {
                        // 期间已经开了别的地址（换线路 / 换集）：这次结果作废。
                        // 但必须给 Dart 回话，否则那个 Future 永远挂着。
                        Log.i(LOG_TAG, "OPEN 作废（已被新的 open 取代）$url")
                        result.success(true)
                        return@post
                    }
                    logTransport(url, merged, headers, if (merged == url) "raw" else "merged")
                    startPlayback(merged, url, headers, isHls, startPositionMs, result, fromRetry = fromRetry)
                }
            }
        } catch (error: Throwable) {
            // 归并线程不可用（极罕见）：退化成不归并，照常播。
            Log.w(LOG_TAG, "清单预归并线程不可用 ${error.javaClass.simpleName}")
            logTransport(url, url, headers, "raw")
            startPlayback(url, url, headers, isHls, startPositionMs, result, fromRetry = fromRetry)
        }
    }

    /**
     * 传输层日志（真机核对用）：`transport=okhttp ua=... manifesto=merged|raw`。
     *
     * 三个字段分别对应三条改动：传输层是 OkHttp、发出去的 UA 是什么、
     * 清单有没有归并（merged = 已经换成 variant，raw = 原样）。
     */
    private fun logTransport(
        requestedUrl: String,
        playUrl: String,
        headers: Map<String, String>,
        manifesto: String,
    ) {
        val target = if (playUrl == requestedUrl) requestedUrl else "$requestedUrl -> $playUrl"
        Log.i(
            LOG_TAG,
            "transport=okhttp ua=${PlayerHttp.userAgent(headers)} manifesto=$manifesto" +
                " url=$target",
        )
        // PLAY_LOG（2026-11-15）：Dart 侧那条 `[FxPlay] open …` 到这儿接上。
        // 真机排查只要 `adb logcat -s FxPlay` 一条命令，就能同时看到
        // 「Dart 判的 source/kind」和「原生最终交给 ExoPlayer 的地址
        // 以及清单是 raw / merged / proxy 哪一路」，不用再翻两个 tag 对时间。
        Log.i(
            "FxPlay",
            "native open manifesto=$manifesto url=$target",
        )
    }

    /**
     * 真正开播（原 open 的函数体，传输层换成 OkHttp）。
     *
     * [playUrl] 是交给播放器的最终地址（可能是归并后的 variant），
     * [requestedUrl] 是 Dart 给的原地址 —— 重试计数与原生重开都按原地址算，
     * 免得「这次归并成功、下次超时」把同一线路的重试次数莫名清零。
     */
    /**
     * 真正开播的**入口**（CRASH_GUARD2 2026-11-15）。
     *
     * 为什么需要这一层：`onMethodCall` 里的 CRASH_GUARD 只兜住「通道调用当场」，
     * 而 open 有两个分支是**延迟**才执行 `startPlayback` 的 ——
     *   · 清单预归并线程跑完后 `mainHandler.post { startPlayback(...) }`
     *   · 分级重试里 `mainHandler.post { rebuildRenderersAndReopen(...) }`
     * 这两条都在主线程上、且不在任何 try 里。它们一旦抛异常，用户看到的就是
     * `FATAL EXCEPTION: main` → **App 直接退出**（不是提示失败）。
     *
     * 死线路（幻想蓝光 FY-PAN1 / mgtv）正好会走到这条路上：404 的清单、
     * 空的 variant 列表、空地址，都会让 media3 侧抛 IllegalArgumentException /
     * IllegalStateException。所以这里做两件事：
     *   1. 地址不合法就地拒绝，绝不把空 Uri 交给 MediaItem.Builder；
     *   2. 整个开播过程兜住 Throwable —— 失败只回一句可读的 error，
     *      由 Dart 侧按「这条线路失败」处理（换线路 / 提示），**绝不带走进程**。
     */
    private fun startPlayback(
        playUrl: String,
        requestedUrl: String,
        headers: Map<String, String>,
        isHls: Boolean,
        startPositionMs: Long,
        result: MethodChannel.Result,
        fromRetry: Boolean = false,
        headerUrl: String = playUrl,
    ) {
        val target = playUrl.trim()
        if (target.isEmpty()) {
            Log.e(LOG_TAG, "OPEN 拒绝空地址（requested=$requestedUrl）")
            replyError(result, "bad_url", "这一集没有播放地址，换一条线路试试")
            return
        }
        if (!PlayerHttp.isPlayableUrl(target)) {
            Log.e(LOG_TAG, "OPEN 拒绝非法地址 $target")
            replyError(result, "bad_url", "播放地址不合法，换一条线路试试")
            return
        }
        try {
            startPlaybackUnsafe(
                target,
                requestedUrl,
                headers,
                isHls,
                startPositionMs,
                result,
                fromRetry = fromRetry,
                headerUrl = headerUrl,
            )
        } catch (error: Throwable) {
            Log.e(
                LOG_TAG,
                "OPEN 开播异常 ${error.javaClass.simpleName}: ${error.message} url=$target",
                error,
            )
            lastError = error.javaClass.simpleName + ": " + (error.message ?: "")
            replyError(result, "open_failed", "播放器打不开这一集，换一条线路试试")
            emit()
        }
    }

    /** 回一句话给 Dart；已经回过话（重复 reply）时忽略，别让 Guard 自己抛。 */
    private fun replyError(result: MethodChannel.Result, code: String, message: String) {
        try {
            result.error(code, message, null)
        } catch (_: Throwable) {
            // 重复 reply：调用方已经拿到结果了，这里没有补救动作。
        }
    }

    /** 原来的 startPlayback 函数体（不做入参校验，只由 [startPlayback] 调用）。 */
    private fun startPlaybackUnsafe(
        playUrl: String,
        requestedUrl: String,
        headers: Map<String, String>,
        isHls: Boolean,
        startPositionMs: Long,
        result: MethodChannel.Result,
        /// true = 这次 open 来自原生分级重试（改动 ⑤）：不取消下一集预载、
        /// 也不重置重试计数，其余流程与用户触发的 open 完全一致。
        fromRetry: Boolean = false,
        /// 请求头按哪个地址推导（Referer 取该站点根）。
        ///
        /// MANIFEST_PROXY：走本地清单代理时，交给播放器的是
        /// `127.0.0.1:PORT/m3u8?…`，但 Referer **必须**还是上游站点的 ——
        /// 否则带防盗链的源直接 403。所以这里单独一个参数。
        headerUrl: String = playUrl,
    ) {
        ensurePlayer()
        lastError = null
        // RETRY（改动 ⑤）：同一个地址（同一集同一线路）才累计重试次数；
        // 换集 / 换线路换了地址就重新计数。
        val retryAddressKey = "$requestedUrl|$isHls"
        if (retryAddressKey != retryKey) {
            retryKey = retryAddressKey
            retryCount = 0
            retryReason = ""
            // 换集 / 换线路：上一轮「下一集预载」整轮作废（改动 ⑥）。
            if (!fromRetry) {
                nextPreloader?.cancel()
                nextPreloadUrl = ""
            }
        }
        // 只有网络源才需要重试（本地文件没有地址过期这回事）。
        val retryIsLocal = !requestedUrl.startsWith("http://") && !requestedUrl.startsWith("https://")
        openedItem = if (retryIsLocal) null else OpenedItem(requestedUrl, headers, isHls)
        lastKnownPositionMs = startPositionMs.coerceAtLeast(0)
        try {
            // TRANSPORT_OKHTTP（2026-11-15）：数据源换成 OkHttp。
            //
            // 这里只新建 factory（无状态），**client 是全局唯一的**
            // （[PlayerHttp.client]）—— 连接池因此跨所有 open、所有分片复用。
            // 以前每次 open 都 `DefaultHttpDataSource.Factory()`，等于每次把
            // HttpURLConnection 的连接池扔掉：302 换一次域就重新 TCP + TLS，
            // 移动网 100~600ms，这是起播慢的主要来源。
            //
            // 也不再有 setAllowCrossProtocolRedirects / setConnectTimeoutMs /
            // setReadTimeoutMs —— 这三项在 OkHttp 里都是 client 级配置。
            val httpFactory = PlayerHttp.httpFactory(playUrl, headers, headerUrl)

            // 本地文件（离线播放页）走 DefaultDataSource：它能识别 file:// 和
            // 绝对路径，直接套 HttpDataSource 会失败。
            val isLocal = !playUrl.startsWith("http://") && !playUrl.startsWith("https://")
            val dataSource = if (isLocal) {
                DefaultDataSource.Factory(context)
            } else {
                DefaultDataSource.Factory(context, httpFactory)
            }
            // SHARED_CACHE（改动 ②）：播放器和预取器共用同一份 SimpleCache，
            // 所以预取过的分片，播放器读的时候就是缓存命中，不产生网络等待。
            // 缓存初始化失败 / 本地文件 / 非 HLS 时退回纯直连。
            //
            // PLAYBACK_NO_WRITE（ALIGN_FONGMI 2026-11-15）：播放路径**只读**缓存，
            // 不写盘。壳的写法是
            // `new CacheDataSource.Factory().setCache(...).setUpstreamDataSourceFactory(...)
            //  .setCacheWriteDataSinkFactory(null)` —— 播放时读缓存、miss 就直连回源，
            // 落盘交给预载线程（DiskPreloadManager）去做。
            // 我们之前播放器自己也写缓存：每个没命中缓存的分片都要在**读线程**上
            // 追加一次磁盘写（SimpleCache 还要抢 span 锁），而预取线程同时在写
            // 同一片 —— 首屏这一片等于被写盘和锁拖了一道。
            val cachedFactory = if (isLocal || !isHls) {
                dataSource
            } else {
                cacheDataSourceFactory(dataSource, writeToCache = false)
            }
            // MEDIA_SESSION（2026-11-15）：MediaItem 带着**通知 / 锁屏要显示的
            // 全部元数据**一起交给播放器。
            //
            // 为什么必须在这里挂：系统卡片读的 `player.getMediaMetadata()` 就是
            // 当前 MediaItem 的 metadata。prepare 之后再去改只能 replace 掉整个
            // MediaSource（等于重新起播），所以「片名 / 第N集 · 线路名 / 封面」
            // 必须在建 source 这一刻就定下来。换集 = 新的 open = 新的 MediaItem，
            // 元数据自然跟着集数一起变（封面不变时 artworkUri 指向同一个文件）。
            val itemBuilder = MediaItem.Builder().setUri(playUrl)
            if (bgTitle.isNotEmpty()) {
                itemBuilder.setMediaMetadata(
                    PlaybackService.buildMetadata(
                        bgTitle,
                        bgEpisode,
                        bgLine,
                        PlaybackService.artworkUriFor(context, bgCover, headers),
                    )
                )
            }
            val item = itemBuilder.build()
            // ALIGN_FONGMI：不挂自定义 LoadErrorHandlingPolicy（壳是空实现，
            // 跑 media3 默认：3 次重试 + 0/1s/2s 退避），死地址交给
            // onPlayerError → Dart 救援链。
            val source: MediaSource = if (isHls) {
                HlsMediaSource.Factory(cachedFactory).createMediaSource(item)
            } else {
                ProgressiveMediaSource.Factory(cachedFactory).createMediaSource(item)
            }
            // CONNECTS（TRANSPORT_OKHTTP，2026-11-15）：清零连接计数，然后按
            // 壳的 switchEpisode 同款序列换源。首帧回来时打 connects=N ——
            // 改造后起播应该只有 1 条（清单那条），分片和 variant 全部复用。
            PlayerHttp.resetConnectCount()
            // NET_SPEED：换源 = 重新开始算网速（否则界面上是上一条线路的数）。
            FxNet.reset()
            // SWITCH_INSTANCE_REUSE（改动 ④）：换集 / 换线路**不重建播放器**，
            // 也不解绑渲染器和纹理视图 —— 只按壳的 switchEpisode 同款序列
            // 换源。细节见 [switchToSource]。
            switchToSource(source, startPositionMs, playWhenReady = fromRetry)
            // TIMING_PROBE：prepare 已经下发给播放器（这一刻起等首帧）。
            FxTiming.mark("prepare_called")
            // RESUME（2026-11-14）：真机 logcat -s FxExo 核对续播是否真的带上了。
            // 「首个分片索引 N」由 SegmentPreloader.start 打出，两条一起看。
            Log.i(
                LOG_TAG,
                "RESUME 起始位置 ${startPositionMs}ms（prepare 前 seek）；" +
                    "isHls=$isHls url=$playUrl（原始 $requestedUrl）",
            )
            // PRELOAD_AFTER_FIRST_FRAME（ALIGN_FONGMI 2026-11-15）：
            // **不再在 open 时立刻开灌分片**，只把请求记下来，等首帧渲染出来
            // 再交给 [SegmentPreloader]。
            //
            // 壳的做法就是这个：它的 media3 `DiskPreloadManager` 只服务
            // 「预载下一集」，当前这一集的取流完全交给播放器自己；要预载时
            // 也是把 `PriorityTaskManager` 挂到 player 上，播放永远优先。
            //
            // 我们之前 open 即开灌，起点还是当前片（从头播就是第 0 片）——
            // 播放器要的那一片和预取线程要的那一片是同一个地址：两路请求同时
            // 打到 CDN / 中转，首片等于是和自己的预取抢带宽和连接名额。
            // 现在预取从「当前位置的下一片」开始，并且只在首帧之后跑。
            if (!isLocal && isHls) {
                // 交给预取器的是**归并后**的地址：它自己拉清单时直接就是媒体
                // 清单，不用再走一次 master → variant。
                pendingPreload = PreloadRequest(playUrl, headers, startPositionMs)
            } else {
                pendingPreload = null
            }
            // BG_SERVICE（2026-11-15）：open 成功（清单已下发、prepare 已发出）
            // 就是「这一集确实要播了」，此时把前台服务拉起来。
            //
            // 放在这里而不是只等 onIsPlayingChanged(true)：用户可能刚点播放就
            // 按了 Home，那时 App 已经在后台，Android 12+ 不允许后台启动前台
            // 服务（会抛 ForegroundServiceStartNotAllowedException）。
            // open 这一步几乎总在前台完成，在这里起最稳。
            startBackground()
            result.success(true)
        } catch (e: Throwable) {
            // 这里必须兜 Throwable：NoClassDefFoundError / OutOfMemoryError
            // 这类 Error 不是 Exception，漏出去会让 MethodChannel 调用悬挂，
            // Dart 侧就一直等，UI 永远转圈。
            lastError = (e.message ?: e.javaClass.simpleName)
            result.error("open_failed", lastError, null)
        }
    }

    /**
     * 换集 / 换线路：**实例不重建、渲染器不解绑**（改动 ④）。
     *
     * 对齐壳的 `switchEpisode`：
     * ```
     * player.stop()
     * player.clearMediaItems()
     * player.setMediaItems(list, index, startPositionMs)
     * player.prepare()
     * player.playWhenReady = true
     * ```
     *
     * 这里写 `setMediaSource(source)` 而不是 `setMediaItems(item)`，唯一差别是
     * 「源工厂」：播放用的 MediaSource 必须带着本次请求的请求头（Referer /
     * 签名）和共享的 CacheDataSource，直接 `setMediaItems` 会退回 ExoPlayer
     * 自带的默认工厂，请求头和磁盘缓存全丢。media3 内部 `setMediaItems` 就是
     * 「清空 playlist → 追加 MediaSource → prepare」，与下面逐句等价。
     *
     * 和旧行为的区别：以前每次 open 都 `stop + clearMediaItems` 之后
     * **Dart 侧还会把整个 FxPlayer 换掉**（新实例 → 原生 `release` →
     * `player.release()` + 缓存释放 + 事件通道解绑）。换集那一下等于重开
     * 一条完整链路，解码器、缓存、预取线程全部重建 —— 这就是「换集卡一下」
     * 的直接原因。现在换集只是换源。
     */
    private fun switchToSource(
        source: MediaSource,
        startPositionMs: Long,
        playWhenReady: Boolean,
    ) {
        val p = player ?: return
        try {
            switchToSourceUnsafe(p, source, startPositionMs, playWhenReady)
        } catch (error: Throwable) {
            // CRASH_GUARD2：换源本身失败（空源 / 已被 release / media3 内部状态机
            // 拒绝）绝不能抛到主线程 —— 那是一次直接闪退。
            Log.e(
                LOG_TAG,
                "SWITCH 换源异常 ${error.javaClass.simpleName}: ${error.message}",
                error,
            )
            lastError = error.javaClass.simpleName + ": " + (error.message ?: "")
            try {
                p.stop()
            } catch (_: Throwable) {
                // 播放器已不可用：无所谓，Dart 侧会按失败处理。
            }
            emit()
        }
    }

    private fun switchToSourceUnsafe(
        p: ExoPlayer,
        source: MediaSource,
        startPositionMs: Long,
        playWhenReady: Boolean,
    ) {
        // 记住原来的播放意图：换集时用户正在播 → 换完继续播；
        // 暂停态打开（先拉一帧再 pause）不被强制播起来。
        val wasPlaying = p.playWhenReady || p.isPlaying
        // OPEN_RESET（2026-11-14）：换源前先把上一个源停掉并清空。
        // 之前某条线路失败后，播放器会停在错误/未就绪状态，
        // 之后无论手动还是自动切线路，setMediaSource 都会被旧状态拖住，
        // 表现就是「一旦某条线路失败，切什么都一直加载」。
        p.stop()
        p.clearMediaItems()
        lastError = null
        // FIRST_FRAME：换源 / 切集后旧画面作废，加载层重新压住。
        firstFrameRendered = false
        // DIAGNOSTICS：丢帧 / 清单耗时是「这一段」的统计，换源就归零。
        droppedFrameCount = 0
        playerManifestLoadMs = -1
        p.setMediaSource(source)
        // RESUME_FIRST_SEG（2026-11-14）：带续播位置打开。
        //
        // setMediaSource 之后、prepare 之前 seekTo 是 ExoPlayer 支持的
        // 「起始位置」写法：prepare 会从这个位置开始选分片，第一个网络
        // 请求就是目标片。以前是 prepare（从第 0 片开始拉）之后再 seek，
        // 第 0 片先到服务器，把 /api/seg 的首片中转名额用掉了，
        // 真正需要的目标片只能 302 直连 —— 表现就是「带 27:55 打开比
        // 从头播慢很多」。
        if (startPositionMs > 0) {
            p.seekTo(startPositionMs)
        }
        p.prepare()
        if (wasPlaying || playWhenReady) p.playWhenReady = true
        Log.i(
            LOG_TAG,
            "SWITCH 复用实例（不 release / 不解绑渲染器）start=${startPositionMs}ms " +
                "play=${wasPlaying || playWhenReady}",
        )
    }

    // ------------------------------------------------ 下一集预载（改动 ⑥）

    /// 建立（或复用）下一集预载器：和播放器共用同一份磁盘缓存。
    private fun ensureNextPreloader(): NextEpisodePreloader? {
        nextPreloader?.let { return it }
        val cache = ensureMediaCache() ?: return null
        val created = NextEpisodePreloader(
            cache = cache,
            // 传输层：和播放路径同一个工厂（PlayerHttp.httpFactory →
            // OkHttpDataSource，共用同一个 OkHttpClient 连接池）。
            upstreamFactory = { url, headers -> PlayerHttp.httpFactory(url, headers) },
            // PRIORITY：播放器在缓冲时预载让路（和 SegmentPreloader 同一判据）。
            // 只读主线程快照 [playerBuffering]，不碰播放器（CRASH_FIX）。
            pauseGate = { playerBuffering },
            log = { message -> Log.d(LOG_TAG, message) },
        )
        nextPreloader = created
        return created
    }

    /**
     * 预载「下一集」的清单 + 前 N 个分片（只写进缓存，不参与当前播放）。
     *
     * 同一集只灌一次；入队即返回，下载在 [NextEpisodePreloader] 自己的线程里跑。
     */
    private fun preloadNextEpisode(url: String, headers: Map<String, String>): Boolean {
        if (url.isEmpty()) return false
        if (url == nextPreloadUrl) {
            Log.d(LOG_TAG, "preload next: 这一集已经预载过，跳过")
            return true
        }
        val created = ensureNextPreloader()
        if (created == null) {
            Log.d(LOG_TAG, "preload next: 磁盘缓存不可用，跳过")
            return false
        }
        nextPreloadUrl = url
        Log.d(LOG_TAG, "preload next: 排队 $url")
        created.preload(url, headers)
        return true
    }

    /// 分片磁盘缓存（1.5 GiB，LRU）。
    ///
    /// 用户现象：第一次拖很快，再拖就开始卡 —— 因为每次拖动都重新回源，
    /// 而上游分片 CDN 对同一 IP 有 429 限流。加了缓存后，
    /// 同一集内来回拖基本不走网络，切集再回来也能命中。
    ///
    /// 缓存实例由 [ensureMediaCache] 统一持有，和预取器是同一个对象
    /// （改动 ② 的前提：缓存只能有一个主人，否则等于两份缓存两份下载）。
    private fun cacheDataSourceFactory(
        upstream: DataSource.Factory,
        writeToCache: Boolean = false,
    ): DataSource.Factory {
        val cache = ensureMediaCache() ?: return upstream
        return try {
            val factory = CacheDataSource.Factory()
                .setCache(cache)
                .setUpstreamDataSourceFactory(upstream)
                // CACHE_KEY：播放器 / 预取器 / 首页续播预取共用同一套 key
                // （FxCacheKeyFactory）。默认的 uri.toString() 无法表达
                // 「/api/seg?u=…&i=…&s=…&ln=…」这种同路径分片，见该文件注释。
                .setCacheKeyFactory(FxCacheKeyFactory)
                // 缓存坏了就忽略、直接回源，别让播放卡死
                .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
            // PLAYBACK_NO_WRITE（ALIGN_FONGMI 2026-11-15）：只有预取线程
            // （writeToCache = true）才落盘；播放路径设 null = 只读。
            // 壳就是这么写的：`setCacheWriteDataSinkFactory(null)`。
            if (!writeToCache) factory.setCacheWriteDataSinkFactory(null)
            factory
        } catch (e: Throwable) {
            upstream
        }
    }

    // ------------------------------------------------ 首页续播预取（2026-11-14）

    /**
     * 把一个 HLS 分片写进播放器同一份 SimpleCache。
     *
     * 为什么必须走原生 CacheDataSource：SimpleCache 是原生磁盘缓存，
     * 播放器的 CacheDataSource 按 cacheKey 查它，而 cacheKey 是
     * [FxCacheKeyFactory] 算出来的。Dart 侧自己 http 拉下来的字节只会进
     * 内存 / 临时文件，播放入口一个字节都命中不到。
     *
     * [maxBytes] > 0 时读到这么多字节就停（移动网络的单次预算），
     * 停止的位置 media3 会按「部分缓存」记着，播放器接着往下读即可。
     * 失败只留一行 logcat，不给 Dart 任何异常。
     */
    private fun prefetchSegment(
        url: String,
        headers: Map<String, String>,
        maxBytes: Long,
        result: MethodChannel.Result,
    ) {
        if (url.isEmpty()) {
            result.success(false)
            return
        }
        // 先确认缓存能建起来：建不起来就别排任务（cacheDataSourceFactory
        // 会退化成直连，那样下完也不落盘，纯属白跑）。
        if (ensureMediaCache() == null) {
            Log.d(LOG_TAG, "PREFETCH 跳过（磁盘缓存不可用）$url")
            result.success(false)
            return
        }
        prefetchQueue.execute {
            var source: DataSource? = null
            try {
                // TRANSPORT_OKHTTP（2026-11-15）：首页续播预取也走**同一个**
                // client —— 预取过的连接留在同一个池子里，用户点「继续观看」
                // 起播时播放器直接复用这条连接，不用重新握手。
                val httpFactory = PlayerHttp.httpFactory(url, headers)
                // 关键：同一个 cacheDataSourceFactory —— 同一份 SimpleCache、
                // 同一个 cacheKey 规则，播放器读的时候才是本地命中。
                // 这条路径是**写盘**的（writeToCache = true）：播放路径已经
                // 不写缓存了（PLAYBACK_NO_WRITE），落盘只剩预取这一条路。
                val factory = cacheDataSourceFactory(
                    DefaultDataSource.Factory(context, httpFactory),
                    writeToCache = true,
                )
                val stream = factory.createDataSource()
                source = stream
                stream.open(DataSpec(Uri.parse(url)))
                val buffer = ByteArray(PREFETCH_BUFFER_SIZE)
                var total = 0L
                while (true) {
                    val read = stream.read(buffer, 0, buffer.size)
                    if (read == -1) break
                    total += read
                    if (maxBytes > 0 && total >= maxBytes) break
                }
                Log.d(LOG_TAG, "PREFETCH 落盘 ${total}B（上限 ${maxBytes}B）$url")
            } catch (error: Throwable) {
                // 预取失败不影响播放：播放器那头回源兜底。
                Log.d(LOG_TAG, "PREFETCH 失败 ${error.javaClass.simpleName} $url")
            } finally {
                try {
                    source?.close()
                } catch (_: Throwable) {
                    // 关闭失败不影响结果
                }
            }
        }
        result.success(true)
    }

    /** 供 PlatformViewFactory 创建画面视图 */
    /// 视图销毁时解绑，避免播放器继续往已销毁的纹理里画（会黑屏/闪退）
    fun detachView(v: android.view.TextureView) {
        if (videoView === v) {
            try { player?.clearVideoSurface() } catch (_: Exception) {}
            videoView = null
        }
    }

    fun createView(): android.view.TextureView {
        val tv = android.view.TextureView(context)
        tv.layoutParams = android.view.ViewGroup.LayoutParams(
            android.view.ViewGroup.LayoutParams.MATCH_PARENT,
            android.view.ViewGroup.LayoutParams.MATCH_PARENT
        )
        videoView = tv
        player?.setVideoTextureView(tv)
        return tv
    }
}

/** PlatformView：把 PlayerView 交给 Flutter */
@OptIn(UnstableApi::class)
class ExoView(context: Context, private val messenger: BinaryMessenger, id: Int, params: Any?) :
    PlatformView {
    private val tv: android.view.TextureView

    init {
        val plugin = ExoPluginHolder.get(messenger)
        tv = plugin?.createView() ?: android.view.TextureView(context)
        // 画面比例档位在 Flutter 侧用 AspectRatio 控制，这里只保证铺满容器
        tv.layoutParams = android.view.ViewGroup.LayoutParams(
            android.view.ViewGroup.LayoutParams.MATCH_PARENT,
            android.view.ViewGroup.LayoutParams.MATCH_PARENT
        )
    }

    override fun getView(): View = tv
    override fun dispose() {
        // 视图销毁时解绑纹理，避免播放器往已销毁的 TextureView 里画
        ExoPluginHolder.get(messenger)?.let { it.detachView(tv) }
    }
}

/** 单例持有：MethodChannel 和 PlatformView 要拿到同一个 plugin 实例 */
object ExoPluginHolder {
    private val map = HashMap<BinaryMessenger, ExoPlayerPlugin>()
    fun put(m: BinaryMessenger, p: ExoPlayerPlugin) { map[m] = p }
    fun get(m: BinaryMessenger): ExoPlayerPlugin? = map[m]
}

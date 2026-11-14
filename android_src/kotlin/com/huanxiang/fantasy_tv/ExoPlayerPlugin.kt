package com.huanxiang.fantasy_tv

import android.app.Activity
import android.net.Uri
import android.util.Log
import android.content.Context
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.SeekParameters
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.hls.HlsMediaSource
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
 *   · connect / read 超时 30s，allowCrossProtocolRedirects = true
 *   · 不自定义 LoadErrorHandlingPolicy（壳跑 media3 默认 3 次重试）
 *   · 播放路径只读缓存，落盘交给预取线程（壳 setCacheWriteDataSinkFactory(null)）
 *   · 预取在首帧之后才开灌、并从下一片起，播放缓冲时让路
 *   · seek 静音闸 1200ms，首帧回来恢复音量
 *   · DefaultHlsPlaylistParser 原生认 #EXT-X-ENDLIST，不会误判成直播
 *   · MediaCodecSelector 自动选硬解，4K HEVC 走硬件解码
 */
@OptIn(UnstableApi::class)
class ExoPlayerPlugin(private val context: Context) : MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

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
         */
        const val HTTP_CONNECT_TIMEOUT_MS = 30_000
        const val HTTP_READ_TIMEOUT_MS = 30_000
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

    /// 首页续播预取的单线程队列（并发 = 1，和 [SegmentPreloader] 同一策略）。
    ///
    /// 为什么不由 [SegmentPreloader] 代劳：那个预取器属于「当前播放的那个源」，
    /// 首页可能还没创建过播放器，而且它的代际号会被播放页的 seek 作废。
    /// 首页预取只做「把一个已知分片写进同一份缓存」，独立队列最简单，
    /// 也绝不打断播放器自己的预取。
    private val prefetchQueue: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "FxPrefetch").also { it.isDaemon = true }
    }

    // ---- seek 音频闸（改动 ③）：拖动时静音，首帧回来再恢复 ----
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var seekGateActive = false
    private var volumeBeforeSeekGate = 1f
    private val seekGateTimeout = Runnable { endSeekAudioGate() }

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

    fun attach(messenger: BinaryMessenger) {
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(this)
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(this)
    }

    fun dispose() {
        mainHandler.removeCallbacks(seekGateTimeout)
        seekGateActive = false
        pendingPreload = null
        preloader?.release()
        preloader = null
        player?.clearVideoSurface()
        player?.release()
        player = null
        events = null
        try { mediaCache?.release() } catch (_: Exception) {}
        mediaCache = null
    }

    // ---------------- EventChannel ----------------

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        events = sink
        player?.let { bindListener(it) }
    }

    override fun onCancel(arguments: Any?) {
        events = null
    }

    // ---------------- MethodChannel ----------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> {
                ensurePlayer()
                result.success(true)
            }
            "open" -> {
                val url = call.argument<String>("url") ?: return result.error("bad_arg", "url 为空", null)
                val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
                val isHls = call.argument<Boolean>("isHls") ?: true
                // RESUME_START：续播 / 跟进度打开时带起始位置，prepare 之前就落位。
                val startMs = call.argument<Number>("startPositionMs")?.toLong() ?: 0L
                open(url, headers, isHls, startMs, result)
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
            "state" -> result.success(snapshot())
            "release" -> { dispose(); result.success(true) }
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
        val renderers = androidx.media3.exoplayer.DefaultRenderersFactory(context)
            .setEnableDecoderFallback(true)
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
        // PRELOADER（改动 ②）：线程池在这里随播放器一起建好 ——
        // 「预取随播放器创建即启动」，拿到源地址（open）后立刻开始灌分片，
        // 不等 prepare 完成、不等用户点播放。
        ensurePreloader()
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
            pauseGate = {
                val p = player
                p != null && p.playbackState == Player.STATE_BUFFERING
            },
        )
        preloader = created
        return created
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

    private fun bindListener(p: ExoPlayer) {
        p.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                // 拖动后播到结尾 / 被停掉：闸必须收掉，否则会一直静音。
                if (state == Player.STATE_IDLE || state == Player.STATE_ENDED) {
                    endSeekAudioGate()
                }
                emit()
            }
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                emit()
            }
            override fun onRenderedFirstFrame() {
                // FIRST_FRAME：只有这里才把首帧标记置 true。
                // Dart 的加载层就是靠它收起的，别再拿 buffering / playing 猜。
                firstFrameRendered = true
                Log.i(LOG_TAG, "FIRST_FRAME 已渲染，pos=${player?.currentPosition}ms")
                // 首帧到了：拖动闸放开（对方确证的结束条件之一）。
                endSeekAudioGate()
                // PRELOAD_AFTER_FIRST_FRAME（ALIGN_FONGMI）：首帧上屏之后
                // 才开始往后预取 —— 起播那一片只留给播放器，不和它抢。
                startPendingPreload()
                emit()
            }
            override fun onPlayerError(error: PlaybackException) {
                lastError = error.errorCodeName + ": " + (error.message ?: "")
                endSeekAudioGate()
                emit()
            }
        })
    }

    private fun snapshot(): Map<String, Any?> {
        val p = player ?: return mapOf(
            "positionMs" to 0, "durationMs" to 0, "bufferedMs" to 0,
            "preloadedMs" to 0L,
            "playing" to false, "buffering" to true, "error" to null,
            "firstFrameRendered" to false,
            "width" to 0, "height" to 0, "ended" to false, "state" to 1
        )
        // 画面尺寸：FxPlayer 的 value.width/height 和分辨率胶囊都靠它，
        // 拿不到就一直显示 "0x0"。format 在 READY 之后才有值。
        val fmt = p.videoFormat
        val rotation = fmt?.rotationDegrees ?: 0
        var w = fmt?.width ?: 0
        var h = fmt?.height ?: 0
        if (rotation == 90 || rotation == 270) {
            val t = w; w = h; h = t
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
            "buffering" to (p.playbackState == Player.STATE_BUFFERING),
            // FIRST_FRAME：Dart 加载层只认这一个字段（open / seek 会重置）。
            "firstFrameRendered" to firstFrameRendered,
            "error" to lastError,
            "width" to w,
            "height" to h,
            "ended" to (p.playbackState == Player.STATE_ENDED),
            "state" to p.playbackState
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
    ) {
        ensurePlayer()
        lastError = null
        try {
            val httpFactory = DefaultHttpDataSource.Factory()
                .setUserAgent(headers["User-Agent"] ?: "Mozilla/5.0")
                .setAllowCrossProtocolRedirects(true)   // 福盈分片 302 必须开
                // ALIGN_FONGMI：30s / 30s，和壳的 OkHttp TIMEOUT 一致。
                .setConnectTimeoutMs(HTTP_CONNECT_TIMEOUT_MS)
                .setReadTimeoutMs(HTTP_READ_TIMEOUT_MS)
                .setDefaultRequestProperties(headers)

            // 本地文件（离线播放页）走 DefaultDataSource：它能识别 file:// 和
            // 绝对路径，直接套 HttpDataSource 会失败。
            val isLocal = !url.startsWith("http://") && !url.startsWith("https://")
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
            val item = MediaItem.fromUri(url)
            // ALIGN_FONGMI：不挂自定义 LoadErrorHandlingPolicy（壳是空实现，
            // 跑 media3 默认：3 次重试 + 0/1s/2s 退避），死地址交给
            // onPlayerError → Dart 救援链。
            val source: MediaSource = if (isHls) {
                HlsMediaSource.Factory(cachedFactory).createMediaSource(item)
            } else {
                ProgressiveMediaSource.Factory(cachedFactory).createMediaSource(item)
            }
            // OPEN_RESET（2026-11-14）：换源前先把上一个源停掉并清空。
            // 之前某条线路失败后，播放器会停在错误/未就绪状态，
            // 之后无论手动还是自动切线路，setMediaSource 都会被旧状态拖住，
            // 表现就是「一旦某条线路失败，切什么都一直加载」。
            player!!.stop()
            player!!.clearMediaItems()
            lastError = null
            // FIRST_FRAME：换源 / 切集后旧画面作废，加载层重新压住。
            firstFrameRendered = false
            player!!.setMediaSource(source)
            // RESUME_FIRST_SEG（2026-11-14）：带续播位置打开。
            //
            // setMediaSource 之后、prepare 之前 seekTo 是 ExoPlayer 支持的
            // 「起始位置」写法：prepare 会从这个位置开始选分片，第一个网络
            // 请求就是目标片。以前是 prepare（从第 0 片开始拉）之后再 seek，
            // 第 0 片先到服务器，把 /api/seg 的首片中转名额用掉了，
            // 真正需要的目标片只能 302 直连 —— 表现就是「带 27:55 打开比
            // 从头播慢很多」。
            if (startPositionMs > 0) {
                player!!.seekTo(startPositionMs)
            }
            player!!.prepare()
            // RESUME（2026-11-14）：真机 logcat -s FxExo 核对续播是否真的带上了。
            // 「首个分片索引 N」由 SegmentPreloader.start 打出，两条一起看。
            Log.i(
                LOG_TAG,
                "RESUME 起始位置 ${startPositionMs}ms（prepare 前 seek）；" +
                    "isHls=$isHls url=$url",
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
                pendingPreload = PreloadRequest(url, headers, startPositionMs)
            } else {
                pendingPreload = null
            }
            result.success(true)
        } catch (e: Throwable) {
            // 这里必须兜 Throwable：NoClassDefFoundError / OutOfMemoryError
            // 这类 Error 不是 Exception，漏出去会让 MethodChannel 调用悬挂，
            // Dart 侧就一直等，UI 永远转圈。
            lastError = (e.message ?: e.javaClass.simpleName)
            result.error("open_failed", lastError, null)
        }
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
                val httpFactory = DefaultHttpDataSource.Factory()
                    .setUserAgent(headers["User-Agent"] ?: "Mozilla/5.0")
                    .setAllowCrossProtocolRedirects(true)
                    // ALIGN_FONGMI：和播放路径同一档超时（壳的 OkHttp 30s）。
                    .setConnectTimeoutMs(HTTP_CONNECT_TIMEOUT_MS)
                    .setReadTimeoutMs(HTTP_READ_TIMEOUT_MS)
                    .setDefaultRequestProperties(headers)
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

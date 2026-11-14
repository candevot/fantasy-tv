package com.huanxiang.fantasy_tv

import android.app.Activity
import android.content.Context
import java.io.File
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
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
 * ExoPlayer（Media3）内核桥接。
 *
 * 为什么不用 better_player / video_player：
 *   它们自带 widget 层和生命周期管理，跟 FxPlayer 现有的救援链、看门狗、
 *   一起看同步会打架。这里只做「最小内核」—— 只管播放，画面用 PlatformView
 *   交给 Flutter 叠控制层，控制权完全在 FxPlayer 手里。
 *
 * 关键配置（对齐腾讯/阿里播放器策略，取值见逆向报告 §10）：
 *   · allowCrossProtocolRedirects = true  → 福盈 4K 分片 302 到移动云能跟
 *   · LoadControl 15s/60s/1s/2s + backBuffer 0 → 首帧只要 1 秒缓冲
 *   · 分片预取单线程 + seek 代际作废，缓存 LRU 1.5GiB
 *   · seek 静音闸 1200ms，首帧回来恢复音量
 *   · DefaultHlsPlaylistParser 原生认 #EXT-X-ENDLIST，不会误判成直播
 *   · MediaCodecSelector 自动选硬解，4K HEVC 走硬件解码
 */
@OptIn(UnstableApi::class)
class ExoPlayerPlugin(private val context: Context) : MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    companion object {
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

    private var lastError: String? = null

    // ---- seek 音频闸（改动 ③）：拖动时静音，首帧回来再恢复 ----
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var seekGateActive = false
    private var volumeBeforeSeekGate = 1f
    private val seekGateTimeout = Runnable { endSeekAudioGate() }

    fun attach(messenger: BinaryMessenger) {
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(this)
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(this)
    }

    fun dispose() {
        mainHandler.removeCallbacks(seekGateTimeout)
        seekGateActive = false
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
                open(url, headers, isHls, result)
            }
            "play" -> { player?.play(); result.success(true) }
            "pause" -> { player?.pause(); result.success(true) }
            "seek" -> {
                val ms = call.argument<Number>("positionMs")?.toLong() ?: 0L
                // 先闸音量再 seek：避免「画面还在旧帧、声音已经跳过去」（改动 ③）。
                beginSeekAudioGate()
                player?.seekTo(ms)
                // 预取改道：代际 +1，旧任务立刻作废，从目标分片往后灌（改动 ②）。
                preloader?.seekTo(ms)
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
            "state" -> result.success(snapshot())
            "release" -> { dispose(); result.success(true) }
            else -> result.notImplemented()
        }
    }

    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    private fun ensurePlayer() {
        if (player != null) return
        // LOAD_CONTROL（2026-11-14，按逆向报告 §10 改动 1 落地）。
        //
        // 对方 MemoryLimitedLoadControl 的确证取值：
        //   setBufferDurationsMs(15000, 60000, 1000, 2000).setBackBuffer(0, false)
        //   · minBufferMs 15s / maxBufferMs 60s：比 media3 默认（50s/50s）低，
        //     停止继续吃带宽的阈值更低，播放器不会为了「多缓冲」把链路占满；
        //   · bufferForPlaybackMs 1s：**首帧只需要 1 秒缓冲**，这是起播快的
        //     直接原因（我们之前是 1s，但 max 120s 会在弱网下无限等）；
        //   · bufferForPlaybackAfterRebufferMs 2s：卡一下补 2 秒就续上；
        //   · backBuffer 0 / 不保留关键帧：ExoPlayer 不往回缓存，
        //     「往回拖」全靠分片磁盘缓存命中（配合改动 ② 的预取）。
        //
        // 注意我们之前是 30s/120s + backBuffer 30s：120s 上限让弱网下的
        // 缓冲等得没完，30s 回看缓冲又和磁盘缓存重复占内存。
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                15_000,   // minBufferMs
                60_000,   // maxBufferMs
                1_000,    // bufferForPlaybackMs
                2_000     // bufferForPlaybackAfterRebufferMs
            )
            .setBackBuffer(0, false)
            .setPrioritizeTimeOverSizeThresholds(true)
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
        )
        preloader = created
        return created
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
                // 首帧到了：拖动闸放开（对方确证的结束条件之一）。
                endSeekAudioGate()
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

    private fun open(url: String, headers: Map<String, String>, isHls: Boolean, result: MethodChannel.Result) {
        ensurePlayer()
        lastError = null
        try {
            val httpFactory = DefaultHttpDataSource.Factory()
                .setUserAgent(headers["User-Agent"] ?: "Mozilla/5.0")
                .setAllowCrossProtocolRedirects(true)   // 福盈分片 302 必须开
                .setConnectTimeoutMs(15_000)
                .setReadTimeoutMs(20_000)
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
            val cachedFactory = if (isLocal || !isHls) {
                dataSource
            } else {
                cacheDataSourceFactory(dataSource)
            }
            val item = MediaItem.fromUri(url)
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
            player!!.setMediaSource(source)
            player!!.prepare()
            // 预取随 open 立刻开灌（改动 ②）：HLS 才需要分片级预取，
            // 本地文件 / 渐进式源跳过。
            if (!isLocal && isHls) {
                ensurePreloader()?.start(url, headers)
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
    private fun cacheDataSourceFactory(upstream: DataSource.Factory): DataSource.Factory {
        val cache = ensureMediaCache() ?: return upstream
        return try {
            CacheDataSource.Factory()
                .setCache(cache)
                .setUpstreamDataSourceFactory(upstream)
                // 缓存坏了就忽略、直接回源，别让播放卡死
                .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
        } catch (e: Throwable) {
            upstream
        }
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

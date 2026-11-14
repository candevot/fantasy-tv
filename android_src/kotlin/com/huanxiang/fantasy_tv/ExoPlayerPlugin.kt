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
 * 关键配置（对齐腾讯/阿里播放器策略）：
 *   · allowCrossProtocolRedirects = true  → 福盈 4K 分片 302 到移动云能跟
 *   · bufferForPlaybackMs = 1500          → 卡一下只需补 1.5 秒（默认 2.5 秒）
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
    private var lastError: String? = null

    fun attach(messenger: BinaryMessenger) {
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(this)
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(this)
    }

    fun dispose() {
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
                player?.seekTo(ms)
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
        // PERF（2026-11-14）：这几项直接决定「拖几次就卡」。
        //
        // 1) 前向缓冲 30s 保底 / 120s 上限：4K 一片 6 秒约 5.5MB，
        //    原来 15s 只等于 2.5 片，网速一抖就见底 → 缓冲 → 黑屏。
        // 2) 回看缓冲 30s：往回拖不用重新回源（上游有 429 限流）。
        // 3) 起播只要 1 秒：第一帧尽快出来。
        // 4) 重缓冲只要 2 秒：卡一下立刻续上，不干等。
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                30_000,   // minBufferMs
                120_000,  // maxBufferMs
                1_000,    // bufferForPlaybackMs
                2_000     // bufferForPlaybackAfterRebufferMs
            )
            .setBackBuffer(30_000, true)
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
    }

    private fun bindListener(p: ExoPlayer) {
        p.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                emit()
            }
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                emit()
            }
            override fun onPlayerError(error: PlaybackException) {
                lastError = error.errorCodeName + ": " + (error.message ?: "")
                emit()
            }
        })
    }

    private fun snapshot(): Map<String, Any?> {
        val p = player ?: return mapOf(
            "positionMs" to 0, "durationMs" to 0, "bufferedMs" to 0,
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
            // PERF_SAFE（2026-11-14）：先不用磁盘缓存。
            // 它是优化项，但一旦 SimpleCache 初始化失败（NoClassDefFoundError
            // 之类的 Error 不是 Exception，catch 不住），会让**所有**线路
            // 都打不开 —— 表现就是「什么线路都一直加载」。
            // 播放正确性优先，缓存等这一版稳定后再单独加回来。
            val cachedFactory = dataSource
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
            result.success(true)
        } catch (e: Throwable) {
            // 这里必须兜 Throwable：NoClassDefFoundError / OutOfMemoryError
            // 这类 Error 不是 Exception，漏出去会让 MethodChannel 调用悬挂，
            // Dart 侧就一直等，UI 永远转圈。
            lastError = (e.message ?: e.javaClass.simpleName)
            result.error("open_failed", lastError, null)
        }
    }

    /// 分片磁盘缓存（512MB，LRU）。
    ///
    /// 用户现象：第一次拖很快，再拖就开始卡 —— 因为每次拖动都重新回源，
    /// 而上游分片 CDN 对同一 IP 有 429 限流。加了缓存后，
    /// 同一集内来回拖基本不走网络，切集再回来也能命中。
    private fun cacheDataSourceFactory(upstream: DataSource.Factory): DataSource.Factory {
        return try {
            val cache = mediaCache ?: run {
                val dir = File(context.cacheDir, "exo_media_cache")
                if (!dir.exists()) dir.mkdirs()
                val c = SimpleCache(
                    dir,
                    LeastRecentlyUsedCacheEvictor(512L * 1024 * 1024),
                    StandaloneDatabaseProvider(context)
                )
                mediaCache = c
                c
            }
            CacheDataSource.Factory()
                .setCache(cache)
                .setUpstreamDataSourceFactory(upstream)
                // 缓存坏了就忽略、直接回源，别让播放卡死
                .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
        } catch (e: Exception) {
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
class ExoView(context: Context, messenger: BinaryMessenger, id: Int, params: Any?) :
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

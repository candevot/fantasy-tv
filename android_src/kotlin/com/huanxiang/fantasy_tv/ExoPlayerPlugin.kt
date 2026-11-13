package com.huanxiang.fantasy_tv

import android.app.Activity
import android.content.Context
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
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
    private var playerView: PlayerView? = null
    private var events: EventChannel.EventSink? = null
    private var lastError: String? = null

    fun attach(messenger: BinaryMessenger) {
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(this)
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(this)
    }

    fun dispose() {
        playerView?.player = null
        player?.release()
        player = null
        events = null
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
            "state" -> result.success(snapshot())
            "release" -> { dispose(); result.success(true) }
            else -> result.notImplemented()
        }
    }

    private fun ensurePlayer() {
        if (player != null) return
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                15_000,   // minBufferMs
                60_000,   // maxBufferMs
                1_500,    // bufferForPlaybackMs —— 卡一下只补 1.5 秒
                3_000     // bufferForPlaybackAfterRebufferMs
            )
            .build()
        player = ExoPlayer.Builder(context)
            .setLoadControl(loadControl)
            .build()
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
            val item = MediaItem.fromUri(url)
            val source: MediaSource = if (isHls) {
                HlsMediaSource.Factory(dataSource).createMediaSource(item)
            } else {
                ProgressiveMediaSource.Factory(dataSource).createMediaSource(item)
            }
            player!!.setMediaSource(source)
            player!!.prepare()
            result.success(true)
        } catch (e: Exception) {
            lastError = e.message
            result.error("open_failed", e.message, null)
        }
    }

    /** 供 PlatformViewFactory 创建画面视图 */
    fun createView(): PlayerView {
        val pv = PlayerView(context)
        pv.useController = false          // 控制层由 Flutter 画
        pv.resizeMode = androidx.media3.ui.AspectRatioFrameLayout.RESIZE_MODE_FIT
        pv.player = player
        playerView = pv
        return pv
    }
}

/** PlatformView：把 PlayerView 交给 Flutter */
@OptIn(UnstableApi::class)
class ExoView(context: Context, messenger: BinaryMessenger, id: Int, params: Any?) :
    PlatformView {
    private val pv: PlayerView

    init {
        val plugin = ExoPluginHolder.get(messenger)
        pv = plugin?.createView() ?: PlayerView(context)
    }

    override fun getView(): View = pv
    override fun dispose() {
        pv.player = null
    }
}

/** 单例持有：MethodChannel 和 PlatformView 要拿到同一个 plugin 实例 */
object ExoPluginHolder {
    private val map = HashMap<BinaryMessenger, ExoPlayerPlugin>()
    fun put(m: BinaryMessenger, p: ExoPlayerPlugin) { map[m] = p }
    fun get(m: BinaryMessenger): ExoPlayerPlugin? = map[m]
}

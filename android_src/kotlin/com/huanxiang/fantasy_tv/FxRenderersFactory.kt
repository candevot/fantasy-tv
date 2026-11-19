package com.huanxiang.fantasy_tv

import android.content.Context
import android.os.Handler
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.audio.AudioRendererEventListener
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import io.github.anilbeesetti.nextlib.media3ext.ffdecoder.FfmpegAudioRenderer
import io.github.anilbeesetti.nextlib.media3ext.ffdecoder.FfmpegLibrary

/**
 * FFmpeg 音轨解码扩展的**开关与状态**（FFMPEG_AUDIO，2026-11-19）。
 *
 * 依赖：`io.github.anilbeesetti:nextlib-media3ext`（预编译 media3 扩展，内含
 * FFmpeg 的 ac3 / eac3 / dca(DTS) / truehd / mlp 解码器 + libswresample）。
 * 版本必须和 media3 一一对应（`1.7.1-0.9.0` ↔ media3 `1.7.1`），见
 * `tools/patch_exoplayer.py` 里的 `NEXT_LIB_VERSION`。
 *
 * 这里只管三件事，全部围绕「**绝不能因为 FFmpeg 起不来导致起播失败**」：
 *   1. [available]：懒探测 `System.loadLibrary` 能不能成（不支持的 ABI /
 *      被裁剪的 ROM / so 缺失，都会在这里抛 `UnsatisfiedLinkError`，
 *      它是 `Error` 不是 `Exception`，所以统一 catch `Throwable`）；
 *   2. [disable]：播放期解不出来时把 FFmpeg 这一档**摘掉**（进程内永久），
 *      退回「纯系统/硬件解码」—— 也就是这次改动之前的行为；
 *   3. [status]：一行日志，让用户截图 logcat 就能看出「这台机器到底有没有
 *      在走 FFmpeg」。
 */
object FxAudioExt {

    private const val TAG = "FxAudioExt"

    /** 探测结果缓存（成功 / 失败都只探一次，loadLibrary 失败再试也一样）。 */
    @Volatile
    private var probed = false

    @Volatile
    private var availableFlag = false

    @Volatile
    private var versionFlag = ""

    /** 非空 = 已降级，原因写在这里（进程内不再挂 FFmpeg 音轨渲染器）。 */
    @Volatile
    private var disabledFlag: String? = null

    /** FFmpeg 扩展能不能用（探测失败一律 false，不抛异常给调用方）。 */
    fun available(): Boolean {
        if (!probed) {
            synchronized(this) {
                if (!probed) {
                    try {
                        availableFlag = FfmpegLibrary.isAvailable()
                        versionFlag = try {
                            FfmpegLibrary.getVersion() ?: ""
                        } catch (_: Throwable) {
                            ""
                        }
                        probed = true
                        Log.i(
                            TAG,
                            "AUDIO_EXT ffmpeg=$availableFlag version=${versionFlag.ifEmpty { "-" }}",
                        )
                    } catch (error: Throwable) {
                        // UnsatisfiedLinkError / NoClassDefFoundError / 任何
                        // 原生库加载失败 —— 这一档就当这台机器没有 FFmpeg。
                        availableFlag = false
                        versionFlag = ""
                        probed = true
                        Log.w(
                            TAG,
                            "AUDIO_EXT ffmpeg 不可用（${error.javaClass.simpleName}: ${error.message}），" +
                                "音轨退回系统解码",
                        )
                    }
                }
            }
        }
        return availableFlag
    }

    /** 当前**是否真的会挂** FFmpeg 音轨渲染器（可用 + 没被降级）。 */
    fun shouldAttach(): Boolean = disabledFlag == null && available()

    /** 播放期解码失败 / 构造失败 → 摘掉 FFmpeg 这一档（只降不升）。 */
    fun disable(reason: String) {
        if (disabledFlag == null) {
            disabledFlag = reason
            Log.w(TAG, "AUDIO_EXT 降级：本次进程内不再挂 FFmpeg 音轨渲染器（$reason）")
        }
    }

    /** 是否已经被降级（诊断用）。 */
    fun isDisabled(): Boolean = disabledFlag != null

    /** 一行状态：[available] / 版本 / 是否降级 —— 起播日志里会打。 */
    fun status(): String {
        val ff = if (available()) "on(${versionFlag.ifEmpty { "-" }})" else "off"
        val dis = disabledFlag?.let { " disabled=$it" } ?: ""
        return "ffmpeg=$ff$dis"
    }
}

/**
 * 渲染器工厂（FFMPEG_AUDIO，2026-11-19）。
 *
 * 继承 [DefaultRenderersFactory]，**只**在音频渲染器列表末尾追加一个
 * [FfmpegAudioRenderer]，其余行为（视频硬解、解码失败回退
 * `setEnableDecoderFallback(true)`、`MediaCodecSelector`）与原实现逐位一致 ——
 * 视频链路这次一点都不碰，避免「加了个音频解码器，结果 1080P 起播变慢」。
 *
 * 为什么追加在**末尾**（= 优先级最低）：
 *   · media3 选渲染器时按列表顺序问 `supportsFormat`，第一个说「能解」的赢；
 *   · 系统/硬件解码器在前 → AC3/EAC3 这类绝大多数盒子硬解能出的，仍然走
 *     硬解（省电、音画同步由系统保证）；
 *   · 只有系统解码器**明确不支持**的（典型：DTS / TrueHD / 部分 EAC3），
 *     才落到 FFmpeg —— 这就是用户要的「硬件/系统 → FFmpeg 兜底」。
 *
 * 构造 FfmpegAudioRenderer 时抛任何 Throwable（so 加载失败、ABI 不匹配）
 * 都只降级这一档，绝不让 `ExoPlayer.Builder.build()` 炸掉 —— 起播失败是
 * 用户能直接感知的故障，音轨少一条解不出来只是一个源的兼容性问题。
 */
@OptIn(UnstableApi::class)
class FxRenderersFactory(context: Context) : DefaultRenderersFactory(context) {

    override fun buildAudioRenderers(
        context: Context,
        extensionRendererMode: Int,
        mediaCodecSelector: MediaCodecSelector,
        enableDecoderFallback: Boolean,
        audioSink: AudioSink,
        eventHandler: Handler,
        eventListener: AudioRendererEventListener,
        out: ArrayList<Renderer>,
    ) {
        // 先让父类把系统 / 硬件音频渲染器装进去（顺序与优先级都不动）。
        super.buildAudioRenderers(
            context,
            extensionRendererMode,
            mediaCodecSelector,
            enableDecoderFallback,
            audioSink,
            eventHandler,
            eventListener,
            out,
        )
        if (!FxAudioExt.shouldAttach()) return
        try {
            // 用父类建好的 AudioSink（和系统渲染器共用同一个），这样
            // 音量 / 音频焦点 / 音频处理链（AudioProcessor）全部一致，
            // 不会出现「切到 FFmpeg 轨音量变了」。
            out.add(FfmpegAudioRenderer(eventHandler, eventListener, audioSink))
            Log.i(
                ExoPlayerPlugin.LOG_TAG,
                "AUDIO_EXT 已挂 FFmpeg 音轨渲染器（优先级=系统硬解之后）status=${FxAudioExt.status()}",
            )
        } catch (error: Throwable) {
            FxAudioExt.disable("构造 FfmpegAudioRenderer 失败: ${error.javaClass.simpleName}")
            Log.w(
                ExoPlayerPlugin.LOG_TAG,
                "AUDIO_EXT 挂载失败（${error.javaClass.simpleName}: ${error.message}），" +
                    "继续用系统解码器",
            )
        }
    }
}

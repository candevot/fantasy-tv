package com.huanxiang.fantasy_tv

import android.util.Log
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import java.util.Locale
import java.util.concurrent.atomic.AtomicLong

/**
 * 实时网速（NET_SPEED 2026-11-15）。
 *
 * 用户实测「缓冲时转圈下面一直显示 0 KB/s」：字节数其实一直在涨，坏的是
 * **速率**这一层。原来的写法把自己数出来的字节塞进 `PlayerHttp.bytesPerSec()`
 * 的「窗口起点快照」里，两个变量共用一个计数器 —— 窗口起点跟着总量一起涨，
 * 增量永远是 0，于是界面上永远是「0 KB/s」（[PlayerHttp] 里已一并修正）。
 *
 * 现在的分工（这里的数字就是界面上的数字）：
 *   · **字节来源优先用 media3 官方回调**：
 *       1. [transferListener]：播放器数据源自身的 `onBytesTransferred`
 *          （`OkHttpDataSource` 每读到一块就回调一次），按块、最实时；
 *       2. 兜底 `PlayerHttp.bytesLoaded()`：同一个 OkHttpClient 上的计数拦截器，
 *          两路都只增不减，取较大者不会重复计数。
 *     为什么不用 `ExoPlayer.getTotalBytesRead()`：本项目锁的是 media3 1.4.1，
 *     这一版的 `ExoPlayer` 接口还没有这个方法（1.6+ 才有），所以用上面两个
 *     官方入口拼出等价的累计字节。
 *   · **速率**：主线程每 ≥400ms 算一次「距上次的字节增量 ÷ 实际经过时间」，
 *     得到真实 B/s；一个窗口内一个字节都没收到就归 0（暂停 / 卡死立刻显示
 *     0 KB/s，不保留上一个数）。这时如果官方带宽估算（[onBandwidthEstimate]）
 *     是 2 秒内的新鲜值，就用它兜一下 —— 它是 media3 自己的 `BandwidthMeter`
 *     在测，比界面瞎猜可信。
 *   · **日志**：每秒最多一行 `[FxNet] bytes=+1234567/s (1.2 MB/s)`，
 *     `adb logcat -s FxExo` 能直接看到网速在动。
 *
 * 只做统计：不改任何播放 / 缓冲行为，也不在主线程做重活。
 */
object FxNet {

    /**
     * 和 `ExoPlayerPlugin.LOG_TAG` 取同一个标签：`adb logcat -s FxExo` 一起看。
     *
     * 这里写字面量而不是引用它，是为了让 [FxNet] 不依赖播放器插件，
     * 单独（单测 / 本机 JVM 验证）也能编译运行。
     */
    private const val LOG_TAG = "FxExo"

    /**
     * 速率窗口下限：400ms。
     *
     * Dart 侧 250ms 轮询一次快照、原生每秒再主动推一次；窗口压到 400ms 以下
     * 只是在放大抖动（每个窗口只有一两块数据），算出来的数字会乱跳。
     */
    private const val MIN_WINDOW_NS = 400_000_000L

    /** 官方带宽估算的有效期：2 秒（更久说明早就没有下载在跑了）。 */
    private const val ESTIMATE_TTL_NS = 2_000_000_000L

    /** `[FxNet]` 日志节流：约 1 秒一行。 */
    private const val LOG_INTERVAL_NS = 900_000_000L

    /** 播放器数据源交付的字节（本次 open 起累计，只增不减）。 */
    private val bytes = AtomicLong(0)

    /** 官方带宽估算（B/s，已由 bit/s 换算）与它的时间戳。 */
    private val estimateBytesPerSec = AtomicLong(0)

    private val estimateAtNs = AtomicLong(0)

    private var windowBytes = -1L

    private var windowAtNs = 0L

    private var rate = 0L

    private var lastLogAtNs = 0L

    private var lastLoggedRate = 0L

    /**
     * media3 官方按块回调（挂在播放数据源的 `OkHttpDataSource.Factory` 上，
     * 见 [PlayerHttp.httpFactory]）。
     *
     * `onBytesTransferred` 每读到一块就回调，慢网下一个分片要下十几秒时，
     * 界面上仍然看得到数字在动 —— 这正是原来「缓冲时恒 0」要解决的问题。
     */
    val transferListener: TransferListener = object : TransferListener {
        override fun onTransferInitializing(
            source: DataSource,
            dataSpec: DataSpec,
            isNetwork: Boolean,
        ) = Unit

        override fun onTransferStart(
            source: DataSource,
            dataSpec: DataSpec,
            isNetwork: Boolean,
        ) = Unit

        override fun onBytesTransferred(
            source: DataSource,
            dataSpec: DataSpec,
            isNetwork: Boolean,
            byteCount: Int,
        ) {
            onBytes(byteCount.toLong())
        }

        override fun onTransferEnd(
            source: DataSource,
            dataSpec: DataSpec,
            isNetwork: Boolean,
        ) = Unit
    }

    /** 累加真实收到的字节（数据源回调与单测都走这里）。 */
    fun onBytes(count: Long) {
        if (count > 0L) bytes.addAndGet(count)
    }

    /**
     * 官方带宽估算（`AnalyticsListener.onBandwidthEstimate`，单位 bit/s）。
     *
     * 只当作「这一窗口没数到字节」时的兜底，过期不用 —— 否则暂停之后界面
     * 还会挂着一个旧数字。
     */
    fun onBandwidthEstimate(bitrateEstimate: Long) {
        if (bitrateEstimate <= 0L) return
        estimateBytesPerSec.set(bitrateEstimate / 8L)
        estimateAtNs.set(System.nanoTime())
    }

    /** 本次 open 至今数据源交付的字节数（官方回调口径）。 */
    fun bytes(): Long = bytes.get()

    /** 两路字节取较大者：都是只增不减的累计值，max 不会重复计数。 */
    fun totalBytes(): Long = maxOf(bytes.get(), PlayerHttp.bytesLoaded())

    /** 2 秒内的官方带宽估算（B/s）；过期或没有就是 0。 */
    fun freshEstimateBytesPerSec(): Long {
        val at = estimateAtNs.get()
        if (at == 0L) return 0L
        return if (System.nanoTime() - at <= ESTIMATE_TTL_NS) estimateBytesPerSec.get() else 0L
    }

    /** 新的一次 open：全部归零（和 [PlayerHttp.resetConnectCount] 一起调）。 */
    @Synchronized
    fun reset() {
        bytes.set(0)
        estimateBytesPerSec.set(0)
        estimateAtNs.set(0)
        windowBytes = -1L
        windowAtNs = 0L
        rate = 0L
        lastLogAtNs = 0L
        lastLoggedRate = 0L
    }

    /**
     * 当前实时网速（字节/秒）；0 就是这一窗口真的没收到字节。
     *
     * [total] 默认取 [totalBytes]，单测可以显式喂一个累计值。
     */
    @Synchronized
    fun speedPerSec(total: Long = totalBytes()): Int {
        val now = System.nanoTime()
        if (windowBytes < 0L || total < windowBytes) {
            // 第一帧 / 换源归零之后：只记起点，不编数字。
            windowBytes = total
            windowAtNs = now
            rate = 0L
            return 0
        }
        val elapsed = now - windowAtNs
        if (elapsed < MIN_WINDOW_NS) return clamp(rate)
        val delta = total - windowBytes
        windowBytes = total
        windowAtNs = now
        // 这一窗口没字节 = 暂停 / 卡死，立刻归 0（不留上一个数）。
        var next = if (delta <= 0L || elapsed <= 0L) 0L else delta * 1_000_000_000L / elapsed
        if (next <= 0L) next = freshEstimateBytesPerSec()
        rate = next.coerceAtLeast(0L)
        logIfDue(now)
        return clamp(rate)
    }

    /** 每秒最多一行；从「有速度」掉到 0 时补一行，之后不再刷屏。 */
    private fun logIfDue(now: Long) {
        if (now - lastLogAtNs < LOG_INTERVAL_NS) return
        if (rate <= 0L && lastLogAtNs != 0L && lastLoggedRate <= 0L) return
        lastLogAtNs = now
        lastLoggedRate = rate
        Log.i(LOG_TAG, "[FxNet] bytes=+$rate/s (${pretty(rate)})")
    }

    /** `1.8 MB/s` / `320 KB/s` / `0 KB/s`（和 Dart 侧 `fxSpeedLabel` 同一套写法）。 */
    fun pretty(bytesPerSec: Long): String = when {
        bytesPerSec <= 0L -> "0 KB/s"
        bytesPerSec >= 1024L * 1024L ->
            String.format(Locale.US, "%.1f MB/s", bytesPerSec / 1048576.0)
        bytesPerSec >= 1024L -> "${bytesPerSec / 1024} KB/s"
        else -> String.format(Locale.US, "%.1f KB/s", bytesPerSec / 1024.0)
    }

    private fun clamp(value: Long): Int =
        if (value > Int.MAX_VALUE) Int.MAX_VALUE else if (value < 0L) 0 else value.toInt()
}

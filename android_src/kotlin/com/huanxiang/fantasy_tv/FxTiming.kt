package com.huanxiang.fantasy_tv

import android.util.Log

/**
 * 起播分段计时（TIMING_PROBE 2026-11-15）。
 *
 * 为什么要它：用户反馈「比影视壳慢」，但我们之前只能看到 FATAL / FIRST_FRAME
 * 这种孤立的点，**没有一条串起来的时间线**，于是每轮优化都靠猜。这里按
 * 「用户点播放」这一下 t=0，把起播拆成几段打点：
 *
 * ```
 * adb logcat -s FxTiming
 * t=0 resolve_start              （Dart 侧开始解析 hxparse / /api/play）
 * t=180ms resolve_done           （拿到最终地址，open 之前的耗时）
 * t=180ms open_req               （进入原生 open）
 * t=240ms manifest_merged        （清单就绪：master 已归并/已拿到媒体清单）
 * t=243ms prepare_called         （setMediaSource + prepare）
 * t=980ms first_frame            （onRenderedFirstFrame）
 * t=1005ms audio_started
 * connects=1
 * total=980ms
 * ```
 *
 * 口径：**除了 resolve_done 之外，所有 t 都从「用户点播放」算起**（已包含
 * Dart 解析那一段），这样跟壳的「首帧 1 秒」可以直接比 —— 用户看到的差异
 * 本来就在同一条时间线上。相对 open 入口的耗时 = t - resolve 的耗时。
 *
 * 线程：打点会从主线程（prepare / 首帧）、FxManifest 线程（清单）、
 * 本地代理线程（清单就绪）调进来，全部走 [lock] 串行，内部无阻塞操作。
 * 快照 ([summary]) 同时被塞进 EventChannel 的 state map，Dart 的诊断浮层
 * 和 logcat 看到的是同一份数字。
 */
object FxTiming {

    /** logcat 过滤标签：`adb logcat -s FxTiming`。 */
    const val TAG = "FxTiming"

    private val lock = Any()

    /** 第几次 open（换集 / 换线路 / 重试都会 +1），Dart 侧用它判断是否换了新时间线。 */
    private var session = 0

    /** Dart 侧解析阶段耗时（毫秒），作为时间线的第一段。 */
    private var preOpenMs = 0L

    /** t=0 的锚点（System.nanoTime，单调时钟，不受系统改时间影响）。 */
    private var anchorNanos = 0L

    /** 已打的点：name -> 距「点播放」的毫秒数。 */
    private val marks = LinkedHashMap<String, Long>()

    /** total 是否已经打过（避免重复刷）。 */
    private var finished = false

    /**
     * 开一条新的时间线。
     *
     * [resolveMs] 由 Dart 传入：它在调原生 `open` 之前已经把地址解析完了
     * （hxparse 302 / 换签名），那段时间也要算进用户等待里。
     */
    fun begin(url: String, resolveMs: Long) {
        synchronized(lock) {
            session += 1
            preOpenMs = if (resolveMs > 0) resolveMs else 0L
            anchorNanos = System.nanoTime()
            marks.clear()
            finished = false
            marks["resolve_done"] = preOpenMs
            marks["open_req"] = preOpenMs
            val label = shortUrl(url)
            line("t=0 resolve_start url=$label")
            line("t=${preOpenMs}ms resolve_done（Dart 侧拿到最终地址）")
            line("t=${preOpenMs}ms open_req url=$label")
        }
    }

    /** 打一个点（同名只记第一次：清单/首帧在重试时会重复回调）。 */
    fun mark(name: String) {
        synchronized(lock) {
            if (anchorNanos == 0L || marks.containsKey(name)) return
            val ms = nowMsLocked()
            marks[name] = ms
            line("t=${ms}ms $name")
        }
    }

    /**
     * 起播结束：打出连接数 + 总耗时（每次 open 只打一次）。
     *
     * [connects] 是 OkHttp `connectStart` 计数 —— 壳起播是 1 条（清单那条，
     * 之后分片全复用）；我们之前每次 302 换域都要重建 TCP + TLS，这个数
     * 会明显大于 1，是排查「DNS / 连接复用」问题的第一现场。
     */
    fun finish(connects: Int) {
        synchronized(lock) {
            if (anchorNanos == 0L || finished) return
            finished = true
            val total = totalMsLocked()
            line("connects=$connects")
            line("total=${total}ms（含解析 ${preOpenMs}ms）")
        }
    }

    /** 某个点相对「点播放」的毫秒数；-1 = 还没到。 */
    fun value(name: String): Long {
        synchronized(lock) {
            return marks[name] ?: -1L
        }
    }

    /**
     * 给 Dart 诊断浮层用的快照（塞进 state map 的 `timing` 键）。
     *
     * 全部是「距点播放」的毫秒数，-1 = 还没到；`totalMs` 在首帧未到时
     * 返回「到现在为止」，这样浮层上的数字会自己往上涨，用户能看出在等。
     */
    fun summary(): Map<String, Any?> {
        synchronized(lock) {
            val firstFrame = marks["first_frame"] ?: -1L
            val total = if (firstFrame >= 0) firstFrame else totalMsLocked()
            val out = LinkedHashMap<String, Any?>()
            out["session"] = session
            out["resolveMs"] = preOpenMs.toInt()
            out["openMs"] = preOpenMs.toInt()
            out["manifestMs"] = (marks["manifest_merged"] ?: -1L).toInt()
            out["prepareMs"] = (marks["prepare_called"] ?: -1L).toInt()
            out["firstFrameMs"] = firstFrame.toInt()
            out["audioMs"] = (marks["audio_started"] ?: -1L).toInt()
            out["totalMs"] = total.toInt()
            return out
        }
    }

    /** 当前时间线已经过了多少毫秒（含解析段）。 */
    fun elapsedMs(): Long {
        synchronized(lock) {
            return totalMsLocked()
        }
    }

    // ------------------------------------------------------------ 内部

    /** 从「点播放」到现在过了多少毫秒（解析段 + open 之后的时间）。 */
    private fun totalMsLocked(): Long = nowMsLocked()

    /** 距锚点（open 入口）的毫秒数。 */
    private fun elapsedSinceAnchorLocked(): Long {
        if (anchorNanos == 0L) return 0L
        val delta = System.nanoTime() - anchorNanos
        return if (delta <= 0L) 0L else delta / 1_000_000L
    }

    /** 「距点播放」的毫秒数 = 解析段 + 距锚点。 */
    private fun nowMsLocked(): Long = preOpenMs + elapsedSinceAnchorLocked()

    private fun line(message: String) {
        Log.i(TAG, message)
    }

    /** 日志里的地址截断：保留域名 + 前 48 字符，够定位又不刷屏。 */
    private fun shortUrl(url: String): String {
        val text = url.trim()
        if (text.length <= 96) return text
        return text.substring(0, 96) + "…"
    }
}

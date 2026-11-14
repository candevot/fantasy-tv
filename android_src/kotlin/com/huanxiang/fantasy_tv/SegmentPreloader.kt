package com.huanxiang.fantasy_tv

import android.content.Context
import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.SimpleCache
import java.io.ByteArrayOutputStream
import java.net.URI
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * HLS 分片预取器（按逆向报告 §10 改动 2）。
 *
 * 对方 App 的做法（VideoPreloader + SmartSegmentDownloader）里，真正决定
 * 「拖动秒加载」的是四条：
 *   1. 预取线程随播放器创建就起，不加延迟（START_DELAY_MS = 0）；
 *   2. **并发 = 1**（newSingleThreadExecutor），宁可串行也不并发，
 *      避免和服务端限速 / 播放器抢带宽；
 *   3. seek 用**代际号**作废旧任务：generation++ 之后旧循环每次迭代都会
 *      发现自己过期并立刻退出，新任务从目标分片向后绕环继续灌；
 *   4. 预取和播放器写**同一份** SimpleCache（同一个 cacheKey），所以
 *      「预取过的分片」在播放器看来就是缓存命中，完全不产生网络等待。
 *
 * 我们照做，但失败策略按自己的情况收紧：重试 3 次、间隔 2 秒、64KB 读缓冲
 * （BUFFER_SIZE / MAX_RETRIES / RETRY_DELAY_MS 三个取值与对方一致）。
 */
@OptIn(UnstableApi::class)
class SegmentPreloader(
    private val context: Context,
    private val cache: SimpleCache,
    private val log: (String) -> Unit = {},
) {

    companion object {
        /** 单片读缓冲：64KB（对方取值）。 */
        const val BUFFER_SIZE = 64 * 1024

        /** 单片最多重试几次。 */
        const val MAX_RETRIES = 3

        /** 两次重试之间的间隔。 */
        const val RETRY_DELAY_MS = 2000L

        /** 清单正文上限，防止被超大响应拖死。 */
        private const val MAX_PLAYLIST_BYTES = 8 * 1024 * 1024

        /** 单集分片数上限（4K 长片也就 500~1500 片）。 */
        private const val MAX_SEGMENTS = 4000
    }

    /** 一个分片：地址 + 在时间轴上的起点与时长。 */
    private class Segment(val uri: String, val startMs: Long, val durationMs: Long)

    /** 单线程执行器：并发度 = 1，和对方一致。 */
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "PreloaderHls").also { it.isDaemon = true }
    }

    private val generationLock = Any()

    /** 预取代际：每次换源 / seek 都 +1，旧任务据此自我作废。 */
    private var generation = 0

    @Volatile
    private var segments: List<Segment> = emptyList()

    /** 已经落盘的分片标记（index 与 [segments] 对齐）。 */
    @Volatile
    private var cachedFlags: BooleanArray = BooleanArray(0)

    @Volatile
    private var requestHeaders: Map<String, String> = emptyMap()

    @Volatile
    private var released = false

    init {
        // 线程随播放器创建就拉起来（不等 open / prepare / 用户点播放）。
        // 空任务只是让单线程执行器建出 "PreloaderHls" 这条线程。
        executor.execute { }
    }

    /**
     * 拿到播放地址后立刻开始灌缓存。
     *
     * 播放器一创建本类就存在，这里只是把「源」交进来：线程池在构造时就建好了，
     * 所以预取随播放器创建即启动，不等 prepare 完成（对应 START_DELAY_MS = 0）。
     */
    fun start(playlistUrl: String, headers: Map<String, String>) {
        if (released || playlistUrl.isEmpty()) return
        requestHeaders = headers
        val generationAtStart = nextGeneration()
        executor.execute {
            val list = loadSegments(playlistUrl, headers)
            if (list.isEmpty()) {
                log("预取: 清单没有可播分片，跳过（$playlistUrl）")
                return@execute
            }
            synchronized(generationLock) {
                // 期间又换了源 / seek 过：这一轮直接作废。
                if (generationAtStart != generation) return@execute
                segments = list
                cachedFlags = BooleanArray(list.size)
            }
            log("预取: ${list.size} 片，从第 0 片开始顺序灌缓存")
            downloadFrom(0, generationAtStart, headers)
        }
    }

    /**
     * seek 改道：作废当前代际，从目标分片起向后绕环继续灌。
     *
     * 和对方一致：**已落盘的分片不删**（回拖靠磁盘命中），只是不再排队
     * 「目标位置之前」的任务。
     */
    fun seekTo(positionMs: Long) {
        if (released || segments.isEmpty()) return
        val generationAtSeek = nextGeneration()
        val startIndex = findIndex(positionMs)
        val headers = requestHeaders
        executor.execute {
            log("预取: seek 改道到 ${positionMs}ms（第 $startIndex 片）")
            downloadFrom(startIndex, generationAtSeek, headers)
        }
    }

    /**
     * 从 [positionMs] 起连续已缓存到哪一刻（毫秒）。
     *
     * 播放器的 buffered 进度条取 max(Exo buffered, 这个值) —— 用户看到的
     * 灰条就是「已经下到磁盘的段」，而不是解码器缓冲。
     */
    fun continuousCachedMs(positionMs: Long): Long {
        val list = segments
        val flags = cachedFlags
        if (list.isEmpty() || flags.size != list.size) return 0L
        val index = findIndex(positionMs)
        if (index < 0 || index >= list.size || !flags[index]) return 0L
        var end = list[index].startMs + list[index].durationMs
        var i = index + 1
        while (i < list.size && flags[i]) {
            end = list[i].startMs + list[i].durationMs
            i++
        }
        return end
    }

    /** 释放：作废所有代际并停线程。 */
    fun release() {
        released = true
        nextGeneration()
        executor.shutdownNow()
    }

    private fun nextGeneration(): Int {
        synchronized(generationLock) {
            generation++
            return generation
        }
    }

    // ------------------------------------------------------------ 下载循环

    private fun downloadFrom(
        startIndex: Int,
        generationAtStart: Int,
        headers: Map<String, String>,
    ) {
        val list = segments
        if (list.isEmpty()) return
        val factory = cacheDataSourceFactory(headers)
        val buffer = ByteArray(BUFFER_SIZE)
        for (step in 0 until list.size) {
            // 每片之前检查代际：旧任务立刻退出（对方 generation++ 的语义）。
            if (generationAtStart != generation) return
            val index = (startIndex + step) % list.size
            val flags = cachedFlags
            if (index < flags.size && flags[index]) continue
            if (downloadSegment(factory, list[index], generationAtStart, buffer)) {
                val target = cachedFlags
                if (index < target.size) target[index] = true
            }
        }
    }

    private fun downloadSegment(
        factory: DataSource.Factory,
        segment: Segment,
        generationAtStart: Int,
        buffer: ByteArray,
    ): Boolean {
        for (attempt in 1..MAX_RETRIES) {
            if (generationAtStart != generation) return false
            var source: DataSource? = null
            try {
                source = factory.createDataSource()
                source.open(DataSpec(Uri.parse(segment.uri)))
                while (true) {
                    if (generationAtStart != generation) return false
                    val read = source.read(buffer, 0, buffer.size)
                    if (read == -1) break
                }
                return true
            } catch (error: Throwable) {
                log("预取: 第 $attempt 次失败 ${segment.startMs}ms ${error.javaClass.simpleName}")
                if (attempt < MAX_RETRIES) {
                    try {
                        Thread.sleep(RETRY_DELAY_MS)
                    } catch (_: InterruptedException) {
                        return false
                    }
                }
            } finally {
                try {
                    source?.close()
                } catch (_: Throwable) {
                    // 关闭失败不影响结果
                }
            }
        }
        return false
    }

    private fun cacheDataSourceFactory(headers: Map<String, String>): DataSource.Factory {
        val upstream = DefaultDataSource.Factory(context, httpFactory(headers))
        return CacheDataSource.Factory()
            .setCache(cache)
            .setUpstreamDataSourceFactory(upstream)
            // 缓存坏了就忽略、直接回源，别让预取卡死
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
    }

    private fun httpFactory(headers: Map<String, String>): DefaultHttpDataSource.Factory {
        return DefaultHttpDataSource.Factory()
            .setUserAgent(headers["User-Agent"] ?: "Mozilla/5.0")
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(15_000)
            .setReadTimeoutMs(20_000)
            .setDefaultRequestProperties(headers)
    }

    // ------------------------------------------------------------ 清单解析

    private fun loadSegments(playlistUrl: String, headers: Map<String, String>): List<Segment> {
        val body = fetchText(playlistUrl, headers) ?: return emptyList()
        if (body.isEmpty()) return emptyList()
        // master playlist：取第一个变体，再解析它的媒体 playlist。
        val variant = firstVariant(body, playlistUrl)
        if (variant != null) {
            val sub = fetchText(variant, headers) ?: return emptyList()
            return parseMediaPlaylist(sub, variant)
        }
        return parseMediaPlaylist(body, playlistUrl)
    }

    private fun fetchText(url: String, headers: Map<String, String>): String? {
        val source = httpFactory(headers).createDataSource()
        return try {
            source.open(DataSpec(Uri.parse(url)))
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(BUFFER_SIZE)
            while (true) {
                val read = source.read(buffer, 0, buffer.size)
                if (read == -1) break
                out.write(buffer, 0, read)
                if (out.size() >= MAX_PLAYLIST_BYTES) break
            }
            out.toString("UTF-8")
        } catch (error: Throwable) {
            log("预取: 清单拉取失败 ${error.javaClass.simpleName}")
            null
        } finally {
            try {
                source.close()
            } catch (_: Throwable) {
                // 关闭失败不影响结果
            }
        }
    }

    /** 解析 `#EXTINF` 累加出每片的起点（和 Java 侧 parseMediaPlaylist 同款做法）。 */
    private fun parseMediaPlaylist(body: String, base: String): List<Segment> {
        val raw = body.split("\n")
        val out = ArrayList<Segment>()
        var startMs = 0L
        var pendingMs = 0L
        for (line in raw) {
            val text = line.trim()
            if (text.isEmpty()) continue
            if (text.startsWith("#EXTINF:")) {
                val value = text.substring(8)
                val comma = value.indexOf(',')
                val seconds = (if (comma >= 0) value.substring(0, comma) else value).trim()
                pendingMs = ((seconds.toDoubleOrNull() ?: 0.0) * 1000).toLong()
                continue
            }
            if (text.startsWith("#")) continue
            out.add(Segment(resolve(base, text), startMs, pendingMs))
            startMs += pendingMs
            pendingMs = 0L
            if (out.size >= MAX_SEGMENTS) break
        }
        return out
    }

    private fun firstVariant(body: String, base: String): String? {
        val lines = body.split("\n")
        for (i in lines.indices) {
            if (!lines[i].trim().startsWith("#EXT-X-STREAM-INF")) continue
            for (j in i + 1 until lines.size) {
                val text = lines[j].trim()
                if (text.isEmpty() || text.startsWith("#")) continue
                return resolve(base, text)
            }
        }
        return null
    }

    private fun resolve(base: String, reference: String): String {
        return try {
            URI(base).resolve(reference).toString()
        } catch (_: Throwable) {
            reference
        }
    }

    /** 二分：起点 <= positionMs 的最后一片。 */
    private fun findIndex(positionMs: Long): Int {
        val list = segments
        if (list.isEmpty()) return 0
        if (positionMs < list[0].startMs) return 0
        var lo = 0
        var hi = list.size - 1
        var hit = 0
        while (lo <= hi) {
            val mid = (lo + hi) / 2
            if (list[mid].startMs <= positionMs) {
                hit = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return hit
    }
}

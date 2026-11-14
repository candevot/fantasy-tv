package com.huanxiang.fantasy_tv

import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.cache.CacheDataSink
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.SimpleCache
import java.io.ByteArrayOutputStream
import java.net.URI
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * 下一集预载（改动 ⑥）。
 *
 * 目标：**只写不读**地把「下一集的清单 + 前 N 个分片」灌进播放器同一份
 * [SimpleCache]，等用户真的切集时，播放器的第一批分片请求就是本地命中，
 * 切集不再从零开始回源。
 *
 * 为什么单独一个类、而不是塞进 [SegmentPreloader]：
 *   · [SegmentPreloader] 服务「正在播的这一集」，它的 `segments` / 代际号
 *     被播放页的 seek 反复改写；下一集是**另一条清单**，两者混在一起会互相
 *     作废（seek 一次就把下一集预载打断，换集又打断当前集的预取）；
 *   · 这个预载器的生命周期跟着「当前这一集」走：换集 / 换线路 / 释放播放器
 *     就整轮取消（[cancel]），不需要和播放代际号纠缠。
 *
 * 和播放器的关系（三条硬约束）：
 *   1. 优先级：播放器 BUFFERING 时不出手（[pauseGate]，和 [SegmentPreloader]
 *      同一个思路 —— 壳用 media3 的 PriorityTaskManager 达到同样效果）；
 *   2. 只写不读：预载下来的字节只进磁盘缓存，绝不参与当前播放；
 *   3. 失败静默：任何异常只留一行 logcat，播放完全不受影响。
 *
 * 传输层：**和播放路径同一条**（[PlayerHttp.httpFactory] → OkHttpDataSource，
 * 同一个 OkHttpClient 连接池）。这里不再自己造 DefaultHttpDataSource ——
 * 预载走另一套 HTTP 栈的话，UA / trust-all / 连接复用 / HTTP2 全都会和播放
 * 路径不一致，CDN 那边就是两副面孔。
 */
@OptIn(UnstableApi::class)
class NextEpisodePreloader(
    private val cache: SimpleCache,
    /**
     * 上游数据源工厂：(url, 请求头) → DataSource.Factory。
     *
     * 由 ExoPlayerPlugin 注入 `PlayerHttp::httpFactory`：传输层怎么改，
     * 预载就怎么走，本文件不认识具体实现。
     */
    private val upstreamFactory: (String, Map<String, String>) -> DataSource.Factory,
    /** 让路判据：返回 true 时预载原地等待（播放器正在缓冲）。 */
    private val pauseGate: () -> Boolean = { false },
    private val log: (String) -> Unit = {},
) {

    companion object {
        /** 预载前几个分片（需求：前 2 个）。 */
        const val DEFAULT_SEGMENTS = 2

        /** 单片读缓冲：和 [SegmentPreloader.BUFFER_SIZE] 同一档。 */
        private const val BUFFER_SIZE = 64 * 1024

        /** 清单正文上限：下一集清单再长也就几百 KB，防止被超大响应拖死。 */
        private const val MAX_PLAYLIST_BYTES = 2 * 1024 * 1024

        /** 单片上限：只预载前几片，单片刻意封顶，避免 4K 大分片吃掉整轮预算。 */
        private const val MAX_SEGMENT_BYTES = 16L * 1024 * 1024

        /** 让路轮询间隔（和 SegmentPreloader 一致）。 */
        private const val GATE_POLL_MS = 150L
    }

    private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "FxNextPre").also { it.isDaemon = true }
    }

    private val lock = Any()

    /** 轮次号：每次 [preload] / [cancel] 都 +1，旧任务据此自我作废。 */
    private var generation = 0

    @Volatile
    private var released = false

    /**
     * 开始预载 [playlistUrl] 对应的下一集。
     *
     * 入队即返回（真正的下载在自己的单线程里跑），失败静默。
     */
    fun preload(playlistUrl: String, headers: Map<String, String>) {
        if (released || playlistUrl.isEmpty()) return
        val generationAtStart = nextGeneration()
        executor.execute {
            try {
                runPreload(playlistUrl, headers, generationAtStart)
            } catch (error: Throwable) {
                // 预载失败不影响播放：播放器那头回源兜底。
                log("preload next: 失败 ${error.javaClass.simpleName}")
            }
        }
    }

    /** 取消当前这一轮（换集 / 换线路 / 释放播放器时调用）。 */
    fun cancel() {
        if (released) return
        nextGeneration()
    }

    fun release() {
        released = true
        nextGeneration()
        executor.shutdownNow()
    }

    private fun nextGeneration(): Int = synchronized(lock) {
        generation++
        generation
    }

    private fun isStale(generationAtStart: Int): Boolean =
        released || generationAtStart != generation

    // ------------------------------------------------------------- 主流程

    private fun runPreload(playlistUrl: String, headers: Map<String, String>, gen: Int) {
        log("preload next: 开始 $playlistUrl")
        val body = fetchText(playlistUrl, headers, gen) ?: return
        if (isStale(gen)) return
        // master playlist：取第一个变体，再拿它的媒体清单。
        val variant = firstVariant(body, playlistUrl)
        val media = if (variant != null) {
            if (isStale(gen)) return
            fetchText(variant, headers, gen) ?: return
        } else {
            body
        }
        val base = variant ?: playlistUrl
        val segments = parseSegments(media, base, DEFAULT_SEGMENTS)
        if (segments.isEmpty()) {
            log("preload next: 清单里没有分片，跳过")
            return
        }
        var written = 0
        for (uri in segments) {
            if (isStale(gen)) {
                log("preload next: 已取消（换集 / 换线路），已写入 $written 片")
                return
            }
            // PRIORITY：播放器正在缓冲就让路，先不占连接 / 带宽。
            if (!awaitPlaybackIdle(gen)) {
                log("preload next: 让路期间被取消，已写入 $written 片")
                return
            }
            if (downloadToCache(uri, headers, gen)) written++
        }
        log("preload next: 完成 ${written}/${segments.size} 片写入缓存")
    }

    /**
     * 播放器在缓冲时等待，直到它不缺数据（或本轮被取消）。
     * 返回 false = 这一轮已经过期，调用方直接退出。
     */
    private fun awaitPlaybackIdle(gen: Int): Boolean {
        if (!pauseGate()) return !isStale(gen)
        log("preload next: 播放器正在缓冲，让路")
        while (pauseGate()) {
            if (isStale(gen)) return false
            try {
                Thread.sleep(GATE_POLL_MS)
            } catch (_: InterruptedException) {
                return false
            }
        }
        return !isStale(gen)
    }

    // ------------------------------------------------------------ 写缓存

    /**
     * 把一整个分片写进共享缓存（**只写不读**）。
     *
     * 走 CacheDataSource + 写 sink：读的时候顺手经 CacheDataSink 落盘，
     * cacheKey 由 [FxCacheKeyFactory] 算 —— 和播放器 / [SegmentPreloader]
     * 完全同一套 key，所以切集时播放器请求同一片就是本地命中。
     */
    private fun downloadToCache(uri: String, headers: Map<String, String>, gen: Int): Boolean {
        var source: DataSource? = null
        try {
            val factory = CacheDataSource.Factory()
                .setCache(cache)
                .setUpstreamDataSourceFactory(upstreamFactory(uri, headers))
                .setCacheKeyFactory(FxCacheKeyFactory)
                // 缓存坏了就忽略、直接回源，别让预载卡死。
                .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
                .setCacheWriteDataSinkFactory(
                    CacheDataSink.Factory().setCache(cache)
                )
            val stream = factory.createDataSource()
            source = stream
            stream.open(DataSpec(Uri.parse(uri)))
            val buffer = ByteArray(BUFFER_SIZE)
            var total = 0L
            while (true) {
                if (isStale(gen)) return false
                val read = stream.read(buffer, 0, buffer.size)
                if (read == -1) break
                total += read
                if (total >= MAX_SEGMENT_BYTES) break
            }
            log("preload next: 写入 ${total}B ${uri.substringAfterLast('/')}")
            return total > 0
        } catch (error: Throwable) {
            log("preload next: 分片失败 ${error.javaClass.simpleName}")
            return false
        } finally {
            try {
                source?.close()
            } catch (_: Throwable) {
                // 关闭失败不影响结果
            }
        }
    }

    // ------------------------------------------------------------ 清单解析

    /** 拉清单正文（只预载前几片，清单本身给 2MB 上限就够）。 */
    private fun fetchText(url: String, headers: Map<String, String>, gen: Int): String? {
        if (isStale(gen)) return null
        var source: DataSource? = null
        return try {
            val stream = upstreamFactory(url, headers).createDataSource()
            source = stream
            stream.open(DataSpec(Uri.parse(url)))
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(BUFFER_SIZE)
            while (true) {
                if (isStale(gen)) return null
                val read = stream.read(buffer, 0, buffer.size)
                if (read == -1) break
                out.write(buffer, 0, read)
                if (out.size() >= MAX_PLAYLIST_BYTES) break
            }
            out.toString("UTF-8")
        } catch (error: Throwable) {
            log("preload next: 清单拉取失败 ${error.javaClass.simpleName}")
            null
        } finally {
            try {
                source?.close()
            } catch (_: Throwable) {
                // 关闭失败不影响结果
            }
        }
    }

    /** 取前 [limit] 个分片（`#EXTINF` 之后的那一行）。 */
    private fun parseSegments(body: String, base: String, limit: Int): List<String> {
        val out = ArrayList<String>(limit)
        var pendingInf = false
        for (raw in body.split("\n")) {
            val text = raw.trim()
            if (text.isEmpty()) continue
            if (text.startsWith("#EXTINF:")) {
                pendingInf = true
                continue
            }
            if (text.startsWith("#")) continue
            if (!pendingInf) continue
            out.add(resolve(base, text))
            if (out.size >= limit) break
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

    private fun resolve(base: String, reference: String): String = try {
        URI(base).resolve(reference).toString()
    } catch (_: Throwable) {
        reference
    }
}

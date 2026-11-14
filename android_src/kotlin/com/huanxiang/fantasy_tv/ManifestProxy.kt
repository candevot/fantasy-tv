package com.huanxiang.fantasy_tv

import android.util.Log
import okhttp3.Request
import okhttp3.Response
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * HLS 清单本地代理（MANIFEST_PROXY 2026-11-15）—— 壳同款，但只做清单。
 *
 * 壳（OK影视 / FongMi）把 `.m3u8` 改写成 `127.0.0.1:PORT/m3u8?url=…`，在
 * 本地端口里做四件事：相对地址绝对化、master 变体合并、去广告段、预取。
 * 我们之前是「交给 ExoPlayer 自己跟跳」+ 一个**阻塞式**的清单预归并：
 *
 *   open → [最多 800ms 等 master 抓完] → prepare → 播放器再抓 variant → 首片
 *
 * 那条路径上，清单那两跳全都在起播关键路径里，而且是我们**先等**再开播。
 * 换成代理之后：
 *
 *   open → 本地地址 + prepare（**零网络**）→ 播放器 GET 127.0.0.1（毫秒级）
 *        → 代理内部并行/缓存地抓 master → variant → 一次返回最终清单
 *
 * 同时把「master 只有一条变体」的情况在代理里合并掉：播放器拿到的直接是
 * 媒体清单，少一跳解析和一次 setMediaSource 之后的重新选择。
 *
 * 三条硬约束（任何一条破了就退回原始地址，播放行为和改造前一致）：
 *   1. **只服务本机**：ServerSocket 绑 127.0.0.1，不对外网卡开放；
 *   2. 抓不到清单就回 302 到原始地址，让播放器自己跟（media3 的
 *      OkHttpDataSource 会跟随重定向，分片地址也按最终 URL 解析）；
 *   3. 分片仍然直连 CDN（只改写绝对地址、不中转字节），
 *      否则等于把所有流量压到一条 Java 线程上，反而更慢。
 */
object ManifestProxy {

    /** 和 [ExoPlayerPlugin.LOG_TAG] 同一个标签：`adb logcat -s FxExo`。 */
    private const val LOG_TAG = "FxExo"

    /** 清单正文上限（master / 媒体清单都是几十 KB，4MB 已经离谱）。 */
    private const val MAX_BODY_BYTES = 4 * 1024 * 1024

    /** 缓存时长：点播清单（带 #EXT-X-ENDLIST）不会变，可以留久一点。 */
    private const val VOD_TTL_MS = 120_000L

    /** 直播清单每次都变，只能极短缓存（够播放器和预取撞在同一次上即可）。 */
    private const val LIVE_TTL_MS = 1_000L

    /** master 清单（变体表）变化很慢。 */
    private const val MASTER_TTL_MS = 60_000L

    /** 一次抓清单的超时（不在主线程上，但也不能无限等）。 */
    private const val FETCH_TIMEOUT_MS = 4_000L

    /** 并发工作线程：播放器一次只会要 1~2 个清单，4 条绰绰有余。 */
    private const val WORK_THREADS = 4

    /** 会话上限（每次 open 一个会话，存的是上游请求头）。 */
    private const val MAX_SESSIONS = 32

    /** 一次代理会话：上游地址 + 该带的请求头。 */
    private class Session(val url: String, val headers: Map<String, String>)

    /** 缓存条目。 */
    private class Cached(val body: String, val atMs: Long, val ttlMs: Long, val note: String)

    private var server: ServerSocket? = null

    @Volatile
    private var port = 0

    private val sessions = ConcurrentHashMap<String, Session>()
    private val sessionIds = AtomicInteger(0)
    private val cache = ConcurrentHashMap<String, Cached>()

    /** 正在抓的地址 → 锁对象：预取和播放器的请求撞在一起时只抓一次。 */
    private val inflight = ConcurrentHashMap<String, Any>()

    /** 统计（诊断浮层 / 日志用）。 */
    private val hitCount = AtomicInteger(0)
    private val fetchCount = AtomicInteger(0)
    private val failCount = AtomicInteger(0)

    private val acceptPool: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "FxManifestAccept").also { it.isDaemon = true }
    }

    private val workPool: ExecutorService = Executors.newFixedThreadPool(WORK_THREADS) { runnable ->
        Thread(runnable, "FxManifestWork").also { it.isDaemon = true }
    }

    /**
     * 抓清单用的 client：和播放共用 [PlayerHttp.client]（同一个连接池 / 同一套
     * trust-all / 同一个 [FxDns]），只把这次调用的超时收紧到 [FETCH_TIMEOUT_MS]。
     */
    private val client by lazy {
        PlayerHttp.client.newBuilder()
            .callTimeout(FETCH_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            .build()
    }

    // ------------------------------------------------------------ 对外入口

    /**
     * 把上游清单地址换成 `http://127.0.0.1:PORT/m3u8?u=…&t=…`。
     *
     * 返回空串 = 代理不可用（端口的 bind 失败等），调用方退回原始地址。
     * 这个方法**不做网络请求、不阻塞**：起播路径上它必须在 1ms 内返回。
     */
    fun proxyUrl(url: String, headers: Map<String, String>): String {
        if (url.isEmpty()) return ""
        val readyPort = ensureStarted()
        if (readyPort <= 0) return ""
        val token = sessionToken(url, headers)
        if (token.isEmpty()) return ""
        val encoded = try {
            URLEncoder.encode(url, "UTF-8")
        } catch (_: Throwable) {
            return ""
        }
        return "http://127.0.0.1:$readyPort/m3u8?u=$encoded&t=$token"
    }

    /**
     * 预抓：把 master / 首个变体清单提前灌进内存（**异步**）。
     *
     * 播放器随后请求本地地址时直接命中缓存 —— 这就是「起播前置动作清零」
     * 的那一半：open 里一行网络都不做，等播放器来要的时候已经在路上/就绪。
     */
    fun prefetch(url: String, headers: Map<String, String>) {
        if (url.isEmpty()) return
        try {
            workPool.execute {
                try {
                    val body = obtain(url, headers)
                    if (body == null) {
                        Log.i(LOG_TAG, "mproxy 预抓失败（稍后播放器来时再试）")
                    } else {
                        FxTiming.mark("manifest_merged")
                    }
                } catch (_: Throwable) {
                    // 预抓失败无所谓：播放器来请求时会再抓一次。
                }
            }
        } catch (_: Throwable) {
            // 线程池拒绝：忽略，等同没有预抓。
        }
    }

    /** 诊断摘要。 */
    fun stats(): String =
        "mproxy[port=$port hit=${hitCount.get()} fetch=${fetchCount.get()} " +
            "fail=${failCount.get()} cache=${cache.size}]"

    /** 释放端口（播放器销毁时调）。 */
    fun release() {
        val current = server
        server = null
        port = 0
        try {
            current?.close()
        } catch (_: Throwable) {
            // 关闭失败不影响结果
        }
        cache.clear()
        sessions.clear()
        inflight.clear()
    }

    // ------------------------------------------------------------ 服务端

    private fun ensureStarted(): Int {
        val existing = server
        if (existing != null && !existing.isClosed) return port
        synchronized(this) {
            val again = server
            if (again != null && !again.isClosed) return port
            return try {
                // 端口 0 = 让系统分配；绑定地址固定 127.0.0.1（只服务本机）。
                val socket = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"))
                server = socket
                port = socket.localPort
                acceptPool.execute { acceptLoop(socket) }
                Log.i(LOG_TAG, "mproxy ready port=$port（只绑 127.0.0.1）")
                port
            } catch (error: Throwable) {
                Log.w(LOG_TAG, "mproxy 启动失败 ${error.javaClass.simpleName}，退回直连")
                0
            }
        }
    }

    private fun acceptLoop(socket: ServerSocket) {
        while (!socket.isClosed) {
            val client = try {
                socket.accept()
            } catch (_: Throwable) {
                return
            }
            try {
                workPool.execute { handle(client) }
            } catch (_: Throwable) {
                try {
                    client.close()
                } catch (_: Throwable) {
                    // 关不掉就算了
                }
            }
        }
    }

    private fun handle(socket: Socket) {
        try {
            socket.soTimeout = 8_000
            val input = socket.getInputStream()
            val reader = BufferedReader(InputStreamReader(input, Charsets.UTF_8))
            val requestLine = reader.readLine() ?: return
            // 请求头读到空行为止（内容我们不用：上游请求头来自会话表）。
            while (true) {
                val line = reader.readLine() ?: break
                if (line.isEmpty()) break
            }
            val parts = requestLine.split(' ')
            if (parts.size < 2) {
                respondText(socket, 400, "bad request")
                return
            }
            val path = parts[1]
            when {
                path.startsWith("/ping") -> respondText(socket, 200, "ok", "text/plain")
                path.startsWith("/m3u8") -> servePlaylist(socket, path)
                else -> respondText(socket, 404, "not found")
            }
        } catch (error: Throwable) {
            Log.d(LOG_TAG, "mproxy 处理请求异常 ${error.javaClass.simpleName}")
        } finally {
            try {
                socket.close()
            } catch (_: Throwable) {
                // 关闭失败不影响结果
            }
        }
    }

    private fun servePlaylist(socket: Socket, path: String) {
        val query = queryParams(path)
        val url = query["u"] ?: query["url"]
        val token = query["t"] ?: ""
        if (url.isNullOrEmpty()) {
            respondText(socket, 400, "missing u")
            return
        }
        val session = sessions[token]
        val headers = session?.headers ?: emptyMap()
        val body = try {
            obtain(url, headers)
        } catch (_: Throwable) {
            null
        }
        if (body == null) {
            // 兜底：让播放器自己去抓原始地址（行为和没加代理时一致）。
            failCount.incrementAndGet()
            redirect(socket, url)
            return
        }
        respondText(socket, 200, body, "application/vnd.apple.mpegurl")
    }

    // ------------------------------------------------------------ 抓 + 改写

    /**
     * 拿一份「可以直接喂给播放器」的清单正文：命中缓存直接返回，
     * 否则抓取 + 改写 + 落缓存。并发请求同一个地址只抓一次。
     */
    private fun obtain(url: String, headers: Map<String, String>): String? {
        cache[url]?.let { entry ->
            if (System.currentTimeMillis() - entry.atMs < entry.ttlMs) {
                hitCount.incrementAndGet()
                Log.i(LOG_TAG, "mproxy hit ${entry.note} $url")
                return entry.body
            }
        }
        val lock = inflight.computeIfAbsent(url) { Any() }
        try {
            synchronized(lock) {
                // 等锁期间别人可能已经抓好。
                cache[url]?.let { entry ->
                    if (System.currentTimeMillis() - entry.atMs < entry.ttlMs) {
                        hitCount.incrementAndGet()
                        return entry.body
                    }
                }
                return fetchAndStore(url, headers, depth = 0)
            }
        } catch (error: Throwable) {
            Log.i(LOG_TAG, "mproxy 抓取异常 ${error.javaClass.simpleName} $url")
            return null
        } finally {
            inflight.remove(url)
        }
    }

    /**
     * 抓一个清单地址；master 且只有一个变体时**就地合并**（返回媒体清单）。
     *
     * [depth] 防止 master → master 的异常嵌套把线程拖死。
     */
    private fun fetchAndStore(url: String, headers: Map<String, String>, depth: Int): String? {
        val fetched = fetchText(url, headers) ?: return null
        val text = fetched.first
        val finalUrl = fetched.second
        val isMedia = !text.contains("#EXT-X-STREAM-INF")
        if (isMedia) {
            val hasEnd = text.contains("#EXT-X-ENDLIST")
            val body = rewriteMedia(text, finalUrl)
            cache[finalUrl] = Cached(body, System.currentTimeMillis(), if (hasEnd) VOD_TTL_MS else LIVE_TTL_MS, "media")
            // 同时也按最初请求的地址记一份（上游 302 之后的地址可能不同）。
            if (finalUrl != url) {
                cache[url] = Cached(body, System.currentTimeMillis(), if (hasEnd) VOD_TTL_MS else LIVE_TTL_MS, "media")
            }
            Log.i(LOG_TAG, "mproxy fetch media ${if (hasEnd) "vod" else "live"} ${text.length}B $url")
            return body
        }
        // master：只有一条变体就直接把它合并掉，播放器少一跳。
        val variants = parseVariants(text)
        if (variants.size == 1 && depth < 2) {
            val only = resolve(finalUrl, variants[0])
            if (only != null) {
                val merged = fetchAndStore(only, headers, depth + 1)
                if (merged != null) {
                    cache[url] = Cached(merged, System.currentTimeMillis(), VOD_TTL_MS, "merged")
                    Log.i(LOG_TAG, "mproxy merge 单变体 -> $only")
                    return merged
                }
            }
            // 合并失败：退回按 master 处理（播放器自己跟跳）。
        }
        val body = rewriteMaster(text, finalUrl, headers)
        cache[url] = Cached(body, System.currentTimeMillis(), MASTER_TTL_MS, "master(${variants.size}变体)")
        Log.i(LOG_TAG, "mproxy fetch master ${variants.size}变体 ${text.length}B $url")
        return body
    }

    /** GET 一次清单；返回（正文, 最终地址）。失败返回 null。 */
    private fun fetchText(url: String, headers: Map<String, String>): Pair<String, String>? {
        fetchCount.incrementAndGet()
        var response: Response? = null
        return try {
            val builder = Request.Builder().url(url)
            PlayerHttp.requestHeaders(url, headers).forEach { (key, value) ->
                if (key.isNotBlank() && value.isNotBlank()) builder.header(key, value)
            }
            response = client.newCall(builder.build()).execute()
            if (!response.isSuccessful) {
                Log.i(LOG_TAG, "mproxy HTTP ${response.code} $url")
                return null
            }
            val body = response.body ?: return null
            val stream = body.byteStream()
            val out = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(16 * 1024)
            var total = 0
            while (true) {
                val read = stream.read(buffer)
                if (read == -1) break
                out.write(buffer, 0, read)
                total += read
                if (total >= MAX_BODY_BYTES) break
            }
            // 顺手把 DNS 预热的成果记下来（清单域名是整条链路最重要的那个）。
            val host = try {
                java.net.URI(url).host
            } catch (_: Throwable) {
                null
            }
            Pair(String(out.toByteArray(), Charsets.UTF_8), response.request.url.toString()).also {
                if (!host.isNullOrEmpty()) {
                    // 只读日志，不做额外网络动作。
                    Log.d(LOG_TAG, "mproxy got ${it.first.length}B from $host")
                }
            }
        } catch (error: Throwable) {
            Log.i(LOG_TAG, "mproxy 请求失败 ${error.javaClass.simpleName} $url")
            null
        } finally {
            try {
                response?.close()
            } catch (_: Throwable) {
                // 关闭失败不影响结果
            }
        }
    }

    /**
     * 媒体清单改写：相对地址绝对化 + 去掉广告段。
     *
     * 分片地址**只绝对化、不代理**：字节直连 CDN，播放器的连接池、Range、
     * 磁盘缓存全部照旧，代理只承担几十 KB 的清单。
     */
    private fun rewriteMedia(body: String, baseUrl: String): String {
        val lines = body.split('\n')
        val out = ArrayList<String>(lines.size + 8)
        var kept = 0
        var dropped = 0
        for (raw in lines) {
            val line = raw.trimEnd('\r')
            if (line.isEmpty()) {
                out.add(line)
                continue
            }
            if (line.startsWith("#")) {
                if (isAdTag(line)) {
                    dropped += 1
                    continue
                }
                out.add(rewriteTagUri(line, baseUrl))
                continue
            }
            // 普通分片行：绝对化；命中广告特征的整行去掉。
            val absolute = resolve(baseUrl, line) ?: line
            if (looksLikeAd(absolute)) {
                dropped += 1
                continue
            }
            kept += 1
            out.add(absolute)
        }
        // 保险：广告规则不可能把清单删到没片可播（真删光了就原样返回）。
        if (kept < 2) {
            if (dropped > 0) Log.w(LOG_TAG, "mproxy 广告过滤会删空清单，忽略本次过滤")
            return absolutizeOnly(body, baseUrl)
        }
        if (dropped > 0) Log.i(LOG_TAG, "mproxy 去掉 $dropped 行广告（剩 $kept 片）")
        return out.joinToString("\n")
    }

    /** master 清单改写：变体行改成代理地址（播放器仍能用 ABR 选码率）。 */
    private fun rewriteMaster(body: String, baseUrl: String, headers: Map<String, String>): String {
        val lines = body.split('\n')
        val out = ArrayList<String>(lines.size + 8)
        for (raw in lines) {
            val line = raw.trimEnd('\r')
            if (line.isEmpty()) {
                out.add(line)
                continue
            }
            if (line.startsWith("#")) {
                out.add(rewriteTagUri(line, baseUrl))
                continue
            }
            val absolute = resolve(baseUrl, line) ?: line
            val proxied = proxyUrl(absolute, headers)
            out.add(if (proxied.isEmpty()) absolute else proxied)
        }
        return out.joinToString("\n")
    }

    /** 完全不改（广告过滤会删空时的兜底路径）。 */
    private fun absolutizeOnly(body: String, baseUrl: String): String {
        val lines = body.split('\n')
        val out = ArrayList<String>(lines.size + 8)
        for (raw in lines) {
            val line = raw.trimEnd('\r')
            if (line.isEmpty()) {
                out.add(line)
            } else if (line.startsWith("#")) {
                out.add(rewriteTagUri(line, baseUrl))
            } else {
                out.add(resolve(baseUrl, line) ?: line)
            }
        }
        return out.joinToString("\n")
    }

    /** 标签行里的 `URI="…"`（#EXT-X-KEY / #EXT-X-MAP / #EXT-X-MEDIA 等）。 */
    private fun rewriteTagUri(line: String, baseUrl: String): String {
        if (!line.contains("URI=\"")) return line
        val builder = StringBuilder(line.length + 32)
        var index = 0
        while (true) {
            val start = line.indexOf("URI=\"", index)
            if (start < 0) {
                builder.append(line, index, line.length)
                break
            }
            builder.append(line, index, start + 5)
            val end = line.indexOf('"', start + 5)
            if (end < 0) {
                builder.append(line, start + 5, line.length)
                break
            }
            val reference = line.substring(start + 5, end)
            val absolute = resolve(baseUrl, reference)
            builder.append(absolute ?: reference)
            index = end
        }
        return builder.toString()
    }

    /** 广告标签（播放器本来就忽略未知标签，删掉是为了别让壳的对齐差异干扰）。 */
    private fun isAdTag(line: String): Boolean {
        val upper = line.uppercase()
        return upper.startsWith("#EXT-X-CUE-OUT") ||
            upper.startsWith("#EXT-X-CUE-IN") ||
            upper.startsWith("#EXT-X-SCTE35") ||
            upper.startsWith("#EXT-OATCLS-SCTE35") ||
            upper.startsWith("#EXT-X-AD") ||
            upper.startsWith("#EXT-X-ASSET")
    }

    /**
     * 分片地址的广告特征。
     *
     * 只认「明显的广告路径」：太宽的规则（比如含 "ad" 就算）会误杀
     * `/upload/ad/` 这种正常内容目录，宁可漏掉广告也不能把正片删了。
     */
    private fun looksLikeAd(url: String): Boolean {
        val lower = url.lowercase()
        return lower.contains("/ads/") ||
            lower.contains("/advert") ||
            lower.contains("/ad_") ||
            lower.contains("/preroll") ||
            lower.contains("/midroll")
    }

    /** master 里的变体地址（#EXT-X-STREAM-INF 的下一行）。 */
    private fun parseVariants(body: String): List<String> {
        val lines = body.split('\n')
        val out = ArrayList<String>()
        for (index in lines.indices) {
            if (!lines[index].trimStart().startsWith("#EXT-X-STREAM-INF")) continue
            for (next in index + 1 until lines.size) {
                val text = lines[next].trim()
                if (text.isEmpty() || text.startsWith("#")) continue
                out.add(text)
                break
            }
        }
        return out
    }

    /** 相对地址绝对化（`URI.resolve` 能正确处理 `//host/path` 和 `../`）。 */
    private fun resolve(baseUrl: String, reference: String): String? {
        val text = reference.trim()
        if (text.isEmpty()) return null
        if (text.startsWith("http://") || text.startsWith("https://")) return text
        return try {
            URI(baseUrl).resolve(text)?.toString()
        } catch (_: Throwable) {
            null
        }
    }

    // ------------------------------------------------------------ 会话 / HTTP

    /** 同一份（地址 + 请求头）复用同一个 token：本地地址稳定，缓存才有意义。 */
    private fun sessionToken(url: String, headers: Map<String, String>): String {
        val key = url + "\n" + headers.entries.sortedBy { it.key }.joinToString("&") {
            "${it.key}=${it.value}"
        }
        for ((token, session) in sessions) {
            if (sessionKey(session) == key) return token
        }
        if (sessions.size >= MAX_SESSIONS) sessions.clear()
        val token = "s" + sessionIds.incrementAndGet()
        sessions[token] = Session(url, headers)
        return token
    }

    private fun sessionKey(session: Session): String =
        session.url + "\n" + session.headers.entries.sortedBy { it.key }.joinToString("&") {
            "${it.key}=${it.value}"
        }

    private fun queryParams(path: String): Map<String, String> {
        val index = path.indexOf('?')
        if (index < 0) return emptyMap()
        val out = HashMap<String, String>()
        val query = path.substring(index + 1)
        for (pair in query.split('&')) {
            if (pair.isEmpty()) continue
            val eq = pair.indexOf('=')
            if (eq <= 0) continue
            val key = pair.substring(0, eq)
            val value = try {
                URLDecoder.decode(pair.substring(eq + 1), "UTF-8")
            } catch (_: Throwable) {
                pair.substring(eq + 1)
            }
            out[key] = value
        }
        return out
    }

    private fun respondText(
        socket: Socket,
        code: Int,
        body: String,
        contentType: String = "text/plain; charset=utf-8",
    ) {
        val bytes = body.toByteArray(Charsets.UTF_8)
        val head = buildString {
            append("HTTP/1.1 $code ${reason(code)}\r\n")
            append("Content-Type: $contentType\r\n")
            append("Content-Length: ${bytes.size}\r\n")
            // 本机代理：不许被缓存层拦（部分 ROM 的 webview/代理会插手）。
            append("Cache-Control: no-store\r\n")
            append("Connection: close\r\n\r\n")
        }
        write(socket, head.toByteArray(Charsets.UTF_8), bytes)
    }

    private fun redirect(socket: Socket, location: String) {
        val head = buildString {
            append("HTTP/1.1 302 Found\r\n")
            append("Location: $location\r\n")
            append("Content-Length: 0\r\n")
            append("Connection: close\r\n\r\n")
        }
        write(socket, head.toByteArray(Charsets.UTF_8), ByteArray(0))
    }

    private fun write(socket: Socket, head: ByteArray, body: ByteArray) {
        val output: OutputStream = socket.getOutputStream()
        output.write(head)
        if (body.isNotEmpty()) output.write(body)
        output.flush()
    }

    private fun reason(code: Int): String = when (code) {
        200 -> "OK"
        302 -> "Found"
        400 -> "Bad Request"
        404 -> "Not Found"
        else -> "OK"
    }
}

package com.huanxiang.fantasy_tv

import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.okhttp.OkHttpDataSource
import okhttp3.Call
import okhttp3.ConnectionPool
import okhttp3.EventListener
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody
import java.io.ByteArrayOutputStream
import java.net.InetSocketAddress
import java.net.Proxy
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.io.IOException
import java.net.InetAddress
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/**
 * 播放传输层：**全 App 一个 OkHttpClient**（TRANSPORT_OKHTTP，2026-11-15）。
 *
 * 为什么要换掉 DefaultHttpDataSource 那一套（HttpURLConnection）：
 *   · HttpURLConnection 的 keep-alive 是**按 URL 实例**记的，HLS 每次 302
 *     换域、每个分片换路径都要重开 TCP + TLS —— 移动网一次 100~600ms，
 *     起播就是这么被拖慢的；
 *   · 我们原来每次 `open()` 都 `DefaultHttpDataSource.Factory()`，
 *     等于每次把连接池扔掉重来，302 之后的直连地址一个都复用不上；
 *   · 壳（OK影视 / 影视壳）用的是 OkHttp：HTTP/2、全局 ConnectionPool、
 *     trust-all、自带 DNS。这里对齐同一套。
 *
 * 关键点：**连接池挂在 client 上**，所以 client 必须全 App 唯一；
 * `OkHttpDataSource.Factory` 每次 open 新建没关系，它只是 client 的薄壳。
 */
@OptIn(UnstableApi::class)
object PlayerHttp {

    /** 和 [ExoPlayerPlugin.LOG_TAG] 同一个标签：`adb logcat -s FxExo` 一起看。 */
    const val LOG_TAG = "FxExo"

    /**
     * 清单预归并（master → variant）的硬超时：800ms。
     *
     * 起播路径上任何一步都不能无限等：清单抓不到就原样播，用户根本感知不到
     * 「少省了一跳」，但会立刻感知到「多等了 5 秒」。
     */
    const val MANIFEST_TIMEOUT_MS = 800L

    /** 清单正文最多读这么多（master/媒体清单都是几十 KB，1MB 已经离谱）。 */
    private const val MAX_MANIFEST_BYTES = 1L * 1024 * 1024

    /** 连接建立次数（EventListener.connectStart 计数），每次 open 前清零。 */
    private val connectCount = AtomicInteger(0)

    /** 本次 open 至今实际收到的正文字节数（EventListener.responseBodyEnd）。 */
    private val totalBytes = AtomicLong(0)

    /** 实测吞吐的时间原点（[resetConnectCount] 时重置）。 */
    private val windowStartNanos = AtomicLong(System.nanoTime())

    private val trustManagerRef: X509TrustManager by lazy { createTrustAllManager() }

    private val socketFactoryRef: SSLSocketFactory by lazy {
        // 必须用**同一个** TrustManager 建 context，否则 sslSocketFactory 和
        // 传进去的 trustManager 不是一套，握手行为会变得不可预期。
        val context = SSLContext.getInstance("TLS")
        context.init(null, arrayOf<TrustManager>(trustManagerRef), SecureRandom())
        context.socketFactory
    }

    /**
     * 连接计数（EventListener.connectStart）。
     *
     * 用它核对「换 OkHttp 之后到底建了几条连接」：同一个源、同一个缓存键，
     * 起播路径应该是 1 条（清单那条），分片全部复用；改造前 302 换个域就是
     * 一条新的。
     */
    private val connectCounter = object : EventListener.Factory {
        override fun create(call: Call): EventListener = object : EventListener() {
            override fun connectStart(
                call: Call,
                inetSocketAddress: InetSocketAddress,
                proxy: Proxy,
            ) {
                // MANIFEST_PROXY：本地清单代理（127.0.0.1）的连接是环回，
                // 毫秒级且不产生流量。把它算进「起播建了几条连接」会让诊断
                // 里的 connects 恒 +1，反而看不出真实复用情况，所以排除。
                val address: InetAddress? = inetSocketAddress.address
                if (address != null && address.isLoopbackAddress) return
                connectCount.incrementAndGet()
            }

            // CUSTOM_DNS（2026-11-15）：把「真的连上了哪个 IP」记给 [FxDns]，
            // 下次同一个 host 直接用它 —— 这就是壳那种 hosts 映射的自动版。
            // 同时：连不上的 IP 拉黑 5 分钟，避免系统 DNS 反复把它喂回来。
            override fun connectEnd(
                call: Call,
                inetSocketAddress: InetSocketAddress,
                proxy: Proxy,
                protocol: okhttp3.Protocol?,
            ) {
                val host = call.request().url.host
                val address: InetAddress? = inetSocketAddress.address
                if (address != null) FxDns.noteConnected(host, address)
            }

            override fun connectFailed(
                call: Call,
                inetSocketAddress: InetSocketAddress,
                proxy: Proxy,
                protocol: okhttp3.Protocol?,
                ioe: IOException,
            ) {
                val host = call.request().url.host
                val address: InetAddress? = inetSocketAddress.address
                if (address != null) FxDns.noteConnectFailed(host, address)
            }

            // 实测吞吐（诊断浮层「码率（实测）」那一行）：分片的字节数是
            // 真实下载量，比 media3 的 BandwidthMeter 更贴近用户看到的网速。
            override fun responseBodyEnd(call: Call, byteCount: Long) {
                if (byteCount > 0) totalBytes.addAndGet(byteCount)
            }
        }
    }

    /**
     * 全局唯一 client。
     *
     * 超时对齐壳（`catvod/net/OkHttp.java` 的 TIMEOUT = 30s）：
     * connect / read / write 全 30s。移动网 CDN 边缘抖一下、首片等回源都是常态，
     * 压到 6~8 秒会把「等一下就能播」的片判死，反而让 Dart 救援链换线路重来。
     *
     * 不设 callTimeout：一次分片请求的时长由 read 超时兜底，整体调用不该被砍。
     */
    val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS)
            // 302 换域（福盈那类分片中转）必须跟，且允许 http ↔ https 跨协议跳
            .followRedirects(true)
            .followSslRedirects(true)
            // 连接池：8 条空闲、保活 5 分钟。HLS 一片接一片，保活足够长，
            // 拖进度条回来也不用重建。
            .connectionPool(ConnectionPool(8, 5, TimeUnit.MINUTES))
            // 影视源里自签 / 域名不符 / 过期证书是常态，壳也是 trust-all
            .sslSocketFactory(trustAllFactory(), trustAllManager())
            .hostnameVerifier { _, _ -> true }
            // CUSTOM_DNS（2026-11-15）：壳带 hosts 映射 + DoH，我们原来纯走
            // 系统 DNS —— 多个 A 记录里撞到一条劣质 IP 就整段慢，而且操作
            // 系统缓存会把它继续喂给后面几十个分片请求。[FxDns] 做三件事：
            // 缓存、IPv4 优先、记住真实连通过的 IP（= 自动 hosts），
            // 失败才退系统 DNS / DoH。**不阻塞**播放主路径。
            .dns(FxDns)
            .eventListenerFactory(connectCounter)
            .build()
    }

    // ------------------------------------------------------------ TLS 兜底

    /** trust-all 的 X509TrustManager（壳同款：不校验证书链）。 */
    fun trustAllManager(): X509TrustManager = trustManagerRef

    private fun createTrustAllManager(): X509TrustManager = object : X509TrustManager {
        override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {
            // trust-all：影视源大量自签证书
        }

        override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
            // trust-all
        }

        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    }

    /** trust-all 的 SSLSocketFactory（和 [trustAllManager] 是同一套 context）。 */
    fun trustAllFactory(): SSLSocketFactory = socketFactoryRef

    // ------------------------------------------------------------ UA / 请求头

    /**
     * 兜底 UA。
     *
     * 原来只有 `"Mozilla/5.0"`：不少源按 UA 做风控，回 403 / 412，media3 默认
     * 策略重试 3 次才报错 —— 用户看到的是「转三圈然后失败」。壳的 UA 是
     * Chrome 风格的 `com.android.chrome/... AndroidXMedia3/x.y.z`，照抄这一档。
     */
    fun defaultUa(): String =
        "com.android.chrome/120.0.6099.230 (Linux;Android ${Build.VERSION.RELEASE})" +
            " AndroidXMedia3/1.4.1"

    /**
     * 站点级兜底请求头：Referer 取源站根。
     *
     * 一部分源（尤其套了 CDN 防盗链的）只认「Referer 是本域」；Dart 侧没给
     * Referer 时这里补一个，给了就以 Dart 侧为准（见 [requestHeaders]）。
     * 非 http(s)（本地文件 / data:）返回空表。
     */
    fun baseHeaders(url: String): Map<String, String> {
        val parsed = try {
            Uri.parse(url)
        } catch (_: Throwable) {
            return emptyMap()
        }
        val scheme = parsed.scheme ?: return emptyMap()
        if (!scheme.startsWith("http", ignoreCase = true)) return emptyMap()
        val authority = parsed.authority ?: return emptyMap()
        // REFERER_OWN（2026-11-15）：本站解析服务（`/hxparse/…`）的地址不发
        // Referer。这些地址 302 到 CDN 之后，上游只看令牌；带一个
        // `http://125.94.244.87/` 的 Referer 反而可能触发源站防盗链，
        // 而且令牌是一次性的，被 403 一次这集就废了。
        // 判定看路径前缀，不看域名：换服务器只改 DNS，域名/IP 都可能变。
        if (parsed.path.orEmpty().startsWith("/hxparse/")) return emptyMap()
        return mapOf("Referer" to "$scheme://$authority/")
    }

    /**
     * 合并请求头：兜底（[baseHeaders] + UA）在前，Dart 给的盖在上面。
     *
     * UA 单独处理：大小写不敏感地只留一个 `User-Agent`，避免 `user-agent` 和
     * `User-Agent` 同时出现（OkHttp 会当成两个头，部分源直接 400）。
     */
    fun requestHeaders(url: String, headers: Map<String, String>): Map<String, String> {
        val ua = headers.entries
            .firstOrNull { it.key.equals("User-Agent", ignoreCase = true) }
            ?.value
            ?.takeIf { it.isNotBlank() }
            ?: defaultUa()
        val merged = LinkedHashMap<String, String>()
        merged.putAll(baseHeaders(url))
        headers.forEach { (key, value) ->
            if (key.isNotBlank() && !key.equals("User-Agent", ignoreCase = true)) {
                merged[key] = value
            }
        }
        merged["User-Agent"] = ua
        return merged
    }

    /** 实际会发出去的 UA（日志用）。 */
    fun userAgent(headers: Map<String, String>): String =
        headers.entries
            .firstOrNull { it.key.equals("User-Agent", ignoreCase = true) }
            ?.value
            ?.takeIf { it.isNotBlank() }
            ?: defaultUa()

    // ------------------------------------------------------------ DataSource

    /**
     * 播放 / 预取共用的 HTTP DataSource 工厂。
     *
     * 每次调用新建 factory（无状态、便宜），**client 始终是 [client]** ——
     * 连接池因此跨越所有 open / 所有分片。
     *
     * [headerUrl]：请求头按哪个地址推导（Referer 取该地址的站根）。
     * 平时等于 [url]；走本地清单代理时，交给播放器的是 `127.0.0.1:PORT/...`，
     * 但 Referer **必须**还是上游站点的 —— 否则盗链校验直接 403，
     * 所以那时把上游地址传进来。
     *
     * 不再设 allowCrossProtocolRedirects / connectTimeout / readTimeout：
     * 这三项在 OkHttp 里都是 client 级配置，factory 上设了也没用。
     */
    fun httpFactory(
        url: String,
        headers: Map<String, String>,
        headerUrl: String = url,
    ): OkHttpDataSource.Factory {
        val merged = requestHeaders(headerUrl, headers)
        return OkHttpDataSource.Factory(client)
            .setUserAgent(merged["User-Agent"] ?: defaultUa())
            .setDefaultRequestProperties(merged)
    }

    // ------------------------------------------------------------ 连接计数

    fun resetConnectCount() {
        connectCount.set(0)
        totalBytes.set(0)
        windowStartNanos.set(System.nanoTime())
    }

    fun connectCount(): Int = connectCount.get()

    /**
     * 本次 open 至今的实测吞吐（kbps，按已收到的正文字节 ÷ 经过时间）。
     *
     * 换集那一下会归零，所以前 200ms 不报数（否则数字会跳一下没意义的值）。
     * 诊断浮层用它当「实测码率」—— 和 [FxTiming] 的首帧耗时一起看，
     * 就能判断慢在「连不上 / 带宽不够」还是「清单跳转」。
     */
    fun measuredKbps(): Int {
        val bytes = totalBytes.get()
        if (bytes <= 0) return 0
        val seconds = (System.nanoTime() - windowStartNanos.get()) / 1_000_000_000.0
        if (seconds < 0.2) return 0
        val kbps = bytes * 8.0 / seconds / 1000.0
        return if (kbps > Int.MAX_VALUE) Int.MAX_VALUE else kbps.toInt()
    }

    // ------------------------------------------------------------ 清单预归并

    fun isHttpUrl(url: String): Boolean =
        url.startsWith("http://") || url.startsWith("https://")

    /**
     * 能不能交给播放器（URL_GUARD 2026-11-15）。
     *
     * 只放行三类：http(s)、file:、以及 content:（下载好的本地文件）。
     * 空串、`about:blank`、`javascript:`、相对路径这些一旦交给
     * `setMediaSource`，media3 会抛 IllegalArgumentException —— 那条路径在主
     * 线程上，未捕获就是闪退。所以在 [ExoPlayerPlugin] 的 open 入口先挡掉。
     */
    fun isPlayableUrl(url: String): Boolean {
        val text = url.trim()
        if (text.isEmpty()) return false
        val lower = text.lowercase()
        if (lower.startsWith("http://") || lower.startsWith("https://")) {
            // 至少要有个主机名，否则 OkHttp 的 Request.Builder().url 会抛。
            val host = try {
                Uri.parse(text).host
            } catch (_: Throwable) {
                null
            }
            return !host.isNullOrEmpty()
        }
        return lower.startsWith("file://") ||
            lower.startsWith("/") ||
            lower.startsWith("content://")
    }

    /**
     * 预热：在主线程把 client（含 trust-all 的 SSLContext）建出来。
     *
     * 为什么必须显式做：`client` 是 by lazy，第一次访问它的可能是
     * FxManifest / PreloaderHls / OkHttp 回调线程。把它们变成「第一次初始化
     * TLS」的现场，等于把最容易抛异常的初始化放到最没人兜的线程上。
     */
    fun warmUp() {
        // 触发 lazy 初始化；顺带把 socketFactory 也建好。
        client
        trustAllFactory()
    }

    /**
     * 清单预归并（MANIFEST_MERGE，2026-11-15）：master → 第一个 variant。
     *
     * 为什么要做：master 清单本身不可播，播放器必须先拉 master、解析、再拉
     * variant，两跳串行。这两跳里的 DNS / TCP / TLS 我们用**同一个 client**
     * 提前付掉，播放器接手 variant 地址时连接已经在池子里，直接 GET。
     *
     * 三条硬约束：
     *   1. 只抓**清单**，绝不预取分片 —— 上一版就是预取了分片被回滚的；
     *   2. 失败 / 超时 / 不是 master / 重定向到非 HLS：一律返回原始地址，
     *      播放行为与改造前完全一致，不引入新的失败面；
     *   3. 用 `newBuilder().callTimeout(800ms)` 的派生 client：只改这一次调用的
     *      超时，连接池、TLS、EventListener 全部继承，不污染全局 client。
     *
     * 返回：可播地址（variant 绝对地址）或原始地址。
     */
    fun mergeMasterPlaylist(
        url: String,
        headers: Map<String, String>,
        log: (String) -> Unit = {},
    ): String {
        if (!isHttpUrl(url)) return url
        val request = try {
            val builder = Request.Builder().url(url)
            requestHeaders(url, headers).forEach { (key, value) ->
                if (key.isNotBlank() && value.isNotBlank()) builder.header(key, value)
            }
            builder.build()
        } catch (error: Throwable) {
            log("清单预归并: 请求构造失败 ${error.javaClass.simpleName}，用原始地址")
            return url
        }
        var response: Response? = null
        return try {
            // client 的懒初始化（trust-all 的 SSLContext）如果失败，异常必须
            // 落在 try 里面 —— 这个函数对调用方的承诺是「永不抛、永远有地址」。
            val mergeClient = client.newBuilder()
                .callTimeout(MANIFEST_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                .build()
            val resp = mergeClient.newCall(request).execute()
            response = resp
            if (!resp.isSuccessful) {
                log("清单预归并: HTTP ${resp.code}，用原始地址")
                return url
            }
            val body: ResponseBody = resp.body ?: run {
                log("清单预归并: 响应无正文，用原始地址")
                return url
            }
            val text = readCapped(body) ?: return url
            if (!text.contains("#EXT-X-STREAM-INF")) {
                // 已经是媒体清单：不需要归并
                return url
            }
            val variant = firstVariant(text)
            if (variant == null) {
                log("清单预归并: master 里没有 variant 地址，用原始地址")
                return url
            }
            val resolved = resp.request.url.resolve(variant)
            if (resolved == null) {
                log("清单预归并: variant 地址无法解析（$variant），用原始地址")
                return url
            }
            val merged = resolved.toString()
            log("清单预归并: $url -> $merged")
            merged
        } catch (error: Throwable) {
            // 超时（callTimeout = 800ms）/ 断网 / TLS 失败：静默回退
            log("清单预归并: 放弃（${error.javaClass.simpleName}），用原始地址")
            url
        } finally {
            try {
                response?.close()
            } catch (_: Throwable) {
                // 关闭失败不影响结果
            }
        }
    }

    /** 读清单正文，超过 [MAX_MANIFEST_BYTES] 就截断（防被超大响应拖死）。 */
    private fun readCapped(body: ResponseBody): String? {
        return try {
            val stream = body.byteStream()
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(8 * 1024)
            var total = 0L
            while (true) {
                val read = stream.read(buffer)
                if (read == -1) break
                val remaining = MAX_MANIFEST_BYTES - total
                if (remaining <= 0) break
                val take = if (read > remaining) remaining.toInt() else read
                out.write(buffer, 0, take)
                total += take
                if (take < read) break
            }
            String(out.toByteArray(), Charsets.UTF_8)
        } catch (error: Throwable) {
            Log.d(LOG_TAG, "清单预归并: 读取失败 ${error.javaClass.simpleName}")
            null
        }
    }

    /** master 清单里第一个 variant 的相对 / 绝对地址。 */
    private fun firstVariant(body: String): String? {
        val lines = body.split('\n')
        for (index in lines.indices) {
            if (!lines[index].trim().startsWith("#EXT-X-STREAM-INF")) continue
            for (next in index + 1 until lines.size) {
                val text = lines[next].trim()
                if (text.isEmpty() || text.startsWith("#")) continue
                return text
            }
        }
        return null
    }
}

package com.huanxiang.fantasy_tv

import android.util.Log
import okhttp3.Dns
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.InetAddress
import java.net.UnknownHostException
import java.net.URL
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * 轻量 DNS 解析器（CUSTOM_DNS 2026-11-15，对齐壳的 hosts + DoH 思路）。
 *
 * 为什么要自己实现 `OkHttp.dns()`：
 *   · 壳（OK影视 / FongMi）带一份 hosts 映射，直连「已知好用的 IP」；
 *     我们每次起播都走系统 DNS，多个 A 记录里撞到一条劣质 IP（限速 / 回源慢
 *     的边缘节点）就整段慢，且**同一台设备上不会自愈** —— 操作系统缓存
 *     会把这颗 IP 继续喂给后面几十个分片请求；
 *   · 分片地址换域很频繁（302 中转），每次换域都要一次 DNS 往返，
 *     移动网 20~120ms，起播那一下就在主路径上。
 *
 * 做法（**全部不阻塞播放主路径**）：
 *   1. 上次真的连通过的 IP 记成「钉住」的 IP（等价于壳的 hosts 映射，但是
 *      自动生成的 —— 不猜、不写死，只记实战结果）；
 *   2. 系统 DNS 的结果进内存缓存（10 分钟），回来的地址 IPv4 排前面
 *      （不少 CDN 的 IPv6 走的是另一套回源，慢很多）；
 *   3. 连接失败的 IP 拉黑 5 分钟，下次解析跳过；
 *   4. 系统 DNS **彻底失败**时才用 DoH（阿里 DNS 的 JSON 接口）兜一次，
 *      并在后台线程跑，绝不挂在起播路径上。
 *
 * 为什么不把 DoH 放在首选：DoH 查询没有 ECS（客户端子网），拿到的往往是
 * 「离 DNS 服务器近」而不是「离用户近」的节点，国内 CDN 上这么干经常反而
 * 更慢。所以只在系统 DNS 已经不可用时才用它兜底。
 */
object FxDns : Dns {

    /** 和 [ExoPlayerPlugin.LOG_TAG] 同一个标签：`adb logcat -s FxExo`。 */
    private const val LOG_TAG = "FxExo"

    /** 系统 DNS 结果的内存缓存时长。 */
    private const val CACHE_TTL_MS = 10 * 60 * 1000L

    /** 「钉住」的 IP（上次成功连过的那个）的有效期。 */
    private const val PIN_TTL_MS = 30 * 60 * 1000L

    /** 连接失败的 IP 拉黑时长。 */
    private const val BAD_TTL_MS = 5 * 60 * 1000L

    /** 缓存条数上限（HLS 会换很多域，别无限涨）。 */
    private const val MAX_ENTRIES = 256

    /** DoH 兜底：阿里公共 DNS 的 JSON 接口（国内可达，不需要证书固定）。 */
    private const val DOH_ENDPOINT = "https://dns.alidns.com/resolve"

    /** DoH 超时：兜底用，宁可放弃也不能拖。 */
    private const val DOH_TIMEOUT_MS = 1500

    private class Entry(val addresses: List<InetAddress>, val atMs: Long)

    private class Pin(val address: InetAddress, val atMs: Long)

    private val cache = ConcurrentHashMap<String, Entry>()
    private val pinned = ConcurrentHashMap<String, Pin>()

    /** key = "host|ip"，value = 拉黑到期时间。 */
    private val badUntil = ConcurrentHashMap<String, Long>()

    /** DoH 兜底线程（只在系统 DNS 失败时用一次）。 */
    private val dohQueue: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "FxDoh").also { it.isDaemon = true }
    }

    /** 诊断用计数：系统 DNS 命中 / 缓存命中 / 钉住命中 / DoH 兜底。 */
    @Volatile
    var statSystem = 0
        private set

    @Volatile
    var statCached = 0
        private set

    @Volatile
    var statPinned = 0
        private set

    @Volatile
    var statDoh = 0
        private set

    override fun lookup(hostname: String): List<InetAddress> {
        val host = hostname.trim()
        if (host.isEmpty()) return Dns.SYSTEM.lookup(hostname)
        // 字面量 IP：不用解析（OkHttp 也会先走到这里）。
        literalIp(host)?.let { return listOf(it) }

        // 1) 钉住的 IP（上次真的连通过的那条）—— 壳的 hosts 映射效果。
        val pin = pinned[host]
        if (pin != null && System.currentTimeMillis() - pin.atMs < PIN_TTL_MS &&
            !isBad(host, pin.address)
        ) {
            statPinned += 1
            return listOf(pin.address)
        }

        // 2) 内存缓存。
        val hit = cache[host]
        if (hit != null && System.currentTimeMillis() - hit.atMs < CACHE_TTL_MS) {
            val usable = hit.addresses.filterNot { isBad(host, it) }
            if (usable.isNotEmpty()) {
                statCached += 1
                return usable
            }
        }

        // 3) 系统 DNS。
        try {
            val raw = Dns.SYSTEM.lookup(hostname)
            val usable = raw.filterNot { isBad(host, it) }
            val ordered = order(if (usable.isNotEmpty()) usable else raw)
            if (ordered.isNotEmpty()) {
                statSystem += 1
                store(host, ordered)
                return ordered
            }
        } catch (error: Throwable) {
            // 系统 DNS 不可用（离线 / 运营商 DNS 挂了）：先退到过期缓存，
            // 再退到 DoH，两条都没有才把异常抛给 OkHttp。
            val stale = hit?.addresses?.filterNot { isBad(host, it) }
            if (!stale.isNullOrEmpty()) {
                Log.i(LOG_TAG, "dns 系统解析失败，用过期缓存 $host")
                return stale
            }
            val doh = dohLookup(host)
            if (doh.isNotEmpty()) {
                store(host, doh)
                return doh
            }
            throw if (error is UnknownHostException) {
                error
            } else {
                UnknownHostException(host).also { it.initCause(error) }
            }
        }
        // 系统 DNS 返回空列表（极罕见）：DoH 兜底后仍空就报错。
        val doh = dohLookup(host)
        if (doh.isNotEmpty()) {
            store(host, doh)
            return doh
        }
        throw UnknownHostException(host)
    }

    /**
     * 记录「这个 host 用这个 IP 连上了」——下次解析直接用它。
     *
     * 这是壳 hosts 映射的自动版：不靠人工维护，只认实战结果。
     */
    fun noteConnected(host: String, address: InetAddress) {
        val key = host.trim().lowercase()
        if (key.isEmpty()) return
        pinned[key] = Pin(address, System.currentTimeMillis())
        // 连得上就说明它不是坏 IP。
        badUntil.remove(badKey(key, address))
    }

    /** 记录「这个 host 的这个 IP 连不上」——拉黑一段时间，下次跳过。 */
    fun noteConnectFailed(host: String, address: InetAddress) {
        val key = host.trim().lowercase()
        if (key.isEmpty()) return
        badUntil[badKey(key, address)] = System.currentTimeMillis() + BAD_TTL_MS
        val pin = pinned[key]
        if (pin != null && pin.address == address) pinned.remove(key)
        Log.i(LOG_TAG, "dns 拉黑 $key -> $address（${BAD_TTL_MS / 1000}s）")
    }

    /** 预解析（不阻塞调用方）：首页/详情页拿到地址时提前把 DNS 付掉。 */
    fun prewarm(host: String) {
        val key = host.trim().lowercase()
        if (key.isEmpty() || literalIp(key) != null) return
        val hit = cache[key]
        if (hit != null && System.currentTimeMillis() - hit.atMs < CACHE_TTL_MS) return
        try {
            dohQueue.execute {
                try {
                    lookup(key)
                } catch (_: Throwable) {
                    // 预解析失败无所谓：真正解析还会再来一次。
                }
            }
        } catch (_: Throwable) {
            // 线程池满了：直接忽略。
        }
    }

    /** 诊断 / 日志用的一行摘要。 */
    fun stats(): String =
        "dns[system=$statSystem cached=$statCached pinned=$statPinned doh=$statDoh]"

    // ------------------------------------------------------------ 内部

    private fun badKey(host: String, address: InetAddress): String =
        "$host|${address.hostAddress}"

    private fun isBad(host: String, address: InetAddress): Boolean {
        val expire = badUntil[badKey(host, address)] ?: return false
        if (System.currentTimeMillis() >= expire) {
            badUntil.remove(badKey(host, address))
            return false
        }
        return true
    }

    /** IPv4 优先：手机上不少 CDN 的 IPv6 路径要绕一跳，起播慢一截。 */
    private fun order(addresses: List<InetAddress>): List<InetAddress> =
        addresses.sortedBy { if (it is Inet4Address) 0 else 1 }

    private fun store(host: String, addresses: List<InetAddress>) {
        if (addresses.isEmpty()) return
        if (cache.size > MAX_ENTRIES) cache.clear()
        cache[host] = Entry(addresses, System.currentTimeMillis())
    }

    private fun literalIp(host: String): InetAddress? {
        // 只认 IPv4 字面量：IPv6 的 hostname 在 URL 里带方括号，OkHttp 自己会处理。
        val parts = host.split('.')
        if (parts.size != 4) return null
        for (part in parts) {
            val value = part.toIntOrNull() ?: return null
            if (value < 0 || value > 255) return null
        }
        return try {
            InetAddress.getByName(host)
        } catch (_: Throwable) {
            null
        }
    }

    /**
     * DoH 兜底（同步版，只在系统 DNS 失败时调用；调用点已经在非主线程）。
     *
     * 用 HttpURLConnection 而不是 [PlayerHttp.client]：这个类本身就是
     * PlayerHttp 的 dns，用那条 client 会绕回自己。
     */
    private fun dohLookup(host: String): List<InetAddress> {
        var connection: HttpURLConnection? = null
        return try {
            val url = URL("$DOH_ENDPOINT?name=${java.net.URLEncoder.encode(host, "UTF-8")}&type=A")
            connection = url.openConnection() as HttpURLConnection
            connection.connectTimeout = DOH_TIMEOUT_MS
            connection.readTimeout = DOH_TIMEOUT_MS
            connection.setRequestProperty("Accept", "application/dns-json")
            if (connection.responseCode != 200) {
                Log.i(LOG_TAG, "doh HTTP ${connection.responseCode} $host")
                return emptyList()
            }
            val text = connection.inputStream.bufferedReader().use { it.readText() }
            val answer = JSONObject(text).optJSONArray("Answer") ?: return emptyList()
            val out = ArrayList<InetAddress>()
            for (index in 0 until answer.length()) {
                val item = answer.optJSONObject(index) ?: continue
                // type 1 = A 记录；CNAME 之类跳过。
                if (item.optInt("type", 0) != 1) continue
                val data = item.optString("data", "").trim()
                if (data.isEmpty()) continue
                val address = literalIp(data) ?: continue
                out.add(address)
            }
            if (out.isNotEmpty()) {
                statDoh += 1
                Log.i(LOG_TAG, "doh 命中 $host -> ${out.map { it.hostAddress }}")
            }
            order(out)
        } catch (error: Throwable) {
            Log.i(LOG_TAG, "doh 失败 $host（${error.javaClass.simpleName}）")
            emptyList()
        } finally {
            try {
                connection?.disconnect()
            } catch (_: Throwable) {
                // 断开失败不影响结果
            }
        }
    }
}

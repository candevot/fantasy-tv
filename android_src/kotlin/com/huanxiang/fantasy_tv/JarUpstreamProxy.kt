package com.huanxiang.fantasy_tv

import android.util.Log
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.SocketAddress
import java.net.URI

/**
 * JAR 上游出口代理（FWD_PROXY，2026-11-22）
 * =====================================================================
 * 为什么需要：咕噜（`csp_Gulu`）的列表/搜索接口
 * `http://103.45.132.22:19987/app/bn/v2` 按**客户端出口 IP** 限流 ——
 * 同一个 IP 短时间第 2 个请求就 429，之后整个 IP 被封一段时间。
 * 手机出口 IP 连开几个详情页就会被封，表现就是「咕噜整组线路消失、点进去
 * 没线路可播」。影视服务器出口 IP 同样被封。
 *
 * 做法：在进程里装一个 [ProxySelector]，只把**白名单里的上游 API host**
 * 的请求指向阿里云 `47.96.0.112:8787`（那台机器上 relay 兼做正向代理，
 * 出口 IP 换来的是干净的。实测连发 3 轮 handshake/boot/search 全 200）。
 *
 * 三条硬约束：
 *   · 只代理白名单 host：其它请求（封面、解析后直链、播放分片）一律直连，
 *     所以不会把播放流量绕一圈，也不会拖慢秒开；
 *   · 代理连不上就退让：`connectFailed` 后 60s 内全部直连，宁可撞 429
 *     也不能因为代理挂了把咕噜彻底打死；
 *   · 装一次就够（[installed]），重复调用直接返回。
 *
 * 白名单必须和阿里云 relay 里的 `PROXY_HOSTS` 一致，改一边就要改另一边。
 */
object JarUpstreamProxy {
    private const val TAG = "FXJarProxy"

    /** 阿里云 relay 地址（安全组只放行 8787/22，所以不走别的端口）。 */
    private const val PROXY_HOST = "47.96.0.112"
    private const val PROXY_PORT = 8787

    /** 代理连不上后多久恢复直连重试。 */
    private const val DOWN_COOLDOWN_MS = 60_000L

    /** 与阿里云 `/proxy/health` 里的 hosts 列表一一对应。 */
    private val HOSTS = setOf(
        "103.45.132.22",          // 咕噜 列表/搜索 boot API
        "111.170.58.215",         // 咕噜 解析 api.php
        "172.247.189.48",         // 咕噜 解析 dsxt/api.php
        "co4k.1ljx.com",          // 咕噜 解析 api
        "api.nbyjson.top",        // 咕噜 解析 api
        "jf.hxx2023.cc",          // 咕噜 解析 api
        "api.extscreen.com",      // 壳通用 token
        "mobilecdnbj.kugou.com",  // 音乐壳
        "krcs.kugou.com",
        "lyrics.kugou.com"
    )

    @Volatile
    private var installed = false

    /** 代理失效截止时间戳（这段时间内走直连）。 */
    @Volatile
    private var downUntil = 0L

    @Volatile
    private var failed = 0L

    @Volatile
    private var routed = 0L

    /** host 大小写无关命中白名单。 */
    private fun allowed(host: String): Boolean = HOSTS.any { it.equals(host, ignoreCase = true) }

    /** 在 [JarSpiderPlugin.attach] 里调用一次即可。 */
    fun install() {
        if (installed) return
        synchronized(this) {
            if (installed) return
            try {
                ProxySelector.setDefault(
                    object : ProxySelector() {
                        override fun select(uri: URI?): List<Proxy> {
                            // 用 equals(ignoreCase) 而不是 lowercase()：Kotlin 2.x 把
                            // String.toLowerCase() 标成 ERROR 级弃用，写了就直接编译红。
                            val host = uri?.host
                            if (host == null || !allowed(host)) {
                                return listOf(Proxy.NO_PROXY)
                            }
                            if (System.currentTimeMillis() < downUntil) {
                                return listOf(Proxy.NO_PROXY)
                            }
                            routed++
                            return listOf(
                                Proxy(Proxy.Type.HTTP, InetSocketAddress(PROXY_HOST, PROXY_PORT))
                            )
                        }

                        override fun connectFailed(uri: URI?, sa: SocketAddress?, ioe: IOException?) {
                            failed++
                            downUntil = System.currentTimeMillis() + DOWN_COOLDOWN_MS
                            Log.w(
                                TAG,
                                "出口代理失败，${DOWN_COOLDOWN_MS}ms 内直连：${ioe?.message} uri=$uri"
                            )
                        }
                    }
                )
                installed = true
                Log.i(TAG, "jar 上游出口代理就绪：$PROXY_HOST:$PROXY_PORT，白名单 ${HOSTS.size} 个 host")
            } catch (t: Throwable) {
                Log.w(TAG, "装出口代理失败（其它功能不受影响）：${t.message}")
            }
        }
    }

    /** 状态页 / 排障用：一眼看出代理是否在生效、有没有降级。 */
    fun status(): Map<String, Any> = mapOf(
        "installed" to installed,
        "proxy" to "$PROXY_HOST:$PROXY_PORT",
        "degraded" to (System.currentTimeMillis() < downUntil),
        "routed" to routed,
        "failed" to failed,
        "hosts" to HOSTS.size
    )
}

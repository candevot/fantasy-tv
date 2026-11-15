package com.huanxiang.fantasy_tv

import android.content.Context
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.zip.ZipFile
import android.os.Handler
import android.os.Looper

/**
 * `MethodChannel('fantasy_tv/spider')` 的原生实现（JAR_SPIDER）。
 *
 * 职责只有三件：
 *   1. **jar 文件管理**：下载 / 校验 md5 / 落到 `filesDir/spiders/<md5>.jar` /
 *      记录「当前生效的 jar」；内置 jar（`assets/spiders/spider.jar`）也认，
 *      没有下载过时自动解出来，保证离线也能用。
 *   2. **实例生命周期**：按当前 jar 的 md5 分配 dex 缓存目录
 *      （`filesDir/dex/<md5>`），md5 变了就销毁旧 [JarSpiderLoader] 换新的 ——
 *      否则 DexClassLoader 会命中上一次的 odex，改了 jar 也还是旧类。
 *   3. **通道分发**：所有方法丢到后台线程，结果回主线程。
 *      加载器本身已经有 25 秒超时 + 全异常兜底，返回值永远是 JSON 字符串，
 *      Dart 侧先看 `error` 字段，不需要 try/catch 通道异常。
 *
 * 与 ExoPlayer 插件的关系：互不相干。本类不碰播放器，只在 Dart 侧取数据时
 * 出现；[JarSpiderLoader] 里的 okhttp 连接池与播放器的 ExoPlayer 数据源分开，
 * 不会互相抢带宽（各自的 client）。
 */
class JarSpiderPlugin(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "fantasy_tv/spider"
        const val TAG = "FXSpider"

        /** 内置 jar 的 assets 路径（可选，没有就只靠下载）。 */
        const val ASSET_JAR = "spiders/spider.jar"

        private const val PREF = "fx_jar_spider"
        private const val KEY_PATH = "jar_path"
        private const val KEY_MD5 = "jar_md5"

        /** jar 从哪来：downloaded / manual / bundled（状态页据此写「内置」）。 */
        private const val KEY_SOURCE = "jar_source"

        /**
         * 用户主动卸载过内置 jar：下次启动不要再自动从 assets 解出来。
         * 重新安装（下载 / 选文件 / 点「用内置」）时清掉。
         */
        private const val KEY_BUNDLE_OFF = "bundled_off"

        /** 下载进度回传间隔：250ms 一次，别把通道刷爆。 */
        private const val PROGRESS_INTERVAL_MS = 250L

        private const val UA =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    }

    private val appContext: Context = context.applicationContext ?: context

    private var channel: MethodChannel? = null

    /** 通道线程池：安装 / 查询 / 取数据分开跑，别让一次下载卡住搜索。 */
    private val executor: ExecutorService = Executors.newFixedThreadPool(2) { runnable ->
        Thread(runnable, "fx-jar-channel").apply {
            isDaemon = true
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    /** 当前生效的加载器 + 它对应的 md5（md5 变了才重建）。 */
    @Volatile
    private var loader: JarSpiderLoader? = null

    @Volatile
    private var loaderMd5: String = ""

    /* ------------------------------------------------------------ 生命周期 */

    /** MainActivity 里调用：注册通道。 */
    fun attach(messenger: BinaryMessenger) {
        channel?.setMethodCallHandler(null)
        channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }
        Log.i(TAG, "通道就绪：$CHANNEL")
    }

    /** 页面销毁 / 引擎销毁时调用。 */
    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        loader?.destroy()
        loader = null
        loaderMd5 = ""
    }

    /* ------------------------------------------------------------ 通道 */

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val method = call.method
        runAsync(result) {
            when (method) {
                "jarInstall" -> install(call)
                "installFromPath" -> installFromPath(call)
                "installBundled" -> installBundled()
                "selfTest" -> selfTestCall(call)
                "status" -> status()
                "uninstall" -> uninstall()
                "destroy" -> {
                    loader?.destroy()
                    loader = null
                    loaderMd5 = ""
                    mapOf<String, Any?>("ok" to true)
                }
                "spider" -> spiderCall(call) { api, ext ->
                    loader(api).home(api, ext, call.argument<Boolean>("filter") ?: false)
                }
                "home" -> spiderCall(call) { api, ext ->
                    loader(api).home(api, ext, call.argument<Boolean>("filter") ?: false)
                }
                "homeVideo" -> spiderCall(call) { api, ext ->
                    loader(api).homeVideo(api, ext)
                }
                "search" -> spiderCall(call) { api, ext ->
                    loader(api).search(
                        api,
                        ext,
                        call.argument<String>("key") ?: "",
                        call.argument<Boolean>("quick") ?: true,
                        call.argument<Int>("page") ?: 1,
                    )
                }
                "detail" -> spiderCall(call) { api, ext ->
                    loader(api).detail(api, ext, idsOf(call))
                }
                "category" -> spiderCall(call) { api, ext ->
                    loader(api).category(
                        api,
                        ext,
                        call.argument<String>("tid") ?: "",
                        call.argument<Int>("page") ?: 1,
                        call.argument<Boolean>("filter") ?: false,
                        stringMap(call.argument<Any?>("extend")),
                    )
                }
                "player" -> spiderCall(call) { api, ext ->
                    loader(api).player(
                        api,
                        ext,
                        call.argument<String>("flag") ?: "",
                        call.argument<String>("id") ?: "",
                        stringList(call.argument<Any?>("vipFlags")),
                    )
                }
                "live" -> spiderCall(call) { api, ext ->
                    loader(api).live(api, ext, call.argument<String>("url") ?: "")
                }
                else -> null
            }
        }
    }

    /** 统一的「后台跑 + 主线程回话 + 全异常兜底」。 */
    private fun runAsync(result: MethodChannel.Result, block: () -> Any?) {
        executor.execute {
            val value = try {
                Result.success(block())
            } catch (e: Throwable) {
                Log.w(TAG, "通道方法失败：${e.javaClass.simpleName}: ${e.message}")
                Result.failure<Any?>(e)
            }
            mainHandler.post {
                value.fold(
                    onSuccess = { result.success(it) },
                    onFailure = { result.error("spider", it.message ?: it.javaClass.simpleName, null) },
                )
            }
        }
    }

    /* ------------------------------------------------------------ 进度回传 */

    @Volatile
    private var lastProgressAt = 0L

    /**
     * 下载 / 校验 / 安装进度回传给 Flutter（`jarInstallProgress`）。
     *
     * 通道是双向的：Dart 侧 `JarSpider.installProgress` 监听这个方法，
     * 设置页用 percent 画进度条；total <= 0 时 percent = -1（不确定进度）。
     * 250ms 节流 + 主线程 invokeMethod：下载线程里不能直接碰通道。
     */
    private fun reportProgress(phase: String, url: String, received: Long, total: Long) {
        val now = System.currentTimeMillis()
        if (phase == "download" && now - lastProgressAt < PROGRESS_INTERVAL_MS) return
        lastProgressAt = now
        val percent = if (total > 0) ((received * 100L) / total).toInt().coerceIn(0, 100) else -1
        mainHandler.post {
            try {
                channel?.invokeMethod(
                    "jarInstallProgress",
                    mapOf(
                        "phase" to phase,
                        "url" to url,
                        "received" to received,
                        "total" to total,
                        "percent" to percent,
                    ),
                )
            } catch (ignored: Throwable) {
                // 通道已销毁 / Dart 侧没监听：进度丢了不影响安装本身。
            }
        }
    }

    /* ------------------------------------------------------------ jar 调用 */

    /**
     * 取数据：任何失败都返回 JSON 字符串（不是通道异常），
     * Dart 侧统一按 `{"error": …}` 处理。
     */
    private fun spiderCall(
        call: MethodCall,
        block: (String, String) -> String,
    ): String {
        val api = (call.argument<String>("api") ?: "").trim()
        val ext = call.argument<String>("ext") ?: ""
        if (api.isEmpty()) {
            return errorJson("no_api", "这个源没有配置 api（jar 类名）")
        }
        if (currentJar() == null) {
            return errorJson("no_jar", "还没有安装 jar 源插件，请先在片源页安装")
        }
        return try {
            // 同一个 api 可能配了不同 ext，加载器按 (api, ext) 自己管 init。
            block(api, ext)
        } catch (e: Throwable) {
            Log.w(TAG, "调用失败：${e.javaClass.simpleName}: ${e.message}")
            errorJson("failed", e.message ?: e.javaClass.simpleName)
        }
    }

    /**
     * 自检：装完 jar 后确认它真的能跑（默认 `csp_Douban` 的 `homeContent`）。
     *
     * 返回值结构（Flutter 侧 `JarSelfTest.fromMap` 解析）：
     * ```
     * {ok, api, stage, code?, error?, className?, classes?, items?, sample?,
     *  elapsedMs, md5, size, source, jarPath}
     * ```
     * 失败时 `stage` 指出卡在哪一步（resolve / instantiate / init / call /
     * parse），`code` 是原因（no_class / missing_dependency / no_method …），
     * 页面上直接把 `error` 原文显示出来，不用连 adb 看日志。
     */
    private fun selfTestCall(call: MethodCall): Map<String, Any?> {
        val api = (call.argument<String>("api") ?: "").trim().ifEmpty { "csp_Douban" }
        val ext = call.argument<String>("ext") ?: ""
        val jar = currentJar()
            ?: return mapOf(
                "ok" to false,
                "api" to api,
                "stage" to "jar",
                "code" to "no_jar",
                "error" to "还没有安装 jar 源插件",
                "elapsedMs" to 0,
            )
        val md5 = jarMd5(jar)
        val source = prefs().getString(KEY_SOURCE, "") ?: ""
        val base = mapOf<String, Any?>(
            "jarPath" to jar.absolutePath,
            "size" to jar.length(),
            "md5" to md5,
            "source" to source,
        )
        val result = try {
            loader(api).selfTest(api, ext)
        } catch (e: Throwable) {
            mapOf<String, Any?>(
                "ok" to false,
                "api" to api,
                "stage" to "loader",
                "code" to ((e as? JarSpiderException)?.code ?: "failed"),
                "error" to (e.message ?: e.javaClass.simpleName),
                "elapsedMs" to 0,
            )
        }
        return base + result
    }

    /** 取（必要时重建）加载器。jar 换了必须重建，否则加载到的是旧 odex。 */
    private fun loader(api: String): JarSpiderLoader {
        val jar = currentJar() ?: throw JarSpiderException("no_jar", "还没有安装 jar 源插件")
        val md5 = jarMd5(jar)
        loader?.let { hit ->
            if (md5 == loaderMd5) return hit
            Log.i(TAG, "jar 变了（$loaderMd5 → $md5），重建加载器")
            hit.destroy()
            loader = null
        }
        synchronized(this) {
            loader?.let { hit ->
                if (md5 == loaderMd5) return hit
                hit.destroy()
                loader = null
            }
            val dexDir = File(File(appContext.filesDir, "dex"), md5)
            if (dexDir.exists()) dexDir.deleteRecursively()
            dexDir.mkdirs()
            val made = JarSpiderLoader(appContext, jar, dexDir)
            loader = made
            loaderMd5 = md5
            Log.i(TAG, "加载器就绪：${jar.name} md5=$md5 api=$api")
            return made
        }
    }

    /* ------------------------------------------------------------ jar 文件 */

    private fun spidersDir(): File {
        val dir = File(appContext.filesDir, "spiders")
        if (!dir.exists()) dir.mkdirs()
        return dir
    }

    private fun prefs() = appContext.getSharedPreferences(PREF, Context.MODE_PRIVATE)

    /** 当前生效的 jar：优先用装好的，其次解内置 assets 的那一份。 */
    private fun currentJar(): File? {
        val path = prefs().getString(KEY_PATH, "") ?: ""
        if (path.isNotEmpty()) {
            val f = File(path)
            if (f.isFile && f.length() > 0) return f
        }
        // 用户点过「卸载」：不要再偷偷把内置 jar 解出来，否则卸载等于没卸。
        if (prefs().getBoolean(KEY_BUNDLE_OFF, false)) return null
        return extractAssetJar()
    }

    /** 内置 jar（可选）：首次使用时从 assets 解到 filesDir，之后走同一套路径。 */
    private fun extractAssetJar(): File? {
        val target = File(spidersDir(), "bundled.jar")
        if (target.isFile && target.length() > 0) return target
        return try {
            appContext.assets.open(ASSET_JAR).use { input ->
                FileOutputStream(target).use { out -> input.copyTo(out) }
            }
            val md5 = jarMd5(target)
            prefs().edit()
                .putString(KEY_PATH, target.absolutePath)
                .putString(KEY_MD5, md5)
                .putString(KEY_SOURCE, "bundled")
                .apply()
            Log.i(TAG, "已解出内置 jar：${target.absolutePath} md5=$md5")
            target
        } catch (e: Throwable) {
            // assets 里没放 jar：正常情况，等用户下载。
            null
        }
    }

    private fun jarMd5(file: File): String {
        val cached = prefs().getString(KEY_MD5, "") ?: ""
        val cachedPath = prefs().getString(KEY_PATH, "") ?: ""
        if (cached.isNotEmpty() && cachedPath == file.absolutePath) return cached
        val md5 = md5Of(file)
        prefs().edit().putString(KEY_MD5, md5).putString(KEY_PATH, file.absolutePath).apply()
        return md5
    }

    /* ------------------------------------------------------------ 安装 */

    /** `install(url)` / `install(url, md5)`：下载 → 校验 → 落盘 → 换加载器。 */
    private fun install(call: MethodCall): Map<String, Any?> {
        val url = (call.argument<String>("url") ?: "").trim()
        if (url.isEmpty()) throw JarSpiderException("bad_url", "没有下载地址")
        val expect = (call.argument<String>("md5") ?: "").trim().lowercase()
        return installJar(url, expect)
    }

    /** 本地文件安装（真机 adb push / 用户选择的文件）：不再下载。 */
    private fun installFromPath(call: MethodCall): Map<String, Any?> {
        val path = (call.argument<String>("path") ?: "").trim()
        if (path.isEmpty()) throw JarSpiderException("bad_path", "没有文件路径")
        val src = File(path)
        if (!src.isFile) throw JarSpiderException("bad_path", "文件不存在：$path")
        reportProgress("verify", "file://$path", src.length(), src.length())
        val map = adopt(src, "", "manual")
        reportProgress("done", "file://$path", src.length(), src.length())
        return map
    }

    private fun installJar(url: String, expectMd5: String): Map<String, Any?> {
        val tmp = File(spidersDir(), "download.tmp")
        if (tmp.exists()) tmp.delete()
        val started = System.currentTimeMillis()
        reportProgress("start", url, 0, 0)
        try {
            download(url, tmp) { received, total ->
                reportProgress("download", url, received, total)
            }
            Log.i(TAG, "下载完成 ${tmp.length()} bytes, " +
                "${System.currentTimeMillis() - started}ms, $url")
            reportProgress("verify", url, tmp.length(), tmp.length())
            val map = adopt(tmp, expectMd5, "downloaded")
            reportProgress("done", url, map["size"] as? Long ?: tmp.length(), tmp.length())
            return map
        } catch (e: Throwable) {
            reportProgress("error", url, 0, 0)
            throw e
        } finally {
            if (tmp.exists()) tmp.delete()
        }
    }

    /** 用安装包里内置的 `assets/spiders/spider.jar`（不联网）。 */
    private fun installBundled(): Map<String, Any?> {
        val target = File(spidersDir(), "bundled.jar")
        try {
            appContext.assets.open(ASSET_JAR).use { input ->
                FileOutputStream(target).use { out -> input.copyTo(out) }
            }
        } catch (e: Throwable) {
            throw JarSpiderException("no_asset", "安装包里没有内置 spider.jar（assets/$ASSET_JAR）")
        }
        prefs().edit().putBoolean(KEY_BUNDLE_OFF, false).apply()
        reportProgress("verify", "asset://$ASSET_JAR", target.length(), target.length())
        val map = adopt(target, "", "bundled")
        reportProgress("done", "asset://$ASSET_JAR", target.length(), target.length())
        return map
    }

    /** 校验 → 按 md5 命名落盘 → 记录 → 换加载器。 */
    private fun adopt(
        source: File,
        expectMd5: String,
        kind: String = "manual",
    ): Map<String, Any?> {
        if (!source.isFile || source.length() < 1024) {
            throw JarSpiderException("bad_jar", "文件太小，不是有效的 jar")
        }
        val md5 = md5Of(source)
        if (expectMd5.isNotEmpty() && expectMd5 != md5) {
            throw JarSpiderException("md5_mismatch", "md5 不匹配：期望 $expectMd5，实际 $md5")
        }
        // 是真 jar（zip 里有 .class）才收，避免把 404 页面 / 网页存成 jar。
        if (!looksLikeJar(source)) {
            throw JarSpiderException("bad_jar", "不是有效的 jar（没有 class 文件）")
        }
        // 内置 jar 保留固定文件名 `bundled.jar`：状态页要能一眼看出「这是内置的」，
        // 下载 / 手动的按 md5 命名，同一个 jar 重复装不会堆文件。
        val target = if (kind == "bundled") {
            File(spidersDir(), "bundled.jar")
        } else {
            File(spidersDir(), "$md5.jar")
        }
        if (target.exists()) {
            if (source.absolutePath != target.absolutePath) source.delete()
        } else if (source.absolutePath != target.absolutePath) {
            if (!source.renameTo(target)) {
                source.copyTo(target, overwrite = true)
                source.delete()
            }
        }
        prefs().edit()
            .putString(KEY_PATH, target.absolutePath)
            .putString(KEY_MD5, md5)
            .putString(KEY_SOURCE, kind)
            .putBoolean(KEY_BUNDLE_OFF, false)
            .apply()
        // 换 jar → 旧加载器立即释放，下次调用按新 md5 重建 dex 目录。
        loader?.destroy()
        loader = null
        loaderMd5 = ""
        Log.i(TAG, "jar 已安装：${target.absolutePath} md5=$md5")
        return mapOf(
            "ok" to true,
            "path" to target.absolutePath,
            "md5" to md5,
            "size" to target.length(),
        )
    }

    private fun download(
        url: String,
        dst: File,
        onProgress: (Long, Long) -> Unit = { _, _ -> },
    ) {
        if (url.startsWith("file://")) {
            val src = File(url.removePrefix("file://"))
            if (!src.isFile) throw JarSpiderException("bad_url", "本地文件不存在")
            src.copyTo(dst, overwrite = true)
            onProgress(src.length(), src.length())
            return
        }
        if (!url.startsWith("http://") && !url.startsWith("https://")) {
            throw JarSpiderException("bad_url", "只支持 http(s) 地址")
        }
        var conn: HttpURLConnection? = null
        try {
            val connection = (URL(url).openConnection() as HttpURLConnection).apply {
                connectTimeout = 20_000
                readTimeout = 60_000
                instanceFollowRedirects = true
                setRequestProperty("User-Agent", UA)
                setRequestProperty("Accept", "*/*")
            }
            conn = connection
            val code = connection.responseCode
            if (code >= 400) throw JarSpiderException("http_$code", "下载失败：HTTP $code")
            // minSdk 23：contentLengthLong 是 API 24，只能用 Int 版（-1 = 未知）。
            val total = connection.contentLength.toLong()
            var received = 0L
            connection.inputStream.use { input ->
                FileOutputStream(dst).use { out ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n <= 0) break
                        out.write(buf, 0, n)
                        received += n
                        onProgress(received, total)
                    }
                }
            }
            if (dst.length() < 1024) {
                throw JarSpiderException("bad_jar", "下载到的内容太小（${dst.length()} bytes）")
            }
        } finally {
            try {
                conn?.disconnect()
            } catch (ignored: Throwable) {
            }
        }
    }

    /**
     * zip 里有没有可加载的字节码：`.class` **或 `classes.dex`** 才算。
     *
     * 为什么两种都收：线上肥猫那批 spider.jar 是 **dex 包**
     * （`classes.dex` + META-INF，176KB / 解压 3.8MB），
     * 之前只认 `.class` 会把它当「不是有效的 jar」直接拒掉 ——
     * 这才是「下到了正确的 jar 却装不上」的隐藏原因。
     */
    private fun looksLikeJar(file: File): Boolean = try {
        ZipFile(file).use { zip ->
            val entries = zip.entries()
            var found = false
            while (entries.hasMoreElements()) {
                val name = entries.nextElement().name
                if (name.endsWith(".class") || name == "classes.dex" || name.endsWith(".dex")) {
                    found = true
                    break
                }
            }
            found
        }
    } catch (e: Throwable) {
        false
    }

    /** 卸载：释放加载器 + 删掉 filesDir/spiders 下的 jar 与记录。 */
    private fun uninstall(): Map<String, Any?> {
        loader?.destroy()
        loader = null
        loaderMd5 = ""
        val dir = spidersDir()
        dir.listFiles()?.forEach { file ->
            try {
                file.delete()
            } catch (ignored: Throwable) {
            }
        }
        // clear 之后立刻写回「别再用内置」：否则下一次 status() 又会把
        // assets 里的 spider.jar 解出来，用户点了卸载却还是「已安装」。
        prefs().edit().clear().putBoolean(KEY_BUNDLE_OFF, true).apply()
        Log.i(TAG, "已卸载 jar（${dir.absolutePath}）")
        return mapOf("ok" to true)
    }

    /* ------------------------------------------------------------ 状态 */

    private fun status(): Map<String, Any?> {
        val jar = currentJar()
        if (jar == null) {
            return mapOf(
                "installed" to false,
                "path" to "",
                "md5" to "",
                "size" to 0,
            )
        }
        val source = prefs().getString(KEY_SOURCE, "") ?: ""
        return mapOf(
            "installed" to true,
            "path" to jar.absolutePath,
            "md5" to jarMd5(jar),
            "size" to jar.length(),
            "bundled" to (source == "bundled" || jar.name.startsWith("bundled")),
            "source" to source,
        )
    }

    /* ------------------------------------------------------------ 工具 */

    private fun idsOf(call: MethodCall): List<String> {
        val raw = call.argument<Any?>("ids")
        val out = ArrayList<String>()
        if (raw is List<*>) {
            for (e in raw) {
                val text = e?.toString()?.trim() ?: ""
                if (text.isNotEmpty()) out.add(text)
            }
        } else if (raw is String) {
            for (part in raw.split(',', '|')) {
                val text = part.trim()
                if (text.isNotEmpty()) out.add(text)
            }
        }
        if (out.isEmpty()) throw JarSpiderException("no_ids", "没有传影片 id")
        return out
    }

    private fun stringMap(raw: Any?): Map<String, String> {
        val out = HashMap<String, String>()
        if (raw is Map<*, *>) {
            for ((k, v) in raw) {
                val key = k?.toString() ?: continue
                out[key] = v?.toString() ?: ""
            }
        }
        return out
    }

    private fun stringList(raw: Any?): List<String> {
        val out = ArrayList<String>()
        if (raw is List<*>) {
            for (e in raw) {
                val text = e?.toString()?.trim() ?: ""
                if (text.isNotEmpty()) out.add(text)
            }
        } else if (raw is String && raw.isNotBlank()) {
            out.add(raw.trim())
        }
        return out
    }

    private fun md5Of(file: File): String {
        val digest = MessageDigest.getInstance("MD5")
        file.inputStream().use { input ->
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buf)
                if (n <= 0) break
                digest.update(buf, 0, n)
            }
        }
        val out = digest.digest()
        val sb = StringBuilder(out.size * 2)
        for (b in out) {
            val v = b.toInt() and 0xFF
            if (v < 16) sb.append('0')
            sb.append(Integer.toHexString(v))
        }
        return sb.toString()
    }

    private fun errorJson(code: String, message: String): String =
        JSONObject().put("error", message).put("code", code).toString()
}

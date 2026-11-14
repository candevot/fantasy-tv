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
            prefs().edit().putString(KEY_PATH, target.absolutePath).putString(KEY_MD5, md5).apply()
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
        return adopt(src, "")
    }

    private fun installJar(url: String, expectMd5: String): Map<String, Any?> {
        val tmp = File(spidersDir(), "download.tmp")
        if (tmp.exists()) tmp.delete()
        val started = System.currentTimeMillis()
        try {
            download(url, tmp)
            Log.i(TAG, "下载完成 ${tmp.length()} bytes, " +
                "${System.currentTimeMillis() - started}ms, $url")
            return adopt(tmp, expectMd5)
        } finally {
            if (tmp.exists()) tmp.delete()
        }
    }

    /** 校验 → 按 md5 命名落盘 → 记录 → 换加载器。 */
    private fun adopt(source: File, expectMd5: String): Map<String, Any?> {
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
        val target = File(spidersDir(), "$md5.jar")
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

    private fun download(url: String, dst: File) {
        if (url.startsWith("file://")) {
            val src = File(url.removePrefix("file://"))
            if (!src.isFile) throw JarSpiderException("bad_url", "本地文件不存在")
            src.copyTo(dst, overwrite = true)
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
            connection.inputStream.use { input ->
                FileOutputStream(dst).use { out -> input.copyTo(out) }
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

    /** zip 里有没有 .class：有才当 jar。 */
    private fun looksLikeJar(file: File): Boolean = try {
        ZipFile(file).use { zip ->
            val entries = zip.entries()
            var found = false
            while (entries.hasMoreElements()) {
                if (entries.nextElement().name.endsWith(".class")) {
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
        prefs().edit().clear().apply()
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
        return mapOf(
            "installed" to true,
            "path" to jar.absolutePath,
            "md5" to jarMd5(jar),
            "size" to jar.length(),
            "bundled" to jar.name.startsWith("bundled"),
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

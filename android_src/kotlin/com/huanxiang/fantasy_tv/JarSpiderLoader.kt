package com.huanxiang.fantasy_tv

import android.content.Context
import android.util.Log
import dalvik.system.DexClassLoader
import org.json.JSONObject
import java.io.File
import java.lang.reflect.Method
import java.util.concurrent.Callable
import java.util.concurrent.ExecutionException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.zip.ZipFile

/**
 * TVBox jar 源（`{"type":3,"api":"csp_Xxx","ext":"…"}`）的加载器（JAR_SPIDER）。
 *
 * 工作原理照 TVBox：
 *   1. jar 用 [DexClassLoader] 加载，**父加载器是 App 自己的** ——
 *      `com.github.catvod.crawler.Spider` 基类在 `android_src/libs/api.jar`
 *      里，已经随 APK 打进 classpath，所以 jar 里的子类能正常继承；
 *   2. `api` 是类名（`csp_Xxx` / 全限定名），反射 newInstance 后调
 *      `init(context, ext)`，得到 Spider 实例并缓存；
 *   3. 每个接口（home / category / detail / search / player）用反射调用，
 *      返回值都是 **JSON 字符串**，本类原样交给 Flutter，不做二次拼装。
 *
 * 三条硬约束（都是踩过的坑）：
 *   · **绝不抛异常出去**：所有反射调用走 [guard]，失败返回
 *     `{"error":"…","code":"…"}`。jar 是第三方代码，崩一次就是整个 App 崩，
 *     而这类源普遍会用 System.exit 之外的野路子（空指针、类型转换），
 *     所以这里连 `Throwable` 都接（OOM / StackOverflow / NoClassDefFoundError
 *     都能接住并降级）。
 *   · **必须在独立线程跑**：jar 里的实现基本都是同步网络请求（okhttp 同步
 *     `execute()`），在 UI 线程调就是 ANR。这里自带单线程 worker，
 *     既离屏又天然串行 —— 很多 jar 有静态状态，并发调会互相串数据。
 *   · **签名要宽容**：`categoryContent` 第二参线上是 String（页码），
 *     老代码里有 boolean 的写法；`searchContent` 有两参 / 三参两个版本。
 *     [coerce] 按目标形参类型做类型转换，找不到同名方法再按「同名 + 参数个数」
 *     兜底，避免一个字符的差异就让整个源不可用。
 *
 * md5 变化 → 换 jar：dex 缓存目录（[dexDir]）里是上一次的 odex，名字一样但
 * 内容变了会加载到旧类，所以 [JarSpiderPlugin] 在 md5 变化时换一个新的
 * dexDir（`dex/<md5>`），旧目录整个删掉。[destroy] 负责释放 ClassLoader 引用，
 * 让 GC 能回收；DexClassLoader 本身没有 close()，只能丢引用。
 */
class JarSpiderLoader(
    private val context: Context,
    private val jarPath: File,
    private val dexDir: File,
) {
    companion object {
        const val TAG = "FXSpider"

        /** 单次反射调用的默认超时：jar 里的同步请求最长给 25 秒。 */
        const val DEFAULT_TIMEOUT_MS = 25_000L

        /** 类名没有包名时补这个前缀（TVBox 的约定）。 */
        const val CLASS_PREFIX = "com.github.catvod.spider."
    }

    /** 懒创建的 DexClassLoader：jar 不存在时永远不该建它。 */
    @Volatile
    private var loader: DexClassLoader? = null

    /** api（类名）→ Spider 实例。 */
    private val cache = HashMap<String, Any>()

    /** api → 上次 init 用的 ext（ext 变了要重新 init）。 */
    private val initedWith = HashMap<String, String>()

    private val lock = Any()

    /** 串行 worker：jar 实现多为同步网络请求，且常有静态状态。 */
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "fx-jar-spider").apply {
            isDaemon = true
            priority = Thread.NORM_PRIORITY - 1
        }
    }

    @Volatile
    private var destroyed = false

    /* ------------------------------------------------------------ 类加载 */

    /** 取（必要时创建）DexClassLoader。父加载器 = App 加载器（api.jar 在里面）。 */
    private fun classLoader(): DexClassLoader {
        loader?.let { return it }
        synchronized(lock) {
            loader?.let { return it }
            if (!jarPath.isFile) {
                throw JarSpiderException("no_jar", "jar 不存在：${jarPath.name}")
            }
            if (!dexDir.exists() && !dexDir.mkdirs()) {
                throw JarSpiderException("no_dex_dir", "无法创建 dex 目录")
            }
            val parent = context.classLoader
            val made = DexClassLoader(jarPath.absolutePath, dexDir.absolutePath, null, parent)
            loader = made
            Log.i(TAG, "DexClassLoader 就绪 jar=${jarPath.name} dex=${dexDir.absolutePath}")
            return made
        }
    }

    /**
     * `api` → Class。
     *
     * 依次尝试：全限定名 → `com.github.catvod.spider.` 前缀 →
     * 去掉 `csp_` 前缀 → 扫 jar 条目按「简单类名」匹配。
     * 最后一步是给那些类名和配置里的 api 不一致的 jar 兜底
     * （例如配置写 `csp_AppYsV2` 而类叫 `AppYsV2`）。
     */
    private fun resolveClass(api: String): Class<*> {
        val raw = api.trim()
        if (raw.isEmpty()) throw JarSpiderException("no_api", "没有配置 api（类名）")
        val cl = classLoader()

        val candidates = LinkedHashSet<String>()
        if (raw.contains('.')) candidates.add(raw) else candidates.add(CLASS_PREFIX + raw)
        if (raw.startsWith("csp_")) {
            val bare = raw.removePrefix("csp_")
            candidates.add(CLASS_PREFIX + bare)
            candidates.add(bare)
        } else {
            candidates.add(CLASS_PREFIX + "csp_" + raw)
        }
        candidates.add(raw)

        for (name in candidates) {
            try {
                return Class.forName(name, true, cl)
            } catch (ignored: Throwable) {
                // 下一个候选
            }
        }

        // 兜底：按 jar 里的条目找「简单类名相同」的类。
        val simpleNames = LinkedHashSet<String>()
        simpleNames.add(raw)
        if (raw.startsWith("csp_")) simpleNames.add(raw.removePrefix("csp_"))
        simpleNames.add("csp_" + raw)
        val hit = scanClassNames(simpleNames)
        if (hit != null) {
            return Class.forName(hit, true, cl)
        }
        throw JarSpiderException("no_class", "jar 里没有这个类：$raw")
    }

    /** 扫 jar 条目，找到简单名匹配的类全名（找不到返回 null）。 */
    private fun scanClassNames(simpleNames: Set<String>): String? {
        return try {
            ZipFile(jarPath).use { zip ->
                val entries = zip.entries()
                while (entries.hasMoreElements()) {
                    val name = entries.nextElement().name
                    if (!name.endsWith(".class") || name.contains("$")) continue
                    val simple = name.substringAfterLast('/').removeSuffix(".class")
                    if (!simpleNames.contains(simple)) continue
                    if (name.startsWith("android/") || name.startsWith("androidx/")) continue
                    return name.removeSuffix(".class").replace('/', '.')
                }
                null
            }
        } catch (e: Throwable) {
            Log.w(TAG, "扫 jar 条目失败：${e.message}")
            null
        }
    }

    /* ------------------------------------------------------------ 实例 */

    /**
     * 取（必要时创建并 init）Spider 实例。
     *
     * `ext` 变化时会重新 init —— 同一个 api 在不同配置里 ext 可能不同，
     * 不重 init 就会拿到上一个站点的数据（表现为「两个源内容一模一样」）。
     */
    fun spider(api: String, ext: String): Any {
        val key = api.trim()
        if (key.isEmpty()) throw JarSpiderException("no_api", "没有配置 api（类名）")
        synchronized(lock) {
            cache[key]?.let { instance ->
                if (initedWith[key] == ext) return instance
                initInstance(instance, ext)
                initedWith[key] = ext
                return instance
            }
            val clz = resolveClass(key)
            val made = try {
                clz.getDeclaredConstructor().newInstance()
            } catch (e: Throwable) {
                // 没有默认构造 / 构造里抛异常
                val inner = (e as? java.lang.reflect.InvocationTargetException)?.targetException ?: e
                throw JarSpiderException(
                    "new_instance_failed",
                    "实例化 ${clz.name} 失败：${inner.javaClass.simpleName}: ${inner.message}",
                )
            }
            initInstance(made, ext)
            cache[key] = made
            initedWith[key] = ext
            Log.i(TAG, "Spider 就绪：${clz.name} ext=${ext.take(40)}")
            return made
        }
    }

    /** 调 init：优先 (Context, String)，只有 (Context) 的 jar 也认。 */
    private fun initInstance(instance: Any, ext: String) {
        val contextParam = context.applicationContext ?: context
        val two = findMethod(instance.javaClass, "init", arrayOf<Any?>(contextParam, ext))
        if (two != null) {
            try {
                two.invoke(instance, contextParam, ext)
                return
            } catch (e: Throwable) {
                val inner = (e as? java.lang.reflect.InvocationTargetException)?.targetException ?: e
                throw JarSpiderException(
                    "init_failed",
                    "init 失败：${inner.javaClass.simpleName}: ${inner.message}",
                )
            }
        }
        val one = findMethod(instance.javaClass, "init", arrayOf<Any?>(contextParam))
        if (one != null) {
            try {
                one.invoke(instance, contextParam)
                return
            } catch (ignored: Throwable) {
                // 老 jar 的 init 只做界面相关的事，失败不影响取数据
            }
        }
    }

    /* ------------------------------------------------------------ 反射 */

    /**
     * 找方法：名字 + 参数个数 + 参数可转换。找不到返回 null。
     *
     * 不用 `getMethod(name, types…)`：jar 的泛型擦除后是 HashMap / List，
     * 但有的写成 Map / ArrayList，直接按类型查会 MethodNotFoundException。
     */
    private fun findMethod(clz: Class<*>, name: String, args: Array<Any?>): Method? {
        val methods = try {
            clz.methods
        } catch (ignored: Throwable) {
            clz.declaredMethods
        }
        var fallback: Method? = null
        for (m in methods) {
            if (m.name != name) continue
            val types = m.parameterTypes
            if (types.size != args.size) continue
            if (m.isBridge || m.isSynthetic) continue
            if (compatible(types, args)) return m
            if (fallback == null) fallback = m
        }
        return fallback
    }

    /** 形参类型能不能吃下这些实参（只做宽判断，真正的转换在 [coerce]）。 */
    private fun compatible(types: Array<Class<*>>, args: Array<Any?>): Boolean {
        for (i in types.indices) {
            val t = types[i]
            val a = args[i] ?: continue
            val ok = when {
                t == String::class.java -> true
                t == java.lang.Boolean.TYPE || t == java.lang.Boolean::class.java -> true
                t == Integer.TYPE || t == java.lang.Integer::class.java -> true
                t == java.lang.Long.TYPE || t == java.lang.Long::class.java -> true
                t.isInstance(a) -> true
                t.isAssignableFrom(a.javaClass) -> true
                Map::class.java.isAssignableFrom(t) -> a is Map<*, *>
                List::class.java.isAssignableFrom(t) -> a is List<*>
                else -> false
            }
            if (!ok) return false
        }
        return true
    }

    /** 按目标形参做类型转换（String ↔ 数字 ↔ 布尔 ↔ Map/List）。 */
    private fun coerce(types: Array<Class<*>>, args: Array<Any?>): Array<Any?> {
        val out = arrayOfNulls<Any?>(args.size)
        for (i in types.indices) {
            val t = types[i]
            val a = args[i]
            out[i] = when {
                a == null -> when {
                    t == java.lang.Boolean.TYPE -> false
                    t == Integer.TYPE -> 0
                    t == java.lang.Long.TYPE -> 0L
                    else -> null
                }
                t == String::class.java -> if (a is String) a else a.toString()
                t == java.lang.Boolean.TYPE || t == java.lang.Boolean::class.java -> when (a) {
                    is Boolean -> a
                    is Number -> a.toInt() != 0
                    is String -> a == "1" || a.equals("true", ignoreCase = true)
                    else -> true
                }
                t == Integer.TYPE || t == java.lang.Integer::class.java -> when (a) {
                    is Number -> a.toInt()
                    is String -> a.trim().toIntOrNull() ?: 0
                    else -> 0
                }
                t == java.lang.Long.TYPE || t == java.lang.Long::class.java -> when (a) {
                    is Number -> a.toLong()
                    is String -> a.trim().toLongOrNull() ?: 0L
                    else -> 0L
                }
                Map::class.java.isAssignableFrom(t) -> if (a is Map<*, *>) a else HashMap<String, String>()
                List::class.java.isAssignableFrom(t) -> if (a is List<*>) a else ArrayList<Any?>()
                t.isInstance(a) -> a
                else -> a
            }
        }
        return out
    }

    /**
     * 调一个 Spider 方法，返回 JSON 字符串。
     *
     * 返回值的三种情况：
     *   · jar 返回了非空 JSON → 原样返回（Flutter 侧负责解析 / 转模型）；
     *   · jar 返回 null / 空串 → `{"error":"返回为空","code":"empty"}`；
     *   · 抛异常 → `{"error":"…","code":"call_failed"}`。
     */
    fun call(api: String, ext: String, method: String, args: Array<Any?>): String {
        val instance = spider(api, ext)
        val m = findMethod(instance.javaClass, method, args)
            ?: throw JarSpiderException(
                "no_method",
                "${instance.javaClass.simpleName} 没有实现 $method/${args.size}",
            )
        val converted = coerce(m.parameterTypes, args)
        val raw = try {
            m.invoke(instance, *converted)
        } catch (e: Throwable) {
            val inner = (e as? java.lang.reflect.InvocationTargetException)?.targetException ?: e
            val message = inner.message ?: inner.javaClass.simpleName
            Log.w(TAG, "$method 抛异常：${inner.javaClass.name}: $message")
            throw JarSpiderException("call_failed", "$method 失败：$message")
        }
        val text = when (raw) {
            null -> ""
            is String -> raw
            else -> raw.toString()
        }
        if (text.isBlank()) throw JarSpiderException("empty", "$method 返回为空")
        return text
    }

    /* ------------------------------------------------------------ 对外接口（全部不抛异常） */

    /** 在 worker 线程执行并兜住所有异常 / 超时。 */
    private fun guard(tag: String, block: () -> String): String {
        if (destroyed) return errorJson("closed", "加载器已释放")
        val task = Callable { block() }
        return try {
            worker.submit(task).get(DEFAULT_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        } catch (e: TimeoutException) {
            Log.w(TAG, "$tag 超时")
            errorJson("timeout", "$tag 超时（${DEFAULT_TIMEOUT_MS / 1000} 秒）")
        } catch (e: ExecutionException) {
            val cause = e.cause ?: e
            val code = (cause as? JarSpiderException)?.code ?: "failed"
            val message = cause.message ?: cause.javaClass.simpleName
            Log.w(TAG, "$tag 失败[$code]：$message")
            if (cause is OutOfMemoryError) errorJson("oom", "$tag 内存不足，换一个源试试") else errorJson(code, message)
        } catch (e: Throwable) {
            Log.w(TAG, "$tag 失败：${e.javaClass.simpleName}: ${e.message}")
            errorJson("failed", e.message ?: e.javaClass.simpleName)
        }
    }

    /** 首页分类 + 首页列表。 */
    fun home(api: String, ext: String, filter: Boolean): String =
        guard("homeContent") { call(api, ext, "homeContent", arrayOf<Any?>(filter)) }

    /** 首页视频墙。 */
    fun homeVideo(api: String, ext: String): String =
        guard("homeVideoContent") { call(api, ext, "homeVideoContent", emptyArray<Any?>()) }

    /** 分类列表。`page` 从 1 开始。 */
    fun category(
        api: String,
        ext: String,
        tid: String,
        page: Int,
        filter: Boolean,
        extend: Map<String, String>,
    ): String = guard("categoryContent") {
        call(
            api,
            ext,
            "categoryContent",
            arrayOf<Any?>(tid, page.coerceAtLeast(1).toString(), filter, HashMap(extend)),
        )
    }

    /**
     * 分类列表（旧签名，第二参是 boolean）。
     *
     * 保留这个重载是为了和 TVBox 里 `categoryContent(tid, pg: Boolean, …)`
     * 的老调用点兼容：`pg == true` 当第 2 页处理（TVBox 里它表示「继续翻页」）。
     * Flutter 侧一律走上面的 [category]（页码是真页码）。
     */
    fun category(
        api: String,
        ext: String,
        tid: String,
        pg: Boolean,
        filter: Boolean,
        extend: Map<String, String>,
    ): String = category(api, ext, tid, if (pg) 2 else 1, filter, extend)

    /** 详情。ids 是 vod_id 列表。 */
    fun detail(api: String, ext: String, ids: List<String>): String =
        guard("detailContent") { call(api, ext, "detailContent", arrayOf<Any?>(ArrayList(ids))) }

    /** 搜索。先试三参（带页码）版本，jar 没实现再试两参版本。 */
    fun search(api: String, ext: String, key: String, quick: Boolean, page: Int = 1): String =
        guard("searchContent") {
            val pageText = page.coerceAtLeast(1).toString()
            try {
                call(api, ext, "searchContent", arrayOf<Any?>(key, quick, pageText))
            } catch (e: JarSpiderException) {
                if (e.code != "no_method") throw e
                call(api, ext, "searchContent", arrayOf<Any?>(key, quick))
            }
        }

    /** 取播放地址。flag = 线路名，id = 该集地址。 */
    fun player(
        api: String,
        ext: String,
        flag: String,
        id: String,
        vipFlags: List<String>,
    ): String = guard("playerContent") {
        call(api, ext, "playerContent", arrayOf<Any?>(flag, id, ArrayList(vipFlags)))
    }

    /** 直播。 */
    fun live(api: String, ext: String, url: String): String =
        guard("liveContent") { call(api, ext, "liveContent", arrayOf<Any?>(url)) }

    /** 这个源是不是要 App 侧再校验播放地址。 */
    fun manualVideoCheck(api: String, ext: String): Boolean = try {
        val instance = spider(api, ext)
        val m = findMethod(instance.javaClass, "manualVideoCheck", emptyArray<Any?>())
        (m?.invoke(instance) as? Boolean) ?: false
    } catch (ignored: Throwable) {
        false
    }

    /* ------------------------------------------------------------ 释放 */

    /** 释放 ClassLoader 与实例缓存（App 退出 / 换 jar 时调）。 */
    fun destroy() {
        destroyed = true
        synchronized(lock) {
            cache.clear()
            initedWith.clear()
            loader = null
        }
        try {
            worker.shutdownNow()
        } catch (ignored: Throwable) {
        }
        Log.i(TAG, "销毁加载器 ${jarPath.name}")
    }
}

/** jar 源调用失败的最小异常类型：带 code，方便 Flutter 侧区分原因。 */
class JarSpiderException(val code: String, message: String) : Exception(message)

/** 统一的错误 JSON（Flutter 侧先看 `error` 字段）。 */
private fun errorJson(code: String, message: String): String =
    JSONObject()
        .put("error", message)
        .put("code", code)
        .toString()

package com.huanxiang.fantasy_tv

import android.app.Activity
import android.content.Context
import android.util.Log
import com.github.catvod.Runtime
import com.github.catvod.crawler.Spider
import com.github.catvod.spider.SpiderApiImpl
import dalvik.system.DexClassLoader
import org.json.JSONObject
import java.io.File
import java.lang.reflect.InvocationTargetException
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
 *
 * **第四条硬约束（DEX_READONLY 2026-11-15）**：Android 14（API 34）起，jar
 * 必须是只读（0444），可写就抛
 * `SecurityException: Writable dex file '…' is not allowed.`。
 * 所以 [classLoader] 在建构造器之前先过一遍 [JarPermissions.makeReadOnly]，
 * 并打日志 `[JarSpider] jar path=… writable=false perms=444`；
 * 输出目录 [dexDir] 反过来必须可写（ART 要往里写 odex），别给它 chmod。
 */
class JarSpiderLoader(
    private val context: Context,
    private val jarPath: File,
    private val dexDir: File,
) {
    companion object {
        const val TAG = "FXSpider"

        /**
         * 单次反射调用的默认超时：**8 秒**（TIMEOUT_UNIFY 2026-11-15）。
         *
         * 原来给 25 秒，比 Dart 侧的 8 秒超时还长 —— 于是每次搜索都有 41 个
         * jar 源把原生那两条通道线程占满 25 秒，虽然 Dart 早就按「这个源没结果」
         * 继续往下走了，原生却还在排队，后面的调用全被堵在队列里。
         * 现在两侧统一 8 秒：Dart 超时的那一刻原生也差不多收工，不会互相拖。
         */
        /**
         * 单次反射调用的默认超时：**12 秒**（JAR_TIMEOUT 2026-11-15）。
         *
         * 8 秒不够：`Gulu.searchContent` 自带 3 次重试 + 500ms×2ⁿ 退避
         * （光睡眠 3.5 秒）再叠加密握手，8 秒经常刚到最后一次重试就被杀，
         * 表现就是「咕噜一条都没有」。Dart 侧 `JarSpider.timeout` 同步 12 秒，
         * 两边别再错位（否则日志里分不清是谁先放弃）。
         */
        const val DEFAULT_TIMEOUT_MS = 12_000L

        /** 并行 worker 数：和 Dart 侧 `JarSpider.maxConcurrentSearches` 对齐。 */
        /**
         * 并行 worker 数（JAR_PARALLEL 2026-11-16）。
         *
         * 原来是 6：41 个源一起搜时后 35 个在队列里排队，排队时间也算进
         * 单源超时 → 只有最前面几个源能出结果（用户看到「只出咕噜」）。
         * 壳是多源并行，这里提到 20，和 Dart 侧
         * `JarSpider.maxConcurrentSearches` 保持一致。
         */
        const val WORKER_THREADS = 20

        /** 类名没有包名时补这个前缀（TVBox 的约定）。 */
        const val CLASS_PREFIX = "com.github.catvod.spider."

        /**
         * fatcat jar 的默认 `Pizazz/config.json`（和 jar 里 `Init.saveConfig`
         * 写出来的一致，只留取数据会用到的键，少写几个键不影响源）。
         */
        const val DEFAULT_FATCAT_CONFIG =
            "{\"version\":\"2.0\",\"update\":\"关闭\"," +
                "\"danmuColor\":\"默认\",\"danmuSearch\":\"开启\"," +
                "\"homePage\":\"猜你喜欢,热门电影,热播剧集,热门动漫,热播综艺," +
                "电影筛选,电视筛选,电影榜单,电视剧榜单\",\"proxyMode\":\"关闭\"}"

        /**
         * 自检单项超时：**25 秒**。
         *
         * 自检要真的走一遍 jar 的网络请求（`csp_Douban.homeContent`），
         * 比日常取数的 8 秒宽一点；但也不能无限等，否则点「自检」的按钮
         * 会一直转。超时同样返回结构化结果（stage=timeout）。
         */
        const val SELF_TEST_TIMEOUT_MS = 25_000L

        /**
         * 单个源的 `init` 上限：**10 秒**（INIT_TIMEOUT 2026-11-16）。
         *
         * 实测（116 源逐个跑 `searchContent("济公传")`）：`csp_SaoHuo.init()`
         * 会同步抓 `http://shapp.us/`，**33 秒**才返回；`csp_Gulu.init()` 174ms。
         * 以前 init 和实例创建一起放在全局 `synchronized(lock)` 里，一个 33 秒的
         * init 就把**所有**源堵在锁外 —— 12 秒单源预算下，116 个源只跑得完 23 个，
         * 用户看到的就是「只出咕噜」。
         *
         * 现在：实例创建仍然短锁，init 挪到锁外、走独立线程池，并在这里限时。
         * 超时的源按「init 超时」记账，[INIT_FAIL_COOLDOWN_MS] 内不再试。
         */
        const val INIT_TIMEOUT_MS = 10_000L

        /** init 失败 / 超时后的冷却：**30 分钟**（和壳的 crash 熔断同一量级）。 */
        const val INIT_FAIL_COOLDOWN_MS = 30 * 60 * 1000L

        /**
         * init 专用线程池条数：**20**，与 [WORKER_THREADS] 对齐（INIT_PARALLEL 2026-11-16）。
         *
         * 曾经写成 3，理由是「慢 init 不该占着 search 的线程」。实测证明那个
         * 取舍是错的 —— 86 个可搜源、20 并发 search，两种 init 池的首屏对比：
         *
         * | init 池 | 1s | 2s | 3s | 5s |
         * |---------|----|----|----|----|
         * | 3 条    | 6 源 | 8 源 | 8 源 | 8 源 |
         * | 20 条   | 7 源 | 10 源 | **14 源** | 20 源 |
         *
         * 原因很简单：**每个源第一次搜索前都必须先 init**，init 池只有 3 条
         * 就等于把「能不能开始搜」的闸门收窄到 3 —— 慢 init 源（金牌 9.1s /
         * 厂长 8.2s / 骚火 5.9s）把 3 条占满时，后面 80 多个源连 search 都发不出去。
         *
         * 壳（FongMi）的 `App.searchExecutor` 就是 20 条，init 直接在搜索线程里
         * 做，所以 SaoHuo 那 33 秒只占 1 条、其余 19 条照跑。这里对齐壳：
         * init 独立池 20 条，既和 search 一样宽，又不会和 search 抢同一批线程
         * （init 慢的时候 search 仍能全速跑已 init 好的源）。
         *
         * 全量 init 成本实测：116 源 / 20 并发 = 墙钟 9.7 秒，其中 >1s 只有 15 个、
         * >3s 只有 5 个 —— init 从来不是「搜索慢」的主因，收窄池子才是。
         */
        const val INIT_THREADS = 20
    }

    /** 懒创建的 DexClassLoader：jar 不存在时永远不该建它。 */
    @Volatile
    private var loader: DexClassLoader? = null

    /** api（类名）→ Spider 实例。 */
    private val cache = java.util.concurrent.ConcurrentHashMap<String, Any>()

    /** api → 上次 init 用的 ext（ext 变了要重新 init）。 */
    private val initedWith = java.util.concurrent.ConcurrentHashMap<String, String>()

    /**
     * api → 这个源「init 还没完成」的 Future（INIT_TIMEOUT 2026-11-16）。
     *
     * 同一实例的 init 与 search 必须串行（jar 里的源大多是单例 + 可变字段），
     * 所以：谁先来谁发起 init，后来的人等同一个 Future，不重复 init。
     */
    private val initTasks = java.util.concurrent.ConcurrentHashMap<String, java.util.concurrent.Future<*>>()

    /** api → init 失败后的冷却到期时间（毫秒）。 */
    private val initCoolDown = java.util.concurrent.ConcurrentHashMap<String, Long>()

    /**
     * init 专用线程池（不和 search 抢线程）。
     *
     * 守护线程：加载器被丢弃时不会阻止进程退出。
     */
    private val initPool: ExecutorService = Executors.newFixedThreadPool(INIT_THREADS) { runnable ->
        Thread(runnable, "fx-jar-init").apply {
            isDaemon = true
            priority = Thread.NORM_PRIORITY - 1
        }
    }

    private val lock = Any()

    /**
     * 每个 api（类名）一把锁：同一个源**串行**，不同源**并行**。
     *
     * JAR_CONCURRENCY（2026-11-15）：jar 里的源大多是「单例 + 可变字段」，
     * 同一个源并发调两次会互相踩（上次的列表、上次的 token）。但**不同源**
     * 之间没有共享状态，串着跑纯属浪费。
     */
    private val apiLocks = java.util.concurrent.ConcurrentHashMap<String, Any>()

    private fun lockOf(api: String): Any =
        apiLocks.computeIfAbsent(api.trim()) { Any() }

    /**
     * 并行 worker（**不是**单线程 —— 这是「肥猫源只出 1 条」的真凶）。
     *
     * 原来是 `newSingleThreadExecutor`：41 个 jar 源一起来的时候全部排进这
     * 一条线程，每个 `guard()` 还要按 [DEFAULT_TIMEOUT_MS] 等自己那一轮 ——
     * 排在后面的源根本没被调用就已经在 Dart 侧超时了，用户看到的就是
     * 「只出 1 条」。现在固定 [WORKER_THREADS] 条线程并行，同一个源仍然靠
     * [lockOf] 串行（见 [call]）。线程数要和 Dart 侧
     * `JarSpider.maxConcurrentSearches` 对齐。
     */
    private val worker: ExecutorService = Executors.newFixedThreadPool(WORKER_THREADS) { runnable ->
        Thread(runnable, "fx-jar-spider").apply {
            isDaemon = true
            priority = Thread.NORM_PRIORITY - 1
        }
    }

    @Volatile
    private var destroyed = false

    /** jar 自带的宿主环境只初始化一次（Init.context + 默认 config.json）。 */
    @Volatile
    private var bootstrapped = false

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
            // dex 输出目录的要求和 jar 相反：ART 要把 odex / vdex 写进去，
            // 目录可写是必须的（目录只读的表现是 ClassNotFoundException，
            // 不是权限异常，很难查）。所以这里只「保证可写」，绝不 chmod 成只读。
            JarPermissions.makeDirWritable(dexDir)
            // Android 14 的硬要求：jar 必须 0444，否则构造函数里就抛
            // SecurityException("Writable dex file … is not allowed")。
            ensureJarReadOnly()
            val parent = context.classLoader
            val made = try {
                DexClassLoader(jarPath.absolutePath, dexDir.absolutePath, null, parent)
            } catch (e: SecurityException) {
                // 极端情况：chmod 明明成功了 ART 还是拒（个别 ROM / 预览版）。
                // 再来一次最暴力的 chmod，仍失败就给用户一句能看懂的话。
                Log.w(TAG, "[JarSpider] DexClassLoader 拒绝加载：${e.message}；强制 chmod 444 后重试")
                JarPermissions.makeReadOnly(jarPath)
                val now = JarPermissions.describe(jarPath)
                Log.i(TAG, "[JarSpider] jar path=${jarPath.absolutePath} $now (retry)")
                if (JarPermissions.isWritable(jarPath)) {
                    throw JarSpiderException(
                        "jar_not_readonly",
                        "jar 文件不是只读，Android 14 不允许加载：${jarPath.absolutePath}（$now）",
                    )
                }
                DexClassLoader(jarPath.absolutePath, dexDir.absolutePath, null, parent)
            }
            loader = made
            Log.i(TAG, "DexClassLoader 就绪 jar=${jarPath.name} dex=${dexDir.absolutePath}")
            return made
        }
    }

    /**
     * 加载前把 jar 钉成只读（DEX_READONLY 2026-11-15）。
     *
     * 这一行日志是排查「自检失败」的第一现场，格式固定成
     * `[JarSpider] jar path=… writable=false perms=444`，`adb logcat -s FXSpider`
     * 一搜就能确认权限到底是 444 还是 644。
     *
     * 只读失败不在这里抛：真正的判据是 ART 抛不抛 SecurityException。
     * 老系统（< 14）可写 dex 完全能用，提前抛会把本来正常的源判死。
     * 34+ 上真加载失败时由上面的 catch 报 `jar_not_readonly`。
     */
    private fun ensureJarReadOnly() {
        val ok = JarPermissions.makeReadOnly(jarPath)
        Log.i(TAG, "[JarSpider] jar path=${jarPath.absolutePath} ${JarPermissions.describe(jarPath)}")
        if (!ok) {
            Log.w(
                TAG,
                "[JarSpider] jar 仍然可写，Android 14 会拒绝加载：" +
                    "${jarPath.absolutePath}（${JarPermissions.describe(jarPath)}）",
            )
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

    /* ------------------------------------------------------------ jar 运行时环境 */

    /**
     * 给 fatcat 系 jar 补宿主环境（FATCAT_ENV 2026-11-15）。
     *
     * 线上这份 `spider.jar`（classes.dex 4.9MB，带 `com.github.catvod.spider.Init`）
     * 里的源普遍会：
     *   · `Init.context().getFilesDir()` 读自己的配置目录 `Pizazz/`；
     *   · 用 `Spider.safeDns()` / `SpiderApi` 回调。
     *
     * **但不能直接调 `Init.init(context)`**：它内部有签名黑名单检查
     * （debug / apktool / MT 管理器签名会 `Process.killProcess`），
     * 还会启动悬浮球和 Go 代理线程 —— 在 debug 包上等于一点就闪退。
     *
     * 所以这里只做两件无副作用的事：
     *   1. 反射把 App Context 塞进 `Init.Loader.a.c`（`Init.context()` 的返回值）；
     *   2. 没有 `Pizazz/config.json` 时写一份官方默认配置（homePage 等），
     *      否则 `csp_Douban.homeContent` 解析空串会直接抛 JSONException。
     */
    private fun bootstrapJar() {
        if (bootstrapped) return
        synchronized(lock) {
            if (bootstrapped) return
            val app = context.applicationContext ?: context
            try {
                Runtime.setContext(app)
            } catch (e: Throwable) {
                Log.w(TAG, "Runtime.setContext 失败：${e.javaClass.simpleName}")
            }
            try {
                if (context is Activity) Spider.setActivity(context)
            } catch (ignored: Throwable) {
            }
            // classLoader() 必须在 try 之外：它抛的是「jar 加载不了」
            // （比如 jar_not_readonly），被下面那句「非 fatcat jar，跳过」的
            // 兜底日志吞掉就看不到真正原因了。
            val cl = classLoader()
            // 拿到 ClassLoader 才算 bootstrap 过：classLoader() 抛错时
            // 这个标记必须保持 false，否则换好 jar 之后不会再注入 Init.context。
            bootstrapped = true
            try {
                val loaderClass = Class.forName("com.github.catvod.spider.Init\$Loader", true, cl)
                val instance = loaderClass.getDeclaredField("a").apply { isAccessible = true }.get(null)
                if (instance != null) {
                    val contextField = instance.javaClass.getDeclaredField("c")
                    contextField.isAccessible = true
                    contextField.set(instance, app)
                    Log.i(TAG, "已注入 Init.context：${app.packageName}")
                }
                ensureFatcatConfig(app)
            } catch (e: Throwable) {
                // 不是 fatcat 结构（普通 csp_ jar）：正常，跳过。
                Log.i(TAG, "jar 没有 Init.context（非 fatcat jar，跳过）：${e.javaClass.simpleName}")
            }
        }
    }

    /** `filesDir/Pizazz/config.json`：缺了就写官方默认值（不联网）。 */
    private fun ensureFatcatConfig(app: Context) {
        try {
            val dir = File(app.filesDir, "Pizazz")
            if (!dir.exists()) dir.mkdirs()
            val file = File(dir, "config.json")
            if (file.isFile && file.length() > 2) return
            file.writeText(DEFAULT_FATCAT_CONFIG, Charsets.UTF_8)
            Log.i(TAG, "已写入默认 Pizazz/config.json")
        } catch (e: Throwable) {
            Log.w(TAG, "写 Pizazz/config.json 失败：${e.message}")
        }
    }

    /* ------------------------------------------------------------ 实例 */

    /**
     * 取（必要时创建并 init）Spider 实例。
     *
     * `ext` 变化时会重新 init —— 同一个 api 在不同配置里 ext 可能不同，
     * 不重 init 就会拿到上一个站点的数据（表现为「两个源内容一模一样」）。
     *
     * **INIT_TIMEOUT（2026-11-16）**：以前「bootstrap + 实例化 + init」整段都在
     * 全局 `synchronized(lock)` 里，而 `csp_SaoHuo.init()` 实测要 33 秒 ——
     * 一个慢 init 就把 116 个源全堵在锁外。现在锁只包「bootstrap + 实例化」
     * （毫秒级），init 挪到锁外、走 [initPool]、限时 [INIT_TIMEOUT_MS]。
     * 同一实例的 init / search 仍然串行：调用方 [call] 先拿 `lockOf(api)`，
     * 所以这里是「按源串行、跨源并行」，和壳一致。
     */
    fun spider(api: String, ext: String): Any {
        val key = api.trim()
        if (key.isEmpty()) throw JarSpiderException("no_api", "没有配置 api（类名）")
        // init 超时过的源：30 分钟内直接判失败，别再白等 10 秒。
        val until = initCoolDown[key] ?: 0L
        if (until > System.currentTimeMillis()) {
            throw JarSpiderException(
                "init_cooldown",
                "这个源上次 init 超时，${(until - System.currentTimeMillis()) / 60_000} 分钟后重试",
            )
        }
        bootstrapJar()
        // 短锁：只做「查缓存 / 建实例」。resolveClass 内部还会进 classLoader()，
        // 那是同一把可重入锁，同一个线程再进一次没问题。
        val instance = synchronized(lock) {
            cache[key] ?: run {
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
                cache[key] = made
                Log.i(TAG, "Spider 就绪：${clz.name} ext=${ext.take(40)}")
                made
            }
        }
        // 锁外：init（ext 变了 / 还没 init 过才走）
        ensureInited(key, instance, ext)
        return instance
    }

    /**
     * 保证实例已经用 [ext] init 过；没 init 就发起一次，**限时** [INIT_TIMEOUT_MS]。
     *
     * 并发语义：同一个源同时只允许一次 init。先到的提交任务，后到的等同一个
     * Future（不重复 init —— jar 里的源普遍是单例 + 可变字段，init 两遍会互相踩）。
     */
    private fun ensureInited(key: String, instance: Any, ext: String) {
        if (initedWith[key] == ext) return
        // 已经有别的线程在 init 这个源：等它，别再来一次。
        initTasks[key]?.let { running ->
            try {
                running.get(INIT_TIMEOUT_MS + 2_000L, TimeUnit.MILLISECONDS)
            } catch (ignored: Throwable) {
                // 失败 / 超时由发起者记账，这里只是不再重复 init。
            }
            if (initedWith[key] == ext) return
        }
        val task = initPool.submit(
            Callable {
                initInstance(instance, ext)
                ext
            },
        )
        initTasks[key] = task
        try {
            task.get(INIT_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            initedWith[key] = ext
        } catch (e: TimeoutException) {
            // 慢 init 的源（SaoHuo 33 秒）不能拖住整轮搜索：判失败 + 冷却 30 分钟。
            task.cancel(true)
            initCoolDown[key] = System.currentTimeMillis() + INIT_FAIL_COOLDOWN_MS
            Log.w(TAG, "init 超时 ${INIT_TIMEOUT_MS / 1000}s：$key（${INIT_FAIL_COOLDOWN_MS / 60_000} 分钟内不再试）")
            throw JarSpiderException(
                "init_timeout",
                "这个源初始化超过 ${INIT_TIMEOUT_MS / 1000} 秒（站点太慢），本轮跳过",
            )
        } catch (e: ExecutionException) {
            val cause = e.cause ?: e
            if (cause is JarSpiderException) throw cause
            val message = cause.message ?: cause.javaClass.simpleName
            throw JarSpiderException("init_failed", "init 失败：$message")
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            throw JarSpiderException("init_failed", "init 被中断")
        } finally {
            initTasks.remove(key)
        }
    }

    /** 调 init：优先 (Context, String)，只有 (Context) 的 jar 也认。 */
    private fun initInstance(instance: Any, ext: String) {
        val contextParam = context.applicationContext ?: context
        // 先把宿主的 SpiderApi 注入基类：源里调用 api.log / getAddress 时才不 NPE。
        try {
            (instance as? Spider)?.initApi(SpiderApiImpl(contextParam))
        } catch (e: Throwable) {
            Log.w(TAG, "initApi 失败：${e.javaClass.simpleName}: ${e.message}")
        }
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
        // 同一个源串行（它的实例字段是可变的），不同源并行。
        synchronized(lockOf(api)) {
            return callLocked(api, ext, method, args)
        }
    }

    private fun callLocked(
        api: String,
        ext: String,
        method: String,
        args: Array<Any?>,
    ): String {
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

    /**
     * 搜索。先试三参（带页码）版本，jar 没实现再试两参版本。
     *
     * 每次调用都打一行 `[JarSearch]`（JAR_LOG 2026-11-15）：真机排查时
     * `adb logcat | grep JarSearch` 就能看到「哪个源、什么关键词、什么 quick、
     * 回了几字节、耗时多少」—— Dart 侧那行日志说条数，这行说字节数，
     * 两边一对就知道是「jar 真回空」还是「回了但被客户端转换/闸门丢了」。
     */
    fun search(api: String, ext: String, key: String, quick: Boolean, page: Int = 1): String {
        val started = System.currentTimeMillis()
        val out = guard("searchContent") {
            // SHELL_PARITY（2026-11-19）：**第一页走两参版本**，和壳一致。
            //
            // 壳 SearchTask.java:51：
            //   page=1  → searchContent(keyword, quick)
            //   page>1  → searchContent(keyword, quick, page)
            // 我们原来无条件先调三参 —— 只实现两参的源，三参反射能命中但内部
            // 把 "1" 当页码拼 URL，第一页地址是错的，返回条数很少甚至为空。
            // 这就是「同一个源壳能出 20 条、我们只出几条」的直接原因。
            val pageText = page.coerceAtLeast(1).toString()
            if (page <= 1) {
                try {
                    call(api, ext, "searchContent", arrayOf<Any?>(key, quick))
                } catch (e: JarSpiderException) {
                    if (e.code != "no_method") throw e
                    call(api, ext, "searchContent", arrayOf<Any?>(key, quick, pageText))
                }
            } else {
                try {
                    call(api, ext, "searchContent", arrayOf<Any?>(key, quick, pageText))
                } catch (e: JarSpiderException) {
                    if (e.code != "no_method") throw e
                    call(api, ext, "searchContent", arrayOf<Any?>(key, quick))
                }
            }
        }
        val elapsed = System.currentTimeMillis() - started
        Log.i(
            TAG,
            "[JarSearch] api=$api key=$key quick=$quick page=$page " +
                "bytes=${out.length} elapsed=${elapsed}ms",
        )
        return out
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
    /* ------------------------------------------------------------ 自检 */

    /**
     * 结构化自检：装完 jar 之后确认「它到底能不能跑」。
     *
     * 走的是一条真链路：解析类 → 实例化 → init(context, ext) →
     * `homeContent(false)` → JSON 解析。任何一步失败都带上**具体阶段**和
     * **异常类型 / 缺失的类**，页面上直接显示，不用连 adb 抓日志：
     *
     * | code | 含义 | 用户要做什么 |
     * | --- | --- | --- |
     * | `no_jar` | 没装 jar | 先安装 |
     * | `no_class` | jar 里没有这个类 | 换 jar（不是肥猫那批） |
     * | `new_instance_failed` | 没有无参构造 / 构造抛异常 | jar 与 api.jar 不配套 |
     * | `init_failed` | init 抛异常（常见：ext 配置不对） | 检查 ext |
     * | `no_method` | 方法签名不匹配 | 返回里带实际方法列表 |
     * | `missing_dependency` | 缺 okhttp / gson 等类 | 打包缺依赖 |
     * | `call_failed` | homeContent 抛异常（多为源站/网络） | 换时间重试 |
     * | `empty` / `bad_json` | 返回空 / 不是 JSON | 源站挂了或需要代理 |
     */
    fun selfTest(api: String, ext: String): Map<String, Any?> {
        val started = System.currentTimeMillis()
        val task = Callable {
            val out = LinkedHashMap<String, Any?>()
            out["api"] = api
            out["jar"] = jarPath.name
            var stage = "classloader"
            try {
                classLoader()
                bootstrapJar()
                stage = "resolve"
                val clz = resolveClass(api)
                out["className"] = clz.name
                out["extendsSpider"] = Spider::class.java.isAssignableFrom(clz)
                stage = "instantiate"
                val instance = try {
                    clz.getDeclaredConstructor().newInstance()
                } catch (e: Throwable) {
                    throw wrap("new_instance_failed", "实例化 ${clz.name} 失败", e)
                }
                stage = "init"
                try {
                    initInstance(instance, ext)
                } catch (e: Throwable) {
                    throw wrap("init_failed", "init(${clz.simpleName}) 失败", e)
                }
                stage = "call"
                val method = findMethod(instance.javaClass, "homeContent", arrayOf<Any?>(false))
                    ?: throw JarSpiderException(
                        "no_method",
                        "${clz.simpleName} 没有 homeContent(boolean)；实际方法：${signatures(clz, "homeContent")}",
                    )
                val raw = try {
                    method.invoke(instance, false)
                } catch (e: Throwable) {
                    throw wrap("call_failed", "homeContent 抛异常", e)
                }
                val text = when (raw) {
                    null -> ""
                    is String -> raw
                    else -> raw.toString()
                }
                if (text.isBlank()) {
                    throw JarSpiderException("empty", "homeContent 返回为空（源站没数据，或 ext 没配对）")
                }
                stage = "parse"
                val json = try {
                    JSONObject(text)
                } catch (e: Throwable) {
                    throw JarSpiderException(
                        "bad_json",
                        "homeContent 返回的不是 JSON：${text.take(160)}",
                    )
                }
                val classes = json.optJSONArray("class")
                val list = json.optJSONArray("list")
                out["ok"] = true
                out["stage"] = "done"
                out["classes"] = classes?.length() ?: 0
                out["items"] = list?.length() ?: 0
                out["sample"] = list?.optJSONObject(0)?.optString("vod_name") ?: ""
                out["bytes"] = text.length
                out["elapsedMs"] = System.currentTimeMillis() - started
                return@Callable out
            } catch (e: Throwable) {
                val error = e as? JarSpiderException ?: wrap("failed", "自检失败", e)
                out["ok"] = false
                out["stage"] = stage
                out["code"] = error.code
                out["error"] = error.message ?: error.code
                out["elapsedMs"] = System.currentTimeMillis() - started
                Log.w(TAG, "自检失败[$stage/${error.code}]：${error.message}")
                return@Callable out
            }
        }
        return try {
            worker.submit(task).get(SELF_TEST_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        } catch (e: TimeoutException) {
            mapOf(
                "api" to api,
                "jar" to jarPath.name,
                "ok" to false,
                "stage" to "call",
                "code" to "timeout",
                "error" to "自检超时（${SELF_TEST_TIMEOUT_MS / 1000} 秒）：jar 里的网络请求没有返回",
                "elapsedMs" to (System.currentTimeMillis() - started),
            )
        } catch (e: Throwable) {
            mapOf(
                "api" to api,
                "jar" to jarPath.name,
                "ok" to false,
                "stage" to "unknown",
                "code" to "failed",
                "error" to "${e.javaClass.simpleName}: ${e.message}",
                "elapsedMs" to (System.currentTimeMillis() - started),
            )
        }
    }

    /** 把反射调用里的真实异常挖出来，并识别「缺依赖」。 */
    private fun wrap(code: String, prefix: String, e: Throwable): JarSpiderException {
        if (e is JarSpiderException) return e
        val inner = (e as? InvocationTargetException)?.targetException ?: e
        val missing = missingClasses(inner)
        val builder = StringBuilder(prefix)
        builder.append("：").append(inner.javaClass.name)
        val message = inner.message
        if (!message.isNullOrBlank()) builder.append(": ").append(message)
        if (missing.isNotEmpty()) builder.append("（缺少类：").append(missing.joinToString(", ")).append("）")
        return JarSpiderException(
            if (missing.isNotEmpty()) "missing_dependency" else code,
            builder.toString(),
        )
    }

    /**
     * 从异常链里找「缺哪个类 / 方法」。
     *
     * 只看 NoClassDefFoundError / ClassNotFoundException / NoSuchMethodError /
     * NoSuchFieldError 这几种：它们的 message 里带类名（
     * `Failed resolution of: Lokhttp3/OkHttpClient;`、`com.google.gson.Gson`），
     * 把描述符里的 `/` 换成 `.` 就是用户能看懂的类名。
     */
    private fun missingClasses(root: Throwable): List<String> {
        val out = LinkedHashSet<String>()
        var node: Throwable? = root
        var guard = 0
        while (node != null && guard++ < 8) {
            val cls = node.javaClass.name
            val wanted = cls.contains("NoClassDefFoundError") ||
                cls.contains("ClassNotFoundException") ||
                cls.contains("NoSuchMethodError") ||
                cls.contains("NoSuchFieldError")
            if (wanted) {
                val raw = node.message ?: ""
                Regex("[A-Za-z_\\$][A-Za-z0-9_\\$/.]*").findAll(raw).forEach { m ->
                    val text = m.value.replace('/', '.').trim().removeSuffix(".")
                    if (text.length > 5 && text.contains('.')) out.add(text)
                }
            }
            node = node.cause
        }
        return out.take(4).toList()
    }

    /** 某个方法名的所有实际签名（诊断「方法签名不匹配」用）。 */
    private fun signatures(clz: Class<*>, name: String): String = try {
        val hits = clz.methods
            .filter { it.name == name }
            .map { m -> m.parameterTypes.joinToString(", ") { it.simpleName } }
        if (hits.isEmpty()) "（没有这个方法）" else hits.joinToString(" / ") { "$name($it)" }
    } catch (ignored: Throwable) {
        "（无法读取方法列表）"
    }

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
        initTasks.clear()
        initCoolDown.clear()
        try {
            worker.shutdownNow()
        } catch (ignored: Throwable) {
        }
        // init 池也要停：不然 3 条线程会一直挂着等下一个任务。
        try {
            initPool.shutdownNow()
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

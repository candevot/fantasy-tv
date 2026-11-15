package com.huanxiang.fantasy_tv

import java.io.File

/**
 * jar / dex 文件的权限（DEX_READONLY 2026-11-15）。
 *
 * **为什么需要这个文件**：Android 14（API 34）起，ART 在打开 dex 之前会检查
 * 「这个文件会不会被 App 自己改写」—— 只要 `st_mode & 0222` 非零（owner /
 * group / other 任何一个可写），就直接抛：
 *
 * ```
 * java.lang.SecurityException: Writable dex file
 * '/data/user/0/com.huanxiang.fantasy_tv/files/spiders/<md5>.jar' is not allowed.
 * ```
 *
 * 而我们从网上下的、从 assets 解出来的 jar 天生是 0660 / 0644（可写），
 * 所以 v1.0.352 及之前的表现是「下载成功、md5 校验通过、自检必失败」。
 * 修法只有一条：**落盘之后、交给 DexClassLoader 之前，把文件 chmod 成 0444**。
 *
 * 反过来，**更新 / 卸载之前必须改回 0600**：0444 的文件虽然能 unlink（有目录
 * 写权限就行），但 `FileOutputStream(target)` 覆盖写会直接 EACCES ——
 * 内置 jar 的 `bundled.jar` 是固定文件名的，第二次「用内置」就会踩到。
 *
 * 设计约束（刻意为之）：
 *   · 这个文件**不 import 任何 android.\***，`Os.chmod` / `Os.stat` 全走反射。
 *     于是同一份代码能在 PC 的 JVM 上跑，`tools/check_jar_perms.sh` 的
 *     单测才验证得了「chmod 之后 canWrite=false」；手机上没有对应的
 *     Android 实现时也能降级到 `File.setReadOnly()` / `chmod` 命令。
 *   · 不做日志：调用方打 `[JarSpider] jar path=… perms=…`，权限逻辑保持纯函数。
 */
object JarPermissions {

    /** `0444`：所有位去写，Android 14 唯一接受的 jar 形态。 */
    const val MODE_READ_ONLY = 292 // Integer.parseInt("444", 8)

    /** `0600`：更新 / 覆盖 / 卸载前，把文件改回「自己能读写」。 */
    const val MODE_READ_WRITE = 384 // Integer.parseInt("600", 8)

    /** `0700`：目录用，必须带 x 位，否则进不去也删不掉。 */
    const val MODE_DIR_WRITE = 448 // Integer.parseInt("700", 8)

    /** `0222`：三个写位。只看这个掩码，Android 14 的判定就是这样。 */
    private const val WRITE_BITS = 146 // Integer.parseInt("222", 8)

    private const val PERM_BITS = 0x1FF // 0777

    /* ---------------------------------------------------------------- 判定 */

    /**
     * 这个文件在 Android 14 眼里算不算「可写」。
     *
     * 先看 mode 位（root 下 `canWrite()` 永远返回 true，不能单独用），
     * mode 读不到才退回 `canWrite()`。
     */
    fun isWritable(file: File): Boolean {
        val bits = modeBits(file)
        if (bits >= 0) return (bits and WRITE_BITS) != 0
        return file.exists() && file.canWrite()
    }

    /** `444` / `600` / `unknown`：日志和状态页直接显示。 */
    fun modeText(file: File): String {
        val bits = modeBits(file)
        if (bits < 0) return "unknown"
        val text = Integer.toOctalString(bits)
        return if (text.length >= 3) text else "0".repeat(3 - text.length) + text
    }

    /** `writable=false perms=444`：一行说清「能不能加载」。 */
    fun describe(file: File): String = "writable=${isWritable(file)} perms=${modeText(file)}"

    /* ---------------------------------------------------------------- 改 */

    /**
     * 把文件改成只读（0444）。返回**最终是否真的只读**。
     *
     * 三层兜底，都是同一件事，只是可用性不同：
     *   1. `android.system.Os.chmod(path, 0444)` —— Android 正规途径；
     *   2. `File.setReadOnly()` —— 纯 JDK，PC 单测走这条；
     *   3. `chmod 444 <path>` —— 上面两步被 ROM / SELinux 拦掉时最后一搏。
     * 每一步之后都重新读 mode 位验证，成功就返回，不浪费时间。
     */
    fun makeReadOnly(file: File): Boolean {
        if (!file.exists()) return false
        if (!isWritable(file)) return true
        chmod(file, MODE_READ_ONLY)
        if (!isWritable(file)) return true
        try {
            file.setReadOnly()
        } catch (ignored: Throwable) {
            // 某些 ROM 上会抛 SecurityException：继续走命令兜底。
        }
        if (!isWritable(file)) return true
        execChmod(file, MODE_READ_ONLY)
        return !isWritable(file)
    }

    /**
     * 把文件（或目录）改回可写。返回**最终是否可写**。
     *
     * 目录自动用 0700：`chmod 600 目录` 会把 x 位也去掉，那个目录就再也
     * 进不去了 —— 删 dex 缓存目录时会踩这个坑。
     */
    fun makeWritable(file: File): Boolean {
        if (!file.exists()) return false
        if (isWritable(file)) return true
        val mode = if (file.isDirectory) MODE_DIR_WRITE else MODE_READ_WRITE
        chmod(file, mode)
        if (isWritable(file)) return true
        try {
            file.setWritable(true, true)
        } catch (ignored: Throwable) {
        }
        if (isWritable(file)) return true
        execChmod(file, mode)
        return isWritable(file)
    }

    /**
     * dex 输出目录：**要求和 jar 相反，必须可写**。
     *
     * ART 要把 `classes.dex` 编译出来的 odex / vdex 写进 outputDir，
     * 目录只读会直接失败（表现是 ClassNotFoundException 而不是权限错）。
     * 上一版如果有人手贱 chmod 过，这里纠正回来。
     */
    fun makeDirWritable(dir: File): Boolean {
        if (!dir.exists()) return false
        var bits = modeBits(dir)
        if (bits >= 0 && (bits and 0x1C0) == 0x1C0) return true // 0700 已就绪
        chmod(dir, MODE_DIR_WRITE)
        bits = modeBits(dir)
        if (bits >= 0 && (bits and 0x1C0) == 0x1C0) return true
        execChmod(dir, MODE_DIR_WRITE)
        bits = modeBits(dir)
        return bits < 0 || (bits and 0x1C0) == 0x1C0
    }

    /* ---------------------------------------------------------- 底层 chmod */

    /** chmod 一次：Os.chmod 优先，失败用 chmod 命令。 */
    private fun chmod(file: File, mode: Int): Boolean =
        osChmod(file, mode) || execChmod(file, mode)

    /**
     * `android.system.Os.chmod(path, mode)`：反射调用，PC 上解析不到就返回 false。
     *
     * Method 用 lazy 缓存：`isWritable` / `describe` 在搜索路径上会被调几十次，
     * 每次重新 `Class.forName` + `getMethod` 没必要（ART 的反射查找不便宜）。
     */
    private fun osChmod(file: File, mode: Int): Boolean {
        val method = osChmodMethod ?: return false
        return try {
            method.invoke(null, file.absolutePath, mode)
            true
        } catch (ignored: Throwable) {
            false
        }
    }

    /** `chmod <octal> <path>`：最后兜底，Android 和 Linux 都有。 */
    private fun execChmod(file: File, mode: Int): Boolean = try {
        val process = ProcessBuilder("chmod", Integer.toOctalString(mode), file.absolutePath)
            .redirectErrorStream(true)
            .start()
        process.inputStream.close()
        process.waitFor() == 0
    } catch (ignored: Throwable) {
        false
    }

    /* ---------------------------------------------------------- 读权限位 */

    /**
     * 读 9 位权限（`0644` → 420）。取不到返回 -1。
     *
     * 两条路都走反射/外部命令，就是为了让本文件不依赖 `android.*`：
     *   · Android：`Os.stat(path).st_mode & 0777`（StructStat 是公开 SDK 类）；
     *   · PC / JVM：`stat -c %a`（Ubuntu / macOS 的 coreutils）。
     */
    private fun modeBits(file: File): Int {
        androidMode(file)?.let { return it }
        shellMode(file)?.let { return it }
        return -1
    }

    private fun androidMode(file: File): Int? {
        val method = osStatMethod ?: return null
        return try {
            val stat = method.invoke(null, file.absolutePath) ?: return null
            // StructStat 是公开 SDK 类，st_mode 是 public int 字段。
            stat.javaClass.getField("st_mode").getInt(stat) and PERM_BITS
        } catch (ignored: Throwable) {
            null
        }
    }

    /* 反射句柄只解析一次（PC 上没有 android.system.*，解析结果就是 null）。 */

    private val osClass: Class<*>? by lazy {
        try {
            Class.forName("android.system.Os")
        } catch (ignored: Throwable) {
            null
        }
    }

    private val osChmodMethod by lazy {
        try {
            osClass?.getMethod("chmod", String::class.java, Int::class.javaPrimitiveType)
        } catch (ignored: Throwable) {
            null
        }
    }

    private val osStatMethod by lazy {
        try {
            osClass?.getMethod("stat", String::class.java)
        } catch (ignored: Throwable) {
            null
        }
    }

    private fun shellMode(file: File): Int? = try {
        val process = ProcessBuilder("stat", "-c", "%a", file.absolutePath)
            .redirectErrorStream(false)
            .start()
        val text = process.inputStream.bufferedReader().use { it.readText() }.trim()
        process.waitFor()
        text.toIntOrNull(8)
    } catch (ignored: Throwable) {
        null
    }
}

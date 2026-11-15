// DEX_READONLY 的 JVM 侧验证（不依赖 Android）：
// 用同一份 JarPermissions.kt 在桌面上跑「chmod 之后 canWrite=false」，
// 证明 makeReadOnly / makeWritable 的语义真能拦住 Android 14 的判定。
// 用法：tools/check_jar_perms.sh（编译本文件 + JarPermissions.kt 后直接 java 跑）
package com.huanxiang.fantasy_tv

import java.io.File
import java.io.FileOutputStream

private var failed = 0

private fun check(name: String, cond: Boolean, detail: String = "") {
    if (cond) {
        println("  ok   $name ${if (detail.isEmpty()) "" else "（$detail）"}")
    } else {
        failed++
        println("  FAIL $name ${if (detail.isEmpty()) "" else "（$detail）"}")
    }
}

private fun tmpDir(): File {
    val dir = File(System.getProperty("java.io.tmpdir"), "jarperm-test-" + System.nanoTime())
    dir.mkdirs()
    return dir
}

fun main() {
    println("JarPermissions JVM 单测 · user=${System.getProperty("user.name")}")
    val dir = tmpDir()

    // 1) 刚落盘的 jar：0644，可写 —— 就是 Android 14 拒加载的形态。
    val jar = File(dir, "cbe016eb.jar")
    FileOutputStream(jar).use { it.write(ByteArray(4096)) }
    check("新文件可写", JarPermissions.isWritable(jar), JarPermissions.describe(jar))
    check("modeText 是 3 位八进制", JarPermissions.modeText(jar).length == 3, JarPermissions.modeText(jar))

    // 2) makeReadOnly → 0444，Android 14 的判定（st_mode & 0222）必须为 0。
    if (!JarPermissions.isWritable(jar) && System.getProperty("user.name") != "root") {
        println("  FAIL 前置条件：文件本该可写，实际 ${JarPermissions.describe(jar)}")
        failed++
    }
    val sealed = JarPermissions.makeReadOnly(jar)
    check("makeReadOnly 成功", sealed, JarPermissions.describe(jar))
    check("perms=444", JarPermissions.modeText(jar) == "444", JarPermissions.modeText(jar))
    check("writable=false", !JarPermissions.isWritable(jar), JarPermissions.describe(jar))
    check("canWrite()=false", !jar.canWrite(), "File.canWrite()=${jar.canWrite()}")
    check("幂等：再调一次仍 true", JarPermissions.makeReadOnly(jar) && !JarPermissions.isWritable(jar))

    // 3) 只读不影响读取（md5 / looksLikeJar 还要读它）。
    check("只读文件仍可读", jar.inputStream().use { it.readBytes() }.size == 4096)

    // 4) 更新流程：想覆盖写 444 的文件必须先 makeWritable，否则 EACCES。
    val writeBlocked = try {
        FileOutputStream(jar).use { it.write(byteArrayOf(1)) }
        false
    } catch (e: Throwable) {
        true
    }
    if (System.getProperty("user.name") == "root") {
        println("  skip 444 覆盖写被拒（root 下 access() 永远放行，手机上不是 root）")
    } else {
        check("444 直接覆盖写被拒", writeBlocked)
    }

    // 5) makeWritable → 0600，能写、能删。
    val opened = JarPermissions.makeWritable(jar)
    check("makeWritable 成功", opened, JarPermissions.describe(jar))
    check("perms=600", JarPermissions.modeText(jar) == "600", JarPermissions.modeText(jar))
    check("writable=true", JarPermissions.isWritable(jar), JarPermissions.describe(jar))
    check("能覆盖写", try {
        FileOutputStream(jar).use { it.write(byteArrayOf(2)) }
        true
    } catch (e: Throwable) {
        false
    })
    JarPermissions.makeReadOnly(jar)
    check("444 能删（有目录写权限就行）", jar.delete() && !jar.exists())

    // 6) dex 输出目录：chmod 600 会把 x 位也去掉，makeDirWritable 必须补回 700。
    val dex = File(dir, "dex-md5")
    dex.mkdirs()
    // 手工制造「有人把输出目录 chmod 600 了」的现场（600 会连 x 位一起丢掉）。
    ProcessBuilder("chmod", "600", dex.absolutePath).redirectErrorStream(true).start()
        .apply { inputStream.close() }.waitFor()
    check("目录被误伤成 600", JarPermissions.modeText(dex) == "600", JarPermissions.modeText(dex))
    check("makeDirWritable → 700", JarPermissions.makeDirWritable(dex) && JarPermissions.modeText(dex) == "700",
        JarPermissions.modeText(dex))
    val inside = File(dex, "classes.dex")
    FileOutputStream(inside).use { it.write(byteArrayOf(0x64, 0x65, 0x78)) }
    check("目录可写 → 能写 odex", inside.length() == 3L)

    // 7) 不存在的路径不抛异常（currentJar / uninstall 会盲调）。
    val ghost = File(dir, "nope.jar")
    check("不存在的文件 makeReadOnly=false", !JarPermissions.makeReadOnly(ghost))
    check("不存在的文件 makeWritable=false", !JarPermissions.makeWritable(ghost))

    dir.deleteRecursively()
    println(if (failed == 0) "\nALL PASS" else "\n$failed FAILED")
    if (failed != 0) System.exit(1)
}

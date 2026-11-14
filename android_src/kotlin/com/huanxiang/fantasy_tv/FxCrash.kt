package com.huanxiang.fantasy_tv

import android.content.Context
import android.os.Build
import android.util.Log
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 崩溃兜底记录（CRASH_LOG，2026-11-15）。
 *
 * 为什么需要它：播放页出现过「一点播放直接闪退」，而 release 包没有 logcat
 * 留存，用户也拿不到栈 —— 只能靠猜。这里装一个
 * [Thread.setDefaultUncaughtExceptionHandler]，把**线程名 + 完整栈**同时写进
 *
 *   · logcat，标签 `FxCrash`（`adb logcat -s FxCrash`）
 *   · 文件 `filesDir/crash.log`（保留最近 20 万字符）
 *
 * 然后照原样把异常交还给系统默认处理器 —— 我们只记录，不吞异常，
 * 不改变「该崩还是崩」的语义（吞掉未捕获异常会让 App 处于半死状态，
 * 比崩掉更难查）。
 *
 * 用法：MainActivity.onCreate 里 `FxCrash.install(this)`（幂等）。
 */
object FxCrash {

    const val TAG = "FxCrash"

    private const val MAX_BYTES = 200_000

    @Volatile
    private var installed = false

    fun install(context: Context) {
        if (installed) return
        installed = true
        val appContext = context.applicationContext ?: context
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                record(appContext, thread, error)
            } catch (ignored: Throwable) {
                // 记录失败绝不能再抛：那会变成「记录崩溃时又崩一次」。
            }
            previous?.uncaughtException(thread, error)
        }
        Log.i(TAG, "崩溃记录已就绪：${logFile(appContext).absolutePath}")
    }

    private fun logFile(context: Context): File = File(context.filesDir, "crash.log")

    private fun record(context: Context, thread: Thread, error: Throwable) {
        val stack = StringWriter().also { writer ->
            PrintWriter(writer).use { error.printStackTrace(it) }
        }.toString()
        val time = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date())
        val text = buildString {
            append("\n==== $time ====\n")
            append("thread: ${thread.name}\n")
            append("device: ${Build.MANUFACTURER} ${Build.MODEL} (API ${Build.VERSION.SDK_INT})\n")
            append("app: ${context.packageName}\n")
            append(stack)
            if (!stack.endsWith("\n")) append('\n')
        }
        Log.e(TAG, text)
        val file = logFile(context)
        try {
            file.appendText(text)
            if (file.length() > MAX_BYTES) {
                // 只留后一半，别让日志文件无限长。
                val kept = file.readText().takeLast(MAX_BYTES / 2)
                file.writeText(kept)
            }
        } catch (ignored: Throwable) {
            // 磁盘满 / 无权限：logcat 那一份已经写过了。
        }
    }
}

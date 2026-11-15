package com.huanxiang.fantasy_tv

/**
 * 后台播放的「能不能起服务 / 能不能进前台」判定 —— **纯逻辑，不 import 任何
 * android.***（BG_GATE，2026-11-15）。
 *
 * 为什么单独抽出来：这次线上事故（任意剧点播放就闪退）里，真正致命的不是
 * 「哪一个系统调用抛了」，而是**抛在谁手里**。media3 的 MediaSessionService
 * 会在播放开始时自己去 `startForeground`，那一段在库内部，我们的 try/catch
 * 根本接不住（见 docs/BACKGROUND-PLAYBACK.md 的异常表）。所以修法不是
 * 「再多包一层 try」，而是**在调用前就用可计算的前置条件把会抛的分支挡掉**，
 * 并且让这套判定可以在 JVM 上直接跑单测（tools/bg_gate_jvm_test.kt）。
 *
 * 判定只依赖 5 个观测值，全部由 PlaybackService 在真机上采集：
 *   · sdkInt                    —— Build.VERSION.SDK_INT
 *   · appForeground             —— ActivityManager 里本进程 importance
 *   · notificationPermission    —— POST_NOTIFICATIONS（Android 13+）
 *   · declaredForegroundTypes   —— ServiceInfo.foregroundServiceType（Android 10+）
 *   · mediaPlaybackPermission   —— FOREGROUND_SERVICE_MEDIA_PLAYBACK（Android 14+）
 */
data class BgEnv(
    val sdkInt: Int,
    val appForeground: Boolean,
    val notificationPermission: Boolean,
    val declaredForegroundTypes: Int,
    val mediaPlaybackPermission: Boolean
) {
    companion object {
        /**
         * `android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK`
         * 的数值（API 29 起固定为 0x2）。这里不直接 import，是为了让本文件
         * 能在没有 android.jar 的 JVM 上编译；PlaybackService 会在 onCreate
         * 里核对平台常量与它一致（不一致只记日志，不影响判定逻辑）。
         */
        const val MEDIA_PLAYBACK_TYPE: Int = 0x2

        /**
         * 采样失败时的兜底值：**按最严格的现代机器算**（Android 14 + 什么都没
         * 声明），判定结果一定是「不许进前台」。宁可退成「没有后台保活」，
         * 也不拿一个猜出来的结论去调会抛异常的系统 API。
         */
        val UNKNOWN = BgEnv(
            sdkInt = 34,
            appForeground = false,
            notificationPermission = false,
            declaredForegroundTypes = 0,
            mediaPlaybackPermission = false
        )
    }
}

/** 拦住的原因。名字即日志文案，别改成中文，方便和真机 logcat 对齐。 */
enum class BgBlock {
    /** 允许。 */
    NONE,

    /** Android 12+：App 不在前台时不允许「起」前台服务（只有 open 这条前台路径可以）。 */
    APP_NOT_FOREGROUND,

    /** Android 13+ 通知权限没给：此时进前台在部分 ROM 上会抛 SecurityException。 */
    NO_NOTIFICATION_PERMISSION,

    /**
     * Android 14+：`startForeground()` 带的类型必须写进 manifest
     * （`android:foregroundServiceType="mediaPlayback"`），否则
     * `MissingForegroundServiceTypeException`（它 extends IllegalStateException，
     * media3 只吞 ForegroundServiceStartNotAllowedException，其余原样抛到主线程）。
     */
    FOREGROUND_TYPE_NOT_DECLARED,

    /**
     * Android 14+：还要单独持有 `FOREGROUND_SERVICE_MEDIA_PLAYBACK`，
     * 缺了就是 SecurityException。
     */
    NO_MEDIA_PLAYBACK_PERMISSION,
}

object BgGate {

    /**
     * 能不能**起服务**（`startService` + 建 session + 挂通知）。
     *
     * 只拦一条：调用方要求「必须在前台」（onIsPlayingChanged 那条路径）而 App
     * 已经不在前台。播放、后台保活本身都不受影响 —— 服务晚一点由 open 路径
     * 或下一次回到前台时补起。
     */
    fun checkServiceStart(env: BgEnv, requireForeground: Boolean): BgBlock {
        if (requireForeground && !env.appForeground) return BgBlock.APP_NOT_FOREGROUND
        return BgBlock.NONE
    }

    /**
     * 能不能**进前台**（`startForeground(id, notification, type)`）。
     *
     * 返回 NONE 以外时：**一次都不要调** `startForeground`，只把通知按普通
     * 通知发出去（媒体卡片在通知栏里仍然可见，只是进程没有前台身份保护）。
     * 这样即使某台 ROM 的前台服务规则更严，也只会「没有前台保活」，
     * 不会把播放带崩。
     */
    fun checkForeground(env: BgEnv): BgBlock {
        // 顺序按「最容易在真机上撞到」排：先类型、再权限、最后通知权限。
        if (env.sdkInt >= 29 &&
            (env.declaredForegroundTypes and BgEnv.MEDIA_PLAYBACK_TYPE) == 0
        ) {
            return BgBlock.FOREGROUND_TYPE_NOT_DECLARED
        }
        if (env.sdkInt >= 34 && !env.mediaPlaybackPermission) {
            return BgBlock.NO_MEDIA_PLAYBACK_PERMISSION
        }
        if (env.sdkInt >= 33 && !env.notificationPermission) {
            return BgBlock.NO_NOTIFICATION_PERMISSION
        }
        return BgBlock.NONE
    }

    /** 一行诊断（onCreate / 每次判定失败时打，真机 logcat 直接能看出缺哪一项）。 */
    fun describe(env: BgEnv, block: BgBlock): String =
        "sdk=${env.sdkInt} fg=${env.appForeground} notif=${env.notificationPermission} " +
            "types=0x${Integer.toHexString(env.declaredForegroundTypes)} " +
            "mediaPlaybackPerm=${env.mediaPlaybackPermission} -> $block"
}

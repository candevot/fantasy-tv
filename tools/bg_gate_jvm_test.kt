// BG_GATE 的 JVM 单测（2026-11-15）。
//
// 为什么能在 JVM 上跑：BgGate.kt 是纯逻辑（不 import android.*），只吃 5 个
// 观测值。这条链路过去只能靠真机复现，现在「哪种机器允许进前台」可以在
// CI / 本地用 200ms 跑完 —— 任何一条规则被改松（例如把 Android 14 的类型
// 校验删掉），这里立刻红。
//
// 跑法：bash tools/check_bg_gate.sh（没有 kotlinc 的环境自动 SKIP）

import com.huanxiang.fantasy_tv.BgBlock
import com.huanxiang.fantasy_tv.BgEnv
import com.huanxiang.fantasy_tv.BgGate

private var failures = 0

private fun expect(name: String, actual: Any?, wanted: Any?) {
    val ok = actual == wanted
    if (!ok) failures++
    println((if (ok) "PASS " else "FAIL ") + name + " -> " + actual + (if (ok) "" else "（期望 $wanted）"))
}

private fun env(
    sdkInt: Int,
    appForeground: Boolean = true,
    notificationPermission: Boolean = true,
    declaredForegroundTypes: Int = BgEnv.MEDIA_PLAYBACK_TYPE,
    mediaPlaybackPermission: Boolean = true
) = BgEnv(sdkInt, appForeground, notificationPermission, declaredForegroundTypes, mediaPlaybackPermission)

fun main() {
    // 0) 常量：android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK = 0x2
    expect("MEDIA_PLAYBACK_TYPE 与平台常量一致", BgEnv.MEDIA_PLAYBACK_TYPE, 0x2)

    // 1) 真机同一档（Redmi / Android 17 / targetSdk 36）：类型 + 权限 + 通知全齐 → 允许
    expect("SDK37 全齐 → 可进前台", BgGate.checkForeground(env(37)), BgBlock.NONE)
    expect("SDK34 全齐 → 可进前台", BgGate.checkForeground(env(34)), BgBlock.NONE)

    // 2) Android 14+ 最常见的一条：manifest 没声明 mediaPlayback → 一次都别调
    expect(
        "SDK34 没声明类型 → 拦",
        BgGate.checkForeground(env(34, declaredForegroundTypes = 0)),
        BgBlock.FOREGROUND_TYPE_NOT_DECLARED
    )
    // 声明了别的类型（0x1 dataSync / 0x40 specialUse）也不行
    expect(
        "SDK34 只声明 dataSync(0x1) → 拦",
        BgGate.checkForeground(env(34, declaredForegroundTypes = 0x1)),
        BgBlock.FOREGROUND_TYPE_NOT_DECLARED
    )
    // 多位掩码里带 mediaPlayback 就可以
    expect(
        "SDK34 掩码含 mediaPlayback → 放",
        BgGate.checkForeground(env(34, declaredForegroundTypes = 0x1 or 0x2)),
        BgBlock.NONE
    )

    // 3) Android 14+ 缺 FOREGROUND_SERVICE_MEDIA_PLAYBACK → SecurityException 来源
    expect(
        "SDK34 缺 mediaPlayback 权限 → 拦",
        BgGate.checkForeground(env(34, mediaPlaybackPermission = false)),
        BgBlock.NO_MEDIA_PLAYBACK_PERMISSION
    )
    // SDK 33 不需要这条权限（Android 14 才有）
    expect(
        "SDK33 不看 mediaPlayback 权限",
        BgGate.checkForeground(env(33, mediaPlaybackPermission = false)),
        BgBlock.NONE
    )

    // 4) Android 13 通知权限没给 → 不 startForeground（部分 ROM 会抛 SecurityException）
    expect(
        "SDK33 通知权限未给 → 拦",
        BgGate.checkForeground(env(33, notificationPermission = false)),
        BgBlock.NO_NOTIFICATION_PERMISSION
    )
    // Android 12 及以下没有 POST_NOTIFICATIONS，不能被这条挡
    expect(
        "SDK32 通知权限不适用 → 放",
        BgGate.checkForeground(env(32, notificationPermission = false)),
        BgBlock.NONE
    )
    // Android 9 及以下没有前台服务类型的概念
    expect(
        "SDK28 无类型概念 → 放",
        BgGate.checkForeground(env(28, declaredForegroundTypes = 0)),
        BgBlock.NONE
    )

    // 5) 起服务：open 路径（不要求前台）永远放；onIsPlayingChanged 路径（要求前台）
    //    在后台必须被挡住 —— 这正是 Android 12+ ForegroundServiceStartNotAllowedException
    //    的入口。
    expect("open 路径+前台 → 起", BgGate.checkServiceStart(env(37), requireForeground = false), BgBlock.NONE)
    expect(
        "open 路径+后台 → 仍可起（open 一定在前台，这里不额外拦）",
        BgGate.checkServiceStart(env(37, appForeground = false), requireForeground = false),
        BgBlock.NONE
    )
    expect(
        "onIsPlayingChanged+后台 → 不起",
        BgGate.checkServiceStart(env(37, appForeground = false), requireForeground = true),
        BgBlock.APP_NOT_FOREGROUND
    )
    expect(
        "onIsPlayingChanged+前台 → 起",
        BgGate.checkServiceStart(env(37, appForeground = true), requireForeground = true),
        BgBlock.NONE
    )

    // 6) 诊断行必须把 5 个观测值都带上（真机靠它一眼看出缺哪项）
    val line = BgGate.describe(env(34, declaredForegroundTypes = 0), BgBlock.FOREGROUND_TYPE_NOT_DECLARED)
    for (needle in listOf("sdk=34", "fg=true", "notif=true", "types=0x0", "mediaPlaybackPerm=true")) {
        expect("describe 含 $needle", line.contains(needle), true)
    }

    // 7) 兜底值：什么都不知道 → 什么都不允许（宁可没后台保活，也不闪退）
    expect(
        "UNKNOWN 环境 → 不进前台",
        BgGate.checkForeground(BgEnv.UNKNOWN),
        BgBlock.FOREGROUND_TYPE_NOT_DECLARED
    )

    println()
    if (failures == 0) {
        println("BG_GATE 单测全绿（21 项）")
        kotlin.system.exitProcess(0)
    } else {
        println("BG_GATE 单测有 $failures 项失败")
        kotlin.system.exitProcess(1)
    }
}

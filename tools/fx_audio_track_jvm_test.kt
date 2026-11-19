// AUDIO_BITRATE（2026-11-19）JVM 单测：音轨按码率选。
//
// 跑法：bash tools/check_fx_audio_track.sh
//
// 为什么必须单测：选轨逻辑错的时候**不会报错、不会黑屏**，只是「声音不对」
// —— 而用户能听出来、我们又没法在 CI 里听。所以把规则逐条钉成断言：
//   ① 所有可用音轨按 bitrate 降序取最高；
//   ② 同码率 EAC3 > AC3 > DTS > AAC；
//   ③ 首选语言存在时只在该语言里选，不存在时退回全局最高；
//   ④ 未声明码率（-1）不能被当成最高；
//   ⑤ 解不了的轨不参与（除非全都不支持）。
//
// 只依赖 FxAudioTrack.kt（纯 Kotlin、不碰 Android），所以能在 runner 上跑。

import com.huanxiang.fantasy_tv.FxAudioTrack

private var failed = 0
private var passed = 0

private fun check(name: String, ok: Boolean, detail: String = "") {
    if (ok) {
        passed++
        println("PASS  $name")
    } else {
        failed++
        println("FAIL  $name${if (detail.isEmpty()) "" else "  -> $detail"}")
    }
}

private fun cand(
    index: Int,
    mime: String?,
    bitrate: Int,
    lang: String? = null,
    supported: Boolean = true,
): FxAudioTrack.Cand = FxAudioTrack.Cand(
    index = index,
    mimeType = mime,
    bitrate = bitrate,
    language = lang,
    supported = supported,
)

private fun pickName(cands: List<FxAudioTrack.Cand>, lang: String = ""): String {
    val chosen = FxAudioTrack.pick(cands, lang)
    return chosen?.let { "${it.index}:${it.mimeType}:${it.bitrate}" } ?: "null"
}

fun main() {
    // ① 单轨：只有一条，就是它。
    check(
        "单轨直接选中",
        pickName(listOf(cand(0, "audio/mp4a-latm", 128_000, "eng"))) == "0:audio/mp4a-latm:128000",
    )

    // ② 多组多编码：**码率最高**的赢（EAC3 640k）。
    check(
        "多音轨按码率取最高（EAC3 640k > AC3 384k > AAC 128k）",
        pickName(
            listOf(
                cand(0, "audio/mp4a-latm", 128_000, "eng"),
                cand(1, "audio/ac3", 384_000, "eng"),
                cand(2, "audio/eac3", 640_000, "eng"),
            ),
        ) == "2:audio/eac3:640000",
    )

    // ③ 同码率 → 编码优先级 EAC3 > AC3 > DTS > AAC。
    check(
        "同码率 EAC3 优先",
        pickName(
            listOf(
                cand(0, "audio/mp4a-latm", 640_000),
                cand(1, "audio/vnd.dts", 640_000),
                cand(2, "audio/ac3", 640_000),
                cand(3, "audio/eac3", 640_000),
            ),
        ) == "3:audio/eac3:640000",
    )
    check(
        "同码率无 EAC3 时 AC3 优先",
        pickName(
            listOf(
                cand(0, "audio/mp4a-latm", 640_000),
                cand(1, "audio/vnd.dts", 640_000),
                cand(2, "audio/ac3", 640_000),
            ),
        ) == "2:audio/ac3:640000",
    )
    check(
        "同码率无 EAC3/AC3 时 DTS 优先于 AAC",
        pickName(
            listOf(
                cand(0, "audio/mp4a-latm", 640_000),
                cand(1, "audio/vnd.dts", 640_000),
            ),
        ) == "1:audio/vnd.dts:640000",
    )
    check(
        "DTS-HD 与 DTS 同档",
        FxAudioTrack.codecRank("audio/vnd.dts.hd") == FxAudioTrack.codecRank("audio/vnd.dts"),
    )
    check(
        "E-AC3 JOC（Atmos）与 E-AC3 同档",
        FxAudioTrack.codecRank("audio/eac3-joc") == FxAudioTrack.codecRank("audio/eac3"),
    )

    // ④ **码率高于编码偏好**：AAC 码率更高时选 AAC（这是这次改动的核心 ——
    //    原来的「优先 AAC」方向是错的，现在也不再「一律优先 EAC3」）。
    check(
        "码率优先于编码类型（AAC 640k 赢 AC3 192k）",
        pickName(
            listOf(
                cand(0, "audio/ac3", 192_000),
                cand(1, "audio/mp4a-latm", 640_000),
            ),
        ) == "1:audio/mp4a-latm:640000",
    )

    // ⑤ 首选语言：有该语言就只在该语言里选最高码率。
    val multilingual = listOf(
        cand(0, "audio/mp4a-latm", 128_000, "eng"),
        cand(1, "audio/ac3", 192_000, "chi"),
        cand(2, "audio/eac3", 640_000, "eng"),
    )
    check(
        "首选中文 → 选中文 AC3 192k（不是最高码率的英语）",
        pickName(multilingual, "zho") == "1:audio/ac3:192000",
        pickName(multilingual, "zho"),
    )
    check(
        "首选语言用 ISO2 也认（zh = zho）",
        pickName(multilingual, "zh") == "1:audio/ac3:192000",
        pickName(multilingual, "zh"),
    )
    check(
        "首选语言用 ISO3 认（chi = zho）",
        pickName(multilingual, "chi") == "1:audio/ac3:192000",
        pickName(multilingual, "chi"),
    )
    check(
        "源里没有该语言 → 退回全局最高码率（不丢音轨）",
        pickName(multilingual, "jpn") == "2:audio/eac3:640000",
        pickName(multilingual, "jpn"),
    )
    check(
        "不指定语言 → 全局最高码率",
        pickName(multilingual) == "2:audio/eac3:640000",
    )
    check(
        "同一语言多条 → 该语言内仍然取最高码率",
        pickName(
            listOf(
                cand(0, "audio/ac3", 192_000, "zh-Hans"),
                cand(1, "audio/eac3", 448_000, "zho"),
                cand(2, "audio/ac3", 640_000, "eng"),
            ),
            "chi",
        ) == "1:audio/eac3:448000",
    )
    check(
        "und / 空语言不参与『有该语言』的判定",
        FxAudioTrack.langKey("und") == "" && FxAudioTrack.langKey("") == "",
    )

    // ⑥ 未声明码率（media3 的 C.RATE_UNSET_INT = -1）按 0 计，不能赢。
    check(
        "未声明码率(-1)不高于有码率的轨",
        pickName(
            listOf(
                cand(0, "audio/eac3", -1),
                cand(1, "audio/ac3", 192_000),
            ),
        ) == "1:audio/ac3:192000",
    )
    check(
        "两条都未声明码率 → 按编码优先级",
        pickName(
            listOf(
                cand(0, "audio/mp4a-latm", -1),
                cand(1, "audio/eac3", -1),
            ),
        ) == "1:audio/eac3:-1",
    )

    // ⑦ 解不了的轨不参与（FFmpeg 挂上之后 TrueHD 之类会在 supported 里体现）。
    check(
        "不支持的最高码率轨被跳过",
        pickName(
            listOf(
                cand(0, "audio/true-hd", 3_000_000, "eng", supported = false),
                cand(1, "audio/ac3", 384_000, "eng"),
            ),
        ) == "1:audio/ac3:384000",
    )
    check(
        "全都不支持时不挑空（交给 media3 报错）",
        pickName(
            listOf(
                cand(0, "audio/true-hd", 3_000_000, supported = false),
                cand(1, "audio/ac3", 384_000, supported = false),
            ),
        ) == "0:audio/true-hd:3000000",
    )

    // ⑧ 完全并列 → 取原始顺序第一条（结果稳定，不会每帧抖）。
    check(
        "码率与编码都相同时取原始顺序",
        pickName(
            listOf(
                cand(0, "audio/ac3", 384_000, "eng"),
                cand(1, "audio/ac3", 384_000, "eng"),
            ),
        ) == "0:audio/ac3:384000",
    )

    // ⑨ 空候选 → null（不崩）。
    check("空候选返回 null", FxAudioTrack.pick(emptyList(), "zho") == null)

    // ⑩ 工具函数：日志里的码率标签 / mime 归一。
    check("bitrateLabel 640000 -> 640k", FxAudioTrack.bitrateLabel(640_000) == "640k")
    check("bitrateLabel 未声明 -> -", FxAudioTrack.bitrateLabel(-1) == "-")
    check(
        "normalizeMime 大小写/下划线归一",
        FxAudioTrack.normalizeMime("Audio/E_AC3") == "audio/e-ac3",
    )
    check("codecRank 未知编码 -> 0", FxAudioTrack.codecRank("audio/opus") == 0)

    println("")
    println("共 ${passed + failed} 条：通过 $passed，失败 $failed")
    if (failed > 0) {
        println("FAIL: AUDIO_BITRATE 选轨规则被改动")
        kotlin.system.exitProcess(1)
    }
    println("OK: AUDIO_BITRATE 选轨规则全部通过")
}

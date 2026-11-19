package com.huanxiang.fantasy_tv

/**
 * AUDIO_BITRATE（2026-11-19）：**按码率**挑音轨。
 *
 * 为什么需要这一层：media3 的 `DefaultTrackSelector` 选音轨时，同一组里的
 * 多条轨按「语言 → 角色 → 编码类型 → 码率」比较，而**跨组的音轨不会被
 * 拿来比较码率** —— HLS 的 master 常常把每条音轨拆成独立的 `EXT-X-MEDIA`
 * 组，于是「E-AC3 640k 的国语」和「AAC 128k 的英语」在 media3 眼里是两组，
 * 谁先出来就是谁；再叠上原来那条「preferAac = 优先 AAC」，结果就是
 * **在带 E-AC3/AC3 的源上反而选了码率最低的 AAC**（用户实测）。
 *
 * 所以选轨逻辑从 `DefaultTrackSelector` 的参数里搬出来，改成**显式**的：
 * 拿 `player.currentTracks` 里所有音频轨，自己排一次序，再用
 * `TrackSelectionOverride` 把唯一赢家钉死。规则（用户口径）：
 *
 *   1. 所有可用音轨按 **bitrate 降序**，取最高；
 *   2. 同码率时 `EAC3 > AC3 > DTS > AAC > 其它`；
 *   3. 仍然尊重「首选音轨语言」：源里**有**该语言的轨，就只在这个语言的
 *      轨里选最高码率；一条都没有，才在全部语言里选。
 *
 * 这个对象只做**纯计算**（不碰 Android / media3 的类型），所以能用 kotlinc
 * 在 JVM 上直接跑单测（`tools/fx_audio_track_jvm_test.kt`）—— 选轨规则
 * 这种「错了也照样能播、只是音轨不对」的问题，必须靠单测钉住。
 */
object FxAudioTrack {

    /**
     * 一条候选音轨。
     *
     * [index] 是调用方给的稳定序号（在它自己的候选列表里的下标），本对象
     * 只负责「选第几条」，不解释它到底指向哪个 `TrackGroup`。
     */
    data class Cand(
        /** 调用方的序号（media3 › 组内轨下标 一起编进来的稳定值）。 */
        val index: Int,
        /** `Format.sampleMimeType`，如 `audio/eac3`；null = 没声明。 */
        val mimeType: String?,
        /** `Format.bitrate`，单位 bit/s；`C.RATE_UNSET_INT`(=-1) 表示未声明。 */
        val bitrate: Int,
        /** `Format.language`，ISO 639-1/2/3 都可能，null = 未声明。 */
        val language: String?,
        /** 当前渲染器能不能解这条轨（`Tracks.Group.isTrackSupported`）。 */
        val supported: Boolean,
        /** 当前是不是已经选中（只用于日志与「不用重复 setParameters」）。 */
        val selected: Boolean = false,
    )

    /** 编码类型优先级（只在**码率完全相同**时用来分胜负）。 */
    fun codecRank(mimeType: String?): Int = when (normalizeMime(mimeType)) {
        "audio/eac3-joc", "audio/eac3" -> 4   // E-AC3（含 Atmos 的 joc 变体）
        "audio/ac3" -> 3                      // AC-3
        "audio/vnd.dts.hd", "audio/vnd.dts" -> 2 // DTS / DTS-HD
        "audio/mp4a-latm", "audio/aac" -> 1   // AAC
        else -> 0                             // flac / opus / mp3 / pcm …
    }

    /** `audio/E-AC3` 这种大小写混乱的写法归一成小写小横线。 */
    fun normalizeMime(mimeType: String?): String =
        (mimeType ?: "").trim().lowercase().replace('_', '-')

    /**
     * 语言归一成 ISO 639-3 三字母（能认的都认，认不出的原样返回）。
     *
     * 为什么需要：媒体源里 `chi` / `zho` / `zh` / `zh-Hans` / `cmn` 全都表示
     * 中文，只做字符串相等比较的话「首选中文」这条会静默失效（而且它是
     * 静默的 —— 用户只看到「怎么选了英语」）。
     */
    fun langKey(raw: String?): String {
        val text = (raw ?: "").trim().lowercase()
        if (text.isEmpty() || text == "und" || text.startsWith("und-")) return ""
        val head = text.split('-', '_').first()
        return LANG_ALIAS[head] ?: head
    }

    /**
     * 选一条音轨。
     *
     * @param cands 全部候选（按调用方遍历顺序）
     * @param preferredLanguage 首选音轨语言（任意 ISO 形式；空串 = 不限制）
     * @return 选中的候选；`cands` 为空时返回 null
     */
    fun pick(cands: List<Cand>, preferredLanguage: String): Cand? {
        if (cands.isEmpty()) return null
        // ① 能解的优先。全都不支持时退回全部（交给 media3 报错，比我们自己
        //    猜一条「大概能播」的更诚实）。
        val playable = cands.filter { it.supported }.ifEmpty { cands }
        // ② 首选语言：源里真有这个语言才收窄，否则不因为「偏好」把能播的轨丢掉。
        val want = langKey(preferredLanguage)
        val pool = if (want.isEmpty()) {
            playable
        } else {
            playable.filter { langKey(it.language) == want }.ifEmpty { playable }
        }
        // ③ 码率降序 → 编码优先级降序 → 原始顺序（稳定）。
        return pool.minWithOrNull(ORDER) ?: pool.first()
    }

    private val ORDER: Comparator<Cand> = Comparator { a, b ->
        val byBitrate = bitrateOrZero(b.bitrate).compareTo(bitrateOrZero(a.bitrate))
        if (byBitrate != 0) return@Comparator byBitrate
        val byCodec = codecRank(b.mimeType).compareTo(codecRank(a.mimeType))
        if (byCodec != 0) return@Comparator byCodec
        a.index.compareTo(b.index)
    }

    /** 未声明码率（-1 / 0）按 0 计 —— 不能让它排在有真实码率的轨前面。 */
    fun bitrateOrZero(bitrate: Int): Int = if (bitrate > 0) bitrate else 0

    /** 日志用的「640k」形式（未声明打 `-`）。 */
    fun bitrateLabel(bitrate: Int): String =
        if (bitrate > 0) "${bitrate / 1000}k" else "-"

    private val LANG_ALIAS: Map<String, String> = mapOf(
        "zh" to "zho", "chi" to "zho", "zho" to "zho", "cmn" to "zho",
        "en" to "eng", "eng" to "eng",
        "ja" to "jpn", "jpn" to "jpn",
        "ko" to "kor", "kor" to "kor",
        "fr" to "fra", "fre" to "fra", "fra" to "fra",
        "de" to "deu", "ger" to "deu", "deu" to "deu",
        "es" to "spa", "spa" to "spa",
        "ru" to "rus", "rus" to "rus",
        "it" to "ita", "ita" to "ita",
        "pt" to "por", "por" to "por",
        "th" to "tha", "tha" to "tha",
        "vi" to "vie", "vie" to "vie",
        "id" to "ind", "ind" to "ind",
        "ms" to "msa", "may" to "msa", "msa" to "msa",
        "ar" to "ara", "ara" to "ara",
        "hi" to "hin", "hin" to "hin",
        "tr" to "tur", "tur" to "tur",
        "nl" to "nld", "dut" to "nld", "nld" to "nld",
        "pl" to "pol", "pol" to "pol",
        "sv" to "swe", "swe" to "swe",
        "da" to "dan", "dan" to "dan",
        "no" to "nor", "nb" to "nor", "nor" to "nor",
        "fi" to "fin", "fin" to "fin",
        "el" to "ell", "gre" to "ell", "ell" to "ell",
        "he" to "heb", "iw" to "heb", "heb" to "heb",
        "cs" to "ces", "cze" to "ces", "ces" to "ces",
        "hu" to "hun", "hun" to "hun",
        "ro" to "ron", "rum" to "ron", "ron" to "ron",
        "uk" to "ukr", "ukr" to "ukr",
        "fa" to "fas", "per" to "fas", "fas" to "fas",
        "ta" to "tam", "tam" to "tam",
        "te" to "tel", "tel" to "tel",
        "bn" to "ben", "ben" to "ben",
        "ur" to "urd", "urd" to "urd",
        "sw" to "swa", "swa" to "swa",
    )
}

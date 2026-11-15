/// 播放失败后的**三段降级**判定层（FX_FALLBACK，2026-11-15）。
///
/// 这一层只做纯判定 —— 不联网、不碰 UI、**不 import 任何包**：
///   · 片名怎么归一化、两个片名算不算同一部；
///   · 年份差多少还能认（≤1 年）；
///   · 哪些结果根本不是正片（解说 / 预告 / 花絮 …）；
///   · 集号怎么对齐（对方集数不够时怎么办）；
///   · 进度怎么接（对方这集比当前进度短时怎么办）；
///   · 日志 / 提示文案的唯一出处。
///
/// 为什么要独立一层：这三段降级的每一条判定都直接决定「用户会不会被跳到
/// 另一部片子上」。判定写错的表现是「看着看着变成了别的剧」，比播不出来
/// 更糟。所以规则集中在这里，由 `tools/test_fallback_match.dart` 逐条钉住。
///
/// 三段降级的定义（播放失败后的顺序）：
/// ```
/// 第 1 段  本片其他线路      已有（详情页 _switchNextLine）
/// 第 2 段  同源其他版本      同片名 + 年份差 ≤1 的**另一条记录**（hx / xo 拆分后的另一条）
/// 第 3 段  跨源找同名        拿片名去外部源（肥猫的 jar 源）搜，命中就跳过去
/// 全失败   提示「所有线路都尝试过了，暂时无法播放」
/// ```
library;

import 'playback_progress.dart';

/* ------------------------------------------------------------------ 文案 */

/// 切源时盖在画面上的提示。
const String fxFallbackSearchingText = '当前源播放失败，正在尝试其他源…';

/// 自动换线路时的进度前缀，后面接「（2/11）」。
const String fxTryingLinePrefix = '正在尝试其他线路';

/// 起播「连续无进展」判定窗口（8 秒）。
///
/// SLOW_NET（2026-11-15）：这个 8 秒**不再是**「总共只等 8 秒」。
/// 用户明确反对「没加载出来就跳过」：
///
/// > 一定要是真失败才会跳过，而不是没有加载出来就跳过。
/// > 比如用户网速是真的慢。
///
/// 现在 8 秒量的是「**一动不动**」：字节数 / 缓冲位置 / 播放位置三项
/// 连续 8 秒全都没变化才算卡死；只要有一项在涨就一直等下去（上限
/// [fxSlowStartupCap] 120 秒，到点交给用户选）。慢网 20 秒才出首帧
/// 属于正常情况，绝不判失败切线路。
const Duration fxOpenFirstFrameTimeout = fxStartupNoProgressWindow;

/// 「正在尝试其他线路（2/11）」——自动换线路时画面上显示这一句。
String fxTryingLineText(int attempt, int total) {
  final a = attempt < 1 ? 1 : attempt;
  final t = total < a ? a : total;
  return '$fxTryingLinePrefix（$a/$t）';
}

/// 三段全部失败后的最终提示（不能一直转圈）。
///
/// 文案故意写软：不出现「掉线」「请切换线路」这种把问题推回给用户的说法 ——
/// 用户不用自己点任何线路，App 已经把全部线路和全部源都试过了。
const String fxFallbackAllFailedText = '这部片暂时播不了，已帮你试过全部线路';

/// 切源成功后的 toast 前缀，后面接源名。
const String fxFallbackSwitchedPrefix = '已切换到';

/// 全链路最多切几次源（**只切一次**）。
///
/// 跨源换源是「整页换到另一条记录」，换过去之后是一个新页面、新的状态；
/// 如果只靠页面内的 `switched` 记账，换过去的那条记录也全失败时会再搜一轮，
/// 于是 A → B → C … 一路跳下去（每跳一次都可能跳到另一部片子上）。
/// 所以跳转时把次数带在路由参数里，超过 [fxFallbackMaxHops] 直接给最终提示。
const int fxFallbackMaxHops = 1;

/// 源方集数不够时的提示（[eps] 是对方真实集数）。
String fxFallbackShortEpText(int eps) => '该源只有 $eps 集';

/// 切源成功的 toast：「已切换到 咕噜」。
String fxFallbackSwitchedText(String sourceName) {
  final name = sourceName.trim();
  return name.isEmpty
      ? '$fxFallbackSwitchedPrefix其他源'
      : '$fxFallbackSwitchedPrefix$name';
}

/* ------------------------------------------------------------ 线路冷却期 */

/// 一条线路失败后的「临时不可用」时长（用户定稿：10 分钟）。
///
/// 10 分钟内不再试它（可能是当时网络抖动，也可能是真坏了），10 分钟后
/// 自动恢复原来的权重 —— 不给用户留一条永久拉黑的线路。
const Duration fxLineCooldownWindow = Duration(minutes: 10);

/// 冷却期是否仍然有效：[failedAtMs] 是失败时刻（毫秒时间戳，0 = 没记录）。
bool fxCoolingActive(int failedAtMs, int nowMs) {
  if (failedAtMs <= 0) return false;
  final gap = nowMs - failedAtMs;
  if (gap < 0) return true;
  return gap < fxLineCooldownWindow.inMilliseconds;
}

/// 单条线路的失败原因归类（日志里的 `reason=`，也是冷却判定的依据）。
///
/// SLOW_NET（2026-11-15）判定规则改为「真失败优先，慢不算失败」：
/// ```
/// HTTP 401/403/404/410/500/502/503      → http_<code>
/// DNS 失败 / 连接被拒 / TLS 失败         → dns_error / connect_refused / tls_error
/// 清单非法（不是 #EXTM3U）/ 0 个分片     → parse_error / manifest_invalid / no_segments
/// 有进展（字节 / 缓冲 / 位置在涨）       → slow_progress（**不是失败**，别换线）
/// 连续 8 秒三项全不动                   → stuck_no_progress（真卡死）
/// 卡了 8 秒但调用方没给进展信息          → no_first_frame（旧口径兜底）
/// 其它                                  → open_failed
/// ```
///
/// `progressing` / `stalledFor` 由调用方从 [FxProgressWindow] 取：判定依据是
/// **真实进展**，不是「等了多久」。
String fxOpenFailReason({
  required int elapsedMs,
  String error = '',
  bool progressing = false,
  Duration? stalledFor,
}) {
  final text = error.trim().toLowerCase();
  // PROBE（2026-11-15）：起播前的线路预检失败 —— 原因要原样报出来
  // （`线路预检失败(http_404)` → `http_404`），这样日志里一眼能看出
  // 「是线路坏了」而不是「网慢」。
  final probe = RegExp(r'线路预检失败\(([^)]+)\)').firstMatch(error);
  if (probe != null) {
    final code = (probe.group(1) ?? '').trim();
    if (code.isNotEmpty) return code;
    return 'probe_failed';
  }
  // 慢网 30 秒硬上限：不是卡死，是「有数据但太慢」。
  if (text.contains('慢网超时')) return 'slow_network';
  if (text.contains('403') || text.contains('forbidden')) return 'http_403';
  if (text.contains('404') || text.contains('not found')) return 'http_404';
  if (text.contains('解析') ||
      text.contains('parse') ||
      text.contains('unsupported')) {
    return 'parse_error';
  }
  // 真失败（DNS / 连接被拒 / TLS / 5xx / 清单没了）：不看时间，立即失败。
  final immediate = fxImmediateFailCode(error: error);
  if (immediate.isNotEmpty) return immediate;
  // 有进展 = 只是慢：不是失败，绝不能拿去换线路。
  if (progressing) return 'slow_progress';
  final stalled = stalledFor;
  if (stalled != null && stalled >= fxStartupNoProgressWindow) {
    return 'stuck_no_progress';
  }
  if (elapsedMs >= fxOpenFirstFrameTimeout.inMilliseconds - 500) {
    return 'no_first_frame';
  }
  return 'open_failed';
}

/// 首帧之后连续多久**没有任何进展**才算失败（10 秒）。
///
/// 和起播同一个口径：缓冲位置 / 字节数只要有一项在涨就不算失败。
const Duration fxBufferingFailTimeout = fxStallNoProgressWindow;

/* -------------------------------------------------------------- 片名归一化 */

/// 片名归一化：去大小写、空白、标点。
///
/// **与 `SourceHub.normTitle` 同一套规则**（那边现在直接调这里）：
/// 降级搜索的匹配如果和搜索页的去重规则不一致，就会出现「搜索页认为是同一部、
/// 换源却认不出来」的割裂。
String fxNormTitle(String raw) {
  final text = raw
      .trim()
      .toLowerCase()
      .replaceAll(
        RegExp(r'[\s\u3000·・•,，。.、:：;；!！?？\-—_/\\|｜()（）\[\]【】]'),
        '',
      );
  return text;
}

/// 片名归一化后是否完全一致（**不做模糊匹配**：宁可不跳，也不跳错片子）。
bool fxSameTitle(String a, String b) {
  final na = fxNormTitle(a);
  final nb = fxNormTitle(b);
  if (na.isEmpty || nb.isEmpty) return false;
  return na == nb;
}

/// 这些词出现在片名里就说明它不是正片：解说 / 预告 / 花絮 / 片段 …
///
/// 外部源里同一部剧常挂着一堆二次创作（「XX 第3集解说」「XX 预告」），
/// 片名归一化后照样能「匹配上」—— 跳过去就是另一段视频。
const List<String> fxExtraClipMarks = <String>[
  '解说',
  '预告',
  '花絮',
  '片段',
  '抢先',
  '彩蛋',
  '幕后',
  '特辑',
  '混剪',
  '精讲',
  '速看',
  '高能',
  'reaction',
  'trailer',
  'cut版',
];

/// 这条结果是不是「解说 / 预告 / 花絮」这类非正片。
bool fxIsExtraClip(String title) {
  final text = title.trim().toLowerCase();
  if (text.isEmpty) return true;
  for (final mark in fxExtraClipMarks) {
    if (text.contains(mark)) return true;
  }
  return false;
}

/* ------------------------------------------------------------------ 年份 */

/// 年份差：一方未知返回 -1（未知年份**可以**接受，只是排在后面）。
int fxYearGap(int want, int got) {
  if (want <= 0 || got <= 0) return -1;
  final gap = want - got;
  return gap < 0 ? -gap : gap;
}

/// 年份是否可接受：相差 ≤ [tolerance] 年；一方未知时也算可接受
/// （服务端 `vod_year` 经常是空的，因为「年份空着」就放弃换源没有道理）。
bool fxYearCompatible(int want, int got, {int tolerance = 1}) {
  final gap = fxYearGap(want, got);
  if (gap < 0) return true;
  return gap <= tolerance;
}

/* ------------------------------------------------------------------ 集号 */

/// 换源后的集号：[availableEps] 是目标源真实集数（0 = 未知）。
///
/// 返回 0 表示**不能换**：对方集数不够（当前第 12 集、对方只有 8 集）。
/// 从头开始播会直接把用户的进度甩掉，所以停在原处并提示
/// 「该源只有 N 集」，由上层决定要不要换。
int fxFallbackEp({required int wantEp, required int availableEps}) {
  if (wantEp < 1) return 0;
  if (availableEps <= 0) return wantEp;
  return availableEps >= wantEp ? wantEp : 0;
}

/* -------------------------------------------------------------- 线路挑选 */

/// 一条候选线路的可播性摘要（纯数据：把 [LineInfo] 里跟「能不能播这一集」
/// 有关的字段抽出来，判定就能脱离模型和网络单独核验）。
class FxLineProbe {
  const FxLineProbe({
    required this.id,
    this.type = 'hls',
    this.degraded = false,
    this.epCount = 0,
  });

  final String id;

  /// `hls`（直链）/ `parse`（要现场走 hxparse 解析）。
  final String type;

  /// 服务端标的「不健康」：照常可选，但排在最后。
  final bool degraded;

  /// 这条线路自己的集数（0 = 未知）。
  final int epCount;
}

/// 这一集在目标记录里最多能到第几集：服务端声明、各线路集名数、剧集列表取最大。
///
/// 取最大而不是取「当前线路的集数」：换源时要判断的是「这个源到底有没有
/// 第 12 集」，任一线路有就算有。
int fxEpisodeCount({
  required int declared,
  required List<int> lineCounts,
  required int episodeListCount,
}) {
  var total = declared < 0 ? 0 : declared;
  for (final n in lineCounts) {
    if (n > total) total = n;
  }
  if (episodeListCount > total) total = episodeListCount;
  return total;
}

/// 从候选线路里挑一条能播第 [ep] 集的，返回下标；都不可播返回 -1。
///
/// 排序口径（分数越低越优先）：
///   · 集数不够这一集的直接不要；
///   · `degraded`（服务端标不健康）+100；
///   · 要现场解析的 `parse` +10（多一层解析就多一个失败点）；
///   · 集名数量未知 +15（不知道这条线路到底有没有这一集，比「要多解析一层」
///     更不可靠，所以排得更后）。
int fxPickLineIndex(List<FxLineProbe> lines, int ep) {
  var best = -1;
  var bestScore = 1 << 20;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.id.trim().isEmpty) continue;
    if (line.epCount > 0 && line.epCount < ep) continue;
    var score = 0;
    if (line.degraded) score += 100;
    if (line.type.trim().toLowerCase() == 'parse') score += 10;
    if (line.epCount <= 0) score += 15;
    if (score < bestScore) {
      bestScore = score;
      best = i;
    }
  }
  return best;
}

/* ------------------------------------------------------------------ 进度 */

/// 换源后要 seek 到的位置（秒）。
///
/// 对方这一集比当前进度还短时（用户看到 40 分钟、对方只有 30 分钟），
/// 直接 seek 到末尾并从那里接着播 —— 不要把用户丢回片头，
/// 也不要把越界的时间交给内核（部分内核会直接报错）。
double fxFallbackPosition({
  required double want,
  double targetDuration = 0,
}) {
  var pos = want;
  if (!pos.isFinite || pos < 0) pos = 0;
  if (targetDuration > 0 && pos > targetDuration) pos = targetDuration;
  return pos;
}

/* ------------------------------------------------------------------ 日志 */

/// 降级日志：`fallback level=2 from=幻想 to=咕噜 reason=all_lines_failed`。
///
/// 真机排查一条命令就够：`adb logcat | grep FxPlay`。
String fxFallbackLog({
  required int level,
  required String from,
  required String to,
  String reason = 'all_lines_failed',
}) {
  final a = from.trim().isEmpty ? '未知' : from.trim();
  final b = to.trim().isEmpty ? '未知' : to.trim();
  return 'fallback level=$level from=$a to=$b reason=$reason';
}

/// 某一段被跳过的日志（第 3 段 jar 没装时用）。
String fxFallbackSkipLog({
  required int level,
  required String from,
  required String reason,
}) {
  final a = from.trim().isEmpty ? '未知' : from.trim();
  return 'fallback level=$level skip from=$a reason=$reason';
}

/// 自动换线路的一步日志：
/// `auto line=2/11 name=红牛 result=fail reason=no_first_frame`。
///
/// `reason`：`no_first_frame`（8 秒没出首帧）/ `open_failed`（其它失败）/ `ok`。
String fxAutoLineLog({
  required int attempt,
  required int total,
  required String name,
  required bool ok,
  String reason = '',
}) {
  final a = attempt < 1 ? 1 : attempt;
  final t = total < a ? a : total;
  final label = name.trim().isEmpty ? '未知线路' : name.trim();
  final tail = ok ? 'ok' : (reason.trim().isEmpty ? 'open_failed' : reason.trim());
  return 'auto line=$a/$t name=$label result=${ok ? 'ok' : 'fail'} '
      'reason=$tail';
}

/// 第 3 段里「这一轮查了哪个源、有没有命中」。
///
/// 咕噜内容最全、速度也快，所以它是**第一个**要查的外部源；这一条日志回答
/// 「到底先查了谁、结果如何」：`fallback source=咕噜 hit=true`。
String fxFallbackSourceLog({required String source, required bool hit}) {
  final name = source.trim().isEmpty ? '未知' : source.trim();
  return 'fallback source=$name hit=$hit';
}

/// 第 3 段优先查的源名（肥猫那一批里内容最全、速度最快的那一条）。
const String fxFallbackPreferredSource = '咕噜';

/// 这个名字是不是「优先查」的那条源。
bool fxIsPreferredSource(String name) =>
    name.trim().isNotEmpty && name.contains(fxFallbackPreferredSource);

/// 换源起播日志：`resume ep=5 pos=754000ms from=幻想 to=咕噜`。
String fxFallbackResumeLog({
  required int ep,
  required int posMs,
  required String from,
  required String to,
}) {
  final a = from.trim().isEmpty ? '未知' : from.trim();
  final b = to.trim().isEmpty ? '未知' : to.trim();
  final ms = posMs < 0 ? 0 : posMs;
  return 'resume ep=$ep pos=${ms}ms from=$a to=$b';
}

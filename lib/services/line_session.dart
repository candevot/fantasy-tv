/// 咕噜系线路的「本次会话剔除」+ 详情页可用性预判（LINE_PRUNE 2026-11-21）。
///
/// 用户口径（原话）：
/// ```
/// 取不到片源就把它从线路列表里删掉，自动跳下一条继续播，
/// 而不是冷却后还留在列表里。
/// 对，都是实时解析的。如果没有，就从线路列表里面消失，不要占位，
/// 误导用户以为能用。
/// 加上这两个，这两个只对咕噜的线路有效。咕噜的那些线路
/// ```
///
/// 所以这一层**只管咕噜系**（线路名以「咕噜」开头，见 [fxIsGuluLine]）：
/// ```
/// 咕噜 / 咕噜·咖啡4K / 咕噜·玫瑰4K / 咕噜·蚂蚁资源 / 咕噜·旋风VIP …
///     判定不过 → 本次会话从列表里消失 + 自动跳下一条 + 轻提示
/// SH4K / 幻想爱奇艺 / shvip / bilibili / 量子 / 红牛 … 等其它线路
///     行为完全不变：失败仍按 line_cooldown 记冷却、跳过，不剔除、不隐藏
/// ```
///
/// 和 `line_cooldown.dart` 的分工（两个都要，缺一不可）：
/// ```
/// line_cooldown  按时间记账（2~10 分钟）＝「这段时间别再试它」（全部线路）
/// line_session   按会话剔除（内存，杀进程即清）＝「这次播放里它就不该出现」（只咕噜系）
/// ```
/// 冷却**不再等于留在列表**：被剔除的咕噜线路本次会话既不出现在详情页列表里，
/// 也不出现在自动换线路的候选里；用户重新进详情页 / 点刷新时重新判定
/// （不是永久黑名单：源只是临时抖一下，不该让用户永久少一条线路）。
///
/// 这一层只做两件事，都不碰播放器、不 import 任何 UI：
/// ```
/// ① 剔除表        `vodId` → {线路名: 失败原因}（内存，不落盘）
/// ② 可用性预判    并发解析 + HTTP 探测，单条 6 秒封顶，只探前 6 条咕噜线
/// ```
/// 判定逻辑全部可注入（[FxLineProbeRunner.checkAll] 的 resolve / check），
/// 所以 `test/line_session_test.dart` 能脱网逐条核验。
library;

import 'dart:async';
import 'dart:io';

import '../models.dart';
import 'play_log.dart';

/* --------------------------------------------------------------- 咕噜系判定 */

/// 咕噜系线路名的前缀（用户点名的这一批：「咕噜的那些线路」）。
const String fxGuluLinePrefix = '咕噜';

/// 这条线路是不是「咕噜系」—— 只有它们参与本次会话剔除 / 页面预判。
///
/// 判定只看线路名（`LineInfo.displayName`）：用户在详情页看到的名字、
/// 播放页日志里记的名字、这里判定的名字必须是同一个，否则会出现
/// 「剔除了一条、列表里还留着另一条同名不同写的」。
bool fxIsGuluLine(String lineName) {
  final name = lineName.trim();
  if (name.isEmpty) return false;
  return name.startsWith(fxGuluLinePrefix);
}

/* ------------------------------------------------------------------ 文案 */

/// 一条线路被剔除、自动切到下一条时的轻提示。
///
/// 用户点名要的形态：`咕噜 线路不可用，已切到 SH4K`。
String fxLinePrunedText({
  required List<String> lines,
  required String switchedTo,
}) {
  final names = <String>[
    for (final name in lines)
      if (name.trim().isNotEmpty) name.trim(),
  ];
  final target = switchedTo.trim();
  if (names.isEmpty) {
    return target.isEmpty ? fxLineAllPrunedText : '已切到 $target';
  }
  // 连跳多条（一次自动轮里失败 2~3 条咕噜线）合成一条提示，别连弹三个 toast。
  final where = names.join('、');
  if (target.isEmpty) return '$where 线路不可用';
  return '$where 线路不可用，已切到 $target';
}

/// 全部线路都不可用时的文案（用户定稿的措辞）。
const String fxLineAllPrunedText = '本片暂无可用线路';

/// 详情页预判的日志：`prune line=咕噜·咖啡4K usable=false reason=http_403`。
String fxLinePruneLog(String lineName, FxLineVerdict verdict) {
  final name = lineName.trim().isEmpty ? '未知线路' : lineName.trim();
  final reason = verdict.reason.trim().isEmpty ? 'ok' : verdict.reason.trim();
  return 'prune line=$name usable=${verdict.usable} reason=$reason';
}

/* -------------------------------------------------------------- 探测结果 */

/// 一条线路的可用性判定结果。
class FxLineVerdict {
  const FxLineVerdict({
    required this.lineId,
    required this.lineName,
    required this.usable,
    this.reason = '',
    this.url = '',
  });

  final String lineId;
  final String lineName;

  /// 现在能不能播（解析出地址 + 地址探测通过）。
  final bool usable;

  /// 判定原因：`http_403` / `no_url` / `timeout` / `resolve_failed` / `ok` …
  final String reason;

  /// 解析出来的播放地址（探通时可用于预热缓存；拿不到为空串）。
  final String url;

  bool get unusable => !usable;
}

/// 一条线路地址的 HTTP 探测结果。
///
/// [status] 为 0 表示「连不上 / 超时」，此时看 [reason]（`dns` / `timeout` …）。
class FxLineHttpResult {
  const FxLineHttpResult({required this.status, this.reason = ''});

  const FxLineHttpResult.failure(String this.reason) : status = 0;

  final int status;
  final String reason;

  /// 2xx / 3xx 都算「这里能出片」（3xx 由 HttpClient 跟随，兜底也算通）。
  bool get ok => status >= 200 && status < 400;

  /// 失败码，和 `line_probe.dart` / `line_cooldown.dart` 同一份词表。
  String get failureCode {
    if (status > 0) return 'http_$status';
    final text = reason.trim();
    return text.isEmpty ? 'probe_failed' : text;
  }
}

/// 解析一条线路的可播地址（空串 / 抛异常 = 这条线路现在取不到片源）。
typedef FxLineResolve = Future<String?> Function(LineInfo line);

/// 探一个地址能不能出片（只看状态码，不下载内容）。
typedef FxLineHttpCheck = Future<FxLineHttpResult> Function(String url);

/* ------------------------------------------------------------ 可用性预判 */

/// 详情页线路可用性预判（并发 + 单条封顶）。
///
/// 用户要求：
/// ```
/// 进详情页时就判定，不能用的线路根本不显示；
/// 先显示列表骨架，探测完把不可用的移除；
/// 并发跑、单条 6 秒封顶，不能拖慢详情页；只探前 6 条。
/// ```
class FxLineProbeRunner {
  FxLineProbeRunner._();

  /// 单条线路的判定预算（解析 + 探测合计 6 秒）。
  static const Duration lineBudget = Duration(seconds: 6);

  /// 并发上限：3 条一起探，别把详情页的网络占满。
  static const int maxParallel = 3;

  /// 一次判定这批线路；结果按入参顺序返回，永不抛异常。
  ///
  /// [onVerdict] 每判完一条就回调一次（详情页据此**边探边移除**，
  /// 而不是等全部探完才一起消失）。
  static Future<List<FxLineVerdict>> checkAll({
    required List<LineInfo> lines,
    required FxLineResolve resolve,
    required FxLineHttpCheck check,
    Duration budget = lineBudget,
    int parallel = maxParallel,
    void Function(FxLineVerdict verdict)? onVerdict,
  }) async {
    if (lines.isEmpty) return const <FxLineVerdict>[];
    final verdicts = List<FxLineVerdict?>.filled(lines.length, null);
    var cursor = 0;
    Future<void> worker() async {
      while (true) {
        final index = cursor++;
        if (index >= lines.length) return;
        final verdict = await checkOne(
          lines[index],
          resolve: resolve,
          check: check,
          budget: budget,
        );
        verdicts[index] = verdict;
        onVerdict?.call(verdict);
      }
    }

    final workers = <Future<void>>[
      for (var i = 0; i < (parallel < 1 ? 1 : parallel); i++) worker(),
    ];
    await Future.wait(workers);
    return <FxLineVerdict>[for (final v in verdicts) v!];
  }

  /// 判一条线路：先解析地址，再探状态码；任何一步失败都算「现在不能用」。
  static Future<FxLineVerdict> checkOne(
    LineInfo line, {
    required FxLineResolve resolve,
    required FxLineHttpCheck check,
    Duration budget = lineBudget,
  }) async {
    final name = line.displayName.trim();
    FxLineVerdict fail(String reason) => FxLineVerdict(
      lineId: line.id,
      lineName: name,
      usable: false,
      reason: reason,
    );
    var url = '';
    try {
      url = (await resolve(line).timeout(budget))?.trim() ?? '';
    } on TimeoutException {
      return fail('timeout');
    } catch (_) {
      return fail('resolve_failed');
    }
    if (url.isEmpty) return fail('no_url');
    try {
      final result = await check(url).timeout(budget);
      return FxLineVerdict(
        lineId: line.id,
        lineName: name,
        usable: result.ok,
        reason: result.ok ? 'ok' : result.failureCode,
        url: url,
      );
    } on TimeoutException {
      return fail('timeout');
    } catch (_) {
      return fail('probe_failed');
    }
  }
}

/// 默认探测实现：GET 一次地址（Range 取 1 字节），只看状态码。
///
/// 和 `line_probe.dart` 的区别：那边要判「清单合法 + 首片能下」，用于起播
/// 前的严格预检；这里只判「这条线路现在出不出现」，302 到 m3u8 能回来
/// 200 就够 —— 判定太严格会让用户少一条其实能播的线路。
Future<FxLineHttpResult> fxCheckLineUrl(
  String url, {
  Duration timeout = FxLineProbeRunner.lineBudget,
  HttpClient? client,
}) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return const FxLineHttpResult.failure('bad_url');
  }
  final owned = client == null;
  final http =
      client ??
      (HttpClient()
        ..connectionTimeout = timeout
        // 影视源自签 / 域名不符是常态（播放器也是 trust-all）：
        // 探测比播放器严格就会出现「探死、其实能播」。
        ..badCertificateCallback = (cert, host, port) => true);
  try {
    final request = await http.openUrl('GET', uri).timeout(timeout);
    request.followRedirects = true;
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
    final response = await request.close().timeout(timeout);
    final status = response.statusCode;
    // 状态码拿到就够了：立刻断开，不下内容（省流量、不烧一次性令牌）。
    unawaited(response.drain<void>().catchError((Object _) {}));
    return FxLineHttpResult(status: status);
  } on TimeoutException {
    return const FxLineHttpResult.failure('timeout');
  } on SocketException catch (error) {
    final text = '${error.message} ${error.osError?.message ?? ''}'
        .toLowerCase();
    final dns =
        text.contains('failed host lookup') ||
        text.contains('name or service not known') ||
        text.contains('no address associated');
    return FxLineHttpResult.failure(dns ? 'dns_error' : 'connect_refused');
  } catch (_) {
    return const FxLineHttpResult.failure('probe_failed');
  } finally {
    if (owned) http.close(force: true);
  }
}

/* -------------------------------------------------------------- 剔除结果 */

/// 剔除一条线路后的结论：下一条是谁、还有没有下一条、该提示什么。
class FxLinePruneResult {
  const FxLinePruneResult({
    required this.applied,
    required this.lineName,
    required this.nextLineId,
    required this.nextLineName,
    required this.exhausted,
  });

  /// 这条线路真的被剔除了（非咕噜系线路返回 false，行为不变）。
  final bool applied;

  final String lineName;

  /// 自动接手的那条线路（`''` = 没有下一条了）。
  final String nextLineId;
  final String nextLineName;

  /// 本片已经没有可用线路了。
  final bool exhausted;

  /// 给用户看的那一句话（非咕噜系 / 没剔除时为空串：原逻辑不弹提示）。
  String get text {
    if (!applied) return '';
    return exhausted
        ? fxLineAllPrunedText
        : fxLinePrunedText(lines: <String>[lineName], switchedTo: nextLineName);
  }
}

/* ------------------------------------------------------------ 会话剔除表 */

/// 本次会话里「已经证明不能用」的咕噜系线路。
///
/// 键是 `vodId`，值是「线路名 → 失败原因」。**只在内存里**：
/// 杀进程 / 重新进详情页 / 点刷新就清空 —— 用户明确要求不是永久黑名单。
class FxLineSession {
  FxLineSession._(this.videoId);

  /// 详情页进页面时最多预判前几条（用户基本只点前几条）。
  static const int probeLimit = 6;

  /// 最多同时记多少部剧（防止长时间使用时无限增长）。
  static const int maxSessions = 40;

  static final Map<String, FxLineSession> _sessions = <String, FxLineSession>{};

  /// 取（并创建）某部剧的会话剔除表。
  static FxLineSession of(String videoId) {
    final id = videoId.trim();
    final existing = _sessions[id];
    if (existing != null) return existing;
    if (_sessions.length >= maxSessions) {
      _sessions.remove(_sessions.keys.first);
    }
    final created = FxLineSession._(id);
    _sessions[id] = created;
    return created;
  }

  /// 重新进详情页 / 点刷新：线路重新评估（本次会话的剔除全部作废）。
  static void clearFor(String videoId) {
    _sessions.remove(videoId.trim());
  }

  /// 清空全部（测试 / 排障）。
  static void clearAll() => _sessions.clear();

  final String videoId;

  /// 咕噜线路名 → 失败原因（`http_403` / `no_url` / `stuck_no_progress` …）。
  final Map<String, String> _withdrawn = <String, String>{};

  /// 本次会话已经探通过的线路名（别再重复探）。
  final Set<String> _usable = <String>{};

  /// 被剔除的线路名（按剔除顺序）。
  List<String> get withdrawnNames => _withdrawn.keys.toList(growable: false);

  int get withdrawnCount => _withdrawn.length;

  int get usableCount => _usable.length;

  /// 这条线路本次会话已经证明不能用。
  bool isWithdrawn(String lineName) =>
      _withdrawn.containsKey(lineName.trim());

  /// 这条线路本次会话已经探通。
  bool isUsable(String lineName) => _usable.contains(lineName.trim());

  /// 剔除原因（没剔除过返回空串）。
  String withdrawnReason(String lineName) => _withdrawn[lineName.trim()] ?? '';

  /// 线路不可用 → 本次会话从列表里消失。
  ///
  /// **只对咕噜系生效**：其它线路传进来直接忽略（行为完全不变），
  /// 返回 false 表示「没剔除，外面照旧走冷却 + 跳过」。
  bool withdraw(String lineName, {String reason = ''}) {
    final name = lineName.trim();
    if (name.isEmpty) return false;
    if (!fxIsGuluLine(name)) {
      fxPlayLog(
        'prune skip video=$videoId line=$name reason=not_gulu',
      );
      return false;
    }
    final text = reason.trim().isEmpty ? 'unavailable' : reason.trim();
    _withdrawn[name] = text;
    _usable.remove(name);
    fxPlayLog('prune withdraw video=$videoId line=$name reason=$text');
    return true;
  }

  /// 线路探通 / 播成功 → 从剔除表里放回去（同一部剧同一次会话里自愈）。
  void markUsable(String lineName) {
    final name = lineName.trim();
    if (name.isEmpty) return;
    final removed = _withdrawn.remove(name);
    _usable.add(name);
    if (removed != null) {
      fxPlayLog('prune restore video=$videoId line=$name');
    }
  }

  /// 本次会话的剔除全部作废（页面刷新后重新判定）。
  void reset() {
    if (_withdrawn.isEmpty && _usable.isEmpty) return;
    _withdrawn.clear();
    _usable.clear();
    fxPlayLog('prune reset video=$videoId');
  }

  /// 用户能看到的线路：保持服务端顺序，只摘掉被剔除的（只可能是咕噜系）。
  List<LineInfo> visible(List<LineInfo> lines) => <LineInfo>[
    for (final line in lines)
      if (!isWithdrawn(line.displayName)) line,
  ];

  /// 详情页进页面时要静默预判的那批：**前 6 条咕噜线**里还没判过的。
  ///
  /// 非咕噜系线路永远不探（用户要求：别拖慢页面、也别改它们的行为）。
  List<LineInfo> probeTargets(List<LineInfo> lines) {
    final out = <LineInfo>[];
    for (final line in lines) {
      if (out.length >= probeLimit) break;
      final name = line.displayName.trim();
      if (name.isEmpty || !fxIsGuluLine(name)) continue;
      if (isWithdrawn(name) || isUsable(name)) continue;
      // 已经在解析中的平台线不用再探（详情页有自己的「解析中」占位）。
      if (line.linePending) continue;
      out.add(line);
    }
    return out;
  }

  /// 当前线路之后的**下一条可用线路**（环形，跳过已剔除的咕噜线）。
  ///
  /// 找不到返回 null（本片本次会话已经没线路可用了）。
  LineInfo? next(List<LineInfo> lines, String currentLineId) {
    final usable = visible(lines);
    if (usable.isEmpty) return null;
    if (usable.length == 1) {
      return usable.first.id == currentLineId ? null : usable.first;
    }
    var index = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].id == currentLineId) {
        index = i;
        break;
      }
    }
    for (var step = 1; step <= lines.length; step++) {
      final candidate = lines[(index + step) % lines.length];
      if (isWithdrawn(candidate.displayName)) continue;
      if (candidate.id == currentLineId) continue;
      if (candidate.id.trim().isEmpty) continue;
      return candidate;
    }
    return null;
  }

  /// 本片本次会话是否已经没有线路可用。
  bool exhausted(List<LineInfo> lines) => visible(lines).isEmpty;

  /// 播放失败时调用：剔除这条咕噜线，并算好「下一条是谁 + 提示什么」。
  ///
  /// 非咕噜系线路返回 `applied=false`（不剔除、不提示），调用方照旧记冷却。
  FxLinePruneResult pruneAndPickNext({
    required String lineName,
    required String currentLineId,
    required List<LineInfo> lines,
    String reason = '',
  }) {
    final applied = withdraw(lineName, reason: reason);
    if (!applied) {
      return FxLinePruneResult(
        applied: false,
        lineName: lineName.trim(),
        nextLineId: '',
        nextLineName: '',
        exhausted: false,
      );
    }
    final nextLine = next(lines, currentLineId);
    return FxLinePruneResult(
      applied: true,
      lineName: lineName.trim(),
      nextLineId: nextLine?.id ?? '',
      nextLineName: nextLine?.displayName ?? '',
      exhausted: nextLine == null,
    );
  }
}

/// 连跳多条后合成一条提示（例：`咕噜、咕噜·咖啡4K 线路不可用，已切到 SH4K`）。
String fxLinePrunedChainText({
  required List<String> lines,
  required String switchedTo,
}) => fxLinePrunedText(lines: lines, switchedTo: switchedTo);

/// 「真失败」与「只是慢」的判定层（SLOW_NET，2026-11-15）。
///
/// 用户定稿的规则：
///
/// > 一定要是**真失败**才会跳过（换线路），而不是「没有加载出来就跳过」。
/// > 比如用户网速是真的慢。
///
/// 所以判定依据从「等了多久」换成「**有没有真实进展**」：
///   · 字节数在涨、缓冲位置在涨、播放位置在走 —— 任意一项在动就是慢，不是死；
///   · 连续 [fxStartupNoProgressWindow]（8 秒）三项**全部**不动才算卡死；
///   · 首帧之后卡顿同理，窗口是 [fxStallNoProgressWindow]（6 秒）；
///   · 有数据在动但一直没首帧：硬上限 [fxSlowStartupCap]（30 秒），
///     到点**直接切**下一条 —— 不弹二选一，问用户只会更烦；
///   · 等满 [fxSlowNoticeAfter]（15 秒）开始显示「网速较慢（已等 N 秒）」。
///
/// 真失败（不看时间，立刻换）：
/// ```
/// HTTP 401/403/404/410/500/502/503     立即失败
/// 解析返回错误 / 清单不是 #EXTM3U       立即失败
/// DNS 解析失败 / 连接被拒 / TLS 失败    立即失败
/// 清单 0 分片 / 所有分片都 4xx          立即失败
/// ```
///
/// 这一层是纯 Dart、**不 import 任何包**（和 `fallback_match.dart` 同一种风格），
/// 这样判定逻辑能被单测 / `dart run tools/...` 直接钉住，不必起播放器。
library;

/* ------------------------------------------------------------------ 时间口径 */

/// 起播阶段「连续无进展」判定窗口：8 秒。
///
/// 以前的规则是「固定 8 秒没出首帧 = 失败」，慢网（几十 KB/s 拉 4K 清单 +
/// 首片，20 秒才出首帧很常见）会被误判成死线路，越切越糟。现在 8 秒只用来
/// 量「一动不动」：只要字节 / 缓冲 / 位置任何一项在涨，就一直等。
const Duration fxStartupNoProgressWindow = Duration(seconds: 8);

/// 首帧之后卡顿的「连续无进展」窗口：**6 秒**。
///
/// 用户口径：首帧出来之后连续 6 秒 buffered 不涨就切下一条。首帧之后管线
/// 已经通了，卡顿多半是某一片在重试（media3 默认 0/1s/2s 三次退避最多
/// 约 3 秒），6 秒足够吃掉一轮多；再长就是真的没数据了。
const Duration fxStallNoProgressWindow = Duration(seconds: 6);

/// 慢但有进展时的自动等待上限：**30 秒硬上限**。
///
/// 用户口径：30 秒是硬上限，不是弹性值 —— 再多用户就等不了了。
/// 到点**直接切**下一条（不问用户：他也不会点「继续等待」，反而更烦）。
const Duration fxSlowStartupCap = Duration(seconds: 30);

/// 慢网提示的门槛：等了 15 秒还没出画面就写一行「网速较慢（已等 N 秒）」。
///
/// 目的不是让用户做决定（30 秒到点就切），而是让他知道**在等什么**：
/// 只有一个转圈的话，用户分不清「在下载」和「卡死了」。
const Duration fxSlowNoticeAfter = Duration(seconds: 15);

/// 进度采样间隔（Dart 侧喂窗口的节奏；原生侧另有 1 秒一次的上报）。
const Duration fxProgressSampleInterval = Duration(milliseconds: 500);

/* --------------------------------------------------------------- 真失败判定 */

/// 一律「立即失败」的 HTTP 状态码。
///
/// 这些不是网络慢，是这条地址真的没了：鉴权过期（401/403）、资源不存在
/// （404/410）、服务端挂了（500/502/503）。等下去只会让用户对着黑屏。
const Set<int> fxFatalHttpStatus = <int>{401, 403, 404, 410, 500, 502, 503};

/// 计数字段用的空状态（老原生包没有这些键时）。
const int _kNoBytes = -1;

/// 原生错误文本 / HTTP 状态码 → 立即失败码；返回空串表示「不算真失败」。
///
/// 返回的码同时用于日志（`reason=http_404`）和坏地址账本（解析类失败一次判死）。
String fxImmediateFailCode({int? httpStatus, String error = ''}) {
  final status = httpStatus ?? 0;
  if (fxFatalHttpStatus.contains(status)) return 'http_$status';
  final text = error.toLowerCase();
  if (text.trim().isEmpty) return '';

  // 清单 / 解析类：拿不到列表、列表不是 #EXTM3U、容器解析不了。
  if (text.contains('extm3u') ||
      text.contains('不是 m3u8') ||
      text.contains('清单非法') ||
      text.contains('parsing_') ||
      text.contains('manifest') ||
      text.contains('parser') ||
      text.contains('container_malformed') ||
      text.contains('invalid_http_content_type')) {
    return 'manifest_invalid';
  }
  // 清单里一个分片都没有 / 所有分片都 4xx（原生转成这句话再报上来）。
  if (text.contains('no_segments') ||
      text.contains('0 个分片') ||
      text.contains('没有分片') ||
      text.contains('所有分片')) {
    return 'no_segments';
  }
  // DNS：解析不到主机。重试没有意义，换个域名（换线路）才有。
  if (text.contains('unknownhost') ||
      text.contains('unable to resolve host') ||
      text.contains('nodename nor servname') ||
      text.contains('dns') ||
      text.contains('解析主机')) {
    return 'dns_error';
  }
  // 连接被拒 / 端口不通 / 连接被重置到连不上。
  if (text.contains('connection refused') ||
      text.contains('connectexception') ||
      text.contains('failed to connect') ||
      text.contains('连接被拒绝')) {
    return 'connect_refused';
  }
  // TLS：证书 / 握手失败。
  if (text.contains('sslhandshake') ||
      text.contains('sslpeerunverified') ||
      text.contains('certificate') ||
      text.contains('certpathvalidator') ||
      text.contains('tls') ||
      text.contains('证书')) {
    return 'tls_error';
  }
  // 文本里直接带状态码（Dart 侧 http 客户端的异常文案）。
  final m = RegExp(r'\b(4\d\d|5\d\d)\b').firstMatch(text);
  if (m != null) {
    final code = int.tryParse(m.group(1)!) ?? 0;
    if (fxFatalHttpStatus.contains(code)) return 'http_$code';
  }
  if (text.contains('403') || text.contains('forbidden')) return 'http_403';
  if (text.contains('404') || text.contains('not found')) return 'http_404';
  return '';
}

/// 这次失败是不是「真失败」（该立刻换线路，不必等任何窗口）。
bool fxIsImmediateFailure({int? httpStatus, String error = ''}) =>
    fxImmediateFailCode(httpStatus: httpStatus, error: error).isNotEmpty;

/// 立即失败码是不是解析 / 清单类（这种地址重试也没用，账本一次判死）。
bool fxIsResolveFailureCode(String code) =>
    code == 'manifest_invalid' || code == 'no_segments';

/* ------------------------------------------------------------------ 采样 */

/// 一次进度采样。
///
/// 三个「有没有动」的量都记：字节（网络层）、缓冲位置（内核层）、播放位置
/// （已经出画之后才走）。只看时间是不够的 —— 慢网三项都在慢慢涨，
/// 而真卡死是三项一起不动。
class FxProgressSample {
  const FxProgressSample({
    required this.atMs,
    this.bytesLoaded = _kNoBytes,
    this.buffered = Duration.zero,
    this.position = Duration.zero,
    this.isLoading = true,
  });

  /// 采样时刻（毫秒时间戳）。
  final int atMs;

  /// 本次 open 至今收到的正文字节数（原生 `bytesLoaded`）；-1 = 老原生包没有。
  final int bytesLoaded;

  /// 已缓冲的媒体时长。
  final Duration buffered;

  /// 当前播放位置。
  final Duration position;

  /// 内核是否仍在加载（buffering / 首帧未渲染）。
  final bool isLoading;

  /// 只要有一项在动就是有进展。
  bool movedFrom(FxProgressSample prev) {
    if (bytesLoaded >= 0 && prev.bytesLoaded >= 0) {
      if (bytesLoaded != prev.bytesLoaded) return true;
    }
    if (buffered != prev.buffered) return true;
    if (position != prev.position) return true;
    return false;
  }

  @override
  String toString() =>
      'sample(at=$atMs, bytes=$bytesLoaded, buf=${buffered.inMilliseconds}ms, '
      'pos=${position.inMilliseconds}ms, loading=$isLoading)';
}

/// 判定结果：慢（继续等）还是卡死（真失败）。
enum FxProgressState {
  /// 有进展 —— 网慢也得等，不许判失败。
  slow,

  /// 连续一整个窗口三项全不动 —— 真卡死，可以换线路。
  stuck,
}

/// 「最近一段时间有没有进展」的滑动窗口。
///
/// 用法：每 [fxProgressSampleInterval] 喂一次 [add]，然后问 [state] /
/// [stalledFor]。判定完全基于采样，不看总耗时。
class FxProgressWindow {
  FxProgressWindow({
    this.window = fxStartupNoProgressWindow,
    this.maxSamples = 240,
  });

  /// 连续多久没有任何进展算卡死（起播 8 秒 / 首帧之后 10 秒）。
  Duration window;

  /// 采样上限：按 500ms 一次算，240 条 = 2 分钟，够覆盖整个起播窗口。
  final int maxSamples;

  final List<FxProgressSample> _samples = <FxProgressSample>[];

  /// 最近一次「有进展」的时刻；-1 = 还没有任何采样。
  int _lastMoveAtMs = -1;

  /// 最新一次采样（没有则为 null）。
  FxProgressSample? get latest => _samples.isEmpty ? null : _samples.last;

  /// 采样条数。
  int get length => _samples.length;

  /// 清空（换线路 / 换集时重新起算）。
  void reset() {
    _samples.clear();
    _lastMoveAtMs = -1;
  }

  /// 喂一次采样。
  void add(FxProgressSample sample) {
    final prev = latest;
    if (prev == null || sample.movedFrom(prev)) {
      _lastMoveAtMs = sample.atMs;
    }
    _samples.add(sample);
    while (_samples.length > maxSamples) {
      _samples.removeAt(0);
    }
  }

  /// 已经连续多久**完全**没有进展。
  Duration get stalledFor {
    final last = latest;
    if (last == null || _lastMoveAtMs < 0) return Duration.zero;
    final gap = last.atMs - _lastMoveAtMs;
    return Duration(milliseconds: gap < 0 ? 0 : gap);
  }

  /// 窗口内是否还在动。
  bool get progressing => stalledFor < window;

  /// 判定：还在动 = [FxProgressState.slow]，连续一整个窗口不动 = 卡死。
  FxProgressState get state =>
      progressing ? FxProgressState.slow : FxProgressState.stuck;

  /// 窗口内的字节增量（拿不到字节时为 -1）。
  int get bytesDelta {
    if (_samples.length < 2) return _kNoBytes;
    final a = _samples.first.bytesLoaded;
    final b = _samples.last.bytesLoaded;
    if (a < 0 || b < 0) return _kNoBytes;
    return b - a;
  }

  /// 窗口内的缓冲增量（毫秒）。
  int get bufferedDeltaMs {
    if (_samples.length < 2) return 0;
    return _samples.last.buffered.inMilliseconds -
        _samples.first.buffered.inMilliseconds;
  }

  @override
  String toString() =>
      'progress(samples=$length, stalled=${stalledFor.inMilliseconds}ms, '
      'state=${state.name}, bytes=$bytesDelta, buf=$bufferedDeltaMs)';
}

/* -------------------------------------------------------------------- 文案 */

/// 字节增量文案：`+38KB` / `+1.2MB` / `+0B`。
String fxByteDeltaText(int bytes) {
  final n = bytes < 0 ? 0 : bytes;
  if (n >= 1024 * 1024) return '+${(n / 1024 / 1024).toStringAsFixed(1)}MB';
  if (n >= 1024) return '+${(n / 1024).round()}KB';
  return '+${n}B';
}

/// 时长增量文案：`+1.2s` / `+0.0s`。
String fxDurationDeltaText(int ms) {
  final n = ms < 0 ? 0 : ms;
  return '+${(n / 1000).toStringAsFixed(1)}s';
}

/// 已下载量文案：`已下载 1.2MB`。
String fxLoadedText(int bytes) {
  final n = bytes < 0 ? 0 : bytes;
  if (n >= 1024 * 1024) return '已下载 ${(n / 1024 / 1024).toStringAsFixed(1)}MB';
  if (n >= 1024) return '已下载 ${(n / 1024).round()}KB';
  if (n > 0) return '已下载 ${n}B';
  return '';
}

/// 进度日志的正文（用户指定的固定格式）：
/// `progress bytes=+38KB buffered=+1.2s verdict=slow|stuck`。
///
/// 调用方用 `fxPlayLog(fxProgressLog(...))` 包一层，最终就是
/// `[FxPlay] progress bytes=+38KB buffered=+1.2s verdict=slow`。
/// 真机一条命令就能看到「慢网不是死」：`adb logcat -s FxPlay | grep progress`。
String fxProgressLog({
  required int bytesDelta,
  required int bufferedDeltaMs,
  required FxProgressState state,
  String extra = '',
}) {
  final tail = extra.trim().isEmpty ? '' : ' $extra';
  return 'progress bytes=${fxByteDeltaText(bytesDelta)} '
      'buffered=${fxDurationDeltaText(bufferedDeltaMs)} '
      'verdict=${state.name}$tail';
}

/// 慢网提示文案：`网速较慢（已等 18 秒）`。
///
/// 15 秒起显示在加载层的网速下面：用户看得见「已经等多久」，就不会以为
/// 是卡死；30 秒到点由内在逻辑直接切下一条，不需要他点任何按钮。
String fxSlowNoticeText(int waitedSeconds) {
  final secs = waitedSeconds < 0 ? 0 : waitedSeconds;
  return '网速较慢（已等 $secs 秒）';
}

/// 慢网到硬上限被切下一条的日志：
/// `slow line=量子 waited=30s buffered=2.1s → switch`。
///
/// 调用方用 `fxPlayLog(...)` 包一层，最终是 `[FxPlay] slow … → switch`。
String fxSlowSwitchLog({
  required String line,
  required int waitedSeconds,
  required Duration buffered,
}) {
  final name = line.trim().isEmpty ? '未知线路' : line.trim();
  final secs = waitedSeconds < 0 ? 0 : waitedSeconds;
  final buf = (buffered.inMilliseconds / 1000).toStringAsFixed(1);
  return 'slow line=$name waited=${secs}s buffered=${buf}s → switch';
}

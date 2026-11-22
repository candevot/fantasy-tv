/// 自动换线后的「继续播 / 接续位置」与「判死前的那一次重试」（AUTO_RESUME
/// 2026-11-20）。
///
/// 两个现场问题的判定层，纯 Dart、不 import 任何包（和 `playback_progress.dart`
/// / `fallback_match.dart` 同一种风格），所以能被单测直接钉住：
///
/// **问题 ①：自动切线路之后画面停着不动，要手动点播放。**
///
/// 根因不在「切完没调 play」，而在**要不要继续播这件事判错了**：
/// `_bootstrapSource` 一进来就 `_controller?.pause()`（先停旧实例再开新地址），
/// 于是「切换前在不在播」这个信息在判定时已经丢了 ——
///   · 旧实例被我们自己 pause 了 → `isPlaying == false`；
///   · ExoPlayer 在 BUFFERING 时 `isPlaying` 也是 false（卡顿换线时必中）；
/// 两者都被当成了「用户主动暂停」，新线路 open 完立刻又被 pause 回去
/// （`play()` 后 60ms 补一个 `pause()`，专门用来「拉一帧不黑屏」），
/// 用户看到的就是**有画面、但停着不动**。
///
/// 所以「要不要继续播」只能看**用户意图**（[fxShouldPlayAfterSwitch]），
/// 不能再看 `isPlaying`。用户真按过暂停才是暂停。
///
/// **问题 ②：SH4K 有时判「线路用不了」。**
///
/// SH4K 是令牌解析线路（`/hxparse/xo?u=SH4K-…` → 302 → 上游 m3u8），
/// 首帧天然比直链慢：实测冷启动时解析 302 + 上游清单要 2.7~6.5 秒，
/// AES-128 的 key 请求另有一次冷 DNS/TLS（5.3 秒），首片本身是 13 MB 级别。
/// 8 秒「连续无进展」窗口对这条链路太紧；而一次抖动就把线路记 10 分钟
/// 不可用，用户下次进来还是「线路用不了」。所以：
///   · 令牌线路的起播窗口放宽到 [fxTokenStartupNoProgressWindow]（20 秒）；
///   · 判死之前补**一次**快速重试（[fxFastRetryDelay] = 1.5 秒）；
///   · 抖动类失败的冷却期缩短到 [fxTransientCooldownWindow]（2 分钟），
///     只有真坏（4xx / 解析失败 / 清单非法）才留 [fxLineCooldownWindow]。
library;

import 'fallback_match.dart' show fxLineCooldownWindow;
import 'playback_progress.dart' show fxStartupNoProgressWindow;

/* ------------------------------------------------------- 换线后要不要继续播 */

/// 自动换线 / 切集成功后要不要自动起播。
///
/// 唯一依据是**用户意图**（[userPaused]）：用户自己按过暂停才保持暂停。
/// 系统 / 我们主动的暂停（换线前先停旧实例、缓冲中 `isPlaying=false`、
/// 播放器报错）一律不算 —— 那正是「自动换线后停在暂停」的根因。
bool fxShouldPlayAfterSwitch({required bool userPaused}) => !userPaused;

/* --------------------------------------------------------- 换线后的接续位置 */

/// 换线接续位置最多允许回退多少秒。
///
/// 换线要重新拉清单 + 目标分片，落点可能比切换前差一点点；只要不差过 3 秒
/// 用户就感知不到（更早就是「怎么退回去了」）。
const Duration fxAutoSwitchMaxRewind = Duration(seconds: 3);

/// 自动换线后从哪一秒接上。
///
/// [snapshotSeconds] = 切换前**可信**的位置（播放器真实进度 → 本集最后一次
/// 正常位置 → UI 进度，顺序由页面决定）；[candidateSeconds] = 另一个来源
/// （磁盘续播点 / 报错后被清零的位置）。
///
/// 规则：以切换前的位置为准；候选位置只允许**往回退**不超过
/// [maxRewindSeconds]，也不允许往前快进；两者都不可信时返回 0（从头播）。
double fxResumeSecondsAfterSwitch({
  required double snapshotSeconds,
  required double candidateSeconds,
  double maxRewindSeconds = 3,
}) {
  final snap =
      snapshotSeconds.isFinite && snapshotSeconds > 0 ? snapshotSeconds : 0.0;
  final cand = candidateSeconds.isFinite && candidateSeconds > 0
      ? candidateSeconds
      : 0.0;
  if (snap <= 0) return cand;
  if (cand <= 0) return snap;
  final rewind = maxRewindSeconds.isFinite && maxRewindSeconds > 0
      ? maxRewindSeconds
      : 0.0;
  final floor = snap - rewind < 0 ? 0.0 : snap - rewind;
  if (cand < floor) return floor;
  if (cand > snap) return snap;
  return cand;
}

/* --------------------------------------------------- 令牌线路与起播判定窗口 */

/// 令牌解析线路（SH4K / 幻想4K / shvip 这类 `/hxparse/*` 包装地址）的
/// 起播「连续无进展」窗口：**20 秒**（直链仍是 8 秒）。
///
/// 用户口径是「自动换线要能自动起来」，不是「8 秒不动就换」：
/// 令牌线路多两跳（本站解析 302 + 上游清单）和一次 AES key 请求，解析期
/// 字节 / 缓冲 / 位置全是 0 —— 对「按进展判活」的看门狗来说等于一动不动，
/// 8 秒就判死（「SH4K 一会能用一会说线路用不了」）。实测冷启动这一段
/// 5~7 秒（首请求 2.7~6.5 秒 + AES key 冷 5.3 秒），20 秒留够余量。
///
/// **这是唯一一处数字**：竖屏播放页（`player_page`）、全屏看门狗
/// （`fullscreen_page`）、内核 `fx_player` 的起播判定都取它，别再各写一份。
const Duration fxTokenStartupNoProgressWindow = Duration(seconds: 20);

/// 本站解析服务的三个入口前缀（`/hxparse/xo` 换直链、`/hxparse/parse`
/// 令牌解析、`/hxparse/play` 成品清单）。用 `contains` 而不是正则：判定只需
/// 「是不是这条路」，不解析参数。
const List<String> _hxParsePaths = <String>[
  '/hxparse/xo',
  '/hxparse/parse',
  '/hxparse/play',
];

/// 这条地址 / 线路是不是「令牌解析」型（首帧天然比直链慢）。
///
/// 判定只看地址形态与线路名，不联网、不看视频 id：
///   · 本站解析服务的包装地址 `/hxparse/xo?u=…`、`/hxparse/parse/fuying?u=…`、
///     成品清单 `/hxparse/play/…`；
///   · 令牌本身 `SH4K-<md5>` / `FY-SH4K-<md5>` / `shvip-…`；
///   · 线路名 `SH4K` / `幻想4K` / `幻想蓝光`（FY-PAN1）。
bool fxIsTokenParseLine({String url = '', String lineName = ''}) {
  final name = lineName.trim().toUpperCase();
  if (name.contains('SH4K') || name.contains('幻想4K') || name.contains('FY-')) {
    return true;
  }
  final u = url.trim().toLowerCase();
  if (u.isEmpty) return false;
  for (final path in _hxParsePaths) {
    if (u.contains(path)) return true;
  }
  if (u.contains('u=sh4k-') || u.contains('u=fy-') || u.contains('u=shvip-')) {
    return true;
  }
  return false;
}

/// jar 线路（咕噜这类现签地址）的起播窗口：30 秒。
///
/// JAR_FIRST_WINDOW（2026-11-22 用户实测）：咕噜首片落在 xfyvideo.online 这类
/// 边缘节点上，**冷命中要回源 10~25 秒**，热命中 1.6 秒。原来的 8 秒窗口会把
/// 冷命中的正常起播判死 → 自动重解析 → 新地址又是冷命中 → 再判死 → 用满两次
/// 重试后停在 0 KB。用户看到的就是「加载两下就不动了，手点刷新才播」：
/// 手点刷新时前两次已经把边缘拉热了。这里把 jar 线路的窗口放到 30 秒，
/// 让第一次冷命中能跑完；配合起播时的首片预热（`_FxJarWarm`），第二次开始
/// 就是热命中。
const Duration fxJarStartupNoProgressWindow = Duration(seconds: 30);

/// 这次起播「连续无进展」该等多长：jar 线路 30 秒、令牌线路 20 秒、直链 8 秒。
Duration fxStartupNoProgressWindowFor({
  String url = '',
  String lineName = '',
  bool jarLine = false,
}) {
  if (jarLine) return fxJarStartupNoProgressWindow;
  return fxIsTokenParseLine(url: url, lineName: lineName)
      ? fxTokenStartupNoProgressWindow
      : fxStartupNoProgressWindow;
}

/* --------------------------------------------------- 判死前的那一次快速重试 */

/// 判死前补重试的间隔：1.5 秒。
///
/// 上游抖一下（一次 5xx / 一次连接超时）不该让整条线路进冷却：等一个
/// 半秒再要一次地址，绝大多数抖动就过去了。只补一次，不是无限重试。
const Duration fxFastRetryDelay = Duration(milliseconds: 1500);

/// 这些原因是**真坏**，补重试没有意义（地址 / 令牌本身失效）。
const Set<String> _hardFailReasons = <String>{
  'http_401',
  'http_403',
  'http_404',
  'http_410',
  'http_451',
  'parse_error',
  'manifest_invalid',
  'no_segments',
  'dead_line',
  // 解析不到主机 / 连不上 / 证书过不去：1.5 秒后再要一次也是一样的结果。
  'dns_error',
  'connect_refused',
  'tls_error',
};

/// 判死前要不要再试一次。
///
/// [reason] 是 `fallback_match.dart` 的 [fxOpenFailReason] 口径；
/// [retries] 是本次候选线路已经补过几次（只补 1 次）；
/// [tokenLine] = 令牌解析线路（这类线路的任何非硬失败都值得再要一次）。
bool fxShouldFastRetry({
  required String reason,
  int retries = 0,
  bool tokenLine = false,
}) {
  if (retries >= 1) return false;
  final r = reason.trim().toLowerCase();
  if (r.isEmpty) return false;
  if (_hardFailReasons.contains(r)) return false;
  if (r.startsWith('http_4')) return false;
  if (tokenLine) return true;
  if (r == 'no_first_frame' ||
      r == 'stuck_no_progress' ||
      r == 'open_failed' ||
      r == 'slow_network' ||
      r == 'timeout' ||
      r == 'connect_timeout' ||
      r == 'bootstrap_exception') {
    return true;
  }
  return r.startsWith('http_5');
}

/* ------------------------------------------------------------- 冷却期长度 */

/// 抖动类失败的冷却期：**2 分钟**。
///
/// 10 分钟太长 —— 一次慢网首帧超时就把 SH4K 封十分钟，用户下次进来还是
/// 「线路用不了」。抖一下停 2 分钟够了，真坏（4xx / 解析失败）照旧 10 分钟。
const Duration fxTransientCooldownWindow = Duration(minutes: 2);

/// 一次失败该冷却多久：真坏 10 分钟（[fxLineCooldownWindow]），抖动 2 分钟。
Duration fxCooldownWindowFor(String reason) {
  final r = reason.trim().toLowerCase();
  if (r.isEmpty) return fxLineCooldownWindow;
  if (_hardFailReasons.contains(r)) return fxLineCooldownWindow;
  if (r.startsWith('http_4')) return fxLineCooldownWindow;
  return fxTransientCooldownWindow;
}

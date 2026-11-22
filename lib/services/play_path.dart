/// 播放路径的**纯判定层**（PLAY_PATH 2026-11-15）。
///
/// 这个文件一个 import 都没有，只放「给一段字符串就能回答」的规则。这么写
/// 有三个实际好处：
///   · 可以在没有 Flutter 的机器上 `dart run` 直接核验（起播链路的判定错了
///     的代价是「两条线路都一直转圈」，不能只靠肉眼看代码）；
///   · test/ 与 CI 的回归用例直接钉同一个函数，详情页 / 播放器 / 下载不会再
///     各自抄一套规则然后互相打脸；
///   · 判定和联网、UI 彻底解耦，改规则不会牵动播放器。
///
/// 起播链路上有三处一直在回答同样的三个问题，之前三处各写一份：
///   1. 这条地址能不能直接播，还是得先走 hxparse 现解析（[isDirectAddress]）；
///   2. 要解析的话该交给哪个解析器（[parseKindFor]）。
///   3. 这次 open 该不该复用正在跑的那一个（[shouldReuseOpen]）；
/// 第 3 条曾经把「重试」吃掉：页面推进 token 后仍然领回上一次的 Future，
/// 界面就永远停在「正在加载 第01集」。
library;

/// 爱奇艺线路的占位地址前缀。
///
/// 爱奇艺线路不是采集来的，`vod_play_url` 里给不出集地址；为了让「集数 /
/// 集名」和其它线路一样参与展示，给每一集填一个 `iqiyi:<集号>` 占位，
/// 播放时再按集号现查。
const String kIqiyiMark = 'iqiyi:';

/// 静态资源后缀：命中就是能直接播的地址，不是平台页面。
final RegExp _mediaExt =
    RegExp(r'\.(m3u8|mp4|mkv|flv|mov|ts)(\?|#|$)', caseSensitive: false);

/// 本站解析服务已经生好的播放地址（`/hxparse/xo?u=…`、`/hxparse/play/…`）。
///
/// PARSE_ONCE（2026-11-15）：这些地址是**解析的产物**，不是待解析的令牌 /
/// 页面。以前只认媒体后缀，于是 `/hxparse/xo?u=SH4K-xxx` 被判成「还要解析」，
/// 又被套进 `/hxparse/parse/fuying` 转一层：多一次 302 + 中转解析，中转站
/// 和直连并不等价，平台页面地址的 `&t=/&y=` 语义也变了。
final RegExp _wrappedPlaylist =
    RegExp(r'/hxparse/(?:xo|play|parse)(?:/|\?|$)', caseSensitive: false);

/// 能不能直接交给播放器：http(s) 且带媒体后缀，或已经是本站解析产物。
///
/// 注意 `幻想4K` 的地址是 `FY-SH4K-<md5>` 令牌，连 http 都不是；
/// `量子` 是 `https://lzv34.com/share/<md5>` 页面 —— 两者都要走 hxparse。
bool isDirectAddress(String address) {
  final text = address.trim().toLowerCase();
  if (!text.startsWith('http://') && !text.startsWith('https://')) return false;
  if (_mediaExt.hasMatch(text)) return true;
  return _wrappedPlaylist.hasMatch(text);
}

/// 需要现场解析（不是直链）。
bool needsParseAddress(String address) => !isDirectAddress(address);

/// 这段地址该交给哪个解析器：`direct` / `iqiyi` / `fuying`。
///
/// 判定顺序是**地址优先、线路名兜底**（PARSE_ONCE2 2026-11-15）：
///
/// 站点给「幻想爱奇艺」的 `vod_play_url` 已经变成成品地址
/// `http://…/hxparse/play/iqiyi/1/index.m3u8?title=济公传&year=2016&ep=1`
/// （302 → `/hxparse/iqiyi.m3u8?tvid=…` → 429KB 清单）。这种地址**不需要**
/// 任何解析器；只按线路名里带「爱奇艺」就返回 `iqiyi`，会把它再套一层
/// `/hxparse/parse/iqiyi?title=…`：白多一次 302 + 中转解析，套出来的地址
/// 语义已经变了，而原来的成品地址本来就能播。
///
/// 只有「没有地址 / 只有 `iqiyi:` 占位 / 给的是平台页面」时，线路名才有
/// 决定权 —— 这也是线路名唯一有信息量的时候。
String parseKindFor(String lineName, String address) {
  final addr = address.trim();
  final name = lineName.toLowerCase();
  if (isDirectAddress(addr)) return 'direct';
  if (addr.startsWith(kIqiyiMark)) return 'iqiyi';
  if (name.contains('爱奇艺') || name.contains('iqiyi')) return 'iqiyi';
  if (_hostOf(addr).contains('iqiyi')) return 'iqiyi';
  return 'fuying';
}

/// 这条记录的播放地址能不能问旧后端（8787 的 `/api/play`）。
///
/// DELEGACY（2026-11-15）：只有**明确来自旧接口**的记录才允许。原因：
///   · CMS 的 `vod_id` 与旧接口的影片 id 是两套完全不同的编号，拿 CMS id
///     去问 8787 只会查不到；
///   · 8787 那个 Node 服务根本不认识「幻想爱奇艺 / 量子 / 红牛 / SH4K」这批
///     新线路，请求只会失败或者挂到超时；
///   · 起播路径上多插一段注定失败的等待（8 秒 × 2 次重试），用户看到的就是
///     「正在加载」不动。
///
/// `unknown`（来源未知）同样不允许：宁可把 CMS 的真实错误透给页面，也不要
/// 在用户等待里再塞 16 秒。
bool legacyPlayAllowed({required bool legacyEnabled, required CmsOrigin origin}) =>
    legacyEnabled && origin == CmsOrigin.legacy;

/// 一条播放记录来自哪个后端。
enum CmsOrigin {
  /// CMS 采集站（`/api.php/provide/vod/`）—— 内容与播放地址的唯一来源。
  cms,

  /// 旧的 8787 后端。只服务历史遗留记录，不再提供新内容。
  legacy,

  /// 还不知道（App 刚起来 / 冻结列表里 evict 掉的老 id）。
  unknown,
}

/// 本次 `open` 要不要复用**正在跑**的那一个。
///
/// 三个条件必须同时成立才复用：
///   · 真的有一个在跑；
///   · 它和这次请求是同一个组合（`line|ep`）；
///   · 它没有被更新的请求取代（token 相同）。
///
/// 第三条是「重试永远转圈」的根因修复（OPEN_GATE 2026-11-15）：页面点重试
/// 时会推进 token，如果这里仍然按 key 命中，重试只是把上一次那个（已经注定
/// 失败的）Future 又领回来 —— 新的一次 open 从来没发出去，界面就永远停在
/// 「正在加载 第01集」，既不出画也不报错。[force] 让重试 / 强制接管直接跳过
/// 去重。
bool shouldReuseOpen({
  required bool hasPending,
  required String? pendingKey,
  required String key,
  required int pendingToken,
  required int currentToken,
  required bool force,
}) =>
    hasPending &&
    !force &&
    pendingKey == key &&
    pendingToken == currentToken;

/// 首播失败后最多「自动重新解析再起播」几次（GULU_FIRST_PLAY 2026-11-22）。
///
/// 用户口径：首播失败或无进展时，**自动**重新解析（等价于手点右上角「刷新」）
/// 并重试起播，最多 2 次，日志留痕 `[JarPlay] retry=N …`。
const int fxFirstPlayReparseMax = 2;

/// 这一次失败值不值得再来一轮「重新解析 + 重新起播」。
///
/// 只有两条否决项，其余一律放行：
///   1. 次数用满（[fxFirstPlayReparseMax]）—— 用满就回到原来的失败链
///      （原线重试 → 全线路轮 → 跨源），**自动切线路的节奏一行不改**；
///   2. `慢网超时` —— 30 秒硬上限是用户定的「到点直接换下一条」，
///      不许被重试拖成 30s × 3。
///
/// [reason] 是 `_lastOpenError` 的口径（`播放超时` / `线路不可用(403)` /
/// `连续 8 秒无进展` …）；空串按「无进展」处理，照样值得再签一条地址。
bool fxShouldReparsePlay({required int reparse, required String reason}) {
  if (reparse >= fxFirstPlayReparseMax) return false;
  if (reason.trim().contains('慢网超时')) return false;
  return true;
}

String _hostOf(String address) {
  if (address.isEmpty) return '';
  final uri = Uri.tryParse(address);
  return (uri?.host ?? '').toLowerCase();
}

/* ------------------------------------------------------------ 死线路跳过 */

/// 解析一定失败的线路名（DEAD_LINE 2026-11-15）。
///
/// 和**服务端** `HxApi::deadLineNames()` 同一份规则，客户端留一份是双保险：
/// 接口层已经把死线路摘掉了（`dropDeadLines`），但只要还有一条老缓存 /
/// 老接口 / 外部 CMS 把死线路送进来，App 这边也不能把它摆给用户 ——
/// 用户点到一条「解析一定失败」的线路，最好的结果也是白等 8 秒。
///
/// 目前成员：
///   · `幻想蓝光`  福盈 PAN1 令牌全量失效（/hxparse/play/fuying/FY-PAN1-… 404，
///                 上游回「只支持 http/https 地址」），全库 36,079 条记录无一例外。
///   · `mgtv`      芒果网页地址，我们这边没有能用的解析器（福盈 404 / xo 502）。
const List<String> kDeadLineNames = <String>['幻想蓝光', 'mgtv'];

/// 地址形态本身就一定失败（令牌前缀 / 平台网页）。
///
/// 只认「确认过整批失效」的东西，别拿它当成通用的可用性探测 ——
/// 真正的可用性靠实测（8 秒无首帧）和线路冷却。
bool isDeadAddress(String address) {
  final a = address.trim().toLowerCase();
  if (a.isEmpty) return true;
  // 福盈 PAN1 令牌：无论 query 风格还是 path 风格，一律 404。
  if (a.contains('fy-pan1-')) return true;
  // 直链媒体永远算活 —— 芒果也可能下发真 m3u8，不能被下面的网页判据误杀。
  if (RegExp(r'\.(m3u8|mp4|flv|mkv)(\?|#|$)').hasMatch(a)) return false;
  // 芒果网页地址：没有解析器，点了一定失败。
  // 输出层可能把它包成 `/hxparse/xo?u=<urlencode>`，两种形态都认。
  if (a.contains('mgtv.com/b/') ||
      a.contains('mgtv.com%2fb%2f') ||
      a.contains('www.mgtv.com')) {
    return true;
  }
  return false;
}

/// 线路名是否在「已知死线路」名单里（**只看名字，不看地址**）。
///
/// 用在还拿不到地址的场合：详情页排线路顺序、选默认线路、线路健康度打分
/// （`line_health.dart` / `detail_page.dart`）—— 这些地方手里只有
/// `LineInfo`，没有每集的地址，只能按名字先避开必然失败的线路。
///
/// 真正「这条线路能不能播」的判定是 [isDeadLine]（以地址为准）。
bool isDeadLineName(String name) {
  final n = name.trim().toLowerCase();
  if (n.isEmpty) return false;
  return kDeadLineNames.any((d) => d.toLowerCase() == n);
}

/// 这条线路是不是已经确认的死线路。
///
/// 判定**只以地址为准**，不看名字：
///   · 所有集都是死形态（FY-PAN1 令牌 / mgtv 网页 / 空地址）→ 死；
///   · 只要有一集是活的地址 → 留着，交给实测（首帧 8 秒 / 线路冷却）判可用性。
///
/// 为什么名字不能参与判定：库里确实有「线路名和地址段错位」的坏数据
/// （名下挂着别的线路的地址）。按名字杀线路会把**活地址**一起丢掉 ——
/// 用户看到的是「这部片一条线路都没有」。名字只在文档里说明死线路是谁
/// （[kDeadLineNames]），判定权留给地址。
bool isDeadLine(String name, Iterable<String> addresses) {
  final list = <String>[
    for (final a in addresses)
      if (a.trim().isNotEmpty) a.trim(),
  ];
  if (list.isEmpty) return true;   // 没有地址 = 没得播
  return list.every(isDeadAddress);
}

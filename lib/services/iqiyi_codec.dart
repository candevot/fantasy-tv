/// 爱奇艺线路的**编码选择规则**（纯字符串层，IQ_CODEC 2026-11-15）。
///
/// 服务端（实测 2026-11-15）：
/// ```
/// /hxparse/play/iqiyi/<ep>/index.m3u8?title=..&year=..          默认 H.264 → 896x504（.ts）
/// /hxparse/play/iqiyi/<ep>/index.m3u8?...&hevc=1                HEVC    → 1920x1080（.265ts）
/// ```
/// 也就是说**同一个地址**换个查询参数就是另一条码流，客户端只要会拼
/// `hevc=1` 就能拿到 1080P HEVC。拼错（`?` / `&` 用反、已经有 `hevc=0`
/// 又追加一个）在服务端看来是「另一个不认识的参数」，静默退回 896×504 ——
/// 用户看到的就是「明明是高配手机，画质却比别的播放器糊」。
///
/// 所以这一层只放**能单独核验**的纯函数（零 import，`dart run` 就能跑）：
///   · [isIqiyiPlayUrl]  这段地址是不是爱奇艺播放地址（只有它才允许动）；
///   · [withHevc]        加 / 去 `hevc=1`，保留原来查询串的顺序与编码；
///   · [hevcOf]          这个地址当前请求的是哪种编码；
///   · [codecLabelOf] / [iqCodecText]  把「实测编码 + 分辨率」翻成人话。
/// 设备有没有 HEVC 硬解是原生的事（`fantasy_tv/exo_player` 的
/// `supportsHevc`），规则见 `iq_codec_gate.dart`。
library;

/// 爱奇艺播放地址的路径特征。
///
/// 实测形态是 `/hxparse/play/iqiyi/<集号>/index.m3u8`；站点换域名 / 换前缀
/// 后 `play/iqiyi/<n>` 这一段不变（那是解析服务的路由，不是站点），所以只
/// 认这一段。`/hxparse/parse/iqiyi?title=…` 是**解析入口**、不是成品码流，
/// 给它加 `hevc=1` 没有任何语义，这里刻意不认。
final RegExp _iqPlayPath = RegExp(
  r'/play/iqiyi/\d+(?:/index\.m3u8|\.m3u8)?$',
  caseSensitive: false,
);

/// 这段地址是不是「爱奇艺线路的成品播放地址」。
///
/// 只看 path，不看 host：同一个 hxparse 服务在不同环境挂在不同域名下。
bool isIqiyiPlayUrl(String url) {
  final path = _pathOf(url);
  if (path.isEmpty) return false;
  return _iqPlayPath.hasMatch(path.toLowerCase());
}

/// 这个地址当前请求的编码：`'hevc'` / `'avc'`（没有参数就是服务端默认 AVC）。
String hevcOf(String url) {
  final raw = _queryOf(url);
  if (raw.isEmpty) return 'avc';
  for (final pair in raw.split('&')) {
    if (pair.isEmpty) continue;
    final cut = pair.indexOf('=');
    final key = cut < 0 ? pair : pair.substring(0, cut);
    if (key != 'hevc') continue;
    final value = cut < 0 ? '' : pair.substring(cut + 1);
    // 服务端判据是 vt=0（HEVC）/ vt=1（AVC），对应 `hevc=1` / `hevc=0`。
    return value == '1' || value.toLowerCase() == 'true' ? 'hevc' : 'avc';
  }
  return 'avc';
}

/// 本次请求的编码：`'hevc'` / `'avc'`；不是爱奇艺播放地址返回 ''。
///
/// 和 [hevcOf] 的区别：这个先判「是不是爱奇艺线路」，给诊断浮层的
/// 「编码」行用 —— 别的线路既不显示也不参与判断。
String iqRequestedCodec(String url) =>
    isIqiyiPlayUrl(url) ? hevcOf(url) : '';

/// 加 / 去 `hevc=1`，返回新地址。
///
/// 三条硬约束（都有单测钉住）：
///   · **只动爱奇艺播放地址**：其它线路原样返回，一个字节都不改；
///   · 已有查询串用 `&`，没有才用 `?`（用 `?` 拼第二个参数会让服务端把
///     `title` 的值吃成 `济公传&hevc=1`，作品就查不到了）；
///   · `hevc` 只留一个：原来带 `hevc=0` 时先删掉再按需要追加，
///     绝不出现 `hevc=0&hevc=1`（服务端取第一个，等于没生效）。
String withHevc(String url, {required bool hevc}) {
  final raw = url.trim();
  if (!isIqiyiPlayUrl(raw)) return url;
  final wanted = hevcOf(raw) == 'hevc';
  if (wanted == hevc) return raw;
  final without = _stripHevc(raw);
  if (!hevc) return without;
  return _appendParam(without, 'hevc', '1');
}

/// 去 `hevc=1`（拿 896×504 的 AVC 码流）；本来就没有 hevc 参数时返回 null。
///
/// 起播失败降级用：null = 这个地址没有可降级的空间，别拿同一条地址重试。
String? avcVariant(String url) {
  final raw = url.trim();
  if (!isIqiyiPlayUrl(raw)) return null;
  if (hevcOf(raw) != 'hevc') return null;
  return withHevc(raw, hevc: false);
}

/* ------------------------------------------------------------ 候选序列 */

/// 一条待尝试的播放地址 + 它是怎么来的（纯数据，可单独构造 / 断言）。
class IqPlayTarget {
  const IqPlayTarget(
    this.url, {
    this.hevc = false,
    this.degradeFromHevc = false,
  });

  /// 真正交给播放器的地址（已经按设备能力拼好 `hevc=1`）。
  final String url;

  /// 这条地址请求的是 HEVC。
  final bool hevc;

  /// true = 这条是「HEVC 起播失败」之后的降级地址（拿 896×504 的 AVC）。
  final bool degradeFromHevc;
}

/// 把「服务端给的候选地址」按设备能力展开成**尝试序列**（纯函数）。
///
/// 规则：
///   · 支持 HEVC：每条爱奇艺地址先试 `hevc=1`，紧跟一条去掉它的降级地址
///     —— 播放页的候选循环本来就是「一条不行试下一条」，于是「HEVC 解码
///     失败 / 首帧 8 秒超时 → AVC 重试一次」是天然的，不需要新的状态机；
///   · 不支持 HEVC：只试原地址（服务端默认就是 AVC，896×504）；
///   · 其它线路的地址原样进列表，一条不多一条不少，顺序也不变。
///
/// 降级地址只出现在它自己那条 HEVC 地址**后面**：顺序反了就成了
/// 「明明能硬解却先放 AVC」，画质白降。
List<IqPlayTarget> planTargets(
  List<String> candidates, {
  required bool hevc,
}) {
  final out = <IqPlayTarget>[];
  for (final raw in candidates) {
    final url = raw.trim();
    if (url.isEmpty) continue;
    final adapted = withHevc(url, hevc: hevc);
    final wanted = isIqiyiPlayUrl(adapted) && hevcOf(adapted) == 'hevc';
    if (!out.any((t) => t.url == adapted)) {
      out.add(IqPlayTarget(adapted, hevc: wanted));
    }
    if (!wanted) continue;
    final avc = avcVariant(adapted);
    if (avc == null || avc.isEmpty) continue;
    if (!out.any((t) => t.url == avc)) {
      out.add(IqPlayTarget(avc, degradeFromHevc: true));
    }
  }
  return out;
}

/// 降级那一条的固定日志：`[FxPlay] iqiyi downgrade hevc->avc url=…`。
///
/// 为什么单独抽出来：这条日志是用户「画质怎么掉了」的唯一解释，
/// 三个播放入口（竖屏 / 全屏 / 一起看）必须打出来一模一样的一行，
/// 排查时 `adb logcat | grep iqiyi` 就能看到。
String iqDegradeLog(String url) => 'iqiyi downgrade hevc->avc url=$url';

/* ------------------------------------------------------------ 显示文案 */

/// `hevc` / `video/hevc` / `H265` … → `'HEVC'`；认不出来返回 ''。
String codecLabelOf(String raw) {
  final text = raw.trim().toLowerCase();
  if (text.isEmpty) return '';
  if (text.contains('hevc') ||
      text.contains('h265') ||
      text.contains('h.265')) {
    return 'HEVC';
  }
  if (text.contains('avc') ||
      text.contains('h264') ||
      text.contains('h.264')) {
    return 'H.264';
  }
  if (text.contains('av01') || text.contains('av1')) return 'AV1';
  if (text.contains('vp9')) return 'VP9';
  if (text.contains('vp8')) return 'VP8';
  return '';
}

/// `1920x1080`；宽高拿不到（0 / 负数）返回 ''。
String sizeTextOf(int width, int height) =>
    (width > 0 && height > 0) ? '${width}x$height' : '';

/// 诊断浮层 / 通知条上的「编码」那一行。
///
/// 取值顺序就是**可信度顺序**：
///   1. [mime]：内核解出来的真实轨道编码（`video/hevc`）；
///   2. [headerCodec] + [headerQuality]：服务端响应头 `X-Iq-Codec` /
///      `X-Iq-Quality` 说的编码与分辨率（HEVC 起播失败降级时，头里会
///      直接写实际给的码流，比猜准）；
///   3. [requested]：我们**请求**的编码（`hevc=1` 有没有拼上）；
///   4. 都没有 → `--`。
///
/// 分辨率优先用 [width]×[height]（`onVideoSizeChanged` 实测），没有才用
/// 响应头里的 [headerQuality]。
String iqCodecText({
  String mime = '',
  String headerCodec = '',
  String headerQuality = '',
  String requested = '',
  int width = 0,
  int height = 0,
}) {
  final measured = sizeTextOf(width, height);
  final fromHeader = headerQuality.trim();
  final size = measured.isNotEmpty ? measured : fromHeader;
  var label = codecLabelOf(mime);
  if (label.isEmpty) label = codecLabelOf(headerCodec);
  if (label.isEmpty) label = codecLabelOf(requested);
  if (label.isEmpty) return size.isEmpty ? '--' : size;
  return size.isEmpty ? label : '$label $size';
}

/* ------------------------------------------------------------ 内部 */

/// 取 `?` 与 `#` 之间的查询串（不解析、不解码，原样切片）。
///
/// 为什么不用 `Uri.parse`：爱奇艺地址里带着未编码的中文片名
/// （`title=济公传`），个别片名还带空格 / `&`，交给 `Uri` 解析会被
/// 重新编码甚至抛异常 —— 这条地址要原样交给服务端，不能被我们改写。
String _queryOf(String url) {
  final raw = url.trim();
  final q = raw.indexOf('?');
  if (q < 0) return '';
  final hash = raw.indexOf('#', q);
  return hash < 0 ? raw.substring(q + 1) : raw.substring(q + 1, hash);
}

/// 取路径部分（去掉 scheme / host / 查询串 / 片段）。
String _pathOf(String url) {
  final raw = url.trim();
  if (raw.isEmpty) return '';
  final noHash = raw.split('#').first;
  final noQuery = noHash.split('?').first;
  final schemeAt = noQuery.indexOf('://');
  final afterHost = schemeAt < 0 ? noQuery : noQuery.substring(schemeAt + 3);
  final slashAt = afterHost.indexOf('/');
  if (slashAt < 0) return '';
  return afterHost.substring(slashAt);
}

/// 删掉查询串里所有 `hevc=` 参数（其它参数一个都不动，顺序保持）。
String _stripHevc(String url) {
  final hashAt = url.indexOf('#');
  final head = hashAt < 0 ? url : url.substring(0, hashAt);
  final tail = hashAt < 0 ? '' : url.substring(hashAt);
  final q = head.indexOf('?');
  if (q < 0) return url;
  final base = head.substring(0, q);
  final query = head.substring(q + 1);
  final kept = <String>[];
  for (final pair in query.split('&')) {
    if (pair.isEmpty) continue;
    final cut = pair.indexOf('=');
    final key = cut < 0 ? pair : pair.substring(0, cut);
    if (key == 'hevc') continue;
    kept.add(pair);
  }
  if (kept.isEmpty) return '$base$tail';
  return '$base?${kept.join('&')}$tail';
}

/// 追加一个查询参数：已有查询串用 `&`，没有才用 `?`。
String _appendParam(String url, String key, String value) {
  final hashAt = url.indexOf('#');
  final head = hashAt < 0 ? url : url.substring(0, hashAt);
  final tail = hashAt < 0 ? '' : url.substring(hashAt);
  // 结尾是 `?` / `&`（极少见但合法）时不要再补分隔符。
  final sep = head.contains('?')
      ? (head.endsWith('?') || head.endsWith('&') ? '' : '&')
      : '?';
  return '$head$sep$key=$value$tail';
}

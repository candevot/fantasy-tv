/// 幻想影视 · CMS 采集数据源解析层（CMS_LAYER 第二阶段）。
///
/// 这一层只做**纯字符串解析**，不联网、不碰 UI、不依赖 cms_api.dart：
///   · `vod_play_from` / `vod_play_url` → `List<CmsLine>`（线路 + 每集地址）
///   · 判断一条地址是「能直接播的 m3u8」还是「要交给 hxparse 现解析的页面 / 令牌」
///   · 线路名 / 线路 id 的查找（播放页只拿线路名也能定位线路）
///
/// 站点实际数据形态（2026-11-15 实测）：
///   · `幻想4K`   → 地址是令牌 `FY-SH4K-<md5>`，必须走 hxparse/fuying
///   · `量子`     → 地址是 `https://lzv34.com/share/<md5>` 页面，也走 hxparse/fuying
///   · `幻想爱奇艺` → **已经给的是成品地址**
///     `http://…/hxparse/play/iqiyi/1/index.m3u8?title=…&ep=1`（302 → 429KB 清单），
///     直接播，不要再套 `/hxparse/parse/iqiyi`
///   · `红牛`     → `https://hn.bfvvs.com/play/<id>/index.m3u8` 直链
///
/// 所以判断依据是**地址本身**，不是线路名：同一条线路换采集源后地址形态会变，
/// 按名字硬编码一定会在某天全部误判（「幻想爱奇艺」就是这么被误判成要解析的）。
/// 具体规则集中在 `play_path.dart`（纯函数、可独立核验）。
///
/// IQ_CODEC（2026-11-15，**不在这里**）：爱奇艺同一个地址换个查询参数就是
/// 另一条码流 —— 带 `hevc=1` 是 1920×1080 HEVC，不带是 896×504 H.264。
/// 但「要不要 hevc」取决于**这台设备能不能硬解 HEVC**，属于播放器的事：
/// 规则在 `iqiyi_codec.dart`（纯函数）与 `iq_codec_gate.dart`（设备能力 +
/// 失败降级），改写发生在播放页拿到候选地址之后。不写进这一层是因为解析结果
/// 有 10 分钟缓存（`FxPlayCache`），把编码写进缓存等于把「本机能力」和
/// 「这条地址」绑死，换设备 / 换线路后会立刻错。
library;

import '../models.dart';
import 'play_path.dart';

/// 线路 / 集的分隔符（苹果CMS 固定用这三个）。
const String kLineSep = r'$$$';

/// 一条 CMS 线路：线路身份（交给 UI）+ 它**自己**的集名 / 集地址（交给播放）。
///
/// LINE_EPNAMES：每条线路的集名独立保存，不再全站共用一条线路的集名 ——
/// 否则某条线路只更到 12 集，却显示另一条线路的 40 集，点进去播不出来。
class CmsLine {
  CmsLine({required this.info, required this.names, required this.urls});

  final LineInfo info;
  final List<String> names;
  final List<String> urls;

  int get count => urls.length;

  /// 需要 hxparse 现解析（令牌 / 页面地址 / 爱奇艺占位）。
  bool get needsParse => info.type.trim().toLowerCase() == 'parse';

  /// ep 从 1 开始；越界返回 null。
  String? urlAt(int ep) {
    if (ep < 1 || ep > urls.length) return null;
    return urls[ep - 1];
  }

  /// ep 从 1 开始；越界返回空串。
  String nameAt(int ep) {
    if (ep < 1 || ep > names.length) return '';
    return names[ep - 1];
  }

  /// 这一集是不是爱奇艺占位（播放时按集号现查，地址不存在）。
  bool isIqiyiAt(int ep) {
    final url = urlAt(ep);
    return url != null && url.startsWith(kIqiyiMark);
  }
}

/* ------------------------------------------------------------ 切分 */

/// 按分隔符切，**保留空段**：`vod_play_from` 与 `vod_play_url` 必须按下标对齐，
/// 丢掉空段会让「第 2 条线路」的名字配到「第 3 条线路」的地址上。
List<String> splitAligned(String raw, String sep) {
  final text = raw.trim();
  if (text.isEmpty) return const <String>[];
  return <String>[for (final part in text.split(sep)) part.trim()];
}

/// 按分隔符切并丢掉空段（`$` 切线路、`,` 切 id 列表共用）。
List<String> splitRaw(String raw, String sep) {
  final text = raw.trim();
  if (text.isEmpty) return const <String>[];
  return <String>[
    for (final part in text.split(sep))
      if (part.trim().isNotEmpty) part.trim(),
  ];
}

/// 采集失败时后台塞进来的占位地址（实测「其他」分类里有一条
/// `vod_play_from=tips` / `vod_play_url=about:blank` 的「采集数据获取失败」记录）。
///
/// 这种集地址既有集名又不像空串，不拦掉的话详情页会多出一条叫 `tips` 的线路，
/// 点开必然解析失败 —— 用户以为是我们播放器坏了。
bool isPlaceholderAddress(String address) {
  final text = address.trim().toLowerCase();
  if (text.isEmpty) return true;
  return text == 'about:blank' ||
      text.startsWith('javascript:') ||
      text == 'null' ||
      text == 'undefined';
}

/// 一段 `集名$地址#集名$地址` → `[[集名, 地址], …]`。
///
/// 集名可以为空（`$http://…`）。地址里的 `#` 服务端已经转成 `%23`，
/// 所以按 `#` 切不会把地址切断；`%23` 原样留在地址里（它本身就是合法 URL 字符）。
List<List<String>> epPairs(String block) {
  final text = block.trim();
  if (text.isEmpty) return const <List<String>>[];
  final out = <List<String>>[];
  for (final chunk in text.split('#')) {
    final item = chunk.trim();
    if (item.isEmpty) continue;
    final cut = item.indexOf(r'$');
    final name = cut > 0 ? item.substring(0, cut).trim() : '';
    final address = cut >= 0 ? item.substring(cut + 1).trim() : item;
    if (isPlaceholderAddress(address)) continue;
    out.add(<String>[name, address]);
  }
  return out;
}

/* ------------------------------------------------------------ 地址判定 */

/// 能不能直接播：http(s) 且带媒体后缀，或已经是本站解析产物。
///
/// 规则本体在 `play_path.dart`（纯函数，可独立核验）。这一层保留同名入口，
/// 是因为详情页 / 播放页 / 下载 / 单测都在用它，改名没有收益。
bool isMediaUrl(String address) => isDirectAddress(address);

/// 需要现场解析（不是直链）。
bool needsParse(String address) => needsParseAddress(address);

/// 页面 / 令牌该找哪个解析器：`direct` / `iqiyi` / `fuying`。
///
/// PARSE_ONCE2（2026-11-15）：**地址优先，线路名兜底**。站点现在给
/// 「幻想爱奇艺」的是成品地址 `/hxparse/play/iqiyi/1/index.m3u8?…`，
/// 之前只按线路名里带「爱奇艺」就判 `iqiyi`，等于告诉播放链路「这条还要
/// 解析」——详情页会先弹「正在解析 幻想爱奇艺」，任何信任 `LineInfo.type`
/// 的路径（下载 / 一起看 / 全屏）都会把它再套一层 `/hxparse/parse/iqiyi`，
/// 套出来的地址语义已经变了，而原地址本来就能播。
String parseKindOf(String lineName, String address) =>
    parseKindFor(lineName, address);

/* ------------------------------------------------------------ 线路解析 */

/// `vod_play_from` + `vod_play_url` → 线路表。
///
/// 切法：`$$$` 切线路 → `#` 切集 → `$` 切「集名」与「地址」。
///
/// 两种特殊情况：
///   · 有线路名但**没有地址块**：只有爱奇艺这种「不来自采集」的线路才允许，
///     按其它线路的最长集数补齐占位集，保证它在列表里可选；
///   · 地址块为空又认不出线路：直接跳过，不让空线路进 UI。
List<CmsLine> parseLines(Map<String, dynamic> vod) {
  final vodId = _text(vod['vod_id']);
  final froms = splitAligned(_text(vod['vod_play_from']), kLineSep);
  final blocks = splitAligned(_text(vod['vod_play_url']), kLineSep);
  final total = froms.length > blocks.length ? froms.length : blocks.length;

  // 先摸一遍所有地址块，算出「这部剧最长有多少集」——爱奇艺占位线路要用。
  var longest = _intOf(vod['vod_total']);
  for (final block in blocks) {
    final n = epPairs(block).length;
    if (n > longest) longest = n;
  }

  final out = <CmsLine>[];
  for (var i = 0; i < total; i++) {
    final rawName = i < froms.length ? froms[i] : '';
    final block = i < blocks.length ? blocks[i] : '';
    final pairs = epPairs(block);
    final fallbackName = '线路${out.length + 1}';
    final name = rawName.isEmpty ? fallbackName : rawName;

    if (pairs.isEmpty) {
      // 爱奇艺：没有采集地址，按最长集数补占位（至少 1 集，电影就是「正片」）。
      if (parseKindOf(name, '') != 'iqiyi') continue;
      final count = longest < 1 ? 1 : longest;
      final epNames = <String>[
        for (var k = 0; k < count; k++) count == 1 ? '正片' : '第${k + 1}集',
      ];
      out.add(CmsLine(
        info: LineInfo(
          'cms_${vodId.isEmpty ? '0' : vodId}_${out.length + 1}',
          name,
          'parse',
          out.length,
          from: name,
          epNames: epNames,
        ),
        names: epNames,
        urls: <String>[for (var k = 0; k < count; k++) '$kIqiyiMark${k + 1}'],
      ));
      continue;
    }

    final urls = <String>[for (final pair in pairs) pair[1]];
    final names = <String>[
      for (var k = 0; k < pairs.length; k++)
        pairs[k][0].isNotEmpty
            ? pairs[k][0]
            // 单集线路叫「正片」，多集才叫「第 N 集」：
            // 电影照搬「第01集」会被用户当成剧集。
            : (pairs.length == 1 ? '正片' : '第${k + 1}集'),
    ];
    // PARSE_ONCE2（2026-11-15）：线路「要不要解析」只看**它自己的地址**。
    //
    // 这里原来还 or 了一个 `parseKindOf(name, urls.first) == 'iqiyi'`，等于
    // 只要线路名里带「爱奇艺」就强行标成 parse —— 站点现在给「幻想爱奇艺」
    // 的是成品地址 `/hxparse/play/iqiyi/1/index.m3u8?…`（302 → 429KB 清单），
    // 于是整条链路都被这句标记带偏：详情页先弹「正在解析」，凡信任
    // `LineInfo.type` 的地方还会再套一层解析。
    // 地址是直链就是 hls，是令牌 / 页面 / `iqiyi:` 占位才叫 parse —— 占位
    // 地址本身过不了 [needsParse]，所以这一句已经覆盖了爱奇艺那种情况。
    final parse = urls.any(needsParse);
    out.add(CmsLine(
      info: LineInfo(
        'cms_${vodId.isEmpty ? '0' : vodId}_${out.length + 1}',
        name,
        parse ? 'parse' : 'hls',
        out.length,
        from: name,
        epNames: names,
      ),
      names: names,
      urls: urls,
    ));
  }
  return out;
}

/// 只要线路身份（含 epnames / 集数）时用这个：[parseLines] 的投影。
List<LineInfo> lineInfosOf(Map<String, dynamic> vod) =>
    <LineInfo>[for (final line in parseLines(vod)) line.info];

/// 按线路 id 或线路名找线路：先精确（id / 显示名 / 原始 from），
/// 再按「基础名」前缀匹配（`幻想4K·高清` ↔ `幻想4K`），都找不到返回 null。
CmsLine? findLine(List<CmsLine> lines, String key) {
  final wanted = key.trim();
  if (wanted.isEmpty) return null;
  for (final line in lines) {
    if (line.info.id == wanted) return line;
  }
  for (final line in lines) {
    if (line.info.displayName == wanted) return line;
    if ((line.info.from ?? '').trim() == wanted) return line;
  }
  final wantedBase = baseNameOf(wanted);
  for (final line in lines) {
    final base = baseNameOf(line.info.displayName);
    if (base.isEmpty || wantedBase.isEmpty) continue;
    if (base == wantedBase ||
        base.startsWith(wantedBase) ||
        wantedBase.startsWith(base)) {
      return line;
    }
  }
  return null;
}

/// 线路名去掉「·高清」「-线路2」这类后缀后的基础名（与 models.dart 同规则）。
String baseNameOf(String raw) {
  final name = raw.trim();
  if (name.isEmpty) return '';
  final base = name.split(RegExp(r'\s*[·・•|｜/\\\-–—_:：]\s*')).first.trim();
  return base.isEmpty ? name : base;
}

String _text(Object? raw) {
  if (raw == null) return '';
  if (raw is String) return raw.trim();
  return '$raw'.trim();
}

int _intOf(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse(_text(raw)) ?? 0;
}

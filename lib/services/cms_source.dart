/// 幻想影视 · CMS 采集数据源解析层（CMS_LAYER 第二阶段）。
///
/// 这一层只做**纯字符串解析**，不联网、不碰 UI、不依赖 cms_api.dart：
///   · `vod_play_from` / `vod_play_url` → `List<CmsLine>`（线路 + 每集地址）
///   · 判断一条地址是「能直接播的 m3u8」还是「要交给 hxparse 现解析的页面 / 令牌」
///   · 线路名 / 线路 id 的查找（播放页只拿线路名也能定位线路）
///
/// 站点实际数据形态（2026-11-14 实测全量 919 部）：
///   · `幻想4K`   → 地址是令牌 `FY-SH4K-<md5>`，必须走 hxparse/fuying
///   · `量子`     → 地址是 `https://lzv34.com/share/<md5>` 页面，也走 hxparse/fuying
///   · 有的采集源给的是真 m3u8 直链 → 直接播，不解析
///   · `幻想爱奇艺` 不来自采集，没有任何集地址 → 按「剧名 + 年份 + 第几集」现查
///
/// 所以判断依据是**地址本身**，不是线路名：同一条线路换采集源后地址形态会变，
/// 按名字硬编码一定会在某天全部误判。
library;

import '../models.dart';

/// 爱奇艺线路的占位地址前缀。
///
/// 爱奇艺线路不是采集来的，`vod_play_url` 里根本没有地址；为了让「集数 / 集名」
/// 和其它线路一样参与展示，给每一集填一个占位标记，播放时再按集号现查。
const String kIqiyiMark = 'iqiyi:';

/// 线路 / 集的分隔符（苹果CMS 固定用这三个）。
const String kLineSep = r'$$$';

/// 静态资源后缀：命中就是能直接播的地址，不是平台页面。
final RegExp _mediaExt =
    RegExp(r'\.(m3u8|mp4|mkv|flv|mov|ts)(\?|#|$)', caseSensitive: false);

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

/// 本站解析服务已经生好的播放地址（`/hxparse/xo?u=…`、`/hxparse/play/…`）。
///
/// PARSE_ONCE（2026-11-15）：这些地址是**解析的产物**，不是待解析的令牌 / 页面。
/// 以前 `isMediaUrl` 只认媒体后缀，于是 `/hxparse/xo?u=SH4K-xxx` 被判成
/// 「还需要解析」，又被套进 `/hxparse/parse/fuying?u=…` 转了一层：
///   · 多一次 302 + 中转解析，起播白多 0.9~2 秒；
///   · 中转站（hc.fuyingapi.top）和直连（api.wki8.com）并不等价；
///   · 平台页面地址（qq 那条）本身带 `&t=&y=`，套两层后参数语义已经变了。
/// 认出这层包装就直接当直链播，交给播放器的清单代理去跟 302。
final RegExp _wrappedPlaylist =
    RegExp(r'/hxparse/(?:xo|play|parse)(?:/|\?|$)', caseSensitive: false);

/// 能不能直接播：http(s) 且带媒体后缀。
///
/// 注意 `幻想4K` 的地址是 `FY-SH4K-<md5>` 令牌，连 http 都不是；
/// `量子` 是 `https://lzv34.com/share/<md5>` 页面 —— 两者都要走 hxparse。
bool isMediaUrl(String address) {
  final text = address.trim().toLowerCase();
  if (!text.startsWith('http://') && !text.startsWith('https://')) return false;
  if (_mediaExt.hasMatch(text)) return true;
  // 已经由本站解析服务包装好的清单地址：直接播，不再二次解析。
  return _wrappedPlaylist.hasMatch(text);
}

/// 需要现场解析（不是直链）。
bool needsParse(String address) => !isMediaUrl(address);

/// 页面 / 令牌该找哪个解析器：爱奇艺线路按「剧名 + 年份 + 集号」查，
/// 其余（幻想4K / 幻想蓝光 / 量子 / 红牛 …）都交给福盈。
String parseKindOf(String lineName, String address) {
  final name = lineName.toLowerCase();
  final host = (Uri.tryParse(address.trim())?.host ?? '').toLowerCase();
  if (name.contains('爱奇艺') ||
      name.contains('iqiyi') ||
      host.contains('iqiyi') ||
      address.trim().startsWith(kIqiyiMark)) {
    return 'iqiyi';
  }
  return 'fuying';
}

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
    final parse =
        urls.any(needsParse) || parseKindOf(name, urls.first) == 'iqiyi';
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

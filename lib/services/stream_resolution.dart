/// 线路分辨率的**纯函数**判定（RESOLUTION，2026-11-15）。
///
/// 这个文件不 import 任何 Flutter / 插件依赖，所以既能被 App 引用，
/// 也能被纯 Dart 脚本 / 单测直接跑（用来核对真实接口数据的排序结果）。
///
/// 下面这些是历史文档，说明为什么这么判：
///
/// 排序依据是**线路的实际分辨率**，不是线路名硬编码出来的权重 ——
/// 名字只能当兜底线索，真实分辨率优先从数据里读。
///
/// 每条线路怎么定分辨率（按优先级）：
///   1. `vod_play_url` 里的标注（集名 / 地址里的 `4K`、`1080P`、`超清`，
///      或者 `3840x2160` 这种宽高）；
///   2. `vod_play_url` / `vod_quality` 这类清晰度字段（jar 源常给）；
///   3. 线路名推断：`SH4K`/`幻想4K` → 2160p、`幻想蓝光` → 1080p、
///      `幻想爱奇艺` → 1080p、`shvip` → 1080p、`bilibili/qiyi/qq/mgtv/youku`
///      → 1080p、`量子`/`红牛` → 720p（免费源，保守估）；
///   4. 完全认不出来 → 480p。
///
/// 分数：
/// ```
/// 2160p → 100     1440p → 90     1080p → 75
///  720p →  50     480p  → 20      未知  → 10
///
/// 记录分 = 最高分辨率分 × 0.7 + 线路数 × 5
/// ```
/// 也就是「画质上限优先，线路多再加一点」，跨源用同一套（我们自己的源、
/// 云端线路切片、肥猫的 41 个 jar 源都走这里）。
library;

/// 分辨率档位（长边像素）。
class ResTier {
  const ResTier(this.height, this.label);

  /// 归一化后的高度（2160 / 1440 / 1080 / 720 / 480）。
  final int height;
  final String label;

  @override
  String toString() => label;
}

const ResTier res2160 = ResTier(2160, '2160p');
const ResTier res1440 = ResTier(1440, '1440p');
const ResTier res1080 = ResTier(1080, '1080p');
const ResTier res720 = ResTier(720, '720p');
const ResTier res480 = ResTier(480, '480p');

/// 「读不到分辨率」的哨兵（和 480p 区分：未知排最后）。
const ResTier resUnknown = ResTier(0, '未知');

/// 高度 → 分数。
double scoreOfTier(ResTier tier) {
  switch (tier.height) {
    case 2160:
      return 100;
    case 1440:
      return 90;
    case 1080:
      return 75;
    case 720:
      return 50;
    case 480:
      return 20;
    default:
      return 10;
  }
}

/// 高度（像素，可能是 2160 / 1080 这种「档位」，也可能是真实短边）→ 档位。
ResTier tierOfHeight(int height) {
  if (height <= 0) return resUnknown;
  if (height >= 2000) return res2160;
  if (height >= 1400) return res1440;
  if (height >= 1000) return res1080;
  if (height >= 700) return res720;
  if (height >= 400) return res480;
  return res480;
}

/// 线路名 → 档位（兜底推断）。
///
/// 判定顺序有讲究：`幻想4K` 里也含 `4k`，而它其实是我们自己的 4K 源
/// （2160p），所以先认它；`qiyi` 是平台线（1080p），`幻想爱奇艺` 实测也是
/// 1080p，两者同档。
ResTier tierOfLineName(String raw) {
  final name = raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
  if (name.isEmpty) return resUnknown;
  bool has(List<String> words) => words.any(name.contains);

  if (has(const <String>['sh4k', '幻想4k', 'fx4k', 'fx-4k'])) return res2160;
  if (has(const <String>['4k', 'uhd', '2160'])) return res2160;
  if (has(const <String>['1440', '2k'])) return res1440;
  if (has(const <String>['1080'])) return res1080;
  if (has(const <String>['720', 'hd'])) return res720;
  // 平台线 / 我们的蓝光、爱奇艺、shvip：实测都是 1080p 档。
  if (has(const <String>[
    '幻想蓝光',
    '蓝光',
    '幻想爱奇艺',
    '爱奇艺',
    'iqiyi',
    'qiyi',
    'shvip',
    'bilibili',
    'b站',
    'qq',
    'mgtv',
    '芒果',
    'youku',
    '优酷',
    '腾讯',
  ])) {
    return res1080;
  }
  // 免费源：保守按 720p 估。
  if (has(const <String>['量子', '红牛'])) return res720;
  // 清晰度字面量（肥猫那些源的线路名常带 BD / HD / 超清 这类）。
  if (has(const <String>['蓝光', 'bd', '超清', '高清1080'])) return res1080;
  if (has(const <String>['高清', 'hd'])) return res720;
  if (has(const <String>['标清', 'sd'])) return res480;
  // 第三层没数据前的默认：**按 1080p 估**（影视壳的源绝大多数是 1080）。
  // 「金牌极速 / 旋风VIP / 电影天堂」这类名字里没有任何分辨率线索，
  // 按 480p 估会把肥猫的源整体压到最底下，和实际观感不符。
  return res1080;
}

final RegExp _whPattern = RegExp(r'(\d{3,4})\s*[x×*]\s*(\d{3,4})');

/// 从一段文本里读分辨率标注（集名、地址后缀、`3840x2160` 之类）。
///
/// 只认「明显是画质标注」的东西：
///   · `3840x2160` / `1920×1080` 这种宽高；
///   · `4k` / `2160p` / `1080p` / `720p` 这种带 p 或 k 的字面量；
///   · `超清` / `高清` / `标清` 中文标注。
/// 不认裸数字，避免把地址里的 `1080` 目录名当成画质（宁可当未知）。
ResTier tierOfText(String raw) {
  final text = raw.toLowerCase();
  if (text.trim().isEmpty) return resUnknown;
  for (final match in _whPattern.allMatches(text)) {
    final w = int.tryParse(match.group(1) ?? '') ?? 0;
    final h = int.tryParse(match.group(2) ?? '') ?? 0;
    final side = w > h ? h : w;
    if (side >= 400) return tierOfHeight(side);
  }
  if (text.contains('2160') || text.contains('4k')) return res2160;
  if (text.contains('1440')) return res1440;
  if (text.contains('1080')) return res1080;
  if (text.contains('720')) return res720;
  if (text.contains('480')) return res480;
  if (text.contains('超清') || text.contains('高清')) return res1080;
  if (text.contains('标清')) return res480;
  return resUnknown;
}

/// 一条线路的分辨率：数据标注优先，其次线路名推断。
ResTier tierOfLine({required String lineName, required String block}) {
  // 1. 集名（`#` 段的 `$` 前面那截）里常有「第1集 4K」这种标注。
  final nameText = StringBuffer();
  for (final chunk in block.split('#')) {
    final item = chunk.trim();
    if (item.isEmpty) continue;
    final cut = item.indexOf(r'$');
    if (cut > 0) nameText.write(' ${item.substring(0, cut)}');
  }
  final fromNames = tierOfText(nameText.toString());
  if (fromNames.height > 0) return fromNames;
  // 2. 地址本身带的画质目录（`/4k/`、`1080p/`）。
  final fromUrl = tierOfText(block);
  if (fromUrl.height > 0) return fromUrl;
  // 3. 线路名推断。
  return tierOfLineName(lineName);
}

/// 一条记录的打分结果（给界面 / 日志用）。
class SearchScore {
  const SearchScore({
    required this.resolution,
    required this.lineCount,
    required this.score,
  });

  /// 最高的那条线路的分辨率。
  final ResTier resolution;

  /// 有地址的线路数。
  final int lineCount;

  /// `最高分辨率分 × 0.7 + 线路数 × 5`。
  final double score;

  String get label => '${resolution.label} / $lineCount 条线路 / ${score.toStringAsFixed(1)} 分';

  @override
  String toString() => label;
}

/// 空结果（没线路 / 认不出来）。
const SearchScore emptyScore = SearchScore(
  resolution: ResTier(0, '未知'),
  lineCount: 0,
  score: 0,
);

/// `vod_play_from` + `vod_play_url` → 分数。
///
/// [learnedHeightByLine] 是第三层「播放器真正出过的分辨率」（线路名 → 高度），
/// 传进来就直接用它覆盖第二层的估算。
SearchScore scoreOfRecord({
  required String playFrom,
  required String playUrl,
  String extraQuality = '',
  Map<String, int> learnedHeightByLine = const <String, int>{},
}) {
  final froms = _split(playFrom);
  final blocks = _split(playUrl);
  if (blocks.isEmpty) return emptyScore;
  var best = resUnknown;
  var count = 0;
  for (var i = 0; i < blocks.length; i++) {
    final block = blocks[i];
    if (!_blockHasAddress(block)) continue;
    final name = i < froms.length ? froms[i] : '';
    // 第三层：播放器真出过画面就按真实分辨率算（优先级最高）。
    final learned = learnedHeightByLine[name];
    var tier = learned != null && learned > 0
        ? tierOfHeight(learned)
        : tierOfLine(lineName: name, block: block);
    // 记录级清晰度字段（有的 jar 源直接在 vod 上给 `quality: "4K"`）。
    if (tier.height == 0 && extraQuality.trim().isNotEmpty) {
      tier = tierOfText(extraQuality);
    }
    count++;
    if (scoreOfTier(tier) > scoreOfTier(best)) best = tier;
  }
  if (count == 0) return emptyScore;
  final score = scoreOfTier(best) * 0.7 + count * 5;
  return SearchScore(resolution: best, lineCount: count, score: score);
}

/* ------------------------------------------------------------ 内部 */

List<String> _split(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return const <String>[];
  return <String>[for (final part in text.split(r'$$$')) part.trim()];
}

bool _blockHasAddress(String block) {
  final text = block.trim();
  if (text.isEmpty) return false;
  for (final chunk in text.split('#')) {
    final item = chunk.trim();
    if (item.isEmpty) continue;
    final cut = item.indexOf(r'$');
    final address = (cut >= 0 ? item.substring(cut + 1) : item).trim();
    if (address.isEmpty) continue;
    final lower = address.toLowerCase();
    if (lower == 'about:blank' ||
        lower.startsWith('javascript:') ||
        lower == 'null' ||
        lower == 'undefined') {
      continue;
    }
    return true;
  }
  return false;
}

/// 补线路的**纯规则层**（ENRICH 2026-11-15）。
///
/// 只放判定与文案，不联网、不读缓存、不碰 UI —— 和 `fallback_match.dart`
/// 同一个套路，这样规则能被 `dart run tools/test_line_enrich.dart` 直接钉住。
///
/// 具体做事的在 `line_enrich.dart`（探测走 `line_probe.dart` 的三级预检，
/// 命中写 SharedPreferences）。
library;

/// 补进来的线路 id 前缀：一眼能看出「这条不是服务端给的」。
const String kEnrichIdPrefix = 'enrich:';

/// 幻想爱奇艺的线路名（和服务端一致，用户看到的文案不变）。
const String kEnrichIqiyiName = '幻想爱奇艺';

/// 福盈4K 的线路名（服务端两种写法都有）。
const String kEnrichSh4kName = 'SH4K';

/// 明确**不补**的线路：福盈解析接口坏了，补上去是死线路。
///
/// 用户原话：「福盈蓝光（PAN1）福盈解析接口坏了，先不补」。这条规则必须
/// 写死在规则层：补一条点了不出画的线，比不补更糟。
const List<String> kEnrichSkipNames = <String>['PAN1', '福盈蓝光'];

/// 补线路的日志标签（和应用内 `[FxPlay]` 分开，方便 `grep FxEnrich`）。
const String kEnrichLogTag = 'FxEnrich';

/// 命中缓存的时长：24 小时。
const Duration kEnrichTtl = Duration(hours: 24);

/// 一条补进来的线路（纯数据，不带 UI 类型）。
class EnrichHit {
  const EnrichHit({
    required this.name,
    required this.episodes,
    this.kind = 'iqiyi',
    this.borrowVodId = '',
    this.borrowLineId = '',
  });

  /// 线路显示名：`幻想爱奇艺` / `SH4K`。
  final String name;

  /// 对方实际集数（探不到就不补这条）。
  final int episodes;

  /// `iqiyi` = 解析服务现取成品地址；`borrow` = 借用另一条记录的线路地址。
  final String kind;

  /// `borrow` 用：那部片的 vodId 与线路 id。
  final String borrowVodId;
  final String borrowLineId;

  /// 这条线路在 App 里的 id（稳定：同一部片同一线路每次算出来都一样）。
  String get lineId => switch (kind) {
    'borrow' => '$kEnrichIdPrefix${name}_${borrowVodId}_$borrowLineId',
    _ => '$kEnrichIdPrefix$name',
  };

  /// 是不是「借用别的记录」的线路。
  bool get borrowed => kind == 'borrow';

  Map<String, Object?> toJson() => <String, Object?>{
    'n': name,
    'e': episodes,
    'k': kind,
    'v': borrowVodId,
    'l': borrowLineId,
  };

  static EnrichHit? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = (raw['n'] as String?)?.trim() ?? '';
    final eps = (raw['e'] as num?)?.toInt() ?? 0;
    if (name.isEmpty || eps <= 0) return null;
    return EnrichHit(
      name: name,
      episodes: eps,
      kind: (raw['k'] as String?)?.trim() ?? 'iqiyi',
      borrowVodId: (raw['v'] as String?)?.trim() ?? '',
      borrowLineId: (raw['l'] as String?)?.trim() ?? '',
    );
  }
}

/// 一部片的补线路结果（也是缓存条目）。
class EnrichEntry {
  const EnrichEntry({
    required this.title,
    required this.year,
    required this.atMs,
    required this.hits,
  });

  final String title;
  final int year;
  final int atMs;
  final List<EnrichHit> hits;

  Map<String, Object?> toJson() => <String, Object?>{
    't': title,
    'y': year,
    'at': atMs,
    'h': <Object?>[for (final hit in hits) hit.toJson()],
  };

  static EnrichEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final at = (raw['at'] as num?)?.toInt() ?? 0;
    if (at <= 0) return null;
    final rawHits = raw['h'];
    return EnrichEntry(
      title: (raw['t'] as String?)?.trim() ?? '',
      year: (raw['y'] as num?)?.toInt() ?? 0,
      atMs: at,
      hits: <EnrichHit>[
        if (rawHits is List)
          for (final item in rawHits)
            if (EnrichHit.fromJson(item) != null) EnrichHit.fromJson(item)!,
      ],
    );
  }
}

/// 片名归一化（去大小写、空白、标点）。
///
/// 和 `fallback_match.dart` 的 `fxNormTitle` 同一套规则 —— 两套归一化迟早
/// 会出现「这边认为是同一部、那边不认」。
String enrichNormTitle(String raw) => raw
    .trim()
    .toLowerCase()
    .replaceAll(
      RegExp(r'[\s\u3000·・•,，。.、:：;；!！?？\-—_/\\|｜()（）\[\]【】]'),
      '',
    );

/// 缓存键：归一化片名 + 年份（和去重规则一致）。
String enrichKeyOf(String title, int year) =>
    '${enrichNormTitle(title)}|${year > 0 ? year : 0}';

/// 缓存是否还有效（24 小时）。
bool enrichFresh({required int atMs, required int nowMs}) {
  if (atMs <= 0) return false;
  final age = nowMs - atMs;
  if (age < 0) return true;
  return age <= kEnrichTtl.inMilliseconds;
}

/// 这条线路名在**不补**名单里吗（福盈蓝光 / PAN1）。
bool enrichBlocked(String lineName) {
  final upper = lineName.trim().toUpperCase();
  if (upper.isEmpty) return true;
  return kEnrichSkipNames.any((skip) => upper.contains(skip.toUpperCase()));
}

/// 线路名是不是福盈4K / SH4K（要补的那一条）。
bool enrichIsSh4k(String lineName) {
  final text = lineName.trim();
  if (text.isEmpty) return false;
  return text.toUpperCase().contains('SH4K') || text.contains('福盈4K');
}

/// 集名：单集叫「正片」，多集叫「第 N 集」。
///
/// 和服务端 `epPairs` 的规则一致，否则详情页的选集条会和别的线路不齐。
List<String> enrichEpisodeNames(int episodes) {
  final n = episodes < 1 ? 1 : episodes;
  return <String>[
    for (var i = 0; i < n; i++) n == 1 ? '正片' : '第${i + 1}集',
  ];
}

/// 固定日志格式：`[FxEnrich] vod=济公传 add=幻想爱奇艺,SH4K hit=2/2`。
String enrichLog({
  required String title,
  required List<String> added,
  required int wanted,
}) {
  final name = title.trim().isEmpty ? '未知' : title.trim();
  final list = added.isEmpty ? 'none' : added.join(',');
  return '[$kEnrichLogTag] vod=$name add=$list hit=${added.length}/$wanted';
}

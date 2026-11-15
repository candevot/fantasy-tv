/// 补线路的**纯规则层**（ENRICH 2026-11-15）。
///
/// 只放判定与文案，不联网、不读缓存、不碰 UI —— 和 `fallback_match.dart`
/// 同一个套路，这样规则能被 `dart run tools/test_line_enrich.dart` 直接钉住。
///
/// 用户口径（动态探测，不写死排除任何线路）：
/// ```
/// 三条都去试：幻想爱奇艺 / 福盈4K(SH4K) / 福盈蓝光(PAN1)
/// 每条先探测能不能解析出可播地址（line_probe 三关：连接 → 清单 → 首片）
///   探通了 → 补进线路列表
///   探不通 → 不补，并记住失败时间（1 小时内不再探它）
/// ```
/// 这样「福盈蓝光哪天自己好了，下一次搜索就会自动补出来」——不用改代码。
library;

/// 补进来的线路 id 前缀：一眼能看出「这条不是服务端给的」。
const String kEnrichIdPrefix = 'enrich:';

/// 幻想爱奇艺的线路名（和服务端一致，用户看到的文案不变）。
const String kEnrichIqiyiName = '幻想爱奇艺';

/// 福盈4K 的线路名（服务端两种写法都有）。
const String kEnrichSh4kName = 'SH4K';

/// 福盈蓝光的线路名（历史上解析接口坏过，现在**照样动态探**）。
const String kEnrichPan1Name = '福盈蓝光';

/// 补线路的日志标签（和应用内 `[FxPlay]` 分开，方便 `grep FxEnrich`）。
const String kEnrichLogTag = 'FxEnrich';

/// 探测成功后的缓存时长：24 小时。
const Duration kEnrichOkTtl = Duration(hours: 24);

/// 探测失败后的冷却：1 小时内不再探它（别拿坏线路反复打接口）。
const Duration kEnrichFailTtl = Duration(hours: 1);

/// 一个可补的线路来源。
///
/// [aliases] 是服务端可能用的其它写法（同名线路在不同采集源里名字不一样）。
class EnrichProvider {
  const EnrichProvider({
    required this.name,
    required this.kind,
    this.aliases = const <String>[],
  });

  /// App 里显示的线路名。
  final String name;

  /// `iqiyi` = 解析服务按「片名 + 年份 + 集号」现取；`borrow` = 借同名同年
  /// 的另一条记录里同名线路的地址。
  final String kind;

  /// 匹配服务端线路名时额外认的写法。
  final List<String> aliases;

  /// 这个服务端线路名是不是本来源。
  bool matches(String lineName) {
    final text = lineName.trim();
    if (text.isEmpty) return false;
    if (text.toLowerCase() == name.toLowerCase()) return true;
    if (text.contains(name)) return true;
    return aliases.any((alias) => text.toUpperCase().contains(alias.toUpperCase()));
  }
}

/// 要补的三条线路（顺序 = 补进来的优先级，也是排序里的次序）。
const List<EnrichProvider> enrichProviders = <EnrichProvider>[
  EnrichProvider(name: kEnrichIqiyiName, kind: 'iqiyi'),
  EnrichProvider(
    name: kEnrichSh4kName,
    kind: 'borrow',
    aliases: <String>['福盈4K'],
  ),
  EnrichProvider(
    name: kEnrichPan1Name,
    kind: 'borrow',
    aliases: <String>['PAN1'],
  ),
];

/// 一条线路的探测结果（也是缓存条目）。
class EnrichLineState {
  const EnrichLineState({
    required this.name,
    required this.ok,
    required this.atMs,
    this.episodes = 0,
    this.stage = '',
    this.reason = '',
    this.borrowVodId = '',
    this.borrowLineId = '',
  });

  /// 线路名：`幻想爱奇艺` / `SH4K` / `福盈蓝光`。
  final String name;

  /// 探通了没有（探通才补进列表）。
  final bool ok;

  /// 探测时刻（毫秒时间戳）。
  final int atMs;

  /// 对方实际集数（ok 才有意义；不硬凑）。
  final int episodes;

  /// ok 时是最后通过的阶段（`manifest`），失败时是**失败的那个阶段**。
  final String stage;

  /// 失败原因（`http_400` / `dns_error` / `no_segments` …）；ok 时为空。
  final String reason;

  /// `borrow` 用：被借的记录与线路 id。
  final String borrowVodId;
  final String borrowLineId;

  /// 是不是借来的线路（地址在别的记录上）。
  bool get borrowed => borrowVodId.isNotEmpty && borrowLineId.isNotEmpty;

  /// 线路 id：稳定、带前缀，播放器靠前缀决定去问 LineEnrich。
  String get lineId => borrowed
      ? '$kEnrichIdPrefix${name}_${borrowVodId}_$borrowLineId'
      : '$kEnrichIdPrefix$name';

  /// 这条记录还有效吗：成功 24 小时，失败 1 小时。
  bool fresh(int nowMs) {
    if (atMs <= 0) return false;
    final age = nowMs - atMs;
    if (age < 0) return true;
    return age <= (ok ? kEnrichOkTtl : kEnrichFailTtl).inMilliseconds;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'n': name,
    'ok': ok,
    'at': atMs,
    'e': episodes,
    'st': stage,
    'r': reason,
    'v': borrowVodId,
    'l': borrowLineId,
  };

  static EnrichLineState? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = (raw['n'] as String?)?.trim() ?? '';
    final at = (raw['at'] as num?)?.toInt() ?? 0;
    if (name.isEmpty || at <= 0) return null;
    return EnrichLineState(
      name: name,
      ok: raw['ok'] == true,
      atMs: at,
      episodes: (raw['e'] as num?)?.toInt() ?? 0,
      stage: (raw['st'] as String?)?.trim() ?? '',
      reason: (raw['r'] as String?)?.trim() ?? '',
      borrowVodId: (raw['v'] as String?)?.trim() ?? '',
      borrowLineId: (raw['l'] as String?)?.trim() ?? '',
    );
  }
}

/// 一部片的补线路结果（缓存里 = `enrich[片名|年份]`）。
class EnrichEntry {
  const EnrichEntry({
    required this.title,
    required this.year,
    required this.atMs,
    required this.lines,
  });

  final String title;
  final int year;
  final int atMs;
  final List<EnrichLineState> lines;

  /// 探通了的线路（真正补进详情页的那些）。
  List<EnrichLineState> get usable => <EnrichLineState>[
    for (final line in lines)
      if (line.ok && line.episodes > 0) line,
  ];

  Map<String, Object?> toJson() => <String, Object?>{
    't': title,
    'y': year,
    'at': atMs,
    'lines': <Object?>[for (final line in lines) line.toJson()],
  };

  static EnrichEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final at = (raw['at'] as num?)?.toInt() ?? 0;
    if (at <= 0) return null;
    final rawLines = raw['lines'];
    return EnrichEntry(
      title: (raw['t'] as String?)?.trim() ?? '',
      year: (raw['y'] as num?)?.toInt() ?? 0,
      atMs: at,
      lines: <EnrichLineState>[
        if (rawLines is List)
          for (final item in rawLines)
            if (EnrichLineState.fromJson(item) != null)
              EnrichLineState.fromJson(item)!,
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

/// 缓存键：归一化片名 + 年份。
String enrichKeyOf(String title, int year) =>
    '${enrichNormTitle(title)}|${year > 0 ? year : 0}';

/// 集名：单集叫「正片」，多集叫「第 N 集」。
///
/// 和服务端 `epPairs` 的规则一致，否则详情页的选集条会和别的线路不齐。
List<String> enrichEpisodeNames(int episodes) {
  final n = episodes < 1 ? 1 : episodes;
  return <String>[
    for (var i = 0; i < n; i++) n == 1 ? '正片' : '第${i + 1}集',
  ];
}

/// 单条线路的日志：`[FxEnrich] vod=济公传 line=幻想爱奇艺 ok=true eps=58` /
/// `[FxEnrich] vod=济公传 line=福盈蓝光 ok=false stage=manifest reason=http_400`。
String enrichLineLog({
  required String title,
  required EnrichLineState line,
}) {
  final name = title.trim().isEmpty ? '未知' : title.trim();
  final tail = line.ok
      ? 'ok=true eps=${line.episodes}'
      : 'ok=false stage=${line.stage.isEmpty ? 'probe' : line.stage} '
            'reason=${line.reason.isEmpty ? 'unknown' : line.reason}';
  return '[$kEnrichLogTag] vod=$name line=${line.name} $tail';
}

/// 一部片补完后的汇总日志（一眼看命中几条）：
/// `[FxEnrich] vod=济公传 add=幻想爱奇艺,SH4K hit=2/3`。
String enrichSummaryLog({
  required String title,
  required List<String> added,
  required int probed,
}) {
  final name = title.trim().isEmpty ? '未知' : title.trim();
  final list = added.isEmpty ? 'none' : added.join(',');
  return '[$kEnrichLogTag] vod=$name add=$list hit=${added.length}/$probed';
}

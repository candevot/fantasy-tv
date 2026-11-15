/// 补线路规则层的回归（ENRICH 2026-11-15）。
///
/// 补线路的三个判定点，错任何一个用户都会直接看到：
///   · 福盈蓝光（PAN1）被补上去 → 点开不出画（解析接口坏了）；
///   · 集数硬凑 → 选集条多出播不了的集；
///   · 缓存键不稳定 → 同一部片每次进详情都重新探一遍。
///
/// 跑法：`dart run tools/test_line_enrich.dart`（纯 Dart，不需要 Flutter SDK）
library;

import '../lib/services/line_enrich_rules.dart';

var _checks = 0;

void _check(bool ok, String name) {
  if (!ok) throw StateError(name);
  _checks++;
  print('PASS $name');
}

void main() {
  // 缓存键：归一化后同一部片是同一个键，年份不同是不同键。
  _check(
    enrichKeyOf(' 济公传·高清 ', 2016) == enrichKeyOf('济公传高清', 2016),
    '缓存键：标点 / 空格不影响',
  );
  _check(
    enrichKeyOf('济公传', 2016) != enrichKeyOf('济公传', 2017),
    '缓存键：年份不同是不同条目',
  );
  _check(enrichKeyOf('', 0) == '|0', '缓存键：空片名也能算出一个稳定键');

  // 24 小时缓存。
  const at = 1700000000000;
  _check(
    enrichFresh(atMs: at, nowMs: at + 23 * 3600 * 1000),
    '缓存：23 小时内有效',
  );
  _check(
    !enrichFresh(atMs: at, nowMs: at + 25 * 3600 * 1000),
    '缓存：25 小时过期要重探',
  );

  // 不补名单：福盈蓝光 / PAN1 绝不能被补上去。
  _check(enrichBlocked('PAN1'), '不补：PAN1');
  _check(enrichBlocked('福盈蓝光'), '不补：福盈蓝光');
  _check(enrichBlocked('福盈蓝光 1080P'), '不补：带后缀的福盈蓝光');
  _check(!enrichBlocked('SH4K'), '可补：SH4K 不在跳过名单');
  _check(!enrichBlocked('幻想爱奇艺'), '可补：幻想爱奇艺不在跳过名单');

  // 要补的 SH4K 线路名识别（服务端两种写法）。
  _check(enrichIsSh4k('SH4K'), '识别：SH4K');
  _check(enrichIsSh4k('福盈4K'), '识别：福盈4K');
  _check(!enrichIsSh4k('福盈蓝光'), '识别：福盈蓝光不是 SH4K');
  _check(!enrichIsSh4k('幻想蓝光'), '识别：幻想蓝光不是 SH4K');

  // 集数：单集叫「正片」，多集叫「第 N 集」（和服务端一致）。
  _check(enrichEpisodeNames(1).join(',') == '正片', '集名：单集是正片');
  _check(
    enrichEpisodeNames(3).join(',') == '第1集,第2集,第3集',
    '集名：多集是第 N 集',
  );
  _check(enrichEpisodeNames(0).length == 1, '集名：0 集兜底成 1 集');

  // 线路 id：稳定、带前缀（播放器靠前缀决定去问 LineEnrich）。
  const iqiyi = EnrichHit(name: kEnrichIqiyiName, episodes: 40);
  _check(
    iqiyi.lineId.startsWith(kEnrichIdPrefix),
    'id：带 enrich: 前缀',
  );
  _check(
    iqiyi.lineId == const EnrichHit(name: kEnrichIqiyiName, episodes: 41).lineId,
    'id：同一线路集数变化不影响 id',
  );
  const borrow = EnrichHit(
    name: kEnrichSh4kName,
    episodes: 40,
    kind: 'borrow',
    borrowVodId: '123',
    borrowLineId: 'cms_123_2',
  );
  _check(borrow.borrowed, '借用的线路标记为 borrow');
  _check(
    borrow.lineId.contains('123') && borrow.lineId.contains('cms_123_2'),
    'id：借用线路带上被借的记录与线路',
  );

  // JSON 往返：缓存写进 prefs 再读回来不能变样。
  const entry = EnrichEntry(
    title: '济公传',
    year: 2016,
    atMs: at,
    hits: <EnrichHit>[iqiyi, borrow],
  );
  final restored = EnrichEntry.fromJson(entry.toJson());
  _check(restored != null, 'JSON：能读回来');
  _check(restored!.hits.length == 2, 'JSON：两条线路都在');
  _check(restored.hits.first.lineId == iqiyi.lineId, 'JSON：线路 id 不变');
  _check(
    restored.hits.last.borrowLineId == 'cms_123_2',
    'JSON：借用信息不丢',
  );
  _check(EnrichHit.fromJson(<String, Object?>{'n': 'x', 'e': 0}) == null,
      'JSON：集数非法就丢');

  // 固定日志格式。
  _check(
    enrichLog(
          title: '济公传',
          added: <String>[kEnrichIqiyiName, kEnrichSh4kName],
          wanted: 2,
        ) ==
        '[FxEnrich] vod=济公传 add=幻想爱奇艺,SH4K hit=2/2',
    '日志：[FxEnrich] vod=济公传 add=幻想爱奇艺,SH4K hit=2/2',
  );
  _check(
    enrichLog(title: '某片', added: const <String>[], wanted: 2) ==
        '[FxEnrich] vod=某片 add=none hit=0/2',
    '日志：一条都没命中也要打',
  );

  print('ALL PASS ($_checks checks)');
}

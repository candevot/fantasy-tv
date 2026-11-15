/// 补线路规则层的回归（ENRICH 2026-11-15，动态探测口径）。
///
/// 这一层错了用户会直接看到：
///   · 三条线路漏掉一条（该补的没补）；
///   · 把探不通的线路补上去 → 点开不出画；
///   · 缓存时限错（成功 24h / 失败 1h）→ 要么重复打接口、要么坏线路永久拉黑；
///   · 集数硬凑 → 选集条多出播不了的集。
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

  // 三条线路都要试（动态探测：不写死排除任何一条）。
  _check(enrichProviders.length == 3, '三条线路都在探测清单里');
  _check(
    enrichProviders.map((p) => p.name).join(',') ==
        '幻想爱奇艺,SH4K,福盈蓝光',
    '顺序：幻想爱奇艺 → SH4K → 福盈蓝光',
  );
  _check(
    enrichProviders.any((p) => p.kind == 'iqiyi'),
    '幻想爱奇艺走解析服务',
  );
  _check(
    enrichProviders.last.kind == 'borrow',
    '福盈蓝光走「借同名线路」，不是写死排除',
  );

  // 服务端线路名识别（同名线路在不同采集源里写法不一样）。
  final sh4k = enrichProviders[1];
  final pan1 = enrichProviders[2];
  _check(sh4k.matches('SH4K'), '识别：SH4K');
  _check(sh4k.matches('福盈4K'), '识别：福盈4K 也算 SH4K');
  _check(!sh4k.matches('福盈蓝光'), '识别：福盈蓝光不是 SH4K');
  _check(pan1.matches('福盈蓝光'), '识别：福盈蓝光');
  _check(pan1.matches('PAN1'), '识别：PAN1 也算福盈蓝光');
  _check(!pan1.matches('SH4K'), '识别：SH4K 不是福盈蓝光');

  // 成功 24 小时 / 失败 1 小时。
  const at = 1700000000000;
  const okState = EnrichLineState(
    name: kEnrichIqiyiName,
    ok: true,
    atMs: at,
    episodes: 58,
    stage: 'manifest',
  );
  const badState = EnrichLineState(
    name: kEnrichPan1Name,
    ok: false,
    atMs: at,
    stage: 'manifest',
    reason: 'http_400',
  );
  _check(okState.fresh(at + 23 * 3600 * 1000), '成功缓存：23 小时内有效');
  _check(!okState.fresh(at + 25 * 3600 * 1000), '成功缓存：25 小时过期');
  _check(badState.fresh(at + 50 * 60 * 1000), '失败缓存：50 分钟内不再探');
  _check(!badState.fresh(at + 70 * 60 * 1000), '失败缓存：1 小时后可以重探');

  // 集名：单集叫「正片」，多集叫「第 N 集」。
  _check(enrichEpisodeNames(1).join(',') == '正片', '集名：单集是正片');
  _check(
    enrichEpisodeNames(3).join(',') == '第1集,第2集,第3集',
    '集名：多集是第 N 集',
  );

  // 线路 id：稳定、带前缀（播放器靠前缀决定去问 LineEnrich）。
  _check(
    okState.lineId == const EnrichLineState(
      name: kEnrichIqiyiName,
      ok: true,
      atMs: at + 1000,
      episodes: 60,
    ).lineId,
    'id：同一条线路集数变化不影响 id',
  );
  const borrow = EnrichLineState(
    name: kEnrichSh4kName,
    ok: true,
    atMs: at,
    episodes: 40,
    borrowVodId: '123',
    borrowLineId: 'cms_123_2',
  );
  _check(borrow.borrowed, '借来的线路标记为 borrowed');
  _check(
    borrow.lineId.startsWith(kEnrichIdPrefix) &&
        borrow.lineId.contains('cms_123_2'),
    'id：借用线路带上被借的记录与线路',
  );

  // 「补进列表」只用探通的：探不通的绝不进列表。
  const entry = EnrichEntry(
    title: '济公传',
    year: 2016,
    atMs: at,
    lines: <EnrichLineState>[okState, badState, borrow],
  );
  _check(entry.usable.length == 2, '只补探通的两条');
  _check(
    entry.usable.every((line) => line.ok && line.episodes > 0),
    '补的线路都有集数',
  );

  // JSON 往返：缓存写进 prefs 再读回来不能变样。
  final restored = EnrichEntry.fromJson(entry.toJson());
  _check(restored != null && restored.lines.length == 3, 'JSON：三条都在');
  _check(
    restored!.lines[1].reason == 'http_400' &&
        restored.lines[1].stage == 'manifest',
    'JSON：失败阶段与原因都不丢',
  );
  _check(
    restored.lines.last.borrowLineId == 'cms_123_2',
    'JSON：借用信息不丢',
  );

  // 日志格式（用户指定）。
  _check(
    enrichLineLog(title: '济公传', line: okState) ==
        '[FxEnrich] vod=济公传 line=幻想爱奇艺 ok=true eps=58',
    '日志：探通那条按指定格式',
  );
  _check(
    enrichLineLog(title: '济公传', line: badState) ==
        '[FxEnrich] vod=济公传 line=福盈蓝光 ok=false stage=manifest '
            'reason=http_400',
    '日志：探不通那条带阶段与原因',
  );
  _check(
    enrichSummaryLog(
          title: '济公传',
          added: <String>[kEnrichIqiyiName, kEnrichSh4kName],
          probed: 3,
        ) ==
        '[FxEnrich] vod=济公传 add=幻想爱奇艺,SH4K hit=2/3',
    '日志：汇总命中 2/3',
  );

  print('ALL PASS ($_checks checks)');
}

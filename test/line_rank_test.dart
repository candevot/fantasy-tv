import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fantasy_tv/models.dart';
import 'package:fantasy_tv/services/line_cooldown.dart';
import 'package:fantasy_tv/services/line_health.dart';

/// 线路排序 / 默认线路的回归（KNOWN_BAD 2026-11-15）。
///
/// 用户实测报障：「换一部剧默认还是幻想蓝光 → 直接闪退」「进去播不了
/// 就直接显示失败，不往下一线路走」。两条现象在排序这一层的根因是同一个：
///
///   · 详情页默认线路以前取 `FxLineCooldown.sortLines(...).first` ——
///     只认「10 分钟内失败过」，新装的 App 冷却表是空的，于是原样取服务端
///     第一条；而服务端按「线路名推断分辨率」把幻想蓝光（1080P）排在
///     量子 / 红牛（720P）前面，FY-PAN1 令牌解析又必然 404；
///   · `rankLines` 只看预检档案，没预检过的死线路是「未知」档，和健康线路
///     同权 —— 于是它照样排在第一。
///
/// 这里钉住：死线路沉最后且**不被选为默认**；冷却中 / 预检判坏 / 服务端
/// degraded 的排在健康线路后面；手动选过的好线路仍然优先。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await FxLineCooldown.clearAll();
    await LineHealth.instance.clear();
  });

  LineInfo line(String name, {bool degraded = false}) => LineInfo(
        'id-$name',
        name,
        'hls',
        0,
        from: name,
        degraded: degraded,
      );

  group('rankLines / defaultLine（已知不可用的线路沉后且不当默认）', () {
    test('死线路（幻想蓝光）排最后，默认线路跳过它', () {
      final lines = <LineInfo>[
        line('幻想蓝光'),
        line('量子'),
        line('红牛'),
      ];
      final ranked = LineHealth.instance.rankLines('100', lines);
      expect(ranked.last.displayName, '幻想蓝光');

      final pick = LineHealth.instance.defaultLine('100', lines);
      expect(pick, isNotNull);
      expect(pick!.displayName, isNot('幻想蓝光'));
      expect(pick.displayName, '量子');
    });

    test('mgtv 同样算死线路', () {
      final lines = <LineInfo>[line('mgtv'), line('量子')];
      expect(LineHealth.instance.defaultLine('101', lines)!.displayName, '量子');
    });

    test('冷却中的线路沉后，不当默认', () async {
      final now = DateTime(2026, 11, 15, 12);
      final lines = <LineInfo>[line('红牛'), line('量子')];
      FxLineCooldown.markFailed('102', '红牛', now: now);

      final ranked = LineHealth.instance.rankLines('102', lines, now: now);
      expect(ranked.first.displayName, '量子');
      expect(
        LineHealth.instance.defaultLine('102', lines, now: now)!.displayName,
        '量子',
      );
    });

    test('预检判坏（ok=false）的线路沉后，不当默认', () async {
      final now = DateTime(2026, 11, 15, 12);
      await LineHealth.instance.record(
        vodId: '103',
        lineName: '红牛',
        ok: false,
        now: now,
      );
      final lines = <LineInfo>[line('红牛'), line('量子')];
      expect(
        LineHealth.instance.defaultLine('103', lines, now: now)!.displayName,
        '量子',
      );
      expect(
        LineHealth.instance.rankLines('103', lines, now: now).last.displayName,
        '红牛',
      );
    });

    test('服务端标 degraded 的线路不当默认（未知档里它也是坏的那一半）', () {
      final lines = <LineInfo>[
        line('红牛', degraded: true),
        line('量子'),
      ];
      expect(LineHealth.instance.defaultLine('104', lines)!.displayName, '量子');
    });

    test('健康线路优先于未知线路', () async {
      final now = DateTime(2026, 11, 15, 12);
      await LineHealth.instance.record(
        vodId: '105',
        lineName: '量子',
        ok: true,
        now: now,
      );
      final lines = <LineInfo>[line('红牛'), line('量子')];
      expect(
        LineHealth.instance.defaultLine('105', lines, now: now)!.displayName,
        '量子',
      );
    });

    test('全是死线路时退回第一条（详情页会照常提示暂无可播放地址）', () {
      final lines = <LineInfo>[line('幻想蓝光'), line('mgtv')];
      expect(
        LineHealth.instance.defaultLine('106', lines)?.id,
        lines.first.id,
      );
    });

    test('空列表返回 null，单条列表原样返回', () {
      expect(LineHealth.instance.defaultLine('107', const <LineInfo>[]), isNull);
      final one = <LineInfo>[line('量子')];
      expect(LineHealth.instance.defaultLine('107', one)!.displayName, '量子');
    });
  });
}

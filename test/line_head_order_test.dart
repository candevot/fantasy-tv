// 用户钉死的线路顺序：咕噜4K → SH4K → 幻想爱奇艺 → 其余原序。
import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/models.dart';
import 'package:fantasy_tv/services/jar_sources.dart';

LineInfo _l(String name, String id) => LineInfo(id, name, 'hls', 0, from: name);

void main() {
  test('前三条按指定顺序提最前，其余保持原序', () {
    final lines = <LineInfo>[
      _l('红牛', 'a'),
      _l('幻想爱奇艺', 'b'),
      _l('lz', 'c'),
      _l('SH4K', 'd'),
      _l('咕噜·咕噜4K', fxJarLineId('咕噜', '1', '咕噜4K')),
      _l('暴风资源', fxJarLineId('咕噜', '1', '暴风资源')),
      _l('qq', 'qq'),
    ];
    final out = fxApplyLineHeadOrder(lines).map((e) => e.displayName).toList();
    expect(out[0], 'qq'); // 腾讯4K 首位
    expect(out[1].contains('咕噜4K'), isTrue);
    expect(out[2], 'SH4K');
    expect(out[3], '幻想爱奇艺');
    expect(out.sublist(4), containsAll(<String>['红牛', 'lz', '暴风资源']));
  });

  test('缺哪条就跳过，不追加假的', () {
    final lines = <LineInfo>[_l('红牛', 'a'), _l('SH4K', 'd')];
    final out = fxApplyLineHeadOrder(lines).map((e) => e.displayName).toList();
    expect(out, <String>['SH4K', '红牛']);
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/models.dart';
import 'package:fantasy_tv/services/jar_sources.dart';
import 'package:fantasy_tv/services/line_fallback_order.dart';
import 'package:fantasy_tv/services/line_session.dart' show fxLineAllPrunedText;

/// GROUP_ORDER（2026-11-21 用户明确要求）：
///
/// ```
/// 播放不了 → 先在当前主线路（大类）里换下一条子线路
/// 当前大类的子线路全播不了 → 才切到另一个主线路（另一个大类）
/// 全部大类都失败 → 提示「本片暂无可用线路」
/// ```
///
/// 这里钉的是**候选顺序本身**（纯函数 `fxFallbackLineOrder` / `fxFallbackNextLine`），
/// 详情页 `_switchNextLine`、播放器 `autoTryAllLines` 都从这一份取顺序：
///   · 候选 = 当前大类的其它子线路（按第二行显示顺序）
///   ·       → 下一个大类的全部子线路（大类按第一行显示顺序，环形）
///   · 全部失败 → 本片暂无可用线路
///
/// 现场 bug：扁平线路列表被 `fxOwnLinesFirst` / 健康度排序 / jar 合并重排过，
/// 旧实现 `(index + step) % length` 会「幻想→咕噜→幻想」乱跳。
void main() {
  LineInfo own(String name) => LineInfo('id_$name', name, 'hls', 0);
  LineInfo jar(String from, {String vodId = '1'}) => LineInfo(
        fxJarLineId('咕噜', vodId, from),
        '咕噜·$from',
        'hls',
        0,
      );

  /// 按页面真实走法跑完一整条链：每次取「下一条」，取到就记成失败再取。
  /// 返回依次尝试的线路名（顺序 = 用户看到的一串自动切换）。
  ///
  /// 起始线路本身就是刚失败的那条，所以先记进「已失败」——
  /// 页面上它也正是先 `_failedLines.add` / 冷却后才来取下一次候选。
  List<String> chain(
    List<LineInfo> lines, {
    required String start,
    Set<String> alreadyFailed = const <String>{},
  }) {
    final failed = <String>{
      if (start.trim().isNotEmpty) start,
      ...alreadyFailed,
    };
    var current = start;
    final seq = <String>[];
    for (var guard = 0; guard < lines.length + 2; guard++) {
      final next = fxFallbackNextLine(
        lines: lines,
        currentLineId: current,
        skip: failed,
      );
      if (next == null) break;
      seq.add(next.displayName);
      failed.add(next.id);
      current = next.id;
    }
    return seq;
  }

  /* -------------------------------------------- ① 大类内走完才切下个大类 */

  test('① 幻想 3 条子线路全失败后，才切到咕噜大类的第一条子线路', () {
    final lines = <LineInfo>[
      own('幻想爱奇艺'),
      own('SH4K'),
      own('红牛'),
      jar('4K'),
      jar('量子资源'),
    ];
    final seq = chain(lines, start: 'id_幻想爱奇艺');
    // 前三条 = 幻想大类的其它三条子线路（顺序和显示一致）。
    expect(seq.take(2).toList(), <String>['SH4K', '红牛']);
    // 第 3 次切换（下标 2）才是咕噜大类，而且从它的**第一条**子线路开始。
    expect(seq[2], '咕噜·4K');
    expect(seq[3], '咕噜·量子资源');
    expect(seq.length, 4);
    // 咕噜大类里不许出现「先跳第二条再回头」。
    expect(seq.indexOf('咕噜·4K'), lessThan(seq.indexOf('咕噜·量子资源')));
  });

  test('①-b 扁平列表里两个大类交错时，仍然先走完当前大类', () {
    // 详情页实际给到播放器的列表长这样（jar 合并 / 排序后交错）。
    final lines = <LineInfo>[
      own('幻想爱奇艺'),
      jar('4K'),
      own('SH4K'),
      jar('量子资源'),
      own('红牛'),
    ];
    // 显示顺序：幻想 = 爱奇艺 / SH4K / 红牛，咕噜 = 4K / 量子资源。
    expect(
      chain(lines, start: 'id_幻想爱奇艺'),
      <String>['SH4K', '红牛', '咕噜·4K', '咕噜·量子资源'],
    );
  });

  /* --------------------------------------- ② 同一大类内先换，不跨大类乱跳 */

  test('② 当前大类还有子线路时，绝不跳到另一个大类', () {
    final lines = <LineInfo>[
      own('幻想爱奇艺'),
      jar('4K'),
      own('SH4K'),
      jar('量子资源'),
    ];
    final order = fxFallbackLineOrder(
      lines: lines,
      currentLineId: 'id_幻想爱奇艺',
    );
    expect(order.map((l) => l.displayName).toList(), <String>[
      'SH4K',
      '咕噜·4K',
      '咕噜·量子资源',
    ]);
    final next = fxFallbackNextLine(
      lines: lines,
      currentLineId: 'id_幻想爱奇艺',
    );
    expect(next?.displayName, 'SH4K');
    expect(fxLineGroupKeyOf(next!), kOwnLineGroupKey);
  });

  test('②-b 当前在咕噜大类：先走完咕噜的其它子线路，再回到幻想大类', () {
    final lines = <LineInfo>[
      own('幻想爱奇艺'),
      own('SH4K'),
      jar('4K'),
      jar('量子资源'),
    ];
    expect(
      chain(lines, start: fxJarLineId('咕噜', '1', '4K')),
      <String>['咕噜·量子资源', '幻想爱奇艺', 'SH4K'],
    );
    // 同一大类内再切时不跨大类。
    final next = fxFallbackNextLine(
      lines: lines,
      currentLineId: fxJarLineId('咕噜', '1', '4K'),
    );
    expect(next?.displayName, '咕噜·量子资源');
    expect(fxLineGroupKeyOf(next!), '咕噜');
  });

  /* ------------------------------------------------- ③ 全部失败的提示文案 */

  test('③ 全部大类都失败：没有下一条，提示「本片暂无可用线路」', () {
    final lines = <LineInfo>[
      own('幻想爱奇艺'),
      own('SH4K'),
      jar('4K'),
    ];
    expect(
      fxFallbackNextLine(
        lines: lines,
        currentLineId: 'id_幻想爱奇艺',
        skip: <String>{'id_SH4K', fxJarLineId('咕噜', '1', '4K')},
      ),
      isNull,
    );
    expect(fxLineNoUsableText, '本片暂无可用线路');
    // 只有一个大类、且全部失败：同样落到这句话上。
    final ownOnly = <LineInfo>[own('幻想爱奇艺'), own('SH4K')];
    expect(
      fxFallbackNextLine(
        lines: ownOnly,
        currentLineId: 'id_幻想爱奇艺',
        skip: <String>{'id_SH4K'},
      ),
      isNull,
    );
    expect(fxLineNoUsableText, fxLineAllPrunedText);
  });

  /* -------------------------------------------- ④ 手动选线路的优先级最高 */

  test('④ 手动选的线路失败后，仍按「当前大类 → 下个大类」回退', () {
    final lines = <LineInfo>[
      own('幻想爱奇艺'),
      own('SH4K'),
      own('红牛'),
      jar('4K'),
      jar('量子资源'),
    ];
    // 用户手动点了「红牛」，前两条幻想线路已经失败过。
    final next = fxFallbackNextLine(
      lines: lines,
      currentLineId: 'id_红牛',
      skip: <String>{'id_幻想爱奇艺', 'id_SH4K'},
    );
    // 幻想大类没有别的子线路了 → 才进咕噜大类第一条。
    expect(next?.displayName, '咕噜·4K');
    // 手动选中的线路本身不会被「回退」成别人（它不是候选）。
    expect(
      fxFallbackLineOrder(lines: lines, currentLineId: 'id_红牛')
          .map((l) => l.id),
      isNot(contains('id_红牛')),
    );
  });

  /* --------------------------------------------------------- 边界 / 顺序 */

  test('不知道当前线路（重试全部线路）时按显示顺序从第一个大类开始', () {
    final lines = <LineInfo>[
      jar('4K'),
      own('幻想爱奇艺'),
      own('SH4K'),
    ];
    expect(
      fxFallbackLineOrder(lines: lines).map((l) => l.displayName).toList(),
      <String>['幻想爱奇艺', 'SH4K', '咕噜·4K'],
    );
  });

  test('当前线路已从列表里移除（播失败即消失）时，从第一个大类重新排', () {
    final lines = <LineInfo>[own('SH4K'), jar('4K')];
    expect(
      fxFallbackLineOrder(lines: lines, currentLineId: 'id_已移除')
          .map((l) => l.displayName)
          .toList(),
      <String>['SH4K', '咕噜·4K'],
    );
  });

  test('空列表 / 全被跳过：候选为空，不会造出一条假线路', () {
    expect(fxFallbackLineOrder(lines: const <LineInfo>[]), isEmpty);
    final lines = <LineInfo>[own('幻想爱奇艺')];
    expect(
      fxFallbackNextLine(
        lines: lines,
        currentLineId: 'id_幻想爱奇艺',
        skip: <String>{'id_幻想爱奇艺'},
      ),
      isNull,
    );
  });

  test('线路 id 重复时不重复入列（jar 合并重名只出现一次）', () {
    final dup = LineInfo('id_dup', 'SH4K', 'hls', 0);
    final lines = <LineInfo>[
      own('幻想爱奇艺'),
      dup,
      LineInfo('id_dup', 'SH4K', 'hls', 0),
      jar('4K'),
    ];
    expect(
      fxFallbackLineOrder(lines: lines, currentLineId: 'id_幻想爱奇艺')
          .map((l) => l.id)
          .toList(),
      <String>['id_dup', fxJarLineId('咕噜', '1', '4K')],
    );
  });

  test('degraded 沉后只在同一大类内做，不许把线路挪到别的大类后面', () {
    LineInfo degraded(String name) =>
        LineInfo('id_$name', name, 'hls', 0, degraded: true);
    final lines = <LineInfo>[
      degraded('幻想爱奇艺'),
      own('SH4K'),
      own('红牛'),
      jar('4K'),
    ];
    final order = fxFallbackLineOrder(lines: lines);
    expect(order.map((l) => l.displayName).toList(), <String>[
      '幻想爱奇艺',
      'SH4K',
      '红牛',
      '咕噜·4K',
    ]);
    // 生效中的默认线路沉到**幻想大类内部**最后，而不是排到咕噜后面。
    expect(
      fxSortDegradedWithinGroups(order).map((l) => l.displayName).toList(),
      <String>['SH4K', '红牛', '幻想爱奇艺', '咕噜·4K'],
    );
  });
}

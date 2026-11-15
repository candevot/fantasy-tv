// 搜索修复的**实机（可运行环境）验证脚本**，不属于 CI 门禁。
//
// 跑法（需要联网，会真的请求主站）：
//   flutter test tool/search_live_probe.dart
//
// 它做三件事，全部走 App 真实代码路径：
//   1. ③ 搜「济公传」：把 CmsBridge.searchStream 的结果按页面同样的
//      `_appendUnique` 规则合并，打印「我们自己的」那一段 ——
//      验证「空壳记录被过滤」「同名记录只留线路多的那条」「切片 id 带线路名」。
//   2. ③ 详情：分别用**旧的裸 id**（900000003）和**新的切片 id**
//      （@line:幻想爱奇艺::900000003）调 CmsBridge.detail，对比成功 / 失败。
//   3. ⑤ 肥猫：把现场那批无关结果喂给客户端相关性闸门，打印过滤后肥猫那一段
//      的片名 —— 验收标准是「留下的每一条片名都和关键词相关」。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/models.dart';
import 'package:fantasy_tv/services/cms_bridge.dart';
import 'package:fantasy_tv/services/search_relevance.dart';
import 'package:fantasy_tv/services/source_hub.dart';

const String _kQuery = '济公传';

Future<void> main() async {
  // flutter_test 默认会把 HttpClient 换成假实现，这里要真的发请求。
  HttpOverrides.global = null;

  test('③ 搜「济公传」：自己的那一段没有空壳 / 没有重复', () async {
    final own = <VideoCard>[];
    final external = <VideoCard>[];
    await for (final batch in CmsBridge.searchStream(_kQuery, 1)) {
      final target = batch.external ? external : own;
      // 与页面 SearchPage._appendUnique 完全同一套规则（同一批 helper）。
      for (final card in batch.items) {
        if (target.any((c) => c.id == card.id)) continue;
        final at = target.indexWhere((c) => SourceHub.sameRecord(c, card));
        if (at < 0) {
          target.add(card);
        } else if (SourceHub.betterRecord(card, target[at])) {
          target[at] = card;
        }
      }
      if (batch.finished) break;
    }

    stdout.writeln('\n=== ③ 我们自己的结果（${own.length} 条）===');
    for (final c in own) {
      stdout.writeln('  ${c.title} | year=${c.year} | id=${c.id} '
          '| lines=${c.lineCount} | from=${c.fromSource}');
    }
    expect(own, isNotEmpty, reason: '主站应该有「济公传」相关记录');
    // 空壳：一条可用线路都没有的记录不许出现。
    for (final c in own) {
      expect(c.lineCount, greaterThan(0), reason: '${c.title} 是空壳记录');
    }
    // 同名同年只留一条（旧实现会同时留主库那条和「幻想爱奇艺」切片那条）。
    final keys = <String>{};
    for (final c in own) {
      final key = '${c.title.trim()}|${c.year}';
      if (c.fromSource.isEmpty) continue; // 通配（切片 / 外部源）不参与这条断言
      expect(keys.add(key), isTrue, reason: '同名同年重复出现：$key');
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('③ 那条记录：裸 id 打不开，切片 id 能打开', () async {
    const bareId = '900000003';
    Object? bareError;
    try {
      await CmsBridge.detail(bareId);
    } catch (e) {
      bareError = e;
    }
    stdout.writeln('\n=== ③ 裸 id $bareId → ${bareError ?? '（居然成功了）'}');
    expect(bareError, isNotNull,
        reason: '这条切片的平台线 id 在主库里并不存在（就是用户报的那一条）');

    final detail = await CmsBridge.detail(
      CmsBridge.sliceId('幻想爱奇艺', bareId),
    );
    stdout.writeln('=== ③ 切片 id → 《${detail.title}》线路 '
        '${detail.lines.map((l) => l.name).join(' / ')}');
    expect(detail.title, contains('济公'));
    expect(detail.lines, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('⑤ 肥猫那一段：和「济公传」无关的片名一条都不许留', () {
    // 现场（用户报的那次）肥猫分区实际显示的东西，外加两条真正相关的。
    const reported = <String>[
      '背着善宰跑',
      '与恶魔有约',
      '爱情怎么翻译',
      '釜山行前传：首尔站',
    ];
    const relevant = <String>['济公传', '济公新传', '新编济公传奇国语'];
    final raw = <VideoCard>[
      for (final t in reported)
        VideoCard(id: 'fatcat:$t', title: t, cover: '', year: 2024),
      for (final t in relevant)
        VideoCard(id: 'fatcat:$t', title: t, cover: '', year: 2016),
    ];
    final kept = fxRelevantCards(raw, _kQuery);
    stdout.writeln('\n=== ⑤ 肥猫分区过滤后（${kept.length} 条）===');
    for (final c in kept) {
      stdout.writeln('  ${c.title}  相关度=${fxSearchScore(c.title, _kQuery).toStringAsFixed(2)}');
    }
    for (final c in kept) {
      expect(
        fxSearchRelevant(c.title, _kQuery),
        isTrue,
        reason: '${c.title} 与「$_kQuery」无关，不该出现在肥猫分区',
      );
      expect(reported.contains(c.title), isFalse,
          reason: '${c.title} 是现场那批无关结果');
    }
    expect(kept.length, relevant.length,
        reason: '相关的都要留，无关的都要丢');
  });
}

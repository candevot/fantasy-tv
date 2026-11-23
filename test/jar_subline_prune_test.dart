// JAR_PLATFORM_WEB + JAR_SUB_ORDER（2026-11-22 实测《八仙》15 条子线路）：
//   · 爱奇艺 / 腾讯视频 / 优酷 / bilibili 这几条子线路 playerContent 回的是
//     **网页地址**，我们没有 WebView 嗅探器 → 必须当死线直接消失；
//   · 真能播的只有「暴风资源」（2371KB/s）和「咕噜4K」（447KB/s），
//     默认线路要优先挑快的那条。
import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/models.dart';
import 'package:fantasy_tv/services/jar_sources.dart';
import 'package:fantasy_tv/services/play_path.dart';

LineInfo _line(String name, String id) =>
    LineInfo(id, name, 'hls', 0, from: name);

void main() {
  test('jar 里回网页地址的平台子线路被剔掉（CMS 的同类线路不受影响）', () {
    final groups = <LineInfo>[
      _line('咕噜·暴风资源', fxJarLineId('咕噜', '1', '暴风资源')),
      _line('咕噜·爱奇艺', fxJarLineId('咕噜', '1', '爱奇艺')),
      _line('咕噜·腾讯视频', fxJarLineId('咕噜', '1', '腾讯视频')),
      _line('咕噜·bilibili', fxJarLineId('咕噜', '1', 'bilibili')),
      _line('咕噜·mgtv', fxJarLineId('咕噜', '1', 'mgtv')),
      _line('咕噜·玫瑰4K', fxJarLineId('咕噜', '1', '玫瑰4K')),
      _line('咕噜·量子资源', fxJarLineId('咕噜', '1', '量子资源')),
    ];
    final kept = fxPruneJarLines(groups);
    expect(kept.length, 1);
    expect(kept.first.displayName.contains('暴风资源'), isTrue);
  });

  test('CMS 的 bilibili 网页地址不算死线（服务端能解析）', () {
    expect(
      isDeadAddress('https://www.bilibili.com/bangumi/play/ep7303508'),
      isFalse,
    );
  });

  test('真直链不算死线', () {
    expect(isDeadAddress('https://cdn.example.com/a/index.m3u8'), isFalse);
    expect(isDeadAddress('https://xfyvideo.online/m.php?data=x&xfy.m3u8'),
        isFalse);
  });

  test('默认子线路优先挑咕噜4K', () {
    final lines = <LineInfo>[
      _line('咕噜·咕噜4K', fxJarLineId('咕噜', '1', '咕噜4K')),
      _line('咕噜·暴风资源', fxJarLineId('咕噜', '1', '暴风资源')),
      _line('咕噜·玫瑰4K', fxJarLineId('咕噜', '1', '玫瑰4K')),
    ];
    final pick = fxJarDefaultLine(lines);
    expect(pick, isNotNull);
    expect(pick!.displayName.contains('咕噜4K'), isTrue);
  });

  test('没有首选时退回原顺序第一条', () {
    final lines = <LineInfo>[
      _line('咕噜·甲', fxJarLineId('咕噜', '1', '甲')),
      _line('咕噜·乙', fxJarLineId('咕噜', '1', '乙')),
    ];
    expect(fxJarDefaultLine(lines)!.displayName.contains('甲'), isTrue);
  });
}

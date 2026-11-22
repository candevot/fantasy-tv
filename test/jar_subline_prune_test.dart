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
  test('平台网页地址按死线处理', () {
    expect(isDeadAddress('https://v.qq.com/x/cover/abc.html'), isTrue);
    expect(isDeadAddress('https://www.iqiyi.com/v_abc.html'), isTrue);
    expect(isDeadAddress('https://www.youku.com/v_show/id_X.html'), isTrue);
    expect(isDeadAddress('https://www.bilibili.com/bangumi/play/ep1'), isTrue);
  });

  test('真直链不算死线', () {
    expect(isDeadAddress('https://cdn.example.com/a/index.m3u8'), isFalse);
    expect(isDeadAddress('https://xfyvideo.online/m.php?data=x&xfy.m3u8'),
        isFalse);
  });

  test('默认子线路优先挑暴风资源', () {
    final lines = <LineInfo>[
      _line('咕噜·咕噜4K', fxJarLineId('咕噜', '1', '咕噜4K')),
      _line('咕噜·暴风资源', fxJarLineId('咕噜', '1', '暴风资源')),
      _line('咕噜·玫瑰4K', fxJarLineId('咕噜', '1', '玫瑰4K')),
    ];
    final pick = fxJarDefaultLine(lines);
    expect(pick, isNotNull);
    expect(pick!.displayName.contains('暴风资源'), isTrue);
  });

  test('没有首选时退回原顺序第一条', () {
    final lines = <LineInfo>[
      _line('咕噜·甲', fxJarLineId('咕噜', '1', '甲')),
      _line('咕噜·乙', fxJarLineId('咕噜', '1', '乙')),
    ];
    expect(fxJarDefaultLine(lines)!.displayName.contains('甲'), isTrue);
  });
}

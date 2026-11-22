// JAR_FIRST_WINDOW（2026-11-22）：jar 线路的起播无进展窗口必须比直链宽。
//
// 用户实测：咕噜首播「加载两下就 0 KB，手点刷新才播」。根因是首片落在 CDN
// 边缘为冷命中（回源 10~25 秒），8 秒窗口把它判死两次就停了；手点刷新时
// 前两次已经把边缘拉热。这里把口径钉死，防止以后又改回 8 秒。
import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/services/auto_resume.dart';
import 'package:fantasy_tv/services/playback_progress.dart';

void main() {
  test('jar 线路用 30 秒窗口，且与地址形态无关', () {
    expect(
      fxStartupNoProgressWindowFor(
        url: 'https://xfyvideo.online/m.php?data=abc',
        lineName: '咕噜',
        jarLine: true,
      ),
      const Duration(seconds: 30),
    );
    expect(
      fxStartupNoProgressWindowFor(jarLine: true),
      const Duration(seconds: 30),
    );
  });

  test('非 jar：令牌线路 20 秒、直链 8 秒（原口径不变）', () {
    expect(
      fxStartupNoProgressWindowFor(
        url: 'http://125.94.244.87/hxparse/xo?u=SH4K-abc',
        lineName: '幻想4K',
      ),
      fxTokenStartupNoProgressWindow,
    );
    expect(
      fxStartupNoProgressWindowFor(
        url: 'https://cdn.example.com/a/index.m3u8',
        lineName: '红牛',
      ),
      fxStartupNoProgressWindow,
    );
  });

  test('jar 窗口必须显著大于直链窗口', () {
    expect(
      fxJarStartupNoProgressWindow.inSeconds,
      greaterThan(fxStartupNoProgressWindow.inSeconds),
    );
  });
}

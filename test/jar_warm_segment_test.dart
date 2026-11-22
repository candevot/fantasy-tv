// JAR_WARM（2026-11-22）：jar 线路首片预热的地址解析单测。
//
// 背景：咕噜这类线路的 CDN 边缘冷命中要 10~25 秒、热命中 1.6 秒，起播前
// 用 Range 拉首片前 1MB 把边缘拉热。预热第一步是「从 m3u8 正文里取第一条
// 分片地址」，相对地址必须按清单地址补全，注释行 / 空行不能当成地址。
import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/services/play_path.dart';

void main() {
  test('取第一条分片：跳过注释与空行', () {
    const playlist = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXTINF:10.0,
seg-1.ts
#EXTINF:10.0,
seg-2.ts
''';
    expect(
      fxFirstSegmentOf(playlist, 'https://cdn.example.com/x/index.m3u8'),
      'https://cdn.example.com/x/seg-1.ts',
    );
  });

  test('相对地址带 ../ 也能补全', () {
    const playlist = '''
#EXTM3U
#EXTINF:4.0,
../ts/a.ts
''';
    expect(
      fxFirstSegmentOf(playlist, 'https://cdn.example.com/x/y/index.m3u8'),
      'https://cdn.example.com/x/ts/a.ts',
    );
  });

  test('绝对地址原样返回', () {
    const playlist = '#EXTM3U\n#EXTINF:4.0,\nhttps://v.example.com/a.ts?t=1\n';
    expect(
      fxFirstSegmentOf(playlist, 'https://cdn.example.com/index.m3u8'),
      'https://v.example.com/a.ts?t=1',
    );
  });

  test('没有分片（空正文 / 只有标签）返回空串', () {
    expect(fxFirstSegmentOf('', 'https://cdn.example.com/i.m3u8'), '');
    expect(
      fxFirstSegmentOf('#EXTM3U\n#EXT-X-ENDLIST\n', 'https://cdn.example.com/i.m3u8'),
      '',
    );
  });
}

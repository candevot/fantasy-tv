// JAR_HEADER_JSON（2026-11-22）：咕噜的 playerContent.header 是字符串化 JSON。
//
// 实测原始返回：
//   {"parse":0,"url":"https://xfyvideo.online/m.php?data=…&xfy.m3u8",
//    "header":"{\"User-Agent\":\"Dalvik/2.1.0 (Linux; U; Android 11; Pixel 4)\"}"}
// 老代码只认 Map，字符串直接丢 → 我们拿默认 UA 去请求，和壳（FongMi 会把这段
// 解析出来照发）不是一个身份。这条测试把这个差异钉死。
import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/services/jar_spider.dart';

void main() {
  test('header 是字符串化 JSON 时要解析出 UA', () {
    final info = JarSpider.playOf(<String, dynamic>{
      'parse': 0,
      'url': 'https://xfyvideo.online/m.php?data=abc&xfy.m3u8',
      'header':
          '{"User-Agent":"Dalvik/2.1.0 (Linux; U; Android 11; Pixel 4)"}',
    });
    expect(info.headers['User-Agent'],
        'Dalvik/2.1.0 (Linux; U; Android 11; Pixel 4)');
    expect(info.type, 'hls');
  });

  test('header 是对象时照旧生效', () {
    final info = JarSpider.playOf(<String, dynamic>{
      'parse': 0,
      'url': 'https://cdn.example.com/a/index.m3u8',
      'header': <String, dynamic>{'User-Agent': 'UA-OBJ', 'Referer': 'https://a/'},
    });
    expect(info.headers['User-Agent'], 'UA-OBJ');
    expect(info.headers['Referer'], 'https://a/');
  });

  test('没有 header 时补默认 UA（不能缺）', () {
    final info = JarSpider.playOf(<String, dynamic>{
      'parse': 0,
      'url': 'https://cdn.example.com/a/index.m3u8',
    });
    expect(info.headers.containsKey('User-Agent'), isTrue);
  });

  test('header 是坏 JSON 不至于抛异常', () {
    final info = JarSpider.playOf(<String, dynamic>{
      'parse': 0,
      'url': 'https://cdn.example.com/a/index.m3u8',
      'header': '{not json',
    });
    expect(info.headers.containsKey('User-Agent'), isTrue);
  });
}

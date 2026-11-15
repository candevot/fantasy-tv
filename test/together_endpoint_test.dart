// 一起看（/ws/together）地址推导回归。
//
// 用户实测的两个坑：
//   1. 旧服务器 47.96.0.112 已下线，老版本 prefs 里存过它 → 一直连不上；
//   2. `replaceFirst('http','ws')` 拼出来的地址在带尾斜杠 / https 时会错位，
//      表现就是「一直正在重连」。
import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/api.dart';

void main() {
  group('Api.wsFromBase', () {
    test('默认服务器 → 8787 的 /ws/together', () {
      expect(
        Api.wsFromBase('http://125.94.244.87:8787/api'),
        'ws://125.94.244.87:8787/ws/together',
      );
    });

    test('尾斜杠不会拼出双斜杠', () {
      expect(
        Api.wsFromBase('http://125.94.244.87:8787/api/'),
        'ws://125.94.244.87:8787/ws/together',
      );
    });

    test('https → wss，保留端口', () {
      expect(
        Api.wsFromBase('https://api.example.com:9443/api'),
        'wss://api.example.com:9443/ws/together',
      );
    });

    test('没有 /api 后缀也能推导', () {
      expect(
        Api.wsFromBase('http://example.com:8787'),
        'ws://example.com:8787/ws/together',
      );
    });

    test('空串回落默认服务器', () {
      expect(Api.wsFromBase(''), 'ws://125.94.244.87:8787/ws/together');
    });
  });

  test('候选地址里不再有已下线的 47.96.0.112', () {
    for (final item in Api.candidates) {
      expect(item.contains('47.96.0.112'), isFalse);
      expect(item.contains('/api'), isTrue);
    }
    expect(Api.candidates.first, contains('125.94.244.87:8787'));
  });

  test('当前 base 与 wsBase 指向同一台服务器', () {
    expect(Api.wsBase, Api.wsFromBase(Api.base));
    expect(Api.wsBase.endsWith('/ws/together'), isTrue);
    expect(Api.wsBase.startsWith('ws://'), isTrue);
  });
}

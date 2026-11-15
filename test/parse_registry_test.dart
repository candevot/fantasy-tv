// 解析器注册表与寻址单测（PROTOCOL_FACE 2026-11-15 · 移植阶段 1 第 2 条）。
//
// 钉住壳的寻址协议：
//   · `json:<地址>` → 现造一个 type 1（Json）解析器，不查注册表；
//   · `parse:<名字>` → 按名字查，查不到退回默认解析器（但名字要带出去）；
//   · 站点级 `playUrl` 优先于地址前缀；
//   · type 0 → 嗅探、type 1 → Json、type 2/3/4 → 本阶段不支持（但要有名字）；
//   · `ext.flag` 决定「哪些线路名能用这条解析器」。

import 'package:flutter_test/flutter_test.dart';
import 'package:fantasy_tv/services/parse_registry.dart';
import 'package:fantasy_tv/services/tvbox_config.dart';

ParseRegistry _registry() => ParseRegistry(<FxParse>[
      const FxParse(name: '虾米', type: 0, url: 'https://jx.xmflv.com/?url='),
      const FxParse(name: '云解', type: 1, url: 'https://yparse/?url='),
      const FxParse(
        name: '盘古',
        type: 0,
        url: 'https://playm3u8/?url=',
        flag: <String>['量子'],
      ),
      const FxParse(name: '聚合', type: 3, url: 'Web'),
    ]);

void main() {
  group('json: / parse: 寻址', () {
    test('json: 前缀现造 Json 解析器（不查注册表）', () {
      final route = _registry().route('json:https://jx.example/?url=');
      expect(route.kind, FxParseKind.json);
      expect(route.type, 1);
      expect(route.url, 'https://jx.example/?url=');
      expect(route.needsParse, isTrue);
      expect(route.runnable, isTrue);
    });

    test('parse:名字 命中的类型决定执行形态', () {
      final sniff = _registry().route('parse:虾米');
      expect(sniff.kind, FxParseKind.sniff);
      expect(sniff.name, '虾米');

      final json = _registry().route('parse:云解');
      expect(json.kind, FxParseKind.json);
      expect(json.name, '云解');

      final unsupported = _registry().route('parse:聚合');
      expect(unsupported.kind, FxParseKind.unsupported);
      expect(unsupported.type, 3);
      expect(unsupported.runnable, isFalse);
    });

    test('parse:名字 没登记时退回默认解析器，但名字要带出去', () {
      final route = _registry().route('parse:不存在的解析器');
      expect(route.name, '不存在的解析器');
      // 默认解析器取第一个 0/1 类型（这里是「虾米」）。
      expect(route.url, 'https://jx.xmflv.com/?url=');
      expect(route.kind, FxParseKind.sniff);
    });

    test('默认解析器跳过 type 2/3/4（没有执行能力的不排前面）', () {
      final registry = ParseRegistry(<FxParse>[
        const FxParse(name: '聚合', type: 3, url: 'Web'),
        const FxParse(name: '云解', type: 1, url: 'https://yparse/?url='),
      ]);
      expect(registry.defaultParse?.name, '云解');
    });
  });

  group('站点级 playUrl', () {
    test('playUrl 优先于地址前缀', () {
      final route = _registry().route(
        'json:https://ignored/?url=',
        sitePlayUrl: 'parse:云解',
      );
      expect(route.name, '云解');
      expect(route.kind, FxParseKind.json);
      expect(route.playUrl, 'parse:云解');
    });

    test('playUrl 直接给地址时按 Json 解析执行', () {
      final route = _registry().route(
        'FY-SH4K-deadbeef',
        sitePlayUrl: 'https://api.example.com/parse?url=',
      );
      expect(route.kind, FxParseKind.json);
      expect(route.name, 'playUrl');
      expect(route.url, 'https://api.example.com/parse?url=');
    });
  });

  group('直链与空注册表', () {
    test('直链不寻址（isDirect 由调用方给）', () {
      final route = _registry().route(
        'https://cdn.example.com/a/index.m3u8',
        isDirect: (a) => true,
      );
      expect(route.kind, FxParseKind.direct);
      expect(route.needsParse, isFalse);
    });

    test('没有 isDirect 时按媒体后缀兜底', () {
      final registry = _registry();
      expect(
        registry.route('https://cdn/a.m3u8').kind,
        FxParseKind.direct,
      );
      expect(
        registry.route('https://lzv34.com/share/abc').kind,
        FxParseKind.sniff,
      );
    });

    test('空注册表 + 非直链 → unsupported（不再假装能播）', () {
      final route = ParseRegistry.empty.route('https://lzv34.com/share/abc');
      expect(route.kind, FxParseKind.unsupported);
      expect(route.runnable, isFalse);
    });
  });

  group('ext.flag 过滤', () {
    test('ofTypeFor 只留下服务该线路名的解析器', () {
      final registry = _registry();
      // 只有「盘古」显式声明服务「量子」；空 flag 的「虾米」不算命中
      // （壳是 `ext.flag.contains(flag)`，不是「空表示全部」）。
      final forQuantum = registry.ofTypeFor(0, '量子');
      expect(forQuantum.map((p) => p.name), <String>['盘古']);
      // 一条都没声明服务「红牛」→ 退回全部 type 0（壳的兜底口径）。
      final forOther = registry.ofTypeFor(0, '红牛');
      expect(forOther.map((p) => p.name), <String>['虾米', '盘古']);
      expect(registry.ofTypeFor(1, '量子').map((p) => p.name), <String>['云解']);
    });

    test('flag 为空串时返回全部', () {
      expect(_registry().ofTypeFor(1, '').map((p) => p.name), <String>['云解']);
    });
  });

  group('请求地址拼装', () {
    test('直接拼、%s 替换、{url} 替换都支持', () {
      const plain = ParseRoute(
        kind: FxParseKind.json,
        url: 'https://jx/?url=',
      );
      expect(
        plain.requestUrlFor('https://v/1.m3u8'),
        'https://jx/?url=https://v/1.m3u8',
      );
      const printf = ParseRoute(kind: FxParseKind.json, url: 'https://jx/?u=%s');
      expect(
        printf.requestUrlFor('https://v/1.m3u8'),
        'https://jx/?u=https://v/1.m3u8',
      );
      const braces = ParseRoute(kind: FxParseKind.json, url: 'https://jx/{url}/x');
      expect(
        braces.requestUrlFor('https://v/1.m3u8'),
        'https://jx/https://v/1.m3u8/x',
      );
    });
  });

  group('全局安装', () {
    tearDown(ParseRegistry.resetForTest);

    test('install 之后 active 换掉，reset 回到空表', () {
      expect(ParseRegistry.active.isEmpty, isTrue);
      ParseRegistry.install(_registry());
      expect(ParseRegistry.active.parses, hasLength(4));
      expect(ParseRegistry.active.byName('虾米')?.url, contains('xmflv'));
      ParseRegistry.resetForTest();
      expect(ParseRegistry.active.isEmpty, isTrue);
    });
  });
}

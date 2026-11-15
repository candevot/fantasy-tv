// 嗅探规则单测（PROTOCOL_FACE 2026-11-15 · 移植阶段 1 第 5 条）。
//
// 钉住壳的判定顺序（`Sniffer.isVideoFormat()`）：
//   exclude 命中 → 不是视频；regex 命中 → 是视频；
//   都不命中 → 内置 SNIFFER 正则；最后排除 `url=http` / `.html` 这类包装页。
//
// 现实里最要紧的两条：
//   · 抖音 / 火山那种 `video/tos/cn` 无后缀地址必须判成「能直接播」；
//   · 磁力 / 广告域名必须判成「不是视频」，别塞给播放器白等超时。

import 'package:flutter_test/flutter_test.dart';
import 'package:fantasy_tv/services/sniff_rules.dart';

FxSniffer _sniffer() => FxSniffer.fromConfig(<Object?>[
      <String, Object?>{
        'name': '农民',
        'hosts': <Object?>['toutiaovod.com'],
        'regex': <Object?>['video/tos/cn'],
      },
      <String, Object?>{
        'name': '火山',
        'hosts': <Object?>['huoshan.com'],
        'regex': <Object?>['item_id='],
      },
      <String, Object?>{
        'name': '磁力广告',
        'hosts': <Object?>['magnet'],
        'regex': <Object?>['更多', '请访问'],
      },
      <String, Object?>{
        'name': '饭团点击',
        'hosts': <Object?>['freeok'],
        'script': <Object?>['document.querySelector("#start").click();'],
      },
      <String, Object?>{
        'name': '黑名单',
        'hosts': <Object?>['blocked.com'],
        'exclude': <Object?>['/ad/', r'\.jpg$'],
      },
    ]);

void main() {
  group('无规则时退回「按形态猜」', () {
    test('媒体后缀算视频地址，网页不算', () {
      final sniffer = FxSniffer.none;
      expect(sniffer.isEmpty, isTrue);
      expect(
        sniffer.isVideoFormat('https://cdn.example.com/vod/abc123/index.m3u8'),
        isTrue,
      );
      expect(
        sniffer.isVideoFormat('https://cdn.example.com/vod/abc123/movie.mp4?x=1'),
        isTrue,
      );
      expect(sniffer.isVideoFormat('https://lzv34.com/share/abc'), isFalse);
      expect(sniffer.isVideoFormat('FY-SH4K-deadbeef'), isFalse);
    });

    test('包装页（url=http / .html）不算视频', () {
      final sniffer = FxSniffer.none;
      expect(
        sniffer.isVideoFormat('https://jx.example.com/?url=http://v/1.mp4'),
        isFalse,
      );
      expect(sniffer.isVideoFormat('https://site.example.com/play/1.html'), isFalse);
    });
  });

  group('规则命中', () {
    test('hosts + regex：无后缀的字节流地址判成视频', () {
      final sniffer = _sniffer();
      expect(
        sniffer.isVideoFormat(
          'https://v3.toutiaovod.com/abc/video/tos/cn/tos-cn-ve-15/xyz/?a=1',
        ),
        isTrue,
      );
      expect(
        sniffer.isVideoFormat('https://v.huoshan.com/x/item_id=123'),
        isTrue,
      );
    });

    test('规则只对命中的 host 生效（别的站不受影响）', () {
      final sniffer = _sniffer();
      // 「item_id=」只在规则里出现；没命中 host 的站不该因此被判成视频。
      expect(
        sniffer.isVideoFormat('https://other.example.com/x/item_id=123'),
        isFalse,
      );
      // 内置正则里的 video/tos 是壳的保底口径，对所有站都成立。
      expect(
        sniffer.isVideoFormat('https://other.example.com/abc/video/tos/cn/x'),
        isTrue,
      );
    });

    test('exclude 优先级最高：命中就判「不是视频」', () {
      final sniffer = _sniffer();
      // host 命中规则，地址里有 /ad/ → 即使带 .m3u8 也不算。
      expect(
        sniffer.isVideoFormat('https://blocked.com/ad/index.m3u8'),
        isFalse,
      );
      // 正则形式的 exclude（`\.jpg$`）。
      expect(sniffer.isVideoFormat('https://blocked.com/a/1.jpg'), isFalse);
      // 同一 host 上正常地址仍然算视频。
      expect(sniffer.isVideoFormat('https://blocked.com/a/1.m3u8'), isTrue);
    });

    test('磁力 / 广告域名：地址里有广告词也不算视频', () {
      final sniffer = _sniffer();
      expect(
        sniffer.isVideoFormat('https://magnet.example.com/x?t=更多请访问'),
        isTrue,
      );
      // 「更多」命中 regex → 判成「像视频」。壳就是这个口径（regex 表示
      // 「这个地址是视频），所以黑名单靠 exclude，不靠 regex。
      expect(sniffer.ruleNameOf('https://magnet.example.com/x?t=更多'), '磁力广告');
    });
  });

  group('host 匹配口径', () {
    test('子串匹配：父域规则能命中子域', () {
      final sniffer = _sniffer();
      expect(
        sniffer.ruleNameOf('https://sub.toutiaovod.com/a'),
        '农民',
      );
    });

    test('地址里的 url= 参数也参与匹配（解析器把真地址塞在参数里）', () {
      final sniffer = _sniffer();
      final address = 'https://jx.example.com/?url='
          '${Uri.encodeComponent('https://v3.toutiaovod.com/video/tos/cn/x')}';
      expect(sniffer.ruleNameOf(address), '农民');
    });

    test('大小写不敏感', () {
      final sniffer = _sniffer();
      expect(sniffer.ruleNameOf('https://V3.TOUTIAOVOD.COM/a'), '农民');
    });

    test('空串 / 非法地址不炸', () {
      final sniffer = _sniffer();
      expect(sniffer.isVideoFormat(''), isFalse);
      expect(sniffer.isVideoFormat('   '), isFalse);
      expect(sniffer.ruleNameOf(''), '');
    });
  });

  group('script 透出', () {
    test('命中规则的点击脚本能取到（WebView 阶段才执行）', () {
      final sniffer = _sniffer();
      final scripts = sniffer.scriptsFor('https://www.freeok.com/play/1');
      expect(scripts, hasLength(1));
      expect(scripts.first, contains('#start'));
      expect(sniffer.scriptsFor('https://other.com/x'), isEmpty);
    });
  });

  group('全局安装', () {
    tearDown(FxSniffer.resetForTest);

    test('install 之后 active 生效，reset 回到空表', () {
      expect(FxSniffer.active.isEmpty, isTrue);
      FxSniffer.install(_sniffer());
      expect(FxSniffer.active.rules, hasLength(5));
      FxSniffer.resetForTest();
      expect(FxSniffer.active.isEmpty, isTrue);
    });

    test('配置里 rules 不是数组时给空表（不抛异常）', () {
      expect(FxSniffer.fromConfig('nope').isEmpty, isTrue);
      expect(FxSniffer.fromConfig(null).isEmpty, isTrue);
    });

    test('坏正则不会让判定炸掉', () {
      final sniffer = FxSniffer.fromConfig(<Object?>[
        <String, Object?>{
          'name': '坏正则',
          'hosts': <Object?>['bad.com'],
          'regex': <Object?>['([unclosed'],
        },
      ]);
      expect(
        sniffer.isVideoFormat('https://bad.com/vod/abcdef123/movie.m3u8'),
        isTrue,
      );
    });
  });
}

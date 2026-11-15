import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/services/iq_codec_gate.dart';
import 'package:fantasy_tv/services/iqiyi_codec.dart';

/// IQ_CODEC（2026-11-15）：爱奇艺线路「按设备硬解能力选编码」的回归。
///
/// 服务端实测：
/// ```
/// /hxparse/play/iqiyi/1/index.m3u8?title=济公传&year=2016&ep=1         → AVC   896x504
/// /hxparse/play/iqiyi/1/index.m3u8?title=济公传&year=2016&ep=1&hevc=1  → HEVC 1920x1080
/// ```
/// 这条逻辑一旦写错，用户看到的不是报错，而是「画质莫名其妙变糊」——
/// 所以每个分支都在这里钉死：只有爱奇艺地址被改写、`?` / `&` 不拼错、
/// `hevc` 只留一个、HEVC 失败后一定有一条 AVC 候选跟在后面。
void main() {
  const iqUrl =
      'http://125.94.244.87/hxparse/play/iqiyi/1/index.m3u8?title=济公传&year=2016&ep=1';
  const iqNoQuery = 'http://125.94.244.87/hxparse/play/iqiyi/3/index.m3u8';
  const redbull = 'https://hn.bfvvs.com/play/abc123/index.m3u8';

  group('isIqiyiPlayUrl：只有成品码流才允许动', () {
    test('带查询串的爱奇艺播放地址', () {
      expect(isIqiyiPlayUrl(iqUrl), isTrue);
    });

    test('没有查询串的爱奇艺播放地址', () {
      expect(isIqiyiPlayUrl(iqNoQuery), isTrue);
    });

    test('https + 别的域名也认（路由不变，只换 host）', () {
      expect(
        isIqiyiPlayUrl('https://a.example.com/hxparse/play/iqiyi/12/index.m3u8'),
        isTrue,
      );
    });

    test('解析入口 /hxparse/parse/iqiyi 不是成品码流，不能加参数', () {
      expect(
        isIqiyiPlayUrl(
          'http://h/hxparse/parse/iqiyi?title=济公传&year=2016&ep=1',
        ),
        isFalse,
      );
    });

    test('其它线路（红牛 / 量子 / 4K 令牌）一律不认', () {
      expect(isIqiyiPlayUrl(redbull), isFalse);
      expect(isIqiyiPlayUrl('https://lzv34.com/share/abcd'), isFalse);
      expect(isIqiyiPlayUrl('FY-SH4K-abcdef'), isFalse);
      expect(isIqiyiPlayUrl(''), isFalse);
    });
  });

  group('withHevc：拼参数不能拼坏', () {
    test('已有查询串用 &', () {
      final out = withHevc(iqUrl, hevc: true);
      expect(out, '$iqUrl&hevc=1');
      expect(out.contains('?title='), isTrue);
      expect(out.contains('&&'), isFalse);
    });

    test('没有查询串才用 ?', () {
      expect(
        withHevc(iqNoQuery, hevc: true),
        '$iqNoQuery?hevc=1',
      );
    });

    test('重复调用不叠加', () {
      final once = withHevc(iqUrl, hevc: true);
      expect(withHevc(once, hevc: true), once);
    });

    test('原来的 hevc=0 先删再追加，绝不出现两个 hevc', () {
      final out = withHevc(
        'http://h/hxparse/play/iqiyi/2/index.m3u8?ep=2&hevc=0&year=0',
        hevc: true,
      );
      expect(out, 'http://h/hxparse/play/iqiyi/2/index.m3u8?ep=2&year=0&hevc=1');
      expect('hevc='.allMatches(out).length, 1);
    });

    test('hevc: false 是「去参数」，拿回服务端默认的 896x504 码流', () {
      final withFlag = withHevc(iqUrl, hevc: true);
      final back = withHevc(withFlag, hevc: false);
      expect(back, iqUrl);
      expect(back.contains('hevc'), isFalse);
    });

    test('别的线路一个字节都不动', () {
      expect(withHevc(redbull, hevc: true), redbull);
      expect(withHevc(redbull, hevc: false), redbull);
    });

    test('片段标记保持在最后', () {
      expect(
        withHevc('http://h/hxparse/play/iqiyi/1/index.m3u8?ep=1#t=3',
            hevc: true),
        'http://h/hxparse/play/iqiyi/1/index.m3u8?ep=1&hevc=1#t=3',
      );
    });
  });

  group('hevcOf / iqRequestedCodec / avcVariant', () {
    test('没有 hevc 参数 = 服务端默认 AVC', () {
      expect(hevcOf(iqUrl), 'avc');
    });

    test('hevc=1 是 HEVC，hevc=0 是 AVC', () {
      expect(hevcOf('$iqUrl&hevc=1'), 'hevc');
      expect(hevcOf('$iqUrl&hevc=0'), 'avc');
    });

    test('非爱奇艺线路不参与编码判断', () {
      expect(iqRequestedCodec(redbull), '');
      expect(iqRequestedCodec('$iqUrl&hevc=1'), 'hevc');
    });

    test('avcVariant：有 hevc 才有降级地址，没有就是 null', () {
      expect(avcVariant('$iqUrl&hevc=1'), iqUrl);
      expect(avcVariant(iqUrl), isNull);
      expect(avcVariant(redbull), isNull);
    });
  });

  group('planTargets：候选序列', () {
    test('支持 HEVC：先 hevc=1，紧跟一条降级 AVC', () {
      final plan = planTargets(<String>[iqUrl], hevc: true);
      expect(plan.length, 2);
      expect(plan[0].url, '$iqUrl&hevc=1');
      expect(plan[0].hevc, isTrue);
      expect(plan[0].degradeFromHevc, isFalse);
      expect(plan[1].url, iqUrl);
      expect(plan[1].hevc, isFalse);
      expect(plan[1].degradeFromHevc, isTrue);
    });

    test('不支持 HEVC：只试原地址（服务端默认 896x504）', () {
      final plan = planTargets(<String>[iqUrl], hevc: false);
      expect(plan.length, 1);
      expect(plan[0].url, iqUrl);
      expect(plan[0].hevc, isFalse);
      expect(plan[0].degradeFromHevc, isFalse);
    });

    test('其它线路不受影响：一条不多一条不少', () {
      final plan = planTargets(<String>[redbull], hevc: true);
      expect(plan.length, 1);
      expect(plan[0].url, redbull);
    });

    test('多候选保持原顺序，空地址被丢掉', () {
      final plan = planTargets(<String>['', redbull, iqUrl], hevc: true);
      expect(plan.map((t) => t.url).toList(), <String>[
        redbull,
        '$iqUrl&hevc=1',
        iqUrl,
      ]);
    });

    test('重复地址不会重复尝试', () {
      final plan = planTargets(<String>[iqUrl, iqUrl], hevc: true);
      expect(plan.length, 2);
    });

    test('已经带 hevc=1 的地址不会再叠一条', () {
      final plan = planTargets(<String>['$iqUrl&hevc=1'], hevc: true);
      expect(plan.map((t) => t.url).toList(), <String>['$iqUrl&hevc=1', iqUrl]);
      expect(plan[1].degradeFromHevc, isTrue);
    });

    test('降级日志格式固定（排查时 grep 这一行）', () {
      expect(
        iqDegradeLog(iqUrl),
        'iqiyi downgrade hevc->avc url=$iqUrl',
      );
    });
  });

  group('IqCodecGate：能力 → 地址', () {
    setUp(IqCodecGate.debugReset);
    tearDown(IqCodecGate.debugReset);

    test('能硬解时改写地址，不能时保持原样', () {
      IqCodecGate.debugSetHevcSupported(true);
      expect(IqCodecGate.adapt(iqUrl), '$iqUrl&hevc=1');
      expect(IqCodecGate.hevcSupported, isTrue);

      IqCodecGate.debugSetHevcSupported(false);
      expect(IqCodecGate.adapt(iqUrl), iqUrl);
      expect(IqCodecGate.hevcSupported, isFalse);
    });

    test('plan 带上设备能力（不支持时不给 HEVC 候选）', () {
      IqCodecGate.debugSetHevcSupported(false);
      final plan = IqCodecGate.plan(<String>[iqUrl]);
      expect(plan.every((t) => !t.hevc), isTrue);

      IqCodecGate.debugSetHevcSupported(true);
      final plan2 = IqCodecGate.plan(<String>[iqUrl]);
      expect(plan2.first.hevc, isTrue);
      expect(plan2.last.degradeFromHevc, isTrue);
    });
  });

  group('编码文案', () {
    test('codecLabelOf 认得出 HEVC / H.264 / AV1', () {
      expect(codecLabelOf('video/hevc'), 'HEVC');
      expect(codecLabelOf('hevc'), 'HEVC');
      expect(codecLabelOf('H265'), 'HEVC');
      expect(codecLabelOf('video/avc'), 'H.264');
      expect(codecLabelOf('av01.0.08M'), 'AV1');
      expect(codecLabelOf(''), '');
      expect(codecLabelOf('mpeg4'), '');
    });

    test('内核实测优先，其次响应头，最后才是请求参数', () {
      expect(
        iqCodecText(
          mime: 'hevc',
          headerCodec: 'avc',
          requested: 'hevc',
          width: 1920,
          height: 1080,
        ),
        'HEVC 1920x1080',
      );
      expect(
        iqCodecText(
          headerCodec: 'avc',
          headerQuality: '896x504',
          requested: 'hevc',
        ),
        'H.264 896x504',
      );
      expect(iqCodecText(requested: 'hevc'), 'HEVC');
      expect(iqCodecText(), '--');
    });

    test('分辨率优先用实测宽高', () {
      expect(
        iqCodecText(mime: 'avc', headerQuality: '1920x1080', width: 896, height: 504),
        'H.264 896x504',
      );
    });

    test('通知条：正常 / 降级两种说法', () {
      expect(
        IqCodecGate.notice(
          degraded: false,
          mime: 'hevc',
          width: 1920,
          height: 1080,
        ),
        '爱奇艺：HEVC 1920x1080',
      );
      expect(
        IqCodecGate.notice(
          degraded: true,
          mime: 'avc',
          width: 896,
          height: 504,
        ),
        '爱奇艺：HEVC 不可用，已降级 H.264 896x504',
      );
    });
  });
}

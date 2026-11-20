import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/api.dart';
import 'package:fantasy_tv/services/jar_log.dart';
import 'package:fantasy_tv/models.dart';
import 'package:fantasy_tv/services/jar_spider.dart';
import 'package:fantasy_tv/services/search_relevance.dart';

/// JAR_SEARCH_FALLBACK（2026-11-15）回归。
///
/// 现场症状演变：
///   1. `quick=true`（写死）→ 搜「济公传」出「背着善宰跑」这类首页热门；
///   2. 改成 `quick=false` + 相关性闸门 → **肥猫源一条都没有了**；
///   3. 用户实测「只出 1 条，还点不开」。
///
/// 反编译线上 `spider.jar`（md5 cbe016eb…）核对：**几乎没有一个源读 quick**
/// （`Gulu` / `SaoHuo` / `Jpys` / `Gz360` / `AppGet` / `AppQi` / `AppRJ` /
/// `AppYQK` / `YGP` 的 `searchContent(str, z)` 里都没有对 `z` 的分支），
/// 所以押一种模式必然踩坑。这里把「两种都试、谁先有结果用谁」钉住。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];
  final logs = <String>[];

  DebugPrintCallback originalDebugPrint = debugPrint;

  /// 一段返回给 Dart 的 jar 响应（原生回的是 JSON 字符串）。
  String listBody(List<String> titles) => jsonEncode(<String, Object?>{
        'list': <Map<String, Object?>>[
          for (var i = 0; i < titles.length; i++)
            <String, Object?>{
              'vod_id': '${1000 + i}',
              'vod_name': titles[i],
              'vod_pic': 'https://img/$i.jpg',
              'vod_year': '2016',
            },
        ],
      });

  setUp(() {
    calls.clear();
    logs.clear();
    JarSpider.debugForceSupported = true;
    originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };
  });

  tearDown(() {
    debugPrint = originalDebugPrint;
    JarSpider.debugForceSupported = false;
    TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(JarSpider.channel, null);
  });

  /// 按 `quick` 给不同响应：`byMode` 里没定义的 quick 一律回空列表。
  void mockJar({
    List<String> Function()? quickFalse,
    List<String> Function()? quickTrue,
    String? quickFalseError,
    String? quickTrueError,
  }) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(JarSpider.channel, (call) async {
      calls.add(call);
      expect(call.method, 'search');
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final quick = args['quick'] == true;
      if (quick) {
        if (quickTrueError != null) throw PlatformException(code: 'spider', message: quickTrueError);
        return listBody(quickTrue?.call() ?? const <String>[]);
      }
      if (quickFalseError != null) throw PlatformException(code: 'spider', message: quickFalseError);
      return listBody(quickFalse?.call() ?? const <String>[]);
    });
  }

  group('quick 两种都试', () {
    test('quick=false 有结果：只用一次，不回退', () async {
      mockJar(quickFalse: () => <String>['济公传', '新济公传']);
      final report = await JarSpider.searchWithFallback(
        api: 'csp_Gulu',
        ext: '',
        key: '济公传',
        label: '咕噜',
      );
      expect(report.cards.map((c) => c.title), <String>['济公传', '新济公传']);
      expect(report.attempts.length, 1);
      expect(report.attempts.single.quick, isFalse);
      expect(report.usedFallback, isFalse);
      expect(calls.length, 1);
      // 日志格式：`[JarSearch] source=咕噜 key=济公传 quick=false → 2 条 耗时 …ms`
      expect(
        logs.any((l) =>
            l.contains('[JarSearch]') &&
            l.contains('source=咕噜') &&
            l.contains('key=济公传') &&
            l.contains('quick=false') &&
            l.contains('→ 2 条')),
        isTrue,
        reason: '日志必须能看清链路：$logs',
      );
    });

    test('quick=false 回空 → 回退 quick=true 拿到结果', () async {
      mockJar(quickTrue: () => <String>['济公传']);
      final report = await JarSpider.searchWithFallback(
        api: 'csp_Jpys',
        ext: '',
        key: '济公传',
        label: '金牌',
      );
      expect(report.cards.length, 1);
      expect(report.cards.single.title, '济公传');
      expect(report.attempts.length, 2);
      expect(report.attempts.first.count, 0);
      expect(report.attempts.last.quick, isTrue);
      expect(report.usedFallback, isTrue);
      expect(logs.any((l) => l.contains('quick=false → 0 条 (empty)')), isTrue);
      expect(logs.any((l) => l.contains('quick=true → 1 条')), isTrue);
    });

    test('quick=false 抛异常 → 也回退 quick=true', () async {
      mockJar(
        quickFalseError: 'searchContent 超时（12 秒）',
        quickTrue: () => <String>['济公传'],
      );
      final report = await JarSpider.searchWithFallback(
        api: 'csp_SaoHuo',
        ext: '',
        key: '济公传',
      );
      expect(report.cards.length, 1);
      expect(report.attempts.first.error, contains('超时'));
      expect(report.usedFallback, isTrue);
      expect(logs.any((l) => l.contains('出错')), isTrue);
    });

    test('两种都空：不回退无限次，结果为空且带空日志', () async {
      mockJar();
      final report = await JarSpider.searchWithFallback(
        api: 'csp_Gulu',
        ext: '',
        key: '济公传',
        label: '咕噜',
      );
      expect(report.cards, isEmpty);
      expect(report.attempts.length, 2);
      expect(report.allFailed, isFalse);
      expect(report.allTimedOut, isFalse);
      expect(calls.length, 2, reason: '最多两种模式各一次，不许循环重试');
      expect(logs.last, contains('两种模式都没结果'));
    });

    test('两种都报错：allFailed 为真（页面显示「出错」而不是「空」）', () async {
      mockJar(
        quickFalseError: 'jar 里没有这个类：csp_AppDrama2',
        quickTrueError: 'jar 里没有这个类：csp_AppDrama2',
      );
      final report = await JarSpider.searchWithFallback(
        api: 'csp_AppDrama2',
        ext: '',
        key: '济公传',
      );
      expect(report.cards, isEmpty);
      expect(report.allFailed, isTrue);
      expect(report.note, contains('没有这个类'));
    });
  });

  group('超时 / 日志', () {
    test('超时被记成「超时」而不是「空」，且不阻塞第二次尝试', () async {
      var first = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(JarSpider.channel, (call) async {
        calls.add(call);
        final args = Map<String, dynamic>.from(call.arguments as Map);
        if (args['quick'] != true && first) {
          first = false;
          // 模拟通道超时（比这次尝试的预算长，Dart 侧 timeout 先抛）。
          await Future<void>.delayed(const Duration(milliseconds: 1400));
        }
        return listBody(<String>['济公传']);
      });
      final report = await JarSpider.searchWithFallback(
        api: 'csp_Gulu',
        ext: '',
        key: '济公传',
        budget: const Duration(seconds: 1),
      );
      // 预算 1 秒只够一次尝试：第一次超时后剩余预算不足 300ms，第二次被跳过。
      expect(report.attempts, hasLength(1));
      expect(report.attempts.single.timedOut, isTrue);
      expect(report.cards, isEmpty);
      expect(
        logs.any((l) => l.contains('超时') || l.contains('预算已用完')),
        isTrue,
        reason: '超时必须单独记日志：$logs',
      );
    });

    test('fxJarClip 截断保留长度提示', () {
      final text = 'x' * 400;
      final clipped = fxJarClip(text);
      expect(clipped.length, lessThan(text.length));
      expect(clipped, contains('+80'));
    });
  });

  group('闸门（放宽但保留底线）', () {
    test('片名带后缀 / 同 IP 变体都算相关', () {
      // 直接走闸门：这些上一次会被判无关 → 整段消失。
      expect(_keep('济公传[电影解说]'), isTrue);
      expect(_keep('济公传(2016)'), isTrue);
      expect(_keep('新济公传'), isTrue);
      expect(_keep('活佛济公'), isTrue);
      expect(_keep('背着善宰跑'), isFalse);
    });
  });

  group('链路日志（对 5 个有代表性的源跑一遍）', () {
    test('搜「济公传」：日志把每个源的结局都写清楚', () async {
      // 每个源一套「真机上的典型行为」，用真实代码路径跑：
      //   · 咕噜：quick=false 就真搜到了 3 条；
      //   · 剧圈（Jpys）：quick=false 空、quick=true 才有 1 条；
      //   · 火火（SaoHuo）：两种都超时；
      //   · 干饭（AppDrama2）：jar 里没有这个类（部署的 spider.jar 缺类）；
      //   · 哔哩（Bili）：无视关键词回首页 —— 闸门必须把它丢掉。
      final behaviors = <String, Object? Function(bool quick)>{
        'csp_Gulu': (quick) => quick
            ? <String>[]
            : <String>['济公传', '新济公传', '济公传(2016)'],
        'csp_Jpys': (quick) => quick ? <String>['济公传[电影解说]'] : <String>[],
        'csp_SaoHuo': (quick) => null, // null = 超时
        'csp_AppDrama2': (quick) => 'jar 里没有这个类：csp_AppDrama2',
        'csp_Bili': (quick) => <String>['背着善宰跑', '与恶魔有约', '济公传'],
      };
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(JarSpider.channel, (call) async {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final api = '${args['api']}';
        final quick = args['quick'] == true;
        final behavior = behaviors[api]!(quick);
        if (behavior == null) {
          await Future<void>.delayed(const Duration(milliseconds: 1400));
          return listBody(<String>[]);
        }
        if (behavior is String) {
          throw PlatformException(code: 'spider', message: behavior);
        }
        return listBody(behavior as List<String>);
      });

      final sources = <String, String>{
        'csp_Gulu': '咕噜',
        'csp_Jpys': '金牌',
        'csp_SaoHuo': '火火',
        'csp_AppDrama2': '干饭',
        'csp_Bili': '哔哩合集',
      };
      for (final entry in sources.entries) {
        final report = await JarSpider.searchWithFallback(
          api: entry.key,
          ext: '',
          key: '济公传',
          label: entry.value,
          budget: const Duration(seconds: 1),
        );
        // 外部源都要过闸门，这里跟 cms_bridge.emit 用的是同一个函数。
        final gate = fxSearchGate(report.cards, '济公传');
        fxJarGateLog(entry.value, gate);
        // ignore: avoid_print
        print('  → ${entry.value}: 原 ${report.cards.length} 条 / 过闸门 '
            '${gate.kept.length} 条（丢 ${gate.dropped}）');
      }
      // ignore: avoid_print
      print('[JarSearch] 链路日志（真机 logcat 同款格式）：\n'
          '${logs.where((l) => l.startsWith('[JarSearch]')).join('\n')}');
      // 咕噜那 3 条必须活着出来（用户验收标准）。
      expect(logs.any((l) => l.contains('source=咕噜') && l.contains('→ 3 条')),
          isTrue);
      expect(logs.any((l) => l.contains('gate source=咕噜') && l.contains('kept=3')),
          isTrue);
      // 哔哩回首页：2 条无关被丢，1 条真「济公传」留下。
      expect(
        logs.any((l) => l.contains('gate source=哔哩合集') &&
            l.contains('dropped=2') &&
            l.contains('kept=1') &&
            l.contains('reason=unrelated')),
        isTrue,
      );
      // 缺类的源要能看出是「没有这个类」，不是「空」。
      expect(logs.any((l) => l.contains('没有这个类')), isTrue);
    });
  });

  group('详情 / 播放（「点进去加载不了」只能靠这两行日志定位）', () {
    // 每个用例用不同 vod_id：JarSpider 按 `api|ext|id` 缓存详情，
    // 同一个 id 第二次不会再问通道（缓存命中是功能，不是 bug）。
    String detailBody({String vodId = '418792', bool withLines = true}) =>
        jsonEncode(<String, Object?>{
          'list': <Map<String, Object?>>[
            <String, Object?>{
              'vod_id': vodId,
              'vod_name': '济公传',
              'vod_pic': 'https://img/418792.jpg',
              'vod_year': '2016',
              'vod_play_from': withLines ? '咕噜' : '',
              'vod_play_url': withLines
                  ? '第01集\$https://cdn/1.m3u8#第02集\$https://cdn/2.m3u8'
                  : '',
            },
          ],
        });

    test('详情有线路：日志写出 play_from / lines，播放能拿到地址', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(JarSpider.channel, (call) async {
        if (call.method == 'detail') return detailBody();
        if (call.method == 'player') {
          return jsonEncode(<String, Object?>{
            'parse': 0,
            'url': 'https://cdn/1.m3u8',
          });
        }
        return '{}';
      });
      final detail = await JarSpider.detail(
        api: 'csp_Gulu',
        ext: '',
        vodId: '418792',
      );
      expect(detail.title, '济公传');
      expect(detail.lines, isNotEmpty);
      expect(logs.any((l) => l.startsWith('[JarDetail]') && l.contains('lines=1')),
          isTrue);

      final info = await JarSpider.play(
        api: 'csp_Gulu',
        ext: '',
        vodId: '418792',
        lineName: detail.lines.first.name,
        ep: 1,
      );
      expect(info.url, 'https://cdn/1.m3u8');
      expect(
        logs.any((l) => l.startsWith('[JarPlay]') && l.contains('url=https://cdn/1.m3u8')),
        isTrue,
      );
    });

    test('详情没有线路：抛「没给播放地址」，日志写明原因', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(JarSpider.channel,
              (call) async => detailBody(vodId: '418793', withLines: false));
      await expectLater(
        JarSpider.detail(api: 'csp_Gulu', ext: '', vodId: '418793'),
        throwsA(isA<ApiException>()),
      );
      expect(
        logs.any((l) =>
            l.startsWith('[JarDetail]') && l.contains('线路解析为空')),
        isTrue,
        reason: '打不开时日志必须说清是「没线路」还是「没地址」：$logs',
      );
    });

    test('播放拿到需要 WebView 嗅探的地址：报明确原因 + 记日志', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(JarSpider.channel, (call) async {
        if (call.method == 'detail') return detailBody(vodId: '418794');
        return jsonEncode(<String, Object?>{
          'parse': 1,
          'url': 'http://vip.example.com/play/123',
        });
      });
      await expectLater(
        JarSpider.play(
          api: 'csp_Gulu',
          ext: '',
          vodId: '418794',
          lineName: '咕噜',
          ep: 1,
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            contains('网页解析'),
          ),
        ),
      );
      expect(logs.any((l) => l.startsWith('[JarPlay]') && l.contains('失败')),
          isTrue);
    });
  });

  group('异常收敛', () {
    test('通道抛 PlatformException 时是 ApiException（不是裸异常）', () async {
      mockJar(quickFalseError: 'call_failed：searchContent 失败');
      await expectLater(
        JarSpider.search(api: 'csp_Gulu', ext: '', key: '济公传'),
        throwsA(isA<ApiException>()),
      );
    });
  });
}

/// 单条片名过一遍闸门（搜「济公传」）。
bool _keep(String title) {
  final card = VideoCard.fromJson(<String, dynamic>{
    'id': title,
    'title': title,
  });
  return fxSearchGate(<VideoCard>[card], '济公传').kept.isNotEmpty;
}

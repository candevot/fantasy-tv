import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fantasy_tv/services/cms_bridge.dart';
import 'package:fantasy_tv/services/fx_player.dart';
import 'package:fantasy_tv/services/jar_log.dart';
import 'package:fantasy_tv/services/jar_sources.dart';
import 'package:fantasy_tv/services/jar_spider.dart';
import 'package:fantasy_tv/services/play_log.dart';
import 'package:fantasy_tv/services/play_path.dart';

/// GULU_FIRST_PLAY（2026-11-22）回归：**咕噜线路首播一直卡「正在加载」，
/// 手点右上角「刷新」立刻秒播**（用户实测 v1.0.493）。
///
/// 根因（本文件逐条钉死）：
///
/// ```
/// 首播  FxPlayCache.resolve(force:false) → 命中详情页 warm() 预解析的地址
///       → 那条地址是**上一次** playerContent 签出来的，到真播时已失效
/// 刷新  FxPlayCache.resolve(force:true)  → 丢缓存 → JarSpider.play →
///       playerContent **现签**一条新地址 → 秒播
/// ```
///
/// 两条路的唯一差别就是「读缓存」还是「现签」，所以修法是：短寿命线路
/// （`FxPlayCache.isShortLived` = jar 线路）**不预热、不读缓存、每次都现签**，
/// 外加首播失败时自动重新解析重试最多 2 次（`fxShouldReparsePlay`）。
///
/// 这里用 jar 通道的 mock 把「每次 playerContent 签一条新地址」这个上游事实
/// 固化下来，于是断言可以直接比较**首播地址 vs 刷新地址**。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];
  final logs = <String>[];
  DebugPrintCallback originalDebugPrint = debugPrint;
  var playerSeq = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    calls.clear();
    logs.clear();
    playerSeq = 0;
    JarSpider.debugForceSupported = true;
    originalDebugPrint = debugPrint;
    // 把 [fxPlayLog] / [fxJarLog] 收起来当证据（同时别让测试输出被刷屏）。
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };
    JarMergeIndex.instance.clear();
  });

  tearDown(() {
    debugPrint = originalDebugPrint;
    JarSpider.debugForceSupported = false;
    JarMergeIndex.instance.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(JarSpider.channel, null);
  });

  /// 咕噜风格详情：一条 `4K` 子线路，第 1 集是占位地址（真地址由
  /// `playerContent` 现签，所以这里给什么都行）。
  String detailBody({required String vodId}) => '''
{"list":[{"vod_id":"$vodId","vod_name":"八仙","vod_year":"2016",
"vod_pic":"https://img/1.jpg","vod_play_from":"4K",
"vod_play_url":"第1集\$https://cdn/$vodId/1.m3u8"}]}''';

  void mockJar(Object? Function(String method, Map<String, dynamic> args) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(JarSpider.channel, (call) async {
      calls.add(call);
      final args = Map<String, dynamic>.from(
        (call.arguments as Map?) ?? <String, dynamic>{},
      );
      return handler(call.method, args);
    });
  }

  /// 上游事实：`playerContent` 每调一次就签一条**新**地址（带递增 sign）。
  void mockGulu({required String vodId}) {
    mockJar((method, args) {
      if (method == 'status') {
        return jsonEncode(<String, Object?>{'installed': true, 'md5': 'abc'});
      }
      if (method == 'player') {
        playerSeq += 1;
        return jsonEncode(<String, Object?>{
          'parse': 0,
          'url': 'https://cdn/$vodId/1.m3u8?sign=call$playerSeq',
        });
      }
      return detailBody(vodId: vodId);
    });
  }

  int playerCalls() => calls.where((c) => c.method == 'player').length;

  /* ------------------------------------------- 1. 首播地址 vs 刷新地址 */

  test('首播与刷新各自现签：两条地址不同（这就是用户看到的差异）', () async {
    mockGulu(vodId: '9101');
    final id = '@src:咕噜::9101';
    final line = fxJarLineId('咕噜', '9101', '4K');

    // ① 首播：详情页进页面就调过 warm（修之前这里会把地址塞进 10 分钟缓存）
    FxPlayCache.warm(id, 1, line);
    final first = await FxPlayCache.resolve(id, 1, line);

    // ② 手点右上角「刷新」：reload(forcePlayInfo: true)
    final refreshed = await FxPlayCache.resolve(id, 1, line, force: true);

    stdout.writeln('--- 首播 vs 刷新 地址对比（GULU_FIRST_PLAY 证据）---');
    for (final l in logs.where((l) => l.contains('resolve ') || l.contains('warm '))) {
      stdout.writeln(l);
    }
    stdout.writeln('首播  = ${first.url}');
    stdout.writeln('刷新  = ${refreshed.url}');

    expect(first.url, 'https://cdn/9101/1.m3u8?sign=call1');
    expect(refreshed.url, 'https://cdn/9101/1.m3u8?sign=call2');
    // 根因：两条地址不一样 —— 首播用的绝不能是「上一次」签的那条。
    expect(first.url, isNot(refreshed.url));
    // 两次都是真的 playerContent，没有一次读到缓存。
    expect(playerCalls(), 2);
    expect(logs.where((l) => l.contains('cache=short-lived')).length, 2);
  });

  test('预热过也不许把旧地址交给首播（修之前这里必然同一条）', () async {
    mockGulu(vodId: '9102');
    final id = '@src:咕噜::9102';
    final line = fxJarLineId('咕噜', '9102', '4K');

    // warm 直接跳过：不发 playerContent，也就没有「过期地址」可被首播命中。
    FxPlayCache.warm(id, 1, line);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(playerCalls(), 0);
    expect(
      logs.any((l) => l.contains('warm skip short-lived')),
      isTrue,
      reason: '短寿命线路必须打一行「不预解析」的日志',
    );
    // peek 恒空：UI 不能据此以为「可秒开」而跳过现解析。
    expect(FxPlayCache.peek(id, 1, line), isNull);

    final first = await FxPlayCache.resolve(id, 1, line);
    final second = await FxPlayCache.resolve(id, 1, line);
    expect(first.url, contains('sign=call1'));
    // 再来一次仍然是现签，绝不回落到 call1。
    expect(second.url, contains('sign=call2'));
    expect(playerCalls(), 2);
  });

  test('救援链 refreshPlay 对 jar 有效：fresh:true 也是现签新地址', () async {
    mockGulu(vodId: '9103');
    final id = '@src:咕噜::9103';
    final line = fxJarLineId('咕噜', '9103', '4K');

    // _refreshPlatformUrl 里那一句就是它。
    final a = await CmsBridge.play(id, 1, line, fresh: true);
    final b = await CmsBridge.play(id, 1, line, fresh: true);
    expect(a.url, contains('sign=call1'));
    expect(b.url, contains('sign=call2'));
    expect(a.url, isNot(b.url));
    expect(playerCalls(), 2);
    // jar 分支不看 fresh（它本来就没有服务端缓存），但**必须**真的现签。
    expect(CmsBridge.isJarLine(line), isTrue);
  });

  /* ------------------------------------------- 2. 自动重新解析重试策略 */

  group('首播失败 → 自动重新解析重试（fxShouldReparsePlay）', () {
    test('无进展 / 真失败都值得再签一条地址', () {
      expect(
        fxShouldReparsePlay(reparse: 0, reason: '播放超时'),
        isTrue,
        reason: '首播卡住 → 重试 1',
      );
      expect(
        fxShouldReparsePlay(reparse: 1, reason: '线路不可用(403)'),
        isTrue,
        reason: '第 1 次重试也失败 → 重试 2',
      );
      expect(
        fxShouldReparsePlay(reparse: 0, reason: 'no_progress'),
        isTrue,
      );
    });

    test('最多 2 次，用满就交回原来的失败链', () {
      expect(fxFirstPlayReparseMax, 2);
      expect(fxShouldReparsePlay(reparse: 2, reason: '播放超时'), isFalse);
      expect(fxShouldReparsePlay(reparse: 3, reason: '播放超时'), isFalse);
    });

    test('慢网 30 秒硬上限不参与重试（到点直接换下一条，口径不许变）', () {
      expect(
        fxShouldReparsePlay(reparse: 0, reason: '慢网超时(30s)'),
        isFalse,
      );
      expect(
        fxShouldReparsePlay(reparse: 0, reason: 'FxPlayerException: 慢网超时(30s)'),
        isFalse,
      );
    });
  });

  /* ------------------------------------------- 3. 日志样例（验收证据） */

  group('自动重解析重试日志', () {
    test('首行：决定重试（action=reparse）', () {
      expect(
        fxRetryLog(
          retry: 1,
          line: '咕噜·金牌极速',
          ep: 1,
          reason: '播放超时',
          oldUrl: 'https://cdn/9101/1.m3u8?sign=call1',
          action: 'reparse',
        ),
        'retry=1 line=咕噜·金牌极速 ep=1 reason=播放超时 '
        'old=https://cdn/9101/1.m3u8?sign=call1 action=reparse',
      );
    });

    test('次行：拿到的新地址（old= vs new= 一比就出根因）', () {
      final line = fxRetryLog(
        retry: 1,
        line: '咕噜·金牌极速',
        ep: 1,
        reason: '播放超时',
        oldUrl: 'https://cdn/9101/1.m3u8?sign=call1',
        newUrl: 'https://cdn/9101/1.m3u8?sign=call7',
      );
      expect(
        line,
        'retry=1 line=咕噜·金牌极速 ep=1 reason=播放超时 '
        'old=https://cdn/9101/1.m3u8?sign=call1 '
        'new=https://cdn/9101/1.m3u8?sign=call7',
      );
      // 首播地址与重解析地址必须不同 —— 否则重试毫无意义。
      final old = RegExp(r'old=(\S+)').firstMatch(line)!.group(1)!;
      final neu = RegExp(r'new=(\S+)').firstMatch(line)!.group(1)!;
      expect(old, isNot(neu));
    });

    test('打上 jar tag 就是验收要的 `[JarPlay] retry=1 …`', () {
      // player_page 里 `tag: CmsBridge.isJarLine(line) ? fxJarPlayTag : fxPlayTag`，
      // fxJarLog 的输出格式是 `[$tag] $body`。
      final body = fxRetryLog(
        retry: 1,
        line: '咕噜·金牌极速',
        ep: 1,
        reason: '播放超时',
        oldUrl: 'https://cdn/9101/1.m3u8?sign=call1',
        newUrl: 'https://cdn/9101/1.m3u8?sign=call7',
      );
      final printed = '[$fxJarPlayTag] $body';
      expect(printed, startsWith('[JarPlay] retry=1 '));
      expect(printed, contains('old='));
      expect(printed, contains('new='));
    });

    test('短寿命线路的判定只认 jar 线路 id', () {
      expect(FxPlayCache.isShortLived(fxJarLineId('咕噜', '9101', '4K')), isTrue);
      expect(FxPlayCache.isShortLived('量子'), isFalse);
      expect(FxPlayCache.isShortLived(''), isFalse);
    });
  });
}

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/services/cms_api.dart';
import 'package:fantasy_tv/services/cms_bridge.dart';

/// HOME_ROW（2026-11-22 用户实测 bug）回归：**推荐页空白**。
///
/// 现场：推荐 tab 一直「这个频道暂时没有内容」，而分类页 / 搜索完全正常；
/// 服务端 `ac=detail&t=1&pg=1&src=hx&order=vod_hits&by=desc` 实测 20 条、
/// `vod_play_url` 一条都不空。
///
/// 根因（已修）：`CmsBridge._row` 去重那一行写的是
/// `(v as dynamic).vodId ?? v.vod_id ?? v`，而 `v` 是 `Map<String, dynamic>`
/// —— 动态取 `vodId` 直接抛 `NoSuchMethodError`（`??` 只兜 null，兜不住异常）。
/// 于是 5 行全抛、`_tryRow` 全返回 null、sections 为空。
///
/// 这里用 [CmsApi.debugFetch] 把「接口」换成内存假数据，跑的是**真实**的
/// `CmsBridge.home()`：取数 → 去重 → 可播过滤 → 转卡片 → 空态降级重试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  DebugPrintCallback originalDebugPrint = debugPrint;

  setUp(() {
    CmsApi.fallback = false;
    // 打点要能被断言：先收集，不刷屏。
    originalDebugPrint = debugPrint;
  });

  tearDown(() {
    CmsApi.debugFetch = null;
    debugPrint = originalDebugPrint;
  });

  /// 一条和我们库同形状的记录（字段照实测 `ac=detail` 的返回）。
  Map<String, dynamic> record(int typeId, int i) => <String, dynamic>{
        'vod_id': typeId * 10000 + i,
        'vod_name': '测试影片$typeId-$i',
        'vod_pic': 'https://img.example/$typeId-$i.jpg',
        'vod_year': '2026',
        'vod_area': '大陆',
        'vod_score': '8.${i % 10}',
        'vod_hits': 1200000 - i,
        'vod_remarks': '更新至${i + 1}集',
        'vod_total': 40,
        'vod_time': '2026-11-21 10:00:00',
        'vod_from': 'hx',
        'type_id': typeId,
        'type_name': '电影',
        'vod_content': '简介',
        'vod_play_from': '幻想4K\$\$\$量子',
        'vod_play_url':
            '第1集\$FY-SH4K-0a1b2c#第2集\$FY-SH4K-0a1b3c'
                '\$\$\$第1集\$https://lzv34.com/share/0a1b2c',
      };

  List<Map<String, dynamic>> page(int typeId, int n) =>
      <Map<String, dynamic>>[for (var i = 0; i < n; i++) record(typeId, i)];

  test('推荐页出内容：5 行、每行 30 条（根因修复前这里全是 0）', () async {
    final calls = <Map<String, String>>[];
    CmsApi.debugFetch = (query) async {
      calls.add(Map<String, String>.from(query));
      final typeId = int.tryParse(query['t'] ?? '') ?? 0;
      final pg = int.tryParse(query['pg'] ?? '1') ?? 1;
      return <String, dynamic>{
        'code': 1,
        'page': pg,
        'pagecount': 4,
        'limit': 20,
        'total': 64,
        // 第 2 页给不同 id，验证「两页合并去重」这条路也走得通。
        'list': <Map<String, dynamic>>[
          for (var i = 0; i < 20; i++)
            record(typeId, (pg - 1) * 100 + i),
        ],
      };
    };

    final data = await CmsBridge.home('recommend');

    // ① 五行都得有内容（电影 / 电视剧 / 动漫 / 综艺 / 少儿）。
    expect(data.sections.length, 5, reason: '推荐页必须有 5 个分类行');
    for (final section in data.sections) {
      expect(section.items, isNotEmpty, reason: '「${section.title}」行不能空');
      // 两页（20 + 20）合并去重后按上限截到 30 条。
      expect(section.items.length, 30);
    }
    expect(data.banners.length, 5);
    // ② 卡片字段真的转出来了（不是「有卡片但全是空字段」）。
    final first = data.sections.first.items.first;
    expect(first.id, isNotEmpty);
    expect(first.title, isNotEmpty);
    expect(first.cover, isNotEmpty);
    // ③ 请求口径没变：热播排序 + 自有片源 + 两页。
    expect(
      calls.any((q) => q['order'] == 'vod_hits' && q['by'] == 'desc'),
      isTrue,
      reason: '首页仍按热播排序取数',
    );
    expect(calls.every((q) => q['src'] == 'hx'), isTrue);
    expect(calls.any((q) => q['pg'] == '2'), isTrue);
  });

  test('热播那一路空 → 自动降级「t=1 第一页不带 order」，推荐照样有内容', () async {
    final plainCalls = <Map<String, String>>[];
    CmsApi.debugFetch = (query) async {
      final typeId = int.tryParse(query['t'] ?? '') ?? 0;
      // 带 order 的热播请求：服务端排序坏了 / 给回空列表。
      if (query.containsKey('order')) {
        return <String, dynamic>{
          'code': 1,
          'page': 1,
          'pagecount': 0,
          'limit': 20,
          'total': 0,
          'list': const <Object>[],
        };
      }
      // 不带 order 的普通第一页：分类页一直在用这条路，永远有数据。
      plainCalls.add(Map<String, String>.from(query));
      return <String, dynamic>{
        'code': 1,
        'page': 1,
        'pagecount': 4,
        'limit': 20,
        'total': 64,
        'list': page(typeId, 20),
      };
    };

    final data = await CmsBridge.home('recommend');

    expect(data.sections, isNotEmpty, reason: '降级重试必须让推荐页出内容');
    expect(data.sections.first.items.length, 20);
    expect(data.banners, isNotEmpty);
    // 降级请求：t=1、pg=1、**不带 order / by**。
    final movie = plainCalls.firstWhere((q) => q['t'] == '1');
    expect(movie['pg'], '1');
    expect(movie.containsKey('order'), isFalse);
    expect(movie.containsKey('by'), isFalse);
  });

  test('两边都空才交给页面显示空态（不抛异常）', () async {
    CmsApi.debugFetch = (query) async => <String, dynamic>{
          'code': 1,
          'page': 1,
          'pagecount': 0,
          'limit': 20,
          'total': 0,
          'list': const <Object>[],
        };

    final data = await CmsBridge.home('recommend');
    expect(data.sections, isEmpty);
    expect(data.banners, isEmpty);
  });

  test('打点：行失败时打出 异常类型 + 第一条记录的 key 列表', () async {
    final lines = <String>[];
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) lines.add(message);
    };
    CmsApi.debugFetch = (query) async {
      final typeId = int.tryParse(query['t'] ?? '') ?? 0;
      final pg = query['pg'] ?? '1';
      // 第 2 页整页 500：HOME_MORE_SAFE 要吞掉这一页，但必须留下痕迹。
      if (pg == '2') throw StateError('page2 boom');
      // 电视剧那一行整行取数失败：验证「失败行 + 异常类型」。
      if (typeId == 2) throw StateError('row boom');
      final list = page(typeId, 20);
      // 一半记录 play_url 是空的：验证 dropNoPlay 分布也打出来。
      for (var i = 0; i < list.length; i += 2) {
        list[i]['vod_play_url'] = '';
      }
      return <String, dynamic>{
        'code': 1,
        'page': 1,
        'pagecount': 1,
        'limit': 20,
        'total': 20,
        'list': list,
      };
    };

    await CmsBridge.home('recommend');

    final logs = lines.where((l) => l.contains('[HOME_ROW]')).join('\n');
    expect(logs, isNotEmpty, reason: 'debug 下必须留下 HOME_ROW 打点');
    expect(logs, contains('电视剧 t=2 取数失败 StateError'), reason: '失败行 + 异常类型');
    expect(logs, contains('第 2 页取数失败 StateError'));
    expect(logs, contains('dropNoPlay=10'), reason: '被丢掉的条数要有分布');
    expect(logs, contains('keys=['), reason: '第一条记录的 key 列表');
    expect(logs, contains('vod_id'));
    expect(logs, contains('vod_play_url'));
  });

  test('根因回归：Map 记录按 vod_id 去重，不再抛 NoSuchMethodError', () async {
    // 直接断言曾经的崩溃点：动态 getter 抛异常，而 Map 取值不抛。
    expect(() => (<String, dynamic>{'vod_id': 1} as dynamic).vodId,
        throwsA(isA<NoSuchMethodError>()));
    CmsApi.debugFetch = (query) async => <String, dynamic>{
          'code': 1,
          'page': 1,
          'pagecount': 1,
          'limit': 20,
          'total': 1,
          'list': <Map<String, dynamic>>[record(1, 0)],
        };
    // 不抛异常、并且真的出了卡片。
    final data = await CmsBridge.home('movie');
    expect(data.sections.single.items, hasLength(1));
  });
}

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/api.dart';
import 'package:fantasy_tv/models.dart';
import 'package:fantasy_tv/services/cms_bridge.dart';
import 'package:fantasy_tv/services/jar_spider.dart';
import 'package:fantasy_tv/widgets/fx_cards.dart';

/// DETAIL_FIX（2026-11-15）：详情页「加载失败（该源暂不可用，8 秒无响应）」
/// 与「肥猫结果封面空白」两件事的回归。
///
/// 钉死的四组规则：
///   1. 详情超时**按来源区分**：外部源（肥猫 jar）20 秒，本站 CMS 保持 12 秒。
///      8 秒必挂 —— 咕噜的 `detailContent` 要先握手，自身还有
///      3 次重试 + 500/1000/2000ms 退避（光睡眠 3.5 秒），一次成功的详情
///      经常落在 9～15 秒。
///   2. 错误文案按来源区分：本站 →「该线路暂时取不到，换条线路试试」；
///      外部源 →「<源名> 暂时没响应，换一个源试试」。外部源没有「本站线路」。
///   3. jar 的 `vod_pic` 归一化：空串 / 源站相对地址 / 协议相对地址三种都
///      不许再补成我们已下线的旧后端地址（那会变成一块空白封面）。
///   4. 封面加载中 / 加载失败 / 地址为空都显示「片名首字 + 渐变底」，
///      不再是灰白空白块。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('封面地址归一化（Api.coverOf）', () {
    test('绝对地址原样保留', () {
      expect(
        Api.coverOf('https://img.example.com/a.jpg'),
        'https://img.example.com/a.jpg',
      );
      expect(
        Api.coverOf('http://img.example.com/a.jpg?x=1'),
        'http://img.example.com/a.jpg?x=1',
      );
    });

    test('空串 / data URI / 纯空白 → 空串（交给首字占位）', () {
      expect(Api.coverOf(''), '');
      expect(Api.coverOf('   '), '');
      expect(Api.coverOf('data:image/png;base64,AAAA'), '');
    });

    test('协议相对地址补 https:', () {
      expect(Api.coverOf('//img.example.com/a.jpg'),
          'https://img.example.com/a.jpg');
    });

    test('源站相对地址按源自己的站点根补全', () {
      expect(
        Api.coverOf('upload/vod/1.jpg', root: 'https://gulu.example/api.php'),
        'https://gulu.example/upload/vod/1.jpg',
      );
      expect(
        Api.coverOf('/upload/vod/1.jpg', root: 'https://gulu.example/api.php'),
        'https://gulu.example/upload/vod/1.jpg',
      );
      expect(
        Api.coverOf('upload/1.jpg', root: 'http://1.2.3.4:8787/api.php'),
        'http://1.2.3.4:8787/upload/1.jpg',
      );
    });

    test('补不出绝对地址 → 空串（绝不落到我们的旧后端）', () {
      // jar 源的 api 是类名（csp_Gulu），没有站点根可补。
      expect(Api.coverOf('upload/vod/1.jpg', root: 'csp_Gulu'), '');
      expect(Api.coverOf('/upload/1.jpg'), '');
      expect(Api.coverOf('upload/1.jpg', root: ''), '');
    });

    test('originOf 取出站点根 / 取不出返回空串', () {
      expect(Api.originOf('https://a.b/api.php?x=1'), 'https://a.b');
      expect(Api.originOf('http://1.2.3.4:8787/api.php'), 'http://1.2.3.4:8787');
      expect(Api.originOf('csp_Gulu'), '');
      expect(Api.originOf(''), '');
    });
  });

  group('详情超时按来源区分（DETAIL_TIMEOUT）', () {
    test('外部源 20 秒（咕噜 detailContent 要握手，缩到 12s 会直接超时放不了）', () {
      expect(CmsBridge.detailTimeout('@src:gulu::418792'),
          const Duration(seconds: 20));
      expect(CmsBridge.externalDetailTimeout, const Duration(seconds: 20));
    });

    test('本站 CMS 保持 12 秒', () {
      expect(CmsBridge.detailTimeout('418792'), const Duration(seconds: 12));
      expect(CmsBridge.detailTimeout('@line:幻想爱奇艺::418792'),
          const Duration(seconds: 12));
      expect(CmsBridge.ownDetailTimeout, const Duration(seconds: 12));
    });

    test('jar 单次调用默认 12 秒（搜索 / 播放），详情单独放宽', () {
      expect(CmsBridge.jarTimeout, const Duration(seconds: 12));
      // 详情 18 秒：咕噜要握手，比搜索的 12 秒长。
      expect(CmsBridge.jarDetailTimeout >= const Duration(seconds: 15), isTrue);
      expect(CmsBridge.jarDetailTimeout, const Duration(seconds: 18));
    });

    test('源级超时先于页面级：jar guard 比页面预算短', () {
      // 和 searchBudget < timeout 同一个口径：页面要拿到「咕噜暂时没响应」，
      // 而不是一句笼统的页面超时。
      expect(
        CmsBridge.jarDetailTimeout < CmsBridge.externalDetailTimeout,
        isTrue,
      );

    });
  });

  group('错误文案按来源区分（SOURCE_TEXT）', () {
    test('本站源：换条线路试试', () {
      expect(
        CmsBridge.detailErrorText('418792'),
        '该线路暂时取不到，换条线路试试',
      );
    });

    test('外部源：<源名> 暂时没响应，换一个源试试', () {
      expect(
        CmsBridge.detailErrorText('@src:gulu::418792', label: '咕噜'),
        '咕噜 暂时没响应，换一个源试试',
      );
    });

    test('外部源但拿不到源名时也给可读文案', () {
      expect(
        CmsBridge.detailErrorText('@src:unknown::1'),
        '这个源暂时没响应，换一个源试试',
      );
    });

    test('外部源判定只看 id 前缀', () {
      expect(CmsBridge.isExternalId('@src:gulu::1'), isTrue);
      expect(CmsBridge.isExternalId('  418792'), isFalse);
      expect(CmsBridge.isExternalId('@line:幻想::1'), isFalse);
    });
  });

  group('jar 详情的封面归一化（COVER_FIX）', () {
    test('相对 vod_pic 按源站根补全；空 vod_pic 保持空串', () {
      Map<String, Object?> body(String pic) => <String, Object?>{
            'list': <Map<String, Object?>>[
              <String, Object?>{
                'vod_id': '9001',
                'vod_name': '济公传',
                'vod_pic': pic,
                'vod_year': '2016',
                'vod_play_from': '咕噜',
                'vod_play_url':
                    '第01集\$https://cdn/1.m3u8#第02集\$https://cdn/2.m3u8',
              },
            ],
          };

      final relative = JarSpider.detailOf(body('upload/vod/9.jpg'),
          fallbackId: '9001', root: 'https://gulu.example/api.php');
      expect(relative.cover, 'https://gulu.example/upload/vod/9.jpg');

      final empty = JarSpider.detailOf(body(''), fallbackId: '9001');
      expect(empty.cover, '');

      final absolute = JarSpider.detailOf(body('https://img/9.jpg'),
          fallbackId: '9001', root: 'https://gulu.example/api.php');
      expect(absolute.cover, 'https://img/9.jpg');
    });

    test('jar 卡片（搜索）经片源中心归一化后不再是「我们旧后端的相对地址」', () {
      // 直接验证转换规则本身：csp_Gulu 没有站点根 → 空串（走首字占位），
      // 而不是补成 http://<我们后端>/upload/1.jpg 这种必然 404 的地址。
      expect(Api.coverOf('upload/vod/9.jpg', root: 'csp_Gulu'), '');
      expect(Api.coverOf('https://img/9.jpg', root: 'csp_Gulu'),
          'https://img/9.jpg');
    });
  });

  group('封面占位：加载中 / 失败 / 空地址都不许是空白块', () {
    testWidgets('空封面显示片名首字占位', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 84,
              height: 112,
              child: FxCover(url: '', title: '济公传'),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('济'), findsOneWidget);
    });

    testWidgets('加载中的首帧也是片名首字（不是灰白 shimmer）', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 84,
              height: 112,
              child: FxCover(url: 'https://img.invalid/1.jpg', title: '济公传'),
            ),
          ),
        ),
      );
      // 首帧（图片还没到）就应该能看到首字，用户不会把加载中看成没封面。
      expect(find.text('济'), findsOneWidget);
    });
  });

  test('VideoCard 封面字段没被转换过程改写', () {
    final card = VideoCard.fromJson(<String, dynamic>{
      'id': '1',
      'title': '济公传',
      'cover': 'https://img/1.jpg',
    });
    expect(card.cover, 'https://img/1.jpg');
    expect(card.title, '济公传');
    // 只是确认 JSON 形状没变；封面归一化发生在 source_hub / jar_spider 一层。
    expect(jsonEncode(<String, Object?>{'cover': card.cover}),
        '{"cover":"https://img/1.jpg"}');
  });
}

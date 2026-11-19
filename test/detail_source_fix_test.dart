import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/api.dart';
import 'package:fantasy_tv/models.dart';
import 'package:fantasy_tv/services/cms_bridge.dart';
import 'package:fantasy_tv/widgets/fx_cards.dart';

/// DETAIL_FIX（2026-11-15）：详情页「加载失败（该源暂不可用，8 秒无响应）」
/// 与「肥猫结果封面空白」两件事的回归。
///
/// 钉死的四组规则：
///   1. 详情超时**按来源区分**：外部源 20 秒，本站 CMS 保持 12 秒。
///      8 秒必挂 —— 外部源详情自身带 3 次重试 + 500/1000/2000ms 退避
///      （光睡眠 3.5 秒），一次成功的详情经常落在 9～15 秒。
///   2. 错误文案按来源区分：本站 →「该线路暂时取不到，换条线路试试」；
///      外部源 →「<源名> 暂时没响应，换一个源试试」。外部源没有「本站线路」。
///   3. `vod_pic` 归一化：空串 / 源站相对地址 / 协议相对地址三种都不许再补成
///      我们已下线的旧后端地址（那会变成一块空白封面）。
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
    test('外部源 20 秒', () {
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
    // 只是确认 JSON 形状没变；封面归一化发生在片源中心那一层。
    expect(jsonEncode(<String, Object?>{'cover': card.cover}),
        '{"cover":"https://img/1.jpg"}');
  });
}

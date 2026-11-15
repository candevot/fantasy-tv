// 外部 CMS 请求协议单测（PROTOCOL_FACE 2026-11-15 · 移植阶段 1 第 4、7 条）。
//
// 钉住两件事：
//   1. `ac=` 只有 `videolist` / `detail` 两个取值（`type 0` 用 videolist，
//      其余用 detail），「站点栏目表」固定 `list`；
//   2. `ext` 长度决定 GET / POST：≤1000 字走 query，>1000 字走表单体 ——
//      长 ext 塞进 query 会撞 414 / 被后端截断。

import 'package:flutter_test/flutter_test.dart';
import 'package:fantasy_tv/services/cms_request.dart';

void main() {
  group('ac 取值', () {
    test('分类列表：type 0 用 videolist，其余 detail', () {
      expect(
        CmsRequest.acFor(CmsCall.categoryList, directKind: true),
        'videolist',
      );
      expect(
        CmsRequest.acFor(CmsCall.categoryList, directKind: false),
        'detail',
      );
    });

    test('详情同理；搜索固定 detail；栏目表固定 list', () {
      expect(CmsRequest.acFor(CmsCall.detail, directKind: true), 'videolist');
      expect(CmsRequest.acFor(CmsCall.detail, directKind: false), 'detail');
      expect(CmsRequest.acFor(CmsCall.search, directKind: true), 'detail');
      expect(CmsRequest.acFor(CmsCall.classes, directKind: true), 'list');
    });
  });

  group('GET / POST 分流', () {
    test('没有 ext：GET，参数全在 query', () {
      final req = CmsRequest.build(
        api: 'https://cms.example.com/api.php/provide/vod',
        params: <String, String>{'ac': 'detail', 'ids': '123'},
      );
      expect(req.method, CmsHttpMethod.get);
      expect(req.isPost, isFalse);
      expect(req.body, isEmpty);
      expect(req.uri.queryParameters['ac'], 'detail');
      expect(req.uri.queryParameters['ids'], '123');
      // 没 query 的地址补尾斜杠（MacCMS 的路径惯例）。
      expect(req.uri.path, endsWith('/'));
    });

    test('短 ext（≤1000）走 GET，ext 作为 extend 参数', () {
      final ext = 'x' * 1000;
      final req = CmsRequest.build(
        api: 'https://cms.example.com/api.php/provide/vod/',
        params: <String, String>{'ac': 'detail', 't': '1', 'pg': '1'},
        profile: CmsSiteProfile(ext: ext),
      );
      expect(req.method, CmsHttpMethod.get);
      expect(req.uri.queryParameters['extend'], ext);
    });

    test('长 ext（>1000）走 POST，参数搬到表单体里，query 不再带 extend', () {
      final ext = 'x' * 1001;
      final req = CmsRequest.build(
        api: 'https://cms.example.com/api.php/provide/vod/',
        params: <String, String>{'ac': 'detail', 'ids': '9'},
        profile: CmsSiteProfile(ext: ext),
      );
      expect(req.method, CmsHttpMethod.post);
      expect(req.uri.queryParameters.containsKey('extend'), isFalse);
      expect(req.body, contains('ac=detail'));
      expect(req.body, contains('ids=9'));
      expect(req.body, contains('extend=$ext'));
      expect(req.header['content-type'], 'application/x-www-form-urlencoded');
    });

    test('边界 1000 走 GET，1001 走 POST', () {
      CmsHttpMethod methodOf(int len) => CmsRequest.build(
            api: 'https://a/b/',
            params: const <String, String>{'ac': 'detail'},
            profile: CmsSiteProfile(ext: 'e' * len),
          ).method;
      expect(methodOf(kMaxExtForGet), CmsHttpMethod.get);
      expect(methodOf(kMaxExtForGet + 1), CmsHttpMethod.post);
    });

    test('搜索没 ext 时也补一个空 extend（部分源靠这个键走 TVBox 分支）', () {
      final req = CmsRequest.build(
        api: 'https://a/b/',
        params: <String, String>{'ac': 'detail', 'wd': '济公传'},
      );
      expect(req.uri.queryParameters['extend'], '');
    });
  });

  group('站点级 header', () {
    test('header 合进请求，accept 仍然兜底', () {
      final req = CmsRequest.build(
        api: 'https://a/b/',
        params: const <String, String>{'ac': 'detail'},
        profile: const CmsSiteProfile(
          header: <String, String>{
            'Referer': 'https://site.example.com/',
            'Cookie': 'uid=7',
          },
        ),
      );
      expect(req.header['Referer'], 'https://site.example.com/');
      expect(req.header['Cookie'], 'uid=7');
      expect(req.header['accept'], '*/*');
    });

    test('站点 header 可以覆盖 accept', () {
      final req = CmsRequest.build(
        api: 'https://a/b/',
        params: const <String, String>{},
        profile: const CmsSiteProfile(
          header: <String, String>{'accept': 'application/json'},
        ),
      );
      expect(req.header['accept'], 'application/json');
    });
  });

  group('地址归一', () {
    test('已有 query 时不再补斜杠', () {
      final req = CmsRequest.build(
        api: 'https://a/b/api.php?key=1',
        params: const <String, String>{'ac': 'detail'},
      );
      expect(req.uri.path, '/b/api.php');
      expect(req.uri.queryParameters['key'], '1');
      expect(req.uri.queryParameters['ac'], 'detail');
    });

    test('画像 copyWith 保留未改的字段', () {
      const base = CmsSiteProfile(
        key: 'k',
        ext: 'e',
        header: <String, String>{'Referer': 'r'},
        playUrl: 'parse:x',
        quickSearch: false,
      );
      final next = base.copyWith(key: 'k2');
      expect(next.key, 'k2');
      expect(next.ext, 'e');
      expect(next.header['Referer'], 'r');
      expect(next.playUrl, 'parse:x');
      expect(next.quickSearch, isFalse);
    });
  });
}

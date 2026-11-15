import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/services/cms_source.dart';
import 'package:fantasy_tv/services/hls_segment_index.dart';

/// TOKEN_ONCE / PARSE_ONCE（2026-11-15）的回归。
///
/// 用户实测：《走马上任》(id=3865) 四条线路在 App 里全部播不出来、卡 0 KB/s。
/// 服务端和 CDN 侧都用 curl 验过是通的，问题全在 App 的两处判定：
///
///   1. `isMediaUrl('/hxparse/xo?u=SH4K-…')` 返回 false —— 这个地址是**解析的
///      产物**，却被当成「待解析的令牌」，又被套进 `/hxparse/parse/fuying`
///      转一层（多 1~2 秒，而且中转站和直连并不等价）。
///   2. `HlsSegmentIndex` 为了建「拖动索引」把同一份清单**再抓一次**。本站
///      `/hxparse/xo?u=shvip-…` 背后是一次性令牌，第二次请求直接 403 ——
///      令牌被索引那条烧掉，播放器就是「清单到手、分片 0 KB/s」。
///
/// 这两个用例直接把上面两条钉死。
void main() {
  group('isMediaUrl：本站解析产物不再二次解析', () {
    test('令牌包装地址（?u= 查询串形态）直接可播', () {
      const url = 'http://125.94.244.87/hxparse/xo?u=SH4K-b002a8b424c11a99';
      expect(isMediaUrl(url), isTrue);
      expect(needsParse(url), isFalse);
    });

    test('平台页面包装地址（qq 那条，u 是 URL 编码）直接可播', () {
      const url = 'http://125.94.244.87/hxparse/xo'
          '?u=https%3A%2F%2Fv.qq.com%2Fx%2Fcover%2Fmzc00200zsqz54y'
          '%2Fv4102cvlyfo.html&t=%E8%B5%B0%E9%A9%AC';
      expect(isMediaUrl(url), isTrue);
    });

    test('幻想4K/幻想蓝光的 index.m3u8 路径形态直接可播', () {
      const url = 'http://125.94.244.87/hxparse/play/fuying/'
          'FY-SH4K-b002a8b424c11a9911c9bce46a932cbe/index.m3u8';
      expect(isMediaUrl(url), isTrue);
    });

    test('裸令牌仍然要解析（没被误判成直链）', () {
      expect(isMediaUrl('FY-SH4K-b002a8b424c11a9911c9bce46a932cbe'), isFalse);
      expect(needsParse('FY-SH4K-b002a8b424c11a9911c9bce46a932cbe'), isTrue);
    });

    test('平台页面地址仍然要解析', () {
      expect(isMediaUrl('https://lzv34.com/share/abc123'), isFalse);
      expect(isMediaUrl('https://v.qq.com/x/cover/mzc00200zsqz54y.html'), isFalse);
    });

    test('普通 mp4 / m3u8 直链不受影响', () {
      expect(isMediaUrl('https://cdn.example.com/a/b.mp4'), isTrue);
      expect(isMediaUrl('https://cdn.example.com/a/b.m3u8?token=1'), isTrue);
    });
  });

  group('HlsSegmentIndex：一次性令牌清单不许重复抓', () {
    test('/hxparse/xo 判为一次性令牌', () {
      expect(
        HlsSegmentIndex.isOneTimePlaylist(
          'http://125.94.244.87/hxparse/xo?u=shvip-da57d0f7a7f3a1f62db2bf75',
        ),
        isTrue,
      );
    });

    test('/hxparse/play 判为一次性令牌', () {
      expect(
        HlsSegmentIndex.isOneTimePlaylist(
          'http://125.94.244.87/hxparse/play/fuying/FY-x/index.m3u8',
        ),
        isTrue,
      );
    });

    test('/hxparse/parse 判为一次性令牌', () {
      expect(
        HlsSegmentIndex.isOneTimePlaylist(
          'http://125.94.244.87/hxparse/parse/fuying?u=SH4K-x',
        ),
        isTrue,
      );
    });

    test('CDN 实际清单地址可以去抓（相对分片基准）', () {
      expect(
        HlsSegmentIndex.isOneTimePlaylist(
          'https://ts1.wki8.com/shvip/369bad6c75423c05fc3773d77e7c0ccd.m3u8',
        ),
        isFalse,
      );
    });

    test('空串 / 普通地址不误判', () {
      expect(HlsSegmentIndex.isOneTimePlaylist(''), isFalse);
      expect(
        HlsSegmentIndex.isOneTimePlaylist('https://cdn.example.com/a.m3u8'),
        isFalse,
      );
    });
  });
}

import '../lib/services/play_path.dart';

/// 播放路径判定层的回归（PLAY_PATH 2026-11-15）。
///
/// 全部用**真机实测抓到的地址**，不造数据：
///   · 《济公传》id=202369 幻想爱奇艺
///     `http://125.94.244.87/hxparse/play/iqiyi/1/index.m3u8?title=…&ep=1`
///     → 302 `/hxparse/iqiyi.m3u8?tvid=…` → 200，429087 B，mpegurl；
///   · 同剧 红牛 `https://hn.bfvvs.com/play/Xe07G9vd/index.m3u8` → 200，73685 B；
///   · 幻想4K 令牌 `FY-SH4K-<md5>`、量子 `https://lzv34.com/share/<md5>` 页面。
///
/// 这三类地址的判定只要错一处，用户看到的就是「正在加载」不动：
/// 把直链当令牌会二次解析（地址语义变了），把令牌当直链会直接 403。
void main() {
  var checks = 0;
  void check(bool ok, String name) {
    if (!ok) throw StateError(name);
    checks++;
    print('PASS $name');
  }

  const iqiyi =
      'http://125.94.244.87/hxparse/play/iqiyi/1/index.m3u8'
      '?title=%E6%B5%8E%E5%85%AC%E4%BC%A0&year=2016&ep=1';
  const hongniu = 'https://hn.bfvvs.com/play/Xe07G9vd/index.m3u8';

  // ---------------------------------------------------- 直链 / 解析
  check(isDirectAddress(iqiyi), 'iqiyi 成品地址带 .m3u8? 查询串 -> 直链');
  check(!needsParseAddress(iqiyi), 'iqiyi 成品地址不需要解析');
  check(isDirectAddress(hongniu), '红牛直链');
  check(!needsParseAddress(hongniu), '红牛不需要解析');
  check(
    isDirectAddress('http://h/hxparse/xo?u=SH4K-abc'),
    '本站解析产物（无媒体后缀）也算直链',
  );
  check(
    isDirectAddress('http://h/hxparse/parse/fuying?u=x'),
    '/hxparse/parse 产物算直链，不再套第二层',
  );
  check(
    !isDirectAddress('FY-SH4K-11d01a6e89b1'),
    '幻想4K 令牌不是直链',
  );
  check(
    !isDirectAddress('https://lzv34.com/share/3d8d871deb'),
    '量子 share 页面不是直链',
  );
  check(!isDirectAddress('iqiyi:1'), '爱奇艺占位不是直链');
  check(!isDirectAddress(''), '空地址不是直链');

  // ---------------------------------------------------- 解析器归属
  check(parseKindFor('幻想爱奇艺', iqiyi) == 'direct', '爱奇艺成品地址 -> direct');
  check(parseKindFor('红牛', hongniu) == 'direct', '红牛 -> direct');
  check(parseKindFor('幻想爱奇艺', '') == 'iqiyi', '爱奇艺无地址 -> iqiyi');
  check(parseKindFor('幻想爱奇艺', 'iqiyi:1') == 'iqiyi', '爱奇艺占位 -> iqiyi');
  check(parseKindFor('幻想4K', 'FY-SH4K-11d01a6e') == 'fuying', '4K 令牌 -> fuying');
  check(
    parseKindFor('量子', 'https://lzv34.com/share/3d8d') == 'fuying',
    '量子页面 -> fuying',
  );

  // ---------------------------------------------------- 旧后端闸门
  check(
    !legacyPlayAllowed(legacyEnabled: true, origin: CmsOrigin.cms),
    'CMS 记录的播放路径里不许出现 Api.play',
  );
  check(
    !legacyPlayAllowed(legacyEnabled: true, origin: CmsOrigin.unknown),
    '来源未知也不许回落 8787（只会挂到超时）',
  );
  check(
    legacyPlayAllowed(legacyEnabled: true, origin: CmsOrigin.legacy),
    '只有旧接口记录才允许问 8787',
  );
  check(
    !legacyPlayAllowed(legacyEnabled: false, origin: CmsOrigin.legacy),
    'legacyEnabled=false 时谁都不许问',
  );

  // ---------------------------------------------------- open 去重
  check(
    shouldReuseOpen(
      hasPending: true,
      pendingKey: 'A|1',
      key: 'A|1',
      pendingToken: 5,
      currentToken: 5,
      force: false,
    ),
    '同 key 同代际复用（连点不重复 open）',
  );
  check(
    !shouldReuseOpen(
      hasPending: true,
      pendingKey: 'A|1',
      key: 'A|1',
      pendingToken: 4,
      currentToken: 5,
      force: false,
    ),
    '代际已推进 -> 必须真发一次（重试不再被吞）',
  );
  check(
    !shouldReuseOpen(
      hasPending: true,
      pendingKey: 'A|1',
      key: 'A|1',
      pendingToken: 5,
      currentToken: 5,
      force: true,
    ),
    'force 重试跳过去重',
  );
  check(
    !shouldReuseOpen(
      hasPending: true,
      pendingKey: 'B|1',
      key: 'A|1',
      pendingToken: 5,
      currentToken: 5,
      force: false,
    ),
    '换线路不复用上一条的结果',
  );
  check(
    !shouldReuseOpen(
      hasPending: false,
      pendingKey: null,
      key: 'A|1',
      pendingToken: 0,
      currentToken: 0,
      force: false,
    ),
    '没有在跑的请求不复用',
  );

  print('ALL PASS ($checks checks)');
}

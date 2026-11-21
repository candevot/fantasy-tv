/// 平台热播榜（RANK_BOARD 2026-11-21）。
///
/// 排行榜页要的是**腾讯 / 爱奇艺自己的名次**，不是我们库里按 `vod_hits`
/// 排出来的热度榜 —— 后者只是「谁先进库谁靠前」，跟平台榜毫无关系。
///
/// 数据链路：
///   腾讯 pbaccess / 爱奇艺 mesh 榜单
///     → `hot_rank_sync.php`（宝塔计划任务，每 3 小时）
///     → `mac_hot_rank`（source + type + rank + title + year + vod_id）
///     → `GET /api/rank?source=…&type=…`（本文件，服务端 60 秒缓存）
///
/// 服务端只会返回 `vod_id` 非空的条目（对不上我们库的没片可点，直接跳过），
/// 所以名次会有断号 —— 卡片徽标显示的是**服务端给的真实名次**，
/// 不是列表下标，别改成本地序号。
library;

import '../api.dart';

/// 一个榜单平台。
class RankPlatform {
  const RankPlatform(this.key, this.label, this.tag);

  /// 接口参数 `source`：`tencent` / `iqiyi`。
  final String key;

  /// 顶部切换按钮上的字：腾讯热播 / 爱奇艺热播。
  final String label;

  /// 名次文案里的平台名：腾讯视频 / 爱奇艺。
  final String tag;
}

/// 一个榜单频道：接口参数 `type` + 分类 tab 文案。
class RankChannel {
  const RankChannel(this.type, this.label);
  final int type;
  final String label;
}

/// 榜单一条。
class PlatformRankItem {
  const PlatformRankItem({
    required this.rank,
    required this.title,
    required this.year,
    required this.vodId,
    required this.cover,
  });

  /// 平台真实名次（1 = 榜首）。
  final int rank;
  final String title;
  final int year;

  /// 我们库里的 `mac_vod.vod_id`，点进去就是这部片。
  final String vodId;

  /// 封面：优先 `mac_vod.vod_pic`，库里没图时是榜单自带的平台封面。
  final String cover;
}

/// 一张榜（某平台 × 某频道）。
class PlatformRankBoard {
  const PlatformRankBoard({
    required this.source,
    required this.type,
    required this.channelName,
    required this.updatedAt,
    required this.stale,
    required this.items,
  });

  final String source;
  final int type;
  final String channelName;

  /// 服务端出这份数据的时间（秒级时间戳）。
  final int updatedAt;

  /// true = 服务端读库失败，给的是 30 分钟内的旧榜。
  final bool stale;

  final List<PlatformRankItem> items;

  bool get isEmpty => items.isEmpty;

  static const PlatformRankBoard empty = PlatformRankBoard(
    source: '',
    type: 0,
    channelName: '',
    updatedAt: 0,
    stale: false,
    items: <PlatformRankItem>[],
  );

  factory PlatformRankBoard.fromJson(Map<String, dynamic> j) {
    final raw = j['items'];
    final items = <PlatformRankItem>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is! Map) continue;
        final m = Map<String, dynamic>.from(e);
        final vodId = '${m['vod_id'] ?? ''}'.trim();
        final title = '${m['title'] ?? ''}'.trim();
        if (vodId.isEmpty || vodId == '0' || title.isEmpty) continue;
        items.add(PlatformRankItem(
          rank: _int(m['rank']),
          title: title,
          year: _int(m['year']),
          vodId: vodId,
          cover: '${m['cover'] ?? ''}'.trim(),
        ));
      }
    }
    return PlatformRankBoard(
      source: '${j['source'] ?? ''}'.trim(),
      type: _int(j['type']),
      channelName: '${j['channelName'] ?? ''}'.trim(),
      updatedAt: _int(j['updatedAt']),
      stale: j['stale'] == true,
      items: items,
    );
  }

  static int _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('${v ?? ''}'.trim()) ?? 0;
  }
}

/// 平台榜单的数据层：两个平台 × 四个频道的定义 + 带缓存的取数。
///
/// 缓存 60 秒（与服务端一致）：在「腾讯电影 → 腾讯电视剧 → 腾讯电影」之间
/// 来回切时不重复打请求，列表也不会闪一下空白。任何一次取数失败都**不写
/// 缓存、不回落库内热度榜** —— 页面显示「榜单同步中」，绝不拿假榜单冒充。
class PlatformRankApi {
  PlatformRankApi._();

  /// 顶部切换的两个平台，顺序即界面顺序。
  static const List<RankPlatform> platforms = <RankPlatform>[
    RankPlatform('tencent', '腾讯热播', '腾讯视频'),
    RankPlatform('iqiyi', '爱奇艺热播', '爱奇艺'),
  ];

  /// 分类 tab，顺序即界面顺序；`type` 与服务端 / 同步脚本的频道号一致。
  static const List<RankChannel> channels = <RankChannel>[
    RankChannel(1, '电影'),
    RankChannel(2, '电视剧'),
    RankChannel(3, '动漫'),
    RankChannel(4, '综艺'),
  ];

  static const Duration _ttl = Duration(seconds: 60);

  static final Map<String, _Entry> _cache = <String, _Entry>{};

  static RankPlatform platformOf(String key) {
    for (final p in platforms) {
      if (p.key == key) return p;
    }
    return platforms.first;
  }

  static RankChannel channelOf(int type) {
    for (final c in channels) {
      if (c.type == type) return c;
    }
    return channels.first;
  }

  static String _key(String source, int type) => '$source:$type';

  /// 取一张榜。[force] 为 true 时跳过本地缓存（下拉刷新 / 点刷新按钮）。
  static Future<PlatformRankBoard> fetch(
    String source,
    int type, {
    int limit = 100,
    bool force = false,
  }) async {
    final key = _key(source, type);
    final now = DateTime.now();
    if (!force) {
      final hit = _cache[key];
      if (hit != null && now.difference(hit.at) < _ttl) return hit.board;
    }
    final data = await Api.rankBoard(source: source, type: type, limit: limit);
    final board = PlatformRankBoard.fromJson(data);
    _cache[key] = _Entry(board, now);
    return board;
  }

  /// 清缓存（切换服务器 / 调试用）。
  static void clearCache() => _cache.clear();
}

class _Entry {
  _Entry(this.board, this.at);
  final PlatformRankBoard board;
  final DateTime at;
}

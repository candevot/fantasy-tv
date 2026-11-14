import 'dart:convert';

import 'package:http/http.dart' as http;

import '../api.dart';

/// 弹幕数据层 —— 走主服务 `GET /api/danmu?title=<片名>&ep=<集>`。
///
/// 服务端内部四级回退：本地片库 → 弹弹play（无凭证跳过）→ danmu-api → 空，
/// 并把结果缓存 30 分钟（空结果 5 分钟）。客户端不再自己拼 danmu_api 的
/// search + comment 两步（旧实现在老机器上已经 404），只按 title + ep 要。
///
/// 冷启动的现实：danmu-api 冷搜一次 3~4 秒，而 /api/danmu 对外预算只有
/// 1.2 秒 —— 所以「第一次问」经常拿到空数组。解决靠两边配合：
///   · [warm]：详情页/播放页先让服务端在后台拉（立刻返回），点播放时缓存已热；
///   · 播放页 [DanmuLayer] 对空结果按 1.5s / 4s / 8s 退避重试。
class DanmuService {
  DanmuService._();
  static final DanmuService instance = DanmuService._();

  /// 弹幕接口：[Api.base] 形如 `http://host:8787/api` → `…/api/danmu`。
  /// 用 getter 而不是常量：启动时 [Api.pickBase] 可能把地址切到另一台机器。
  static String get host {
    final base = Api.base.trim().replaceFirst(RegExp(r'/+$'), '');
    return '$base/danmu';
  }

  /// 已取到的弹幕（30 分钟）。空结果不进缓存 —— 空可能是「服务端还在预热」。
  final Map<String, List<DanmuItem>> _cache = {};
  final Map<String, DateTime> _at = {};
  static const Duration _ttl = Duration(minutes: 30);

  static String _key(String title, int ep) => '$title|$ep';

  /// 预热：请求服务端在后台把 title|ep 拉好写缓存，接口立刻返回 `warming:true`。
  ///
  /// 纯尽力而为 —— 失败、超时、页面已经关掉都不影响任何 UI，所以这里吞掉所有异常。
  Future<void> warm({required String title, required int ep}) async {
    final t = title.trim();
    if (t.isEmpty || ep <= 0) return;
    try {
      final uri = Uri.parse(host)
          .replace(queryParameters: {'warm': '1', 'title': t, 'ep': '$ep'});
      await http.get(uri, headers: const {
        'Accept': 'application/json'
      }).timeout(const Duration(seconds: 6));
    } catch (_) {
      // 预热失败静默：真正取弹幕时会重试。
    }
  }

  /// 按剧名 + 集数取弹幕。
  ///
  /// 返回 `null` 表示请求失败（网络/服务异常，调用方可以重试）；
  /// 返回空列表表示服务端明确说这一集没有（或还在预热）。
  Future<List<DanmuItem>?> load({
    required String title,
    required int ep,
    String epName = '',
  }) async {
    final t = title.trim();
    if (t.isEmpty) return null;
    final key = _key(t, ep);
    final at = _at[key];
    if (at != null) {
      if (DateTime.now().difference(at) < _ttl) {
        final cached = _cache[key];
        if (cached != null) return cached;
      } else {
        _cache.remove(key);
        _at.remove(key);
      }
    }
    try {
      final uri =
          Uri.parse(host).replace(queryParameters: {'title': t, 'ep': '$ep'});
      final res = await http.get(uri, headers: const {
        'Accept': 'application/json'
      }).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      final list = body is Map ? body['data'] : null;
      final out = <DanmuItem>[];
      for (final c in (list is List ? list : const <dynamic>[])) {
        final item = DanmuItem.fromJson(c);
        if (item != null) out.add(item);
      }
      out.sort((a, b) => a.time.compareTo(b.time));
      if (out.isNotEmpty) {
        _cache[key] = out;
        _at[key] = DateTime.now();
      }
      return out;
    } catch (_) {
      return null;
    }
  }
}

/// 单条弹幕。
class DanmuItem {
  const DanmuItem({
    required this.time,
    required this.text,
    this.mode = 1,
    this.color = 0xFFFFFF,
  });

  /// 从服务端条目解析：`{t: 秒, text: '…', color: '#ffffff' | int, mode: 1}`。
  ///
  /// 四种来源（本地片库 / 弹弹play / danmu-api / 用户自建）字段类型不完全一致，
  /// 单条解析失败就跳过这一条，不让整集弹幕挂掉。
  static DanmuItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final text = '${raw['text'] ?? ''}'.trim();
    if (text.isEmpty) return null;
    final t = raw['t'];
    final seconds = t is num ? t.toDouble() : (double.tryParse('$t') ?? 0);
    final m = raw['mode'];
    final mode = m is num ? m.toInt() : (int.tryParse('$m') ?? 1);
    return DanmuItem(
      time: Duration(milliseconds: (seconds * 1000).round()),
      text: text,
      mode: mode,
      color: _parseColor(raw['color']),
    );
  }

  /// 颜色：服务端可能给 `#ffffff` 字符串，也可能给 0xFFFFFF 整数。
  static int _parseColor(Object? v) {
    if (v is int) return v & 0xFFFFFF;
    final s = '${v ?? ''}'.trim();
    if (s.isEmpty) return 0xFFFFFF;
    final hex = s.startsWith('#') ? s.substring(1) : s;
    if (hex.length == 6) return int.tryParse(hex, radix: 16) ?? 0xFFFFFF;
    if (hex.length == 8) {
      return int.tryParse(hex.substring(2), radix: 16) ?? 0xFFFFFF;
    }
    return int.tryParse(s) ?? 0xFFFFFF;
  }

  /// 出现时间（相对片头）。
  final Duration time;

  final String text;

  /// 1=滚动 4=底部 5=顶部
  final int mode;

  /// RGB 整数（0xFFFFFF = 白）。
  final int color;
}

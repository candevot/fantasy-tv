import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'danmu_service.dart';

/// 本地弹幕 —— 用户自己发的弹幕。
///
/// danmu_api 只提供「取弹幕」，没有「发弹幕」接口（弹幕源都是只读的
/// 第三方平台）。所以自己发的弹幕存在本机，按 videoId + ep 分组，
/// 和拉下来的弹幕合并后一起渲染。
class DanmuLocal {
  DanmuLocal._();
  static final DanmuLocal instance = DanmuLocal._();

  static const String _key = 'fx_danmu_local_v1';

  /// 内存缓存：key = "videoId|ep"
  final Map<String, List<DanmuItem>> _cache = {};

  static String _k(String videoId, int ep) => '$videoId|$ep';

  /// 读某集自己发的弹幕。
  Future<List<DanmuItem>> read(String videoId, int ep) async {
    final k = _k(videoId, ep);
    if (_cache.containsKey(k)) return _cache[k]!;
    final all = await _readAll();
    final raw = all[k];
    final out = <DanmuItem>[];
    for (final m in (raw as List? ?? const [])) {
      final map = Map<String, dynamic>.from(m as Map);
      out.add(DanmuItem(
        time: Duration(milliseconds: int.tryParse('${map['ms']}') ?? 0),
        text: '${map['text'] ?? ''}',
        mode: int.tryParse('${map['mode']}') ?? 1,
        color: int.tryParse('${map['color']}') ?? 0xFFFFFF,
      ));
    }
    _cache[k] = out;
    return out;
  }

  /// 发一条弹幕。[at] 是当前播放位置。
  Future<void> send({
    required String videoId,
    required int ep,
    required Duration at,
    required String text,
    int mode = 1,
    int color = 0xFFFFFF,
  }) async {
    final t = text.trim();
    if (t.isEmpty) return;
    final k = _k(videoId, ep);
    final all = await _readAll();
    final list = (all[k] as List? ?? <dynamic>[]).toList();
    list.add(<String, dynamic>{
      'ms': at.inMilliseconds,
      'text': t,
      'mode': mode,
      'color': color,
      'at': DateTime.now().millisecondsSinceEpoch,
    });
    // 单集最多留 200 条，避免无限增长
    if (list.length > 200) list.removeRange(0, list.length - 200);
    all[k] = list;
    await _writeAll(all);
    _cache.remove(k);
  }

  Future<Map<String, dynamic>> _readAll() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_key);
      if (raw == null || raw.isEmpty) return {};
      final v = jsonDecode(raw);
      return v is Map ? Map<String, dynamic>.from(v) : {};
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeAll(Map<String, dynamic> all) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_key, jsonEncode(all));
    } catch (_) {}
  }
}

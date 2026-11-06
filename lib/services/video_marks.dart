import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一部剧（videoId）的「跳过片头片尾」时长，单位秒；0 = 未设置 = 完全不跳。
///
/// - [introSeconds] 片头：开播 / 切集时播放位置还在前 N 秒内
///   （position < introSeconds）→ seek 到第 N 秒，即跳过前 N 秒，每集一次。
/// - [outroSeconds] 片尾：距结尾不足 N 秒（duration - position ≤ outroSeconds）
///   → seek 到本集结尾，交给播完流程自动下一集 / 结束，每集一次。
///
/// 旧版按「标记位置」存的 `introEnd` / `outroStart` 语义不同，不迁移，
/// 存储直接换到新 key（见 [VideoMarks.storageKey]）忽略掉。
class VideoMark {
  const VideoMark({this.introSeconds = 0, this.outroSeconds = 0});

  final int introSeconds;
  final int outroSeconds;

  bool get hasIntro => introSeconds > 0;
  bool get hasOutro => outroSeconds > 0;

  /// 两项都是 0 = 这部剧没设置，任何位置都不跳。
  bool get isEmpty => !hasIntro && !hasOutro;

  @override
  bool operator ==(Object other) =>
      other is VideoMark &&
      other.introSeconds == introSeconds &&
      other.outroSeconds == outroSeconds;

  @override
  int get hashCode => Object.hash(introSeconds, outroSeconds);
}

/// 片头 / 片尾时长存储：`{videoId: {introSeconds, outroSeconds}}`，一部剧一份，
/// 全部落在 SharedPreferences（key [storageKey]）。没设置 = 什么都不跳。
class VideoMarks {
  VideoMarks._();

  /// 输入上限：10:00。片头 / 片尾都按这个范围校验与裁剪。
  static const int maxSeconds = 600;

  /// v1 存的是「标记位置」（introEnd / outroStart），语义不同：
  /// 换成 v2 后旧数据既不读也不写，等于直接忽略。
  static const String storageKey = 'fx_video_marks_v2';

  /// 写串行队列：设置 / 清除可能连点，后写不能覆盖先写。
  static Future<void> _pending = Future<void>.value();

  static Future<void> _enqueue(Future<void> Function() action) {
    final next = _pending.then<void>((_) => action()).catchError((Object e) {
      debugPrint('VideoMarks: write failed: $e');
    });
    _pending = next;
    return next;
  }

  static Future<Map<String, dynamic>> _readAll() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(storageKey);
      if (raw == null || raw.isEmpty) return <String, dynamic>{};
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (e) {
      debugPrint('VideoMarks: read failed: $e');
    }
    return <String, dynamic>{};
  }

  static VideoMark _parse(dynamic raw) {
    if (raw is! Map) return const VideoMark();
    final map = Map<String, dynamic>.from(raw);
    return VideoMark(
      introSeconds: _seconds(map['introSeconds']),
      outroSeconds: _seconds(map['outroSeconds']),
    );
  }

  /// 读出来的秒数裁进 0–[maxSeconds]：负数当 0（未设置），
  /// 超上限当上限，null / 字符串等没法用的值一律 0。
  static int _seconds(dynamic value) {
    final n = value is int
        ? value
        : value is double
            ? value.round()
            : null;
    if (n == null || n <= 0) return 0;
    return n > maxSeconds ? maxSeconds : n;
  }

  /// 读取某部剧的时长；videoId 为空返回空标记。读不入队：它只读不写，
  /// 不会覆盖正在排队的写。
  static Future<VideoMark> load(String videoId) async {
    if (videoId.isEmpty) return const VideoMark();
    final all = await _readAll();
    return _parse(all[videoId]);
  }

  /// 写入某部剧的片头 / 片尾时长（整体覆盖两项，值会裁到 0–10:00）。
  static Future<void> save(String videoId, VideoMark mark) async {
    if (videoId.isEmpty) return;
    final intro = _seconds(mark.introSeconds);
    final outro = _seconds(mark.outroSeconds);
    await _enqueue(() async {
      final all = await _readAll();
      all[videoId] = <String, dynamic>{
        'introSeconds': intro,
        'outroSeconds': outro,
      };
      final sp = await SharedPreferences.getInstance();
      await sp.setString(storageKey, jsonEncode(all));
    });
  }

  /// 清除本剧设置（片头 / 片尾一起清）。
  static Future<void> clear(String videoId) async {
    if (videoId.isEmpty) return;
    await _enqueue(() async {
      final all = await _readAll();
      if (!all.containsKey(videoId)) return;
      all.remove(videoId);
      final sp = await SharedPreferences.getInstance();
      await sp.setString(storageKey, jsonEncode(all));
    });
  }
}

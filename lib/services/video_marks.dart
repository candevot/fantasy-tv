import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一部剧（videoId）的片头 / 片尾标记，单位秒。
///
/// - [introEnd] 片头结束：播放位置进入 `[introEnd, introEnd + 5s)` 时
///   跳回 [introEnd]，每集只触发一次。
/// - [outroStart] 片尾开始：播放位置到达 [outroStart] 后跳到本集结尾，
///   每集只触发一次；随后按「自动下一集」正常切集或结束。
class VideoMark {
  const VideoMark({this.introEnd, this.outroStart});

  final int? introEnd;
  final int? outroStart;

  bool get hasIntro => introEnd != null;
  bool get hasOutro => outroStart != null;
  bool get isEmpty => !hasIntro && !hasOutro;

  @override
  bool operator ==(Object other) =>
      other is VideoMark &&
      other.introEnd == introEnd &&
      other.outroStart == outroStart;

  @override
  int get hashCode => Object.hash(introEnd, outroStart);
}

/// 片头 / 片尾标记存储：`{videoId: {introEnd, outroStart}}`，一部剧一份，
/// 全部落在 SharedPreferences（key [storageKey]）。没有标记 = 什么都不跳。
class VideoMarks {
  VideoMarks._();

  static const String storageKey = 'fx_video_marks_v1';

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
      introEnd: _asSeconds(map['introEnd']),
      outroStart: _asSeconds(map['outroStart']),
    );
  }

  static int? _asSeconds(dynamic value) {
    if (value is int) return value < 0 ? null : value;
    if (value is double) return value < 0 ? null : value.round();
    return null;
  }

  /// 读取某部剧的标记；videoId 为空返回空标记。读不入队：它只读不写，
  /// 不会覆盖正在排队的写。
  static Future<VideoMark> load(String videoId) async {
    if (videoId.isEmpty) return const VideoMark();
    final all = await _readAll();
    return _parse(all[videoId]);
  }

  /// 写入某部剧的标记：传 null 表示清除该项标记。
  static Future<void> save(
    String videoId, {
    int? introEnd,
    int? outroStart,
  }) async {
    if (videoId.isEmpty) return;
    await _enqueue(() async {
      final all = await _readAll();
      all[videoId] = <String, dynamic>{
        if (introEnd != null) 'introEnd': introEnd,
        if (outroStart != null) 'outroStart': outroStart,
      };
      final sp = await SharedPreferences.getInstance();
      await sp.setString(storageKey, jsonEncode(all));
    });
  }

  /// 清除本剧标记（片头 / 片尾一起清）。
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

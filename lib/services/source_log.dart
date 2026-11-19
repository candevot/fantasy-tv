import 'package:flutter/foundation.dart';

/// 片源链路日志前缀（源级超时 / 结局 / 失败原因）。
///
/// 为什么要有它：源的状态全在**远端站点**，出问题时用户只能看到「搜不到」，
/// 具体是「没进计划 / 站点报错 / 超时 / 回来了但被判无关」全看不见。
///
/// 真机排查：`adb logcat | grep -E 'SourceSearch|SourceDetail'` 一条命令看全链路：
///
/// ```
/// [SourceSearch] source=幻想4K key=济公传 → 3 条 耗时 897ms
/// [SourceSearch] source=幻想蓝光 key=济公传 结局=empty 耗时 1204ms
/// [SourceSearch] source=幻想 key=济公传 结局=timeout（站点级 12s） 耗时=12003ms
/// ```
///
/// release 包里也保留：[debugPrint] 不会被裁掉，只是频率被限流。
const String fxSourceSearchTag = 'SourceSearch';
const String fxSourceDetailTag = 'SourceDetail';

/// 写一条片源链路日志。[tag] 默认 [fxSourceSearchTag]。
void fxSourceLog(String body, {String tag = fxSourceSearchTag}) {
  debugPrint('[$tag] $body');
}

/// 把一段原文截断成日志里能看的样子（不要整份 JSON 灌进 logcat）。
///
/// 截断处保留长度信息，看日志的人知道「后面还有多少没打出来」。
String fxSourceClip(String raw, {int max = 320}) {
  final text = raw.trim();
  if (text.length <= max) return text;
  return '${text.substring(0, max)}…(+${text.length - max})';
}

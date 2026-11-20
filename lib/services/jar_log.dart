import 'package:flutter/foundation.dart';

/// jar 源（肥猫那批 `spider.jar` 源）整条链路的日志前缀。
///
/// 为什么要有它（JAR_LOG 2026-11-15）：这类源的状态全在 **jar 内部**，
/// 出问题时用户只能看到「搜不到」，具体是
/// 「没进计划 / 类找不到 / 抛异常 / 超时 / 回来了但被判无关」全看不见，
/// 之前`_searchOne` 把异常吞成空列表，等于把唯一的线索也丢了。
///
/// 真机排查：`adb logcat | grep -E 'JarSearch|JarDetail|JarPlay'` 一条命令看全链路：
///
/// ```
/// [JarSearch] source=咕噜 key=济公传 quick=false → 3 条 耗时 897ms
/// [JarSearch] source=剧圈 key=济公传 quick=true → 0 条 (empty) 耗时 1204ms
/// [JarSearch] gate source=哔哩合集 dropped=2 kept=3 reason=unrelated
/// [JarSearch] summary key=济公传 源=41 命中=5 空=30 超时=4 错=2 耗时=18.3s
/// [JarDetail] api=csp_Gulu vodId=418792 line=… bytes=2048 lines=2
/// [JarPlay] api=csp_Gulu vodId=418792 line=咕噜 ep=1 parse=0 url=https://…
/// ```
///
/// release 包里也保留：[debugPrint] 不会被裁掉，只是频率被限流，
/// 一轮搜索几十条日志完全够用。
const String fxJarSearchTag = 'JarSearch';
const String fxJarDetailTag = 'JarDetail';
const String fxJarPlayTag = 'JarPlay';

/// 写一条 jar 链路日志。[tag] 默认 [fxJarSearchTag]。
void fxJarLog(String body, {String tag = fxJarSearchTag}) {
  debugPrint('[$tag] $body');
}

/// 把一段原文截断成日志里能看的样子（不要整份 JSON 灌进 logcat）。
///
/// 截断处保留长度信息，看日志的人知道「后面还有多少没打出来」。
String fxJarClip(String raw, {int max = 320}) {
  final text = raw.trim();
  if (text.length <= max) return text;
  return '${text.substring(0, max)}…(+${text.length - max})';
}

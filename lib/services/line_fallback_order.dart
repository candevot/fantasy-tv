/// 自动换线路的**候选顺序**（GROUP_ORDER 2026-11-21，用户明确要求）。
///
/// 用户口径（原话）：
/// ```
/// 播放不了 → 先在当前主线路（大类）里换下一条子线路
/// 当前大类的子线路全播不了 → 才切到另一个主线路（另一个大类）
/// ```
///
/// 之前详情页 `_switchNextLine` 和播放器 `autoTryAllLines` 都是拿**扁平线路
/// 列表**按 `(index + step) % length` 轮 —— 而扁平列表是被
/// `fxOwnLinesFirst` / `LineHealth.rankLines` / jar 合并**重排过**的，
/// 于是会出现「幻想第 1 条 → 咕噜第 1 条 → 幻想第 2 条」这种跨大类乱跳：
/// 用户刚在幻想大类里点了一条，失败后却被丢到咕噜大类，看着像随机。
///
/// 现在统一走这里：候选顺序 = **当前大类的其它子线路（按显示顺序）**，
/// 当前大类全试完才进**下一个大类**（大类之间按第一行的显示顺序，环形）。
/// 详情页 / 播放器 / 全屏都从这一份取顺序，口径只有一处。
///
/// 纯函数，不 import 任何 UI，`test/line_fallback_order_test.dart` 逐条钉住。
library;

import '../models.dart';
import 'jar_sources.dart';
import 'line_session.dart' show fxLineAllPrunedText;

/// 全部大类都试过仍不可播时的提示（用户定稿的措辞）。
///
/// 和「咕噜系线路被剔除」共用同一句话：用户看到的语境是一个 —— 这部片
/// 现在没线路能播。两边各写一份字面量迟早会漂，这里直接引用。
const String fxLineNoUsableText = fxLineAllPrunedText;

/// 一个线路 id 属于哪个大类（`own` = 幻想；找不到返回空串）。
String fxFallbackGroupKeyOf(List<LineInfo> lines, String lineId) {
  final id = lineId.trim();
  if (id.isEmpty) return '';
  for (final group in fxLineGroups(lines)) {
    for (final line in group.lines) {
      if (line.id == id) return group.key;
    }
  }
  return '';
}

/// 自动换线路的候选顺序（**大类优先**）。
///
/// 入参 [lines] 是详情页 / 播放器手上的那份线路列表（顺序 = 显示顺序）；
/// [currentLineId] 是当前正在播的线路，它**不会**出现在结果里；
/// [skip] 是已经证明不可播 / 本次已经试过的线路 id。
///
/// 返回：
/// ```
/// 当前大类的其它子线路（按显示顺序）
///   → 下一个大类的全部子线路（按该大类的显示顺序）
///   → …（大类环形，最多转完一圈）
/// ```
/// 空列表 = 没有下一条可换的线路（外面据此给 [fxLineNoUsableText]）。
///
/// `currentLineId` 为空（不知道当前在哪条，例如「重试全部线路」）时，
/// 从第一个大类开始按显示顺序排 —— 也就是整条链的自然顺序。
List<LineInfo> fxFallbackLineOrder({
  required List<LineInfo> lines,
  String currentLineId = '',
  Set<String> skip = const <String>{},
}) {
  final groups = fxLineGroups(lines);
  if (groups.isEmpty) return const <LineInfo>[];
  final currentId = currentLineId.trim();

  // 当前大类在第一行里的位置：从它开始，转一圈覆盖所有大类。
  var start = 0;
  if (currentId.isNotEmpty) {
    for (var i = 0; i < groups.length; i++) {
      if (groups[i].lines.any((line) => line.id == currentId)) {
        start = i;
        break;
      }
    }
  }

  final out = <LineInfo>[];
  final seen = <String>{};
  for (var step = 0; step < groups.length; step++) {
    final group = groups[(start + step) % groups.length];
    for (final line in group.lines) {
      final id = line.id.trim();
      if (id.isEmpty) continue;
      if (id == currentId) continue;
      if (skip.contains(id)) continue;
      if (!seen.add(id)) continue;
      out.add(line);
    }
  }
  return out;
}

/// 下一条要自动切过去的线路；没有可换的返回 null。
LineInfo? fxFallbackNextLine({
  required List<LineInfo> lines,
  String currentLineId = '',
  Set<String> skip = const <String>{},
}) {
  final order = fxFallbackLineOrder(
    lines: lines,
    currentLineId: currentLineId,
    skip: skip,
  );
  return order.isEmpty ? null : order.first;
}

/// 在已经排好的候选序列里，**每个大类内部**把服务端标 `degraded` 的沉后。
///
/// 为什么不是全局按 `degraded` 排：当前大类只剩一条 degraded 线路时，全局
/// 排序会把它挪到另一个大类后面 —— 又变成用户抱怨的「跨大类乱跳」。
/// 这里只在大类内部调顺序，大类之间的先后（[fxFallbackLineOrder] 给的）不动。
List<LineInfo> fxSortDegradedWithinGroups(List<LineInfo> ordered) {
  if (ordered.length < 2) return List<LineInfo>.of(ordered);
  final out = <LineInfo>[];
  var run = <LineInfo>[];
  void flush() {
    if (run.isEmpty) return;
    final fresh = <LineInfo>[];
    final degraded = <LineInfo>[];
    for (final line in run) {
      (line.degraded ? degraded : fresh).add(line);
    }
    out
      ..addAll(fresh)
      ..addAll(degraded);
    run = <LineInfo>[];
  }

  for (final line in ordered) {
    if (run.isNotEmpty &&
        fxLineGroupKeyOf(run.first) != fxLineGroupKeyOf(line)) {
      flush();
    }
    run.add(line);
  }
  flush();
  return out;
}

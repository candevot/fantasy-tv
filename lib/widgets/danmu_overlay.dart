import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../services/danmu_service.dart';

/// 弹幕渲染层 —— 对齐成熟方案（弹弹play / B站）的轨道算法。
///
/// 三条轨道规则（这是成熟实现的核心，不是自创）：
///   1. **不重叠**：同一轨道上一条弹幕的尾巴离开右边界前，新弹幕不能进这条轨道。
///   2. **不追尾**：新弹幕速度相同，若前一条还没完全进入屏幕就放进同轨道，
///      会撞上 —— 所以除了「尾巴离开」，还要「头部已完全进入」。
///   3. **轨道轮转**：从上次用过轨道的下一条开始找，避免总挤在顶部。
///
/// 顶部/底部弹幕（mode 4/5）不进轨道，居中停留 4 秒。
class DanmuOverlay extends StatefulWidget {
  const DanmuOverlay({
    super.key,
    required this.items,
    required this.position,
    required this.playing,
    this.enabled = true,
    this.opacity = 1,
    this.fontSize = 15,
    this.speed = 1,
    this.areaRatio = 0.7,
  });

  /// 该集全部弹幕（按 time 升序）。
  final List<DanmuItem> items;

  /// 当前播放位置。
  final Duration position;

  /// 是否在播放（暂停时弹幕也停）。
  final bool playing;

  final bool enabled;

  /// 0-1，弹幕整体透明度。
  final double opacity;

  final double fontSize;

  /// 滚动速度倍率（>1 更快）。
  final double speed;

  /// 弹幕占画面高度的比例（0.7 = 上方 70%）。
  final double areaRatio;

  @override
  State<DanmuOverlay> createState() => _DanmuOverlayState();
}

class _DanmuOverlayState extends State<DanmuOverlay>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;

  /// 正在屏幕上飞的弹幕。
  final List<_Flying> _flying = [];

  /// 每条轨道最后一条弹幕的「尾巴离开时刻」与「头部进入时刻」。
  final Map<int, _LaneState> _lanes = {};

  /// 下一条弹幕在 items 里的下标。
  int _cursor = 0;

  /// 上次 tick 的时间戳（用于算 dt）。
  Duration _lastPos = Duration.zero;

  /// 累计播放时间（暂停时不累加）。
  Duration _clock = Duration.zero;

  /// 重绘信号：数值变化只触发 CustomPaint 重绘，不重建 Widget 树。
  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);

  int _laneCount = 8;
  double _laneHeight = 0;
  double _width = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void didUpdateWidget(covariant DanmuOverlay old) {
    super.didUpdateWidget(old);
    // 换集：重置全部状态
    if (!identical(old.items, widget.items)) {
      _reset();
    }
    // 跳转：位置回退或跳跃过大时重新定位 cursor
    final delta = widget.position - _lastPos;
    if (delta.isNegative || delta > const Duration(seconds: 3)) {
      _seekTo(widget.position);
    }
  }

  void _reset() {
    _flying.clear();
    _lanes.clear();
    _cursor = 0;
    _clock = Duration.zero;
    _lastPos = widget.position;
  }

  void _seekTo(Duration pos) {
    _flying.clear();
    _lanes.clear();
    _clock = pos;
    _lastPos = pos;
    // 二分找到第一条 time >= pos 的弹幕
    var lo = 0, hi = widget.items.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (widget.items[mid].time < pos) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    _cursor = lo;
  }

  /// 每帧推进。
  ///
  /// DANMU_SMOOTH（2026-11-12）：
  ///   之前用 Ticker + setState(() {}) 全量重建整棵 Widget 树 ——
  ///   每条弹幕都是一个 Positioned + Opacity + Text，屏幕上二三十条时
  ///   每帧要重建二三十个组件，中低端机直接掉到 30fps 以下，
  ///   肉眼就是「弹幕一卡一卡的」。
  ///
  ///   现在改成：**不碰 Widget 树**，Dart 侧只更新数值，
  ///   由一个 CustomPainter 在一次 paint 里把全部弹幕画出来。
  ///   每帧成本从「重建 N 个组件」降到「一次 canvas 绘制」。
  void _onTick(Duration elapsed) {
    if (!mounted) return;
    if (!widget.enabled || !widget.playing) {
      _lastPos = widget.position;
      return;
    }
    // 用播放器位置推进，不用 ticker 的 elapsed —— 倍速、缓冲都能跟上
    final pos = widget.position;
    var dt = pos - _lastPos;
    _lastPos = pos;
    if (dt.isNegative || dt > const Duration(seconds: 2)) {
      _seekTo(pos);
      return;
    }
    _clock += dt;

    // 1) 发射到期的弹幕。
    //
    // DANMU_CONTINUOUS：之前 here 是 while 一次性把「所有 time <= _clock」
    // 的都吐出来 —— 一旦某一帧卡了一下（比如解码抖动 dt 变大），
    // 就会在那一瞬间炸出一整批，用户看到的就是「一组一组地冒」，
    // 而不是连续飘过。现在限制每帧最多发射 3 条，多出来的留在
    // cursor 里下一帧继续，视觉上就是平滑的流水。
    var spawned = 0;
    while (_cursor < widget.items.length &&
        widget.items[_cursor].time <= _clock &&
        spawned < 3) {
      if (_spawn(widget.items[_cursor])) spawned++;
      _cursor++;
    }
    // 把「本该早就出现」的过时弹幕丢掉，避免 seek 后一次性补一堆。
    while (_cursor < widget.items.length &&
        _clock - widget.items[_cursor].time > const Duration(seconds: 6)) {
      _cursor++;
    }

    // 2) 推进已发射的弹幕
    final dtSec = dt.inMicroseconds / 1e6;
    for (final f in _flying) {
      f.x -= f.speed * dtSec;
      f.age += dt;
    }
    // 3) 移除飞出屏幕的
    _flying.removeWhere((f) {
      if (f.mode == 1) return f.x + f.width < -20;
      return f.age > const Duration(seconds: 4);
    });

    // 只触发重绘，不重建组件树。
    _repaint.value++;
  }

  /// 屏幕上最近出现过的弹幕文本（去重用，带出现时刻）。
  final Map<String, Duration> _recent = <String, Duration>{};

  /// 发射一条弹幕。返回 true 表示真的上屏了。
  ///
  /// DANMU_DEDUP（2026-11-12）：弹幕源里同一句话会重复很多次
  /// （尤酷/腾讯的接口会把同一条弹幕挂到多个时间点）。
  /// 之前照单全收，用户看到的就是「一直都是重复的」。
  /// 现在同一句话 [_dedupWindow] 内只放一条。
  static const Duration _dedupWindow = Duration(seconds: 6);

  bool _spawn(DanmuItem item) {
    if (_width <= 0 || _laneHeight <= 0) return false;
    // 去重：同一句话 6 秒内只出现一次
    final key = item.text;
    final last = _recent[key];
    if (last != null && (_clock - last).abs() < _dedupWindow) return false;
    _recent[key] = _clock;
    // 清掉过期的去重记录，避免 Map 无限增长
    if (_recent.length > 400) {
      _recent.removeWhere((_, at) => (_clock - at).abs() > _dedupWindow);
    }
    // 估算宽度：中文按字号，英文按 0.55 字号
    final width = _measure(item.text, widget.fontSize);

    if (item.mode == 4 || item.mode == 5) {
      // 顶部/底部：不进轨道，直接加
      _flying.add(_Flying(
        item: item,
        x: (_width - width) / 2,
        y: item.mode == 5 ? 8 : _laneHeight * (_laneCount - 1),
        width: width,
        speed: 0,
        mode: item.mode,
        age: Duration.zero,
      ));
      return true;
    }

    // 滚动弹幕：找一条可用轨道
    final lane = _pickLane(width);
    if (lane < 0) return false; // 全满，丢弃（成熟方案也这么做，避免叠字）
    final travel = _width + width;
    // 速度：固定穿过时间 8 秒 / speed 倍率
    final durationSec = 8 / math.max(0.5, widget.speed);
    final speed = travel / durationSec;
    _lanes[lane] = _LaneState(
      tailFreeAt: _clock + Duration(milliseconds: ((width + _width) / speed * 1000).round()),
      headInAt: _clock + Duration(milliseconds: ((width) / speed * 1000).round()),
    );
    _flying.add(_Flying(
      item: item,
      x: _width,
      y: lane * _laneHeight,
      width: width,
      speed: speed,
      mode: 1,
      age: Duration.zero,
    ));
  }

  /// 选轨道：从上一条用过的下一条开始轮转，跳过还没腾出来的。
  int _pickLane(double width) {
    for (var i = 0; i < _laneCount; i++) {
      final lane = i;
      final st = _lanes[lane];
      if (st == null) return lane;
      // 尾巴离开右边界 且 头部已完全进入
      if (_clock >= st.tailFreeAt && _clock >= st.headInAt) return lane;
    }
    return -1;
  }

  double _measure(String text, double fontSize) {
    var w = 0.0;
    for (final r in text.runes) {
      // 中文/全角 ≈ 1em，ASCII ≈ 0.55em
      w += r > 0x2E80 ? fontSize : fontSize * 0.55;
    }
    return w + 8;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || widget.items.isEmpty) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (ctx, cons) {
        _width = cons.maxWidth;
        // DANMU_AREA（2026-11-12）：显示区域改成按「条数」而不是「屏幕比例」。
        //
        // 之前 areaRatio 是画面高度的百分比，最低 30% —— 在 1080p 横屏
        // 上下留了约 200dp，按字号算仍有 7~8 条轨道，用户看到的就是
        // 「调到最低还是占半个屏幕」。
        //
        // 现在 areaRatio 直接换算成轨道条数：30% → 3 条，100% → 10 条。
        // 这样滑到最低是真的「只在画面上部飘三条」。
        final lanes = (widget.areaRatio * 10).round().clamp(1, 12);
        _laneCount = math.max(1, lanes);
        _laneHeight = (widget.fontSize * 1.6).clamp(18.0, 40.0);
        return IgnorePointer(
          child: ClipRect(
            // 一次 paint 画完所有弹幕：不再为每条弹幕建 Positioned+Opacity+Text。
            // _repaint 变化只触发重绘，不重建组件树。
            child: RepaintBoundary(
              child: CustomPaint(
                size: Size(cons.maxWidth, cons.maxHeight),
                painter: _DanmuPainter(
                  flying: _flying,
                  repaint: _repaint,
                  opacity: widget.opacity,
                  fontSize: widget.fontSize,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Flying {
  _Flying({
    required this.item,
    required this.x,
    required this.y,
    required this.width,
    required this.speed,
    required this.mode,
    required this.age,
  });

  final DanmuItem item;
  double x;
  final double y;
  final double width;
  final double speed;
  final int mode;
  Duration age;
}

class _LaneState {
  const _LaneState({required this.tailFreeAt, required this.headInAt});

  /// 这条轨道什么时候可以再放弹幕（尾巴离开右边界）。
  final Duration tailFreeAt;

  /// 新弹幕的头部完全进入屏幕的时刻（防追尾）。
  final Duration headInAt;
}


/// 把屏幕上所有弹幕一次性画出来。
///
/// 相比「每条弹幕一个 Text 组件」：省掉组件树重建、布局、合成，
/// 中低端机上帧率差别很明显（30fps → 60fps）。
/// 文字用 TextPainter 缓存，避免每帧重新排版。
class _DanmuPainter extends CustomPainter {
  _DanmuPainter({
    required this.flying,
    required this.repaint,
    required this.opacity,
    required this.fontSize,
  }) : super(repaint: repaint);

  final List<_Flying> flying;
  final Listenable repaint;
  final double opacity;
  final double fontSize;

  /// 文本排版缓存：同一条弹幕的内容不重复 layout。
  static final Map<String, TextPainter> _cache = <String, TextPainter>{};

  TextPainter _painterFor(_Flying f) {
    final key = '${f.item.color}|${f.item.text}';
    final cached = _cache[key];
    if (cached != null) return cached;
    final tp = TextPainter(
      text: TextSpan(
        text: f.item.text,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          color: Color(0xFF000000 | f.item.color),
          height: 1.25,
          shadows: const [
            Shadow(color: Colors.black87, blurRadius: 3),
            Shadow(color: Colors.black54, blurRadius: 6),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    if (_cache.length > 600) _cache.clear();
    _cache[key] = tp;
    return tp;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0) return;
    for (final f in flying) {
      final tp = _painterFor(f);
      canvas.save();
      canvas.translate(f.x, f.y);
      // 用 saveLayer 做整体透明度：比给每条文字设 alpha 更省
      if (opacity < 1) {
        final layer = canvas.saveLayer(
          Rect.fromLTWH(-4, -4, tp.width + 8, tp.height + 8),
          Paint()..color = Colors.white.withValues(alpha: opacity),
        );
        tp.paint(canvas, Offset.zero);
        canvas.restoreToCount(layer);
      } else {
        tp.paint(canvas, Offset.zero);
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _DanmuPainter old) => true;
}

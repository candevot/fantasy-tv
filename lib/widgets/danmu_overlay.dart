import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../services/danmu_service.dart';

/// 弹幕渲染层 —— 对齐成熟方案（弹弹play / B站）的轨道算法。
///
/// 四条轨道规则（这是成熟实现的核心，不是自创）：
///   1. **不重叠**：同一轨道上一条弹幕的尾巴离开右边界前，新弹幕不能进这条轨道。
///   2. **不追尾**：新弹幕速度相同，若前一条还没完全进入屏幕就放进同轨道，
///      会撞上 —— 所以除了「尾巴离开」，还要「头部已完全进入」。
///   3. **同轨最小间隔**：同一条轨道两条弹幕的入场时刻至少隔
///      [_minLaneGap]（250ms），避免同一簇数据在同一帧挤进同一条轨道。
///   4. **轨道轮转**：从上次用过轨道的下一条开始找，避免总挤在顶部。
///
/// DANMU_POSITION_DRIVEN（2026-11-14，按逆向报告 §10 改动 5）：
///   之前时钟是 `_clock += 帧间隔` 累加出来的，位置只用来「纠偏」；
///   现在把播放器 `position` 当成唯一真值，两帧之间只做有上限的外推
///   （[_maxDeadReckon]）。谁该上屏由 position 决定，不由「数据到达」决定，
///   所以一条弹幕不会因为某个回调晚到就整簇爆发。
///
/// 顶部/底部弹幕（mode 4/5）不进轨道，居中停留 4 秒。
class DanmuOverlay extends StatefulWidget {
  const DanmuOverlay({
    super.key,
    required this.items,
    required this.position,
    this.positionListenable,
    required this.playing,
    this.enabled = true,
    this.opacity = 1,
    this.fontSize = 15,
    this.speed = 1,
    this.areaRatio = 0.7,
    this.massive = false,
  });

  /// 该集全部弹幕（按 time 升序）。
  final List<DanmuItem> items;

  /// 当前播放位置。
  final Duration position;

  /// 高频位置通道（可选）。
  ///
  /// 传了就用它：每帧直接从 ValueListenable 读最新值，
  /// 不再等父组件 setState 传新的 position 进来。
  /// 这样即使外层整棵树不重建，弹幕也能跟着播放器流畅滚动。
  final ValueListenable<Duration>? positionListenable;

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

  /// 海量模式：轨道数从 8 提到 14（对应逆向报告里的 massive_mode）。
  ///
  /// 显示区域拉到 100% 时也会自动进海量模式，见 [_DanmuOverlayState._baseTracks]。
  final bool massive;

  @override
  State<DanmuOverlay> createState() => _DanmuOverlayState();
}

class _DanmuOverlayState extends State<DanmuOverlay>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;

  /// 正在屏幕上飞的弹幕。
  final List<_Flying> _flying = [];

  /// 每条轨道最近一条弹幕的占用状态。
  final Map<int, _LaneState> _lanes = {};

  /// 下一条弹幕在 items 里的下标。
  int _cursor = 0;

  /// 上一次发射时用到的轨道（轨道轮转的起点）。
  int _nextLane = 0;

  /// 上一帧的播放器位置（检测 seek）。
  Duration _lastPos = Duration.zero;

  /// 上一帧的 ticker 时间，用来算真实帧间隔。
  Duration _lastElapsed = Duration.zero;

  /// 位置锚点：最近一次读到的播放器位置，以及读到它那一刻的 ticker 时间。
  Duration _anchorPos = Duration.zero;
  Duration _anchorElapsed = Duration.zero;

  /// 由位置推导出来的渲染时钟（弹幕时间轴的当前时刻）。
  Duration _clock = Duration.zero;

  /// 两帧之间最多外推多久。
  ///
  /// 位置回流的频率不稳定（快时 50ms，慢时 500ms）。外推给了
  /// [_maxDeadReckon] 的上限：位置一旦停更，弹幕不会一直往前飘，
  /// 而是停在原地等下一个真实位置，避免「画面停了弹幕还在跑」。
  static const Duration _maxDeadReckon = Duration(milliseconds: 320);

  /// 播放器位置单帧跳变超过这个值就当 seek 处理。
  static const Duration _seekJump = Duration(seconds: 3);

  /// 滚动弹幕横穿屏幕的固定时长（对应 danmu.duration，8s）。
  static const Duration _scrollDuration = Duration(seconds: 8);

  /// 同一条轨道两条弹幕的最小入场间隔。
  static const Duration _minLaneGap = Duration(milliseconds: 250);

  /// 重绘信号：数值变化只触发 CustomPaint 重绘，不重建 Widget 树。
  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);

  /// 普通模式的轨道数。
  static const int _normalTracks = 8;

  /// 海量模式的轨道数。
  static const int _massiveTracks = 14;

  int _laneCount = _normalTracks;
  double _laneHeight = 0;
  double _width = 0;

  /// 弹幕区的上下安全区（尽量避开顶部控件条 / 底部控制栏）。
  double _areaTop = 0;
  double _areaHeight = 0;

  /// 轨道数：海量模式（或显示区域拉满）14 条，否则 8 条，再按显示区域比例收缩。
  int _baseTracks() {
    if (widget.massive || widget.areaRatio >= 0.95) return _massiveTracks;
    return _normalTracks;
  }

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
    if (delta.isNegative || delta > _seekJump) {
      _seekTo(widget.position);
    }
  }

  void _reset() {
    _flying.clear();
    _lanes.clear();
    _cursor = 0;
    _nextLane = 0;
    _clock = widget.position;
    _lastPos = widget.position;
    _anchorPos = widget.position;
  }

  void _seekTo(Duration pos) {
    _flying.clear();
    _lanes.clear();
    _nextLane = 0;
    _clock = pos;
    _lastPos = pos;
    _anchorPos = pos;
    _anchorElapsed = _lastElapsed;
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

  /// 位置驱动的渲染时钟。
  ///
  /// 返回「这一刻弹幕时间轴应该在的位置」：
  ///   · 播放器位置更新了 → 直接采信它，并把外推锚点挪到当前帧；
  ///   · 位置还没更新 → 在锚点上按帧间隔外推，最多 [_maxDeadReckon]。
  Duration _clockNow(Duration elapsed, Duration pos) {
    if (pos != _anchorPos) {
      _anchorPos = pos;
      _anchorElapsed = elapsed;
      return pos;
    }
    final gap = elapsed - _anchorElapsed;
    if (gap.isNegative) return _anchorPos;
    return _anchorPos + (gap > _maxDeadReckon ? _maxDeadReckon : gap);
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
    final pos = widget.positionListenable?.value ?? widget.position;
    // 暂停 / 关闭：时钟跟住播放器，恢复时不会一次补一大段。
    if (!widget.enabled || !widget.playing) {
      _lastElapsed = elapsed;
      _lastPos = pos;
      _clock = pos;
      _anchorPos = pos;
      _anchorElapsed = elapsed;
      return;
    }
    // seek：位置回退或跳跃过大，重建时钟与游标。
    final posDelta = pos - _lastPos;
    _lastPos = pos;
    if (posDelta.isNegative || posDelta > _seekJump) {
      _lastElapsed = elapsed;
      _seekTo(pos);
      return;
    }

    final frameDt = elapsed - _lastElapsed;
    _lastElapsed = elapsed;

    // 1) 时钟：以播放器位置为准，帧间只做有上限的外推。
    final clock = _clockNow(elapsed, pos);
    var dt = clock - _clock;
    if (dt.isNegative) dt = Duration.zero;
    // 单帧推进上限：掉帧 / 后台回来时别让整屏弹幕瞬移。
    if (dt > const Duration(milliseconds: 200)) {
      dt = const Duration(milliseconds: 200);
    }
    _clock = clock;

    // 2) 发射到期的弹幕。
    //
    // 谁该上屏只由 [_clock]（播放器位置）决定；轨道满了 [_spawn] 返回 false
    // 直接丢弃（成熟方案也这么做，避免叠字）。同一簇 20 条会被 8 条轨道
    // 按 250ms 间隔摊开，视觉上是连续涌入而不是一簇爆发。
    while (_cursor < widget.items.length &&
        widget.items[_cursor].time <= _clock) {
      _spawn(widget.items[_cursor]);
      _cursor++;
    }
    // 把「本该早就出现」的过时弹幕丢掉，避免 seek 后一次性补一堆。
    while (_cursor < widget.items.length &&
        _clock - widget.items[_cursor].time > const Duration(seconds: 6)) {
      _cursor++;
    }

    // 3) 推进已发射的弹幕
    final dtSec = dt.inMicroseconds / 1e6;
    if (dtSec > 0) {
      for (final f in _flying) {
        f.x -= f.speed * dtSec;
        f.age += dt;
      }
    }
    // 4) 移除飞出屏幕的
    _flying.removeWhere((f) {
      if (f.mode == 1) return f.x + f.width < -20;
      return f.age > const Duration(seconds: 4);
    });

    // 只触发重绘，不重建组件树。
    if (frameDt > Duration.zero) _repaint.value++;
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
    if (_width <= 0 || _laneHeight <= 0 || _laneCount <= 0) return false;
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
      // 顶部/底部：不进轨道，直接加（底部贴着安全区下沿）
      _flying.add(_Flying(
        item: item,
        x: (_width - width) / 2,
        y: item.mode == 5
            ? _areaTop + _areaHeight - _laneHeight
            : _areaTop,
        width: width,
        speed: 0,
        mode: item.mode,
        age: Duration.zero,
      ));
      return true;
    }

    // 滚动弹幕：找一条可用轨道
    final lane = _pickLane();
    if (lane < 0) return false; // 全满，丢弃（成熟方案也这么做，避免叠字）
    final travel = _width + width;
    // 速度：固定穿过时长 [_scrollDuration] / speed 倍率
    final durationSec = _scrollDuration.inMilliseconds /
        1000 /
        math.max(0.5, widget.speed);
    final speed = travel / durationSec;
    _lanes[lane] = _LaneState(
      enterAt: _clock + _minLaneGap,
      tailFreeAt:
          _clock + Duration(milliseconds: ((width + _width) / speed * 1000).round()),
      headInAt: _clock + Duration(milliseconds: (width / speed * 1000).round()),
    );
    _nextLane = (lane + 1) % _laneCount;
    _flying.add(_Flying(
      item: item,
      x: _width,
      y: _areaTop + lane * _laneHeight,
      width: width,
      speed: speed,
      mode: 1,
      age: Duration.zero,
    ));
    return true;
  }

  /// 选轨道：从上一条用过的下一条开始轮转，跳过还没腾出来的。
  ///
  /// 轨道准入三条件（对应逆向报告改动 5）：
  ///   1. `_clock >= tailFreeAt`：上一条的尾巴已经离开右边界；
  ///   2. `_clock >= headInAt`：上一条头部已完全进入（防追尾）；
  ///   3. `_clock >= enterAt`：同轨最小间隔 [_minLaneGap]。
  int _pickLane() {
    for (var i = 0; i < _laneCount; i++) {
      final lane = (_nextLane + i) % _laneCount;
      final st = _lanes[lane];
      if (st == null) return lane;
      if (_clock >= st.tailFreeAt &&
          _clock >= st.headInAt &&
          _clock >= st.enterAt) {
        return lane;
      }
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
        // 现在 areaRatio 在地基条数（普通 8 / 海量 14）上按比例收缩：
        // 30% → 2 条，100% → 全部。滑到最低是真的「只在画面上部飘两条」。
        final base = _baseTracks();
        final lanes = (widget.areaRatio * base).round().clamp(1, base);
        // 行高按字号 1.35 倍（逆向报告的取值），比原来的 1.6 更紧凑，
        // 同样的显示区域能多放一条轨道。
        _laneHeight = (widget.fontSize * 1.35).clamp(16.0, 40.0);
        // 安全区：上避让顶部控件条，下避让底部控制栏。
        // 小窗（竖屏内嵌播放器）高度不够时按比例收，避免把弹幕区压没。
        final topInset = math.min(48.0, cons.maxHeight * 0.12);
        final bottomInset = math.min(72.0, cons.maxHeight * 0.22);
        final areaHeight = cons.maxHeight - topInset - bottomInset;
        // 轨道数还要被「实际放得下几条」限制。
        final fit = areaHeight <= 0 ? 1 : (areaHeight / _laneHeight).floor();
        _areaTop = topInset;
        _areaHeight = areaHeight > 0 ? areaHeight : cons.maxHeight;
        _laneCount = math.max(1, math.min(lanes, math.max(1, fit)));
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

/// 一条轨道的占用状态。
class _LaneState {
  const _LaneState({
    required this.enterAt,
    required this.tailFreeAt,
    required this.headInAt,
  });

  /// 这条轨道最早什么时候能再放弹幕（同轨最小间隔）。
  final Duration enterAt;

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

  /// 把整体透明度算进文字颜色，避免每条弹幕都开一次离屏层。
  ///
  /// DANMU_NO_SAVELAYER（2026-11-14）：之前 opacity < 1 时对**每条**弹幕
  /// canvas.saveLayer 一次做离屏合成 —— 屏幕上二三十条就是每帧二三十次
  /// 离屏叠加，这是整个弹幕层最贵的操作，中低端机直接掉帧，肉眼就是
  /// 「一帧一帧卡住」。默认透明度是 0.92（< 1），所以每条都命中了这条慢路径。
  ///
  /// 现在把 alpha 直接乘进 color，普通绘制即可，缓存键带上透明度档位。
  TextPainter _painterFor(_Flying f) {
    final alpha = (opacity.clamp(0.05, 1.0) * 255).round();
    final key = '$alpha|$fontSize|${f.item.color}|${f.item.text}';
    final cached = _cache[key];
    if (cached != null) return cached;
    final base = Color(0xFF000000 | f.item.color);
    final tp = TextPainter(
      text: TextSpan(
        text: f.item.text,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          color: base.withValues(alpha: alpha / 255),
          height: 1.25,
          shadows: [
            Shadow(
              color: Colors.black.withValues(alpha: .68 * alpha / 255),
              blurRadius: 3,
            ),
            Shadow(
              color: Colors.black.withValues(alpha: .42 * alpha / 255),
              blurRadius: 6,
            ),
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
      // 透明度已经在 _painterFor 里乘进颜色了，这里直接画，
      // 不再对每条弹幕 saveLayer（那是每帧 N 次离屏合成）。
      tp.paint(canvas, Offset.zero);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _DanmuPainter old) => true;
}

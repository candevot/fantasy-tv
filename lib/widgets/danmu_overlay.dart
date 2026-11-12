import 'dart:async';
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

    // 1) 发射到期的弹幕
    while (_cursor < widget.items.length &&
        widget.items[_cursor].time <= _clock) {
      _spawn(widget.items[_cursor]);
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

    setState(() {});
  }

  void _spawn(DanmuItem item) {
    if (_width <= 0 || _laneHeight <= 0) return;
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
      return;
    }

    // 滚动弹幕：找一条可用轨道
    final lane = _pickLane(width);
    if (lane < 0) return; // 全满，丢弃（成熟方案也这么做，避免叠字）
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
        final area = cons.maxHeight * widget.areaRatio;
        _laneCount = math.max(1, (area / (widget.fontSize * 1.6)).floor());
        _laneHeight = area / _laneCount;
        return IgnorePointer(
          child: ClipRect(
            child: Stack(
              children: [
                for (final f in _flying)
                  Positioned(
                    left: f.x,
                    top: f.y,
                    child: Opacity(
                      opacity: widget.opacity,
                      child: Text(
                        f.item.text,
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(
                          fontSize: widget.fontSize,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF000000 | f.item.color),
                          height: 1.25,
                          shadows: const [
                            Shadow(color: Colors.black87, blurRadius: 3),
                            Shadow(color: Colors.black54, blurRadius: 6),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
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

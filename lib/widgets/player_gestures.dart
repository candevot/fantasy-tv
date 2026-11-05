import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';
import 'package:volume_controller/volume_controller.dart';

import '../services/fx_player.dart';
import 'player_theme.dart';

/// 播放器手势层（竖屏内嵌 / 全屏横屏共用）。
///
/// - 单击：显隐控件（交给 [onTap]）
/// - 双击：播放 / 暂停
/// - 左右滑：调进度，浮层显示「+15s」与目标时间，**松手才 seek**
/// - 上下滑：左半屏亮度 / 右半屏音量，带图标与百分比提示
/// - 长按：2 倍速（由页面负责恢复，来电/切后台时页面也会复位）
///
/// 该组件铺满播放器区域，放在视频层之上、控件层之下：
/// 控件可见时由控件自己消费点击，不会误触手势。
class FxPlayerGestures extends StatefulWidget {
  const FxPlayerGestures({
    super.key,
    required this.player,
    required this.onTap,
    required this.onDoubleTap,
    required this.onSeek,
    required this.onLongPressStart,
    required this.onLongPressEnd,
    this.onGestureStart,
    this.enabled = true,
    this.enableVertical = true,
    this.seekSecondsPerScreen = 90,
    this.resetBrightnessOnDispose = true,
  });

  final FxPlayer player;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onLongPressStart;
  final VoidCallback onLongPressEnd;

  /// 横扫 / 竖扫开始时回调，页面可借此收起控件，避免遮挡手势浮层。
  final VoidCallback? onGestureStart;
  final bool enabled;

  /// 是否启用左半屏亮度 / 右半屏音量上下滑；只在全屏开启，竖屏内嵌关闭。
  final bool enableVertical;

  /// 横扫满屏对应的秒数（默认 90s，即 1/6 屏 ≈ 15s）。
  final int seekSecondsPerScreen;

  /// 退出页面时是否把应用亮度恢复成系统亮度。
  /// 全屏退出、竖屏离开播放页时都要恢复。
  final bool resetBrightnessOnDispose;

  /// 跨竖屏/全屏共享：任一播放器改过亮度，离开播放页时都要恢复。
  static bool _brightnessTouched = false;

  @override
  State<FxPlayerGestures> createState() => _FxPlayerGesturesState();
}

enum _GestureMode { none, seek, brightness, volume }

class _GestureHud {
  const _GestureHud({
    required this.icon,
    required this.label,
    this.value,
  });

  final IconData icon;
  final String label;

  /// 0–1；null 表示不画进度条（seek 浮层）。
  final double? value;
}

class _FxPlayerGesturesState extends State<FxPlayerGestures> {
  _GestureMode _mode = _GestureMode.none;

  // 横向 seek
  Duration _seekStart = Duration.zero;
  Duration _seekTarget = Duration.zero;
  int _seekDeltaSeconds = 0;
  double _seekAccum = 0;
  bool _seekChanged = false;

  // 纵向亮度 / 音量
  double _brightness = .5;
  double _volume = .5;
  double _dragStartValue = .5;
  double _dragAccum = 0;
  DateTime _lastApply = DateTime.fromMillisecondsSinceEpoch(0);

  _GestureHud? _hud;
  IconData? _flashIcon;
  Timer? _hudTimer;
  Timer? _flashTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSystemValues());
    try {
      VolumeController.instance.showSystemUI = false;
    } catch (_) {
      // 桌面 / 测试环境没有实现，忽略即可。
    }
  }

  @override
  void dispose() {
    _hudTimer?.cancel();
    _flashTimer?.cancel();
    if (widget.resetBrightnessOnDispose &&
        FxPlayerGestures._brightnessTouched) {
      FxPlayerGestures._brightnessTouched = false;
      unawaited(_resetBrightness());
    }
    super.dispose();
  }

  Future<void> _resetBrightness() async {
    try {
      await ScreenBrightnessPlatform.instance
          .resetApplicationScreenBrightness();
    } catch (_) {}
  }

  Future<void> _loadSystemValues() async {
    try {
      final b = await ScreenBrightnessPlatform.instance.application;
      if (b.isFinite && b >= 0 && b <= 1) _brightness = b;
    } catch (_) {}
    try {
      final v = await VolumeController.instance.getVolume();
      if (v.isFinite && v >= 0 && v <= 1) _volume = v;
    } catch (_) {}
  }

  /* ------------------------------------------------------------ 状态与动效 */

  bool get _playing => widget.player.value.isPlaying;

  void _showHud(_GestureHud hud, {bool autoHide = true}) {
    _hudTimer?.cancel();
    if (!mounted) return;
    setState(() => _hud = hud);
    if (autoHide) {
      _hudTimer = Timer(const Duration(milliseconds: 720), () {
        if (!mounted) return;
        setState(() => _hud = null);
      });
    }
  }

  void _hideHudSoon() {
    _hudTimer?.cancel();
    _hudTimer = Timer(const Duration(seconds: 1), () {
      if (!mounted) return;
      setState(() => _hud = null);
    });
  }

  void _flash(IconData icon) {
    _flashTimer?.cancel();
    if (!mounted) return;
    setState(() => _flashIcon = icon);
    _flashTimer = Timer(const Duration(milliseconds: 520), () {
      if (!mounted) return;
      setState(() => _flashIcon = null);
    });
  }

  /* ---------------------------------------------------------------- 横向滑 */

  void _onHorizontalStart(DragStartDetails details) {
    widget.onGestureStart?.call();
    _mode = _GestureMode.seek;
    _seekStart = widget.player.value.position;
    _seekTarget = _seekStart;
    _seekDeltaSeconds = 0;
    _seekAccum = 0;
    _seekChanged = false;
    _showHud(_seekHud(), autoHide: false);
  }

  void _onHorizontalUpdate(DragUpdateDetails details) {
    if (_mode != _GestureMode.seek) return;
    final width = context.size?.width ?? MediaQuery.sizeOf(context).width;
    if (width <= 0) return;
    _seekAccum += details.delta.dx;
    // 满屏 90 秒，量化到 5 秒，浮层读起来稳定（常见 +15s / -30s）。
    final raw = (_seekAccum / width) * widget.seekSecondsPerScreen;
    final delta = (raw / 5).round() * 5;
    final total = widget.player.value.duration;
    var target = _seekStart + Duration(seconds: delta);
    if (target < Duration.zero) target = Duration.zero;
    if (total > Duration.zero && target > total) target = total;
    _seekTarget = target;
    _seekDeltaSeconds = delta;
    _seekChanged = delta != 0 && _seekTarget != _seekStart;
    _showHud(_seekHud(), autoHide: false);
  }

  void _onHorizontalEnd(DragEndDetails details) {
    if (_mode != _GestureMode.seek) return;
    _mode = _GestureMode.none;
    if (_seekChanged) widget.onSeek(_seekTarget);
    _hideHudSoon();
  }

  _GestureHud _seekHud() {
    final delta = _seekDeltaSeconds;
    final sign = delta > 0 ? '+' : '';
    final target = fxTime(_seekTarget);
    final total = fxTime(widget.player.value.duration);
    return _GestureHud(
      icon: delta >= 0 ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded,
      label: '$sign${delta}s  $target / $total',
    );
  }

  /* ---------------------------------------------------------------- 纵向滑 */

  void _onVerticalStart(DragStartDetails details) {
    widget.onGestureStart?.call();
    final width = context.size?.width ?? MediaQuery.sizeOf(context).width;
    final isLeft = details.localPosition.dx < width / 2;
    _mode = isLeft ? _GestureMode.brightness : _GestureMode.volume;
    _dragStartValue = isLeft ? _brightness : _volume;
    _dragAccum = 0;
    _showHud(_verticalHud(isLeft, _dragStartValue), autoHide: false);
  }

  void _onVerticalUpdate(DragUpdateDetails details) {
    if (_mode != _GestureMode.brightness && _mode != _GestureMode.volume) {
      return;
    }
    final height = context.size?.height ?? MediaQuery.sizeOf(context).height;
    if (height <= 0) return;
    _dragAccum += -details.delta.dy;
    final value = (_dragStartValue + _dragAccum / (height * .78))
        .clamp(0.0, 1.0)
        .toDouble();
    if (_mode == _GestureMode.brightness) {
      _brightness = value;
    } else {
      _volume = value;
    }
    _showHud(_verticalHud(_mode == _GestureMode.brightness, value),
        autoHide: false);
    _applyVertical(value);
  }

  void _onVerticalEnd(DragEndDetails details) {
    if (_mode != _GestureMode.brightness && _mode != _GestureMode.volume) {
      return;
    }
    // 节流可能吞掉最后一次 update，松手时补一次，保证落到手指停下的值。
    if (_mode == _GestureMode.brightness) {
      unawaited(_setBrightness(_brightness));
    } else {
      unawaited(_setVolume(_volume));
    }
    _mode = _GestureMode.none;
    _hideHudSoon();
  }

  _GestureHud _verticalHud(bool brightness, double value) {
    final percent = (value * 100).round();
    if (brightness) {
      final icon = percent <= 15
          ? Icons.brightness_low_rounded
          : (percent >= 70
              ? Icons.brightness_high_rounded
              : Icons.brightness_medium_rounded);
      return _GestureHud(icon: icon, label: '亮度 $percent%', value: value);
    }
    final icon = percent == 0
        ? Icons.volume_off_rounded
        : (percent >= 55 ? Icons.volume_up_rounded : Icons.volume_down_rounded);
    return _GestureHud(icon: icon, label: '音量 $percent%', value: value);
  }

  void _applyVertical(double value) {
    // 60ms 节流，拖动时不要每个像素都打一次平台通道。
    final now = DateTime.now();
    if (now.difference(_lastApply).inMilliseconds < 60) return;
    _lastApply = now;
    if (_mode == _GestureMode.brightness) {
      unawaited(_setBrightness(value));
    } else if (_mode == _GestureMode.volume) {
      unawaited(_setVolume(value));
    }
  }

  Future<void> _setBrightness(double value) async {
    try {
      await ScreenBrightnessPlatform.instance
          .setApplicationScreenBrightness(value);
      FxPlayerGestures._brightnessTouched = true;
    } catch (_) {}
  }

  Future<void> _setVolume(double value) async {
    try {
      await VolumeController.instance.setVolume(value);
    } catch (_) {}
  }

  /* -------------------------------------------------------------------- UI */

  @override
  Widget build(BuildContext context) {
    final hud = _hud;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.enabled ? widget.onTap : null,
      onDoubleTap: widget.enabled
          ? () {
              widget.onDoubleTap();
              _flash(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded);
            }
          : null,
      onLongPressStart:
          widget.enabled ? (_) => widget.onLongPressStart() : null,
      onLongPressEnd: widget.enabled ? (_) => widget.onLongPressEnd() : null,
      onLongPressCancel: widget.enabled ? widget.onLongPressEnd : null,
      onHorizontalDragStart: widget.enabled ? _onHorizontalStart : null,
      onHorizontalDragUpdate: widget.enabled ? _onHorizontalUpdate : null,
      onHorizontalDragEnd: widget.enabled ? _onHorizontalEnd : null,
      onHorizontalDragCancel: widget.enabled
          ? () {
              _mode = _GestureMode.none;
              _hideHudSoon();
            }
          : null,
      onVerticalDragStart:
          widget.enabled && widget.enableVertical ? _onVerticalStart : null,
      onVerticalDragUpdate:
          widget.enabled && widget.enableVertical ? _onVerticalUpdate : null,
      onVerticalDragEnd:
          widget.enabled && widget.enableVertical ? _onVerticalEnd : null,
      onVerticalDragCancel: widget.enabled && widget.enableVertical
          ? () {
              _mode = _GestureMode.none;
              _hideHudSoon();
            }
          : null,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const SizedBox.expand(),
          if (hud != null)
            Center(
              child: _GestureHudCard(hud: hud),
            ),
          if (_flashIcon != null)
            Center(
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(.42),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white.withOpacity(.28)),
                ),
                child: Icon(_flashIcon, color: Colors.white, size: 34),
              ),
            ),
        ],
      ),
    );
  }
}

class _GestureHudCard extends StatelessWidget {
  const _GestureHudCard({required this.hud});

  final _GestureHud hud;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(.52),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(.26), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.18),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(hud.icon, color: Colors.white, size: 30),
          const SizedBox(height: 7),
          Text(
            hud.label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: .3,
            ),
          ),
          if (hud.value != null) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: 132,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: math.max(0, math.min(1, hud.value!)),
                  minHeight: 4,
                  backgroundColor: Colors.white.withOpacity(.24),
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

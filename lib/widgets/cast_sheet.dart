import 'dart:async';

import 'package:flutter/material.dart';

import '../fx_globals.dart';
import '../services/cast_platform.dart';
import '../services/cast_service.dart';
import '../theme.dart';

/*
 * 阶段二预留：悬浮遥控窗（SYSTEM_ALERT_WINDOW）
 * ---------------------------------------------------------------
 * 本阶段只做底部 CastSheet。后续若做可拖动的系统悬浮遥控窗：
 *  1. Manifest 增加 android.permission.SYSTEM_ALERT_WINDOW，并引导用户
 *     到「设置 → 显示在其他应用上层」手动授权（Android 无运行时弹窗）；
 *  2. 用原生 MethodChannel 起一个 WindowManager 悬浮 View（播放/暂停/
 *     停止），或复用本文件的 _remotePanel 渲染成 FlutterView；
 *  3. 悬浮窗只订阅 CastService.instance.changes，不持有播放器；
 *  4. 投屏结束 / 页面不可见时 removeView 并释放窗口。
 * 本次不实现，避免申请高风险悬浮窗权限。
 */

/// 打开投屏底部弹窗。
///
/// - 未投屏：SSDP 搜索中 → 设备列表 → 点击后变成遥控面板；
/// - 已投屏：直接显示当前会话的遥控面板。
///
/// 关闭弹窗不会停止投屏；只有「断开投屏」或发起页面 dispose 才会 stop。
Future<void> showCastSheet(
  BuildContext context, {
  required CastSource source,
  required Object owner,
  Future<void> Function()? onCastStarted,
  Future<void> Function()? onCastStopped,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: .38),
    builder: (_) => CastSheet(
      source: source,
      owner: owner,
      onCastStarted: onCastStarted,
      onCastStopped: onCastStopped,
    ),
  );
}

class CastSheet extends StatefulWidget {
  const CastSheet({
    super.key,
    required this.source,
    required this.owner,
    this.onCastStarted,
    this.onCastStopped,
  });

  final CastSource source;

  /// 投屏会话归属页；页面 dispose 时只停自己的会话。
  final Object owner;
  final Future<void> Function()? onCastStarted;
  final Future<void> Function()? onCastStopped;

  @override
  State<CastSheet> createState() => _CastSheetState();
}

class _CastSheetState extends State<CastSheet> {
  final CastService _service = CastService.instance;

  StreamSubscription<CastState>? _sub;
  CastState _castState = CastState.idle;
  List<CastDevice>? _devices;
  CastDevice? _connectingDevice;
  String? _error;
  bool _searching = false;
  bool _stopping = false;
  bool _actionBusy = false;
  double? _dragPositionMs;
  double? _dragVolume;

  /// 只有连接成功后才切遥控面板：play() 会先发 connecting 状态，
  /// 那段时间仍停留在设备列表 / 按钮 loading，失败则直接回到列表报错。
  bool get _casting =>
      _service.isCasting &&
      _castState.device != null &&
      _connectingDevice == null &&
      _castState.phase != CastPhase.connecting;

  @override
  void initState() {
    super.initState();
    _castState = _service.state;
    _sub = _service.changes.listen((state) {
      if (!mounted) return;
      setState(() => _castState = state);
    });
    if (_service.isCasting) {
      _searching = false;
    } else {
      unawaited(_discover());
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _discover() async {
    setState(() {
      _searching = true;
      _error = null;
      _devices = null;
      _connectingDevice = null;
    });
    try {
      final devices = await runWithCastMulticastLock(_service.discover);
      if (!mounted) return;
      setState(() {
        _searching = false;
        _devices = devices;
        _error = devices.isEmpty ? '同一 WiFi 下未发现电视' : null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _devices = const <CastDevice>[];
        _error =
            error is CastException ? error.message : '搜索电视失败，请稍后重试';
      });
    }
  }

  Future<void> _connect(CastDevice device) async {
    if (_connectingDevice != null) return;
    setState(() {
      _connectingDevice = device;
      _error = null;
    });
    try {
      await _service.play(
        device,
        widget.source.url,
        title: widget.source.title,
        owner: widget.owner,
        startAt: widget.source.startAt,
      );
      try {
        await widget.onCastStarted?.call();
      } catch (_) {
        // 暂停手机播放失败不应影响电视端已开始的投屏。
      }
      if (!mounted) return;
      setState(() => _connectingDevice = null);
      fxGlobalToast('已投屏到 ${device.name}');
    } catch (error) {
      if (!mounted) return;
      final message =
          error is CastException ? error.message : '投屏失败，请稍后重试';
      setState(() {
        _connectingDevice = null;
        _error = message;
      });
      fxGlobalToast('投屏失败：$message');
    }
  }

  Future<void> _stopCasting() async {
    if (_stopping) return;
    setState(() => _stopping = true);
    await _service.stop();
    try {
      await widget.onCastStopped?.call();
    } catch (_) {
      // 恢复手机播放失败不影响「已停止投屏」。
    }
    if (!mounted) return;
    Navigator.of(context).maybePop();
    fxGlobalToast('已停止投屏');
  }

  Future<void> _togglePlay() async {
    if (_actionBusy || _stopping) return;
    setState(() => _actionBusy = true);
    try {
      if (_castState.isPlaying) {
        await _service.pause();
      } else {
        await _service.resume();
      }
    } on CastException catch (error) {
      fxGlobalToast(error.message);
    } catch (_) {
      fxGlobalToast('操作失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _seekTo(Duration target) async {
    if (_actionBusy || _stopping) return;
    setState(() => _actionBusy = true);
    try {
      await _service.seek(target);
    } on CastException catch (error) {
      fxGlobalToast(error.message);
    } catch (_) {
      fxGlobalToast('调整进度失败');
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _seekBy(int seconds) {
    return _seekTo(_castState.position + Duration(seconds: seconds));
  }

  Future<void> _changeVolume(double value) async {
    if (_actionBusy) return;
    setState(() => _actionBusy = true);
    try {
      await _service.setVolume(value.round());
    } on CastException catch (error) {
      fxGlobalToast(error.message);
    } catch (_) {
      fxGlobalToast('调整音量失败');
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * .84;
    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        20,
        14 + MediaQuery.paddingOf(context).bottom,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 38,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFFE3E9F3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 14),
          _header(),
          const SizedBox(height: 12),
          if (!_casting) _sourceHint(),
          if (_casting)
            Flexible(
              child: SingleChildScrollView(
                child: _remotePanel(_castState),
              ),
            )
          else
            Flexible(
              child: SingleChildScrollView(
                child: _devicePanel(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _header() {
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: Fx.brand,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(
            _casting ? Icons.settings_remote_rounded : Icons.cast_rounded,
            size: 18,
            color: Colors.white,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _casting ? '投屏遥控' : '投屏到电视',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: Fx.ink,
                ),
              ),
              if (_casting)
                Text(
                  _castState.device?.name ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Fx.sub,
                  ),
                ),
            ],
          ),
        ),
        if (!_casting && !_searching)
          IconButton(
            tooltip: '重新搜索',
            visualDensity: VisualDensity.compact,
            onPressed: () => unawaited(_discover()),
            icon: const Icon(Icons.refresh_rounded, size: 20, color: Fx.sub),
          ),
        IconButton(
          tooltip: '关闭',
          visualDensity: VisualDensity.compact,
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.close_rounded, size: 20, color: Fx.sub),
        ),
      ],
    );
  }

  Widget _sourceHint() {
    final text = widget.source.viaProxy
        ? '源站需要 Referer/UA，已自动改走服务器代理'
        : '使用当前播放直链投屏';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F7FF),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        children: [
          Icon(
            widget.source.viaProxy
                ? Icons.cloud_queue_rounded
                : Icons.link_rounded,
            size: 14,
            color: Fx.accent,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: Fx.sub,
              ),
            ),
          ),
          Flexible(
            child: Text(
              widget.source.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: Fx.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _devicePanel() {
    if (_searching) {
      return SizedBox(
        height: 230,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: Fx.accent,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              '搜索中…',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: Fx.ink,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '正在同一 WiFi 下寻找可投屏的电视',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: Fx.sub.withValues(alpha: .9),
              ),
            ),
          ],
        ),
      );
    }

    final devices = _devices ?? const <CastDevice>[];
    if (devices.isEmpty) {
      return SizedBox(
        height: 250,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 62,
              height: 62,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: Color(0xFFF3F6FC),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.tv_off_rounded,
                size: 30,
                color: Fx.sub,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              _error ?? '同一 WiFi 下未发现电视',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Fx.ink,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '请确认电视已开机、支持 DLNA，并与手机连在同一个 WiFi',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10.5,
                height: 1.5,
                color: Fx.sub,
              ),
            ),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: () => unawaited(_discover()),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  gradient: Fx.brand,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Text(
                  '重新搜索',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_error != null) _errorBanner(_error!),
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 8),
          child: Text(
            '发现 ${devices.length} 台设备',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Fx.sub,
            ),
          ),
        ),
        for (final device in devices) ...[
          _deviceTile(device),
          const SizedBox(height: 9),
        ],
      ],
    );
  }

  Widget _deviceTile(CastDevice device) {
    final connecting = identical(_connectingDevice, device);
    return Material(
      color: const Color(0xFFF6F8FC),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: _connectingDevice == null
            ? () => unawaited(_connect(device))
            : null,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Fx.accent.withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: const Icon(
                  Icons.tv_rounded,
                  size: 22,
                  color: Fx.accent,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Fx.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      device.ip,
                      style: const TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                        color: Fx.sub,
                      ),
                    ),
                  ],
                ),
              ),
              if (connecting)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: Fx.accent,
                  ),
                )
              else
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 22,
                  color: Fx.sub,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _remotePanel(CastState state) {
    final device = state.device;
    final duration = state.duration;
    final seekable = duration > Duration.zero;
    final position = _dragPositionMs != null
        ? Duration(milliseconds: _dragPositionMs!.round())
        : state.position;
    final sliderMax = seekable
        ? duration.inMilliseconds.toDouble()
        : 1.0;
    final sliderValue = seekable
        ? position.inMilliseconds.clamp(0, duration.inMilliseconds).toDouble()
        : 0.0;
    final volume = _dragVolume ?? (state.volume ?? 0).toDouble();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFFEFFAF4),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: const Color(0xFFD5F2E4)),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.check_circle_rounded,
                size: 14,
                color: Color(0xFF35C98A),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '已投屏到 ${device?.name ?? ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1F8A5F),
                  ),
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFF1F5FF), Color(0xFFF8F5FF)],
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Fx.accent.withValues(alpha: .12),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.tv_rounded,
                  size: 21,
                  color: Fx.accent,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device?.name ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: Fx.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: state.phase == CastPhase.error
                                ? const Color(0xFFFF6B6B)
                                : const Color(0xFF35C98A),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          state.phase == CastPhase.error
                              ? '连接中断'
                              : '已连接 · ${device?.ip ?? ''}',
                          style: const TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: Fx.sub,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Fx.accent.withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  state.isPlaying ? '播放中' : '已暂停',
                  style: const TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    color: Fx.accent,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 13),
        Text(
          state.title.isEmpty ? widget.source.title : state.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 13,
            height: 1.35,
            fontWeight: FontWeight.w700,
            color: Fx.ink,
          ),
        ),
        if (state.error != null) ...[
          const SizedBox(height: 9),
          _errorBanner(state.error!),
        ],
        const SizedBox(height: 13),
        if (seekable) ...[
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              activeTrackColor: Fx.accent,
              inactiveTrackColor: const Color(0xFFE7EDF8),
              thumbColor: Fx.accent,
              overlayColor: Fx.accent.withValues(alpha: .12),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            ),
            child: Slider(
              value: sliderValue,
              max: sliderMax,
              onChanged: (value) {
                setState(() => _dragPositionMs = value);
              },
              onChangeEnd: (value) {
                setState(() => _dragPositionMs = null);
                unawaited(
                  _seekTo(Duration(milliseconds: value.round())),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                Text(
                  _timeText(position),
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: Fx.sub,
                  ),
                ),
                const Spacer(),
                Text(
                  _timeText(duration),
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: Fx.sub,
                  ),
                ),
              ],
            ),
          ),
        ] else
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFF6F8FC),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.sensors_rounded,
                  size: 15,
                  color: Fx.accent,
                ),
                const SizedBox(width: 6),
                Text(
                  widget.source.isLive ? '直播投屏中，进度由电视端控制' : '电视端未返回时长，暂不支持拖动进度',
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: Fx.sub,
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _roundControl(
              icon: Icons.replay_10_rounded,
              tooltip: '后退 10 秒',
              onTap: seekable ? () => unawaited(_seekBy(-10)) : null,
            ),
            _mainControl(state),
            _roundControl(
              icon: Icons.forward_10_rounded,
              tooltip: '前进 10 秒',
              onTap: seekable ? () => unawaited(_seekBy(10)) : null,
            ),
            _roundControl(
              icon: Icons.stop_rounded,
              tooltip: '停止投屏',
              danger: true,
              onTap: _stopping ? null : () => unawaited(_stopCasting()),
            ),
          ],
        ),
        if (state.supportsVolume && state.volume != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                volume <= 0
                    ? Icons.volume_off_rounded
                    : Icons.volume_down_rounded,
                size: 19,
                color: Fx.sub,
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    activeTrackColor: Fx.accent2,
                    inactiveTrackColor: const Color(0xFFE7EDF8),
                    thumbColor: Fx.accent2,
                    overlayColor: Fx.accent2.withValues(alpha: .12),
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 14),
                  ),
                  child: Slider(
                    value: volume.clamp(0, 100).toDouble(),
                    max: 100,
                    onChanged: (value) {
                      setState(() => _dragVolume = value);
                    },
                    onChangeEnd: (value) {
                      setState(() => _dragVolume = null);
                      unawaited(_changeVolume(value));
                    },
                  ),
                ),
              ),
              SizedBox(
                width: 34,
                child: Text(
                  '${volume.round()}',
                  textAlign: TextAlign.end,
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: Fx.sub,
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 6),
        Center(
          child: TextButton(
            onPressed: _stopping ? null : () => unawaited(_stopCasting()),
            child: Text(
              _stopping ? '正在断开…' : '断开投屏',
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: Color(0xFFFF6B6B),
              ),
            ),
          ),
        ),
        const Center(
          child: Text(
            '关闭面板不会停止投屏',
            style: TextStyle(
              fontSize: 9.5,
              color: Fx.sub,
            ),
          ),
        ),
      ],
    );
  }

  Widget _mainControl(CastState state) {
    final busy = _actionBusy || _stopping;
    return GestureDetector(
      onTap: busy ? null : () => unawaited(_togglePlay()),
      child: Container(
        width: 54,
        height: 54,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: Fx.brand,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Fx.accent.withValues(alpha: .28),
              blurRadius: 14,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: Colors.white,
                ),
              )
            : Icon(
                state.isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                size: 30,
                color: Colors.white,
              ),
      ),
    );
  }

  Widget _roundControl({
    required IconData icon,
    required String tooltip,
    VoidCallback? onTap,
    bool danger = false,
  }) {
    final color = danger ? const Color(0xFFFF6B6B) : Fx.ink;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 42,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: danger
                ? const Color(0xFFFFF1F1)
                : const Color(0xFFF3F6FC),
            shape: BoxShape.circle,
          ),
          child: Icon(
            icon,
            size: 21,
            color: onTap == null ? Fx.sub.withValues(alpha: .35) : color,
          ),
        ),
      ),
    );
  }

  Widget _errorBanner(String message) {
    return Container(
      margin: const EdgeInsets.only(bottom: 9),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8F3),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: const Color(0xFFFFE1CC)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            size: 15,
            color: Color(0xFFF08A5D),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 10.5,
                height: 1.45,
                fontWeight: FontWeight.w600,
                color: Color(0xFF9A5B2E),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _timeText(Duration value) {
    final total = value.inSeconds < 0 ? 0 : value.inSeconds;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    String two(int v) => v < 10 ? '0$v' : '$v';
    return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }
}

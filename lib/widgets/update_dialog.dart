import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_info.dart';
import '../services/app_update_service.dart';
import '../theme.dart';
import 'player_theme.dart' show fxToast;

/// 启动检查命中的更新弹窗：白色液态玻璃（半透明磨砂 + 渐变按钮）。
///
/// 行为：
/// - 「暂不更新」/ 点遮罩关闭：本次会话不再弹，**下次冷启动还会弹**；
/// - 「立即更新」：下载 APK（弹窗内玻璃进度条）→ 调起系统安装器；
/// - 下载 / 安装失败：toast 提示 + 弹窗内保留「重试」，另给「复制链接」
///   （github releases 国内常打不开，复制后可在浏览器手动下载）。
Future<void> showAppUpdateDialog(BuildContext context, AppUpdateInfo info) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => AppUpdateDialog(info: info),
  );
}

enum _UpdatePhase { idle, downloading, failed }

class AppUpdateDialog extends StatefulWidget {
  const AppUpdateDialog({super.key, required this.info});

  final AppUpdateInfo info;

  @override
  State<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<AppUpdateDialog> {
  _UpdatePhase _phase = _UpdatePhase.idle;

  /// 0–1；服务端没给 content-length 时为 null（走不确定态进度条）。
  double? _progress;
  String _error = '';

  @override
  void initState() {
    super.initState();
    // 弹出来就算提示过：本次会话不再重复打扰（冷启动会重新检查）。
    AppUpdateService.markPrompted(widget.info.versionCode);
  }

  void _close() {
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  Future<void> _start() async {
    if (_phase == _UpdatePhase.downloading) return;
    setState(() {
      _phase = _UpdatePhase.downloading;
      _progress = null;
      _error = '';
    });
    try {
      final file = await AppUpdateService.downloadApk(
        widget.info.downloadUrl,
        onProgress: (value) {
          if (!mounted) return;
          setState(() => _progress = value);
        },
      );
      // 下载期间用户关掉了弹窗：不再调起安装器打断用户。
      if (!mounted) return;
      setState(() => _progress = 1.0);
      // 明确告诉用户安装包存到哪了：以后想重装 / 转发给别人能找到。
      if (mounted) {
        fxToast(context, '安装包已保存：${AppUpdateService.shortPath(file.path)}');
      }
      await AppUpdateService.installApk(file);
      if (!mounted) return;
      // 安装器已接管，弹窗留着也没意义。
      _close();
    } catch (e) {
      final message = e is AppUpdateException ? e.message : '下载失败，请检查网络后重试';
      if (!mounted) return;
      fxToast(context, message);
      setState(() {
        _phase = _UpdatePhase.failed;
        _error = message;
      });
    }
  }

  Future<void> _copyLink() async {
    await Clipboard.setData(ClipboardData(text: widget.info.downloadUrl));
    if (!mounted) return;
    fxToast(context, '链接已复制，请在浏览器中打开下载安装包');
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    // 下载中不许退出：避免下载到一半弹窗没了、安装器却在后台被调起。
    return PopScope(
      canPop: _phase != _UpdatePhase.downloading,
      child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 30, vertical: 24),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
            child: Container(
              width: double.maxFinite,
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .78),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: Colors.white.withValues(alpha: .95),
                  width: 1.2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF50729F).withValues(alpha: .18),
                    blurRadius: 40,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(info),
                  const SizedBox(height: 14),
                  if (info.notes.trim().isNotEmpty) ...[
                    _notes(info.notes.trim()),
                    const SizedBox(height: 14),
                  ],
                  if (_phase == _UpdatePhase.downloading) ...[
                    _progressBar(),
                    const SizedBox(height: 14),
                  ] else if (_phase == _UpdatePhase.failed) ...[
                    _errorBox(_error),
                    const SizedBox(height: 14),
                  ],
                  _actions(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(AppUpdateInfo info) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Fx.accent.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(13),
          ),
          child: const Icon(
            Icons.system_update_rounded,
            size: 21,
            color: Fx.accent,
          ),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '发现新版本',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: Fx.ink,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '当前 ${AppInfo.displayVersion} → 最新 ${info.displayVersion}',
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  color: Fx.sub,
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            gradient: Fx.brand,
            borderRadius: BorderRadius.circular(99),
          ),
          child: Text(
            'v${info.displayVersion}',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ),
      ],
    );
  }

  Widget _notes(String notes) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 150),
      child: SingleChildScrollView(
        child: Text(
          notes,
          style: const TextStyle(
            fontSize: 12.5,
            height: 1.65,
            color: Fx.sub,
          ),
        ),
      ),
    );
  }

  Widget _errorBox(String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFE8544A).withValues(alpha: .08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFFE8544A).withValues(alpha: .30),
        ),
      ),
      child: Text(
        message,
        style: const TextStyle(
          fontSize: 12,
          height: 1.5,
          color: Color(0xFFC43C33),
        ),
      ),
    );
  }

  Widget _progressBar() {
    final value = _progress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              '正在下载安装包',
              style: TextStyle(fontSize: 12, color: Fx.sub),
            ),
            const Spacer(),
            Text(
              value == null ? '' : '${(value * 100).toStringAsFixed(0)}%',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Fx.ink,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // 玻璃进度条：磨砂底槽 + 品牌渐变填充；没拿到总长度时走不确定态。
        Container(
          height: 8,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .70),
            borderRadius: BorderRadius.circular(99),
            border: Border.all(color: Colors.white.withValues(alpha: .95)),
          ),
          child: value == null
              ? const _IndeterminateBar()
              : Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: value.clamp(0.0, 1.0),
                    heightFactor: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(gradient: Fx.brand),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _actions() {
    final downloading = _phase == _UpdatePhase.downloading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GradButton(
          text: downloading
              ? (_progress == null ? '正在下载…' : '正在下载 ${( _progress! * 100).toStringAsFixed(0)}%')
              : (_phase == _UpdatePhase.failed ? '重试更新' : '立即更新'),
          onTap: downloading ? null : _start,
        ),
        if (_phase == _UpdatePhase.failed) ...[
          const SizedBox(height: 10),
          _ghostButton('复制链接手动下载', _copyLink),
        ] else if (!downloading) ...[
          const SizedBox(height: 10),
          _ghostButton('暂不更新', _close),
        ],
      ],
    );
  }

  Widget _ghostButton(String text, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .55),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white.withValues(alpha: .95)),
        ),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Fx.sub,
          ),
        ),
      ),
    );
  }
}

/// 不确定进度：一段品牌渐变在磨砂槽里来回滑。
class _IndeterminateBar extends StatefulWidget {
  const _IndeterminateBar();

  @override
  State<_IndeterminateBar> createState() => _IndeterminateBarState();
}

class _IndeterminateBarState extends State<_IndeterminateBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        // 0→1→0 往返：从左侧滑到右侧再滑回来。
        final x = t < .5 ? t * 2 : (1 - t) * 2;
        return FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: .35,
          heightFactor: 1,
          child: Transform.translate(
            offset: Offset(x * (context.size?.width ?? 0) * .65 / .35, 0),
            child: DecoratedBox(
              decoration: BoxDecoration(gradient: Fx.brand),
            ),
          ),
        );
      },
    );
  }
}

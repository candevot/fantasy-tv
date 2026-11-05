import 'package:flutter/material.dart';

import '../theme.dart';

/// 循环播放模式：单集 / 列表 / 关闭。
enum FxLoopMode {
  single('单集'),
  list('列表'),
  off('关闭');

  const FxLoopMode(this.label);

  final String label;

  FxLoopMode get next => switch (this) {
        FxLoopMode.single => FxLoopMode.list,
        FxLoopMode.list => FxLoopMode.off,
        FxLoopMode.off => FxLoopMode.single,
      };
}

/// 腾讯播放设置样式的「更多」面板：
/// 图标行（画中画 / 定时关闭 / 下载 / 倍速 / 后台播放）
/// + 列表行（循环播放 / 跳过片头片尾 / 撑满全屏 / 问题反馈）。
Future<void> showFxMorePanel(
  BuildContext context, {
  required FxLoopMode loopMode,
  required bool skipIntroOutro,
  required bool fillScreen,
  required ValueChanged<FxLoopMode> onLoopChanged,
  required ValueChanged<bool> onSkipChanged,
  required ValueChanged<bool> onFillChanged,
  required VoidCallback onPip,
  required VoidCallback onSleepTimer,
  required VoidCallback onDownload,
  required VoidCallback onSpeed,
  required VoidCallback onBackground,
  required VoidCallback onFeedback,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (sheetContext) {
      var loop = loopMode;
      var skip = skipIntroOutro;
      var fill = fillScreen;
      return StatefulBuilder(
        builder: (context, setSheetState) {
          void closeThen(VoidCallback action) {
            Navigator.of(sheetContext).maybePop();
            action();
          }

          return Container(
            padding: EdgeInsets.fromLTRB(
              20,
              12,
              20,
              18 + MediaQuery.of(context).padding.bottom,
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
                Row(
                  children: [
                    const Text(
                      '播放设置',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Fx.ink,
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(sheetContext).maybePop(),
                      child: Container(
                        width: 30,
                        height: 30,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: const Color(0xFFF3F6FC),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white),
                        ),
                        child: const Icon(Icons.close_rounded,
                            size: 18, color: Fx.sub),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    _MoreAction(
                      icon: Icons.picture_in_picture_alt_rounded,
                      label: '画中画',
                      onTap: () => closeThen(onPip),
                    ),
                    _MoreAction(
                      icon: Icons.timer_outlined,
                      label: '定时关闭',
                      onTap: () => closeThen(onSleepTimer),
                    ),
                    _MoreAction(
                      icon: Icons.download_rounded,
                      label: '下载',
                      onTap: () => closeThen(onDownload),
                    ),
                    _MoreAction(
                      icon: Icons.speed_rounded,
                      label: '倍速',
                      onTap: () => closeThen(onSpeed),
                    ),
                    _MoreAction(
                      icon: Icons.headphones_rounded,
                      label: '后台播放',
                      onTap: () => closeThen(onBackground),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const Divider(height: 1, color: Color(0xFFEFF3FA)),
                _MoreRow(
                  icon: Icons.repeat_rounded,
                  title: '循环播放',
                  value: loop.label,
                  onTap: () {
                    loop = loop.next;
                    setSheetState(() {});
                    onLoopChanged(loop);
                  },
                ),
                _MoreRow(
                  icon: Icons.skip_next_rounded,
                  title: '跳过片头片尾',
                  trailing: Switch.adaptive(
                    value: skip,
                    activeColor: Fx.accent,
                    onChanged: (v) {
                      skip = v;
                      setSheetState(() {});
                      onSkipChanged(v);
                    },
                  ),
                ),
                _MoreRow(
                  icon: Icons.fit_screen_rounded,
                  title: '撑满全屏',
                  trailing: Switch.adaptive(
                    value: fill,
                    activeColor: Fx.accent,
                    onChanged: (v) {
                      fill = v;
                      setSheetState(() {});
                      onFillChanged(v);
                    },
                  ),
                ),
                _MoreRow(
                  icon: Icons.feedback_outlined,
                  title: '问题反馈',
                  onTap: () => closeThen(onFeedback),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

class _MoreAction extends StatelessWidget {
  const _MoreAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFFF3F6FC),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white),
              ),
              child: Icon(icon, size: 21, color: Fx.ink),
            ),
            const SizedBox(height: 7),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Fx.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MoreRow extends StatelessWidget {
  const _MoreRow({
    required this.icon,
    required this.title,
    this.value,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: 52,
        child: Row(
          children: [
            Icon(icon, size: 19, color: Fx.sub),
            const SizedBox(width: 10),
            Text(
              title,
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: Fx.ink,
              ),
            ),
            const Spacer(),
            if (trailing != null)
              trailing!
            else if (value != null) ...[
              Text(
                value!,
                style: const TextStyle(fontSize: 12, color: Fx.sub),
              ),
              const SizedBox(width: 2),
              const Icon(Icons.chevron_right_rounded, size: 18, color: Fx.sub),
            ] else
              const Icon(Icons.chevron_right_rounded, size: 18, color: Fx.sub),
          ],
        ),
      ),
    );
  }
}

/// 倍速选择面板，返回选中的倍速；取消返回 null。
Future<double?> showFxSpeedSheet(BuildContext context, double current) {
  const options = <double>[0.75, 1.0, 1.25, 1.5, 2.0];
  return showModalBottomSheet<double>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => Container(
      padding: EdgeInsets.fromLTRB(
        20,
        14,
        20,
        18 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '播放速度',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: Fx.ink,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final item in options)
                ChipTag(
                  item == 1.0 ? '1.0x' : '${item}x',
                  active: (current - item).abs() < .001,
                  onTap: () => Navigator.of(sheetContext).pop(item),
                ),
            ],
          ),
          const SizedBox(height: 6),
        ],
      ),
    ),
  );
}

/// 定时关闭选择面板，返回分钟数；0 = 关闭，取消返回 null。
Future<int?> showFxSleepTimerSheet(BuildContext context) {
  const options = <int>[15, 30, 45, 60];
  return showModalBottomSheet<int>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => Container(
      padding: EdgeInsets.fromLTRB(
        20,
        14,
        20,
        18 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '定时关闭',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: Fx.ink,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final item in options)
                ChipTag(
                  '$item 分钟',
                  onTap: () => Navigator.of(sheetContext).pop(item),
                ),
              ChipTag(
                '关闭定时',
                onTap: () => Navigator.of(sheetContext).pop(0),
              ),
            ],
          ),
          const SizedBox(height: 6),
        ],
      ),
    ),
  );
}

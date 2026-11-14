import 'dart:async';

import 'package:flutter/material.dart';

import '../services/fx_display_settings.dart';
import '../theme.dart';

/// 循环播放模式：单集循环 / 关闭（对应 mpv setLooping）。
/// 「列表循环」已移除：连播交给设置页的「自动下一集」开关。
enum FxLoopMode {
  single('单集循环'),
  off('关闭');

  const FxLoopMode(this.label);

  final String label;

  FxLoopMode get next =>
      this == FxLoopMode.single ? FxLoopMode.off : FxLoopMode.single;
}

/// 腾讯播放设置样式的「更多」面板（竖屏与全屏共用）：
/// 图标行（定时关闭 / 下载本集 / 倍速 / 后台播放）
/// + 列表行（循环播放 / 跳过片头片尾 / 画面比例 / 镜像模式 / 问题反馈）。
/// 旧「清晰度 · 线路」入口已删除：码率档切换面板随入口一起移除，
/// 线路切换仍由错误页「换线路」与详情页线路卡片负责。
/// [onLoopChanged] / [onJumpPanel] / [onDownload] /
/// [onSpeed] 传 null 时对应入口整块不显示（直播全屏没有下一集 /
/// 片头尾 / 下载 / 倍速）；其余行为所有播放场景共用。
/// 画中画已移除：当前版本不支持，列表只保留可用项。
/// 旧「撑满全屏」开关已删除：由「画面比例 · 填充」替代。
/// 旧的跳过秒数下拉已删除：片头 / 片尾改为按本剧标记，
/// [markLabel] 显示「本剧：片头 01:20 · 片尾 43:10」，点行打开标记面板。
Future<void> showFxMorePanel(
  BuildContext context, {
  required FxLoopMode loopMode,
  required String markLabel,
  ValueChanged<FxLoopMode>? onLoopChanged,
  VoidCallback? onJumpPanel,
  required VoidCallback onSleepTimer,
  VoidCallback? onDownload,
  VoidCallback? onSpeed,
  required VoidCallback onBackground,
  required VoidCallback onFeedback,
  /// 播放诊断开关的当前值（默认关）。
  bool diagnosticsOn = false,
  /// 点「播放诊断」行时回调新值；null = 不显示这一行。
  /// 走回调而不是面板自己写 AppSettings：页面要保持同一个 state 才能
  /// 立刻抬起 / 收起浮层，面板只负责把「用户点了」这件事交回去。
  ValueChanged<bool>? onDiagnosticsChanged,
}) {
  // 兜底：面板比播放画面先开时也把已保存档位读出来（幂等）。
  unawaited(FxDisplaySettings.instance.ensureLoaded());
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (sheetContext) {
      var loop = loopMode;
      // 画面比例 / 镜像模式是全局设置：这里只负责高亮，真正生效靠
      // FxDisplaySettings 通知所有播放画面重建（立即生效，不重载视频）。
      var aspect = FxDisplaySettings.instance.aspect;
      var mirror = FxDisplaySettings.instance.mirror;
      // 诊断开关在面板里就地翻转，用户点一下马上看到「开 / 关」的变化。
      var diagnostics = diagnosticsOn;
      final diagnosticsChanged = onDiagnosticsChanged;
      // 直播等场景缺省的行为：局部变量判空后可安全地在闭包里使用。
      final loopChanged = onLoopChanged;
      final jumpPanel = onJumpPanel;
      final download = onDownload;
      final speed = onSpeed;
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
                      icon: Icons.timer_outlined,
                      label: '定时关闭',
                      onTap: () => closeThen(onSleepTimer),
                    ),
                    if (download != null)
                      _MoreAction(
                        icon: Icons.download_rounded,
                        label: '下载本集',
                        onTap: () => closeThen(download),
                      ),
                    if (speed != null)
                      _MoreAction(
                        icon: Icons.speed_rounded,
                        label: '倍速',
                        onTap: () => closeThen(speed),
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
                if (loopChanged != null)
                  _MoreRow(
                    icon: Icons.repeat_rounded,
                    title: '循环播放',
                    value: loop.label,
                    onTap: () {
                      loop = loop.next;
                      setSheetState(() {});
                      loopChanged(loop);
                    },
                  ),
                if (jumpPanel != null)
                  _MoreRow(
                    icon: Icons.bookmark_border_rounded,
                    title: '跳过片头片尾',
                    value: markLabel,
                    onTap: () => closeThen(jumpPanel),
                  ),
                _MoreChoiceRow(
                  icon: Icons.aspect_ratio_rounded,
                  title: '画面比例',
                  options: [
                    for (final mode in FxAspectMode.values) (mode.key, mode.label),
                  ],
                  selected: aspect.key,
                  onSelect: (key) {
                    final mode = FxAspectMode.fromKey(key) ?? FxAspectMode.contain;
                    aspect = mode;
                    setSheetState(() {});
                    unawaited(FxDisplaySettings.instance.setAspect(mode));
                  },
                ),
                _MoreChoiceRow(
                  icon: Icons.flip_rounded,
                  title: '镜像模式',
                  options: [
                    for (final mode in FxMirrorMode.values) (mode.key, mode.label),
                  ],
                  selected: mirror.key,
                  onSelect: (key) {
                    final mode = FxMirrorMode.fromKey(key) ?? FxMirrorMode.none;
                    mirror = mode;
                    setSheetState(() {});
                    unawaited(FxDisplaySettings.instance.setMirror(mode));
                  },
                ),
                if (diagnosticsChanged != null)
                  _MoreRow(
                    icon: Icons.monitor_heart_outlined,
                    title: '播放诊断',
                    // 值右对齐显示「开 / 关」，点一下翻转（面板不关，
                    // 用户可以马上看到浮层在画面上出现 / 消失）。
                    value: diagnostics ? '开' : '关',
                    onTap: () {
                      diagnostics = !diagnostics;
                      setSheetState(() {});
                      diagnosticsChanged(diagnostics);
                    },
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
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? value;
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
            if (value != null) ...[
              Text(
                value!,
                style: const TextStyle(fontSize: 12, color: Fx.sub),
              ),
              const SizedBox(width: 2),
            ],
            const Icon(Icons.chevron_right_rounded, size: 18, color: Fx.sub),
          ],
        ),
      ),
    );
  }
}

/// 播放设置里的档位行：左图标 + 标题，右侧一排可点档位按钮
/// （竞品三行式布局：画面比例 / 镜像模式共用）。
/// 档位多于一行时自动换行，选项整体右对齐。
class _MoreChoiceRow extends StatelessWidget {
  const _MoreChoiceRow({
    required this.icon,
    required this.title,
    required this.options,
    required this.selected,
    required this.onSelect,
  });

  final IconData icon;
  final String title;

  /// 档位列表：(持久化 key, 显示标签)。
  final List<(String, String)> options;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Icon(icon, size: 19, color: Fx.sub),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 56,
            child: Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: Fx.ink,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (key, label) in options)
                  _MoreChip(
                    label: label,
                    active: key == selected,
                    onTap: () => onSelect(key),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MoreChip extends StatelessWidget {
  const _MoreChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active ? Fx.accent : const Color(0xFFF3F6FC),
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: active ? Fx.accent : const Color(0xFFE7EDF7),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: active ? FontWeight.w700 : FontWeight.w600,
            color: active ? Colors.white : Fx.sub,
          ),
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

/// 定时关闭 · 自定义分钟输入框：1–1440，确认返回分钟数；取消返回 null。
Future<int?> showFxSleepCustomDialog(BuildContext context, {int current = 0}) {
  final controller = TextEditingController(
    text: current > 0 ? '$current' : '',
  );
  final formKey = GlobalKey<FormState>();
  return showDialog<int>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text(
        '自定义定时',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w800,
          color: Fx.ink,
        ),
      ),
      content: Form(
        key: formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '输入 1–1440 分钟，到点暂停播放并保留进度。',
              style: TextStyle(fontSize: 12, color: Fx.sub, height: 1.4),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              style: const TextStyle(fontSize: 15, color: Fx.ink),
              decoration: InputDecoration(
                labelText: '分钟',
                hintText: '例如 45',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              validator: (value) {
                final n = int.tryParse((value ?? '').trim());
                if (n == null || n < 1 || n > 1440) {
                  return '请输入 1–1440 的数字';
                }
                return null;
              },
              onFieldSubmitted: (_) {
                if (formKey.currentState?.validate() != true) return;
                Navigator.of(dialogContext)
                    .pop(int.parse(controller.text.trim()));
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('取消', style: TextStyle(color: Fx.sub)),
        ),
        TextButton(
          onPressed: () {
            if (formKey.currentState?.validate() != true) return;
            Navigator.of(dialogContext).pop(int.parse(controller.text.trim()));
          },
          child: const Text('确定', style: TextStyle(color: Fx.accent)),
        ),
      ],
    ),
  ).then((value) {
    controller.dispose();
    return value;
  });
}

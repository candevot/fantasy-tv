import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/fx_display_settings.dart';
import '../theme.dart';
import 'fs_side_panel.dart';

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

/// 腾讯视频样式的「更多」播放设置面板（竖屏与全屏共用）。
///
/// SIDE_PANEL（2026-11-20）：从**底部通栏弹层**改成**右侧竖排面板**。
///   · 壳：`FxSidePanel`（贴右、贯穿屏高、黑 72% + blur 18、只左两角圆角、
///     右上角 ×、点外部关闭），几何常量在 `fs_side_panel.dart`；
///   · 顶：定时关闭 / 下载本集 / 倍速 / 后台播放，4 列等宽「圆底图标 + 文字」；
///   · 下：循环播放 / 跳过片头片尾 / 画面比例 / 镜像模式 / 播放诊断 /
///     问题反馈，每行右侧是开关或箭头（档位行是选中片）；
///   · 整块在 `ListView` 里，内容多了自己上下滚。
///
/// 功能一项不少：定时关闭、下载本集、倍速、后台播放、循环播放、跳过片头片尾、
/// 画面比例、镜像模式、播放诊断、问题反馈全部保留（显隐语义没变）。
/// [onLoopChanged] / [onJumpPanel] / [onDownload] / [onSpeed] 传 null 时对应
/// 入口整块不显示（直播全屏没有下一集 / 片头尾 / 下载 / 倍速）。
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
  return showFxSidePanel<void>(
    context,
    builder: (_) => FxSidePanel(
      header: const Text(
        '播放设置',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w800,
          color: kFxSidePanelInk,
        ),
      ),
      child: _FxMoreBody(
        loopMode: loopMode,
        markLabel: markLabel,
        onLoopChanged: onLoopChanged,
        onJumpPanel: onJumpPanel,
        onSleepTimer: onSleepTimer,
        onDownload: onDownload,
        onSpeed: onSpeed,
        onBackground: onBackground,
        onFeedback: onFeedback,
        diagnosticsOn: diagnosticsOn,
        onDiagnosticsChanged: onDiagnosticsChanged,
      ),
    ),
  );
}

/// 播放设置面板主体：图标行 + 列表行，整块可滚。
class _FxMoreBody extends StatefulWidget {
  const _FxMoreBody({
    required this.loopMode,
    required this.markLabel,
    required this.onLoopChanged,
    required this.onJumpPanel,
    required this.onSleepTimer,
    required this.onDownload,
    required this.onSpeed,
    required this.onBackground,
    required this.onFeedback,
    required this.diagnosticsOn,
    required this.onDiagnosticsChanged,
  });

  final FxLoopMode loopMode;
  final String markLabel;
  final ValueChanged<FxLoopMode>? onLoopChanged;
  final VoidCallback? onJumpPanel;
  final VoidCallback onSleepTimer;
  final VoidCallback? onDownload;
  final VoidCallback? onSpeed;
  final VoidCallback onBackground;
  final VoidCallback onFeedback;
  final bool diagnosticsOn;
  final ValueChanged<bool>? onDiagnosticsChanged;

  @override
  State<_FxMoreBody> createState() => _FxMoreBodyState();
}

class _FxMoreBodyState extends State<_FxMoreBody> {
  late FxLoopMode _loop = widget.loopMode;
  late bool _diagnostics = widget.diagnosticsOn;
  // 画面比例 / 镜像模式是全局设置：这里只负责高亮，真正生效靠
  // FxDisplaySettings 通知所有播放画面重建（立即生效，不重载视频）。
  late FxAspectMode _aspect = FxDisplaySettings.instance.aspect;
  late FxMirrorMode _mirror = FxDisplaySettings.instance.mirror;

  /// 图标行是「打开另一个面板」的动作：先关掉本面板，再执行动作 ——
  /// 顺序反过来会让新面板被这个模态路由盖住。
  void _closeThen(VoidCallback action) {
    Navigator.of(context).maybePop();
    action();
  }

  @override
  Widget build(BuildContext context) {
    final loopChanged = widget.onLoopChanged;
    final jumpPanel = widget.onJumpPanel;
    final download = widget.onDownload;
    final speed = widget.onSpeed;
    final diagnosticsChanged = widget.onDiagnosticsChanged;
    // 面板宽度随屏幕变（横屏 336dp、手机竖屏全屏 180dp），左右内边距和
    // 图标圆底直径都按实际可用宽度算，窄屏也不会把 4 个图标挤成溢出。
    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth = constraints.maxWidth;
        final padH = contentWidth < 240 ? 14.0 : 20.0;
        final actions = <_SideActionData>[
          _SideActionData(
            Icons.timer_outlined,
            '定时关闭',
            () => _closeThen(widget.onSleepTimer),
          ),
          if (download != null)
            _SideActionData(
              Icons.download_rounded,
              '下载本集',
              () => _closeThen(download),
            ),
          if (speed != null)
            _SideActionData(
              Icons.speed_rounded,
              '倍速',
              () => _closeThen(speed),
            ),
          _SideActionData(
            Icons.headphones_rounded,
            '后台播放',
            () => _closeThen(widget.onBackground),
          ),
        ];
        // 4 列等宽：列宽 = 可用宽度 / 图标个数（直播只有 2 个就 2 列等分）。
        final column = (contentWidth - padH * 2) / actions.length;
        // 46dp 是设计值；列宽不够时缩到 28dp 为止。
        final circle = math.min(46.0, math.max(28.0, column - 6));
        return ListView(
          padding: EdgeInsets.fromLTRB(padH, 16, padH, 22),
          physics: const ClampingScrollPhysics(),
          children: [
            // ── 图标行：4 列等宽 ──
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final action in actions)
                  _SideAction(
                    icon: action.icon,
                    label: action.label,
                    size: circle,
                    onTap: action.onTap,
                  ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(height: 1, color: kFxSidePanelLine),
            if (loopChanged != null)
              _SideRow(
                icon: Icons.repeat_rounded,
                title: '循环播放',
                subtitle: _loop.label,
                trailing: _SideSwitch(
                  value: _loop == FxLoopMode.single,
                  onChanged: (on) {
                    final mode = on ? FxLoopMode.single : FxLoopMode.off;
                    setState(() => _loop = mode);
                    loopChanged(mode);
                  },
                ),
              ),
            if (jumpPanel != null)
              _SideRow(
                icon: Icons.bookmark_border_rounded,
                title: '跳过片头片尾',
                subtitle: widget.markLabel,
                trailing: const _SideChevron(),
                onTap: () => _closeThen(jumpPanel),
              ),
            _SideChoiceRow(
              icon: Icons.aspect_ratio_rounded,
              title: '画面比例',
              options: [
                for (final mode in FxAspectMode.values) (mode.key, mode.label),
              ],
              selected: _aspect.key,
              onSelect: (key) {
                final mode =
                    FxAspectMode.fromKey(key) ?? FxAspectMode.contain;
                setState(() => _aspect = mode);
                unawaited(FxDisplaySettings.instance.setAspect(mode));
              },
            ),
            _SideChoiceRow(
              icon: Icons.flip_rounded,
              title: '镜像模式',
              options: [
                for (final mode in FxMirrorMode.values) (mode.key, mode.label),
              ],
              selected: _mirror.key,
              onSelect: (key) {
                final mode = FxMirrorMode.fromKey(key) ?? FxMirrorMode.none;
                setState(() => _mirror = mode);
                unawaited(FxDisplaySettings.instance.setMirror(mode));
              },
            ),
            if (diagnosticsChanged != null)
              _SideRow(
                icon: Icons.monitor_heart_outlined,
                title: '播放诊断',
                // 开关就地翻转（面板不关）：用户可以马上看到浮层在画面上
                // 出现 / 消失。
                subtitle: _diagnostics ? '开' : '关',
                trailing: _SideSwitch(
                  value: _diagnostics,
                  onChanged: (on) {
                    setState(() => _diagnostics = on);
                    diagnosticsChanged(on);
                  },
                ),
              ),
            _SideRow(
              icon: Icons.feedback_outlined,
              title: '问题反馈',
              trailing: const _SideChevron(),
              onTap: () => _closeThen(widget.onFeedback),
            ),
          ],
        );
      },
    );
  }
}

/// 图标行的数据：图标 + 文字 + 动作。
class _SideActionData {
  const _SideActionData(this.icon, this.label, this.onTap);

  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

/// 图标行的一格：圆底图标 + 一行文字，宽度由 Row 等分给出。
class _SideAction extends StatelessWidget {
  const _SideAction({
    required this.icon,
    required this.label,
    required this.size,
    required this.onTap,
  });

  final IconData icon;
  final String label;

  /// 圆底直径（44–46 是设计值，窄面板会缩到 28）。
  final double size;
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
              width: size,
              height: size,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0x1AFFFFFF),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0x24FFFFFF)),
              ),
              child: Icon(icon, size: size * .48, color: kFxSidePanelInk),
            ),
            const SizedBox(height: 7),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: kFxSidePanelInk,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SideChevron extends StatelessWidget {
  const _SideChevron();

  @override
  Widget build(BuildContext context) {
    return const Icon(
      Icons.chevron_right_rounded,
      size: 18,
      color: kFxSidePanelSub,
    );
  }
}

/// 深色面板里的开关：紫轨道 + 白滑块。
class _SideSwitch extends StatelessWidget {
  const _SideSwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Switch(
      value: value,
      activeThumbColor: Colors.white,
      activeTrackColor: kFxSidePanelAccent,
      inactiveThumbColor: const Color(0xFFB7BECA),
      inactiveTrackColor: const Color(0x26FFFFFF),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onChanged: onChanged,
    );
  }
}

/// 列表一行：左图标 + 标题（+ 副标题），右侧开关或箭头。
class _SideRow extends StatelessWidget {
  const _SideRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 19, color: kFxSidePanelSub),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: kFxSidePanelInk,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: kFxSidePanelSub,
                        height: 1.25,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

/// 档位行：左图标 + 标题，下面是可点片（画面比例 / 镜像模式共用）。
///
/// 面板只有 300–340dp 宽，档位挤在同一行会被压成蚂蚁字，所以档位单独占
/// 一行放在标题下方，横向排不下就换行。
class _SideChoiceRow extends StatelessWidget {
  const _SideChoiceRow({
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
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 19, color: kFxSidePanelSub),
              const SizedBox(width: 10),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: kFxSidePanelInk,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (key, label) in options)
                _SideChip(
                  label: label,
                  active: key == selected,
                  onTap: () => onSelect(key),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SideChip extends StatelessWidget {
  const _SideChip({
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: active ? kFxSidePanelAccent : const Color(0x1AFFFFFF),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active ? kFxSidePanelAccent : const Color(0x24FFFFFF),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: active ? FontWeight.w700 : FontWeight.w600,
            color: active ? Colors.white : kFxSidePanelSub,
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

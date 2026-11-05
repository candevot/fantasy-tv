import 'dart:async';

import 'package:flutter/material.dart';

import '../services/screen_fit.dart';
import '../theme.dart';

/// 播放设置面板里的「画面」一行：点开显示充满 / 适应 / 拉伸三档，当前档高亮。
///
/// 选中后通过 [ScreenFitStore] 立即生效并持久化；竖屏和全屏播放器监听同一个
/// notifier，不会因为切换画面模式重新加载视频。
class ScreenFitSelector extends StatefulWidget {
  const ScreenFitSelector({super.key});

  @override
  State<ScreenFitSelector> createState() => _ScreenFitSelectorState();
}

class _ScreenFitSelectorState extends State<ScreenFitSelector> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ScreenFit>(
      valueListenable: ScreenFitStore.notifier,
      builder: (context, fit, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    const Icon(Icons.aspect_ratio_rounded,
                        size: 19, color: Fx.sub),
                    const SizedBox(width: 8),
                    const Text(
                      '画面',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: Fx.ink,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Fx.accent.withOpacity(.10),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        fit.label,
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: Fx.accent,
                        ),
                      ),
                    ),
                    const Spacer(),
                    AnimatedRotation(
                      turns: _expanded ? .5 : 0,
                      duration: const Duration(milliseconds: 160),
                      child: const Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 21,
                        color: Fx.sub,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final option in ScreenFit.values)
                    ChipTag(
                      option.label,
                      active: option == fit,
                      onTap: () => unawaited(ScreenFitStore.set(option)),
                    ),
                ],
              ),
              const SizedBox(height: 7),
              Text(
                fit.description,
                style: const TextStyle(fontSize: 11, color: Fx.sub),
              ),
            ],
            const SizedBox(height: 3),
          ],
        );
      },
    );
  }
}

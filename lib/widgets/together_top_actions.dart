import 'package:flutter/material.dart';

import '../theme.dart';

/* ========================================================================== */
/*  一起看 · 顶栏动作区自适应（TOPBAR_44 / 2026-11-16）                        */
/*                                                                            */
/*  现场：横屏全屏顶部把「1人 / 邀请 / 投屏 / 我在操作 / 换源 / 换剧」挤成一排， */
/*  字号和热区都极小，手指点不准。根因是右侧整组被塞进 `FittedBox(scaleDown)`  */
/*  —— 空间一不够就**等比缩小**，字和图标一起缩，最小能到 7~8sp、热区十几 dp。 */
/*                                                                            */
/*  现在改成「按屏宽自适应」：                                                 */
/*    · 不再用 FittedBox 缩放，字号与热区永远是硬规格（12.5sp / 44dp）；        */
/*    · 放不下时把低优先级的收进「更多」菜单，而不是把所有人一起缩小；          */
/*    · 「换源」「换剧」标 always，任何屏宽都直接可见（高频操作）。              */
/* ========================================================================== */

/// 顶栏动作的硬规格：热区最小 44dp，字号不小于 12sp。
const double kTogetherActionHit = 44;
const double kTogetherActionFont = 12.5;
const double kTogetherActionHeight = 32;
const double kTogetherActionSpacing = 6;

/// 一个顶栏动作：宽度预算用于「放不放得下」的判定。
class TogetherActionSpec {
  const TogetherActionSpec({
    required this.id,
    required this.width,
    required this.priority,
    this.always = false,
  });

  final String id;

  /// 该动作占用的水平宽度（dp，含内边距）。用 [togetherPillWidth] 估算。
  final double width;

  /// 越小越重要：空间不够时从大到小往「更多」里收。
  final int priority;

  /// 无论如何都要直接显示（换源 / 换剧）。
  final bool always;
}

/// 自适应结果：哪些直接排在外面、哪些收进「更多」、要不要降级成图标。
class TogetherActionFit {
  const TogetherActionFit({
    required this.visible,
    required this.overflow,
    this.iconOnly = false,
  });

  final List<String> visible;
  final List<String> overflow;

  /// 常驻项（换源 / 换剧 / 邀请）是否降级成「只有图标」。
  ///
  /// TOPBAR_44 的第二级：竖屏 360dp 时三个文字胶囊（约 201dp）放不下，
  /// 但三个图标钮只要 144dp。降级只去掉文字（Tooltip 仍在），
  /// **热区和字号规格一个都不动** —— 这是「不缩放」的前提。
  final bool iconOnly;

  bool get hasOverflow => overflow.isNotEmpty;
}

/// 估算一个「图标 + 文字」胶囊的宽度（与 [TogetherTopPill] 同一套内边距）。
double togetherPillWidth(
  String text, {
  IconData? icon,
  double fontSize = kTogetherActionFont,
  double horizontalPadding = 10,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w600),
    ),
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
  )..layout();
  final textWidth = painter.width;
  painter.dispose();
  final iconWidth = icon == null ? 0.0 : 14 + 4;
  return (textWidth + iconWidth + horizontalPadding * 2).ceilToDouble();
}

/// 按可用宽度决定「谁排在外面、谁进更多、要不要只留图标」。
///
/// 三级降级，**顺序固定**（越往后越省空间，但永远不缩小字号/热区）：
///   1. 全部带文字 + 放不下的进「更多」；
///   2. 常驻项（always）只留图标，可选项继续按优先级尝试带文字；
///   3. 常驻项只留图标 + 可选项全部进「更多」。
TogetherActionFit togetherFitActions({
  required List<TogetherActionSpec> items,
  required double available,
  double spacing = kTogetherActionSpacing,
  double moreWidth = kTogetherActionHit,
  double iconWidth = kTogetherActionHit,
}) {
  final always = <TogetherActionSpec>[
    for (final item in items)
      if (item.always) item,
  ];
  final optional = <TogetherActionSpec>[
    for (final item in items)
      if (!item.always) item,
  ]..sort((a, b) => a.priority.compareTo(b.priority));

  /// 在给定宽度下做一次「谁进更多」的分配，返回 (可见, 溢出, 总宽)。
  (List<TogetherActionSpec>, List<TogetherActionSpec>, double) distribute(
    List<TogetherActionSpec> alwaysRow,
    List<TogetherActionSpec> optionalRow,
  ) {
    double rowWidth(List<TogetherActionSpec> row) => row.isEmpty
        ? 0
        : row.fold<double>(0, (a, b) => a + b.width) +
              spacing * (row.length - 1);

    if (rowWidth(<TogetherActionSpec>[...alwaysRow, ...optionalRow]) <=
        available) {
      return (
        <TogetherActionSpec>[...alwaysRow, ...optionalRow],
        const <TogetherActionSpec>[],
        rowWidth(<TogetherActionSpec>[...alwaysRow, ...optionalRow]),
      );
    }
    final kept = <TogetherActionSpec>[...optionalRow];
    final dropped = <TogetherActionSpec>[];
    while (true) {
      final row = <TogetherActionSpec>[...alwaysRow, ...kept];
      final needsMore = dropped.isNotEmpty;
      final width =
          rowWidth(row) +
          (needsMore ? (row.isEmpty ? 0 : spacing) + moreWidth : 0);
      if (width <= available || kept.isEmpty) {
        return (row, dropped, width);
      }
      dropped.insert(0, kept.removeLast());
    }
  }

  // 第 1 级：所有项都带文字。
  final full = distribute(always, optional);
  if (full.$3 <= available && full.$2.isEmpty) {
    return TogetherActionFit(
      visible: <String>[for (final item in full.$1) item.id],
      overflow: const <String>[],
    );
  }

  // 第 2 级：常驻项降级成图标（宽度压到 iconWidth），可选项照旧尝试文字。
  final alwaysIcon = <TogetherActionSpec>[
    for (final item in always)
      TogetherActionSpec(
        id: item.id,
        width: iconWidth,
        priority: item.priority,
        always: true,
      ),
  ];
  final withIcon = distribute(alwaysIcon, optional);
  if (withIcon.$3 <= available) {
    return TogetherActionFit(
      visible: <String>[for (final item in withIcon.$1) item.id],
      overflow: <String>[for (final item in withIcon.$2) item.id],
      iconOnly: true,
    );
  }

  // 第 3 级：常驻图标 + 可选项全部进「更多」。
  final iconsOnly = distribute(alwaysIcon, const <TogetherActionSpec>[]);
  return TogetherActionFit(
    visible: <String>[for (final item in iconsOnly.$1) item.id],
    overflow: <String>[for (final item in optional) item.id],
    iconOnly: true,
  );
}

/// 竖屏房间页顶栏给动作区留的宽度预算。
///
/// TOPBAR_44：不能靠「Row + Expanded」让两侧平分 —— 左侧房间号是弹性的，
/// Expanded 会把剩余空间全吃掉，动作区永远只拿到三分之一，于是 480dp 屏
/// 也把「1人」挤进「更多」。这里按屏宽直接算预算：
///   返回键 36 + 间距 4 + 左侧最小需求（房间号 55 + 复制 13 + 状态 25 + 间隔 11）
/// = 144dp 固定开销，其余全部给动作区（上限 480，避免大屏把动作拉散）。
///
/// 屏幕太窄时预算会小于「邀请 / 换源 / 换剧」三个胶囊的宽度，
/// [TogetherTopActionBar] 内部改用 Wrap 换行 —— 依然不缩放、热区依然 44dp。
double togetherHeaderActionsBudget(double screenWidth) {
  // 左侧固定开销：返回 36 + 间距 2 + 房间号（最长 6 位数字 ≈ 62）+ 复制图标 13
  // + 房间号与复制之间的 3 + 右侧留白 10 ≈ 126。
  //
  // 注意：不要「故意留小」去逼动作区换行 —— Wrap 一旦换行，顶栏高度会从
  // 44 变成 94+，整个房间页被顶下去。三级降级（文字 → 图标 → 更多）就是
  // 为了在**一行之内**消化窄屏。
  final budget = screenWidth - 126;
  if (budget < kTogetherActionHit) return kTogetherActionHit;
  if (budget > 480) return 480;
  return budget;
}

/// 一个动作的渲染数据（图标 + 文字 + 回调）。
class TogetherActionItem {
  const TogetherActionItem({
    required this.id,
    required this.label,
    required this.icon,
    required this.onTap,
    this.priority = 0,
    this.always = false,
    this.active = false,
    this.showLabel = false,
  });

  final String id;
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final int priority;
  final bool always;
  final bool active;

  /// 只画图标（换源 / 换剧这类高频项，图标已足够识别，省宽度）。
  final bool showLabel;

  /// 真实占位宽度：视觉胶囊宽，但**不小于 44dp 热区**（热区盒子会撑开布局）。
  TogetherActionSpec toSpec(TextScaler scaler) {
    final visual = showLabel
        ? togetherPillWidth(label, icon: icon, textScaler: scaler)
        : kTogetherActionHit;
    return TogetherActionSpec(
      id: id,
      width: visual < kTogetherActionHit ? kTogetherActionHit : visual,
      priority: priority,
      always: always,
    );
  }
}

/// 顶栏动作区：一行放得下就一行，放不下把次要项收进「更多」。
///
/// 任何一项的热区都不小于 [kTogetherActionHit]（44dp），字号不小于
/// [kTogetherActionFont]（12.5sp）—— 这是本组件存在的唯一理由，不要改小。
class TogetherTopActionBar extends StatelessWidget {
  const TogetherTopActionBar({
    super.key,
    required this.actions,
    this.dark = true,
    this.maxWidth,
  });

  final List<TogetherActionItem> actions;

  /// 深色（盖在画面上）或浅色（房间页白玻璃）。
  final bool dark;

  /// 外部给定的可用宽度；为空时取屏幕宽度（全屏顶栏就是这种情况）。
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    if (actions.isEmpty) return const SizedBox.shrink();
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final available =
            maxWidth ??
            (constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : MediaQuery.sizeOf(context).width);
        final fit = togetherFitActions(
          items: <TogetherActionSpec>[
            for (final action in actions) action.toSpec(scaler),
          ],
          available: available,
        );
        final byId = <String, TogetherActionItem>{
          for (final action in actions) action.id: action,
        };
        // iconOnly：只去掉文字（Tooltip 保留），热区与字号规格不变。
        Widget pill(TogetherActionItem item) => TogetherTopActionButton(
          item: fit.iconOnly && item.always
              ? TogetherActionItem(
                  id: item.id,
                  label: item.label,
                  icon: item.icon,
                  onTap: item.onTap,
                  priority: item.priority,
                  always: item.always,
                  active: item.active,
                  showLabel: false,
                )
              : item,
          dark: dark,
        );
        // 三级降级之后正常情况下一定单行；Wrap 只是最后的兜底
        // （极端窄屏 / 超大字体缩放），此时宁可换行也不缩放。
        //
        // 用 Row(mainAxisSize: min) 而不是 Wrap 做主排布：Wrap 会给每个
        // 子项「整行可用宽度」作为约束，我们这几个按钮的 Tooltip / Center
        // 包装就会贪心地吃满，于是每个按钮独占一行（实测 320dp → 4 行）。
        // Row(min) 下每个子项按自身宽度排，单行是自然结果；
        // 真放不下时由外层的三级降级保证不换行。
        // 再包一层 Align：动作条自己按内容宽度（Row.min）排，但对外占位
        // 由外层 Row/Flexible 决定；Align 让它在给定宽度里靠右，不会把
        // 左侧的房间号 / 状态挤掉。
        // 高度固定一行 44dp：让外层 Row（房间页顶栏）能按 44 排版，
        // 也不会被 parent 的高度（比如整屏 600）拉满。
        return SizedBox(
          height: kTogetherActionHit,
          child: Align(
            alignment: Alignment.centerRight,
            widthFactor: 1,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                for (final id in fit.visible)
                  if (byId[id] != null) ...<Widget>[
                    if (id != fit.visible.first)
                      const SizedBox(width: kTogetherActionSpacing),
                    pill(byId[id]!),
                  ],
                if (fit.hasOverflow) ...<Widget>[
                  const SizedBox(width: kTogetherActionSpacing),
                  TogetherTopMoreButton(
                    dark: dark,
                    items: <TogetherActionItem>[
                      for (final id in fit.overflow)
                        if (byId[id] != null) byId[id]!,
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 单个动作：视觉胶囊 32dp，**热区 44dp**，字号 12.5sp 不缩放。
class TogetherTopActionButton extends StatelessWidget {
  const TogetherTopActionButton({
    super.key,
    required this.item,
    this.dark = true,
  });

  final TogetherActionItem item;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final fg = dark ? Colors.white : Fx.ink.withValues(alpha: .86);
    final bg = item.active
        ? (dark ? Fx.accent.withValues(alpha: .82) : Fx.accent)
        : (dark
              ? Colors.black.withValues(alpha: .42)
              : Colors.white.withValues(alpha: .9));
    final border = dark
        ? Colors.white.withValues(alpha: .26)
        : Colors.white.withValues(alpha: .96);
    final visual = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: item.onTap,
      child: Container(
        height: kTogetherActionHeight,
        padding: EdgeInsets.symmetric(horizontal: item.showLabel ? 10 : 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(kTogetherActionHeight / 2),
          border: Border.all(color: border, width: 1),
          boxShadow: dark
              ? null
              : <BoxShadow>[
                  BoxShadow(
                    color: const Color(0xFF263A5A).withValues(alpha: .14),
                    blurRadius: 12,
                    offset: const Offset(0, 3),
                  ),
                ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(item.icon, size: 15, color: item.active ? Colors.white : fg),
            if (item.showLabel) ...<Widget>[
              const SizedBox(width: 4),
              Text(
                item.label,
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                  fontSize: kTogetherActionFont,
                  height: 1.1,
                  fontWeight: FontWeight.w700,
                  color: item.active ? Colors.white : fg,
                ),
              ),
            ],
          ],
        ),
      ),
    );
    // 热区：视觉 32，命中框 44（只放大不可见区域，视觉尺寸不变）。
    //
    // TOPBAR_44_LAYOUT：这里必须用 **SizedBox(width/height)** 直接把热区盒子
    // 撑成 44×44，不能用外层 `SizedBox(height: 44) + Center` —— 放进 Wrap
    // 之后它会拿到整行宽度，每个按钮独占一行，顶栏被撑成 4 行（实测
    // 320dp 屏 barH=194）。宽度必须显式给出，Wrap 才排得下。
    // 布局要点（TOPBAR_44_LAYOUT，实测踩过三个坑，别再改回这些写法）：
    //   · `SizedBox(width: 44)`：带文字的胶囊（约 64dp）会被挤到 overflow；
    //   · `Center(child:)` **不带 widthFactor**：在 Wrap 里会吃满整行，
    //     每个按钮独占一行，顶栏被撑成 4 行（320dp 屏 barH=194）；
    //   · 用估算宽度硬写 width：估算和真实字宽差 3px 就溢出。
    // 正解是 `ConstrainedBox(minWidth: 44, minHeight: 44)` + `Center(widthFactor: 1)`：
    // 宽度跟随内容、不小于 44dp，Wrap 里也不会撑满。
    // Tooltip 放在**内层**：它自己会包一层可以撑满父级的布局，放在 Wrap
    // 的直接子项位置会把每个按钮撑成整行（实测 barH 从 44 → 194）。
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minWidth: kTogetherActionHit,
        minHeight: kTogetherActionHit,
      ),
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: Tooltip(message: item.label, child: visual),
      ),
    );
  }
}

/// 「更多」：把放不下的动作收进一个菜单，菜单项同样 44dp 热区 / 12.5sp。
class TogetherTopMoreButton extends StatelessWidget {
  const TogetherTopMoreButton({
    super.key,
    required this.items,
    this.dark = true,
  });

  final List<TogetherActionItem> items;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final fg = dark ? Colors.white : Fx.ink.withValues(alpha: .86);
    return SizedBox(
      height: kTogetherActionHit,
      child: PopupMenuButton<String>(
        tooltip: '更多',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 168, maxWidth: 240),
        color: dark ? const Color(0xF01B1F27) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        onSelected: (id) {
          for (final item in items) {
            if (item.id == id) item.onTap();
          }
        },
        itemBuilder: (context) => <PopupMenuEntry<String>>[
          for (final item in items)
            PopupMenuItem<String>(
              value: item.id,
              height: kTogetherActionHit,
              child: Row(
                children: <Widget>[
                  Icon(
                    item.icon,
                    size: 17,
                    color: dark
                        ? Colors.white.withValues(alpha: .86)
                        : Fx.ink.withValues(alpha: .8),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    item.label,
                    style: TextStyle(
                      fontSize: kTogetherActionFont + .5,
                      fontWeight: FontWeight.w600,
                      color: dark ? Colors.white : Fx.ink,
                    ),
                  ),
                ],
              ),
            ),
        ],
        child: Container(
          height: kTogetherActionHit,
          width: kTogetherActionHit,
          alignment: Alignment.center,
          child: Container(
            height: kTogetherActionHeight,
            width: kTogetherActionHeight,
            decoration: BoxDecoration(
              color: dark
                  ? Colors.black.withValues(alpha: .42)
                  : Colors.white.withValues(alpha: .9),
              shape: BoxShape.circle,
              border: Border.all(
                color: dark
                    ? Colors.white.withValues(alpha: .26)
                    : Colors.white.withValues(alpha: .96),
                width: 1,
              ),
            ),
            child: Icon(Icons.more_horiz_rounded, size: 17, color: fg),
          ),
        ),
      ),
    );
  }
}

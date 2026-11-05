import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../theme.dart';
import 'together_ui.dart';

/* ========================================================================== */
/*  一起看 · 房间弹层（成员 / 邀请 / 换剧·选集菜单 / 清晰度 / 线路 / 倍速）      */
/*  样式与房间页一致：白色液态玻璃 + 深色字，不依赖全屏黑色面板。               */
/* ========================================================================== */

/// 房间右上角「换剧/选集」菜单动作。
enum TogetherRoomMenuAction { episodes, changeDrama, quality, line, speed }

/// 房间成员弹层（竖屏与全屏顶栏共用）。
Future<void> showTogetherMembers(
  BuildContext context, {
  required List<TogetherMember> members,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: true,
    barrierColor: Colors.black.withOpacity(.30),
    builder: (ctx) => SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(ctx).height * .64,
        ),
        decoration: BoxDecoration(
          color: const Color(0xFFF9FBFF),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '房间成员',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: Fx.ink,
                    ),
                  ),
                ),
                Text(
                  '${members.length} 人',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: Fx.sub.withOpacity(.9),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              child: members.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 26),
                      child: Text(
                        '暂无成员',
                        style: TextStyle(
                          fontSize: 12,
                          color: Fx.sub.withOpacity(.75),
                        ),
                      ),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final member in members)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 5),
                            child: Row(
                              children: [
                                TogetherAvatar(
                                  name: member.name,
                                  avatar: member.avatar,
                                  size: 30,
                                  host: member.host,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    member.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w600,
                                      color: Fx.ink,
                                    ),
                                  ),
                                ),
                                if (member.host)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Fx.gold.withOpacity(.16),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Text(
                                      '房主',
                                      style: TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.w700,
                                        color: Color(0xFF9A6A00),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
            ),
            const SizedBox(height: 4),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(ctx).pop(),
              child: Container(
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(.9),
                  borderRadius: BorderRadius.circular(19),
                ),
                child: const Text(
                  '关闭',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: Fx.sub,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 邀请弹层：大号房间号 + 邀请文案 + 一键复制。
Future<void> showTogetherInvite(
  BuildContext context, {
  required String code,
  required String title,
}) async {
  if (code.isEmpty) {
    togetherToast(context, '房间号还没准备好，请稍候');
    return;
  }
  final invite =
      '我在幻想影视一起看《${title.trim().isEmpty ? '一起看' : title.trim()}》，房间号 $code，打开 App 输入房间号加入';
  var copied = false;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        backgroundColor: Colors.white.withOpacity(.98),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
        contentPadding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
        title: const Row(
          children: [
            Icon(Icons.celebration_rounded, size: 20, color: Fx.accent),
            SizedBox(width: 8),
            Text(
              '邀请好友一起看',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: Fx.ink,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Fx.accent.withOpacity(.10),
                    Fx.accent2.withOpacity(.10),
                  ],
                ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white),
              ),
              child: Column(
                children: [
                  const Text(
                    '房间号',
                    style: TextStyle(fontSize: 10.5, color: Fx.sub),
                  ),
                  const SizedBox(height: 3),
                  SelectableText(
                    code,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w900,
                      color: Fx.ink,
                      letterSpacing: 6,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF4F7FC),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                invite,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: Fx.sub,
                ),
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              '复制后发给好友，对方打开 App 输入房间号即可加入',
              style: TextStyle(fontSize: 10, color: Color(0xFFA6B1C2)),
            ),
            const SizedBox(height: 14),
            GradButton(
              text: copied ? '已复制' : '复制邀请文案',
              icon: copied ? Icons.check_rounded : Icons.copy_all_rounded,
              height: 44,
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: invite));
                if (!ctx.mounted) return;
                setLocal(() => copied = true);
                togetherToast(ctx, '邀请文案已复制');
              },
            ),
          ],
        ),
        actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text(
              '关闭',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Fx.sub,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// 换剧 / 选集 / 清晰度 / 线路 / 倍速 菜单（仅房主会打开）。
Future<TogetherRoomMenuAction?> showTogetherRoomMenu(
  BuildContext context, {
  required String epLabel,
  required String qualityLabel,
  required String lineLabel,
  required double rate,
  bool hasEpisodes = true,
  bool hasQuality = true,
  bool hasLines = true,
}) {
  return showModalBottomSheet<TogetherRoomMenuAction>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: true,
    barrierColor: Colors.black.withOpacity(.28),
    builder: (ctx) => SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: const BoxDecoration(
          color: Color(0xFFF9FBFF),
          borderRadius: BorderRadius.all(Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SheetTile(
              icon: Icons.movie_filter_rounded,
              title: '换一部剧',
              subtitle: '选一部新片，所有人一起切换',
              onTap: () =>
                  Navigator.of(ctx).pop(TogetherRoomMenuAction.changeDrama),
            ),
            _SheetTile(
              icon: Icons.list_alt_rounded,
              title: '选集',
              subtitle: hasEpisodes ? '当前 $epLabel' : '暂无剧集信息',
              onTap: hasEpisodes
                  ? () => Navigator.of(ctx).pop(TogetherRoomMenuAction.episodes)
                  : null,
            ),
            _SheetTile(
              icon: Icons.high_quality_rounded,
              title: '清晰度',
              subtitle: hasQuality ? '当前 $qualityLabel' : '当前线路暂无更多清晰度',
              onTap: hasQuality
                  ? () => Navigator.of(ctx).pop(TogetherRoomMenuAction.quality)
                  : null,
            ),
            _SheetTile(
              icon: Icons.alt_route_rounded,
              title: '播放线路',
              subtitle: hasLines ? '当前 $lineLabel' : '暂无其他线路',
              onTap: hasLines
                  ? () => Navigator.of(ctx).pop(TogetherRoomMenuAction.line)
                  : null,
            ),
            _SheetTile(
              icon: Icons.speed_rounded,
              title: '倍速',
              subtitle: '当前 ${togetherRateLabel(rate)}，仅房主可调',
              onTap: () => Navigator.of(ctx).pop(TogetherRoomMenuAction.speed),
            ),
            _SheetTile(
              icon: Icons.close_rounded,
              title: '取消',
              subtitle: '',
              onTap: () => Navigator.of(ctx).pop(),
            ),
          ],
        ),
      ),
    ),
  );
}

class _SheetTile extends StatelessWidget {
  const _SheetTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? .45 : 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Fx.accent.withOpacity(.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 17, color: Fx.accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Fx.ink,
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 9.5,
                          color: Fx.sub.withOpacity(.9),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (onTap != null)
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: Fx.sub,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String togetherRateLabel(double rate) {
  if ((rate - rate.roundToDouble()).abs() < .0001) {
    return '${rate.toStringAsFixed(1)}x';
  }
  return '${rate}x';
}

/// 清晰度弹层「主播放地址」的哨兵值；页面收到后映射回 null。
const String togetherDefaultQualityKey = '__default__';

/// 清晰度选择（浅色弹层），返回选中的 key；null 表示取消，
/// [togetherDefaultQualityKey] 表示切回主播放地址。
Future<String?> showTogetherQualitySheet(
  BuildContext context, {
  required List<QualityItem> items,
  required String? currentKey,
}) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    barrierColor: Colors.black.withOpacity(.28),
    builder: (ctx) => SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
        decoration: const BoxDecoration(
          color: Color(0xFFF9FBFF),
          borderRadius: BorderRadius.all(Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '清晰度',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: Fx.ink,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '切换后保持当前播放进度；仅房主可选择',
              style: TextStyle(fontSize: 10.5, color: Fx.sub),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _ChoiceChip(
                  label: '默认',
                  active: currentKey == null,
                  onTap: () => Navigator.of(ctx).pop(togetherDefaultQualityKey),
                ),
                for (final q in items)
                  _ChoiceChip(
                    label: q.name.trim().isEmpty ? q.key : q.name.trim(),
                    active: currentKey == q.key,
                    onTap: () => Navigator.of(ctx).pop(q.key),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// 线路选择，返回线路 id；null 表示取消。
Future<String?> showTogetherLineSheet(
  BuildContext context, {
  required List<LineInfo> lines,
  required String current,
}) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    barrierColor: Colors.black.withOpacity(.28),
    builder: (ctx) => SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(ctx).height * .6,
        ),
        decoration: const BoxDecoration(
          color: Color(0xFFF9FBFF),
          borderRadius: BorderRadius.all(Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '播放线路',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: Fx.ink,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '换线路后所有人一起切换；仅房主可选择',
              style: TextStyle(fontSize: 10.5, color: Fx.sub),
            ),
            const SizedBox(height: 10),
            Flexible(
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final line in lines)
                      _ChoiceChip(
                        label: line.displayName.trim().isEmpty
                            ? line.id
                            : line.displayName,
                        active: current == line.id,
                        onTap: () => Navigator.of(ctx).pop(line.id),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 倍速选择，返回倍速；null 表示取消。
Future<double?> showTogetherSpeedSheet(
  BuildContext context, {
  required double current,
}) {
  const options = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
  return showModalBottomSheet<double>(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    barrierColor: Colors.black.withOpacity(.28),
    builder: (ctx) => SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
        decoration: const BoxDecoration(
          color: Color(0xFFF9FBFF),
          borderRadius: BorderRadius.all(Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  '倍速',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: Fx.ink,
                  ),
                ),
                const Spacer(),
                Text(
                  '当前 ${togetherRateLabel(current)}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Fx.accent,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              '仅房主可调整；成员始终跟随房主播放',
              style: TextStyle(fontSize: 10.5, color: Fx.sub),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final rate in options)
                  _ChoiceChip(
                    label: togetherRateLabel(rate),
                    active: (current - rate).abs() < .001,
                    onTap: () => Navigator.of(ctx).pop(rate),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({
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
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: BoxDecoration(
          color: active ? Fx.accent : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active ? Fx.accent : const Color(0xFFE4EAF4),
          ),
          boxShadow: [
            BoxShadow(
              color: Fx.accent.withOpacity(active ? .28 : .04),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.w700 : FontWeight.w600,
            color: active ? Colors.white : Fx.sub,
          ),
        ),
      ),
    );
  }
}

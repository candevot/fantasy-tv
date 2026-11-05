import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../theme.dart';
import 'fx_cards.dart';

/// 一起看房间页统一的时间常量。
///
/// 覆盖控件 3 秒自动隐藏（房间页规格；播放页的 5 秒常量不在这里复用）；
/// 锁屏后解锁钮同样只亮 3 秒。
const Duration togetherControlsAutoHide = Duration(seconds: 3);
const Duration togetherUnlockAutoHide = Duration(seconds: 3);

/// 全屏一起看沿用播放器全屏的 5 秒自动隐藏；竖屏房间视频区用 3 秒。
const Duration togetherFullscreenControlsAutoHide = Duration(seconds: 5);

/// 竖屏房间视频区的固定高度：屏高 32%，不随键盘变化，最低 220dp。
const double togetherRoomVideoRatio = .32;
const double togetherRoomVideoMin = 220;

/// 房间聊天空态文案（规格固定）。
const String togetherChatEmptyText = '暂无消息，说点什么吧';

/// 封面地址归一：服务器可能返回相对地址（/api/proxy?u=…），
/// data URI 和已是绝对地址的保持原样。
String togetherCoverUrl(String cover) {
  final raw = cover.trim();
  if (raw.isEmpty) return '';
  if (raw.startsWith('data:') ||
      raw.startsWith('http://') ||
      raw.startsWith('https://')) {
    return raw;
  }
  return Api.abs(raw);
}

/// 一起看 · 通用数据与小部件。
///
/// 这一层不依赖一起看的网络/播放状态，入口、房间、选片弹层共用。
class TogetherMember {
  const TogetherMember({
    required this.id,
    required this.name,
    this.avatar = '',
    this.host = false,
  });

  final String id;
  final String name;
  final String avatar;
  final bool host;

  factory TogetherMember.fromJson(Map<String, dynamic> j) {
    final rawHost = j['host'];
    return TogetherMember(
      id: '${j['id'] ?? ''}',
      name: '${j['name'] ?? '影迷'}',
      avatar: '${j['avatar'] ?? ''}',
      host: rawHost == true || rawHost == 1 || rawHost == 'true',
    );
  }
}

const _coverPalette = <Color>[
  Color(0xFF5B8CFF),
  Color(0xFF8E6BFF),
  Color(0xFF39B7B0),
  Color(0xFFF08A5D),
  Color(0xFFE45D8E),
  Color(0xFF6E8BFF),
  Color(0xFF44A6E8),
  Color(0xFFB67CFF),
];

/// 由片名 / 房间号稳定生成渐变色，保证没有封面时也好看。
Color togetherColor(String seed) {
  if (seed.isEmpty) return _coverPalette.first;
  var hash = 0;
  for (var i = 0; i < seed.length; i++) {
    hash = 0x1fffffff & (hash + seed.codeUnitAt(i));
    hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
    hash ^= hash >> 6;
  }
  return _coverPalette[hash.abs() % _coverPalette.length];
}

BoxDecoration togetherGlass({
  double radius = 20,
  double opacity = .66,
  Color? tint,
  Border? border,
}) {
  final base = tint ?? Colors.white;
  return BoxDecoration(
    color: base.withOpacity(opacity),
    borderRadius: BorderRadius.circular(radius),
    border:
        border ?? Border.all(color: Colors.white.withOpacity(.92), width: 1),
    boxShadow: [
      BoxShadow(
        color: const Color(0xFF50729F).withOpacity(.10),
        blurRadius: 26,
        offset: const Offset(0, 8),
      ),
    ],
  );
}

/// 白色玻璃圆钮（返回 / 刷新 / 房间号等）。
class TogetherCircleButton extends StatelessWidget {
  const TogetherCircleButton({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 36,
    this.iconSize = 18,
    this.tooltip,
    this.active = false,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final String? tooltip;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final button = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration:
            togetherGlass(radius: size / 2, opacity: active ? .92 : .72),
        child: Icon(
          icon,
          size: iconSize,
          color: active ? Fx.accent : Fx.ink.withOpacity(.82),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// 白色玻璃胶囊（换剧 / 选集 / 邀请）。
class TogetherPill extends StatelessWidget {
  const TogetherPill({
    super.key,
    required this.text,
    this.icon,
    this.onTap,
    this.locked = false,
    this.height = 32,
    this.accent = false,
  });

  final String text;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool locked;
  final double height;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: accent
            ? BoxDecoration(
                gradient: Fx.brand,
                borderRadius: BorderRadius.circular(height / 2),
                boxShadow: [
                  BoxShadow(
                    color: Fx.accent.withOpacity(.28),
                    blurRadius: 14,
                    offset: const Offset(0, 5),
                  ),
                ],
              )
            : BoxDecoration(
                color: Colors.white.withOpacity(.86),
                borderRadius: BorderRadius.circular(height / 2),
                border: Border.all(color: Colors.white.withOpacity(.96)),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF263A5A).withOpacity(.14),
                    blurRadius: 12,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 14,
                color: accent ? Colors.white : Fx.ink.withOpacity(.78),
              ),
              const SizedBox(width: 4),
            ],
            Text(
              text,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: accent ? Colors.white : Fx.ink.withOpacity(.86),
              ),
            ),
            if (locked) ...[
              const SizedBox(width: 3),
              Icon(
                Icons.lock_outline_rounded,
                size: 11,
                color: accent ? Colors.white70 : Fx.sub.withOpacity(.7),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 头像：服务端头像是 SVG data URI，Flutter 原生画不了，因此统一用昵称首字渐变头像；
/// 房主在右上角带皇冠。
class TogetherAvatar extends StatelessWidget {
  const TogetherAvatar({
    super.key,
    required this.name,
    this.avatar = '',
    this.size = 32,
    this.host = false,
    this.ring = false,
  });

  final String name;
  final String avatar;
  final double size;
  final bool host;
  final bool ring;

  @override
  Widget build(BuildContext context) {
    final color = togetherColor(name);
    final trimmed = name.trim();
    final initial = trimmed.isEmpty ? '影' : trimmed.characters.first;
    final image = avatar.startsWith('http://') || avatar.startsWith('https://')
        ? FxNetworkImage(
            url: avatar,
            width: size,
            height: size,
            cacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                .round()
                .clamp(24, 512),
            fit: BoxFit.cover,
            fallback: _fallback(initial, color),
          )
        : _fallback(initial, color);

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            padding: ring ? const EdgeInsets.all(1.6) : EdgeInsets.zero,
            decoration: ring
                ? const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: Fx.brand,
                  )
                : null,
            child: ClipOval(child: image),
          ),
          if (host)
            Positioned(
              right: -4,
              top: -5,
              child: Container(
                width: 16,
                height: 16,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Fx.gold.withOpacity(.35),
                      blurRadius: 5,
                    ),
                  ],
                ),
                child:
                    const Text('👑', style: TextStyle(fontSize: 10, height: 1)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _fallback(String initial, Color color) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color, Color.lerp(color, Fx.accent2, .5) ?? color],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * .42,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 海报封面：与首页 / 分类共用 [FxCover]，统一走图片代理，
/// 加载中灰底微光、失败灰底影片图标。
class TogetherCover extends StatelessWidget {
  const TogetherCover({
    super.key,
    required this.cover,
    required this.title,
    this.width,
    this.height,
    this.radius = 12,
    this.showTitle = true,
  });

  final String cover;
  final String title;
  final double? width;
  final double? height;
  final double radius;
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final image = FxCover(
      url: cover,
      title: title,
      radius: radius,
      big: height != null && height! >= 160,
    );
    if (width == null && height == null) return image;
    return SizedBox(width: width, height: height, child: image);
  }
}

/// 统一 toast（白玻璃 App 里用深色浮动条，保证在亮色背景上可读）。
void togetherToast(
  BuildContext context,
  String text, {
  String? actionLabel,
  VoidCallback? onAction,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12.5,
          fontWeight: FontWeight.w500,
        ),
      ),
      backgroundColor: const Color(0xEE1B2430),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(22, 0, 22, 18),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      duration: Duration(milliseconds: actionLabel == null ? 1800 : 4000),
      action: actionLabel == null || onAction == null
          ? null
          : SnackBarAction(
              label: actionLabel,
              textColor: const Color(0xFF9FC4FF),
              onPressed: onAction,
            ),
    ),
  );
}

Future<void> togetherCopy(
  BuildContext context,
  String text, {
  String message = '已复制',
}) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) togetherToast(context, message);
}

/// 退出房间 / 解散房间等确认框。
Future<bool> showTogetherConfirm(
  BuildContext context, {
  required String title,
  required String content,
  String cancelText = '取消',
  String confirmText = '确定',
  bool danger = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Colors.white.withOpacity(.97),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Text(
        title,
        style: const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w800,
          color: Fx.ink,
        ),
      ),
      content: Text(
        content,
        style: const TextStyle(fontSize: 13, color: Fx.sub, height: 1.5),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(
            cancelText,
            style: const TextStyle(
              fontSize: 13,
              color: Fx.sub,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        GestureDetector(
          onTap: () => Navigator.of(ctx).pop(true),
          child: Container(
            height: 38,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: BoxDecoration(
              gradient: danger
                  ? const LinearGradient(
                      colors: [Color(0xFFFF7A7A), Color(0xFFFF5252)],
                    )
                  : Fx.brand,
              borderRadius: BorderRadius.circular(19),
            ),
            child: Text(
              confirmText,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    ),
  );
  return result ?? false;
}

String togetherFmt(num seconds) {
  final total = seconds.isNaN || seconds < 0 ? 0 : seconds.round();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String p(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${p(m)}:${p(s)}' : '${p(m)}:${p(s)}';
}

String togetherClock(DateTime time) {
  String p(int n) => n.toString().padLeft(2, '0');
  return '${p(time.hour)}:${p(time.minute)}';
}

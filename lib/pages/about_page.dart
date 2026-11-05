import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_info.dart';
import '../theme.dart';
import 'category_page.dart';
import 'legal_page.dart';

/// 关于页：真实版本号、简介、内置隐私政策 / 用户协议、联系邮箱。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await AppInfo.load();
    if (!mounted) return;
    setState(() => _loaded = true);
  }

  void _toast(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xEE1B2430),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ));
  }

  Future<void> _copyEmail() async {
    await Clipboard.setData(const ClipboardData(text: AppInfo.contactEmail));
    if (!mounted) return;
    _toast('联系邮箱已复制');
  }

  Future<void> _open(LegalDocument document) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => LegalPage(document: document)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FxPageScaffold(
      title: '关于',
      child: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 32),
        children: [
          const SizedBox(height: 6),
          Center(
            child: Container(
              width: 78,
              height: 78,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(23),
                gradient: Fx.brand,
                boxShadow: [
                  BoxShadow(
                    color: Fx.accent.withOpacity(.30),
                    blurRadius: 24,
                    offset: const Offset(0, 9),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Image.asset(
                'assets/logo.png',
                fit: BoxFit.cover,
                errorBuilder: (context, error, stack) => const Icon(
                  Icons.play_arrow_rounded,
                  size: 40,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(height: 13),
          const Center(
            child: Text(
              AppInfo.appName,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: Fx.ink,
                letterSpacing: .5,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              _loaded ? AppInfo.fullVersion : '正在读取版本…',
              style: const TextStyle(fontSize: 11, color: Fx.sub),
            ),
          ),
          const SizedBox(height: 14),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              AppInfo.introduction,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, height: 1.65, color: Fx.sub),
            ),
          ),
          const SizedBox(height: 15),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            alignment: WrapAlignment.center,
            children: const [
              _Tag('无广告'),
              _Tag('4K 高清'),
              _Tag('多线路'),
              _Tag('离线缓存'),
            ],
          ),
          const SizedBox(height: 24),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            radius: 20,
            child: Column(
              children: [
                _row(
                  icon: Icons.privacy_tip_outlined,
                  color: Fx.accent,
                  title: '隐私政策',
                  subtitle: '了解我们如何处理你的数据',
                  onTap: () => _open(privacyPolicy),
                ),
                _divider(),
                _row(
                  icon: Icons.description_outlined,
                  color: const Color(0xFF8E6BFF),
                  title: '用户协议',
                  subtitle: '使用本应用前请先阅读',
                  onTap: () => _open(userAgreement),
                ),
                _divider(),
                _row(
                  icon: Icons.alternate_email_rounded,
                  color: const Color(0xFF2FA985),
                  title: '联系邮箱',
                  subtitle: AppInfo.contactEmail,
                  trailing: const Icon(
                    Icons.copy_rounded,
                    size: 15,
                    color: Color(0xFFA6B1C2),
                  ),
                  onTap: _copyEmail,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              '© ${DateTime.now().year} ${AppInfo.appName} · ${AppInfo.packageName}',
              style: const TextStyle(
                fontSize: 9.5,
                color: Color(0xFFB3BECD),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider() => Padding(
        padding: const EdgeInsets.only(left: 48),
        child: Container(height: 1, color: Fx.ink.withOpacity(.05)),
      );

  Widget _row({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Widget? trailing,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color.withOpacity(.11),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, size: 18, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Fx.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10.5, color: Fx.sub),
                  ),
                ],
              ),
            ),
            trailing ?? const SizedBox.shrink(),
            const SizedBox(width: 2),
            const Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: Color(0xFFC3CDDA),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Fx.accent.withOpacity(.07),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 10, color: Fx.accent),
      ),
    );
  }
}

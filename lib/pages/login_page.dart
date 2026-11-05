import 'package:flutter/material.dart';

import '../api.dart';
import '../auth.dart';
import '../theme.dart';

/// 登录 / 注册：手机号或邮箱 + 密码。
/// 注册成功后服务器直接返回 token，因此自动登录并返回上一页。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _account = TextEditingController();
  final TextEditingController _password = TextEditingController();

  bool _register = false;
  bool _busy = false;
  bool _obscure = true;
  String _error = '';

  @override
  void dispose() {
    _account.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    final account = _account.text.trim();
    final password = _password.text;
    final phone = RegExp(r'^1[3-9]\d{9}$').hasMatch(account);
    final email = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$').hasMatch(account);
    if (!phone && !email) {
      setState(() => _error = '请输入正确的手机号或邮箱');
      return;
    }
    if (password.length < 6 || password.length > 64) {
      setState(() => _error = '密码需为 6-64 位');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      if (_register) {
        await Auth.instance.register(account, password);
      } else {
        await Auth.instance.login(account, password);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '网络异常，请检查网络或服务器地址后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F8FC),
      body: FxBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 28),
            children: [
              Row(
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.of(context).maybePop(),
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: .72),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white),
                      ),
                      child: const Icon(Icons.arrow_back_ios_new_rounded,
                          size: 16, color: Fx.ink),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 26),
              Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  gradient: Fx.brand,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Fx.accent.withValues(alpha: .30),
                      blurRadius: 22,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: const Icon(Icons.person_rounded,
                    color: Colors.white, size: 32),
              ),
              const SizedBox(height: 18),
              Text(
                _register ? '创建幻想影视账号' : '欢迎回来',
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: Fx.ink,
                  letterSpacing: -.3,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _register
                    ? '注册成功后自动登录，可同步昵称与头像'
                    : '登录后可修改昵称与头像，和好友一起追剧',
                style: const TextStyle(
                    fontSize: 11.5, height: 1.5, color: Fx.sub),
              ),
              const SizedBox(height: 24),
              _modeTabs(),
              const SizedBox(height: 18),
              _field(
                controller: _account,
                hint: '手机号或邮箱',
                icon: Icons.alternate_email_rounded,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.username],
              ),
              const SizedBox(height: 12),
              _field(
                controller: _password,
                hint: '密码（6-64 位）',
                icon: Icons.lock_outline_rounded,
                obscure: _obscure,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.password],
                onSubmitted: (_) => _submit(),
                suffix: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _obscure = !_obscure),
                  child: Icon(
                    _obscure
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded,
                    size: 19,
                    color: Fx.sub,
                  ),
                ),
              ),
              if (_error.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF6B6B).withValues(alpha: .10),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: const Color(0xFFFF6B6B).withValues(alpha: .24)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline_rounded,
                          size: 15, color: Color(0xFFE05252)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _error,
                          style: const TextStyle(
                              fontSize: 11.5, color: Color(0xFFC84444)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 22),
              Opacity(
                opacity: _busy ? .65 : 1,
                child: GradButton(
                  text: _busy
                      ? '请稍候…'
                      : (_register ? '注册并登录' : '登录'),
                  height: 50,
                  onTap: _busy ? null : _submit,
                ),
              ),
              const SizedBox(height: 14),
              const Center(
                child: Text(
                  '账号支持手机号或邮箱 · 密码 6-64 位',
                  style: TextStyle(fontSize: 10, color: Color(0xFFA6B1C2)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _modeTabs() {
    return Container(
      height: 44,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .62),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: .92)),
      ),
      child: Row(
        children: [
          _modeTab('登录', !_register),
          _modeTab('注册', _register),
        ],
      ),
    );
  }

  Widget _modeTab(String text, bool active) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (_register == (text == '注册')) return;
          setState(() {
            _register = text == '注册';
            _error = '';
          });
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: active ? Fx.brand : null,
            borderRadius: BorderRadius.circular(12),
            boxShadow: active
                ? [
                    BoxShadow(
                      color: Fx.accent.withValues(alpha: .25),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: active ? Colors.white : Fx.sub,
            ),
          ),
        ),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    bool obscure = false,
    TextInputType? keyboardType,
    TextInputAction? textInputAction,
    List<String>? autofillHints,
    ValueChanged<String>? onSubmitted,
    Widget? suffix,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      autofillHints: autofillHints,
      onSubmitted: onSubmitted,
      style: const TextStyle(
          fontSize: 14, color: Fx.ink, fontWeight: FontWeight.w600),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(
            fontSize: 13, color: Color(0xFFA6B1C2), fontWeight: FontWeight.w400),
        prefixIcon: Icon(icon, size: 19, color: Fx.sub),
        suffixIcon: suffix == null
            ? null
            : Padding(
                padding: const EdgeInsets.only(right: 14),
                child: suffix,
              ),
        suffixIconConstraints:
            const BoxConstraints(minWidth: 40, minHeight: 40),
        filled: true,
        fillColor: Colors.white.withValues(alpha: .76),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: .95)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: const BorderSide(color: Fx.accent, width: 1.2),
        ),
      ),
    );
  }
}

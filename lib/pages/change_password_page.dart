import 'package:flutter/material.dart';

import '../api.dart';
import '../auth.dart';
import '../theme.dart';
import 'category_page.dart';
import 'login_page.dart';

/// 修改密码：旧密码 / 新密码 / 确认新密码 → `POST /api/user/password`。
/// 成功后 toast 提示并返回上一页（POST 契约下旧 token 继续有效，无需重新登录）。
class ChangePasswordPage extends StatefulWidget {
  const ChangePasswordPage({super.key});

  @override
  State<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends State<ChangePasswordPage> {
  final TextEditingController _old = TextEditingController();
  final TextEditingController _new = TextEditingController();
  final TextEditingController _confirm = TextEditingController();

  bool _busy = false;
  bool _obscure = true;
  String _error = '';

  @override
  void dispose() {
    _old.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _toast(String message) {
    final m = ScaffoldMessenger.maybeOf(context);
    if (m == null) return;
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xEE1B2430),
      margin: const EdgeInsets.fromLTRB(22, 0, 22, 18),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      duration: const Duration(milliseconds: 1800),
    ));
  }

  Future<void> _submit() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    final oldPassword = _old.text;
    final newPassword = _new.text;
    final confirm = _confirm.text;

    String? error;
    if (oldPassword.isEmpty) {
      error = '请输入原密码';
    } else if (newPassword.length < 6 || newPassword.length > 64) {
      error = '新密码需为 6-64 位';
    } else if (newPassword == oldPassword) {
      error = '新密码不能与原密码相同';
    } else if (newPassword != confirm) {
      error = '两次输入的新密码不一致';
    }
    if (error != null) {
      setState(() => _error = error!);
      return;
    }

    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await Api.changePassword(
        oldPassword: oldPassword,
        newPassword: newPassword,
      );
      if (!mounted) return;
      _toast('密码修改成功');
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '网络异常，请检查网络后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final logged = Auth.instance.user != null;
    return FxPageScaffold(
      title: '修改密码',
      child: logged ? _form() : _needLogin(),
    );
  }

  Widget _needLogin() {
    return FxEmptyView(
      icon: Icons.lock_person_rounded,
      title: '登录后才能修改密码',
      subtitle: '登录后可在这里更换账号密码',
      actionText: '去登录',
      onAction: () async {
        await Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const LoginPage()));
        if (mounted) setState(() {});
      },
    );
  }

  Widget _form() {
    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 30),
      children: [
        const Text('定期更换密码，账号更安全',
            style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                fontWeight: FontWeight.w400,
                color: Fx.sub)),
        const SizedBox(height: 16),
        GlassCard(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
          radius: 20,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.lock_outline_rounded,
                      size: 18, color: Fx.accent),
                  const SizedBox(width: 7),
                  const Text('设置新密码',
                      style: TextStyle(
                          fontSize: 15,
                          height: 1.2,
                          fontWeight: FontWeight.w700,
                          color: Fx.ink)),
                  const Spacer(),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _obscure = !_obscure),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _obscure
                                ? Icons.visibility_off_rounded
                                : Icons.visibility_rounded,
                            size: 15,
                            color: Fx.sub,
                          ),
                          const SizedBox(width: 3),
                          Text(_obscure ? '显示密码' : '隐藏密码',
                              style: const TextStyle(
                                  fontSize: 11, color: Fx.sub)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _field(
                controller: _old,
                hint: '原密码',
                icon: Icons.lock_outline_rounded,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.password],
              ),
              const SizedBox(height: 11),
              _field(
                controller: _new,
                hint: '新密码（6-64 位）',
                icon: Icons.lock_reset_rounded,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.newPassword],
              ),
              const SizedBox(height: 11),
              _field(
                controller: _confirm,
                hint: '确认新密码',
                icon: Icons.check_circle_outline_rounded,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
              ),
              if (_error.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF6B6B).withOpacity(.10),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: const Color(0xFFFF6B6B).withOpacity(.24)),
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
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: Opacity(
                  opacity: _busy ? .65 : 1,
                  child: GradButton(
                    text: _busy ? '正在提交…' : '确认修改',
                    height: 48,
                    onTap: _busy ? null : _submit,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text('密码 6-64 位，建议使用字母与数字组合',
                  style: TextStyle(fontSize: 10.5, color: Color(0xFFA6B1C2))),
            ],
          ),
        ),
      ],
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    bool obscure = true,
    TextInputAction? textInputAction,
    List<String>? autofillHints,
    ValueChanged<String>? onSubmitted,
  }) {
    return TextField(
      controller: controller,
      obscureText: _obscure && obscure,
      textInputAction: textInputAction,
      autofillHints: autofillHints,
      onSubmitted: onSubmitted,
      style: const TextStyle(
          fontSize: 14, color: Fx.ink, fontWeight: FontWeight.w600),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(
            fontSize: 13,
            color: Color(0xFFA6B1C2),
            fontWeight: FontWeight.w400),
        prefixIcon: Icon(icon, size: 19, color: Fx.sub),
        filled: true,
        fillColor: const Color(0xFFF4F7FC),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.white.withOpacity(.95)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Fx.accent, width: 1.2),
        ),
      ),
    );
  }
}

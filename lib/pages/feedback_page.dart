import 'package:flutter/material.dart';

import '../auth.dart';
import '../services/feedback_service.dart';
import '../theme.dart';
import 'category_page.dart';

/// 意见反馈：`POST /api/feedback {content, contact, uid}`。
/// 提交失败时不清空输入，用户可直接重试。
class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key});

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  final TextEditingController _content = TextEditingController();
  final TextEditingController _contact = TextEditingController();
  bool _submitting = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _content.addListener(_onTextChanged);
    final account = Auth.instance.user?.account.trim() ?? '';
    if (account.contains('@')) _contact.text = account;
  }

  @override
  void dispose() {
    _content
      ..removeListener(_onTextChanged)
      ..dispose();
    _contact.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
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

  Future<void> _submit() async {
    if (_submitting) return;
    FocusScope.of(context).unfocus();
    final content = _content.text.trim();
    if (content.isEmpty) {
      setState(() => _error = '请先填写你遇到的问题或建议');
      return;
    }
    if (content.length > FeedbackService.maxContentLength) {
      setState(() => _error = '反馈内容不能超过 ${FeedbackService.maxContentLength} 字');
      return;
    }

    setState(() {
      _submitting = true;
      _error = '';
    });
    try {
      await FeedbackService.submit(
        content: content,
        contact: _contact.text.trim(),
        uid: Auth.instance.user?.id ?? '',
      );
      if (!mounted) return;
      _toast('反馈提交成功，感谢你的建议');
      Navigator.of(context).pop(true);
    } on FeedbackException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '提交失败，内容已保留，请稍后重试');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final length = _content.text.characters.length;
    final overLimit = length > FeedbackService.maxContentLength;
    return FxPageScaffold(
      title: '意见反馈',
      child: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 30),
        children: [
          GlassCard(
            padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
            radius: 18,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: Fx.accent.withValues(alpha: .10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.forum_outlined,
                    size: 17,
                    color: Fx.accent,
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    '遇到问题或有功能建议，都可以告诉我们。请描述具体场景，方便快速定位；提交失败时内容会保留，可直接重试。',
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.65,
                      color: Fx.sub,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          GlassCard(
            padding: const EdgeInsets.fromLTRB(16, 15, 16, 17),
            radius: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.edit_note_rounded, size: 18, color: Fx.accent),
                    SizedBox(width: 6),
                    Text(
                      '反馈内容',
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: Fx.ink,
                      ),
                    ),
                    SizedBox(width: 4),
                    Text(
                      '* 必填',
                      style: TextStyle(fontSize: 10, color: Color(0xFFE05252)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _content,
                  minLines: 5,
                  maxLines: 8,
                  maxLength: FeedbackService.maxContentLength + 50,
                  textInputAction: TextInputAction.newline,
                  style: const TextStyle(
                    fontSize: 13.5,
                    height: 1.6,
                    color: Fx.ink,
                  ),
                  decoration: InputDecoration(
                    hintText: '例如：在 XX 手机上播放第 3 集时会卡住，切换线路后正常……',
                    hintStyle: const TextStyle(
                      fontSize: 12.5,
                      height: 1.6,
                      color: Color(0xFFA6B1C2),
                    ),
                    filled: true,
                    fillColor: const Color(0xFFF4F7FC),
                    counterText: '',
                    contentPadding: const EdgeInsets.all(14),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide:
                          BorderSide(color: Colors.white.withValues(alpha: .95)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide:
                          const BorderSide(color: Fx.accent, width: 1.2),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    if (overLimit)
                      const Text(
                        '已超出字数限制',
                        style:
                            TextStyle(fontSize: 10, color: Color(0xFFE05252)),
                      ),
                    const Spacer(),
                    Text(
                      '$length / ${FeedbackService.maxContentLength}',
                      style: TextStyle(
                        fontSize: 10,
                        color: overLimit
                            ? const Color(0xFFE05252)
                            : const Color(0xFFA6B1C2),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  '联系方式（选填）',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: Fx.ink,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _contact,
                  textInputAction: TextInputAction.done,
                  keyboardType: TextInputType.emailAddress,
                  onSubmitted: (_) => _submit(),
                  style: const TextStyle(fontSize: 13.5, color: Fx.ink),
                  decoration: InputDecoration(
                    hintText: '邮箱 / QQ / 手机号，便于我们回复你',
                    hintStyle: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFFA6B1C2),
                    ),
                    prefixIcon: const Icon(
                      Icons.alternate_email_rounded,
                      size: 18,
                      color: Fx.sub,
                    ),
                    filled: true,
                    fillColor: const Color(0xFFF4F7FC),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide:
                          BorderSide(color: Colors.white.withValues(alpha: .95)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide:
                          const BorderSide(color: Fx.accent, width: 1.2),
                    ),
                  ),
                ),
                if (_error.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF6B6B).withValues(alpha: .10),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: const Color(0xFFFF6B6B).withValues(alpha: .24),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.error_outline_rounded,
                          size: 15,
                          color: Color(0xFFE05252),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _error,
                            style: const TextStyle(
                              fontSize: 11.5,
                              height: 1.5,
                              color: Color(0xFFC84444),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: Opacity(
                    opacity: _submitting ? .65 : 1,
                    child: GradButton(
                      text: _submitting ? '正在提交…' : '提交反馈',
                      height: 48,
                      icon: Icons.send_rounded,
                      onTap: _submitting ? null : _submit,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          const Center(
            child: Text(
              '我们通常会在 1-3 个工作日内查看反馈',
              style: TextStyle(fontSize: 10, color: Color(0xFFA6B1C2)),
            ),
          ),
        ],
      ),
    );
  }
}

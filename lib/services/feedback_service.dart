import 'dart:convert';

import 'package:http/http.dart' as http;

import '../api.dart';

class FeedbackException implements Exception {
  FeedbackException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 意见反馈：`POST /api/feedback {content, contact, uid}`。
///
/// 只有 HTTP 2xx 且业务 code=0 才算成功；后端未部署接口时会返回
/// `{code:404}`（HTTP 200），同样按失败处理，页面保留内容供重试。
class FeedbackService {
  FeedbackService._();

  static const int maxContentLength = 500;
  static const Duration _timeout = Duration(seconds: 15);

  static Future<void> submit({
    required String content,
    String contact = '',
    String uid = '',
  }) async {
    final text = content.trim();
    if (text.isEmpty) throw FeedbackException('请先填写反馈内容');
    if (text.length > maxContentLength) {
      throw FeedbackException('反馈内容不能超过 $maxContentLength 字');
    }

    http.Response response;
    try {
      response = await http
          .post(
            Uri.parse('${Api.base}/feedback'),
            headers: <String, String>{
              'Accept': 'application/json',
              'Content-Type': 'application/json',
              if (Api.token.isNotEmpty) 'Authorization': 'Bearer ${Api.token}',
            },
            body: jsonEncode(<String, dynamic>{
              'content': text,
              'contact': contact.trim(),
              'uid': uid.trim(),
            }),
          )
          .timeout(_timeout);
    } catch (_) {
      throw FeedbackException('网络连接失败，内容已保留，请稍后重试');
    }

    if (response.statusCode == 404) {
      throw FeedbackException('反馈服务暂未开放，内容已保留，可稍后重试');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FeedbackException(
        '提交失败（HTTP ${response.statusCode}），内容已保留，可重试',
      );
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw FeedbackException('服务器返回格式异常，内容已保留，可重试');
    }
    final code = decoded is Map ? decoded['code'] : null;
    final ok = code == 0 || code == '0';
    if (!ok) {
      final msg = decoded is Map ? '${decoded['msg'] ?? ''}'.trim() : '';
      if (code == 404 || code == '404') {
        throw FeedbackException('反馈服务暂未开放，内容已保留，可稍后重试');
      }
      throw FeedbackException(
        msg.isEmpty ? '提交失败，内容已保留，可重试' : '$msg（内容已保留，可重试）',
      );
    }
  }
}

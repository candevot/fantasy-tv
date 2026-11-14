import 'dart:convert';
import 'dart:io';

import 'package:fantasy_tv/services/tvbox_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// TVBox 加密配置（肥猫）解密回归。
///
/// 样本是 2026-11-15 从 `http://肥猫.net/` 实抓的完整加密配置（播放器 UA）
/// 与站方 `/api/parse` 解出的明文，放在 `test/fixtures/`。CI 里的
/// `flutter test` 会跑这一份，纯 Dart 版见 `tools/test_tvbox_crypto.dart`。
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('肥猫加密配置：解出的明文与站方解密结果一致，且含 sites 数组', () {
    final encrypted = read('test/fixtures/tvbox_encrypted.txt');
    final expected = read('test/fixtures/tvbox_plain.json').trim();

    expect(isTvBoxEncrypted(encrypted), isTrue);
    final decoded = decodeTvBoxConfig(encrypted);
    expect(decoded, isNotNull);
    expect(decoded, equals(expected));

    final parsed = jsonDecode(decoded!);
    expect(parsed, isA<Map<String, dynamic>>());
    final sites = (parsed as Map<String, dynamic>)['sites'];
    expect(sites, isA<List<Object?>>());
    expect(sites as List<Object?>, isNotEmpty);
  });

  test('明文 JSON 不会被当成密文', () {
    const plain = '{"sites":[{"key":"a","name":"A","type":0,"api":"x"}]}';
    expect(isTvBoxEncrypted(plain), isFalse);
    expect(decodeTvBoxConfig(plain), isNull);
  });

  test('截断密文返回 null 而不是抛异常', () {
    final truncated = read('test/fixtures/tvbox_truncated.txt');
    expect(decodeTvBoxConfig(truncated), isNull);
  });
}

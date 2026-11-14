// 纯 Dart 自检：TVBox 加密配置（肥猫 `$#key#$` + AES-128-CBC）能不能解开。
//
//   dart tools/test_tvbox_crypto.dart
//
// 样本是 2026-11-15 从 http://肥猫.net/ 实抓的完整加密配置（播放器 UA），
// 对照明文来自站方自己的 /api/parse 解密结果，两个文件都在 test/fixtures/：
//   · tvbox_encrypted.txt —— 完整密文（25244 字符的 hex）
//   · tvbox_plain.json    —— 对应的明文 JSON（41 个 sites，压缩格式）
//
// 失败就抛异常并 exit 1，别只看「好像解开了」。
import 'dart:convert';
import 'dart:io';

import '../lib/services/tvbox_crypto.dart';

int _passed = 0;

void check(bool ok, String message) {
  if (!ok) throw StateError('FAIL: $message');
  _passed++;
}

String _read(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError('缺样本文件：$path（在仓库根目录下运行这个脚本）');
  }
  return file.readAsStringSync();
}

void main() {
  final encrypted = _read('test/fixtures/tvbox_encrypted.txt');
  final plainFixture = _read('test/fixtures/tvbox_plain.json');

  // 1. 认得出是加密串
  check(isTvBoxEncrypted(encrypted), '完整密文应被识别为加密配置');

  // 2. 解得开
  final decoded = decodeTvBoxConfig(encrypted);
  check(decoded != null, '完整密文应能解出明文');
  final text = decoded!;

  // 3. 和站方 /api/parse 的明文完全一致（逐字节）
  check(text == plainFixture.trim(), '解密结果应与 tvbox_plain.json 完全一致');

  // 4. 是合法 JSON，且 sites 是非空数组
  final parsed = jsonDecode(text);
  check(parsed is Map, '明文应是 JSON 对象');
  final sites = (parsed as Map)['sites'];
  check(sites is List && sites.isNotEmpty, 'sites 应是非空数组');
  print(
    '  解得 ${(sites as List).length} 个 sites，'
    '${text.length} 字节明文',
  );

  // 5. 明文 JSON 原样传进来不能被当成密文
  check(!isTvBoxEncrypted(plainFixture), '明文 JSON 不应被识别为加密配置');
  check(decodeTvBoxConfig(plainFixture) == null, '明文 JSON 应返回 null');

  // 6. 截断的密文（只有前 400 个字符那种）要安静地返回 null，不能崩
  final truncated = _read('test/fixtures/tvbox_truncated.txt');
  check(decodeTvBoxConfig(truncated) == null, '截断密文应返回 null');

  // 7. 空串 / 非 hex / 普通文本都不算
  check(decodeTvBoxConfig('') == null, '空串应返回 null');
  check(decodeTvBoxConfig('zzzz') == null, '非 hex 应返回 null');
  check(!isTvBoxEncrypted('{"sites":[]}'), '普通 JSON 不算加密配置');

  print('OK: $_passed 项检查全部通过');
}

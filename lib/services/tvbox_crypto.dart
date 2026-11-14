import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/api.dart';

/// TVBox / 猫源「加密配置」的解密。
///
/// 线上格式（2026-11-15 对 `http://肥猫.net/` 实测，服务端 /api/parse 的解密
/// 结果与这里一致）：
///
/// ```text
/// 整个响应体是纯 hex 字符串
///   hex 解码后 = "$#<13 位 key>#$" + AES-128-CBC 密文 + <13 位 iv>
/// key / iv 都补 '0' 到 16 字节（超过 16 就截断）
/// 密文 16 字节对齐，明文尾部是 PKCS7 填充
/// ```
///
/// 两个要注意的点（踩过的坑，写下来免得再踩）：
///   1. iv **不是** key：响应尾部那 13 个 ASCII 字符才是 iv 的来源。
///      拿 key 当 iv 解，只有第一块（`{"spider":"https`）会花，后面全是好的
///      —— 看着像解开了，`jsonDecode` 却一定失败。
///   2. 尾部那 13 个字符不是密文的一部分，长度不是 16 的倍数，需要先切掉。
///
/// 解密失败（不是加密串、hex 坏了、密文截断、明文不是 JSON）统统返回 null，
/// 调用方继续按原来的「明文 JSON」路径走。
String? decodeTvBoxConfig(String raw) {
  final text = raw.trim();
  if (text.length < 32 || text.length.isOdd) return null;
  final body = _hexDecode(text);
  if (body == null) return null;
  final header = _headerOf(body);
  if (header == null) return null;
  final key = _pad16(header.key);
  final rest = body.sublist(header.end);
  for (final candidate in _candidates(rest, key)) {
    final plain = _decrypt(key, candidate.iv, candidate.ct);
    if (plain == null) continue;
    final json = _asJson(plain);
    if (json != null) return json;
  }
  return null;
}

/// 是不是「hex + `$#…$#` 头」这种加密配置（只看外壳，不解密）。
bool isTvBoxEncrypted(String raw) {
  final text = raw.trim();
  if (text.length < 32 || text.length.isOdd) return false;
  final body = _hexDecode(text);
  return body != null && _headerOf(body) != null;
}

/* ------------------------------------------------------------ 外壳解析 */

class _Header {
  const _Header(this.key, this.end);

  /// `$#` 与 `#$` 之间的 13 位 key（原样字节，未补齐）。
  final Uint8List key;

  /// 密文开始的下标（`#$` 之后）。
  final int end;
}

/// 认 `$#<key>#$` 头；不是这种格式返回 null。
_Header? _headerOf(Uint8List body) {
  if (body.length < 5 || body[0] != 0x24 || body[1] != 0x23)
    return null; // "$#"
  for (var i = 2; i + 1 < body.length; i++) {
    if (body[i] == 0x23 && body[i + 1] == 0x24) {
      final key = Uint8List.sublistView(body, 2, i);
      if (key.isEmpty) return null;
      return _Header(key, i + 2);
    }
  }
  return null;
}

class _Candidate {
  const _Candidate(this.iv, this.ct);

  final Uint8List iv;
  final Uint8List ct;
}

/// iv / 密文的候选切法，按可能性排序：
///   1. 尾部 13 字节当 iv（肥猫现在的格式）；
///   2. header key 当 iv（早期版本 / 别的猫源站）；
///   3. 全零 iv（最后兜底）。
///
/// 每种都只切到 16 的整数倍，解出来还得是 JSON 才算通过。
List<_Candidate> _candidates(Uint8List rest, Uint8List key) {
  final out = <_Candidate>[];
  void add(Uint8List iv, int cut) {
    final end = rest.length - cut;
    if (end <= 0 || end % 16 != 0) return;
    out.add(_Candidate(_pad16(iv), Uint8List.sublistView(rest, 0, end)));
  }

  // 尾部 13 字节的 iv：先在常见长度里找，密文长度对不上就整个跳过。
  for (final ivLen in const <int>[13, 16, 8]) {
    if (rest.length <= ivLen || (rest.length - ivLen) % 16 != 0) continue;
    add(Uint8List.sublistView(rest, rest.length - ivLen), ivLen);
  }
  add(key, 0);
  add(Uint8List(16), 0);
  return out;
}

/* ------------------------------------------------------------ AES */

const int _blockSize = 16;

/// key / iv 补 `'0'` 到 16 字节；超过 16 就截断（和 TVBox 的补法一致）。
Uint8List _pad16(Uint8List raw) {
  final out = Uint8List(_blockSize);
  final n = raw.length < _blockSize ? raw.length : _blockSize;
  out.setRange(0, n, raw);
  for (var i = n; i < _blockSize; i++) {
    out[i] = 0x30; // '0'
  }
  return out;
}

/// AES-128-CBC 解密 + 去 PKCS7。解不干净（填充非法）返回 null。
Uint8List? _decrypt(Uint8List key, Uint8List iv, Uint8List data) {
  if (data.isEmpty || data.length % _blockSize != 0) return null;
  try {
    final cipher = CBCBlockCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(key), iv));
    final out = Uint8List(data.length);
    for (var offset = 0; offset < data.length; offset += _blockSize) {
      cipher.processBlock(data, offset, out, offset);
    }
    final pad = out[out.length - 1];
    if (pad == 0 || pad > _blockSize || pad > out.length) return out;
    for (var i = out.length - pad; i < out.length; i++) {
      if (out[i] != pad) return out;
    }
    return Uint8List.sublistView(out, 0, out.length - pad);
  } catch (_) {
    return null;
  }
}

/// 明文 → JSON 文本（解析不了就不是配置，返回 null）。
String? _asJson(Uint8List plain) {
  if (plain.isEmpty) return null;
  String text;
  try {
    text = utf8.decode(plain, allowMalformed: true).trim();
  } catch (_) {
    return null;
  }
  if (text.isEmpty) return null;
  try {
    final parsed = jsonDecode(text);
    if (parsed is Map || parsed is List) return text;
  } catch (_) {
    return null;
  }
  return null;
}

/* ------------------------------------------------------------ hex */

/// 两位一组手写 hex 解码（`dart:convert` 没有现成的）；非法字符返回 null。
Uint8List? _hexDecode(String text) {
  final out = Uint8List(text.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final hi = _hexValue(text.codeUnitAt(i * 2));
    final lo = _hexValue(text.codeUnitAt(i * 2 + 1));
    if (hi < 0 || lo < 0) return null;
    out[i] = (hi << 4) | lo;
  }
  return out;
}

int _hexValue(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30; // 0-9
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10; // a-f
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10; // A-F
  return -1;
}

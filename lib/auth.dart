import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'fx_globals.dart';
import 'models.dart';

/// 登录态：token 持久化在 SharedPreferences，所有 API 请求由 [Api.token]
/// 自动带 `Authorization: Bearer <token>`。
class Auth extends ChangeNotifier {
  Auth._() {
    // 所有 HTTP 401 统一走这里：清 session + 全局提示，页面不用各自处理。
    Api.onUnauthorized = _onUnauthorized;
  }
  static final Auth instance = Auth._();

  static const String _kToken = 'fx_auth_token_v1';
  static const String _kUser = 'fx_auth_user_v1';
  static const String _kAvatarPrefix = 'fx_auth_avatar_v1_';

  AuthUser? _user;
  String _token = '';
  String _avatarPath = '';
  bool _refreshing = false;
  bool _loggingOut = false;

  AuthUser? get user => _user;
  bool get loggedIn => _user != null && _token.isNotEmpty;

  /// 本地头像文件（服务器没有 multipart 头像接口，选图后压缩存本机）。
  String get avatarPath => _avatarPath;

  /// 启动时只读本地缓存，不阻塞启动；随后后台校验一次 token。
  Future<void> init() async {
    try {
      final sp = await SharedPreferences.getInstance();
      _token = sp.getString(_kToken) ?? '';
      final raw = sp.getString(_kUser);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _user =
              AuthUser.fromJson(Map<String, dynamic>.from(decoded));
        }
      }
      if (_token.isEmpty) _user = null;
      Api.token = _token;
      final u = _user;
      if (u != null) {
        _avatarPath = sp.getString('$_kAvatarPrefix${u.id}') ?? '';
        if (_avatarPath.isNotEmpty && !File(_avatarPath).existsSync()) {
          _avatarPath = '';
        }
      }
    } catch (_) {
      // 本地缓存损坏时就当未登录，不阻塞启动。
      _token = '';
      _user = null;
    }
    notifyListeners();
    if (_token.isNotEmpty) unawaited(refresh());
  }

  Future<void> login(String account, String password) async {
    final data = await Api.login(
      account: account.trim(),
      password: password,
    );
    await _applySession(data);
  }

  Future<void> register(String account, String password) async {
    final data = await Api.register(
      account: account.trim(),
      password: password,
    );
    await _applySession(data);
  }

  Future<void> _applySession(Map<String, dynamic> data) async {
    final rawUser = data['user'];
    if (rawUser is! Map) throw ApiException('登录返回数据异常');
    final user = AuthUser.fromJson(Map<String, dynamic>.from(rawUser));
    final token = '${data['token'] ?? ''}';
    if (token.isEmpty) throw ApiException('登录返回数据异常');

    _user = user;
    _token = token;
    Api.token = token;

    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kToken, token);
    await sp.setString(_kUser, jsonEncode(user.toJson()));
    final saved = sp.getString('$_kAvatarPrefix${user.id}') ?? '';
    _avatarPath =
        saved.isNotEmpty && File(saved).existsSync() ? saved : '';

    notifyListeners();
  }

  /// 拉取 `/user/me` 校验 token，并同步昵称等资料；失败则保留本地缓存。
  Future<void> refresh() async {
    if (_refreshing || _token.isEmpty) return;
    _refreshing = true;
    final token = _token;
    try {
      final data = await Api.me();
      if (_token != token) return;
      final user = AuthUser.fromJson(data);
      if (user.id.isEmpty) return;
      _user = user;
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kUser, jsonEncode(user.toJson()));
      notifyListeners();
    } on ApiException catch (e) {
      if (e.code == 401 && _token == token) await _clearSession();
    } catch (_) {
      // 网络异常时保留本地登录态，下次进入再校验。
    } finally {
      _refreshing = false;
    }
  }

  Future<void> updateNickname(String nickname) async {
    final value = nickname.trim();
    if (value.isEmpty) throw ApiException('昵称不能为空');
    if (value.runes.length > 20) throw ApiException('昵称最多 20 字');
    final user = await Api.updateProfile(nickname: value);
    _user = user;
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kUser, jsonEncode(user.toJson()));
    notifyListeners();
  }

  /// 相册选图后：居中裁方、缩到 256×256、JPEG 压缩到 200KB 以内，
  /// 转成 base64 调 `POST /api/user/avatar`，成功后更新本地用户，
  /// 同时在应用私有目录缓存一份，弱网 / 离线时头像也能立即显示。
  Future<void> uploadAvatar(Uint8List raw) async {
    final user = _user;
    if (user == null) throw ApiException('请先登录');
    final bytes = _compressAvatar(raw);
    final avatarUrl = await Api.uploadAvatar(base64Encode(bytes));

    // 本地缓存读写失败不影响线上头像生效，静默降级。
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/fx_avatar_${user.id}.jpg');
      await file.writeAsBytes(bytes, flush: true);
      _avatarPath = file.path;
      final sp = await SharedPreferences.getInstance();
      await sp.setString('$_kAvatarPrefix${user.id}', file.path);
    } catch (_) {
      _avatarPath = '';
    }

    final latest = _user;
    if (latest == null || latest.id != user.id) return;
    _user = latest.copyWith(avatar: avatarUrl);
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kUser, jsonEncode(_user!.toJson()));
    } catch (_) {}
    notifyListeners();
  }

  /// 兼容旧调用：头像上传统一走 [uploadAvatar]。
  Future<void> saveAvatar(Uint8List raw) => uploadAvatar(raw);

  /// 居中裁方 + 压缩到 200KB 以内，返回 JPEG 字节。
  Uint8List _compressAvatar(Uint8List raw) {
    final decoded = img.decodeImage(raw);
    if (decoded == null) throw ApiException('无法识别这张图片');

    var picture = img.copyResizeCropSquare(
      decoded,
      size: 256,
      interpolation: img.Interpolation.average,
    );
    var bytes = img.encodeJpg(picture, quality: 82);
    for (var quality = 72;
        bytes.length > 200 * 1024 && quality >= 42;
        quality -= 10) {
      bytes = img.encodeJpg(picture, quality: quality);
    }
    if (bytes.length > 200 * 1024) {
      picture = img.copyResize(picture, width: 160, height: 160);
      bytes = img.encodeJpg(picture, quality: 60);
    }
    if (bytes.length > 200 * 1024) {
      throw ApiException('图片压缩后仍超过 200KB，请换一张');
    }
    return bytes;
  }

  Future<void> logout() async {
    _loggingOut = true;
    try {
      await Api.logout();
    } catch (_) {
      // 离线也允许退出本地账号。
    }
    await _clearSession();
    _loggingOut = false;
  }

  void _onUnauthorized() {
    // 用户主动退出时 token 可能已经过期，不要误报「登录已过期」。
    if (_loggingOut) return;
    unawaited(expire());
  }

  /// token 已失效：清掉本地登录态并全局提示一次。
  ///
  /// 返回是否由本次调用真正处理（已经处理过时静默，避免同时收到
  /// HTTP 401 与一起去重连探测 401 时重复弹窗）。
  Future<bool> expire() async {
    if (_token.isEmpty && _user == null) return false;
    await _clearSession();
    fxGlobalToast('登录已过期，请重新登录');
    return true;
  }

  Future<void> _clearSession() async {
    _token = '';
    _user = null;
    _avatarPath = '';
    Api.token = '';
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(_kToken);
      await sp.remove(_kUser);
    } catch (_) {}
    notifyListeners();
  }
}

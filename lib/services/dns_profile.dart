/// 把配置里的 `hosts` / `doh` 喂给原生 DNS（PROTOCOL_FACE 2026-11-15 · 第 6 条）。
///
/// 原生侧 `FxDns` 早就有「钉 IP + DoH」的能力（`android_src/.../FxDns.kt`），
/// 但它只会**自动**记「上次连通过的 IP」，配置里写死的 `hosts` 没人喂 ——
/// 于是壳靠 `hosts` 直连「已知好用的 IP」的那类源（CDN 边缘节点、被污染域名），
/// 我们只能听运营商的 DNS。
///
/// 这条链路的三个环节：
///   1. `TvBoxConfig.hosts`（`["host=ip", …]`，壳 `OkDns.addAll` 的格式）
///      + `TvBoxConfig.doh`（取第一个可用地址）→ [DnsProfile]；
///   2. [DnsProfileInstaller] 去重后推给原生通道 `fantasy_tv/exo_player`
///      的 `setDnsProfile`（**新增方法，不改任何既有方法的入参/快照键**）；
///   3. 原生 `FxDns.applyProfile()` 把 hosts 当「最高优先级的钉 IP」，DoH 端点
///      换成配置里的那一个。
///
/// 没配 `hosts` / `doh` 时不发请求 —— 空配置必须保持「与改造前完全一致」。
library;

import 'exo_player.dart';
import 'tvbox_config.dart';

/// 一份 DNS 画像。
class DnsProfile {
  const DnsProfile({
    this.hosts = const <String, String>{},
    this.dohUrl = '',
  });

  static const DnsProfile empty = DnsProfile();

  /// `host → ip`（值可能带端口 / 多 IP，原样交给原生，它自己解析）。
  final Map<String, String> hosts;

  /// DoH 端点（空 = 保留原生默认的阿里 DNS）。
  final String dohUrl;

  bool get isEmpty => hosts.isEmpty && dohUrl.isEmpty;

  /// 给原生通道的形态：`["host=ip", …]`（与壳配置里的写法一致，
  /// 原生侧按 `=` 切，不需要 Map 编解码，跨通道最稳）。
  List<String> get hostLines =>
      <String>[for (final e in hosts.entries) '${e.key}=${e.value}'];

  /// 去重签名：配置刷新但 hosts/doh 没变时不必再推一次。
  String get signature {
    final keys = hosts.keys.toList()..sort();
    return '$dohUrl|${keys.map((k) => '$k=${hosts[k]}').join(';')}';
  }

  /// 从配置里取（`hosts` 解析成 map，`doh` 取第一个）。
  factory DnsProfile.fromConfig(TvBoxConfig config) =>
      DnsProfile(hosts: config.hostsMap, dohUrl: config.dohUrl);

  /// 日志用的一行摘要。
  String summary() =>
      'dns_profile[hosts=${hosts.length} doh=${dohUrl.isEmpty ? '默认' : dohUrl}]';
}

/// 推送 DNS 画像到原生（去重 + 失败静默）。
///
/// 为什么失败要静默：这条链路只在「配置里有 hosts/doh」时才走，推不过去
/// （非 Android、通道没起来、老版本插件）的后果只是回到系统 DNS —— 与改造前
/// 完全一样，不该让它冒到检索链路上。
class DnsProfileInstaller {
  DnsProfileInstaller._();

  static DnsProfile _current = DnsProfile.empty;
  static String _pushed = '';
  static Future<bool>? _inflight;

  /// 当前生效的画像（诊断 / 单测用）。
  static DnsProfile get current => _current;

  /// 已经推成功的签名（诊断用）。
  static String get pushedSignature => _pushed;

  /// 装一份画像：内容没变就直接返回（幂等）。
  static Future<bool> install(DnsProfile profile) {
    _current = profile;
    if (!ExoPlayerEngine.isSupported) return Future<bool>.value(false);
    // 空画像 + 从没推过：什么都不用做（保持改造前的行为）。
    if (profile.isEmpty && _pushed.isEmpty) return Future<bool>.value(false);
    final signature = profile.signature;
    if (signature == _pushed) return Future<bool>.value(true);
    final running = _inflight;
    if (running != null) return running;
    final task = _push(profile, signature);
    _inflight = task;
    return task.whenComplete(() {
      _inflight = null;
    });
  }

  static Future<bool> _push(DnsProfile profile, String signature) async {
    try {
      final ok = await ExoPlayerEngine.setDnsProfile(
        hosts: profile.hostLines,
        doh: profile.dohUrl,
      );
      if (ok) {
        _pushed = signature;
      } else {
        // 通道没实现（老插件）：记成已推，避免每次刷新都试一遍。
        _pushed = signature;
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// 单测 / 诊断用：清掉「已推」记录。
  static void resetForTest() {
    _current = DnsProfile.empty;
    _pushed = '';
    _inflight = null;
  }
}

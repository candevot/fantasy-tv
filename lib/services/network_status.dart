import 'dart:io';

import 'package:flutter/foundation.dart';

/// 当前网络类型（基于系统网络接口的真实探测）。
enum FxNetworkKind { wifi, mobile, ethernet, offline, unknown }

extension FxNetworkKindText on FxNetworkKind {
  String get label => switch (this) {
        FxNetworkKind.wifi => 'Wi-Fi',
        FxNetworkKind.mobile => '移动网络',
        FxNetworkKind.ethernet => '有线网络',
        FxNetworkKind.offline => '无网络',
        FxNetworkKind.unknown => '网络状态未知',
      };

  bool get isMobile => this == FxNetworkKind.mobile;
}

/// Android 的接口名可以区分 Wi-Fi / 移动数据：
/// `wlan0` / `rmnet_data0` / `ccmni0` / `pdp0`。
/// 这里不用第三方插件，避免为了一个开关新增原生依赖。
class NetworkStatus {
  NetworkStatus._();

  static Future<FxNetworkKind> detect() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
      );
      if (interfaces.isEmpty) return FxNetworkKind.offline;

      var hasWifi = false;
      var hasMobile = false;
      var hasEthernet = false;
      var hasOther = false;

      for (final interface in interfaces) {
        final name = interface.name.toLowerCase();
        if (name.startsWith('wlan') ||
            name.startsWith('wifi') ||
            name.startsWith('swlan')) {
          hasWifi = true;
        } else if (name.startsWith('eth')) {
          hasEthernet = true;
        } else if (name.startsWith('rmnet') ||
            name.startsWith('ccmni') ||
            name.startsWith('pdp') ||
            name.startsWith('radio') ||
            name.startsWith('wwan') ||
            name.startsWith('v4-rmnet') ||
            name.startsWith('clat')) {
          hasMobile = true;
        } else if (name.startsWith('tun') ||
            name.startsWith('ppp') ||
            name.startsWith('tap')) {
          // VPN 接口：底层可能是 Wi-Fi 也可能是移动网络，无法仅凭接口名判断。
          hasOther = true;
        } else {
          hasOther = true;
        }
      }

      // 同时开着 Wi-Fi 和移动数据时，系统默认走 Wi-Fi。
      if (hasWifi) return FxNetworkKind.wifi;
      if (hasEthernet) return FxNetworkKind.ethernet;
      if (hasMobile) return FxNetworkKind.mobile;
      if (hasOther) return FxNetworkKind.unknown;
      return FxNetworkKind.offline;
    } catch (e) {
      debugPrint('NetworkStatus: detect failed: $e');
      return FxNetworkKind.unknown;
    }
  }
}

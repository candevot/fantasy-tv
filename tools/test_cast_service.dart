// DLNA 投屏协议单测（纯 Dart，不需要 Flutter / 真电视）：
//   FLUTTER_ROOT=/tmp/fl/flutter332 \
//   /tmp/fl/dart381/dart-sdk/bin/dart --packages=.dart_tool/package_config.json \
//     tools/test_cast_service.dart
//
// 起一个本地假 DLNA 渲染器（设备描述 + AVTransport / RenderingControl
// SOAP 端点），验证 describeLocation / play / pause / resume / seek /
// setVolume / stop 以及 SSDP 解析、投屏地址（直链 vs 服务器代理）选择。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../lib/services/cast_service.dart';

int _passed = 0;

void check(bool cond, String message) {
  if (!cond) throw StateError('FAIL: $message');
  _passed++;
}

void checkEq(Object? actual, Object? expected, String message) {
  if (actual != expected) {
    throw StateError('FAIL: $message (expected $expected, got $actual)');
  }
  _passed++;
}

class MockRenderer {
  late HttpServer _server;
  final List<String> actions = <String>[];
  String transport = 'STOPPED';
  String? currentUri;
  String? seekTarget;
  String lastAction = '';
  int relSeconds = 10;
  int volume = 20;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(_serve());
  }

  int get port => _server.port;
  String get descriptionUrl => 'http://127.0.0.1:$port/desc.xml';

  Future<void> close() => _server.close(force: true);

  Future<void> _serve() async {
    await for (final request in _server) {
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (request.method == 'GET' && path == '/desc.xml') {
        await _xml(request, _description.replaceAll('PORT', '$port'));
        return;
      }
      if (request.method == 'GET' && path == '/router.xml') {
        await _xml(request, _routerDescription);
        return;
      }
      if (request.method == 'POST' && (path == '/av' || path == '/rc')) {
        final body = await utf8.decoder.bind(request).join();
        final action =
            RegExp(r'<u:([A-Za-z]+)').firstMatch(body)?.group(1) ?? '';
        actions.add(action);
        lastAction = action;
        if (action == 'SetAVTransportURI') {
          currentUri = RegExp(r'<CurrentURI>(.*?)</CurrentURI>')
              .firstMatch(body)
              ?.group(1);
        } else if (action == 'Play') {
          transport = 'PLAYING';
        } else if (action == 'Pause') {
          transport = 'PAUSED_PLAYBACK';
        } else if (action == 'Stop') {
          transport = 'STOPPED';
        } else if (action == 'Seek') {
          seekTarget =
              RegExp(r'<Target>(.*?)</Target>').firstMatch(body)?.group(1);
          relSeconds = _seconds(seekTarget ?? '');
        } else if (action == 'SetVolume') {
          volume = int.tryParse(
                RegExp(r'<DesiredVolume>(\d+)</DesiredVolume>')
                        .firstMatch(body)
                        ?.group(1) ??
                    '',
              ) ??
              volume;
        }
        final payload = switch (action) {
          'GetPositionInfo' =>
            '<TrackDuration>00:05:00</TrackDuration>'
                '<RelTime>${_time(relSeconds)}</RelTime>'
                '<AbsTime>${_time(relSeconds)}</AbsTime>',
          'GetTransportInfo' =>
            '<CurrentTransportState>$transport</CurrentTransportState>'
                '<CurrentTransportStatus>OK</CurrentTransportStatus>',
          'GetVolume' => '<CurrentVolume>$volume</CurrentVolume>',
          _ => '',
        };
        await _xml(request, _envelope(action, payload));
        return;
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    } catch (error) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write('$error');
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> _xml(HttpRequest request, String body) async {
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType('text', 'xml');
    request.response.add(utf8.encode(body));
    await request.response.close();
  }

  static String _envelope(String action, String payload) {
    return '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body><u:${action}Response '
        'xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">'
        '$payload</u:${action}Response></s:Body></s:Envelope>';
  }

  static int _seconds(String value) {
    var total = 0;
    for (final part in value.split(':')) {
      total = total * 60 + (int.tryParse(part) ?? 0);
    }
    return total;
  }

  static String _time(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    String two(int v) => v < 10 ? '0$v' : '$v';
    return '${two(h)}:${two(m)}:${two(s)}';
  }

  final String _description = '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <URLBase>http://127.0.0.1:PORT/</URLBase>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>客厅电视</friendlyName>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
        <controlURL>/av</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>
        <controlURL>/rc</controlURL>
      </service>
    </serviceList>
  </device>
</root>''';

  final String _routerDescription = '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType>
    <friendlyName>路由器</friendlyName>
  </device>
</root>''';
}

/// 本地假电视：监听 SSDP 239.255.255.250:1900，收到 M-SEARCH 后单播回
/// 设备描述地址。用于在没有真实电视时验证 discover() 的完整链路。
class MockSsdpResponder {
  MockSsdpResponder(this.rendererPort);

  final int rendererPort;
  RawDatagramSocket? _socket;

  Future<void> start() async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      1900,
      reuseAddress: true,
      reusePort: true,
    );
    _socket = socket;
    socket.broadcastEnabled = true;
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: true,
      );
      for (final interface in interfaces) {
        try {
          socket.joinMulticast(
            InternetAddress('239.255.255.250'),
            interface,
          );
        } catch (_) {}
      }
    } catch (_) {}
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      while (true) {
        final packet = socket.receive();
        if (packet == null) break;
        final text = utf8.decode(packet.data, allowMalformed: true);
        if (!text.startsWith('M-SEARCH')) continue;
        final response = utf8.encode(
          'HTTP/1.1 200 OK\r\n'
          'CACHE-CONTROL: max-age=1800\r\n'
          'LOCATION: http://127.0.0.1:$rendererPort/desc.xml\r\n'
          'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
          'USN: uuid:mock-tv::urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
          'SERVER: Test/1.0 UPnP/1.1\r\n\r\n',
        );
        socket.send(response, packet.address, packet.port);
      }
    });
  }

  void close() => _socket?.close();
}

Future<void> main() async {
  final renderer = MockRenderer();
  await renderer.start();
  final rendererPort = renderer.port;
  final description = renderer.descriptionUrl;
  final service = CastService.instance;

  // 1) 设备描述解析：只接受带 AVTransport 的 MediaRenderer。
  final device = await service.describeLocation(description);
  check(device != null, 'describeLocation returns renderer');
  final d = device!;
  checkEq(d.name, '客厅电视', 'friendlyName');
  checkEq(d.ip, '127.0.0.1', 'ip from description');
  checkEq(
    d.controlUrl,
    'http://127.0.0.1:$rendererPort/av',
    'absolute AVTransport controlUrl',
  );
  check(d.supportsVolume, 'RenderingControl -> supportsVolume');
  checkEq(
    await service.describeLocation(
      'http://127.0.0.1:$rendererPort/router.xml',
    ),
    null,
    'non-renderer description rejected',
  );

  // 2) SSDP 解析。
  final ssdp = CastService.parseSsdpResponse(
    'HTTP/1.1 200 OK\r\n'
    'CACHE-CONTROL: max-age=1800\r\n'
    'LOCATION: $description\r\n'
    'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
    'USN: uuid:tv-1::urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
    'SERVER: Linux UPnP/1.0\r\n\r\n',
  );
  check(ssdp != null, 'parse M-SEARCH response');
  checkEq(ssdp!.location, description, 'SSDP LOCATION');
  checkEq(ssdp.usn, 'uuid:tv-1::urn:schemas-upnp-org:device:MediaRenderer:1',
      'SSDP USN');
  check(
    CastService.parseSsdpResponse(
          'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n\r\n',
        ) ==
        null,
    'ignore M-SEARCH request',
  );
  check(
    CastService.parseSsdpResponse(
          'NOTIFY * HTTP/1.1\r\n'
          'NTS: ssdp:byebye\r\n'
          'LOCATION: $description\r\n\r\n',
        ) ==
        null,
    'ignore ssdp:byebye',
  );
  check(
    CastService.parseSsdpResponse(
          'HTTP/1.1 200 OK\r\nST: urn:test\r\n\r\n',
        ) ==
        null,
    'ignore missing LOCATION',
  );

  // 3) 投屏地址：直链优先；防盗链源改走服务器代理。
  const api = 'https://api.example.com/api';
  const directUrl = 'https://cdn.example.com/movie.m3u8';
  checkEq(
    CastService.resolveCastUrl(
      directUrl,
      headers: const <String, String>{'User-Agent': 'Mozilla/5.0'},
      serverBase: api,
    ),
    directUrl,
    'plain direct URL stays direct',
  );
  final proxied = CastService.resolveCastUrl(
    directUrl,
    headers: const <String, String>{
      'Referer': 'https://redbull.example.com/',
      'User-Agent': 'Mozilla/5.0',
    },
    serverBase: api,
  );
  check(
    proxied.startsWith('https://api.example.com/api/proxy?u='),
    'Referer source uses /api/proxy',
  );
  check(
    proxied.contains(Uri.encodeComponent(directUrl)),
    'proxy carries encoded source URL',
  );
  final own = CastService.resolveCastUrl(
    'https://api.example.com/api/fyplay?id=1',
    headers: const <String, String>{
      'Referer': 'https://redbull.example.com/',
    },
    serverBase: api,
  );
  checkEq(own, 'https://api.example.com/api/fyplay?id=1',
      'own server URL is not double-proxied');
  var loopbackRejected = false;
  try {
    CastService.resolveCastUrl('http://127.0.0.1:8080/a.m3u8');
  } on CastException {
    loopbackRejected = true;
  }
  check(loopbackRejected, 'loopback URL rejected');

  // 4) SSDP 发现完整链路：假电视回 M-SEARCH，CastService 拉描述并去重。
  final responder = MockSsdpResponder(rendererPort);
  var discoveryAvailable = true;
  try {
    await responder.start();
  } catch (_) {
    discoveryAvailable = false;
  }
  if (discoveryAvailable) {
    final devices = await service.discover(timeout: const Duration(seconds: 2));
    check(
      devices.any((item) => item.name == '客厅电视'),
      'discover finds mock TV over SSDP',
    );
    check(
      devices.where((item) => item.name == '客厅电视').length == 1,
      'discover dedupes repeated SSDP responses',
    );
    responder.close();
  } else {
    // 没有可用组播的环境（CI / 蜂窝网）跳过这一项，其余控制逻辑仍覆盖。
    check(true, 'SSDP discovery skipped (no multicast)');
  }

  // 5) 投屏控制：SetAVTransportURI + Play + 从手机进度续播 Seek。
  await service.play(
    d,
    'http://cdn.example.com/movie.m3u8?token=1',
    title: '测试影片 · 第1集',
    startAt: const Duration(seconds: 30),
  );
  check(renderer.actions.contains('SetAVTransportURI'), 'set AVTransport URI');
  checkEq(
    renderer.currentUri,
    'http://cdn.example.com/movie.m3u8?token=1',
    'TV received current URI',
  );
  check(renderer.actions.contains('Play'), 'play sent');
  checkEq(renderer.seekTarget, '00:00:30', 'resume position seek');
  check(service.isCasting, 'service is casting');
  checkEq(service.state.phase, CastPhase.playing, 'phase playing');
  checkEq(service.state.duration, const Duration(minutes: 5), 'duration');
  checkEq(service.state.position, const Duration(seconds: 30), 'position');
  checkEq(service.state.volume, 20, 'initial volume');

  await service.pause();
  checkEq(renderer.transport, 'PAUSED_PLAYBACK', 'pause reaches TV');
  checkEq(service.state.phase, CastPhase.paused, 'phase paused');

  await service.resume();
  checkEq(renderer.transport, 'PLAYING', 'resume reaches TV');
  checkEq(service.state.phase, CastPhase.playing, 'phase resumed');

  await service.seek(const Duration(seconds: 95));
  checkEq(renderer.seekTarget, '00:01:35', 'seek target formatted');
  checkEq(service.state.position, const Duration(seconds: 95), 'seek state');

  await service.setVolume(35);
  checkEq(renderer.volume, 35, 'volume reaches TV');
  checkEq(service.state.volume, 35, 'volume state');

  // 6) 2 秒轮询刷新进度。
  renderer.relSeconds = 40;
  await Future<void>.delayed(const Duration(milliseconds: 2300));
  checkEq(service.state.position, const Duration(seconds: 40), 'polling position');

  await service.stop();
  checkEq(renderer.transport, 'STOPPED', 'stop reaches TV');
  check(!service.isCasting, 'stop clears cast session');
  checkEq(service.state.phase, CastPhase.idle, 'phase idle after stop');

  await renderer.close();
  service.dispose();
  print('PASS: $_passed checks');
}

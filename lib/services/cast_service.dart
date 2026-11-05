import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dlna_dart/dlna.dart';
// dlna.dart 只 import 不 export 协议解析器；这里直接用公开的 xmlParser
// 库构造 DLNADevice（控制 AVTransport / RenderingControl）。
import 'package:dlna_dart/xmlParser.dart'
    show
        DeviceInfo,
        DeviceInfoParser,
        PositionParser,
        TransportInfoParser,
        VideoMime,
        VolumeParser;

import '../models.dart' show kDefaultVideoUserAgent;

/// 投屏失败：message 直接给用户看，cause 保留原始异常便于日志排查。
class CastException implements Exception {
  const CastException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

/// 一次投屏的地址来源。
///
/// [url] 已经过 [CastService.resolveSource] 处理：需要 Referer / 自定义 UA
/// 的源会换成服务器代理地址，电视能直接拉流。
class CastSource {
  const CastSource({
    required this.url,
    required this.title,
    this.isLive = false,
    this.direct = false,
    this.startAt = Duration.zero,
  });

  final String url;
  final String title;
  final bool isLive;
  final bool direct;

  /// 投屏后从手机当前进度继续播放；直播传零即可。
  final Duration startAt;

  /// 当前是否走 `/api/proxy?u=` 服务器代理。
  bool get viaProxy => url.contains('/api/proxy?');
}

enum CastPhase { idle, connecting, playing, paused, error }

/// 投屏会话快照。CastSheet 订阅 [CastService.changes] 后据此重绘遥控面板。
class CastState {
  const CastState({
    this.phase = CastPhase.idle,
    this.device,
    this.title = '',
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.volume,
    this.supportsVolume = false,
    this.error,
  });

  static const CastState idle = CastState();

  final CastPhase phase;
  final CastDevice? device;
  final String title;
  final Duration position;
  final Duration duration;

  /// null = 还没读到 / 设备不支持音量控制。
  final int? volume;
  final bool supportsVolume;
  final String? error;

  bool get isCasting => device != null;
  bool get isPlaying => phase == CastPhase.playing;
  bool get supportsSeek => duration > Duration.zero;

  CastState copyWith({
    CastPhase? phase,
    CastDevice? device,
    String? title,
    Duration? position,
    Duration? duration,
    int? volume,
    bool? supportsVolume,
    String? error,
    bool clearError = false,
    bool clearVolume = false,
  }) {
    return CastState(
      phase: phase ?? this.phase,
      device: device ?? this.device,
      title: title ?? this.title,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      volume: clearVolume ? null : (volume ?? this.volume),
      supportsVolume: supportsVolume ?? this.supportsVolume,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// 局域网 DLNA/UPnP 渲染器。
///
/// - [controlUrl] 是 AVTransport 的绝对 SOAP 控制地址；
/// - [services] 原样保留 serviceList，控制时重新交给 dlna_dart 解析；
/// - 去重 / 测试比较只用 [controlUrl]。
class CastDevice {
  const CastDevice({
    required this.name,
    required this.ip,
    required this.controlUrl,
    required this.location,
    this.baseUrl = '',
    this.supportsVolume = false,
    this.services = const <Map<String, String>>[],
  });

  final String name;
  final String ip;
  final String controlUrl;

  /// SSDP 响应里的设备描述地址。
  final String location;

  /// 设备描述里的 URLBase；没有时用描述地址推导。
  final String baseUrl;
  final bool supportsVolume;

  /// dlna_dart 的 DeviceInfo.serviceList 结构：
  /// `{serviceType, serviceId, controlURL}`。
  final List<Map<String, String>> services;

  @override
  bool operator ==(Object other) =>
      other is CastDevice &&
      other.controlUrl.toLowerCase() == controlUrl.toLowerCase();

  @override
  int get hashCode => controlUrl.toLowerCase().hashCode;

  @override
  String toString() => '$name($ip)';
}

/// SSDP 搜索命中的一条响应（也用于单测解析逻辑）。
class SsdpResponse {
  const SsdpResponse({
    required this.location,
    required this.key,
    this.st = '',
    this.usn = '',
    this.sourceIp = '',
  });

  final String location;
  final String key;
  final String st;
  final String usn;
  final String sourceIp;
}

/// DLNA 投屏服务：SSDP 发现 + AVTransport / RenderingControl 遥控。
///
/// 单例：投屏会话跨详情页 / 全屏页持续存在，页面只负责打开 CastSheet
/// 和离开时调用 [stopIfOwned]。
///
/// 本文件刻意不 import Flutter（除 API 常量外全是纯 Dart），便于
/// `tools/test_cast_service.dart` 在手机上的 Dart VM 里直接跑协议测试。
class CastService {
  CastService._();

  static final CastService instance = CastService._();

  /// 搜索窗口：5 秒内收集 SSDP 响应，再给设备描述最多 ~1 秒。
  static const Duration discoveryTimeout = Duration(seconds: 5);

  static const Duration _opTimeout = Duration(seconds: 8);
  static const Duration _queryTimeout = Duration(seconds: 4);
  static const Duration _pollInterval = Duration(seconds: 2);

  static const String _ssdpHost = '239.255.255.250';
  static const int _ssdpPort = 1900;
  static const String _mediaRenderer =
      'urn:schemas-upnp-org:device:MediaRenderer:1';
  static const String _avTransport =
      'urn:schemas-upnp-org:service:AVTransport:1';
  static const String _renderingControl =
      'urn:schemas-upnp-org:service:RenderingControl:1';
  static const String _userAgent =
      'FantasyTV/1.0 UPnP/1.1 DLNADOC/1.50';

  final StreamController<CastState> _changes =
      StreamController<CastState>.broadcast(sync: true);

  CastState _state = CastState.idle;
  DLNADevice? _remote;
  Object? _owner;
  Future<List<CastDevice>>? _discovering;

  Timer? _pollTimer;
  bool _polling = false;
  int _pollTick = 0;
  int _pollFailures = 0;
  int? _volume;
  int _sessionId = 0;

  Stream<CastState> get changes => _changes.stream;
  CastState get state => _state;
  CastDevice? get device => _state.device;
  bool get isCasting => _state.device != null;
  Duration get position => _state.position;

  /// 当前投屏会话是否由 [owner] 发起（页面 dispose 时只停自己的会话）。
  bool isOwnedBy(Object owner) => identical(_owner, owner);

  // ---------------------------------------------------------------- 发现

  /// SSDP 搜索局域网 DLNA 渲染器，[timeout] 内返回去重后的设备列表。
  ///
  /// 未找到设备返回空列表（由 UI 提示「同一 WiFi 下未发现电视」）；
  /// 端口 / 组播不可用时抛出 [CastException]。
  Future<List<CastDevice>> discover({Duration timeout = discoveryTimeout}) {
    final running = _discovering;
    if (running != null) return running;
    late final Future<List<CastDevice>> future;
    future = _discover(timeout).whenComplete(() {
      if (identical(_discovering, future)) _discovering = null;
    });
    _discovering = future;
    return future;
  }

  Future<List<CastDevice>> _discover(Duration timeout) async {
    final watch = Stopwatch()..start();
    final hits = <String, SsdpResponse>{};
    final devices = <String, CastDevice>{};
    final jobs = <Future<void>>[];
    RawDatagramSocket? socket;
    StreamSubscription<RawSocketEvent>? sub;

    void consider(String message, String sourceIp) {
      final hit = parseSsdpResponse(message, sourceIp: sourceIp);
      if (hit == null || hits.containsKey(hit.key)) return;
      hits[hit.key] = hit;
      jobs.add(
        describeLocation(hit.location)
            .then((device) {
              if (device == null) return;
              devices.putIfAbsent(device.controlUrl.toLowerCase(), () => device);
            })
            .catchError((Object _) {}),
      );
    }

    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
      );
      socket.broadcastEnabled = true;
      socket.multicastHops = 4;
      await _joinMulticast(socket);
      sub = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        while (true) {
          final packet = socket?.receive();
          if (packet == null) break;
          final text = utf8.decode(packet.data, allowMalformed: true);
          consider(text, packet.address.address);
        }
      });

      var round = 0;
      while (watch.elapsed < timeout) {
        _sendSearch(socket, first: round == 0);
        round++;
        final remain = timeout - watch.elapsed;
        if (remain <= Duration.zero) break;
        await Future<void>.delayed(
          remain < const Duration(milliseconds: 900)
              ? remain
              : const Duration(milliseconds: 900),
        );
      }
    } on SocketException catch (e) {
      throw CastException('无法发起局域网搜索，请确认手机已连接 WiFi', cause: e);
    } finally {
      await sub?.cancel();
      socket?.close();
    }

    // 设备描述通常在 100ms 内返回；给搜索结束后仍在途的请求一点时间，
    // 超过就放弃慢设备，保证整体体验接近 5 秒。
    if (jobs.isNotEmpty) {
      try {
        await Future.wait(jobs).timeout(const Duration(milliseconds: 1100));
      } catch (_) {
        // 部分设备描述超时不影响其它结果。
      }
    }

    final list = devices.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  Future<void> _joinMulticast(RawDatagramSocket socket) async {
    final group = InternetAddress(_ssdpHost);
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      var joined = false;
      for (final interface in interfaces) {
        if (interface.addresses.isEmpty) continue;
        try {
          socket.joinMulticast(group, interface);
          joined = true;
        } catch (_) {
          // 某些虚拟网卡 / 蜂窝网卡不支持组播，跳过即可。
        }
      }
      if (joined) return;
    } catch (_) {
      // NetworkInterface.list 在部分 ROM 上会失败，退回默认网卡。
    }
    try {
      socket.joinMulticast(group);
    } catch (_) {
      // 没有 WiFi 时仍然可以发 M-SEARCH，靠单播响应发现设备。
    }
  }

  void _sendSearch(RawDatagramSocket socket, {required bool first}) {
    final targets = first
        ? const <String>['ssdp:all', _mediaRenderer, _avTransport]
        : const <String>[_mediaRenderer, _avTransport];
    for (final st in targets) {
      final data = utf8.encode(
        'M-SEARCH * HTTP/1.1\r\n'
        'HOST: $_ssdpHost:$_ssdpPort\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 2\r\n'
        'ST: $st\r\n'
        'USER-AGENT: $_userAgent\r\n'
        '\r\n',
      );
      try {
        socket.send(data, InternetAddress(_ssdpHost), _ssdpPort);
      } catch (_) {
        // 单次发包失败不终止整个搜索。
      }
    }
  }

  /// 解析 SSDP `HTTP/1.1 200 OK` / `NOTIFY * HTTP/1.1` 响应。
  ///
  /// M-SEARCH 请求、byebye、缺 LOCATION 的包都返回 null。公开给单测用。
  static SsdpResponse? parseSsdpResponse(String text, {String sourceIp = ''}) {
    final lines = text.split(RegExp(r'\r?\n'));
    if (lines.isEmpty) return null;
    final status = lines.first.trim().toUpperCase();
    if (!status.startsWith('HTTP/1.1 200') &&
        !status.startsWith('HTTP/1.0 200') &&
        !status.startsWith('NOTIFY * HTTP/1.1')) {
      return null;
    }
    final headers = <String, String>{};
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i];
      if (line.trim().isEmpty) break;
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      headers[line.substring(0, idx).trim().toUpperCase()] =
          line.substring(idx + 1).trim();
    }
    if ((headers['NTS'] ?? '').toLowerCase() == 'ssdp:byebye') return null;
    final location = (headers['LOCATION'] ?? '').trim();
    if (location.isEmpty) return null;
    final uri = Uri.tryParse(location);
    if (uri == null || uri.host.isEmpty) return null;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return null;
    final usn = (headers['USN'] ?? '').trim();
    final st = (headers['ST'] ?? '').trim();
    return SsdpResponse(
      location: location,
      key: usn.isNotEmpty ? usn : location.toLowerCase(),
      st: st,
      usn: usn,
      sourceIp: sourceIp.isNotEmpty ? sourceIp : uri.host,
    );
  }

  /// 拉取并解析任意一个设备描述地址；非 DLNA 渲染器返回 null。
  ///
  /// 公开给单测 / 调试用，正常发现流程由 [discover] 自动调用。
  Future<CastDevice?> describeLocation(String location) async {
    final uri = Uri.tryParse(location);
    if (uri == null) return null;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 3));
      req.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      final res = await req.close().timeout(const Duration(seconds: 3));
      if (res.statusCode != HttpStatus.ok) return null;
      var body = await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 3));
      // 部分电视的描述 XML 带 UTF-8 BOM，XmlDocument.parse 会直接报错。
      if (body.startsWith('\uFEFF')) body = body.substring(1);
      final info = DeviceInfoParser(body).parse(uri);
      final av = _serviceFor(info, 'AVTransport');
      if (av == null) return null;
      final rc = _serviceFor(info, 'RenderingControl');
      final base = info.URLBase.trim().isEmpty
          ? _baseFromLocation(uri)
          : info.URLBase.trim();
      final controlUrl = _resolveUrl(base, av['controlURL'] ?? '');
      if (controlUrl.isEmpty) return null;
      final services = <Map<String, String>>[
        <String, String>{
          'serviceType': av['serviceType'] ?? _avTransport,
          'serviceId': av['serviceId'] ?? '',
          'controlURL': controlUrl,
        },
        if (rc != null)
          <String, String>{
            'serviceType': rc['serviceType'] ?? _renderingControl,
            'serviceId': rc['serviceId'] ?? '',
            'controlURL': _resolveUrl(base, rc['controlURL'] ?? ''),
          },
      ];
      final ip = uri.host;
      return CastDevice(
        name: _cleanName(info.friendlyName, fallback: info.deviceType),
        ip: ip,
        controlUrl: controlUrl,
        location: location,
        baseUrl: base,
        supportsVolume: rc != null,
        services: services,
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static Map<String, String>? _serviceFor(DeviceInfo info, String kind) {
    for (final raw in info.serviceList) {
      if (raw is! Map) continue;
      final type = '${raw['serviceType'] ?? ''}';
      final id = '${raw['serviceId'] ?? ''}';
      if (!type.contains(kind) && !id.contains(kind)) continue;
      return <String, String>{
        'serviceType': type,
        'serviceId': id,
        'controlURL': '${raw['controlURL'] ?? ''}',
      };
    }
    return null;
  }

  static String _baseFromLocation(Uri uri) {
    var path = uri.path;
    if (path.isEmpty || path == '/') return uri.origin;
    if (!path.endsWith('/')) {
      final i = path.lastIndexOf('/');
      path = i <= 0 ? '/' : path.substring(0, i + 1);
    }
    return '${uri.origin}$path';
  }

  static String _resolveUrl(String base, String path) {
    final raw = path.trim();
    if (raw.isEmpty) return '';
    if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
    try {
      final normalized = base.endsWith('/') ? base : '$base/';
      return Uri.parse(normalized).resolve(raw).toString();
    } catch (_) {
      return '';
    }
  }

  static String _cleanName(String name, {String fallback = ''}) {
    var text = name.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) text = fallback.trim();
    if (text.isEmpty) text = '未命名电视';
    return text.length > 40 ? text.substring(0, 40) : text;
  }

  // ---------------------------------------------------------------- 地址

  /// 把当前播放地址转换成电视能拉的地址。
  ///
  /// - 已是本服务器地址（`/api/fyplay`、`/api/proxy` 等）直接使用；
  /// - 源站需要 Referer / Cookie / 非默认 UA 时改用 `/api/proxy?u=`，
  ///   由服务器补请求头（红牛 / bfvvs 等防盗链源）；
  /// - 其余保持直链。
  static String resolveCastUrl(
    String rawUrl, {
    Map<String, String> headers = const <String, String>{},
    String serverBase = '',
  }) {
    final url = rawUrl.trim();
    if (url.isEmpty) throw const CastException('当前没有可投屏的播放地址');
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      throw const CastException('当前播放地址不是 http(s) 直链，无法投屏');
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      throw const CastException('当前播放地址不是 http(s) 直链，无法投屏');
    }
    if (_isLoopback(uri)) {
      throw const CastException('当前播放地址在手机本机，电视无法访问');
    }
    if (_isOwnServer(uri, serverBase) || !_needsProxy(headers)) return url;
    if (serverBase.trim().isEmpty) {
      throw const CastException('服务器地址未就绪，无法代理需要防盗链的片源');
    }
    final root = serverBase.replaceFirst(RegExp(r'/api/?$'), '');
    return '$root/api/proxy?u=${Uri.encodeComponent(url)}';
  }

  /// 解析一次播放源，供各页面直接构造 [CastSource]。
  static CastSource resolveSource({
    required String url,
    required String title,
    Map<String, String> headers = const <String, String>{},
    bool isLive = false,
    bool direct = false,
    Duration startAt = Duration.zero,
    String serverBase = '',
  }) {
    return CastSource(
      url: resolveCastUrl(url, headers: headers, serverBase: serverBase),
      title: title.trim().isEmpty ? (isLive ? '电视直播' : '正在播放') : title.trim(),
      isLive: isLive,
      direct: direct,
      startAt: startAt < Duration.zero ? Duration.zero : startAt,
    );
  }

  static bool _isLoopback(Uri uri) {
    final host = uri.host.toLowerCase();
    return host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1' ||
        host == '0.0.0.0';
  }

  static bool _isOwnServer(Uri uri, String serverBase) {
    final base = Uri.tryParse(serverBase.trim());
    if (base == null || base.host.isEmpty) return false;
    return uri.host.toLowerCase() == base.host.toLowerCase();
  }

  static bool _needsProxy(Map<String, String> headers) {
    for (final entry in headers.entries) {
      final name = entry.key.toLowerCase();
      final value = entry.value.trim();
      if (value.isEmpty) continue;
      if (name == 'referer' || name == 'origin' || name == 'cookie') {
        return true;
      }
      if (name == 'user-agent' && value != kDefaultVideoUserAgent) {
        return true;
      }
    }
    return false;
  }

  // ---------------------------------------------------------------- 控制

  /// 设置 AVTransport URI 并开始播放。
  Future<void> play(
    CastDevice device,
    String url, {
    String? title,
    Object? owner,
    Duration startAt = Duration.zero,
  }) async {
    final target = url.trim();
    final uri = Uri.tryParse(target);
    if (uri == null || uri.host.isEmpty) {
      throw const CastException('投屏地址无效，电视无法打开');
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      throw const CastException('投屏地址无效，电视无法打开');
    }
    if (_isLoopback(uri)) {
      throw const CastException('投屏地址在手机本机，电视无法访问');
    }

    await _finishSession(stopRemote: true);
    final session = ++_sessionId;
    _remote = DLNADevice(
      DeviceInfo(
        device.baseUrl.isEmpty ? device.location : device.baseUrl,
        'MediaRenderer',
        device.name,
        device.services,
      ),
    );
    _owner = owner;
    _state = CastState(
      phase: CastPhase.connecting,
      device: device,
      title: title?.trim() ?? '',
      supportsVolume: device.supportsVolume,
    );
    _emit();

    final cleanTitle = (title ?? '').trim();
    try {
      await _withDevice(device, () async {
        final body = await _remote!
            .setUrl(
              target,
              title: cleanTitle.isEmpty ? device.name : cleanTitle,
              type: VideoMime.any,
            )
            .timeout(_opTimeout);
        _checkSoapFault(body);
        final playBody = await _remote!.play().timeout(_opTimeout);
        _checkSoapFault(playBody);
      });
      _ensureActive(session);

      var supportsVolume = device.supportsVolume;
      var volume = _volume;
      if (supportsVolume) {
        try {
          volume = VolumeParser(
            await _remote!.getVolume().timeout(_queryTimeout),
          ).current;
          _volume = volume;
        } catch (_) {
          // 描述里声明了 RenderingControl，但设备实际不响应：隐藏音量条。
          supportsVolume = false;
        }
      }

      var duration = Duration.zero;
      try {
        final info = PositionParser(
          await _remote!.position().timeout(_queryTimeout),
        );
        duration = Duration(seconds: info.TrackDurationInt);
        _state = _state.copyWith(
          position: Duration(seconds: info.RelTimeInt),
        );
      } catch (_) {
        // 部分直播渲染器没有 TrackDuration，保持 0。
      }
      _ensureActive(session);

      // 从手机当前进度继续：能 seek 的片源先跳过去，失败也不影响已开始的投屏。
      var position = _state.position;
      if (startAt > Duration.zero &&
          duration > Duration.zero &&
          startAt < duration - const Duration(seconds: 2)) {
        try {
          final body = await _remote!
              .seek(_formatTime(startAt))
              .timeout(_opTimeout);
          _checkSoapFault(body);
          position = startAt;
        } catch (_) {
          // 电视拒绝 seek 时从电视自己的起点播放。
        }
      }

      _ensureActive(session);
      _state = _state.copyWith(
        phase: CastPhase.playing,
        position: position,
        duration: duration,
        supportsVolume: supportsVolume,
        volume: volume,
        clearError: true,
      );
      _emit();
      _startPolling();
    } catch (error) {
      final failure = error is CastException
          ? error
          : _friendly(error, device);
      await _finishSession(stopRemote: true);
      throw failure;
    }
  }

  Future<void> pause() async {
    final remote = _remote;
    final device = _state.device;
    if (remote == null || device == null) {
      throw const CastException('还没有连接电视');
    }
    await _withDevice(device, () async {
      final body = await remote.pause().timeout(_opTimeout);
      _checkSoapFault(body);
    });
    _state = _state.copyWith(phase: CastPhase.paused, clearError: true);
    _emit();
  }

  Future<void> resume() async {
    final remote = _remote;
    final device = _state.device;
    if (remote == null || device == null) {
      throw const CastException('还没有连接电视');
    }
    await _withDevice(device, () async {
      final body = await remote.play().timeout(_opTimeout);
      _checkSoapFault(body);
    });
    _state = _state.copyWith(phase: CastPhase.playing, clearError: true);
    _emit();
  }

  /// 调整电视端进度；直播（没有 TrackDuration）不支持。
  Future<void> seek(Duration position) async {
    final remote = _remote;
    final device = _state.device;
    if (remote == null || device == null) {
      throw const CastException('还没有连接电视');
    }
    if (_state.duration <= Duration.zero) {
      throw const CastException('直播投屏不支持调整进度');
    }
    var target = position;
    if (target < Duration.zero) target = Duration.zero;
    if (target > _state.duration) target = _state.duration;
    final text = _formatTime(target);
    await _withDevice(device, () async {
      final body = await remote.seek(text).timeout(_opTimeout);
      _checkSoapFault(body);
    });
    _state = _state.copyWith(position: target);
    _emit();
  }

  Future<void> setVolume(int volume) async {
    final remote = _remote;
    final device = _state.device;
    if (remote == null || device == null) {
      throw const CastException('还没有连接电视');
    }
    if (!_state.supportsVolume) {
      throw const CastException('这台电视不支持音量控制');
    }
    final value = volume < 0 ? 0 : (volume > 100 ? 100 : volume);
    await _withDevice(device, () async {
      final body = await remote.volume(value).timeout(_opTimeout);
      _checkSoapFault(body);
    });
    _volume = value;
    _state = _state.copyWith(volume: value);
    _emit();
  }

  /// 停止电视播放并清空会话；页面退出 / 面板「停止投屏」都调用它。
  Future<void> stop() => _finishSession(stopRemote: true);

  /// 只停止自己发起的会话：详情页 / 直播页 dispose 时调用，
  /// 避免误停别的页面刚建立的投屏。
  Future<void> stopIfOwned(Object owner) async {
    if (isOwnedBy(owner)) await stop();
  }

  Future<void> _finishSession({required bool stopRemote}) async {
    final remote = _remote;
    final device = _state.device;
    _sessionId++;
    _remote = null;
    _owner = null;
    _pollTimer?.cancel();
    _pollTimer = null;
    _polling = false;
    _pollFailures = 0;
    if (stopRemote && remote != null && device != null) {
      try {
        await remote.stop().timeout(const Duration(seconds: 5));
      } catch (_) {
        // 电视可能已经关机 / 断网，退出投屏不能被它卡住。
      }
    }
    remote?.dispose();
    _volume = null;
    _state = CastState.idle;
    _emit();
  }

  void _ensureActive(int session) {
    if (session != _sessionId || _remote == null) {
      throw const CastException('投屏已取消');
    }
  }

  Future<T> _withDevice<T>(
    CastDevice device,
    Future<T> Function() action,
  ) async {
    try {
      return await action();
    } catch (error) {
      if (error is CastException) rethrow;
      throw _friendly(error, device);
    }
  }

  static CastException _friendly(Object error, CastDevice device) {
    if (error is CastException) return error;
    if (error is TimeoutException) {
      return CastException(
        '电视无响应，请确认电视已开机并和手机连在同一个 WiFi',
        cause: error,
      );
    }
    if (error is SocketException) {
      return CastException(
        '连接不上电视 ${device.ip}，请确认手机和电视在同一个 WiFi',
        cause: error,
      );
    }
    final text = error.toString();
    final status = RegExp(r'status\s+(\d{3})').firstMatch(text)?.group(1);
    final code = RegExp(r'<errorCode>\s*(\d+)\s*</errorCode>')
        .firstMatch(text)
        ?.group(1);
    if (status != null) {
      return CastException(_upnpErrorText(code, status), cause: error);
    }
    if (text.contains('not found controlURL')) {
      return CastException('这台设备不支持 DLNA 播放', cause: error);
    }
    if (text.contains('XmlParserException') ||
        text.contains('FormatException')) {
      return CastException('电视返回的数据无法识别，请换一台电视试试', cause: error);
    }
    var detail = text.trim();
    if (detail.length > 120) detail = '${detail.substring(0, 120)}…';
    return CastException(
      '投屏失败：${detail.isEmpty ? '未知错误' : detail}',
      cause: error,
    );
  }

  static void _checkSoapFault(String body) {
    if (!body.contains('UPnPError')) return;
    final code =
        RegExp(r'<errorCode>\s*(\d+)\s*</errorCode>').firstMatch(body)?.group(1);
    throw CastException(_upnpErrorText(code, '500'), cause: body);
  }

  static String _upnpErrorText(String? code, String status) {
    return switch (code) {
      '701' => '电视不支持这个视频格式',
      '702' => '电视不支持这个视频格式',
      '714' => '电视正忙，请稍后重试',
      '715' => '电视不支持这个播放资源',
      '716' => '电视不支持这个播放地址',
      '718' => '电视打不开这个播放地址',
      '402' || '501' => '这台电视不支持该操作',
      _ => '电视拒绝了这个请求（HTTP $status${code == null ? '' : ' / $code'}）',
    };
  }

  // ---------------------------------------------------------------- 轮询

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTick = 0;
    _pollFailures = 0;
    _pollTimer = Timer.periodic(_pollInterval, (_) {
      unawaited(_poll());
    });
  }

  Future<void> _poll() async {
    if (_polling) return;
    final remote = _remote;
    final device = _state.device;
    if (remote == null || device == null) return;
    final session = _sessionId;
    _polling = true;
    try {
      final info = PositionParser(
        await remote.position().timeout(_queryTimeout),
      );
      final duration = Duration(seconds: info.TrackDurationInt);
      var phase = _state.phase;
      var volume = _state.volume;
      if (_pollTick % 3 == 0) {
        try {
          final transport = TransportInfoParser(
            await remote.getTransportInfo().timeout(_queryTimeout),
          );
          final state = transport.CurrentTransportState.toUpperCase();
          if (state == 'PLAYING') phase = CastPhase.playing;
          if (state == 'PAUSED_PLAYBACK' || state == 'PAUSED') {
            phase = CastPhase.paused;
          }
        } catch (_) {
          // 部分设备不支持 GetTransportInfo：保留当前按钮状态。
        }
        if (_state.supportsVolume) {
          try {
            volume = VolumeParser(
              await remote.getVolume().timeout(_queryTimeout),
            ).current;
            _volume = volume;
          } catch (_) {
            // 读不到音量时保留上一次的值。
          }
        }
      }
      if (session != _sessionId) return;
      _pollFailures = 0;
      _state = _state.copyWith(
        position: Duration(seconds: info.RelTimeInt),
        duration: duration,
        volume: volume,
        phase: phase,
      );
      _emit();
    } catch (_) {
      if (session != _sessionId) return;
      _pollFailures++;
      if (_pollFailures >= 3) {
        _pollTimer?.cancel();
        _pollTimer = null;
        _state = _state.copyWith(
          phase: CastPhase.error,
          error: '电视连接中断，请重新投屏',
        );
        _emit();
      }
    } finally {
      _polling = false;
      _pollTick++;
    }
  }

  static String _formatTime(Duration value) {
    final total = value.inSeconds < 0 ? 0 : value.inSeconds;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    String two(int v) => v < 10 ? '0$v' : '$v';
    return '${two(h)}:${two(m)}:${two(s)}';
  }

  void _emit() {
    if (_changes.isClosed) return;
    _changes.add(_state);
  }

  /// 进程退出前调用（测试或热重启时清理）。
  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _remote?.dispose();
    _remote = null;
    if (!_changes.isClosed) _changes.close();
  }
}

import 'package:flutter/foundation.dart';

import 'cms_bridge.dart' show CmsBridge;
import '../widgets/player_theme.dart' show fxLoadProgress, fxResumeMinSeconds;
import 'app_settings.dart';
import 'exo_player.dart';
import 'fx_player.dart' show FxPlayCache;
import 'hls_segment_index.dart';
import 'network_status.dart';

/// 一条「继续观看」的预取目标：视频 + 线路 + 集数 + 续播秒数。
///
/// 只有这四项就够了 —— 播放地址由 `/api/play` 现取，分片由 m3u8 现解析，
/// 这里不缓存任何会过期的地址。
@immutable
class ResumeTarget {
  const ResumeTarget({
    required this.videoId,
    required this.line,
    required this.episode,
    this.seconds = 0,
    this.title = '',
  });

  final String videoId;

  /// 线路 id（`/api/play` 的 `line` 参数），不是线路名。
  final String line;

  final int episode;

  /// 续播秒数：0 表示从头播，预取目标就是第 0 片。
  final double seconds;

  /// 仅用于日志。
  final String title;

  bool get isValid => videoId.isNotEmpty && line.isNotEmpty && episode > 0;

  /// 会话内去重用的整数键：`视频id|线路|集|秒数` 的 32 位指纹。
  int get key => _fingerprint(signature);

  /// 可读签名（日志 / 排查用）。
  String get signature => '$videoId|$line|$episode|${seconds.round()}';

  @override
  String toString() => 'ResumeTarget($signature title=$title)';
}

/// 首页「继续观看」预取：把续播位置的分片提前写进播放器同一份 SimpleCache。
///
/// 为什么要有这一层：详情页是打开即播，没有任何可插入的提前量；
/// 唯一稳定的时间窗口是「首页可见 → 用户点继续观看」这一小段。
/// 这里只做一件事 —— 让续播位置那一片（和紧随其后的一片）已经在本地缓存里，
/// 点开就是磁盘命中，首帧不用等网络。
///
/// 四条硬约束（任何一条破了都会变成负优化）：
///   · **写播放器同一个 SimpleCache**：必须走原生 `CacheDataSource`
///     （[ExoPlayerEngine.prefetchSegment]）。Dart 自己 http 拉下来只会落进
///     内存/临时文件，播放器按 URL 查缓存照样命中不了。
///   · **不阻塞、不打扰**：全部 fire-and-forget，失败静默，没有任何 UI。
///   · **一次会话一个目标只跑一次**：按 [ResumeTarget.key] 去重；失败最多再给
///     一次机会（`maxAttempts = 2`，即「重试不超过 1 次」），之后不再打扰网络。
///   · **不取消播放器的请求**：播放器真要那一片时，原生侧的预取线程不中断，
///     让 CacheDataSource 的写入自然跑完（播放器那头等的是同一份缓存写）。
class ResumePrefetch {
  ResumePrefetch._();

  /// 单条目标的整条预算：拉 /api/play + 拉 m3u8 + 两片落盘。
  static const Duration budget = Duration(seconds: 20);

  /// 移动网络下单次预取的字节上限（Wi-Fi / 有线不限）。
  ///
  /// 「仅 Wi-Fi 下载」开关没开时也允许在流量下预取，但必须有个上限，
  /// 否则 4K 两片就能吃掉几十 MB。
  static const int mobileByteBudget = 30 * 1024 * 1024;

  /// 每个目标最多尝试几次（首次 + 重试 1 次）。
  static const int maxAttempts = 2;

  /// 已经成功预取过的目标（会话内）。
  static final Set<int> _done = <int>{};

  /// 正在预取的目标：重复触发时直接跳过，不再拉一遍清单。
  static final Set<int> _active = <int>{};

  /// 每个目标试过几次。
  static final Map<int, int> _attempts = <int, int>{};

  /// 这个目标是否已经预取过 / 正在预取 / 试够次数了。
  static bool isWarmed(int key) =>
      _done.contains(key) ||
      _active.contains(key) ||
      (_attempts[key] ?? 0) >= maxAttempts;

  /// 预取一条「继续观看」记录。
  ///
  /// 任何一步失败都静默返回：预取只是把「点开即播」的概率做高，
  /// 不该给用户任何感知。
  static Future<void> warm(ResumeTarget target) async {
    if (!ExoPlayerEngine.isSupported || !target.isValid) return;
    // GULU_FIRST_PLAY：短寿命线路不预取。播放时会现签一条新地址
    // （见 FxPlayCache.isShortLived），这里签出来的那条没人会用，
    // 清单 + 分片全是白拉，还平白多打一次上游解析接口。
    if (FxPlayCache.isShortLived(target.line)) {
      _log('短寿命线路跳过预取 ${target.signature}');
      return;
    }
    final key = target.key;
    if (isWarmed(key)) return;
    _attempts[key] = (_attempts[key] ?? 0) + 1;
    _active.add(key);
    // 超时只包「这一次尝试」：超时后底层请求会自然结束，不再排队新分片。
    var timedOut = false;
    try {
      await _run(target).timeout(budget, onTimeout: () {
        timedOut = true;
        _log('${budget.inSeconds}s 预算用完，放弃 ${target.signature}');
      });
      if (!timedOut) _done.add(key);
    } catch (error) {
      _log('预取失败 ${target.signature}: $error');
    } finally {
      _active.remove(key);
    }
  }

  /// 续播秒数对应的分片 + 紧随其后的一片（目标片在前）。
  ///
  /// 抽成纯函数是为了让「按秒数定位分片」可以被离线校验：
  /// 起点 <= 秒数 的最后一片就是播放器 seek 到该位置时会拉的那一片。
  static List<HlsSegmentRef> segmentWindow(
    HlsPlaylistIndex index,
    double seconds,
  ) {
    final segments = index.segments;
    if (segments.isEmpty) return const <HlsSegmentRef>[];
    final ms = seconds <= 0 ? 0 : (seconds * 1000).round();
    final hit = index.segmentAtMs(ms);
    if (hit == null) return const <HlsSegmentRef>[];
    final at = segments.indexOf(hit);
    final out = <HlsSegmentRef>[hit];
    if (at >= 0 && at + 1 < segments.length) out.add(segments[at + 1]);
    return out;
  }

  // ------------------------------------------------------------ 主流程

  static Future<void> _run(ResumeTarget target) async {
    final kind = await NetworkStatus.detect();
    if (kind == FxNetworkKind.offline) {
      _log('没有网络，跳过 ${target.signature}');
      return;
    }
    await AppSettings.instance.init();
    // 「仅 Wi-Fi 下载」同时约束预取：用户已经明确表示不想在流量下走后台下载，
    // 首页预取属于同一类行为，不该偷偷绕过这个开关。
    if (AppSettings.instance.wifiOnlyDownload && kind == FxNetworkKind.mobile) {
      _log('仅 Wi-Fi 下载已开启，移动网络下跳过预取');
      return;
    }
    final maxBytes = kind == FxNetworkKind.mobile ? mobileByteBudget : 0;

    // 1) 播放地址：复用 FxPlayCache.resolve —— 播放器 open 时拿的是同一份结果
    //    （10 分钟 TTL），这样两边请求的 m3u8 地址完全一致，分片地址才可能一致。
    final info = await FxPlayCache.resolve(
      target.videoId,
      target.episode,
      target.line,
    );
    // 根跟着记录来源走（CMS 补站点根，旧接口才补 8787）。
    final playlist = CmsBridge.absolutePlayUrl(target.videoId, info.url);
    if (playlist.isEmpty || !_isHls(playlist, info.isHls)) {
      _log('不是 HLS 播放地址，跳过 ${target.signature}');
      return;
    }

    // 2) 清单：复用 HlsSegmentIndex（播放器拖动用的也是这份索引，
    //    解析规则同一套 —— 分片地址必须和播放器解析出来的逐字节一致）。
    final index = await HlsSegmentIndex.instance.indexOf(
      playlist,
      info.headers,
      budget: const Duration(seconds: 8),
    );
    if (index == null) {
      _log('清单没建起来，跳过 ${target.signature}');
      return;
    }

    // 3) 按续播秒数定位分片。
    final seconds = await _resumeSeconds(target);
    final window = segmentWindow(index, seconds);
    if (window.isEmpty) {
      _log('清单里没有可用分片，跳过 ${target.signature}');
      return;
    }
    _log(
      '续播 ${seconds.round()}s → 第 ${index.segments.indexOf(window.first)} 片，'
      '预取 ${window.length} 片（共 ${index.segments.length} 片）',
    );

    // 4) 逐片交给原生，写进播放器同一份 SimpleCache。
    for (final segment in window) {
      final url = segment.uri.toString();
      final accepted = await ExoPlayerEngine.prefetchSegment(
        url,
        headers: info.headers,
        maxBytes: maxBytes,
      );
      _log('提交预取 ${segment.startMs}ms accepted=$accepted $url');
    }
  }

  /// 播放器实际会从哪一秒开始播。
  ///
  /// 和 `player_page` 的 `_openStream` 保持一致：优先 `pos_<id>_<ep>` 这份
  /// 播放器进度（比历史里的整数秒准），拿不到才用历史里的秒数；
  /// 不足 [fxResumeMinSeconds] 秒时播放器从头播，预取目标也就该是第 0 片。
  static Future<double> _resumeSeconds(ResumeTarget target) async {
    final saved = await fxLoadProgress(target.videoId, target.episode);
    final raw = saved > 0 ? saved : target.seconds;
    return raw >= fxResumeMinSeconds ? raw : 0;
  }

  /// 服务端 type 字段可靠时直接用；否则看地址里有没有 .m3u8
  /// （平台线路常是 `/api/fyplay` 这类没有后缀的包装地址）。
  static bool _isHls(String url, bool declared) {
    if (declared) return true;
    return Uri.decodeFull(url).toLowerCase().contains('.m3u8');
  }

  static void _log(String message) => debugPrint('ResumePrefetch: $message');
}

/// 32 位 FNV-1a：同一个「视频id|线路|集|秒」永远得到同一个整数。
///
/// 不能用 `String.hashCode`：它每次进程启动都可能不同，做不了「会话内去重」。
int _fingerprint(String text) {
  var hash = 0x811c9dc5;
  for (var i = 0; i < text.length; i++) {
    hash ^= text.codeUnitAt(i);
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}

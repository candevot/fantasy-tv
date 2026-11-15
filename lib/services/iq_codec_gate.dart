/// 爱奇艺线路的**编码选择闸门**（IQ_CODEC 2026-11-15）。
///
/// 目标：能硬解 HEVC 的机器看 1080P HEVC，不能的才退回 896×504 H.264。
///
/// 这条闸门把三件事绑在一起，播放页只要调用 [plan] / [notice] 就够了：
///   1. **设备能力**：原生 `fantasy_tv/exo_player` 的 `supportsHevc`
///      （MediaCodecList 里找 `video/hevc` 且 `isHardwareAccelerated`），
///      首次查询后缓存 —— 每次起播都扫一遍解码器表没必要，而且
///      解码器表在一次进程生命周期里不会变。
///   2. **地址改写**：规则本体在纯函数层 `iqiyi_codec.dart`（可单独核验），
///      这里只负责「这次要不要加」，并且**只对爱奇艺线路**生效。
///   3. **失败降级**：`hevc=1` 起播失败（解码错误 / 首帧 8 秒超时）时，
///      候选列表里紧跟一条去掉 `hevc=1` 的地址 —— 播放页的候选循环本来
///      就是「一条不行试下一条」，于是降级不需要新的状态机，也不会和
///      换线路 / 救援链打架。日志固定打 `[FxPlay] iqiyi downgrade hevc->avc`。
///
/// 为什么不把 `hevc=1` 直接写进 [PlayInfo.url]（解析那一层）：解析结果
/// 有 10 分钟缓存（[FxPlayCache]），把编码写进缓存会把「这台机器的能力」
/// 和「这条地址」绑死；而 `hevc=1` 是**本次播放**的选择，必须在缓存之后。
library;

import 'exo_player.dart';
import 'iqiyi_codec.dart';
import 'play_log.dart';

/// 设备 HEVC 硬解能力 + 爱奇艺地址改写的唯一入口。
class IqCodecGate {
  IqCodecGate._();

  /// 首次探测的 Future：并发调用共用同一次查询。
  static Future<bool>? _pending;

  /// 探测结果（首次探测完成前后都安全：完成前按「不支持」处理，
  /// 也就是先要 AVC —— 宁可比别人糊一点，也不要黑屏）。
  static bool _hevc = false;
  static bool _known = false;

  /// 兜底开关：`--dart-define=FX_IQ_HEVC=0` 可以整体关掉 HEVC 请求
  /// （服务端 HEVC 码流出问题时的逃生口，不用发新包）。
  static const bool _enabled = bool.fromEnvironment(
    'FX_IQ_HEVC',
    defaultValue: true,
  );

  /// 探测到的设备能力（探测完成前是 false）。
  static bool get hevcSupported => _enabled && _hevc;

  /// 是否已经拿到确定的答案（诊断浮层用：没探测完别急着下结论）。
  static bool get known => _known;

  /// 探测一次并缓存。重复调用直接返回缓存结果，不会重复扫解码器表。
  static Future<bool> ensure() {
    if (_known) return Future<bool>.value(hevcSupported);
    final pending = _pending;
    if (pending != null) return pending;
    final future = _probe();
    _pending = future;
    return future;
  }

  static Future<bool> _probe() async {
    var supported = false;
    try {
      supported = await ExoPlayerEngine.supportsHevc();
    } catch (_) {
      // 通道没实现 / 老原生包：按不支持处理，走 AVC 一定播得出来。
      supported = false;
    }
    _hevc = supported;
    _known = true;
    fxPlayLog('iqiyi hevc supported=$supported');
    return hevcSupported;
  }

  /// HEVC 起播的观察窗口：8 秒还没出首帧就判这条码流失败。
  ///
  /// 为什么 HEVC 单独给一个更短的上限：HEVC 起播失败几乎都是「解码器初始化
  /// 失败 / 花屏后卡住」，不是在等网络 —— 拖到全站统一的 30 秒，用户就是
  /// 干看着转圈。8 秒够走完 302 + 清单 + 首片，超了就降级拿 896×504 的
  /// AVC，至少能看。
  static const Duration hevcOpenTimeout = Duration(seconds: 8);

  /// 按设备能力改写一条地址（只动爱奇艺播放地址，其它原样返回）。
  static String adapt(String url) => withHevc(url, hevc: hevcSupported);

  /// 单测用：直接设定设备能力，不经过平台通道。
  static void debugSetHevcSupported(bool value) {
    _hevc = value;
    _known = true;
    _pending = Future<bool>.value(value);
  }

  /// 单测用：清掉缓存，回到「还没探测」的状态。
  static void debugReset() {
    _pending = null;
    _hevc = false;
    _known = false;
  }

  /// 把「服务端给的候选地址」展开成「按设备能力排好的尝试序列」。
  ///
  /// 规则本体在纯函数 [planTargets]（可 `dart run` 直接核验），这里只负责
  /// 把「这台机器能不能硬解 HEVC」传进去。
  static List<IqPlayTarget> plan(List<String> candidates) =>
      planTargets(candidates, hevc: hevcSupported);

  /// 通知条文案：只在爱奇艺线路 + 拿到实测编码之后调用。
  ///
  /// [degraded] = 这次确实走了「HEVC 失败 → AVC」这条路；
  /// [mime] / [headerCodec] / [headerQuality] / [width] / [height] 全部来自
  /// 原生实测（`video/hevc` 或响应头 `X-Iq-Codec` / `X-Iq-Quality`）。
  static String notice({
    required bool degraded,
    String mime = '',
    String headerCodec = '',
    String headerQuality = '',
    int width = 0,
    int height = 0,
  }) {
    final text = iqCodecText(
      mime: mime,
      headerCodec: headerCodec,
      headerQuality: headerQuality,
      requested: degraded ? 'avc' : 'hevc',
      width: width,
      height: height,
    );
    return degraded ? '爱奇艺：HEVC 不可用，已降级 $text' : '爱奇艺：$text';
  }
}

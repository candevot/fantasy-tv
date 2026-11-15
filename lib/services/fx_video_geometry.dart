import 'package:flutter/painting.dart' show BoxFit, Size;

/// 视频真实宽高比（`宽 / 高`）；宽或高缺失、为 0 / 负数时返回 null。
///
/// ASPECT_REAL（2026-11-15）：画面比例必须来自视频自己 —— 容器写死 16:9、
/// 原生 TextureView 又是 MATCH_PARENT（它只负责把纹理铺满，**不做比例处理**，
/// 见 `ExoPlayerPlugin.kt` 的 `ExoView` 注释），两者一叠加，非 16:9 的片子
/// 就被硬拉成 16:9：
///   · 1920×800（2.4:1 电影）→ 纵向拉长
///   · 1080×1920（竖屏短剧）→ 严重压扁
///   · 640×480（4:3 老片）→ 横向拉长
///
/// 这里的数是「显示用尺寸」（原生已按 rotate 元数据换过横竖），直接算就行。
double? fxVideoAspectOf(int? width, int? height) {
  final w = width ?? 0;
  final h = height ?? 0;
  if (w <= 0 || h <= 0) return null;
  return w / h;
}

/// 视频比例拿不到时的兜底：16:9（老版本行为，保证有画面可显示）。
const double kFxFallbackVideoAspect = 16 / 9;

/// 真实比例，拿不到时退回 [kFxFallbackVideoAspect]。
///
/// 优先用「显示尺寸」，缺失时再用解码尺寸：ExoPlayer 的 `onVideoSizeChanged`
/// 会先报一次 0×0 再报真实值，切线路 / 切集时也会重报，任一层拿到都算数。
double fxVideoAspectOrFallback({int? width, int? height, int? rawWidth, int? rawHeight}) {
  return fxVideoAspectOf(width, height) ??
      fxVideoAspectOf(rawWidth, rawHeight) ??
      kFxFallbackVideoAspect;
}

/// 把 `ratio` 比例的画布等比放进 [container]：
///
/// - [BoxFit.contain]：完整放进容器（可能留黑边），不裁切、不变形；
/// - [BoxFit.cover]：等比放大到铺满容器，超出的部分由调用方裁掉；
/// - [BoxFit.fill]：直接铺满容器（会变形，只有用户主动选「拉伸」才用）。
///
/// 返回值就是**最终画面的实际尺寸**：原生 TextureView 是 MATCH_PARENT，
/// 它会被 Flutter 摆成多大，就按多大拉伸纹理 —— 所以只要这个框的比例等于
/// 视频比例，画面就不会变形。
Size fxFitSize(Size container, double ratio, BoxFit fit) {
  final cw = container.width;
  final ch = container.height;
  if (cw <= 0 || ch <= 0 || !ratio.isFinite || ratio <= 0) return container;
  if (fit == BoxFit.fill) return container;
  final byWidth = Size(cw, cw / ratio);
  final byHeight = Size(ch * ratio, ch);
  if (fit == BoxFit.cover) {
    // 铺满：取「更大的那个」，容器被完全盖住，多余部分裁掉。
    return byWidth.height >= ch ? byWidth : byHeight;
  }
  // contain（其它 BoxFit 也按等比完整显示处理）：取「更小的那个」。
  return byWidth.height <= ch ? byWidth : byHeight;
}

/// 竖屏播放区的高度：宽 [width] 的容器，装一个 [videoRatio] 比例的片子，
/// 容器该多高。
///
/// 规则（对应用户要的三类片）：
/// - 比 16:9 更宽的片子（2.4:1 电影）：容器跟着收窄到真实比例，上下不留黑边；
/// - 更方的片子（4:3 老片、竖屏短剧 9:16）：容器停在 16:9 的高度，
///   画面在里面「铺满高度、左右留黑」，而不是把容器拉成一条竖长条。
///
/// 这样既不会浪费屏幕，也不会因为竖屏短剧把整个页面顶下去 —— 详情页 /
/// 播放页下方的简介、选集都还能一眼看到。
double fxPlayerStageHeight({
  required double width,
  required double videoRatio,
}) {
  if (width <= 0) return 0;
  final baseline = width * 9 / 16; // 原来的 16:9 高度
  if (!videoRatio.isFinite || videoRatio <= 0) return baseline;
  final natural = width / videoRatio; // 按宽度铺满时的高度
  return natural < baseline ? natural : baseline;
}

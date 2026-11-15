import 'package:flutter/material.dart';

import '../services/fx_player.dart';
import '../services/iqiyi_codec.dart';

/// 播放诊断浮层。
///
/// 这一层**只是可关闭的诊断浮层，不参与任何播放逻辑** —— 它不读平台通道、
/// 不改播放器参数、不拦截手势（调用方一律用 IgnorePointer 包住），
/// 唯一作用是把原生已经算好的分段耗时摆到用户面前。
///
/// 为什么需要它：用户反馈「起播比影视壳（OK影视 / FongMi）慢」，但「慢」
/// 到底是解析地址慢、清单慢，还是首帧解码慢，只靠感觉判断不了。这里把
/// 解析 / 清单 / 首帧 / 起播总并列出来，哪一段超标就把那一行标成橙色，
/// 用户自己能看出瓶颈，反馈也就不用再猜。
///
/// 数据类 [PlaybackDiagnosticsData] 刻意与播放器实现解耦（普通字段，不用
/// record）：页面把 FxPlayerValue 映射过来即可，Widget 本身可以单独预览 /
/// 单独测试。
class PlaybackDiagnosticsData {
  const PlaybackDiagnosticsData({
    this.resolveMs = -1,
    this.manifestMs = -1,
    this.firstFrameMs = -1,
    this.totalMs = -1,
    this.connectCount = 0,
    this.bufferedAhead = Duration.zero,
    this.bitrateKbps = 0,
    this.measuredKbps = 0,
    this.droppedFrames = 0,
    this.width = 0,
    this.height = 0,
    this.videoCodec = '',
    this.iqCodec = '',
    this.iqQuality = '',
    this.codecHint = '',
  });

  /// -1 = 还没到（界面显示「--」）。
  final int resolveMs;
  final int manifestMs;
  final int firstFrameMs;
  final int totalMs;

  /// 起播至今的连接次数（OkHttp connectStart）。
  final int connectCount;
  final Duration bufferedAhead;

  /// 视频轨道声明码率；0 时退回 [measuredKbps]（实测）。
  final int bitrateKbps;

  /// OkHttp 实测吞吐。
  final int measuredKbps;
  final int droppedFrames;

  /// 显示宽高；0 表示还没拿到。
  final int width;
  final int height;

  /// 内核解出来的真实编码（`hevc` / `avc` …）；'' = 还没拿到视频轨。
  ///
  /// IQ_CODEC（2026-11-15）：爱奇艺线路分 HEVC（1920×1080）与 AVC
  /// （896×504）两条码流，客户端按设备硬解能力选。「画质对不对」这件事
  /// 只能靠这一行 + 分辨率说话，光看请求参数不够（服务端可能已经降级）。
  final String videoCodec;

  /// 服务端响应头 `X-Iq-Codec` / `X-Iq-Quality`（拿不到就是 ''）。
  final String iqCodec;
  final String iqQuality;

  /// 本次**请求**的编码（`hevc` / `avc`）；'' = 不是爱奇艺线路 / 没请求。
  final String codecHint;

  /// 编码那一行的文案（`HEVC 1920x1080` / `H.264 896x504`）。
  ///
  /// 取值顺序：内核实测 → 服务端响应头 → 本次请求参数，规则在
  /// [iqCodecText] 里（纯函数，单独可测）。
  String get codecText => iqCodecText(
        mime: videoCodec,
        headerCodec: iqCodec,
        headerQuality: iqQuality,
        requested: codecHint,
        width: width,
        height: height,
      );

  /// 从播放器状态直接映射（页面里少写一遍转字段的代码）。
  factory PlaybackDiagnosticsData.fromPlayer(FxPlayerValue value) {
    final timing = value.timing;
    // 解码宽高优先（videoParams），没拿到才退回显示尺寸。
    final rawW = value.videoWidth ?? 0;
    final rawH = value.videoHeight ?? 0;
    final shownW = value.width ?? 0;
    final shownH = value.height ?? 0;
    return PlaybackDiagnosticsData(
      resolveMs: timing.resolveMs,
      manifestMs: timing.manifestMs,
      firstFrameMs: timing.firstFrameMs,
      // 原生给 -1（首帧未到）时，用「解析 + 当前已耗时」兜底也要显示，
      // 否则用户永远看不到「现在到底等了多久」。
      totalMs: timing.totalMs >= 0 ? timing.totalMs : timing.incrementalTotalMs,
      connectCount: value.connectCount,
      bufferedAhead: value.bufferedAhead,
      bitrateKbps: value.bitrateKbps,
      measuredKbps: value.measuredKbps,
      droppedFrames: value.droppedFrames,
      width: rawW > 0 ? rawW : shownW,
      height: rawH > 0 ? rawH : shownH,
      videoCodec: value.videoCodec,
      iqCodec: value.iqCodec,
      iqQuality: value.iqQuality,
      codecHint: value.codecHint,
    );
  }
}

/// 半透明黑底小卡片：左中文标签、右对齐数值。
class PlaybackDiagnosticsPanel extends StatelessWidget {
  const PlaybackDiagnosticsPanel({
    super.key,
    required this.data,
    this.width = 210,
  });

  final PlaybackDiagnosticsData data;

  /// 卡片宽度：窄屏播放器里也别铺满画面，右上角一小块就够。
  final double width;

  /// 超过这个阈值就把数值标橙：清单 800ms、首帧 1500ms。
  static const int manifestWarnMs = 800;
  static const int firstFrameWarnMs = 1500;

  /// 瓶颈色（描边橙），正常数值白色。
  static const Color warnColor = Color(0xFFFFB300);

  @override
  Widget build(BuildContext context) {
    final rows = _rows();
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .58),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: .12)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < rows.length; i++)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 2),
              child: _row(rows[i]),
            ),
        ],
      ),
    );
  }

  List<_DiagRowData> _rows() {
    // 码率：声明值优先；拿不到才用 OkHttp 实测，并在后缀标明「实测」，
    // 免得用户把吞吐当成视频码率去对比。
    final declared = data.bitrateKbps > 0;
    final kbps = declared ? data.bitrateKbps : data.measuredKbps;
    final kbpsText =
        kbps > 0 ? (declared ? '$kbps kbps' : '$kbps kbps 实测') : '-- kbps';
    return <_DiagRowData>[
      _DiagRowData('解析', _msText(data.resolveMs), warn: false),
      _DiagRowData(
        '清单',
        _msText(data.manifestMs),
        warn: data.manifestMs > manifestWarnMs,
      ),
      _DiagRowData(
        '首帧',
        _msText(data.firstFrameMs),
        warn: data.firstFrameMs > firstFrameWarnMs,
      ),
      _DiagRowData('起播总', _msText(data.totalMs), warn: false),
      _DiagRowData('连接数', '${data.connectCount}', warn: false),
      _DiagRowData('已缓冲', _secondsText(data.bufferedAhead), warn: false),
      _DiagRowData('码率', kbpsText, warn: false),
      _DiagRowData('丢帧', '${data.droppedFrames}', warn: false),
      _DiagRowData('分辨率', _sizeText(), warn: false),
      // 编码：HEVC 硬解失败会降级成 AVC（896×504），这一行是唯一证据。
      _DiagRowData('编码', data.codecText, warn: false),
    ];
  }

  Widget _row(_DiagRowData row) {
    return Row(
      children: [
        Text(
          row.label,
          style: TextStyle(
            fontSize: 11,
            height: 1.25,
            color: Colors.white.withValues(alpha: .72),
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
        const Spacer(),
        Text(
          row.value,
          style: TextStyle(
            fontSize: 11,
            height: 1.25,
            // 等宽数字：毫秒数逐帧变化时不会左右抖，整列能对齐。
            fontWeight: FontWeight.w600,
            color: row.warn ? warnColor : Colors.white,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  /// 毫秒文案：-1（还没到）显示「--」，0 也照实显示 0ms。
  static String _msText(int ms) => ms < 0 ? '--' : '${ms}ms';

  /// 秒文案：`3.2s`，保留一位小数；负值按 0。
  static String _secondsText(Duration d) {
    final seconds = d.inMilliseconds <= 0 ? 0.0 : d.inMilliseconds / 1000;
    return '${seconds.toStringAsFixed(1)}s';
  }

  /// `1920x1080`；宽高都没拿到时显示「--」。
  String _sizeText() {
    if (data.width <= 0 || data.height <= 0) return '--';
    return '${data.width}x${data.height}';
  }
}

/// 一行诊断项（内部用，不对外暴露）。
class _DiagRowData {
  const _DiagRowData(this.label, this.value, {required this.warn});

  final String label;
  final String value;

  /// true = 这一段超标，数值标橙。
  final bool warn;
}

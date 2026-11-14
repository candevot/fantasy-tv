import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/danmu_local.dart';
import '../services/danmu_service.dart';
import 'danmu_overlay.dart';

/// 弹幕接入层 —— 播放页只放这一个 widget，内部负责：
///   1. 按「剧名 + 集号」拉弹幕（先让服务端预热，空则退避重试）
///   2. 跟随播放器位置渲染
///   3. 开关 / 透明度 / 字号从全局设置读
///
/// 四个播放场景（全屏 / 竖屏 / 一起看全屏 / 一起看小窗）共用同一份实现。
class DanmuLayer extends StatefulWidget {
  const DanmuLayer({
    super.key,
    required this.title,
    required this.ep,
    required this.epName,
    required this.position,
    this.positionListenable,
    required this.playing,
    this.enabled = true,
    this.opacity = 1,
    this.fontSize = 15,
    this.speed = 1,
    this.areaRatio = 0.7,
    this.reloadKey = 0,
    this.videoId = '',
    this.onCount,
  });

  final String title;
  final int ep;
  final String epName;

  /// 播放器当前位置。
  final Duration position;

  /// 高频位置通道（有就用，弹幕能跟得更紧）。
  final ValueListenable<Duration>? positionListenable;

  /// 是否在播放。
  final bool playing;

  final bool enabled;
  final double opacity;
  final double fontSize;

  /// 滚动速度倍率。
  final double speed;

  final double areaRatio;

  /// 自增时重新拉取（发完自己的弹幕用）。
  final int reloadKey;

  /// 用于读本地弹幕。
  final String videoId;

  /// 拉到弹幕后回调条数（给设置面板显示）。
  final ValueChanged<int>? onCount;

  @override
  State<DanmuLayer> createState() => _DanmuLayerState();
}

class _DanmuLayerState extends State<DanmuLayer> {
  List<DanmuItem> _items = const [];
  String _loadedKey = '';

  /// 每次切集/重载自增。旧的重试循环看到代数变了就自己退出，
  /// 避免用户快速切集时旧集的弹幕写进新集。
  int _gen = 0;

  /// 空列表的重试间隔（1.5s / 4s / 8s，累计 13.5 秒）。
  ///
  /// /api/danmu 对外预算只有 1.2 秒，冷搜一次却要 3~4 秒（最长见过 12 秒）：
  /// 第一次问必然空。服务端在后台继续拉、拉完直接写缓存，这三档退避正好
  /// 卡在它后面把结果取回来。三轮都空就放弃。
  static const List<Duration> _retryDelays = <Duration>[
    Duration(milliseconds: 1500),
    Duration(seconds: 4),
    Duration(seconds: 8),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant DanmuLayer old) {
    super.didUpdateWidget(old);
    if (old.title != widget.title ||
        old.ep != widget.ep ||
        old.reloadKey != widget.reloadKey) {
      _load();
    }
  }

  Future<void> _load() async {
    final key = '${widget.title}|${widget.ep}|${widget.reloadKey}';
    if (key == _loadedKey) return;
    _loadedKey = key;
    final gen = ++_gen;
    // 先让出一拍：_load 会被 didUpdateWidget 同步调用，那一帧里直接 setState
    // 会撞「build 期间 setState」。
    await Future<void>.delayed(Duration.zero);
    if (!mounted || gen != _gen) return;
    // 切集先把上一集的弹幕清掉：新集还在重试时不能继续飘旧集的弹幕。
    if (_items.isNotEmpty) setState(() => _items = const <DanmuItem>[]);

    // 自己发的弹幕（本地存储，毫秒级）；每轮都合并进去。
    final local = widget.videoId.isEmpty
        ? const <DanmuItem>[]
        : await DanmuLocal.instance.read(widget.videoId, widget.ep);
    if (!mounted || gen != _gen) return;

    for (var attempt = 0; attempt <= _retryDelays.length; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(_retryDelays[attempt - 1]);
        if (!mounted || gen != _gen) return;
      }
      // 每轮先让服务端去拉：warm 立刻返回，已缓存/正在拉时服务端不重复发起。
      unawaited(
        DanmuService.instance.warm(title: widget.title, ep: widget.ep),
      );
      final remote = await DanmuService.instance.load(
        title: widget.title,
        ep: widget.ep,
        epName: widget.epName,
      );
      if (!mounted || gen != _gen) return;
      final merged = <DanmuItem>[...(remote ?? const <DanmuItem>[]), ...local]
        ..sort((a, b) => a.time.compareTo(b.time));
      if (merged.length != _items.length) {
        setState(() => _items = merged);
        widget.onCount?.call(merged.length);
      }
      if (remote != null && remote.isNotEmpty) return;
    }
    // 三轮都空：直接不渲染，不显示「暂无弹幕」——这集可能只是上游还没拉到。
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || _items.isEmpty) return const SizedBox.shrink();
    return DanmuOverlay(
      items: _items,
      position: widget.position,
      positionListenable: widget.positionListenable,
      playing: widget.playing,
      enabled: widget.enabled,
      opacity: widget.opacity,
      fontSize: widget.fontSize,
      speed: widget.speed,
      areaRatio: widget.areaRatio,
    );
  }
}

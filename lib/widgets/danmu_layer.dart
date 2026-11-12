import 'dart:async';

import 'package:flutter/material.dart';

import '../services/danmu_local.dart';
import '../services/danmu_service.dart';
import 'danmu_overlay.dart';

/// 弹幕接入层 —— 播放页只放这一个 widget，内部负责：
///   1. 按「剧名 + 集号」拉弹幕
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
  bool _loading = false;
  String _loadedKey = '';

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
    if (key == _loadedKey || _loading) return;
    _loadedKey = key;
    _loading = true;
    final remote = await DanmuService.instance.load(
      title: widget.title,
      ep: widget.ep,
      epName: widget.epName,
    );
    // 自己发的弹幕：和远程的合并后一起渲染
    final local = widget.videoId.isEmpty
        ? const <DanmuItem>[]
        : await DanmuLocal.instance.read(widget.videoId, widget.ep);
    if (!mounted || _loadedKey != key) return;
    final merged = <DanmuItem>[...(remote ?? const <DanmuItem>[]), ...local]
      ..sort((a, b) => a.time.compareTo(b.time));
    setState(() {
      _items = merged;
      _loading = false;
    });
    widget.onCount?.call(merged.length);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || _items.isEmpty) return const SizedBox.shrink();
    return DanmuOverlay(
      items: _items,
      position: widget.position,
      playing: widget.playing,
      enabled: widget.enabled,
      opacity: widget.opacity,
      fontSize: widget.fontSize,
      speed: widget.speed,
      areaRatio: widget.areaRatio,
    );
  }
}

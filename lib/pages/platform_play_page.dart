import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../services/fx_player.dart';
import '../theme.dart';
import '../widgets/player_gestures.dart';
import '../widgets/player_theme.dart';

/// 搜索结果里「片库没有、但平台有」的条目（`tx_` 腾讯 / `iq_` 爱奇艺）播放页。
///
/// 这类条目不在片库里，详情页按 id 查库会 404，所以单独走这里：
///  1. 直接用平台 id 调 `/api/play`（服务端已按 `tx_<cid>` / `iq_<albumId>` 取流）；
///  2. 播放器复用 [FxPlayer]，与详情页一致（手势、字幕、画面比例都相同）；
///  3. 选集用 `/api/play` 返回的集数做简单翻页，不做片库那套线路切换。
///
/// 下载 / 一起看目前只对片库条目开放（它们需要完整的详情与线路信息），
/// 这里只保证「能看」。
class PlatformPlayPage extends StatefulWidget {
  const PlatformPlayPage({
    super.key,
    required this.id,
    required this.title,
    this.cover = '',
    this.episodes = 1,
    this.startEp = 1,
  });

  /// 平台条目 id：`tx_<cid>` 或 `iq_<albumId>`。
  final String id;
  final String title;
  final String cover;
  final int episodes;
  final int startEp;

  @override
  State<PlatformPlayPage> createState() => _PlatformPlayPageState();
}

class _PlatformPlayPageState extends State<PlatformPlayPage> {
  FxPlayer? _player;
  PlayInfo? _info;
  late int _ep = widget.startEp;
  bool _loading = true;
  String _error = '';
  bool _controls = true;
  Timer? _hideTimer;
  int _seq = 0;

  /// 平台条目的线路 id：腾讯走自有直连，爱奇艺走会员 dash。
  String get _line => widget.id.startsWith('iq_') ? 'pt_iqiyi' : 'pt_tencent_direct';

  @override
  void initState() {
    super.initState();
    unawaited(_open(_ep));
  }

  Future<void> _open(int ep) async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = '';
      _ep = ep;
    });
    final old = _player;
    _player = null;
    if (old != null) {
      old.removeListener(_onPlayer);
      unawaited(old.dispose());
    }
    PlayInfo info;
    try {
      info = await Api.play(widget.id, ep, _line);
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        _error = '获取播放地址失败：$e';
      });
      return;
    }
    if (!mounted || seq != _seq) return;
    if (info.url.trim().isEmpty) {
      setState(() {
        _loading = false;
        _error = '该集暂无可用地址';
      });
      return;
    }
    final player = FxPlayer.create();
    player.addListener(_onPlayer);
    try {
      await player.open(
        info.url,
        headers: info.headers,
        play: true,
        direct: info.direct && info.isHls,
        // 平台签名会过期：交给播放器在 403 / 断流时重新取地址。
        refreshPlay: () => _refreshUrl(ep, seq),
      );
    } catch (e) {
      player.removeListener(_onPlayer);
      unawaited(player.dispose());
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        _error = '播放失败：$e';
      });
      return;
    }
    if (!mounted || seq != _seq) {
      player.removeListener(_onPlayer);
      unawaited(player.dispose());
      return;
    }
    _player = player;
    setState(() {
      _info = info;
      _loading = false;
    });
    _wake();
  }

  /// 签名刷新：重新走一次 /api/play 拿新地址（平台直链有时效）。
  Future<String?> _refreshUrl(int ep, int seq) async {
    if (seq != _seq) return null;
    try {
      final fresh = await Api.play(widget.id, ep, _line, fresh: true);
      if (!mounted || seq != _seq) return null;
      return fresh.url;
    } catch (_) {
      return null;
    }
  }

  void _onPlayer() {
    if (!mounted) return;
    final player = _player;
    if (player == null) return;
    final v = player.value;
    if (v.hasError && _error.isEmpty) {
      setState(() => _error = v.errorText.trim().isEmpty ? '播放出错' : v.errorText);
    }
  }

  void _wake() {
    _hideTimer?.cancel();
    if (!mounted) return;
    if (!_controls) setState(() => _controls = true);
    _hideTimer = Timer(kPlayerControlsAutoHide, () {
      if (!mounted) return;
      setState(() => _controls = false);
    });
  }

  void _togglePlay() {
    final player = _player;
    if (player == null || _loading || _error.isNotEmpty) return;
    unawaited(player.playOrPause());
    _wake();
  }

  Future<void> _pickEpisode() async {
    final total = widget.episodes;
    if (total <= 1) return;
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _EpisodeSheet(total: total, current: _ep),
    );
    if (picked != null && picked != _ep) unawaited(_open(picked));
  }

  @override
  void dispose() {
    _seq++;
    _hideTimer?.cancel();
    final player = _player;
    _player = null;
    if (player != null) {
      player.removeListener(_onPlayer);
      unawaited(player.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ColoredBox(
                color: Colors.black,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (player != null && _error.isEmpty)
                      FxPlayerSurface(player: player),
                    if (player != null && _error.isEmpty)
                      FxPlayerGestures(
                        player: player,
                        enabled: !_loading,
                        enableVertical: false,
                        onTap: () {
                          if (_controls) {
                            _hideTimer?.cancel();
                            setState(() => _controls = false);
                          } else {
                            _wake();
                          }
                        },
                        onDoubleTap: _togglePlay,
                        onSeek: (d) => unawaited(player.seekTo(d)),
                        onGestureStart: () => _hideTimer?.cancel(),
                      ),
                    if (_loading)
                      const FxLoadingOverlay(title: '正在加载…', compact: true),
                    if (_error.isNotEmpty) _buildError(),
                    if (!_loading && _error.isEmpty)
                      IgnorePointer(
                        ignoring: !_controls,
                        child: AnimatedOpacity(
                          opacity: _controls ? 1 : 0,
                          duration: const Duration(milliseconds: 180),
                          child: _buildControls(player),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Expanded(child: _buildInfo()),
          ],
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 24),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .95),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, color: Fx.sub, size: 26),
            const SizedBox(height: 8),
            Text(
              _error,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Fx.ink, height: 1.5),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: () => unawaited(_open(_ep)),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControls(FxPlayer? player) {
    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 18),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: .55),
                  Colors.black.withValues(alpha: 0),
                ],
              ),
            ),
            child: Row(
              children: [
                PGlassIcon(
                  icon: Icons.arrow_back_ios_new_rounded,
                  size: 32,
                  iconSize: 17,
                  onTap: () => Navigator.of(context).maybePop(),
                ),
                const Spacer(),
                if (widget.episodes > 1)
                  PGlassIcon(
                    icon: Icons.list_rounded,
                    size: 31,
                    iconSize: 18,
                    tooltip: '选集',
                    onTap: () => unawaited(_pickEpisode()),
                  ),
              ],
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(10, 24, 8, 6),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0),
                  Colors.black.withValues(alpha: .62),
                ],
              ),
            ),
            child: player == null
                ? const SizedBox(height: 30)
                : AnimatedBuilder(
                    animation: player,
                    builder: (context, _) {
                      final v = player.value;
                      return Row(
                        children: [
                          PGlassIcon(
                            icon: v.isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: 30,
                            iconSize: 19,
                            onTap: _togglePlay,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: FxSeekRow(
                              position: v.position,
                              duration: v.duration,
                              buffered: v.buffered,
                              height: 3,
                              touchHeight: 34,
                              thumbSize: 15,
                              labelWidth: 40,
                              gap: 6,
                              timeFontSize: 10.5,
                              onSeek: (d) => unawaited(player.seekTo(d)),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildInfo() {
    final info = _info;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      children: [
        Text(
          widget.title,
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '第 $_ep 集${info != null && info.quality.isNotEmpty ? ' · ${info.quality}' : ''}',
          style: const TextStyle(fontSize: 12, color: Colors.white70),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .07),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              const Icon(Icons.info_outline_rounded,
                  size: 16, color: Colors.white54),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '平台线路（${widget.id.startsWith('iq_') ? '幻想爱奇艺' : '幻想独家腾讯'}）'
                  '· 该片未收录进片库，暂不支持下载与一起看',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.white54,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 选集弹层：平台条目的集数可能很多（300+），按网格铺开。
class _EpisodeSheet extends StatelessWidget {
  const _EpisodeSheet({required this.total, required this.current});

  final int total;
  final int current;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.sizeOf(context).height * .6,
      decoration: const BoxDecoration(
        color: Color(0xFF141A24),
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
                Text(
                  '选集（共 $total 集）',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close_rounded,
                      size: 20, color: Colors.white70),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 5,
                childAspectRatio: 1.7,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: total,
              itemBuilder: (_, i) {
                final ep = i + 1;
                final active = ep == current;
                return GestureDetector(
                  onTap: () => Navigator.of(context).pop(ep),
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: active
                          ? Fx.accent.withValues(alpha: .22)
                          : Colors.white.withValues(alpha: .08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: active ? Fx.accent : Colors.transparent,
                      ),
                    ),
                    child: Text(
                      '$ep',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                        color: active ? Fx.accent : Colors.white70,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

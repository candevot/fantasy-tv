import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../models.dart';
import '../services/fx_player.dart';
import '../theme.dart';
import '../widgets/detail_widgets.dart';
import '../widgets/player_gestures.dart';
import '../widgets/player_theme.dart';
import 'history_page.dart' show FxStore;
import 'fullscreen_page.dart';
import 'together_page.dart';

/// 直播频道详情页。
///
/// 复用剧集详情页的视觉组件（[DetailActionButton] / [DetailLineCard]）与
/// 播放器组件（[FxPlayerSurface] / [FxLoadingOverlay] / 播放器手势），
/// 只去掉进度、选集这些直播没有的东西；全屏交给 LiveFullscreenPage，
/// 它和剧集全屏共用同一套 fs_controls / fs_panels。
class LiveDetailPage extends StatefulWidget {
  const LiveDetailPage({
    super.key,
    required this.channel,
    this.initialLineId = '',
  });

  final LiveChannel channel;
  final String initialLineId;

  @override
  State<LiveDetailPage> createState() => _LiveDetailPageState();
}

class _LiveDetailPageState extends State<LiveDetailPage>
    with WidgetsBindingObserver {
  late LiveChannel _channel;
  String _lineId = '';
  FxPlayer? _player;
  String? _error;
  bool _loading = true;
  bool _controls = true;
  bool _fav = false;
  bool _openingTogether = false;

  /// 进一起看时播放器所有权已交给房间：期间不允许本页重新拉流，
  /// 否则房间里会多出一路同频道直播。
  bool _releasedForTogether = false;

  /// 切线路进行中：线路卡禁用，避免并发 open 出两个播放器。
  bool _switchingLine = false;

  int _openSeq = 0;
  String _lastPlayerKey = '';
  Timer? _hideTimer;

  List<LiveLine> get _lines => _channel.lines;

  LiveLine? get _line {
    for (final line in _lines) {
      if (line.id == _lineId) return line;
    }
    return _lines.isEmpty ? null : _lines.first;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _channel = widget.channel;
    _lineId = widget.initialLineId;
    _loadFav();
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _openSeq++;
    final player = _player;
    _player = null;
    if (player != null) {
      player.removeListener(_onPlayer);
      unawaited(_release(player));
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 直播回前台：画面可能已断流，重建一次拉流回到直播最新位置；
    // 切后台不主动 pause，方便用户边听边做别的事。
    if (state == AppLifecycleState.resumed && mounted && _error == null) {
      final player = _player;
      if (player != null && player.value.hasError) {
        unawaited(_reopenCurrent());
      }
    }
  }

  Future<void> _init() async {
    var channel = _channel;
    if (channel.lines.isEmpty) {
      try {
        final fresh = await Api.liveChannel(channel.id);
        if (fresh != null && fresh.lines.isNotEmpty) channel = fresh;
      } catch (_) {}
    }
    if (!mounted) return;
    if (channel.lines.isEmpty) {
      setState(() {
        _channel = channel;
        _loading = false;
        _error = '该频道暂无可用直播线路';
      });
      return;
    }
    setState(() {
      _channel = channel;
      if (!_lines.any((line) => line.id == _lineId)) {
        _lineId = _lines.first.id;
      }
    });
    await _open(_lineId);
  }

  Future<void> _loadFav() async {
    final id = _channel.id;
    if (id.isEmpty) return;
    var fav = false;
    try {
      // 收藏列表是唯一事实源：收藏页删除后这里必须立刻变回未收藏，
      // 不能再用 fav_live_ 标记抢先返回 true。读到结果后顺手修正旧标记。
      final list = await FxStore.read(FxStore.favoriteKey);
      fav = list.any((e) => '${e['id']}' == id && '${e['kind']}' == 'live');
      final sp = await SharedPreferences.getInstance();
      if ((sp.getBool('fav_live_$id') ?? false) != fav) {
        await sp.setBool('fav_live_$id', fav);
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() => _fav = fav);
  }

  Future<void> _release(FxPlayer player) async {
    try {
      await player.pause();
    } catch (_) {}
    try {
      await player.player.stop();
    } catch (_) {}
    try {
      await player.dispose();
    } catch (_) {}
  }

  /// 释放并摘掉 `_open` 本次新建的播放器。
  ///
  /// 所有提前返回（页面已退出 / 被更新的 open 取代 / open 抛异常）都必须
  /// 走这里：否则这个实例没有任何引用方，会一直出声到进程结束。
  Future<void> _dropPlayer(FxPlayer player) async {
    player.removeListener(_onPlayer);
    if (identical(_player, player)) _player = null;
    await _release(player);
  }

  Future<FxPlayer?> _open(String lineId) async {
    if (_releasedForTogether) return null;
    final line = _lineFor(lineId);
    if (line == null || line.url.trim().isEmpty) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '该线路暂不可用';
        });
      }
      return null;
    }
    final seq = ++_openSeq;
    final old = _player;
    _player = null;
    old?.removeListener(_onPlayer);
    if (mounted) {
      setState(() {
        _lineId = line.id;
        _loading = true;
        _error = null;
        _controls = true;
      });
    }
    if (old != null) await _release(old);

    // 释放旧播放器期间页面可能已经退出，或又有新的 open 抢先发起：
    // 此时绝不能再创建播放器，否则它会成为没人释放、一直在响的孤儿。
    if (!mounted || seq != _openSeq) return null;

    final player = FxPlayer.create(readyTimeout: const Duration(seconds: 20));
    try {
      player.addListener(_onPlayer);
      await player.open(line.url, play: true);
      if (!mounted || seq != _openSeq) {
        await _dropPlayer(player);
        return null;
      }
      await player.setLooping(false).catchError((_) {});
      if (!mounted || seq != _openSeq) {
        await _dropPlayer(player);
        return null;
      }
      await player.play().catchError((_) {});
      if (!mounted || seq != _openSeq) {
        await _dropPlayer(player);
        return null;
      }
      // 只有 open 成功、且仍是最新一次请求时才挂到 _player：
      // 并发时后发者不会被先发者覆盖，先发者在上面的分支里已被释放。
      _player = player;
      _lastPlayerKey = '';
      setState(() {
        _loading = false;
        _error = null;
      });
      _startHideTimer();
      return player;
    } catch (_) {
      await _dropPlayer(player);
      if (!mounted || seq != _openSeq) return null;
      setState(() {
        _loading = false;
        _error = '直播源加载失败，请重试或切换线路';
      });
      return null;
    }
  }

  LiveLine? _lineFor(String id) {
    for (final line in _lines) {
      if (line.id == id) return line;
    }
    return _lines.isEmpty ? null : _lines.first;
  }

  Future<void> _reopenCurrent() async {
    if (_releasedForTogether) return;
    final line = _line;
    if (line == null) return;
    await _open(line.id);
  }

  void _onPlayer() {
    final player = _player;
    if (!mounted || player == null) return;
    final v = player.value;
    final key =
        '${v.isInitialized}|${v.isPlaying}|${v.isBuffering}|${v.hasError}';
    if (key == _lastPlayerKey) return;
    _lastPlayerKey = key;
    if (v.hasError && _error == null) {
      setState(() {
        _loading = false;
        _error = '播放中断，请重试';
      });
      return;
    }
    if (mounted) setState(() {});
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || _loading || _error != null) return;
      if (_controls) setState(() => _controls = false);
    });
  }

  void _touch() {
    _hideTimer?.cancel();
    if (!_controls) setState(() => _controls = true);
    _startHideTimer();
  }

  void _toggleControls() {
    _hideTimer?.cancel();
    if (mounted) setState(() => _controls = !_controls);
    if (_controls) _startHideTimer();
  }

  Future<void> _togglePlay() async {
    final player = _player;
    if (player == null || _loading || _error != null) return;
    try {
      if (player.value.isPlaying) {
        await player.pause();
      } else {
        await player.play();
      }
    } catch (_) {}
    _touch();
  }

  Future<void> _switchLine(String lineId) async {
    // 并发锁：加载中连点线路会同时发起多次 open，先发起者被覆盖后
    // 容易漏释放，最坏两路直播同时出声。这里直接忽略重复请求。
    if (_switchingLine) {
      if (mounted) fxToast(context, '正在切换线路，请稍候');
      return;
    }
    if (lineId == _lineId && _error == null) return;
    _switchingLine = true;
    if (mounted) setState(() {});
    try {
      await _open(lineId);
    } finally {
      _switchingLine = false;
      if (mounted) {
        setState(() {});
        _touch();
      }
    }
  }

  Future<void> _openFullscreen() async {
    final player = _player;
    if (player == null || _loading || _error != null) return;
    _hideTimer?.cancel();
    final line = _line;
    await Navigator.of(context).push<FullPlayerResult>(
      MaterialPageRoute(
        builder: (_) => FullPlayerPage(
          player: player,
          title: _channel.title,
          line: _lineId,
          lineName: line?.qualityLabel ?? '',
          isLive: true,
        ),
      ),
    );
    if (!mounted) return;
    _touch();
  }

  Future<void> _toggleFav() async {
    final id = _channel.id;
    if (id.isEmpty) return;
    final next = !_fav;
    setState(() => _fav = next);
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool('fav_live_$id', next);
      if (next) {
        await FxStore.addFavorite(
          id: id,
          kind: 'live',
          title: _channel.title,
          cover: _channel.cover,
          status: '直播中',
          group: _channel.group,
          url: _channel.url,
          lines: [for (final line in _lines) line.toJson()],
        );
      } else {
        final list = await FxStore.read(FxStore.favoriteKey);
        list.removeWhere(
          (e) => '${e['id']}' == id && '${e['kind']}' == 'live',
        );
        await FxStore.write(FxStore.favoriteKey, list);
      }
    } catch (_) {}
    if (!mounted) return;
    fxToast(context, next ? '已收藏到我的收藏' : '已取消收藏');
  }

  Future<void> _share() async {
    final line = _line;
    final name = _channel.title.trim().isEmpty ? '电视直播' : _channel.title;
    final group = _channel.group.trim();
    final text = StringBuffer()
      ..writeln('【直播】$name${group.isEmpty ? '' : ' · $group'}')
      ..writeln('我在幻想影视看直播，一起来看：');
    if (line != null) text.writeln(line.url);
    final body = text.toString().trim();
    try {
      final box = context.findRenderObject();
      await Share.share(
        body,
        subject: name,
        sharePositionOrigin:
            box is RenderBox ? box.localToGlobal(Offset.zero) & box.size : null,
      );
    } catch (_) {
      // 系统分享不可用时退回复制，保证地址能发出去。
      await Clipboard.setData(ClipboardData(text: body));
      if (!mounted) return;
      fxToast(context, '已复制直播地址，可粘贴分享');
    }
  }

  void _cast() => fxToast(context, '投屏：暂无可用设备');

  Future<void> _together() async {
    if (_openingTogether) return;
    final player = _player;
    if (player == null || _loading || _error != null) {
      fxToast(context, '直播还没准备好');
      return;
    }
    _openingTogether = true;
    _releasedForTogether = true;
    _hideTimer?.cancel();
    try {
      // 房间里只能有一个播放器：进房前彻底释放本页播放器（不能只 pause，
      // 否则同一路直播会同时开两台解码器、两条流，一旦 pause 失败就是双声）。
      await _dropPlayer(player);
      if (!mounted) return;
      final result = await Navigator.of(context).push<TogetherExitResult>(
        MaterialPageRoute(
          builder: (_) => TogetherPage.live(
            liveChannel: _channel,
            liveLineId: _lineId,
          ),
        ),
      );
      if (!mounted) return;
      // 房间内可能换了线路：回来自动重建，回到直播边缘。
      if (result != null &&
          result.videoId == _channel.id &&
          result.lineId.trim().isNotEmpty) {
        _lineId = result.lineId.trim();
      }
    } finally {
      _releasedForTogether = false;
      _openingTogether = false;
      if (mounted) {
        await _reopenCurrent();
        if (mounted) _touch();
      }
    }
  }

  Future<void> _back() async {
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F8FC),
      body: FxBackground(
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              _buildTopBar(),
              Expanded(
                child: ListView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.only(bottom: 30),
                  children: [
                    _buildPlayer(),
                    _buildActions(),
                    _buildLines(),
                    _buildHint(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    final title =
        _channel.title.trim().isEmpty ? '电视直播' : _channel.title.trim();
    final group = _channel.group.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Row(
        children: [
          _circle(
            Icons.arrow_back_ios_new_rounded,
            onTap: () => unawaited(_back()),
            size: 36,
            iconSize: 16,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: Fx.ink,
                        ),
                      ),
                    ),
                    const SizedBox(width: 7),
                    const _LiveBadge(),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  group.isEmpty ? '直播中 · 无回看' : '$group · 直播中',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Fx.sub),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _circle(
            Icons.refresh_rounded,
            onTap: () => unawaited(_reopenCurrent()),
            size: 36,
            iconSize: 18,
          ),
        ],
      ),
    );
  }

  Widget _buildPlayer() {
    final player = _player;
    final ready = player != null && player.value.isInitialized;
    return Column(
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(0),
            child: ColoredBox(
              color: Colors.black,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (player != null && ready)
                    FxPlayerSurface(
                      key: ObjectKey(player),
                      player: player,
                      fit: BoxFit.contain,
                      subtitleBottom: 70,
                    ),
                  if (player != null)
                    Positioned.fill(
                      child: FxPlayerGestures(
                        player: player,
                        enabled: _error == null,
                        enableVertical: false,
                        enableSeek: false,
                        onTap: _toggleControls,
                        onDoubleTap: () => unawaited(_togglePlay()),
                        onSeek: (_) {},
                        onGestureStart: () => _hideTimer?.cancel(),
                      ),
                    ),
                  if (_loading)
                    const Positioned.fill(
                      child: FxLoadingOverlay(
                        title: '正在加载直播…',
                        dim: false,
                        compact: true,
                      ),
                    ),
                  if (_error != null) _buildError(),
                  if (_error == null)
                    Positioned.fill(
                      child: IgnorePointer(
                        ignoring: !_controls,
                        child: AnimatedOpacity(
                          opacity: _controls ? 1 : 0,
                          duration: const Duration(milliseconds: 180),
                          child: _buildPlayerControls(),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPlayerControls() {
    final playing = _player?.value.isPlaying ?? false;
    final line = _line;
    return Stack(
      fit: StackFit.expand,
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
                  Colors.black.withOpacity(.52),
                  Colors.black.withOpacity(0),
                ],
              ),
            ),
            child: Row(
              children: [
                PGlassIcon(
                  icon: Icons.arrow_back_ios_new_rounded,
                  size: 32,
                  iconSize: 17,
                  onTap: () => unawaited(_back()),
                ),
                const Spacer(),
                PGlassIcon(
                  icon: Icons.tv_rounded,
                  size: 31,
                  iconSize: 18,
                  tooltip: '投屏',
                  onTap: _cast,
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
                  Colors.black.withOpacity(0),
                  Colors.black.withOpacity(.62),
                ],
              ),
            ),
            child: Row(
              children: [
                PGlassIcon(
                  icon:
                      playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: 30,
                  iconSize: 19,
                  tint: .13,
                  tooltip: playing ? '暂停' : '播放',
                  onTap: () => unawaited(_togglePlay()),
                ),
                const SizedBox(width: 8),
                const _LiveBadge(),
                if (line != null) ...[
                  const SizedBox(width: 7),
                  Text(
                    line.qualityLabel,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Colors.white70,
                    ),
                  ),
                ],
                const Spacer(),
                PGlassIcon(
                  icon: Icons.fullscreen_rounded,
                  size: 30,
                  iconSize: 20,
                  tint: .13,
                  tooltip: '全屏',
                  onTap: () => unawaited(_openFullscreen()),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildActions() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 14, 6, 0),
      child: Row(
        children: [
          Expanded(
            child: DetailActionButton(
              icon: _fav ? Icons.star_rounded : Icons.star_border_rounded,
              label: _fav ? '已收藏' : '收藏',
              color: Fx.gold,
              active: _fav,
              onTap: () => unawaited(_toggleFav()),
            ),
          ),
          Expanded(
            child: DetailActionButton(
              icon: Icons.share_rounded,
              label: '分享',
              color: const Color(0xFF39B7B0),
              onTap: () => unawaited(_share()),
            ),
          ),
          Expanded(
            child: DetailActionButton(
              icon: Icons.tv_rounded,
              label: '投屏',
              color: const Color(0xFF5B8DEF),
              onTap: _cast,
            ),
          ),
          Expanded(
            child: DetailActionButton(
              icon: Icons.live_tv_rounded,
              label: '一起看',
              color: const Color(0xFFF08A5D),
              onTap: () => unawaited(_together()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLines() {
    if (_lines.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DetailSectionTitle(
            title: '线路',
            trailing: Text(
              '按清晰度排序 · ${_lines.length} 条',
              style: const TextStyle(fontSize: 10.5, color: Fx.sub),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 64,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: _lines.length,
              separatorBuilder: (_, __) => const SizedBox(width: 9),
              itemBuilder: (context, i) {
                final line = _lines[i];
                return DetailLineCard(
                  name: line.qualityLabel,
                  count: 0,
                  subtitle: line.subtitle(i),
                  width: 94,
                  active: line.id == _lineId,
                  onTap: _switchingLine
                      ? null
                      : () => unawaited(_switchLine(line.id)),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHint() {
    final line = _line;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.66),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white),
        ),
        child: Row(
          children: [
            Icon(Icons.wifi_tethering_rounded,
                size: 16, color: Color(0xFF39B7B0).withOpacity(.9)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                line == null
                    ? '直播流会持续更新，暂时无法回看。'
                    : '${line.name.isEmpty ? line.qualityLabel : line.name} · '
                        '直播流持续更新，没有进度条与回看。',
                style: const TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: Fx.sub,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(.42),
        alignment: Alignment.center,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 24),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.95),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off_rounded, color: Fx.sub, size: 26),
              const SizedBox(height: 6),
              Text(
                _error ?? '直播源加载失败',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: Fx.ink,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _errorAction('重试', () => unawaited(_reopenCurrent())),
                  if (_lines.length > 1) ...[
                    const SizedBox(width: 10),
                    _errorAction('换线路', () {
                      final index = _lines.indexWhere((l) => l.id == _lineId);
                      final next = _lines[(index + 1) % _lines.length];
                      unawaited(_switchLine(next.id));
                    }),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _errorAction(String text, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          gradient: Fx.brand,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _circle(
    IconData icon, {
    required VoidCallback onTap,
    double size = 36,
    double iconSize = 17,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.78),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF50729F).withOpacity(.10),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Icon(icon, size: iconSize, color: Fx.ink),
      ),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFFF4D4F).withOpacity(.13),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFFF6B6B).withOpacity(.45)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 6, color: Color(0xFFFF5A5A)),
          SizedBox(width: 4),
          Text(
            'LIVE',
            style: TextStyle(
              fontSize: 9,
              height: 1.1,
              fontWeight: FontWeight.w800,
              letterSpacing: .5,
              color: Color(0xFFFF5A5A),
            ),
          ),
        ],
      ),
    );
  }
}

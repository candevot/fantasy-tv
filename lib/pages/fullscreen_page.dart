import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../models.dart';
import '../services/fx_player.dart';
import '../theme.dart';
import '../widgets/fs_controls.dart';
import '../widgets/fs_panels.dart';
import '../widgets/player_theme.dart';

/// 全屏播放退出时带回给竖屏播放器的结果。
///
/// 退出时播放器实例由竖屏继续复用，这里只同步集数 / 进度 / 播放状态。
class FullPlayerResult {
  const FullPlayerResult({
    required this.ep,
    required this.position,
    required this.playing,
    this.info,
    this.rate = 1.0,
    this.qualityKey,
  });

  /// 退出时的集数
  final int ep;

  /// 退出时的播放进度（秒）
  final double position;

  /// 退出时是否处于播放中
  final bool playing;

  /// 退出时对应的播放信息（全屏内切集后用于同步竖屏）
  final PlayInfo? info;

  /// 退出时的播放倍速，交回竖屏继续使用
  final double rate;

  /// 退出时选择的清晰度 key；null = 自动
  final String? qualityKey;
}

/// 全屏画面适配档位。
enum FsVideoFit {
  contain('默认'),
  cover('裁剪'),
  stretch('拉伸');

  const FsVideoFit(this.label);
  final String label;
}

/// 全屏横屏播放页
///
/// 直接复用竖屏传入的 [FxPlayer]（同一个 Player / VideoController）：
/// 进入和退出全屏都不重新创建、不重新 open，进度与暂停状态自然保持。
/// 进入即横屏 + 沉浸式，退出恢复竖屏；控件 3 秒自动隐藏，点击画面切换显隐；
/// 锁屏后只剩解锁按钮，其它手势全部失效。
class FullPlayerPage extends StatefulWidget {
  const FullPlayerPage({
    super.key,
    required this.player,
    this.videoId = '',
    this.ep = 1,
    this.line = '',
    this.title = '',
    this.playInfo,
    this.episodes = const <Episode>[],
    this.lineName = '',
    this.rate = 1.0,
    this.qualityKey,
  });

  /// 竖屏播放页正在使用的播放器实例（全屏直接复用）
  final FxPlayer player;

  final String videoId;
  final int ep;
  final String line;
  final String title;

  /// 竖屏已经拿到的播放信息，可直接复用，省一次请求
  final PlayInfo? playInfo;

  /// 剧集列表（详情页带入）
  final List<Episode> episodes;

  /// 线路名（仅用于设置面板展示）
  final String lineName;

  /// 竖屏进入全屏时的真实倍速（来自 player.state.rate）
  final double rate;

  /// 竖屏上次在全屏选择的清晰度，重进时保持选中
  final String? qualityKey;

  @override
  State<FullPlayerPage> createState() => _FullPlayerPageState();
}

class _FullPlayerPageState extends State<FullPlayerPage>
    with WidgetsBindingObserver {
  static const List<DeviceOrientation> _landscape = <DeviceOrientation>[
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  /// 与 main.dart 里保持一致，退出全屏后恢复
  static const SystemUiOverlayStyle _appOverlay = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.dark,
    systemStatusBarContrastEnforced: false,
    systemNavigationBarContrastEnforced: false,
  );

  FxPlayer? _controller;
  PlayInfo? _info;

  late int _ep;
  late String _line;
  late String _title;
  late List<Episode> _episodes;

  int _loadToken = 0;

  /// controller 实际已经打开的集；进度只写这一集，loading 时不写。
  int? _loadedEp;

  bool _loading = false;
  bool _error = false;
  String _errorText = '';
  bool _sourceFailNotified = false;
  bool _ended = false;

  // 控件显隐 / 锁屏
  bool _controls = true;
  Timer? _hideTimer;
  bool _locked = false;
  bool _rotationLocked = false;

  // 弹层
  bool _showSpeed = false;
  bool _showEpisodes = false;
  bool _showJump = false;
  bool _showQuality = false;

  /// 当前清晰度；null = 自动（使用 PlayInfo.url + backup）
  String? _qualityKey;

  /// 画面适配：默认保持真实比例，裁剪铺满，拉伸铺满。
  FsVideoFit _videoFit = FsVideoFit.contain;

  // 播放倍速
  double _rate = 1.0;
  double _rateBeforeHold = 1.0;
  bool _holding2x = false;

  // 进度提示
  String? _seekHint;
  Timer? _seekHintTimer;

  bool _exiting = false;

  bool get _panelOpen =>
      _showSpeed || _showEpisodes || _showJump || _showQuality;

  bool get _playing => _controller?.value.isPlaying ?? false;

  List<QualityItem> get _qualityList => _info?.quality ?? const <QualityItem>[];

  /// 底部清晰度按钮文案：只展示接口真实返回的码率；无多码率时就是原画。
  String get _qualityLabel {
    final list = _qualityList;
    if (list.isEmpty) return '原画';
    final key = _qualityKey;
    if (key == null) return '自动';
    for (final q in list) {
      if (q.key == key) return _qualityName(q);
    }
    return '自动';
  }

  /// 直接使用 PlayInfo.quality 里的真实名称，不再把 key 猜成 4K / 1080P。
  String _qualityName(QualityItem q) {
    final name = q.name.trim();
    return name.isEmpty ? q.key : name;
  }

  /// 当前视频的真实分辨率，如 1280x720；未就绪时返回空串。
  String get _resolutionText {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return '';
    // media_kit 的 videoParams 提供解码后的真实宽高（如 3840x2160）。
    return c.value.resolutionText;
  }

  String get _epLabel {
    for (final e in _episodes) {
      if (e.n == _ep && e.name.isNotEmpty) return e.name;
    }
    return fxEpisodeLabel(_ep);
  }

  @override
  void initState() {
    super.initState();
    _ep = widget.ep;
    _line = widget.line;
    _title = widget.title.trim().isEmpty ? '正在播放' : widget.title.trim();
    _episodes = List<Episode>.from(widget.episodes);

    // 复用竖屏的播放器实例：不新建 player，也不重新 open。
    final c = widget.player;
    _controller = c;
    _info = widget.playInfo;
    _qualityKey = widget.qualityKey;
    _rate = widget.rate > 0 ? widget.rate : (c.rate > 0 ? c.rate : 1.0);
    _loadedEp = c.value.isInitialized ? _ep : null;
    _loading = !c.value.isInitialized;
    c.addListener(_onVideoValue);
    if (c.value.isInitialized && (c.rate - _rate).abs() > .01) {
      unawaited(_applyRate(_rate));
    }

    WidgetsBinding.instance.addObserver(this);
    unawaited(_enterImmersive());
    _startHideTimer();
    if (widget.videoId.isNotEmpty && _episodes.isEmpty) {
      unawaited(_loadEpisodeMeta());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _seekHintTimer?.cancel();
    _loadToken++;
    unawaited(_saveProgress());
    // 播放器实例属于竖屏页面，退出全屏只移除监听，不能 dispose。
    _controller?.removeListener(_onVideoValue);
    unawaited(_restoreSystemUi());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      unawaited(_saveProgress());
      final c = _controller;
      if (c != null) unawaited(c.pause());
    }
  }

  /* ------------------------------------------------------------------ 系统 */

  Future<void> _enterImmersive() async {
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations(_landscape);
      SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
    } catch (_) {
      // 桌面 / 模拟器上不支持也无所谓
    }
  }

  Future<void> _restoreSystemUi() async {
    try {
      await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
        DeviceOrientation.portraitUp,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setSystemUIOverlayStyle(_appOverlay);
    } catch (_) {}
  }

  /* ---------------------------------------------------------------- 数据 */

  Future<void> _loadEpisodeMeta() async {
    try {
      final detail = await Api.detail(widget.videoId);
      if (!mounted) return;
      setState(() {
        _episodes = detail.allEpisodes;
        if (widget.title.trim().isEmpty && detail.title.isNotEmpty) {
          _title = detail.title;
        }
      });
    } catch (_) {
      // 拿不到剧集也不影响播放
    }
  }

  /// 重新加载当前集（重试 / 全屏内切集）：复用竖屏传入的同一个
  /// [FxPlayer] 实例换播放地址，不新建播放器、不重建视频输出。
  Future<void> _bootstrap({
    required bool seekToSaved,
    bool saveOld = true,
  }) async {
    final c = _controller;
    if (c == null) return;
    final token = ++_loadToken;
    _hideTimer?.cancel();
    if (saveOld) await _saveProgress();
    if (!mounted || token != _loadToken) return;
    unawaited(c.pause());
    setState(() {
      _loading = true;
      _loadedEp = null;
      _error = false;
      _errorText = '';
      _ended = false;
      _sourceFailNotified = false;
      _qualityKey = null;
    });

    PlayInfo source;
    try {
      source = await Api.play(widget.videoId, _ep, _line);
    } catch (_) {
      if (!mounted || token != _loadToken) return;
      setState(() {
        _loading = false;
        _error = true;
        _errorText = '获取播放地址失败，请检查网络后重试';
      });
      _notifySourceFailed();
      return;
    }
    if (!mounted || token != _loadToken) return;
    _info = source;

    final all = <String>[
      if (source.url.trim().isNotEmpty) source.url.trim(),
      for (final u in source.backup)
        if (u.trim().isNotEmpty) u.trim(),
    ];
    final candidates = <String>[];
    for (final u in all) {
      if (!candidates.contains(u)) candidates.add(u);
    }
    if (candidates.isEmpty) {
      setState(() {
        _loading = false;
        _error = true;
        _errorText = '当前线路没有可用播放地址，请更换线路';
      });
      _notifySourceFailed();
      return;
    }

    var resume = 0.0;
    if (seekToSaved) {
      resume = await fxLoadProgress(widget.videoId, _ep);
    }
    if (!mounted || token != _loadToken) return;

    var ok = false;
    for (final url in candidates) {
      if (!mounted || token != _loadToken) return;
      try {
        await c.open(url, headers: source.headers);
        if (!mounted || token != _loadToken) return;
        final durationMs = c.value.duration.inMilliseconds;
        var start = resume;
        if (durationMs > 0 && start >= durationMs / 1000.0 - 2) start = 0;
        if (start > 0) {
          await c.seekTo(Duration(milliseconds: (start * 1000).round()));
        }
        await c.setLooping(false);
        try {
          await c.setRate(_rate);
        } catch (_) {}
        if (!mounted || token != _loadToken) return;
        await c.play();
        if (!mounted || token != _loadToken) return;
        _loadedEp = _ep;
        setState(() {
          _loading = false;
          _error = false;
          _errorText = '';
        });
        _sourceFailNotified = false;
        ok = true;
        _wake();
        break;
      } catch (_) {
        // 换下一条备用地址继续尝试
      }
    }

    if (!ok) {
      if (!mounted || token != _loadToken) return;
      setState(() {
        _loading = false;
        _error = true;
        _errorText = '播放失败：线路不可用，请重试或切换线路';
      });
      _notifySourceFailed();
    }
  }

  void _notifySourceFailed() {
    if (_sourceFailNotified) return;
    _sourceFailNotified = true;
    if (!mounted) return;
    fxToast(context, '当前线路播放失败，可返回竖屏切换线路');
  }

  /// 用同一播放器实例打开一个地址，并恢复进度 / 倍速 / 播放状态。
  /// open 或 play 抛出的异常都在这里兜住，返回是否成功。
  Future<bool> _openSource(
    String url, {
    required Map<String, String> headers,
    required Duration resume,
    required bool wasPlaying,
  }) async {
    final c = _controller;
    if (c == null) return false;
    try {
      await c.open(url, headers: headers);
      if (!mounted) return false;
      final duration = c.value.duration;
      var target = resume;
      if (duration > Duration.zero &&
          target >= duration - const Duration(milliseconds: 1500)) {
        target = Duration.zero;
      }
      if (target > Duration.zero) await c.seekTo(target);
      await c.setLooping(false);
      try {
        await c.setRate(_rate);
      } catch (_) {}
      if (wasPlaying) await c.play();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 切换清晰度：真正换 networkUrl，并恢复切换前的进度 / 倍速 / 播放状态。
  /// 新清晰度失败时回退打开原来的播放地址；连回退也失败才进入错误态。
  Future<void> _selectQuality(String? key) async {
    if (_loading) {
      fxToast(context, '正在加载，请稍候');
      return;
    }
    final info = _info;
    final list = _qualityList;
    if (info == null || list.isEmpty) {
      fxToast(context, '当前线路仅提供原画');
      return;
    }
    if (key == _qualityKey) {
      _closePanels();
      _wake();
      return;
    }

    QualityItem? picked;
    if (key != null) {
      for (final q in list) {
        if (q.key == key) {
          picked = q;
          break;
        }
      }
      if (picked == null) {
        fxToast(context, '该清晰度暂不可用');
        return;
      }
    }

    final urls = <String>[];
    if (picked == null) {
      for (final u in <String>[info.url, ...info.backup]) {
        final url = u.trim();
        if (url.isNotEmpty && !urls.contains(url)) urls.add(url);
      }
    } else {
      final url = picked.url.trim();
      if (url.isNotEmpty) urls.add(url);
    }
    if (urls.isEmpty) {
      fxToast(context, '当前清晰度没有可用的播放地址');
      return;
    }

    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      fxToast(context, '播放器尚未就绪，请稍后再试');
      return;
    }
    final oldQuality = _qualityKey;
    String? oldUrl;
    if (oldQuality != null) {
      for (final q in list) {
        if (q.key == oldQuality && q.url.trim().isNotEmpty) {
          oldUrl = q.url.trim();
          break;
        }
      }
    }
    final wasPlaying = c.value.isPlaying;
    final resume = c.value.position;

    _hideTimer?.cancel();
    setState(() {
      _showQuality = false;
      _showSpeed = false;
      _showEpisodes = false;
      _showJump = false;
      _loading = true;
      _error = false;
      _errorText = '';
      _ended = false;
      _controls = true;
    });

    final token = ++_loadToken;
    var ok = false;
    for (final url in urls) {
      if (!mounted || token != _loadToken) return;
      // 复用同一个播放器实例，只换地址，切清晰度后仍可交回竖屏继续用。
      if (await _openSource(
        url,
        headers: info.headers,
        resume: resume,
        wasPlaying: wasPlaying,
      )) {
        ok = true;
        break;
      }
    }

    if (!mounted || token != _loadToken) return;
    if (!ok) {
      // open 已经打断了原片源：必须把原来的地址重新打开并 seek 回原进度，
      // 否则就是黑屏且不报错。回退也失败才置错误态，让用户点重试。
      final fallback = <String>[];
      if (oldUrl != null) fallback.add(oldUrl);
      for (final u in <String>[info.url, ...info.backup]) {
        final url = u.trim();
        if (url.isNotEmpty && !fallback.contains(url)) fallback.add(url);
      }
      var restored = false;
      var restoredKey = oldUrl == null ? null : oldQuality;
      for (final url in fallback) {
        if (!mounted || token != _loadToken) return;
        if (await _openSource(
          url,
          headers: info.headers,
          resume: resume,
          wasPlaying: wasPlaying,
        )) {
          restored = true;
          if (oldUrl == null || url != oldUrl) restoredKey = null;
          break;
        }
      }
      if (!mounted || token != _loadToken) return;
      setState(() {
        _loading = false;
        _qualityKey = restored ? restoredKey : oldQuality;
        _controls = true;
        if (!restored) {
          _error = true;
          _errorText = '切换清晰度失败，播放器需要重试';
        }
      });
      _wake();
      fxToast(context, restored ? '切换清晰度失败，已恢复原清晰度' : '切换清晰度失败，请重试');
      return;
    }

    setState(() {
      _qualityKey = key;
      _loading = false;
      _error = false;
      _errorText = '';
      _sourceFailNotified = false;
      _controls = true;
    });
    _wake();
    _showSeekHint('清晰度：$_qualityLabel');
  }

  Future<double> _saveProgress({bool ended = false}) async {
    if (_loading || _error) return 0;
    final c = _controller;
    final ep = _loadedEp;
    if (c == null || ep == null || !c.value.isInitialized) return 0;
    final v = c.value;
    var seconds = ended ? 0.0 : v.position.inMilliseconds / 1000.0;
    if (!ended &&
        v.duration.inMilliseconds > 0 &&
        v.position.inMilliseconds >= v.duration.inMilliseconds - 1500) {
      seconds = 0;
    }
    await fxSaveProgress(widget.videoId, ep, seconds);
    return seconds;
  }

  void _onVideoValue() {
    final c = _controller;
    if (c == null || !mounted) return;
    // loading 期间的错误交给 _bootstrap / _openSource 的 try/catch 处理。
    if (_loading || _error) return;
    final v = c.value;
    if (v.hasError) {
      setState(() {
        _loading = false;
        _error = true;
        _errorText = '播放中断，请重试或切换线路';
      });
      _notifySourceFailed();
      return;
    }
    if (!v.isInitialized) return;
    if (!v.isCompleted) {
      _ended = false;
      return;
    }
    if (_ended) return;
    _ended = true;
    unawaited(_handleEnded());
  }

  Future<void> _handleEnded() async {
    await _saveProgress(ended: true);
    if (!mounted) return;
    final next = _nextEpNumber();
    if (next != null) {
      await _switchEp(next, auto: true);
    } else {
      _wake();
      fxToast(context, '已播放完最后一集');
    }
  }

  int? _nextEpNumber() {
    // 剧集列表为空时按单片处理，播完就停；不再无限跳第 02 集。
    if (_episodes.isEmpty) return null;
    final index = _episodes.indexWhere((e) => e.n == _ep);
    if (index < 0) return null;
    if (index + 1 >= _episodes.length) return null;
    return _episodes[index + 1].n;
  }

  Future<void> _switchEp(int next, {bool auto = false}) async {
    if (_loading) return;
    if (next == _ep) {
      _closePanels();
      return;
    }
    await _saveProgress();
    if (!mounted) return;
    setState(() {
      _ep = next;
      _episodes = List<Episode>.from(_episodes);
      _showEpisodes = false;
      _showQuality = false;
      _controls = true;
      _loading = true;
      _loadedEp = null;
      _error = false;
    });
    if (auto) fxToast(context, '即将播放 ${fxEpisodeLabel(next)}');
    await _bootstrap(seekToSaved: true, saveOld: false);
    if (!mounted) return;
    _wake();
  }

  Future<void> _next() async {
    final next = _nextEpNumber();
    if (next == null) {
      fxToast(context, '已经是最后一集了');
      _wake();
      return;
    }
    await _switchEp(next);
  }

  /* ---------------------------------------------------------------- 控件 */

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (_locked || _panelOpen || _holding2x || _loading || _error) {
        if (_holding2x) _startHideTimer();
        return;
      }
      setState(() => _controls = false);
    });
  }

  void _wake() {
    if (!mounted || _locked) return;
    if (!_controls) {
      setState(() => _controls = true);
    }
    _startHideTimer();
  }

  void _hideControls() {
    _hideTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _controls = false;
      _showSpeed = false;
      _showEpisodes = false;
      _showJump = false;
      _showQuality = false;
    });
  }

  void _onSurfaceTap() {
    if (_locked) return;
    if (_panelOpen) {
      _closePanels();
      return;
    }
    if (_loading || _error) {
      _wake();
      return;
    }
    if (_controls) {
      _hideControls();
    } else {
      _wake();
    }
  }

  void _closePanels() {
    if (!_panelOpen) return;
    setState(() {
      _showSpeed = false;
      _showEpisodes = false;
      _showJump = false;
      _showQuality = false;
    });
    _wake();
  }

  void _lock() {
    setState(() {
      _locked = true;
      _controls = false;
      _showSpeed = false;
      _showEpisodes = false;
      _showJump = false;
      _showQuality = false;
    });
    _hideTimer?.cancel();
    fxToast(context, '已锁定，点击左侧锁图标解锁');
  }

  void _unlock() {
    if (!mounted) return;
    setState(() => _locked = false);
    _wake();
  }

  void _toggleRotation() {
    setState(() => _rotationLocked = !_rotationLocked);
    // Flutter 无法读取当前横屏的左右朝向，这里保留状态位（接入平台插件后可真正锁定）
    fxToast(
      context,
      _rotationLocked ? '已锁定横屏方向，旋转手机不再翻转画面' : '已解除旋转锁定',
    );
    _wake();
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null || _loading || _error || !c.value.isInitialized) return;
    // 直接让 media_kit 切换，图标由 player.stream.playing 驱动，避免本地态覆盖。
    unawaited(c.playOrPause());
    _wake();
  }

  void _seekTo(Duration d) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    unawaited(c.seekTo(d));
    _wake();
  }

  void _seekBy(int seconds) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final total = c.value.duration;
    var target = c.value.position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (target > total) target = total;
    unawaited(c.seekTo(target));
    _showSeekHint(seconds > 0 ? '快进 ${seconds}s' : '后退 ${-seconds}s');
    _wake();
  }

  void _showSeekHint(String text) {
    _seekHintTimer?.cancel();
    if (!mounted) return;
    setState(() => _seekHint = text);
    _seekHintTimer = Timer(const Duration(milliseconds: 720), () {
      if (!mounted) return;
      setState(() => _seekHint = null);
    });
  }

  Future<void> _applyRate(double rate) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    try {
      await c.setRate(rate);
    } catch (_) {}
  }

  void _setRate(double rate) {
    if (!mounted) return;
    setState(() => _rate = rate);
    unawaited(_applyRate(rate));
    _showSeekHint('${fxRateLabel(rate)} 播放');
  }

  void _startHold2x() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (_rate >= 2.0) return;
    _rateBeforeHold = _rate;
    unawaited(_applyRate(2.0));
    setState(() => _holding2x = true);
    _wake();
  }

  void _endHold2x() {
    if (!_holding2x) return;
    unawaited(_applyRate(_rateBeforeHold));
    if (!mounted) return;
    setState(() => _holding2x = false);
    _wake();
  }

  void _toggleSpeed() {
    _hideTimer?.cancel();
    setState(() {
      _showSpeed = !_showSpeed;
      _showJump = false;
      _showEpisodes = false;
      _showQuality = false;
      _controls = true;
    });
    if (!_showSpeed) _wake();
  }

  void _toggleJump() {
    _hideTimer?.cancel();
    setState(() {
      _showJump = !_showJump;
      _showSpeed = false;
      _showEpisodes = false;
      _showQuality = false;
      _controls = true;
    });
    if (!_showJump) _wake();
  }

  void _toggleEpisodes() {
    _hideTimer?.cancel();
    if (!_showEpisodes && _episodes.isEmpty) {
      fxToast(context, '暂无剧集信息');
      _wake();
      return;
    }
    setState(() {
      _showEpisodes = !_showEpisodes;
      _showSpeed = false;
      _showJump = false;
      _showQuality = false;
      _controls = true;
    });
    if (!_showEpisodes) _wake();
  }

  void _toggleQuality() {
    if (_loading) {
      fxToast(context, '正在加载，请稍候');
      return;
    }
    _hideTimer?.cancel();
    if (_qualityList.isEmpty) {
      fxToast(context, '当前线路仅提供原画');
      _wake();
      return;
    }
    setState(() {
      _showQuality = !_showQuality;
      _showSpeed = false;
      _showJump = false;
      _showEpisodes = false;
      _controls = true;
    });
    if (!_showQuality) _wake();
  }

  void _jumpIntro() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    const target = Duration(seconds: 90);
    final total = c.value.duration;
    unawaited(c.seekTo(target > total ? Duration.zero : target));
    _showSeekHint('已跳过片头');
    _wake();
  }

  void _jumpOutro() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final total = c.value.duration;
    final target = total - const Duration(seconds: 90);
    unawaited(c.seekTo(target < Duration.zero ? Duration.zero : target));
    _showSeekHint('已跳到片尾');
    _wake();
  }

  Future<void> _openPlayerSettings() async {
    _hideTimer?.cancel();
    _closePanels();
    if (mounted) setState(() => _controls = true);

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final quality = _info?.quality ?? const <QualityItem>[];
            final lineName = _info?.lineName ?? widget.lineName;
            final maxHeight = MediaQuery.of(context).size.height * .88;
            return Container(
              constraints: BoxConstraints(maxHeight: maxHeight),
              padding: EdgeInsets.fromLTRB(
                20,
                14,
                20,
                16 + MediaQuery.of(context).padding.bottom,
              ),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.settings_rounded,
                            size: 19, color: Fx.accent),
                        const SizedBox(width: 7),
                        const Text('播放设置',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: Fx.ink)),
                        const Spacer(),
                        IconButton(
                          onPressed: () => Navigator.of(sheetContext).pop(),
                          icon: const Icon(Icons.close_rounded,
                              color: Fx.sub, size: 22),
                        ),
                      ],
                    ),
                    if (lineName.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text('当前线路：$lineName',
                            style:
                                const TextStyle(fontSize: 11.5, color: Fx.sub)),
                      ),
                    if (_resolutionText.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text('当前分辨率：$_resolutionText',
                            style:
                                const TextStyle(fontSize: 11.5, color: Fx.sub)),
                      ),
                    const Text('播放速度',
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: Fx.sub)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final item in FsSpeedPanel.options)
                          ChipTag(
                            fxRateLabel(item),
                            active: (_rate - item).abs() < .001,
                            onTap: () {
                              _setRate(item);
                              setSheetState(() {});
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    const Text('画面比例',
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: Fx.sub)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final fit in FsVideoFit.values)
                          ChipTag(
                            fit.label,
                            active: _videoFit == fit,
                            onTap: () {
                              setState(() => _videoFit = fit);
                              setSheetState(() {});
                            },
                          ),
                      ],
                    ),
                    if (quality.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      const Text('清晰度',
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: Fx.sub)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ChipTag(
                            '自动',
                            active: _qualityKey == null,
                            onTap: () {
                              Navigator.of(sheetContext).pop();
                              unawaited(_selectQuality(null));
                            },
                          ),
                          for (final q in quality)
                            ChipTag(
                              _qualityName(q),
                              active: _qualityKey == q.key,
                              onTap: () {
                                Navigator.of(sheetContext).pop();
                                unawaited(_selectQuality(q.key));
                              },
                            ),
                        ],
                      ),
                    ] else ...[
                      const SizedBox(height: 14),
                      const Text('清晰度',
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: Fx.sub)),
                      const SizedBox(height: 8),
                      const ChipTag('原画', active: true),
                    ],
                    const ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: Icon(Icons.info_outline_rounded,
                          size: 20, color: Fx.sub),
                      title: Text('播放内核',
                          style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: Fx.ink)),
                      subtitle: Text('media_kit · libmpv · HLS / 加密 / 多编码',
                          style: TextStyle(fontSize: 10.5, color: Fx.sub)),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (!mounted) return;
    _wake();
  }

  Future<void> _exit() async {
    if (_exiting) return;
    _exiting = true;
    _hideTimer?.cancel();
    final playing = _playing;
    final position = await _saveProgress();
    // 播放器交回竖屏继续使用：不 pause、不 dispose，保持进度与播放状态。
    await _restoreSystemUi();
    if (!mounted) return;
    Navigator.of(context).pop(
      FullPlayerResult(
        ep: _ep,
        position: position,
        playing: playing,
        info: _info,
        rate: _rate,
        qualityKey: _qualityKey,
      ),
    );
  }

  /* ---------------------------------------------------------------- 布局 */

  Rect _videoRect(Size size) {
    // 裁剪 / 拉伸都是铺满整屏；默认模式按视频真实宽高比做 letterbox。
    if (_videoFit != FsVideoFit.contain) return Offset.zero & size;
    final video = _controller?.value;
    var aspect = 16 / 9;
    if (video != null && video.isInitialized) {
      final s = video.size;
      if (s.width > 0 && s.height > 0) {
        aspect = s.width / s.height;
      } else if (video.aspectRatio > 0) {
        aspect = video.aspectRatio;
      }
    }
    var w = size.width;
    var h = w / aspect;
    if (h > size.height) {
      h = size.height;
      w = h * aspect;
    }
    return Rect.fromLTWH((size.width - w) / 2, (size.height - h) / 2, w, h);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final rect = _videoRect(size);
    final c = _controller;

    return PopScope<FullPlayerResult>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        unawaited(_exit());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        resizeToAvoidBottomInset: false,
        body: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fromRect(rect: rect, child: _buildVideoSurface(c)),
            if (!_locked)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _onSurfaceTap,
                  onDoubleTap: _togglePlay,
                  onLongPressStart: (_) => _startHold2x(),
                  onLongPressEnd: (_) => _endHold2x(),
                  child: const SizedBox.expand(),
                ),
              ),
            if (_loading && !_error) _buildLoading(rect),
            if (_error) _buildError(rect),
            if (_panelOpen)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _closePanels,
                  child: const SizedBox.expand(),
                ),
              ),
            if (!_locked)
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: !_controls || _loading,
                  child: AnimatedOpacity(
                    opacity: _controls ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: _buildControls(c, keyboard, pad),
                  ),
                ),
              ),
            if (_locked)
              Positioned.fill(
                child: SafeArea(child: FsUnlockButton(onUnlock: _unlock)),
              ),
            if (_holding2x)
              Positioned(
                top: pad.top + 10,
                left: 0,
                right: 0,
                child: const Center(child: _FsBadge(text: '2.0x 倍速播放中')),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoSurface(FxPlayer? c) {
    if (c == null || !c.value.isInitialized) {
      return const ColoredBox(color: Colors.black);
    }
    final size = c.value.size;
    final width = size.width > 0 ? size.width : 16.0;
    final height = size.height > 0 ? size.height : 9.0;
    final aspect = width / height;
    switch (_videoFit) {
      case FsVideoFit.contain:
        // _videoRect 已按真实比例算好，这里填满该矩形。
        return Center(
          child: AspectRatio(aspectRatio: aspect, child: c.buildVideo()),
        );
      case FsVideoFit.cover:
        return ClipRect(
          child: SizedBox.expand(
            child: c.buildVideo(fit: BoxFit.cover),
          ),
        );
      case FsVideoFit.stretch:
        return ClipRect(
          child: SizedBox.expand(
            child: c.buildVideo(fit: BoxFit.fill),
          ),
        );
    }
  }

  Widget _buildLoading(Rect rect) {
    return Positioned.fromRect(
      rect: rect,
      child: IgnorePointer(
        child: Container(
          color: Colors.black.withOpacity(.22),
          alignment: Alignment.center,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(.16),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(.26)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 17,
                  height: 17,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
                SizedBox(width: 9),
                Text('正在加载线路…',
                    style: TextStyle(color: Colors.white, fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildError(Rect rect) {
    return Positioned.fromRect(
      rect: rect,
      child: Center(
        child: Container(
          width: 330,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.95),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(.20),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded, color: Fx.sub, size: 26),
              const SizedBox(height: 4),
              Text(
                _errorText,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(color: Fx.ink, fontSize: 12, height: 1.5),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _errorAction('重试', () {
                    unawaited(_bootstrap(
                      seekToSaved: true,
                      saveOld: false,
                    ));
                  }),
                  const SizedBox(width: 10),
                  _errorAction('退出全屏', () => unawaited(_exit())),
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
          boxShadow: [
            BoxShadow(
              color: Fx.accent.withOpacity(.25),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
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

  Widget _buildControls(
    FxPlayer? c,
    double keyboard,
    EdgeInsets pad,
  ) {
    final compact = MediaQuery.sizeOf(context).width < 700;
    final bottomInset = keyboard > 0 ? 0.0 : pad.bottom;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: FsTopBar(
            title: _title,
            epLabel: _epLabel,
            resolution: _resolutionText,
            compact: compact,
            rotationLocked: _rotationLocked,
            onBack: () => unawaited(_exit()),
            onRotate: _toggleRotation,
            onPip: () => fxToast(context, '画中画：正在准备…'),
            onCast: () => fxToast(context, '正在搜索附近投屏设备…'),
            onSettings: () => unawaited(_openPlayerSettings()),
          ),
        ),
        Positioned.fill(
          child: FsSideControls(
            onLock: _lock,
            onSeekBy: _seekBy,
          ),
        ),
        if (c != null)
          Center(
            child: AnimatedBuilder(
              animation: c,
              builder: (context, _) {
                final playing = c.value.isInitialized && c.value.isPlaying;
                return FsCenterControls(
                  playing: playing,
                  onTogglePlay: _togglePlay,
                );
              },
            ),
          ),
        if (_seekHint != null)
          Align(
            alignment: const Alignment(0, .56),
            child: _FsBadge(text: _seekHint!),
          ),
        Positioned(
          left: 0,
          right: 0,
          bottom: keyboard,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_showQuality)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: FsQualityPanel(
                      items: _qualityList,
                      currentKey: _qualityKey,
                      onPick: (key) => unawaited(_selectQuality(key)),
                    ),
                  ),
                ),
              if (_showSpeed)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: FsSpeedPanel(
                      rate: _rate,
                      onPick: (v) {
                        _setRate(v);
                        setState(() => _showSpeed = false);
                        _wake();
                      },
                    ),
                  ),
                ),
              if (_showJump)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: FsJumpPanel(
                      onIntro: () {
                        _closePanels();
                        _jumpIntro();
                      },
                      onOutro: () {
                        _closePanels();
                        _jumpOutro();
                      },
                    ),
                  ),
                ),
              if (_showEpisodes)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: FsEpisodeStrip(
                    episodes: _episodes,
                    current: _ep,
                    onPick: (n) => unawaited(_switchEp(n)),
                    onClose: _closePanels,
                  ),
                ),
              if (c == null)
                SizedBox(height: 68 + bottomInset)
              else
                AnimatedBuilder(
                  animation: c,
                  builder: (context, _) {
                    final v = c.value;
                    return FsBottomBar(
                      position: v.position,
                      duration: v.duration,
                      playing: v.isInitialized && v.isPlaying,
                      rate: _rate,
                      qualityLabel: _qualityLabel,
                      compact: compact,
                      bottomInset: bottomInset,
                      onSeek: _seekTo,
                      onTogglePlay: _togglePlay,
                      onNext: () => unawaited(_next()),
                      onJump: _toggleJump,
                      onSpeed: _toggleSpeed,
                      onQuality: _toggleQuality,
                      onEpisodes: _toggleEpisodes,
                      onExit: () => unawaited(_exit()),
                    );
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 居中提示小胶囊（±10s / 倍速提示）
class _FsBadge extends StatelessWidget {
  const _FsBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(.52),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(.28)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

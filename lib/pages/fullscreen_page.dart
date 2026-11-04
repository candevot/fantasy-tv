import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/danmaku_overlay.dart';
import '../widgets/fs_controls.dart';
import '../widgets/fs_panels.dart';
import '../widgets/player_theme.dart';

/// 全屏播放退出时带回给竖屏播放器的结果
class FullPlayerResult {
  const FullPlayerResult({
    required this.ep,
    required this.position,
    required this.playing,
  });

  /// 退出时的集数
  final int ep;

  /// 退出时的播放进度（秒）
  final double position;

  /// 退出时是否处于播放中
  final bool playing;
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
/// 进入即横屏 + 沉浸式，退出恢复竖屏；控件 3 秒自动隐藏，点击画面切换显隐；
/// 锁屏后只剩解锁按钮，其它手势全部失效。
class FullPlayerPage extends StatefulWidget {
  const FullPlayerPage({
    super.key,
    this.videoId = '',
    this.ep = 1,
    this.line = '',
    this.title = '',
    this.startPosition = 0,
    this.playInfo,
    this.episodes = const <Episode>[],
    this.initialDanmaku,
    this.lineName = '',
  });

  final String videoId;
  final int ep;
  final String line;
  final String title;

  /// 竖屏播放器带入的当前进度（秒）
  final double startPosition;

  /// 竖屏已经拿到的播放信息，可直接复用，省一次请求
  final PlayInfo? playInfo;

  /// 剧集列表（详情页带入）
  final List<Episode> episodes;

  /// 竖屏已经加载好的弹幕
  final List<DanmuItem>? initialDanmaku;

  /// 线路名（仅用于设置面板展示）
  final String lineName;

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

  VideoPlayerController? _controller;
  PlayInfo? _info;
  List<DanmuItem> _danmaku = const <DanmuItem>[];

  late int _ep;
  late String _line;
  late String _title;
  late List<Episode> _episodes;

  int _loadToken = 0;
  bool _loading = true;
  bool _error = false;
  String _errorText = '';
  bool _sourceFailNotified = false;
  bool _ended = false;

  // 控件显隐 / 锁屏
  bool _controls = true;
  Timer? _hideTimer;
  bool _locked = false;
  bool _rotationLocked = false;

  // 弹层 / 输入态
  bool _inputActive = false;
  bool _showSpeed = false;
  bool _showEpisodes = false;
  bool _showJump = false;
  bool _showQuality = false;
  bool _showColors = true;

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

  double? _pendingStart;
  bool _exiting = false;

  Color _danmakuColor = kDanmakuPalette.first;

  final TextEditingController _danmakuCtrl = TextEditingController();
  final FocusNode _danmakuFocus = FocusNode();

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
    final size = _controller?.value.size;
    if (size == null || size.width <= 0 || size.height <= 0) return '';
    return '${size.width.round()}x${size.height.round()}';
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
    _pendingStart = widget.startPosition > 0 ? widget.startPosition : null;

    WidgetsBinding.instance.addObserver(this);
    danmakuSettings.addListener(_onDanmakuChanged);
    _danmakuFocus.addListener(_onDanmakuFocus);

    unawaited(_enterImmersive());
    _startHideTimer();
    unawaited(_bootstrap(seekToSaved: true, saveOld: false, useProvided: true));
    if (widget.videoId.isNotEmpty && _episodes.isEmpty) {
      unawaited(_loadEpisodeMeta());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    danmakuSettings.removeListener(_onDanmakuChanged);
    _danmakuFocus.removeListener(_onDanmakuFocus);
    _hideTimer?.cancel();
    _seekHintTimer?.cancel();
    _loadToken++;
    unawaited(_saveProgress());
    _danmakuCtrl.dispose();
    _danmakuFocus.dispose();
    _controller?.removeListener(_onVideoValue);
    _controller?.dispose();
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

  Future<void> _bootstrap({
    required bool seekToSaved,
    bool saveOld = true,
    bool useProvided = false,
  }) async {
    final token = ++_loadToken;
    _hideTimer?.cancel();
    if (saveOld) await _saveProgress();
    if (!mounted || token != _loadToken) return;
    _controller?.pause();
    setState(() {
      _loading = true;
      _error = false;
      _errorText = '';
      _ended = false;
      _sourceFailNotified = false;
      _qualityKey = null;
    });

    List<DanmuItem>? presetDanmaku;
    PlayInfo source;
    final provided = widget.playInfo;
    if (useProvided &&
        provided != null &&
        _ep == widget.ep &&
        _line == widget.line) {
      source = provided;
      presetDanmaku = widget.initialDanmaku;
    } else {
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
      final pending = _pendingStart;
      _pendingStart = null;
      resume = (pending != null && pending > 0)
          ? pending
          : await fxLoadProgress(widget.videoId, _ep);
    }
    if (!mounted || token != _loadToken) return;

    var ok = false;
    for (final url in candidates) {
      if (!mounted || token != _loadToken) return;
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(url),
        httpHeaders:
            source.headers.isEmpty ? const <String, String>{} : source.headers,
      );
      try {
        await controller.initialize();
        if (!mounted || token != _loadToken) {
          await controller.dispose();
          return;
        }
        final durationMs = controller.value.duration.inMilliseconds;
        var start = resume;
        if (durationMs > 0 && start >= durationMs / 1000.0 - 2) start = 0;
        if (start > 0) {
          await controller
              .seekTo(Duration(milliseconds: (start * 1000).round()));
        }
        await controller.setLooping(false);
        if (_rate != 1.0) {
          try {
            await controller.setPlaybackSpeed(_rate);
          } catch (_) {}
        }
        await controller.play();
        if (!mounted || token != _loadToken) {
          await controller.dispose();
          return;
        }
        final old = _controller;
        old?.removeListener(_onVideoValue);
        _controller = controller;
        controller.addListener(_onVideoValue);
        if (old != null) unawaited(old.dispose());
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
        try {
          controller.removeListener(_onVideoValue);
          await controller.dispose();
        } catch (_) {}
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
      return;
    }

    List<DanmuItem> danmaku;
    if (presetDanmaku != null && presetDanmaku.isNotEmpty) {
      danmaku = presetDanmaku;
    } else {
      danmaku = await loadDanmakuSource(source.danmu);
    }
    if (!mounted || token != _loadToken) return;
    setState(() => _danmaku = danmaku);
  }

  void _notifySourceFailed() {
    if (_sourceFailNotified) return;
    _sourceFailNotified = true;
    if (!mounted) return;
    fxToast(context, '当前线路播放失败，可返回竖屏切换线路');
  }

  /// 切换清晰度：真正换 networkUrl，并恢复切换前的进度 / 倍速 / 播放状态。
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

    final old = _controller;
    if (old == null || !old.value.isInitialized) {
      fxToast(context, '播放器尚未就绪，请稍后再试');
      return;
    }
    final wasPlaying = old.value.isPlaying;
    final resume = old.value.position;
    unawaited(old.pause());

    _hideTimer?.cancel();
    _danmakuFocus.unfocus();
    setState(() {
      _showQuality = false;
      _showSpeed = false;
      _showEpisodes = false;
      _showJump = false;
      _inputActive = false;
      _loading = true;
      _error = false;
      _errorText = '';
      _ended = false;
      _controls = true;
    });

    final token = ++_loadToken;
    VideoPlayerController? fresh;
    for (final url in urls) {
      if (!mounted || token != _loadToken) return;
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(url),
        httpHeaders:
            info.headers.isEmpty ? const <String, String>{} : info.headers,
      );
      try {
        await controller.initialize();
        if (!mounted || token != _loadToken) {
          await controller.dispose();
          return;
        }
        final duration = controller.value.duration;
        var target = resume;
        if (duration > Duration.zero &&
            target >= duration - const Duration(milliseconds: 1500)) {
          target = Duration.zero;
        }
        if (target > Duration.zero) await controller.seekTo(target);
        await controller.setLooping(false);
        try {
          await controller.setPlaybackSpeed(_holding2x ? 2.0 : _rate);
        } catch (_) {}
        if (wasPlaying) await controller.play();
        fresh = controller;
        break;
      } catch (_) {
        try {
          await controller.dispose();
        } catch (_) {}
      }
    }

    if (!mounted || token != _loadToken) {
      await fresh?.dispose();
      return;
    }
    if (fresh == null) {
      setState(() => _loading = false);
      if (wasPlaying) unawaited(old.play());
      _wake();
      fxToast(context, '切换清晰度失败，请重试');
      return;
    }

    old.removeListener(_onVideoValue);
    fresh.addListener(_onVideoValue);
    _controller = fresh;
    unawaited(old.dispose());
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

  Future<double> _saveProgress() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return 0;
    final v = c.value;
    var seconds = v.position.inMilliseconds / 1000.0;
    if (v.duration.inMilliseconds > 0 &&
        v.position.inMilliseconds >= v.duration.inMilliseconds - 1500) {
      seconds = 0;
    }
    await fxSaveProgress(widget.videoId, _ep, seconds);
    return seconds;
  }

  void _onVideoValue() {
    final c = _controller;
    if (c == null || !mounted) return;
    final v = c.value;
    if (v.hasError && !_error) {
      setState(() {
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
    await fxSaveProgress(widget.videoId, _ep, 0);
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
    if (_episodes.isEmpty) return _ep + 1;
    final index = _episodes.indexWhere((e) => e.n == _ep);
    if (index < 0) return _ep + 1;
    if (index + 1 >= _episodes.length) return null;
    return _episodes[index + 1].n;
  }

  Future<void> _switchEp(int next, {bool auto = false}) async {
    if (next == _ep) {
      _closePanels();
      return;
    }
    await _saveProgress();
    if (!mounted) return;
    setState(() {
      _ep = next;
      _episodes = List<Episode>.from(_episodes);
      _danmaku = const <DanmuItem>[];
      _showEpisodes = false;
      _showQuality = false;
      _controls = true;
      _loading = true;
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

  void _onDanmakuChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _onDanmakuFocus() {
    if (!mounted || !_danmakuFocus.hasFocus) return;
    _hideTimer?.cancel();
    if (!_inputActive || !_controls) {
      setState(() {
        _inputActive = true;
        _controls = true;
      });
    }
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (_locked ||
          _inputActive ||
          _panelOpen ||
          _holding2x ||
          _loading ||
          _error) {
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
    _danmakuFocus.unfocus();
    if (!mounted) return;
    setState(() {
      _controls = false;
      _inputActive = false;
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
    if (_inputActive) {
      _closeInput();
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
    if (!_inputActive) _wake();
  }

  void _lock() {
    _danmakuFocus.unfocus();
    setState(() {
      _locked = true;
      _controls = false;
      _inputActive = false;
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
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isPlaying) {
      unawaited(c.pause());
      unawaited(_saveProgress());
    } else {
      unawaited(c.play());
    }
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
      await c.setPlaybackSpeed(rate);
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

  void _toggleDanmaku() {
    danmakuSettings.setShow(!danmakuSettings.show);
    _wake();
  }

  Future<void> _openDanmakuSettings() async {
    _closePanels();
    _hideTimer?.cancel();
    _danmakuFocus.unfocus();
    if (!mounted) return;
    setState(() {
      _controls = true;
      _inputActive = false;
    });
    await showDanmakuSettingsPanel(context);
    if (!mounted) return;
    _wake();
  }

  void _beginInput() {
    _hideTimer?.cancel();
    _closePanels();
    setState(() {
      _controls = true;
      _inputActive = true;
      _showColors = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _danmakuFocus.requestFocus();
    });
  }

  void _closeInput() {
    _danmakuFocus.unfocus();
    if (!mounted) return;
    setState(() {
      _inputActive = false;
      _showColors = true;
    });
    _wake();
  }

  void _sendDanmaku() {
    final text = _danmakuCtrl.text.trim();
    if (text.isEmpty) {
      fxToast(context, '弹幕内容不能为空');
      return;
    }
    final c = _controller;
    final at = c != null && c.value.isInitialized
        ? c.value.position.inMilliseconds / 1000.0
        : 0.0;
    setState(() {
      _danmaku = List<DanmuItem>.from(_danmaku)
        ..add(DanmuItem(at, text, fxColorToHex(_danmakuColor), 1));
    });
    _danmakuCtrl.clear();
    _showSeekHint('弹幕已发送');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _danmakuFocus.requestFocus();
    });
  }

  void _toggleSpeed() {
    _hideTimer?.cancel();
    _danmakuFocus.unfocus();
    setState(() {
      _showSpeed = !_showSpeed;
      _showJump = false;
      _showEpisodes = false;
      _showQuality = false;
      _inputActive = false;
      _controls = true;
    });
    if (!_showSpeed) _wake();
  }

  void _toggleJump() {
    _hideTimer?.cancel();
    _danmakuFocus.unfocus();
    setState(() {
      _showJump = !_showJump;
      _showSpeed = false;
      _showEpisodes = false;
      _showQuality = false;
      _inputActive = false;
      _controls = true;
    });
    if (!_showJump) _wake();
  }

  void _toggleEpisodes() {
    _hideTimer?.cancel();
    _danmakuFocus.unfocus();
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
      _inputActive = false;
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
    _danmakuFocus.unfocus();
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
      _inputActive = false;
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
    _danmakuFocus.unfocus();
    if (mounted) setState(() => _controls = true);

    final openDanmaku = await showModalBottomSheet<bool>(
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
                          onPressed: () =>
                              Navigator.of(sheetContext).pop(false),
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
                              Navigator.of(sheetContext).pop(false);
                              unawaited(_selectQuality(null));
                            },
                          ),
                          for (final q in quality)
                            ChipTag(
                              _qualityName(q),
                              active: _qualityKey == q.key,
                              onTap: () {
                                Navigator.of(sheetContext).pop(false);
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
                    const SizedBox(height: 6),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: danmakuSettings.show,
                      activeColor: Fx.accent,
                      title: const Text('显示弹幕',
                          style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: Fx.ink)),
                      onChanged: (v) {
                        danmakuSettings.setShow(v);
                        setSheetState(() {});
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: const Icon(Icons.tune_rounded,
                          size: 20, color: Fx.accent),
                      title: const Text('弹幕设置',
                          style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: Fx.ink)),
                      subtitle: const Text('字号 / 透明度 / 区域 / 滚动时间 / 类型',
                          style: TextStyle(fontSize: 10.5, color: Fx.sub)),
                      trailing: const Icon(Icons.chevron_right_rounded,
                          color: Fx.sub),
                      onTap: () => Navigator.of(sheetContext).pop(true),
                    ),
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
                      subtitle: Text('video_player · HLS / MP4 自适应',
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
    if (openDanmaku == true) {
      await _openDanmakuSettings();
    } else {
      _wake();
    }
  }

  Future<void> _exit() async {
    if (_exiting) return;
    _exiting = true;
    _hideTimer?.cancel();
    _danmakuFocus.unfocus();
    final playing = _playing;
    final position = await _saveProgress();
    final c = _controller;
    if (c != null) unawaited(c.pause());
    await _restoreSystemUi();
    if (!mounted) return;
    Navigator.of(context).pop(
      FullPlayerResult(ep: _ep, position: position, playing: playing),
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
            if (c != null)
              Positioned.fromRect(
                rect: rect,
                child: IgnorePointer(child: _buildDanmakuLayer(c)),
              ),
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
                  ignoring: !_controls,
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

  Widget _buildVideoSurface(VideoPlayerController? c) {
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
          child: AspectRatio(aspectRatio: aspect, child: VideoPlayer(c)),
        );
      case FsVideoFit.cover:
        return ClipRect(
          child: SizedBox.expand(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: width,
                height: height,
                child: VideoPlayer(c),
              ),
            ),
          ),
        );
      case FsVideoFit.stretch:
        return ClipRect(
          child: SizedBox.expand(
            child: FittedBox(
              fit: BoxFit.fill,
              child: SizedBox(
                width: width,
                height: height,
                child: VideoPlayer(c),
              ),
            ),
          ),
        );
    }
  }

  Widget _buildDanmakuLayer(VideoPlayerController c) {
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        final v = c.value;
        if (!v.isInitialized) return const SizedBox.shrink();
        return DanmakuOverlay(
          items: _danmaku,
          position: v.position,
          playing: v.isPlaying,
          settings: danmakuSettings,
        );
      },
    );
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
                      useProvided: true,
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
    VideoPlayerController? c,
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
              if (_inputActive)
                FsDanmakuInputBar(
                  controller: _danmakuCtrl,
                  focusNode: _danmakuFocus,
                  color: _danmakuColor,
                  showColors: _showColors,
                  onPickColor: (color) => setState(() => _danmakuColor = color),
                  onTogglePalette: () =>
                      setState(() => _showColors = !_showColors),
                  onSend: _sendDanmaku,
                  onClose: _closeInput,
                  compact: compact,
                  bottomInset: bottomInset,
                )
              else if (c == null)
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
                      danmakuOn: danmakuSettings.show,
                      qualityLabel: _qualityLabel,
                      compact: compact,
                      bottomInset: bottomInset,
                      onSeek: _seekTo,
                      onTogglePlay: _togglePlay,
                      onNext: () => unawaited(_next()),
                      onToggleDanmaku: _toggleDanmaku,
                      onDanmakuSettings: () =>
                          unawaited(_openDanmakuSettings()),
                      onDanmakuInput: _beginInput,
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

/// 居中提示小胶囊（±10s / 已发送弹幕 / 2x 提示）
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

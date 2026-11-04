import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:http/http.dart' as http;

import '../api.dart';
import '../models.dart';
import '../theme.dart';

/// 全局共享的弹幕设置（竖屏 / 全屏 / 设置抽屉实时同步）
class DanmakuSettings extends ChangeNotifier {
  bool show = true;
  double fontSize = 14;
  double opacity = .8;
  double area = .3;
  double scrollSeconds = 10;
  bool hideTop = false;
  bool whiteOnly = false;
  bool massive = false;
  bool hideBottom = false;
  bool outline = true;
  bool subtitle = false;

  void setShow(bool v) {
    if (show == v) return;
    show = v;
    notifyListeners();
  }

  void setFontSize(double v) {
    if (fontSize == v) return;
    fontSize = v;
    notifyListeners();
  }

  void setOpacity(double v) {
    if (opacity == v) return;
    opacity = v;
    notifyListeners();
  }

  void setArea(double v) {
    if (area == v) return;
    area = v;
    notifyListeners();
  }

  void setScrollSeconds(double v) {
    if (scrollSeconds == v) return;
    scrollSeconds = v;
    notifyListeners();
  }

  void toggleHideTop() {
    hideTop = !hideTop;
    notifyListeners();
  }

  void toggleWhiteOnly() {
    whiteOnly = !whiteOnly;
    notifyListeners();
  }

  void toggleMassive() {
    massive = !massive;
    notifyListeners();
  }

  void toggleHideBottom() {
    hideBottom = !hideBottom;
    notifyListeners();
  }

  void toggleOutline() {
    outline = !outline;
    notifyListeners();
  }

  void toggleSubtitle() {
    subtitle = !subtitle;
    notifyListeners();
  }
}

final DanmakuSettings danmakuSettings = DanmakuSettings();

/// 解析 PlayInfo.danmu：支持 XML / JSON / URL，失败或为空时用演示弹幕。
Future<List<DanmuItem>> loadDanmakuSource(String source) async {
  final parsed = await _parseDanmaku(source);
  return parsed.isEmpty ? demoDanmaku() : parsed;
}

Future<List<DanmuItem>> _parseDanmaku(String source) async {
  final raw = source.trim();
  if (raw.isEmpty) return <DanmuItem>[];
  var text = raw;
  final inline = raw.startsWith('<') || raw.startsWith('[') || raw.startsWith('{');
  if (!inline) {
    var url = raw;
    if (!url.startsWith('http')) url = Api.abs(url);
    try {
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 6));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return <DanmuItem>[];
      }
      text = utf8.decode(res.bodyBytes, allowMalformed: true);
    } catch (_) {
      return <DanmuItem>[];
    }
  }
  final body = text.trim();
  if (body.isEmpty) return <DanmuItem>[];
  if (body.startsWith('[') || body.startsWith('{')) {
    final jsonList = _parseJsonDanmaku(body);
    if (jsonList.isNotEmpty) return jsonList;
  }
  return _parseXmlDanmaku(body);
}

List<DanmuItem> _parseJsonDanmaku(String text) {
  dynamic decoded;
  try {
    decoded = jsonDecode(text);
  } catch (_) {
    return <DanmuItem>[];
  }
  final list = _findDanmakuList(decoded);
  if (list == null) return <DanmuItem>[];
  final out = <DanmuItem>[];
  for (final e in list) {
    if (e is! Map) continue;
    final m = Map<String, dynamic>.from(e);
    final content =
        '${m['text'] ?? m['content'] ?? m['m'] ?? m['msg'] ?? ''}'.trim();
    if (content.isEmpty) continue;
    var time = 0.0;
    final rawTime = m['t'] ?? m['time'] ?? m['stime'] ?? m['progress'];
    if (rawTime is num) {
      time = rawTime.toDouble();
      if (m.containsKey('progress') && time > 1000) time /= 1000;
    } else if (rawTime is String) {
      time = double.tryParse(rawTime) ?? 0;
    }
    var color = '${m['color'] ?? '#FFFFFF'}';
    final rawColor = m['color'];
    if (rawColor is int) {
      color = '#${(rawColor & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    }
    final rawMode = m['mode'] ?? m['type'] ?? 1;
    final mode = rawMode is num ? rawMode.toInt() : 1;
    out.add(DanmuItem(time < 0 ? 0 : time, content, color, mode.clamp(1, 4).toInt()));
  }
  out.sort((a, b) => a.t.compareTo(b.t));
  return out;
}

List<dynamic>? _findDanmakuList(dynamic value) {
  if (value is List) return value;
  if (value is Map) {
    for (final key in const ['data', 'danmu', 'items', 'list', 'comments', 'result']) {
      if (!value.containsKey(key)) continue;
      final found = _findDanmakuList(value[key]);
      if (found != null) return found;
    }
    for (final v in value.values) {
      final found = _findDanmakuList(v);
      if (found != null) return found;
    }
  }
  return null;
}

List<DanmuItem> _parseXmlDanmaku(String text) {
  final out = <DanmuItem>[];
  final re = RegExp(
    r'<(?:d|danmu|comment)\b([^>]*)>([\s\S]*?)</(?:d|danmu|comment)>',
    caseSensitive: false,
  );
  for (final match in re.allMatches(text)) {
    final attrs = match.group(1) ?? '';
    final content = _decodeXml(_stripCdata(match.group(2) ?? '')).trim();
    if (content.isEmpty) continue;
    var time = 0.0;
    var mode = 1;
    var color = '#FFFFFF';
    final p = _xmlAttr(attrs, 'p');
    if (p != null && p.contains(',')) {
      final parts = p.split(',');
      if (parts.isNotEmpty) {
        time = double.tryParse(parts[0].trim()) ?? 0;
      }
      if (parts.length > 1) {
        mode = int.tryParse(parts[1].trim()) ?? 1;
      }
      if (parts.length > 3) {
        final c = int.tryParse(parts[3].trim());
        if (c != null) {
          color = '#${(c & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
        }
      }
    } else {
      time = double.tryParse(
            _xmlAttr(attrs, 'time') ?? _xmlAttr(attrs, 't') ?? '',
          ) ??
          0;
      mode = int.tryParse(
            _xmlAttr(attrs, 'mode') ?? _xmlAttr(attrs, 'type') ?? '',
          ) ??
          1;
      final colorRaw = _xmlAttr(attrs, 'color') ?? '';
      final c = int.tryParse(colorRaw);
      if (c != null) {
        color = '#${(c & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
      } else if (colorRaw.startsWith('#')) {
        color = colorRaw;
      }
    }
    out.add(DanmuItem(time < 0 ? 0 : time, content, color, mode.clamp(1, 4).toInt()));
  }
  out.sort((a, b) => a.t.compareTo(b.t));
  return out;
}

String? _xmlAttr(String attrs, String name) {
  final re = RegExp('$name\\s*=\\s*["\']([^"\']*)["\']', caseSensitive: false);
  return re.firstMatch(attrs)?.group(1);
}

String _stripCdata(String raw) {
  final v = raw.trim();
  if (v.startsWith('<![CDATA[') && v.endsWith(']]>')) {
    return v.substring(9, v.length - 3);
  }
  return v;
}

String _decodeXml(String raw) {
  var v = raw
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
  v = v.replaceAllMapped(
    RegExp(r'&#x([0-9a-fA-F]+);'),
    (m) => _charFromCode(int.tryParse(m.group(1) ?? '', radix: 16)),
  );
  v = v.replaceAllMapped(
    RegExp(r'&#(\d+);'),
    (m) => _charFromCode(int.tryParse(m.group(1) ?? '')),
  );
  return v;
}

String _charFromCode(int? code) {
  if (code == null || code < 0 || code > 0x10FFFF) return '';
  return String.fromCharCode(code);
}

/// 演示弹幕（接口失败 / 空数据时兜底）
List<DanmuItem> demoDanmaku() => <DanmuItem>[
      DanmuItem(1.2, '来了来了！', '#FFFFFF', 1),
      DanmuItem(2.6, '前排打卡', '#FFFFFF', 2),
      DanmuItem(3.1, '这个镜头绝了', '#69F0AE', 1),
      DanmuItem(4.4, '老婆好美啊啊啊', '#FF80AB', 1),
      DanmuItem(5.8, '台词好戳我', '#FFFFFF', 1),
      DanmuItem(7.2, '什么神仙画面', '#80D8FF', 1),
      DanmuItem(8.9, '进度条撑住', '#FFFFFF', 3),
      DanmuItem(10.5, '前方高能！', '#FFF176', 1),
      DanmuItem(12.1, '这也太甜了吧', '#FF80AB', 1),
      DanmuItem(13.7, '导演加鸡腿', '#FFFFFF', 1),
      DanmuItem(15.2, '弹幕护体', '#B388FF', 1),
      DanmuItem(17.0, '好喜欢这段配乐', '#FFFFFF', 2),
      DanmuItem(18.6, '别走开，后面更精彩', '#80D8FF', 1),
      DanmuItem(20.1, '我宣布这是本集最佳', '#FFF176', 1),
      DanmuItem(22.3, '笑死我了哈哈哈哈', '#FFFFFF', 1),
      DanmuItem(24.0, '这个眼神有故事', '#69F0AE', 1),
      DanmuItem(26.5, '截图当壁纸了', '#FF80AB', 1),
      DanmuItem(28.9, '一集根本不够看', '#FFFFFF', 3),
      DanmuItem(31.2, '第二遍来打卡', '#B388FF', 1),
      DanmuItem(34.0, '弹幕比剧情还精彩', '#FFFFFF', 1),
      DanmuItem(37.5, '求更新求更新', '#80D8FF', 1),
      DanmuItem(41.0, '这个转场好丝滑', '#FFFFFF', 1),
    ];

/// 右侧滑出的白玻璃弹幕设置抽屉
Future<void> showDanmakuSettingsPanel(BuildContext context) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '弹幕设置',
    barrierColor: Colors.black.withOpacity(.22),
    transitionDuration: const Duration(milliseconds: 240),
    pageBuilder: (context, animation, secondaryAnimation) {
      return const _DanmakuDrawer();
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      );
    },
  );
}

class _DanmakuDrawer extends StatelessWidget {
  const _DanmakuDrawer();

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final width = math.min(size.width * .88, 360.0);
    return Material(
      color: Colors.transparent,
      child: Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: width,
          height: size.height,
          child: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(.91),
                  border: Border(
                    left: BorderSide(color: Colors.white.withOpacity(.95)),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF50729F).withOpacity(.18),
                      blurRadius: 40,
                      offset: const Offset(-12, 0),
                    ),
                  ],
                ),
                child: SafeArea(
                  left: false,
                  child: AnimatedBuilder(
                    animation: danmakuSettings,
                    builder: (context, _) => _buildContent(context),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final s = danmakuSettings;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 8, 6),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  gradient: Fx.brand,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Fx.accent.withOpacity(.30),
                      blurRadius: 14,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: const Icon(Icons.auto_awesome_rounded,
                    color: Colors.white, size: 19),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('弹幕设置',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: Fx.ink)),
                    SizedBox(height: 2),
                    Text('白玻璃 · 即时生效',
                        style: TextStyle(fontSize: 10.5, color: Fx.sub)),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.close_rounded, color: Fx.sub, size: 22),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Container(
            height: 1,
            color: const Color(0xFFE8EDF5),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(0, 4, 0, 24),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 12, 4),
                child: Row(
                  children: [
                    Icon(
                      s.show
                          ? Icons.visibility_rounded
                          : Icons.visibility_off_rounded,
                      size: 19,
                      color: s.show ? Fx.accent : Fx.sub,
                    ),
                    const SizedBox(width: 8),
                    const Text('显示弹幕',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Fx.ink)),
                    const Spacer(),
                    Switch(
                      value: s.show,
                      activeColor: Fx.accent,
                      onChanged: s.setShow,
                    ),
                  ],
                ),
              ),
              _DSlider(
                label: '字体大小',
                valueText: s.fontSize.round().toString(),
                value: s.fontSize.clamp(10.0, 30.0).toDouble(),
                min: 10,
                max: 30,
                divisions: 20,
                onChanged: s.setFontSize,
              ),
              _DSlider(
                label: '不透明度',
                valueText: '${(s.opacity * 100).round()}%',
                value: s.opacity.clamp(.2, 1.0).toDouble(),
                min: .2,
                max: 1,
                divisions: 16,
                onChanged: s.setOpacity,
              ),
              _DSlider(
                label: '显示区域',
                valueText: '${(s.area * 100).round()}%',
                value: s.area.clamp(.1, 1.0).toDouble(),
                min: .1,
                max: 1,
                divisions: 18,
                onChanged: s.setArea,
              ),
              _DSlider(
                label: '滚动时间',
                valueText: '${s.scrollSeconds.toStringAsFixed(1)} 秒',
                value: s.scrollSeconds.clamp(3.0, 20.0).toDouble(),
                min: 3,
                max: 20,
                divisions: 34,
                onChanged: s.setScrollSeconds,
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(18, 12, 18, 4),
                child: Row(
                  children: [
                    Text('弹幕类型设置',
                        style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w800,
                            color: Fx.ink)),
                    SizedBox(width: 6),
                    Text('按喜好净化弹幕',
                        style: TextStyle(fontSize: 10.5, color: Fx.sub)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 6, 18, 6),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _DTypeChip(
                      label: '隐藏顶部',
                      active: s.hideTop,
                      onTap: s.toggleHideTop,
                    ),
                    _DTypeChip(
                      label: '白色弹幕',
                      active: s.whiteOnly,
                      onTap: s.toggleWhiteOnly,
                    ),
                    _DTypeChip(
                      label: '海量',
                      active: s.massive,
                      onTap: s.toggleMassive,
                    ),
                    _DTypeChip(
                      label: '隐藏底部',
                      active: s.hideBottom,
                      onTap: s.toggleHideBottom,
                    ),
                    _DTypeChip(
                      label: '弹幕描边',
                      active: s.outline,
                      onTap: s.toggleOutline,
                    ),
                    _DTypeChip(
                      label: '字幕',
                      active: s.subtitle,
                      onTap: s.toggleSubtitle,
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(18, 14, 18, 0),
                child: Text(
                  '提示：长按画面 2 倍速，双击暂停；全屏底部输入框可发送弹幕。',
                  style: TextStyle(
                      fontSize: 10.5, color: Fx.sub, height: 1.6),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DSlider extends StatelessWidget {
  const _DSlider({
    required this.label,
    required this.valueText,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;
  final String valueText;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 7, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600, color: Fx.ink)),
              const Spacer(),
              Text(valueText,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Fx.accent)),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              activeTrackColor: Fx.accent,
              inactiveTrackColor: const Color(0xFFE2E8F2),
              thumbColor: Fx.accent,
              overlayColor: Fx.accent.withOpacity(.12),
              thumbShape:
                  const RoundSliderThumbShape(enabledThumbRadius: 8, elevation: 3),
              overlayShape:
                  const RoundSliderOverlayShape(overlayRadius: 16),
            ),
            child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

class _DTypeChip extends StatelessWidget {
  const _DTypeChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active
              ? Fx.accent.withOpacity(.12)
              : Colors.white.withOpacity(.62),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: active ? Fx.accent.withOpacity(.65) : Colors.white,
            width: active ? 1.2 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (active) ...[
              const Icon(Icons.check_rounded, size: 13, color: Fx.accent),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: active ? Fx.accent : Fx.sub,
                fontWeight: active ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 弹幕绘制层：CustomPaint 式 Positioned 文字 + 内部 Ticker 平滑滚动
class DanmakuOverlay extends StatefulWidget {
  const DanmakuOverlay({
    super.key,
    required this.items,
    required this.position,
    required this.playing,
    this.settings,
    this.enabled = true,
  });

  final List<DanmuItem> items;
  final Duration position;
  final bool playing;
  final DanmakuSettings? settings;
  final bool enabled;

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

enum _DanmakuKind { scroll, top, bottom }

class _DItem {
  _DItem({
    required this.item,
    required this.kind,
    required this.lane,
    required this.width,
    required this.color,
    required this.speed,
  });

  final DanmuItem item;
  final _DanmakuKind kind;
  final int lane;
  final double width;
  final Color color;
  final double speed;
}

class _DanmakuOverlayState extends State<DanmakuOverlay>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  DanmakuSettings? _listening;
  double _anchorSeconds = 0;
  DateTime _anchorWall = DateTime.now();
  bool _anchorPlaying = false;
  DateTime? _lastFrame;

  List<_DItem> _layout = const <_DItem>[];
  int _layoutSignature = 0;

  DanmakuSettings get _settings => widget.settings ?? danmakuSettings;

  @override
  void initState() {
    super.initState();
    _anchorSeconds = widget.position.inMilliseconds / 1000.0;
    _anchorPlaying = widget.playing;
    _anchorWall = DateTime.now();
    _listening = _settings;
    _listening!.addListener(_onSettingsChanged);
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void didUpdateWidget(covariant DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextSettings = _settings;
    if (_listening != nextSettings) {
      _listening?.removeListener(_onSettingsChanged);
      _listening = nextSettings;
      _listening!.addListener(_onSettingsChanged);
    }
    if (oldWidget.playing != widget.playing ||
        oldWidget.position != widget.position) {
      _syncAnchor();
    }
    if (oldWidget.items != widget.items || oldWidget.settings != widget.settings) {
      _layoutSignature = 0;
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _listening?.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() {
    if (!mounted) return;
    _layoutSignature = 0;
    setState(() {});
  }

  void _syncAnchor() {
    final target = widget.position.inMilliseconds / 1000.0;
    final now = DateTime.now();
    if (!widget.playing) {
      if (!_anchorPlaying && (_anchorSeconds - target).abs() < 0.02) return;
      _anchorSeconds = target;
      _anchorWall = now;
      _anchorPlaying = false;
      return;
    }
    final predicted = _anchorPlaying
        ? _anchorSeconds + now.difference(_anchorWall).inMilliseconds / 1000.0
        : _anchorSeconds;
    if (_anchorPlaying == widget.playing && (predicted - target).abs() < 0.35) {
      return;
    }
    _anchorSeconds = target;
    _anchorWall = now;
    _anchorPlaying = true;
  }

  void _onTick(Duration elapsed) {
    if (!mounted || !widget.playing) return;
    final now = DateTime.now();
    if (_lastFrame != null &&
        now.difference(_lastFrame!).inMilliseconds < 33) {
      return;
    }
    _lastFrame = now;
    setState(() {});
  }

  double get _currentSeconds {
    if (!widget.playing) return _anchorSeconds;
    return _anchorSeconds +
        DateTime.now().difference(_anchorWall).inMilliseconds / 1000.0;
  }

  int _signature(double width, double height) {
    final s = _settings;
    return Object.hash(
      width,
      height,
      s.fontSize,
      s.area,
      s.scrollSeconds,
      s.massive,
      s.hideTop,
      s.hideBottom,
      s.whiteOnly,
      s.outline,
      s.subtitle,
      widget.items.length,
      identityHashCode(widget.items),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || !_settings.show || widget.items.isEmpty) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        if (width <= 0 || height <= 0) return const SizedBox.shrink();
        final sig = _signature(width, height);
        if (sig != _layoutSignature) {
          _layoutSignature = sig;
          _layout = _buildLayout(width, height);
        }
        final s = _settings;
        final pos = _currentSeconds;
        final fs = s.fontSize.clamp(10.0, 32.0).toDouble();
        final lineHeight = fs * (s.massive ? 1.24 : 1.52);
        final region = height * s.area.clamp(.1, 1.0);
        final scrollTop = math.min(6.0, lineHeight * .3);
        final children = <Widget>[];
        for (final d in _layout) {
          if (d.kind == _DanmakuKind.scroll) {
            if (pos < d.item.t) continue;
            final x = width - (pos - d.item.t) * d.speed;
            if (x > width || x + d.width < 0) continue;
            final y = scrollTop + d.lane * lineHeight;
            if (y > region) continue;
            children.add(Positioned(
              left: x,
              top: y,
              child: _buildDanmakuText(d, fs),
            ));
          } else {
            if (pos < d.item.t || pos > d.item.t + 4.6) continue;
            final y = d.kind == _DanmakuKind.top
                ? scrollTop + d.lane * lineHeight
                : math.max(0.0, region - (d.lane + 1) * lineHeight);
            children.add(Positioned(
              left: (width - d.width) / 2,
              top: y,
              child: _buildDanmakuText(d, fs),
            ));
          }
        }
        return SizedBox(
          width: width,
          height: height,
          child: IgnorePointer(
            child: ClipRect(
              child: Stack(children: children),
            ),
          ),
        );
      },
    );
  }

  List<_DItem> _buildLayout(double width, double height) {
    final s = _settings;
    final fs = s.fontSize.clamp(10.0, 32.0).toDouble();
    final region = height * s.area.clamp(.1, 1.0);
    final lineHeight = fs * (s.massive ? 1.24 : 1.52);
    final laneCount = math.max(1, (region / lineHeight).floor());
    final topLanes = math.max(1, math.min(3, laneCount));
    final bottomLanes = math.max(1, math.min(3, laneCount));
    final scrollFree = List<double>.filled(laneCount, -9999);
    final topFree = List<double>.filled(topLanes, -9999);
    final bottomFree = List<double>.filled(bottomLanes, -9999);
    final scrollSeconds = s.scrollSeconds.clamp(3.0, 20.0).toDouble();
    final items = List<DanmuItem>.from(widget.items)
      ..sort((a, b) => a.t.compareTo(b.t));
    final out = <_DItem>[];
    for (final item in items) {
      final text = item.text.trim();
      if (text.isEmpty) continue;
      final color = _parseColor(item.color, s.whiteOnly);
      if (item.mode == 2) {
        if (s.hideTop) continue;
        final lane = _findLane(topFree, item.t);
        if (lane < 0) continue;
        topFree[lane] = item.t + 4.6;
        out.add(_DItem(
          item: item,
          kind: _DanmakuKind.top,
          lane: lane,
          width: _estimateWidth(text, fs),
          color: color,
          speed: 0,
        ));
      } else if (item.mode == 3 || item.mode == 4) {
        if (item.mode == 3 && s.hideBottom) continue;
        if (item.mode == 4 && !s.subtitle) continue;
        final lane = _findLane(bottomFree, item.t);
        if (lane < 0) continue;
        bottomFree[lane] = item.t + 4.6;
        out.add(_DItem(
          item: item,
          kind: _DanmakuKind.bottom,
          lane: lane,
          width: _estimateWidth(text, fs),
          color: color,
          speed: 0,
        ));
      } else {
        final textWidth = _estimateWidth(text, fs);
        final speed = (width + textWidth) / scrollSeconds;
        final lane = _findLane(scrollFree, item.t);
        if (lane < 0) continue;
        scrollFree[lane] = item.t + (textWidth + 30) / speed;
        out.add(_DItem(
          item: item,
          kind: _DanmakuKind.scroll,
          lane: lane,
          width: textWidth,
          color: color,
          speed: speed,
        ));
      }
    }
    return out;
  }

  int _findLane(List<double> free, double time) {
    for (var i = 0; i < free.length; i++) {
      if (free[i] <= time) return i;
    }
    return -1;
  }

  double _estimateWidth(String text, double fontSize) {
    var width = 8.0;
    for (final rune in text.runes) {
      width += rune > 0x2E80 ? fontSize : fontSize * .56;
    }
    return width;
  }

  Color _parseColor(String raw, bool whiteOnly) {
    if (whiteOnly) return Colors.white;
    var v = raw.trim();
    if (v.isEmpty) return Colors.white;
    if (v.startsWith('#')) v = v.substring(1);
    if (v.startsWith('0x') || v.startsWith('0X')) v = v.substring(2);
    if (v.length == 8) v = v.substring(2);
    if (v.length == 3) {
      v = '${v[0]}${v[0]}${v[1]}${v[1]}${v[2]}${v[2]}';
    }
    if (v.length == 6) {
      final parsed = int.tryParse(v, radix: 16);
      if (parsed != null) return Color(0xFF000000 | parsed);
    }
    final decimal = int.tryParse(raw.trim());
    if (decimal != null) return Color(0xFF000000 | (decimal & 0xFFFFFF));
    return Colors.white;
  }

  Widget _buildDanmakuText(_DItem d, double fontSize) {
    final alpha = _settings.opacity.clamp(.15, 1.0).toDouble();
    final base = TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
      height: 1.15,
      letterSpacing: .2,
    );
    if (!_settings.outline) {
      return Text(
        d.item.text,
        maxLines: 1,
        softWrap: false,
        style: base.copyWith(
          color: d.color.withOpacity(alpha),
          shadows: [
            Shadow(
              color: Colors.black.withOpacity(alpha * .65),
              blurRadius: 4,
            ),
          ],
        ),
      );
    }
    return Stack(
      children: [
        Text(
          d.item.text,
          maxLines: 1,
          softWrap: false,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w600,
            height: 1.15,
            letterSpacing: .2,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3
              ..strokeJoin = StrokeJoin.round
              ..color = Colors.black.withOpacity(alpha * .78),
          ),
        ),
        Text(
          d.item.text,
          maxLines: 1,
          softWrap: false,
          style: base.copyWith(color: d.color.withOpacity(alpha)),
        ),
      ],
    );
  }
}

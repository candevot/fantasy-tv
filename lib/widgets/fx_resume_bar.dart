import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart' show Nav;
import '../pages/history_page.dart' show FxStore, WatchRecord;
import '../services/resume_prefetch.dart' show ResumePrefetch, ResumeTarget;
import '../theme.dart';
import 'fx_cards.dart' show FxCover;

/* ========================================================================== */
/*  首页「继续观看」悬浮条                                                     */
/*                                                                           */
/*  位置：底部标签栏正上方，固定不随首页滚动（挂在 home_page 的 Stack 里）。   */
/*  数据：观看历史最近一条 —— 和 history_page 用的是同一份本地记录、同一个     */
/*        WatchRecord 模型，不新造接口。                                      */
/*  预取：悬浮条真正渲染完成（post frame）时调 ResumePrefetch.warm，把续播位  */
/*        置那一片写进播放器同一份 SimpleCache。                              */
/* ========================================================================== */

/// 「已关闭」持久化键：存一条记录的签名，同一条记录不再弹。
const String fxResumeBarClosedKey = 'fx_resume_bar_closed_v1';

/// 首页悬浮条展示的一条续播记录。
@immutable
class FxResumeEntry {
  const FxResumeEntry({
    required this.id,
    required this.title,
    required this.cover,
    required this.ep,
    required this.epName,
    required this.lineId,
    required this.lineName,
    required this.seconds,
  });

  final String id;
  final String title;
  final String cover;
  final int ep;
  final String epName;

  /// 续播用的线路 id（`/api/play` 的 line 参数）。
  final String lineId;

  /// 线路名：清晰度（4K / 1080P）是从这里抠出来的。
  final String lineName;

  /// 上次看到第几秒（历史里的整数秒）。
  final int seconds;

  factory FxResumeEntry.fromRecord(WatchRecord r) => FxResumeEntry(
        id: r.id,
        title: r.title,
        cover: r.cover,
        ep: r.ep,
        epName: r.epName,
        lineId: r.lineId,
        lineName: r.lineName,
        seconds: r.position,
      );

  /// 关闭去重用的签名：同一条记录、同一进度才算「同一条」。
  ///
  /// 带上进度是有意的 —— 用户关掉之后又看了十几分钟，进度变了，
  /// 悬浮条该重新出现，而不是永久消失。
  String get signature => '$id|$ep|$seconds';

  /// 片名：最多 10 个字，超出用省略号（按 rune 截，不会切坏表情/生僻字）。
  String get titleLabel {
    final runes = title.runes.toList();
    if (runes.length <= 10) return title;
    return '${String.fromCharCodes(runes.take(10))}…';
  }

  /// 清晰度：取该记录线路名里的质量标识，抠不到就空串。
  String get quality => _fxQualityTag(lineName);

  /// 语言：集名优先、线路名兜底，都没有就空串。
  String get language {
    final fromEp = _fxLanguageTag(epName);
    return fromEp.isNotEmpty ? fromEp : _fxLanguageTag(lineName);
  }

  /// 进度文案：不足 1 小时 `73:07` 风格，超过 1 小时 `1:13:07`。
  String get clock {
    if (seconds <= 0) return '';
    final s = seconds;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
  }

  /// 副标题：`4K国语 (1:13:07)`；缺哪段就少哪段。
  String get subtitle {
    final head = '$quality$language';
    final time = clock;
    if (head.isEmpty) return time.isEmpty ? '' : '($time)';
    return time.isEmpty ? head : '$head ($time)';
  }

  /// 交给预取服务的目标（视频 id / 线路 id / 集数 / 秒数）。
  ResumeTarget get prefetchTarget => ResumeTarget(
        videoId: id,
        line: lineId,
        episode: ep,
        seconds: seconds.toDouble(),
        title: title,
      );
}

/// 读「继续观看」候选：历史最近一条；同一条已经被关过就返回 null。
Future<FxResumeEntry?> fxLoadResumeEntry() async {
  final raw = await FxStore.read(FxStore.historyKey);
  if (raw.isEmpty) return null;
  final list = raw
      .map(WatchRecord.fromMap)
      .where((e) => e.id.isNotEmpty)
      .toList()
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  if (list.isEmpty) return null;
  final entry = FxResumeEntry.fromRecord(list.first);
  final closed = await _readClosedSignature();
  if (closed.isNotEmpty && closed == entry.signature) return null;
  return entry;
}

/// 记住「用户已经关掉了这一条」。
Future<void> fxCloseResumeEntry(String signature) async {
  if (signature.isEmpty) return;
  try {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(fxResumeBarClosedKey, signature);
  } catch (_) {
    // 存储不可用时只是下次还会弹一次，不该影响关闭本身。
  }
}

Future<String> _readClosedSignature() async {
  try {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(fxResumeBarClosedKey) ?? '';
  } catch (_) {
    return '';
  }
}

/// 线路名 → 清晰度标签：`幻想4K` → `4K`，`1080P线路` → `1080P`。
String _fxQualityTag(String raw) {
  final s = raw.toUpperCase();
  if (s.contains('4K') || s.contains('2160')) return '4K';
  if (s.contains('1080')) return '1080P';
  if (s.contains('720')) return '720P';
  if (s.contains('480') || s.contains('标清')) return '480P';
  return '';
}

/// 集名 / 线路名里的语言标识。
const List<String> _fxLanguages = <String>[
  '国语',
  '粤语',
  '普通话',
  '闽南语',
  '英语',
  '日语',
  '韩语',
  '泰语',
];

String _fxLanguageTag(String raw) {
  if (raw.isEmpty) return '';
  for (final lang in _fxLanguages) {
    if (raw.contains(lang)) return lang;
  }
  return '';
}

/* -------------------------------------------------------------------------- */

/// 悬浮条本体（纯展示，不含数据 / 预取逻辑）。
///
/// 规格：整条高 72、圆角 16、左右 12、阴影 0 6 20 rgba(0,0,0,.18)；
/// 内部左→右：56×56 封面 → 片名 / 副标题 → 「继续观看」文字按钮 → 圆形关闭。
class FxResumeBar extends StatelessWidget {
  const FxResumeBar({
    super.key,
    required this.entry,
    required this.onOpen,
    required this.onClose,
  });

  final FxResumeEntry entry;

  /// 点卡片或「继续观看」：进详情页续播。
  final VoidCallback onOpen;

  /// 点 ×：立即消失并持久化「已关闭」。
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    // 卡片底：深色主题深紫底，浅色主题走主题的 surface（白）。
    final card = dark ? Fx.cardInk : theme.colorScheme.surface;
    // 强调色取主题的 primary，换肤时按钮跟着走。
    final accent = theme.colorScheme.primary;
    final inkColor = dark ? Colors.white : Fx.ink;
    final subColor = dark ? Colors.white.withValues(alpha: .62) : Fx.sub;
    final subtitle = entry.subtitle;

    return Semantics(
      container: true,
      button: true,
      label: '继续观看 ${entry.title}',
      child: Container(
        height: 72,
        decoration: BoxDecoration(
          color: card,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: .18),
              blurRadius: 20,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onOpen,
            child: Row(
              children: [
                const SizedBox(width: 12),
                SizedBox(
                  width: 56,
                  height: 56,
                  child: FxCover(
                    url: entry.cover,
                    title: entry.title,
                    radius: 8,
                    fit: BoxFit.cover,
                    showText: false,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.titleLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          height: 1.2,
                          fontWeight: FontWeight.w600,
                          color: inkColor,
                        ),
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.2,
                            fontWeight: FontWeight.w400,
                            color: subColor,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                // 「继续观看」：只有文字，无背景无边框。
                TextButton(
                  onPressed: onOpen,
                  style: TextButton.styleFrom(
                    foregroundColor: accent,
                    backgroundColor: Colors.transparent,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: const Text('继续观看'),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 4, right: 12),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onClose,
                    child: Semantics(
                      button: true,
                      label: '关闭继续观看',
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: const BoxDecoration(
                          color: Fx.danger,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.close_rounded,
                          size: 12,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 悬浮条宿主：自己拉历史、自己预热、自己处理关闭，外层只负责贴位置。
///
/// 用法（必须是 Stack 的直接子节点）：`const FxResumeBarHost()`。
/// 它返回 [Positioned]，底距 = 标签栏高度 + 8（见 [fxBottomBarInset]）。
class FxResumeBarHost extends StatefulWidget {
  const FxResumeBarHost({super.key});

  @override
  State<FxResumeBarHost> createState() => _FxResumeBarHostState();
}

class _FxResumeBarHostState extends State<FxResumeBarHost>
    with WidgetsBindingObserver {
  FxResumeEntry? _entry;

  /// 首次读完历史之前不占位也不闪一下空条。
  bool _ready = false;

  /// 防止并发读盘时旧结果覆盖新结果。
  int _loadSeq = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 回到前台：进度可能变了（刚从别处看完回来 / 进程没被杀），重读一次。
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final seq = ++_loadSeq;
    final entry = await fxLoadResumeEntry();
    if (!mounted || seq != _loadSeq) return;
    setState(() {
      _entry = entry;
      _ready = true;
    });
    if (entry != null) _warmOnRendered(entry);
  }

  /// 「渲染完成时」预热：等这一帧真的把悬浮条画出来再发预取。
  ///
  /// 放在 post frame 里而不是 _load 里直接调，是为了不和首页首屏的
  /// banner / 封面请求抢带宽 —— 那些图等着上屏，预取并不急。
  void _warmOnRendered(FxResumeEntry entry) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _entry?.signature != entry.signature) return;
      unawaited(ResumePrefetch.warm(entry.prefetchTarget));
    });
  }

  Future<void> _open() async {
    final entry = _entry;
    if (entry == null) return;
    // 和观看历史页保持一致：先进详情页，由详情页按记录的集数 / 线路续播
    // （播放器自己读 pos_<id>_<ep> 那份进度，所以这里不用传秒数）。
    await Nav.detail(context, entry.id, ep: entry.ep, line: entry.lineId);
    if (mounted) await _load();
  }

  Future<void> _close() async {
    final entry = _entry;
    if (entry == null) return;
    // 立即消失：先落 UI，再写盘。写盘失败也只影响「下次还弹一次」。
    setState(() => _entry = null);
    await fxCloseResumeEntry(entry.signature);
  }

  @override
  Widget build(BuildContext context) {
    final entry = _entry;
    if (!_ready || entry == null) return const SizedBox.shrink();
    return Positioned(
      left: 12,
      right: 12,
      // 标签栏顶边 + 8：几何和标签栏同源（theme.dart），标签栏改高度不会错位。
      bottom: fxBottomBarInset(context) + 8,
      child: FxResumeBar(entry: entry, onOpen: _open, onClose: _close),
    );
  }
}

import '../lib/services/fallback_match.dart';
import '../lib/services/playback_progress.dart';

/// 三段降级（FX_FALLBACK 2026-11-15）匹配规则的回归。
///
/// 这里钉的都是**用户能直接感知的错**：
///   · 片名归一化不一致 → 搜到了却认不出（换源永远不生效）；
///   · 片名模糊匹配 → 跳到另一部片子上（比播不出来更糟）；
///   · 年份不设限 → 翻拍版串了；
///   · 不排除解说 / 预告 → 跳过去变成「XX 第3集解说」；
///   · 集号不对齐 → 第 5 集换源后变成第 1 集；
///   · 进度不接 → 换源后回到片头。
void main() {
  var checks = 0;
  void check(bool ok, String name) {
    if (!ok) throw StateError(name);
    checks++;
    print('PASS $name');
  }

  // -------------------------------------------------------------- 归一化
  check(fxNormTitle(' The 100 ') == 'the100', '归一化：去空白 + 小写');
  check(fxNormTitle('济公传·高清') == '济公传高清', '归一化：去间隔号');
  check(fxNormTitle('名侦探柯南（国语）') == '名侦探柯南国语', '归一化：去全角括号');
  check(fxNormTitle('  ') == '', '归一化：空白片名归一化成空串');

  // 与搜索页（SourceHub.normTitle）同一套规则 —— 两边各写一套就会
  // 「搜索页认作同一部、换源却认不出来」。
  check(fxSameTitle('The 100', 'the100'), '同名片：大小写 + 空格不影响');
  check(fxSameTitle('济公传', '济公传 '), '同名片：尾部空格不影响');
  check(!fxSameTitle('济公传', '济公传第二季'), '不是同一部：第二季不算同名');
  check(!fxSameTitle('济公传', '济公传 高清'), '不做模糊：带后缀的不算同名');
  check(!fxSameTitle('', '济公传'), '空片名不算匹配');

  // ------------------------------------------------------------ 非正片排除
  check(fxIsExtraClip('济公传第3集解说'), '解说被排除');
  check(fxIsExtraClip('济公传 预告'), '预告被排除');
  check(fxIsExtraClip('济公传花絮'), '花絮被排除');
  check(fxIsExtraClip('济公传 精彩片段'), '片段被排除');
  check(fxIsExtraClip('The 100 Trailer'), '英文 trailer 被排除');
  check(!fxIsExtraClip('济公传'), '正片不被排除');
  check(!fxIsExtraClip('欢乐喜剧人'), '带「剧」字的正常片名不被误杀');

  // ---------------------------------------------------------------- 年份
  check(fxYearCompatible(2016, 2016), '年份相同可接受');
  check(fxYearCompatible(2016, 2015), '差 1 年可接受');
  check(fxYearCompatible(2016, 2017), '差 1 年（后一年）可接受');
  check(!fxYearCompatible(2016, 2014), '差 2 年不接受');
  check(fxYearCompatible(0, 2016), '本地年份未知时可接受');
  check(fxYearCompatible(2016, 0), '源方年份未知时可接受');
  check(fxYearGap(2016, 2016) == 0, '年级差 0');
  check(fxYearGap(2016, 2019) == 3, '年级差取绝对值');
  check(fxYearGap(0, 2019) == -1, '年份未知返回 -1');

  // ---------------------------------------------------------------- 集号
  check(fxFallbackEp(wantEp: 5, availableEps: 12) == 5, '集号对齐：对方够集');
  check(fxFallbackEp(wantEp: 12, availableEps: 8) == 0, '集数不够：不换（不回到第 1 集）');
  check(fxFallbackEp(wantEp: 8, availableEps: 8) == 8, '刚好够集');
  check(fxFallbackEp(wantEp: 5, availableEps: 0) == 5, '对方集数未知按原集号');
  check(fxFallbackEp(wantEp: 0, availableEps: 12) == 0, '非法集号返回 0');

  // ---------------------------------------------------------------- 进度
  check(
    fxFallbackPosition(want: 754, targetDuration: 1800) == 754,
    '进度接续：12:34 → 12:34',
  );
  check(
    fxFallbackPosition(want: 2400, targetDuration: 1800) == 1800,
    '进度超过对方时长：夹到末尾而不是回片头',
  );
  check(
    fxFallbackPosition(want: 754, targetDuration: 0) == 754,
    '对方时长未知：原样带过去',
  );
  check(fxFallbackPosition(want: -3, targetDuration: 100) == 0, '负进度归零');

  // ---------------------------------------------------------------- 线路挑选
  final lines = <FxLineProbe>[
    const FxLineProbe(id: 'cms_1_1', type: 'hls', degraded: true, epCount: 40),
    const FxLineProbe(id: 'cms_1_2', type: 'parse', epCount: 40),
    const FxLineProbe(id: 'cms_1_3', type: 'hls', epCount: 40),
  ];
  check(fxPickLineIndex(lines, 5) == 2, '线路挑选：健康的直链优先');
  check(fxPickLineIndex(lines, 40) == 2, '线路挑选：够集就可用');
  check(
    fxPickLineIndex(<FxLineProbe>[
      const FxLineProbe(id: 'a', epCount: 3),
      const FxLineProbe(id: 'b', epCount: 2),
    ], 5) ==
        -1,
    '线路挑选：所有线路都没这么多集 → 不换',
  );
  check(
    fxPickLineIndex(<FxLineProbe>[
      const FxLineProbe(id: ''),
      const FxLineProbe(id: 'a', epCount: 0),
    ], 5) ==
        1,
    '线路挑选：空 id 跳过，集数未知的可用',
  );
  check(
    fxPickLineIndex(<FxLineProbe>[
      const FxLineProbe(id: 'a', type: 'hls', epCount: 0),
      const FxLineProbe(id: 'b', type: 'parse', epCount: 20),
    ], 5) ==
        1,
    '线路挑选：直链比要解析的更优先（即使集数未知）',
  );

  // ---------------------------------------------------------------- 集数统计
  check(
    fxEpisodeCount(
      declared: 0,
      lineCounts: <int>[3, 8, 0],
      episodeListCount: 8,
    ) ==
        8,
    '集数：取各线路与剧集列表的最大值',
  );
  check(
    fxEpisodeCount(declared: 24, lineCounts: <int>[3], episodeListCount: 3) ==
        24,
    '集数：服务端声明的优先（更大）',
  );

  // ------------------------------------------------------------------ 文案
  check(
    fxFallbackSearchingText == '当前源播放失败，正在尝试其他源…',
    '切源提示文案固定',
  );

  check(fxFallbackSwitchedText('咕噜') == '已切换到咕噜', '切源成功 toast');
  check(fxFallbackSwitchedText(' ') == '已切换到其他源', '源名未知时的 toast');
  check(fxFallbackShortEpText(8) == '该源只有 8 集', '集数不够的提示');
  check(fxFallbackMaxHops == 1, '全链路只允许切一次源（防 A→B→C 连环跳）');

  // ------------------------------------------------------------------ 日志
  check(
    fxFallbackLog(level: 2, from: '幻想', to: '咕噜') ==
        'fallback level=2 from=幻想 to=咕噜 reason=all_lines_failed',
    '降级日志格式（第 2 段）',
  );
  check(
    fxFallbackLog(level: 3, from: '幻想', to: '剧圈', reason: 'all_lines_failed') ==
        'fallback level=3 from=幻想 to=剧圈 reason=all_lines_failed',
    '降级日志格式（第 3 段）',
  );
  check(
    fxFallbackSkipLog(level: 3, from: '幻想', reason: 'jar_missing') ==
        'fallback level=3 skip from=幻想 reason=jar_missing',
    '跳过日志格式（jar 没装）',
  );
  check(
    fxFallbackResumeLog(ep: 5, posMs: 754000, from: '幻想', to: '咕噜') ==
        'resume ep=5 pos=754000ms from=幻想 to=咕噜',
    '换源起播日志格式',
  );
  check(
    fxFallbackResumeLog(ep: 5, posMs: -1, from: '', to: '') ==
        'resume ep=5 pos=0ms from=未知 to=未知',
    '日志里的空值写「未知」，负位置归零',
  );
  check(
    fxFallbackSourceLog(source: '咕噜', hit: true) ==
        'fallback source=咕噜 hit=true',
    '逐源日志格式（命中）',
  );
  check(
    fxFallbackSourceLog(source: '', hit: false) ==
        'fallback source=未知 hit=false',
    '逐源日志格式（源名未知）',
  );

  // 第 3 段先查咕噜：名字带「咕噜」的源算优先源（TVBox 名字常带「 • 类型」后缀）。
  check(fxIsPreferredSource('咕噜'), '咕噜是优先源');
  check(fxIsPreferredSource('咕噜 • APP'), '带类型后缀的咕噜仍是优先源');
  check(!fxIsPreferredSource('剧圈'), '别的源不是优先源');
  check(!fxIsPreferredSource('  '), '空名字不是优先源');

  // ------------------------------------------------------- 8 秒 / 失败原因
  check(
    fxOpenFirstFrameTimeout == const Duration(seconds: 8),
    '每条线路最多等 8 秒（用户定稿，不要 30 秒）',
  );
  check(
    fxOpenFailReason(elapsedMs: 8000) == 'no_first_frame',
    '8 秒没出首帧 → no_first_frame',
  );
  check(
    fxOpenFailReason(elapsedMs: 120, error: 'HttpException 403') == 'http_403',
    '403 立即判失败（不等 8 秒）',
  );
  check(
    fxOpenFailReason(elapsedMs: 120, error: '404 Not Found') == 'http_404',
    '404 立即判失败（不等 8 秒）',
  );
  check(
    fxOpenFailReason(elapsedMs: 90, error: '该线路解析失败') == 'parse_error',
    '解析错误立即判失败',
  );
  check(
    fxOpenFailReason(elapsedMs: 1500, error: 'boom') == 'open_failed',
    '其它失败归 open_failed',
  );
  // FLOW_WATCH（2026-11-15，用户最终口径）：首帧之后连续 **6 秒** buffered
  // 不涨就切下一条（原来 10 秒），并且只引用唯一出处 fxStallNoProgressWindow。
  check(
    fxBufferingFailTimeout == fxStallNoProgressWindow,
    '首帧后卡顿门槛引用 fxStallNoProgressWindow',
  );
  check(
    fxBufferingFailTimeout == const Duration(seconds: 6),
    '首帧后连续 6 秒不动就换线',
  );

  // ------------------------------------------------------------ 冷却期
  final now = DateTime(2026, 11, 15, 12, 0).millisecondsSinceEpoch;
  check(fxLineCooldownWindow == const Duration(minutes: 10), '冷却期 10 分钟');
  check(fxCoolingActive(0, now) == false, '没记录 → 不在冷却');
  check(fxCoolingActive(now - 60 * 1000, now), '1 分钟前失败 → 仍在冷却');
  check(
    fxCoolingActive(now - 9 * 60 * 1000, now),
    '9 分钟前失败 → 仍在冷却',
  );
  check(
    !fxCoolingActive(now - 11 * 60 * 1000, now),
    '11 分钟前失败 → 冷却已过期（恢复原权重）',
  );

  // --------------------------------------------------- 自动换线日志 / 进度
  check(
    fxAutoLineLog(attempt: 2, total: 11, name: '红牛', ok: false, reason: 'no_first_frame') ==
        'auto line=2/11 name=红牛 result=fail reason=no_first_frame',
    '自动换线日志格式',
  );
  check(
    fxAutoLineLog(attempt: 3, total: 11, name: '量子', ok: true) ==
        'auto line=3/11 name=量子 result=ok reason=ok',
    '自动换线成功日志',
  );
  check(
    fxTryingLineText(2, 11) == '正在尝试其他线路（2/11）',
    '换线进度文案（让用户知道在动）',
  );
  check(
    fxFallbackAllFailedText == '这部片暂时播不了，已帮你试过全部线路',
    '最终失败文案要软，不甩锅给用户',
  );

  print('');
  print('fallback_match: $checks checks passed');
}

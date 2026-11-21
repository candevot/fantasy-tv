import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/models.dart';
import 'package:fantasy_tv/pages/live_groups_page.dart';
import 'package:fantasy_tv/services/live_validity.dart';

/// LIVE_INVALID（2026-11-21）门禁：播放失败的台本会话内不再出现。
///
/// 现场：直播页显示 512 个台，点进去一部分直接黑屏 / 「播放中断」，
/// 用户退回来那一张卡还在，反复点、反复失败。现在播放页确认拿不到流时
/// 调 `LiveValidity.markBroken`，列表（首页直播区和直播页共用
/// `buildLiveSections`）立刻把它剔除。
void main() {
  LiveGroup cctvGroup() => LiveGroup(
        id: '央视频道',
        name: '央视频道',
        cover: '',
        channels: const <LiveChannel>[
          LiveChannel(
            id: 'ch-a',
            title: 'CCTV-1 综合',
            cover: '',
            url: 'http://example.com/a.m3u8',
            group: '央视',
          ),
          LiveChannel(
            id: 'ch-b',
            title: 'CCTV-2 财经',
            cover: '',
            url: 'http://example.com/b.m3u8',
            group: '央视',
          ),
        ],
      );

  tearDown(LiveValidity.clear);

  test('标记失效的台从分组里消失，其余台不受影响', () {
    final groups = <LiveGroup>[cctvGroup()];
    expect(buildLiveSections(groups).single.count, 2);

    LiveValidity.markBroken('ch-a');
    final after = buildLiveSections(groups);
    expect(after.single.count, 1);
    expect(after.single.channels.single.title, 'CCTV-2 财经');
  });

  test('整组都失效时分组本身不再出现（不会留下 0 个台的空标题）', () {
    LiveValidity.markBroken('ch-a');
    LiveValidity.markBroken('ch-b');
    expect(buildLiveSections(<LiveGroup>[cctvGroup()]), isEmpty);
  });

  test('标记会通知页面重建，clear 之后全部回来', () {
    var hits = 0;
    void listener() => hits++;
    LiveValidity.revision.addListener(listener);
    addTearDown(() => LiveValidity.revision.removeListener(listener));

    LiveValidity.markBroken('ch-a');
    LiveValidity.markBroken('ch-a'); // 幂等：同一台不重复通知
    expect(hits, 1);
    expect(LiveValidity.isBroken('ch-a'), isTrue);

    LiveValidity.clear();
    expect(hits, 2);
    expect(buildLiveSections(<LiveGroup>[cctvGroup()]).single.count, 2);
  });

  test('台名首字：CCTV 取 C，中文台取第一个汉字，空名不崩', () {
    expect(liveInitialOf('CCTV-1 综合'), 'C');
    expect(liveInitialOf('湖南卫视'), '湖');
    expect(liveInitialOf('4K 超高清'), '4');
    expect(liveInitialOf('   '), '·');
  });

  test('分组色：同分组同色，不同分组不同色', () {
    final cctv = liveSectionColor('央视频道');
    expect(liveSectionColor('央视频道'), cctv);
    expect(liveSectionColor('卫视频道'), isNot(cctv));
    expect(liveSectionColor('地方频道'), isNot(cctv));
  });
}

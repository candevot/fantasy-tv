// 直播数据模型单测（纯 Dart，不依赖 Flutter）：
//   /root/dartsdk-arm64/dart-sdk/bin/dart tools/test_live_models.dart
import '../lib/models.dart';

int _passed = 0;

void check(bool cond, String message) {
  if (!cond) throw StateError('FAIL: $message');
  _passed++;
}

void main() {
  // 新服务端：{id,name,cover,lines:[{label,url,height}]}，线路按高度降序。
  final channel = LiveChannel.fromJson(<String, dynamic>{
    'id': 'live_1',
    'name': 'CCTV-1 综合',
    'cover': 'https://x/cover.jpg',
    'group': '央视频道',
    'lines': <Map<String, dynamic>>[
      {'label': '720P', 'url': 'https://x/720.m3u8', 'height': 720},
      {'label': '4K', 'url': 'https://x/4k.m3u8', 'height': 2160},
      {'label': '1080P', 'url': 'https://x/1080.m3u8', 'height': 1080},
      {'label': '720P', 'url': 'https://x/720.m3u8', 'height': 720},
    ],
  });
  check(channel.title == 'CCTV-1 综合', '频道名兼容 name');
  check(channel.lines.length == 3, '重复 URL 去重');
  check(channel.lines[0].qualityLabel == '4K', '最高清在前');
  check(channel.lines[1].qualityLabel == '1080P', '1080P 其次');
  check(channel.lines[2].qualityLabel == '720P', '720P 最后');
  check(channel.lines[0].id == 'l1' && channel.lines[2].id == 'l3', '缺 id 时补 l1…');
  check(channel.lines[1].subtitle(1) == '线路 2', 'label 与清晰度重复时显示线路序号');

  // 收藏 / 房间标题往返。
  final decoded = decodeLiveRoomTitle(encodeLiveRoomTitle(channel));
  check(decoded != null, '标题能解出频道');
  check(decoded!.id == channel.id, '频道 id 往返');
  check(decoded.lines.length == 3, '线路往返');
  check(decoded.lines[0].url == 'https://x/4k.m3u8', '线路地址往返');
  check(stripLiveRoomTitle(encodeLiveRoomTitle(channel)) == 'CCTV-1 综合 · 一起看',
      '标题展示去掉编码尾巴');
  check(decodeLiveRoomTitle('普通房间') == null, '非直播房返回 null');

  // 旧接口：单个 url 兜底成一条线路。
  final legacy = LiveChannel.fromJson(<String, dynamic>{
    'id': 'old',
    'title': '旧频道',
    'url': 'https://x/old.m3u8',
    'group': '其他',
  });
  check(legacy.lines.length == 1 && legacy.lines.first.url.endsWith('old.m3u8'),
      '旧 url 兜底线路');
  check(legacy.lines.first.id == 'l1', '旧线路 id 固定 l1');

  // 分组解析：channels 里允许只有 lines 没有 url 的频道。
  final group = LiveGroup.fromJson(<String, dynamic>{
    'id': 'cctv',
    'name': '央视频道',
    'channels': <Map<String, dynamic>>[
      {
        'id': 'live_1',
        'name': 'CCTV-1 综合',
        'lines': <Map<String, dynamic>>[
          {'label': '1080P', 'url': 'https://x/1080.m3u8', 'height': 1080},
        ],
      },
      {
        'id': 'empty',
        'name': '没有线路',
      },
    ],
  });
  check(group.channels.length == 1, '无线路频道被过滤');
  check(group.channels.first.group == '央视频道', '频道继承分组名');

  print('OK: $_passed assertions');
}

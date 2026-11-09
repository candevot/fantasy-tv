import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';
import '../widgets/fx_cards.dart';
import 'live_detail_page.dart';
import '../utils/fx_route.dart';

/// 直播 Tab 的固定分组顺序：央视 → 卫视 → 少儿 → 地方 → 港澳台 → 体育 → 其他。
const List<String> kLiveSectionOrder = <String>[
  '央视频道',
  '卫视频道',
  '少儿频道',
  '地方频道',
  '港澳台',
  '体育频道',
  '其他',
];

const String _localSection = '地方频道';
const String _otherProvince = '其他地区';

/// 直播首页的一个分组：频道列表；地方频道额外带省份子组。
class LiveSection {
  const LiveSection({
    required this.name,
    required this.channels,
    this.subgroups = const <LiveSection>[],
  });

  final String name;
  final List<LiveChannel> channels;

  /// 只有「地方频道」会按省份再拆一层；普通分组为空。
  final List<LiveSection> subgroups;

  int get count => channels.length;
  bool get hasSubgroups => subgroups.isNotEmpty;
  String get firstCover => channels.isEmpty ? '' : channels.first.cover;
}

/// 把 `/api/live` 的 groups 归并成固定顺序的 7 个分组，空组直接丢掉。
List<LiveSection> buildLiveSections(List<LiveGroup> groups) {
  final buckets = <String, List<LiveChannel>>{};
  final seen = <String>{};
  for (final group in groups) {
    final name = liveSectionName(group.name);
    final list = buckets.putIfAbsent(name, () => <LiveChannel>[]);
    for (final channel in group.channels) {
      final id = channel.id.trim();
      if (id.isNotEmpty && !seen.add(id)) continue;
      list.add(channel);
    }
  }

  final out = <LiveSection>[];
  for (final name in kLiveSectionOrder) {
    final channels = buckets[name];
    if (channels == null || channels.isEmpty) continue;
    out.add(
      LiveSection(
        name: name,
        channels: List<LiveChannel>.unmodifiable(channels),
        subgroups: name == _localSection
            ? buildProvinceSections(channels)
            : const <LiveSection>[],
      ),
    );
  }
  return out;
}

/// 地方频道按台名里的省市关键词拆成省份子组，无法归类的放「其他地区」。
List<LiveSection> buildProvinceSections(List<LiveChannel> channels) {
  final buckets = <String, List<LiveChannel>>{};
  for (final channel in channels) {
    final province = liveProvinceOf(channel);
    buckets
        .putIfAbsent(
          province.isEmpty ? _otherProvince : province,
          () => <LiveChannel>[],
        )
        .add(channel);
  }

  final out = <LiveSection>[
    for (final entry in buckets.entries)
      LiveSection(
        name: entry.key == _otherProvince ? _otherProvince : '${entry.key}频道',
        channels: List<LiveChannel>.unmodifiable(entry.value),
      ),
  ];
  out.sort((a, b) {
    if (a.name == _otherProvince) return 1;
    if (b.name == _otherProvince) return -1;
    final byCount = b.count.compareTo(a.count);
    return byCount != 0 ? byCount : a.name.compareTo(b.name);
  });
  return out;
}

/// 服务端分组名 → 固定的 7 个首页分组名。
String liveSectionName(String raw) {
  final name = raw.trim();
  if (name.isEmpty) return '其他';
  final upper = name.toUpperCase();
  if (name.contains('央视') || upper.contains('CCTV')) return '央视频道';
  if (name.contains('卫视')) return '卫视频道';
  if (name.contains('少儿')) return '少儿频道';
  if (name.contains('港澳台') ||
      name.contains('香港') ||
      name.contains('澳门') ||
      name.contains('台湾')) {
    return '港澳台';
  }
  if (name.contains('体育')) return '体育频道';
  if (name.contains('地方') || liveProvinceOfName(name).isNotEmpty) {
    return _localSection;
  }
  return '其他';
}

/// 台名 / 分组名里的省份；识别不了返回空串。
String liveProvinceOfName(String raw) {
  final name = raw.trim();
  if (name.isEmpty) return '';
  final exact = _exactProvince[name];
  if (exact != null) return exact;
  final upper = name.toUpperCase();
  for (final entry in _provinceKeywords.entries) {
    for (final keyword in entry.value) {
      if (upper.contains(keyword.toUpperCase())) return entry.key;
    }
  }
  return '';
}

/// 单台频道所属省份；优先看分组字段，再按台名关键词兜底。
String liveProvinceOf(LiveChannel channel) {
  final group = channel.group.trim();
  if (group.isNotEmpty && group != _localSection && !group.endsWith('频道')) {
    final direct = liveProvinceOfName(group);
    if (direct.isNotEmpty) return direct;
  }
  if (group.endsWith('频道')) {
    final short = group.substring(0, group.length - 2);
    final byGroup = liveProvinceOfName(short);
    if (byGroup.isNotEmpty) return byGroup;
  }
  return liveProvinceOfName(channel.title);
}

/// 搜索台名：去掉空格 / 连字符再比，`CCTV5` 也能命中 `CCTV-5 体育`。
bool liveChannelMatches(LiveChannel channel, String query) {
  final key = _normalize(query);
  if (key.isEmpty) return false;
  if (_normalize(channel.title).contains(key)) return true;
  if (_normalize(channel.group).contains(key)) return true;
  final province = liveProvinceOf(channel);
  return province.isNotEmpty && _normalize(province).contains(key);
}

String _normalize(String raw) =>
    raw.toLowerCase().replaceAll(RegExp(r'[\s\-_·.]+'), '');

/// 当前台最高清晰度：只在有 720P 及以上线路时显示真实分辨率（1920x1080），
/// 没有高清线路时为空（标清线路不打标签）。
String liveChannelQuality(LiveChannel channel) {
  var height = 0;
  for (final line in channel.lines) {
    if (line.height > height) height = line.height;
  }
  return height >= 720 ? liveQualityLabel(height) : '';
}

/// 频道卡副标题：地方台优先展示省份，其余展示所属分组。
String liveChannelSubtitle(LiveChannel channel) {
  final group = channel.group.trim();
  if (group.isEmpty) return '直播中';
  if (group == _localSection || liveSectionName(group) == _localSection) {
    final province = liveProvinceOf(channel);
    return province.isEmpty ? _localSection : '${province}频道';
  }
  final section = liveSectionName(group);
  return section == '其他' ? group : section;
}

IconData liveSectionIcon(String name) {
  if (name.contains('港澳台')) return Icons.public_rounded;
  if (name.contains('体育')) return Icons.sports_soccer_rounded;
  if (name.contains('央视')) return Icons.live_tv_rounded;
  if (name.contains('卫视')) return Icons.satellite_alt_rounded;
  if (name.contains('少儿')) return Icons.child_care_rounded;
  if (name.contains('地方') || name.endsWith('频道')) {
    return Icons.location_city_rounded;
  }
  return Icons.tv_rounded;
}

/// 点分组卡：地方频道先进入省份索引，其余直接进分组播放页。
void openLiveSection(BuildContext context, LiveSection section) {
  if (section.channels.isEmpty) return;
  if (section.hasSubgroups) {
    Navigator.of(context).push(
      FxPageRoute(builder: (_) => LiveProvincePage(section: section)),
    );
    return;
  }
  Navigator.of(context).push(
    FxPageRoute(
      builder: (_) => LiveDetailPage(
        channel: section.channels.first,
        groupName: section.name,
        playlist: section.channels,
      ),
    ),
  );
}

/// 搜索 / 单台入口：沿用原来的单频道直播详情页。
void openLiveChannel(BuildContext context, LiveChannel channel) {
  Navigator.of(
    context,
  ).push(FxPageRoute(builder: (_) => LiveDetailPage(channel: channel)));
}

/// 地方频道的省份索引：卡片式 2–3 列，不把 143 台铺在一页。
class LiveProvincePage extends StatelessWidget {
  const LiveProvincePage({super.key, required this.section});

  final LiveSection section;

  @override
  Widget build(BuildContext context) {
    final provinces = section.subgroups;
    return Scaffold(
      backgroundColor: const Color(0xFFF6F8FC),
      body: FxBackground(
        child: SafeArea(
          bottom: false,
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
                  child: Row(
                    children: [
                      _BackButton(onTap: () => Navigator.maybePop(context)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${section.name} · ${section.count} 台',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 20,
                                height: 1.2,
                                fontWeight: FontWeight.w600,
                                color: Fx.ink,
                              ),
                            ),
                            const SizedBox(height: 3),
                            const Text(
                              '按省份分组 · 选择省份开始观看',
                              style: TextStyle(fontSize: 11.5, color: Fx.sub),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                sliver: SliverLayoutBuilder(
                  builder: (context, constraints) {
                    final columns = constraints.crossAxisExtent >= 560 ? 3 : 2;
                    return SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: columns == 3 ? 1.45 : 1.25,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, i) => LiveGroupCard(
                          section: provinces[i],
                          onTap: () => openLiveSection(context, provinces[i]),
                        ),
                        childCount: provinces.length,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 直播分组卡：首台封面（没有就用图标）+ 组名 + 台数。
class LiveGroupCard extends StatelessWidget {
  const LiveGroupCard({super.key, required this.section, required this.onTap});

  final LiveSection section;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cover = section.firstCover.trim();
    final icon = liveSectionIcon(section.name);
    final sub = section.hasSubgroups
        ? '${section.count} 台 · ${section.subgroups.length} 个省份'
        : '${section.count} 台';
    return RepaintBoundary(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF50729F).withValues(alpha: .10),
                blurRadius: 16,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (cover.isEmpty)
                Container(
                  decoration: const BoxDecoration(gradient: Fx.brand),
                  child: Center(
                    child: Icon(
                      icon,
                      size: 38,
                      color: Colors.white.withValues(alpha: .92),
                    ),
                  ),
                )
              else
                FxCover(
                  url: cover,
                  title: section.name,
                  radius: 0,
                  showText: false,
                ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0),
                      Colors.black.withValues(alpha: cover.isEmpty ? .38 : .68),
                    ],
                    stops: const [.35, 1],
                  ),
                ),
              ),
              Positioned(
                left: 11,
                right: 11,
                bottom: 9,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Icon(icon, size: 13, color: Colors.white70),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            section.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15.5,
                              height: 1.2,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10.5,
                        height: 1.2,
                        fontWeight: FontWeight.w500,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 搜索结果里的频道卡：封面 + 台名 + 最高分辨率标签。
class LiveChannelCard extends StatelessWidget {
  const LiveChannelCard({
    super.key,
    required this.channel,
    required this.onTap,
  });

  final LiveChannel channel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final title = channel.title.trim().isEmpty ? '未命名频道' : channel.title.trim();
    final cover = channel.cover.trim();
    final quality = liveChannelQuality(channel);
    return RepaintBoundary(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .72),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF50729F).withValues(alpha: .08),
                blurRadius: 14,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (cover.isEmpty)
                      Container(
                        decoration: BoxDecoration(
                          gradient: Fx.brand,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Center(
                          child: Icon(
                            Icons.live_tv_rounded,
                            color: Colors.white,
                            size: 30,
                          ),
                        ),
                      )
                    else
                      FxCover(
                        url: cover,
                        title: title,
                        radius: 10,
                        showText: false,
                      ),
                    const Positioned(top: 6, left: 6, child: _LiveTag()),
                    if (quality.isNotEmpty)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: _QualityTag(label: quality),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 7),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.2,
                  fontWeight: FontWeight.w600,
                  color: Fx.ink,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                liveChannelSubtitle(channel),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 10,
                  height: 1.2,
                  color: Fx.sub,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LiveTag extends StatelessWidget {
  const _LiveTag();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .48),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 6, color: Color(0xFFFF5A5A)),
          SizedBox(width: 3),
          Text(
            'LIVE',
            style: TextStyle(
              fontSize: 9,
              height: 1.1,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

class _QualityTag extends StatelessWidget {
  const _QualityTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    // 标签可能是新的真实分辨率 `1920x1080`，也可能退回旧的 4K / 1080P。
    final height = int.tryParse(label.split('x').last) ?? 0;
    final color = switch (label) {
      '4K' => Fx.gold,
      '1080P' => const Color(0xFF8DB4FF),
      _ when height >= 2160 => Fx.gold,
      _ when height >= 1080 => const Color(0xFF8DB4FF),
      _ => const Color(0xFF7FE3D9),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: .55)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          height: 1.1,
          fontWeight: FontWeight.w800,
          letterSpacing: .3,
          color: color,
        ),
      ),
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .72),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white),
        ),
        child: const Icon(
          Icons.arrow_back_ios_new_rounded,
          size: 17,
          color: Fx.ink,
        ),
      ),
    );
  }
}

/// 无法从台名归类时用的精确映射（含少数省份不明显的频道）。
const Map<String, String> _exactProvince = <String, String>{
  '新闻综合': '内蒙古',
  '兴安新闻综合': '内蒙古',
  '都市剧场': '上海',
  '欢笑剧场': '上海',
  '梨园': '河南',
};

/// 省份 / 城市关键词。顺序很重要：先匹配更具体的省份，避免「巴彦」
/// 抢走「巴彦淖尔」、「兴安」抢走「大兴安岭」。
const Map<String, List<String>> _provinceKeywords = <String, List<String>>{
  '北京': <String>['北京', 'BTV'],
  '天津': <String>['天津', '滨海'],
  '上海': <String>['上海', '都市剧场', '欢笑剧场'],
  '重庆': <String>['重庆'],
  '广东': <String>[
    '广东',
    '广州',
    '深圳',
    '东莞',
    '中山',
    '珠海',
    '佛山',
    '惠州',
    '汕头',
    '韶关',
    '江门',
    '湛江',
    '茂名',
    '肇庆',
    '清远',
    '潮州',
    '揭阳',
    '云浮',
    '阳江',
    '河源',
    '梅州',
    '汕尾',
    '大湾区',
    '珠江',
    '南国都市',
  ],
  '浙江': <String>[
    '浙江',
    '杭州',
    '宁波',
    '温州',
    '绍兴',
    '湖州',
    '嘉兴',
    '金华',
    '衢州',
    '台州',
    '丽水',
    '舟山',
    '萧山',
    '余杭',
    '象山',
    '青田',
    '缙云',
    '海宁',
    '平湖',
    '嵊州',
    '诸暨',
    '上虞',
    '文成',
    '之江',
    '中国蓝',
    '钱江',
    '东阳',
    '普陀',
  ],
  '江苏': <String>[
    '江苏',
    '南京',
    '苏州',
    '无锡',
    '常州',
    '南通',
    '盐城',
    '徐州',
    '扬州',
    '镇江',
    '泰州',
    '淮安',
    '连云港',
    '宿迁',
    '溧水',
    '江阴',
    '昆山',
    '常熟',
    '张家港',
  ],
  '山东': <String>[
    '山东',
    '济南',
    '青岛',
    '烟台',
    '潍坊',
    '临沂',
    '淄博',
    '济宁',
    '泰安',
    '威海',
    '日照',
    '滨州',
    '德州',
    '聊城',
    '菏泽',
    '枣庄',
    '东营',
  ],
  '河南': <String>[
    '河南',
    '郑州',
    '洛阳',
    '开封',
    '南阳',
    '新乡',
    '许昌',
    '平顶山',
    '安阳',
    '焦作',
    '商丘',
    '信阳',
    '周口',
    '驻马店',
    '三门峡',
    '濮阳',
    '鹤壁',
    '漯河',
    '梨园',
  ],
  '四川': <String>[
    '四川',
    '成都',
    '绵阳',
    '德阳',
    '广元',
    '雅安',
    '乐山',
    '宜宾',
    '泸州',
    '南充',
    '达州',
    '内江',
    '自贡',
    '攀枝花',
    '遂宁',
    '眉山',
    '资阳',
    '广安',
    '巴中',
    '青川',
    '乐至',
    '荥经',
    '名山',
    '井研',
  ],
  '湖南': <String>[
    '湖南',
    '长沙',
    '株洲',
    '湘潭',
    '衡阳',
    '岳阳',
    '常德',
    '张家界',
    '益阳',
    '郴州',
    '永州',
    '怀化',
    '娄底',
    '湘西',
  ],
  '湖北': <String>[
    '湖北',
    '武汉',
    '宜昌',
    '襄阳',
    '荆州',
    '黄石',
    '十堰',
    '孝感',
    '荆门',
    '鄂州',
    '黄冈',
    '咸宁',
    '随州',
    '恩施',
  ],
  '河北': <String>[
    '河北',
    '石家庄',
    '唐山',
    '保定',
    '廊坊',
    '邯郸',
    '邢台',
    '沧州',
    '秦皇岛',
    '张家口',
    '承德',
    '衡水',
  ],
  '山西': <String>[
    '山西',
    '太原',
    '大同',
    '临汾',
    '运城',
    '长治',
    '晋城',
    '晋中',
    '忻州',
    '吕梁',
    '朔州',
    '阳泉',
    '太谷',
    '汾西',
    '万荣',
    '平顺',
    '左云',
    '闻喜',
  ],
  '安徽': <String>[
    '安徽',
    '合肥',
    '芜湖',
    '蚌埠',
    '阜阳',
    '安庆',
    '马鞍山',
    '滁州',
    '宿州',
    '六安',
    '亳州',
    '宣城',
    '淮南',
    '铜陵',
    '淮北',
    '黄山',
    '池州',
    '固镇',
    '广德',
  ],
  '福建': <String>['福建', '福州', '厦门', '泉州', '漳州', '莆田', '三明', '南平', '龙岩', '宁德'],
  '江西': <String>[
    '江西',
    '南昌',
    '赣州',
    '九江',
    '上饶',
    '宜春',
    '吉安',
    '抚州',
    '景德镇',
    '萍乡',
    '新余',
    '鹰潭',
  ],
  '广西': <String>[
    '广西',
    '南宁',
    '桂林',
    '柳州',
    '北海',
    '玉林',
    '梧州',
    '钦州',
    '贵港',
    '百色',
    '河池',
    '来宾',
    '崇左',
    '贺州',
    '防城港',
  ],
  '海南': <String>['海南', '海口', '三亚'],
  '云南': <String>[
    '云南',
    '昆明',
    '曲靖',
    '玉溪',
    '大理',
    '丽江',
    '红河',
    '文山',
    '楚雄',
    '普洱',
    '保山',
    '昭通',
    '临沧',
    '德宏',
    '迪庆',
    '西双版纳',
    '易门',
    '通海',
  ],
  '贵州': <String>['贵州', '贵阳', '遵义', '六盘水', '安顺', '毕节', '铜仁', '黔东南', '黔南', '黔西南'],
  '辽宁': <String>[
    '辽宁',
    '沈阳',
    '大连',
    '鞍山',
    '抚顺',
    '本溪',
    '丹东',
    '锦州',
    '营口',
    '阜新',
    '辽阳',
    '盘锦',
    '铁岭',
    '朝阳',
    '葫芦岛',
  ],
  '吉林': <String>['吉林', '长春', '四平', '通化', '白山', '松原', '白城', '延边', '辽源'],
  '内蒙古': <String>[
    '内蒙古',
    '内蒙',
    '呼和浩特',
    '包头',
    '呼伦贝尔',
    '通辽',
    '赤峰',
    '锡林郭勒',
    '乌兰察布',
    '鄂尔多斯',
    '巴彦淖尔',
    '乌海',
    '阿拉善',
  ],
  '黑龙江': <String>[
    '黑龙江',
    '哈尔滨',
    '齐齐哈尔',
    '牡丹江',
    '佳木斯',
    '大庆',
    '伊春',
    '鸡西',
    '鹤岗',
    '双鸭山',
    '七台河',
    '绥化',
    '黑河',
    '大兴安岭',
    '巴彦',
    '方正',
    '呼兰',
    '尚志',
    '通河',
    '五常',
    '依兰',
    '延寿',
    '肇源',
    '拜泉',
    '甘南',
    '克东',
    '龙江',
    '泰来',
    '嘉荫',
    '铁力',
    '勃利',
    '东宁',
    '海林',
    '林口',
    '富锦',
    '虎林',
    '鸡东',
    '安达',
    '望奎',
    '北安',
    '孙吴',
    '逊克',
    '饶河',
    '漠河',
    '塔河',
  ],
  '甘肃': <String>[
    '甘肃',
    '兰州',
    '天水',
    '白银',
    '武威',
    '张掖',
    '平凉',
    '酒泉',
    '庆阳',
    '定西',
    '陇南',
    '临夏',
    '甘南州',
    '天祝',
    '永昌',
    '渭源',
    '西峰',
  ],
  '陕西': <String>[
    '陕西',
    '西安',
    '宝鸡',
    '咸阳',
    '渭南',
    '延安',
    '汉中',
    '榆林',
    '安康',
    '商洛',
    '铜川',
  ],
  '新疆': <String>[
    '新疆',
    '乌鲁木齐',
    '克拉玛依',
    '吐鲁番',
    '哈密',
    '昌吉',
    '博尔塔拉',
    '巴音郭楞',
    '阿克苏',
    '克孜勒苏',
    '喀什',
    '和田',
    '伊犁',
    '塔城',
    '阿勒泰',
  ],
  '西藏': <String>['西藏', '拉萨', '日喀则', '昌都', '林芝', '山南', '那曲', '阿里'],
  '青海': <String>['青海', '西宁', '海东', '海北', '黄南', '果洛', '玉树', '海西'],
  '宁夏': <String>['宁夏', '银川', '石嘴山', '吴忠', '固原', '中卫'],
};

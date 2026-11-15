import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/services/source_hub.dart';

/// SOURCE_SHORTNAME（2026-11-15）：线上肥猫配置里的站点名长这样 ——
/// `🕊┃︎咕噜┃APP`、`🐼┃豆瓣┃预告`、`⭕┃韩圈 ┃APP`。
///
/// 老实现「遇到第一个分隔符就砍」，于是每一条的标注都只剩一个 emoji，
/// 日志里也变成 `source=🕊`，排查时根本看不出是哪个源。这里把结果钉住：
/// 取第一个**有字**的段。
void main() {
  KSource src(String name, {String api = 'csp_Gulu'}) => KSource(
        key: 'k',
        name: name,
        api: api,
        kind: KSourceKind.jar,
        origin: KSourceOrigin.user,
      );

  group('短名字（emoji + ┃ 命名）', () {
    test('取有字的那一段，不留 emoji', () {
      expect(src('🕊┃︎咕噜┃APP').shortName, '咕噜');
      expect(src('🐼┃豆瓣┃预告').shortName, '豆瓣');
      expect(src('⭕┃韩圈 ┃APP').shortName, '韩圈');
      expect(src('🎬┃荐片┃影视').shortName, '荐片');
      expect(src('🍉┃瓜子┃影视').shortName, '瓜子');
      expect(src('🏀┃瓜子┃体育').shortName, '瓜子');
    });

    test('老格式（• / · / ｜）继续正确', () {
      expect(src('咕噜 • APP').shortName, '咕噜');
      expect(src('玩偶 · 4K').shortName, '玩偶');
      expect(src('豆瓣｜首页').shortName, '豆瓣');
    });

    test('没有分隔符的名字原样返回', () {
      expect(src('QQ频道：肥猫宝贝').shortName, 'QQ频道：肥猫宝贝');
      expect(src('QQ频道：肥猫宝贝┃').shortName, 'QQ频道：肥猫宝贝');
    });

    test('来源标注用的是短名字（卡片 / 日志都靠它认源）', () {
      expect(src('🕊┃︎咕噜┃APP').resultLabel, '咕噜');
    });
  });
}

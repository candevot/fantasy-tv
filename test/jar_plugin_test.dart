// jar 插件（TVBox type 3）的**纯解析层**回归：
//   · 原生 `jarInstallProgress` / `selfTest` 回传的结构 → Dart 模型；
//   · 自检失败时「阶段 / 原因」必须能翻译成人话（类找不到 / 方法签名不匹配 /
//     缺依赖 / 源站异常），设置页和搜索提示条直接用 summary。
import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/services/jar_spider.dart';

void main() {
  group('JarInstallProgress', () {
    test('下载阶段：percent / 体积 / 文案', () {
      final p = JarInstallProgress.fromMap(<String, dynamic>{
        'phase': 'download',
        'received': 965000,
        'total': 1929492,
        'percent': 50,
        'url': 'http://125.94.244.87/spider.jar',
      });
      expect(p.phase, JarInstallPhase.download);
      expect(p.determinate, isTrue);
      expect(p.fraction, 0.5);
      expect(p.label, contains('50%'));
      expect(p.url, 'http://125.94.244.87/spider.jar');
    });

    test('服务器没给 Content-Length：不确定进度', () {
      final p = JarInstallProgress.fromMap(<String, dynamic>{
        'phase': 'download',
        'received': 1024,
        'total': 0,
        'percent': -1,
      });
      expect(p.determinate, isFalse);
      expect(p.fraction, isNull);
      expect(p.label, contains('正在下载'));
    });

    test('完成 / 失败阶段', () {
      expect(
        JarInstallProgress.fromMap(<String, dynamic>{'phase': 'done'}).phase,
        JarInstallPhase.done,
      );
      expect(
        JarInstallProgress.fromMap(<String, dynamic>{'phase': 'error'}).phase,
        JarInstallPhase.error,
      );
    });
  });

  group('JarSelfTest', () {
    test('csp_Douban 通过：分类 / 条数 / 样例', () {
      final t = JarSelfTest.fromMap(<String, dynamic>{
        'ok': true,
        'api': 'csp_Douban',
        'stage': 'done',
        'className': 'com.github.catvod.spider.Douban',
        'classes': 9,
        'items': 20,
        'sample': '流浪地球',
        'elapsedMs': 1234,
        'md5': 'cbe016eb3cb002ae62058604843f5106',
        'size': 1929492,
        'source': 'downloaded',
      });
      expect(t.ok, isTrue);
      expect(t.summary, contains('自检通过'));
      expect(t.summary, contains('流浪地球'));
      expect(t.classes, 9);
      expect(t.items, 20);
    });

    test('类找不到：阶段是 resolve', () {
      final t = JarSelfTest.fromMap(<String, dynamic>{
        'ok': false,
        'api': 'csp_Nope',
        'stage': 'resolve',
        'code': 'no_class',
        'error': 'jar 里没有这个类：csp_Nope',
      });
      expect(t.ok, isFalse);
      expect(t.summary, contains('找不到类'));
      expect(t.summary, contains('no_class'));
    });

    test('缺依赖：报出具体类名', () {
      final t = JarSelfTest.fromMap(<String, dynamic>{
        'ok': false,
        'api': 'csp_Douban',
        'stage': 'call',
        'code': 'missing_dependency',
        'error': 'homeContent 抛异常：java.lang.NoClassDefFoundError: '
            'Failed resolution of: Lokhttp3/OkHttpClient;',
      });
      expect(t.summary, contains('调用失败'));
      expect(t.summary, contains('missing_dependency'));
      expect(t.summary, contains('OkHttpClient'));
    });

    // DEX_READONLY（2026-11-15）：Android 14 拒加载可写 jar，原生会回
    // code=jar_not_readonly + jarPerms/jarWritable。文案要能指着用户重装。
    test('jar 不是只读：专有文案 + 权限', () {
      final t = JarSelfTest.fromMap(<String, dynamic>{
        'ok': false,
        'api': 'csp_Douban',
        'stage': 'classloader',
        'code': 'jar_not_readonly',
        'error': 'jar 文件不是只读，Android 14 不允许加载：'
            '/data/user/0/com.huanxiang.fantasy_tv/files/spiders/x.jar'
            '（writable=true perms=644）',
        'jarPerms': '644',
        'jarWritable': true,
      });
      expect(t.ok, isFalse);
      expect(t.jarPerms, '644');
      expect(t.jarWritable, isTrue);
      expect(t.summary, contains('权限不对'));
      expect(t.summary, contains('Android 14'));
      expect(t.summary, contains('重装'));
    });

    test('自检结果带上 jar 权限（444 = 合格）', () {
      final t = JarSelfTest.fromMap(<String, dynamic>{
        'ok': true,
        'api': 'csp_Douban',
        'stage': 'done',
        'classes': 9,
        'items': 20,
        'jarPerms': '444',
        'jarWritable': false,
      });
      expect(t.jarPerms, '444');
      expect(t.jarWritable, isFalse);
      expect(t.summary, contains('自检通过'));
    });

    test('方法签名不匹配：带上实际方法列表', () {
      final t = JarSelfTest.fromMap(<String, dynamic>{
        'ok': false,
        'api': 'csp_Old',
        'stage': 'call',
        'code': 'no_method',
        'error': 'Old 没有 homeContent(boolean)；实际方法：（没有这个方法）',
      });
      expect(t.summary, contains('no_method'));
    });
  });
}

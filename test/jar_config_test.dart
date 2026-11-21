import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/services/jar_config.dart';
import 'package:fantasy_tv/services/jar_sources.dart';

/// 线上配置接口（`hx_all.json`）的回归。
///
/// 用户口径（2026-11-21）：「四个 jar 源的 api + ext 不再内置硬编码，改成启动时
/// 拉接口，从里面按 key/name 取完整配置；接口挂了用本地缓存的上一次配置」。
///
/// 这里用的是**服务器上那份 hx_all.json 的真实片段**（含橘汁 / 下饭 / 半日99
/// 这些不该进来的源），钉住三件事：
///   1. 白名单里只有咕噜 / 剧圈，别的 csp 源一条都进不来；
///   2. 剧圈的 ext 逐字段原样保留（host / package / buildSignature 一个都不能丢）；
///   3. 咕噜没有 ext 也要收进来（线上它本来就是空）。
void main() {
  const String realSites = '''
{"sites":[
{"key":"咕噜","name":"咕噜 • APP","type":3,"api":"csp_Gulu","searchable":1,"quickSearch":1,"filterable":1},
{"key":"下饭","name":"下饭 • APP","type":3,"api":"csp_JuXiaFan","searchable":1,"quickSearch":1,"filterable":1},
{"key":"剧圈99","name":"剧圈 • APP","type":3,"api":"csp_App99","ext":{"host":"http://124.221.3.182:19987/app/bn","versionName":"1.2.0","name":"剧圈圈","package":"com.qingtangxiaozhuan.xyz","buildNumber":"2002","buildSignature":"054FA8DDA4319C6B6A9B954CA5777541C993F00B1B0BD4394F7EDE48184C4594"}},
{"key":"半日99","name":"半日 • APP","type":3,"api":"csp_App99","ext":{"host":"http://103.217.190.91:19987/app/bn","versionName":"3.5.8","name":"半日闲","package":"com.yf.lelian","buildNumber":"2001","buildSignature":"A40DA80A59D170CAA950CF15C18C454D47A39B26989D8B640ECD745BA71BF5DC"}},
{"key":"橘汁","name":"橘汁 • APP","type":3,"api":"csp_AppDrama","searchable":1,"quickSearch":1,"filterable":1,"ext":{"appName":"橘汁","publicKey":"MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCr8SzZhjYy+rsya1K09t8d2K50pWFoBkgUqMpKOiW+3IEVKd4eTdvg9RSOjQ82kypL6R9BnsmrS1V8s4PVDwjQbUtYhTPPC9Hz16qY7rpD6m0d2vr09/UpWQ5uOy9PR0QTrsioveZ+DIe9jc3C+zBCu/kZSY/R8stwJoiitki3gwIDAQAB","dataKey":"ZU1DSFFWNENKMDYXVUQRN0ZJDUC4PQ==","dataIv":"OC1A06E197EF10CF3F6058CA7A803B5E","pkg":"com.asjdhjhd.mgd.p3","host":"","site":"https://1848463092.cdn.123clouddisk.com/1848463092/cct/az.txt","version":"3.0.7.0","decrypt":"1"}}
]}''';

  test('只收白名单里的源：只保留 咕噜', () {
    final defs = JarConfig.parseSitesJson(realSites);
    expect(defs.map((d) => d.key).toList(), <String>['咕噜']);
    expect(defs.map((d) => d.api).toList(), <String>['csp_Gulu', 'csp_App99']);
  });

  test('剧圈不在白名单，但配置解析仍保留其 ext（备用，不参与运行）', () {
    final ju = JarConfig.parseSitesJson(realSites)
        .firstWhere((d) => d.key == '剧圈');
    expect(ju.name, '剧圈 • APP');
    expect(ju.ext, contains('"host":"http://124.221.3.182:19987/app/bn"'));
    expect(ju.ext, contains('"versionName":"1.2.0"'));
    expect(ju.ext, contains('"package":"com.qingtangxiaozhuan.xyz"'));
    expect(ju.ext, contains('"buildNumber":"2002"'));
    expect(
      ju.ext,
      endsWith(
        '"buildSignature":"054FA8DDA4319C6B6A9B954CA5777541C993F00B1B0BD4394F7EDE48184C4594"}',
      ),
    );
  });

  test('咕噜没有 ext：收进来且 ext 为空串', () {
    final gulu = JarConfig.parseSitesJson(realSites)
        .firstWhere((d) => d.key == '咕噜');
    expect(gulu.ext, isEmpty);
    expect(gulu.name, '咕噜 • APP');
  });

  test('接口里没有白名单源 → 返回空（调用方继续用缓存 / 内置）', () {
    expect(JarConfig.parseSitesJson('{"sites":[]}'), isEmpty);
    expect(JarConfig.parseSitesJson('不是 json'), isEmpty);
    expect(
      JarConfig.parseSitesJson(
        '{"sites":[{"key":"豆瓣","name":"豆瓣 • 首页","api":"csp_Douban"}]}',
      ),
      isEmpty,
    );
  });

  test('ext 的三种写法都能交给 jar：缺省 / 字符串 / 对象', () {
    expect(JarConfig.encodeExt(null), '');
    expect(JarConfig.encodeExt('https://vip.wwgz.cn:5200'),
        'https://vip.wwgz.cn:5200');
    expect(JarConfig.encodeExt(<String, Object?>{'url': 'http://a'}),
        '{"url":"http://a"}');
  });

  test('内置兜底那份与接口口径一致（兜底不等于放水）', () {
    for (final def in kBuiltinJarSources) {
      expect(kEnabledJarSources, contains(def.key));
      expect(def.api.startsWith('csp_'), isTrue);
      if (def.key == '剧圈') {
        expect(def.ext, contains('"host":"http://124.221.3.182:19987/app/bn"'));
      } else {
        expect(def.ext, isEmpty);
      }
    }
  });
}

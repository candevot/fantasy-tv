// 用**真实配置**跑一遍协议面解析，打印识别结果（PROTOCOL_FACE 2026-11-15 验证用）。
//
// 为什么要有它：`flutter test` 里只能喂构造出来的 JSON，真配置里的坑全在
// 「字段名变体 / ext 是对象也可能是字符串 / sites 117 条里有十几条没有 api」
// 这些地方。这个脚本直接拿线上配置跑，输出「识别到多少 sites / 多少 parses /
// 多少带 timeout 的站点」，验收标准就是这一行。
//
// 用法（不需要 flutter，纯 dart 就能跑）：
//   dart tools/probe_tvbox_config.dart http://125.94.244.87/hx_all.json
//   dart tools/probe_tvbox_config.dart ./hx_all.json          # 本地文件
//   dart tools/probe_tvbox_config.dart <url> --json           # 只打机器可读结果
//
// 注意：这个文件只 import `lib/services/tvbox_config.dart`（纯 Dart，无插件），
// 所以能在没有 Flutter 的环境里跑。

import 'dart:convert';
import 'dart:io';

import '../lib/services/tvbox_config.dart';

Future<void> main(List<String> args) async {
  final inputs = args.where((a) => !a.startsWith('--')).toList();
  final jsonOnly = args.contains('--json');
  final source = inputs.isEmpty ? '' : inputs.first;
  if (source.isEmpty) {
    stderr.writeln('用法: dart tools/probe_tvbox_config.dart <配置地址或本地文件>');
    exitCode = 2;
    return;
  }
  final body = await _load(source);
  if (body == null) {
    stderr.writeln('读不到配置：$source');
    exitCode = 1;
    return;
  }
  Object? raw;
  try {
    raw = jsonDecode(body);
  } catch (e) {
    stderr.writeln('配置不是合法 JSON：$e');
    exitCode = 1;
    return;
  }
  final config = TvBoxConfig.parse(raw, baseUrl: source);
  final report = <String, Object?>{
    'source': source,
    'bytes': body.length,
    'depotUrls': config.depotUrls,
    'sites': config.sites.length,
    'sitesRaw': config.siteCount,
    'sitesSkipped': config.skippedSites,
    'parses': config.parses.length,
    'parsesByType': <String, int>{
      for (var t = 0; t <= 4; t++)
        'type$t': config.parses.where((p) => p.type == t).length,
    },
    'sitesWithTimeout': config.sitesWithTimeout,
    'sitesWithHeader': config.sitesWithHeader,
    'sitesByType': <String, int>{
      for (var t = 0; t <= 4; t++)
        'type$t': config.sites.where((s) => s.type == t).length,
    },
    'flags': config.flags.length,
    'ads': config.ads.length,
    'hosts': config.hosts.length,
    'rules': config.rules.length,
    'doh': config.doh.length,
    'spider': config.spider,
  };
  if (jsonOnly) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
    return;
  }
  stdout
    ..writeln('=== $source (${body.length} 字节) ===')
    ..writeln('depot      : ${config.depotUrls.isEmpty ? '无' : config.depotUrls.join(', ')}')
    ..writeln('sites      : ${config.sites.length} 条'
        '（原始 ${config.siteCount} 条，跳过 ${config.skippedSites} 条）')
    ..writeln('  按 type  : ${_counts(<String, int>{for (var t = 0; t <= 4; t++) 'type$t': config.sites.where((s) => s.type == t).length})}')
    ..writeln('  带 timeout: ${config.sitesWithTimeout} 条')
    ..writeln('  带 header : ${config.sitesWithHeader} 条')
    ..writeln('parses     : ${config.parses.length} 个'
        '（${_counts(<String, int>{for (var t = 0; t <= 4; t++) 'type$t': config.parses.where((p) => p.type == t).length})}）')
    ..writeln('flags      : ${config.flags.length} 条  ads: ${config.ads.length} 条')
    ..writeln('hosts      : ${config.hosts.length} 条  rules: ${config.rules.length} 条'
        '  doh: ${config.doh.length} 个')
    ..writeln('spider     : ${config.spider.isEmpty ? '无' : config.spider}');
  if (config.sitesWithTimeout > 0) {
    stdout.writeln('--- 带 timeout 的站点 ---');
    for (final site in config.sites.where((s) => s.timeout > 0).take(10)) {
      stdout.writeln('  ${site.key}  timeout=${site.timeout}s  type=${site.type}');
    }
  }
  if (config.sitesWithHeader > 0) {
    stdout.writeln('--- 带 header 的站点 ---');
    for (final site in config.sites.where((s) => s.header.isNotEmpty).take(10)) {
      stdout.writeln('  ${site.key}  header=${site.header.keys.join(',')}');
    }
  }
  if (config.parses.isNotEmpty) {
    stdout.writeln('--- 解析器 ---');
    for (final parse in config.parses.take(10)) {
      stdout.writeln('  [${parse.type}] ${parse.name}'
          '  ${parse.url.isEmpty ? '' : parse.url}'
          '${parse.flag.isEmpty ? '' : '  flag=${parse.flag.join('/')}'}');
    }
  }
  if (config.hosts.isNotEmpty) {
    stdout.writeln('--- hosts（钉 IP） ---');
    for (final line in config.hosts.take(5)) {
      stdout.writeln('  $line');
    }
  }
  stdout.writeln('--- 摘要 ---');
  stdout.writeln(config.summary());
}

String _counts(Map<String, int> map) {
  final parts = <String>[
    for (final e in map.entries)
      if (e.value > 0) '${e.key}=${e.value}',
  ];
  return parts.isEmpty ? '空' : parts.join(' ');
}

Future<String?> _load(String source) async {
  if (source.startsWith('http://') || source.startsWith('https://')) {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(Uri.parse(source));
      // 猫源那类站按 UA 分流：播放器 UA 才回配置本身。
      request.headers.set('user-agent', 'okhttp/3.12.12');
      request.headers.set('accept', '*/*');
      final response = await request.close();
      if (response.statusCode >= 400) {
        stderr.writeln('HTTP ${response.statusCode}');
        return null;
      }
      return await response.transform(utf8.decoder).join();
    } catch (e) {
      stderr.writeln('请求失败：$e');
      return null;
    } finally {
      client.close(force: true);
    }
  }
  final file = File(source);
  if (!await file.exists()) return null;
  return file.readAsString();
}

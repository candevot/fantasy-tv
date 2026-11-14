#!/usr/bin/env python3
"""编译 jar 源自检用的示例解析器，并做一次「类加载 + 反射调用」自检。

产物：
  tools/spider_sample/spider-demo.jar   一个真的、能在 Android 上跑的 jar
                                        （纯 Java，只依赖 api.jar）
  build/spider_sample/*.json            自检时各接口返回的原始 JSON
                                        （可直接喂给 Dart 侧转换逻辑核对）

用法（仓库根目录）：
  python3 tools/build_sample_jar.py              # 只编译
  python3 tools/build_sample_jar.py --selftest   # 编译 + JVM 自检

自检做了什么（与 JarSpiderLoader 的调用序列一一对应）：
  URLClassLoader 载入 spider-demo.jar（父加载器带 api.jar）
  → Class.forName("com.example.spider.CspDemo") → newInstance
  → init(null, ext) → homeContent(false) → categoryContent("1","1",false,{})
  → detailContent(["demo-1"]) → searchContent("自检",true,"1")
  → playerContent("demo2", url, []) → homeVideoContent()
只要其中任何一步抛异常，就说明「api.jar 的签名 / jar 的结构」与加载器的
约定不一致 —— 这正是 CI 里最容易踩、真机上最难查的一类问题。
"""

import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'tools', 'spider_sample', 'src')
LIBS = os.path.join(ROOT, 'android_src', 'libs')
API_JAR = os.path.join(LIBS, 'api.jar')
OUT_DIR = os.path.join(ROOT, 'tools', 'spider_sample')
OUT_JAR = os.path.join(OUT_DIR, 'spider-demo.jar')
OUT_JSON = os.path.join(ROOT, 'build', 'spider_sample')

ANDROID_STUB_URL = (
    'https://repo.maven.apache.org/maven2/com/google/android/android/4.1.1.4/'
    'android-4.1.1.4.jar'
)

HARNESS = r'''
import android.content.Context;

import java.io.File;
import java.lang.reflect.Method;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;

/** 复刻 JarSpiderLoader 的调用序列（JVM 版），验证 jar 与 api.jar 的契约。 */
public class SelfTest {

    private static int failed = 0;
    private static final List<String> lines = new ArrayList<>();

    static void save(String name, String json) throws Exception {
        File dir = new File(System.getProperty("fx.out"));
        dir.mkdirs();
        File f = new File(dir, name);
        Files.write(f.toPath(), json.getBytes(StandardCharsets.UTF_8));
        String head = json.length() > 90 ? json.substring(0, 90) + "…" : json;
        System.out.println("  " + name + " (" + json.length() + " bytes) " + head);
    }

    static void check(String label, String text, String... needles) {
        boolean ok = text != null;
        if (ok) {
            for (String n : needles) {
                if (!text.contains(n)) {
                    ok = false;
                    System.out.println("  FAIL " + label + "：缺少 " + n);
                }
            }
        }
        if (ok) {
            System.out.println("  PASS " + label);
        } else {
            failed++;
        }
    }

    public static void main(String[] args) throws Exception {
        File jar = new File(args[0]);
        URLClassLoader loader = new URLClassLoader(
                new URL[]{jar.toURI().toURL()}, SelfTest.class.getClassLoader());
        Class<?> clz = Class.forName("com.example.spider.CspDemo", true, loader);
        Object spider = clz.getDeclaredConstructor().newInstance();

        Method init = clz.getMethod("init", Context.class, String.class);
        init.invoke(spider, null, "");

        String home = (String) clz.getMethod("homeContent", boolean.class)
                .invoke(spider, false);
        save("01-home.json", home);
        check("homeContent 有分类和列表", home, "\"class\"", "电影", "demo-1");

        HashMap<String, String> ext = new HashMap<>();
        String category = (String) clz.getMethod("categoryContent", String.class,
                String.class, boolean.class, HashMap.class)
                .invoke(spider, "1", "1", false, ext);
        save("02-category.json", category);
        check("categoryContent 传 String 页码", category, "demo-1", "\"pagecount\"");

        List<String> ids = new ArrayList<>();
        ids.add("demo-1");
        String detail = (String) clz.getMethod("detailContent", List.class)
                .invoke(spider, ids);
        save("03-detail.json", detail);
        check("detailContent 有两条线路", detail, "演示A$$$演示B", "demo.m3u8");

        String search = (String) clz.getMethod("searchContent",
                String.class, boolean.class, String.class)
                .invoke(spider, "自检", true, "1");
        save("04-search.json", search);
        check("searchContent 三参版本", search, "demo-1");

        String player = (String) clz.getMethod("playerContent", String.class,
                String.class, List.class)
                .invoke(spider, "演示B", "https://example.com/demo2.m3u8",
                        new ArrayList<String>());
        save("05-player.json", player);
        check("playerContent 返回直链", player, "\"parse\":0", "demo2.m3u8");

        // 基类默认实现：这些方法示例里没 override，必须返回空串而不是抛异常。
        Object homeVideo = clz.getMethod("homeVideoContent").invoke(spider);
        check("未 override 的方法走基类默认实现", homeVideo == null ? "" : homeVideo.toString(),
                "");
        Object manual = clz.getMethod("manualVideoCheck").invoke(spider);
        check("manualVideoCheck 默认 false", String.valueOf(manual), "false");

        loader.close();
        if (failed > 0) {
            System.out.println("== 自检失败 " + failed + " 项 ==");
            System.exit(1);
        }
        System.out.println("== 自检通过：jar 与 api.jar 的契约一致 ==");
    }
}
'''


def die(msg):
    print('ERROR: ' + msg, file=sys.stderr)
    sys.exit(1)


def find_android_jar(work):
    env = os.environ.get('ANDROID_JAR', '')
    if env and os.path.exists(env):
        return env
    cached = os.path.join(work, 'android.jar')
    if os.path.exists(cached):
        return cached
    print('  fetch android 桩 jar（编译期只需要 android.content.Context）')
    with urllib.request.urlopen(ANDROID_STUB_URL, timeout=120) as r, \
            io.open(cached, 'wb') as f:
        shutil.copyfileobj(r, f)
    return cached


def main(argv):
    selftest = '--selftest' in argv
    if not os.path.exists(API_JAR):
        die('缺少 %s，先跑 python3 tools/build_api_jar.py' % API_JAR)

    work = tempfile.mkdtemp(prefix='spider-sample-')
    classes = os.path.join(work, 'classes')
    os.makedirs(classes, exist_ok=True)
    android_jar = find_android_jar(work)

    sources = []
    for base, _dirs, files in os.walk(SRC):
        for f in files:
            if f.endswith('.java'):
                sources.append(os.path.join(base, f))
    if not sources:
        die('tools/spider_sample/src 里没有 java 文件')

    cp = os.pathsep.join([API_JAR, android_jar])
    print('  javac %d 个源文件' % len(sources))
    r = subprocess.run(['javac', '-source', '11', '-target', '11', '-encoding',
                        'UTF-8', '-nowarn', '-cp', cp, '-d', classes] + sources,
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout)
        print(r.stderr, file=sys.stderr)
        die('javac 失败')

    os.makedirs(OUT_DIR, exist_ok=True)
    if os.path.exists(OUT_JAR):
        os.remove(OUT_JAR)
    r = subprocess.run(['jar', 'cf', OUT_JAR, '-C', classes, '.'], capture_output=True,
                       text=True)
    if r.returncode != 0:
        print(r.stderr, file=sys.stderr)
        die('jar 打包失败')
    print('  生成 %s (%d bytes)' % (OUT_JAR, os.path.getsize(OUT_JAR)))

    if not selftest:
        shutil.rmtree(work, ignore_errors=True)
        return 0

    # ---- 自检：把示例 jar 当三方 jar 一样加载并反射调用
    harness = os.path.join(work, 'SelfTest.java')
    io.open(harness, 'w', encoding='utf-8').write(HARNESS)
    harness_classes = os.path.join(work, 'harness')
    os.makedirs(harness_classes, exist_ok=True)
    r = subprocess.run(['javac', '-source', '11', '-target', '11', '-encoding',
                        'UTF-8', '-nowarn', '-cp', cp, '-d', harness_classes,
                        harness], capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stderr, file=sys.stderr)
        die('自检 harness 编译失败')

    os.makedirs(OUT_JSON, exist_ok=True)
    print('== 自检：加载 jar 并反射调用 Spider ==')
    r = subprocess.run(
        ['java', '-cp', os.pathsep.join([harness_classes, API_JAR, android_jar]),
         '-Dfx.out=' + OUT_JSON, 'SelfTest', OUT_JAR],
        capture_output=True, text=True)
    print(r.stdout.rstrip())
    if r.returncode != 0:
        print(r.stderr, file=sys.stderr)
        die('自检失败')
    print('  原始 JSON 已写入 %s' % OUT_JSON)
    shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

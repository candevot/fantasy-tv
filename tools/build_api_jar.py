#!/usr/bin/env python3
"""重新生成 android_src/libs/api.jar（自建 TVBox 解析器基类）。

为什么需要这个脚本
------------------
TVBox 的 jar 源（`{"type":3,"api":"csp_Xxx","ext":"..."}`）都继承
`com.github.catvod.crawler.Spider`。官方 api.jar 拿不到（GitHub 直连不通、
jsDelivr 的仓库里也没有这个 jar），所以仓库自带一份**接口等价**的实现：
源码在 `android_src/api_stub/java/`，编译产物就是 `android_src/libs/api.jar`。

官方 api.jar 拿到手之后**不用改任何代码**：直接把它覆盖成
`android_src/libs/api.jar` 即可，包名 / 类名 / 方法签名完全一致。

依赖
----
  · JDK 11+（javac / jar）
  · android-4.1.1.4.jar（Maven 上的 android.* 编译桩，只需编译期）
  · okhttp3 / okio / gson（编译期，运行期由 android_src/libs 里的同名 jar 提供）

用法（仓库根目录）
------------------
  python3 tools/build_api_jar.py
  # 已下载的 android 桩 jar 也可以直接指定：
  python3 tools/build_api_jar.py --android-jar /path/to/android-4.1.1.4.jar
"""

import io
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'android_src', 'api_stub', 'java')
LIBS = os.path.join(ROOT, 'android_src', 'libs')
OUT = os.path.join(LIBS, 'api.jar')

ANDROID_STUB_URL = (
    'https://repo.maven.apache.org/maven2/com/google/android/android/4.1.1.4/'
    'android-4.1.1.4.jar'
)
MAVEN = 'https://repo.maven.apache.org/maven2'
COMPILE_DEPS = (
    ('com/squareup/okhttp3/okhttp/3.12.13/okhttp-3.12.13.jar', 'okhttp-3.12.13.jar'),
    ('com/squareup/okio/okio/1.17.5/okio-1.17.5.jar', 'okio-1.17.5.jar'),
    ('com/google/code/gson/gson/2.10.1/gson-2.10.1.jar', 'gson-2.10.1.jar'),
)


def die(msg):
    print('ERROR: ' + msg, file=sys.stderr)
    sys.exit(1)


def fetch(url, dst):
    if os.path.exists(dst) and os.path.getsize(dst) > 0:
        return dst
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    print('  fetch %s' % url)
    with urllib.request.urlopen(url, timeout=120) as r, io.open(dst, 'wb') as f:
        shutil.copyfileobj(r, f)
    return dst


def main(argv):
    android_jar = None
    for i, a in enumerate(argv):
        if a == '--android-jar' and i + 1 < len(argv):
            android_jar = argv[i + 1]
    if not os.path.isdir(SRC):
        die('找不到 ' + SRC)

    work = tempfile.mkdtemp(prefix='api-jar-')
    classes = os.path.join(work, 'classes')
    os.makedirs(classes, exist_ok=True)

    if android_jar is None:
        android_jar = fetch(ANDROID_STUB_URL, os.path.join(work, 'android.jar'))
    elif not os.path.exists(android_jar):
        die('android 桩 jar 不存在：' + android_jar)

    cp = [android_jar]
    for rel, name in COMPILE_DEPS:
        local = os.path.join(LIBS, name)
        if not os.path.exists(local):
            local = fetch(MAVEN + '/' + rel, os.path.join(work, name))
        cp.append(local)

    sources = []
    for base, _dirs, files in os.walk(SRC):
        for f in files:
            if f.endswith('.java'):
                sources.append(os.path.join(base, f))
    if not sources:
        die('api_stub 里没有 .java 文件')

    cmd = [
        'javac', '-source', '11', '-target', '11',
        '-encoding', 'UTF-8', '-nowarn',
        '-cp', os.pathsep.join(cp),
        '-d', classes,
    ] + sources
    print('  javac %d 个源文件' % len(sources))
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout)
        print(r.stderr, file=sys.stderr)
        die('javac 失败')

    os.makedirs(LIBS, exist_ok=True)
    r = subprocess.run(['jar', 'cf', OUT, '-C', classes, '.'],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stderr, file=sys.stderr)
        die('jar 打包失败')
    print('  生成 %s (%d bytes)' % (OUT, os.path.getsize(OUT)))
    shutil.rmtree(work, ignore_errors=True)
    print('== 完成 ==')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

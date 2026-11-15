#!/usr/bin/env python3
"""检查默认 jar 插件地址是否还在、md5 是否和 App 默认值一致。

CI 里是**非阻塞**步骤（`|| true`）：服务器抖动不该让构建红掉，但日志要能
看见「URL 404 / md5 变了」，避免发出去的包首启必然装不上 jar。

用法：python3 tools/check_spider_url.py
退出码：0 = 正常 / 无法访问但已提示；2 = md5 不一致（脚本本身仍返回 0，
由调用方决定是否阻塞）。
"""

import hashlib
import io
import sys
import urllib.request

URL = 'http://125.94.244.87/spider.jar'
EXPECT_MD5 = 'cbe016eb3cb002ae62058604843f5106'
APP_SETTINGS = 'lib/services/app_settings.dart'


def read_expected():
    try:
        src = io.open(APP_SETTINGS, encoding='utf-8').read()
    except OSError:
        return EXPECT_MD5
    marker = 'defaultJarMd5'
    idx = src.find(marker)
    if idx < 0:
        return EXPECT_MD5
    quote = src.find("'", idx)
    end = src.find("'", quote + 1)
    if quote < 0 or end < 0:
        return EXPECT_MD5
    return src[quote + 1:end].strip()


def main():
    expected = read_expected()
    print('jar 插件地址：%s' % URL)
    print('默认 md5    ：%s' % expected)
    try:
        req = urllib.request.Request(URL, headers={'User-Agent': 'fx-ci/1.0'})
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = resp.read()
            status = resp.status
            length = resp.headers.get('Content-Length')
    except Exception as e:  # noqa: BLE001 - CI 里只打印原因
        print('!! 拉取失败：%s（App 首次启动会回落到内置/手动安装）' % e)
        return 0
    md5 = hashlib.md5(data).hexdigest()
    print('HTTP %s · %d bytes（Content-Length=%s）' % (status, len(data), length))
    print('实际 md5    ：%s' % md5)
    if status != 200:
        print('!! 非 200：App 会提示「下载地址 404」')
        return 0
    if md5 != expected:
        print('!! md5 与 App 默认值不一致：首启会判 md5_mismatch 并重试一次后失败')
        return 2
    print('OK：地址可达且 md5 一致')
    return 0


if __name__ == '__main__':
    sys.exit(main())

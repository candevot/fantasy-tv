#!/usr/bin/env python3
"""静态门禁：DEX_READONLY —— Android 14 只加载只读 dex/jar。

背景：API 34 起 ART 打开 dex 前会看 `st_mode & 0222`，非零就抛
`java.lang.SecurityException: Writable dex file '<path>' is not allowed.`
v1.0.352 的真机报错就是这么来的（下载下来的 jar 是 0644）。

这个脚本防的是「以后有人把 chmod 删了 / 挪到加载后面」这类回归 ——
Dart 侧测不到原生，Kotlin 编译也不管行为，所以在这里钉死顺序。

检查项（任一不过即失败，CI 红）：
  1. JarSpiderLoader：`JarPermissions.makeReadOnly` 必须在 `DexClassLoader(` 之前；
  2. JarSpiderLoader：必须打 `[JarSpider] jar path=` 日志（真机排查入口）；
  3. JarSpiderLoader：dex 输出目录必须 makeDirWritable（反过来要可写）；
  4. JarSpiderLoader：SecurityException 兜底必须报 `jar_not_readonly`；
  5. JarSpiderPlugin：装完 sealJar(strict)、动之前 unseal（tmp / bundled / 卸载）；
  6. JarPermissions.kt 必须存在（chmod 实现本体）。
"""

import io
import os
import sys

LOADER = 'JarSpiderLoader.kt'
PLUGIN = 'JarSpiderPlugin.kt'
PERMS = 'JarPermissions.kt'

CANDIDATES = (
    'android/app/src/main/kotlin/com/huanxiang/fantasy_tv',  # CI 注入后的位置
    'android_src/kotlin/com/huanxiang/fantasy_tv',           # 仓库里的源
)


def fail(msg: str) -> None:
    print('FAIL: %s' % msg, file=sys.stderr)
    raise SystemExit(1)


def pkg_dir() -> str:
    for path in CANDIDATES:
        if os.path.isfile(os.path.join(path, LOADER)):
            return path
    fail('找不到 %s（先在 android_src 或 CI 注入目录里）' % LOADER)


def read(path: str) -> str:
    try:
        return io.open(path, encoding='utf-8').read()
    except OSError:
        fail('读不到 %s' % path)


def need(text: str, needle: str, where: str, why: str) -> None:
    if needle not in text:
        fail('%s 里没有 `%s` —— %s' % (where, needle, why))


def body(text: str, marker: str) -> str:
    """粗切出某个函数的正文（从 marker 到文件末尾，够做顺序断言）。"""
    at = text.find(marker)
    if at < 0:
        fail('找不到 `%s`' % marker)
    return text[at:]


def order(text: str, first: str, second: str, where: str, why: str) -> None:
    a = text.find(first)
    b = text.find(second)
    if a < 0:
        fail('%s 里没有 `%s` —— %s' % (where, first, why))
    if b < 0:
        fail('%s 里没有 `%s` —— %s' % (where, second, why))
    if a > b:
        fail('%s 里 `%s` 必须在 `%s` 之前 —— %s' % (where, first, second, why))


def main() -> None:
    d = pkg_dir()
    loader = read(os.path.join(d, LOADER))
    plugin = read(os.path.join(d, PLUGIN))

    if not os.path.isfile(os.path.join(d, PERMS)):
        fail('缺 %s：chmod 的实现本体必须跟着 jar 源一起打包' % PERMS)
    perms = read(os.path.join(d, PERMS))
    need(perms, 'MODE_READ_ONLY = 292', PERMS, 'jar 必须是 0444（0444 = 292）')
    need(perms, 'android.system.Os', PERMS, 'Android 上必须走 Os.chmod')
    need(perms, 'chmod', PERMS, 'Os 不可用时要有 chmod 命令兜底')

    # 1) chmod 一定要在 DexClassLoader 构造之前。
    order(
        loader,
        'ensureJarReadOnly()',
        'DexClassLoader(',
        LOADER,
        'Android 14 会拒加载可写 jar（Writable dex file is not allowed）',
    )
    need(loader, 'JarPermissions.makeReadOnly', LOADER, '加载前没 chmod 444')

    # 2) 真机排查入口：一行能 grep 到的日志。
    need(loader, '[JarSpider] jar path=', LOADER, '加载前必须打 jar path/permissions 日志')

    # 3) dex 输出目录相反：ART 要往里写 odex，必须可写。
    need(loader, 'JarPermissions.makeDirWritable(dexDir)', LOADER,
         'dex 输出目录要保证可写，不能跟着 jar 一起 chmod 只读')

    # 4) 真的被 ART 拒了要给结构化原因，而不是把 SecurityException 原样抛给 Dart。
    need(loader, 'jar_not_readonly', LOADER, '需要给用户一句能看懂的错误码')

    # 5) 安装 / 更新 / 卸载两侧的权限翻转。
    need(plugin, 'sealJar(target, strict = true)', PLUGIN, 'adopt() 装完必须钉成只读')
    need(plugin, 'private fun sealJar(', PLUGIN, '缺 sealJar 封装')
    need(plugin, 'private fun unseal(', PLUGIN, '缺 unseal 封装（0444 写不进去）')
    need(plugin, 'unseal(tmp)', PLUGIN, '重新下载前 download.tmp 要先改回可写')
    need(plugin, 'unseal(target)', PLUGIN, '覆盖写固定文件名的 bundled.jar 前要先改回可写')
    need(plugin, 'sealJar(target)', PLUGIN, '内置 jar 解出来之后也要 chmod 444')
    # 卸载：先放开权限，再删 jar、再清 dex 缓存（都限定在 uninstall() 里，
    # 否则会被前面 loader() 之类无关位置的同名字符串误判）。
    uninstall = body(plugin, 'private fun uninstall(')
    order(uninstall, 'unseal(file)', 'file.delete()', PLUGIN + ' uninstall()',
          '卸载删 jar 前要先改回可写')
    order(uninstall, 'file.delete()', 'deleteRecursively()', PLUGIN + ' uninstall()',
          '先删 jar 再清 dex 缓存')
    order(uninstall, 'makeDirWritable(', 'deleteRecursively()', PLUGIN + ' uninstall()',
          '删 dex 缓存目录前要先放开目录权限')

    print('OK: DEX_READONLY 静态门禁通过（%s）' % d)


if __name__ == '__main__':
    main()

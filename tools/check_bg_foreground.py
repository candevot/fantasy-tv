#!/usr/bin/env python3
"""BG_GATE 静态门禁（2026-11-15）。

为什么需要它：这一轮的闪退不是「哪句代码写错」，而是**某句系统调用抛出的
异常没人接**。grep 只能证明「代码里有这句话」，证明不了「它在 try 里」。
所以这里做成结构检查：

  1. `PlaybackService.kt` 里**每一处** `startForeground(` 都必须落在
     含 `BgSafe.run` 的函数体内（runCatching 的唯一出口）；
  2. 绝对不允许把 `startInForegroundRequired` / `true` 原样交给
     `super.onUpdateNotification(...)` —— media3 内部那条路会自己
     startForeground，异常直接落到主线程（本次闪退的根因）；
  3. `startForeground` 必须显式带 `FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK`
     （Android 14+ 不带就是 MissingForegroundServiceTypeException）；
  4. `MediaSession.Builder` 只能出现在 `createSession` 里，而 `ensureSession`
     必须先校验主线程（`Looper.myLooper() != Looper.getMainLooper()`）；
  5. `ExoPlayerPlugin`：BG_SERVICE_ENABLED 必须为 true、起服务前必须过
     `PlaybackService.gateServiceStart()`、onIsPlayingChanged 那条路径必须
     `requireForeground = true`、`dispose()` 里 releaseSessionNow 必须在
     `player.release()` 之前；
  6. `BgGate.kt` 不许 import android.*（否则 JVM 单测跑不了）；
  7. `docs/BACKGROUND-PLAYBACK.md` 必须在（崩因分析表 + 验收步骤）。

任何一条不满足：打印原因并退出 1。
"""

import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KOTLIN = os.path.join(ROOT, 'android_src', 'kotlin', 'com', 'huanxiang', 'fantasy_tv')
SERVICE = os.path.join(KOTLIN, 'PlaybackService.kt')
PLUGIN = os.path.join(KOTLIN, 'ExoPlayerPlugin.kt')
GATE = os.path.join(KOTLIN, 'BgGate.kt')
DOC = os.path.join(ROOT, 'docs', 'BACKGROUND-PLAYBACK.md')

def strip_comments(lines):
    """把 /* */ 与 // 注释抹成空格，保留行号（注释里的 startForeground 不算调用）。"""
    out = []
    in_block = False
    for line in lines:
        buf = []
        i = 0
        while i < len(line):
            if in_block:
                end = line.find('*/', i)
                if end < 0:
                    buf.append(' ' * (len(line) - i))
                    i = len(line)
                else:
                    buf.append(' ' * (end + 2 - i))
                    in_block = False
                    i = end + 2
                continue
            start = line.find('/*', i)
            slash = line.find('//', i)
            if slash >= 0 and (start < 0 or slash < start):
                buf.append(line[i:slash])
                break
            if start < 0:
                buf.append(line[i:])
                break
            buf.append(line[i:start])
            in_block = True
            i = start + 2
        out.append(''.join(buf))
    return out


FUN_RE = re.compile(
    r'^\s{0,8}(?:(?:override|private|internal|public|protected|suspend|inline|open)\s+)*fun\s+(\w+)')

problems = []


def read(path):
    with io.open(path, encoding='utf-8') as handle:
        return handle.read()


def line_of(text, needle, start=0):
    index = text.find(needle, start)
    if index < 0:
        return -1
    return text.count('\n', 0, index) + 1


def enclosing_function(lines, index):
    """返回 (函数名, 函数体行列表)；找不到返回 (None, [])。"""
    name = None
    start = 0
    for i in range(index, -1, -1):
        match = FUN_RE.match(lines[i])
        if match:
            name = match.group(1)
            start = i
            break
    if name is None:
        return None, []
    body = []
    for i in range(start + 1, len(lines)):
        if FUN_RE.match(lines[i]):
            break
        if lines[i].startswith('}'):
            break
        body.append(lines[i])
    return name, body


def require(condition, message):
    if not condition:
        problems.append(message)


def check_service():
    text = read(SERVICE)
    lines = strip_comments(text.split('\n'))

    require('class PlaybackService : MediaSessionService()' in text,
            'PlaybackService 必须仍然继承 MediaSessionService')

    # 1) 每一处 startForeground( 都要在含 BgSafe.run 的函数里
    for i, line in enumerate(lines):
        if not re.search(r'\bstartForeground\(', line):
            continue
        name, body = enclosing_function(lines, i)
        body_text = '\n'.join(body)
        require(name is not None and 'BgSafe.run' in body_text,
                'PlaybackService.kt:%d 的 startForeground 不在 BgSafe.run 里（函数 %s）'
                % (i + 1, name))
        require('FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK' in body_text,
                'PlaybackService.kt:%d 的 startForeground 没带 '
                'FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK（Android 14+ 会 '
                'MissingForegroundServiceTypeException）' % (i + 1))

    # 2) 绝不把 true / startInForegroundRequired 交给 media3
    for bad in ('super.onUpdateNotification(session, startInForegroundRequired',
                'super.onUpdateNotification(session, true'):
        require(bad not in text,
                'PlaybackService 不许把 %r 交给 media3：库内部会自己 startForeground，'
                '异常直接落主线程（本次闪退根因）' % bad)
    require('super.onUpdateNotification(session, false)' in text,
            'PlaybackService 必须用 super.onUpdateNotification(session, false) 只发通知')
    require('override fun onUpdateNotification(session: MediaSession, startInForegroundRequired: Boolean)' in text,
            'PlaybackService 必须覆写 onUpdateNotification 接管前台')

    # 3) MediaSession.Builder 只能在 createSession 里，且 ensureSession 先校验主线程
    index = text.find('MediaSession.Builder')
    require(index >= 0, 'PlaybackService 必须仍然创建 MediaSession')
    if index >= 0:
        name, _ = enclosing_function(lines, text.count('\n', 0, index))
        require(name == 'createSession',
                'MediaSession.Builder 只能出现在 createSession 里（实际在 %s）' % name)
    require('Looper.myLooper() != Looper.getMainLooper()' in text,
            'ensureSession 必须先校验主线程（MediaSession 只能在有 Looper 的线程建）')

    # 4) session 先于 player 释放
    require('fun releaseSessionNow()' in text, 'PlaybackService 必须提供 releaseSessionNow()')
    require('releaseSessionQuietly()' in text, 'PlaybackService 必须在 onDestroy 里释放 session')


def check_plugin():
    text = read(PLUGIN)

    require(re.search(r'BG_SERVICE_ENABLED\s*=\s*true', text) is not None,
            'ExoPlayerPlugin: BG_SERVICE_ENABLED 必须是 true（后台播放要真的开起来）')
    require('PlaybackService.gateServiceStart(' in text,
            'ExoPlayerPlugin: 起服务前必须过 PlaybackService.gateServiceStart() 门禁')
    require('startBackground(requireForeground = true)' in text,
            'ExoPlayerPlugin: onIsPlayingChanged 那条路径必须 startBackground(requireForeground = true)')

    # dispose()：先摘 session 再 release 播放器
    dispose = text.find('fun dispose()')
    require(dispose >= 0, 'ExoPlayerPlugin 必须有 dispose()')
    if dispose >= 0:
        release = text.find('releaseSessionNow()', dispose)
        player_release = text.find('player?.release()', dispose)
        require(release >= 0 and player_release >= 0 and release < player_release,
                'dispose(): releaseSessionNow() 必须在 player?.release() 之前')


def check_gate():
    text = read(GATE)
    require('import android' not in text,
            'BgGate.kt 不许 import android.*（它要能在 JVM 上直接跑单测）')
    require('data class BgEnv' in text, 'BgGate.kt 必须定义 BgEnv')
    require('fun checkForeground(' in text, 'BgGate.kt 必须定义 checkForeground')
    require('fun checkServiceStart(' in text, 'BgGate.kt 必须定义 checkServiceStart')


def check_doc():
    require(os.path.isfile(DOC), 'docs/BACKGROUND-PLAYBACK.md 必须存在（崩因分析表 + 验收步骤）')
    if not os.path.isfile(DOC):
        return
    text = read(DOC)
    for needle in ('MissingForegroundServiceTypeException',
                   'ForegroundServiceStartNotAllowedException',
                   'SecurityException',
                   'FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK',
                   '真机验收'):
        require(needle in text, 'docs/BACKGROUND-PLAYBACK.md 必须提到 %s' % needle)


def main():
    for path in (SERVICE, PLUGIN, GATE):
        if not os.path.isfile(path):
            problems.append('缺少文件 %s' % path)
    if problems:
        for item in problems:
            print('FAIL ' + item)
        return 1

    check_service()
    check_plugin()
    check_gate()
    check_doc()

    if problems:
        for item in problems:
            print('FAIL ' + item)
        print()
        print('BG_GATE 静态门禁：%d 项不通过' % len(problems))
        return 1
    print('BG_GATE 静态门禁全绿'
          '（startForeground 全在 runCatching 内 + 主线程建 session + '
          '永不让 media3 自己进前台 + BG 开关已恢复 + 文档在）')
    return 0


if __name__ == '__main__':
    sys.exit(main())

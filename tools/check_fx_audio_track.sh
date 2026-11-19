#!/usr/bin/env bash
# AUDIO_BITRATE（2026-11-19）的 JVM 单测：音轨按码率选。
#
# 验什么（全部在 tools/fx_audio_track_jvm_test.kt 里，一行一条断言）：
#   · 多音轨按 bitrate 降序取最高；
#   · 同码率 EAC3 > AC3 > DTS > AAC（原来的「优先 AAC」方向是错的，已去掉）；
#   · 首选音轨语言：有该语言只在该语言里选，没有就退回全局最高；
#   · 未声明码率（-1）不能被当成最高、解不了的轨不参与。
#
# 这些规则错了**不会崩、不会黑屏**，只是音轨选错 —— CI 里没有耳朵，
# 所以只能靠这里的断言钉住。
#
# 没有 kotlinc 的环境（典型 CI runner）直接 SKIP，不算失败：
# 真正拦回归的是同一步里的结构断言 + 真机日志。
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
ROOT=$(pwd)
SRC="$ROOT/android_src/kotlin/com/huanxiang/fantasy_tv/FxAudioTrack.kt"
TEST_SRC="$ROOT/tools/fx_audio_track_jvm_test.kt"
TMP=$(mktemp -d 2>/dev/null || mktemp -d -t fxaudio)
trap 'rm -rf "$TMP"' EXIT

if [ ! -f "$SRC" ]; then
  echo "FAIL: 找不到 $SRC"
  exit 1
fi

# 两种编译器来源：KOTLIN_COMPILER_JAR（embeddable）与 PATH 里的 kotlinc。
if [ -n "${KOTLIN_COMPILER_JAR:-}" ] && [ -f "${KOTLIN_COMPILER_JAR:-}" ]; then
  CC="$KOTLIN_COMPILER_JAR"
  for extra in "$(dirname "$KOTLIN_COMPILER_JAR")"/*.jar \
               /usr/share/kotlin/kotlinc/lib/trove4j.jar; do
    [ -f "$extra" ] && case ":$CC:" in *":$extra:"*) ;; *) CC="$CC:$extra";; esac
  done
  STDLIB=""
  for c in "$(dirname "$KOTLIN_COMPILER_JAR")/kotlin-stdlib.jar" \
           /usr/share/kotlin/kotlinc/lib/kotlin-stdlib.jar; do
    [ -f "$c" ] && { STDLIB="$c"; break; }
  done
  echo "compiler: embeddable $KOTLIN_COMPILER_JAR"
  mkdir -p "$TMP/out"
  CP_ARGS=()
  [ -n "$STDLIB" ] && CP_ARGS=(-classpath "$STDLIB")
  java -cp "$CC" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
    -nowarn -d "$TMP/out" "${CP_ARGS[@]}" "$SRC" "$TEST_SRC" 2>&1 \
    | grep -v '^warning:' | head -20
  if [ ! -f "$TMP/out/Fx_audio_track_jvm_testKt.class" ]; then
    echo 'FAIL: AUDIO_BITRATE 单测编译失败'
    exit 1
  fi
  java -cp "$TMP/out:$STDLIB" Fx_audio_track_jvm_testKt
elif command -v kotlinc >/dev/null 2>&1; then
  echo "compiler: $(command -v kotlinc)"
  kotlinc -nowarn -include-runtime -d "$TMP/fx_audio_track.jar" "$SRC" "$TEST_SRC" 2>&1 \
    | grep -v '^warning:' | head -20
  if [ ! -f "$TMP/fx_audio_track.jar" ]; then
    echo 'FAIL: AUDIO_BITRATE 单测编译失败'
    exit 1
  fi
  java -jar "$TMP/fx_audio_track.jar"
else
  echo 'SKIP: 没有 kotlinc（可用 KOTLIN_COMPILER_JAR 指定）'
fi

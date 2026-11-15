#!/usr/bin/env bash
# Kotlin 源码编译门禁（KOTLIN_COMPILE，2026-11-15）。
#
# 为什么需要它：`flutter analyze` 只管 Dart；android_src/ 里那 14 个 .kt
# 平时只有 Gradle 真正编译（CI 里要等 10 分钟才轮到）。这一轮改的是
# PlaybackService / ExoPlayerPlugin / BgGate —— 一个 import 写错、一个
# media3 签名记错，都要等到 APK 构建最后才红。这个脚本用 kotlinc 直接编译
# 整份 android_src，本地 3 秒就能看到结果。
#
# 依赖（缺了就 SKIP，不算失败）：
#   ANDROID_JAR    android.jar（默认自动找 ANDROID_HOME/platforms/*）
#   FLUTTER_JAR    flutter.jar（默认从 PATH 里的 flutter 推出来）
#   FX_KT_LIBS     一个目录，里面放 media3-*.jar / okhttp / okio / guava /
#                  annotation / api.jar（就是 Gradle 拉下来的那些 classes.jar）
#   KOTLIN_COMPILER_JAR  kotlin-compiler 的 jar（没有就用 PATH 里的 kotlinc）
#
# 用法：
#   FX_KT_LIBS=/tmp/fxc/jars bash tools/check_kotlin_compile.sh
#   只校验单个文件：KOTLIN_COMPILE_TARGET=android_src/.../PlaybackService.kt
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
ROOT=$(pwd)
SRC_DIR="$ROOT/android_src/kotlin/com/huanxiang/fantasy_tv"
API_JAR="$ROOT/android_src/libs/api.jar"
TMP=$(mktemp -d 2>/dev/null || mktemp -d -t fxkt)
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- 找编译器
COMPILER=()
STDLIB=""
if [ -n "${KOTLIN_COMPILER_JAR:-}" ] && [ -f "${KOTLIN_COMPILER_JAR:-}" ]; then
  CC="$KOTLIN_COMPILER_JAR"
  for extra in "$(dirname "$KOTLIN_COMPILER_JAR")"/*.jar \
               /usr/share/kotlin/kotlinc/lib/trove4j.jar; do
    [ -f "$extra" ] && case ":$CC:" in *":$extra:"*) ;; *) CC="$CC:$extra";; esac
  done
  COMPILER=(java -cp "$CC" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler)
  for c in "$(dirname "$KOTLIN_COMPILER_JAR")/kotlin-stdlib.jar" \
           /usr/share/kotlin/kotlinc/lib/kotlin-stdlib.jar; do
    [ -f "$c" ] && { STDLIB="$c"; break; }
  done
elif command -v kotlinc >/dev/null 2>&1; then
  COMPILER=(kotlinc)
else
  echo 'SKIP: 没有 kotlinc（可用 KOTLIN_COMPILER_JAR 指定）'
  exit 0
fi

# ---------------------------------------------------------------- 找 android.jar
ANDROID_JAR="${ANDROID_JAR:-}"
if [ -z "$ANDROID_JAR" ]; then
  for c in "${ANDROID_HOME:-}/platforms" "${ANDROID_SDK_ROOT:-}/platforms" \
           "$HOME/Android/Sdk/platforms" /root/workspace/android-sdk/plat; do
    [ -d "$c" ] || continue
    ANDROID_JAR=$(ls -d "$c"/android-*/android.jar 2>/dev/null | sort -V | tail -1)
    [ -n "$ANDROID_JAR" ] && break
  done
fi
[ -f "${ANDROID_JAR:-}" ] || { echo 'SKIP: 找不到 android.jar（设 ANDROID_JAR）'; exit 0; }

# ---------------------------------------------------------------- 找 flutter.jar
FLUTTER_JAR="${FLUTTER_JAR:-}"
if [ -z "$FLUTTER_JAR" ] && command -v flutter >/dev/null 2>&1; then
  BIN=$(readlink -f "$(command -v flutter)" 2>/dev/null || command -v flutter)
  for c in "$(dirname "$BIN")/cache/artifacts/engine/android-arm64/flutter.jar" \
           "$(dirname "$BIN")/cache/artifacts/engine/android-arm/flutter.jar" \
           "$(dirname "$BIN")/cache/artifacts/engine/android-x64/flutter.jar"; do
    [ -f "$c" ] && { FLUTTER_JAR="$c"; break; }
  done
fi
[ -f "${FLUTTER_JAR:-}" ] || { echo 'SKIP: 找不到 flutter.jar（设 FLUTTER_JAR）'; exit 0; }

# ---------------------------------------------------------------- 找第三方 jar
FX_KT_LIBS="${FX_KT_LIBS:-}"
if [ -z "$FX_KT_LIBS" ] || [ ! -d "$FX_KT_LIBS" ]; then
  echo 'SKIP: 没给 FX_KT_LIBS（media3 / okhttp / okio / guava / annotation 的 jar 目录）'
  exit 0
fi
JARS=$(ls "$FX_KT_LIBS"/*.jar 2>/dev/null | tr '\n' ':')
[ -n "$JARS" ] || { echo "SKIP: $FX_KT_LIBS 里没有 jar"; exit 0; }
[ -f "$API_JAR" ] && JARS="$JARS$API_JAR:"

# ---------------------------------------------------------------- R 桩
# 真机资源由 tools/patch_manifest.py 生成；这里只给 kotlinc 一个占位的 R。
mkdir -p "$TMP/rstub/com/huanxiang/fantasy_tv"
cat > "$TMP/rstub/com/huanxiang/fantasy_tv/R.kt" <<'KT'
package com.huanxiang.fantasy_tv

object R {
    object drawable { const val ic_stat_fx_play: Int = 1 }
    object string { const val fx_bg_channel: Int = 2 }
}
KT

TARGET="${KOTLIN_COMPILE_TARGET:-}"
if [ -n "$TARGET" ]; then
  SOURCES=("$ROOT/$TARGET")
else
  SOURCES=("$SRC_DIR"/*.kt)
fi

mkdir -p "$TMP/out"
CP="$ANDROID_JAR:$JARS${STDLIB:+:$STDLIB}"
# PATH 里的 kotlinc（发行版）会自己带 stdlib，不能再传 -no-stdlib；
# embeddable 编译器则必须显式给 -no-stdlib + 手拼 stdlib。
STD_ARGS=()
case "${COMPILER[0]}" in
  java) STD_ARGS=(-no-stdlib) ;;
esac
"${COMPILER[@]}" -nowarn -jvm-target 17 "${STD_ARGS[@]}" -classpath "$CP" \
  -d "$TMP/out" "$TMP/rstub/com/huanxiang/fantasy_tv/R.kt" "${SOURCES[@]}" \
  2>&1 | grep -v '^warning:' | head -40

COUNT=$(find "$TMP/out/com/huanxiang/fantasy_tv" -name '*.class' 2>/dev/null | wc -l)
if [ "$COUNT" -lt 1 ]; then
  echo "FAIL: kotlinc 编译失败（android.jar=$ANDROID_JAR jars=${#JARS} 字节）"
  exit 1
fi
echo "Kotlin 编译通过：$(echo "${SOURCES[@]}" | wc -w) 个源文件 -> $COUNT 个 class"
echo "  android.jar : $ANDROID_JAR"
echo "  flutter.jar : $FLUTTER_JAR"

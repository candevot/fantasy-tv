#!/usr/bin/env bash
# BG_GATE（2026-11-15）的 JVM 单测。
#
# 验什么：`BgGate.kt` 这套「能不能起服务 / 能不能进前台」的判定在
#   · Android 14/15/16/17（类型 + 权限 + 通知权限三道闸）
#   · Android 13（通知权限）
#   · Android 12 及以下（不该被新规则挡住）
#   · uncaught 环境兜底（必须 fail-closed）
# 上分别给出正确结论。任何一条被改松，这里立刻红 —— 不用等真机闪退。
#
# 没有 kotlinc 的环境（典型 CI runner）直接 SKIP，不算失败：
# 真正拦回归的是同一步里的 `tools/check_bg_foreground.py` 和 Gradle 编译。
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
ROOT=$(pwd)
SRC="$ROOT/android_src/kotlin/com/huanxiang/fantasy_tv/BgGate.kt"
TEST_SRC="$ROOT/tools/bg_gate_jvm_test.kt"
TMP=$(mktemp -d 2>/dev/null || mktemp -d -t bggate)
trap 'rm -rf "$TMP"' EXIT

# 两种编译器来源，命令行不一样，必须分开处理：
#   · KOTLIN_COMPILER_JAR（embeddable，本地 / 无发行版时）：自己拼 classpath，
#     并且要显式带上 kotlin-stdlib.jar；
#   · PATH 里的 kotlinc（发行版，CI runner 上就是它）：用 -include-runtime 打
#     成可执行 jar，stdlib 由它自己带 —— 否则 java 一启动就是
#     NoClassDefFoundError: kotlin/jvm/internal/Intrinsics。
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
  if [ ! -f "$TMP/out/Bg_gate_jvm_testKt.class" ]; then
    echo 'FAIL: BG_GATE 单测编译失败'
    exit 1
  fi
  java -cp "$TMP/out:$STDLIB" Bg_gate_jvm_testKt
elif command -v kotlinc >/dev/null 2>&1; then
  echo "compiler: $(command -v kotlinc)"
  kotlinc -nowarn -include-runtime -d "$TMP/bg_gate.jar" "$SRC" "$TEST_SRC" 2>&1 \
    | grep -v '^warning:' | head -20
  if [ ! -f "$TMP/bg_gate.jar" ]; then
    echo 'FAIL: BG_GATE 单测编译失败'
    exit 1
  fi
  java -jar "$TMP/bg_gate.jar"
else
  echo 'SKIP: 没有 kotlinc（可用 KOTLIN_COMPILER_JAR 指定 kotlin-compiler jar）'
  exit 0
fi

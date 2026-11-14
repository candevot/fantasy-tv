#!/usr/bin/env bash
# 起播链路分段探测（本机 curl 版）—— 只当「服务端侧对照」，不是结论。
#
# 为什么留着它：App 内的「播放诊断」浮层报的是**客户端实测**（这才是用户
# 真正感受到的）。但如果客户端显示「清单 900ms」，你需要一个独立视角判断
# 是源站本身慢、还是我们这一侧多走了一跳：这个脚本把 DNS / TCP / TLS /
# 首字节 / 首片下载拆开量一遍，两边的数字对不上就说明问题在我们这边。
#
# 用法：
#   tools/fx_probe.sh 'https://host/path/index.m3u8'
#   tools/fx_probe.sh 'https://host/path/index.m3u8' 'Referer: https://host/'
#
# 输出示例（好线路 / 差线路对照）：
#   dns        12 ms
#   tcp        38 ms
#   tls        96 ms      ← 复用连接后这一档应该接近 0
#   ttfb      210 ms
#   manifest  221 ms  1 个变体 / 812 片 / ENDLIST
#   variant    58 ms  ← 清单里只有一个变体时，这两跳是串行的
#   seg1       74 ms  ← 首片；太慢就是取流慢，不是清单慢
set -u

url="${1:-}"
referer="${2:-}"
if [ -z "$url" ]; then
  echo "用法: $0 <m3u8 url> ['Referer: https://...']" >&2
  exit 2
fi

# -w 的 time_* 单位都是秒（小数），这里统一换算成毫秒。
fmt='%{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{http_code} %{size_download}'

measure() {
  local target="$1"
  local extra="${2:-}"
  if [ -n "$extra" ]; then
    curl -sS -o /dev/null -w "$fmt" -H "$extra" --max-time 20 "$target" 2>/dev/null
  else
    curl -sS -o /dev/null -w "$fmt" --max-time 20 "$target" 2>/dev/null
  fi
}

ms() { awk -v v="$1" 'BEGIN { printf "%.0f", v * 1000 }'; }

echo "== $url"
read -r dns tcp tls ttfb total code size <<EOF
$(measure "$url" "$referer")
EOF
echo "  http   $code  ${size}B"
echo "  dns       $(ms "$dns") ms"
echo "  tcp       $(ms "$tcp") ms   (= dns + 建连)"
echo "  tls       $(ms "$tls") ms   (= dns + TCP + TLS；http 源等于 tcp)"
echo "  ttfb      $(ms "$ttfb") ms"
echo "  total     $(ms "$total") ms"

# 抓一份清单做结构统计（master 几变体 / 多少片 / 有没有 ENDLIST）。
body=$(curl -sS --max-time 20 ${referer:+-H "$referer"} "$url" 2>/dev/null || true)
if [ -z "$body" ]; then
  echo "  清单正文抓取失败（跳过结构统计）"
  exit 0
fi
variants=$(printf '%s\n' "$body" | grep -c '^#EXT-X-STREAM-INF' || true)
segs=$(printf '%s\n' "$body" | grep -v '^#' | grep -c . || true)
endlist=$(printf '%s\n' "$body" | grep -c 'EXT-X-ENDLIST' || true)
echo "  结构   变体=$variants 分片=$segs ENDLIST=$endlist"

# master → 第一个变体（我们原来的阻塞式预归并就卡在这一次跳转上）。
if [ "$variants" -gt 0 ]; then
  next=$(printf '%s\n' "$body" | awk '/^#EXT-X-STREAM-INF/{f=1;next} f&&NF&&!/^#/{print;exit}')
  case "$next" in
    http*) variant_url="$next" ;;
    /*)    variant_url="$(printf '%s' "$url" | sed -E 's#^(https?://[^/]+).*#\1#')$next" ;;
    *)     variant_url="$(printf '%s' "$url" | sed -E 's#[^/]*$##')$next" ;;
  esac
  read -r d2 t2 l2 f2 tot2 code2 size2 <<EOF
$(measure "$variant_url" "$referer")
EOF
  echo "  变体    $(ms "$f2") ms 首字节（$code2）  $variant_url"
  vbody=$(curl -sS --max-time 20 ${referer:+-H "$referer"} "$variant_url" 2>/dev/null || true)
  first=$(printf '%s\n' "$vbody" | awk 'NF&&!/^#/{print;exit}')
  if [ -n "$first" ]; then
    case "$first" in
      http*) seg_url="$first" ;;
      /*)    seg_url="$(printf '%s' "$variant_url" | sed -E 's#^(https?://[^/]+).*#\1#')$first" ;;
      *)     seg_url="$(printf '%s' "$variant_url" | sed -E 's#[^/]*$##')$first" ;;
    esac
    read -r d3 t3 l3 f3 tot3 code3 size3 <<EOF
$(measure "$seg_url" "$referer")
EOF
    echo "  首片    $(ms "$f3") ms 首字节 / $(ms "$tot3") ms 全部  ${size3}B（$code3）"
  fi
fi

cat <<'NOTE'

怎么读这些数字（和 App 内「播放诊断」对照）：
  · 客户端「解析」大 → hxparse / /api/play 那一跳慢，跟 DNS 无关；
  · 客户端「清单」大而这里 manifest 很小 → 是我们这一侧多走了一跳
    （老版本的阻塞式预归并，现在交给本地清单代理后应该消失）；
  · 客户端「首帧」大、清单小、首片也快 → 解码 / 渲染慢（看丢帧数）；
  · 客户端「连接数」> 2 → 连接池没复用，重点查 OkHttpClient 是不是被 new 了多次。
NOTE

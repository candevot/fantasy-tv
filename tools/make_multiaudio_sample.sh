#!/usr/bin/env bash
# 生成「多音轨 + AC3/EAC3/DTS/TrueHD」测试样本（FFMPEG_AUDIO / AUDIO_BITRATE，2026-11-19）。
#
# 为什么要这个脚本：验收「带 EAC3/AC3 的源能出声」「多音轨选最高码率」需要
# 一份**确定**的样本 —— 每条音轨的编码 / 码率 / 语言都是我们指定的，
# 选中哪条可以逐字对照，不依赖任何线上源（线上源随时会变、也会 404）。
#
# 产物（默认输出到 $OUT）：
#   multiaudio.mkv  渐进式，5 条音轨：
#                     #0 AAC    128k  2ch  eng   （码率未声明，用来验证 -1 不算最高）
#                     #1 AC3    384k  6ch  zho
#                     #2 EAC3   640k  6ch  eng
#                     #3 DTS   1536k  6ch  jpn   （只有 FFmpeg 能解）
#                     #4 TrueHD  未声明 6ch eng  （只有 FFmpeg 能解）
#   hls/            1080P HLS，一个 audiogroup 三条音轨（AAC 128k eng /
#                   AC3 384k zho / EAC3 640k eng），master 里带
#                   #EXT-X-MEDIA LANGUAGE，用来验证「按语言收窄 + 按码率选」。
#
# 用法：bash tools/make_multiaudio_sample.sh [输出目录]
# 需要系统 ffmpeg（>=6，带 ac3/eac3/dca/truehd 编码器；本机 6.1.1 验证过）。
set -euo pipefail

OUT=${1:-/tmp/fx-multiaudio}
mkdir -p "$OUT/hls"
cd "$OUT"

echo "== 1/2 渐进式 MKV（5 条音轨）-> $OUT/multiaudio.mkv"
ffmpeg -y -hide_banner -loglevel error \
  -f lavfi -i "testsrc2=s=640x360:r=25:d=10" \
  -f lavfi -i "sine=f=440:r=48000:d=10" \
  -f lavfi -i "sine=f=660:r=48000:d=10" \
  -f lavfi -i "sine=f=880:r=48000:d=10" \
  -f lavfi -i "sine=f=220:r=48000:d=10" \
  -f lavfi -i "sine=f=330:r=48000:d=10" \
  -map 0:v -map 1:a -map 2:a -map 3:a -map 4:a -map 5:a \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p -b:v 800k \
  -c:a:0 aac -b:a:0 128k -ac:a:0 2 -metadata:s:a:0 language=eng -metadata:s:a:0 title="AAC 128k ENG" \
  -c:a:1 ac3 -b:a:1 384k -ac:a:1 6 -metadata:s:a:1 language=zho -metadata:s:a:1 title="AC3 384k ZHO" \
  -c:a:2 eac3 -b:a:2 640k -ac:a:2 6 -metadata:s:a:2 language=eng -metadata:s:a:2 title="EAC3 640k ENG" \
  -c:a:3 dca -strict -2 -b:a:3 1536k -ac:a:3 6 -metadata:s:a:3 language=jpn -metadata:s:a:3 title="DTS 1536k JPN" \
  -c:a:4 truehd -strict -2 -ac:a:4 6 -metadata:s:a:4 language=eng -metadata:s:a:4 title="TrueHD ENG" \
  multiaudio.mkv

echo "== 2/2 1080P HLS（一个 audigroup，三条音轨）-> $OUT/hls/"
ffmpeg -y -hide_banner -loglevel warning \
  -f lavfi -i "testsrc2=s=1920x1080:r=25:d=8" \
  -f lavfi -i "sine=f=440:r=48000:d=8" \
  -f lavfi -i "sine=f=660:r=48000:d=8" \
  -f lavfi -i "sine=f=880:r=48000:d=8" \
  -map 0:v -map 1:a -map 2:a -map 3:a \
  -c:v libx264 -preset ultrafast -profile:v main -b:v 2500k -g 50 -keyint_min 50 -sc_threshold 0 \
  -c:a:0 aac -b:a:0 128k -ac:a:0 2 \
  -c:a:1 ac3 -b:a:1 384k -ac:a:1 6 \
  -c:a:2 eac3 -b:a:2 640k -ac:a:2 6 \
  -f hls -hls_time 4 -hls_playlist_type vod -hls_segment_type mpegts \
  -var_stream_map "v:0,agroup:aud a:0,agroup:aud,language:eng,name:aud-aac a:1,agroup:aud,language:zho,name:aud-ac3 a:2,agroup:aud,language:eng,name:aud-eac3" \
  -master_pl_name master.m3u8 -hls_segment_filename "hls/v%v/seg%d.ts" "hls/v%v/index.m3u8"

echo ""
echo "== 音轨清单（验收要贴的就是这张表）=="
ffprobe -v error \
  -show_entries stream=index,codec_name,codec_type,bit_rate,channels:stream_tags=language,title \
  -of json multiaudio.mkv \
  | python3 -c '
import json, sys
for s in json.load(sys.stdin)["streams"]:
    if s.get("codec_type") != "audio":
        continue
    tags = s.get("tags", {})
    print("  #%s %-7s br=%-8s ch=%s lang=%-4s %s" % (
        s["index"], s.get("codec_name"), s.get("bit_rate", "unset"),
        s.get("channels"), tags.get("language", "-"), tags.get("title", "-")))
'
echo ""
echo "产物：$OUT/multiaudio.mkv ，$OUT/hls/master.m3u8"

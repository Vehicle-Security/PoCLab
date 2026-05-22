#!/usr/bin/env bash
LAB="$HOME/nginx-poc-lab"
POCLAB="/mnt/d/download/PoClab/PoCLab"
pkill -f "$LAB/nginx-" 2>/dev/null||true
sleep 1
"$LAB/nginx-1.23.1/sbin/nginx" -c "$LAB/conf/41741.conf"
python3 /mnt/d/download/PoClab/PoCLab/.nginx-poc-test/t41741.py
echo "41741_exit=$?" >"$LAB/t41741.result"
cat "$LAB/t41741.result"

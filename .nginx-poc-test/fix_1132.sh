#!/usr/bin/env bash
set -e
LAB="$HOME/nginx-poc-lab"
src="$LAB/nginx-1.13.2-src"
prefix="$LAB/nginx-1.13.2"
sed -i 's/cd\.current_salt\[0\] = ~salt\[0\];/cd.initialized = 0;/' "$src/src/os/unix/ngx_user.c"
cd "$src"
make -j"$(nproc)"
make install
test -x "$prefix/sbin/nginx" && echo "nginx 1.13.2 OK"

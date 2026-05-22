#!/usr/bin/env bash
unshare -Ur bash -c 'id; mkdir -p /data/files; ls -ld /data/files'

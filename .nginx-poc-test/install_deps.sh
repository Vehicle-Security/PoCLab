#!/usr/bin/env bash
echo '1' | sudo -S apt-get install -y -qq python3-pip python3-scapy
python3 -c "import scapy; print('scapy', scapy.__version__)"

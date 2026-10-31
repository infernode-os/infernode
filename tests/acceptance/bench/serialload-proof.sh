#!/bin/bash
# Prove #639's fix: load a kernel over the serial loader and see it boot.
#   serialload-proof.sh <kernel.img> <expected size>
K=$1; SZ=$2
for p in $(pgrep -f 'sercap.py'); do [ "$p" != "$$" ] && [ "$p" != "$PPID" ] && kill $p && echo "capture paused ($p)"; done; sleep 1
(cd ~/pitools && timeout 600 python3 -u serialboot.py "$K" /dev/ttyUSB0 > /tmp/serialboot.out 2>&1 &)
sleep 3; echo "loader host started; resetting the board over the console"; printf '\x14\x14r' > /dev/ttyUSB0
for i in $(seq 1 120); do sleep 5; if grep -q 'GO\|jumped\|timed out\|error\|SZ' /tmp/serialboot.out 2>/dev/null; then break; fi; done
echo "--- serialboot.py said:"; tail -6 /tmp/serialboot.out | cut -c1-120
(cd ~/pitools && setsid nohup python3 sercap.py > sercap.out 2>&1 &); sleep 1; echo "capture restarted ($(pgrep -f 'sercap.py' | head -1))"
echo "waiting for the loaded kernel to come up on the network"
for i in $(seq 1 36); do sleep 5; ping -c1 -W1 192.168.1.104 > /dev/null 2>&1 && break; done
sleep 15
cd /mnt/orin-ssd/pdfinn/github.com/infernode-os/infernode-bt/tests/acceptance && timeout 60 python3 -u -c "
from board import Board
o=Board('192.168.1.104').sh('ls -l /dev/bootimage', wait=1.5); print(o.strip())
print('PROOF:', 'the serial-loaded kernel is running' if '$SZ' in o else 'the running kernel is NOT the serial-loaded one')"

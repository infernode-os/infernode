#!/bin/bash
# hourly snapshot of the board's live allocations by call site (read-only on the board)
cd /tmp
while true; do
  sleep 3600
  f=~/pitools/soak/memtags/$(date +%F-%H%M).txt
  timeout 90 python3 -u ~/pitools/soak/slowsess.py 'cat /dev/memtags' > $f 2>&1
done

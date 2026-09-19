#!/bin/bash
# run an Inferno-side sh test and print its verdict; the emulator never exits by itself
cd /mnt/orin-ssd/pdfinn/github.com/infernode-os/infernode-bt
out=$(mktemp); ./emu/Linux/o.emu -c1 -r$PWD sh -c "sh $1; echo VERDICT-STATUS: \$status" > $out 2>&1 & pid=$!
for i in $(seq 1 ${2:-420}); do grep -q "^VERDICT-STATUS" $out && break; kill -0 $pid 2>/dev/null || break; sleep 1; done
sleep 1; kill $pid 2>/dev/null; wait $pid 2>/dev/null
grep -v "Sh\":killed" $out | tail -${3:-4}; rm -f $out

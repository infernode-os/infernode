#!/bin/bash
# run the early-failure Bluetooth test under gdb repeatedly; keep any run that faults
cd /mnt/orin-ssd/pdfinn/github.com/infernode-os/infernode-bt
D=/tmp/claude-1000/gdbloop; mkdir -p $D
for i in $(seq 1 ${1:-60}); do
  O=$D/run.$i
  timeout -s KILL 40 gdb -q -batch \
    -ex "handle SIGUSR1 nostop noprint pass" -ex "handle SIGUSR2 nostop noprint pass" \
    -ex "handle SIGPIPE nostop noprint pass" -ex "handle SIGALRM nostop noprint pass" \
    -ex "handle SIGCHLD nostop noprint pass" \
    -ex run -ex "bt 25" -ex "info registers pc sp x0 x1 x2" -ex "thread apply all bt 6" \
    --args ./emu/Linux/o.emu -c1 -r$PWD sh /tests/inferno/zz_early.sh > $O 2>&1
  if grep -q "SIGSEGV\|SIGBUS\|SIGABRT\|panic:" $O; then echo "run $i FAULT" >> $D/summary; else rm -f $O; fi
  echo "run $i done" >> $D/progress
done
echo finished >> $D/summary

#!/usr/bin/env python3
# Boot the bare-metal kernel under QEMU, type a few shell lines, and
# let it run for a while, streaming the serial console to a log. For
# hunting things that only show up under sustained load: the Dis
# error-stack imbalance (#622) reproduces in about five minutes with
#
#   tools/qemu-soak.py $BUILD/bcm2837-kernel.img $BUILD/bcm2837-sd.img 1800 soak.log \
#     "{while {~ 1 1} {echo a > /tmp/a; cat /tmp/a > /dev/null; ls -l /tmp/a > /dev/null; rm /tmp/a}} &" \
#     "{while {~ 1 1} {cat /dis/sh.dis > /tmp/c; cat /tmp/c | cat > /dev/null; rm /tmp/c}} &" \
#     "{while {~ 1 1} {mkdir /tmp/dd; echo y > /tmp/dd/e; mv /tmp/dd/e /tmp/dd/f; rm /tmp/dd/f; rm /tmp/dd}} &"
#
# then grep the log for "vmachine:" and "poperror: label". Not a test:
# nothing here decides pass or fail. The kernel and card images are
# what tests/host/baremetal_test.sh builds.
import subprocess, sys, time, threading, os

kernel, sd, secs, log = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
cmds = sys.argv[5:]
p = subprocess.Popen([os.path.expanduser("~/.local/bin/qemu-system-aarch64"), "-M", "raspi3b",
                      "-netdev", "user,id=n0", "-device", "usb-net,netdev=n0,id=usbnet0",
                      "-drive", "file=%s,if=sd,format=raw" % sd,
                      "-kernel", kernel, "-display", "none",
                      "-serial", "null", "-serial", "stdio"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
buf = bytearray()
out = open(log, "ab", buffering=0)
def reader():
    while True:
        d = p.stdout.read(1)
        if not d:
            return
        buf.extend(d)
        out.write(d)
threading.Thread(target=reader, daemon=True).start()
deadline = time.time() + 120
while time.time() < deadline:
    if b"init: starting the shell" in buf:
        break
    time.sleep(0.2)
time.sleep(2)
for c in cmds:
    p.stdin.write(c.encode() + b"\r"); p.stdin.flush()
    time.sleep(1.0)
end = time.time() + secs
while time.time() < end and p.poll() is None:
    time.sleep(5)
p.kill(); p.wait()
print("soak done; %d bytes of console" % len(buf))

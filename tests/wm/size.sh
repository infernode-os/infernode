#!/dis/sh.dis
#
# One program from dis/wm under wm/wm, for tests/host/wm_size_test.sh:
# the program named in $app is started in a name space of its own (a
# wm/wm run as a client makes its own /chan/uitest, which would hide
# this one's), and the windows (a read of /chan/uitest: id minx miny
# maxx maxy, topmost first) are printed as "R win ..." (not a test:
# the runner runs every script in tests/inferno).
#
load std
sleep 1
@{pctl forkns; $app} &
sleep 6
echo R win `{cat /chan/uitest}
echo halt > '#c/sysctl'

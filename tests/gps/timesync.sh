#!/dis/sh.dis
#
# gpsfs's time file and timesync(8), for tests/host/timesync_test.sh
# (not a test: the runner runs every script in tests/inferno).  $1 is
# the test's directory, $2 the UDP port a fake gateway sends NMEA to,
# its clock an hour ahead.  What each step gives is written beside it.
#
load std

d=$1
@{pctl newpgrp; gpsfs}
# a port listened to is anyone's to send to: its times are not offered
# to the clock unless the source command says sync
echo source udp!*!^$2 > /mnt/gps/ctl
sleep 3
cat /mnt/gps/time > $d/time.nosync
timesync -n 1 > $d/out.nosync >[2] $d/err.nosync
echo source udp!*!^$2 sync > /mnt/gps/ctl
sleep 3
cat /mnt/gps/ctl > $d/ctl.sync
cat /mnt/gps/time > $d/time.live
timesync -n 3 > $d/out.set >[2] $d/err.set
cat /dev/time > $d/clock.after
timesync -n 2 > $d/out.again >[2] $d/err.again

# from a name space that has not the mount: the posted files
@{pctl forkns; unmount /mnt/gps; timesync -n 1 -t 3600000000 > $d/out.posted >[2] $d/err.posted}

# -p in such a name space, and gpsfs gone and started again: the new
# one's posted files are mounted, and the errors stop
@{pctl forkns; unmount /mnt/gps; timesync -n 1 -p 1 > $d/out.remount >[2] $d/err.remount} &
sleep 3
kill -g Gpsfs > /dev/null
unmount /mnt/gps
sleep 3
@{pctl newpgrp; gpsfs}
echo source udp!*!^$2 sync > /mnt/gps/ctl
sleep 5
cat $d/err.remount > $d/err.remount.1
sleep 5
kill Timesync > /dev/null
cat $d/err.remount > $d/err.remount.2

# a recording's times are not set from
echo source $d/track.nmea > /mnt/gps/ctl
sleep 1
cat /mnt/gps/time > $d/time.recorded
timesync -n 1 > $d/out.recorded >[2] $d/err.recorded

# Times that are not the receiver's, as records scripted by
# tests/timerec.b (each reading of /chan/NAME the next of its script).
# The clock is an hour ahead of the host's from here.

# one sample in five a year ahead: the others decide
/dis/tests/timerec.dis t1 0 0 31536000 0 0
timesync -n 5 /chan/t1 > $d/out.median >[2] $d/err.median
cat /dev/time > $d/clock.median

# samples that agree on nothing
/dis/tests/timerec.dis t2 0 100 200
timesync -n 3 /chan/t2 > $d/out.disagree >[2] $d/err.disagree

# a hundred years back: before this system was built
/dis/tests/timerec.dis t3 -3155760000 -3155760000 -3155760000
timesync -n 1 /chan/t3 > $d/out.floor >[2] $d/err.floor
cat /dev/time > $d/clock.floor
/dis/tests/timerec.dis t3b -3155760000 -3155760000 -3155760000
timesync -n 1 -m 0 /chan/t3b > $d/out.floor0 >[2] $d/err.floor0
cat /dev/time > $d/clock.floor0

# ten days ahead of a clock that has been set: more than a step
/dis/tests/timerec.dis t4 864000
timesync -n 1 /chan/t4 > $d/out.bound >[2] $d/err.bound
cat /dev/time > $d/clock.bound
# allowed, it is taken; and back again
/dis/tests/timerec.dis t5 864000
timesync -n 1 -m 1000000 /chan/t5 > $d/out.allowed >[2] $d/err.allowed
cat /dev/time > $d/clock.allowed
/dis/tests/timerec.dis t6 -864000
timesync -n 1 -m 0 /chan/t6 > $d/out.back >[2] $d/err.back
cat /dev/time > $d/clock.back

# a record that does not say its offset; a file with nothing in it yet
/dis/tests/timerec.dis t7 nooffset nooffset nooffset
timesync -n 1 /chan/t7 > $d/out.nooffset >[2] $d/err.nooffset
/dis/tests/timerec.dis t8 empty
timesync -n 1 /chan/t8 > $d/out.empty >[2] $d/err.empty

# this host's clock cannot be read: said, and nothing set
/dis/tests/timerec.dis t10 0
@{pctl forkns; bind $d/empty /dev; timesync -n 1 /chan/t10 > $d/out.noclock >[2] $d/err.noclock}

# one record an hour behind and then no more, as when the receiver goes:
# applied once, however often it is looked at
/dis/tests/timerec.dis t9 -3600
timesync -n 1 -p 2 /chan/t9 > $d/out.stale >[2] $d/err.stale &
sleep 9
kill Timesync
cat /dev/time > $d/clock.stale
echo R done
echo halt > '#c/sysctl'

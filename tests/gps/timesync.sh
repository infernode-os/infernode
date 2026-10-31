#!/dis/sh.dis
#
# gpsfs's time file and timesync(8), for tests/host/timesync_test.sh
# (not a test: the runner runs every script in tests/inferno).  $1 is
# the test's directory, $2 the UDP port a fake gateway sends NMEA to,
# its clock an hour ahead.  What each step gives is written beside it.
#
load std

d=$1
gpsfs
echo source udp!*!^$2 > /mnt/gps/ctl
sleep 3
cat /mnt/gps/time > $d/time.live
timesync -n 3 > $d/out.set >[2] $d/err.set
cat /dev/time > $d/clock.after
timesync -n 2 > $d/out.again >[2] $d/err.again

# from a name space that has not the mount: the posted files
@{pctl forkns; unmount /mnt/gps; timesync -n 1 -t 3600000000 > $d/out.posted >[2] $d/err.posted}

# a recording's times are not set from
echo source $d/track.nmea > /mnt/gps/ctl
sleep 1
cat /mnt/gps/time > $d/time.recorded
timesync -n 1 > $d/out.recorded >[2] $d/err.recorded
echo R done
echo halt > '#c/sysctl'

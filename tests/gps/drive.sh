#!/dis/sh.dis
#
# gpsfs driven through its files, for tests/host/gpsfs_test.sh (not a
# test: the runner runs every script in tests/inferno).  $1 is the
# test's directory, holding track.nmea; $2 the port of a fake NMEA feed,
# $3 of a fake gpsd.  What each step gives is written beside it.  A
# write refused ends the shell it is in, so each that may be is made in
# a shell of its own.
#
load std

d=$1
g=/mnt/gps
gpsfs
ls $g > $d/ls
cat $g/status > $d/status.start

# a log read as a source, whole: the last fix, satellites, the command
echo source $d/track.nmea > $g/ctl
sleep 1
cat $g/ctl > $d/ctl.file
cat $g/fix > $d/fix.file
cat $g/position > $d/position.file
cat $g/satellites > $d/satellites.file
cat $g/status > $d/status.file

# replayed at the pace of its times; event and nmea follow it
cat $g/event > $d/events &
cat $g/nmea > $d/nmea &
sleep 1
echo replay $d/track.nmea > $g/ctl
sleep 1
wc -l < $d/events > $d/events.early
sleep 3
wc -l < $d/events > $d/events.late

# a network feed, and gpsd
sh -c 'echo source tcp!127.0.0.1!'^$2^' > '^$g^'/ctl' >[2] $d/err.tcp
sleep 1
cat $g/position > $d/position.tcp
sh -c 'echo source gpsd 127.0.0.1!'^$3^' > '^$g^'/ctl' >[2] $d/err.gpsd
sleep 1
cat $g/position > $d/position.gpsd
cat $g/status > $d/status.gpsd

# refusals
sh -c 'echo source '^$d^'/track.nmea 4800 > '^$g^'/ctl' >[2] $d/err.baud
sh -c 'echo source /nonexistent > '^$g^'/ctl' >[2] $d/err.missing
sh -c 'echo bogus > '^$g^'/ctl' >[2] $d/err.bogus
sh -c 'echo source x 4k8 > '^$g^'/ctl' >[2] $d/err.badbaud
sh -c 'echo ''$GPRMC,1,A*00'' > '^$g^'/feed' >[2] $d/err.feed

echo stop > $g/ctl
cat $g/ctl > $d/ctl.stop
cat $g/status > $d/status.stop

# fed: a fix lost and found again, as event tells it
cat $g/event > $d/events.feed &
sleep 1
cat $d/feed.nmea > $g/feed
sleep 1
sh -c 'cat '^$g^'/position' > $d/position.lost >[2] $d/err.lost

gpsfs >[2] $d/again
echo R done
echo halt > '#c/sysctl'

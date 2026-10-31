#!/dis/sh.dis
#
# #g, the host's location service, for tests/host/location_test.sh
# (not a test: the runner runs every script in tests/inferno).  $1 is
# the test's directory; what each step gives is written beside it.  The
# emulator is started with or without $INFERNODE_LOCATION_FAKE.
#
load std

d=$1
ls '#g' > $d/ls
cat '#g/status' > $d/status.before
if {~ $2 fake} {
	cat '#g/nmea' > $d/raw &
	catpid=$apid
	sleep 2
	cat '#g/status' > $d/status.reading
	gpsfs source '#g/nmea'
	sleep 3
	cat /mnt/gps/fix > $d/fix
	echo stop > /mnt/gps/ctl
	cat '#g/status' > $d/status.onestill
	kill $catpid
	sleep 1
	cat '#g/status' > $d/status.after
} {
	sh -c 'cat ''#g/nmea''' >[2] $d/err.open
}
echo R done
echo halt > '#c/sysctl'

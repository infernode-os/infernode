#!/dis/sh.dis
#
# sdrfs driven through its files, for tests/host/sdrfs_test.sh (not a
# test).  $1 is the test's directory; $2 the port of a fake rtl_tcp
# (tests/host/sdr/fake_rtl_tcp.py), $3 of something that is not
# rtl_tcp, $4 of nothing, $5 of an rtl_tcp busy with another client,
# $6 of one that sends two bytes at a time, $7 of one slow to greet.
# What each step gives is written beside it.
# A write that may be refused is made in a shell of its own.
#
load std

d=$1
s=/mnt/sdr
sdrfs -w 2 -l 2 -t 200
ls $s > $d/ls
cat $s/status > $d/status.start
cat $s/ctl > $d/ctl.start
sh -c 'cat '^$s^'/iq' > $d/iq.nosource >[2] $d/err.nosource

# settings before any source are kept, and sent when it is dialled
echo freq 1090M > $s/ctl
echo 'rate 250000
gain 38' > $s/ctl
echo ppm -3 > $s/ctl

# a source: dialled to see it is rtl_tcp, its settings sent, held
echo source 127.0.0.1!$2 > $s/ctl
sleep 1
cat $s/status > $d/status.idle
cat $s/ctl > $d/ctl.source
cat $s/gains > $d/gains

# a reader within -l takes the held connection: the header first, by
# itself, then reads give whole samples
{read 64 > $d/iq.hdr; read 16384 > $d/iq.1; read 16384 > $d/iq.2; read 16384 > $d/iq.3} < $s/iq
sleep 1
cat $s/status > $d/status.closed1
# -l after the last reader: hung up
sleep 3
cat $s/status > $d/status.hungup

# two readers; a setting written while they read is sent at once.  One
# the header does not say ends nothing; a retune ends both streams, and
# opened again they have the new header, with no dial
cat $s/iq > $d/iq.r1 &
p1=$apid
cat $s/iq > /dev/null &
p2=$apid
sleep 1
cat $s/status > $d/status.two
echo ppm -2 > $s/ctl
sleep 1
cat $s/status > $d/status.ppm
echo freq 162.025M > $s/ctl
sleep 1
cat $s/status > $d/status.retuned
cat $s/iq > $d/iq.r2 &
p1=$apid
cat $s/iq > /dev/null &
p2=$apid
echo biastee on > $s/ctl
echo direct off > $s/ctl
sleep 1
kill $p1 $p2 >[2] /dev/null
sleep 1
cat $s/status > $d/status.gone
sleep 3
cat $s/status > $d/status.gone2

# a reader that does not read falls behind and loses the oldest
echo rate 2.4M > $s/ctl
{sleep 6; read 64 > /dev/null; read 16384 > $d/iq.late} < $s/iq
cat $s/status > $d/status.dropped

# refusals
sh -c 'echo source 127.0.0.1!'^$3^' > '^$s^'/ctl' >[2] $d/err.notrtl
sh -c 'echo source 127.0.0.1!'^$4^' > '^$s^'/ctl' >[2] $d/err.nothing
sh -c 'echo source 127.0.0.1!'^$5^' > '^$s^'/ctl' >[2] $d/err.busy
cat $s/ctl > $d/ctl.refused
sh -c 'echo freq 0 > '^$s^'/ctl' >[2] $d/err.freq
sh -c 'echo rate 500000 > '^$s^'/ctl' >[2] $d/err.rate
sh -c 'echo gain loud > '^$s^'/ctl' >[2] $d/err.gain
sh -c 'echo direct x > '^$s^'/ctl' >[2] $d/err.direct
sh -c 'echo enc s16 > '^$s^'/ctl' >[2] $d/err.enc
echo enc cu8 > $s/ctl
sh -c 'echo bogus 1 > '^$s^'/ctl' >[2] $d/err.bogus
sh -c 'echo ''freq 98M
rate 1'' > '^$s^'/ctl' >[2] $d/err.half
cat $s/ctl > $d/ctl.after

# localhost is 127.0.0.1, with no connection server
sh -c 'echo source localhost!'^$2^' > '^$s^'/ctl' >[2] $d/err.localhost
cat $s/ctl > $d/ctl.localhost

echo stop > $s/ctl
cat $s/status > $d/status.stop

# a server that is not posted ends whole with its mount: its stream's
# reader, its connection to rtl_tcp and its timers with it
ps | grep Sdrfs | wc -l > $d/procs.before
sdrfs -S -m $d/m2
sh -c 'echo source 127.0.0.1!'^$2^' > '^$d^'/m2/ctl' >[2] $d/err.unposted
read 4096 < $d/m2/iq > /dev/null
ps | grep Sdrfs | wc -l > $d/procs.during
# a setting written over and over while rtl_tcp is still applying the
# last is sent once, as it then is: twelve in one write, twenty writes
sleep 2
echo 'freq 101000001
freq 101000002
freq 101000003
freq 101000004
freq 101000005
freq 101000006
freq 101000007
freq 101000008
freq 101000009
freq 101000010
freq 101000011
freq 101000012' > $d/m2/ctl
for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 { echo freq 2000000$i > $d/m2/ctl }
cat $d/m2/ctl > $d/ctl.knob
sleep 2
unmount $d/m2
sleep 2
ps | grep Sdrfs | wc -l > $d/procs.after

# an rtl_tcp that sends two bytes at a time: given in chunks
sdrfs -S -m $d/m3 -t 200
sh -c 'echo source 127.0.0.1!'^$6^' > '^$d^'/m3/ctl' >[2] $d/err.trickle
read 16384 < $d/m3/iq > $d/iq.trickle
unmount $d/m3

# a source command given up (its writer killed) is not done
sdrfs -S -m $d/m4
sh -c 'echo source 127.0.0.1!'^$7^' > '^$d^'/m4/ctl' >[2] /dev/null &
p=$apid
sleep 1
kill $p > /dev/null
sleep 3
cat $d/m4/status > $d/status.givenup
cat $d/m4/ctl > $d/ctl.givenup
unmount $d/m4

sdrfs >[2] $d/again
echo R done
echo halt > '#c/sysctl'

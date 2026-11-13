#!/dis/sh.dis
#
# sdrfs driven through its files, for tests/host/sdrfs_test.sh (not a
# test).  $1 is the test's directory; $2 the port of a fake rtl_tcp
# (tests/host/sdr/fake_rtl_tcp.py), $3 of something that is not
# rtl_tcp, $4 of nothing, $5 of an rtl_tcp busy with another client.
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

# a reader within -l takes the held connection; its header first, in a
# read of its own, then reads give whole samples
{read 16384 > $d/iq.hdr; read 16384 > $d/iq.1; read 16384 > $d/iq.2; read 16384 > $d/iq.3} < $s/iq
sleep 1
cat $s/status > $d/status.closed1
# -l after the last reader: hung up
sleep 3
cat $s/status > $d/status.hungup

# two readers; a setting written while they read is sent at once.  A
# gain ends neither; a frequency ends both, each after what it had
# queued, and a reopen has the new one in its header, on the held
# connection
{cat $s/iq > $d/iq.two1; echo ended > $d/ended.two1} &
{cat $s/iq > /dev/null; echo ended > $d/ended.two2} &
sleep 1
cat $s/status > $d/status.two
echo gain 20 > $s/ctl
sleep 1
cat $s/status > $d/status.gain
echo freq 162.025M > $s/ctl
echo biastee on > $s/ctl
echo direct off > $s/ctl
sleep 1
cat $s/status > $d/status.retune
cat $d/ended.two1 $d/ended.two2 > $d/ended.retune
sdr/iqhdr < $d/iq.two1 > $d/iqhdr.two1
read 16384 < $s/iq > $d/hdr.retuned
sleep 1
cat $s/status > $d/status.gone
sleep 3
cat $s/status > $d/status.gone2

# a reader that does not read falls behind and loses the oldest
echo rate 2.4M > $s/ctl
{sleep 6; read 16384 > /dev/null; read 16384 > $d/iq.late} < $s/iq
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
sh -c 'echo bogus 1 > '^$s^'/ctl' >[2] $d/err.bogus
sh -c 'echo enc cs16 > '^$s^'/ctl' >[2] $d/err.enc
sh -c 'echo enc cu8 > '^$s^'/ctl' >[2] $d/err.enccu8
sh -c 'echo ''freq 98M
rate 1'' > '^$s^'/ctl' >[2] $d/err.half
cat $s/ctl > $d/ctl.after

# localhost is 127.0.0.1, with no connection server
sh -c 'echo source localhost!'^$2^' > '^$s^'/ctl' >[2] $d/err.localhost
cat $s/ctl > $d/ctl.localhost

# a recording's header tunes the radio back to it
sdr/iqhdr < $d/iq.two1 > $s/ctl
cat $s/ctl > $d/ctl.iqhdr

echo stop > $s/ctl
cat $s/status > $d/status.stop

sdrfs >[2] $d/again
echo R done
echo halt > '#c/sysctl'

#!/dis/sh.dis
#
# sdr(1)'s demodulators driven, for tests/host/sdr_demod_test.sh (not a
# test).  $1 is the test's directory, holding synthetic samples
# (tests/host/sdr/synth_iq.py); $2 the port of a fake rtl_tcp serving
# wfm.u8.  What each step gives is written beside it.
#
load std

d=$1

sdr/fm -r 2.4M -o 48000 < $d/wfm.u8 > $d/wfm.pcm
sdr/fm -r 2.4M < $d/wfm.u8 > $d/wfm8.pcm
sdr/fm -r 2.4M -o 22050 < $d/wfm.u8 > $d/wfm22.pcm
sdr/fm -n -r 2048000 -o 22050 < $d/nfm.u8 > $d/nfm.pcm
sdr/am -r 2.4M -o 22050 -c 1 < $d/am.u8 > $d/am.pcm

# refusals
sh -c 'sdr/fm -r 10k -o 22050 < /dev/null' >[2] $d/err.low
sh -c 'sdr/fm -r fast < /dev/null' >[2] $d/err.rate
sh -c 'sdr/am -b 5 < /dev/null' >[2] $d/err.bw

# through sdrfs from a (fake) rtl_tcp, as a radio is listened to
sdrfs -l 1 -t 100
echo source 127.0.0.1!$2 > /mnt/sdr/ctl
echo rate 2.4M > /mnt/sdr/ctl
sdr/fm -r 2.4M -o 48000 < /mnt/sdr/iq > $d/live.pcm &
p=$apid
sleep 4
cat /mnt/sdr/status > $d/status.live
kill $p > /dev/null
echo R done
echo halt > '#c/sysctl'

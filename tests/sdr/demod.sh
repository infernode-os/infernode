#!/dis/sh.dis
#
# sdr(1)'s demodulators driven, for tests/host/sdr_demod_test.sh (not a
# test).  $1 is the test's directory, holding synthetic samples with no
# header (tests/host/sdr/synth_iq.py); $2 the port of a fake rtl_tcp
# serving wfm.u8.  What each step gives is written beside it.
#
load std

d=$1

# headers put on with sdr/rawiq, and read back with sdr/iqhdr
sdr/rawiq -r 2.4M -f 98M < $d/wfm.u8 > $d/wfm.iq
sdr/iqhdr < $d/wfm.iq > $d/wfm.hdr
sdr/rawiq -r 2048000 < $d/nfm.u8 > $d/nfm.iq
sdr/iqhdr $d/nfm.iq > $d/nfm.hdr

# -R: the sound alone; the rate in from the header
sdr/fm -R -o 48000 < $d/wfm.iq > $d/wfm.pcm
sdr/fm -R < $d/wfm.iq > $d/wfm8.pcm
sdr/fm -R -o 22050 < $d/wfm.iq > $d/wfm22.pcm
sdr/fm -R -n -o 22050 < $d/nfm.iq > $d/nfm.pcm
sdr/rawiq -r 2.4M < $d/am.u8 | sdr/am -R -o 22050 -c 1 > $d/am.pcm

# audio(6)'s header on the sound, read by auplay's own parse (as
# auplay, named otherwise, prints the header it would set)
sdr/fm -o 22050 < $d/wfm.iq > $d/wfm.au
sdr/rawiq -r 2.4M < $d/am.u8 | sdr/am -o 8000 -c 1 > $d/am.au
cp /dis/auplay.dis $d/auhdr.dis
$d/auhdr.dis $d/wfm.au >[2] $d/auhdr.fm
$d/auhdr.dis $d/am.au >[2] $d/auhdr.am

# refusals
sh -c 'sdr/fm -o 22050 < '^$d^'/wfm.u8' >[2] $d/err.nohdr
sh -c 'sdr/am < '^$d^'/am.u8' >[2] $d/err.amnohdr
sh -c 'sdr/fm < /dev/null' >[2] $d/err.empty
echo 'rate 2400000
enc cs16
' > $d/s16.iq
sh -c 'sdr/fm < '^$d^'/s16.iq' >[2] $d/err.enc
sh -c 'sdr/am < '^$d^'/s16.iq' >[2] $d/err.amenc
sh -c 'sdr/rawiq -r 10k < /dev/null | sdr/fm -o 22050' >[2] $d/err.low
sh -c 'sdr/fm -r 2.4M < /dev/null' >[2] $d/err.r
sh -c 'sdr/rawiq -r fast < /dev/null' >[2] $d/err.rate
sh -c 'sdr/rawiq < /dev/null' >[2] $d/err.norate
sh -c 'sdr/am -b 5 < /dev/null' >[2] $d/err.bw
sh -c 'sdr/iqhdr < '^$d^'/wfm.u8' >[2] $d/err.iqhdr

# through sdrfs from a (fake) rtl_tcp, as a radio is listened to: the
# rate from iq's header, and sdr/fm ending with the stream at a retune
sdrfs -l 1 -t 100
echo source 127.0.0.1!$2 > /mnt/sdr/ctl
echo rate 2.4M > /mnt/sdr/ctl
{sdr/fm -R -o 48000 < /mnt/sdr/iq > $d/live.pcm; echo ended $status > $d/live.ended} &
sleep 4
cat /mnt/sdr/status > $d/status.live
echo freq 99M > /mnt/sdr/ctl
sleep 1
cat $d/live.ended > $d/live.end
echo R done
echo halt > '#c/sysctl'

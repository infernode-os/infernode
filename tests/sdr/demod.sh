#!/dis/sh.dis
#
# sdr(1)'s demodulators driven, for tests/host/sdr_demod_test.sh (not a
# test).  $1 is the test's directory, holding synthetic samples with no
# header (tests/host/sdr/synth_iq.py); $2 the port of a fake rtl_tcp
# serving wfm.u8.  What each step gives is written beside it.
#
load std

d=$1

# headerless captures given their rate once, by sdr/rawiq; -R: raw sound
sdr/rawiq -r 2.4M -f 99.5M < $d/wfm.u8 > $d/wfm.iq
sdr/fm -R -o 48000 < $d/wfm.iq > $d/wfm.pcm
sdr/fm -R < $d/wfm.iq > $d/wfm8.pcm
sdr/rawiq -r 2.4M < $d/wfm.u8 | sdr/fm -R -o 22050 > $d/wfm22.pcm
sdr/rawiq -r 2048000 < $d/nfm.u8 | sdr/fm -n -R -o 22050 > $d/nfm.pcm
sdr/rawiq -r 2.4M < $d/am.u8 | sdr/am -R -o 22050 -c 1 > $d/am.pcm
# the sound's own header (audio(6))
sdr/fm -o 48000 < $d/wfm.iq > $d/wfm.au
sdr/rawiq -r 2.4M < $d/am.u8 | sdr/am -o 22050 -c 1 > $d/am.au
# the header split across reads: one byte at a time through a pipe
sdr/rawiq -r 2.4M < $d/am.u8 > $d/am.iq
{read 1; read 1; read 1; read 5; read 3; cat} < $d/am.iq | sdr/am -R -o 22050 -c 1 > $d/amsplit.pcm
sdr/iqhdr < $d/wfm.iq > $d/iqhdr.out

# auplay takes the sound's header for audioctl, through a pipe
mkdir -p $d/dev
cp /dev/null $d/dev/audio
cp /dev/null $d/dev/audioctl
sh -c 'bind -b '^$d^'/dev /dev; sdr/fm -o 44100 < '^$d^'/wfm.iq | auplay /fd/0'

# refusals
sh -c 'sdr/rawiq -r 10k < /dev/null | sdr/fm -o 22050' >[2] $d/err.low
sh -c 'sdr/fm < '^$d^'/wfm.u8' >[2] $d/err.nohdr
sh -c 'sdr/fm < /dev/null' >[2] $d/err.empty
sh -c 'echo ''rate 2400000
enc s16
 
'' | sdr/fm' >[2] $d/err.enc
sh -c 'sdr/fm -r 2.4M < /dev/null' >[2] $d/err.r
sh -c 'sdr/rawiq -r fast < /dev/null' >[2] $d/err.rate
sh -c 'sdr/am -b 5 < /dev/null' >[2] $d/err.bw
sh -c 'sdr/iqhdr < '^$d^'/wfm.u8' >[2] $d/err.iqhdr

# through sdrfs from a (fake) rtl_tcp, as a radio is listened to
sdrfs -l 1 -t 100
echo source 127.0.0.1!$2 > /mnt/sdr/ctl
echo rate 2.4M > /mnt/sdr/ctl
sdr/fm -o 48000 < /mnt/sdr/iq > $d/live.au &
p=$apid
sleep 4
cat /mnt/sdr/status > $d/status.live
kill $p > /dev/null
# a recording's header retunes the radio
echo 'rate 1024000
freq 162025000' > /mnt/sdr/ctl
sdr/iqhdr < $d/wfm.iq > /mnt/sdr/ctl
cat /mnt/sdr/ctl > $d/ctl.iqhdr
echo R done
echo halt > '#c/sysctl'

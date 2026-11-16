load std

# brick pair -R with the draft's cleartext secret files still in keydir:
# -R replaces credentials that may have been read, and those files are
# where.  It deleted the factotum entries and then imported the files
# again, so the brick was given the old PSK and D2 key as the new ones.
# Then: the audit record of brick wifi, and a pair.lock left by a crash.

root=/tmp/brick-ft-test
mkdir -p /mnt/factotum $root/rl/config $root/rlprofile $root/rlaudit
auth/factotum -f $root/rl.keys -p testpass
sleep 1
echo RL-OLD-PIN
brick key -d $root/rlprofile
echo 5555555555555555555555555555555555555555555555555555555555555555 > $root/rlprofile/client.key
echo 6666666666666666666666666666666666666666666666666666666666666666 > $root/rlprofile/sdg.key
echo 7777777777777777777777777777777777777777777777777777777777777777 > $root/rlprofile/sdg.psk
echo 8888888888888888888888888888888888888888888888888888888888888888 > $root/rlprofile/d2.key
echo 9999999999999999999999999999999999999999999999999999999999999999 > $root/rl/config/spki
echo 'pub aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > $root/rl/config/sdg
echo initial > $root/rl/config/d2
echo initial > $root/rl/config/peer
echo initial > $root/rl/config/wifi
brick pair -R -d $root/rlprofile $root/rl
echo RL-SDG `{cat $root/rl/config/sdg}
echo RL-D2 `{cat $root/rl/config/d2}
if {ftest -e $root/rlprofile/client.key} {echo BAD-RL-CLIENT} {echo RL-GONE-CLIENT}
if {ftest -e $root/rlprofile/sdg.key} {echo BAD-RL-SDG} {echo RL-GONE-SDG}
if {ftest -e $root/rlprofile/sdg.psk} {echo BAD-RL-PSK} {echo RL-GONE-PSK}
if {ftest -e $root/rlprofile/d2.key} {echo BAD-RL-D2} {echo RL-GONE-D2}
echo RL-NEW-PIN
brick key -d $root/rlprofile

# brick key -R with a draft client.key back in place: a new identity,
# not the file's
echo 5555555555555555555555555555555555555555555555555555555555555555 > $root/rlprofile/client.key
echo RL-KEYR-PIN
brick key -R -d $root/rlprofile
if {ftest -e $root/rlprofile/client.key} {echo BAD-RL-KEYR-CLIENT} {echo RL-KEYR-GONE-CLIENT}

# the audit record of wifi: a file stands for the log
bind -c $root/rlaudit /mnt/audit
echo -n > /mnt/audit/log
echo 'ssid home pass hunter2hunter2' | brick wifi $root/rl
echo RL-AUDIT1 `{cat /mnt/audit/log}
echo -n > /mnt/audit/log
{echo 'ssid my home'; echo 'pass hunter2hunter2'} | brick wifi $root/rl
echo RL-AUDIT2 `{cat /mnt/audit/log}
unmount /mnt/audit

# a lock a killed emulator left: an old one is taken, a new one is not
touch -t 1000000000 $root/rlprofile/pair.lock
if {brick key -d $root/rlprofile >/dev/null} {echo RL-STALE-LOCK-TAKEN} {echo BAD-RL-STALE-LOCK}
touch $root/rlprofile/pair.lock
if {brick key -d $root/rlprofile >/dev/null} {echo BAD-RL-FRESH-LOCK} {echo RL-FRESH-LOCK-HELD}
rm $root/rlprofile/pair.lock
echo FACTOTUM-ROTATE-LEGACY-DONE
echo halt > '#c/sysctl'

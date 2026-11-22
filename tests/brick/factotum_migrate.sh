load std

root=/tmp/brick-ft-test
mkdir -p /mnt/factotum $root/migrate/config $root/migrateprofile
auth/factotum -f $root/migrate.keys -p testpass
sleep 1
# Establish the TLS bundle, then emulate the remaining draft-#1015 secret
# files.  client.key is deliberately also present: an already persisted TLS
# bundle must still cause the obsolete cleartext copy to be removed.
brick key -d $root/migrateprofile
echo 5555555555555555555555555555555555555555555555555555555555555555 > $root/migrateprofile/client.key
echo 6666666666666666666666666666666666666666666666666666666666666666 > $root/migrateprofile/sdg.key
echo 7777777777777777777777777777777777777777777777777777777777777777 > $root/migrateprofile/sdg.psk
echo 8888888888888888888888888888888888888888888888888888888888888888 > $root/migrateprofile/d2.key
echo 9999999999999999999999999999999999999999999999999999999999999999 > $root/migrate/config/spki
echo 'pub aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > $root/migrate/config/sdg
echo initial > $root/migrate/config/d2
echo initial > $root/migrate/config/peer
brick pair -d $root/migrateprofile $root/migrate
if {ftest -e $root/migrateprofile/client.key} {echo BAD-MIGRATE-CLIENT} {echo MIGRATED-CLIENT}
if {ftest -e $root/migrateprofile/sdg.key} {echo BAD-MIGRATE-SDG} {echo MIGRATED-SDG}
if {ftest -e $root/migrateprofile/sdg.psk} {echo BAD-MIGRATE-PSK} {echo MIGRATED-PSK}
if {ftest -e $root/migrateprofile/d2.key} {echo BAD-MIGRATE-D2} {echo MIGRATED-D2}
cat /mnt/factotum/ctl
echo FACTOTUM-MIGRATE-DONE
echo halt > '#c/sysctl'

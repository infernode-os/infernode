load std

root=/tmp/brick-ft-test
mkdir -p /mnt/factotum
auth/factotum -f $root/factotum.keys -p testpass
sleep 1
echo RELOAD-PIN
brick key -d $root/profile
cat /mnt/factotum/ctl
echo FACTOTUM-RELOAD-DONE
echo halt > '#c/sysctl'

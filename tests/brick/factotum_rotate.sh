load std

root=/tmp/brick-ft-test
mkdir -p /mnt/factotum
auth/factotum -f $root/factotum.keys -p testpass
sleep 1
echo OLD-PIN
brick key -d $root/profile
echo 'pub 2222222222222222222222222222222222222222222222222222222222222222' > $root/brick/config/sdg
brick pair -R -d $root/profile $root/brick
echo NEW-PIN
brick key -d $root/profile
cat /mnt/factotum/ctl
echo FACTOTUM-ROTATE-DONE
echo halt > '#c/sysctl'

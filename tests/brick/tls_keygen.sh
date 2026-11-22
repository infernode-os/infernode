load std

root=$1
mkdir -p /mnt/factotum $root
auth/factotum -f $root/factotum.keys -p testpass
sleep 1
brick key -d $root/k
brick key -d $root/other
echo TLS-KEYGEN-DONE
echo halt > '#c/sysctl'

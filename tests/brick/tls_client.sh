load std

root=$1
profile=$2
cert=$3
pin=$4
addr=$5
mkdir -p /mnt/factotum
auth/factotum -f $root/factotum.keys -p testpass
sleep 1
if {~ $profile -} {
	/dis/tests/tlspinclient.dis -p $pin $addr
} {
	if {~ $cert -} {
		/dis/tests/tlspinclient.dis -d $profile -p $pin $addr
	} {
		/dis/tests/tlspinclient.dis -d $profile -c $cert -p $pin $addr
	}
}
echo halt > '#c/sysctl'

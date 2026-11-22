load std

/dis/tests/tlspinclient.dis -V $1 -p $2
echo halt > '#c/sysctl'

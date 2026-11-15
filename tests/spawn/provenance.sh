#!/dis/sh.dis
#
# The spawn tool where the install requires auditing, through a real
# tools9p, auditfs and ventisrv, for
# tests/host/spawn_provenance_test.sh (not a test: the runner runs every
# script in tests/inferno).  $port is the provenance store's.  Each
# call's result is /tmp/r.<name> (what its write was refused with,
# /tmp/err.<name>), what the tool server says of the switch
# /tmp/meta.<name>, and the model's log after it /tmp/log.<name>.
#
load std

path=(/dis/veltro /dis/cmd /dis .)
mkdir -p /tmp/usr/inferno/audit /tmp/llm /tmp/venti /tmp/empty
bind -c /tmp/usr /usr
bind -a '#I' /net >[2] /dev/null
echo -n > /tmp/venti/data
echo -n > /tmp/venti/index
ventisrv -d /tmp/venti/data -i /tmp/venti/index -w tcp!127.0.0.1!$port 33554432 8192 &
/dis/tests/spawnfake.dis llm /tmp/llm /tmp/llm.log &
sleep 1
bind /tmp/llm /mnt/llm

# the install requires auditing, and its sink and store are there
echo -n > /usr/inferno/audit/on
mount {auditfs} /mnt/audit
auditventi=tcp!127.0.0.1!$port
tools9p -b read,plan spawn read &
sleep 3

fn call {
	# in a shell of its own: a call the tool server refuses is a write
	# error, which ends the shell it is in
	sh -c 'echo ''-- tools=read :: SCENARIO:text go'' > /tool/spawn/ctl' >[2] /tmp/err.$1
	cat /tool/spawn/ctl > /tmp/r.$1
	cat /mnt/toolctl/meta/audit > /tmp/meta.$1
	cp /tmp/llm.log /tmp/log.$1
	echo called $1
}

call recorded
cat /mnt/audit/chain > /tmp/chain.recorded

# the store goes
/dis/tests/spawnfake.dis kill kill Ventisrv > /tmp/r.killstore
sleep 1
call nostore

# the sink goes (an empty directory where it was): nothing may run that
# cannot be recorded
bind /tmp/empty /mnt/audit
call nosink

# the install no longer requires it, and has no sink: as before auditing
rm /usr/inferno/audit/on
call off

echo R done
echo halt > '#c/sysctl'

#!/dis/sh.dis -n
load std
# The registry knows a caller by the user name of its attach, and a
# service is its registrant's to change or remove.  styxlisten gives
# each caller on the network an attach of its own, in the name it
# authenticated with; this machine's mount is one more caller.  (The
# registry used to be mounted here and that mount exported: every
# caller was then the user who mounted it, and any of them could
# rewrite or remove another's service.)
if {ftest -f /mnt/registry/new} {
	# one is mounted already: serve it as it is, in its mounter's name
	listen -v 'tcp!*!registry' {export /mnt/registry&}
} {
	db=()
	and {ftest -f /lib/ndb/registry} {db=(-f /lib/ndb/registry)}
	if {styxlisten -v 'tcp!*!registry' ndb/registry $db} {
		mount -c 'tcp!127.0.0.1!registry' /mnt/registry
	} {
		# no listener (no certificate, say): a registry for this machine alone
		mount -A -c {ndb/registry $db} /mnt/registry
	}
}

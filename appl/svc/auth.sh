#!/dis/sh.dis -n
load std
or {ftest -e /net/dns} {ftest -e /env/emuhost} {ndb/dns}
or {ftest -e /net/cs} {ndb/cs}
or {ftest -f /keydb/signerkey} {echo 'auth: need to use createsignerkey(8)' >[1=2]; exit nosignerkey}
or {ftest -f /keydb/keys} {echo 'auth: need to create /keydb/keys' >[1=2]; exit nokeys}
and {auth/keyfs} {
	listen -v -t -A 'tcp!*!inflogin' {auth/logind&}
	listen -v -t -A 'tcp!*!infkey' {auth/keysrv&}
}
# signer(8) and countersigner are not started here: nothing in this
# system is their client, they take requests from anybody, and the
# certificates they issue never expire.  A realm that wants the
# operator-approved enrolment starts them itself; signer(8) says how.
# run svc/registry separately if desired

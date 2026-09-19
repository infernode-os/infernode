#!/dis/sh.dis
#
# Namespace-contract test for setupfs(4): what a phone in radio range
# may do to a board with no network (#647). The card's files are stood
# in for by files under /tmp, so it runs anywhere. Asserts the tree and
# its modes; that the Wi-Fi configuration is replaced whole, in the
# card file's syntax, and only by a valid one; that the passphrase is
# never read back; that ctl takes two verbs and nothing else; and that
# net and log say what the board would.
#

load std

if {! ftest -f /dis/setupfs.dis} {
	raise 'skip:setupfs.dis not built'
}

T=/tmp/setupfs-test
rm -rf $T >[2] /dev/null
mkdir -p $T/mnt $T/ipifc/0 $T/ipifc/1
echo 'device /net/ether0 maxtu 1514 192.168.1.104 /120' > $T/ipifc/0/status
echo -n 'device /net/ether1 maxtu 1500 unbound' > $T/ipifc/1/status
echo 'wpa: 4-way handshake failed: wrong passphrase?' > $T/wpa.log
echo -n > $T/sysctl

mount {setupfs -w $T/wifi -c $T/sysctl -n $T/ipifc -l $T/wpa.log -l $T/missing.log} $T/mnt
S=$T/mnt

# The tree, and the modes that say what each file is for.
for (f in wifi net log ctl) {
	if {! ftest -f $S/$f} {
		raise fail:^$f^' missing'
	}
}
v=`{ls -l $S/ctl}
if {! ~ $"v '---w--w--w-'*} {
	raise 'fail:ctl is not write-only: '^$"v
}
v=`{ls -l $S/net}
if {! ~ $"v '--r--r--r--'*} {
	raise 'fail:net is not read-only: '^$"v
}
if {cat $S/ctl >[2] /dev/null} {
	raise 'fail:ctl was readable'
}
# (in a shell of its own: a redirection that cannot be opened ends the shell it is in)
if {sh -c 'echo x > '^$S^'/net' >[2] /dev/null} {
	raise 'fail:net was writable'
}

# A board nobody has configured.
v=`{cat $S/wifi}
if {! ~ $"v unconfigured} {
	raise 'fail:wifi with no card file: '^$"v
}

# A configuration is both lines in one write; anything less changes nothing.
if {echo 'essid Only A Name' > $S/wifi >[2] /dev/null} {
	raise 'fail:a configuration with no password was accepted'
}
if {echo 'password no network named' > $S/wifi >[2] /dev/null} {
	raise 'fail:a configuration with no essid was accepted'
}
if {echo 'essid Net
password 1234567' > $S/wifi >[2] /dev/null} {
	raise 'fail:a seven-byte passphrase was accepted'
}
if {echo 'essid this-network-name-is-33-bytes-xxx
password long enough' > $S/wifi >[2] /dev/null} {
	raise 'fail:a 33-byte essid was accepted'
}
if {ftest -e $T/wifi} {
	raise 'fail:a refused configuration reached the card'
}

# two lines, one write: the error, if any, comes back on that write
if {{echo 'essid Split'; echo 'password across two writes'} > $S/wifi >[2] /dev/null} {
	raise 'fail:a configuration split across two writes was accepted'
}
echo 'essid My Home Network
password correct horse battery' > $S/wifi
v=`{cat $T/wifi}
if {! ~ $"v 'essid My Home Network password correct horse battery'} {
	raise 'fail:the card file after a good write: '^$"v
}
if {ftest -e $T/wifi.new} {
	raise 'fail:the temporary file was left beside the card file'
}
v=`{cat $S/wifi}
if {! ~ $"v 'essid My Home Network password set'} {
	raise 'fail:wifi read back: '^$"v
}
if {cat $S/wifi | grep -s 'horse'} {
	raise 'fail:the passphrase was read back'
}

# replacing it: the old one goes whole, and a refused one leaves it be
echo 'essid Field Router
password another passphrase' > $S/wifi
v=`{cat $T/wifi}
if {! ~ $"v 'essid Field Router password another passphrase'} {
	raise 'fail:the card file after a second write: '^$"v
}
if {echo 'essid Broken' > $S/wifi >[2] /dev/null} {
	raise 'fail:a second, bad configuration was accepted'
}
v=`{cat $T/wifi}
if {! ~ $"v 'essid Field Router password another passphrase'} {
	raise 'fail:a refused configuration damaged the good one: '^$"v
}

# net: each interface under its number, as /net/ipifc gives it
v=`{cat $S/net}
if {! ~ $"v *'0 device /net/ether0 maxtu 1514 192.168.1.104'*} {
	raise 'fail:net is missing the first interface: '^$"v
}
if {! ~ $"v *'1 device /net/ether1 maxtu 1500 unbound'*} {
	raise 'fail:net is missing the second interface: '^$"v
}

# log: each log under its name, and one that is not there said so
v=`{cat $S/log}
if {! ~ $"v *'wrong passphrase'*} {
	raise 'fail:log is missing the supplicant''s: '^$"v
}
if {! ~ $"v *'missing.log (nothing)'*} {
	raise 'fail:log did not say a log was empty: '^$"v
}

# ctl: two verbs
echo reboot > $S/ctl
v=`{cat $T/sysctl}
if {! ~ $"v reboot} {
	raise 'fail:reboot did not reach the control file: '^$"v
}
echo -n > $T/sysctl
echo tryboot > $S/ctl
v=`{cat $T/sysctl}
if {! ~ $"v tryboot} {
	raise 'fail:tryboot did not reach the control file: '^$"v
}
echo -n > $T/sysctl
for (bad in halt 'reboot now' 'rm -rf /' '') {
	if {echo $bad > $S/ctl >[2] /dev/null} {
		raise 'fail:ctl accepted: '^$"bad
	}
}
v=`{cat $T/sysctl}
if {! ~ $#v 0} {
	raise 'fail:a refused verb reached the control file: '^$"v
}

unmount $S
rm -rf $T >[2] /dev/null
echo PASS

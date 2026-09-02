# Bare-metal Lucifer bring-up.
#
# The boot profile runs this IN THE BACKGROUND when the card
# userspace provides it, so the serial console stays an interactive
# shell -- on a machine with one console that shell is the management
# plane, and the desktop must never take it hostage.
#
# The hosted lib/lucifer/boot.sh is not reused: it assumes a host
# filesystem, ndb-configured LLM backends, veltro message sources and
# a plumber, none of which exist here yet. Pieces move over as they
# earn their place, not wholesale.
#
# skiplogon: create the file /n/dos/skiplogon (or set skiplogon=1 in
# the environment) to go straight to the desktop with no factotum and
# no secstore -- the GUI-testing posture. Removing the file restores
# the login screen on the next boot.

load std

# Let the boot settle: this races USB enumeration and service
# startup, and logon's first act is to attach the draw device.
sleep 3

skip=0
if {ftest -f /n/dos/skiplogon} {skip=1}
if {! ~ $#skiplogon 0} {skip=1}

ok=0
if {~ $skip 1} {
	echo 'boot: skiplogon -- desktop without factotum/secstore'
	ok=1
}{
	#
	# Retried, and FAIL-CLOSED. A login screen that dies must not
	# quietly fall through to an authenticated-looking desktop with
	# no factotum behind it -- a crash is not a login. If logon
	# cannot run after three tries, say so and stop; the serial
	# console is still a shell, and skiplogon exists for the
	# deliberate no-auth posture.
	#
	for i in 1 2 3 {
		if {~ $ok 0} {
			if {wm/logon} {
				ok=1
			}{
				echo 'boot: wm/logon failed (try' $i 'of 3)'
				sleep 2
			}
		}
	}
}

if {~ $ok 1} {
	luciuisrv
	sleep 1
	echo activity create Main > /mnt/ui/ctl
	lucifer
}{
	echo 'boot: logon would not start; NOT starting the desktop.'
	echo 'boot: fix logon, or create /n/dos/skiplogon for a no-auth desktop.'
}

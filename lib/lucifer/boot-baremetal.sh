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

#
# The desktop's namespace, narrowed.
#
# Every process on this machine runs as the host owner
# (os/arm64/main.c), so no identity check refuses a desktop program
# anything. The only thing between an agent tool and the raw SD card
# is what the tool's namespace does not contain -- which is how the
# rest of InferNode draws its boundaries (docs/DESIGN-PRINCIPLES.md),
# and it is drawn here, before anything of the desktop's starts, so
# that logon, luciuisrv, lucifer and everything they spawn inherit it.
#
# What the desktop gets is /dev as the kernel built it, less this:
#
#	#S	/dev/sdcard, /dev/sdctl	the raw card and its partition
#					table (sdaddpart checks nothing)
#	#G	/dev/gpio/N/{ctl,level}	the pins
#	/dev/sysctl			reboot, tryboot, halt, panic
#	/dev/hostowner			renames the owner of every process
#
# and keeps: #c (cons, keyboard, random, time, user, null, drivers --
# what a program expects of /dev), #m the pointer, #B the running
# kernel image (read-only) and #b the microsecond timer. #i, the draw
# device, is not bound by the kernel (main.c: attaching it takes the
# panel from the text console) and not bound here either: libdraw's
# initdisplay binds it the first time a program opens a display, so
# it lands in THIS namespace when logon starts, and the panel stays a
# console until then. /n, /usr, /dis, /lib, /fonts, /net, /prog, /env
# and /chan are inherited as they are -- and "as they are" includes
# /n/dos read-write: the FAT boot partition, holding config.txt and
# the kernel image the firmware loads. A desktop program can no longer
# write the raw card, but it can still overwrite the kernel it booted
# from through the filesystem. Inferno has no read-only bind, so that
# is not closed here; it belongs with the second half of this item
# (a non-eve user for the desktop, and a /n it does not own).
#
# #S and #G are whole devices unioned onto /dev, so they come out with
# unmount. /dev/sysctl and /dev/hostowner are two files of #c, and #c
# is also the console and the keyboard, so they cannot be unmounted;
# /dev/null is bound over each instead. A write lands in null, a read
# is empty, and the version line logon shows falls back to the brand
# name. (Verified: Inferno's cmount takes a file over a file with
# MREPL, and pgrpcpy gives this process its own mount table.)
#
# One consequence is deliberate and must be known: lucifer's Quit
# (shutdown() in appl/cmd/lucifer.b) and xenith's killwins() write
# "halt" to /dev/sysctl before they exit. Here that write lands in
# null and succeeds, so Quit ends the desktop and the board stays up
# with the serial console alive -- which is the point: a desktop
# program, or anything it spawned, must not be able to stop the
# machine. Halting is the management plane's, and the line printed
# when lucifer returns (bottom of this script) says so on the console
# so that a dead panel is not mistaken for a hung board.
#
# pctl forkns first. sh forks its namespace as it starts, so this
# script already has its own copy -- but that is a property of how the
# profile happens to invoke it, and the boundary must not depend on
# that. The serial console shell is another process group and is not
# touched by any of this: it keeps the card, the pins and sysctl,
# because it is the management plane.
#
pctl forkns
unmount '#S' /dev
unmount '#G' /dev
bind /dev/null /dev/sysctl
bind /dev/null /dev/hostowner

#
# And check that it took, because this is a boundary: a desktop
# started over a namespace that still holds the card is exactly what
# the lines above exist to prevent, and an unmount that failed prints
# one line on a console nobody is watching.
#
narrowed=1
if {ftest -e /dev/sdcard} {narrowed=0}
if {ftest -e /dev/sdctl} {narrowed=0}
if {ftest -e /dev/gpio} {narrowed=0}
v=`{cat /dev/sysctl}
if {! ~ $#v 0} {narrowed=0}
if {~ $narrowed 0} {
	echo 'boot: the desktop namespace still holds the card, the pins or sysctl; NOT starting the desktop.'
	exit
}

# Let the boot settle: this races USB enumeration and service
# startup, and logon's first act is to attach the draw device.
sleep 3

skip=0
if {ftest -f /n/dos/skiplogon} {skip=1}
if {~ $skiplogon 1} {skip=1}

#
# wm/logon has three outcomes and the shell must tell them apart (the
# contract is at the top of appl/wm/logon.b):
#
#	it returns	logged in; factotum holds the keys
#	skipped		the user chose to go on without secstore, twice.
#			Deliberate, so the desktop starts -- but said
#			so here, because from the panel it looks the
#			same as a login and it is not one.
#	anything else	it died: no display, no keyboard, no form. Retry,
#			and after three tries say so and STOP. A crash
#			is not a login, and the serial console is still
#			a shell; skiplogon exists for the deliberate
#			no-auth posture.
#
# The first version of this loop tested the exit status alone, which
# was success on every one of those paths.
#
# $status is copied at once: `if` sets it from every condition it
# runs, so by the time the reason is printed the `~` test has replaced
# it with "no match".
#
ok=0
if {~ $skip 1} {
	echo 'boot: skiplogon -- desktop without factotum/secstore'
	ok=1
}{
	for i in 1 2 3 {
		if {~ $ok 0} {
			if {wm/logon} {
				ok=1
			}{
				why=$status
				if {~ $why skipped} {
					echo 'boot: login skipped at the screen -- desktop WITHOUT factotum/secstore; keys will not persist'
					ok=1
				}{
					echo 'boot: wm/logon failed:' $why '(try' $i 'of 3)'
					sleep 2
				}
			}
		}
	}
}

if {~ $ok 1} {
	luciuisrv
	sleep 1
	echo activity create Main > /mnt/ui/ctl
	lucifer
	#
	# The desktop's own Quit wrote "halt" into the null bound over
	# its /dev/sysctl (see the namespace comment above), so the board
	# is still running, with a dead panel. Say so where it can be
	# read; halt or reboot from the serial console.
	#
	echo 'boot: the desktop has exited. The machine is still up: a Quit from the panel cannot halt the board (its /dev/sysctl is null). Halt or reboot from the serial console.'
}{
	echo 'boot: logon would not run; NOT starting the desktop.'
	echo 'boot: fix logon, or create /n/dos/skiplogon for a no-auth desktop.'
}

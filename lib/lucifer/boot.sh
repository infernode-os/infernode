# InferNode's boot: the login screen, then the interface chosen there.
#
# The one boot every build runs:
#
#	hosted (macOS, Linux, Windows)	sh -l /lib/lucifer/boot.sh, after
#					lib/sh/profile
#	phone, tablet			lib/lucifer/boot-mobile.sh, which sets
#					up the phone (fonts, radio, $infmobile)
#					and runs this
#	a board (the Pis, QEMU virt)	os/init/profile, in the background of
#					the serial console's shell
#
# There was a second copy for the boards, boot-baremetal.sh, and every
# change to the login screen after it was made went into this one alone:
# the boards had no choice of interface, no Desktop, no agent and no
# plumber for four releases.  What differs between the builds is decided
# here, below, by what the machine is -- never by a script of its own.
#
#	$board		1 on the native kernel (no host: emu sets $emuhost,
#			the native kernel does not)
#	$infmobile	1 on a phone or tablet (boot-mobile.sh)
#	$osk		on or off: the keyboard on the screen.  Unset, it is
#			on where the screen is the keyboard (a board's touch
#			panel, a phone) and off on a hosted desktop, which has
#			a keyboard; osk=on for a hosted kiosk.  Lucifer reads
#			it too.
#	$skiplogon	1: no login screen (tests, a developer); on a board
#			also the file /n/dos/skiplogon
#	$interface	the interface to start, whatever was chosen
#	$noplumber	1: no plumber (a test's)

load std

board=0
if {~ $#emuhost 0} {board=1}

user=`{cat /dev/user}

#
# A board: the desktop's name space narrowed, the remote-desktop
# listener, and whether there is a screen at all.
#
# The serial console's shell is another process group and keeps all of
# this; it is the management plane.
#
if {~ $board 1} {
	#
	# Every process on a board runs as the host owner
	# (os/arm64/main.c), so no identity check refuses a desktop
	# program anything.  The only thing between an agent tool and the
	# raw SD card is what the tool's name space does not contain --
	# which is how the rest of InferNode draws its boundaries
	# (docs/DESIGN-PRINCIPLES.md) -- and it is drawn here, before
	# anything of the desktop's starts, so that logon, the interface
	# and everything they spawn inherit it.
	#
	# What the desktop gets is /dev as the kernel built it, less this:
	#
	#	#S	/dev/sdcard, /dev/sdctl	the raw card and its
	#					partition table (sdaddpart
	#					checks nothing)
	#	#G	/dev/gpio/N/{ctl,level}	the pins
	#	/dev/sysctl			reboot, tryboot, halt, panic
	#					(and booted, console, broken,
	#					nobroken)
	#	/dev/hostowner			renames the owner of every
	#					process
	#
	# and keeps: #c (cons, keyboard, random, time, user, null, drivers
	# -- what a program expects of /dev), #m the pointer, #B the
	# running kernel image (read-only) and #b the microsecond timer.
	# #i, the draw device, is not bound by the kernel (main.c:
	# attaching it takes the panel from the text console); the screen
	# check below binds it.  /n, /usr, /dis, /lib, /fonts, /net,
	# /prog, /env and /chan are inherited as they are -- and "as they
	# are" includes /n/dos read-write: the FAT boot partition, holding
	# config.txt and the kernel image the firmware loads.  A desktop
	# program can no longer write the raw card, but it can still
	# overwrite the kernel it booted from through the file system.
	# Inferno has no read-only bind, so that is not closed here; it
	# belongs with a non-eve user for the desktop, and a /n it does
	# not own.
	#
	# #S and #G are whole devices unioned onto /dev, so they come out
	# with unmount.  /dev/sysctl and /dev/hostowner are two files of
	# #c, and #c is also the console and the keyboard, so they cannot
	# be unmounted; /dev/null is bound over each instead.  A write
	# lands in null, a read is empty, and the version line logon shows
	# falls back to the brand name.
	#
	# One consequence is deliberate: Lucifer's Quit, Xenith's and this
	# script's own "halt" go into null, so they end the desktop and the
	# board stays up with the serial console alive.  A desktop program,
	# or anything it spawned, must not be able to stop the machine.
	# Halting is the management plane's, and the line printed when the
	# interface returns (the end of this script) says so.
	#
	# pctl forkns first: the boundary must not depend on how the
	# profile happens to start this script.
	#
	pctl forkns
	unmount '#S' /dev
	unmount '#G' /dev
	bind /dev/null /dev/sysctl
	bind /dev/null /dev/hostowner

	#
	# And check that it took, because this is a boundary: a desktop
	# started over a name space that still holds the card is exactly
	# what the lines above exist to prevent, and an unmount that failed
	# prints one line on a console nobody is watching.
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

	#
	# The remote-desktop listener: cpu(1) from another InferNode runs
	# programs here that draw on the caller's screen
	# (docs/REMOTE-DESKTOP.md).  OFF unless the card asks for it with a
	# file /n/dos/cpulisten, whose contents, if any, are the address to
	# listen on (default tcp!*!rstyx, port 6668).  Started here, in the
	# desktop's narrowed name space, so a remote session starts with a
	# desktop's powers; rstyxd narrows it again (/n/dos unmounted,
	# NODEVS).  Before the screen check, so a headless board has it too.
	#
	# It needs this machine's own certificate in
	# /usr/<user>/keyring/default, signed by the signer the callers'
	# certificates come from, and without one it does not start.
	# Every session is AES-256-GCM (-a aes_256_gcm), which makes a
	# record flipped, cut, replayed or reordered an error; cleartext
	# and MAC-only callers are refused in the handshake.
	#
	if {ftest -f /n/dos/cpulisten} {
		cpuaddr=`{cat /n/dos/cpulisten}
		if {~ $#cpuaddr 0} {cpuaddr='tcp!*!rstyx'}
		cpukey=/usr/^`{cat /dev/user}^/keyring/default
		if {ftest -f $cpukey} {
			listen -a aes_256_gcm $cpuaddr auxi/rstyxd &
			echo 'boot: cpu listener on' $cpuaddr '(AES-256-GCM, certificate' $cpukey^')'
		} {
			echo 'boot: /n/dos/cpulisten is set but' $cpukey 'is missing; NOT starting the cpu listener'
		}
	}

	# Let the boot settle: this races USB enumeration and service
	# startup, and logon's first act is to attach the draw device.
	sleep 3

	#
	# Is there a screen?  If not, the board is HEADLESS, and that is a
	# way of running it, not a fault: the serial console is a shell
	# with the whole name space and the network is up.  Asked here, of
	# the draw device, because nothing else knows; without it logon
	# dies three times with "no display", or with skiplogon the
	# interface starts, fails and is announced as exited.
	#
	# The question is the one logon would ask first: open
	# /dev/draw/new.  With no framebuffer the draw device refuses it.
	# ONE read of 144 bytes (twelve fields of twelve), not cat: `new`
	# does not end, and cat's second read fails on a machine with a
	# perfectly good screen.  In a subshell, because the open is a
	# redirection, and a failed redirection can end a non-interactive
	# shell where it stands, before it has said why.
	#
	bind -a '#i' /dev >[2] /dev/null
	if {! sh -c 'read 144 < /dev/draw/new > /dev/null >[2] /dev/null'} {
		echo 'boot: no display -- running headless; not starting the desktop. This console is the machine''s shell.'
		exit
	}
}

# Warm trfs cache for the secstore overlay so logon and secstored can
# find PAK/factotum files on second launch (trfs may not have read-ahead
# the directory contents yet when the overlay bind was set up in profile).
ls /usr/inferno/secstore >[2] /dev/null
if {! ~ $user ''} {
	ls /usr/inferno/secstore/$user >[2] /dev/null
}

# No login screen: $skiplogon, or on a board the file /n/dos/skiplogon
# (removing it brings the login screen back on the next boot).
skip=0
if {~ $skiplogon 1} {skip=1}
if {~ $board 1} {
	if {ftest -f /n/dos/skiplogon} {skip=1}
}

# The keyboard on the screen, where the screen is the keyboard: a
# board's touch panel, a phone.  A hosted desktop has a keyboard and
# gets none unless asked (osk=on: a kiosk).  $osk is left set, on or
# off, for Lucifer, which starts its own for the session.
if {~ $#osk 0} {
	osk=off
	if {~ $board 1} {osk=on}
	if {~ $infmobile 1} {osk=on}
}

# The keyboard for the password: it shows itself once the screen is
# touched with no keyboard attached, and in secret mode shows nothing
# of what is typed and learns none of it (osk(1)).  It goes when the
# login is done.
oskpid=()
if {~ $osk on} {
	if {~ $skip 0} {
		if {ftest -f /dis/wm/osk.dis} {
			wm/osk -s -M secret &
			oskpid=$apid
		}
	}
}

# The interfaces the login screen offers, and the file the one chosen is
# kept in:
#
#	Assistant	Lucia, the agent-first interface (lucifer), the default
#	Desktop	windows (wm/wm), a shell to begin with
#
# wm/logon shows them, each with the line $about gives it, and writes
# the name chosen to $interfacefile; it knows nothing of what each is,
# which is this script's, below.  The file is the user's
# (/usr/<user>/lib or, for a user with no home of their own,
# /usr/inferno/lib, kept in ~/.infernode as the plumbing rules are), so
# the interface chosen is the one the screen offers next time.  It is
# the login screen's: with skiplogon the interface is Assistant,
# whatever was chosen there.  $interface, set before this runs, starts
# that one either way.  A phone or tablet has Assistant alone: wm/wm's
# windows are not for a touch screen held in the hand.  Assistant was
# called Lucia here: a file or $interface naming Lucia is taken for
# Assistant.
interfaces=(Assistant Desktop)
if {~ $infmobile 1} {interfaces=(Assistant)}
about=(-d 'Assistant=Agent-first. Voice, touch and keyboard input. Adaptive layout.' -d 'Desktop=Overlapping windows, pointer input, command shell.')
interfacefile=/usr/^$user^/lib/interface
if {! ftest -d /usr/^$user^/lib} {
	mkdir -p /usr/inferno/lib >[2] /dev/null
	interfacefile=/usr/inferno/lib/interface
}

# The login screen (unlocks secstore, loads keys into factotum).
#
# wm/logon returns when the user logged in, fails with status
# "skipped" when they chose to go on without secstore, and fails with
# the reason otherwise (no keyboard, no form -- see the top of
# appl/wm/logon.b).  The two kinds of machine answer a failure
# differently:
#
#	hosted	goes on to the interface: the host's own login already
#		stands between the world and this screen, and a
#		developer running without a display wants the desktop,
#		not a refusal.
#	board	tries three times and then STOPS: this screen is the
#		machine's only login, a crash is not a login, and the
#		serial console is still a shell.  skiplogon is the
#		deliberate no-auth posture.
#
# Either way it says which it was, because an interface with no
# factotum looks exactly like one with.  ($status is copied first: `if`
# resets it from every condition it evaluates, the `~` included.)
tries=(1)
if {~ $board 1} {tries=(1 2 3)}
loggedin=0
if {~ $skip 1} {
	echo 'boot: skiplogon=1 — wm/logon bypassed (no factotum, no secstore)'
	loggedin=1
}{
	for i in $tries {
		if {~ $loggedin 0} {
			if {wm/logon -i $interfacefile $about $interfaces} {
				echo 'boot: logged in — secstore keys are in factotum'
				loggedin=1
			}{
				why=$status
				if {~ $why skipped} {
					echo 'boot: login skipped at the screen — no factotum, no secstore; keys will not persist'
					loggedin=1
				}{
					echo 'boot: wm/logon failed:' $why '(try' $i 'of' $#tries^')'
					if {~ $board 1} {sleep 2}
				}
			}
		}
	}
}
if {! ~ $#oskpid 0} {kill -g $oskpid >[2] /dev/null}
if {~ $loggedin 0} {
	if {~ $board 1} {
		echo 'boot: logon would not run; NOT starting the desktop.'
		echo 'boot: fix logon, or create /n/dos/skiplogon for a no-auth desktop.'
		exit
	}
	echo 'boot: continuing without factotum/secstore'
}

# The interface to start: $interface if it was set, else the one chosen
# at the login screen, else the first; and one of $interfaces
# whichever it is.
if {~ $#interface 0} {
	if {~ $skip 0} {interface=`{cat $interfacefile >[2] /dev/null}}
}
if {~ $interface Lucia} {interface=Assistant}
known=0
for offered in $interfaces {if {~ $offered $interface} {known=1}}
if {~ $known 0} {interface=${hd $interfaces}}
echo 'boot: interface' $interface

# What a board says when the interface returns: its Quit wrote "halt"
# into the null over its /dev/sysctl, so the board is still running,
# with a dead panel.
boardup='boot: the desktop has exited. The machine is still up: a Quit from the panel cannot halt the board (its /dev/sysctl is null). Halt or reboot from the serial console.'

# (Re-)start LLM service in the background: lib/lucifer/llmsrv.sh,
# which a standalone Xenith runs too.  Backgrounded so the desktop
# comes up whether or not a remote /mnt/llm answers.
{
	run /lib/lucifer/llmsrv.sh
} &

# Wallet service.  wallet9p, msg9p and luciuisrv mount themselves and
# return, serving from the background: run in the foreground, each one's
# files are there when the next line runs.
/dis/veltro/wallet9p.dis >[2] /dev/null

# Message layer — msg9p mounts /mnt/msg and aggregates Notifications from
# every registered MsgSrc into /mnt/msg/notify, which lucibridge / agents
# block-read for unified inbound alerts (mail, sms, …). Register the
# sources we ship by default; failures here are non-fatal (the source's
# own init() returns an error if the backing channel isn't available,
# e.g. sms on a build without /phone bound). stderr stays attached so
# mount/register failures surface in the console.
/dis/veltro/msg9p.dis
echo 'register sms /dis/veltro/sources/sms.dis' > /mnt/msg/ctl

# Email source — registered only when an account is configured, so we never
# hardcode a provider. The Settings "Messaging" panel writes the config line
# (server=/smtpserver=/folder=) to /lib/veltro/sources/email.conf; the
# credentials live in factotum via the keyring "Email Account" entry. Both the
# register here and the source's init() soft-fail if the server or creds are
# absent (same posture as sms above). See docs/MESSAGE-INTEGRATION.md.
if {ftest -f /lib/veltro/sources/email.conf} {
	echo register email /dis/veltro/sources/email.dis `{cat /lib/veltro/sources/email.conf} > /mnt/msg/ctl
}

# Desktop: windows, the way Inferno always had them.  wm/wm, its first
# command /lib/wm/desktop.sh: a plumber on the desktop's rules, which
# start a program for what nobody has open (a file in Xenith, a web
# page in Charon) where Lucia's send everything to its presentation
# zone, then a shell.  The plumber's /chan is bound here, before
# wm/wm, so that wm/wm's /chan/wmctl and the plumber's ports are in
# the one directory everything started sees.  Nothing of Lucia's
# below is started.  wm/wm at the top has no Quit (closing the emu's
# window ends it); should it return, the emu halts, as Lucia's Quit
# halts it, rather than leave a display nothing draws on.  A board
# does not halt (its sysctl is null) and says so.
if {~ $interface Desktop} {
	bind -bc '#splumber' /chan
	wm/wm sh /lib/wm/desktop.sh
	if {~ $board 1} {echo $boardup} {echo halt > /dev/sysctl}
	exit
}

# Assistant (Lucia): the GUI services, then lucifer.
luciuisrv
echo activity create Main > /mnt/ui/ctl
# The messages are activity 0's to hand on: /mnt/msg is the read-only
# summary (status), /mnt/msg/draft the proposal endpoint a task writes a
# draft to (queued for the user, never sent by itself), /mnt/msg/flag where
# a message is marked seen.  nsconstruct keeps each to that.  Without them
# meta.txt's and the message policy's ways to delegate mail were refused.
# git is not in the budget (-b): its worker keeps the name space tools9p
# started in, so what it adds, removes, checks out or pushes is bounded by
# no grant and staged by no overlay (its manifest says so).  A task given
# it could change the user's files unasked.  Give it to an activity by hand
# (budget-add git) where that is wanted; tests/host/default_budget_test.sh
# holds the line.
/dis/veltro/tools9p -v -m /tool -b read,list,find,search,grep,write,edit,exec,launch,spawn,diff,json,webfetch,say,editor,fractal,memory,todo,plan,websearch,mail,keyring,present,gap,limbo,sms,dial,contacts -p /dis/wm -p /mnt/msg:ro -p /mnt/msg/draft:rw -p /mnt/msg/flag:rw read list find present say hear task memory gap keyring editor shell limbo sms dial contacts
# /tmp is bound by lib/sh/profile; on Windows the bind has hit edge
# cases where it silently failed and the redirect below produced no log
# file (GH #230 sphynkx report). Force /tmp into existence and pre-create
# the log so the background redirect always has a writable target. If
# /tmp truly doesn't exist after this, the mkdir will print to stderr
# instead of being silenced.
mkdir -p /tmp
> /tmp/lucibridge.log
# The Tasks tab first: lucibridge may add a Welcome tab of its own, and
# a sleep between them only made this order likely.
echo 'create id=tasks type=taskboard label=Tasks' > /mnt/ui/activity/0/presentation/ctl
lucibridge -a 0 -v -s >[2] /tmp/lucibridge.log &

# Incoming messages reach the agent only when the user has turned it on
# (/lib/veltro/messaging.conf watch=on; shipped off).  After luciuisrv and
# activity 0, which msgwatch hands each message to.
if {grep -s '^watch=on' /lib/veltro/messaging.conf} {
	/dis/veltro/msgwatch.dis >[2] /tmp/msgwatch.log &
}

# Plumbing — route file-opens to the presentation view.  The stock Inferno
# plumber matches the user's rules (/usr/<user>/lib/plumbing) and then
# /lib/lucifer/plumbing, and forwards to the 'presentation' port; lucipres
# consumes it (plumbreceiver) and opens each file as the right artifact,
# and a web page in Charon.  This is the shared path for every picker: the
# ftree file tree, the context panel, an agent, or the `plumb` command.
# lib/sh/plumbrules starts it, falling back to the defaults alone if the
# user's rules do not parse.
#
# The plumber publishes /chan/plumb.* via file2chan, which needs /chan on
# the srv device (#s); emu leaves /chan as the snarf device (#^).  Bind a
# named srv instance first, exactly as acme/xenith do (bind -bc
# '#splumber' /chan).  This runs in the boot namespace, so lucifer,
# lucipres (the consumer) and ftree (a client) — all forked after this —
# inherit the same /chan and see the same ports.  Start the plumber before
# lucifer so the 'presentation' port exists when lucipres opens it.
# $noplumber=1 skips the plumber (regression-test hook, like $skiplogon):
# tests/host/presentation_fileopen_test.sh uses it to verify the UI still
# comes up — Tasks tab and all — when no plumber is present, since the plumb
# consumer must never gate lucipres's init (see lucipres plumbreceiver).
if {! ~ $noplumber 1} {
	bind -bc '#splumber' /chan
	/lib/sh/plumbrules start /lib/lucifer/plumbing
}{
	echo 'boot: noplumber=1 — plumber not started (pickers use the /mnt/ui fallback)'
}

# (No auto-spawn of /dis/wm/shell in Activity 0 — the Main agent
#  doesn't have shell authority, so the tab either sits empty or, on
#  mobile, slides a shell in front of a context that shouldn't have
#  it. Users that genuinely want a shell open a fresh task activity
#  for it.)
lucifer
if {~ $board 1} {echo $boardup}

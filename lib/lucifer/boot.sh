# InferNode GUI boot sequence
# Runs AFTER profile (invoked as: sh -l /lib/lucifer/boot.sh)


# Warm trfs cache for the secstore overlay so logon and secstored can
# find PAK/factotum files on second launch (trfs may not have read-ahead
# the directory contents yet when the overlay bind was set up in profile).
user=`{cat /dev/user}
ls /usr/inferno/secstore >[2] /dev/null
if {! ~ $user ''} {
	ls /usr/inferno/secstore/$user >[2] /dev/null
}

# The keyboard on the screen for the password, on a screen with no
# keyboard (a phone, the Pi's touch panel): it shows itself once the
# screen is touched with none attached, and in secret mode shows
# nothing of what is typed and learns none of it (osk(1)).  It goes
# when the login is done; Lucifer starts its own.  $osk off: not.
oskpid=()
if {! ~ $osk off} {
	if {! ~ $skiplogon 1} {
		if {ftest -f /dis/wm/osk.dis} {
			wm/osk -s -M secret &
			oskpid=$apid
		}
	}
}

# The interfaces the login screen offers, and the file the one chosen is
# kept in:
#
#	Lucia	the agent's three zones (lucifer), the default
#	Desktop	windows (wm/wm), a shell to begin with
#
# wm/logon shows them and writes the name chosen to $interfacefile; it
# knows nothing of what each is, which is this script's, below.  The
# file is the user's (/usr/<user>/lib or, for a user with no home of
# their own, /usr/inferno/lib, kept in ~/.infernode as the plumbing
# rules are), so the interface chosen is the one the screen offers
# next time.  It is the login screen's: with $skiplogon (the tests',
# a developer's) the interface is Lucia, as it always was, whatever was
# chosen there.  $interface, set before this runs, starts that one
# either way.  A phone has Lucia alone: wm/wm's windows are not for a
# touch screen.
interfaces=(Lucia Desktop)
if {~ $infmobile 1} {interfaces=(Lucia)}
interfacefile=/usr/^$user^/lib/interface
if {! ftest -d /usr/^$user^/lib} {
	mkdir -p /usr/inferno/lib >[2] /dev/null
	interfacefile=/usr/inferno/lib/interface
}

# Login screen (unlocks secstore, loads keys into factotum).
#
# Skippable via $skiplogon. Mobile dev iteration (hellaphone) sets
# this from /lib/lucifer/boot-mobile.sh when the Activity passes
# --no-logon — typing a password on every UI rebuild is wasted
# iteration time. Default behaviour is unchanged (variable unset =
# logon runs). When $skiplogon is 1, secstore stays locked and
# factotum starts empty; downstream code that needs keys (LLM
# keyring mounts, etc.) will fail in expected ways.
#
# wm/logon returns when the user logged in, fails with status
# "skipped" when they chose to go on without secstore, and fails with
# the reason otherwise (no display, no keyboard -- see the top of
# appl/wm/logon.b). The hosted boot goes on to the desktop in every
# case, as it always has: the host's own login already stands between
# the world and this screen, and a developer running without a
# display wants the desktop, not a refusal. But it says which of the
# three it was, because a desktop with no factotum looks exactly like
# one with. ($status is copied first: `if` resets it from every
# condition it evaluates, the `~` included.)
if {! ~ $skiplogon 1} {
	if {wm/logon -i $interfacefile $interfaces} {
		echo 'boot: logged in — secstore keys are in factotum'
	}{
		why=$status
		if {~ $why skipped} {
			echo 'boot: login skipped at the screen — no factotum, no secstore; keys will not persist'
		}{
			echo 'boot: wm/logon failed:' $why '— continuing without factotum/secstore'
		}
	}
}{
	echo 'boot: skiplogon=1 — wm/logon bypassed (dev mode; no factotum, no secstore)'
}
if {! ~ $#oskpid 0} {kill -g $oskpid >[2] /dev/null}

# The interface to start: $interface if it was set, else the one chosen
# at the login screen, else the first; and one of $interfaces
# whichever it is.
if {~ $#interface 0} {
	if {! ~ $skiplogon 1} {interface=`{cat $interfacefile >[2] /dev/null}}
}
known=0
for offered in $interfaces {if {~ $offered $interface} {known=1}}
if {~ $known 0} {interface=${hd $interfaces}}
echo 'boot: interface' $interface

# (Re-)start LLM service in the background: lib/lucifer/llmsrv.sh,
# which a standalone Xenith runs too.  Backgrounded so the desktop
# comes up whether or not a remote /mnt/llm answers.
{
	run /lib/lucifer/llmsrv.sh
} &

# Wallet service.  wallet9p, msg9p and luciuisrv mount themselves and
# return, serving from the background: run in the foreground, each one's
# files are there when the next line runs.  (Each used to be started
# with & and followed by a sleep 1 -- five seconds of every boot spent
# guessing how long a mount takes.)
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
# halts it, rather than leave a display nothing draws on.
if {~ $interface Desktop} {
	bind -bc '#splumber' /chan
	wm/wm sh /lib/wm/desktop.sh
	echo halt > /dev/sysctl
	exit
}

# Lucia: the GUI services, then lucifer.
luciuisrv
echo activity create Main > /mnt/ui/ctl
# The messages are activity 0's to hand on: /mnt/msg is the read-only
# summary (status), /mnt/msg/draft the proposal endpoint a task writes a
# draft to (queued for the user, never sent by itself), /mnt/msg/flag where
# a message is marked seen.  nsconstruct keeps each to that.  Without them
# meta.txt's and the message policy's ways to delegate mail were refused.
/dis/veltro/tools9p -v -m /tool -b read,list,find,search,grep,write,edit,exec,launch,spawn,diff,json,webfetch,git,say,editor,fractal,memory,todo,plan,websearch,mail,keyring,present,gap,limbo,sms,dial,contacts -p /dis/wm -p /mnt/msg:ro -p /mnt/msg/draft:rw -p /mnt/msg/flag:rw read list find present say hear task memory gap keyring editor shell limbo sms dial contacts
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
#  it. The old `mobile SMS test affordance` from c71663e8 became
#  redundant once Veltro picked up the sms / dial tools (INFR-150 /
#  INFR-151 / INFR-169). Users that genuinely want a shell open a
#  fresh task activity for it.)
lucifer

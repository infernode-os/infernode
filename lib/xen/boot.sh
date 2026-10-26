#!/dis/sh.dis
# boot.sh [xenith's arguments] — start a standalone Xenith
#
# A plumber and the model, the way Lucifer's boot starts them, then
# Xenith over the whole emu window; leaving Xenith halts the emu.  The
# one entry point for tools/xen, tools/xen.ps1, Xenith.app, Linux/xenith and
# Xenith.exe, run after the profile (sh -l) in the shell that runs
# Xenith, so the plumber's /chan is in Xenith's name space.
load std
# The plumber first, so plumbing works from the outset and Xenith does
# not start its own: the user's rules (/usr/<user>/lib/plumbing), then
# /lib/xen/plumbing.
bind -bc '#splumber' /chan
/lib/sh/plumbrules start /lib/xen/plumbing
# Files the host asks to have opened, a document opened with the app
# (Finder's Open With, the Dock icon) or a file dropped on the window,
# arrive on /dev/hostopen (cons(3)) and are plumbed like any other.
if {ftest -e /dev/hostopen} {hostplumb -p < /dev/hostopen &}
# The model, so the Agent window (xenith/dis/Agent) finds /mnt/llm.
# In the background: a remote /mnt/llm must never hold up the editor.
{run /lib/lucifer/llmsrv.sh} >[2] /dev/null &
# The user's own start-up, /usr/<user>/lib/xen/profile or, for a user
# with no home of their own (as with the plumbing rules), the one in
# /usr/inferno, kept in ~/.infernode/usr/inferno.  It runs in this
# shell so that what it binds (a package's commands and files, its own
# /lib/xenith/doctypes) is in Xenith's name space from the outset.  One
# that fails is said and Xenith starts all the same.
xenprofile=/usr/^`{cat /dev/user}^/lib/xen/profile
if {! ftest -f $xenprofile} {xenprofile=/usr/inferno/lib/xen/profile}
if {ftest -f $xenprofile} {
	run $xenprofile
	if {! ~ $status ''} {echo 'xen: '^$xenprofile^': '^$status >[1=2]}
}
xenith $*

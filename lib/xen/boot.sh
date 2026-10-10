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
xenith $*

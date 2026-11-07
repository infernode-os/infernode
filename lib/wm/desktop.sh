#!/dis/sh.dis
# desktop.sh — the Desktop interface's first command: wm/wm runs it
# (lib/lucifer/boot.sh), so it and what it starts have wm/wm's draw
# context.  The plumber is started here, not before wm/wm, for that:
# a program it starts gets the plumber's context, and one with none
# (Xenith for a file plumbed) took the whole display, over wm/wm,
# instead of a window.  The plumber's /chan is bound already, by the
# boot, and wm/wm's /chan/wmctl is beside its ports.
load std
if {! ~ $noplumber 1} {
	/lib/sh/plumbrules start /lib/wm/plumbing
	# Files the host asks to have opened (Finder's Open With, a file
	# dropped on the window) arrive on /dev/hostopen and are plumbed.
	# A process group of its own: the shell below is this one's, and
	# leaving it must not take the host's files with it.
	if {ftest -e /dev/hostopen} {{pctl newpgrp; hostplumb -p < /dev/hostopen} &}
}
wm/sh

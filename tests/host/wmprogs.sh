# wmprogs.sh — the programs in dis/wm and how a test runs each, for the
# tests that open every one (wm_size_test.sh under wm/wm,
# lucifer_app_test.sh in Lucifer's zone).  Sourced, after common.sh.
#
# wmprog_how p: the program's arguments ("wm/page /README.md"), or "-"
# and why it is not opened as an app.  A program not named here is run
# with no arguments, so a new one is covered from the day it is built.
wmprog_how() {
	case $1 in
	samengine|samrx|samstub|samtk)
		echo "- a module of wm/sam's, not a program" ;;
	logon)	echo "- the boot screen: it draws on the display itself, before any window manager" ;;
	presrender)
		echo "- Lucifer's presentation renderer: it follows /mnt/ui" ;;
	page)	echo "wm/page /README.md" ;;		# with nothing named it reads standard input
	sam)	echo "wm/sam /README.md" ;;
	view)	echo "wm/view /MacOSX/Xenith.png" ;;	# with nothing named it opens nothing
	*)	echo "wm/$1" ;;
	esac
}

# wmprogs: every program in dis/wm, by name (page, sam, ...)
wmprogs() {
	for f in "$ROOT"/dis/wm/*.dis; do
		basename "$f" .dis
	done
}

#!/dis/sh.dis
#
# An app's cursor under Lucifer: it asks for one on its window
# server (/chan/wmctl), as wm/wm does for New's cross and Delete's
# gunsight, and Lucifer makes it the pointer's.  Rio's cross, the
# arrow again (cursor alone), then a request with too few fields, which
# must be refused.  After each it prints R and the step's name;
# tests/host/lucifer_cursor_test.sh checks the cursor calls emu made
# through SDL between them (not a test: the runner runs every script in
# tests/inferno).
#
cross='cursor -7 -7 16 32 03c003c003c003c003c003c0ffffffffffffffff03c003c003c003c003c003c000000180018001800180018001807ffe7ffe0180018001800180018001800000'
{
	# a client reads its id before it asks for anything
	read > /dev/null
	echo -n $cross >[1=0]
	sleep 1
	echo R cross >[1=2]
	echo -n cursor >[1=0]
	sleep 1
	echo R arrow >[1=2]
	if {echo -n 'cursor 1 2 3' >[1=0] >[2] /dev/null} {
		echo R badaccepted >[1=2]
	}{
		echo R badrefused >[1=2]
	}
} <> /chan/wmctl
echo R done >[1=2]
echo halt > '#c/sysctl'

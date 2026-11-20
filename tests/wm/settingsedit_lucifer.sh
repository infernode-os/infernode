#!/dis/sh.dis
#
# wm/settings's Edit buttons in Lucifer, for
# tests/host/settings_edit_test.sh (not a test: the runner runs every
# script in tests/inferno), run after a boot of lib/lucifer/boot.sh at
# 1280x800: Settings opened in the presentation zone, each button that
# opens a file clicked in turn.  After each, the zone's current artifact,
# its artifacts and the documents of every posted editor are printed
# (R lines): one editor, `editor`, given each file through #seditor/fs.
# Then typing into it, and the next file must not replace what was typed;
# then the editor killed, and the next file must start it again.
#
load std

fn click { echo m $1 $2 1 > /dev/pointer; echo m $1 $2 0 > /dev/pointer }
ui=/mnt/ui/activity/0/presentation/ctl
pr=/mnt/ui/activity/0/presentation

fn report {
	echo R $1 current `{cat $pr/current} > '#c/cons'
	for a in `{ls $pr} {
		if {ftest -d $a} {
			echo R $1 art `{basename $a} `{cat $a/dispath >[2]/dev/null} > '#c/cons'
		}
	}
	mkdir -p /tmp/ed
	for e in `{ls '#seditor'} {
		mount -A $e /tmp/ed
		echo R $1 posted `{basename $e} `{cat /tmp/ed/index} > '#c/cons'
		unmount /tmp/ed
	}
}

# step name category-y button-x button-y: the category, then its button
fn step {
	echo 'center id=settings' > $ui
	sleep 2
	click 450 $2
	sleep 2
	click $3 $4
	sleep 5
	report $1
}

echo 'create id=settings type=app label=settings dis=/dis/wm/settings.dis data=-c theme' > $ui
echo 'center id=settings' > $ui
sleep 6
step theme 300 652 248
step theme2 300 652 248
step meta 160 637 109
step task 160 637 161
step profile 180 637 109
step email 200 651 128
echo 'center id=editor' > $ui
sleep 2
click 670 400
sleep 1
echo -n 'UNSAVED' > /dev/keyboard
sleep 2
report typed
step dirty 300 652 248
echo 'kill id=editor' > $ui
sleep 3
step reopen 160 637 109
echo R done > '#c/cons'
echo halt > /dev/sysctl

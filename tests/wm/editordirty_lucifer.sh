#!/dis/sh.dis
#
# Unsaved changes in Lucifer's editor, for
# tests/host/lucifer_editor_dirty_test.sh (not a test: the runner runs
# every script in tests/inferno), run after a boot of lib/lucifer/boot.sh
# at 1280x800, with the plumber or without ($noplumber=1).  Matrix's
# `edit` (its context menu's Edit, the picker's button) opens the
# composition in the editor; typing makes it unsaved; Matrix's `edit` of
# another composition must keep that editor and its text and give the
# file an editor of its own.  Then the editor itself is asked to open a
# file over the unsaved text, and must refuse.  After each step the
# zone's current artifact, its artifacts and the documents of every
# posted editor are printed (R lines).
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

fn matrix {
	echo $* > /mnt/matrix/ctl
	sleep 5
}

echo 'create id=matrix type=app label=matrix dis=/dis/wm/matrix.dis data=/lib/matrix/compositions/tk-demo' > $ui
echo 'center id=matrix' > $ui
sleep 8
if {! ftest -f /mnt/matrix/ctl} {
	echo R nomatrix > '#c/cons'
}
report start
matrix edit
report first
echo 'center id=editor' > $ui
sleep 2
click 670 400
sleep 1
echo -n 'UNSAVED' > /dev/keyboard
sleep 2
report typed
echo 'center id=matrix' > $ui
sleep 2
matrix load sysmon
matrix edit
report second

# The editor asked directly: a file over unsaved text is refused, the
# file it holds already is not.
mkdir -p /tmp/ed
mount -A '#seditor/fs' /tmp/ed
if {echo open /lib/sh/profile > /tmp/ed/ctl} {
	echo R other taken > '#c/cons'
} {
	echo R other refused > '#c/cons'
}
if {echo open /lib/matrix/compositions/tk-demo > /tmp/ed/ctl} {
	echo R same taken > '#c/cons'
} {
	echo R same refused > '#c/cons'
}
echo R direct posted fs `{cat /tmp/ed/index} > '#c/cons'
# Its changes thrown away (`clean`), it takes the next file.
echo clean > /tmp/ed/1/ctl
if {echo open /lib/sh/profile > /tmp/ed/ctl} {
	echo R clean taken > '#c/cons'
} {
	echo R clean refused > '#c/cons'
}
echo R clean posted fs `{cat /tmp/ed/index} > '#c/cons'
unmount /tmp/ed
echo R done > '#c/cons'
echo halt > /dev/sysctl

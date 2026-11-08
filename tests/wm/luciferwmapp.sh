#!/dis/sh.dis
#
# wm/wm run as an app in Lucifer, then osk and About after it, for
# tests/host/lucifer_wmapp_test.sh (not a test itself).  wm/wm puts a
# window server of its own over /chan/wmctl; run in Lucifer's
# namespace, every app started after it was its client and not
# Lucifer's, and wm/wm broke when one went.  After each step it prints
# R, the step, and the processes that are broken.
#
fn step {
	sleep 6
	echo R $1 `{ps | grep -i broken | wc -l} >[1=2]
}
fn app {
	echo 'create id='^$1^' type=app dis=/dis/wm/'^$1^'.dis label='^$1 > /mnt/ui/activity/0/presentation/ctl
	echo 'center id='^$1 > /mnt/ui/activity/0/presentation/ctl
}
app wm
step wm
app osk
step osk
app about
step about
echo R status `{cat /mnt/ui/activity/0/presentation/about/appstatus} >[1=2]
echo R done >[1=2]
echo halt > '#c/sysctl'

#!/dis/sh.dis
#
# A tool call as tools9p makes it, and its control files, for
# tests/host/tools9p_call_test.sh (not a test: the runner runs every
# script in tests/inferno).  Each step's result is written under /tmp
# for the host test to check.
#
load std

path=(/dis/veltro /dis/cmd /dis .)
mkdir -p /tmp/veltro/scratch/0 /tmp/veltro/vproj
cp /dis/tests/spawnfake.dis /tmp/veltro/scratch/0/fds.dis
/dis/tests/spawnfake.dis ui /tmp/ui.log &
sleep 1
tools9p -b exec,read -p /mnt/acme:ro -p /tmp/veltro/vproj:ro exec read task json &
sleep 3

# what a call's command has open: exec runs a program of the scratch
# that lists its descriptors, beside other calls
for(i in 1 2 3 4 5 6) { echo /lib/veltro > /tool/read/ctl & }
echo '/tmp/veltro/scratch/fds.dis fds' > /tool/exec/ctl
cat /tool/exec/ctl > /tmp/r.fds

cat /tool/paths > /tmp/r.paths

# the budget, revoked in another case
cat /tool/budget > /tmp/r.budget.before
echo budget-remove Exec > /mnt/toolctl/ctl
cat /tool/budget > /tmp/r.budget

# a provisioning that is not under way is not cancelled
sh -c 'echo cancel 7 > /tool/provision' >[2] /tmp/err.cancel

# a create: the task tool's call is restricted like any other
sh -c 'echo ''create label=Probe paths=/nope/x brief=nothing'' > /tool/task/ctl' >[2] /tmp/err.create
cat /tool/task/ctl > /tmp/r.create
sh -c 'echo ''label=Probe2 paths=/nope/x brief=nothing'' > /tool/task/ctl' >[2] /tmp/err.create2
sh -c 'echo ''CREATE label=Probe3 paths=/nope/x brief=nothing'' > /tool/task/ctl' >[2] /tmp/err.create3

# a task made: the stores an earlier task of its number left are gone
# (the fake UI numbers every new activity 7), and no other's
for(d in /tmp/veltro/memory/7 /tmp/veltro/plans/a7 /tmp/veltro/memory/8 /tmp/veltro/plans/a8) {
	mkdir -p $d
	echo old > $d/old
}
{sh -c 'echo ''create label=Probe4 brief=nothing'' > /tool/task/ctl' >[2] /tmp/err.create4} &
sleep 6
ls /tmp/veltro/memory /tmp/veltro/plans > /tmp/r.stores >[2=1]

# a descriptor on a tool's ctl, held while that tool is removed and
# another added: it is not a descriptor on the new tool
{sleep 4; echo go} | /dis/tests/spawnfake.dis hold /tool/json/ctl /lib/veltro > /tmp/r.hold &
sleep 1
echo remove json > /mnt/toolctl/ctl
echo add list > /mnt/toolctl/ctl
sleep 5
echo /lib/veltro > /tool/list/ctl
cat /tool/list/ctl > /tmp/r.list

echo R done
echo halt > '#c/sysctl'

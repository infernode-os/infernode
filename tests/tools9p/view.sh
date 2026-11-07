#!/dis/sh.dis
#
# tools9p's view of the agent's name space, for
# tests/host/toolctl_view_test.sh (not a test: the runner runs every
# script in tests/inferno).  Each step's result is written under /tmp
# for the host test to check: /mnt/toolctl's files, the agent's root
# through view before and after a grant, ns before and after, the
# events a reader got, the errors writes through view got, a file read
# through it, and /tool as a tool call lists it.
#
load std

path=(/dis/veltro /dis/cmd /dis .)
tools9p -m /tool read list json &
sleep 2

ls /mnt/toolctl > /tmp/ls.ctl
cat /mnt/toolctl/event > /tmp/events &
sleep 1

mkdir -p /n/agent
mount -A /mnt/toolctl/view /n/agent
ls /n/agent > /tmp/root.before
cat /mnt/toolctl/ns > /tmp/ns.before
unmount /n/agent

echo bindpath /usr/inferno ro > /mnt/toolctl/ctl
echo remove json > /mnt/toolctl/ctl
sleep 1

mount -A /mnt/toolctl/view /n/agent
ls /n/agent/usr/inferno > /tmp/usr.after
cat /mnt/toolctl/ns > /tmp/ns.after
cat /n/agent/usr/inferno/README > /tmp/readme
# each in a shell of its own: a redirection refused ends the shell it is in
sh -c 'rm /n/agent/usr/inferno/README' >[2] /tmp/rm.err
# a remove clunks its fid even when it fails (remove(5)): if the view
# refused it without telling the export, the export kept the fid and
# the next walks that reuse its number were "fid in use"
for(i in 1 2 3 4 5) { sh -c 'rm /n/agent/usr/inferno/README' >[2] /dev/null }
for(i in `{seq 1 40}) { cat /n/agent/usr/inferno/README > /dev/null >[2] /tmp/afterrm.err.$i }
cat /tmp/afterrm.err.* > /tmp/afterrm.err
sh -c 'echo x > /n/agent/usr/inferno/README' >[2] /tmp/write.err
sh -c 'echo x > /n/agent/tmp/veltro/scratch/new' >[2] /tmp/create.err

echo /tool > /tool/list/ctl
cat /tool/list/ctl > /tmp/agenttool

echo R done
echo halt > '#c/sysctl'

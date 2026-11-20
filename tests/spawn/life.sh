#!/dis/sh.dis
#
# The spawn tool through a real tools9p, its subagents on a scripted
# model (tests/spawnfake.b), for tests/host/spawn_life_test.sh (not a
# test: the runner runs every script in tests/inferno).  Each call's
# result is written to /tmp/r.<name>, the model's log is copied at the
# moments the host test compares, and ps is taken at the end.
#
load std

path=(/dis/veltro /dis/cmd /dis .)
mkdir -p /tmp/usr/inferno/keep /tmp/llm
echo secret > /tmp/usr/inferno/keep/secret
bind -c /tmp/usr /usr
/dis/tests/spawnfake.dis llm /tmp/llm /tmp/llm.log &
sleep 1
bind /tmp/llm /mnt/llm
tools9p -b read,list,exec,plan,sms,dial,task -p /usr/inferno/keep:ro spawn read list &
sleep 3

fn call { echo $2 > /tool/spawn/ctl; cat /tool/spawn/ctl > /tmp/r.$1 }

# a parent's own call first, so that its tool has a last result to keep
echo /usr/inferno/keep/secret > /tool/read/ctl
cat /tool/read/ctl > /tmp/r.parentread

call text '-- tools=read :: SCENARIO:text go'
call probe '-- tools=read,list :: SCENARIO:probe go'
cp /tmp/llm.log /tmp/log.1

# refused, each before anything is started
call llm '-- tools=read paths=/mnt/llm :: SCENARIO:text go'
call outside '-- tools=read paths=/usr/inferno :: SCENARIO:text go'
call later '-- tools=plan :: SCENARIO:text a -- tools=exec paths=/usr/inferno/keep :: SCENARIO:text b'
call overflow 'timeout=3000000 -- tools=plan :: SCENARIO:text go'
# in the budget, and not a subagent's: their effect needs the user's approval
call sms '-- tools=read,sms :: SCENARIO:text go'
call dial '-- tools=dial :: SCENARIO:text go'
call task '-- tools=read,task :: SCENARIO:text go'
cp /tmp/llm.log /tmp/log.2

call granted '-- tools=read paths=/usr/inferno/keep :: SCENARIO:echo FILE:/usr/inferno/keep/secret go'

# a subagent that outlasts its timeout
call timeout 'timeout=2 -- tools=list :: SCENARIO:chatty go'
cp /tmp/llm.log /tmp/log.3
sleep 5
cp /tmp/llm.log /tmp/log.4

# a subagent that goes without a result
{call killed 'timeout=40 -- tools=plan :: SCENARIO:slow go'} &
sleep 3
/dis/tests/spawnfake.dis kill kill AgentLib > /tmp/r.killcmd
sleep 3

# a caller that goes in the middle of its call
/dis/tests/spawnfake.dis callkill /tool/spawn/ctl 1000 'timeout=3 -- tools=plan :: SCENARIO:slow go' > /tmp/r.callkill
sleep 4

# scheduled subagents
call sched '-- tools=list every=1s :: SCENARIO:ticktool go'
sleep 6
cp /tmp/llm.log /tmp/log.5
call cap1 '-- tools=plan every=1h :: SCENARIO:tick a -- tools=plan every=1h :: SCENARIO:tick b -- tools=plan every=1h :: SCENARIO:tick c -- tools=plan every=1h :: SCENARIO:tick d -- tools=plan every=1h :: SCENARIO:tick e'
call cap2 '-- tools=plan every=1h :: SCENARIO:tick a -- tools=plan every=1h :: SCENARIO:tick b -- tools=plan every=1h :: SCENARIO:tick c -- tools=plan every=1h :: SCENARIO:tick d'
ps > /tmp/ps.sched

# the tool server goes: killed, as a session's end kills it
/dis/tests/spawnfake.dis kill killgrp Tools9p > /tmp/r.killsrv
unmount /tool
unmount /mnt/toolctl
sleep 6
cp /tmp/llm.log /tmp/log.6
sleep 4
cp /tmp/llm.log /tmp/log.7
ps > /tmp/ps.end

echo R done
echo halt > '#c/sysctl'

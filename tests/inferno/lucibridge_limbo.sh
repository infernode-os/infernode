#!/dis/sh.dis
# End-to-end orchestrator → /tool/limbo → devstral test (headless).
#
# Drives a full Veltro session (luciuisrv + lucibridge + tools9p)
# against a remote serve-llm to verify that:
#   1. /mnt/llm 9P mount succeeds (multi-client serve-llm fix)
#   2. tools9p loads the limbo tool from the registry
#   3. lucibridge reads the remote configuration in /lib/ndb/llm so
#      it doesn't trip the first-run LLM-setup wizard
#   4. The orchestrator (whatever model serve-llm is configured for —
#      typically gpt-oss/low) dispatches /tool/limbo when asked for
#      Limbo authoring rather than attempting it itself
#   5. The limbo tool successfully calls devstral-limbo-v3 via a
#      private /mnt/llm session and returns Limbo source
#
# It needs a live serve-llm, which CI does not have, so it runs only
# when given one, as its argument; with none (as the test runner calls
# it) it skips.  The LLM configuration lucibridge reads is the test's
# own, written below from that argument, never the user's ~/.infernode:
#
#   emu -c1 -r$PWD sh /tests/inferno/lucibridge_limbo.sh 'tcp!host!5640'
#
# Caller greps the output for:
#   "lucibridge: llm: STOP:tool_use"  followed by  "TOOL:....:limbo:..."
#       → orchestrator dispatched limbo (architectural validation)
#   "lucibridge: tool limbo: done"
#       → limbo tool ran successfully, response came back
#   "role=veltro text=```limbo"
#       → assistant returned Limbo source to user

load std
if {~ $#* 0} {
	raise 'skip:needs a live serve-llm: sh /tests/inferno/lucibridge_limbo.sh <dial>'
}
llmdial=$1

bind -a '#I' /net
ndb/cs

# lucibridge's LLM configuration, the test's own: /lib/ndb/llm says
# remote at $llmdial, so lucibridge does not trip its first-run setup
# wizard (which would take the prompt below as a setup choice).
cfg=/tmp/lucibridge_limbo/ndb
mkdir -p $cfg
echo 'mode=remote' > $cfg/llm
echo 'dial='^$llmdial >> $cfg/llm
bind -bc $cfg /lib/ndb
echo LIB_NDB_LLM:
cat /lib/ndb/llm

echo MOUNTING $llmdial
if {! mount -A $llmdial /mnt/llm} {
	raise 'fail:cannot mount serve-llm at '^$llmdial
}

echo START_TOOLS9P
/dis/veltro/tools9p.dis -v -m /tool -b read,list,find,search,grep,write,edit,exec,launch,spawn,diff,json,webfetch,git,say,editor,fractal,memory,todo,plan,websearch,keyring,present,gap,limbo -p /dis/wm read list find present say hear task memory gap keyring editor shell limbo &
sleep 2
echo TOOL_REGISTRY:
cat /tool/tools

echo START_LUCIUISRV
luciuisrv &
sleep 1

echo CREATE_ACTIVITY
echo 'activity create OrchTest' > /mnt/ui/ctl
sleep 1

echo START_LUCIBRIDGE
lucibridge -v -a 0 -s &
sleep 3

echo SEND_PROMPT
echo 'Please write me a complete compileable Limbo hello-world program that prints hello, limbo and exits.' > /mnt/ui/activity/0/conversation/input

echo WAIT_FOR_RESPONSE
i=0
while {~ $i 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35} {
	sleep 5
	i=`{echo $i + 1 | calc}
	echo tick $i
}

echo CONVERSATION_DUMP
for n in 0 1 2 3 4 5 6 7 8 9 10 {
	if {ftest -e /mnt/ui/activity/0/conversation/$n} {
		echo --- msg $n ---
		cat /mnt/ui/activity/0/conversation/$n
	}
}
echo DONE_MARKER

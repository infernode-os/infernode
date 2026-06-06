#!/dis/sh.dis
# End-to-end orchestrator → /tool/limbo → devstral test (headless).
#
# Drives a full Veltro session (luciuisrv + lucibridge + tools9p)
# against the configured remote serve-llm to verify that:
#   1. /mnt/llm 9P mount succeeds (multi-client serve-llm fix)
#   2. tools9p loads the limbo tool from the registry
#   3. lucibridge picks up the user's .infernode overlay so it
#      doesn't trip the first-run LLM-setup wizard
#   4. The orchestrator (whatever model serve-llm is configured for —
#      typically gpt-oss/low) dispatches /tool/limbo when asked for
#      Limbo authoring rather than attempting it itself
#   5. The limbo tool successfully calls devstral-limbo-v3 via a
#      private /mnt/llm session and returns Limbo source
#
# Run with the Veltro/luciuisrv/lucibridge/tools9p stack already built
# into the host runtime tree (e.g. an InferNode dev bundle):
#
#   emu -c1 -r/tmp/InferNode-dev.app/Contents/Resources \
#       sh /tests/inferno/lucibridge_limbo.sh
#
# Caller greps the output for:
#   "lucibridge: llm: STOP:tool_use"  followed by  "TOOL:....:limbo:..."
#       → orchestrator dispatched limbo (architectural validation)
#   "lucibridge: tool limbo: done"
#       → limbo tool ran successfully, response came back
#   "role=veltro text=```limbo"
#       → assistant returned Limbo source to user

load std
mount -ac {mntgen} /n
bind -a '#I' /net
ndb/cs

echo TRFS
trfs '#U*' /n/local
ghome=/n/local/^`{echo 'echo $HOME' | os sh}
infhome=$ghome^/.infernode
echo HOME $ghome
echo INFHOME $infhome

# Bind the user's .infernode overlay over /lib/ndb so lucibridge
# sees the configured remote-9P dial address. Without this, the
# bundle's default /lib/ndb/llm says backend=api with no key, and
# lucibridge trips its first-run setup wizard which consumes the
# next user message as a "setup choice" instead of a real prompt.
if {ftest -d $infhome/lib/ndb} {
	echo BINDING_NDB_OVERLAY
	bind -bc $infhome/lib/ndb /lib/ndb
}
echo LIB_NDB_LLM:
cat /lib/ndb/llm

llmdial=`{sed -n 's/^dial=//p' /lib/ndb/llm}
if {~ $llmdial ''} {
	llmdial=tcp!10.243.169.78!5640
}
echo MOUNTING $llmdial
mount -A $llmdial /mnt/llm

echo START_TOOLS9P
/dis/veltro/tools9p.dis -v -m /tool -b read,list,find,search,grep,write,edit,exec,launch,spawn,diff,json,webfetch,git,say,editor,fractal,memory,todo,plan,websearch,mail,keyring,present,gap,limbo -p /dis/wm read list find present say hear task memory gap keyring editor shell limbo &
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

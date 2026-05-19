# InferNode GUI boot sequence
# Runs AFTER profile (invoked as: sh -l /lib/lucifer/boot.sh)

# Mobile (Android) font tuning.
#
# Lucifer and most UI elements (wm/shell, wm/editor, acme, xenith,
# charon, lucipres) open "/fonts/combined/unicode.14.font". On a ~388
# dpi phone screen that 14-point text is microscopic. emu/Android/os.c
# sets $emuhost to "Android" specifically so we can detect mobile
# here and bind a larger font over the default. The bind is at the
# file level so every consumer of unicode.14.font gets the bigger
# glyphs without code changes.
#
# Desktop boot ($emuhost == Linux / MacOSX / Nt) skips this block —
# 14pt is fine at 96dpi.
if {~ $emuhost Android} {
	# Two families to consider:
	#   unicode.14.font          — proportional sans-mono, used by wm/shell,
	#                              wm/editor, acme, xenith, charon, lucifer,
	#                              lucipres (anything with code/terminal
	#                              alignment). On mobile the alignment matters
	#                              less than legibility — bind sans.24 over
	#                              it. Trade-off: code columns won't align
	#                              under proportional rendering. Acceptable
	#                              for phone use; revisit when we generate
	#                              real larger mono glyphs from DejaVuSansMono.
	#   unicode.sans.* family    — proportional sans, used by wm/logon body
	#                              text, smallfont, Lucifer chat, Veltro
	#                              chrome. These respond cleanly to scale.
	#
	# Floor is sans.18 (small UI labels). Body text and anything previously
	# 14pt or 18pt goes to sans.24. Bold tier scales the same.
	bind /fonts/combined/unicode.sans.24.font /fonts/combined/unicode.14.font >[2] /dev/null
	bind /fonts/combined/unicode.sans.18.font /fonts/combined/unicode.sans.10.font >[2] /dev/null
	bind /fonts/combined/unicode.sans.18.font /fonts/combined/unicode.sans.12.font >[2] /dev/null
	bind /fonts/combined/unicode.sans.24.font /fonts/combined/unicode.sans.14.font >[2] /dev/null
	bind /fonts/combined/unicode.sans.24.font /fonts/combined/unicode.sans.18.font >[2] /dev/null
	bind /fonts/combined/unicode.sans.bold.18.font /fonts/combined/unicode.sans.bold.12.font >[2] /dev/null
	bind /fonts/combined/unicode.sans.bold.24.font /fonts/combined/unicode.sans.bold.14.font >[2] /dev/null
	bind /fonts/combined/unicode.sans.bold.24.font /fonts/combined/unicode.sans.bold.18.font >[2] /dev/null
}

# Warm trfs cache for the secstore overlay so logon and secstored can
# find PAK/factotum files on second launch (trfs may not have read-ahead
# the directory contents yet when the overlay bind was set up in profile).
user=`{cat /dev/user}
ls /usr/inferno/secstore >[2] /dev/null
if {! ~ $user ''} {
	ls /usr/inferno/secstore/$user >[2] /dev/null
}

# Login screen (unlocks secstore, loads keys into factotum)
wm/logon

# (Re-)start LLM service in the background.
#
# Local boot must NEVER block on remote InferNode availability — see
# docs/postmortems/2026-05-04-local-boot-decoupled-from-remote-llm.md.
# The previous version probed `ftest -f /n/llm/new`; that walk into a
# potentially-degraded 9P export blocks indefinitely (no protocol-level
# timeout) and wedges the entire desktop boot. Run the whole LLM setup
# in a backgrounded subshell so the desktop comes up regardless.
{
	llmmode=`{sed -n 's/^mode=//p' /lib/ndb/llm >[2] /dev/null}
	if {~ $llmmode remote} {
		llmdial=`{sed -n 's/^dial=//p' /lib/ndb/llm}
		mount -A $llmdial /n/llm >[2] /dev/null
	}{
		llmbackend=`{sed -n 's/^backend=//p' /lib/ndb/llm >[2] /dev/null}
		llmurl=`{sed -n 's/^url=//p' /lib/ndb/llm >[2] /dev/null}
		llmmodel=`{sed -n 's/^model=//p' /lib/ndb/llm >[2] /dev/null}
		if {~ $llmbackend openai} {
			llmsrv -b openai -u $llmurl -M $llmmodel >[2] /dev/null
		}{
			if {! ~ $llmmodel ''} {
				llmsrv -M $llmmodel >[2] /dev/null
			}{
				llmsrv >[2] /dev/null
			}
		}
	}
} &

# Wallet service
/dis/veltro/wallet9p.dis >[2] /dev/null &
sleep 1

# GUI services
luciuisrv
echo activity create Main > /n/ui/ctl
sleep 1
/dis/veltro/tools9p -v -m /tool -b read,list,find,search,grep,write,edit,exec,launch,spawn,diff,json,webfetch,git,say,editor,fractal,memory,todo,plan,websearch,mail,keyring,present,gap,limbo -p /dis/wm read list find present say hear task memory gap keyring editor shell limbo
lucibridge -a 0 -v -s >[2] /tmp/lucibridge.log &
sleep 1
echo 'create id=tasks type=taskboard label=Tasks' > /n/ui/activity/0/presentation/ctl
lucifer

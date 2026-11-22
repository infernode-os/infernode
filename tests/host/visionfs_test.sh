#!/bin/bash
#
# tests/host/visionfs_test.sh
#
# vision(4) (visionfs) as a file server, with a model of the test's own
# (tests/host/vision/tinymodel.py: one convolution whose biases are its
# answer, so every picture and frame has one known detection).  The
# tests with a real detector (vision_test.sh, vision_feed_test.sh) skip
# where its weights are not, and until this one visionfs's handlers had
# only been compiled.
#
#   - the root: ctl lists the model; ctl is its user's to write, not
#     everyone's (it was 666); load, unload and engine refuse what is
#     wrong, each saying why; a load that fails is answered
#   - a session: its files are its maker's (ctl 664, image 220,
#     detections 440: they were 666, 222 and 444, anyone's); settings
#     read back; every setting that is wrong refused and none of a write
#     with a wrong line done; no picture yet, an error
#   - a picture: its one detection, its box the picture, the class's
#     name quoted (it has a blank: bare, it was a record with a stray
#     word); a class filter; status and stats; a second picture
#   - a clip followed (src): every frame's record, in order, then the
#     end; read thirty bytes at a time, still every record whole (a
#     frame's records longer than a read were cut and the rest lost);
#     src none; a feed that is not one refused
#   - sixty-four sessions and no more (nothing counted them)
#   - a feed whose fmt never answers: the server goes on answering while
#     it waits, and the write is refused in the end (the fmt was read by
#     the server's one process, and every session stopped with it)
#
# What still needs a real model: what a detector finds (visnet_test.sh,
# vision_test.sh); what needs a Jetson: a session on the engine tree
# (trtsrv_test.sh).
#
# Run from project root: ./tests/host/visionfs_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
for f in visionfs.dis vid9p.dis read.dis; do
	[ -f "$ROOT/dis/$f" ] || { echo "SKIP: dis/$f not built"; exit 77; }
done
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 77; }

N=visionfs_test.$$
W="$ROOT/tmp/$N"
rm -rf "$W"
mkdir -p "$W/fake" "$W/pp"
trap '[ -n "${KEEP:-}" ] || rm -rf "$W"' EXIT
python3 -I "$ROOT/tests/host/vision/tinymodel.py" "$W" || { echo "FAIL: no model made"; exit 1; }
: > "$W/fake/fmt"
E=/tmp/$N

cat > "$W/run.sh" <<EOF
load std
if {! ftest -e /dis/lib/visnet.dis} {echo NO-VISNET; echo halt > '#c/sysctl'}
visionfs load m $E/model
echo '-- ctl'; cat /mnt/vision/ctl
echo '-- rootls'; ls -l /mnt/vision/ctl /mnt/vision/clone
echo '-- info'; cat /mnt/vision/models/m/info
echo '-- classes'; cat /mnt/vision/models/m/classes
echo '-- rootrefusals'
echo load > /mnt/vision/ctl
echo load 'a/b' $E/model > /mnt/vision/ctl
echo load m $E/model > /mnt/vision/ctl
echo load nowhere $E/nomodel > /mnt/vision/ctl
echo unload nosuch > /mnt/vision/ctl
echo engine $E/nomodel > /mnt/vision/ctl
echo frobnicate > /mnt/vision/ctl
echo '-- ctl after'; cat /mnt/vision/ctl
mkdir -p /n/clip
mount {vid9p $E/c.y4m} /n/clip
{
	id=\`{read}
	echo '-- session' \$id
	echo '-- sessls'; ls -l /mnt/vision/\$id
	echo '-- settings'; cat /mnt/vision/\$id/ctl
	echo '-- nopicture'; cat /mnt/vision/\$id/detections
	echo '-- sessrefusals'
	echo model nosuch > /mnt/vision/\$id/ctl
	echo thresh 2 > /mnt/vision/\$id/ctl
	echo thresh abc > /mnt/vision/\$id/ctl
	echo iou -1 > /mnt/vision/\$id/ctl
	echo classes unicorn > /mnt/vision/\$id/ctl
	echo place gpu > /mnt/vision/\$id/ctl
	echo rate -1 > /mnt/vision/\$id/ctl
	echo rate 2000 > /mnt/vision/\$id/ctl
	echo colour red > /mnt/vision/\$id/ctl
	echo src $E/nomodel > /mnt/vision/\$id/ctl
	echo src > /mnt/vision/\$id/ctl
	echo 'thresh 0.5
iou 7' > /mnt/vision/\$id/ctl
	echo '-- settings after'; cat /mnt/vision/\$id/ctl
	cat $E/p.ppm > /mnt/vision/\$id/image
	echo '-- detections'; cat /mnt/vision/\$id/detections
	echo '-- layer'; cat /mnt/vision/\$id/layer/vision.\$id
	echo '-- status'; cat /mnt/vision/\$id/status /mnt/vision/\$id/stats
	echo classes thing > /mnt/vision/\$id/ctl
	cat $E/p.ppm > /mnt/vision/\$id/image
	echo '-- filtered'; cat /mnt/vision/\$id/detections
	echo classes all > /mnt/vision/\$id/ctl
	cat $E/p.ppm > /mnt/vision/\$id/image
	echo '-- again'; cat /mnt/vision/\$id/detections; cat /mnt/vision/\$id/stats
	echo garbage > /mnt/vision/\$id/image
	echo '-- garbage'; cat /mnt/vision/\$id/detections
	echo '-- clip'
	{ echo src /n/clip/0 > /mnt/vision/\$id/ctl; cat } < /mnt/vision/\$id/detections
	echo '-- clipstatus'; cat /mnt/vision/\$id/status /mnt/vision/\$id/stats
	echo '-- pieces'
	{ echo src /n/clip/0 > /mnt/vision/\$id/ctl
	  for i in 0 1 2 3 4 5 6 7 8 9 { for j in 0 1 2 3 4 5 { read 30 } } } < /mnt/vision/\$id/detections
	echo
	echo src none > /mnt/vision/\$id/ctl
	echo '-- idle'; cat /mnt/vision/\$id/status
	echo '-- in the tree'; ls /mnt/vision
} < /mnt/vision/clone
echo '-- after'; ls /mnt/vision
echo '-- many'
for i in 0 1 2 3 4 5 6 { for j in 0 1 2 3 4 5 6 7 8 9 {
	{read > /dev/null; sleep 7} < /mnt/vision/clone &
} }
sleep 3
ls /mnt/vision | grep '/[0-9]' | wc -l
sleep 6
echo '-- stall'
bind '#|' $E/pp
bind $E/pp/data $E/fake/fmt
{
	id=\`{read}
	echo src $E/fake > /mnt/vision/\$id/ctl >[2] $E/stall.err &
	sleep 2
	cat /mnt/vision/\$id/status > $E/stall.status &
	sleep 2
	echo STALL-CHECKED
	sleep 9
	cat $E/stall.err
	echo STALL-END
} < /mnt/vision/clone
echo '-- END'
echo halt > '#c/sysctl'
EOF
with_timeout 120 "$EMU" -c1 -r"$ROOT" /dis/sh.dis "$E/run.sh" > "$W/log" 2>&1 < /dev/null

fail=0
ok()   { echo "PASS: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }
part() { sed -n "/^-- $1\$/,/^-- /p" "$W/log" | grep -v '^-- '; }
inpart() { part "$1" | grep -q -- "$2"; }
want() { inpart "$2" "$3" && ok "$1" || bad "$1 (no '$3' in '$2': $(part "$2" | head -3 | tr '\n' '|'))"; }

if grep -q '^NO-VISNET' "$W/log"; then echo "SKIP: no visnet in this build"; exit 77; fi
if ! grep -q '^STALL-CHECKED' "$W/log"; then
	echo "FAIL: the session did not finish"; grep -v fsqid "$W/log" | tail -15; exit 1
fi

# the root
want "ctl lists the model" ctl "^model m "
part rootls | grep 'ctl$' | grep -q '^--rw-rw-r--' && ok "the root's ctl is its user's to write" ||
	bad "the root's ctl: $(part rootls | grep 'ctl$')"
want "a model's info" info "^kind=detect decode=yolox input=32x32 classes=2 "
[ "$(part classes | tr '\n' '|')" = "thing|traffic light|" ] && ok "a model's classes" || bad "classes: $(part classes | tr '\n' '|')"
want "load with no name refused" rootrefusals "usage: load name dir"
want "a model's name is no path" rootrefusals "letters, digits"
want "a model loaded twice refused" rootrefusals "loaded already"
want "a load that fails is answered, saying why" rootrefusals "nomodel"
want "unload of no model refused" rootrefusals "no model nosuch"
want "an engine tree that is not one refused" rootrefusals "no engine tree there"
want "an unknown command refused" rootrefusals "unknown command frobnicate"
[ "$(part 'ctl after' | grep -c '^model ')" = 1 ] && ok "the refused loads loaded nothing" || bad "ctl after: $(part 'ctl after' | tr '\n' '|')"

# a session
part sessls | grep '/ctl$' | grep -q '^--rw-rw-r--' && part sessls | grep '/image$' | grep -q '^---w--w----' &&
	part sessls | grep '/detections$' | grep -q '^--r--r-----' &&
	ok "a session's files are its maker's (ctl 664, image 220, detections 440)" ||
	bad "a session's files: $(part sessls | awk '{print $1, $NF}' | tr '\n' '|')"
[ "$(part settings | tr '\n' '|')" = "model m|place cpu|thresh 0.30|iou 0.45|classes all|src none|rate 0|" ] &&
	ok "a session's settings" || bad "settings: $(part settings | tr '\n' '|')"
want "detections before any picture: an error" nopicture "no picture yet"
for r in "no model nosuch" "thresh: a number from 0 to 1" "iou: a number from 0 to 1" "has no class unicorn" \
	"place gpu: not one of cpu" "rate: frames a second" "unknown setting colour" "nomodel/fmt" "usage: src"; do
	want "refused: $r" sessrefusals "$r"
done
[ "$(part sessrefusals | grep -c 'thresh: a number')" = 2 ] && ok "a threshold that is no number refused" || bad "thresh abc"
[ "$(part 'settings after' | tr '\n' '|')" = "model m|place cpu|thresh 0.30|iou 0.45|classes all|src none|rate 0|" ] &&
	ok "a write with a wrong line: none of it done" || bad "settings after: $(part 'settings after' | tr '\n' '|')"

# a picture
det="^class='traffic light' score=0.8[56] x0=0 y0=0 x1=48 y1=32\$"
[ "$(part detections | grep -c .)" = 1 ] && inpart detections "$det" &&
	ok "a picture's detection, its class's name quoted: $(part detections)" || bad "detections: $(part detections | tr '\n' '|')"
inpart layer "$det" && ok "the same as a layer" || bad "layer: $(part layer | tr '\n' '|')"
want "status: ready" status "^state=ready model=m"
want "stats: one picture, one found" status "^images=1 found=1 "
[ -z "$(part filtered)" ] && ok "a class filter: the other class's detection left out" || bad "filtered: $(part filtered)"
inpart again "$det" && inpart again "^images=3 found=1 " && ok "a third picture, all classes again" || bad "again: $(part again | tr '\n' '|')"
[ -n "$(part garbage)" ] && ! inpart garbage "class=" && ok "what is no picture: an error, saying why: $(part garbage | head -1)" || bad "garbage: $(part garbage)"

# a clip
n=$(part clip | grep -c "^frame=[0-7] pts=[0-9]* class='traffic light' score=0.8[56] x0=0 y0=0 x1=48 y1=32\$")
[ "$n" = 8 ] && [ "$(part clip | sed 's/ .*//' | tr '\n' ' ')" = "frame=0 frame=1 frame=2 frame=3 frame=4 frame=5 frame=6 frame=7 " ] &&
	ok "a clip followed: its eight frames' records, in order, then the end" || bad "clip: $n records: $(part clip | head -3 | tr '\n' '|')"
want "status: the feed ended" clipstatus "^state=ended model=m src=/n/clip/0"
want "stats: eight frames in, eight looked at" clipstatus "^in=8 inferred=8 skipped=0 "
n=$(part pieces | grep -c "^frame=[0-7] pts=[0-9]* class='traffic light' score=0.8[56] x0=0 y0=0 x1=48 y1=32\$")
[ "$n" = 8 ] && ok "read thirty bytes at a time: every record whole" ||
	bad "read thirty bytes at a time: $n records whole of 8: $(part pieces | head -3 | tr '\n' '|')"
want "src none: idle" idle "^state=idle model=m\$"
part 'in the tree' | grep -q '/[0-9][0-9]*$' && ! part after | grep -q '/[0-9][0-9]*$' &&
	ok "the session in the tree while its files are open, gone after" || bad "tree: $(part 'in the tree' | tr '\n' ' ') after: $(part after | tr '\n' ' ')"

# sessions counted
n=$(part many | grep '^ *[0-9][0-9]*$' | head -1 | tr -d ' ')
[ "$n" = 64 ] && inpart many "too many sessions" && ok "sixty-four sessions and no more (seventy asked for)" ||
	bad "seventy clones: $n sessions; $(part many | grep -v '^ *[0-9]*$' | head -2 | tr '\n' '|')"

# a feed that does not answer
if [ -s "$W/stall.status" ] && grep -q '^state=' "$W/stall.status"; then
	ok "a feed whose fmt never answers: the server answers while it waits ($(cut -d' ' -f1 "$W/stall.status"))"
else
	bad "a feed whose fmt never answers: status was not answered: the server waits with it"
fi
if grep -q '^STALL-END' "$W/log"; then
	grep -q 'no answer in' "$W/stall.err" && ok "and the src is refused in the end: $(sed 's/.*src: //' "$W/stall.err" | head -1)" ||
		bad "the src was not refused: '$(cat "$W/stall.err" 2>/dev/null)'"
else
	bad "the session did not finish after the stalled feed"
fi

[ $fail = 0 ] && echo "visionfs_test: ALL PASS"
exit $fail

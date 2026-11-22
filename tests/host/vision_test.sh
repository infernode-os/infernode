#!/bin/bash
#
# tests/host/vision_test.sh
#
# vision(4) (visionfs) and vision(1)'s filters with a real detector:
#
#   - the files: ctl's engine, places and model, a model's info and
#     classes, a session from clone, its settings as read, a picture
#     written to image and its detections (and its layer), the same with
#     a class filter, status and stats; refusals for an unknown model,
#     class, setting and threshold, a feed that is not there, a second load
#     of one name, and a model whose weights are not the ones recorded;
#     the session gone when its files are closed
#   - the pipelines: vision/detect over a directory with two sessions at
#     once, in the order named; vision/draw writing PNGs and image(6);
#     grep, vision/crop and vision/detect again on the crops
#
# Needs a model directory (tools/vision/onnx2vis.py) and a picture of a
# dog, a bicycle and a car (YOLOX's assets/dog.jpg):
#
#   VISION_MODEL    the model directory
#   VISION_PICTURE  the picture
#
# Skips if either is missing.
#
# Run from project root: ./tests/host/vision_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

for v in VISION_MODEL VISION_PICTURE; do
	[ -n "${!v:-}" ] && [ -e "${!v}" ] || { echo "SKIP: $v not set to something that exists"; exit 77; }
done
[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
for f in visionfs.dis vision/detect.dis vision/draw.dis vision/crop.dis; do
	[ -f "$ROOT/dis/$f" ] || { echo "SKIP: dis/$f not built"; exit 77; }
done

W="$ROOT/tmp/vision_test.$$"
rm -rf "$W"
mkdir -p "$W/pics" "$W/out" "$W/dogs" "$W/badmodel"
trap 'rm -rf "$W"' EXIT
cp "$VISION_PICTURE" "$W/pics/a.jpg"
cp "$VISION_PICTURE" "$W/pics/b.jpg"
# a model whose weights are not the ones its sha256 names
cp "$VISION_MODEL"/{graph,info,classes,sha256} "$W/badmodel/"
head -c 4096 "$VISION_MODEL/weights" > "$W/badmodel/weights"

E=/tmp/h$W
M=/tmp/h$VISION_MODEL
cat > "$W/run.sh" <<EOF
mkdir -p /tmp/h
bind '#U*' /tmp/h
visionfs load m $M
echo '-- ctl'; cat /mnt/vision/ctl
echo '-- info'; cat /mnt/vision/models/m/info
echo '-- nclasses'; cat /mnt/vision/models/m/classes | wc -l
echo load bad $E/badmodel > /mnt/vision/ctl
echo load m $M > /mnt/vision/ctl
{
	id=\`{read}
	echo '-- session' \$id
	cat /mnt/vision/\$id/ctl
	cat $E/pics/a.jpg > /mnt/vision/\$id/image
	echo '-- detections'; cat /mnt/vision/\$id/detections
	echo '-- layer'; cat /mnt/vision/\$id/layer/vision.\$id
	echo classes dog car > /mnt/vision/\$id/ctl
	cat $E/pics/a.jpg > /mnt/vision/\$id/image
	echo '-- filtered'; cat /mnt/vision/\$id/detections
	echo '-- status'; cat /mnt/vision/\$id/status /mnt/vision/\$id/stats
	echo '-- refusals'
	echo model nosuch > /mnt/vision/\$id/ctl
	echo classes unicorn > /mnt/vision/\$id/ctl
	echo thresh 2 > /mnt/vision/\$id/ctl
	echo colour red > /mnt/vision/\$id/ctl
	echo src /mnt/video/0 > /mnt/vision/\$id/ctl
	echo '-- in the tree'; ls /mnt/vision
} < /mnt/vision/clone
echo '-- after'; ls /mnt/vision
cd $E
echo '-- detect'
ls pics/* | vision/detect -j 2 | tee all.txt
echo '-- draw'
vision/draw -d out -o png < all.txt
vision/detect -c car pics/a.jpg | vision/draw -d out
echo '-- crop'
grep 'class=dog' all.txt | vision/crop -d dogs -o png | vision/detect -t 0.2
echo '-- END'
echo halt > '#c/sysctl'
EOF
with_timeout 600 "$EMU" -c1 -r"$ROOT" sh -c "mkdir -p /tmp/h; bind '#U*' /tmp/h; sh /tmp/h$W/run.sh" > "$W/log" 2>&1 < /dev/null

fail=0
ok()   { echo "PASS: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }
has()  { grep -q -- "$2" "$W/log" && ok "$1" || bad "$1 (no '$2' in the log)"; }

grep -q -- '^-- END' "$W/log" || { echo "FAIL: the session did not finish"; tail -20 "$W/log"; exit 1; }
has "ctl names the engine" '^engine cpu$'
has "ctl names the model and its directory" "^model m $M\$"
has "a model's info" '^kind=detect decode=yolox input=416x416 classes=80 order=bgr fill=114 places=cpu sha256='
has "a model's 80 classes" '^ *80$'
has "weights not the ones recorded are refused" 'weights do not match their sha256 (cb3176c547bb2f3e\.\.\., want '
has "a second load of a name is refused" 'model m is loaded already'
has "a session's settings, as read" '^thresh 0.30$'
has "the dog found" '^class=dog score=0.86 x0=133 y0=207 x1=326 y1=543$'
has "the bicycle found" '^class=bicycle score=0.80 '
has "the car found" '^class=car score=0.80 '
n=$(sed -n '/^-- layer/,/^-- filtered/p' "$W/log" | grep -c '^class=')
[ "$n" = 4 ] && ok "the layer holds the detections" || bad "the layer has $n records, want 4"
n=$(sed -n '/^-- filtered/,/^-- status/p' "$W/log" | grep '^class=' | cut -d' ' -f1 | sort -u | tr '\n' ' ')
[ "$n" = "class=car class=dog " ] && ok "classes dog car keeps those" || bad "the filter kept: $n"
has "status says ready" '^state=ready model=m$'
has "stats count the pictures" '^images=2 found=2 ms='
has "an unknown model is refused" 'write error: no model nosuch'
has "an unknown class is refused" 'write error: classes: m has no class unicorn'
has "a threshold past 1 is refused" 'write error: thresh: a number from 0 to 1'
has "an unknown setting is refused" 'write error: unknown setting colour'
has "a feed that is not there is refused, saying why" 'write error: src: /mnt/video/0/fmt'
sed -n '/^-- in the tree/,/^-- after/p' "$W/log" | grep -q '^/mnt/vision/1$' && ok "the session is in the tree" || bad "the session is not in the tree"
sed -n '/^-- after/,/^-- detect/p' "$W/log" | grep -q '^/mnt/vision/1$' && bad "the session outlived its files" || ok "the session goes with its files"
n=$(sed -n '/^-- detect/,/^-- draw/p' "$W/log" | grep -c '^file=')
first=$(sed -n '/^-- detect/,/^-- draw/p' "$W/log" | grep '^file=' | head -1 | cut -d' ' -f1)
[ "$n" = 8 ] && [ "$first" = "file=pics/a.jpg" ] && ok "vision/detect, two sessions, in the order named" || bad "vision/detect: $n records, first $first"
for f in out/a.jpg.png out/b.jpg.png; do
	head -c 8 "$W/$f" | od -An -tx1 | grep -q '89 50 4e 47 0d 0a 1a 0a' && ok "vision/draw wrote $f, a PNG" || bad "$f is not a PNG"
done
head -c 60 "$W/out/a.jpg.bit" | grep -q 'r8g8b8' && [ "$(stat -c %s "$W/out/a.jpg.bit")" = $((60 + 3*768*576)) ] &&
	ok "vision/draw wrote an image(6) of the whole picture" || bad "out/a.jpg.bit is not a whole image(6)"
n=$(sed -n '/^-- crop/,/^-- END/p' "$W/log" | grep -c '^file=dogs/a.jpg.0.png class=dog')
[ "$n" = 1 ] && ok "a dog cut out by vision/crop is a dog again" || bad "the crop: $(sed -n '/^-- crop/,/^-- END/p' "$W/log" | head -3 | tr '\n' ' ')"
exit $fail

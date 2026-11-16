#!/bin/sh
#
# tests/host/keyfs_file_test.sh
#
# keyfs(4) and its key file, with a real auth/keyfs on files the test
# makes and reads back with tests/host/keyfs/kf.py (written from the
# manual page, with Python's cryptography: the control).
#
# The file was Plan 9's aescbc: AES-128-CBC under one unsalted SHA-1 of
# the master key, sixteen X's as its only check, rewritten in place, its
# mode whatever its maker's was. So:
#   - a file in that format is still read, and written at the next change
#     in the new one (PBKDF2-HMAC-SHA-384 with a salt, AES-256-GCM), which
#     the old recipe does not open and the manual's new one does;
#   - a byte changed anywhere in the new file, a file cut short, and
#     another key are refused, and nothing is served (a byte changed in
#     the old one made a disabled account ok);
#   - an emulator ended in the middle of a change leaves the file as it
#     was (it left it empty, which the next start took for a new store),
#     and a change that got as far as removing the old file is finished
#     at the next start;
#   - the file is mode 600 after a start, and after a change;
#   - an entry that is not one (a status that is neither, a name or a
#     secret running past the end, a name twice, a count that is wrong)
#     is refused at the start, naming the entry (a status of 2 was taken,
#     and the first read of the status file stopped the server);
#   - a name too long for an entry is refused when made or renamed to
#     (the server stopped); an expiry time that does not fit is refused
#     (it was stored as another); a count of failures stays what it was
#     across a restart (300 came back as 44);
#   - with more than 4096 users each has its own files (the 4097th had
#     another's);
#   - an empty file is a new store, said to be one, and keyfs leaves no
#     file empty (a store with no users is still a file under its key);
#   - no clock, no keyfs (no account would expire);
#   - at the console: a key of 300 characters is refused as too long (an
#     array bounds error), a confirmation that differs is refused, a key
#     typed twice starts a new store.
#
# Skips (exit 77) with no emulator, no python3 or no cryptography.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/auth/keyfs.dis" ] || { echo "SKIP: dis/auth/keyfs.dis not built"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 77; }
python3 -c 'import cryptography' 2>/dev/null || { echo "SKIP: no Python cryptography"; exit 77; }

KF="$(cd "$(dirname "$0")" && pwd)/keyfs/kf.py"
DIR="$ROOT/tmp/keyfs_file.$$"
G="/tmp/keyfs_file.$$"
mkdir -p "$DIR"
trap 'rm -rf "$DIR"' EXIT
PW=masterpw
printf '%s' "$PW" > "$DIR/nvram"
printf 'another key' > "$DIR/nvram2"

rc=0
bad() { echo "FAIL: $1"; rc=1; }
ok() { echo "PASS: $1"; }
kf() { python3 "$KF" "$@"; }
mode() { ls -l "$1" | cut -c1-10; }
# run an Inferno script (its body on standard input) and print what it says
emu() {
	{ echo "load std"; cat; echo "echo halt > /dev/sysctl"; } > "$DIR/script.$1"
	with_timeout "${2:-60}" "$EMU" -r"$ROOT" -c1 sh "$G/script.$1" 2>&1 < /dev/null || true
}
has() { echo "$OUT" | grep -q -e "$1"; }
# check NAME PATTERN: OUT has a line matching it
check() {
	if has "$2"; then ok "$1"; else bad "$1: $(echo "$OUT" | grep -v fsqid | tail -4 | cut -c1-200 | tr '\n' '|')"; fi
}

SEC=00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff

# --- an old file is read as it is, its mode put right
kf make "$DIR/keys" $PW  1 0 0 alice $SEC  0 0 1700000000 bob $SEC  0 3 0 carol 4343
chmod 644 "$DIR/keys"
cp "$DIR/keys" "$DIR/keys.orig"
for m in a b c d e; do mkdir -p "$DIR/mnt.$m"; done
OUT=$(emu a <<EOF
auth/keyfs -n $G/nvram -m $G/mnt.a $G/keys
echo A-started: \$status.
echo A-status: \`{cat $G/mnt.a/alice/status} \`{cat $G/mnt.a/bob/status} \`{cat $G/mnt.a/carol/status} \`{cat $G/mnt.a/carol/log} \`{cat $G/mnt.a/carol/secret}
EOF
)
check "a file in the old format is read" '^A-status: disabled expired ok 3 CC$'
check "and keyfs says it is the old format" 'keyfs: .*old format'
check "and that its mode was open to others" 'keyfs: .*had mode 644'
if cmp -s "$DIR/keys" "$DIR/keys.orig"; then ok "reading it does not change it"; else bad "the old file was rewritten by a start"; fi
[ "$(mode "$DIR/keys")" = "-rw-------" ] && ok "its mode is 600 after the start" || bad "mode after a start: $(mode "$DIR/keys")"

# --- the next change writes the new format
OUT=$(emu b <<EOF
auth/keyfs -n $G/nvram -m $G/mnt.b $G/keys
echo ok > $G/mnt.b/alice/status
echo B-wrote: \$status.
EOF
)
check "a change is taken" '^B-wrote: \.$'
D=$(kf dumpold "$DIR/keys" $PW)
[ "$D" = "old recipe: no" ] && ok "the file is no longer opened by SHA1(\"aescbc file\"+key) and AES-CBC" || bad "the old recipe still opens the file: $D"
D=$(kf dumpnew "$DIR/keys" $PW)
if echo "$D" | grep -q '^new recipe: yes, 200000 iterations, 3 entries$' && echo "$D" | grep -q "^0 0 0 alice $SEC\$" &&
   echo "$D" | grep -q "^0 0 1700000000 bob $SEC\$" && echo "$D" | grep -q '^0 3 0 carol 4343$'; then
	ok "it is the manual's new format, with the change in it"
else
	bad "the manual's new recipe gives: $(echo "$D" | tr '\n' '|')"
fi
[ "$(mode "$DIR/keys")" = "-rw-------" ] && ok "the new file is mode 600" || bad "mode of the new file: $(mode "$DIR/keys")"
[ ! -e "$DIR/keys.new" ] && ok "nothing is left beside it" || bad "keys.new was left"
kf dumpnew "$DIR/keys" wrongpw >/dev/null && bad "the control opens the file with another key"

# --- the new file read back; changed, cut and under another key refused
size=$(wc -c < "$DIR/keys" | tr -d ' ')
cp "$DIR/keys" "$DIR/k.good"
for o in 0 8 11 20 30 40 $((size-17)) $((size-1)); do
	cp "$DIR/keys" "$DIR/k.x$o"; kf xor "$DIR/k.x$o" $o 1
done
head -c 64 "$DIR/keys" > "$DIR/k.t64"
head -c 43 "$DIR/keys" > "$DIR/k.t43"
head -c $((size-1)) "$DIR/keys" > "$DIR/k.tlast"
VARIANTS="x0 x8 x11 x20 x30 x40 x$((size-17)) x$((size-1)) t64 t43 tlast"
OUT=$(emu c 120 <<EOF
auth/keyfs -n $G/nvram -m $G/mnt.c $G/k.good
echo C-good: \$status. \`{cat $G/mnt.c/alice/status} \`{cat $G/mnt.c/bob/status} \`{cat $G/mnt.c/carol/status}
mkdir $G/m.key
auth/keyfs -n $G/nvram2 -m $G/m.key $G/k.good
echo C-key: \$status. \`{ls $G/m.key}
for v in $VARIANTS {
	mkdir $G/m.\$v
	auth/keyfs -n $G/nvram -m $G/m.\$v $G/k.\$v
	echo C-\$v: \$status. \`{ls $G/m.\$v}
}
EOF
)
check "the new file is read back" '^C-good: \. ok expired ok$'
check "another key is refused, nothing served" '^C-key: error\. *$'
for v in $VARIANTS; do
	case $v in
	x*)	what="byte ${v#x} changed" ;;
	*)	what="cut short ($v)" ;;
	esac
	check "$what: refused, nothing served" "^C-$v: error\\. *\$"
done
n=$(echo "$OUT" | grep -c 'incorrect key or corrupt/damaged keyfile')
[ "$n" = 12 ] && ok "each refusal says the key is wrong or the file damaged" || bad "$n of 12 refusals said why"

# --- entries that are not entries
ent() { python3 -c "
import sys
n=sys.argv[1].encode(); s=bytes.fromhex(sys.argv[4])
print((bytes([int(sys.argv[2]),0])+int(sys.argv[3]).to_bytes(4,'little')+bytes([len(n)])+n+bytes([len(s)])+s).hex())" "$@"; }
A=$(ent alice 0 0 4141); B=$(ent bob 0 0 4242); S2=$(ent sam 2 0 4343); SL=$(ent a/b 0 0 4444)
kf makeraw "$DIR/p.ostatus" $PW "$A$S2"		# old format, status 2
kf makenewraw "$DIR/p.status" $PW 1000 2 "$A$S2"
kf makenewraw "$DIR/p.count" $PW 1000 3 "$A$B"
kf makenewraw "$DIR/p.more" $PW 1000 1 "$A$B"
kf makenewraw "$DIR/p.twice" $PW 1000 3 "$A$B$A"
kf makenewraw "$DIR/p.slash" $PW 1000 2 "$A$SL"
kf makenewraw "$DIR/p.name" $PW 1000 2 "${A}0000000000ff6161"
kf makenewraw "$DIR/p.secret" $PW 1000 2 "${A}00000000000162ff41"
kf makenewraw "$DIR/p.utf" $PW 1000 1 "00000000000002c32800"
kf makenewraw "$DIR/p.fine" $PW 1000 2 "$A$B"
PARSE="ostatus status count more twice slash name secret utf"
OUT=$(emu d 120 <<EOF
for v in $PARSE fine {
	mkdir $G/m.p\$v
	auth/keyfs -n $G/nvram -m $G/m.p\$v $G/p.\$v
	echo D-\$v: \$status. \`{ls $G/m.p\$v}
}
EOF
)
check "a file made by the control is read (1000 iterations, as its header says)" "^D-fine: \\. $G/m.pfine/alice $G/m.pfine/bob\$"
for v in $PARSE; do
	check "not an entry ($v): refused at the start, nothing served" "^D-$v: error\\. *\$"
done
check "a status that is neither ok nor disabled is named" 'p.ostatus: entry 1: sam: status 2'
check "an entry short of the count is named" 'p.count: entry 2: '
check "a name twice is named" 'p.twice: entry 2: alice: a second entry'
check "bytes after the last entry are refused" 'p.more: .* after the last of 1 entries'
if has 'Broken'; then bad "a file's bytes raised an exception: $(echo "$OUT" | grep Broken | head -2)"; else ok "no exception from any of them"; fi

# --- names, expiry times, the count of failures
LONG=$(python3 -c "print('一'*86)")
A256=$(python3 -c "print('a'*256)")
A255=$(python3 -c "print('b'*255)")
kf make "$DIR/e.keys" $PW  0 0 0 alice 4141  0 250 0 bob 4242
OUT=$(emu e <<EOF
auth/keyfs -n $G/nvram -m $G/mnt.e $G/e.keys
mkdir $G/mnt.e/$LONG
echo E-longmk: \$status.
echo E-ls1: \`{ls $G/mnt.e}
mv $G/mnt.e/alice $G/mnt.e/$A256
echo E-longmv: \$status.
echo E-ls2: \`{ls $G/mnt.e}
mkdir $G/mnt.e/$A255
echo E-255: \$status.
echo 4294967296 > $G/mnt.e/alice/expire
echo E-exp1: \$status. \`{cat $G/mnt.e/alice/expire}
echo 99999999999999999999 > $G/mnt.e/alice/expire
echo E-exp2: \$status. \`{cat $G/mnt.e/alice/expire}
echo 2147483647 > $G/mnt.e/alice/expire
echo E-exp3: \$status. \`{cat $G/mnt.e/alice/expire}
for i in 1 2 3 4 5 6 7 8 9 10 { echo bad > $G/mnt.e/bob/log }
echo E-log: \`{cat $G/mnt.e/bob/log} \`{cat $G/mnt.e/bob/status}
mkdir $G/mnt.e2
auth/keyfs -n $G/nvram -m $G/mnt.e2 $G/e.keys
echo E-log2: \`{cat $G/mnt.e2/bob/log} \`{cat $G/mnt.e2/bob/status} \`{cat $G/mnt.e2/alice/expire}
EOF
)
if has '^E-longmk: \.$'; then bad "a name of 258 bytes was made"; else ok "a name of 86 runes and 258 bytes is refused"; fi
check "and the server still answers" "^E-ls1: $G/mnt.e/alice $G/mnt.e/bob\$"
if has '^E-longmv: \.$'; then bad "a user was renamed to a name of 256 bytes"; else ok "a rename to a name of 256 bytes is refused"; fi
check "and the server still answers" "^E-ls2: $G/mnt.e/alice $G/mnt.e/bob\$"
check "a name of 255 bytes is taken" '^E-255: \.$'
check "an expiry time past 31 bits is refused, the old one kept" '^E-exp1: ..*\. never$'
check "and one of twenty digits" '^E-exp2: ..*\. never$'
check "the largest that fits is taken" '^E-exp3: \. 2147483647$'
check "a count of failures stops at 255 and disables the account" '^E-log: 255 disabled$'
check "and is the same after a restart, with the expiry time" '^E-log2: 255 disabled 2147483647$'

# --- more than 4096 users
kf many "$DIR/f.keys" $PW 4097
OUT=$(emu f 120 <<EOF
auth/keyfs -n $G/nvram -m $G/mnt.c $G/f.keys
echo F-first: \`{cat $G/mnt.c/u4096/status} .
rm $G/mnt.c/u0
mkdir $G/mnt.c/mallory
echo -n MMMM > $G/mnt.c/mallory/secret
echo F-secret: \`{cat $G/mnt.c/u4096/status} \`{cat $G/mnt.c/u4096/secret} .
echo -n VVVV > $G/mnt.c/u4096/secret
echo F-mallory: \`{cat $G/mnt.c/mallory/secret} \`{cat $G/mnt.c/u4096/secret} .
EOF
)
check "the 4097th user has files" '^F-first: ok \.$'
check "which are not the files of the user made in the first slot" '^F-secret: ok \.$'
check "nor that user's this one's" '^F-mallory: MMMM VVVV \.$'

# --- an emulator ended in the middle of a change
kf make "$DIR/g.keys" $PW  0 0 0 alice $SEC  0 0 0 bob 4242
cp "$DIR/g.keys" "$DIR/g.orig"
{ echo "load std"
  echo "auth/keyfs -n $G/nvram -m $G/mnt.d $G/g.keys"
  echo "echo G-started: \$status."
  echo "echo disabled > $G/mnt.d/alice/status"
  echo "echo G-survived"
  echo "echo halt > /dev/sysctl"; } > "$DIR/script.g"
# no file may grow: the write of the change ends the emulator (SIGXFSZ)
OUT=$( (ulimit -f 0; with_timeout 60 "$EMU" -r"$ROOT" -c1 sh "$G/script.g" 2>&1 < /dev/null | cat) || true)
if has '^G-started: \.$' && ! has 'G-survived'; then
	if cmp -s "$DIR/g.keys" "$DIR/g.orig"; then
		ok "an emulator ended as it wrote a change leaves the file whole"
	else
		bad "the file after the emulator ended in a change is $(wc -c < "$DIR/g.keys" | tr -d ' ') bytes, not the $(wc -c < "$DIR/g.orig" | tr -d ' ') it was"
	fi
	OUT=$(emu g2 <<EOF
auth/keyfs -n $G/nvram -m $G/mnt.d $G/g.keys
echo G-again: \$status. \`{cat $G/mnt.d/alice/status} \`{cat $G/mnt.d/bob/secret}
echo disabled > $G/mnt.d/alice/status
echo G-change: \$status. \`{cat $G/mnt.d/alice/status}
EOF
)
	check "the next start has every user" '^G-again: \. ok BB$'
	check "and takes the change" '^G-change: \. disabled$'
	D=$(kf dumpnew "$DIR/g.keys" $PW)
	echo "$D" | grep -q "^1 0 0 alice $SEC\$" && [ ! -e "$DIR/g.keys.new" ] && ok "which is in the file, with nothing left beside it" ||
		bad "after the change: $(echo "$D" | tr '\n' '|') $(ls "$DIR" | grep g.keys | tr '\n' ' ')"
else
	echo "SKIP: the file-size limit did not end the emulator in the change (ulimit -f): $(echo "$OUT" | grep '^G-' | tr '\n' ' ')"
fi

# a change that had removed the old file and not yet renamed the new
cp "$DIR/keys" "$DIR/h.keys.new"
cp "$DIR/keys" "$DIR/i.keys.new"; kf xor "$DIR/i.keys.new" 50 1
head -c 30 "$DIR/keys" > "$DIR/j.keys.new"
kf make "$DIR/j.keys" $PW  0 0 0 dave 4444
chmod 666 "$DIR/j.keys.new"
mkdir -p "$DIR/mnt.h" "$DIR/mnt.i" "$DIR/mnt.j"
OUT=$(emu h <<EOF
auth/keyfs -n $G/nvram -m $G/mnt.h $G/h.keys
echo H-new: \$status. \`{ls $G/mnt.h}
auth/keyfs -n $G/nvram -m $G/mnt.i $G/i.keys
echo H-bad: \$status. \`{ls $G/mnt.i}
auth/keyfs -n $G/nvram -m $G/mnt.j $G/j.keys
echo H-stale: \$status. \`{ls $G/mnt.j}
echo disabled > $G/mnt.j/dave/status
echo H-change: \$status.
EOF
)
check "with only the new file there, it is taken" "^H-new: \\. $G/mnt.h/alice $G/mnt.h/bob $G/mnt.h/carol\$"
[ -f "$DIR/h.keys" ] && [ ! -e "$DIR/h.keys.new" ] && ok "and is the key file again" || bad "after the start: $(ls "$DIR" | grep h.keys | tr '\n' ' ')"
check "a new file that does not authenticate is not" '^H-bad: error\. *$'
check "a piece of a file left beside the key file is not read" "^H-stale: \\. $G/mnt.j/dave\$"
D=$(kf dumpnew "$DIR/j.keys" $PW)
echo "$D" | grep -q '^1 0 0 dave 4444$' && [ "$(mode "$DIR/j.keys")" = "-rw-------" ] && [ ! -e "$DIR/j.keys.new" ] &&
	ok "and the next change replaces it, mode 600 whatever the piece's was" ||
	bad "after a change over a stale piece: $(echo "$D" | tr '\n' '|') $(mode "$DIR/j.keys")"

# --- an empty file is a new store, and says so; no clock, no keyfs
: > "$DIR/n.keys"; chmod 644 "$DIR/n.keys"
mkdir -p "$DIR/mnt.n" "$DIR/mnt.n2" "$DIR/mnt.t" "$DIR/empty"
OUT=$(emu n <<EOF
auth/keyfs -n $G/nvram -m $G/mnt.n $G/n.keys
echo N-started: \$status.
mkdir $G/mnt.n/erin
echo -n EEEE > $G/mnt.n/erin/secret
rm $G/mnt.n/erin
echo N-removed: \$status. \`{ls $G/mnt.n}
auth/keyfs -n $G/nvram2 -m $G/mnt.n2 $G/n.keys
echo N-otherkey: \$status.
@{pctl forkns; bind $G/empty /dev; auth/keyfs -n $G/nvram -m $G/mnt.t $G/keys; echo T-noclock: \$status.}
EOF
)
check "an empty file is a new store" '^N-started: \.$'
check "and keyfs says so" 'keyfs: .*n.keys is empty: a new store'
D=$(kf dumpnew "$DIR/n.keys" $PW)
echo "$D" | grep -q '^new recipe: yes, 200000 iterations, 0 entries$' && [ "$(mode "$DIR/n.keys")" = "-rw-------" ] &&
	ok "with its last user removed the file is still a file under its key, mode 600" ||
	bad "the store with no users: $(echo "$D" | tr '\n' '|') $(mode "$DIR/n.keys") $(wc -c < "$DIR/n.keys") bytes"
check "so another key does not open it as a new store" '^N-otherkey: error\.$'
check "with no clock keyfs does not start" '^T-noclock: error\.$'

# --- the master key typed at the console
: > "$DIR/c1.keys"; : > "$DIR/c2.keys"; : > "$DIR/c3.keys"
mkdir -p "$DIR/mnt.c1" "$DIR/mnt.c2" "$DIR/mnt.c3"
{ echo "load std"
  echo "auth/keyfs -m $G/mnt.c1 $G/c1.keys"
  echo "echo K-long: \$status."
  echo "auth/keyfs -m $G/mnt.c2 $G/c2.keys"
  echo "echo K-mismatch: \$status."
  echo "auth/keyfs -m $G/mnt.c3 $G/c3.keys"
  echo "echo K-new: \$status."
  echo "mkdir $G/mnt.c3/zed"
  echo "echo halt > /dev/sysctl"; } > "$DIR/script.k"
# a line of 300 characters (the 44 left over are the second keyfs's key,
# which its confirmation then does not match), then a key and the same again;
# the console is kept open until the emulator has read them
mkfifo "$DIR/cons"
( python3 -c "print('x'*300); print('a'); print('conspw'); print('conspw')"; exec sleep 120 ) > "$DIR/cons" &
conspid=$!
OUT=$(with_timeout 60 "$EMU" -r"$ROOT" -c1 sh "$G/script.k" 2>&1 < "$DIR/cons" || true)
kill $conspid 2>/dev/null
wait $conspid 2>/dev/null
check "a key of 300 characters is refused as too long" "couldn't get key: line too long"
check "with an error status" '^K-long: error\.$'
check "a confirmation that differs is refused" 'keyfs: key mismatch'
check "a key typed twice starts a new store" '^K-new: \.$'
D=$(kf dumpnew "$DIR/c3.keys" conspw)
echo "$D" | grep -q '^0 0 0 zed $' && ok "under the key typed" || bad "the store made at the console: $(echo "$D" | tr '\n' '|')"

exit $rc

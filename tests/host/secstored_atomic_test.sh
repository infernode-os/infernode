#!/bin/sh
#
# secstored replaces a file whole or not at all (appl/cmd/auth/secstored.b,
# doput): a PUT is written beside the file as .NAME.tmp, renamed .NAME.new
# once complete, then renamed over NAME.  It was created in place and
# written after, and creating it truncated it, so a server stopped between
# the two left an empty factotum file: the next login loaded no keys, and
# the next save wrote over it with only the keys added since.
#
# Each boot runs its own secstored and factotum -S on a store under tmp/:
#
#   - two saves (one key, then two) each leave the file and nothing beside
#     it; the two files are kept as A and B
#   - the states a stopped save leaves, set up by hand, then a login:
#     A with a complete .new (B) beside it, and no file with a .new, give B
#     and put it in place; A with a .tmp (half of B) gives A and drops the
#     .tmp; RM with a .new beside the file removes both
#   - a save whose write fails (the emulator run with a file size limit
#     of 0, so no host file can be written, though one can be truncated):
#     the file is as it was; the old server left it empty, every time
#   - a key added and synced with the emulator halted straight after,
#     three times: the file is never empty and the next login has every key
#     the one before it had
#
# Headless; no display needed.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/auth/secstored.dis dis/auth/secstore.dis dis/auth/secstore-setup.dis dis/auth/factotum.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done

T=tmp/secstored_atomic_test.$$
PORT=$((15400 + $$ % 500))
ADDR="tcp!127.0.0.1!$PORT"
U=testuser
S="$ROOT/$T/store/$U"
mkdir -p "$ROOT/$T"
trap '[ -n "${KEEP:-}" ] || rm -rf "$ROOT/$T"' EXIT
cd "$ROOT"

# run NAME: the Inferno script $T/NAME.sh, its output to $T/NAME.log.
# Each starts the server and factotum (which loads the keys at start).
start="load std expr
auth/secstored -s /$T/store -a 'tcp!*!$PORT' >[2] /dev/null &
sleep 2
fn waitfor {
	what=\$1
	cond=\$2
	n=0
	while {! \$cond} {
		if {~ \$n 30} {echo R timeout \$what; echo halt > '#c/sysctl'}
		sleep 1
		n=\${expr \$n 1 +}
	}
}
# the keys factotum holds, once it holds any (it loads them from the
# store after it starts), between markers for keys() below
fn keys {
	waitfor keys {grep -s 'service=' /mnt/factotum/ctl}
	sleep 2
	echo R_KEYS_BEGIN
	cat /mnt/factotum/ctl
	echo R_KEYS_END
}
fn factotum { auth/factotum -S '$ADDR' -P testpass -u $U }
"
run() {
	{ printf '%s\n' "$start"; cat; echo "echo R done"; echo "echo halt > '#c/sysctl'"; } > "$ROOT/$T/$1.sh"
	with_timeout 60 "$EMU" -c1 -r"$ROOT" /dis/sh.dis "/$T/$1.sh" </dev/null >"$ROOT/$T/$1.log" 2>&1 || true
}
keys() { sed -n '/^R_KEYS_BEGIN/,/^R_KEYS_END/p' "$ROOT/$T/$1.log" | grep -o 'service=k[0-9]' | sed 's/service=//' | sort | tr '\n' ' ' | sed 's/ $//'; }
left() { ls -A "$S" | grep -v '^PAK$' | sort | tr '\n' ' ' | sed 's/ $//'; }

failed=0
check() {
	if [ "$1" = 0 ]; then echo "PASS: $2"; else echo "FAIL: $2"; failed=1; fi
}

# Two saves: A holds k1, B holds k1 and k2.
run saves <<EOF
auth/secstore-setup -k testpass -u $U -s /$T/store
factotum
echo 'key proto=pass service=k1 user=u !password=p1' > /mnt/factotum/ctl
echo sync > /mnt/factotum/ctl
waitfor first {ftest -s /$T/store/$U/factotum}
cp /$T/store/$U/factotum /$T/A
echo R after1 \`{ls /$T/store/$U}
echo 'key proto=pass service=k2 user=u !password=p2' > /mnt/factotum/ctl
echo sync > /mnt/factotum/ctl
waitfor second {! cmp -s /$T/store/$U/factotum /$T/A}
sleep 1
cp /$T/store/$U/factotum /$T/B
EOF
# the checks from here: each says what it found, and one failing does
# not stop the rest
grep -q '^R done' "$ROOT/$T/saves.log" || { echo "FAIL: the saving boot did not finish"; grep -v '^fs:' "$ROOT/$T/saves.log" | tail -20; exit 1; }
set +e
[ -s "$ROOT/$T/A" ] && [ -s "$ROOT/$T/B" ] && ! cmp -s "$ROOT/$T/A" "$ROOT/$T/B"
check $? 'two saves, each a new file (A with one key, B with two)'
[ "$(left)" = factotum ]
check $? "a save leaves the file and nothing beside it (left: $(left))"

# login NAME: the keys factotum loads at start
login() { run "$1" <<EOF
factotum
keys
EOF
}

# A with a complete .new beside it: stopped after the .new was written
cp "$ROOT/$T/A" "$S/factotum"; cp "$ROOT/$T/B" "$S/.factotum.new"
login newbeside
[ "$(keys newbeside)" = "k1 k2" ] && cmp -s "$S/factotum" "$ROOT/$T/B" && [ "$(left)" = factotum ]
check $? "a complete .new beside the file is put in place (keys: $(keys newbeside); left: $(left))"

# no file, a .new: stopped after the file was removed (a host whose rename
# does not replace)
rm -f "$S/factotum"; cp "$ROOT/$T/B" "$S/.factotum.new"
login newonly
[ "$(keys newonly)" = "k1 k2" ] && cmp -s "$S/factotum" "$ROOT/$T/B" && [ "$(left)" = factotum ]
check $? "a .new with the file gone is put in place (keys: $(keys newonly); left: $(left))"

# A with half of B as a .tmp: stopped while it was written
cp "$ROOT/$T/A" "$S/factotum"
head -c $(( $(wc -c < "$ROOT/$T/B") / 2 )) "$ROOT/$T/B" > "$S/.factotum.tmp"
login tmpbeside
[ "$(keys tmpbeside)" = "k1" ] && cmp -s "$S/factotum" "$ROOT/$T/A" && [ "$(left)" = factotum ]
check $? "a .tmp is dropped and the file kept (keys: $(keys tmpbeside); left: $(left))"

# RM with a .new beside the file: both go, or the next GET puts it back
cp "$ROOT/$T/B" "$S/.factotum.new"
run remove <<EOF
echo testpass | auth/secstore -i -s '$ADDR' -u $U d factotum
echo R rm \$status
EOF
[ -z "$(left)" ]
check $? "RM removes the file and the .new beside it (left: $(left))"

# A save whose write fails.  ulimit -f 0: a host file cannot grow, but
# it can be truncated, as creating it in place did.  The emulator's output
# goes through a pipe, which the limit does not touch.
cp "$ROOT/$T/B" "$S/factotum"
{ printf '%s\n' "$start"; cat <<EOF; echo "echo R done"; echo "echo halt > '#c/sysctl'"; } > "$ROOT/$T/nowrite.sh"
factotum
echo 'key proto=pass service=k9 user=u !password=p9' > /mnt/factotum/ctl
echo sync > /mnt/factotum/ctl
sleep 3
EOF
( ulimit -f 0; with_timeout 60 "$EMU" -c1 -r"$ROOT" /dis/sh.dis "/$T/nowrite.sh" </dev/null 2>&1 ) | cat >"$ROOT/$T/nowrite.log" || true
[ -s "$S/factotum" ] && cmp -s "$S/factotum" "$ROOT/$T/B"
check $? "a save whose write fails leaves the file as it was ($(wc -c < "$S/factotum") bytes; B is $(wc -c < "$ROOT/$T/B"))"
login afternowrite
[ "$(keys afternowrite)" = "k1 k2" ] && [ "$(left)" = factotum ]
check $? "and the next login has its keys (keys: $(keys afternowrite); left: $(left))"

# Halted straight after a sync, three times: never an empty file, and the
# keys of the login before always there.
cp "$ROOT/$T/B" "$S/factotum"
want="k1 k2"
ok=0
for k in 3 4 5; do
	run halt$k <<EOF
factotum
echo 'key proto=pass service=k$k user=u !password=p$k' > /mnt/factotum/ctl
echo sync > /mnt/factotum/ctl
echo halt > '#c/sysctl'
EOF
	if [ ! -s "$S/factotum" ] && [ ! -s "$S/.factotum.new" ]; then
		echo "    after halt$k: no file with anything in it ($(ls -lA "$S" | tr '\n' ';'))"
		ok=1
	fi
	login after$k
	got=$(keys after$k)
	for w in $want; do
		case " $got " in *" $w "*) ;; *) echo "    after halt$k: $w lost (keys: $got)"; ok=1 ;; esac
	done
	want=$got
done
check $ok "halted straight after a sync, three times: the file never empty, no key lost (last keys: $want)"

for l in "$ROOT/$T"/*.log; do
	if grep -q 'R timeout' "$l"; then
		echo "FAIL: $(basename "$l" .log) timed out: $(grep 'R timeout' "$l")"
		failed=1
	fi
done
exit $failed

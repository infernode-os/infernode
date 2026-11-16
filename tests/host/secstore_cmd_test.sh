#!/bin/sh
#
# auth/secstore (secstore(1)) against a real auth/secstored on the
# loopback, for the operations its manual page lists: r, t, x, p, d.
#
# The command did not work at all once the password had been proved: its
# connection was declared three times and the one the operations used
# was never set ("dereference of nil"); it read and wrote only the
# oldest file format, so it could not print the factotum file logon and
# factotum write; t's filter left nothing out; and after an accepted PIN
# it asked for the password again.
#
# Here: a file stored (in the current format, SGCM2), listed, extracted
# the same, printed, stored under the last component of its local name,
# removed; a missing file, a wrong password and the verifier's name
# refused, each saying why; a wrong password costing one exchange with
# the server, not two, and reported as what it is (the older protocol
# version was tried after any failure, and the failure reported in its
# words); an account still on the older version reached through the
# fallback the server asks for.  secstore-setup failing, and saying so,
# when it cannot make the account ("setup complete" was printed whatever
# its creates and writes had done).
#
# The server is on a port and a store of the test's own.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/auth/secstore.dis dis/auth/secstored.dis dis/auth/secstore-setup.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done

T=tmp/secstore_cmd.$$
mkdir -p "$ROOT/$T/store" "$ROOT/$T/work/sub"
trap '[ -n "${KEEP:-}" ] || rm -rf "$ROOT/$T"' EXIT INT TERM
cd "$ROOT"

# a port nothing is using, as far as can be told
PORT=$((20000 + $$ % 20000))
if command -v python3 >/dev/null 2>&1; then
	PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
fi
A="tcp!127.0.0.1!$PORT"

cat > "$ROOT/$T/run.sh" <<SCRIPT
load std
bind -a '#I' /net
auth/secstored -d -s /$T/store -a $A >[2=1] &
sleep 2
auth/secstore-setup -s /$T/store -u cmduser -k 'pass word' >[2] /dev/null
auth/secstore-setup -s /$T/store -u olduser -V secstore -k oldpass >[2] /dev/null
cd /$T/work
echo 'key proto=pass service=x user=u !password=sekrit' > factotum
echo 'second line' >> factotum
echo other > sub/other
fn sec { echo 'pass word' | auth/secstore -i -u cmduser -s $A \$* }

echo MARK store
sec r factotum; echo STATUS r \$status
echo MAGIC \`{read 5 < /$T/store/cmduser/factotum}
echo MARK list
sec t
echo MARK longlist
sec -v t
echo MARK extract
mv factotum factotum.orig
sec x factotum; echo STATUS x \$status
if {cmp -s factotum factotum.orig} {echo EXTRACT-SAME} {echo EXTRACT-DIFFERS}
echo MARK print
sec p factotum
echo MARK sub
sec r sub/other; echo STATUS rsub \$status
sec t
echo MARK filter
sec t other
echo MARK delete
sec d other; echo STATUS d \$status
sec t
echo MARK missing
sec x nosuchfile; echo STATUS missing \$status
echo MARK verifier
sec r PAK; echo STATUS pak \$status
sec d PAK; echo STATUS dpak \$status
echo MARK wrong
echo 'wrong pass' | auth/secstore -i -u cmduser -s $A t; echo STATUS wrong \$status
echo MARK old
echo oldpass | auth/secstore -i -u olduser -s $A t; echo STATUS old \$status
echo MARK nouser
echo x | auth/secstore -i -u nosuchuser -s $A t; echo STATUS nouser \$status
echo MARK setup
auth/secstore-setup -s /$T/nosuchdir/store -u someone -k pw; echo STATUS setupdir \$status
auth/secstore-setup -s /$T/store -u ../cmduser -k pw; echo STATUS setuppath \$status
echo MARK end
echo halt > /dev/sysctl
SCRIPT

with_timeout 110 "$EMU" -c1 -r"$ROOT" /dis/sh.dis "/$T/run.sh" </dev/null >"$ROOT/$T/out" 2>&1 || true

set +e
failed=0
check() {
	if [ "$1" = 0 ]; then echo "PASS: $2"; else echo "FAIL: $2"; failed=1; fi
}
# sect NAME: the output between MARK NAME and the next MARK
sect() {
	awk -v n="$1" '$1=="MARK"{on=($2==n); next} on' "$ROOT/$T/out"
}
has() { sect "$1" | grep -q "$2"; }
hasnot() { ! sect "$1" | grep -q "$2"; }

grep -q '^MARK end' "$ROOT/$T/out"; check $? "the script ran to its end"
if grep -q 'Broken\|dereference of nil' "$ROOT/$T/out"; then check 1 "no command died"; else check 0 "no command died"; fi

has store '^STATUS r *$'; check $? "r stores a file"
has store '^MAGIC SGCM2'; check $? "in the current format (SGCM2)"
has list '^factotum$'; check $? "t lists it"
hasnot list '^PAK'; check $? "and not the account's verifier"
has longlist '^factotum  *[0-9][0-9]* '; check $? "t -v gives its size"
has extract '^STATUS x *$'; check $? "x extracts it"
has extract '^EXTRACT-SAME'; check $? "as it was stored"
has print '^key proto=pass service=x user=u !password=sekrit$'; check $? "p prints its lines"
has print '^second line$'; check $? "all of them"
has sub '^STATUS rsub *$'; check $? "r takes a local name with a directory"
has sub '^other$'; check $? "and stores it under its last component"
has filter '^other$'; check $? "t with a name lists it"
hasnot filter '^factotum$'; check $? "and not the others"
has delete '^STATUS d *$'; check $? "d removes a file"
hasnot delete '^other$'; check $? "and it is gone from the list"
has delete '^factotum$'; check $? "the other file still there"
has missing 'no such file'; check $? "a missing file is said to be missing"
has missing '^STATUS missing .'; check $? "and the command fails"
has verifier '^STATUS pak .'; check $? "the verifier's name is refused for r"
has verifier '^STATUS dpak .'; check $? "and for d"
[ -s "$ROOT/$T/store/cmduser/PAK" ]; check $? "the verifier is still there"
has wrong '^STATUS wrong .'; check $? "a wrong password fails"
hasnot wrong 'version mismatch'; check $? "and is not reported as a version mismatch"
n=$(sect wrong | grep -c 'secstored: new connection' || true)
[ "$n" = 1 ]; check $? "a wrong password is one exchange with the server (was $n)"
has old '^STATUS old *$'; check $? "an account on the older version is reached"
n=$(sect old | grep -c 'secstored: new connection' || true)
[ "$n" = 2 ]; check $? "by the fallback the server asks for ($n connections)"
has nouser '^STATUS nouser .'; check $? "no account fails"
n=$(sect nouser | grep -c 'secstored: new connection' || true)
[ "$n" = 1 ]; check $? "and is one exchange ($n)"

has setup '^STATUS setupdir .'; check $? "secstore-setup fails when the account cannot be made"
hasnot setup 'setup complete'; check $? "and does not say it is complete"
has setup '^STATUS setuppath .'; check $? "a user name that is a path is refused"

if [ "$failed" != 0 ]; then
	echo "--- output ---"
	grep -v '^fs:' "$ROOT/$T/out" | grep -v 'secstore: step\|secstore: PAK\|secstore: dial\|secstore: ssl' | tail -80
	exit 1
fi
echo PASS

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
# Here: a file stored (in the current format, SGCM3), listed, extracted
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

# A file in the oldest format (Plan 9's aescbc under a SHA-1 of the
# password), which nothing in the tree writes any more: made here, in
# the account's store, with the key file test's control.
mkdir -p "$ROOT/$T/store/cmduser"
python3 - "$ROOT/tests/host/keyfs" "$ROOT/$T/store/cmduser/oldfile" <<'PY' 2>/dev/null && : > "$ROOT/$T/store/cmduser/oldfile.made" || true
import sys, os
sys.path.insert(0, sys.argv[1])
import kf
plain = b"an old secret\n" + b"X" * 16
open(sys.argv[2], "wb").write(kf.oldenc(kf.oldkey(b"pass word"), os.urandom(16), plain))
PY

cat > "$ROOT/$T/run.sh" <<SCRIPT
load std
bind -a '#I' /net
auth/secstored -d -s /$T/store -a $A >[2=1] &
sleep 2
auth/secstore-setup -s /$T/store -u cmduser -k 'pass word' >[2] /dev/null
auth/secstore-setup -s /$T/store -u olduser -V secstore -k oldpassword >[2] /dev/null
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
# a file of that name already there, open to everybody: the secret must
# not be written into it
echo planted > factotum
chmod 666 factotum
sec x factotum; echo STATUS x \$status
if {cmp -s factotum factotum.orig} {echo EXTRACT-SAME} {echo EXTRACT-DIFFERS}
echo MODE \`{ls -l factotum}
echo MARK oldformat
if {ftest -f /$T/store/cmduser/oldfile} {
	sec x oldfile; echo STATUS oldx \$status
	sec p oldfile; echo STATUS oldp \$status
	sec m oldfile; echo STATUS oldm \$status
	echo OLDMAGIC \`{read 5 < /$T/store/cmduser/oldfile}
	sec p oldfile; echo STATUS newp \$status
	sec m oldfile; echo STATUS again \$status
}
echo MARK warn
auth/secstore -k 'pass word' -u cmduser -s $A t; echo STATUS k \$status
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
echo oldpassword | auth/secstore -i -u olduser -s $A t; echo STATUS old \$status
echo OLDPAK \`{cat /$T/store/olduser/PAK}
echo MARK oldagain
echo oldpassword | auth/secstore -i -u olduser -s $A t; echo STATUS oldagain \$status
echo MARK nouser
echo x | auth/secstore -i -u nosuchuser -s $A t; echo STATUS nouser \$status
echo MARK setup
auth/secstore-setup -s /$T/nosuchdir/store -u someone -k longenough; echo STATUS setupdir \$status
auth/secstore-setup -s /$T/store -u ../cmduser -k longenough; echo STATUS setuppath \$status
echo MARK setup2
auth/secstore-setup -s /$T/store -u cmduser -k 'another word'; echo STATUS exists \$status
echo 'pass word' | auth/secstore -i -u cmduser -s $A t; echo STATUS stillin \$status
auth/secstore-setup -s /$T/store -u shorty -k seven77; echo STATUS short \$status
auth/secstore-setup -i -s /$T/store -u importer -k longenough; echo STATUS import \$status
auth/secstore-setup -s /$T/store -u fresh -k longenough; echo STATUS fresh \$status
echo FRESHPAK \`{cat /$T/store/fresh/PAK}
auth/secstore-setup -f -s /$T/store -u fresh -k longenough2; echo STATUS force \$status
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
has store '^MAGIC SGCM3'; check $? "in the current format (SGCM3)"
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
has old '^STATUS old *$'; check $? "an account on the oldest version is reached"
n=$(sect old | grep -c 'secstored: new connection' || true)
[ "$n" = 5 ]; check $? "by the fallbacks the server asks for (6, 5, 3, 1), and then again at version 6 ($n connections)"
has old '^OLDPAK secstore6 [^ ]*$'; check $? "and the account is at version 6 alone after it"
n=$(sect oldagain | grep -c 'secstored: new connection' || true)
has oldagain '^STATUS oldagain *$' && [ "$n" = 1 ]; check $? "its next login is one exchange ($n)"

has extract '^MODE --rw------- '; check $? "x makes its file anew, mode 600, whatever was there"
if [ -f "$ROOT/$T/store/cmduser/oldfile.made" ]; then
	has oldformat '^STATUS oldx .'; check $? "x does not read a file in an old format"
	has oldformat 'auth/secstore m'; check $? "and says how it is moved"
	has oldformat '^STATUS oldp .'; check $? "nor does p"
	has oldformat '^STATUS oldm *$'; check $? "m moves it"
	has oldformat '^OLDMAGIC SGCM3'; check $? "into the current format"
	has oldformat '^an old secret$'; check $? "and then p prints it"
	has oldformat '^STATUS again *$'; check $? "m of a file already moved is no error"
else
	echo "SKIP: no python3 with cryptography: the old-format file was not made"
fi
has warn 'warning: a password given with -k'; check $? "-k warns that the password can be read"
has warn '^STATUS k *$'; check $? "and still works"
has setup2 '^STATUS exists .'; check $? "secstore-setup does not write over an account that is there"
has setup2 '^STATUS stillin *$'; check $? "whose password still logs in"
has setup2 '^STATUS short .'; check $? "a password of seven characters is refused"
[ ! -e "$ROOT/$T/store/shorty/PAK" ]; check $? "and makes no account"
has setup2 '^STATUS import .'; check $? "-i, which imported nothing, is refused"
has setup2 '^STATUS fresh *$' && has setup2 '^FRESHPAK secstore6 '; check $? "a new account is at version 6"
has setup2 '^STATUS force *$'; check $? "-f replaces a verifier"
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

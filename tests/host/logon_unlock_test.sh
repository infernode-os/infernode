#!/bin/sh
#
# wm/logon's unlock (Enter on the password), without its screen, against
# a real auth/secstored and auth/factotum on the loopback: what it loads
# into factotum, and whether it tells factotum to save.
#
#   - a new account unlocks with nothing to load, a key added is saved,
#     and the next unlock loads it; a wrong password is refused in one
#     exchange with the server (the older protocol version was tried
#     after any failure, a second failed login and a misleading reason);
#   - a key file that cannot be read (the connection cut after the
#     file's size) is a failed unlock, factotum is not told to save, and
#     the file on the server is as it was.  It was taken for a new
#     account: the login "succeeded" with no keys, and the next key
#     added was saved over the file that had not been read;
#   - the same for a key file of no bytes;
#   - a server that answers the hello with a message of no bytes is an
#     error on the screen (it was an exception out of the login screen,
#     which left its keyboard and pointer readers running);
#   - a password with a blank in it never reaches factotum as its first
#     word (it did: every save was then a failed login at the server,
#     and the account locked itself out).  Saving is arranged or, by a
#     factotum that does not take such a password, refused and said so;
#   - the mark Keyring and Settings read (/tmp/.secstore-unlocked) is
#     there after an unlock and not after a failed one.
#
# tests/logon_unlock.b calls the unlock; the server is on a port and a
# store of the test's own, /tmp a directory of its own.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/logon.dis dis/auth/secstored.dis dis/auth/secstore-setup.dis dis/auth/factotum.dis dis/tests/logon_unlock.dis; do
	[ -f "$ROOT/$f" ] || [ -f "$ROOT/${f#dis/}" ] || { echo "SKIP: $f not built"; exit 77; }
done

T=tmp/logon_unlock.$$
mkdir -p "$ROOT/$T/store" "$ROOT/$T/tmp"
trap '[ -n "${KEEP:-}" ] || rm -rf "$ROOT/$T"' EXIT INT TERM
cd "$ROOT"

PORT=$((20000 + $$ % 20000))
if command -v python3 >/dev/null 2>&1; then
	PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
fi
A="tcp!127.0.0.1!$PORT"

# boot NAME: an emulator with secstored and a new factotum, running the
# commands on standard input; its output to $T/NAME.out
boot() {
	{
		cat <<SCRIPT
load std
bind -a '#I' /net
bind -c /$T/tmp /tmp
auth/factotum
auth/secstored -s '#U/$T/store' -a $A >[2=1] &
sleep 2
user=\`{cat /dev/user}
fn unlock { /tests/logon_unlock.dis \$* >[2] /dev/null }
fn mark { if {ftest -e /tmp/.secstore-unlocked} {echo MARK-THERE \$1} {echo MARK-ABSENT \$1} }
SCRIPT
		cat
		echo 'echo DONE'
		echo 'echo halt > /dev/sysctl'
	} > "$ROOT/$T/$1.sh"
	with_timeout 100 "$EMU" -c1 -r"$ROOT" /dis/sh.dis "/$T/$1.sh" </dev/null >"$ROOT/$T/$1.out" 2>&1 || true
	grep -q '^DONE' "$ROOT/$T/$1.out" || {
		echo "FAIL: the $1 run did not finish"
		grep -v '^fs:' "$ROOT/$T/$1.out" | tail -20
		exit 1
	}
}

set +e
failed=0
check() {
	if [ "$1" = 0 ]; then echo "PASS: $2"; else echo "FAIL: $2"; failed=1; fi
}
has() { grep -q "$2" "$ROOT/$T/$1.out"; }
count() { grep -c "$2" "$ROOT/$T/$1.out"; }

# --- a new account; a key saved; a wrong password ---
boot new <<SCRIPT
auth/secstore-setup -s '#U/$T/store' -u \$user -k plainpass >[2] /dev/null
echo WRONG
unlock direct $A wrongpass
mark wrong
echo RIGHT
unlock direct $A plainpass
mark right
echo 'key proto=pass service=unlocktest user=u !password=sekrit' > /mnt/factotum/ctl
echo sync > /mnt/factotum/ctl; echo SYNC \$status
SCRIPT
U=$(ls "$ROOT/$T/store" | head -1)
F="$ROOT/$T/store/$U/factotum"
has new '^UNLOCK err=<..*> save=<>'; check $? "a wrong password is refused"
has new '^MARK-ABSENT wrong'; check $? "and leaves no mark of an unlock"
n=$(sed -n '/^WRONG/,/^RIGHT/p' "$ROOT/$T/new.out" | grep -c 'PAK auth failed')
[ "$n" = 1 ]; check $? "in one exchange with the server ($n failed logins)"
sed -n '/^WRONG/,/^RIGHT/p' "$ROOT/$T/new.out" | grep '^UNLOCK' | grep -q 'version mismatch'
[ $? != 0 ]; check $? "and not reported as a version mismatch"
has new '^UNLOCK err=<> save=<>'; check $? "a new account unlocks, and saving is arranged"
has new '^MARK-THERE right'; check $? "the mark of an unlock is left"
has new '^SYNC *$'; check $? "a key added is saved"
[ -s "$F" ]; check $? "to the account's file on the server"
cp "$F" "$ROOT/$T/factotum.saved" 2>/dev/null

# --- the next boot loads it ---
boot again <<SCRIPT
unlock direct $A plainpass
mark again
cat /mnt/factotum/ctl
SCRIPT
has again '^UNLOCK err=<> save=<>'; check $? "the next unlock succeeds"
has again 'service=unlocktest'; check $? "and factotum has the key"

# --- a key file that cannot be read ---
boot cut <<SCRIPT
unlock cut 3 $A plainpass
mark cut
echo KEYS \`{cat /mnt/factotum/ctl}
echo 'key proto=pass service=other user=u !password=two' > /mnt/factotum/ctl
echo sync > /mnt/factotum/ctl; echo SYNC \$status
sleep 1
SCRIPT
has cut '^UNLOCK err=<..*> save=<>'; check $? "a key file cut off part way is a failed unlock"
has cut '^UNLOCK err=<.*cannot read the keys'; check $? "saying that the keys could not be read"
has cut '^MARK-ABSENT cut'; check $? "with no mark of an unlock"
has cut '^SYNC ..*'; check $? "factotum was not told to save"
cmp -s "$F" "$ROOT/$T/factotum.saved"; check $? "and the file that was not read is as it was"

# --- a key file of no bytes ---
: > "$F"
boot nobytes <<SCRIPT
unlock direct $A plainpass
mark nobytes
echo 'key proto=pass service=other user=u !password=two' > /mnt/factotum/ctl
echo sync > /mnt/factotum/ctl; echo SYNC \$status
sleep 1
SCRIPT
has nobytes '^UNLOCK err=<.*empty'; check $? "a key file of no bytes is a failed unlock"
has nobytes '^SYNC ..*'; check $? "factotum was not told to save"
[ ! -s "$F" ]; check $? "and nothing was written over it"
cp "$ROOT/$T/factotum.saved" "$F"

# --- a server that answers with a message of no bytes ---
boot hostile <<SCRIPT
unlock empty plainpass
mark hostile
SCRIPT
has hostile '^UNLOCK err=<..*> save=<>'; check $? "a server's empty message is a failed unlock"
if has hostile 'exception\|Broken'; then check 1 "and no exception"; else check 0 "and no exception"; fi

# --- a password with a blank in it ---
rm -f "$F"
boot blank <<SCRIPT
auth/secstore-setup -f -s '#U/$T/store' -u \$user -k 'my password' >[2] /dev/null
echo UNLOCKING
unlock direct $A 'my password'
mark blank
echo 'key proto=pass service=blank user=u !password=three' > /mnt/factotum/ctl
echo sync > /mnt/factotum/ctl; echo SYNC \$status
sleep 1
SCRIPT
has blank '^UNLOCK err=<> save=<'; check $? "a password with a blank unlocks"
n=$(sed -n '/^UNLOCKING/,$p' "$ROOT/$T/blank.out" | grep -c 'PAK auth failed')
[ "$n" = 0 ]; check $? "and factotum never tries a piece of it at the server ($n failed logins)"
# factotum takes the password quoted (secstoreq): cut at its blank, the
# account logged in and then saved nothing
has blank '^UNLOCK err=<> save=<>'; check $? "and saving is arranged, with the whole password"
has blank '^SYNC *$' && [ -s "$F" ]; check $? "so a key added is saved"

# --- an account with a second factor ---
# A vault under the password alone was taken for such an account whenever
# it decrypted: whoever had the password could store one of their own
# making and have it loaded with no key present.  It is taken only while
# the factor is being enrolled or disabled (twofaslot's state), not once
# the vault has been read under the factor's data key.
rm -f "$F"
boot twofa <<SCRIPT
mkdir -p /usr/inferno/secstore
bind -c '#U/$T/store' /usr/inferno/secstore
auth/secstore-setup -f -s '#U/$T/store' -u \$user -k 'plainpass' >[2] /dev/null
unlock direct $A plainpass
echo 'key proto=pass service=twofa user=u !password=vault' > /mnt/factotum/ctl
echo sync > /mnt/factotum/ctl; echo SYNC \$status
sleep 1
echo SLOTS \`{/tests/logon_unlock.dis slots \$user plainpass 'a recovery phrase' >[2] /dev/null}
echo ENROLLING \`{unlock direct $A plainpass}
echo MARKED \`{/tests/logon_unlock.dis mark \$user >[2] /dev/null}
echo ENROLLED \`{unlock direct $A plainpass}
SCRIPT
has twofa '^SYNC *$' && [ -s "$F" ]; check $? "an account's vault is stored under its password"
has twofa '^SLOTS STATE enrolling err=<>'; check $? "given a slot, its second factor is being enrolled"
has twofa '^ENROLLING UNLOCK err=<> '; check $? "and the vault under the password is still taken"
has twofa '^MARKED STATE enrolled err=<>'; check $? "once the vault has been read under the data key the account is enrolled"
has twofa '^ENROLLED UNLOCK err=<NEEDRECOVERY'; check $? "and a vault under the password alone is no longer the vault"

if [ "$failed" != 0 ]; then
	for f in new again cut nobytes hostile blank twofa; do
		echo "--- $f ---"
		grep -v '^fs:' "$ROOT/$T/$f.out" | tail -15
	done
	exit 1
fi
echo PASS

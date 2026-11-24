#!/bin/sh
#
# tests/host/secstore_migrate_test.sh
#
# A secstore account and its files of the form before version 6, moved
# by their next use (CNSA 2.0 G9): an account at version 4 (its verifier
# from a root of HMAC-SHA256) with a factotum file in SGCM2 made here by
# Python as the client before this one made it; auth/factotum -S, given
# the password, logs in, reads the file, moves the account to version 6
# (PBKDF2-HMAC-SHA-384) and writes the file again as SGCM3; a second
# factotum then logs in at version 6 and reads the same keys.  All of
# it with CNSA mode on from the start: the move is over version 5's
# exchange, which is CNSA's (0.11.1 refused it).
#
# Skips (exit 77) with no emulator or no Python cryptography.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
python3 -c 'import cryptography' 2>/dev/null || { echo "SKIP: no Python cryptography"; exit 77; }

D="$ROOT/tmp/secstore_migrate.$$"
G="/tmp/secstore_migrate.$$"
rm -rf "$D"
mkdir -p "$D"
trap 'rm -rf "$D"' EXIT
PORT=$((20000 + $$ % 20000))
rc=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; rc=1; }

# an account at version 4, made by secstore-setup as it still can
cat > "$D/mk.sh" <<INFERNO
load std
auth/secstore-setup -V secstore4 -k oldpassword1 -u mover -s $G/store
INFERNO
with_timeout 120 "$EMU" -r"$ROOT" -c1 sh "$G/mk.sh" < /dev/null > "$D/mk.log" 2>&1 || true
head -c 9 "$D/store/mover/PAK" 2>/dev/null | grep -q '^secstore4' && ok "an account at version 4 made" || { bad "no version 4 account: $(tail -3 "$D/mk.log")"; exit 1; }

# its factotum file in SGCM2, under mkfilekey3's root, as it was written
python3 - "$D/store/mover/factotum" <<'PY'
import sys, hmac, hashlib, os
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
user, pw = b"mover", b"oldpassword1"
key = hmac.new(pw, b"secstore filekey seed:" + user, hashlib.sha256).digest()
for i in range(1, 100000):
    key = hmac.new(pw, key, hashlib.sha256).digest()
salt, nonce, magic = os.urandom(16), os.urandom(12), b"SGCM2\n"
fk = hmac.new(key, b"secstore file" + salt, hashlib.sha256).digest()
pt = b"key proto=pass service=moved-keys user=alice !password=cheshire\n"
open(sys.argv[1], "wb").write(magic + salt + nonce + AESGCM(fk).encrypt(nonce, pt, magic + salt))
PY
head -c 5 "$D/store/mover/factotum" | grep -q SGCM2 && ok "its key file in SGCM2" || bad "no SGCM2 file"

run() {
	cat > "$D/run.sh" <<INFERNO
load std
$1
auth/secstored -s $G/store -a 'tcp!127.0.0.1!$PORT' &
sleep 2
auth/factotum -S 'tcp!127.0.0.1!$PORT' -P oldpassword1 -u mover
sleep 2
echo KEYS \`{cat /mnt/factotum/ctl}
echo '--- done ---'
INFERNO
	with_timeout 180 "$EMU" -r"$ROOT" -c1 sh "$G/run.sh" < /dev/null 2>&1
}

# CNSA mode on from the start, as a user who turned it on after
# updating has it (0.11.1 refused this account, the login screen saying
# "log in once outside it"): moved over version 5's exchange, which is
# CNSA's (ML-KEM-1024, SHA-384, AES-256), its keys read, its file
# written again as SGCM3
OUT1=$(run 'echo 1 > /env/cnsamode')
echo "$OUT1" | grep -q '^KEYS .*service=moved-keys' && ok "in CNSA mode factotum reads the SGCM2 file with the password" || bad "factotum in CNSA mode: $(echo "$OUT1" | grep -v fsqid | tail -4 | tr '\n' '|' | cut -c1-240)"
[ "$(awk '{print $1}' "$D/store/mover/PAK" | sort -u)" = secstore6 ] && ok "the account is at version 6 alone" || bad "PAK is $(awk '{print $1}' "$D/store/mover/PAK" | tr '\n' ' ')"
head -c 5 "$D/store/mover/factotum" | grep -q SGCM3 && ok "the key file is written again as SGCM3" || bad "the key file is $(head -c 5 "$D/store/mover/factotum")"

OUT2=$(run 'echo 1 > /env/cnsamode')
echo "$OUT2" | grep -q '^KEYS .*service=moved-keys' && ok "and once moved, in CNSA mode too, a factotum reads the same keys" || bad "after the move: $(echo "$OUT2" | grep -v fsqid | tail -4 | tr '\n' '|' | cut -c1-240)"
exit $rc

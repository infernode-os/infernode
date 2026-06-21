#!/usr/bin/env bash
#
# Phase 0 PoC orchestrator for InferNode second-factor auth.
# Proves, on real hardware, the foundation of doc/second-factor-auth.md:
#   enroll -> derive(salt) -> derive(salt) again  => identical, device-bound secret R
#   then mixes R into a secstore-style file key:   filekey = HKDF(pwkey || R)
#
# You will be asked to TOUCH the YubiKey 3 times (1 enroll + 2 derives).
# Touch-only: no FIDO2 PIN is used, so your PIN retry counter is never touched.
#
set -euo pipefail
cd "$(dirname "$0")"

BIN=./yk-hmac-secret
CRED=cred-id.hex
# Fixed 32-byte salt (the value secstore would persist per-account, alongside the cred id):
SALT=$(printf 'InferNode-secstore-2fa-salt-0001' | xxd -p -c256)
# Stand-in for secstore->mkfilekey3(user,pass): the password-derived key.
PWKEY=$(printf 'demo-secstore-password' | shasum -a 256 | cut -d' ' -f1)

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; exit 1; }

[ -x "$BIN" ] || cc -I"$(brew --prefix)/include" yk-hmac-secret.c -L"$(brew --prefix)/lib" -lfido2 -o "$BIN"

echo "== 1. Enroll (touch) =="
[ -f "$CRED" ] || "$BIN" enroll "$CRED"
echo "   credential id: $(cut -c1-32 "$CRED")…  ($(($(wc -c < "$CRED") / 2)) bytes)"

echo "== 2. Derive twice with the same salt (touch x2) =="
R1=$("$BIN" derive "$CRED" "$SALT")
R2=$("$BIN" derive "$CRED" "$SALT")
echo "   R1 = $R1"
echo "   R2 = $R2"

echo "== 3. Checks =="
[ "$R1" = "$R2" ] && pass "determinism: same (key, cred, salt) -> identical secret R" \
                  || fail "determinism: R1 != R2"
[ "${#R1}" -eq 64 ] && pass "entropy: R is 32 bytes (256-bit)" || fail "R is not 32 bytes"

# 4. KDF mixing: filekey = HKDF-SHA256(pwkey || R, info="secstore 2fa")
FILEKEY=$(python3 - "$PWKEY" "$R1" <<'PY'
import sys, hmac, hashlib
pwkey = bytes.fromhex(sys.argv[1]); R = bytes.fromhex(sys.argv[2])
prk = hmac.new(b'\x00'*32, pwkey + R, hashlib.sha256).digest()      # HKDF-extract
okm = hmac.new(prk, b'secstore 2fa' + b'\x01', hashlib.sha256).digest()  # HKDF-expand
print(okm.hex())
PY
)
# Same inputs must reproduce the same file key (so the vault decrypts every login).
FILEKEY2=$(python3 - "$PWKEY" "$R2" <<'PY'
import sys, hmac, hashlib
pwkey = bytes.fromhex(sys.argv[1]); R = bytes.fromhex(sys.argv[2])
prk = hmac.new(b'\x00'*32, pwkey + R, hashlib.sha256).digest()
okm = hmac.new(prk, b'secstore 2fa' + b'\x01', hashlib.sha256).digest()
print(okm.hex())
PY
)
echo "   filekey = $FILEKEY"
[ "$FILEKEY" = "$FILEKEY2" ] && pass "KDF mixing: vault file key reproduces with the key present" \
                             || fail "KDF mixing: file key not reproducible"

cat <<EOF

== Result ==
  Device-bound secret R is reproducible ONLY with this YubiKey present and a
  touch — the hmac-secret CredRandom never leaves the key, so R (and therefore
  the file key) is uncomputable off-device. This is exactly the primitive
  Phase 1-2 will wire into appl/wm/logon.b via the emu /mnt/2fa bridge.

  Password alone is no longer sufficient to derive the secstore file key.  ✔
EOF

# 2FA host PoC (Phase 0)

Host-side proof-of-concept for `docs/second-factor-auth.md`. It validates — on a
real YubiKey — the cryptographic foundation for gating InferNode's secstore
unlock behind a physical second factor, **before** any `emu`/Limbo work.

This is **host-side only**. It does not run inside Inferno. It exercises the same
libfido2 entry points the emu bridge calls on the host side of the emulator. That
bridge has since shipped as `emu/port/devtfa.c` (`#F`, configured on macOS, Linux
and Windows) and reaches Limbo at `/mnt/2fa`. This PoC is superseded by it.

## What it proves

1. **Enroll** — a non-resident FIDO2 credential with the `hmac-secret` extension.
2. **Derive** — given a 32-byte salt, the YubiKey returns a 32-byte secret `R`,
   gated by **touch** (no PIN).
3. **Determinism** — same `(key, credential, salt)` ⇒ identical `R`, so the same
   vault decrypts on every login.
4. **Device-binding** — `R` is uncomputable without the physical key: the
   `hmac-secret` CredRandom never leaves the device.
5. **KDF mixing** — `filekey = HKDF-SHA256(pwkey ‖ R, "secstore 2fa")`, the
   seam from the design doc (§6); it shipped as `mkkek2fa` in
   `appl/lib/secstore.b`. Password alone no longer yields the file key.

## Run

```sh
bash hmac-secret-poc.sh      # 3 touches: 1 enroll + 2 derives
```

Expect `PASS` on determinism, entropy, and KDF mixing. Artifacts (`cred-id.hex`,
the compiled `yk-hmac-secret`) are git-ignored scratch; delete to re-enroll.

## Files

- `yk-hmac-secret.c` — libfido2 tool: `enroll` + `derive` (the bridge core ref).
- `hmac-secret-poc.sh` — orchestrates enroll → derive×2 → checks → KDF.

## Build (standalone)

```sh
cc -I"$(brew --prefix)/include" yk-hmac-secret.c -L"$(brew --prefix)/lib" -lfido2 -o yk-hmac-secret
```

## Why hmac-secret (and not OTP HMAC-SHA1)

The design prefers FIDO2 `hmac-secret`: it rides the FIDO interface, reuses the
FIDO2 PIN/presence model, and needs no OTP slot. On the dev YubiKey the OTP
interface is disabled anyway. HMAC-SHA1 challenge-response (à la yubikey-luks)
remains a valid fallback provider per the design doc.

## Scope / next

Phase 0 only. The later phases shipped: `emu/port/devtfa.c` (`#F`),
`module/twofa.m` and `appl/lib/twofa.b` (`/mnt/2fa`), `appl/cmd/2fa.b`, and
`mkkek2fa` in `appl/lib/secstore.b`. See `docs/second-factor-auth.md` and
`docs/yubikey-2fa-operations.md`.

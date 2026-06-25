# Second-Factor Authentication for InferNode

**Status:** Draft — 2026-06-15
**Scope:** Add hardware/external second-factor unlock to InferNode login, with a
provider-agnostic design (YubiKey first, mobile biometrics second, others later).

---

## 1. Goal

Let a user gate the InferNode **secstore unlock** (the login moment in
`appl/wm/logon.b`) — and therefore everything downstream: factotum keys, the
crypto wallet, the LLM service key — behind a **physical second factor**, such
that the encrypted vault cannot be decrypted by the password alone.

The design is **provider-agnostic** from day one. A "second factor" is anything
that can answer a challenge with a high-entropy, device-bound secret:

- **YubiKey** (desktop) — FIDO2 `hmac-secret`, or HMAC-SHA1 challenge-response,
  or PIV. Secret never leaves the key; touch (presence) + optional PIN.
- **Mobile biometrics** (Android/iOS) — Face/Touch ID gating a Secure-Enclave /
  StrongBox key, via the **existing `/phone/bio_store` bridge**.
- **Future** — other FIDO2 keys, TOTP, smartcards, platform TPMs.

## 2. Non-goals

- Not browser WebAuthn. Charon has no JS engine; the W3C Credential Management
  API is unavailable. We use native challenge-response, not the web flow.
- Not replacing the password outright. The second factor **augments** the
  existing password KDF (defense in depth + recovery), it does not delete it.
- Not on-key signing of arbitrary algorithms. YubiKey PIV does P-256 / Ed25519,
  **not secp256k1** — so on-key signing suits P-256/Ed25519 wallets only; at-rest
  protection is universal regardless of wallet curve.

## 3. How login works today

`appl/wm/logon.b` is a fullscreen Draw UI shown before the window manager. On
Enter it calls `connectfactotum(pass)` (logon.b:522), which:

1. Derives several keys from the password:
   `secstore->mkseckey(pass)`, `mkseckey2(pass)`, `mkfilekey3(user,pass)`,
   `mkfilekey2(pass)`, `mkfilekey(pass)` (logon.b:535-539).
2. Connects to `secstored` (`tcp!localhost!5356`) with a PAK exchange.
3. Fetches the encrypted `factotum` blob and `decrypt3`s it with the derived
   file keys (logon.b:556).
4. Writes the decrypted `key ...` lines into `/mnt/factotum/ctl` (logon.b:564).

The KDF lives in `appl/lib/secstore.b`:
- Legacy: `mkfilekey` → `sha1("aescbc file" ...)`, AES-CBC (secstore.b:384).
- Modern: **SGCM2/SGCM1**, AES-256-GCM with HMAC-SHA-256 key stretching
  (secstore.b:433+).

**The seam:** the file key is a pure function of the password. If we mix a
**device-bound secret** into that derivation, the blob becomes undecryptable
without the physical factor present. No protocol rewrite — we extend the KDF.

## 4. Historical reference: Plan 9 challenge-response

InferNode is Inferno; Inferno is Plan 9's sibling. Plan 9 shipped token auth ~30
years ago and the shape is instructive (we modernize, not copy):

- **`p9cr`** — "Plan 9 Challenge/Response": a textual challenge-response protocol
  spoken between a program and the local factotum, usable with a SecureID token.
  This is the direct ancestor of what we're building: *factotum already models a
  challenge-response second factor.*
- **SecureNet handheld authenticator** (`securenet(8)`) — a calculator-like DES
  box; the server issues a numeric challenge, the box computes the response with
  a shared key. Our YubiKey `hmac-secret` is the same idea with modern crypto
  and a USB/NFC transport instead of a human retyping digits.
- **`guard.srv` / `authsrv`** — the server-side daemons that validated those
  challenge/response exchanges (`authsrv(6)`).

We diverge deliberately: device-bound secrets (FIDO2 `hmac-secret`, Secure
Enclave) instead of a shared DES key on a calculator; presence/biometric gating;
and a pluggable provider model rather than one hardwired token type.

Refs: Security in Plan 9 (9p.io/sys/doc/auth.html), `factotum(4)`,
`securenet(8)`, `authsrv(6)`.

## 5. Architecture: the pluggable authenticator

### 5.1 A provider-agnostic 9P service: `/mnt/2fa`

Expose second factors the Inferno way — as a file server — so callers
(`logon`, factotum, wallet) never link a device library. Proposed interface:

```
/mnt/2fa/
    providers          # read: list available providers, one per line:
                       #   yubikey-fido2  present  "YubiKey 5C Nano 37602882"
                       #   phone-bio      present  "Face ID"
    ctl                # write: select/enroll, e.g. "enroll provider=yubikey-fido2 name=login"
    challenge          # write a 32-byte challenge, then read the response:
                       #   write -> provider does presence/biometric + compute
                       #   read  -> high-entropy response bytes (or error)
    status             # read: last op result / presence state
```

`challenge`/response is the universal primitive: every provider reduces to
"given this challenge, return a stable secret, after proving presence." That
secret is mixed into the secstore file key (§6).

### 5.2 Providers

| Provider | Transport | Mechanism | Presence |
|----------|-----------|-----------|----------|
| `yubikey-fido2` | emu host bridge → libfido2 | FIDO2 `hmac-secret` assertion | touch + (PIN) |
| `yubikey-hmac` | emu host bridge → libfido2/yk | HMAC-SHA1 chal-resp (LUKS-style) | optional touch |
| `phone-bio` | existing `/phone/bio_*` bridge | Secure Enclave / StrongBox key | Face/Touch ID |
| `totp` (later) | pure Limbo | RFC 6238 (weak, fallback only) | none |

The point of the abstraction: `logon.b` asks `/mnt/2fa` for a response to a
challenge and does **not care** whether a YubiKey was touched or a thumb was
scanned. Desktop and mobile share one code path.

### 5.3 The emu host bridge

Inferno runs inside the `emu` host emulator, which today has **no** USB/PCSC/HID
access. We add a host-side device that mirrors the existing mobile bridge:

- Pattern to copy: `/phone/bio_store` ↔ `/phone/bio_retrieve`
  (`emu/port/devphone.c`, `emu/iOS/phonebridge.m`, `emu/Android/phonebridge.c`).
- New: `emu/port/dev2fa.c` exposing `#²/2fa/...` (bound to `/mnt/2fa`), calling
  **host libfido2 / PC-SC** — which the host already has installed. The bridge
  does no crypto of its own; it relays challenge→response.

So: same Plan 9 device idiom, libfido2 lives on the host side of the emu
boundary, Inferno sees only files.

## 6. Crypto: mixing the factor into the file key

Enrollment binds a factor to the account; unlock requires it.

**Enroll** (once, after password is set):
1. `logon` writes `enroll provider=… name=login` to `/mnt/2fa/ctl`.
   - FIDO2: create a credential with the `hmac-secret` extension; store the
     non-secret `credential_id` + RP info in `/usr/inferno/secstore/<user>/2fa/`.
   - phone-bio: generate a Secure-Enclave key; store its public handle.
2. Generate a random 32-byte `salt`, persist it next to the credential id.

**Unlock** (every login):
1. `logon` reads `salt`, writes `challenge = salt` to `/mnt/2fa/challenge`.
2. Provider proves presence and returns `R` (FIDO2 hmac-secret output, or an
   Enclave signature/HMAC over the challenge).
3. Derive the effective file key:
   `filekey = HKDF-SHA256( mkfilekey3(user,pass) || R, info="secstore 2fa" )`.
4. Proceed exactly as today (PAK, fetch blob, `decrypt3`).

Properties: the blob needs **both** password and physical factor. `R` is stable
(same challenge → same secret), so the same vault decrypts every time, but only
with the device present. No private key from the device ever enters Inferno.

**FIDO2 `hmac-secret`** is preferred (reuses the FIDO2 PIN we already set;
presence via touch). **HMAC-SHA1 chal-resp** is the simpler LUKS-style fallback.

## 7. Integration points (file-by-file)

| File | Change |
|------|--------|
| `emu/port/dev2fa.c` (new) | host bridge → libfido2/PCSC; serves `/mnt/2fa` |
| `emu/port/portdat.h`, device table | register `dev2fa` |
| `module/twofa.m` (new) | Limbo interface to `/mnt/2fa` |
| `appl/lib/twofa.b` (new) | challenge/response + enroll helpers |
| `appl/lib/secstore.b` | add `mkfilekey3_2fa(user,pass,R)` HKDF mixing (§6) |
| `appl/wm/logon.b` | enroll flow + "Unlock with security key / biometrics" path; call into 2fa before `connectfactotum` |
| `appl/cmd/auth/factotum/proto/2fa.b` (new, later) | optional `proto=2fa` so factotum can challenge on demand |

## 8. Threat model, recovery, caveats

- **Lost / absent factor:** must not be a hard lockout. Options: keep the
  password-only path as a recovery mode (weaker, opt-out for high-security), or
  enroll **two** factors (e.g. both YubiKeys, à la NERV "pairs only" rule), or a
  one-time recovery code sealed in a vault. Design supports N factors per account.
- **Presence ≠ identity:** touch proves the key is present, not who touched it;
  the FIDO2 PIN / biometric supplies the "who."
- **secp256k1 wallets:** on-key signing not available on PIV; gate at-rest only.
- **emu trust boundary:** the host bridge sees challenges/responses in host
  memory. The factor secret is still device-bound, but a fully compromised host
  can observe a live unlock. This matches today's reality (the password is typed
  into the host emu too); the win is *at-rest* and *theft* resistance.

## 9. Phasing

- **Phase 0 — Host PoC (no Inferno):** prove FIDO2 `hmac-secret` (and/or
  HMAC-SHA1) round-trips deterministically with the real YubiKey via host
  libfido2. De-risks the whole foundation. *Testable now.*
- **Phase 1 — emu bridge + 9P service:** `dev2fa.c`, `/mnt/2fa`, `providers` +
  `challenge` working against one real YubiKey. Limbo `twofa` module.
- **Phase 2 — secstore mixing + logon UI:** `mkfilekey3_2fa`, enroll/unlock in
  `logon.b`. End-to-end YubiKey-gated login.
- **Phase 3 — second provider:** wire `phone-bio` through the existing
  `/phone/bio_*` bridge → mobile biometric unlock, same code path.
- **Phase 4 — factotum proto + wallet:** `proto=2fa`; gate wallet-key access.

## 10. Open questions

- Two-factor-mandatory vs. password-recovery-allowed as the default policy?
- Where to persist per-account 2fa metadata — extend the secstore blob, or a
  sibling `2fa/` dir (chosen above for bootstrap-before-unlock)?
- Should `hmac-secret` salt rotate, and how to re-key the vault if it does?
- NFC path for `yubikey-fido2` on mobile (the 5C NFC) — reuse `phone` bridge?

# Second-Factor Authentication for InferNode

**Status:** As-built — 2026-06-25. Phases 0-2 shipped: YubiKey-gated login with
UV/AAL3 (FIDO PIN), a backup key, a recovery passphrase, and a Settings GUI are
live (**EPIC 1 closed**). Phases 3-4 (mobile-biometric provider, factotum proto)
remain future.
**Scope:** Hardware/external second-factor unlock for InferNode login, with a
provider-agnostic design (YubiKey first, mobile biometrics second, others later).

> This file began as the design draft and has been updated to describe the
> **as-built** system. Where the shipped design diverged from the original
> proposal — the device name, the file layout, and the key-slot crypto — the
> as-built form is documented here and the original intent kept as a *design
> note* for context.

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

### 5.1 A provider-agnostic device: `#F` → `/dev/2fa`

Expose second factors the Inferno way — as a file server — so callers
(`logon`, factotum, wallet) never link a device library. As built this is the
**`#F` device** (`emu/port/devtfa.c`), bound into the namespace at `/dev/2fa`
(`bind "#F" /dev/2fa`, see `appl/lib/twofa.b`). Its synthetic file tree:

```
/dev/2fa/
    providers   # read: available backends, e.g. "yubikey-fido2 available=1"
    ctl         # write "enroll" (touch-only) or "enroll <pin>" (UV/AAL3) to bind
                #   a credential; write "clear" to forget. read: status line.
    cred        # read: the enrolled credential id (hex)
    derive      # write "<cred-hex> <salt-hex> [pin]" -> the key proves presence
                #   (touch, +PIN under UV) and computes a device-bound 32-byte
                #   secret; read it back as hex.
```

`derive` is the universal challenge→response primitive expressed as file I/O:
**write the salt (challenge), read the secret (response)**. The write *blocks*
on the physical touch/PIN ceremony, exactly as a slow read blocks. Every provider
reduces to "given this salt, return a stable device-bound secret after proving
presence." That secret (`R`) is wrapped into the secstore key-slots (§6).

> *Design note:* the original draft proposed `/mnt/2fa` with `challenge` +
> `status` files and a `#²` device. The shipped form uses `#F` → `/dev/2fa` and
> folds challenge/response into the read-write `derive` file (plus a `cred` file
> for the enrolled credential id). The semantics are identical; the names differ.

### 5.2 Providers

| Provider | Transport | Mechanism | Presence |
|----------|-----------|-----------|----------|
| `yubikey-fido2` | emu host bridge → libfido2 | FIDO2 `hmac-secret` assertion | touch + (PIN) |
| `yubikey-hmac` | emu host bridge → libfido2/yk | HMAC-SHA1 chal-resp (LUKS-style) | optional touch |
| `phone-bio` | existing `/phone/bio_*` bridge | Secure Enclave / StrongBox key | Face/Touch ID |
| `totp` (later) | pure Limbo | RFC 6238 (weak, fallback only) | none |

The point of the abstraction: a caller asks `/dev/2fa` for a response to a
challenge and does **not care** whether a YubiKey was touched or a thumb was
scanned. Desktop and mobile share one code path. (As built, `yubikey-fido2` is
live; `yubikey-hmac`, `phone-bio`, and `totp` are provider slots the file
interface already accommodates.)

### 5.3 The emu host bridge

Inferno runs inside the `emu` host emulator, which has **no** native USB/HID
access. The `#F` device is a deliberately thin **text relay**: `devtfa.c` parses
one line and calls the host-side bridge — it does no crypto and no USB itself.

- The bridge: `emu/MacOSX/fido2bridge.c`, pure C against **libfido2** with *no
  Inferno headers* (to avoid name clashes). It does the real work —
  `fido_dev_make_cred` with the `FIDO_EXT_HMAC_SECRET` extension, `fido_dev_open`
  over USB HID. Registered into the device table in `emu/MacOSX/emu.c`.
- When libfido2 is absent at build time (`-DHAVE_FIDO2` unset), the entry points
  compile as stubs so the emu still builds without `/dev/2fa` support.
- Same idiom as the mobile biometric bridge (`/phone/bio_*`,
  `emu/port/devphone.c`); a blocking bridge call runs in the writing kproc,
  exactly as `devphone` blocks on a biometric prompt.

So: same Plan 9 device idiom, libfido2 lives on the host side of the emu
boundary, **Inferno sees only files**. On a native Inferno kernel the device
would speak USB directly; the file interface above it is identical either way.

### 5.4 The namespace bind *is* the capability

Because `/dev/2fa` is a **per-process namespace bind**, access to the second
factor is governed by the namespace, not a separate permission system. A
sandboxed agent whose restricted namespace simply *omits* `/dev/2fa` cannot
`open` the key at all — there is nothing to ask permission for; the file is not
there. This is the most "Plan 9" property of the design: capability-gating
reduces to namespace construction. See the veltro agent-sandbox hardening
(`appl/veltro/nsconstruct.b`; `NodevsBlocksDeviceAttach` in
`tests/veltro_security_test.b`) and EPIC 7 (hardware-backed authorization of
agent actions).

## 6. Crypto: per-account key-slots (the LUKS model)

> *Design note:* the original draft mixed `R` straight into the secstore file
> key via HKDF. The shipped design is stronger — a **key-slot / LUKS envelope**
> (`module/twofaslot.m`, `appl/lib/twofaslot.b`) — so one vault can hold several
> independent unlock paths (primary key, backup key, recovery passphrase). The
> way `R` is obtained from the device is unchanged.

A 2FA account's factotum blob is encrypted under a single random **data key DK**.
DK is then wrapped once per *slot*, each slot a file under
`/usr/inferno/secstore/<user>/2fa/`. Each slot is `encrypt3(DK, KEK)`
(AES-256-GCM, SGCM2):

- **key slot:** `KEK = mkkek2fa(rootkey, R)` — needs the password
  (`rootkey = mkfilekey3(user,pass)`) **and** the device-bound `R` (a YubiKey
  `hmac-secret` output, gated by touch, +PIN under UV/AAL3).
- **recovery slot:** `KEK = mkfilekey3(user, recoverypass)` — a recovery
  passphrase only, the dev / lost-key safety net.

**Enroll** (`twofaslot->writeslots`, verify-before-commit): re-encrypt the
factotum blob under a fresh random DK; derive `R` per key (touch); wrap DK into
each key slot + the recovery slot; **verify every slot unwraps DK** and the new
blob round-trips; *then* replace the live blob. Abort and keep the legacy form on
any mismatch.

**Unlock** (`twofaslot->unlock`, every login): try each key slot first — derive
`R` from the present YubiKey (touch), `KEK = mkkek2fa(rootkey,R)`,
`DK = decrypt3(slot, KEK)`; fall back to the recovery slot if a recovery
passphrase is supplied. Then `decrypt3` the factotum blob under DK and proceed as
today (PAK, fetch, write `/mnt/factotum/ctl`).

**Backup key** (`twofaslot->addkey`): wraps the *same* DK into a new key slot
(unlocked via the recovery passphrase) so a second YubiKey is no single point of
failure — the NERV "pairs only" rule (Nano + NFC).

Properties:
- A 2FA account has **no password-only slot**, so the blob needs *both* the
  password and a physical factor — that is the real at-rest strength. A legacy
  (no-slot) account is byte-for-byte the old format, so no-key users are
  unaffected.
- `R` is stable (same salt → same secret), so the vault decrypts every time, but
  only with the device present. No private key from the device ever enters
  Inferno; the FIDO2 PIN supplies the "who" (AAL3).
- The presence of the `2fa/` slot dir is the sole marker that an account is in
  2FA mode (`twofaslot->is2fa`).

## 7. Integration points (file-by-file)

| File | As-built role |
|------|---------------|
| `emu/port/devtfa.c` | the `#F` device; serves `/dev/2fa` (text relay) |
| `emu/MacOSX/fido2bridge.c` | host bridge → libfido2 (hmac-secret, USB HID) |
| `emu/MacOSX/emu.c` | registers `tfadevtab` in the device table |
| `module/twofa.m`, `appl/lib/twofa.b` | Limbo file interface to `/dev/2fa` |
| `module/twofaslot.m`, `appl/lib/twofaslot.b` | key-slot envelope: `is2fa`/`unlock`/`writeslots`/`addkey`/`disable` (§6) |
| `appl/lib/secstore.b` | `mkkek2fa(rootkey,R)` + `encrypt3`/`decrypt3` for DK wrapping |
| `appl/cmd/2fa.b` | CLI: `enroll` / `addkey` / `disable` |
| `appl/wm/logon.b` | `STATE_FIDOPIN` prompt; `connectfactotum(pass,recoverypass,fidopin)`; DK-aware secstore save-back |
| `appl/wm/settings.b` | Settings "Security" panel — enroll / backup / disable GUI |
| `appl/cmd/auth/factotum/factotum.b` | secstore `ctl` accepts an optional data-key (DK) |
| `appl/cmd/auth/factotum/proto/2fa.b` (future) | optional `proto=2fa` so factotum can challenge on demand |

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

- **Phase 0 — Host PoC (no Inferno):** ✅ done. FIDO2 `hmac-secret` round-trips
  deterministically with the real YubiKey via host libfido2.
- **Phase 1 — emu bridge + device:** ✅ done. `devtfa.c` (`#F` → `/dev/2fa`),
  `fido2bridge.c`, `providers` + `derive` against a real YubiKey; Limbo `twofa`.
- **Phase 2 — secstore key-slots + logon:** ✅ done. `twofaslot` key-slots;
  enroll / unlock / backup / recovery in `logon.b`; **UV/AAL3** (FIDO PIN); and a
  Settings GUI. End-to-end YubiKey-gated login. **EPIC 1 closed** — see
  `doc/compliance/SP800-63B-AAL3.md` and `doc/compliance/FIDO2-CTAP2.md`.
- **Phase 3 — second provider (future):** wire `phone-bio` through the existing
  `/phone/bio_*` bridge → mobile biometric unlock, same code path.
- **Phase 4 — factotum proto + wallet (future):** `proto=2fa`; gate wallet-key
  access.

## 10. Open questions

- ~~Two-factor-mandatory vs. password-recovery-allowed?~~ **Resolved:** a 2FA
  account has no password-only slot, but a **recovery passphrase** slot is the
  safety net (high-security deployments can omit it).
- ~~Where to persist per-account 2fa metadata?~~ **Resolved:** a sibling
  `/usr/inferno/secstore/<user>/2fa/` slot dir (bootstrap-before-unlock).
- Should the `hmac-secret` salt rotate, and how to re-key the vault if it does?
  (Backup-key add already re-wraps DK via `writeslots`/`addkey` verify-before-
  commit; full salt rotation remains open.)
- NFC path for `yubikey-fido2` on mobile (the 5C NFC) — reuse the `phone` bridge?

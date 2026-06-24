# YubiKey 2FA — Operations & Procedure Guide

This is the **hands-on guide** for InferNode's YubiKey-gated secstore login. For
the design and threat model, see [`second-factor-auth.md`](second-factor-auth.md).

InferNode binds login to a hardware security key the way a CAC/PIV card gates a
government workstation: your factotum (key vault) is encrypted under a random
**data key (DK)**, and the DK is wrapped in per-account **key-slots**. A slot can
be unlocked by a **YubiKey** (touch, and — at AAL3 — a hardware-verified PIN) or by
a **recovery passphrase**. A password alone cannot unlock a 2FA account: that is
the whole point.

Two assurance levels:

| Level | What login requires | NIST 800-63B |
|-------|--------------------|--------------|
| **Touch-only** | secstore password + key **presence** (touch) | AAL2 |
| **UV (PIN)** | secstore password + key **+ hardware-verified FIDO PIN** (touch) | **AAL3** |

The PIN is *load-bearing*: without it the key derives a **different** secret that
cannot unwrap the vault (proven on hardware — a touch-only derive and a UV derive
return different `hmac-secret` outputs).

---

## ⚠ Compatibility & migration — this is a BREAKING upgrade

Enrolling an account in 2FA **changes the on-disk format of its secstore vault**
in a way older InferNode builds cannot read. Read this before deploying.

- **A 2FA-enrolled account's `factotum` blob is encrypted under a random data key
  (DK), not the password.** An InferNode build *without* the 2FA support (no
  `twofaslot`/`#F` device, no DK-aware `secstore`/`factotum`) **cannot decrypt it**
  and that user **cannot log in** there. The per-account `2fa/` slot files are also
  unrecognized by older builds.
- **One-way until disabled.** To move an account back to an InferNode without 2FA,
  run **`2fa disable` first** — it re-encrypts the vault under the password and
  removes the slots. After that the old format is restored.
- **The recovery passphrase is the only escape hatch** on a 2FA account, and old
  builds have no recovery-slot logic — so a 2FA vault opened on an un-upgraded build
  is effectively locked until you return to a 2FA-capable build (or had run
  `2fa disable`). **Keep the recovery passphrase in your vault.**
- **The secstore *server* is unaffected** — it stores opaque bytes. Only the
  *client* (logon + factotum) needs the 2FA code. Mixed fleets are fine as long as
  every host a 2FA user logs into runs a 2FA-capable build.
- **Password-only (legacy) accounts are 100% unchanged** — no slot dir, no DK, same
  bytes as before. The break only affects accounts you explicitly `2fa enroll`.

**Upgrade order:** roll the 2FA-capable build to *all* hosts a user touches → then
`2fa enroll`. **Downgrade order:** `2fa disable` on every 2FA account → then roll
back. Always back up `~/.infernode/usr/inferno/secstore` first.

---

## 0. Prerequisites

- A YubiKey with **FIDO2** support.
- For **UV/AAL3**: a **FIDO2 PIN** set on the key (`ykman fido access change-pin`,
  or set during first WebAuthn registration). This is the *FIDO2* PIN — **not** the
  PIV PIN and **not** your secstore password. It has an **8-try hardware lockout**.
- A **recovery passphrase** you store in your password vault. This is your
  anti-lockout net; without it, a lost key means a lost account.

---

## 1. Build the emu — GUI vs headless (read this first)

InferNode's macOS emu has **two display backends**, and picking the wrong one is
the single most common source of "it won't boot to a login screen":

```
cd emu/MacOSX

mk                      # GUIBACK defaults to sdl3  → GRAPHICAL window (use this)
mk GUIBACK=headless     # NO display — console only; full boot can't reach wm/logon
```

- **`sdl3`** is the normal desktop build. A graphical login window appears.
- **`headless`** has no display *by design* (stub backend). A *full* boot
  (`boot.sh`) will print `logon: no display, using console` and then
  `wmlib: can't allocate Display: /dev/draw/new: No such file` and fail to give you
  a usable login. Headless is only for running a single command directly
  (e.g. `o.emu -r$ROOT 2fa status`), **not** for interactive desktop use.

> ⚠️ If you see `/dev/draw/new: No such file or directory`, you are almost
> certainly running a **headless** binary. Rebuild with plain `mk` and relaunch.

After changing any device C (e.g. `fido2bridge.c`, `devtfa.c`), do a clean build to
avoid mixing backend objects:

```
cd emu/MacOSX && rm -f *.o o.emu && mk
```

Limbo modules rebuild to `dis/...` from their source dirs, e.g.:

```
cd appl/wm  && mk $ROOT/dis/wm/logon.dis
cd appl/lib && mk $ROOT/dis/lib/twofa.dis $ROOT/dis/lib/twofaslot.dis
cd appl/cmd && limbo -I$ROOT/module -o $ROOT/dis/2fa.dis 2fa.b
```

Launch the desktop:

```
cd $ROOT
./emu/MacOSX/o.emu -c1 -pheap=1024m -pmain=1024m -pimage=1024m -r$PWD sh -l /lib/lucifer/boot.sh
```

---

## 2. Check status

```
2fa status
```
Prints, for the current account, whether it is 2FA-enrolled and whether a key is
present, e.g. `account pdfinn: 2fa-enrolled=1  key-present=1`.

---

## 3. Enroll — turn a password account into a 2FA account

Run **after a normal login** (so secstored is up). Insert your key first.

```
2fa enroll
```
You are prompted for:

1. **`secstore password:`** — your normal login/secstore password.
2. **`recovery passphrase:`** — the anti-lockout passphrase (store it in your vault).
3. **`FIDO2 PIN (UV / AAL3; blank = touch-only):`**
   - Enter your **FIDO2 PIN** → **UV/AAL3** account (login will require the PIN).
   - Leave **blank** → **touch-only** account (login requires only a touch).

Then **touch the key twice** when prompted (once to create the credential, once to
bind the slot). On success the factotum is re-encrypted under a fresh DK, the key
and recovery slots are written, and the account is now 2FA.

The enroll is **never-brick**: every slot is built and verified to round-trip the DK
*before* the live factotum blob is replaced, and the blob swap rolls back if it
fails. It also requires the recovery passphrase up front.

---

## 4. Log in

At the login screen:

1. **Password** — your secstore password.
2. **`Security key PIN:`** — the screen prompts for it whenever the account has 2FA
   slots:
   - **UV account** → type your **FIDO2 PIN**.
   - **Touch-only account** → leave it **blank** and press Enter.
3. **Touch** the key.

If the key is **absent or fails**, login automatically falls through to:

4. **`Recovery passphrase:`** — type it to unlock via the recovery slot.

Password-only (legacy) accounts are unaffected — no PIN prompt, no change.

---

## 4a. Add a backup key (no single point of failure)

Enroll a **second** key so losing or breaking one never locks you out. The backup
wraps the *same* data key as your primary — in its own slot — so your vault is not
re-encrypted and your other slots are untouched.

Insert the **backup** key, then (after logging in) run:
```
2fa addkey
```
Prompts: **secstore password**, **recovery passphrase** (this authorizes the add —
no key-swap dance needed), and the backup's **FIDO2 PIN** (blank for touch-only).
Touch the backup twice. On success, either key (+ password) unlocks login.

The new slot appears as `2fa/key-<cred>` next to `key` and `recovery`, and is
verified to unwrap the data key *before* it is written. Repeat with more keys for
more backups — each gets its own uniquely-named slot.

> The backup must be a key libfido2 can enumerate (USB; NFC needs a reader). The
> recovery passphrase is required, so keep it in your vault.

## 5. Convert touch-only → UV (add a PIN)

There is no in-place upgrade; disable then re-enroll with a PIN:

```
2fa disable      # secstore password → recovery (blank if key present) → PIN (blank for touch-only) → touch
2fa enroll       # secstore password → recovery passphrase → FIDO2 PIN (enter it!) → touch x2
```

`disable` uses your present key (touch) to unlock the DK, re-encrypts the factotum
back under your password, and removes the slots (reverting to password-only). Then
`enroll` with a PIN gives you a UV/AAL3 account.

---

## 6. Disable (back to password-only)

```
2fa disable
```
Prompts: **secstore password**, **recovery passphrase** (blank if the key is
present), **FIDO2 PIN** (blank for touch-only). Touch the key. The factotum is
re-encrypted under the password and the slots are removed.

---

## 7. Recovery (lost / absent / locked-out key)

At login, when the key isn't usable, the screen offers
`Recovery passphrase:`. Enter the passphrase you set at enroll — it unwraps the DK
via the recovery slot and logs you in. Afterwards you can `2fa disable` and
re-enroll a new key.

> The recovery passphrase is the **only** way back in without the key. Store it in
> your vault. If you lose both the key *and* the recovery passphrase, the account's
> factotum is unrecoverable by design (at-rest strength is real).

---

## 8. Where things live

- **Slots & secstore data (host):** `~/.infernode/usr/inferno/secstore/<user>/`
  - `factotum` — DK-encrypted key vault
  - `PAK` — secstore auth material
  - `2fa/key`, `2fa/recovery` — wrapped-DK slots (cleartext headers `cred salt kind`
    + the wrapped blob; none of that is secret without the key)
  - Inside the emu this appears at `/usr/inferno/secstore/<user>/` via a **trfs**
    overlay (`/n/local` → host `/`), so it is **not** under the repo tree.
- **Back up the store before risky operations:**
  `cp -a ~/.infernode/usr/inferno/secstore /tmp/secstore.bak.$(date +%s)`

---

## 9. Crypto model (short version)

```
factotum_blob = encrypt3(vault, DK)              # AES-256-GCM, random DK
slot "key":      wrap = encrypt3(DK, KEK_key)     KEK_key = HMAC-SHA256(R, mkfilekey3(user,pass))
slot "recovery": wrap = encrypt3(DK, KEK_rec)     KEK_rec = mkfilekey3(user, recoverypass)
```
`R` is the YubiKey `hmac-secret` output for `(credential, salt)` — touch-gated, and
at UV it is the **WithUV** CredRandom (a different value than touch-only). Because a
2FA account has **no** password-only slot, the password alone cannot derive the DK.

---

## 10. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `/dev/draw/new: No such file`, `no display, using console` | running the **headless** binary | rebuild GUI: `cd emu/MacOSX && rm -f *.o o.emu && mk` |
| New launch falls to console after a crash | a **zombie `o.emu`** still holds the display | `pkill -9 -f o.emu` then relaunch |
| `secstore connect: ... invalid IP address` | running a 2fa command in a **bare emu** (no boot/secstored) | run it inside a normal desktop session |
| `get_assert: FIDO_ERR_UNSUPPORTED_OPTION` | setting the `uv` option *and* supplying a PIN | fixed — passing the PIN *is* the UV; don't also set `uv` |
| PIN prompt on a touch-only account | login prompts for a PIN whenever slots exist | leave it **blank** + Enter + touch |
| Wrong FIDO2 PIN repeatedly | **8-try hardware lockout** decrements | use the recovery passphrase; reset the FIDO app only as a last resort |
| `2fa enroll` on an already-2FA account fails to decrypt | the factotum is already DK-encrypted, not password-encrypted | `2fa disable` first, then `2fa enroll` |

---

## 11. Verifying UV is enforced (developers)

A standalone hardware test (`t2uv`) confirms the AAL3 property: enroll a UV
credential, derive twice **with** the PIN (must be deterministic), and derive
**without** the PIN (must return a *different* secret). Both PASS on real hardware
means the PIN is load-bearing. Build a GUI or headless emu, compile the test against
`module/twofa.m`, and run it with the key inserted.

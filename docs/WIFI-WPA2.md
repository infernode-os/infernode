# Joining a WPA2 network

This is how a machine with a CYW43455 radio — a Raspberry Pi 3B+ running
the bare-metal port — joins an encrypted home network, what each console
line means when it does not, and what is deliberately not implemented.

The reference pages are [`wpa(8)`](../man/8/wpa) for the program and
[`wpakey(2)`](../man/2/wpakey) for the module underneath it. This page is
the walkthrough.

## What does what

A CYW43455 is a *fullMAC* radio: the scanning, the 802.11 authentication
and the association all happen inside its firmware, and the kernel driver
publishes the result as an ordinary ethernet interface. Nothing about
WiFi is visible above the driver except four ctl verbs and two lines of
`ifstats`.

What the firmware cannot do is prove the machine knows the network's
passphrase, because the passphrase is not the radio's to hold. That
proof is the four-way EAPOL handshake — four frames of ethernet type
`0x888e` exchanged with the access point after association — and it ends
with two keys being handed down to the firmware. `ip/wpa` is the program
that runs it.

So the division is:

| | |
|---|---|
| firmware | scan, authenticate, associate, encrypt and decrypt frames |
| kernel driver (`os/bcm2837/ether4330.c`) | the SDIO transport, and the ctl verbs `essid`, `auth`, `txkey`, `rxkey`*n* |
| `ip/wpa` | the handshake, and the ctl writes that install what it derives |
| `factotum` | the passphrase |

## Telling factotum the passphrase

The passphrase is never a command-line argument — arguments are readable
through `/prog` by anyone who can see the process — and never a file in
the tree. It goes to `factotum`, keyed by the network it belongs to:

```
echo 'key proto=wpapsk role=client essid=home !password=secret' >/mnt/factotum/ctl
```

One key per network. A machine that moves between several keeps them all
and `ip/wpa` asks for the one matching the network it is joining, so
nothing has to be edited when the machine moves.

To keep it across reboots, put it in `secstore` the way every other key
in this system is kept; `factotum` reads them at logon.

## Joining

```
ip/wpa -s home /net/ether1 &
```

`-s home` is the network name. It is written to the interface, which is
what makes the radio join, and it is also the *salt of the key
derivation* — a network name that differs by one character produces a
completely different key, and the failure looks exactly like a wrong
passphrase. If the essid has already been set on the interface by
something else, `-s` can be left out and `ip/wpa` reads it back from
`ifstats`.

The interface argument defaults to `/net/ether1`. On the bare-metal port
the radio is the second ethernet instance, `#l1/ether1`; bind it where
the program expects it, or name it directly:

```
bind -a '#l1' /net
ip/wpa -s home &
```

`ip/wpa` does not fork into the background; run it with `&`. It stays
running for as long as the machine is on the network, because a
re-association needs a new handshake.

Once it reports the keys installed, the interface is an ordinary
ethernet interface and the rest is the usual:

```
bind -a '#I' /net
ip/dhcp /net/ether1
```

## What the console says

Every line begins `wpa: `.

| line | meaning |
|---|---|
| `/net/ether1: network home` | the name it will derive the key from — check it. A name containing spaces is printed quoted |
| `still waiting for the radio to associate` | 20 seconds with `ifstats` still reporting `unassociated` or `connecting`. The radio has not found or not joined the network: wrong name, out of range, or the firmware never started |
| `associated; starting the four-way handshake` | the radio joined, and the RSN element has been written to `ctl` |
| `pairwise receive key installed` | message 3 arrived and verified: the access point has the same passphrase |
| `pairwise transmit key installed` | message 4 has gone out and the transmit key is in |
| `group key 1 installed` | the broadcast key from message 3 |
| `bad MIC` | a frame's integrity check did not match. One of these against a noisy network is nothing. Every frame of a handshake failing means **the passphrase is wrong**, or the network name is |
| `stale replay counter N` | a retransmitted or replayed frame, ignored. Normal on a lossy link |
| `the wrapped key data did not unwrap` | message 3's group key did not decrypt: the key encryption key is wrong, which again means the passphrase is |
| `key descriptor version 1 (TKIP) is not implemented` | the network is WPA1, not WPA2. See below |
| `link lost; re-associating` | the driver deassociated and closed the queue; everything starts again |
| `no passphrase for 'home' in factotum` | no key with that `essid` — add one as above |

`-d` adds every frame in hexadecimal and prints the derived master key.
It is for debugging a handshake and it prints key material; do not leave
it on.

## When it will not join

In order, because each one makes the next unreadable:

1. **Is the radio up at all?** `cat /net/ether1/ifstats` must show
   `radio: present` and a `firmware:` line with a version. If it says
   `firmware: not loaded` the firmware has never been uploaded and no
   supplicant can help.
2. **Is the name right?** The first `wpa:` line prints what it will use.
   It is case-sensitive and it is the salt.
3. **Does the radio associate?** `status:` in `ifstats` goes
   `unassociated` → `connecting` → `associated` by itself. If it never
   leaves `unassociated`, the problem is below the supplicant.
4. **Does the handshake complete?** If `bad MIC` appears on every
   message 3, the passphrase is wrong. There is no other common cause.

## What is not implemented

- **WPA3 / SAE.** Not implemented, not begun. WPA3 replaces the
  pre-shared key with a dragonfly handshake and is a different program.
  A network set to "WPA3 only" cannot be joined; most access points can
  be set to WPA2/WPA3 mixed mode, which this joins as WPA2.
- **WPA enterprise (802.1X / EAP).** Not implemented. There is no
  RADIUS, no TLS tunnel, no PEAP or TTLS. `ip/wpa` ignores EAP packets
  (EAPOL type 0), so an enterprise network associates and then times out.
  Plan 9's `aux/wpa` implements this; it is a large amount of TLS
  plumbing and was left out deliberately.
- **WPA1 / TKIP.** Refused with a diagnostic. The message integrity
  check for key descriptor version 1 is implemented, but the RC4 unwrap
  of its key data is not, so accepting the earlier messages would only
  fail later and less clearly. WPA1 has been deprecated for over a
  decade.
- **WEP.** No.
- **Roaming.** There is none: no 802.11r fast transition, no scanning
  for a better access point, no band steering. If the association drops,
  `ip/wpa` waits for the firmware to associate again — to whatever it
  chooses — and runs a fresh handshake. Moving between access points on
  the same network works only as fast as the firmware re-associates.
- **PMKSA caching.** Every association is a full four-way handshake.
- **Management frame protection (802.11w).** The RSN element this
  supplicant offers has empty capabilities, so protected management
  frames are not negotiated.
- **Choosing a cipher.** WPA2 with CCMP for both the pairwise and the
  group cipher, and nothing else. The driver does not publish the access
  point's RSN element, so there is nothing to negotiate against; if a
  network insists on TKIP the join fails.

## How it is tested

`tests/wpa_test.b` checks the cryptography against published vectors —
RFC 6070 for PBKDF2, IEEE 802.11i Annex H for the passphrase-to-PSK
mapping and the PRF, RFC 3394 for the key unwrap — and drives a whole
four-way handshake from synthetic frames, asserting on the exact bytes
of the replies and the exact ctl lines. `tests/host/wpa_vectors_test.sh`
runs it as a named CI step.

`tests/host/wpa_join_test.sh` covers the other half, the part that is
I/O rather than arithmetic: it builds an interface out of plain files —
`addr`, `clone`, `ifstats`, and `0/data` holding a real message 1 — puts
the passphrase in a running factotum, runs `ip/wpa` against it, and
reads back what it wrote. The `connect`, `essid` and `auth` verbs must
appear on the ctl file and message 2 must be well formed, with its
integrity check recomputed independently from the station nonce the
supplicant actually drew from `/dev/random`. A wrong passphrase fails
it.

None of that involves a radio, and none of it can. **No part of this has
spoken to a real access point.** The board test is in
`os/bcm2837/README.md`.

# Remote desktop: using a headless InferNode from another one's screen

A Raspberry Pi in a cupboard, a Jetson, a QEMU guest: InferNode machines
often have no screen. From any InferNode that has one, you can run
programs **on** the headless machine that draw **on** your screen, in
either of two ways:

- **The whole desktop** ([3a](#3a-the-whole-desktop-in-its-own-window)):
  a window on your screen becomes the other machine's desktop, with its
  own window manager.
- **Single windows on your desktop** ([3b](#3b-single-windows-on-your-own-desktop)):
  individual programs from the other machine open as ordinary windows
  among your own.

Both use only programs that ship with InferNode, and both run over the
same authenticated, encrypted connection. This document takes you from
nothing to a working session, and explains each step so you can repair
it when it does not work. If Inferno or Plan 9 is new to you, read the
next section first: the rest makes much more sense with it.

**Words used here.** The **viewer** is the machine with the screen,
where you type `cpu`. The **node** is the headless machine you want to
use. The **signer** is one key, kept on the viewer, that vouches for
every machine and person allowed in.

| Step | Time | Where |
|-|-|-|
| [How this works](#how-this-works) | 5 min to read | |
| [0. Before you start](#0-before-you-start) | 5 min | both |
| [1. The signer and the certificates](#1-the-signer-and-the-certificates) | 5 min, once | viewer |
| [2. Turn on the node](#2-turn-on-the-node) | 5 min, once | node |
| [3. Connect: two ways](#3-connect-two-ways) | 1 min, each time | viewer |
| [4. End a session](#4-end-a-session) | | viewer |
| [5. Adding another person](#5-adding-another-person) | | viewer |
| [6. How it is protected](#6-how-it-is-protected) | | |
| [7. When it does not work](#7-when-it-does-not-work) | | |
| [8. Releases before these fixes](#8-releases-before-these-fixes) | | |

---

## How this works

Three ideas carry everything below. They come from Plan 9, the
operating system Inferno descends from, and they are what make a
"remote desktop" possible without any remote-desktop software.

**1. Devices are files.** Your screen, mouse and keyboard are not
special interfaces a program asks the system for; they are files in a
directory called `/dev`. A program draws by writing drawing commands to
`/dev/draw`, reads the mouse from `/dev/pointer`, and reads keys from
`/dev/keyboard`. Whatever files a program finds under those names are
its screen, mouse and keyboard.

**2. Each program sees its own view of the files (its "namespace").**
In Inferno, what a name like `/dev/draw` refers to is decided per
process, and you can change it: `bind` makes one directory appear at
another's place, and `mount` puts a file service (local, or from
another machine over the network) at a name. Two programs on the same
machine can see different things at `/dev`.

**3. Files can come from another machine.** Inferno's file protocol
(called 9P, or Styx) works the same over a network as locally. A
program reading a file that is really on another machine does not know
or care.

Put together: **to show a program's screen somewhere else, give it a
`/dev` whose drawing files are somewhere else.** That is all `cpu` does:

- `cpu` connects to the node, both sides prove who they are, and it
  sends the node a small namespace containing **your `/dev` only**.
  Additional files are delegated only when you explicitly name an export
  root with `-e`.
- On the node, a small program, `rstyxd`, puts your namespace at
  `/n/client` and lays **your** `/dev` over the node's own `/dev`.
- It then runs the command you gave. That command runs on the node's
  CPU, reads the node's files and uses the node's network, but when it
  opens `/dev/draw` it gets **yours** — so it draws on your screen, and
  reads your mouse and keyboard.

The two ways in step 3 differ only in *what* runs on the node:

- **3a** runs the node's own **window manager** (`wm/wm`), which takes
  over a whole screen: you give it a whole screen of its own.
- **3b** runs single programs as **clients of your window manager**.
  Your window manager can itself be offered as files (`wmexport`), and
  a program on the node can ask it for a window through them
  (`wmimport`). The program runs on the node; its window is one of
  yours.

One consequence to remember: inside a session, anything under `/dev` on
the node is **your** machine's, not the node's. The node's writable boot
mount is deliberately absent, and direct kernel-device attachment is disabled.

---

## 0. Before you start

**On the viewer** you need an InferNode with a screen. On a Mac this is
the downloaded app, `/Applications/InferNode.app`. Two facts about it
matter throughout:

- Its emulator is `/Applications/InferNode.app/Contents/MacOS/emu`, and
  its system files are in `/Applications/InferNode.app/Contents/Resources`.
  Never write into that folder: it is replaced on every update, and
  writing into a signed app can stop macOS opening it.
- Your own InferNode files live in **`~/.infernode`** in your Mac home.
  Inside InferNode, `~/.infernode/usr` appears as **`/usr`**, and your
  InferNode user name is your Mac login name. So what InferNode calls
  `/usr/alice/keyring` is `~/.infernode/usr/alice/keyring` on the Mac.
  This only happens in a **login shell** (`sh -l`, or a shell inside the
  Lucifer desktop); a plain `sh` sees the app's own `/usr` instead.

**On the node** you need an InferNode that boots and is on a network the
viewer can reach. For a Raspberry Pi, [BAREMETAL.md](BAREMETAL.md)
section 4 covers making the card. You also need a way to see what it
prints while you set it up: its serial console, or a monitor plugged
into it.

**Find the node's address.** A bare-metal node prints its addresses as
it boots:

```
etherusb: DHCP gave 192.168.1.50 mask 255.255.255.0
init: wifi: ip=192.168.4.23 ipmask=255.255.255.0 ipgw=192.168.4.1
```

The first is the wired port, the second the Wi-Fi. Your router's list
of connected devices shows them too.

**Check the viewer can reach it.** From a Mac terminal (not InferNode):

```sh
nc -vz 192.168.1.50 6668
```

`succeeded` or `refused` both mean the machine is reachable (`refused`
just means its listener is not on yet — that is step 2). `timed out`
means the viewer cannot reach that address at all: typically a laptop
on a guest Wi-Fi and a node on the wired network, which guest networks
keep apart. Use the node's address on the viewer's network.

---

## 1. The signer and the certificates

Once, on the viewer. Open a login shell in InferNode — the shell in the
Lucifer desktop, or on a Mac from Terminal:

```sh
/Applications/InferNode.app/Contents/MacOS/emu -c1 -r/Applications/InferNode.app/Contents/Resources sh -l
```

First look at what is already there, so nothing gets overwritten:

```
ls -l /usr/$user/keyring
```

Then, **one line at a time**:

```
auth/createsignerkey -f /usr/$user/keyring/signer $user-signer
auth/mkauthinfo -k 'key=signer' $user /usr/$user/keyring/default
auth/mkauthinfo -k 'key=signer' mynode /usr/$user/keyring/node-mynode
```

1. **The signer.** The one key that matters. It stays in your keyring,
   readable by you only. Never copy it anywhere, and back it up as you
   would a password manager's master password.
2. **Your certificate**, as `keyring/default`, which is where `cpu`
   looks. If the `ls` showed a `default` you already use for something
   else, don't overwrite it: name this certificate after the address you
   will dial instead, e.g. `'/usr/'$user'/keyring/tcp!192.168.1.50'`
   (`cpu` tries `keyring/<the address you dial>` before `default`).
3. **The node's certificate.** Replace `mynode` with the node's name.
   This is the one file that goes to the node.

Two things that go wrong here:

- `'key=signer'` **must be quoted**. Unquoted, the Inferno shell reads
  it as a variable assignment and the command fails with a syntax
  error.
- Your certificate's name (`$user`) must be **the same as your user name
  on the viewer**. Programs on the node that check who they are talking
  to — acme is one — compare the two and refuse if they differ.

To make certificates expire, add `-e ddmmyyyy` to `mkauthinfo`.

---

## 2. Turn on the node

The listener is **off by default** on every install. Turning it on
takes the node's certificate and one setting.

### A bare-metal node (Raspberry Pi)

Power the node off and put its SD card in any computer. On the card's
boot partition (the one with `config.txt`):

1. **The node's certificate.** Copy the file from step 1 to
   `usr/inferno/keyring/default` on the card, creating the folders if
   they are not there. On a Mac, the file is
   `~/.infernode/usr/<your login>/keyring/node-mynode`.
2. **The switch.** Create an empty file named `cpulisten`. Empty means
   the standard port, 6668. To use another, put an address on its first
   line, e.g. `tcp!*!17030`, and dial that port in step 3.
3. **Recommended: keep the admin console to the wire.** If the card has
   a `netconsole` file (the network console: a full-power shell behind a
   plain-text password), add a line `interface ether0` to it, so it
   answers only on the wired port and never over Wi-Fi. See
   [BAREMETAL.md](BAREMETAL.md) section 7.

Put the card back and boot. Check that the node prints:

```
boot: cpu listener on tcp!*!rstyx (AES-256 + SHA-256, certificate /usr/inferno/keyring/default)
```

If it says `cpulisten is set but … is missing; NOT starting` instead,
the certificate is not at `usr/inferno/keyring/default` on the card.

### A hosted node (a machine running the InferNode app, used headless)

Copy the node's certificate to that machine's
`~/.infernode/usr/<login>/keyring/default`, then in a login shell there:

```
listen -a aes_256_cbc -a sha256 'tcp!*!rstyx' auxi/rstyxd &
```

It runs as long as that emulator does. The host's firewall may ask to
allow incoming connections on port 6668.

---

## 3. Connect: two ways

| | [3a. The whole desktop](#3a-the-whole-desktop-in-its-own-window) | [3b. Single windows](#3b-single-windows-on-your-own-desktop) |
|-|-|-|
| What you get | A window that **is** the node's desktop, with its own window manager | The node's programs as **ordinary windows on your desktop**, mixed with your own |
| Good for | Working "on" the node: a full session there, many programs, its own menus | Using one or two of the node's programs alongside your own work |
| Needs | A second emulator on the viewer, as a screen for the node | A window manager running on the viewer (`wm/wm`) |
| What runs on the node | Its window manager, and everything started from it | Only the programs you ask for |

Both are started from the viewer, and both use the certificates from
step 1. Whichever you use, the first connection takes a few seconds for
the handshake, and everything is slower than local: every change on
screen crosses the network, several times more slowly over Wi-Fi than
over a cable.

### 3a. The whole desktop, in its own window

Your own desktop is busy drawing itself, so the node's desktop gets **a
second emulator, as its own window**. On a Mac, in Terminal, from any
folder:

```sh
/Applications/InferNode.app/Contents/MacOS/emu -c1 -g1024x768 -r/Applications/InferNode.app/Contents/Resources sh -l
```

A window opens (empty for now), and Terminal shows the emulator's `;`
prompt. At that prompt:

```
cpu tcp!192.168.1.50 wm/wm wm/sh &
```

The window becomes the node's desktop: its window manager, with a shell
that runs on the node.

What happens: `cpu` sends your namespace to the node, including this
emulator's `/dev` — its window. On the node, `wm/wm` opens `/dev/draw`,
gets this window, and treats it as its whole screen.

- **`sh -l`, not `sh`.** Only a login shell sees your keyring in
  `~/.infernode`; without it `cpu` says it cannot find a certificate.
- **A non-standard port** (step 2.2) goes on the address:
  `cpu tcp!192.168.1.50!17030 wm/wm wm/sh &`.
- **Keep working locally at the same time.** The trailing `&` runs the
  session in the background, so the `;` prompt in Terminal stays yours:
  commands you type there run on your own machine while the node's
  desktop runs in the window. Ordinary shell job control applies — `&`
  for any number of background jobs, `ps` to list them, `kill` to stop
  one.
- **One desktop per emulator.** An emulator's window is one screen, and
  a second window manager (another node's, or a local `wm/wm`) would
  fight the first for it. For two desktops, start a second emulator in
  another Terminal tab: one window per desktop.

### 3b. Single windows, on your own desktop

Here the node's programs open as windows in **your** window manager.
Start a viewer emulator as in 3a, then give it a window manager of its
own:

```
wm/wm
```

A shell window appears inside it. **In that shell window**, one line at
a time:

```
mkdir -p /tmp/cpuexport/dev /tmp/cpuexport/wmx
bind /dev /tmp/cpuexport/dev
mount {wmexport} /tmp/cpuexport/wmx
cpu -e /tmp/cpuexport tcp!192.168.1.50 wmimport -w /n/client/wmx wm/sh &
```

A new window opens among your own, and the shell in it runs on the
node. Each further `cpu … wmimport … &` line adds another window; put
any program in place of `wm/sh`: `wm/clock`, `acme`, `wm/tetris`.

What each line does:

1. **`mkdir …; bind /dev …`** builds the exact caller-side tree this
   session will receive: the display devices plus one window-manager mount.
2. **`mount {wmexport} /tmp/cpuexport/wmx`** runs the stock program `wmexport`,
   which **serves your window manager as files**: opening
   `/tmp/cpuexport/wmx/clone` creates a new window in it, and each window's
   keyboard, mouse and window-control files appear beside it. The
   braces mean "the files served by this command", and `mount` puts
   them at `/tmp/cpuexport/wmx`. It must be typed in a shell *inside* the window
   manager — that is where it learns which window manager to serve.
3. **`cpu -e /tmp/cpuexport … wmimport -w /n/client/wmx wm/sh &`** runs
   `wmimport` on the node. Only the tree you named arrives under
   `/n/client`, so `/n/client/wmx` is your window manager, seen from
   the node. `wmimport` asks it for a window through those files and
   runs `wm/sh` in it. The program runs on the node; it draws into a
   window of yours, on your screen (your `/dev/draw`, laid over the
   node's), and your window manager gives it your keyboard and mouse
   when its window is in front.

This needs no `bind -a '#i' /dev` on any release: your window manager
already has the display in `/dev`. It has been checked with the stock
`wm/wm` as the viewer's window manager; whether it works from a shell
inside the Lucifer desktop is untested.

---

## 4. End a session

A session ends when the command you gave `cpu` ends, and everything it
started on the node ends with it:

**3a:** close the node's window manager (its menu, or `exit` in its
shell). `cpu` returns, and every program you started from that desktop
stops on the node.

**3b:** quit the remote program in its window (for a shell, `exit`).

If your side simply goes away instead -- you close the emulator, the
laptop sleeps, the network drops -- the node notices within a few
seconds and ends the session the same way, so nothing is left running
there for nobody.

**Older releases** did neither
([#732](https://github.com/infernode-os/infernode/issues/732)): `cpu`
did not return after a one-shot command, and programs from a session
kept running on the node, as you, after you disconnected, quietly using
its CPU until it was restarted. On a node running one of those, quit
what you started before you close anything.

---

## 5. Adding another person

Issue them **their own** certificate from your signer, never a copy of
yours, and make it expire:

```
auth/mkauthinfo -e 31122026 -k 'key=signer' bob /usr/$user/keyring/bob
```

Send them that one file. They put it in their own keyring as `default`
(step 1.2), and their InferNode user name must be `bob` too. There is no
way to withdraw one certificate early: its expiry is the limit, and the
only other way is a new signer and new certificates for everyone.

---

## 6. How it is protected

- **Nothing listens unless you turned it on** (step 2), per node.
- **Both ends prove who they are.** The node accepts only certificates
  from your signer, and you know you reached the node you certified.
- **Encrypted and tamper-evident.** The session key comes from a hybrid
  exchange — classical Diffie-Hellman plus **ML-KEM-768**, a post-quantum
  key agreement — so recorded traffic stays private even against a
  future quantum computer. Every record is then encrypted (AES-256) and
  carries a SHA-256 MAC, so altered or cut traffic is an error, not a
  surprise. `cpu` asks for both by default; a bare-metal node refuses
  anything less.
- **The certificates themselves are ed25519**, which is not
  post-quantum: a future quantum computer could forge one. Post-quantum
  signatures (`createsignerkey -a mldsa87`, with `CNSAMODE=1` on both
  ends, which also raises the exchange to ML-KEM-1024) exist, but have
  not yet been verified on a bare-metal node.
- **A desktop's powers, no more** (bare-metal node). A session can run
  programs and use ordinary node files, but the server's `/usr` and `/n/dos`
  mounts are absent and fresh
  device attachment is disabled after the caller's `/dev` is installed.
  It therefore has no raw card, GPIO pins or kernel sysctl. The loaded
  listener key has no backing path in the session, and the server's
  `/mnt/factotum` and `/tmp/factotum` credential oracles are masked.
- **The viewer delegates devices, not credentials.** `cpu` exports only
  `/dev` by default. `-e` is an explicit capability grant; do not use
  `-e /` with a node you would not trust with your keyring and host mounts.
- **User identities are the process boundary.** The node retains `/prog`
  because shells need it to wait for children. Its ordinary owner permissions
  therefore apply: two certificates with the same Inferno user name are not
  isolated from each other's processes. Give independent people distinct
  certificate names, as in section 5.
- **One host cannot lock others out** by opening many connections: each
  address may hold at most four handshakes in progress (`listen -P`).

---

## 7. When it does not work

| What you see | What it means, and the fix |
|-|-|
| `cpu: cannot find certificate in /usr/…/keyring/` | No `default` and no file named for the address you dialled. Or the shell is not a login shell (`sh -l`), so `/usr` is not your `~/.infernode`. |
| `cpu: authentication failed: pk doesn't match certificate` | Your certificate and the node's come from different signers — often a node still holding an old key. |
| `cpu: dial: … timed out` | The viewer cannot reach that address: another network, a firewall, or the listener is off. Check with `nc -vz` (step 0). |
| `cpu` returns to the prompt with no message | The node refused the session; the reason is on the node's console ([#733](https://github.com/infernode-os/infernode/issues/733)). Most often `client omitted required integrity algorithm` — see section 8. |
| The window stays black, and **the node's own monitor** shows a desktop | The viewer's `/dev` had no display in it, so the node's own display showed through. See section 8, `bind -a '#i' /dev`. |
| A grey window that fills in slowly | Normal over Wi-Fi. If it is very slow, something left on the node is using its CPU (section 4). |
| `wmexport: no window manager context` (3b) | `mount {wmexport}` was typed in a shell that is not inside a window manager (for example Terminal's `;` prompt). Type it in the shell window inside `wm/wm`. |
| `wmimport: no wm at /n/client/wmx` (3b) | The `mount {wmexport} /tmp/cpuexport/wmx` step was skipped or failed, or `cpu -e /tmp/cpuexport` was omitted. |
| acme says `can't mount /mnt/acme` | Your certificate's name differs from your user name on the viewer (step 1). |
| Starting the viewer closes your Lucifer desktop | Section 8. |
| `boot: /n/dos/cpulisten is set but … missing; NOT starting` | The node's certificate is not at `usr/inferno/keyring/default` on the card. |

The node's console (serial, monitor, or network console) logs every
refused connection with its reason — the first place to look.

---

## 8. Releases before these fixes

The steps above assume a release with the fixes from September 2026
(pull requests #728, #730, #731 and #739). On an older one:

- **Before running `cpu`**, type `bind -a '#i' /dev` in the viewer.
  Older `cpu` bound the wrong device for the display, so without this
  the node draws on its own monitor and your window stays black.
- **Name the ciphers**, in both 3a and 3b: `cpu -C 'aes_256_cbc sha256' tcp!…`,
  quoted exactly so. Older `cpu` defaulted to no encryption, and a node that
  requires both refuses encryption without the MAC (`client omitted
  required integrity algorithm`).
- **`mkauthinfo` ignored its file argument**: write
  `auth/mkauthinfo -k 'key=signer' $user > /usr/$user/keyring/default`.
- **Starting the viewer's emulator closed your Lucifer desktop** (its
  login shell stopped the other instance's key server). Quit the
  desktop before starting a viewer.
- **A bare-metal node without `cpulisten` support** needs its listener
  started by hand, from its serial or network console, after every
  boot:
  `mkdir /tmp/client; bind -a /tmp /n; listen -a aes_256_cbc -a sha256 'tcp!*!rstyx' auxi/rstyxd &`.
  Started that way it has the console's full powers, not a desktop's.

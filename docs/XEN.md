# xen — Xenith or sam on host files

`tools/xen` opens files from the host (macOS, Linux, Windows) in an
InferNode instance that runs nothing but an editor, the way Acme-SAC
runs acme. There is no Lucifer, no window manager desktop and no login:
the emu window is the editor, and leaving the editor ends the instance.

```sh
xen file.c other.b      # Xenith, dark, filling the window
xen -s file.c           # sam
xen -w file.c           # wait until the editor is closed
```

| Editor | Runs as | Leaving it |
|---|---|---|
| Xenith (default) | alone, with no window manager, over the whole emu window | middle-click **Exit** in the top tag halts the emu |
| sam (`-s`) | `wm/sam` under `wm/wm` (sam is Tk, so it needs one) | `q` in the `~~sam~~` command window, or **exit** on its menu, halts the emu |

On a Mac trackpad, **Option+click** is button 2 (middle) and
**Cmd+click** is button 3.

## Setup

Build the tree first (emulator and `dis/`; see
[QUICKSTART.md](../QUICKSTART.md)). Then put `xen` on your PATH:

```sh
ln -s /path/to/infernode/tools/xen ~/bin/xen
```

The script follows the link back to the tree it lives in. To run a
different tree, set `INFERNODE_ROOT`.

On Windows use `tools\xen.ps1` (`-Sam`, `-Wait` in place of `-s`, `-w`).
Only `C:` is mounted inside InferNode, so files on other drives are
refused.

Verified on macOS. Linux uses the same script and is yet to be checked
on a Linux host (INFR-522); `xen.ps1` is untested and has no host
plumbing.

## Behaviour

- Host files are reached through `/n/local`, which the profile mounts
  over the host root: `/Users/me/f.c` is `/n/local/Users/me/f.c`. The
  editor starts in the directory `xen` was run from.
- Without `-w`, `xen` returns at once and the editor runs detached; its
  output goes to `$TMPDIR/xen.log`. With `-w` it runs in the
  foreground and returns when the editor is left, so it can be used as
  `EDITOR='xen -w'`.
- Each `xen` invocation is a separate instance. To open files in one
  that is already running, plumb them (below).
- Xenith's tag line cuts a file name at its first space (as Inferno's
  acme does); sam shows such names whole.

| Variable | Meaning | Default |
|---|---|---|
| `INFERNODE_ROOT` | tree to run | the tree holding the script |
| `XEN_THEME` | the session's theme: any installed theme; `glenda` is Plan 9's acme | `xenith` |
| `XEN_GEOM` | initial window size | `1400x900` |
| `XEN_LOG` | where a detached instance's output is added, between a line marking its start and one giving the emu's exit status | `$TMPDIR/xen.log` |
| `INFERNODE_HIDPI` | `0` draws Xenith in points, each doubled on a Retina display, instead of in the display's own pixels | `1` |

On a Retina display Xenith draws in the display's own pixels: the emu
reports two pixels to the point (`emu(1)`), and Xenith doubles its
scroll bar, borders and tick and takes its fonts' double-size builds
under their usual names, so `go.14.font` looks the size it always did,
only sharp. sam is still drawn in doubled points.

A stand-alone Xenith is pinned to its theme: switching the system theme
(Settings, or a write to `/lib/lucifer/theme/current`) leaves it alone,
and its `Theme` command (`Theme halo`, or `Theme` alone for the next)
changes that session only. See [XENITH.md](XENITH.md#themes). sam's
colours follow the system theme rather than `XEN_THEME`.

## Plumbing

Inside Xenith, plumbing works as in acme: button 3 (Cmd+click) on a file
name, `name:42`, a directory or `ls(1)` opens it; `plumb` run from a tag
does the same. `xen` starts a plumber for this, with the rules in
`lib/xen/plumbing`. sam does not plumb.

**From the host, with plan9port.** A running Xenith also listens on a
`xenith` port of plan9port's plumber, so `plumb file` in a host terminal
opens the file in it, as plan9port's acme would. Set it up once:

```sh
# ~/lib/plumbing (plan9port's rules file)
include /path/to/infernode/tools/xen.plumbing
include basic
```

and have plan9port's `plumber` running. One line in your shell start-up
(`~/.zshrc`, after plan9port's `bin` is on `PATH`) starts it once per
login:

```sh
9p ls plumb >/dev/null 2>&1 || plumber
```

Then:

```sh
plumb foo.c          # opens in the running Xenith
plumb foo.c:42       # at line 42
plumb .              # a directory
```

With no Xenith running, the plumber starts `xen` on the file (so `xen`
must be on the plumber's `PATH`). The rules come before `include basic`,
so plumbed files go to Xenith instead of plan9port's acme; leave the
include out to keep acme.

How it works: `xen` finds plan9port's `9p` on the host and runs
`9p read plumb/xenith` through `os(1)`, piping it to `hostplumb(1)`,
which places host paths under `/n/local` and plumbs each message inside
InferNode. The host side of that pipe ends when the emulator does.
Every running Xenith reads the port, so with two running, a plumbed file
opens in both.

## Remote hosts

A file on another machine you ssh to can be plumbed from there into
the Xenith on your Mac, and saving it saves it on that machine.

```sh
hephaestus$ plumb src/foo.c:42     # opens in Xenith on the Mac
```

How it works: one long-lived ssh per host, kept up by launchd on the
Mac, carries the Mac's plumber to the host (`-R` to `~/.plumb.sock`);
the host's `plumb`
(`tools/rplumb`, a small 9P client) sends the file's absolute path,
tagged `host=<name>`, to the `xenith` port; Xenith's `hostplumb` opens
it under `/n/<name>`, where `xen` has mounted that host's file system
over ssh with Plan 9's `u9fs`. No listener runs on the host, and ssh's
own authentication covers both directions.

Setting up a host (say `hephaestus`):

1. On the host: build `u9fs` (from Plan 9's
   `sys/src/cmd/unix/u9fs`) into `~/bin`; install `tools/rplumb` as
   `~/bin/plumb`; write the name the Mac ssh's to it as into
   `~/.plumbhost`.
2. On the host, as root, let a new forward replace a dead one's
   socket (after the Mac sleeps, say):
   `echo 'StreamLocalBindUnlink yes' | sudo tee /etc/ssh/sshd_config.d/plumb.conf`
   then `sudo systemctl reload ssh`.
3. On the Mac, a launchd agent that holds the forward open,
   `~/Library/LaunchAgents/com.you.plumbfwd.hephaestus.plist`, running
   `/usr/bin/ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes
   -o ServerAliveInterval=30 -o ServerAliveCountMax=3
   -R /home/you/.plumb.sock:/tmp/ns.you/plumb hephaestus` with
   `RunAtLoad` and `KeepAlive` (and a `ThrottleInterval` of 30, so a
   host that is down is retried every half minute); load it with
   `launchctl bootstrap gui/$(id -u) <plist>`. It needs a key that
   works without the ssh agent.

   Not a `RemoteForward` in `~/.ssh/config` for interactive sessions,
   as this first did: each new session took the socket from the last
   (`StreamLocalBindUnlink`) and left it dead when it closed, so one
   short ssh broke plumbing for every session still open.
4. On the Mac, in `~/.zshrc`: a fixed plumber name space, and the hosts
   to mount: `export NAMESPACE=/tmp/ns.$USER`,
   `export XEN_HOSTS="hephaestus"`.

`xen` mounts the `XEN_HOSTS` hosts before Xenith starts (Xenith keeps
the name space it starts with), so a host added later needs a new
`xen`. A host that cannot be reached is skipped after a few seconds.
New files written through `u9fs` are created mode 666.

## For agents

When the user asks to have a file opened for them to read or edit, run
`plumb <file>` (on a remote host set up as above, too) (or `plumb <file>:<line>`): it opens in the Xenith the
user already has running, or starts one if none is. If `plumb` fails
(plan9port's plumber is not running), run `xen <file>` instead, which
starts a new instance. For sam, run `xen -s <file>`. These return
immediately and the editor appears on the user's screen; do not wait on
them. Use `xen -w` only when the next step depends on the user having
finished editing (for example, a commit message they are writing), and
expect it to block until they close the editor.

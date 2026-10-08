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
**Cmd+click** is button 3. On Linux use a three-button mouse (or the
touchpad's middle-click emulation); a touchscreen's long press is
button 3.

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

Verified on macOS, and on Linux (INFR-522): natively under Wayland
(Weston at scale 1 and 2, windowed and full screen) and under X11 at
1x and 2x (editing, resizing, host plumbing and remote hosts). Build
the Linux emulator with SDL3 (`./install-sdl3.sh`, then
`./build-linux-amd64.sh` or `./build-linux-arm64.sh`): a headless build
is refused.

On Linux SDL runs the emu as a Wayland client when the compositor has
the `fifo-v1` protocol (current GNOME and KDE), and through XWayland
otherwise; `SDL_VIDEODRIVER=wayland` or `x11` chooses. Under Wayland
the window's title bar is drawn by the client, with libdecor:
`install-sdl3.sh` builds SDL with it, and the desktop needs a libdecor
plugin (`libdecor-0-plugin-1-gtk`, installed with GNOME). An SDL built
without it opens a window with no title bar on GNOME, which cannot be
moved or maximised with the mouse. `xen.ps1` is untested and has no host plumbing. `lib/xen/boot.sh`,
which all of them run, is tested headless by
`tests/host/xen_boot_test.sh`.

## The Xenith app

Every release also ships Xenith as an app of its own: `Xenith.app` in
`xenith-<version>-macos-arm64.dmg`, and `Xenith.exe` in
`xenith-<version>-windows-amd64.zip`. Each is InferNode's emulator and
runtime tree with its own name, icon and launcher, and runs what `xen`
runs, Xenith alone over the whole window, starting in your home
directory. Both share `~/.infernode` with InferNode, so settings, keys
and the model configuration are the same in either. Files dropped on
`Xenith.exe` (or opened with it) are opened in the new instance, on C:
only; on macOS, open files by plumbing them (below) or from Xenith
itself.

`xen`, `xen.ps1` and both apps start the same way, through
`lib/xen/boot.sh`: a plumber, the model service, then Xenith with the
arguments given. The bundle and launcher sources are
`MacOSX/Xenith.app` and `emu/Nt/infernode-launcher.c` built with
`/DXENITH` (`emu/Nt/build-launcher.ps1` builds both launchers); the
icon is `MacOSX/Xenith.png`, from which `Xenith.icns` and
`Nt/Xenith.ico` are made.

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
| `INFERNODE_HIDPI` | `0` draws Xenith in points, each doubled on a Retina or HiDPI Linux display, instead of in the display's own pixels | `1` |

On a Retina display Xenith draws in the display's own pixels: the emu
reports two pixels to the point (`emu(1)`), and Xenith doubles its
scroll bar, borders and tick and takes its fonts' double-size builds
under their usual names, so `go.14.font` looks the size it always did,
only sharp. sam is still drawn in doubled points.

Linux is the same at the desktop's scale: 200% in GNOME or KDE on
Wayland, or on X11 `Xft.dpi: 192` (or `GDK_SCALE=2`). On X11 the
window is in pixels, so the emu also makes it that much larger:
`XEN_GEOM` is in points on every host.

A fractional scale, common on Wayland laptops, is drawn in the
display's own pixels too: the emu reports it in quarters (`1.25`,
`1.5`), Xenith scales its chrome by it, and Go and Go Mono have builds
at 1.25x and 1.5x (20, 21, 22, 24, 27) beside the 2x ones, so each
name is bound to the build nearest its size times the scale; 175%
takes 24, 28 and 32. Render's bold and italic Go faces have no
fractional builds and take their nearest size, within a tenth; Noto
Serif (Font's third face) has none either, and can be up to a sixth
off.

A stand-alone Xenith is pinned to its theme: switching the system theme
(Settings, or a write to `/lib/lucifer/theme/current`) leaves it alone,
and its `Theme` command (`Theme halo`, or `Theme` alone for the next)
changes that session only. See [XENITH.md](XENITH.md#themes). sam's
colours follow the system theme rather than `XEN_THEME`.

## The agent

Middle-click **Agent** in a tag (or run `Agent -p <dir>`) for a window
on the Veltro agent, granted the directory `xen` was run from unless
`-p` says otherwise. Type at the end of the body and middle-click
**Send**; the reply arrives as it is generated, tool calls and all.
**Stop** cancels the turn, **Reset** starts the model over, **Allow** and
**Deny** answer a request for approval shown in the body, **Delete**
ends it. `xen` starts the model service the way Lucifer's boot does
(`lib/lucifer/llmsrv.sh`, from `/lib/ndb/llm`); `Agent` starts the tool
server and the agent harness itself. See `man 4 veltrosrv` and
[VELTRO.md](VELTRO.md).

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
(`~/.zshrc` on a Mac, `~/.bashrc` on Linux, after plan9port's `bin`
is on `PATH`) starts it once per login:

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
the Xenith on your Mac or Linux desktop, and saving it saves it on
that machine. Below, "the Mac" is whichever machine runs Xenith.

```sh
hephaestus$ plumb src/foo.c:42     # opens in Xenith on the Mac
```

How it works: one long-lived ssh per host, kept up by launchd on the
Mac (a systemd user service on Linux), carries the Mac's plumber to the host (`-R` to `~/.plumb.sock`);
the host's `plumb`
(`tools/rplumb`, a small 9P client) sends the file's absolute path,
tagged `host=<name>`, to the `xenith` port; Xenith's `hostplumb` opens
it under `/n/<name>`, where `xen` has mounted that host's file system
over ssh with Plan 9's `u9fs`. No listener runs on the host, and ssh's
own authentication covers both directions.

Setting up a host (say `hephaestus`):

1. On the host: build `u9fs` (from Plan 9's
   `sys/src/cmd/unix/u9fs`) into `~/bin` (if `rune.c` stops on
   `Bit5` and `Runemax`, add `Bit5 = 2,` after `Bit4` and replace
   `Runemax` with `0x10FFFF`); install `tools/rplumb` as
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

   On a Linux desktop, a systemd user service does the same,
   `~/.config/systemd/user/plumbfwd@.service`:

   ```ini
   [Unit]
   Description=Forward the plumber to %i

   [Service]
   ExecStart=/usr/bin/ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes \
       -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
       -R /home/you/.plumb.sock:/tmp/ns.%u/plumb %i
   Restart=always
   RestartSec=30

   [Install]
   WantedBy=default.target
   ```

   started with `systemctl --user enable --now plumbfwd@hephaestus`.
   `/home/you` is your home on the host; `%u` is your user name here.

   Not a `RemoteForward` in `~/.ssh/config` for interactive sessions,
   as this first did: each new session took the socket from the last
   (`StreamLocalBindUnlink`) and left it dead when it closed, so one
   short ssh broke plumbing for every session still open.
4. On the Mac, in `~/.zshrc` (`~/.bashrc` on Linux), before the line
   that starts the plumber: a fixed plumber name space, and the hosts
   to mount: `export NAMESPACE=/tmp/ns.$USER`,
   `export XEN_HOSTS="hephaestus"`. On Linux this matters more:
   plan9port's default there is `/tmp/ns.$USER.$DISPLAY`, which the
   forward above, started without a display, cannot name.

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

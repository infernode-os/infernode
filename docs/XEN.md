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

## Behaviour

- Host files are reached through `/n/local`, which the profile mounts
  over the host root: `/Users/me/f.c` is `/n/local/Users/me/f.c`. The
  editor starts in the directory `xen` was run from.
- Without `-w`, `xen` returns at once and the editor runs detached; its
  output goes to `$TMPDIR/xen.log`. With `-w` it runs in the
  foreground and returns when the editor is left, so it can be used as
  `EDITOR='xen -w'`.
- Each invocation is a separate instance.
- Xenith's tag line cuts a file name at its first space (as Inferno's
  acme does); sam shows such names whole.

| Variable | Meaning | Default |
|---|---|---|
| `INFERNODE_ROOT` | tree to run | the tree holding the script |
| `XEN_THEME` | Xenith theme; `plan9` for the classic colours | `dark` |
| `XEN_GEOM` | initial window size | `1400x900` |
| `XEN_LOG` | output of a detached instance | `$TMPDIR/xen.log` |

sam's colours follow the Lucifer theme rather than `XEN_THEME`.

## For agents

When the user asks to have a file opened for them to read or edit, run
`xen <file>` (or `xen -s <file>` if they ask for sam). It returns
immediately and the editor appears on the user's screen; do not wait on
it. Use `-w` only when the next step depends on the user having finished
editing (for example, a commit message they are writing), and expect it
to block until they close the editor.

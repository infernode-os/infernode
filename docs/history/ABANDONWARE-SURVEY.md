# Plan 9 and Inferno® abandonware survey

Programs that shipped in an original Bell Labs / Lucent / Vita Nuova release
of Plan 9 or Inferno® and later disappeared, found by diffing the release
trees against each other and against this one. This covers original releases
only, not contrib or third-party ports.

## Sources examined

| Tree | Where | Notes |
|------|-------|-------|
| Plan 9 1E (1993-01-03), 2E (1995-04-05), 3E (2001-03-28), 4E (final) | `github.com/plan9foundation/plan9`, tags `1e-*`, `2e-*`, `3e-*`, `main` | All editions MIT-licensed by the Plan 9 Foundation (2021) |
| Plan 9 extras | `9p.io/sources/extra` (`INDEX`) | 2E ports (`mothra`, `art`, `alef.tgz`, `ktrans-2e`, `sun.tgz`), `9hist` kernel history |
| Inferno 1E beta (1997) | `github.com/inferno-os/inferno-1e0` | Lucent beta, Build 1; some apps under `appl/work/` |
| Inferno 1E (Vita Nuova copy) | `github.com/inferno-os/inferno-1e1` | |
| Inferno 2E (1999) | `github.com/inferno-os/inferno-2e` | |
| Inferno 3E (2003-06-04) | `github.com/inferno-os/inferno-3e` | |
| Inferno 4E | `github.com/inferno-os/inferno-os` | This tree's upstream |

Every Inferno tree's top-level `NOTICE` is MIT, but the NOTICE defers to
per-file headers, and some files carry a restrictive 1990s Lucent notice
("not to be used as the basis of manufacture … without the prior written
consent of Lucent"). The files with that notice: 2E `appl/mailtool/*` (6
files), `appl/cmd/rcb.b`, `appl/lib/rcbsrv.b`, `appl/wm/azertykb.b`,
`appl/svc/ppp/pppgui.b`, and 4E `appl/cmd/man2html.b`. Leave those out.

The counts: of the Inferno `.b` sources, 350 appear in 1E–3E and in neither
4E nor this tree, and 395 are in 4E but not here. Most of them are library
or plumbing code. The programs below are the ones worth a look.

## Plan 9

### Games tree (1E/2E; 3E shipped without `/sys/src/games`)

From `sys/man/1/games` (2E) unless noted. All C, against the old `libg`
(Bitmap/`bitblt`) graphics library, so a port is a rewrite to Limbo/Draw.

| Program | What it is | Size / data | Later |
|---------|------------|-------------|-------|
| `games/fsim` | "Pretend you're flying a Cessna." Instrument-panel flight simulator: ADF, VOR, DME, altimeter, ASI, attitude, rate of climb, navaid tables | 28 files, ~490 KB C | Gone after 2E |
| `games/road`, `games/gps` (2E; 1E `tiger` in `cmd`) | Road map of the US drawn from Census TIGER data in three greys (water, rail/airports, roads). `-g` follows a live position from a Garmin GPS (`gps55.c`, `gps100.c`) | Shipped `lib/roads`, 30 files, 6.4 MB | Gone after 2E |
| `games/swar` | Two-player Spacewar ("MCI" vs "SPRINT"; "AT&T scores whenever either ship shoots itself") | 8 files | Gone |
| `games/plumb` | Pipe-laying game ("keep ahead of the advancing oil") with levels and a piece editor `pced` | 9 files | Gone |
| `games/smiley` | "A game of historical importance" | Own font | Gone |
| `games/mandel` | Mandelbrot explorer | | Gone |
| `games/fireworks`, `games/clock`, `games/quiz` (1E) | | | Gone |
| `games/juggle`, `games/festoon`, `games/catclock`, `4s`/`5s`, `life`, `ana` | | | Still in 4E |

The 1E games mkfile also lists `gnuchess` and `zork`. `zork` is the DECUS
*dungeon* C conversion and gnuchess is GNU software, so neither is an
original Bell Labs program.

### Commands and environments

| Program | Edition | What it is |
|---------|---------|------------|
| `help` | 1E | "Experimental window system": Pike's text/command environment, the direct ancestor of Acme |
| `8½` | 1E–2E | The window system before rio |
| `movie` (`anim`, `fdevelop`) | 1E | "Algorithm animation": the Bentley–Kernighan movie system |
| `art`, `art2pic` | 1E–2E | Interactive precise line-art editor that emits `pic`. A 2E port is in `sources/extra/art` |
| `chdb` | 1E–2E | Ken Thompson's chess database browser, with `lib/chess` (a 1.2 MB game history) |
| `tiger` | 1E | US street-map database viewer; became `road` |
| `psi` | 1E | PostScript interpreter (Kartus, Scussel, Cherry; 1988) |
| `pm` / `mpm` | 1E | Kernighan's page-makeup postprocessor and macros (also `sources/extra/mpm`) |
| `seemail`, `mugs` | 1E | `seemail`: the mail-arrival faces display (before `faces`). `mugs`: makes 48×48 face icons from photos |
| `kana` | 1E | Japanese / Cyrillic / Greek input method (became `ktrans`) |
| `char`, `½char`, `rschar` | 2E | Unicode Standard browser |
| `mothra` | 2E | The 2E web browser (2E port in `sources/extra/mothra`) |
| `fone`, `telco`, `fax` | 2E | Control of an AT&T 7506 ISDN phone; a modem/telephone file server; fax |
| `twig` | 1E–2E | Tree-manipulation language (code-generator generator) |
| `sysmon` | 1E | System-activity graphs (later `stats`) |
| `vncviewer`, `wrap`, `bitsy` | 3E | Replaced by `vnc`, gone, and the iPAQ port (`sources/extra/bitsy.tgz`) |

Man pages with no source in any release: `weather(7)` (weather maps,
photos, reports), `oed(7)` (Oxford English Dictionary), `ahd(7)` (American
Heritage Dictionary). They needed Bell Labs' internal data. The 2E
`juke(7)` is a CD-ROM jukebox: each disc in a hardware changer appeared as
a directory under `/n/juke`. It is not a music player.

### The music jukebox (4E: `sys/src/games/music`)

This is the "jukebox player" you remembered. Sape Mullender wrote it and
it shipped in Plan 9 4E. It was never part of Inferno. It is three 9P
pieces:

- `playlistfs`: a play-list file server that runs the player and controls volume
- `jukefs`: a browse server over a catalogue of artists, albums and tracks
- `jukebox`: the GUI (play/pause/next/prev icons)
- `juke.rc`, which starts all three

About 137 KB of C. Its decoder `games/mp3dec` is libmad (GPL v2), and
`mp3enc` is a LAME derivative. Neither is a Bell Labs original, and both
conflict with this tree's GPL clean-up (`GPL-LICENSE-AUDIT.md`). The
jukebox itself is a 9P design that fits InferNode well, but a port would
need a decoder that isn't under the GPL.

## Inferno®

### Gone before 4E

| Program | Edition | What it is |
|---------|---------|------------|
| **Mux suite** `appl/mux/` (1E, revived in 3E) | 1E0 (`appl/work/mux`), 1E1, 3E | The original set-top-box / TV interface, built on Prefab. `mux` (selector), `tv`, `tvlist` (listings), `movie` (a movie database by genre, with `movies/` data whose synopses are machine-generated nonsense), `pizza` (order a pizza, `/services/pizza`), `news`, `readnews`, `fnn` (financial news), `comics`, `email`, `popmail`, `register`, `web`, `games`, `connect4`, `othello`, `gamed`, `audioctl`, `rec-pb` (audio record/playback), `rmux` (remote mux). The `services/` data ships with it. It needs `libprefab`, which this tree dropped |
| **Guido** `wm/guido.b` | 1E1 | The first Inferno web browser, before Charon (3,100 lines, HTML 3.2). Named after Guido Guerra, Canto XVI |
| **DSP demo** `wm/dsp/` | 1E0, 1E1 | "Distributed Sports Program": a distributed demo with a slideshow about Inferno, data spread across machines A/B/C (`demo/dsp/db*`) |
| `work/cmd/irtest` | 1E0 | Infrared remote-control test (the set-top box's remote) |
| `wm/scribe` | 2E | Handwriting recognition with the Papyrus recogniser (stroke input) |
| `mailtool` | 2E | Tk POP3/SMTP mail client. **Restrictive per-file notice; leave it out** |
| `svc/telcofs`, `cmd/fone`, `cmd/phone` | 2E | Telephone file server and ISDN phone control (the Inferno counterpart of Plan 9's `fone`/`telco`). `phone` tested the Sword/UMEC drivers |
| `wm/mwm`, `wm/msh` | 2E | Minimal window manager and minimal shell window (by "obc") |
| `wm/wmcp`, `wm/shortcut`, `wm/winctl` | 1E–3E | Customised wm variants for devices (`wmcp`: no toolbar, an event timer) |
| `games/` (`gamesrv`, `gameclient`, engines) | 3E | The predecessor of Spree. A Styx game server with engines for afghan, canfield, freecell, hearts, liars, othello, racing demon, snap, spider, spit, whist, bounce and chat |
| `tiny/` (`sh`, `rm`, `kill`, `broke`) | 3E–4E | Minimal commands for small devices |
| `wm/ipaqlogon` | 3E | iPAQ login |
| `ftpfs`, `wm/wmftp` | 1E–2E | FTP as a file system, with a Tk front end |

### In 4E, not in InferNode

`DIFFERENCES-FROM-STANDARD-INFERNO.md` lists the directories that were
removed. These are the programs inside them, plus the `wm`/`cmd` ones
removed one at a time:

- **Audio and video**: `wm/wmplay` (a Tk front end to `/dev/audio`;
  `cmd/auplay` and `devaudio` are still here), `wm/avi` (RIFF/AVI),
  `wm/qt` (QuickTime), and 4E's `wm/mpeg` (this tree's `appl/mpeg`
  replaces it). Inferno never had an MP3 player. Its audio was raw/`.iaf`
  through `auplay`, `wav2iaf` and `raw2iaf`.
- **Collaboration**: `wm/drawmux` (multiplexes a `draw` session to several
  viewers: shared screens), `collab/` (collaborative files and services),
  `demo/whiteboard`, `demo/chat`, `spree/` (distributed sessions and card
  games; `RECOMMENDED-ADDITIONS.md` calls it "spreadsheet tools", which is
  wrong).
- **Devices**: `cmd/lego` (Lego Mindstorms RCX: firmware download, link,
  clock), `cmd/palm` (Palm Desk Link, `palmsrv`), `cmd/avr/burn`,
  `cmd/mpc` (PowerPC flash), `demo/camera` (a digital camera over serial,
  2,557 lines), `cmd/rdp`, `cmd/touchcal`, `wm/pen`, `wm/keyboard`.
- **Documents**: `ebook/` (Open eBook reader, CSS, OEB packages),
  `wm/brutus` (SGML screen editor) with `cmd/cook`.
- **Programming**: `alphabet/` (typed shell pipelines, with grid
  operators), `wm/mash`, `cmd/tclsh` and `wm/wish` (Tcl), `demo/odbc`,
  `demo/cpupool`, `demo/ns`.
- **Small wm programs**: `mand`, `polyhedra`, `collide` (physics, via
  c2l), `sweeper`, `snake`, `reversi`, `c4`, `calendar`, `stopwatch`,
  `unibrowse` (Unicode browser, by rog), `vt`, `telnet`, `rmtdir`,
  `readmail`/`sendmail`, `toolbar`, `smenu`, `cprof`/`mprof`/`prof`.
- **Minitel** (`examples/minitel`): removed on purpose. See
  `GPL-LICENSE-AUDIT.md`.

## Candidates, by fit

1. **`road` + `gps`** (Plan 9 2E). A live GPS moving map over vector
   data, written in the Plan 9 way: the position is read from a file.
   Done in Limbo, it would be a map that reads its position from a file
   that a GPS, an agent or a network feed writes. The TIGER data is old;
   the program design is the part worth keeping.
2. **The 4E music jukebox**. Already split into 9P servers
   (`playlistfs`, `jukefs`) with a thin GUI, so it maps onto `/mnt/juke`
   directly. It needs a decoder that isn't GPL.
3. **`fsim`**. Self-contained. Its instruments and navaid code are
   written out in plain C, which makes a Limbo port straightforward.
4. **Mux + Guido + DSP** (Inferno 1E). The set-top-box software that
   Inferno was originally built for. It is worth keeping as working
   history, but needs Prefab brought back or replaced by Tk.
5. **`drawmux`, `collab`, Spree** (Inferno 4E). Shared-screen and
   shared-session programs. These are the dropped programs that come
   closest to what Lucifer and Veltro do today.
6. **`help`, `movie`, `art`, `chdb`, `swar`, `plumb`, `mandel`**. Small
   and historically interesting. `help` is Acme's ancestor and sits next
   to Xenith.
7. **`wmplay`**. Trivial: a Tk front end to the `auplay` already here.

## Reproducing

```sh
git clone https://github.com/plan9foundation/plan9
cd plan9
for t in 1e-1993-01-03 2e-1995-04-05 3e-2001-03-28; do git fetch --depth 1 origin tag $t; done
git ls-tree --name-only 2e-1995-04-05:sys/src/games
git show 2e-1995-04-05:sys/man/1/games

for r in inferno-1e0 inferno-1e1 inferno-2e inferno-3e inferno-os; do
	git clone --depth 1 https://github.com/inferno-os/$r
done
# list every appl/**/*.b per tree, then comm(1) against this tree's appl/
```

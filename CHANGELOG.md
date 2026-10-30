# Changelog

All notable changes to InferNode are documented in this file.

## [Unreleased]

### Applications

- **The old icons are gone; every program draws `icon(2)`'s glyphs.**
  wm/deb's controls, its Stack window's open and closed marks,
  wm/bounce's arrows and dialog(2)'s error, warning, information and
  question icons are Tabler glyphs in the theme's colours, repainted on
  a theme switch; webget's help page shows them too. The 135 old icon
  files left are removed, so `icons/` holds `icons/ui`, Tk's two
  cursors, and the artwork that is not an icon: wm/coffee's cups and
  backdrop and the picture `draw-example(2)` draws, all kept as they
  were. A glyph that cannot be drawn leaves a blank button, not a
  program that fails to start: `icon(2)` makes every Tk image it is
  asked for whatever happens to the glyph, and
  `tests/host/icons_test.sh` (run in CI) fails if anything names an
  icon that is not in the tree. Making an image no longer leaves an
  error in Tk's `lasterror`, which dialog(2) read as a failure and
  answered its own question with the default ("discard").
- **`wm/dir` is back, on new icons.** Inferno's file browser, the Files
  entry of upstream's window menu, was dropped in the migration. It is
  restored with its icons drawn by `icon(2)` in the theme's colours.
  A folder opens in the same window (a window each is an option), and
  a file opens through the plumber, so in Lucifer it lands in the
  presentation view; with no plumber, a program runs, an image opens
  in `wm/view`, a PDF in `wm/page` and anything else in `wm/edit`.
  Fixed on the way: `..` was the working directory's parent, not the
  folder's; resizing the window indexed an empty string; a name with a
  blank broke its label; long names made one column; a folder that
  could not be read closed the window. `tests/host/wm_dir_test.sh`
  drives it.
- **Icons: Tabler's glyphs, drawn at any size in any colour.**
  `icons/ui` holds the 45 glyphs the interface uses, from Tabler Icons
  (MIT), 22.6KB of SVG; `icons/ui/LIST` names them and
  `tools/update-icons.sh` fetches any added. `icon(2)` draws one with
  readsvg at the size asked for and paints it in a theme's colour, so
  a glyph is sharp on any display and a theme switch repaints it.
- **Double-click works in Tk applications on SDL hosts.** Tk took a
  double click only from a press the X11 driver marked as one; SDL and
  `/dev/pointer` send two plain presses, so no `<Double-Button-1>`
  binding ever fired on macOS, Windows or Linux with SDL (wm/dir
  opened nothing, ftree's double-click did nothing, a text widget
  never selected a word). Tk now times presses itself as X11 does:
  the same button again within 300ms and 12 pixels.
- **`wm/edit` is back.** Inferno's own editor was dropped in the
  migration and its name later given to the editor now called
  `wm/editor`, so `wm/task`'s Files button, which loads
  `/dis/wm/edit.dis`, did nothing. It is restored from upstream with
  its bugs fixed: it opened at 384x188 with a white text area under the
  theme's light text, it took the arrow and page keys for changes (so
  reading a file asked to discard it), a name that did not exist was an
  error rather than a new file, and an empty Save As name was tried as a
  file. It follows a theme switch, Limbo mode's colours among it.
  `tests/host/wm_edit_test.sh` drives it. `man/1/edit` described
  `wm/editor`; that page is now `editor(1)`, and `edit(1)` is
  `wm/edit`'s.

## [0.9.0] - 2026-10-29

This release adds SD-card images for the Raspberry Pi 3B+ and 4B, which
boot the native kernel to its login screen. Packages no longer ship the
tree's test key: anyone who authenticated with the default key should
make their own (see Security). Lucifer shows every window an app opens,
dialogs and secondary windows among them. Xenith keeps unsaved work in a
rescue file when it hits an internal error, and a fuzzer found and fixed
its races and lost edits. The Veltro harness gets whole replies,
thinking, retries and working child agents, and llmsrv compacts a
session before it outgrows its model's window. mail9p speaks STARTTLS
for IMAP and SMTP and never sends a password in clear.

### Security

- **No package ships the tree's test key.** Every release package
  carried `usr/inferno/keyring/default`, an ed25519 private key for
  `testnode` committed to this public repository, and `listen`,
  `styxlisten`, `mount`, `dial`, `cpu` and `rcmd` use it when no key is
  named. Every install from a release therefore held the same private
  key. `tools/release-scrub.sh` now empties each `usr/*/keyring/` in a
  package and refuses the package if an Inferno key file or a PEM
  private key is left anywhere in it; every package job runs it, and
  `tests/host/release_scrub_test.sh` fails if one does not. **If you
  authenticated with the default key from an earlier release, make a
  key of your own (`auth/createsignerkey`, `getauthinfo`) and stop
  trusting `testnode`.**

### Packages

- **Raspberry Pi 3B+ and 4B card images.** Each release has
  `infernode-<version>-rpi3bplus.img.xz` and
  `infernode-<version>-rpi4b.img.xz` (about 22 MB), written whole with
  Raspberry Pi Imager ("Use custom"), `dd` or Etcher. A card boots the
  native kernel to the first-boot login screen and offers nothing on the
  network until its `wifi` or `bt` file says so; its `README.txt` says
  how. The boot firmware and the Bluetooth patch are pinned by commit and
  SHA-256. The radio's Wi-Fi firmware and Bluetooth patch ship on these
  images only, beside `LICENCE.cypress`, whose grant covers use with
  Cypress chips and so not the PC packages. `tests/host/piimage_test.sh`
  reads the images back and checks their files; the release job checks
  each against the boot ROM's rules (`tools/piromcheck.py`) and boots it
  under QEMU, through the first login (`tests/host/piimage_boot_test.sh`).
  Both boards have booted the images; the 4B has joined Wi-Fi, brought
  up Bluetooth and made its first login from one. Not yet tried on a
  board: the 3B+'s Wi-Fi, Bluetooth and first login, and a card written
  by Imager or Etcher rather than `dd`.
- **First-boot login makes the whole home path.** `wm/logon` made
  `secstore/` but not `/usr/inferno` above it, so on a card with an
  empty `usr/` the new password was refused.
- **macOS stapling is retried.** `xcrun stapler` sometimes lost its
  connection to Apple fetching the notarization ticket (NSURLErrorDomain
  -1005) after notarization had succeeded, failing the job; it is now
  tried five times.

### Emulator

- **The idle collector rests on a static heap, now also when something
  wakes now and then.** 0.8.1's fix counted the collector's passes round
  the heap afresh in each idle moment, and a moment ends as soon as
  anything is runnable. Headless Charon has a proc that wakes and does
  nothing, so no moment was long enough and the collector never
  stopped: a whole core, again. Passes are now counted from the heap's
  last change. `idle_cpu_test.sh` failed 3 of 3 before, passes after.
- **`s += s` no longer overflows its block.** Appending a string to
  itself in place set the new length before copying the right operand,
  which was by then the new length too, so twice the bytes were copied,
  past the block, under the interpreter and the JIT alike. It corrupted
  the heap in CI. `tests/strcat_test.b`.
- **An image far from 0 in its coordinates is made.** memdraw's byte
  offset to pixel (0,0) was an `int`; for an image whose top is past
  about row 160000 at 3400 pixels wide it wrapped and allocation
  faulted. A strip far down a long Markdown document is such an image.
  `tests/memdraw_far_test.b`.

### Window manager

- **The pointer is warped on SDL's main thread.** A move written to
  `/dev/pointer` (wmlib's `ptr` request) warped the host's pointer from
  the thread that wrote it, though SDL allows a warp only on its main
  thread, and read the window's geometry, which the main thread changes
  on a resize; the main loop now does both, as it does the cursor. And
  `m x y` followed by a newline, as a shell's `echo` writes it, is a
  move, not a press of no buttons. `tests/host/wm_cursor_test.sh`
  checks the warp is made on the main thread.
- **New's cross shows.** emu changed the pointer's cursor through SDL on
  the thread that wrote `/dev/cursor`, though SDL allows cursor calls
  only on its main thread. On macOS the main thread rebuilds the
  window's cursor from SDL's state, and a change made under it from
  another thread could be lost: wm/wm's menu closed on New and the
  arrow stayed. Its gunsight and box could go the same way. The main
  loop now makes the change.
  `tests/host/wm_cursor_test.sh` checks each cursor wm/wm sets is made
  SDL's, on the main thread.
- **A sweep just begun draws no warning.** Its first rectangle is
  narrower than two borders, and wm/wm asked for a window of negative
  size for the edges between, which the image pool refused on standard
  error at the start of every sweep.
- **Every wm program opens at a size that shows it.** Under wm/wm,
  wm/tetris opened as an 8x8 square of frame in the corner, wm/coffee
  and wm/memory filled the screen with their content in a corner of it,
  and a wm/wm run as a client was a 108x108 empty square. The first
  three were made for Lucifer's presentation zone in July: tetris pinned
  its window before its board was made, coffee and memory asked for the
  whole display. They now ask for what they show and keep the size the
  window manager gives, the zone's in Lucifer, as before. A nested
  wm/wm asks for 640x480. `tests/host/wm_size_test.sh` opens every
  program in `dis/wm` on a 2560x1600 screen and fails one that opens as
  its frame alone or as the whole screen; `tests/host/wm_theme_test.sh`
  fails one that opens as little more than its frame (it passed tetris,
  finding no pixels inside to check).
- **A theme switch reaches a canvas's items.** An item given a colour of
  its own (a rectangle's `-fill`) kept the old theme's other colours: in
  wm/memory the bars' outlines stayed the old theme's grey. Seen once
  memory's window was no longer the whole screen, where they were too
  few to count.
- **One way to drive the GUI: `/dev/pointer` and `/dev/keyboard`.**
  wm/wm had a test driver of its own, `/chan/uitest`, beside emu's
  devices, which already drove Lucifer and every app in it. Each write
  to `/dev/pointer` is now delivered as an event of its own, motion
  included, so a drag written press, move, release is not merged into a
  click, and it no longer moves the host's pointer: the host answered
  with a motion carrying its own buttons, none, which let go of a
  button a test held. `/chan/uitest` is gone; what it listed, wm/wm's
  windows, is `/chan/wmwindows`. `tests/host/uitest_transport_test.sh`,
  skipped since it was written for want of a way to reach an app hosted
  in wm/wm, now runs and passes (where ffmpeg and vdec are built).
- **wm/lens fills Lucifer's zone.** It drew a 300x300 image in the
  zone's top-left corner, sized when it started rather than by the
  window it was given, and the rest of the zone kept the old theme's
  background after a switch.
- **`tests/host/lucifer_app_test.sh`** opens every program in `dis/wm`
  in Lucifer's zone and checks that it keeps running, draws, fills the
  zone or centres in it, follows a theme switch, and (editor, shell)
  takes typing.
- **Lucifer shows every window an app opens.** Only an app's first
  window was shown in the presentation zone; a dialog or a second
  toplevel was dropped, and wm/deb, whose Stack window registers second,
  hung at start. The zone now divides the app's tab among its windows,
  newest on top, with a divider between; a click gives the window under
  it the keyboard.
- **The tab strip shows over an app on every boot.** lucipres, which
  draws it, and presrender could join the zone in either order, and the
  first was taken for lucipres; on about one boot in three the strip
  stayed blank under the app. They are now told apart by their
  registration tokens. `tests/host/presentation_tabstrip_test.sh`
  boots Lucifer six times and checks the strip each time.
- **The file selector follows the theme.** Every app's Open dialog had
  its path entry, column frames and titles in fixed colours that a theme
  switch kept.
- **wm/colors and wm/view open in Lucifer.** Lucifer took them for
  ended a moment after they opened, and the zone said "No content".
  They return from `init` and run on in a spawned process, which made a
  process group of its own; Lucifer watches the group it gave `init`,
  and saw it empty. The group is now made in `init`, before the spawn:
  in Lucifer, where `init` leads its group already, that changes
  nothing, and under wm/wm colors' Delete still spares wm/wm.
- **The wm/wm tests run in CI.** `tests/host/wm_test.sh`, written with
  the last fix to New to keep it from breaking again, was not run by any
  workflow; nor were `wm_theme_test.sh`, `wm_ghost_test.sh` and
  `page_test.sh`. The Linux GUI job runs them all now.

### Xenith

- **Unsaved work is kept when Xenith goes wrong.** An internal error in
  the mouse, keyboard or wait task, in a 9P request or in an Edit is now
  recovered from rather than ending Xenith. After one, and on any exit
  nobody asked for, every window (unnamed ones and typing not yet
  committed included) is written to `$home/xenith.rescue` in Dump's
  format; `+Errors` says where, and `Load` brings the windows back.
  Dump's own `xenith.dump` is no longer overwritten, and a Zerox of a
  window a client held no longer cost the dump every window after it in
  its column. `tests/host/xenith_rescue_test.sh`; `docs/XENITH.md` has a
  section on the file.
- **Races and lost edits, found by a fuzzer.** `tools/xenith-fuzz` drives
  a headless Xenith (standalone or in Lucifer) with random clicks, drags,
  chords, typing and a client writing through `/mnt/xenith` at once, then
  checks it answers, that Put writes what a window holds and that undo
  and redo restore its text. Fixed from what it and the race tests found:
  - a B3 in a scroll bar went on scrolling after it was let go;
  - a client's `get` lost typing in the body; a B3 in the tag lost it;
  - a search begun at the end of the file did not come round;
  - Put of a file still loading wrote only what had loaded, and an edit
    or an Edit (`$a`) made while it loaded went in the wrong place;
  - an Edit pipe (`,|cmd`, `X ,|sort`) overwrote text changed while its
    command ran, losing both; it now refuses that window and keeps the
    text;
  - a background Put marked a window saved though a change arrived
    during the write;
  - Redo after a client's change with `nomark` set put undone text back
    where the text no longer was; an undo record that no longer matched
    the text is now dropped with a warning, not half applied;
  - text reaching a window hidden under one grown to fill its column,
    `Put x` in an unnamed window, and a command that could not start all
    ended Xenith;
  - locks held after an exception, a window freed under a 9P request,
    and documents opened twice from two procs.

  `tests/host/xenith_race_test.sh` has a check for each.
- **Typing goes into a live document's text once.** With a source shown
  `Live` beside its text, a refresh committed each window's copy of the
  pending typing, so it went in twice.
- **Cmd-V pastes into a page's form field.** A page browsed in Xenith
  dropped ^V in a field, so a password or a search could not be pasted.
- **The standalone Xenith runs the user's start-up file.**
  `lib/xen/boot.sh` runs `/usr/<user>/lib/xen/profile` (or
  `/usr/inferno/lib/xen/profile`) before Xenith, in the shell that runs
  it, so what it binds (a package such as troff, its own `doctypes`) is
  in Xenith's name space. `docs/XEN.md`, "Your start-up file".
- **Markdown is laid out once and drawn a strip at a time.** Each
  Markdown document was drawn whole into one image as tall as itself,
  70 MB and more at 2x, and with `Live` a second while the first was
  shown, until a refresh failed with `allocimage`. Image memory for
  `AGENTS.md` live at 2x fell from a 224 MB peak to 51 MB.

### Documents

- **A source set in pages is fitted, not set to the width.** The
  document view held every source document at scale 100 and set it to
  the view's width, as Markdown and HTML are. A troff document, set in
  pages and painted sharp at any scale, opened at half size on a Retina
  screen. A source whose engine paints at any scale is now paged, fitted
  and zoomed as a PDF is.

### Charon and the browser engine

- **An image a page's script puts in is fetched.** Images were sent for
  once, as the page loaded; one a script added later showed its alt
  text (JSTOR's logo). `tests/host/charon_scriptimg_test.sh`.
- **A shadow tree's top element is not the root, and a scrolling grid
  item has no automatic minimum.** JSTOR's home page had its heading,
  search and hero in a 144-pixel column, then was laid out 35000 pixels
  wide. `tests/host/charon_shadowgrid_test.sh`.
- **Box lookups and mutation observers cost less on heavy pages.** Boxes
  are indexed by node once per layout, and observers found by target:
  about 7% of the busy time on JSTOR's search results.
- `tests/host/charon_notpage_test.sh` expects a link to audio to be
  saved, as it has been since 0.8.1, and runs in CI.
- docs/CHARON-ENGINE.md: a roadmap for Charon across more than one Dis
  VM.

### Mail

- **mail9p connects with STARTTLS.** `connect name server starttls`
  was refused by the IMAP library as not yet implemented. It connects
  in clear on port 143, reads the greeting, sends STARTTLS and on its
  OK speaks TLS on the same connection; a server declining it is
  refused rather than logged in to in clear. A server may be given as
  `host!port`, for a local bridge's port; the factotum key and the
  certificate are the host's. `tests/host/mail9p_imap_test.sh` drives
  both against a fake IMAP server.
- **mail9p is tested against an IMAP server.** Past `connect`, nothing
  of it was: `tests/host/mail9p_imap_test.sh` runs a session against a
  fake server over verified TLS (an account's boxes, messages, flags,
  search and archive, over TLS and over STARTTLS, and a message sent
  through a fake SMTP server each way), and checks a server
  is refused when its certificate names another host or comes from a CA
  not trusted. The test's CA is its only root, bound over `/lib/certs`.
- **TLS matches an IP address against the certificate's IP addresses.**
  A server reached by address (`127.0.0.1`, a bridge on the LAN) was
  matched only against the certificate's DNS names, so a certificate
  naming the address in an `iPAddress` subjectAltName, as RFC 6125
  has it, was refused. An address is now matched against those alone,
  a name against DNS names and the CN.
- **mail9p sends over STARTTLS, and never in clear.** Sending used
  plain port 25 unless the account used implicit TLS for IMAP, and
  authenticated there with `AUTH PLAIN`: a STARTTLS account would have
  sent the password in clear. smtp(2)'s `authopen` now takes
  `IMPLICIT_TLS` (465) or `STARTTLS` (587, RFC 3207, refused if not
  offered or refused by the server) and refuses `PLAIN`; mail9p sends
  as the account's IMAP mode has it. `smtp=` may be `host!port`. A
  reply's continuation lines (EHLO's) are no longer taken for replies.
- **No "Broken: write on closed pipe" after a TLS connection.** When
  the caller closed its end while the server still sent (an SMTP
  server's `221` after `QUIT`), webclient's TLS reader died on the write
  and the system printed it.

### Veltro and the agent loop

- **serve-llm starts with no model configured.** When
  `~/.infernode/lib/ndb/llm` named no `model=` (or did not exist),
  `serve-profile` passed llmsrv `-M` with nothing after it: the next
  option became the model (`-r`), or llmsrv refused to start and
  `/mnt/llm` was exported empty. `tests/host/serve_llm_smoke_test.sh`
  now mounts `/mnt/llm` with the key and reads a session's model.
- **Whole replies.** llmsrv capped every session's output at 1024
  tokens and reported a reply cut off by it as `end_turn`. The cap is
  now the backend's, and a cut-off reply is `STOP:max_tokens`; the loop
  continues cut-off text and sends cut-off tool calls again rather than
  running them.
- **Current Claude models, thinking and streaming.** The aliases name
  the 5.5 models (default `claude-sonnet-5-5`), each request carries
  what its model accepts, thinking blocks are kept and sent back with
  their signatures, and the Anthropic path streams. Not yet run against
  the API itself, only against recorded requests and responses.
- **Retries.** A request refused before any of its answer was shown
  (429, 5xx, 529, a backend not yet listening) is retried with backoff,
  honouring `Retry-After`. llmclient waits up to 5 minutes for a first
  byte, so a request queued on a one-at-a-time server is not lost.
- **Compaction before a session outgrows its model's window.** llmsrv
  compacted at a fixed 150,000 tokens, past gpt-oss's 65,536 on SGLang
  and Ollama's default 4096. Each model's window is now learned from its
  backend (vLLM, SGLang, Ollama, Anthropic), is a file
  (`/mnt/llm/<id>/window`, or `window=` in `/lib/ndb/llm`), and is
  learned again from a "context too long" refusal, after which llmsrv
  compacts and asks once more. A turn of many tool results is compacted
  in its middle, the step under way kept whole.
  `tests/host/context_window_test.sh`.
- **Child agents work.** No spawned child ever had a model: tools9p kept
  `/mnt/llm` out of spawn's name space. Children now get it, and native
  tool definitions.
- **Steering and a stable prompt.** Input typed during a turn is
  delivered with the next tool results. The system prompt is sent once
  (later changes ride on the next message), and only `exec` and
  `spawn` docs are inlined, about 49 KB less with every tool on.
  `veltro -r` restores the exact history.
- **Tools.** `edit` takes several changes per call and matches past the
  read tool's line numbers, trailing blanks and curly quotes; `read`
  gives 2000 lines or 30 KB and the next offset; `exec`'s timeout is 30
  s (settable to 120), and long output keeps its start and end; read-only
  calls in a batch run concurrently. The `limbo` tool may edit and
  compile the agent's own Limbo and closes its model session after each
  call (they had piled up to llmsrv's limit). Tools that call a model
  get the model's time limit, not 60 s. `task` refuses a brief naming a
  folder the task would not see, saying which `paths=` to add.

### Bare metal

- **NaN and infinity on the 64-bit kernels.** libkernfp took a double
  apart assuming a 32-bit `long`, so `isNaN` never saw a NaN and `Inf()`
  was 0.0; the Limbo compiler died on a board with "bad canonical NaN".
  `strtod` now also reads `Inf`, as reals are printed. `tests/nan_test.b`.
- **A Pi 3B+'s Bluetooth controller gets the board's own address.**
  Every 3B+ reported the patch's default `43:45:c0:00:1f:ac`.
  `btboardaddr(1)` gives it the address Raspberry Pi OS does, from the
  board's serial, unless the card's `bt` file names a `bdaddr`.
- **`/dev/gpio` lists its pins by name.** The generator formatted each
  name on its own stack, gone by the time the listing used it, so every
  pin listed as nothing.
- **bt9p: a listen open on a queued call is not refused.** The `listen`
  file was mode `444`; when a call arrived before the listener, the
  read-write open was refused and `listen(1)` exited, and every later
  call to that PSM was turned away. Under load, 3 L2CAP connections in
  20 s instead of about 350.
- `baremetal_test.sh` keeps the bcm2837 shell transcripts and finds a
  command's reply after its echo, past console lines that interleave.

## [0.8.1] - 2026-10-22

This release fixes what 0.8.0 shipped broken. Charon opened on a test
fixture that no package carried. Packages left out `man`, `doc`,
`icons`, `appl` and `n`. An idle emulator with a page loaded kept a
whole core busy. Every package now runs its own Charon before it is
uploaded. Charon can now complete an institutional sign-in through
Microsoft and download what it cannot show. Xenith no longer exits
when typing beside a Zerox, and its new `Live` command keeps a
document's preview current as you type. On the bare-metal kernel,
USB disks, serial adapters, Ethernet adapters, touchscreens and
non-boot keyboards work on real hardware.

### Security

- **A CNSA-mode mismatch says which side is in CNSA mode.** A node
  with `CNSAMODE` set and one without failed authentication with only
  "bad ml-kem public key length"; each side now says whether it or its
  peer uses ML-KEM-1024, and to set `CNSAMODE` alike. On macOS the
  Dock and a terminal can start an emulator with different
  environments, so one machine could reach a CNSA server one way and
  not the other. `tests/cnsa_nodepair_test.sh` covers both mixes.
- **Charon's page files no longer show a password.** `forms` and a
  password input's `dom/N/attrs` showed the value as typed, so anything
  given the window's files, an agent among them, could read it. They
  now show `********` when the field holds anything; the page, its
  scripts and the submitted form still have the real value
  (`tests/host/charon_password_test.sh`).

### Packages

- **Charon opens on a start page that ships.** Its home was
  `tests/charon/pages/article.html`, and no package carries `tests/`,
  so every released Charon since 0.6.0 opened on "file does not
  exist". `lib/charon/start.html` has a search box, places that render
  in Charon, and the keys. `tests/host/charon_home_test.sh` checks the
  home is under a directory every release job stages.
- **Each package is tested before it ships.**
  `tests/host/release_smoke_test.sh` runs a staged package's own
  emulator on its own tree: headless Charon must show its start page
  and a forty-section page whole; GUI packages also open the page in
  Xenith and in Lucifer's presentation view. A failure stops the
  upload.
- **`man`, `doc`, `icons`, `appl` and `n` are shipped.** `man` found
  no pages, Tk programs could not load their icons, and the debugger
  had no source. Without `n`, a fresh install's first start made the
  user's home inside the package. `appl` ships without its `.dis`.
- **The app icons sit on the macOS grid.** InferNode's and Xenith's
  icons are rounded squares with a margin and shadow, not full-bleed
  squares. On Linux the running window is the pinned dock entry, not
  a second generic icon, and Xenith's window is titled Xenith. The
  Brimstone logo in Lucifer's header is on a clear ground.

### Emulator

- **An idle emulator no longer burns a core.** With a web page loaded,
  the idle collector went round the heap again and again, freeing
  nothing: 99% of a core for as long as the emulator sat idle. It now
  rests until the heap has changed.

### Charon and the browser engine

- **A page left is let go.** Layout kept the boxes and words of the
  last documents after the page was left: 190 MB stayed after leaving
  a 4,000-paragraph page for `about:blank`; now 6 MB.
- **Microsoft and SAML sign-in.** Pages are told CSS does not animate,
  since it does not, so a page waiting for `animationend` takes its
  static path. A form a script submits by POST is posted. A POST body
  longer than one 9P message is sent whole (webfs kept only the last
  piece). Together these take a JSTOR sign-in through Microsoft and
  OpenAthens to the end.
- **Forms hold the controls HTML puts in them.** Controls are numbered
  in document order, including shadow trees; removed controls and a
  `<template>`'s content are left out; a control's `form` attribute is
  honoured; entries are sent in tree order.
- **Web components.** A button's label in `forms` and `dom/N/text` is
  the one shown through its `<slot>`. A label's `for` names a control
  in its own tree, so one component's label no longer ticks another's
  box.
- **Binary bodies.** `arrayBuffer()`, `bytes()`, `blob()` and XHR's
  `arraybuffer` give a response's bytes as they came, not decoded as
  UTF-8; binary request bodies go as their bytes.
- **Downloads.** A page navigated to that Charon cannot show, such as
  a PDF, is fetched whole, saved in `$home/Downloads` under its
  Content-Disposition name, and plumbed, so Xenith or Lucifer opens
  it. charon(1) has a Downloads section.

### Xenith

- **Typing beside a Zerox no longer kills the editor.** The arrow
  keys, Home, End and the control keys committed only the typing
  window's copy of the typing, and the next key tripped a fatal check
  that left a frozen window. They commit through every window, as
  Plan 9 acme does. A copy out of step anyway is recovered and
  reported in Errors. A fatal error now closes the window, and a dump
  with a Zerox loads back.
- **`Live`** turns a document's live preview on and off. A live
  Markdown, HTML or troff document is set again 600 ms after typing
  stops, unsaved edits included, keeping its place and zoom. `Live`
  in the text's tag opens the document beside it if none is shown.
- **Every click reaches the page.** A click on anything but a link or
  a form control was dropped, so script-driven buttons, such as a
  cookie banner's, could not be pressed.
- **A page's viewport is the window's height**, not 600 pixels, so a
  dialog sized to it is no longer cut off.

### Veltro and the agent loop

- **The Limbo compile gate runs**, and `limbo compile <file.b>`
  checks any file.
- **Edits to user folders are staged**, reported as staged, applied
  with `task promote` after approval and discarded with `task revert`.
  Staged changes are offered back after a restart, never applied over
  newer edits.
- **Closing a task mid-turn no longer takes down the UI**, and closing
  one stops its agent, tool server and model session.
- **A failing model service is said so**, shown as "Model unavailable"
  rather than as the agent's reply, and its task is marked failed.
  `/stop` stops a running turn; what the user types during a turn is
  shown at once.
- **Compaction waits for the end of a turn.** llmsrv compacted
  history inside a tool exchange, after which the API refused the
  results and the turn died.
- **`write` and `edit` keep native content intact**, and a task's
  status lists the documents it has made.
- **The model is the server's.** Client-side model selection is gone
  (`task model=`, `spawn model=`, `veltro -m`).

### Documents

- **A PDF page whose box is not at 0 0 is painted**, with its words
  and links in place; cropped figures came out blank.
- **`man -t`** writes troff `-man` output for tr2pdf.

### Bare metal

- **USB disks on a real xHCI controller**: SuperSpeed ep0, composite
  devices, one endpoint number both ways, and disks past 2 TB. dossrv
  reads FAT32 partitions and volumes past 2 GB. Every logical unit of
  a card reader is a disk of its own, and cards may come and go.
- **USB serial adapters** (CDC-ACM, FTDI, CP210x) are `eia(3)` ports,
  `/dev/eiaU<n>`. A control request with wValue's top bit set lost its
  wIndex and wLength on every xHCI machine; fixed.
- **USB Ethernet**: CDC ECM and NCM, beside a kernel NIC on spare
  instances `#l2` and `#l3`. A second interface takes its own address
  by DHCP but leaves the default route alone.
- **USB pointers and keyboards from the HID report descriptor**: mice,
  touchscreens and tablets (absolute positions through `/dev/pointer`'s
  new `a` verb), and keyboards without the boot protocol. Device
  quirks are data in `/n/dos/usbquirks`.
- **Wi-Fi**: one DHCP client per interface, renewing its lease; the
  firmware keepalive on every chip. A Pi 4 soak had collected 93 stuck
  DHCP clients and lost its link every 8.4 minutes.
- **The console scrolls by copying** in a screen-sized framebuffer and
  never moves the scanout window, which left the screen 80 px low on a
  1280x800 panel.
- **`#P` on the Pi 3B+** reports the firmware's temperature and
  throttle flags, as on the Pi 4.
- docs/arm64-jit/BENCHMARK-arm64-bcm2711.md: jitbench on a Pi 4B,
  2.6x to 3.7x the 3B+.

### Build

- CI: a merge to master no longer cancels the run of the one before.

## [0.8.0] - 2026-10-15

This release makes TLS post-quantum by default: the hybrid key exchange
documented before was never sent, because its codepoint was wrong. A
node can now be CNSA-strict to its peers and still reach the web. The
Raspberry Pi 4 kernel has run on a board, and does gigabit both ways.
Characters outside the Basic Multilingual Plane, emoji among them, now
survive the trip from bytes to a Limbo string and back. Delegation in
the agent loop works again after its move into veltrosrv, the
LLM-maintained wiki writes pages for the first time, and `dict` reads
the OED as on Plan 9. Three services moved from `/n` to `/mnt`
(wiki9p, speech9p, wallet9p); scripts that name the old paths need
changing. See Name space.

### Security

- **TLS is post-quantum by default.** The client offers the
  X25519MLKEM768 hybrid first, with X25519, P-256 and P-384 for servers
  that do not take it. Cloudflare, Google, Wikipedia, the BBC, OpenAI and
  Anthropic negotiate it; GitHub falls back to X25519. The hybrid was
  documented before but never sent: its constant was 0x4588, the
  decimal codepoint 4588 read as hex, where it is 0x11EC. `tls->client`'s
  `Conn` has a `group` field naming the group negotiated.
- **`CNSAMODE` no longer makes TLS CNSA-strict.** It governs
  authentication between nodes (ML-KEM-1024, ML-DSA-87) as before. TLS
  that offers only SecP384r1MLKEM1024 is now the host `CNSATLS`
  (`/env/cnsatls`). Public servers do not offer that group, so with
  `CNSAMODE=1` every HTTPS site failed with `alert level=2 desc=40`; a
  node can now be CNSA-strict to its peers and reach the web. A
  deployment that wants strict TLS sets `CNSATLS=1` as well.
- **`/tool/meta/nodevs` is a fact, not a declaration.** tools9p reported
  `unset` unless its launcher passed `-N`, and Lucifer's boot does not, so
  `nsaudit -m /tool` on a live session reported a high `DEVICE_GATE_BYPASS`
  that was not there: every tool tools9p runs runs with `NODEVS`, or is
  refused. It now always reports `set`; `-N` is accepted and ignored. The
  profile test starts a live tools9p for each `nsaudit` profile fixture,
  and for three compositions of them, and requires the same report
  (INFR-456).

### Name space

- **wiki9p mounts at `/mnt/wikia`, not `/n/wikia`.** It invents its own
  schema, so it belongs under `/mnt` (docs/NAMESPACE-LAYOUT.md); `/mnt/wiki`
  is wikifs, the store beneath it. The wiki tool is granted `/mnt/wikia`
  and nothing else is; neither name can be granted as a path. A script
  that binds sources into `/n/wikia/raw` now binds them into
  `/mnt/wikia/raw` (INFR-402).
- **speech9p mounts at `/mnt/speech`, not `/n/speech`.** It invents its
  own schema (`say`, `hear`, `voices`, `ctl`), so it belongs under `/mnt`
  (docs/NAMESPACE-LAYOUT.md). The `say` and `hear` tools are granted
  `/mnt/speech` as before, and nothing else is. Scripts that write
  `/n/speech/say` or `/n/speech/ctl` now write `/mnt/speech/say` and
  `/mnt/speech/ctl`; a remote speech host exports and mounts
  `/mnt/speech` (INFR-403).
- **wallet9p mounts at `/mnt/wallet`, not `/n/wallet`.** It invents its
  own schema, so it belongs under `/mnt` (docs/NAMESPACE-LAYOUT.md). The
  wallet tool, payfetch, x402 and wm/wallet follow it. An agent granted
  `/mnt/wallet` sees the same narrowed view as before (accounts, `default`,
  `network`, and in each account only its proposal and read files). The
  trusted controls under both names stay ungrantable. A path beneath
  `/mnt/wallet` grants nothing, and nsconstruct no longer lets a `/mnt`
  path it declined come back as an extra root. Scripts that write
  `/n/wallet/ctl` or read `/n/wallet/<account>/...` now use `/mnt/wallet`
  (INFR-400).
- **The LLM-maintained wiki works.** wiki9p had never written a page:
  - it read llmsrv's hex session names as numbers, so every model request
    failed;
  - a command's result read back empty unless the read happened to come
    after the work, so the agent's `wiki` tool always returned nothing;
  - concurrent commands shared one model session;
  - `status` deadlocked when nothing was bound on `raw`;
  - pages were listed through wikifs's `map`, which is a lookup, not a
    list.

  Now a result is read on the fid that wrote the command, the read waits
  for it, and operations run one at a time. wikifs also listed a new page
  only once the clock had ticked: its forced map reload trusted a qid
  version that a host file system can leave unchanged.
  `tests/host/wiki9p_test.sh` runs the whole loop against a scripted
  model.

### Window manager

- **Closing `wm/colors` no longer takes down `wm/wm`.** Its exit is a
  `killgrp` (wmclient), and it never took a process group of its own, so
  Delete from the menu killed whatever had started it: `wm/wm` itself
  when run from wm's shell, or the shell window it was typed in.
  `tests/host/wm_ghost_test.sh` deletes and then kills a `wm/colors`
  under `wm/wm`: wm stays up, and where the window was is wm's
  background again (INFR-433).

### Text

- **Runes are 21 bits on every hosted platform** (#918). Each hosted
  `lib9.h` declared a 16-bit `Rune` and `lib9/rune.c` decoded at most
  three bytes of UTF-8, so the four bytes of an emoji became error
  runes, and writing the string back produced `C2 80`. `Rune` is now
  `unsigned int` with `UTFmax` 4, as the native kernel already had;
  `sys.m` has `UTFmax` 4, `UTFerror` 16rFFFD and a new `Runemax`.
  `sys->char2byte` encodes runes above U+FFFF, Tk key events carry 21
  bits, the Limbo compiler takes `\UXXXXXXXX`, and `convcs` joins and
  splits UTF-16 surrogate pairs. The amd64 JIT read `s[i]` on a rune
  string as 16 bits; it reads 32, and the 386, arm, thumb and power JITs
  hand `indc` to the interpreter. The Windows emulator converts Win32
  strings as UTF-16, and Android converts SMS text from UTF-16, not
  JNI's modified UTF-8. Xenith's and Acme's temp files hold 4 bytes a
  rune.

### Charon and the browser engine

- **Pages at the display's pixels to the point** (#899). On a Retina
  screen pages came out half size in the standalone Xenith app. The
  engine lays a page out at `$displayscale` when that is 1.1 or more:
  sharp, not a 1x rendering scaled up.
- **A page leaves nothing behind when it goes.** Its web fonts are
  closed with it (#919); before, every face any page had downloaded
  stayed in OutlineFont's table. With scripts on, a realm that quit
  cleanly left its `setTimeout` sleepers and fetches running, and with
  them the realm's heap; its process group is now killed (#920).
- **Back and Fwd return to where the page was left** (#894, #902), in
  Charon and in Xenith, not to its top.
- **A form with no `action` is submitted to its own page** (#914), not
  to `?q=...` opened as a file.
- **A disabled field takes no click** (#895), and a read-only one takes
  no keys. In Xenith, typing into a disabled field opened the Errors
  window under the pointer, which took the rest of the keys.
- **An element's position is its own boxes, not its `::after`'s**
  (#900), in `Session.boxof`, `dom/N/box` and `getBoundingClientRect`.
- **Two ways a page stopped Xenith** (#892): layout's `curdoc` was left
  pointing at a page's iframe, so a click looked up the page's boxes
  among the frame's nodes. A page's fault is now the page's, not
  Xenith's.

### Xenith

- **Agent typesets its replies** (#898). The reply streams in as text
  and is typeset as markdown when the turn ends; `Render` in the tag
  switches between the two. The window no longer repeats an approval
  request without end, and a failed typeset no longer hides its text.
- **A page loading in a window whose events another program reads no
  longer makes Xenith quit** (#896) with `xenith: no window owner`. The
  document view's work now locks the window, not only the row.
- **A fixed header stays at the top of the window** (#903), instead of
  being drawn again on each strip a scroll exposed.

### Dictionary

- **`dict` reads the second edition of the OED, as on Plan 9** (#893),
  and `Dict word` in Acme or Xenith opens a window of its entries. The
  text is copyright and is not shipped: a user supplies it, as files or
  from a server that exports it over 9P (`dict(7)`). Characters above
  U+07FF were dropped by every dict module; they are not now. The tag
  scripts in `xenith/dis` (`Goog`, `Pedia`, `Slide`, ...) were tracked
  without execute permission and none of them ran; they do.

### Veltro and the agent loop

- **Delegation works again after the move into veltrosrv** (#917). What
  looked like model failures were harness bugs: task agents had no
  tools, activity 0 lost its own at its first delegation, every
  lucibridge shared one `/mnt/veltro`, replies repeated each turn, and
  llmsrv's `/stream` lost text. Activity 0 is now told when a task
  finishes, by a `[task-event]` with its report, instead of polling, and
  the user can keep talking to it meanwhile. Inputs over 8K arrive as
  one turn. `tests/host/agent_delegation_test.sh` runs in CI.

### Emulator

- **An allocation a pool refuses says how much, why and for whom**
  (#905): the size, the reason (the pool's maxsize, the 1 GB block
  limit, a restricted Prog's reserve, or the host), the caller (as
  image+offset on Linux, for `addr2line`), and the pool's state.
- **`Display.writeimage` finishes on an image wider than the display's
  buffer** (#897); it looped forever holding the VM, so `charonshot`
  and `scap` hung on a Retina-wide window.
- **The launchers give the Dis heap 1536 MB** (#921), from 512 for
  Xenith and 1024 for InferNode. Charon with scripts on needs it; the
  pool costs nothing until it fills.

### Documents

- **PDF text from fonts whose ToUnicode maps one code to several
  characters** (#911): ligatures such as "ff", "fi" and "ffl" extract
  as their letters.

### Bare metal

- **The Pi 4 kernel runs on a Pi 4** (#912, #915, #922), a 4B rev 1.5
  with 4 GB. On the board: SD card power on EMMC2 and the GENET receive
  ring fixed, a serial loader, USB keyboard and mouse together behind
  the VL805 (the xHCI interval was read in the wrong unit), all of its
  memory, temperature in `#P`, and `tryboot.txt`. Gigabit TCP both ways
  (out 537 to 890 Mbit/s, in 932) from a send queue sized to the board,
  and SD reads from 1.7 to 19 MB/s raw by reading multiple blocks. The
  console no longer interleaves the cores' lines character by
  character, and `/dev/sysstat` reports idle ticks per core.
  `os/bcm2711/README.md` lists what each subsystem did on the board.

### Build

- **`makemk.sh` builds `mk` for the host it runs on** (#913); on Linux
  it compiled against the macOS headers and failed.

## [0.7.0] - 2026-10-13

This release gives InferNode a JavaScript engine of its own, and Charon
runs pages' scripts with it (off by default: `scripts on` in charon(1)'s
settings). Browsing is the other half: a grind of 40 live sites, six
links and Back on each, went from clicks that did nothing and seven
sites stuck for good to 316 of 320 navigations completed and none stuck.
Layout and style are incremental, a click lands on what is drawn, and
pictures come in from the top of the page. Documents (PDF, Markdown,
Mermaid, HTML, images) share one view in Xenith and in a new wm/page.
The Dis VM, its JITs and the Limbo compiler had a run of memory-safety
fixes, found mostly by the engine's fuzzer. Two fixes are urgent for
users of 0.5.0 and 0.6.0: their macOS tarballs do not run on Apple
Silicon, and Xenith could write a file over 10 KB empty on Put.

### JavaScript

- **A JavaScript engine of InferNode's own** (#848), in Limbo on Dis
  (`appl/lib/js`, `docs/JS-ENGINE.md`): current ECMAScript to register
  bytecode and an interpreter, regular expressions with Unicode 17 data,
  generators, async functions, promises, modules, and the built-ins
  through typed arrays, Proxy and BigInt, with a heap and collector of
  its own. test262: 98.3% of `test/language`, 99.1% of `test/built-ins`.
  Hot functions compile to Dis modules (`jsjit`), which the Dis JIT
  compiles; a verifier checks each, and `jsfuzz` compares the tiers.
  `js(1)` runs scripts; `jsfs(4)` serves realms as files.
- **Charon runs a page's scripts** in a realm confined before it runs
  anything to a name space of its grants: the DOM, events, selectors,
  forms, CSSOM, geometry, fetch and XHR, timers, storage, cookies,
  observers, custom elements, import maps, Intl. A page's network is
  `originfs(4)`, an origin filter in front of webfs that holds requests
  to CORS. Scripts are off unless `scripts on` is in the user's
  settings. The old `appl/lib/ecmascript` is gone; Jwin uses the new
  engine.

### Charon

- **Layout and style are incremental** (#861, #860): a change journal on
  the document and a rule index restyle only what a script changed
  (`:has`, siblings, shadow trees), unchanged blocks keep their layout,
  flex items are measured once, text and SVG are cached. On live sites
  with scripts on, layout time over ten seconds fell from 12953 to
  199 ms on a GitHub repository and from 2701 to 803 ms on BBC News.
- **Leaving a page no longer stops the browser** (#888). A page's realm
  took its process group only once the engine had loaded, and leaving
  the page killed that group: until then, the browser's own, window and
  all. A realm killed holding the session's lock, the realm list's, or
  style's class table's left it held, and every click after waited for
  ever. Locks now know their holder and are taken back from one that is
  gone (#865 did this for the layout lock; its check, made from inside a
  realm, took a live holder for dead, and is fixed).
- **A click lands on what is painted there** (#875, #880): hit testing
  follows paint's stacking order (z-index, stacking contexts), so a
  headline raised over a card's stretched link is clicked, not the card;
  and a box positioned against the root clips its overflow for clicks as
  for paint (GitHub's screen-reader headings took the clicks on the file
  list).
- **With scripts on, `<noscript>` is hidden and its content is text**
  (#873), and `@media (scripting)` matches: craigslist's and Apple's
  no-JavaScript curtains no longer cover their pages.
- **A page's console is a file** (#873): what its scripts log, uncaught
  exceptions and CORS refusals go to `/mnt/charon/console`, not the
  terminal; `/mnt/charon/errors` lists what the page could not fetch. A
  CORS refusal of an error page says it was one.
- **Pictures come from the top of the page down** (#882): the first
  screen's pictures arrived in 6 s where they took 13.5 (CNN), 3 s where
  they took 10 (the Guardian). Pictures are kept for the session (#869),
  so going Back does not fetch them again, and a GIF with no colour
  table decodes (#867).
- **A link to what Charon cannot show is not fetched** (#887): an mp3
  linked from a podcast page was fetched whole (20 MB ran a page load out
  of heap) and parsed as HTML. webclient's `requesttypes` and webfs(4)'s
  `types` read only the bodies asked for; the page says what the file
  was.
- **The window keeps what it shows while a script is busy** (#863), and a
  widget asking for another size repaints only what moved (#862): pages
  no longer flash as their pictures load.
- **Links go where they say** (#866): a URL's host ends at `?` and `#` as
  well as `/` (`cnn.com?x=...` went to the wrong host), and URLs are
  percent-encoded as a browser sends them (Thai paths, spaces).
- **TLS: secp384r1, and handshake messages longer than a record** (#868),
  for pantip.com, w3c.social and instagram.com; the connection pool is
  changed under a lock (#847), which lost modules from GitHub's module
  graph.
- **The window is the size it asks for** (#877): wm/wm kept every
  application's window at what its widgets needed (Charon 380x300 for its
  1024x768); `tkclient` now turns off geometry propagation for a toplevel
  given a size.
- **`ctl scroll` moves the window's view** (#876), and **an inline box's
  place is its pieces in the lines** (#881): `dom/<n>/box` gave a link in
  a paragraph as 0 by 0.
- **Known limits**: sites that refuse a browser they do not recognise
  (by its TLS handshake or a script challenge: Stack Overflow, Reddit,
  Amazon, Medium and others) answer 403; craigslist needs `SharedWorker`,
  which the engine does not have; heavily scripted sites (YouTube,
  GitLab) render nearly empty; pictures are decoded one at a time.

### Dis VM, JITs and the Limbo compiler

- **`a[i] = f()` makes the call before finding the element** (#856): when
  `f` replaced `a`, its result was written into the freed array. Rebuild
  from a clean `dis/` to drop bytecode made by the old compiler.
- **Two inliner faults** (#830): a temporary argument freed before its
  element was read, and `v = f(v)` reading members already written.
- **A `ref fn` of a module's own function no longer adds to equal module
  types' link table** (#872): `load Cmd "/dis/cut.dis"` failed in any
  module of the same shape, which is how `awk_test` skipped every test.
- **A compiled module returning after its last reference dropped**
  (#826): its registers were loaded after the release, so a Prog resumed
  on another's stack under `-c1`.
- **amd64**: reals in SSE2 (#850; JavaScript ran 10 to 25 times slower
  than on arm64), big `*`, `/`, `%` and `hd` compiled, and a fault in a
  callee caught by its own handler, not its caller's (#883). The most
  negative big over -1 now wraps everywhere.
- **A deep structure is freed whole** when its last reference drops
  (#829), not left to the collector past 64 levels; **a call between
  modules no longer ends a compiled thread's time slice** (#831); past
  half a heap the collector runs on one scheduler pass in eight, not
  every one (#845); `up` is a thread-local variable (#844; Android keeps
  the call, #858).

### Emulator

- **The intermittent `poolfree` crash under `-c1`** (#854): three races in
  Prog group handling inherited from Inferno wrote into freed Progs and
  groups; a stack segment now has room for its 64-bit header; three reads
  past an allocation, found with AddressSanitizer.
- **Name space use-after-frees** (#857): a Prog's groups are swapped, read
  and freed under the locks that guard them; a fault reading
  `/prog/n/ns` could leave a name space hung for good. `pgrp_race_test`
  reproduces the `kchdir`/`namec` race on the runtime (#879).
- **Killing a Prog blocked in the host stops it** (#886): a killed
  `listen` stayed in `/prog` holding its port. emu's exit status is the
  one asked for (`halt 3` exits 3; it was 137 or 0 by a race), and a
  panic exits 1.
- **A root path as long as the host allows** (up to 1023 bytes, was
  139). A longer `-r`, `$INFERNO` or `$ROOT` was cut short without a
  word, and emu stopped at `loading "/dis/emuinit.dis": '/dis' file does
  not exist`, as it did for a root that was missing or not a directory.
  A root too long is now refused, naming its length, and one that cannot
  be used stops emu naming it and why.

### Bare metal

- **Bluetooth on the Pi runs at 3 Mbaud** (#825): hardware flow control
  now holds input when the UART's stage is full, where 3 Mbaud lost most
  of a 1.2 MB push; L2CAP 873 kbit/s, was 94.
- **etherusb's timers no longer hang** when the reply wins (#852): a boot
  left seven blocked processes, now none.

### Veltro and the agent loop

- **A tool call longer than one 9P message runs once, on all of it**
  (#870); it ran once per fragment.
- **Plaintext API keys are imported into factotum**, not bound into the
  name space (#871).
- **LLM API connections go through an HTTPS proxy** when `HTTPS_PROXY` is
  set, with `NO_PROXY` (#878).
- **An unattended campaign's gated call is denied**, not left waiting on
  a dialogue (#885); **subagents load their tools**, within their
  delegation budget (#857).
- **Boot waits for the services it needs, not for fixed seconds** (#884,
  #889): a headless Lucifer reaches INIT in about 0.55 s (was 6).

### Documents

- **A PDF's links work**, in Xenith and in wm/page. pdf(2) reads a
  page's link annotations: a URI, or a page of the document (GoTo, a
  destination, a named destination through the catalog's Dests or its
  name tree). In Xenith, button 3 on a link to a page goes there, and on
  a web address opens it in a browser window in Xenith, as a Markdown or
  HTML file's links now do too: what is opened in Xenith stays in
  Xenith (it went to the plumber, and left a standalone Xenith only
  when nothing took it). In wm/page, button 1 clicked without moving
  follows a link: a page of the document, or the plumber. `doc/links`
  lists a PDF's links.
- **HTML scrolls as smoothly as a PDF.** A flowing document is painted
  off screen into a band round the view; a scroll copies from it and
  paints only the strip it exposes, where a web page used to be laid
  out again, box by box, at every step. The view is no longer filled
  with its background before a sheet is painted, which showed it blank
  mid-paint. A scroll step of a 60 KB page at 1400x1000 went from
  8-13 ms to about 1 ms; Markdown from 3 ms to under 1.

- **wm/page shows documents**: PDFs, images, Markdown, Mermaid and
  HTML in a window of their own, through the view Xenith uses: several
  files read as one, standard input, pages turned, find, go to a page,
  write the page shown as an image, a Tk menu with the pages and files
  (`page(1)`). Only the file shown is held open.
- **The document view is a library**, `sheetview(2)`, shared by Xenith
  and wm/page. It turns sheets (once, as each is painted), paints the
  next sheet the way the view is going, and keeps its place to the
  pixel when laid out again. A document opened again in Xenith keeps
  its place, as it was meant to.
- **PDF paths, strokes and shadings drawn where and as they are**:
  Limbo's `int` of a real rounds, and adding a half first had moved
  every path half a pixel, drawn hairlines three pixels wide, and
  turned full-white shadings black; pages were a point too big. Against
  Poppler the difference falls by another 28%.

- **One document model in Xenith.** A PDF, an image, a Mermaid
  diagram, Markdown and HTML set for reading, and a web page are all
  shown by one view: a column of sheets (a PDF's pages), scrolled
  smoothly across page boundaries, dragged in both directions, zoomed
  (`Zoom+`, `Zoom-`, `Zoom n`, `Fit`, `Fit page`) with PDF pages
  painted again sharp at the scale while the old painting is shown
  scaled, and paged (`Page n`, `NextPage`, `PrevPage`). It replaces
  image mode, Render's document view and browser windows' drawing
  (docs/xenith-documents.md).
- **A PDF opens as a PDF however it is opened.** Named on Xenith's
  command line (`xen file.pdf`, and the plumber starting `xen` when no
  Xenith listens), by Get, by Load, or plumbed to a window already
  open on it, a PDF showed its source; only a new window opened by a
  look or a plumb rendered. Every way now decides by the file's kind.
- **A PDF's or an image's text is read-only.** The body is the
  document's text, for Look, search, Snarf and agents; typing and
  writes are refused, and Put writes it only to a file named.
- **Text on the drawing.** In a PDF or Markdown, a click selects the
  word there, button 2 executes it, button 3 follows the link there or
  looks the word up; a search marks what it finds.
- **Documents as files.** `/mnt/xenith/<id>/doc/`: `ctl` (what it is,
  where the view is; zoom, fit, sheet, Render), `text`, `links`,
  `find`.
- **Loaded only when needed.** The kinds of document are a table,
  `/lib/xenith/doctypes`; each kind's engine is loaded the first time a
  document of the kind is opened, and loads its own dependencies then.
  Markdown and Mermaid are set by `rlayout` and never load Charon;
  browser windows and HTML files share one Charon engine. Xenith no
  longer loads every renderer, twice, when it starts. Lucifer's
  presentation view draws documents through the same engines; the old
  render registry and renderers are gone.
- Each PDF window keeps its own page (they shared one).
- **PDF text as it was set.** Every glyph is drawn from its outline at
  the screen's resolution, placed by the PDF's own widths to a quarter
  pixel; no bitmap fonts. Embedded Type 1 fonts are drawn (they were
  replaced by a sans bitmap, as every font not embedded was); a font
  not embedded is drawn by a face with its metrics (TeX Gyre Termes,
  Heros, Cursor for Times, Helvetica, Courier). Glyphs are found as
  the spec says (encodings, Differences, CMaps of mixed code lengths,
  CIDToGIDMap); word spacing, rise, horizontal scale and text render
  modes are applied, text as a clip among them; text is clipped; Type 3
  glyphs are drawn; text at any angle is rasterised as itself. Against Poppler, over 62 pages chosen by font
  kind, the difference falls by a third, and no page is worse.
- **PDF pages painted once, at their scale**, onto the view's own
  image: no longer at twice the scale and averaged down. Fourteen pages
  of a paper are first painted in 1.7 s, not 6.3 s, with an image pool
  of 9 MB, not 35 MB.
- **Long and large PDFs open at once.** Pages are indexed once a
  document, not found by walking the page tree (opening asked every
  page its size, so 1310 pages took 15.8 s; now 0.3 s, and 20000 pages
  0.3 s); a document's text is joined once (the PDF reference's 2.5
  million characters ran out of memory); object streams are kept, not
  decompressed for each object; cross-reference entries are values,
  streams and CFF glyphs slices, not copies (the reference opens in
  40 MB of heap, not 76; a page in a 16 MB CID font is drawn in 17 MB,
  not 63). Xenith shows a document before its text is read, finds the
  visible pages by halving rather than scanning, searches pages' text
  and works out where on a page only when it is shown (the reference:
  8.7 s to 0.14 s), and keeps the words of only 32 pages.
- **PDF streams through every filter they name**, and LZW, ASCII85
  and RunLength decoded: a font program in ASCII85 and Flate was cut
  short, and its font replaced.

### Platforms and releases

- **The macOS tarball runs on Apple Silicon** (#859): from 0.5.0 to
  0.6.0, its bundled libraries' signatures were broken by
  `install_name_tool`, and `o.emu` was killed at exec. The release now
  signs them and runs the staged emulator before archiving. The DMGs
  were not affected.
- **iOS builds from master again**, with a CI job that boots it in the
  Simulator (#855); Tk applications and the plumber run there, and
  Xenith appears.
- **Xenith for Linux**: `xenith-<version>-linux-amd64.tar.gz` and
  `-linux-arm64.tar.gz`, the Linux GUI release's emulator and runtime with
  its own launcher (`./xenith [file ...]`), desktop entry and icon, as
  `Xenith.app` and `Xenith.exe` are for macOS and Windows. Its
  `setup-desktop.sh` adds Xenith to the app menu, opening the files it is
  given, and puts `xenith` on the PATH.
- **Version and publisher in each app's details**: `InferNode.app` and
  `Xenith.app` carry the release's version in Info.plist (they said 0.1),
  and `InferNode.exe` and `Xenith.exe` take theirs from `include/version.h`,
  as the About box does (they said 0.2.0), and name InferNode.io as their
  company. The macOS About box links to github.com/infernode-os/infernode.

### Xenith

- **Put no longer writes a large file empty** (#890). A file over 10 KB
  is written in the background, and the writer read the window's text
  from its own process while Put set a document shown beside it again
  from the same buffer: the file was written empty and the window's text
  left broken. The writer now writes a copy taken at Put, and an edit
  made during the write is no longer marked saved. Affects 0.6.0 and
  earlier when a large file is edited while it is written.
- **Button 2 held on a document's scroll bar follows the mouse** (#864),
  as it does in a text window.
- **A file opened for the plumber no longer races the window files.**
  Xenith handled a plumbed message without holding the row, which every
  other change to its windows holds; acme's threads never ran at once,
  Xenith's procs do. A plumbed open beside a 9P request (a window
  deleted through `/mnt/xenith`, say) could corrupt a frame and stop
  Xenith with `bad assert in read`. `xenith_doc_test` now runs with a
  plumber, as a session has one.

- **A document shown beside its text is set again on Put**, or when
  its `doc/ctl` is written `refresh` (from the unsaved text, for
  scripts), not at each edit. Each keystroke used to lay the page out
  again from the file's committed text, which did not yet hold what was
  being typed: the shown window flickered and kept the old text, and an
  HTML page took half a second a key. The old drawing now stays until
  the new one is ready.
- **Finder opens files in Xenith.app**: Open With, or a file or folder
  dropped on its Dock icon, opens in the running Xenith or starts one,
  and a file dropped on Xenith's window opens in it on every host. The
  emulator gives each path to a new `/dev/hostopen` (`cons(3)`);
  `hostplumb -p` plumbs it, as `lib/xen/boot.sh` does. `Xenith.app`
  declares the document types, as an alternate handler that never takes
  over a file type.
- **File names with blanks**, as Finder hands many, are quoted in the
  tag as plan9port's acme quotes them, and read back whole. Before, a
  change to the tag renamed such a window to the part before the blank,
  and Put wrote that file. A selected name looked at (B3) may have
  blanks in it.

### Window system

- **New from wm/wm's menu takes the first time.** A button-3 click that
  never moved chose nothing, though New is the item under the pointer,
  and once New was chosen the sweep waited for a release the menu had
  already had, so a press that came with no motion before it (as a
  trackpad sends) was lost and the cross never swept. Resize, Move,
  Delete and Hide waited the same way for their gunsight. A click that
  never moves now chooses New, as rio's does; any other button cancels.
  `tests/host/wm_test.sh` drives the menu, the frame and focus and
  checks where they leave the windows.
- **A theme switch reaches wm/wm's windows.** Xenith's Theme (or
  Settings, or a write to `/lib/lucifer/theme/current`) changed only
  the program that made it under a standalone wm/wm: Lucifer tells the
  windows it hosts, but wm/wm at the top watched nothing. It now
  watches the theme and passes `retheme` to every window, hidden ones
  too, and its menu (and every `menuhit` menu) takes the theme's menu
  colours as it opens instead of fixed greens.
- **Every window's frame follows a theme switch, and sam, scene and
  page's insides too.** A Tk window given an explicit colour has its own
  copy of the palette, which a live `retheme` passed over, so the frames
  of charon, editor, fractals, ftree, keyring, man, matrix, page,
  settings, shell and wallet kept the old windowborder. Tk now records
  which colours an option set, and a `retheme` refreshes every other
  colour of every widget. sam, scene and page read the theme only at
  start; they now take it again on a switch. fractals, man and keyring
  recoloured widgets without repainting them, so a switch could leave
  them stale. `tests/host/wm_theme_test.sh` runs every wm application
  through a switch and checks it by pixel.
- **One job per mouse button, as in Plan 9.** wm/page's operations
  (paging, zoom, fit, turning, find, go to, write) move to button 2, and
  button 3 lists the pages and files to choose from, as Plan 9's page
  does; wm/sh's edit menu was already on button 2 and wm/wm's window
  menu on 3. The convention is written down in
  `docs/DESIGN-PRINCIPLES.md`. wm/page sets Markdown and HTML in
  Xenith's faces (Go and Go Mono); it used the default font, which has
  no em dash.
- **`/chan/uitest` types text** (`text STRING`), and is documented in
  `wm(1)`. `tests/host/page_test.sh` now drives wm/page through paging,
  the wheel, a drag, the button-3 menu, fit, zoom, turning, two files
  and standard input.

## [0.6.0] - 2026-10-10

This release ships Intel Macs their own DMG and headless tarball, and
Xenith as an app of its own, `Xenith.app` and `Xenith.exe`, beside
InferNode in every release. Charon has a new engine,
written for this tree, at 81.9% of the WPT reftests. The agent loop is one
program, `veltrosrv`, served as files. A headless node lends its desktop
to another InferNode's screen through stock `cpu(1)`; the screen is the
window, resizable, with one window frame for every app; `wm/sam` edits;
and `scene` draws 2-D situations as files. Bringing the amd64 JIT to
macOS found two bugs it had on every host; see Dis VM and JITs. Security
covers a mode-777 rename on 64-bit hosts, an approval bypass in the agent
loop, and two post-quantum fixes.

### Platforms and releases

- **Intel Macs** (#791): `infernode-<version>-macos-amd64.dmg` and
  `xenith-<version>-macos-amd64.dmg`, signed and notarized as the arm64
  ones are, and a `-macos-amd64.tar.gz` headless build. Built and tested
  natively on GitHub's `macos-15-intel` runner; no universal binary. The
  build scripts, `makemk.sh` and the emu mkfile take `OBJTYPE` from
  `uname -m` and the Homebrew prefix from it. JIT memory on macOS now
  comes from the near-text allocator Linux uses, and an integer divide by
  zero in compiled code is `zero divide`. A GP fault on spawn, found only
  on real Intel hardware (Rosetta hid it), came from an `aligned(16)`
  `FPU` struct the pool allocator could not honour.
- **Xenith ships as an app of its own**, alongside InferNode in every
  release: `Xenith.app` (a signed, notarized `xenith-<version>-macos-<arch>.dmg`)
  and `Xenith.exe` (`xenith-<version>-windows-amd64.zip`), with their own
  icon (#784). Each is the same emulator and runtime tree as InferNode,
  running Xenith alone as `tools/xen` does, and shares `~/.infernode` with
  it. `Xenith.exe` opens the files on its command line (Open With, or
  dropped on it). `xen`, `xen.ps1` and both apps start through one script,
  `lib/xen/boot.sh` (docs/XEN.md). `xen.ps1` now starts the plumber and
  the model service, as `xen` does.
- **Acme's and Xenith's commands ship.** Each editor binds its own command
  directory before `/dis` (`acme/dis`, `xenith/dis`: `win`, `adiff`, `Mail`,
  `Agent` and the rest), as upstream Inferno's acme does. Releases staged a
  fixed list of top-level directories that never included `acme/` or
  `xenith/`, so in a shipped tree neither editor could run its tag
  commands, and Acme had no colour schemes. Every release job stages both
  now, and the build manifest covers both command directories.
- **Android boots to Lucifer again** (#768). Android 0.2.0 showed a blank
  screen: APK packaging drops empty directories and `/mnt` was not on the
  placeholder list, so `msg9p` and `luciuisrv` could not mount. `mnt`,
  `mnt/llm` and `tmp` are staged now, and both the APK and the release
  workflow fail if a mount root is missing. Debug builds use the package
  ID `io.infernode.debug`, so they install beside the Play build.
- **The macOS and Windows headless builds get a memory screen**, as Linux
  has (#744).

### Charon

- **A new engine** (#754, #811, #815): an HTML5 parser (WHATWG tree
  construction, run against html5lib's 1,478 cases), the CSS cascade and
  selectors, box layout with flex, grid (subgrid, auto placement), tables,
  floats and sticky and fixed positioning, TrueType, WOFF and WOFF2 fonts,
  and Brotli. 10,693 of 13,049 WPT reftests pass (81.9%), and layout is
  compared against Chromium on live sites at five widths. Also: CSS
  filters, linear, radial and conic gradients, `clip-path: inset()`,
  `object-fit`, bidi (UAX #9), Thai line breaking from a dictionary,
  variable fonts, progressive loading, and a keep-alive connection pool.
  `appl/charon` is now the browser window alone, `wm/charon`.
- **Its session is files**, `charonfs` at `/mnt/charon` (`url`, `title`,
  `text`, `links`, `forms`, `ctl`, the DOM under `dom/`), posted as
  `#scharon/fs`.
- **Settings** (#811) in one file, `lib/charon/settings` in the user's
  home, which Charon and Xenith's HTML rendering both follow:
  `images on|click`, `fonts web|system` and `effects on|off`, through
  Charon's menu, its `ctl`, and a Web Pages panel in Settings with a Light
  preset for small devices. Form controls are drawn by the page, not Tk
  widgets over it.
- **Memory** (#811): GitHub at 1400×860 went from 615 to 273 MB of emu
  RSS. A style sheet linked several times is parsed once, rules no longer
  keep their sheet's tokens alive, and images are decoded at the size
  shown.
- **Images**: a JPEG decoder (baseline and progressive, CMYK) and a WebP
  decoder (lossless, lossy and alpha), both matching libwebp or the
  reference fixtures to the pixel (#811, #812); the faster of the two WebP
  decoders the tree briefly had is the one kept (#812). Image fetches send
  `Accept: image/webp,…` as browsers do, so image CDNs send WebP (#812).
- Charon follows a theme switch (#794). On the desktop, a web URL plumbed
  goes to Charon, to the running one if there is one (#806).

### Xenith

- **Xenith browses** (#805, #807, #808). B3 on an `http:`, `https:` or
  `file:` URL opens a browser window on the same engine: links, Back, Fwd,
  Reload, and the tag as the address bar (edit the name, then Get). The
  window's text is the page's text, so Look, search and Snarf work on it.
  Form fields take the keyboard. Each browser window's page is served as
  files, as Charon's is, at the path its new `web` window file names.
- **Render sets HTML with Charon's engine** (#797) and markdown in real
  faces (#774): Go Medium, Bold, Italic and Bold Italic, sized headings,
  and tables laid out booktabs-style with their alignment markers. Render
  on a `.md` file shows the typeset document in place of the text; the
  buffer stays untouched. The old HTML engine and `charonrender` are gone.
- **One image loader** (#801) for Xenith, the browser, `wm/view` and
  `scene`: PNG, JPEG, GIF, SVG, XBM, PIC, PPM, PGM, Inferno images and
  WebP, identified from the data and then the name. Xenith opened a
  `.jpg` as text before. Images keep their colours on displays deeper
  than 8 bits instead of being dithered to 256 (#813).
- **`tools/xen` and plumbing from the host** (#770, #772): open host files
  in an InferNode running only Xenith (or sam, `-s`); plan9port's `plumb`
  on the Mac opens files in it through `hostplumb(1)`, and so does `plumb`
  on a remote host reached by ssh, with that host's files mounted over
  `u9fs` so edits save back. On Linux (#778): a Wayland title bar through
  libdecor, HiDPI on X11, and fractional scales (1.25x, 1.5x) with Go
  built to match. With `INFERNODE_HIDPI` set, the desktop emu draws in the
  display's own pixels.
- **From canonical Acme** (#780): the `xdata` and `errors` window files,
  and the `dirty`, `menu` and `nomenu` ctl messages.
- **Fixes**: scrolling on a trackpad quit Xenith and Acme, because the
  quit signal shared a button bit with scrolling left (#779). Exit under a
  window manager closed the whole emulator (#764). `u` written to the
  `edit` file undid nothing, and a short event written to `event` killed a
  worker and hung the writer (#789). Text inserted inside a selection was
  drawn in the wrong colour (#787). A Mac trackpad's fingers were taken as
  touch gestures, so every scroll arrived twice (#772). The PDF, diagram
  and markdown engines load on first use, not at startup (#802).

### Veltro

- **One agent harness, served as files** (#781). The agent loop was
  written out twice, in `veltro` and `lucibridge`, and had drifted; it is
  now one program, `veltrosrv`, which serves a session as a directory at
  `/mnt/veltro`: `input`, `text` (the conversation, following a turn as it
  is generated), `log` (the trajectory), `status`, `approve` and `ctl`.
  The loop is `lucibridge`'s, the one the grinding tuned, moved in
  unchanged; its goldens pass through the new `lucibridge`, now a client
  that renders those files into Lucia. `veltro` is a client too, and
  Xenith gets `Agent`, a window on the agent for work on a project from
  the editor (`man 4 veltrosrv`, docs/VELTRO.md, docs/XEN.md). The
  interactive `repl` is gone.
- **Read-only tool calls run concurrently.** The tool calls of one model
  response run at once when all are read-only (reads, searches, `spawn`)
  and one at a time, in the model's order, when any mutates, so a write
  always precedes the read or compile that follows it. Every call has its
  own sixty-second bound. A read repeated after a write in the same batch
  no longer gets the result from before the write (#798).
- **The server restricts its own namespace before it serves**, with the
  grants it was started with, and mounts only in the client's namespace:
  the agent's tools cannot see `/mnt/veltro`, so it cannot approve or
  widen itself. Compaction is `llmsrv`'s alone.
- **A `window` tool** (#743) saves a picture of one of the activity's own
  windows into the agent's scratch area, from the new per-window tree
  `wmsrv` serves (`<id>/window`, mounted per activity at `/mnt/wsys`); no
  other activity's windows are nameable.
- `exec` refuses GUI apps and points to `launch`; it had reported them
  launched into a presentation zone nothing read (#814). `claude-gate`
  sends one response's tool calls to `llmsrv` as one batch (#799).
- `veltro` session names and logs were built with `string c` on a rune,
  which printed its number; fixed. `-y` answers the approval gate for
  scripts. `xen` starts the model service the way Lucifer's boot does,
  through `lib/lucifer/llmsrv.sh`, now one script for both.

### Remote desktop

- **A headless node's desktop on another InferNode's screen** (#730,
  docs/REMOTE-DESKTOP.md): the viewer runs `cpu tcp!node wm/wm wm/sh`, and
  the node's programs draw on the viewer. On a bare-metal card the
  listener starts only if `/n/dos/cpulisten` exists, only with a
  certificate, and after the boot has narrowed its namespace.
- **`cpu(1)` works out of the box**: it bound `#d` for the draw device
  where this tree's is `#i`, and its default algorithm was `none`, so
  keystrokes went in clear after authentication. The default is now
  `aes_256_cbc sha256`. A session ends with its command or with its caller
  and takes what it started with it (#759); a refused request is reported
  as a failure (#783).
- **A second InferNode no longer kills the first** (#728): every login
  shell on macOS and Linux killed whatever held port 5356, which could
  only be the user's running InferNode. A display that hangs up no longer
  panics the node drawing on it (#727). API keys in the host environment
  reached factotum at login again; every hosted login also printed
  `sh: null list in concatenation` (#742).

### Window system and graphics

- **The screen is the window** (#771): a resized or full-screen window
  used to be the fixed screen scaled into it with black margins. The SDL
  backend now shows the window's size of a display-sized buffer 1:1 and
  reports each resize on `/dev/wmsize`, which Xenith and Lucifer lay
  themselves out to. Touch platforms are unchanged.
- **One window frame for every app; `wm/wm` follows rio** (#763): a 4px
  frame in the theme's `windowborder` colour; buttons 1 and 2 on the
  border reshape, button 3 moves; button 3 on the background opens rio's
  menu (New, Resize, Move, Delete, Hide); click to focus. Hidden windows
  are listed by their labels (#766). Button-3 menus in several apps closed
  at once because they passed a button mask for a button number.
- **One anti-aliased rasteriser, in the draw device** (#745), with exact
  integer coverage, so hosted, headless and bare-metal draw identical
  pixels. `line`, `poly`, `bezier` and ellipse outlines are smooth; paths
  are filled and stroked through new protocol messages (`Path`,
  `Image.fillpath`, `Image.strokepath`); existing `.dis` files run
  unchanged. Four private rasterisers are gone, and Tk's `-width`,
  `-smooth`, `-capstyle` and canvas arcs are right. Both kernels share
  one draw device; the emulator gains `/dev/screen`.
- Anti-aliased glyphs rendered black under GCC, which made dark themes
  unreadable on Linux builds (#750).
- **Lucifer**: ending a task tears down its apps, window manager and
  mounts. Ending one only hid it, and its apps kept running out of
  sight; every closed app also left a process behind (#767).
- **Themes** (#770, #773, #765): live switching moved below Lucifer, so
  every program follows a switch from any writer; new `glenda` (Plan 9's
  own colours) and `xenith` themes; Halo is a conventional light theme;
  the login screen and About show each theme's own picture.

### Applications

- **`wm/sam` edits** (#751, #777): sam's command language, from Plan 9's
  sources (addresses, `x y g v X Y`, `{}` blocks, undo), and the terminal
  takes input. One window with overlapping layers, swept out with button
  3, as in Plan 9.
- **Scene** (#744): 2-D situation graphics as files. `scenefs` serves a
  live scene that producers write to and agents block on; recording is
  `cat /mnt/scene/changes`, playback is `scenereplay`; `wm/scene` is the
  viewer, and it replaces `geo-map`.
- **Video** (#746, #749): about 37% of a core for a 720p feed in Matrix
  down to about 16%: `vid9p` reads each frame straight into its array,
  YCbCr conversion is a C builtin (`$I420`) where available, and frame
  ticks keep to a deadline. A followed live edge moves with each frame.
- Matrix windows can be moved and resized under `wm/wm` (#752). The
  fractals zoom box is drawn while dragging (#793). Tetris keeps its high
  scores in the player's home (#741). Wheel scrolling in Tk canvases and
  listboxes, and a touchpad's stream of ticks scrolls (#811).

### Dis VM and JITs

- **Two amd64 JIT bugs, on every host** (#791): `maccolr` set `nprop`
  with a 64-bit store, zeroing the next global (on macOS the collector's
  sweep pointer, so every program beyond `echo` crashed), and `compile()`
  did not clear `patch[]`, so stale memory intermittently gave
  "compile failed". Both may have contributed to the earlier
  nondeterministic amd64 failures; that is not established.
- **The amd64 and arm64 JITs checked no array bounds** (#756): the flag
  that gates the checks was never set, so out-of-range indices read and
  wrote outside the array. The amd64 string index check was also wrong.
- **Faults in compiled code reach the handler around them** (#758):
  `R.PC` was stale on the fault paths, so a `{...} exception` block that
  caught under the interpreter did not under the JIT. arm64 zero divide
  raises `zero divide` (it returned 0). The riscv64 kernel panicked on any
  JIT fault; on the arm64 kernel a nil dereference in JIT code is now the
  program's exception, not a panic (#753).
- **`ref T` with no initializer zero-fills its scalars** (#755), in the
  compiler and in `heap()`, under both engines; they held whatever the
  recycled block held.
- **A startup SEGV, about one launch in 150** (#762): `pexit` freed its
  Proc while `up` still named it, so the lock count was written into
  freed memory.
- `memfs` frees the fid of a failed remove, which left the next walk with
  "fid in use" (#800).

### Bare metal

- **Authenticated connections on the native kernel** (#726): none had
  ever worked. The handshake's ML-KEM buffers, 9,440 bytes, sat on a
  16 KB kernel stack and overran it; they are on the heap now.
- **Hot plugging** (#792): a cable pulled and put back, a cable plugged in
  after boot, and a Wi-Fi network left and returned to now each bring the
  interface back, tested on the board. Routes follow an address that
  goes, and the DHCP watchdog no longer holds UDP 68 for the whole lease.
- **Page zero is unmapped after boot** on the Pi 3, Pi 4 and `virt`
  (#760), so a nil pointer faults instead of reading the firmware stub.
- The ICMPv6 unreachable reply leaked the interface's read lock, which
  hung DHCP on Wi-Fi and could take the wired interface down (#722).
  `sed` crashed on an unclosed pattern and hung on `D` (#775).

### Security

- **Renaming a host file made it world-writable** (#790). On 64-bit
  Linux and macOS, `mv` inside InferNode (and Xenith, and agents) left a
  host file mode 777 with a 2106 modification time, and `chmod` set that
  time: a wstat's "don't change" fields were not recognised. Windows was
  not affected.
- **An agent's write could skip approval** (#798). Approval judged a
  native tool call's JSON arguments as if they were the positional form,
  so a `write` or `exec` that needed the operator's approval went to the
  tool unasked. The golden test had pinned the bypass; it now records the
  denial.
- **ML-DSA signing timing** (#795): Decompose divided by `2*gamma2` on
  values derived from the secret key, the leak reported as CVE-2026-22705
  in another implementation. It now uses the reference fixed-point
  reciprocal; signatures are unchanged.
- **ML-KEM input checks** (#796): the FIPS 203 modulus check on the
  encapsulation key and hash check on the decapsulation key; a key that
  fails is refused.
- **Authenticated listeners hardened** (#731, #769): per-source pre-auth
  limits (`-P`, default 4) so one host cannot hold every slot; secure
  listeners refuse `none` and incomplete cipher/digest configurations;
  `rstyxd` sessions get a reduced namespace, and `cpu` and `rcmd` export a
  synthetic `/dev` unless given `-e`. The bare-metal network console can
  be kept to one interface (#739), and wired-only is the documented
  posture.
- **X.509 times after 2038** wrapped, and GeneralizedTime was ignored, so
  certificates under the SSL.com roots failed to validate (#814).
- `secstored` refuses `secstore2` verifiers, as the client already did
  (#803); no release wrote one.

### Other fixes

- `sh` reports a script without the execute bit as not executable, not as
  a missing `.dis` (#788).
- `llmclient`: a backend answering a streaming request with one JSON body
  got an empty reply (#814). `spawn`'s `at=` and `every=` past about 24.8
  days overflowed and are refused (#814).
- Plumbing reads the user's rules first, then the system's defaults; a
  user file that does not parse never leaves the system without plumbing
  (#806). The plumber refuses a message nothing can receive (#770).

### Tests

- **The suite gates CI on every platform, and passes on all of them**
  (#814). Each test runs in its own namespace and process group with a
  time limit; tests no longer write into the source tree; about 70
  modules that failed on every platform pass.
- New: `jit_bounds_test`, `jit_fault_test` under both engines,
  `refadt_zero_test`, `mldsa_decompose_test.sh` (no divide instruction in
  Decompose at any optimisation level), `wstat_nulldir_test`, the
  agent-loop characterization goldens, Xenith's 9P interface inside a
  headless Xenith, frame tests on a simulated screen, `sam_test`,
  `aa_test.sh`, and `cpu_session_test.sh`.

### Documentation

- docs/REMOTE-DESKTOP.md, docs/XEN.md, docs/scene-design.md,
  docs/draw-geometry.md, docs/CHARON-ENGINE.md, and man pages for
  `veltrosrv(4)`, `hostplumb(1)`, `scenefs(4)`, `i420(2)` and more.
- The repository root is tidied and about 100 documents corrected against
  the tree; superseded reports moved to `docs/history/` (#810).

### Known limitations

- **The Intel and Xenith release legs run for the first time with this
  tag**: release jobs run only on a tag, so the Intel DMGs' signing and
  notarization were not exercised before. The DMG's real minimum macOS
  version is unchecked. Intel support lasts as long as GitHub has an
  Intel macOS image (#791).
- **Charon runs no JavaScript.** The old engine's was removed with it
  (#797); a script host is proposed in docs/JS-ENGINE.md. In Xenith, a
  form field has no caret (typing goes at the end), and in click-to-load
  mode a browser window cannot load an image on click.
- **Bare metal**: the listener hardening (#769) and the page-zero change
  (#760) were verified under QEMU; their board runs are not recorded in
  their PRs. `claude-gate`'s batching (#799) merged without a live run.
- `xen.ps1` on Windows is untested (#770); the resizable screen was not
  run on Linux or Windows (#771).

## [0.5.0] - 2026-09-28

InferNode runs on bare metal. This release adds a native kernel for the
Raspberry Pi 3B+, brought up on the hardware and soaked for 48 hours,
a port to 64-bit RISC-V, hosted and bare metal, and the fixes that work
found in the shared code: in the Dis VM, all three JITs and the hosted
emulator. It also makes the TLS client authenticate servers, which it
did not do before; see Security.

### Bare metal

- **A native kernel** (`os/`): Inferno's kernel structure, `os/port` and
  `os/ip` shared, `os/arm64` for the architecture, `os/bcm` and
  `os/bcm2837` for the Raspberry Pi 3B+. It boots to the Lucifer desktop
  from the SD card: USB keyboard and mouse, HDMI, the card as a
  filesystem (`dossrv`), the audio jack as `/dev/audio` (#636) with a
  low-latency mode (#653), GPIO pins as files with edge events and
  interrupt timestamps (#651), Wi-Fi (WPA2 and DHCP), Bluetooth (`bt9p`:
  HCI, L2CAP, SDP, RFCOMM, HID), and the on-board Ethernet.
- **Ethernet at 160 Mbit/s in and 148 out** on the 3B+'s LAN7515 behind
  its USB 2 controller, from 7-32 before (#633): a bulk IN kept armed
  across NAKs, a cross-core race on the controller's interrupt mask, a
  cache invalidate after receive DMA, 802.3x pause frames, and
  receiver-side selective acknowledgement (RFC 2018) in the TCP stack.
  One data path, in the kernel; the earlier 9P path is gone.
- **The cores at their rated clock** (#691). The firmware leaves the
  ARM cores at its 600 MHz idle clock for the OS to raise, and nothing
  asked; every soak, battery and benchmark before this ran at 600 MHz.
  They now run at 1400.
- **Two more machines under QEMU**: the `virt` machine (#656, #657) and
  the Raspberry Pi 4 (#662-#666). The Pi 4 port has never run on a
  board and says so; both are built and booted in CI.
- **Drivers for the Pi 4, tested where QEMU can test them** (#705): PCI
  and the Pi 4's PCIe bridge, xHCI with hot-plug, MSI, GICv3, USB disks
  (`diskusb`), isochronous USB output, and GENET Ethernet, all from
  9front. On `virt` they run; the Pi 4's own hardware has never run
  them. A QEMU DWC2 bug that looked like ours (#664) is patched in the
  QEMU that CI builds.
- **64-bit RISC-V** (#718): `emu` on riscv64 Linux with a new Dis JIT
  (`libinterp/comp-riscv64.c`), and a native kernel (`os/riscv64`) for
  QEMU's RISC-V `virt` machine (`os/riscvvirt`, to the graphical logon
  on a ramfb screen) and the PolarFire SoC of the BeagleV-Fire and
  Icicle Kit (`os/mpfs`: SD card, Ethernet, entropy, and a `boot.scr`
  for U-Boot). The virtio drivers and framebuffer console are now shared
  across the kernels. Everything RISC-V has run under QEMU only;
  `os/riscv64/README.md` has the first-boot checklist for the board.
- **A lock loop found by the soak, and fixed** (#681, #682): `tsleep()`
  took the timer-sleep lock with interrupts on while the USB driver spun
  for it with them off; a holder preempted at the wrong instant pinned
  the spinner's core for ever. Reproduced in 40-125 s under a sleep
  storm, then 48 hours clean. Also from the board: a process preempted
  between two uses of a register resumed on another core (#622), the
  JIT's module-pointer sentinel taken for code (#635), type code never
  freed on module unload (#641), the entropy source padding a short
  read with zeros (#658), a software cursor that left a second arrow
  behind (#654), and "clone failed" now says why (#650).
- **More from the board, after the soak**: every Limbo `real` formatted
  as garbage, and loading a map that wrote positions with `%.6f` wedged
  the VM, because `snprint`/`sprint` were built without FP and a
  variadic double travels in a vector register (#715); the 100-slot
  process table filled in an ordinary GUI session and hung everything
  on "no procs", now scaled from RAM and capped at 1000 (#716); a
  program's own mount point under the read-only `/mnt` did not exist,
  now generated by `mntgen` (#714); a full Ethernet transmit queue
  wedged IP instead of dropping (#692); a `chdir` in a sibling process
  could free `dot` under `pctl(NEWNS)` (#640); and `dossrv` glued a
  failed create's orphan long-name slots onto the next file's name
  (#673).

### Dis VM and JITs

- **A Limbo `int` is 32 bits on a 64-bit word**, in the interpreter and
  both JITs. `16r7FFFFFFF + 1` was positive, a `-1` assembled from bytes
  did not compare equal to `-1`, and shifts did not sign-extend; every
  int result is now stored sign-extended, and a string converted to an
  int saturates at the int's own range (#683) instead of carrying a
  64-bit `long` into the slot.
- **Hosted arm64 no longer leaks every type's compiled code** (#646,
  #649): about 52 KB per command run, 52 MB per thousand, now zero. The
  amd64 JIT stored `movw` results sign-extended and truncated 64-bit
  words; fixed and verified on x86-64. Hosted amd64 now also reuses a
  freed type's compiled code instead of growing its slab by about
  1.5 KB per command (#706).
- **A compiled module's code is no longer unmapped under its own
  return** (#718), on every JIT. When a module's last reference went
  while a call into it was running, as a server does with modules it
  unloads, the return punted to `OP(ret)`, which unloaded and unmapped
  the module and then returned into unmapped memory.
- **arm64 JIT returns within a module inline** (#689), as amd64 does,
  instead of punting to the interpreter's `OP(ret)`: recursive code is
  2-6x faster on the 3B+ (jitbench v2 7,354 to 2,607 ms).
- **The arm64 JIT hands off to the interpreter for a callee that is
  not compiled** (#687). A compiled module calling an interpreted one
  -- the JIT switched off at run time, or a module built with `limbo
  -C` -- branched into the callee's bytecode as if it were code: a
  kernel panic on the board, a fault in the hosted emulator. Found by
  the JIT benchmark's interpreter runs on the 3B+; amd64 was already
  right. A regression test runs both directions, hosted and on the
  Pi 3 kernel under QEMU.
- `memfs`: a read past the end of a file returns nothing instead of
  killing the server (found by the soak, #641).
- A Prog whose module is not linked yet has `R.M` nil, not only `H`;
  the #635 diagnostics read through it, which faulted the first Dis
  program on the RISC-V kernel (#718).

### Security

- **The TLS client authenticates servers, and fails closed** (#693).
  Any one of these let a network attacker impersonate any HTTPS server
  to programs using `tls` or `webclient`: X.509 chains did not have to
  reach a trust anchor (a self-signed certificate verified against
  itself, and an unknown issuer was accepted); TLS 1.3 did not require
  Certificate and CertificateVerify; TLS 1.2 skipped the
  ServerKeyExchange signature when absent or not RSA; the hostname check
  soft-failed when an extension did not parse; and PKCS#1 v1.5 was
  verified by suffix match. A connection that cannot be authenticated
  is now refused.

### Other fixes

- `awk`: `$0` is kept verbatim (it was rebuilt with OFS, losing tabs),
  `NF = n` no longer clobbers `$1`, regex literals understand `\t`,
  `\n` and `\r`, and `break`/`continue` work in loops (#694).
- `lucitheme`: a colour whose red channel is `>= 0x80` is no longer
  taken for a parse failure, so light themes such as Halo apply to the
  desktop's own chrome (#717).

### Tests

- `tests/host/baremetal_test.sh` across the three arm64 machines under
  QEMU, and `tests/host/baremetal_riscv64_test.sh` for RISC-V, run by CI
  on every change; hosted riscv64 is built and tested under
  `qemu-riscv64`.
- `tests/acceptance/`: batteries run from a Linux tester against a
  board -- Ethernet after RFC 2544, Bluetooth after the SIG PTS cases,
  GPIO on a loopback jig, and the card's contents against the build --
  with the soak and bench tools beside them.
- `tests/intsem_test.b` pins the 32-bit int semantics under both
  engines; `tests/host/arm64_jit_typecode_leak_test.sh` pins the leak.
- `tests/jit_unload_test.b` reproduces the unmapped-return crash
  deterministically; `tests/jit_fault_test.b` covers faults raised from
  compiled code; `tests/host/dossrv_lfn_test.sh` covers long names.

### Documentation

- `docs/BAREMETAL-PORTING-LESSONS.md`, written for any port; the
  bare-metal manual and board contract; `os/bcm2837/README.md`, the
  port's working notes; man pages for the native devices, `osinit(8)`
  and `mkcard(10.1)`. 9front is credited for the drivers taken from it.
- The JIT benchmarks on bare metal, at 1400 MHz and against the hosted
  emulator on the same board (#690, #696, #712); what the firmware
  leaves for the OS in the porting lessons (#697); `os/riscv64/README.md`
  and `os/bcm2711/README.md` for the boards not yet run.

### Known limitations

- At gigabit, a 60 KB IP burst overruns the LAN7515's 12 KB FIFO unless
  the switch honours pause; it passes at 100 Mb/s (#633).
- Empty hub ports report phantom attaches under load (#644): noisy on
  the console, harmless.
- The Pi 4 and RISC-V ports are QEMU-only.

### The soak

The 48-hour soak ran on the 2026-09-23 Pi 3 kernel (09-21 13:13 to
09-23 13:59: 0 panics, 0 reboots, 290/290 inbound pushes at a mean
144.7 Mbit/s, batteries passed twice, no memory growth unaccounted for).
The kernel in this release is not byte-identical to it: #691, #705,
#707, #714, #715, #716 and #718 all change it. Each ran on the board
or under QEMU as its PR records; the full 48 hours was not re-run on
this build.

### Release artifacts

The hosted archives, as before; there is no riscv64 archive yet. The
release job does not build a bare-metal kernel or card image; build them from the tag with
`tests/host/baremetal_test.sh` (see the bare-metal manual).

## [0.4.1] - 2026-09-17

Security patch release. Three containment fixes from the external
escape-room campaign (`infernode-os/infernode-escape-room`), found after 0.4.0
was cut, and a wallet change that operators need to know about.

### Security

- **Tool metadata sealed before `/tmp`** — `tools9p` restricted
  `/tmp/veltro/.ns` after the worker's `/tmp` had already been replaced, which
  recreated `/tmp/.veltro-ns` inside the model-visible view. A single `list`
  showed the shadow tree, and concurrent calls exposed live worker directory
  names. The 0.4.0 entry for #600 said the shadow tree was no longer visible;
  through `tools9p` it still was. Shadow-backed restriction now completes
  before the final `/tmp` replacement, and model-facing calls wait for the
  trusted startup manifest probe (#619, INFR-470).
- **Tool workers get a fresh environment group** — Inferno lets a process name
  its own `#e` device even under `NODEVS`, so a worker that inherited the
  launcher's environment could read it by spelling `/env` as `#e`,
  bypassing the narrowed view. Every tool worker now starts with `NEWENV` and
  carries only `VELTRO_SESSION` (#618, INFR-480).
- **9P directory stat entries bounded** — `statcheck` advanced by an untrusted
  string length without checking it against the bytes returned, so a malformed
  directory entry could read past its buffer and fault the emulator. Each
  entry is now validated against the remaining span before any field is
  decoded, with an ASan/UBSan guard-page regression (#617, INFR-479).

### Wallet

- **Agent payments are proposal-only** — trusted approval is mandatory for
  every `pay` and x402 authorization. **`requireapproval off` is now
  rejected**: it turned the same agent-visible files into immediate spending
  without changing the agent's namespace or its `nsaudit` report.
  `requireapproval on` is accepted as a no-op. `wallet` and `payfetch` are
  classified as `proposes_payment`, and the caller-asserted `walletbudget`
  audit metadata is removed; any future direct-spend authority fails closed
  without capability-bound enforcement evidence (#627, INFR-488).
- `nsaudit` models `/mnt/msg/draft` as an immutable proposal rather than a
  durable mutation, and the messaging profile grants a real `write` tool
  (#625).

### Build & CI

- Runtime namespace residue under the repo root and host-tool Python bytecode
  are ignored (#611).
- OSSF Scorecard reads branch protection with the default token instead of an
  expired PAT (#607).
- GitHub Sponsors enabled (#628). Dependency bumps (#590, #612, #613).

## [0.4.0] - 2026-09-12

### Runtime tree & build

- **`dis/` is a build product and is no longer tracked** — compiled Dis
  bytecode is untracked, exactly like `emu/*/o.emu`. A fresh clone builds its
  runtime in about 20 seconds, and `hooks/install.sh` installs a `post-merge`
  rebuild. What the build must *produce* is tracked instead, as
  `tools/dis-manifest.txt`, gated by `tools/verify-dis-build.sh` in CI and in
  every release job. Tracking the bytecode had let the tree drift from the
  source that produced it in every way it could: `appl/cmd/git` had not
  compiled since 2026-07-02, `dis/acme.dis` shipped font paths the source
  abandoned five months earlier, 45 modules shipped that no mkfile ever
  compiled, and programs shipped whose sources had been deleted. Releases
  still ship a runnable tree — the packaging job builds it before staging
  (#559).
- **Go-on-Dis removed** — the experimental Go-to-Dis work is gone from the
  tree (#566).
- `mk emuinstall` repaired on a clean clone (#507). Android builds target
  API 36 (Android 16) for Play compliance (#581).

### Agent provenance & audit (INFR-355)

- **Trajectory sealing** — the Veltro agent stack seals its full trajectory
  (prompts, LLM output, tool calls, capability grants, namespace-restriction
  manifests) into the tamper-evident audit chain; bulky payloads are
  content-addressed into a `ventisrv(8)` store with the SHA-256 pin sealed
  under the chain (`auditprov(2)`) (#508).

### Persistence

- **Whole-`/usr` durability** — all of `/usr` is bound from the durable
  overlay; system updates never touch user state. `newuser(8)` creates
  accounts from the skeleton; `snapd(8)` takes daily deduplicated venti
  snapshots of `/usr` (one text line per snapshot: timestamp + `vac:` score,
  restorable with `vacfs(4)`). Settings gains Auditing and Snapshots panels
  (#511).

### Wallet

- **Out of experimental** — the Ethereum wallet is production-supported:
  budgets hard-capped on every path, trusted approval on payments, agents
  see proposal files only (#512, with the raw signing surface removed in
  #488 and proposal validation in #487).

### LLM backends

- **codex-gate** — OpenAI models served through the ChatGPT Codex CLI on the
  host's own subscription login, as a sibling of claude-gate: an
  OpenAI-compatible localhost gateway on `:11436`, `backend=codex` in ndb, a
  "Codex CLI" choice in the Settings LLM panel, and `llmctl set|health codex`.
  The tool bridge is prompt-level (`codex exec --output-schema`) rather than
  MCP, so the gate is stateless — see `docs/CODEX-GATE.md`.
- **First-run wizard offers the CLI gateways** — "Claude CLI" and "Codex CLI"
  join "Remote API" / "Local model" / "Remote 9P" in the first-run LLM setup
  dialogue, so a user who already pays for one of those subscriptions isn't
  steered to paste an API key. Desktop dialogue buttons now wrap onto further
  rows instead of silently dropping the ones that don't fit on one line.
- **codex-gate hardening** — the OAuth gateway uses backend defaults instead
  of forwarding llmsrv's Anthropic default model to an OpenAI-compatible
  backend, and requires a verified ChatGPT login before reporting readiness
  (#529). The gateway is pinned and the CLI's native shell disabled, so Codex
  requests Veltro tools rather than inspecting the gateway filesystem (#539).
  Quota control is returned to callers (#597), and transient model-capacity
  failures are classified as structured retryable errors instead of assistant
  content — the classifier deliberately narrow, so model prose cannot
  authenticate a retry (#603).

### GUI & video

- **Live video panes** — vid9p live-feed ring, Matrix video panes, colour
  fixes; trfs fd-handling fixes (#510).

### Security

Namespace hardening continued through a sustained internal red-team campaign.
This cycle the mounts and the pathname stack themselves were the focus, rather
than the control grammars above them.

- **Read-only mounts genuinely attenuate** — a new `MREADONLY` mount flag
  attenuates Veltro's code, library, metadata, and source views. The
  restriction survives rebinds and 9P exports, writable protocol filters stay
  distinct, and intentional nested writable mounts are retained. This closes a
  campaign path that overwrote `sh.dis`, and a remote-export laundering
  regression (#586, INFR-453).
- **Mount boundaries survive parent walks** — completing the Fourth Edition
  pathname-stack port in the emulator: final-element mount crossings performed
  by `open` are recorded, the child slot is discarded before undoing a parent
  mount, and reference ownership is preserved across `Cname` copy-on-write.
  The private `.veltro-ns` shadow tree is no longer visible (#600, INFR-470).
- **A namespace traversal escape closed**, with delegation evidence hardened
  in the same pass (#537).
- **Runtime profiles are materialized and audited** rather than assembled ad
  hoc, and campaign-only runtime hooks and duplicate profiles are gone from
  the product path (#591, #592, #596, #598 — INFR-456, INFR-466).
- **No hidden audit fallback during namespace construction** — by the time
  `restrictns` emits its audit record, `/mnt` has already been narrowed, so
  reaching for a hidden or stale 9P audit mount could block construction
  outright. The fallback is refused there rather than attempted (#593,
  INFR-459).
- **Copy-on-write overlays keyed by path** — a delegated agent holding a
  writable grant could create a file that `list` and `read` saw but `exec`
  reported absent at the same absolute path, because the overlay directory was
  keyed by a path's position in the invocation list rather than by the path.
  The capability is now composable across tools (#571, INFR-435).
- **Campaign metadata fails closed** — `NODEVS` and wallet-budget
  declarations are validated semantically, and their validity is reported in
  `nsaudit` machine output (#580 — INFR-440, INFR-441, INFR-442).
- **A stalled tool call can no longer silence the audit trail** — a hung 9P
  tool request blocked lucibridge's activity loop indefinitely, so `toolres`
  and `agentdone` records were never written. The existing 60-second Veltro
  tool bound now applies there too (#599).
- **Truthful grantable tool catalogue** — delegation planning context is
  derived from the live `tools9p` budget instead of a hand-maintained persona
  list, preserving namespace attenuation (#544, INFR-393).
- Further fixes: delegated message draft writes preserved (#546), concurrent
  task provisioning made atomic (#547), delayed tasks kept observable (#542,
  INFR-362).
- Earlier in the cycle, ~40 further namespace-hardening fixes: control-grammar
  tightening (wallet #499, wiki #500, msg #496), path-delimiter rejection
  across write/editor/wiki (#493–#495), luciuisrv control metadata (#502),
  matrix composition grants (#501), provisioning validation (#503),
  failed-tool-mutation reporting (#505).

### Emulator, JIT & shell reliability

- **JIT `typecom` slab exhaustion** — scratch overflow and incorrect rollover
  of an exhausted slab, both under sustained load (#561, #570, INFR-421).
- **Linux memory faults report PC and symbol** rather than an address alone
  (#558), and `devfs` directory reads can no longer fault on an
  uninitialised `Fsinfo` (#557).
- **The pthread process leader stays alive**, so a Linux emulator no longer
  strands children when the leader exits (#582), plus further Linux
  concurrency fixes (#602, INFR-601).
- `sh` raises instead of panicking when the wait file is unavailable (#572,
  INFR-436). `llmsrv` cancels flushed async replies safely (#541).

### Testing & compliance

- **The escape-room harness moved out of the product tree**, with a CI
  ring-fence that fails the release stage if harness material reappears in it
  (#585).
- Source-aware `nsaudit` campaign (#555) and dynamic red-team qualification
  (#562). Grind fixes: evidence preserved on scorer errors (#569),
  qualification effects required (#567), scenario canary post-state preserved
  (#545), fail-closed on live child tasks (#543), dynamic child activities
  reconciled (#548), campaigns resume after quota pauses (#576, INFR-437).
- Compliance evidence scorecard re-rolled and stale AU residuals corrected
  (#532). Rooted capability delegation proposed for review (#535).

## [0.3.6] - 2026-07-20

- **claude-gate** — Anthropic models served through the Claude Code CLI as an
  LLM backend, with Settings LLM-panel fixes (#440); factotum API-key
  provisioning generalized beyond one vendor (#321 lineage) and tools read
  secrets from factotum — no plaintext key files (#322).
- **Video over 9P end to end** — Matrix player, Tk design-system engine work
  (#453); click-target alignment and Tk-button picker (#454).
- **Agent-facing module discovery** — man pages, `whatis` index, and a Veltro
  tool for Matrix module discovery (#408).
- **Branding** — themed login screen (#448) and About box / desktop title
  from data files (#450).
- **Shell fix** — initialise before `waitfd()` in `Context.new`; rebuild
  stale `sh.m` consumers (#455).
- Continued namespace hardening (#410–#443): fixed-service namespaces
  reserved (#418, #419), app-IPC grant scoping (#417–#424), manifest hiding
  (#414), MCP tool-name/schema validation (#397, #471 lineage), exec
  write-containment (#374).

## [0.3.5] - 2026-07-13

The bulk of a sustained agent-security campaign (~60 PRs), plus the audit
hardening pass.

- **Audit-log hardening** — strict verification (`-k` makes signatures
  mandatory), off-host anchoring (`-a`), self-driving signed checkpoint
  cadence, fail-closed emitters (#389); checkpoint signing moved into
  factotum (ML-DSA-87) so `auditfs` never holds the key (INFR-356).
- **nsaudit as a CI gate** — namespace-configuration audit runs on every PR
  against committed fixtures (#391), with the internal configuration audit
  tool underneath (#310).
- **mcpdeny** — drop named MCP tools from a child's grant (INFR-258, #369).
- **Failed-attempt lockout** — AC-7/FIA_AFL.1 in `secstored`; compliance
  docs reorganized into an evidence register (#368, #373).
- **Tk reintegration** — libtk built for macOS release jobs (#409).
- Dozens of grant-model fixes: raw service grants denied (factotum #462,
  auditfs #465, gpu #467, video #461, calendar #463, key registry #469,
  llmctl #464), delegated control paths blocked (#392–#394), egress
  flagging for MCP mounts and LLM paths (#395, #396), namespace grant
  delimiter/descendant rejection (#386, #406, #426), mail-send grants
  flagged (#383).

## [0.3.4] - 2026-07-02

- **Send is a capability** — `/mnt/msg` send split from read; authorise-to-send
  with one-shot approval for replies (INFR-367, #337, #343).
- **Per-invocation attenuation** — each tool call runs in a namespace
  containing only the invoked tool (#338).
- **Workspace isolation** — activity workspaces and child capabilities
  isolated (#342); delegated task metadata isolated (#340).
- **Charon SSRF** — private-network fetches blocked (#344).

## [0.3.3] - 2026-06-30

- **Headless macOS arm64 release artifact** (#335).
- Confused-deputy fixes: editor paths (#333), browser local files (#334);
  agent write-capability enforcement (#331).

## [0.3.2] - 2026-06-30

- **`/mnt` by capability only** — mounts are granted, never inherited by
  existence (INFR-366, #329).
- **Delegation reliability** — lost-task race in parallel delegation fixed
  (INFR-362, #320); task agents auto-start reliably, low agentic
  temperature (#317).
- **Fail closed** — namespace setup errors abort the agent (#319); auth
  transport algorithm policy enforced (#318), noncanonical frames rejected
  (#315), client identity preserved after `listen` (#313).

## [0.3.1] - 2026-06-29

Security-hardening point release, with cross-platform YubiKey/FIDO2 second-factor
authentication.

### Second-factor auth (`/dev/2fa`)

- **Cross-platform FIDO2** — the `#F` (`/dev/2fa`) device, previously macOS-only,
  is now built into the Linux and Windows emulators, and into headless Linux
  builds (#305, #307).
- **YubiKey 2FA fixes** — namespace ACL enforcement, Dis-parser hardening,
  Windows Hello (winhello) integration, and clearer error surfacing (#309).
- **Enrollment persistence** — `~/.infernode` overlays are persisted so a
  YubiKey 2FA enrollment survives an emulator restart (#311).

### Cryptography & Dis VM hardening

- **SHA-384 auth-cert hashing** for ML-DSA-87 signing (CNSA 2.0) (#304).
- **Dis parser hardening** — guard the Dis bytecode parser against malformed
  modules and pointer corruption (#306), with additional module-parse
  hardening in `libinterp` (#302).

### Security

- **Pre-authentication bounds** — pre-auth handshake work is time- and
  concurrency-bounded (#312).
- **Transport** — remove weak transport algorithms and close devfs races (#301).
- **Memory safety** — resolve CodeQL memory-safety findings (#300).
- **Internal configuration audit** added (#310).

### Release engineering

- Fix FIDO2 packaging in the release pipeline: the Windows `vcpkg` port is
  `libfido2` (not `fido2`) and that install step is now genuinely best-effort;
  the macOS GUI/headless emulators link `libfido2` and `opus` reliably even when
  `pkg-config` cannot resolve Homebrew's keg-only `openssl@3`.

## [0.3.0] - 2026-06-28

### Breaking & behavior changes

- **Namespace move `/n/*` → `/mnt/*`** — `mail9p` (`/mnt/mail`), `calendar9p`
  (`/mnt/cal`), and `msg9p` (`/mnt/msg`). Scripts, shell profiles, or configs
  referencing the old `/n/` paths must be updated.
- **CNSA 2.0 strict mode** (opt-in via `/env/cnsamode`, off by default) —
  ML-KEM-768 → ML-KEM-1024 and ed25519 → ML-DSA-87 for the native STS
  handshake, TLS, and the auth-domain CA. No silent downgrade; enabling it
  requires upgrading all nodes in a fleet together.
- **2FA accounts** (opt-in) — a YubiKey-enrolled account cannot be unlocked by
  a password alone; it requires the hardware key (touch, and a FIDO PIN at
  AAL3) or the recovery passphrase. Legacy password-only accounts are unchanged.

### Highlights

- **YubiKey-gated secstore login** with UV/AAL3, backup key, and a Settings GUI
  Security panel.
- **Hybrid TLS** — `SecP384r1MLKEM1024` CNSA hybrid key exchange, with P-384
  (secp384r1) ECDH primitives and Keyring builtins.
- **Tamper-evident audit log** (`/mnt/audit`) with factotum-held ML-DSA-87
  signing and a compliance evidence program.
- **Pre-auth hardening** — time-bounded handshakes with a per-listener
  concurrent-auth cap; weak/malformed v2 DH shares are rejected
  (INFR-321/322/323).
- **Veltro agent** — research agent and launchable personas, deterministic
  intent classifier for persona routing, agent-loop read-cache, and per-session
  model override (`veltro -m <model>`).
- **SBOM** — CI-verifiable SPDX SBOM generated and shipped with releases.

## [0.2] - 2026-05-11

### Windows AMD64 release

First official Windows AMD64 distribution. Feature parity with macOS and Linux
modulo the items called out under "Known limitations" below.

- **Windows JIT compiler** — AMD64 JIT with 5.7× speedup (181/181 correctness tests pass).
- **Host filesystem mounting** — Drive letters mounted at `/n/C`, `/n/D`, etc. via the `#U` device; `~/.infernode` overlay for persistent user state.
- **Secstore + factotum** — Encrypted key persistence with PAK authentication; Lucifer login screen unlocks it interactively.
- **SDL3 GUI** — Lucia, Xenith, and the window manager render with D3D acceleration.
- **Bundled-app UX** — `InferNode.exe` is a Windows-subsystem launcher that double-clicks to a full-screen Lucifer session (uses screen-resolution sizing on launch).
- **CSPRNG** — Secure random via `BCryptGenRandom` (replaces the POSIX `/dev/urandom` path).
- **Build system** — Complete MSVC build via `build-windows-amd64.ps1` (libs + headless emu), `build-windows-sdl3.ps1` (GUI emu), and `emu/Nt/build-launcher.ps1`. Crypto libraries (secp256k1, keccak256, securezero) fully linked.
- **Cross-platform unification** — Windows launcher invokes the same `/lib/lucifer/boot.sh` as macOS and Linux; legacy `dis/lucifer-start.sh` and `Lucia.bat` removed.
- **Dev bundle** — `build-dev-bundle.ps1` mirrors the macOS `build-dev-bundle.sh` for local packaging tests without going through CI.
- **CI/CD** — Windows AMD64 build and test job runs alongside macOS/Linux on every PR; release job produces a signed bundle on tag push.

### Known limitations on Windows

- **JIT GUI race** (latent) — Some long-running JIT GUI sessions can crash with `STATUS_BAD_FUNCTION_TABLE` because the JIT does not yet register Windows SEH unwind data for its executable pages. Mitigation in place; proper fix tracked in INFR-46.
- **MSIX packaging** — Deferred to a follow-up release (INFR-48). For 0.2 the artefact is a portable zip.
- **Stdio-redirected boot** — `o.emu.exe` started with `Start-Process -RedirectStandardOutput` crashes in the secstore PAK dial step. Interactive double-click is unaffected. Tracked in INFR-50; matters mainly for headless smoke tests.

### Platforms

| Platform | Architecture | GUI | JIT |
|----------|-------------|-----|-----|
| macOS | ARM64 (Apple Silicon) | SDL3 | 9.6x |
| Linux | AMD64 | Headless / SDL3 | 14.2x |
| Linux | ARM64 | Headless / SDL3 | 8.3x |
| Windows | AMD64 | SDL3 | 5.7x |

## [0.1] - 2026-04-09

First public release of InferNode, a 64-bit fork of Inferno OS for AI agents.

### Highlights

- **Veltro AI Agent** — built-in conversational agent with tool use, delegation,
  and namespace-isolated sub-agents
- **Capability-based namespace isolation** — each agent sees only explicitly
  granted resources; formally verified with TLA+, SPIN, and CBMC
- **Post-quantum cryptography** — preliminary ML-KEM (FIPS 203) and ML-DSA
  (FIPS 204) implementations
- **ARM64 JIT compiler** — native JIT for Apple Silicon and Linux ARM64
  (e.g. NVIDIA Jetson)
- **Xenith text environment** — Acme-inspired editor with markdown, PDF,
  image, and Mermaid rendering
- **Lucifer GUI** — presentation zone with app hosting, tab management, and
  context/namespace browser
- **Secstore persistence** — encrypted key storage with PAK authentication
- **Ollama/OpenAI-compatible backend** — local LLM support alongside
  Anthropic API
- **9P everywhere** — LLM, speech, tools, wallet, and UI all exposed as
  9P filesystems

### Platforms

| Platform | Architecture | GUI |
|----------|-------------|-----|
| macOS | ARM64 (Apple Silicon) | SDL3 |
| Linux | AMD64 | Headless (SDL3 optional via build script) |
| Linux | ARM64 | Headless (SDL3 optional via build script) |

### Known Issues

- Secstore key loading can intermittently fail on cold boot due to trfs
  cache timing; a warmup workaround is in place
- Models that do not support tool use (e.g. llama2) return empty responses;
  use a tool-capable model (llama3.2, qwen2.5, mistral, etc.)
- The presentation rendering architecture is tightly coupled to the lucipres
  window; a refactor to a separate wmclient app is planned (see
  docs/TODO-LUCIPRES-ARCHITECTURE.md)

# Charon engine: hand-off

State of the new Charon web engine as of 2026-10-02 (second session, branch
`claude/practical-faraday-whwxhp`, continuing `claude/vibrant-hamilton-kusgqw`),
written so a fresh session can carry on without the previous one's context.  Read `docs/CHARON-ENGINE.md` for the design and
`tools/ref/README.md` for the measuring tools; this file is the working
state: what is done, how it is judged, how to set up, what is next, and
what bit last time.

Pull request: https://github.com/infernode-os/infernode/pull/754 (pushing to
the branch updates it).

## Where it stands

The engine (`appl/lib/web/`: dom, html, css, style, fonts, layout, page,
browser, charonfs) renders real pages, and is judged against references,
not by eye:

| Measure | Result |
|---|---|
| WPT CSS reftests (18 directories, 12,642 judged) | **53.8%** (6,797 passing), from 50.0% at this session's start and 37.8% at the first run ever; `css-grid/grid-lanes` 465 of 891 (101 before `display: grid-lanes` existed) |
| Acid2 (`test.html#top`) | renders correctly; ~1,400 pixels differ from Chromium, all anti-aliasing |
| pypi.org home page vs Chromium (scripts off) | ~7% of pixels differ, from 47.8%; layout, fonts, logo, icons match |
| Unit tests | web_html 5, web_css 6, web_style 16, web_browser 9, web_fonts 10, bidi 3, brotli 3: all pass |
| Render fixtures (`tools/charon-wpt.sh`) | 69/69 (one intermittent "no image" is the emu SEGV below) |

The WPT count is strict: any test with a `<script>` is reported as
needs-js (1,268 of them) even if its pixels match, and a pass whose
rendering is one flat colour is flagged `blank`.  The full per-test
results of the last run are in `tools/ref/baseline/wpt-results.txt.gz`
(gunzip it and use it as the "before" for `tools/ref/wptcmp.py`).  The
WPT checkout was `web-platform-tests/wpt` at
`89c9ebab4fef9e79de92421dd637f00fa4922359` (2026-10-02); a newer checkout
will move the numbers a little.

### Commits on the branch (newest first)

The third and fourth sessions (same branch) took the hand-off list in
order: the remaining review findings, then the live-site bugs, then bidi
edges, shaping, the regressions each WPT run turned up, and the largest
failing WPT directory (`css-grid/grid-lanes`, 891 tests).

- `9287212` **Grid lanes (Grid 3), absolutes in grid areas, auto-fit.**
  `display: grid-lanes`/`inline-grid-lanes` (`laylanes`): items stack
  into the shortest lane, with `grid-lanes-direction` (row or column,
  fill-reverse, track-reverse), `grid-lanes-pack: dense`,
  `flow-tolerance`, the auto-placement cursor (moved only by auto-placed
  items), definite lines, spans, `order`; track sizing counts an
  unplaced item at every start it could have; auto-repeats of intrinsic
  lanes are counted by the items' smallest max-content contribution;
  the stacking range aligned as a whole, items before room aligned or
  stretched into it, `flow-start`/`flow-end`; intrinsic widths for both
  directions (row lanes by a placement pass).  Shared with grid: auto-fit
  tracks collapse; an item definite in the flow axis only is placed in
  the first free cells of its row; spanning items' contributions are
  planned per span group; a spanning item's intrinsic contribution is
  spread over the non-fixed columns; column flow without a template
  places items down the rows for the intrinsic width; percentage rows in
  a container they size are resolved in a second pass.  Absolutely
  positioned children of grids get the grid area their lines name as
  containing block (explicit lines only) and are aligned in it by
  justify-self/align-self (safe keeps an overflowing box at the
  start).  Also keyword widths as contributions, BFC roots beside
  floats (start margin and border box must fit; tables never narrower
  than their minimum), a float before a line's content keeping the
  indent, column flex height mattering to its content, rtl mark offsets,
  auto tracks stretching only under normal/stretch.
- `90571ce`…`ee9fc95` **GPOS, ligatures across edges, 2D transforms, grids.**
  GPOS pair kerning (most web fonts have no legacy `kern` table) and
  mark-to-base positioning; ligatures that span an inline box's edge
  (the shaper reports each glyph's character span, the seam moves the
  characters into one run); `transform` with rotate, scale, skew and
  matrix about `transform-origin` (the box is painted into an image and
  resampled); a grid container's intrinsic width by column; grid areas
  definite for percentage heights; a table's extra height to its auto
  rows; a BFC root moved below floats it cannot fit beside; stretched
  flex and grid containers laid out again at their definite height;
  HTML's case-insensitive attribute values; text/plain charsets;
  Chromium's scrollbars hidden in the reference tools.
- `210f3f7`…`2eb0047` **Shaping, floats, backgrounds, flex.**
  OpenType GSUB (ligatures through liga/clig/rlig, cursive joining
  through init/medi/fina/isol from `lib/bidi/joining`), right-to-left
  runs shaped in logical order and drawn from the right, joining across
  inline box edges of no width (zero width joiners at the seam).  A
  float met mid-line goes on that line when it fits (docs.python.org's
  search form).  Column flex items: content height as if `height` were
  auto, automatic minimum, percentage sizes only against a definite
  container (go.dev's `flex: 1` main was 0 tall).  A single flex line
  fills a min-height container.  Inline box edges stay physical; isolate
  controls take part in line reordering; inside list markers are
  isolates; tab stops; justification only after the last tab.  The
  root's background covers the canvas; gradients take size, position,
  repeat (including `round`) and px stops; the background shorthand had
  its layers and values reversed.  `transform: translate()` (other
  functions only make a stacking context).  Intrinsic widths: a box's
  own size ignores its min/max-width, its contribution applies them,
  negative margins count, collapsible spaces at line ends do not.
  Inline-level absolutes get an inline static position.  `revert`,
  `safe`, `lh`.  `tools/ref` hides Chromium's scrollbars.

This session started with a code review of the whole engine (three
reviewers, one per area: html/dom, css/style, layout/fonts), verified
each finding against the code, and fixed what mattered; every fix has
a fixture or unit test that fails on the previous engine.

- `14fc892`…`b6c0356` **Bidirectional text.**  `lib/bidi` (module
  `bidi.m`, `/dis/lib/bidi.dis`) is UAX #9 complete, tables generated
  from Unicode 18 by `tools/bidi/gen.py`, tested against every 25th
  case of Unicode's `BidiCharacterTest.txt` (the whole file of 91,707
  passes).  The engine resolves each block's inline content as a
  paragraph (forced breaks split paragraphs; plaintext takes each
  paragraph's direction from its first strong character), splits words
  at level changes, reorders each line's text, atomic and inline-box
  edges, draws right-to-left runs reversed with mirrored brackets.
  `unicode-bidi` is a property; `dir`, `bdo`, `bdi` get theirs.  Not
  shaping (Arabic letters are drawn unjoined).
- `9e35a95` Nested documents: `<iframe>` (src, srcdoc) and `<object>`
  documents are the pipeline run again at the frame's size, painted
  into an image (no scrolling or clicking inside yet; three levels
  deep).  `position: relative` on inlines.  `safe` alignment; `revert`.
  Text fields as wide as `size` says; checkboxes without the UA
  border; min/max-width bound intrinsic widths; `<center>` centres
  blocks; `border=0`; a cell's content height.
- `4e4db7b` Encodings (undeclared pages sniffed as UTF-8 or
  windows-1252, UTF-16, more labels), `<meta http-equiv=refresh>`,
  srcset and `<picture>`, overflow clipping of layers through
  non-context positioned boxes, document-order painting of equal
  z-index layers, aligned subtrees for `vertical-align: top/bottom`,
  flex `wrap-reverse`, `tab-size` lengths, per-document media index,
  XML parser depth, `Doc.insert` refusing cycles.
- `6ee8c32` Stretched flex and grid items get a definite height for
  their content (percentages, positioned descendants); absolute boxes
  inside positioned inlines are laid out; `z-index: auto` boxes are no
  longer stacking contexts; intrinsic widths cached per layout (nested
  shrink-to-fit was exponential).
- `dda0645` Reversed flex lines, `vertical-align` moving glyphs, replaced
  elements keeping their ratio under `max-width`, nowrap spaces in
  min-content, grid column-flow hang, bounded grid line numbers and
  `repeat()` counts, font fallback nil dereference, web-font cache that
  never hit, WOFF allocation bounds, five-channel colour crash,
  background layer lists, `:has(.a .b)`, `[lang|=en]`, `@starting-style`
  dropped, `@scope` scoped.
- `4ad5fcb` Acid2; Brotli, WOFF2, OpenType-CFF fonts; Appendix E paint
  order; clearance and margin collapsing; fixed positioning and
  backgrounds; diagonal border joins; `<object>` fallback; kerning;
  SVG images at display size; input placeholders; CR/FF hangs.
- `3eaa1c5` @font-face (TTF/WOFF), background images, ex/ch units,
  anonymous table objects, phantom lines, Ahem shipped.
- `1d9620f` The reference tools (`tools/ref`), XHTML parsing.
- Earlier: the engine milestones M1–M8b (see `docs/CHARON-ENGINE.md`).

## Setting up a new container

The emulator and all bytecode are build products.  From the repo root:

```sh
./makemk.sh                      # mk, first time
./build-linux-amd64.sh           # or the platform's build script: libs, limbo, emu
export ROOT=$PWD PATH=$PWD/Linux/amd64/bin:$PATH
for d in appl appl/mpeg appl/veltro tests; do (cd $d && mk install); done
tools/verify-dis-build.sh        # all 1032 modules in tools/dis-manifest.txt
```

Reference side (host):

- Node with Playwright and a Chromium (`tools/ref/shot.js`, `boxes.js`);
  set `NODE_PATH=$(npm root -g)` if Playwright is a global install.
  `CHROMIUM_PATH` overrides the browser.
- Python 3 with `numpy`, `Pillow`; `fonttools` and `brotli` only to make
  new test fonts or Brotli vectors (`pip install fonttools brotli`).
- The WPT tree, sparse (about what was used here):

```sh
git clone --depth 1 --filter=blob:none --sparse https://github.com/web-platform-tests/wpt.git
cd wpt; git sparse-checkout set acid fonts images resources/testharness.css css/reference css/support \
  css/CSS2 css/css-backgrounds css/css-box css/css-cascade css/css-color css/css-display \
  css/css-flexbox css/css-fonts css/css-grid css/css-lists css/css-nesting css/css-position \
  css/css-sizing css/css-tables css/css-text css/css-values css/css-variables css/selectors
```

Servers that the tools expect (start each with `setsid nohup ... &`, or
they die with the shell that started them):

- `tools/ref/wptserve.py -p 8790 WPT` for looking at tests by hand
  (wptrun.py starts its own on a free port).
- `tools/ref/mirror.py -p 8780` for live sites, fetched on the host and
  cached in `tmp/mirror`; URLs are `http://127.0.0.1:8780/<host>/<path>`.

## How work is judged (keep doing this)

1. **Baseline first.**  `tools/ref/wptrun.py -j 3 -o $PWD/tmp/wpt WPT css/CSS2 css/css-flexbox ...`
   takes about 12 minutes for all 18 directories.  Keep the
   `results.txt` of each run (`cp tmp/wpt/results.txt tmp/wpt-rN.txt`).
2. **After a change**, run again and `tools/ref/wptcmp.py before after`.
   Look at every regression before committing.  Most "regressions" so far
   were false passes coming to light: test and reference both blank, both
   falling back to the same font, or both wrong the same way.  `wptcmp`
   marks those that were blank passes; for the rest, render the test with
   the old engine (`git stash` the engine, rebuild, run, `stash pop`,
   rebuild) or compare the test directly with Chromium (`boxdiff.py`).
3. **One test:** `tools/ref/wptdiff.py WPT path/to/test.html out.png`
   prints where test and reference differ and writes test | reference | diff.
4. **A page against Chromium:** `tools/ref/boxdiff.py URL` lists elements
   whose boxes differ, in document order; fix the first one, re-run.
   `tools/ref/compare.py -o DIR URL` gives pixel scores and a side-by-side.
5. **Acid2:** `tools/ref/acid2.py WPT` — should stay at ~1,400 pixels.
6. **Before committing:** the unit tests, `tools/charon-wpt.sh`,
   `tools/verify-dis-build.sh`.  Update `tools/dis-manifest.txt` with any
   module added.  A Limbo test runs in emu like this (emu does not exit on
   its own, hence the halt and the timeout):

```sh
for t in web_html web_css web_style web_browser web_fonts brotli; do
  setsid -w timeout 120 ./emu/Linux/o.emu -c1 -r$PWD /dis/sh.dis \
    -c "/tests/${t}_test.dis; echo halt > /dev/sysctl" 2>&1 | grep -v fsqid | tail -2
done
```

The reference Chromium is given Charon's fonts by `tools/ref/fonts.conf`
(generic families and Arial/Times/Courier → DejaVu), so text width
compares layout, not typeface choice.

## What is next

In rough order of payoff.

1. **Live sites.**  The network reaches Wikipedia, MDN, news.ycombinator.com,
   go.dev and docs.python.org from this container (github.com's HTML
   gives 403 to the mirror's fetch; gnu.org drops).  Scores at the end
   of this session (`compare.py`, share of pixels differing, exact and
   by 8px cell), with the first wrong box `boxdiff.py` reports:

   | Page | exact | layout | was (layout) | first wrong box now |
   |---|---|---|---|---|
   | news.ycombinator.com | 13.8% | 3.2% | 27.9% | — (glyph rasterisation only) |
   | pypi.org | 6.5% | 6.3% | 6.3% | — |
   | go.dev | 11.3% | 8.2% | 67.3% | `body` 4726px tall, Chromium 4526; the header nav 703px wide, Chromium 676 (icon button widths) |
   | developer.mozilla.org (CSS/display) | 10.1% | 12.7% | 12.7% | `mdn-placement-top` (custom element) has no box; inline `<svg>` paths have none (the svg itself draws, so this is boxdiff noise) |
   | en.wikipedia.org (Plan 9) | 13.4% | 14.2% | 15.4% | the dropdown panel is 423px tall, Chromium 427 (3px per list item) |
   | docs.python.org (library/os) | 17.9% | 18.1% | 36.9% | the "related" nav's long `li` still wraps to 5 lines, Chromium 3 (text 1px wider per word, it seems: measure with `boxes.js`) |

   The `<center>`, icon-font, flex-column, mid-line float and intrinsic
   space fixes all came from this list.  Take the pages top to bottom:
   the first wrong box per page has been the fastest way to real bugs.
2. **Review findings not yet fixed** (verified by reading, not yet
   done; the full lists are in the session's scratch notes, these are
   the ones that matter):
   - layout: `sizetracks` grows tracks proportionally rather than
     equally with freezing (§12.6); `spread()` can overflow `int` on huge
     tables; a ligature across an inline box's edge is drawn wholly in
     the first box's colour (its characters move there); mark-to-mark
     and cursive attachment (GPOS types 3 and 6) are not read, so
     stacked marks fall on the base; `tab-bidi-001`'s dagesh uses a
     fallback font with no anchors; trailing pre-wrap spaces before a forced break
     should hang conditionally (`hanging-whitespace-003`, tentative);
     textareas paint their background but not their text's layout
     (`textarea-pre-wrap-014`).
   - style: `revert-layer`; nested `@layer` order is flat; `var()`
     cycles fall through to the fallback; a `&` inside `:is()` in a
     nested rule; user origin folded into UA.
   - html: `canoncs` maps gbk/gb18030 to gb2312 and has no euc-kr or
     windows-125x beyond 1250–1252 (tables missing from `lib/convcs`);
     doctype system ids are dropped (html5lib fixtures with ids would
     fail); limited-quirks mode is not modelled.
   - page/browser: no HTTP cache in webfs, so every navigation
     refetches.
3. **Open regressions (tests that passed at the first run ever and fail
   now; 49 at the end of this session, 22 before it).**  Most are the
   grid-lanes directory's references changing from "nothing renders" to
   a real layout: 16 are subgrid (not implemented) inside or beside
   lanes, 11 are auto-repeats of intrinsic lanes (the count is the
   items' smallest max-content contribution, which fits most of the
   directory; no rule found fits `column-auto-repeat-auto-017` and
   `column-auto-repeat-max-content-005` both, and the container's
   Chromium has no grid-lanes to ask).  Also: `last baseline`
   self-alignment of absolutely positioned grid children (4), a fixed
   child of a grid whose containing block is not the grid, two BFC-root
   float cases (`adjoining-float-nested-forced-clearance-002`,
   `floats-wrap-bfc-with-margin-007`), `margin-trim`, the bidi box-model
   pair, the shaped-run rounding pair, and the variable-font, 2-pixel
   and tentative cases from before.  Each with its reason, as far as
   known: `tools/ref/baseline/open-regressions.txt`.
3. **Exposed gaps behind many failures:** vertical writing modes,
   variable-font instances, subgrid (the largest remaining grid-lanes
   bucket, and the `css-grid/subgrid` directory), `contain-intrinsic-size`,
   multi-column layout (the lanes baseline tests' references use it),
   `margin-trim`, scrolling and clicking inside frames, hit-testing of
   transformed boxes (they are drawn moved but clicked where they are in
   the flow), transformed boxes resampled nearest-neighbour (no
   anti-aliasing), translucent opacity on inline boxes (floats inside
   them paint at full opacity; opacity 0 is handled).  Bidi, `<iframe>`,
   GSUB and GPOS shaping, Arabic joining, ligatures across edges, 2D
   transforms, grid lanes (Grid 3), absolutes in grid areas and
   auto-fit collapsing are done (above); declarative shadow DOM is
   approximated (a `<template shadowrootmode>`'s content is shown in
   place, `<slot>`s are transparent).
4. **Sub-pixel layout.**  Layout positions are ints; Chromium uses 1/64 px.
   Many near-miss reftests (a few hundred pixels at glyph edges) come
   from this.  Large change; do it deliberately.
5. **Remaining plan milestones:** JavaScript (the seam is described in
   `CHARON-ENGINE.md`), M8–9 Tk chrome polish and making the new engine
   the default `charon`.

## Known bugs outside the engine

- **Emu start-up SEGV**, about 1 launch in 150 on Linux: `findmount` →
  `eqchantdqid` reading a freed `Mhead->from` during `emuinit`'s
  `kbind("#U/net", "/net", MAFTER)`.  Before any Limbo code runs.  It is
  what makes a fixture or WPT page occasionally report "no image" /
  "crash or hang"; `wptrun.py` now retries a failing page once and logs
  the emu output to `tmp/wpt/crashes.txt`.  A separate task was suggested
  for it; the full backtrace is in that task's description and
  reproduces with a launch loop.

## Map of what was added

| Where | What |
|---|---|
| `appl/lib/web/layout.b` | paint phases (`flowbgs`/`flowfloats`/`flowinline`), `collectlayers`/`floatlayers`, clearance and `topmargin`, `placefloat` band past the containing block, fixed paint (`scrolled`, `viewport`), `paintbg`, trapezoid borders (`trapside`), anonymous table objects (`tablekids`, `wrapruns`, `orphans`), `<object>` (`setobjects`) |
| `appl/lib/web/page.b` | `loadfonts` (@font-face, unicode-range), `loadbgimages`, `findobjects`, SVG re-render at display size (`svgsrc`, `svgresize`), `Pg.target` (#fragment) |
| `appl/lib/web/fonts.b` | web faces (`addface`, `webparts`, weight matching), WOFF 1 and 2, kerning (`kerns`, `kernpair`, `nokern`), Ahem as installed |
| `appl/lib/web/style.b` | `font-kerning`, `font-feature-settings` kern, ex/ch from metrics (`setmetrics`), font longhands before others, background shorthand fixes, anon boxes without borders |
| `appl/lib/brotli.b`, `brotli.tab`, `/lib/brotli/` | RFC 7932 decoder; tables generated from the reference source; MIT dictionary |
| `appl/lib/woff2.b` | WOFF2 container, glyf/loca/hmtx reconstruction |
| `appl/lib/outlinefont.b` | `kern` table, `ymax`, OpenType-CFF (`parseotf`) |
| `appl/lib/readpng.b`, `imageremap.b`, `readsvg.b` | tRNS (indexed and RGB), transparent full-colour SVG |
| `appl/lib/webclient.b`, `appl/cmd/webfs.b` | `Content-Encoding: br` |
| `tools/ref/` | wptrun, wptcmp, wptdiff, wptserve, boxdiff/boxes.js, compare, acid2, mirror, shot.js, fonts.conf, baseline/ |
| `appl/lib/bidi.b`, `lib/bidi/` | UAX #9 (`levels`, `reorder`, `mirror`) and Joining_Type (`joining`); tables from `tools/bidi/gen.py DerivedBidiClass.txt BidiMirroring.txt BidiBrackets.txt ArabicShaping.txt` (the UCD files are not kept in the tree; fetch them from unicode.org/Public/UNIDATA) |
| `appl/lib/outlinefont.b` (GSUB) | `parsegsub`, `Face.ligatures`, `Face.subst`, `Face.hasfeature` |
| `appl/lib/web/fonts.b` (shaping) | `shape` → `Slot`s, `joinforms`, `Typeface.draw` from the right for rtl |
| `appl/lib/web/layout.b` (this session) | `contribution` vs `intrinsic`, `floatwidth`, `joinruns`, `reorderline` with `Vis` controls and `leftedge`/`rightedge`, `contentheightof`/`asauto`, `oncanvas`, `intransform`, `Abs.frag` |
| `appl/lib/web/layout.b` (grid lanes) | `laylanes` (placement by shortest lane: `fitsat`/`lanesfit`, `Gap` for dense packing, `repsize` for intrinsic auto-repeats, `flowal` for flow-start/flow-end), `lanesintrinsic`/`spreadspan`, `collapsefit`/`ngaps` (auto-fit, grids too), `gridabs`/`Abs.area`/`abspalign` (absolutes in grid areas, aligned by justify-self/align-self), `Track.fit`; grid step-1 placement (definite row, auto column), `sizetracks` span groups, `order` for grid children |
| `appl/lib/web/style.b` (grid lanes) | `display: grid-lanes`/`inline-grid-lanes` (and the two-value forms), `grid-lanes-direction`, `grid-lanes-pack`, `flow-tolerance`, `flow-start`/`flow-end` alignment keywords |
| `tests/web/fonts/liga.ttf` | a fontTools-made font with f+i and f+f+i ligatures, for `web_fonts_test` |
| `tests/` | `web_fonts_test`, `brotli_test`, `charonshot -b/-d`, `charonbatch`, fonts and Brotli vectors under `tests/web/`, fixture `charon/wpt/control-chars.html`, `grid-lanes-basic`/`grid-lanes-dense` fixtures, `web_style_test` GridLanes |

## Things that bit, so they need not again

- **Limbo: `t := ref T;` with no initialiser does not zero the adt.**
  Integer fields come out as -1 (the nil word), and the JIT and the
  interpreter differ in which; `newbox` written that way lost a grid
  column.  Always write `ref T(...)` with every field.  A separate task
  was suggested to make the compiler or VM do the right thing.
- **Limbo: a declared-but-unassigned local (`a, b: int;`) is not
  reliably zero in the interpreter either.**  `parseotf` left `gsuboff`
  that way; a font without GSUB then parsed from a garbage offset, which
  the interpreter reported as an array bounds error and the amd64 JIT
  as a SEGV (a negative index escapes its bounds check: a task was
  suggested for that).  Initialise every local.
- **Limbo: `int` of a real rounds to nearest**, it does not truncate.
  `int (x + 0.5)` rounds twice.
- **CSS function names come out of the tokenizer lowercased**, so match
  `translatex`, not `translateX`.
- **`toarray()` in style.b reverses the list it is given** (it is for
  lists built by prepending).  `toarray(rev(l))` is the wrong order.
- **Both panels of `wptdiff.py` are Charon's**: the reference is the
  reference *page* rendered by Charon, not Chromium.  When test and
  reference disagree, check Chromium with a Playwright snippet before
  deciding which is right (`floats-placement-vertical-003` expects
  something Chromium does not do; the test was a false pass).
- **A WPT run must not be disturbed by `mk install`** (it loads the
  installed Dis); edit sources freely meanwhile, install afterwards.
- **Swapping `.m` files under a stash** (to compare with an older engine)
  needs `tests/` rebuilt too, or `charonshot` fails its link typecheck
  and every fixture reports "no image".  `charon-shot.sh -d` prints the
  box tree on stderr.
- **A "regression" whose test is unchanged is the reference changing**:
  `wrap-reverse` and `grid-lanes` tests passed while their references
  rendered as wrongly as they did; a flex fix made the references right.
  Dump both box trees before and after before chasing the test.
- **Limbo:** `con` and `fixed` are keywords (not variable names); real →
  int conversion *rounds* (so `int (x + 0.5)` rounds twice); a local
  redeclared in a sibling `for` header is an error; exception patterns
  take quoted globs (`"brotli:*"`); `16rFE000000` is a `big`, not an int.
- **Stale bytecode:** `tests/mkfile` and `appl/charon/mkfile` did not list
  the web `.m` files, so interfaces changed without recompiling users
  ("link typecheck" at load).  Both now list them; after editing a `.m`,
  rebuild all four directories anyway.
- **Never rebuild while a WPT run is going**: it renders with whatever
  bytecode is installed at that moment.  Prepare edits, build after.
- **Don't load the machine during a WPT run.**  Other emulators running
  alongside made pages miss their time and shared references get blamed
  as "crash or hang".  (The retry now absorbs most of it.)
- **`pkill -f pattern` matches its own shell** when the pattern appears in
  the command line; kill by pid file or use a pattern like `"x[y]"`.
- **Disk:** the raw 800×600 images are large; `wptrun.py` works in chunks
  of 200 tests and deletes them; keep it that way.
- **A server that is down gives a perfect score** (two identical error
  pages); `compare.py` now refuses an unreachable URL.
- **Chromium's `sans-serif` is not DejaVu** on a stock Linux host;
  without `fonts.conf` every text width comparison is off by ~5–15%.
- **Python's http.server ignores wptserve pipes**; Acid2's
  `404.html?pipe=status(404)` needs `wptserve.py`.
- **The container's Chromium (141) has no `display: grid-lanes`**, with
  or without the experimental-features flags, so for `css-grid/grid-lanes`
  there is no ground truth beyond reading the reference pages: a test
  whose reference is itself a grid-lanes page proves nothing when both
  render alike (the whole directory "passed" before the display type
  existed).  `column-auto-repeat-auto-017` is left failing for that
  reason: no reading of auto-repeat counting and placement beyond the
  explicit grid fits both it and `column-auto-repeat-max-content-005`.
- **Parallel tool calls share one shell and its working directory.**
  A `cd` in one changes where the other's relative paths resolve
  (`tools/ref/wptdiff.py` was looked for under `tmp/WPT`).  Use absolute
  paths in anything that may run alongside something else.
- **Adding a field to a positional adt** (`Abs.area`, `Track.fit`,
  `St.lanesdir`) means every `ref Abs(`/`ref Track(`/`ref St(` site:
  grep them all first; the compiler reports the first mismatch only.

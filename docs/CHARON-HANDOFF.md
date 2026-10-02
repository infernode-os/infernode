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
| WPT CSS reftests (18 directories, 12,642 judged) | ****48.0%**** (6,069 passing), from 46.8% at this session's start and 37.8% at the first run ever |
| Acid2 (`test.html#top`) | renders correctly; ~1,400 pixels differ from Chromium, all anti-aliasing |
| pypi.org home page vs Chromium (scripts off) | ~7% of pixels differ, from 47.8%; layout, fonts, logo, icons match |
| Unit tests | web_html 5, web_css 6, web_style 15, web_browser 9, web_fonts 8, brotli 3: all pass |
| Render fixtures (`tools/charon-wpt.sh`) | 56/56 (one intermittent failure is the emu SEGV below) |

The WPT count is strict: any test with a `<script>` is reported as
needs-js (1,268 of them) even if its pixels match, and a pass whose
rendering is one flat colour is flagged `blank`.  The full per-test
results of the last run are in `tools/ref/baseline/wpt-results.txt.gz`
(gunzip it and use it as the "before" for `tools/ref/wptcmp.py`).  The
WPT checkout was `web-platform-tests/wpt` at
`89c9ebab4fef9e79de92421dd637f00fa4922359` (2026-10-02); a newer checkout
will move the numbers a little.

### Commits on the branch (newest first)

This session started with a code review of the whole engine (three
reviewers, one per area: html/dom, css/style, layout/fonts), verified
each finding against the code, and fixed what mattered; every fix has
a fixture or unit test that fails on the previous engine.

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

   | Page | exact | layout | first wrong box |
   |---|---|---|---|
   | pypi.org | 6.5% | 6.3% | — |
   | developer.mozilla.org (CSS/display) | 10.0% | 12.7% | an inline `<svg>` path in the header nav has no box |
   | en.wikipedia.org (Plan 9) | 13.7% | 15.4% | header `input[type=checkbox]` 63×50, Chromium 44×44 (appearance: none sizing) |
   | news.ycombinator.com | 22.2% | 27.9% | rows 28px tall, Chromium 24: the nested table's cell gets 1px extra all round |
   | docs.python.org (library/os) | 23.5% | 36.9% | the "related" nav: the long `li` wraps to 5 lines, Chromium 3; the right-floated search form is narrower and wraps |
   | go.dev | 65.4% | 67.3% | the header nav `ul` is 1659px wide: Material Icons ligature names render as text (the font comes from fonts.googleapis.com; check it loads through the mirror); `body` 768px tall |

   The `<center>` fix came from this list (HN's table was not centred).
   Take the pages top to bottom: the first wrong box per page has been
   the fastest way to real bugs.
2. **Review findings not yet fixed** (verified by reading, not yet
   done; the full lists are in the session's scratch notes, these are
   the ones that matter):
   - layout: images are rescaled on every paint (`scale()` in
     `paintreplaced`/`paintbg`; cache by target size); `relative()` is
     skipped for `Kinline` boxes (`position: relative` on an `<a>` does
     nothing); grid row-flow cursor rule (§8.5 step 3) and percentage
     tracks against an indefinite size (treated as 0, should be auto);
     `sizetracks` grows tracks proportionally rather than equally with
     freezing (§12.6); `intrinsic()` ignores a child's own
     `max-width`/`min-width`; U+00AD and U+200B are not break
     opportunities; BFC roots beside floats are narrowed but never moved
     below one; `spread()` can overflow `int` on huge tables; `Typeface.width`
     looks each glyph up twice.
   - style: `revert`/`revert-layer` are treated as `unset` (the UA
     values should come back); nested `@layer` order is flat; `var()`
     cycles fall through to the fallback; HTML's case-insensitive
     attribute values (`[type=text]` vs `type="Text"`); a `&` inside
     `:is()` in a nested rule; user origin folded into UA.
   - html: `canoncs` maps gbk/gb18030 to gb2312 and has no euc-kr or
     windows-125x beyond 1250–1252 (tables missing from `lib/convcs`);
     doctype system ids are dropped (html5lib fixtures with ids would
     fail); limited-quirks mode is not modelled.
   - page/browser: no HTTP cache in webfs, so every navigation
     refetches; `text/plain` pages ignore their charset.
3. **Open regressions (36 tests that genuinely passed before and fail now).**
   Groups and causes as far as known:
   - `CSS2/colors/color-applies-to-*` (8): sub-pixel text position.  A
     word starting with `&nbsp;` inside a table cell draws its glyphs at
     fractional offsets that round differently from the reference.
     Snapping words to whole pixels fixed these but broke
     `positioning/abspos-011/012` (monospace alignment), so it was
     reverted.  The real fix is sub-pixel layout (item 4).
   - `CSS2/bidi-text/*`, `CSS2/bidi-007` (9): bidi reordering, not
     implemented.  These passed by accident before.
   - `css-grid/alignment`, `grid-lanes`, `grid-items`, `grid-definition`
     (12): mostly baseline alignment in vertical writing modes (not
     implemented); `grid-template-rows-fit-content-001` and
     `grid-items-inline-blocks-001` deserve a look.
   - `css-text/word-break/word-break-min-content-005/006`,
     `overflow-wrap-min-content-size-002`: min-content measurement; likely
     interaction with kerning or the inline-block intrinsic-width change.
   - `CSS2/floats/float-nowrap-hyphen-rewind-1`, `CSS2/box/ltr-span-only`,
     `css-lists/ol-change-display-type`, `css-display/run-in`: unexamined.
   The list, with current status: `tools/ref/baseline/open-regressions.txt`.
3. **Exposed gaps behind many failures:** bidi (UAX #9), vertical writing
   modes, complex-script shaping (Arabic joining; the `css-text/shaping`
   tests now load their WOFF2 fonts and fail honestly), GPOS kerning
   (only the legacy `kern` table is read), `<iframe>`/nested documents
   (`<object>` with HTML data shows an empty frame), translucent opacity on
   inline boxes (floats inside them paint at full opacity; opacity 0 is
   handled).
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
| `tests/` | `web_fonts_test`, `brotli_test`, `charonshot -b/-d`, `charonbatch`, fonts and Brotli vectors under `tests/web/`, fixture `charon/wpt/control-chars.html` |

## Things that bit, so they need not again

- **Limbo: `t := ref T;` with no initialiser does not zero the adt.**
  Integer fields come out as -1 (the nil word), and the JIT and the
  interpreter differ in which; `newbox` written that way lost a grid
  column.  Always write `ref T(...)` with every field.  A separate task
  was suggested to make the compiler or VM do the right thing.
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

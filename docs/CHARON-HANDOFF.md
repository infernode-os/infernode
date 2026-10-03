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
| WPT CSS reftests (18 directories, 12,642 judged) | **80.1%** (10,128 passing), from 74.0% at this session's start (the seventh), 68.5% at the sixth's, 53.8% at the fifth's, 50.0% at the fourth's and 37.8% at the first run ever; CSS2 5,511 of 5,902, css-text 1,013 of 1,382, css-grid 892 of 1,538, css-flexbox 664 of 946, css-backgrounds 523 of 604, css-tables 97 of 138 |
| Acid2 (`test.html#top`) | renders correctly; ~1,400 pixels differ from Chromium, all anti-aliasing |
| pypi.org home page vs Chromium (scripts off) | ~7% of pixels differ, from 47.8%; layout, fonts, logo, icons match |
| Unit tests | web_html 5, web_css 6, web_style 16, web_browser 9, web_fonts 10, bidi 3, brotli 3: all pass |
| Render fixtures (`tools/charon-wpt.sh`) | 70/70 (one intermittent "no image" is the emu SEGV below) |

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
failing WPT directory (`css-grid/grid-lanes`, 891 tests).  The fifth
session went down the failing families by size: lists and counters,
backgrounds, aspect-ratio, positioning, break-spaces, text-transform,
tables.  The sixth went on down them: glyph hinting, stylesheet
encodings, pseudo-element display types, the break-opportunity model
between inline boxes, percentage heights in intrinsic sizes, floats
beside tall lines, and a tail of small properties.  The seventh took
the CSS2 families (tables, floats, margins, clearance, selectors) and
css-text (letter-spacing, soft hyphens, hanging space separators,
text-align-last), 74.0% to 76.0%, and went on through colour gamut
mapping, positioned inlines and flex and grid static positions, SVG
intrinsic sizes for backgrounds and replaced boxes (the whole
`background-size/vector` directory), border-image, background-clip
text and border-area, text-wrap: balance, the segment-break rules,
hanging-punctuation allow-end, hanging space sequences and rtl grids,
76.0% to 80.1%.

- `049b8a1` **Text split around out-of-flow flex children, ratio-only
  images in flex cross sizes.**  `fixkids`' run splitter ends a run at
  an out-of-flow child when the parent is a flex or grid container;
  `flexcrossw` drops the min-content floor for an SVG replaced item
  with no natural size.
- `fee26ff` **Floated items paint, flex automatic minimum clamped by the
  maximum, keep-all relaxed.**  `paintitems` paints floated items;
  the flex automatic minimum is clamped by a definite `maxm` (§4.5);
  `keptall()` lets the overflow split break a keep-all word that
  starts a line; `auto-phrase` parses as keep-all.
- `e8453c6` **Flex and grid items paint atomically.**  `hasitems`/
  `paintitems`: `paintcontent`, and the parent's `flowbgs`/
  `flowfloats`/`flowinline` passes, stop at a flex or grid container
  and paint its items each whole, in order, in the inline content pass
  (Flexbox §5.4, Grid 2 §10), as inline blocks are; before, all item
  backgrounds went down before any item's text.  Also `lbkeepall`/
  `cjkletter` for word-break: keep-all in `lbbreak`, and a zero width
  space after overflowing preserved spaces breaks the line (both still
  short of their tests: keep-all-005..008, letter-spacing-201).
- `c5fcafd` **Grid tracks end where they end, z-index on flex and grid
  items, var() names are free.**  `Track.endp` set by `trackpos`
  (`trackend` prefers it: content-distribution space is not the
  track's), `zitem()` in `islayer`/`isctx`, `validvars` checks only
  for an empty argument list or a top-level `!`/`;`.
- `78961ef` **var() validity at parse time.**  `css->validvars` (css.b,
  exported in css.m): a `var()` with a name that is not a custom
  property, or a `!` or `;` at the top level of its fallback, makes
  the declaration invalid at parse time, so the earlier declaration
  stands; `declaration()` drops it and the `@supports` check in
  style.b consults it (variable-declaration-11, -12,
  variable-reference-07, -08, variable-supports-09, -10).
- `22b80f1` **Hanging space sequences, flex ratio constraints, SVG
  border images, col widths, two-position stops.**  `finish()` keeps
  spaces among hanging separators and anchors the hanging run past the
  last fragment with width; an ideographic space makes a line content
  (`layinline1`'s Ispace); `replacedsize`'s §10.4 table skips a flex
  item's main-axis constraints only (`fw`/`fh`); `paintborderimage`
  rasterises an SVG source at its intrinsic size (`svgraster`);
  `paintgradient` takes `colour p1 p2` stops; `tileplaces` carries a
  spaced tiling into the painting area; `hints()` maps `<col width>`.
- `d8b4c53` **border-image, background-clip text and border-area,
  background-repeat space.**  `Bimage` adt and `St.bimage`
  (`bimageof`, `foursides`, `birepeat`, the `borderimage` shorthand
  splitter; the `border` shorthand resets the source);
  `paintborderimage` (nine parts via `bimpart`/`bimplaces`/`subimage`,
  slices via `slicev` rounded up when they overlap, widths `bimwidth`,
  outsets `bimoutset`, a gradient source rasterised to the area);
  `maskedbackground`/`maskedspan`/`borderareamask` paint the background
  into a layer and composite through a GREY8 mask, `textmask` making
  `painttext`/`paintdeco` draw white and `paintself`/`paintreplaced`/
  `paintoutline`/`paintspan` draw nothing; `tileplaces` for
  background-repeat: space.  Not done: `border-style: double` with
  border-area, conic gradients (2 tests).
- `2748456` **min/max constraints with a ratio, rtl grid lanes,
  static-position room, slivers.**  CSS 2.2 §10.4's constraint table
  at the end of `replacedsize` (lengths and percentages only via
  `plainlen`, not for flex or grid items); `laylanes` mirrors lane
  positions in rtl; `layabs` shrink-to-fit room reaches the containing
  block's end past its width except for tables; a background tile
  thinner than a pixel is dropped unless repeated.
- `f663651` **SVG intrinsic sizes for backgrounds and replaced boxes,
  percentages in SVG, grid static positions and rtl grids.**  Layout
  keeps SVG background sources (`setbgsvg`, `bgsvgs`), reads the
  root's width/height/viewBox (`svgintrinsic`, `svglen`, `svgpct`),
  sizes by Backgrounds 3 §3.9 (`concretesize`) and draws again at the
  tile size (`svgraster`, with `svgresize`/`dropattr`/`strindex` moved
  here from page.b); `Box.svg`/`iratio`/`ipw`/`iph` set by page.b's
  `svgdims` (an `<object>`'s omitted dimensions are 100%), `replacedsize`
  resolving them (a specified dimension and the ratio first, a
  percentage or a ratio alone filling what the containing block leaves
  after padding and borders, else 300×150), `aspect()` using `iratio`.
  readsvg.b: `px`/`py`/`pd`/`plen` for percentages, `rootlen`,
  preserveAspectRatio, and `int width` (Limbo's `int` rounds: a
  `+ 0.5` makes 16 into 17, which was why every SVG raster was a pixel
  too big and its edges blended).  Grid: `gridspalign`, `gridabsarea`,
  `Abs.flexsp` 3 (a grid's content box as the static rectangle) and 4
  (a descendant's grid area, its own static position), rtl mirroring
  of item areas in `laygrid` and of `gridabsarea`; `layabs` shrinks to
  fit the width the static position leaves.
- `7839793` **text-wrap: balance, segment-break rules, hanging-punctuation
  allow-end, margin-trim in grid intrinsic sizes.**  `St.textwrap`
  (`text-wrap-style`, `wrapstyle`); `layinline` is now a wrapper that
  bisects a width cut per forced-break group with `layinline1` laid out
  again each trial (`balancing`, `balancecuts`, `balancegroup`,
  `balancecount`, `cutavail`; floats and `l.pending` restored between
  trials; nested blocks laid plainly); `segbreaks`/`removable`/
  `cjkpunct`/`ignorable` run before words are split; `endhangs`/
  `hangstop` for allow-end and force-end (a break must be possible
  after the mark); grid intrinsic contributions trim margins; an
  absolutely positioned table with both insets keeps its own width;
  the flex "safe" check is against the containing block.
- `22b74e7` **Inline containing-block edges, sliced inline box-shadows,
  gamut mapping by the spec.**  An absolutely positioned box inside an
  inline takes its containing block from the first fragment's top and
  start edge and the last fragment's bottom and end edge (CSS 2.1
  §10.1), the pieces of an inline split by a block counting as one
  (`spanextent`); an inline box's box-shadow is painted per fragment
  as the shadow of the unbroken box, sliced at the ends that are not
  its own (`paintspan`), and `shadowfill` goes through a mask with the
  border box cleared from it (the even-odd fill showed strips inside a
  box without a background); `color(srgb …)` outside the gamut is
  mapped like every other space; the chroma bisection runs to the
  point the spec names; Oklab lightness within an epsilon of its ends
  is white or black; "safe" alignment of a flex container's absolutely
  positioned child checks the axis's own bit (`flexspsafe`).
- `49e5513` **Gamut mapping, positioned inlines as containing blocks,
  flex static positions, relative table parts, margin-trim in flex
  lines.**  `topixel` maps an out-of-gamut colour by reducing Oklch
  chroma (`oklab2lin`, `lin2oklab`, `ingamut`, `clip01`); `Abs.icb`,
  `inlinearea`; `Abs.flexsp`, `flexarea`, `flexspalign` (the static
  rectangle `sr` apart from the containing block `pr` in `layabs`);
  relative offsets for rows, row groups, cells and captions; flex line
  formation leaves out the margins it will trim; flow-end as end in
  flex; text-autospace's initial value is no-autospace.
- `0843e96` **text-autospace, margin-trim for flex and grid, colour
  clamps, outlines and overflow on table parts, stylesheet content
  types.**  `autospacepass`/`isideograph`/`isalnumeral`;
  `St.textautospace`; margin-trim on flex and grid items at the
  container's edges and in `sizetracks` contributions; `trackpos`
  shares space among non-collapsed tracks; lab/lch/oklab/oklch
  lightness clamped (`clampl`), chroma ≥ 0, `display-p3-linear`;
  `paintoutline` skips columns, `innerclip` ignores overflow on rows,
  row groups and columns; `page.b` `mediatype` rejects a linked sheet
  not `text/css` in standards mode.
- `dd5e6d7` **hanging-punctuation first and last.**  `St.hangpunct`;
  `hangpass` splits the opening or closing mark into an item of its own
  (`Item.hang`/`Frag.hang`, `hangopen`/`hangclose`) that takes no room
  on the line, in the intrinsic sizes or in alignment, provided the
  inline box holding it has no border or padding on that side
  (`edged`); `finish()` shifts it past the edge (rtl: the other side).
  force-end and allow-end are not done.
- `0b5533e` **Trailing letter-spacing trimmed at a line's end.**
  `Item.tls`/`Frag.tls`; `segwidth` lets the spacing overflow when
  fitting a word, `finish()` takes it off the last fragment, the
  intrinsic measure leaves it out (letter-spacing-200, -end-of-line-001).
- `ef02bb7` **Soft hyphens between joining letters, min-content without
  hyphenation, rtl overflow to the left.**  `joinedacross` keeps a soft
  hyphen inside a shaped word; the measure keeps a shy word one unit
  (`shy`); inline content too wide for a right-to-left line overflows
  the left, anchored at the start (`off` clamp only for ltr).
- `d1dd7c1` **Soft hyphens, hyphens, hyphenate-character, text-justify:
  none.**  A soft hyphen is a break opportunity kept as a zero-width
  item after its word (text()); `canbreak` takes it when the hyphen
  fits or nothing else on the line could break (`earlierbreak`);
  `hyphenate()` shows the hyphenate character at the line's end
  (U+2010 where `Typeface.has` it, else hyphen-minus); `St.hyphens`,
  `St.hyphenchar`, `St.textjustify`; U+00AD and U+2010 added to
  `lib/bidi/linebreak`; ::first-line colour spares text of its own
  colour (`lineflbase`) and stops at flex/grid/table containers.
- `ad58df4` **::first-line colour, text-align-last everywhere, document
  language.**  `Computed.firstline`/`Box.fl`/`Line.fl`,
  `firstlinest`/`firstinflow`, `linefl` in `painttext`; `Aauto` for
  text-align-last and the last line honouring it under any text-align;
  `Doc.lang` from `<meta http-equiv=content-language>` (`metalang`)
  for `:lang()`; an empty `:lang()` is invalid.
- `eb4b9be` **Letter-spacing at boundaries, tab-stop threshold, hanging
  space separators, break-spaces with overflow-wrap.**  `lspass`/
  `commonbox` (the spacing after a character is the innermost common
  box's, none at the paragraph's end); `tabw` skips a stop within half
  a space; `hangsp`/`hangsep` generalise the ideographic space to the
  ogham space mark, en/em spaces and kin (not the figure space); a
  space under break-spaces wraps alone when overflow-wrap lets it break
  from a word starting the line; an auto-width BFC beside floats needs
  room for its margins.
- `92c4dc9` **Floats mid-line, BFCs beside floats, split inlines,
  spanning-cell borders, lone captions, title case.**  A left float
  placed mid-line moves the line's content from where it was (edgesat
  had already moved `ln.x`); a BFC beside floats keeps its whole border
  box clear when its height is known (`bh` band) and resolves auto
  margins within the band (`automargins`, shared with `sizew1`); a
  cleared box lands exactly at the clearance; `splitinline` gives the
  first piece the start edges and the last the end edges (copied `St`);
  a lone caption is `isinternal`; internal table boxes have no margins
  (`edges`); `collapsed()` clears the grid-line borders inside a
  spanning cell; `cellbaseline` is -1 for a cell with no line box;
  `painttablepart` paints shadows; negative percentage heights invalid,
  calc() padding clamped; bidi `totitle` honours a title case equal to
  the character; `glyph()` maps U+00A0 to the space glyph.
- `c4fad77` **Cell baselines, table-part backgrounds through cells,
  decoration propagation, nested inline backgrounds, clearance and
  empty-box margins.**  `Tcell.base`/`rowbase` for `vertical-align:
  baseline` cells; `painttablepart`/`partcells`/`rowcells` paint a row's,
  row group's or column's background once per cell, clipped; a column
  group's columns are left alone by `fixkids`; `flowdeco` propagates
  text decorations down in-flow boxes; inline box backgrounds are
  painted by depth (outermost first); a cleared box's margins are used
  up at the clearance (`topmargin` in `cury`); `pendingclear` keeps an
  empty cleared box's margins inside the parent; `passempty` lets
  margins collapse through a `height: 0` box; negative percentage
  padding invalid; the layout dump lists `span` fragments.
- `f72b7f4` **Collapsed columns, floats among table children, nowrap
  breaks, color-mix currentcolor.**  `Tgrid.colhid`, `hidw`, cells
  laid out at full width and clipped with the leading collapsed part
  slid out (`Box.clip`, `shiftx`, `innerclip`); a float child of a
  table is wrapped in an anonymous row and cell (`flushwrap`); rows,
  row groups and columns paint no borders in the separated model;
  `spacebefore` lets a nowrap box's word start a line after a space
  whose boundary is outside nowrap text; `mixcur` is what currentcolor
  means inside `color-mix()`, and `colormixr` keeps nested mixes in
  reals.
- `54aa28a` **color() spaces, SVG viewBox ratio, collapsed rows.**
  `colorspace` with the sRGB, linear, Display P3, A98, ProPhoto,
  Rec. 2020 and XYZ transfer functions; an SVG root's ratio from its
  `viewBox`; rows and row groups with `visibility: collapse` leave the
  grid.
- `3e8768c` **Loose line breaking for CJK, atomic inline breaking as
  browsers do.**  `lbmode` 1 (loose: NS/EX/PO before, PR after;
  hyphens U+2010/2013); a no-break space beside an atomic inline
  breaks; GL/WJ/ZWJ/OP/BB/QU/CM hold before, CM/ZWJ/WJ/GL after.
- `1ae742c` **margin-trim, clip: rect(), overflow propagation.**
  `St.margintrim` zeroes a block container's first and last in-flow
  child margins; `St.cliprect` through `layerclip`; `paintself` is
  clipped by the layer clip; the root's and body's overflow is the
  viewport's (`innerclip`).
- `b088614` **:lang() ranges, word-space-transform, wbr, segment breaks,
  system colours.**  Extended filtering for `:lang()` (`langmatch`:
  quoted, `*`, lists, implicit subtags); `word-space-transform`
  (`St.wst`, `wstpass` over the items, with the line-edge exception);
  `<wbr>` is a zero-width space; a segment break between East Asian
  wide characters is removed (`eaw`); an atomic inline breaks like an
  ideograph (`atomicbreak`); the deprecated system colours as what they
  equal; `var()` in `@supports`; `inherit()` copies `lbmode` and `wst`.
- `08973a6` **Lines clear floats for their whole height, header row
  order, break-spaces fixes.**  `tallband`/`shiftline` for a tall atomic
  beside floats; a float after a trailing space may have its room;
  `tgrid`'s head list was reversed once too often; `word-break:
  break-all` no longer cancels `line-break: anywhere`; an ideographic
  space wraps as a space under break-spaces; transferred constraints
  only for auto widths; the quirks height not through a cell's child.
- `c0be16f` **Ratio constraints, flex column free space, overflow-wrap
  levels.**  `transferw` (min/max-height through the ratio), the height
  as used for a transferred width, `stretched` flex items see the line
  height, `packh` for column-wrap intrinsic widths, the quirks
  percentage height, a column flex container's auto main size clamped
  by min/max-height, free space shared in reals, `left`/`right`
  physical in rows; `St.anywhere` 1 (break-word) or 2 (anywhere,
  counted for min-content); loose breaks before U+2010/2013.
- `a2099de` **Percentage heights in intrinsic sizes, fit-content(),
  contain-intrinsic-size.**  `pcth`/`pcthbox`/`definiteh` (the definite
  height a measurement's percentages see; the intrinsic cache keys on
  it), `replacedsize` given the containing block height at layout too,
  canvas `width`/`height` as natural size not hints; `fit-content(<lp>)`
  (`Len(Lfit, px, pct)`); `contain-intrinsic-size` (`St.cisw/cish`,
  size containment in `intrinsic1` and `layblock`); `wordgap` shared by
  layout and `inlineintrinsic`, break-all through `lbbreakall`,
  `segwidth` to the farthest edge, the 〜 rule for ja/zh (`lbcjk`).
- `acee14f` **Stylesheet encodings, pseudo-element display types,
  segment-wise wrapping.**  `html->cssdecode` (BOM, transport,
  `@charset`, link charset, `Doc.charset`; UTF-16 both orders in
  `utf16`), the runner serves `.headers` sidecars; `boxkind` shared by
  elements and pseudo-elements (table parts, list items with markers,
  `content: url()` as a replaced box, `fixkids` on generated kids);
  `isrowgroup`/`iscolumn` never true of a text box; `canbreak` and
  `segwidth` (a word may break from the one before only where UAX #14
  allows, inline edges and floats between them notwithstanding);
  `St.lbmode`; soft hyphens as transparent opportunities; an unmatched
  close-quote shows nothing; `attr()` exact in XML; negative border
  widths invalidate the shorthand; armenian and georgian styles.
- `21cfb7b` **Light hinting, collapsed table widths, quotes, nowrap,
  break opportunities.**  `rasterize` snaps a glyph's top and bottom to
  pixel rows (65 one-row failures); a collapsed table's width is the
  grid's, `edges()` computing the halves up front; `quotes` and
  `qdepth`; `font-size: 0` keeps forced breaks and tab-size lengths;
  `white-space: nowrap` as the shorthand collapses; a pseudo-element
  has a counter identity of its own (`parentof`, ids below zero).
- `d01cb13` **Counter scopes as Lists 3 has them, reversed counters,
  row group order.**  A new counter replaces one the element or a
  previous sibling instantiated and nests inside an ancestor's
  (`instantiate`, `Ctr.origin`); a nested one is for the subtree only
  (`ctrleave`); `reversed(name)` with the spec's initial-value
  algorithm (`reversedinit`/`revscan`); `start=` and `reversed` are
  hints.  Only the first header and footer group move.  `stretch`
  beside a float and for absolutes with auto insets.
- `07b2234` **Textareas as pre-wrap text, the table box without its
  captions, the stretch keyword.**  A textarea is a block of its text
  (cols wide, rows tall: `textarea()`); a table's background and
  borders cover the table box only (`tablerect`); `width/height:
  stretch` (`Lstretch`), for absolutes what the insets leave or the
  room past the static position; a form control is not a replaced box
  in CSS 2.2's sense (`truereplaced`); fitting a word on a line allows
  half a pixel.
- `2ccf2dd` **Right-to-left tables, column group borders, svg
  attributes, absolute replaced boxes.**  Columns run right to left in
  an rtl table (`cx`, `Tb.rtl`, `pcol`/`pline`); a column group's
  borders in the collapsing model (`colfight`); an outer svg's width and
  height attributes are its CSS width and height (`hints`); an
  absolutely positioned replaced box keeps its size whatever the
  insets say; a fixed box's static position counted the root's margin
  twice.
- `27a6ade` **rules= on tables, column elements as columns.**  The
  `rules` attribute's borders (`tablerules`/`rulesof`, width and style
  only so the UA sheet's gray stays); a `<colgroup>`'s `<col>`s stand
  for it (`expandcols`); a column element with a definite width
  (`colwidth`: width or min-width; max-width does not apply) is a
  column with no cells in it.
- `babfc7a` **Separated tables keep their borders; a flex item's
  content size suggestion; cells in inline boxes.**  Only a `Tb` with
  resolved segments means collapsed (ninety tests with bordered tables
  had regressed); a flex item's automatic minimum is its content's
  min-content width, not its width's (`nowidth`); cells in an inline
  box go in an inline table before the inline is split around blocks.
- `d201ec3` **The collapsing border model, column backgrounds,
  fixed-layout percentages.**  `border-collapse: collapse` resolves the
  border at every grid-line segment among the cells, rows, row groups,
  columns and the table (`collapsed`/`fight`: hidden, width, style,
  origin, then left or top), kept in `Tb` on the table box; cells take
  the halves on their side (`cellhalves`), the table the outer halves
  and no padding (`tablehalves`); the borders are painted after the
  cells' backgrounds, centred on the lines (`paintcollapsed`, from
  `flowbgs`); captions lie outside them.  Columns and groups get their
  spans' extent in layout (`placecolumns`) and their backgrounds are
  painted under the rows' (`paintcolumns`).  Fixed layout: a `<col>`
  percentage is the column's, a cell's is of its content box
  (`Tgrid.colpct`, `pex`).  Cells in an inline box go in an inline table.
- `626e14b` **Unicode case mapping, full-width, hanging ideographic
  spaces.**  `lib/bidi/case` and `casex` (from UnicodeData.txt and
  SpecialCasing.txt by `tools/bidi/case.py`); `Bidi->toupper/tolower/
  totitle` with Final_Sigma, the Turkish/Azeri i (`langof` finds the
  lang attribute) and no Mtavruli for Georgian; `text-transform:
  full-width`.  An ideographic space at a line's end hangs, keeping
  its background (the inline boxes reach out over it).  Aspect ratio:
  the transferred width is no less than the content's min-content
  (`transferred`, the automatic minimum) unless the box scrolls; a 1/0
  ratio is auto; svg without dimensions has no natural ratio.  rtl: a
  relative box with both insets takes the containing block's start;
  text-indent is at the right.  A block-level absolute met mid-line
  sits under the line (`Ln.below`).
- `02f7458` **aspect-ratio, break-spaces, positioned table parts,
  line-break: anywhere.**  `aspect-ratio` on non-replaced boxes
  (`ratiow`/`ratioh`, `auto <ratio>` of the content box, `St.aspectauto`;
  blocks, absolutes, intrinsic contributions, grid items not stretched
  by `normal`).  `white-space: break-spaces` wraps a space that does
  not fit, taking the word before it when something it could break
  from precedes that word (the `Ispace` branch of the line builder;
  `line-break: anywhere` is `breakall` 2 and breaks before the space).
  Out-of-flow boxes among a table's parts are kept and registered
  (`tableabs`).  Absolutes: auto vertical margins, negative auto
  horizontal margins, right-to-left over-constrained blocks.
- `89faf88` **Counters, the canvas background, the line-break table.**
  CSS counters with scope (`Ctr`, `ctrprops`, `counters()` outermost
  first, `counterrep` without the marker suffix).  The UA sheet gave
  `html` an opaque Canvas background, so a body background never
  reached the canvas: dropped; the body is found by tag (`istag`),
  paint containment stops propagation (`contain` is parsed, `CT` bits),
  propagated images are positioned on the root's box, a body whose
  background moved keeps its box-shadow (`paintshadows`).  An atomic
  inline gets its containing block's height (`height: 100%` on an
  `<img>` in a 200px div).  The line-break class table was read with
  its class column as hex (15 became JT, 16 EB, 10 ZWJ): words broke
  at bidi controls and joiners.  A root box carries its document
  (`Box.doc`), so a page with frames paints with the right one current.
- `a0849c0`, `4895a7e`, `0fe4325` **Images in true colour, table
  height and hints, fixed layout width, UAX #14 line breaking.**
  `imageremap` returns RGBA32 (+568 tests: images were quantised to a
  palette); a table's `height` excludes its captions; `cellpadding`
  hints for attribute-less cells (`sharekey` nil for td/th); a
  fixed-layout table's width is its columns' given widths plus spacing;
  a BFC root beside a float needs its start margin and border box to
  fit; `lbbreak`/`lbclass` (Line_Break classes from LineBreak.txt by
  `tools/bidi/linebreak.py`) decide breaks inside runs of letters.
- `3cd836d` **::first-letter, fit-content() tracks.**  `::first-letter`
  (`firstletter`/`firsttext` in layout.b: the first text of the first
  formatted line, through inline boxes and into a first block child;
  the letter with the punctuation around it, General_Category P* from
  the new `lib/bidi/punct` table and `bidi->punct`, and its combining
  marks, go in a box of the pseudo-element's style, which inherits from
  `::before` when the letter is generated content).  339 of the CSS2
  selectors tests were `first-letter-punctuation-*`.  `fit-content(x)`
  tracks are their own kind (`Tfit`): max-content no wider than x,
  which minmax(auto, x) had stood in for (and so clamped automatic
  minimums it should not).
- `eed6141` **Subgrid (Grid 2 §9).**  `grid-template-columns/rows:
  subgrid`: the parent hands a subgrid the tracks, line names and gap it
  spans each layout (`Box.subcw/subrh` and friends); sizing the
  parent's tracks, the subgrid stands aside for its items
  (`subgridded`/`subitems`), which carry its margin, border and padding
  at its edges (an empty edge track too), nested subgrids included; its
  own edges come out of its first and last tracks so its lines stay the
  parent's; its size across is the tracks'; a gap of its own is used
  within, the difference carried as margins; lines past its own are
  clamped; grid lanes do the same for subgrid items.  Placement is
  `gridplace`, shared.  Named lines with counts and `span <name>`.  An
  auto-sized item's automatic minimum is clamped by a fixed max track
  size (`minmax(auto, 100px)`).  Not done: a subgrid's own gap when it
  is also the parent of a nested subgrid with another (gap-004), repeat
  names after `subgrid`, orthogonal writing modes, intrinsic size
  transfer through a row subgrid (`aspect-ratio` items).
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
   now; 49 at r55, each with a reason, 9 of them matching Chromium or a
   reference that changed; 52 at r45, 53 at r37, 53 at r27, 49 at the
   end of the fourth session).**  Mostly the grid-lanes directory's
   references changing from "nothing renders" to a real layout: 8 are
   subgrid gaps and line names inside lanes, 11 are auto-repeats of
   intrinsic lanes (the count is the items' smallest max-content
   contribution, which fits most of the directory; no rule found fits
   `column-auto-repeat-auto-017` and `column-auto-repeat-max-content-005`
   both, and the container's Chromium has no grid-lanes to ask).  Also:
   `last baseline` self-alignment of absolutely positioned grid
   children (4), a fixed child of a grid whose containing block is not
   the grid, two BFC-root float cases, the bidi box-model pair, the
   shaped-run rounding pair, `@namespace` selectors (`not-default-ns-001`,
   a former blank pass), former blank or lucky passes that real
   features exposed (`hanging-punctuation-first-ascii-quote`, whose
   reference uses script; `text-wrap-balance-line-clamp-001`, which
   needs line-clamp; two vertical text-autospace cases), the strict
   colour pair `xyz-d50-004` (its two inputs differ in the sixth figure
   and gamut-map a unit apart), and the variable-font, 2-pixel and
   tentative cases from before.  Each with its reason, as far as known:
   `tools/ref/baseline/open-regressions.txt`.
   **Where the failures are now** (r55, 2,508 failing): css-grid 646
   (grid-lanes 366, alignment 87: self-baseline 38, grid-items 56:
   inline contributions and aspect-ratio items, subgrid 51, abspos 41:
   `last baseline` and vertical writing modes), css-flexbox 267
   (`balance` 28 is Flexbox 2's `flex-wrap: balance`, writing modes,
   baseline alignment, aspect-ratio items), css-text 369 (white-space 90:
   pre-wrap trailing spaces with alignment, break-spaces, line-clamp;
   hyphens 35 need dictionaries; word-break 32: keep-all and auto-phrase;
   text-transform 27: tailoring, full-size-kana, a webfont; letter-spacing
   23: around inline box edges, ligatures; text-autospace 18 and
   line-breaking 24 mostly vertical or font cases), css-fonts 152
   (font-palette 14, font-stretch 11, font-variant-east-asian 10,
   font-size-adjust, synthesis: all font-engine work), css-sizing 132
   (aspect-ratio 59: flex and grid items, abspos; calc-size), css-values
   61 (ch and ic units in vertical writing 21, calc-size 19), css-backgrounds
   67 (background-clip 17: text with transforms, double borders; the
   rest 1-2 pixel cases), CSS2 bidi-text 47 (sub-pixel run rounding),
   tables 44 (`table-anonymous-objects` differ by a glyph's sub-pixel
   position), css-lists 43 (`@counter-style`, `::marker` content),
   css-color 40 (relative colours), css-display run-in 37 (no browser
   implements run-in), css-variables 33 (CDC tokens, braces in
   `@supports`), css-tables 31, css-position 29 (sticky 14).

4. **Exposed gaps behind many failures:** vertical writing modes (768
   tests across directories), `@namespace` in selectors, animations and
   transitions, `text-wrap: balance`, counter styles beyond the basic
   list (`@counter-style`, the CJK and alphabetic systems),
   `hanging-punctuation`, variable-font instances, `contain-intrinsic-size`,
   multi-column layout (the lanes baseline tests' references use it),
   `margin-trim`, scrolling and clicking inside frames, hit-testing of
   transformed boxes (they are drawn moved but clicked where they are in
   the flow), transformed boxes resampled nearest-neighbour (no
   anti-aliasing), translucent opacity on inline boxes (floats inside
   them paint at full opacity; opacity 0 is handled).  Bidi, `<iframe>`,
   GSUB and GPOS shaping, Arabic joining, ligatures across edges, 2D
   transforms, grid lanes (Grid 3), subgrid, absolutes in grid areas and
   auto-fit collapsing are done (above); declarative shadow DOM is
   approximated (a `<template shadowrootmode>`'s content is shown in
   place, `<slot>`s are transparent).
5. **Sub-pixel layout.**  Layout positions are ints; Chromium uses 1/64 px.
   Many near-miss reftests (a few hundred pixels at glyph edges) come
   from this.  Large change; do it deliberately.
6. **Remaining plan milestones:** JavaScript (the seam is described in
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
| `appl/lib/web/layout.b` (subgrid) | `gridplace` (placement, shared), `issubgrid`, `subgridded`/`subitems` (sizing through a subgrid, `Gi.extra`/`Gi.empty`), `subtracks`/`regap`/`subgap` (its edges and gap out of its tracks), `fixedtracks`/`tracksizes`, `subnames`/`mergenames`, `clamplines`, `lanessub`, `namedspan`/`hasname`, `autosized` |
| `appl/lib/web/layout.b` (::first-letter) | `firstletter`, `firsttext`; `Tfit` tracks |
| `appl/lib/web/layout.b` (counters) | `Ctr`, `ctrprops`, `ctrfind`/`ctrincr`/`ctrset`, `counters`, `counterrep` |
| `appl/lib/web/layout.b` (canvas, frames) | `istag`, `hasimage`, `paintshadows`, `Box.doc` set by `build`, read by `lay` and `paint` |
| `appl/lib/web/layout.b` (aspect-ratio) | `ratiow`/`ratioh`, `transferred`/`noratio`, `isscroller`, `hasratio`, `sizew(b, cbw, cbh)` |
| `appl/lib/web/layout.b` (lines) | `tabw`, `removefrag`, `Ln.below`, `lbbase`, `inbox`; hanging `　` in `endline`; `transform(s, t, first, lang)`, `langof` |
| `appl/lib/web/layout.b` (sixth session) | `boxkind`, `parentof`, `cssdecode` callers, `canbreak`/`segwidth`/`wordgap`/`atomicbreak`, `lbmode`/`lbcjk`/`lbbreakall`, `pcth`/`pcthbox`/`definiteh`, `transferw`, `stretched`, `packh`, `tallband`/`shiftline`, `wstpass`, `eaw`, `armenian`/`georgian` |
| `appl/lib/web/html.b`, `module/web/html.m`, `module/web/dom.m` | `cssdecode`, `atcharset`, `utf16`, `Doc.charset` |
| `appl/lib/web/style.b` (sixth session) | `langmatch`/`subtags`, `word-space-transform`, `contain-intrinsic-size`, `fit-content()`, `line-break` modes, `overflow-wrap` levels, deprecated system colours, `var()` in `@supports` |
| `appl/lib/outlinefont.b` (`rasterize`) | vertical edge snapping |
| `tools/ref/wptrun.py` | serves wptserve `.headers` sidecars |
| `appl/lib/web/layout.b` (tables) | `collapsed`/`fight`/`stylerank`, `bhalf`/`widest`, `cellhalves`/`tablehalves`, `paintcollapsed`, `placecolumns`/`colspan`/`colbox`, `paintcolumns`, `tableabs`, `Tgrid.colpct`/`tb`, `blankrun(l, pre)` |
| `appl/lib/bidi.b`, `lib/bidi/linebreak`, `lib/bidi/case`, `lib/bidi/casex` | `lbclass` (UAX #14), `toupper`/`tolower`/`totitle` (`special`, `simple`, `turkic`); generators `tools/bidi/linebreak.py`, `tools/bidi/case.py` |
| `appl/lib/web/style.b` (this session) | `contain` (`CT` bits), `aspectauto`, `line-break`, `text-transform: full-width` (`TTfull`), display: none pseudo-elements not generated, the list-style shorthand's none |
| `module/web/layout.m` | `Box.doc`, `Box.tb`, `Tb`, `Bd` |
| `lib/web/html.css` | `html` has no background of its own |
| `appl/lib/bidi.b`, `lib/bidi/punct`, `tools/bidi/punct.py` | `punct(c)`: General_Category P*, from UnicodeData.txt |
| `appl/lib/web/style.b` (::first-letter) | `Computed.firstletter`, `pseudostyle` without content |
| `appl/lib/web/style.b` (grid lanes) | `display: grid-lanes`/`inline-grid-lanes` (and the two-value forms), `grid-lanes-direction`, `grid-lanes-pack`, `flow-tolerance`, `flow-start`/`flow-end` alignment keywords |
| `tests/web/fonts/liga.ttf` | a fontTools-made font with f+i and f+f+i ligatures, for `web_fonts_test` |
| `tests/` | `web_fonts_test`, `brotli_test`, `charonshot -b/-d`, `charonbatch`, fonts and Brotli vectors under `tests/web/`, fixture `charon/wpt/control-chars.html`, `grid-lanes-basic`/`grid-lanes-dense` fixtures, `web_style_test` GridLanes |

## Things that bit, so they need not again

- **`lib/bidi/linebreak` lacked U+00AD and U+2010** (both BA) though
  the generator reads LineBreak.txt; they were added by hand.  If the
  table is regenerated, check they are still there.
- **`grep -i error` on `mk install` output misses Limbo errors.**  The
  compiler prints `file.b:123: cannot make ...` or `near ... : syntax
  error` with no "error" word in the cases that matter (the latter has
  it; the former does not), and `redeclaration of local x` is a hard
  error when it names a local in the same scope but a warning in a
  nested one.  Filter with `grep -v warning` and look at what is left,
  or check `mk`'s exit status.  Half a session went into "fixes that
  do not take effect" that had never been compiled.
- **`to` is a Limbo keyword** (`case 1 to 5 =>`); `after`, `nxt` are
  fine as locals.  A `Len` literal has four fields:
  `Style->Len(Style->Lpx, 0.0, 0.0, nil)`.
- **Never `mk install` while a WPT run is going.**  r41 was polluted by
  mid-run rebuilds (23 "regressions", most of them the window when
  `layout.dis` was absent); the next run settled them.  Make the edits,
  wait for TOTAL, then build.
- **Runes are 16 bits in this VM.**  `&#x10A50;` arrives as U+0A50;
  astral characters cannot be represented in a Limbo string, so
  `first-letter-punctuation-337..345` (supplementary-plane
  punctuation) and anything with emoji cannot pass until the
  interpreter's `Rune` grows.
- **Chromium fails these too** (checked with the headless binary; the
  reference and test disagree, or antialiasing of overlapping text):
  `margin-bottom-applies-to-012..015`, `vertical-align-sub-001`,
  `vertical-align-super-001`, `text-transform-upperlower-016` (full
  case mapping of U+1F80 gives two characters, the reference expects
  one), `table-anonymous-objects-079..086` (the reference's abspos
  tables wrap), `letter-spacing-080` (reference uses a different
  margin), `table-anonymous-objects-017/018/177..200` (a cell's rounded
  width against a text run's real one, one pixel).  `column-visibility-
  004` we pass by the reference while Chromium does not.

- **`inherit()` in style.b copies inherited properties field by
  field.**  Adding an inherited property means adding it there as well
  as to `isinherited` and `copyprop`, or it inherits through the
  `inherit` keyword only (`lbmode` and `wst` were missed for a while).
- **Two properties sharing one field fight.**  `line-break: anywhere`
  and `word-break: break-all` both lived in `St.breakall`; the second
  declared wiped the first.  Give each property its own field, or make
  each setter preserve the other's state.
- **A text box carries its parent's style, display included.**  Any
  test of `k.st.display` on a child (`isrowgroup`, `iscolumn`) must
  exclude `Ktext`, or a row group holding text directly wraps the text
  in a table of its own and collapses to nothing.
- **A pseudo-element needs an identity of its own in counters**:
  numbered below zero (`-(2n)`, `-(2n+1)`), parent `n`, so that
  sibling-replacement and nesting rules see it as the element's first
  or last child.
- **`emu` start-up flakes can make a render differ wholesale** (48,457
  pixels on a test that differs by 128).  Re-render before chasing a
  regression that looks too large for the change.
- **Chromium fails some of these tests too** (`counters-scope-004`,
  `content-counter-006`, `counters-010`, `root-box-003`, `font-size-121`,
  `border-width-011`, `content-081`, `float-nowrap-8`, `numbers-units-015`
  needs Ahem's `ex`).  A "regression" that matches Chromium's rendering
  is the right behaviour; check with the Chromium binary under
  `/opt/pw-browsers` before undoing it.
- **Glyph edges smeared over two rows** were behind 65 one-row
  failures: the rasteriser now snaps a glyph's top and bottom to pixel
  rows (light hinting).  A reference that puts an Ahem glyph beside a
  sized box depends on this.
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
- **`bidi.b`'s `table()` reads every column as hex.**  The line-break
  table's class column is decimal and was read as hex for a whole run:
  CM became JT, ZWJ became EB, so words broke at bidi controls and
  joiners and never beside an ideographic space.  A new table with a
  decimal column needs its own case in `table()` (as `/linebreak` and
  `/classes` have).  Check a generated table with one known code point
  before trusting a run.
- **`curdoc` is whichever document was built last.**  A page with
  frames builds the frames' documents after its own, then paints the
  main one with a frame's document current: `istag` dereferenced nil
  (fixture `iframe-basic`, "no image").  `lay` and `paint` now set it
  from `Box.doc`; anything new that reads the DOM from layout or paint
  must go through the root's document, not a global set elsewhere.
- **A `.xht` copied to `.html` parses differently**: the XHTML tests
  wrap their CSS in `<![CDATA[`, which the HTML parser hands to the CSS
  tokenizer as junk, so the first rule is lost.  Keep the extension
  when copying a test under `tmp/t/` for a box dump.
- **`wptdiff.py` can report "identical" for a build that failed to
  compile**: it renders with the installed bytecode.  Check `mk`'s
  output before believing a render.
- **A one-argument helper named like a two-argument one** (`before`
  was the layer comparator) is a type error at the first call, not a
  clash at the definition; the compiler points at the call.

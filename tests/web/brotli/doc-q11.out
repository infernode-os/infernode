# Charon's new engine — design sketch

Status: **accepted** (decisions at the end); milestones 1–8 built: the new engine is the browser people launch (`wm/charon`, source `appl/charon/web.b`), the old one remains only for Xenith's render mode until milestone 9.
Owner of the question: what web browser would Bell Labs build?

## Why a new engine

Charon's renderer is the 1990s "item list" design: the HTML lexer feeds a
builder that emits a flat stream of text, image, rule and table items, and
the layout breaks that stream into lines. There is no document tree and no
box tree. CSS was later bolted onto the stream (`Item.Ibox`, ~150
`ComputedStyle` fields), but the model cannot express what CSS means:

- An element with no text has no items, so an empty `<div>` with a width,
  height and background does not exist.
- Block boxes shrink to their content instead of filling the containing
  block; flex items stack instead of forming a row; grid tracks collapse.
- There is no tree to match `:has()`, `:is()` or sibling selectors
  against, no place for margin collapsing, and no formatting contexts.

`tests/charon/wpt/` measures this: **6 of 32** fixtures pass. The fixtures
are small, so the gap is not polish. The old engine is ~16,000 lines
(`build.b`, `layout.b`, `lex.b`) and cannot be patched into a CSS engine.

## What Bell Labs would build

Not a smaller Chrome. The Plan 9 answer to any large program is the same:
find the data structures, make each stage a small piece with a plain
interface, and let the namespace do the integration. Concretely:

1. **Data dominates.** The engine is four data structures and the
   functions between them: a document tree, a style sheet, a box tree and
   a display list. Get those right and the code is obvious (Pike, rule 5).
2. **Arrays and integers, not object graphs.** A document is an array of
   nodes linked by integer indices. No cycles for the collector to chase,
   cheap to walk, and the JIT compiles index arithmetic well. Element and
   attribute names are interned to small integers (atoms) once, at parse
   time; everything after compares integers.
3. **One pass per stage, no caches until measured.** Parse, cascade, lay
   out, paint, each a function from one structure to the next. Incremental
   relayout comes later and only where a profile says so.
4. **Implement the spec's algorithms, not a superset.** Where a standard
   defines an algorithm (HTML tree construction, the CSS cascade, flex
   and grid sizing), follow its steps and cite the section. Where it
   defines a long tail (quirks mode, legacy presentational attributes),
   implement what real pages use and say what is left out.
5. **The browser is a file server.** What it shows can be read, and what
   it does can be driven, through `/mnt/charon`. An agent browses with
   `cat` and `echo`; a test asserts layout with `grep`. The network is a
   grant: the browser can reach what its namespace lets it reach.
6. **Widgets are Tk, drawing is draw(3).** Chrome and form controls are Tk
   widgets, themed with everything else. Page content is painted through
   the draw device's anti-aliased paths, so rounded borders, SVG and
   outline text come from one rasteriser, not a private one.
7. **JavaScript is a later client of the tree, not a part of it.** The
   document has a small mutation interface; a script engine, when there is
   one, is just another caller of it.

## The pipeline

```
bytes ─ html ─▶ Doc ─┐
                     ├─ style ─▶ styled Doc ─ layout ─▶ Box tree ─ paint ─▶ display list ─▶ draw(3)
css text ─ css ─▶ Sheet ┘                                   │
                                                  hit testing, /mnt/charon
```

Each arrow is one module with one entry point. Nothing reaches backwards.

| Module | In | Out | Spec |
|---|---|---|---|
| `html` | bytes, charset | `Doc` | WHATWG HTML §13.2 tokenizer and tree construction |
| `css` | text | `Sheet` | CSS Syntax 3, Selectors 4, Nesting, Cascade 5 (`@layer`), MQ 4, `@supports` |
| `style` | `Doc`, `Sheet`s, viewport | computed `Style` per element | CSS Cascade 5, Values 4 (`calc`, `var`, units) |
| `layout` | styled `Doc`, viewport | `Box` tree with geometry | CSS 2.2 visual formatting, Flexbox 1, Grid 1, Tables 3, Position 3 |
| `paint` | `Box` tree | display list | CSS 2.2 Appendix E stacking order, Backgrounds 3 |
| `font` | family, size, weight, style | metrics, glyph runs | CSS Fonts 4 matching (subset) |

### The document (`module/web/dom.m`)

```limbo
Node: adt {
	kind:	int;		# Element, Text, Comment, Doctype
	tag:	int;		# atom: Adiv, Aspan, ...; 0 for non-elements
	parent, first, last, next, prev:	int;	# indices into Doc.nodes; 0 = none
	attrs:	list of (int, string);	# (atom, value)
	text:	string;		# Text and Comment
	style:	ref Style;	# set by style; nil until then
};
Doc: adt {
	nodes:	array of ref Node;	# node 0 is the document
	n:	int;
	free:	int;		# freed slots, chained through next
	atoms:	ref Atoms;	# name <-> atom
	# the mutation interface, also the JS seam
	create:	fn(d: self ref Doc, kind, tag: int, text: string): int;
	append:	fn(d: self ref Doc, parent, child: int);
	insert:	fn(d: self ref Doc, parent, child, before: int);
	remove:	fn(d: self ref Doc, child: int);
	setattr:	fn(d: self ref Doc, n, attr: int, val: string);
	settext:	fn(d: self ref Doc, n: int, s: string);
	dirty:	int;		# generation; bumped by every mutation
};
```

The parser uses only the mutation interface, so whatever builds the tree
at load time is exactly what a script would call later.

### Styles

A `Style` is a flat adt of computed values (lengths in device pixels as
`int` or as a percentage tagged in the high bits, colours as RGBA `int`,
enumerations as `byte`). Elements with the same parent style and the same
matched rules share one `Style`. Selectors are compiled once into arrays
of simple-selector tests and matched right to left; rules are bucketed by
their rightmost id, class and tag so most elements test a handful of
rules, not all of them.

### Boxes

```limbo
Box: adt {
	node:	int;		# generating node (0 for anonymous)
	kind:	byte;		# Block, Inline, InlineBlock, Replaced, Flex, Grid, Table, ...
	st:	ref Style;
	x, y, w, h:	int;	# border box, relative to the containing block
	kids:	cyclic array of ref Box;
	lines:	array of ref Line;	# for a block that holds inline content
};
```

Layout is a recursive function from (box, available width) to (height,
baselines), with one routine per formatting context: block (margin
collapsing, floats as an exclusion list), inline (line boxes, white-space,
breaking), flex, grid, table. Positioned boxes are laid out after their
containing block is sized.

### The display list

An array of drawing operations in paint order: fill rect, fill/stroke
path (rounded borders, SVG), text run, image, push/pop clip, push/pop
layer (opacity). Painting the viewport is a walk over the list, clipped to
the dirty rectangle; scrolling repaints from the list without relayout.
The same list serves hit testing in reverse.

### Fonts

Text is drawn from TrueType outlines through `outlinefont`, which fills
glyphs with the draw device's anti-aliased paths, so any size, weight or
slant a style asks for is available. The tree ships DejaVu (Sans, Serif,
Mono; regular, bold, oblique; ~6 MB, free licence) as the default faces,
with the existing pre-rendered DejaVu subfonts as the fallback when a face
is missing. Glyphs are cached per (face, size) as masks, so a page draws
each distinct glyph once. Web fonts (`@font-face`) come after.

## Widgets: Tk

Chrome (location bar, back/forward/reload, status, find) is a Tk window,
themed by lucitheme like every migrated app. The page is a Tk canvas: one
image item holding the painted viewport and one window item per form
control. Form controls are real Tk widgets (`entry`, `button`,
`checkbutton`, `radiobutton`, `text` for `textarea`, a menubutton or
listbox for `select`). Layout asks a control for its natural size, CSS
`width`/`height`/`font`/`color`/`background` map to Tk options, and an
element with `appearance: none` is painted by the engine instead. Keyboard
focus, text editing, selection and IME behaviour come from Tk rather than
being re-implemented, as the old engine did (~1,800 lines of `Control`).

## The file interface

Placement: `/mnt/charon`, a tree Charon synthesizes (NAMESPACE-LAYOUT).
It replaces the polled plain files under `/tmp/veltro/browser/`.

```
/mnt/charon/
	ctl		write: open <url> | back | forward | reload | stop | width <px>
	url		read: current URL
	title		read: document title
	status		read: loading | done | error <msg>
	text		read: rendered text, in reading order, one block per line
	links		read: one per line: <n> <url> <text>
	forms		read: one field per line: <form> <name> <type> <value>
	find		write: <text>; read: matching lines
	image		read: the rendered viewport, in image(6) format
	event		read: one line per navigation or load event, blocking
	dom/		the document, one directory per element:
		<n>/	tag  attrs  text  style  box  children
```

```
; echo open file:///tests/charon/wpt/flex-row.html > /mnt/charon/ctl
; cat /mnt/charon/status
done
; cat /mnt/charon/dom/5/box
block 0 0 100 100
; cat /mnt/charon/dom/5/style | grep display
display flex
```

Posting: `/mnt/charon` is a mount in the browser's own name space, so
it alone would not reach an agent whose name space was built before the
browser started. The browser therefore also posts the session as
`#scharon/fs`: `#s` with a spec is one directory per spec and user across
every name space, Inferno's `/srv`, and each open of the posted file is
its own 9P connection (`mount -A '#scharon/fs' /mnt/charon`). Agents run
with `NODEVS`, which refuses `#s` with a spec, so they cannot attach it
themselves: tools9p mounts it at `/mnt/charon` for the charon tool only,
before `NODEVS`, and nsconstruct grants that path to that tool only.
`event` also carries `update` when a form control changes, so the window
repaints when an agent fills in a field.

`dom/<n>/box` and `style` make layout assertable from the shell, which is
how most engine tests are written: no pixels, no images. The `dom/` tree
is read-only; driving a page is done through `ctl` and `forms`.

**Agents.** `text`, `links`, `forms`, `status`, `title`, `url` and `dom/`
are safe to grant: they are reads of what was already fetched. `ctl` is an
egress capability (it makes the browser fetch), so granting it is granting
network reach, bounded by whatever the browser's own namespace can dial.
The two are not paired by default.

**Network.** The new engine fetches through `webfs` (`/mnt/web`), so a
browser's reach is literally a mount: bind a different `webfs` (or none)
and the same browser sees a different (or no) network. `webfs` gains what
a browser needs first: a cookie jar, an HTTP cache, `data:` and `file:`
URLs, and content decoding. Charon's private HTTP/TLS transport goes when
the old engine does.

Done (7a): `webfs` fetches concurrently (one slow resource stalls only its
own readers); keeps one RFC 6265 cookie jar per instance, readable and
writable as `/mnt/web/cookies`, so a browsing session is a mount;
decodes gzip and deflate; and reports the URL that answered (`N/url`,
which the engine uses as the document's base) and the response header
(`N/header`). The engine fetches a page's sheets and images six at a time.
`data:` and `file:` stay in the engine, which reads them without
`webfs`: neither touches the network. Still to come: the HTTP cache. See
webfs(4).

## Conformance, measured

Charon is judged by how pages look against references, with the tools
in `tools/ref` (see its README):

- **web-platform-tests reftests**, test and reference both rendered by
  Charon and compared pixel for pixel. Over the CSS directories
  (CSS2, flexbox, grid, selectors, cascade, values, color, backgrounds,
  text, display, position, sizing, box, tables, lists, variables,
  nesting, fonts; 12,911 judged, 982 more need script): 37.8% at the
  first run, **46.4%** now. `tools/ref/wptcmp.py` compares two runs;
  every regression is looked at before a change goes in.
- **Live sites against Chromium** (scripts off), through a caching
  mirror so both render the same bytes: pypi.org's home page went from
  47.8% of pixels differing to 6.6%. `tools/ref/boxdiff.py` lists the
  elements whose boxes differ from Chromium's, in document order, which
  is how most of these were found: the first wrong height explains the
  rest.

The live sites reachable from the development sandbox are few (its
egress policy); the mirror replays whatever has been fetched.

## The JavaScript seam

There is no JS engine in this plan. The design leaves exactly one place
for one:

- The `Doc` mutation interface above is the DOM's write side; reads are
  the node fields. A script host binds these to its object model.
- Every mutation bumps `Doc.dirty`; the browser restyles and relays out
  from the root when it changes (incremental later, if measured).
- Events (click, input, submit, load) are delivered by the browser to a
  channel the script host reads, and default actions run only if the host
  replies "not cancelled". Without a host, the reply is implicit.
- `<script>` elements are kept in the tree (not executed) and their text
  is available, so a host can run them in document order.

The tree's single owner is the browser's main process; a script host runs
in its own process and calls in over a channel, so a script that loops
forever stalls only itself.

## Size and speed budget

Targets, to be held to: the engine (html, css, style, layout, paint, font)
in under 12,000 lines of Limbo; a 100 KB article page parsed, styled and
laid out in under 200 ms under the JIT on a 2020 laptop. The old engine
and its builder are deleted when the new one passes everything they did.

## Plan

Each milestone ends with the fixture score, and fixtures are added as
features land. The new engine sits behind `-engine new` until it passes
every fixture the old one does, then becomes the default; the old engine
is then removed.

| # | Milestone | Fixtures expected |
|---|---|---|
| 1 | `dom`, `html` tokenizer + tree builder, unit tests | parser tests |
| 2 | `css` parser (Syntax 3, Selectors 4, nesting), `style` cascade | selector, cascade, var/calc |
| 3 | block + inline layout, paint, fonts (nearest size); render mode | block, margins, text |
| 4 | floats, positioning, overflow, stacking | float, position |
| 5 | flex, grid | flex, grid |
| 6 | tables, lists, generated content | table, list |
| 7 | images (PNG, JPEG, GIF, SVG via readsvg, WebP), `data:` URLs | img |
| 7a | `webfs`: cookie jar, cache, `data:`/`file:`, content decoding; engine fetches only through `/mnt/web` | network |
| 8 | Tk chrome + canvas viewport + form controls; `/mnt/charon` | interactive |
| 9 | default switch; old engine removed | everything |

## Decisions (2026-10-01)

1. **The rewrite**: yes. New modules under `appl/lib/web/`
   (`/dis/lib/web/*.dis`, interfaces in `module/web/`), usable by Xenith
   and Veltro as well as Charon.
2. **TrueType fonts ship** (~6 MB) for arbitrary sizes, weights and
   slants; the bitmap subfonts are the fallback.
3. **`/mnt/charon`** is the browser's interface, replacing
   `/tmp/veltro/browser/`; the Veltro `charon` tool moves with it.
4. **Network via `webfs` now**: the new engine never dials; `webfs`
   grows cookies, caching and the URL schemes it needs.

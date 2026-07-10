# Geo-Map: a Matrix display module for georeferenced data

**Status:** Phase 1 implemented (renderer + fixture); event/ctl/view and
raster layers are Phase 3.

This document specifies a map display surface for InferNode's Matrix
runtime — a pannable, zoomable map that renders georeferenced
**entities** (moving units), **features** (drawn graphics: points,
lines, polygons), and, later, **overlays** (raster tiles / image
layers). The map is protocol-agnostic: it renders a generic geo model
served as files, and anything that can write that model — a GPS feed, a
vessel tracker, a sensor-fusion service, a simulation — can drive it.
Translators for specific external feeds live out of tree and map their
sources onto this contract; the renderer never learns their protocols.

The load-bearing design decision: get the **data contract** between the
renderer and its data source right, and the renderer and any feed
translator can be built independently.

---

## 1. Why this is a Matrix module, and why raw Draw

### 1.1 It is just another `MatrixDisplay`

Matrix (`appl/wm/matrix.b`, `module/matrix.m`) hands each display module
a `ref Draw->Image` and drives it through `init/resize/update/draw/
pointer/key/retheme/shutdown`. `geo-map` is the spatial sibling of the
existing `appl/matrix/position-table.b`: same lifecycle, same "read a 9P
mount, render into my region" shape, registered the same way in a
composition file (`lib/matrix/compositions/*`). No new runtime machinery.

### 1.2 Raw Draw, not Tk

A map wants direct `Draw` control and its own scene graph — projection,
z-ordered layers, and hit-testing of hundreds of moving icons — not
canvas items. The one thing a toolkit canvas would give "for free" (item
picking, scrolling) is exactly what a map implements custom anyway.
Every primitive the renderer needs exists in `module/draw.m`:
`poly`/`fillpoly` (polygons, sector fans), `line` (routes/leaders),
`ellipse`/`arc` (range rings), `bezspline` (smooth tracks), `text`
(labels), and `image.draw` blitting (raster tiles, icon sprites). Any
button/menu chrome a composition needs around the map is Tk's job, not
the module's.

---

## 2. The data contract — a generic geo model

This is the interface both halves are written against. It is
**filesystem-first** (InferNode-native, not a JSON blob): the source
serves files, the renderer reads files, and a human or test fixture can
`cat`/`echo` against it.

### 2.0 The Inferno idioms this leans on (not new mechanism)

| Need | Idiom | Precedent |
|------|-------|-----------|
| The live set of objects | **directory = the set**; a file appears/vanishes as the object does | `/prog`, `/net/tcp` |
| "Tell me when it changed" | **blocking read = park-and-wake**, one event per read | `/dev/cons` |
| Drive the view | **`ctl` file**: write terse text commands | `/dev/draw`, `wmclient` |
| A structured record | **ndb `attr=value` tuples** — greppable, `ndb/query`-able | `lib/ndb/*` |
| Tiles / overlays | **synthesise on open**, cache lazily; path *is* the request | `ndb/cs`, `ndb/dns` |

The map is therefore "just a filesystem": a `cat`/`echo`/`grep` session
against the geo tree is a complete, debuggable interface, and a headless
agent on another box mounts the same tree and sees the same picture.

### 2.1 Namespace layout

```
<geo>/
    ctl                     (w)   "center <lat> <lon>", "zoom <z>", "follow <id>", "clear"   [Phase 3]
    view                    (r)   current camera: "<lat> <lon> <zoom> <wpx> <hpx>"           [Phase 3]
    event                   (r)   BLOCKING; one change per read: "+<id>" / "-<id>"           [Phase 3]
    entities/                     one file per moving/point entity, name = entity id
        <id>                (r)   one ndb stanza (see 2.2)
    features/                     one file per drawn graphic, name = feature id
        <id>                (r)   one ndb stanza (see 2.3)
    layers/                       raster/overlay layers, lowest z first                      [Phase 3]
        <name>/
            meta            (r)   ndb stanza: "kind=tiles z=<n> opacity=<0-255> ..."
            tiles/<z>/<x>/<y>     (r)   image, synthesised/fetched on open
            image           (r)   image (when kind=image)
```

Design notes:

- **One file per object, directory = the live set** — the `/prog` /
  `/net/tcp` idiom. Removal of the file *is* the "entity gone" signal;
  no tombstone record needed. Phase 1's renderer detects change by a
  cheap scan (entry count + max mtime) and reloads on difference.
- **`event` (Phase 3) is an optimisation, not the source of truth.**
  The directories are. A client that ignores `event` and re-enumerates
  still sees a correct, current picture.
- **`ctl`/`view` (Phase 3)** are the write-command / read-state pair
  (the `/dev/draw` idiom) so an agent or any other mounter can drive
  follow/centre/zoom.

### 2.2 Entity record (moving units / point tracks)

One **ndb `attr=value` stanza** per file. Unknown attrs are ignored
(forward compatible). All attrs except `lat`/`lon` are optional.

```
id=ALPHA-6
lat=38.8895
lon=-77.0353
hae=80.0            # height above ellipsoid, metres (optional)
affil=friend        # friend|hostile|neutral|unknown  (abstract enum)
kind=ground         # ground|air|sea|subsurface|space|installation
label=ALPHA-6       # display label
symbol=             # opaque symbol token; renderer maps known tokens to glyphs, else dot
course=350          # degrees true (optional; drives leader/orientation)
speed=4.2           # m/s (optional)
stale=1719772800    # unix seconds; renderer dims past this (optional)
color=              # optional explicit RRGGBBAA override; else derived from affil
```

The `affil` enum is deliberately abstract. The renderer maps it to
colour (the conventional cyan/red/green/amber) without knowing any
richer classification scheme. `symbol` is an opaque token: the renderer
keeps a small built-in glyph table (dot, square, triangle, diamond) and
falls back to a coloured dot for unknown tokens; a feed translator may
put whatever token vocabulary it likes in there and richer glyph
mapping stays that translator's concern.

### 2.3 Feature record (drawn graphics)

```
id=GRAPHIC-1
type=polygon         # point|polyline|polygon|circle
points=38.90,-77.04 38.91,-77.03 38.89,-77.02   # lat,lon pairs
radius=500           # metres, for type=circle
color=FFCC00FF       # stroke RRGGBBAA
fill=FFCC0040        # fill RRGGBBAA (polygons/circles; optional)
width=2              # stroke px
label=OBJ BRAVO      # optional
```

Maps directly onto `Draw` calls: `polyline`→`line` segments,
`polygon`→`poly` + optional `fillpoly`, `circle`→`ellipse` with a
metres→pixels radius from the current projection.

### 2.4 Projection

The renderer owns projection; the model is always **WGS84 lat/lon**,
never pixels. `lib/geoproj` (`module/geoproj.m`) is a small name-keyed
registry mapping lat/lon to a unit world square and back; Web Mercator
is the default (the de-facto tile standard, so standard slippy-map
tiles drop in later — the zoom/pixel scale already matches), with
equirectangular as the alternative. Keeping pixels out of the model is
what lets the same tree feed a 200px tile and a fullscreen view
unchanged.

---

## 3. The renderer — `geo-map`

**Files:** `appl/matrix/geo-map.b` (display module),
`appl/lib/geoproj.b` (projections), `appl/matrix/geo-fixture.b` (a
`MatrixService` writing a synthetic scenario so the map is demoable in
stock InferNode — `lib/matrix/compositions/geo-demo` wires the pair).

Layered scene graph, drawn back-to-front in `draw(dst)`:

1. **Base layer** — graticule with nice-stepped, labelled parallels and
   meridians; raster tiles (`layers/`) in Phase 3.
2. **Feature layer** — polygons/lines/circles.
3. **Entity layer** — glyphs coloured by affiliation, with optional
   true-bearing course leaders and stale dimming.
4. **Label layer** — `text` labels.
5. **HUD** — projection name, zoom, centre, and a metres/km scale bar.

Interaction (`pointer`/`key`): drag to pan; wheel or `+`/`-` to zoom
(clamped 0–20); `h`/`j`/`k`/`l` pan; click within 14px selects an
entity; `f` centres on the selection.

Performance notes: Phase 1 reloads all records when the cheap
count+mtime scan reports change; the Phase 3 `event` reader makes
`update()` O(changed), and glyph `Image` caching keyed by
`(symbol, affil, stale)` turns a few hundred moving tracks into blits.

---

## 4. Phasing

- **Phase 1 — renderer + fixture (done).** Projection, pan/zoom,
  entity + feature + label layers, graticule base, hit-testing, HUD.
  Demoable on synthetic data; `tests/geomap_test.b` covers the
  projection maths.
- **Phase 2 — live feeds.** Out-of-tree translators write real data
  onto the contract; nothing in this tree changes.
- **Phase 3 — interactivity and overlays.** `ctl`/`view`/`event`,
  raster tile layers, entity click → agent context, glyph caching.

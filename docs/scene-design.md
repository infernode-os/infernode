# Scene: a general 2-D situation display for InferNode

**Status:** implemented — `lib/scene` (model, camera, renderer),
`scenefs` (the served scene: camera, clock, a stream of its changes),
`wm/scene` (a window showing a scene; composed into Matrix as an `app`
region, replacing `geo-map`), `scenereplay` (plays a recording back),
`scenedemo` (a synthetic producer).  Man pages: scene(1), scene(2),
scenefs(4); the Matrix library page for `scene-fixture`.

Scene generalises the earlier geo-map contract
from "georeferenced units on a Mercator map" to "things in a 2-D space,
over time": a simulation on a local metre grid, a board game, a network
laid out in the plane, a test rig replaying a log, and — unchanged — a
map. The same data drives a window, a Matrix pane, and an agent that reads and steers the view through files.

Nothing here is domain-specific. The renderer knows shapes, colours,
labels, headings and time; it does not know what the things are.

---

## 1. Pieces

| Piece | Kind | Role |
|---|---|---|
| `module/scene.m`, `appl/lib/scene.b` | library | The model (entities, features, layers, meta, clock), the record grammar, frames and camera, the renderer, hit-testing. Every other piece is a thin client of it. |
| `scenefs` (`appl/cmd/scenefs.b`) | 9P server | Serves one live scene at `/mnt/scene`: producers write it, viewers read it, anyone steers it through `ctl`. Owns the shared camera, and streams every change as records: reading that stream is recording. |
| `wm/scene` (`appl/wm/scene.b`) | window | Draws a scene directory — a `scenefs` mount or a plain directory — in an ordinary window: under `wm`, in a Lucifer activity, or in a Matrix `app` region. |
| `scenereplay` (`appl/cmd/scenereplay.b`) | filter | Plays a recording back as records, from a start time, paced by the recording's clock: `scenereplay run.scene > /mnt/scene/log`. |
| `scenedemo` (`appl/cmd/scenedemo.b`) | command | A synthetic producer (a field survey) writing records to a scene's `log`: a demo and a test load. |
| `scene-fixture` (`appl/matrix/scene-fixture.b`) | Matrix service | Mounts a `scenefs` and runs `scenedemo`, so `lib/matrix/compositions/scene-demo` works from the picker. |

The load-bearing decision is the same one geo-map made: **get the data
contract right** and the producers, the renderers and the agents are
built independently.

---

## 2. The scene directory (the data contract)

A scene is a directory. The minimum is the geo-map contract, so every
existing geo tree is already a valid scene:

```
<scene>/
    meta              ndb stanza: frame, projection, units, title, ...   (optional)
    time              the scene clock: one number                         (optional)
    entities/<id>     one ndb stanza per thing that moves
    features/<id>     one ndb stanza per drawn graphic
    layers/<id>       one ndb stanza per background layer                 (optional)
```

Stanza files are one `attr=value` per line; the value is the rest of the
line (so `label=Relay 2` needs no quoting). Unknown attributes are kept
and ignored — the format is forward compatible.

### 2.1 Frames

`meta` names the coordinate frame. Everything else is in that frame;
pixels never appear in the model.

| `frame=` | Positions | Notes |
|---|---|---|
| `geo` (default) | `lat=` `lon=`; points `lat,lon` | WGS84. `projection=mercator` (default) or `equirect`, via `lib/geoproj`. Metres for radii and scale bar come from the projection. |
| `xy` | `x=` `y=`; points `x,y` | Planar, **y up**, `units=` names the unit (default `m`) for the scale bar and HUD only. A simulation grid, a board, a floor plan. |

Other `meta` attributes: `title=`, `bounds=x0,y0 x1,y1` (the extent a
fit should show when there is no data yet), `trail=<n>` (default trail
length for every entity).

### 2.2 Entity (a thing that moves)

```
x=1250  y=830           # or lat= lon= in the geo frame (required)
label=Relay 2
shape=triangle          # dot|square|triangle|diamond|circle|cross|ring   (default dot)
color=35C7FFFF          # RRGGBBAA; else from group; else from affil; else amber
group=blue              # categorical colour by name (stable across runs)
course=90               # degrees, 0 = +y / north, clockwise; draws a heading leader
size=6                  # glyph radius, px
stale=312.5             # scene time after which the entity is drawn dimmed
trail=40                # remember and draw the last 40 positions
dim=1                   # draw dimmed regardless of time
```

For compatibility with the geo contract, `kind=` (air/sea/subsurface/
ground/installation) maps onto shapes and `affil=` (friend/hostile/
neutral/unknown) onto the fixed four-colour palette when `shape=`/
`color=`/`group=` are absent.

### 2.3 Feature (a drawn graphic)

As in the earlier geo contract: `type=point|polyline|polygon|circle`,
`points=`, `radius=` (in frame units: metres for geo, `units` for xy),
`color=`, `fill=`, `width=`, `label=`. Plus `dash=1` for a dashed
stroke. Features are drawn in file-name order, filled ones first.

### 2.4 Layers: the stack

```
kind=grid   step=100  color=223044FF          # a regular grid in frame units (auto step if absent)
kind=image  file=/lib/scene/floor.bit  bounds=x0,y0 x1,y1  opacity=160
kind=scene  dir=/n/mosaic/truth/scene  opacity=100
```

Layers draw below the scene's own features and entities, in name order
(so `10-terrain`, `20-coverage` stack as they sort). `grid` replaces the
default graticule/grid; `image` is a raster pinned to frame coordinates,
resampled to the camera and cached until it moves.

**A layer can be a scene.** `kind=scene dir=...` draws another scene
directory — plain files, a `scenefs`, a remote server's tree — with the
same camera, under this one. That is the whole composition model: a
stack is a scene whose layers are scenes, and it nests (to a depth of
4, so a scene that layers itself stops). At `opacity` below 255 the
layer's geometry is drawn off screen and blended once, so its own
overlaps do not double up. Labels from every layer are placed in one
pass, the scene in view first and deeper layers after, so the stack
never overprints. A layer in another frame is skipped (geo and xy
cannot share a camera).

The `dir` name resolves **in the viewer's namespace**: a viewer overlays
what it can see, and granting a scene grants nothing it names. So a
judge's display composes the commander's picture with the truth:

```
mkdir -p /tmp/judge/layers
echo 'frame=xy' > /tmp/judge/meta
{echo 'kind=scene'; echo 'dir=/n/mosaic/view/scene'} > /tmp/judge/layers/10-view
{echo 'kind=scene'; echo 'dir=/n/mosaic/truth/scene'; echo 'opacity=90'} > /tmp/judge/layers/20-truth
wm/matrix ...   # with: top app /dis/wm/scene.dis /tmp/judge
```

and the commander's own display, granted only `/n/mosaic/view`, cannot.
Any object — entity, feature or layer — with `hide=1` is not drawn, so a
human or an agent toggles a layer with one write. A scene with no
`layers/` gets the default grid; so does one whose layers draw no grid.

The other composition is the namespace's own: a union `bind` of several
producers' `entities/` directories is one scene with all their entities.

### 2.5 Clock

`time` holds one number in the scene's own units (seconds by
convention). The renderer shows it in the HUD and compares `stale=`
against it. Nothing else interprets it: a scene without `time` is simply
timeless.

---

## 3. `scenefs` — the served scene

A plain directory is enough for a static picture. A *live* scene wants
more: a camera several viewers share, a way for an agent to see and move
what the human sees, a cheap change signal, and a record of what
happened. `scenefs` serves the §2 directory plus a control surface:

```
/mnt/scene/
    ctl            (w)   one command per line (below)
    view           (r)   the shared camera: "frame F center A B zoom Z sel ID follow ID fit N"
    status         (r)   "t T gen G entities N features N layers N"
    event          (r)   BLOCKING; one event per read (below)
    changes        (r)   BLOCKING; every change as records (§3.3)
    log            (w)   batched update records (§3.2) — the ingest wire
    meta           (rw)
    time           (rw)
    entities/<id>  (rw)  create, write, remove — like a plain directory
    features/<id>  (rw)
    layers/<id>    (rw)
```

`scenefs` serves 9P on its standard input, the Inferno idiom:
`mount -c {scenefs} /mnt/scene`.

A producer may use either wire: write stanza files exactly as into a
plain directory (easy from `sh`: `echo ... > entities/r2`), or write a
batch of records to `log` (one write is seen whole — viewers never see
half a tick — which is what a simulation ticking hundreds of entities
wants; a bad record stops the write with an error, and the lines before
it stand). Stanza files behave as
files: a write lands at its offset and takes effect at once, so `echo >`
replaces, `echo >>` appends, and `rm` deletes.  (Taking effect on close
was tried and dropped: a shell's clunks arrive out of order.)

### 3.1 `ctl`

```
center A B        zoom Z        fit        follow ID        unfollow
select ID         deselect
clear             (drop every entity, feature and layer; a recording keeps the clear)
```

Camera commands change `view` for every viewer: a human panning in one
window moves the picture an agent reads, and an agent writing
`follow r2` moves the human's picture. `select` is how a click reaches
an agent (as an `event`).  `fit` cannot be answered by the server, which
does not know any viewer's size: it posts a request number in `view`
(`fit N`), the first viewer to see it fits for its own size and writes
the camera back, and the request reads 0 again.  A fresh scene starts
with a request; a viewer joining a scene whose camera is set adopts it.

### 3.2 Records (`log`, `changes`, recordings)

One record per line, fields space-separated, rc-style quoting for values
with spaces:

```
time 12.5
ent r2 x=1250 y=830 'label=Relay 2' shape=triangle group=blue
feat ao type=polygon 'points=0,0 2000,0 2000,2000 0,2000' color=5A6B82FF
layer g kind=grid step=250
meta frame=xy units=m 'title=Search area'
del ent r2
clear
```

`ent`/`feat`/`layer` *replace* the object's stanza (a full state, not a
patch), so any suffix of a recording after a `clear` is
self-contained.

### 3.3 Recording and replay: `changes` and `scenereplay`

`scenefs` keeps the scene as it stands, and no history. Time travel is
not a server mode; it is two ordinary programs on either side of it.

**Recording is reading.** `changes` is a blocking stream of every change
as §3.2 records, with a `time` record wherever the clock has moved. Each
open is its own cursor and begins with the scene as it stands (a `clear`
and the records that rebuild it), so whatever one open reads is a
self-contained recording:

```
cat /mnt/scene/changes > run.scene
```

Nothing is dropped: a reader that falls more than 4 MB behind is cut off
with an error rather than handed a recording with holes in it.

**Replay is writing.** `scenereplay [-t start] [-x rate] run.scene`
writes, on standard output, the scene as it stood at `start` as one
batch, then each tick's records as one write, paced by the recording's
clock (`-x 0`: as fast as the reader takes it). Pointed at a scene's
`log` it is just another producer:

```
scenereplay -t 120 -x 2 run.scene > /mnt/scene/log
```

So a review is a second `scenefs` fed by `scenereplay` while the live one
carries on; every viewer of that scene is in step because they share its
camera and clock, as with any producer. Seeking is running `scenereplay`
again from another start; pausing is stopping it. The pieces compose
with everything else that reads and writes files — `grep` a recording,
cut one with `sed`, tee a live run to two scenes.

(An earlier design kept the history and a playhead inside `scenefs`,
with `play`/`pause`/`seek` verbs. It served two scenes through one set of
files — which one a read saw depended on a mode — and put a recorder
and a player inside a file server. They are gone.)

### 3.4 `event`

Each open of `event` is its own cursor; a read blocks until something
happens and returns one line:

```
gen 42            # the visible scene changed (coalesced: only the latest is queued)
select r2         # a viewer selected r2
view ...          # the camera moved (same text as `view`)
```

Renderers poll `status` for `gen` instead (one small read per tick);
agents block on `event`.

### 3.5 Trust

`scenefs` holds no authority beyond the files it serves: it opens none.
Access is by placement — bind `/mnt/scene` into a namespace to grant it.
A grant that should watch but not steer is a second scene fed from the
first (`cat changes | scenereplay -x 0 > other/log`), not a mode flag.

---

## 4. Renderers

`lib/scene` draws, back to front: background, layers (or the default
grid/graticule), filled features, stroked features, trails, entity
glyphs with heading leaders, labels (decluttered), selection, HUD (frame,
scale bar, zoom and clock). Colours are allocated once per value
and cached; shapes are anti-aliased paths, filled and stroked by the
draw device (`docs/draw-geometry.md`).

- **`wm/scene`** (a window, 100 ms ticker). It polls `status` when the
  directory is a `scenefs` (reload only on a new `gen`), else falls back
  to a signature scan of the directories.  It keeps looking for a
  `status` file, because a scene may be mounted after the window starts.
  It follows the shared camera in `view` and writes its own
  pan/zoom/select back to `ctl`, so viewers and agents stay in step.
  Keys: `+`/`-` zoom, `h/j/k/l` pan, `f` fit; button 3 for a menu.  In
  Matrix it is an `app` region (`top app /dis/wm/scene.dis /mnt/scene`),
  so the same program is the standalone viewer and the composed pane.
- **Pictures are files.** Images stay in the Inferno image format inside
  the system: `present` shows `.bit` files. Conversion happens once, at
  the edge, when an image leaves (`tools/p9img2png.py` on the host).
  A window's picture, as it is on screen, is a file too: `wmsrv` serves
  each client's window read-only (wmsrv(2) `wsys`, the rio
  `/dev/wsys/<id>/window` shape), and a Lucifer activity's agent reads
  its own activity's windows with the `window` tool.
- **Agents** need nothing new. An agent granted `/mnt/scene` reads
  `status`, `view` and the stanza files, blocks on `event` for what a
  human selects, and steers with `ctl` (`follow`, `select`, `center`) —
  the human's window moves with it. To show a picture it saves the
  window with the `window` tool and hands the file to `present`.

---

## 5. Anti-aliasing and labels

Everything the renderer draws is anti-aliased by default.  The shapes
are Draw paths (`Image.fillpath`, `Image.strokepath`), rasterised in C
by the draw device with the exact area of each pixel they cover; see
`docs/draw-geometry.md`.  An earlier Limbo module, `aadraw`, did this
arithmetic in Dis and has been removed.

Labels are placed after the geometry, most important first (selection,
entities, features, grid), each at the first of several candidate
positions that collides with nothing already placed or reserved (the HUD,
the zoom buttons) and lies inside the pane; entity and feature labels get
a background halo.

## 6. Matrix runtime: per-region redraw

Before this work Matrix redrew every region whenever any region changed,
so a 25 fps video pane repainted a map (and every gauge) 25 times a
second. The runtime now keeps an off-screen image per display region and
calls a module's `draw` only when that region went stale — its `update`
reported a change, it consumed input, it was resized or rethemed; the
frame is composited from the cached images. The module interface is
unchanged.

---

## 7. The GPU

The GPU belongs under the draw device, not in applications; the plan,
and what is built, is in `docs/draw-geometry.md`.

---

## 8. Not yet

- Tile pyramids (`layers/<id>` with `kind=tiles`); only single images
  today.
- Selecting an entity in a scene layer: `hit` looks at the scene in view
  only.
- Interpolation between producer updates (the producer's tick rate is the
  display's motion rate).
- Seeking a long recording: `scenereplay -t` reads from the start, O(recording).
  Periodic full-state stanzas (the `clear` a new reader gets) would allow
  an index; not needed yet.

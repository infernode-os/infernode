#
# scene.m — a 2-D scene: model, record grammar, camera, renderer.
#
# A scene is things in a plane (or on the globe) over time: entities
# that move, features that are drawn, background layers, a clock.  It
# is served as a directory of ndb stanza files (docs/scene-design.md
# §2) and changed by one-line records (§3.2).  This library is the
# whole of the scene's semantics; scenefs and wm/scene
# are thin clients of it.
#
# Positions are always (a, b) in the order the frame writes them:
# (lat, lon) in the geo frame, (x, y) in the xy frame.  Pixels never
# appear in the model — the camera owns them.
#

Scene: module
{
	PATH:	con "/dis/lib/scene.dis";

	# frames
	GEO, XY: con iota;

	# object kinds
	ENT, FEAT, LAYER: con iota;

	# glyph shapes
	SDOT, SSQUARE, STRIANGLE, SDIAMOND, SCIRCLE, SCROSS, SRING: con iota;

	# render flags
	RHUD:	con 1<<0;	# title/zoom/clock strip and scale bar
	RGRID:	con 1<<1;	# default grid/graticule when the scene has no layers
	RCHIPS:	con 1<<2;	# zoom-in, zoom-out and fit buttons (see chiprects)

	# One entity, feature or layer.  attrs is the stanza as written,
	# in order — the source of truth; the fields below are parsed from
	# it by the model.
	Obj: adt
	{
		kind:	int;
		id:	string;
		attrs:	list of (string, string);

		haspos:	int;		# entity: a, b valid
		a, b:	real;		# entity position
		pts:	array of (real, real);	# feature points
		typ:	string;		# feature type / layer kind
		label:	string;
		shape:	int;
		col:	int;		# RRGGBBAA; hascol=0 means derive
		hascol:	int;
		fill:	int;
		hasfill: int;
		width:	int;
		size:	int;
		course:	real;
		hascourse: int;
		stale:	real;
		hasstale: int;
		trail:	int;
		dim:	int;
		dash:	int;
		radius:	real;
		step:	real;		# grid layer
		opacity: int;		# image and scene layers, 0..255
		file:	string;		# image layer
		bounds:	array of (real, real);	# image layer: two corners
		dir:	string;		# scene layer: the scene it draws
		sub:	cyclic ref Model;	# scene layer: that scene, as read
		hide:	int;		# hide=1: not drawn

		get:	fn(o: self ref Obj, k: string): string;
		text:	fn(o: self ref Obj): string;	# stanza, one attr per line
		record:	fn(o: self ref Obj): string;	# "ent id k=v ..." (quoted)
	};

	Model: adt
	{
		frame:	int;
		proj:	string;		# geo projection name
		units:	string;		# xy unit name
		title:	string;
		trail:	int;		# default trail length
		meta:	list of (string, string);
		t:	real;		# scene clock
		hast:	int;
		gen:	int;		# bumped on every change
		tabs:	array of ref Tab;	# by kind (internal)

		new:	fn(): ref Model;
		# Read a scene directory (meta, time, entities/, features/,
		# layers/), and the scenes its scene layers name.
		read:	fn(dir: string): ref Model;
		# (Re)read the scenes this model's scene layers name.
		resolve: fn(m: self ref Model);

		# Apply one record (docs/scene-design.md §3.2).  nil or error.
		apply:	fn(m: self ref Model, rec: string): string;
		# Replace an object's stanza.  attrs nil is allowed (an
		# empty stanza: kept, not drawn).
		set:	fn(m: self ref Model, kind: int, id: string, attrs: list of (string, string));
		del:	fn(m: self ref Model, kind: int, id: string): int;
		find:	fn(m: self ref Model, kind: int, id: string): ref Obj;
		clear:	fn(m: self ref Model);
		setmeta: fn(m: self ref Model, attrs: list of (string, string));
		settime: fn(m: self ref Model, t: real);
		# Objects of a kind, sorted by id.
		objs:	fn(m: self ref Model, kind: int): array of ref Obj;
		count:	fn(m: self ref Model, kind: int): int;
		metatext: fn(m: self ref Model): string;
		# Everything, as records that rebuild this state from empty.
		dump:	fn(m: self ref Model): string;
		# Data extent over entities and feature points: (ok, a0, b0, a1, b1)
		extent:	fn(m: self ref Model): (int, real, real, real, real);
	};

	# Internal hash table of objects of one kind.
	Tab: adt
	{
		b:	array of list of ref Obj;
		n:	int;
		sorted:	array of ref Obj;	# cache; nil when stale
	};

	# Camera: centre, zoom, the pixel rectangle.  Zoom is log2 of the
	# scale: 256*2^zoom px per world in the geo frame (the slippy-map
	# convention), 2^zoom px per unit in the xy frame.
	Cam: adt
	{
		r:	Draw->Rect;
		ca, cb:	real;
		zoom:	real;
		sel:	string;
		follow:	string;

		new:	fn(r: Draw->Rect): ref Cam;
		fwd:	fn(c: self ref Cam, m: ref Model, a, b: real): Draw->Point;
		inv:	fn(c: self ref Cam, m: ref Model, p: Draw->Point): (real, real);
		pan:	fn(c: self ref Cam, m: ref Model, dx, dy: int);
		zoomby:	fn(c: self ref Cam, m: ref Model, dz: real);
		zoomat:	fn(c: self ref Cam, m: ref Model, p: Draw->Point, dz: real);
		fit:	fn(c: self ref Cam, m: ref Model);
		# Frame units (metres for geo) per pixel at the centre.
		upp:	fn(c: self ref Cam, m: ref Model): real;
		# "frame F center A B zoom Z sel ID follow ID" (- for none)
		text:	fn(c: self ref Cam, m: ref Model): string;
		# Adopt center/zoom/sel/follow from a view line; returns 1 if changed.
		parse:	fn(c: self ref Cam, s: string): int;
	};

	# Per-entity position history for trails.
	Trails: adt
	{
		ids:	array of list of (string, ref Ring);

		new:	fn(): ref Trails;
		# Remember the current position of every entity with a trail.
		note:	fn(t: self ref Trails, m: ref Model);
		reset:	fn(t: self ref Trails);
		get:	fn(t: self ref Trails, id: string): array of (real, real);
	};

	Ring: adt
	{
		pts:	array of (real, real);
		n, head: int;
	};

	# Load the Draw-side state (colour cache, theme).  Must be
	# called before any rendering; the model and camera work without it.
	init:	fn(d: ref Draw->Display, f: ref Draw->Font);
	retheme: fn();

	# Draw the scene into c.r of dst.  hud is extra text for the HUD
	# strip (a playback mode, say); trails may be nil.
	render:	fn(dst: ref Draw->Image, m: ref Model, c: ref Cam, tr: ref Trails,
		   flags: int, hud: string);

	# The RCHIPS buttons: (zoom in, zoom out, fit).
	chiprects: fn(c: ref Cam): (Draw->Rect, Draw->Rect, Draw->Rect);

	# The entity nearest p within radius px, or nil.
	hit:	fn(m: ref Model, c: ref Cam, p: Draw->Point, radius: int): string;

	# A scene directory's change signature, its scene layers' included:
	# it changes when anything the renderer would draw does (for a
	# synthetic server with no useful mtimes, through the clock).
	signature: fn(dir: string): string;
	# The signatures of a model's scene layers alone.
	subsignature: fn(m: ref Model): string;

	# Parse helpers, exported for servers and tests.
	stanza:	fn(text: string): list of (string, string);	# ndb stanza
	attrs:	fn(toks: list of string): list of (string, string);	# k=v tokens
	kindname: fn(kind: int): string;	# "ent" "feat" "layer"
	kindof:	fn(name: string): int;		# inverse; -1 if unknown
	dirname: fn(kind: int): string;	# "entities" "features" "layers"
	parsecolor: fn(s: string): (int, int);	# (ok, RRGGBBAA)
	groupcolor: fn(name: string): int;
};

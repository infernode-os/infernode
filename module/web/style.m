#
# style.m - the cascade: from a document and its style sheets to a
# computed style for every element.
#
# A Styles holds the sheets that apply to a document, in cascade order,
# with their rules indexed for matching.  compute() walks the document,
# matches selectors, sorts the winning declarations by origin, layer,
# importance, specificity and order, substitutes var(), expands
# shorthands and computes values.  The result is one St per element
# (shared where elements have identical styles), plus St for the
# ::before and ::after pseudo-elements that have content.
#
# Values are computed as CSS defines it: lengths are in pixels, except
# that percentages are kept, because only layout knows what they are a
# percentage of.  A Len is px + pct% of that basis.
#
Style: module
{
	PATH:	con "/dis/lib/web/style.dis";
	UACSS:	con "/lib/web/html.css";

	init:	fn(): string;
	# how ex and ch are measured: (x-height, width of "0") in px
	setmetrics:	fn(f: ref fn(family: list of string, weight, italic: int, size: real): (real, real));

	# the media and environment a document is styled for
	Env: adt {
		width, height:	int;	# viewport, px
		dpr:	real;		# device pixels per CSS px
		dark:	int;		# prefers-color-scheme: dark
		print:	int;		# media type print, else screen
		hover:	int;		# element under the pointer, 0 if none
		focus:	int;		# focused element
		active:	int;		# element being clicked
		target:	int;		# element named by the URL fragment
	};

	# length kinds
	Lpx, Lauto, Lnone, Lnormal, Lnum, Lmin, Lmax, Lfit, Lcontent, Lcalc, Lstretch: con iota;

	Len: adt {
		kind:	int;	# Lpx: px + pct% of the basis; Lnum: a bare number (line-height);
				# Lcalc: needs the basis to evaluate (min/max/clamp with %)
		px:	real;
		pct:	real;
		e:	ref Expr;

		resolve:	fn(l: self Len, basis: real): real;	# auto and the like resolve to 0
		isauto:	fn(l: self Len): int;
	};

	# a calc() expression kept for layout; leaves are px + pct
	Expr: adt {
		op:	int;	# '+', '-', '*', '/', 'm' (min), 'M' (max), 'c' (clamp), 'n' (leaf)
		px, pct:	real;
		kids:	cyclic array of ref Expr;
	};

	# display
	Dnone, Dcontents, Dblock, Dinline, Dinlineblock, Dflowroot, Dlistitem,
	Dflex, Dinlineflex, Dgrid, Dinlinegrid, Dtable, Dinlinetable,
	Dtablerowgroup, Dtableheadergroup, Dtablefootergroup, Dtablerow,
	Dtablecell, Dtablecolumngroup, Dtablecolumn, Dtablecaption,
	Dgridlanes, Dinlinegridlanes: con iota;

	Pstatic, Prelative, Pabsolute, Pfixed, Psticky: con iota;	# position
	Fnone, Fleft, Fright: con iota;			# float
	Cnone, Cleft, Cright, Cboth: con iota;			# clear
	Bnone, Bhidden, Bsolid, Bdashed, Bdotted, Bdouble, Bgroove, Bridge, Binset, Boutset: con iota;	# border-style
	Ovisible, Ohidden, Oclip, Oscroll, Oauto: con iota;	# overflow
	# contain
	CTpaint, CTlayout, CTsize, CTstyle, CTinlinesize: con 1 << iota;
	Vvisible, Vhidden, Vcollapse: con iota;		# visibility
	Wnormal, Wpre, Wnowrap, Wprewrap, Wpreline, Wbreakspaces: con iota;	# white-space
	Astart, Aend, Aleft, Aright, Acenter, Ajustify, Aauto: con iota;	# text-align (auto: text-align-last only)
	TTnone, TTupper, TTlower, TTcap, TTfull: con iota;			# text-transform
	TDunder, TDover, TDthrough: con 1<<iota;			# text-decoration-line bits
	VAbaseline, VAtop, VAmiddle, VAbottom, VAtexttop, VAtextbottom, VAsub, VAsuper, VAlen: con iota;
	# unicode-bidi
	UBnormal, UBembed, UBisolate, UBoverride, UBisolateoverride, UBplaintext: con iota;
	FSnormal, FSitalic, FSoblique: con iota;			# font-style
	# flex/grid alignment
	ALnormal, ALstretch, ALstart, ALend, ALcenter, ALbaseline, ALbetween,
	ALaround, ALevenly, ALleft, ALright, ALauto,
	ALflowstart, ALflowend: con iota;	# grid lanes: the stacking flow's ends, which reversing swaps (Grid 3 §7)

	# a color is 16rRRGGBBAA; Ccurrent stands for currentcolor until computed
	Ctransparent:	con 0;
	Ccurrent:	con 16r00000001;

	Shadow: adt {
		x, y, blur, spread:	real;
		color:	int;
		inset:	int;
	};

	# one transform function (CSS Transforms 1 §7); for translate the
	# lengths x and y, for the rest the numbers v (angles in radians)
	TFtranslate, TFrotate, TFscale, TFskew, TFmatrix: con iota;
	# filter functions (Filter Effects 1 §5)
	Fblur, Fbrightness, Fcontrast, Fgrayscale, Fhuerotate, Finvert, Fopacity, Fsaturate, Fsepia: con iota;
	Filt: adt {
		op:	int;
		v:	real;	# blur: the standard deviation, px; hue-rotate: radians; the others: an amount, 1 = 100%
	};

	# what else makes a box a stacking context (St.ctx)
	SCisolate, SCblend, SCclippath, SCwillchange: con 1 << iota;

	# the colour spaces colours mix in (Color 4 §12), and how a hue goes round
	CSsrgb, CSsrgblinear, CSoklab, CSoklch, CSlab, CSlch, CShsl, CShwb, CSxyz, CSxyzd50: con iota;
	Hshorter, Hlonger, Hincreasing, Hdecreasing: con iota;

	Tf: adt {
		kind:	int;
		v:	array of real;
		x, y:	Len;
	};

	# one background layer
	Bg: adt {
		img:	ref Css->Tok;	# url(...) or a gradient function; nil for none
		rx, ry:	int;		# repeat in x, y (Rrepeat etc.)
		posx, posy:	Len;
		sizex, sizey:	Len;	# Lauto; Lcontent with px -1 = cover, -2 = contain
		clip, origin:	int;	# BOXborder etc.
		attfixed:	int;	# background-attachment: fixed
	};
	Rrepeat, Rnorepeat, Rspace, Rround: con iota;

	# border-image (Backgrounds 3 §6)
	Bimage: adt {
		src:	ref Css->Tok;	# url(...) or a gradient function; nil for none
		slice:	array of Len;	# top, right, bottom, left: Lpx numbers (pixels of the image) or percentages of it
		fill:	int;
		width:	array of Len;	# Lnum: that many border widths; Lauto: the slice's size; else a length or percentage of the border box
		outset:	array of Len;	# Lnum: that many border widths; else a length
		repx, repy:	int;	# BIstretch etc.
	};
	BIstretch, BIrepeat, BIround, BIspace: con iota;
	BOXborder, BOXpadding, BOXcontent, BOXtext, BOXborderarea: con iota;

	# a grid line: a number, a span, or auto
	Gline: adt {
		n:	int;		# 0 = auto
		span:	int;
		name:	string;
	};

	St: adt {
		display:	int;
		position:	int;
		float:	int;
		clear:	int;
		borderbox:	int;	# box-sizing: border-box
		width, height, minwidth, minheight, maxwidth, maxheight:	Len;
		aspect:	real;		# aspect-ratio, 0 = auto
		mt, mr, mb, ml:	Len;	# margins
		pt, pr, pb, pl:	Len;	# padding
		bt, br, bb, bl:	int;	# border widths, px (0 when style is none)
		bst, bsr, bsb, bsl:	int;	# border styles
		bct, bcr, bcb, bcl:	int;	# border colours
		rtl, rtr, rbr, rbl:	Len;	# corner radii
		top, right, bottom, left:	Len;	# inset
		z:	int;
		zauto:	int;
		overflowx, overflowy:	int;
		visibility:	int;
		opacity:	real;
		color:	int;
		bgcolor:	int;
		bg:	array of ref Bg;
		shadows:	array of ref Shadow;
		outlinew:	int;
		outlines:	int;
		outlinec:	int;
		outlineoff:	int;

		# text and fonts (inherited)
		family:	list of string;	# lower case; generic families as written
		fontsize:	real;	# px
		weight:	int;		# 100..900
		fontstyle:	int;
		smallcaps:	int;
		lineheight:	Len;	# Lnormal, Lnum (factor in px), or Lpx
		align:	int;
		alignlast:	int;
		indent:	Len;
		transform:	int;
		letterspacing:	real;
		wordspacing:	real;
		whitespace:	int;
		breakall:	int;	# word-break: break-all
		keepall:	int;	# word-break: keep-all 1, manual 2
		anywhere:	int;	# overflow-wrap: anywhere / break-word
		ellipsis:	int;	# text-overflow: ellipsis (not inherited)
		decoration:	int;	# TDunder etc. (not inherited; propagated by layout)
		decorationcolor:	int;
		decorationstyle:	int;
		valign:	int;
		valignlen:	Len;
		textshadows:	array of ref Shadow;
		dirrtl:	int;		# direction: rtl
		tabsize:	real;

		# lists and generated content
		liststyle:	string;	# disc, decimal, ..., "none"; or a <string> marker as "\"x\""
		listinside:	int;
		listimage:	ref Css->Tok;
		content:	array of ref Css->Tok;	# nil = normal/none
		quotes:	array of string;
		counterreset, counterincrement, counterset:	array of ref Css->Tok;

		# flex and grid
		flexdir:	int;	# 0 row, 1 row-reverse, 2 column, 3 column-reverse
		flexwrap:	int;	# 0 nowrap, 1 wrap, 2 wrap-reverse
		justifycontent, alignitems, alignself, aligncontent, justifyitems, justifyself:	int;
		grow, shrink:	real;
		basis:	Len;	# Lauto, Lcontent or a length
		order:	int;
		rowgap, colgap:	Len;	# Lnormal or a length
		gridcols, gridrows:	array of ref Css->Tok;	# track lists, unparsed
		gridareas:	array of string;
		autocols, autorows:	array of ref Css->Tok;
		autoflow:	int;	# 0 row, 1 column; +2 dense
		colstart, colend, rowstart, rowend:	Gline;
		gridarea:	string;	# named area, if grid-area names one

		# tables
		tablefixed:	int;
		collapse:	int;	# border-collapse: collapse
		spacingx, spacingy:	real;
		captionbottom:	int;
		hideempty:	int;

		# multi-column
		colcount:	int;	# 0 auto
		colwidth:	Len;
		colrulew:	int;
		colrules:	int;
		colrulec:	int;

		# replaced elements and the rest
		objectfit:	int;	# 0 fill, 1 contain, 2 cover, 3 none, 4 scale-down
		cursor:	string;
		pointer:	int;	# pointer-events not none
		appearance:	int;	# appearance not none
		accent:	int;	# accent-color
		caret:	int;
		vars:	ref Vars;	# custom properties
		sid:	int;		# serial number, for style sharing
		nokern:	int;		# font-kerning: none (or "kern" off)
		unicodebidi:	int;	# UBnormal ...
		safe:	int;		# "safe" alignment: bit 1 align-content, 2 justify-content, 4 align-items/self, 8 justify-items/self
		translated:	int;	# a transform applies (a stacking context)
		tx, ty:	Len;		# when it is a translation only: by how much (percentages of the box's own size)
		tfs:	array of ref Tf;	# otherwise the functions, in order (nil when a translation only)
		tox, toy:	Len;		# transform-origin
		wasinline:	int;	# blockified from an inline-level display: the static position of an absolute is an inline one

		# grid lanes (Grid 3)
		lanesdir:	int;	# grid-lanes-direction: 0 normal, 1 row, 2 column; +4 fill-reverse, +8 track-reverse
		lanespack:	int;	# grid-lanes-pack: 1 dense
		tolerance:	Len;	# flow-tolerance: Lnormal (1em), Lnone (infinite), or a length (% of the grid axis)
		subcols, subrows:	int;	# grid-template-columns/rows: subgrid (the tokens are then its line names)
		contain:	int;		# contain: CT bits
		aspectauto:	int;	# aspect-ratio: auto <ratio>: a replaced box's natural ratio first, else the ratio of the content box
		lbmode:	int;		# line-break: 0 auto/normal, 1 loose, 2 strict (anywhere is breakall 2)
		cisw, cish:	Len;	# contain-intrinsic-size: the explicit intrinsic width and height under size containment (Lnone: none)
		wst:	int;		# word-space-transform: 0 none, 1 space, 2 ideographic-space (what a zero-width space and a wbr become)
		cliprect:	array of Len;	# clip: rect(top, right, bottom, left) on an absolutely positioned box (Lauto: that edge); nil for auto
		margintrim:	int;	# margin-trim: 1 block-start, 2 block-end, 4 inline-start, 8 inline-end
		hyphens:	int;		# hyphens: 0 none, 1 manual, 2 auto (as manual: no dictionary yet)
		hyphenchar:	string;	# hyphenate-character, auto resolved to "-" (an empty one shows nothing)
		textjustify:	int;	# text-justify: 0 auto, 1 none, 2 inter-word, 3 inter-character
		hangpunct:	int;	# hanging-punctuation: 1 first, 2 last, 4 force-end, 8 allow-end
		textautospace:	int;	# text-autospace: 0 normal (ideograph-alpha and ideograph-numeric), 1 no-autospace
		textwrap:	int;	# text-wrap-style: 0 auto, 1 balance, 2 stable, 3 pretty
		bimage:	ref Bimage;	# border-image, nil for none
		mask:	array of ref Bg;	# mask layers (Masking 1 §6): the same shape as background layers
		svgfill, svgstroke:	string;	# fill and stroke for an inline svg (inherited): none, currentcolor, #rrggbb or url(...); nil when not set
		dark:	int;	# color-scheme comes out dark (inherited): light-dark() takes its second colour
		fontvars:	list of (string, real);	# font-variation-settings: (axis tag, value), in order; nil for normal (inherited)
		stretch:	real;	# font-stretch (font-width), a percentage (inherited)
		slant:	real;	# font-style: oblique's angle, degrees (inherited)
		synth:	int;	# font-synthesis: 1 weight, 2 style (inherited)
		filter:	array of Filt;	# filter: its functions, in order; nil for none
		ctx:	int;	# SC bits: isolation, mix-blend-mode, clip-path, will-change making a stacking context
		objx, objy:	Len;	# object-position: px, and pct of the room left over

		new:	fn(): ref St;		# initial values
	};

	# custom properties: copy on write, shared with the parent when unchanged
	Vars: adt {
		tab:	array of list of (string, array of ref Css->Tok);
		get:	fn(v: self ref Vars, name: string): array of ref Css->Tok;
	};

	# origins
	UA, User, Author: con iota;

	Styles: adt {
		sheets:	list of (ref Css->Sheet, int, string);	# reversed: (sheet, origin, base url)
		idx:	ref Index;
		new:	fn(): ref Styles;
		add:	fn(s: self ref Styles, sh: ref Css->Sheet, origin: int, base: string);
		imports:	fn(s: self ref Styles, env: ref Env): list of string;	# @import URLs not yet loaded
	};
	Index: adt {
		id, class, tag:	array of list of ref Entry;	# hashed
		other:	list of ref Entry;
		n:	int;
		layers:	list of string;
		env:	ref Env;	# the environment whose media queries it reflects
	};
	Entry: adt {
		sel:	ref Css->Sel;
		decls:	array of ref Css->Decl;
		tier:	int;	# origin and layer, before importance
		order:	int;
		anc:	array of int;	# Bloom bits an element's ancestors must have
		mark:	int;	# candidate-gathering generation
	};

	# Computed styles for d's elements, indexed by node; before[n] and
	# after[n] are the pseudo-elements' styles where they generate boxes;
	# firstletter[n] is ::first-letter's where rules give it one.
	Computed: adt {
		st:	array of ref St;
		before, after, marker:	array of ref St;
		firstletter:	array of ref St;
		firstline:	array of ref St;	# ::first-line's, where rules give it one
		placeholder:	array of ref St;	# ::placeholder's, where rules give it one
	};

	compute:	fn(d: ref Dom->Doc, s: ref Styles, env: ref Env): ref Computed;
	match:	fn(d: ref Dom->Doc, n: int, sel: ref Css->Sel, env: ref Env): int;
	mediamatch:	fn(q: array of ref Css->Tok, env: ref Env): int;
	supports:	fn(cond: array of ref Css->Tok): int;
	color:	fn(v: array of ref Css->Tok): (int, int);	# (ok, RGBA)
	# two colours mixed f of the way in a colour space, a hue going round
	# as asked; a space's and a hue method's names (-1 unknown); whether
	# a space has a hue
	spacemix:	fn(a, b: int, f: real, space, hue: int): int;
	mixspace:	fn(name: string): int;
	huemethod:	fn(name: string): int;
	polar:	fn(space: int): int;
	dump:	fn(st: ref St): string;	# "property value" lines
	resolveurl:	fn(base, rel: string): string;	# RFC 3986 reference resolution
	anon:	fn(parent: ref St, display: int): ref St;	# an anonymous box's style
	addimport:	fn(url: string, sh: ref Css->Sheet);	# the sheet fetched for an @import
};

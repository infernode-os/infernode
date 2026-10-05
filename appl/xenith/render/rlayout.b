implement Rlayout;

include "sys.m";
	sys: Sys;

include "draw.m";
	drawm: Draw;
	Display, Image, Font, Rect, Point: import drawm;

include "rlayout.m";

include "mermaid.m";
	mermaid: Mermaid;

display: ref Display;
mermaid_tried := 0;  # lazy-load flag: 0=untried, 1=loaded or failed

# Layout state. Laid out with no image (img nil), a document draws
# nothing and is only measured: render does that first, to make the
# image exactly as tall as the document.
Lstate: adt {
	img: ref Image;       # Target image, or nil to measure
	style: ref Style;
	x: int;               # Current x position
	y: int;               # Current y position (top of line)
	left: int;            # Left edge of text: the margin, plus any indent
	right: int;           # Right edge of text
	m: int;               # Margin, in pixels
	f: array of ref Font; # Faces text is set in, by Bold|Italic; nil where there is none
	fb: int;              # f[0] stands in for a bold face: embolden it
	lh: int;              # Line height
	asc: int;             # Baseline, below the top of the line
	maxx: int;            # Rightmost x text has reached (measuring cells)
	mcache: list of (ref DocNode, ref Image);  # Mermaid diagrams, drawn once
};

# weights and slopes, as indices into Lstate.f
Bold: con 1;
Italic: con 2;

scale := 1;	# pixels to the point: $displayscale
fonts: list of (string, ref Font);	# styled faces opened, nil where there is none

init(d: ref Draw->Display)
{
	sys = load Sys Sys->PATH;
	drawm = load Draw Draw->PATH;
	display = d;
}

render(doc: list of ref DocNode, style: ref Style): (ref Draw->Image, int)
{
	if(style == nil || style.font == nil)
		return (nil, 0);

	width := style.width;
	if(width <= 0)
		width = 800;
	scale = getscale();

	# Lay out without drawing for the height, then draw
	ls := newstate(nil, style, width);
	renderblocks(ls, doc);
	height := ls.y + ls.m;
	if(height < style.font.height * 2)
		height = style.font.height * 2;

	r := Rect(Point(0, 0), Point(width, height));
	img := display.newimage(r, drawm->RGB24, 0, drawm->Black);
	if(img == nil)
		return (nil, 0);
	img.draw(r, style.bgcolor, nil, Point(0, 0));

	mc := ls.mcache;
	ls = newstate(img, style, width);
	ls.mcache = mc;
	renderblocks(ls, doc);

	return (img, ls.y);
}

newstate(img: ref Image, style: ref Style, width: int): ref Lstate
{
	m := px(style.margin);
	return ref Lstate(img, style, m, m, m, width - m, m,
		bodyfaces(style.font), 0, style.font.height, style.font.ascent, 0, nil);
}

px(n: int): int
{
	return n * scale;
}

# On a Retina display Xenith sets in pixels, $displayscale to the
# point, and binds each face's larger build over its name; spacing and
# rules scale with it.
getscale(): int
{
	fd := sys->open("/env/displayscale", Sys->OREAD);
	if(fd == nil)
		return 1;
	buf := array[8] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return 1;
	s := int string buf[0:n];
	if(s < 1)
		return 1;
	if(s > 4)
		return 4;
	return s;
}

# ---- Faces ----
#
# A family's styles are found by name: go.bold.22.font beside
# go.14.font (tools/gen-text-fonts.py builds Go's; DejaVu has
# unicode.sans.bold.N.font). Where a style is missing, bold is drawn
# twice a pixel apart and italic is underlined.

# The stem and size of a font file's name: (/fonts/combined/go, 14)
# for /fonts/combined/go.14.font, or (nil, 0)
fontname(f: ref Font): (string, int)
{
	name := f.name;
	if(len name < 6 || name[len name - 5:] != ".font")
		return (nil, 0);
	e := len name - 5;
	i := e;
	while(i > 0 && name[i-1] >= '0' && name[i-1] <= '9')
		i--;
	if(i == e || i < 2 || name[i-1] != '.')
		return (nil, 0);
	return (name[0:i-1], int name[i:e]);
}

# base's family in a style (nil for regular) at a size, or nil
styledfont(base: ref Font, style: string, size: int): ref Font
{
	(stem, nil) := fontname(base);
	if(stem == nil)
		return nil;
	name := stem;
	if(style != nil)
		name += "." + style;
	name += "." + string size + ".font";
	for(l := fonts; l != nil; l = tl l){
		(n, f) := hd l;
		if(n == name)
			return f;
	}
	f := Font.open(display, name);
	fonts = (name, f) :: fonts;
	return f;
}

# The style at size, or the nearest smaller size there is, down to the body's
sized(base: ref Font, style: string, size: int): ref Font
{
	(nil, body) := fontname(base);
	if(body <= 0)
		return nil;
	for(z := size; z >= body; z--)
		if((f := styledfont(base, style, z)) != nil)
			return f;
	return nil;
}

bodyfaces(f: ref Font): array of ref Font
{
	(nil, n) := fontname(f);
	return array[] of {f, sized(f, "bold", n), sized(f, "italic", n), sized(f, "bolditalic", n)};
}

# Headings: the first three larger than the body (11/7, 9/7 and 8/7:
# 22, 18 and 16 over 14) and bold, the fourth bold, the fifth and
# sixth medium. Returns the faces and whether the first is to be
# emboldened, for want of a bold one.
headfaces(base: ref Font, level: int): (array of ref Font, int)
{
	(nil, n) := fontname(base);
	size := n;
	case level {
	1 =>	size = (n*11 + 3) / 7;
	2 =>	size = (n*9 + 3) / 7;
	3 =>	size = (n*8 + 3) / 7;
	}
	bold := sized(base, "bold", size);
	bi := sized(base, "bolditalic", size);
	if(level >= 5){
		if((f := sized(base, "medium", size)) != nil)
			return (array[] of {f, bold, sized(base, "italic", size), bi}, 0);
	}
	if(bold != nil)
		return (array[] of {bold, bold, bi, bi}, 0);
	f := sized(base, nil, size);
	if(f == nil)
		f = base;
	return (array[] of {f, nil, nil, nil}, 1);
}

# The font for text in w (Bold|Italic), whether to embolden it, and
# whether to underline it, standing in for a missing italic
face(ls: ref Lstate, w: int): (ref Font, int, int)
{
	if((f := ls.f[w]) != nil)
		return (f, ls.fb, 0);
	ul := w & Italic;
	if((f = ls.f[w & Bold]) != nil)
		return (f, ls.fb, ul);
	return (ls.f[0], ls.fb | (w & Bold), ul);
}

# ---- Blocks ----

# Render a list of block-level nodes
renderblocks(ls: ref Lstate, doc: list of ref DocNode)
{
	inlist := 0;
	for(; doc != nil; doc = tl doc){
		node := hd doc;
		# a list's items sit together; the list is spaced as a
		# paragraph, from what follows and from a list of another kind
		islist := 0;
		if(node.kind == Nbullet || node.kind == Nnumber){
			islist = node.kind;
			if(node.kind == Nbullet && istask(node))
				islist = -1;
		}
		if(inlist && islist != inlist && (!islist || toplevel(node)))
			ls.y += ls.lh / 3;
		inlist = islist;
		case node.kind {
		Npara =>
			renderpara(ls, node);
		Nheading =>
			renderheading(ls, node);
		Ncodeblock =>
			rendercodeblock(ls, node);
		Nmermaid =>
			rendermermaid(ls, node);
		Nbullet =>
			renderbullet(ls, node);
		Nnumber =>
			rendernumber(ls, node);
		Nhrule =>
			renderhrule(ls);
		Nblockquote =>
			renderblockquote(ls, node);
		Ntable =>
			rendertable(ls, node);
		* =>
			# Treat as paragraph
			renderpara(ls, node);
		}
	}
}

# Render a paragraph
renderpara(ls: ref Lstate, node: ref DocNode)
{
	ls.x = ls.left;
	renderinlines(ls, node.children, 0, ls.style.fgcolor, 0);
	newline(ls);
	ls.y += ls.lh / 3;  # Paragraph spacing
}

# Render a heading, in the accent colour, nearer the text it heads
# than the text before it
renderheading(ls: ref Lstate, node: ref DocNode)
{
	level := node.aux;
	color := ls.style.linkcolor;
	if(color == nil || level >= 6)
		color = ls.style.fgcolor;	# the sixth level: medium, in the text's colour

	f := ls.f;
	fb := ls.fb;
	lh := ls.lh;
	asc := ls.asc;
	(ls.f, ls.fb) = headfaces(ls.style.font, level);
	ls.lh = ls.f[0].height;
	ls.asc = ls.f[0].ascent;

	if(level <= 2)
		ls.y += lh * 2 / 3;
	else
		ls.y += lh / 3;
	ls.x = ls.left;
	renderinlines(ls, node.children, 0, color, 0);
	newline(ls);
	if(level <= 1){
		# a rule under the first level, across the page
		ry := ls.y + px(2);
		fill(ls, Rect(Point(ls.left, ry), Point(ls.right, ry + px(1))), color);
		ls.y += px(4);
	}

	ls.f = f;
	ls.fb = fb;
	ls.lh = lh;
	ls.asc = asc;
	ls.x = ls.left;
	ls.y += lh / 4;
}

# Render a code block
rendercodeblock(ls: ref Lstate, node: ref DocNode)
{
	font := ls.style.codefont;
	if(font == nil)
		font = ls.style.font;

	txt := "";
	if(node.text != nil)
		txt = node.text;
	else
		txt = flattentext(node.children);
	txt = expandtabs(txt, 4);

	nlines := 1;
	for(i := 0; i < len txt; i++)
		if(txt[i] == '\n')
			nlines++;

	pad := px(6);
	blockh := nlines * font.height + 2 * pad;

	if(ls.img != nil){
		fill(ls, Rect(Point(ls.left, ls.y), Point(ls.right, ls.y + blockh)), ls.style.codebgcolor);
		ty := ls.y + pad;
		linestart := 0;
		for(i = 0; i <= len txt; i++){
			if(i == len txt || txt[i] == '\n'){
				line := "";
				if(i > linestart)
					line = txt[linestart:i];
				ls.img.text(Point(ls.left + pad, ty), ls.style.fgcolor, Point(0, 0), font, line);
				ty += font.height;
				linestart = i + 1;
			}
		}
	}

	ls.y += blockh + ls.lh / 3;
	ls.x = ls.left;
}

# Tabs to spaces, to stops every n columns
expandtabs(s: string, n: int): string
{
	t := "";
	col := 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c == '\t'){
			do{
				t[len t] = ' ';
				col++;
			}while(col % n != 0);
			continue;
		}
		t[len t] = c;
		col++;
		if(c == '\n')
			col = 0;
	}
	return t;
}

# Render a mermaid diagram inline within markdown.
# Loads the Mermaid module on first use; falls back to code block on failure.
# The diagram is drawn once, when the document is measured.
rendermermaid(ls: ref Lstate, node: ref DocNode)
{
	syntax := "";
	if(node.text != nil)
		syntax = node.text;
	if(len syntax == 0){
		rendercodeblock(ls, node);
		return;
	}

	im: ref Image;
	found := 0;
	for(l := ls.mcache; l != nil; l = tl l)
		if((hd l).t0 == node){
			im = (hd l).t1;
			found = 1;
			break;
		}
	if(!found){
		im = drawmermaid(ls, syntax);
		ls.mcache = (node, im) :: ls.mcache;
	}
	if(im == nil){
		# Mermaid missing, or the diagram failed: show its source
		rendercodeblock(ls, node);
		return;
	}

	width := ls.right - ls.left;
	imr := im.r;
	imh := imr.max.y - imr.min.y;
	imw := imr.max.x - imr.min.x;

	# Center horizontally if narrower than available width
	xoff := 0;
	if(imw < width)
		xoff = (width - imw) / 2;

	if(ls.img != nil){
		dst := Rect(Point(ls.left + xoff, ls.y), Point(ls.left + xoff + imw, ls.y + imh));
		ls.img.draw(dst, im, nil, imr.min);
	}

	ls.y += imh + ls.lh / 3;
	ls.x = ls.left;
}

drawmermaid(ls: ref Lstate, syntax: string): ref Image
{
	# Lazy-load mermaid module
	if(!mermaid_tried){
		mermaid_tried = 1;
		mermaid = load Mermaid Mermaid->PATH;
		if(mermaid != nil)
			mermaid->init(display, ls.style.font, ls.style.codefont);
	}
	if(mermaid == nil)
		return nil;

	width := ls.right - ls.left;
	if(width <= 0)
		width = 400;
	im: ref Image;
	{
		(im, nil) = mermaid->render(syntax, width);
	} exception {
	"*" =>
		return nil;
	}
	return im;
}

# Render a bullet list item: its level (aux) sets its indent and its
# mark, a disc, a ring, a square; a task item ([ ] or [x]) is marked
# with a box, filled when done
renderbullet(ls: ref Lstate, node: ref DocNode)
{
	level := node.aux;
	indent := level * px(20);
	kids := node.children;
	task := -1;
	if(kids != nil && (hd kids).kind == Ntext && (t := (hd kids).text) != nil &&
	    len t >= 3 && t[0] == '[' && t[2] == ']' && (t[1] == ' ' || t[1] == 'x' || t[1] == 'X')){
		task = t[1] != ' ';
		rest := pmd_stripws(t[3:]);
		kids = tl kids;
		if(len rest > 0)
			kids = ref DocNode(Ntext, rest, nil, 0) :: kids;
	}
	if(ls.img != nil){
		f := ls.f[0];
		x := ls.left + indent + px(6);
		if(task >= 0){
			sz := f.ascent * 3 / 4;
			y := ls.y + ls.asc - sz;
			r := Rect(Point(x, y), Point(x + sz, y + sz));
			if(task){
				fill(ls, r, ls.style.linkcolor);
				# a tick in the page's colour
				ls.img.line(Point(x + sz/5, y + sz/2), Point(x + sz*2/5, y + sz*3/4),
					drawm->Endsquare, drawm->Endsquare, (px(1)+1)/2, ls.style.bgcolor, Point(0, 0));
				ls.img.line(Point(x + sz*2/5, y + sz*3/4), Point(x + sz*4/5, y + sz/4),
					drawm->Endsquare, drawm->Endsquare, (px(1)+1)/2, ls.style.bgcolor, Point(0, 0));
			}else{
				t := px(1);
				fill(ls, Rect(r.min, Point(r.max.x, r.min.y + t)), ls.style.fgcolor);
				fill(ls, Rect(Point(r.min.x, r.max.y - t), r.max), ls.style.fgcolor);
				fill(ls, Rect(r.min, Point(r.min.x + t, r.max.y)), ls.style.fgcolor);
				fill(ls, Rect(Point(r.max.x - t, r.min.y), r.max), ls.style.fgcolor);
			}
		}else{
			mark := "•";
			case level % 3 {
			1 =>	mark = "◦";
			2 =>	mark = "▪";
			}
			ls.img.text(Point(x, ls.y), ls.style.fgcolor, Point(0, 0), f, mark);
		}
	}
	listitem(ls, kids, indent + px(24));
}

istask(node: ref DocNode): int
{
	if(node.children == nil || (hd node.children).kind != Ntext)
		return 0;
	t := (hd node.children).text;
	return t != nil && len t >= 3 && t[0] == '[' && t[2] == ']' && (t[1] == ' ' || t[1] == 'x' || t[1] == 'X');
}

toplevel(node: ref DocNode): int
{
	if(node.kind == Nbullet)
		return node.aux == 0;
	return node.text == nil || node.text == "0";
}

# Render a numbered list item; node.text is its level
rendernumber(ls: ref Lstate, node: ref DocNode)
{
	indent := 0;
	if(node.text != nil)
		indent = int node.text * px(24);
	if(ls.img != nil)
		ls.img.text(Point(ls.left + indent + px(2), ls.y), ls.style.fgcolor, Point(0, 0), ls.f[0],
			sys->sprint("%d.", node.aux));
	listitem(ls, node.children, indent + px(24));
}

listitem(ls: ref Lstate, kids: list of ref DocNode, indent: int)
{
	left := ls.left;
	ls.left += indent;
	ls.x = ls.left;
	renderinlines(ls, kids, 0, ls.style.fgcolor, 0);
	newline(ls);
	ls.left = left;
	ls.x = left;
}

# Render a horizontal rule
renderhrule(ls: ref Lstate)
{
	ls.y += ls.lh / 3;
	y := ls.y + ls.lh / 2;
	fill(ls, Rect(Point(ls.left, y), Point(ls.right, y + px(1))), ls.style.fgcolor);
	ls.y += ls.lh;
}

# Render a blockquote paragraph: a bar for each level it is nested (aux)
renderblockquote(ls: ref Lstate, node: ref DocNode)
{
	depth := node.aux;
	if(depth < 1)
		depth = 1;
	y0 := ls.y;

	left := ls.left;
	ls.left += depth * px(16);
	ls.x = ls.left;
	renderinlines(ls, node.children, 0, ls.style.fgcolor, 0);
	newline(ls);
	ls.left = left;
	ls.x = left;

	for(d := 0; d < depth; d++){
		bx := ls.left + d * px(16) + px(3);
		fill(ls, Rect(Point(bx, y0), Point(bx + px(3), ls.y)), ls.style.linkcolor);
	}

	ls.y += ls.lh / 4;
}

# Render a table node: node.text is its rows, one a line, cells
# separated by '|', the header first; node.aux the number of columns;
# node.children, if any, a text node of each column's alignment
# (l, c or r).
#
# Set as typographers set them (booktabs): columns as wide as their
# text, a gap between them and no vertical rules; a rule above and
# below the table, a lighter one under the header, and faint ones
# between rows. When the table would be wider than the page, columns
# narrow in proportion to their slack and their cells wrap.
rendertable(ls: ref Lstate, node: ref DocNode)
{
	if(node.text == nil || len node.text == 0)
		return;
	ncols := node.aux;
	if(ncols <= 0)
		ncols = 1;
	aligns := "";
	if(node.children != nil && (hd node.children).text != nil)
		aligns = (hd node.children).text;

	# The cells, as inline text
	rl: list of array of list of ref DocNode;
	lines := pmd_splitlines(node.text);
	for(li := 0; li < len lines; li++){
		if(pmd_isblank(lines[li]))
			continue;
		cs := pmd_splittablerow(lines[li]);
		row := array[ncols] of list of ref DocNode;
		for(c := 0; c < ncols && c < len cs; c++)
			row[c] = pmd_parseinline(pmd_trim(cs[c]));
		rl = row :: rl;
	}
	nrows := len rl;
	if(nrows == 0)
		return;
	rows := array[nrows] of array of list of ref DocNode;
	for(r := nrows - 1; r >= 0; r--){
		rows[r] = hd rl;
		rl = tl rl;
	}

	bodyf := ls.f;
	bodyfb := ls.fb;
	(headf, headfb) := headfaces(ls.style.font, 5);	# medium, the body's size

	# Each cell's width on one line, and each column's widest line
	# and widest word
	cellw := array[nrows] of array of int;
	nat := array[ncols] of {* => 0};
	narrow := array[ncols] of {* => 0};
	for(r = 0; r < nrows; r++){
		if(r == 0){
			ls.f = headf;
			ls.fb = headfb;
		}else{
			ls.f = bodyf;
			ls.fb = bodyfb;
		}
		cellw[r] = array[ncols] of int;
		for(c := 0; c < ncols; c++){
			(w, ww) := measurecell(ls, rows[r][c]);
			cellw[r][c] = w;
			if(w > nat[c])
				nat[c] = w;
			if(ww > narrow[c])
				narrow[c] = ww;
		}
	}

	gap := px(16);
	colw := fitcolumns(nat, narrow, ls.right - ls.left - (ncols - 1) * gap);
	tablew := (ncols - 1) * gap;
	for(c := 0; c < ncols; c++)
		tablew += colw[c];

	fg := ls.style.fgcolor;
	heavy := px(2);
	light := px(1);
	vpad := px(4);
	x0 := ls.left;
	left := ls.left;
	right := ls.right;

	ls.y += ls.lh / 4;
	fill(ls, Rect(Point(x0, ls.y), Point(x0 + tablew, ls.y + heavy)), fg);
	ls.y += heavy;
	for(r = 0; r < nrows; r++){
		if(r == 0){
			ls.f = headf;
			ls.fb = headfb;
		}else{
			ls.f = bodyf;
			ls.fb = bodyfb;
		}
		top := ls.y + vpad;
		bottom := top + ls.lh;
		cx := x0;
		for(c = 0; c < ncols; c++){
			off := 0;
			a := 'l';
			if(c < len aligns)
				a = aligns[c];
			if(cellw[r][c] <= colw[c]){
				if(a == 'r')
					off = colw[c] - cellw[r][c];
				else if(a == 'c')
					off = (colw[c] - cellw[r][c]) / 2;
			}
			ls.left = cx;
			ls.right = cx + colw[c];
			ls.x = cx + off;
			ls.y = top;
			clipr: Rect;
			if(ls.img != nil){
				clipr = ls.img.clipr;
				ls.img.clipr = Rect(Point(cx, clipr.min.y), Point(cx + colw[c], clipr.max.y));
			}
			renderinlines(ls, rows[r][c], 0, fg, 0);
			if(ls.img != nil)
				ls.img.clipr = clipr;
			if(ls.y + ls.lh > bottom)
				bottom = ls.y + ls.lh;
			cx += colw[c] + gap;
		}
		ls.y = bottom + vpad;
		if(r == 0 && nrows > 1){
			fill(ls, Rect(Point(x0, ls.y), Point(x0 + tablew, ls.y + light)), fg);
			ls.y += light;
		}else if(r > 0 && r < nrows - 1){
			fill(ls, Rect(Point(x0, ls.y), Point(x0 + tablew, ls.y + light)), ls.style.codebgcolor);
			ls.y += light;
		}
	}
	fill(ls, Rect(Point(x0, ls.y), Point(x0 + tablew, ls.y + heavy)), fg);
	ls.y += heavy + ls.lh / 2;

	ls.f = bodyf;
	ls.fb = bodyfb;
	ls.left = left;
	ls.right = right;
	ls.x = left;
}

# Column widths for a page avail wide, from each column's widest line
# (nat) and widest word (narrow). A column narrower than an even share
# of what is left keeps its width, so short columns never wrap; the
# rest share the remainder, each getting its widest word and a part of
# the slack above it in proportion to that slack. If not even that
# fits, they share by their widest words, and are clipped.
fitcolumns(nat, narrow: array of int, avail: int): array of int
{
	n := len nat;
	colw := array[n] of {* => -1};
	left := n;
	for(changed := 1; changed && left > 0;){
		changed = 0;
		share := avail / left;
		for(c := 0; c < n; c++)
			if(colw[c] < 0 && nat[c] <= share){
				colw[c] = nat[c];
				avail -= nat[c];
				left--;
				changed = 1;
			}
	}
	if(left == 0)
		return colw;
	sumnat := 0;
	sumnarrow := 0;
	for(c := 0; c < n; c++)
		if(colw[c] < 0){
			sumnat += nat[c];
			sumnarrow += narrow[c];
		}
	for(c = 0; c < n; c++){
		if(colw[c] >= 0)
			continue;
		if(sumnarrow >= avail){
			colw[c] = narrow[c];
			if(avail > 0 && sumnarrow > 0)
				colw[c] = narrow[c] * avail / sumnarrow;
			if(colw[c] < px(8))
				colw[c] = px(8);
		}else
			colw[c] = narrow[c] + (avail - sumnarrow) * (nat[c] - narrow[c]) / (sumnat - sumnarrow);
	}
	return colw;
}

# A cell's width set on one line, and the width of its widest word
measurecell(ls: ref Lstate, cell: list of ref DocNode): (int, int)
{
	img := ls.img;
	x := ls.x;
	y := ls.y;
	left := ls.left;
	right := ls.right;

	ls.img = nil;
	ls.left = ls.x = 0;
	ls.right = 1 << 30;
	renderinlines(ls, cell, 0, ls.style.fgcolor, 0);
	w := ls.x;
	ls.x = ls.maxx = 0;
	ls.right = 1;	# a word a line
	renderinlines(ls, cell, 0, ls.style.fgcolor, 0);
	ww := ls.maxx;

	ls.img = img;
	ls.x = x;
	ls.y = y;
	ls.left = left;
	ls.right = right;
	return (w, ww);
}

# Split a table row by '|' into its cells, dropping the outer pipes
pmd_splittablerow(row: string): array of string
{
	row = pmd_trim(row);
	if(len row > 0 && row[0] == '|')
		row = row[1:];
	if(len row > 0 && row[len row - 1] == '|')
		row = row[:len row - 1];

	# a pipe escaped with a backslash is the cell's, even in code
	nsep := 0;
	for(i := 0; i < len row; i++)
		if(row[i] == '|' && (i == 0 || row[i-1] != '\\'))
			nsep++;
	cells := array[nsep + 1] of string;
	ci := 0;
	cell := "";
	for(j := 0; j <= len row; j++){
		if(j == len row || (row[j] == '|' && (j == 0 || row[j-1] != '\\'))){
			cells[ci++] = cell;
			cell = "";
		}else if(row[j] == '\\' && j+1 < len row && row[j+1] == '|')
			;
		else
			cell[len cell] = row[j];
	}
	return cells;
}

# ---- Inline text ----

# lines drawn with text, as Ul|Strike
Ul: con 1;
Strike: con 2;

# Render inline nodes (text, bold, italic, code, links) with word
# wrapping, in weight w (Bold|Italic), colour color, and lined as ul
renderinlines(ls: ref Lstate, nodes: list of ref DocNode, w: int, color: ref Image, ul: int)
{
	for(; nodes != nil; nodes = tl nodes){
		node := hd nodes;
		case node.kind {
		Ntext =>
			rendertext(ls, node.text, w, color, ul);
		Nbold =>
			renderinlines(ls, node.children, w | Bold, color, ul);
		Nitalic =>
			renderinlines(ls, node.children, w | Italic, color, ul);
		Nstrike =>
			renderinlines(ls, node.children, w, color, ul | Strike);
		Ncode =>
			renderinlinecode(ls, node.text);
		Nlink =>
			lc := ls.style.linkcolor;
			if(lc == nil)
				lc = color;
			renderinlines(ls, node.children, w, lc, ul | Ul);
		Nnewline =>
			newline(ls);
		* =>
			# Recurse for nested structures
			if(node.children != nil)
				renderinlines(ls, node.children, w, color, ul);
			else if(node.text != nil)
				rendertext(ls, node.text, w, color, ul);
		}
	}
}

# Render text with word wrapping, on the line's baseline
rendertext(ls: ref Lstate, text: string, w: int, color: ref Image, underline: int)
{
	if(text == nil || len text == 0)
		return;

	(font, emb, ul) := face(ls, w);
	if(emb)
		emb = px(1);
	if(ul)
		underline |= Ul;	# for want of an italic
	dy := ls.asc - font.ascent;

	i := 0;
	for(;;){
		wordstart := i;
		while(i < len text && text[i] != ' ' && text[i] != '\t' && text[i] != '\n')
			i++;

		if(i > wordstart){
			word := text[wordstart:i];
			ww := font.width(word) + emb;
			if(ls.x + ww > ls.right && ls.x > ls.left)
				newline(ls);
			if(ls.img != nil){
				p := Point(ls.x, ls.y + dy);
				ls.img.text(p, color, Point(0, 0), font, word);
				if(emb)
					ls.img.text(p.add(Point(emb, 0)), color, Point(0, 0), font, word);
				decorate(ls, ls.x, ls.x + ww, font, color, underline);
			}
			ls.x += ww;
			if(ls.x > ls.maxx)
				ls.maxx = ls.x;
		}

		if(i >= len text)
			break;
		if(text[i] == '\n')
			newline(ls);
		else if(ls.x > ls.left){
			sw := font.width(" ");
			if(i + 1 < len text)	# join the words, not the last to what follows
				decorate(ls, ls.x, ls.x + sw, font, color, underline);
			ls.x += sw;
		}
		i++;
	}
}

# Render inline code with background
renderinlinecode(ls: ref Lstate, text: string)
{
	if(text == nil)
		return;
	font := ls.style.codefont;
	if(font == nil)
		font = ls.style.font;

	pad := px(3);
	tw := font.width(text);
	if(ls.x + tw + 2*pad > ls.right && ls.x > ls.left)
		newline(ls);

	dy := ls.asc - font.ascent;
	if(ls.img != nil){
		bgr := Rect(Point(ls.x, ls.y + dy), Point(ls.x + tw + 2*pad, ls.y + dy + font.height));
		ls.img.draw(bgr, ls.style.codebgcolor, nil, Point(0, 0));
		ls.img.text(Point(ls.x + pad, ls.y + dy), ls.style.fgcolor, Point(0, 0), font, text);
	}
	ls.x += tw + 2*pad;
	if(ls.x > ls.maxx)
		ls.maxx = ls.x;
}

# Move to next line
newline(ls: ref Lstate)
{
	ls.y += ls.lh;
	ls.x = ls.left;
}

# The underline (Ul) and strike (Strike) under or through x0 to x1
decorate(ls: ref Lstate, x0, x1: int, font: ref Font, color: ref Image, lines: int)
{
	if(lines & Ul){
		y := ls.y + ls.asc + px(2);
		fill(ls, Rect(Point(x0, y), Point(x1, y + px(1))), color);
	}
	if(lines & Strike){
		y := ls.y + ls.asc - font.ascent * 3 / 10;
		fill(ls, Rect(Point(x0, y), Point(x1, y + px(1))), color);
	}
}

fill(ls: ref Lstate, r: Rect, color: ref Image)
{
	if(ls.img != nil)
		ls.img.draw(r, color, nil, Point(0, 0));
}

# Flatten all inline children to plain text
flattentext(nodes: list of ref DocNode): string
{
	s := "";
	for(; nodes != nil; nodes = tl nodes){
		node := hd nodes;
		if(node.text != nil)
			s += node.text;
		if(node.children != nil)
			s += flattentext(node.children);
	}
	return s;
}

# ---- Markdown Parser (shared with mdrender and external callers) ----

# Parse markdown text into a list of DocNode blocks.
parsemd(text: string): list of ref DocNode
{
	doc: list of ref DocNode;
	lines := pmd_splitlines(text);

	# the indents of the list items open around the current one,
	# innermost first: an item's nesting level is its place in them
	indents: list of int;

	i := 0;
	nlines := len lines;
	for(;;){
		if(i >= nlines)
			break;
		line := lines[i];

		# Blank line - skip
		if(pmd_isblank(line)){
			i++;
			continue;
		}

		# A list item (- * + or 1. 1)), nested by its indent
		(mk, ind, nil, nil) := pmd_listmarker(line);
		if(mk != 0){
			while(indents != nil && ind < hd indents)
				indents = tl indents;
			if(indents == nil || ind > hd indents)
				indents = ind :: indents;
			(item, ni) := pmd_parseitem(lines, i, nlines, len indents - 1);
			doc = item :: doc;
			i = ni;
			continue;
		}
		inlist := indents != nil;
		indents = nil;

		# Indented code block: four spaces or a tab, not under a list item
		if(!inlist && (line[0] == '\t' || (len line >= 4 && line[0:4] == "    "))){
			(block, ni) := pmd_parseindented(lines, i, nlines);
			doc = block :: doc;
			i = ni;
			continue;
		}
		line = pmd_stripws(line);

		# Code block (```)
		if(len line >= 3 && line[0:3] == "```"){
			(block, ni) := pmd_parsecodeblock(lines, i);
			doc = block :: doc;
			i = ni;
			continue;
		}

		# Heading (#)
		if(len line > 0 && line[0] == '#'){
			(heading, ni) := pmd_parseheading(line);
			if(heading != nil){
				doc = heading :: doc;
				if(ni > i)
					i = ni;
				else
					i++;
				continue;
			}
		}

		# Horizontal rule (---, ***, ___)
		if(pmd_ishrule(line)){
			doc = ref DocNode(Nhrule, nil, nil, 0) :: doc;
			i++;
			continue;
		}

		# Blockquote (>)
		if(line[0] == '>'){
			(bqs, ni) := pmd_parseblockquote(lines, i, nlines);
			for(; bqs != nil; bqs = tl bqs)
				doc = hd bqs :: doc;
			i = ni;
			continue;
		}

		# Table (line contains '|' and next line is a separator)
		if(pmd_istablerow(line) && i+1 < nlines && pmd_istablesep(lines[i+1])){
			(tbl, ni) := pmd_parsetable(lines, i, nlines);
			if(tbl != nil){
				doc = tbl :: doc;
				i = ni;
				continue;
			}
		}

		# Setext heading: a line underlined with === (first level) or --- (second)
		if(i+1 < nlines && (u := pmd_setext(lines[i+1])) != 0){
			children := pmd_parseinline(pmd_trim(line));
			doc = ref DocNode(Nheading, nil, children, u) :: doc;
			i += 2;
			continue;
		}

		# Default: paragraph
		(para, ni) := pmd_parsepara(lines, i, nlines);
		doc = para :: doc;
		i = ni;
	}

	return pmd_reverselist(doc);
}

# 1 if line underlines a first-level setext heading (===), 2 a second (---)
pmd_setext(line: string): int
{
	line = pmd_trim(line);
	if(len line == 0 || (line[0] != '=' && line[0] != '-'))
		return 0;
	for(i := 0; i < len line; i++)
		if(line[i] != line[0])
			return 0;
	if(line[0] == '=')
		return 1;
	return 2;
}

# A list item's marker: (kind, indent, where its text starts, number);
# kind is Nbullet or Nnumber, or 0 if line is not a list item
pmd_listmarker(line: string): (int, int, int, int)
{
	ind := 0;
	i := 0;
	for(; i < len line; i++){
		if(line[i] == ' ')
			ind++;
		else if(line[i] == '\t')
			ind += 4;
		else
			break;
	}
	if(i >= len line)
		return (0, 0, 0, 0);
	c := line[i];
	if((c == '-' || c == '*' || c == '+') && i+1 < len line && line[i+1] == ' '){
		if(pmd_ishrule(line[i:]))
			return (0, 0, 0, 0);
		return (Nbullet, ind, i+2, 0);
	}
	j := i;
	while(j < len line && line[j] >= '0' && line[j] <= '9')
		j++;
	if(j > i && j - i < 10 && j+1 < len line && (line[j] == '.' || line[j] == ')') && line[j+1] == ' ')
		return (Nnumber, ind, j+2, int line[i:j]);
	return (0, 0, 0, 0);
}

# A list item and the lines that continue it: indented lines that are
# not items themselves. Nbullet: aux is the nesting level. Nnumber:
# aux is the number, text the nesting level.
pmd_parseitem(lines: array of string, start, nlines, level: int): (ref DocNode, int)
{
	(kind, nil, at, num) := pmd_listmarker(lines[start]);
	text := lines[start][at:];
	i := start + 1;
	while(i < nlines && !pmd_isblank(lines[i]) &&
	    (lines[i][0] == ' ' || lines[i][0] == '\t')){
		(k, nil, nil, nil) := pmd_listmarker(lines[i]);
		if(k != 0)
			break;
		text += " " + pmd_stripws(lines[i]);
		i++;
	}
	children := pmd_parseinline(pmd_trim(text));
	if(kind == Nbullet)
		return (ref DocNode(Nbullet, nil, children, level), i);
	return (ref DocNode(Nnumber, string level, children, num), i);
}

# An indented code block: lines indented four spaces or a tab, and the
# blank lines between them
pmd_parseindented(lines: array of string, start, nlines: int): (ref DocNode, int)
{
	code := "";
	i := start;
	last := start;
	for(; i < nlines; i++){
		line := lines[i];
		if(pmd_isblank(line)){
			if(len code > 0)
				code += "\n";
			continue;
		}
		if(line[0] == '\t')
			line = line[1:];
		else if(len line >= 4 && line[0:4] == "    ")
			line = line[4:];
		else
			break;
		if(i > start)
			code += "\n";
		code += line;
		last = i;
	}
	# trailing blank lines are not the code's
	n := len code;
	while(n > 0 && code[n-1] == '\n')
		n--;
	return (ref DocNode(Ncodeblock, code[0:n], nil, 0), last + 1);
}

# A block quote: its lines' text, one Nblockquote a paragraph, aux the
# depth of > marks (> > nests)
pmd_parseblockquote(lines: array of string, start, nlines: int): (list of ref DocNode, int)
{
	out: list of ref DocNode;
	text := "";
	depth := 0;
	i := start;
	for(; i < nlines; i++){
		line := pmd_stripws(lines[i]);
		if(len line == 0 || line[0] != '>')
			break;
		d := 0;
		while(len line > 0 && line[0] == '>'){
			d++;
			line = pmd_stripws(line[1:]);
		}
		if(pmd_isblank(line) || (d != depth && len text > 0)){
			if(len text > 0)
				out = ref DocNode(Nblockquote, nil, pmd_parseinline(text), depth) :: out;
			text = "";
			if(pmd_isblank(line))
				continue;
		}
		depth = d;
		if(len text > 0)
			text += " ";
		text += pmd_trim(line);
	}
	if(len text > 0)
		out = ref DocNode(Nblockquote, nil, pmd_parseinline(text), depth) :: out;
	r: list of ref DocNode;
	for(; out != nil; out = tl out)
		r = hd out :: r;
	return (r, i);
}

pmd_parsepara(lines: array of string, start, nlines: int): (ref DocNode, int)
{
	text := "";
	i := start;
	while(i < nlines){
		line := lines[i];
		if(pmd_isblank(line))
			break;
		if(i > start){
			s := pmd_stripws(line);
			if(len s > 0 && (s[0] == '#' || s[0] == '>'))
				break;
			if(len s >= 3 && s[0:3] == "```")
				break;
			if(pmd_ishrule(s) || pmd_setext(s) == 1)
				break;
			(k, nil, nil, nil) := pmd_listmarker(line);
			if(k != 0)
				break;
			# Stop at table rows
			if(pmd_istablerow(line))
				break;
		}
		# two spaces or a backslash at the end of a line break it there
		sep := " ";
		n := len text;
		if(n >= 2 && text[n-2:] == "  "){
			text = pmd_trim(text);
			sep = "\n";
		}else if(n >= 1 && text[n-1] == '\\'){
			text = text[0:n-1];
			sep = "\n";
		}
		if(len text > 0)
			text += sep;
		text += pmd_stripws(line);
		i++;
	}

	children := pmd_parseinline(pmd_trim(text));
	return (ref DocNode(Npara, nil, children, 0), i);
}


pmd_parseheading(line: string): (ref DocNode, int)
{
	level := 0;
	i := 0;
	while(i < len line && line[i] == '#'){
		level++;
		i++;
	}
	if(level == 0 || level > 6)
		return (nil, 0);
	while(i < len line && line[i] == ' ')
		i++;

	text := "";
	if(i < len line)
		text = line[i:];
	while(len text > 0 && text[len text - 1] == '#')
		text = text[:len text - 1];
	while(len text > 0 && text[len text - 1] == ' ')
		text = text[:len text - 1];

	children := pmd_parseinline(text);
	return (ref DocNode(Nheading, nil, children, level), 0);
}

pmd_parsecodeblock(lines: array of string, start: int): (ref DocNode, int)
{
	# Extract language hint from opening fence (e.g. "```mermaid" → "mermaid")
	lang := "";
	fence := lines[start];
	for(fi := 0; fi < len fence && fence[fi] == '`'; fi++)
		;
	if(fi < len fence){
		# Skip whitespace after backticks
		for(; fi < len fence && (fence[fi] == ' ' || fence[fi] == '\t'); fi++)
			;
		if(fi < len fence)
			lang = fence[fi:];
	}

	i := start + 1;
	code := "";

	while(i < len lines){
		if(len lines[i] >= 3 && lines[i][0:3] == "```"){
			i++;
			break;
		}
		if(len code > 0)
			code += "\n";
		code += lines[i];
		i++;
	}

	# ```mermaid blocks become Nmermaid nodes
	if(lang == "mermaid")
		return (ref DocNode(Nmermaid, code, nil, 0), i);

	return (ref DocNode(Ncodeblock, code, nil, 0), i);
}





pmd_parseinline(text: string): list of ref DocNode
{
	nodes: list of ref DocNode;
	i := 0;
	plain := "";

	while(i < len text){
		c := text[i];

		# A backslash makes the punctuation after it literal: \* \_ \` \|
		if(c == '\\' && i+1 < len text && pmd_ispunct(text[i+1])){
			plain[len plain] = text[i+1];
			i += 2;
			continue;
		}

		# Image: ![alt](url) — its alt text
		if(c == '!' && i+1 < len text && text[i+1] == '['){
			if(len plain > 0){
				nodes = ref DocNode(Ntext, plain, nil, 0) :: nodes;
				plain = "";
			}
			(linknode, ni) := pmd_parselink(text, i+1);
			if(linknode != nil){
				# Turn link node into plain text (alt text only, no click)
				# an image shows as its alt text
				alttxt := flattentext(linknode.children);
				if(alttxt != nil && len alttxt > 0)
					nodes = ref DocNode(Ntext, alttxt, nil, 0) :: nodes;
				i = ni;
				continue;
			}
			plain[len plain] = c;
			i++;
			continue;
		}

		# Strikethrough: ~~text~~
		if(c == '~' && i+1 < len text && text[i+1] == '~'){
			if(len plain > 0){
				nodes = ref DocNode(Ntext, plain, nil, 0) :: nodes;
				plain = "";
			}
			end := pmd_findclose(text, i+2, "~~");
			if(end > 0){
				inner := text[i+2:end];
				nodes = ref DocNode(Nstrike, nil, pmd_parseinline(inner), 0) :: nodes;
				i = end + 2;
				continue;
			}
			# No closing ~~ — emit literals
			plain[len plain] = c;
			i++;
			continue;
		}

		# Bold+italic: ***text*** (triple asterisk)
		if(c == '*' && i+2 < len text && text[i+1] == '*' && text[i+2] == '*'){
			if(len plain > 0){
				nodes = ref DocNode(Ntext, plain, nil, 0) :: nodes;
				plain = "";
			}
			end := pmd_findclose(text, i+3, "***");
			if(end > 0){
				inner := text[i+3:end];
				nodes = ref DocNode(Nbold, nil, ref DocNode(Nitalic, nil, pmd_parseinline(inner), 0) :: nil, 0) :: nodes;
				i = end + 3;
				continue;
			}
			plain[len plain] = c;
			i++;
			continue;
		}

		# Bold: **text** or __text__
		if((c == '*' && i+1 < len text && text[i+1] == '*') ||
		   (c == '_' && i+1 < len text && text[i+1] == '_')){
			delim := text[i:i+2];
			if(len plain > 0){
				nodes = ref DocNode(Ntext, plain, nil, 0) :: nodes;
				plain = "";
			}
			end := pmd_findclose(text, i+2, delim);
			if(end > 0){
				inner := text[i+2:end];
				nodes = ref DocNode(Nbold, nil, pmd_parseinline(inner), 0) :: nodes;
				i = end + 2;
				continue;
			}
			plain[len plain] = c;
			i++;
			continue;
		}

		# Italic: *text* or _text_  (single, not double)
		if((c == '*' && !(i+1 < len text && text[i+1] == '*')) ||
		   (c == '_' && !(i+1 < len text && text[i+1] == '_'))){
			delim := text[i:i+1];
			if(len plain > 0){
				nodes = ref DocNode(Ntext, plain, nil, 0) :: nodes;
				plain = "";
			}
			end := pmd_findclose(text, i+1, delim);
			if(end > 0){
				inner := text[i+1:end];
				nodes = ref DocNode(Nitalic, nil, pmd_parseinline(inner), 0) :: nodes;
				i = end + 1;
				continue;
			}
			plain[len plain] = c;
			i++;
			continue;
		}

		# Inline code: `text`
		if(c == '`'){
			if(len plain > 0){
				nodes = ref DocNode(Ntext, plain, nil, 0) :: nodes;
				plain = "";
			}
			end := pmd_findclose(text, i+1, "`");
			if(end > 0){
				inner := text[i+1:end];
				nodes = ref DocNode(Ncode, inner, nil, 0) :: nodes;
				i = end + 1;
				continue;
			}
			plain[len plain] = c;
			i++;
			continue;
		}

		# Autolink: <https://...>, <mailto:...>
		if(c == '<'){
			end := pmd_findclose(text, i+1, ">");
			if(end > 0){
				u := text[i+1:end];
				if(pmd_isurl(u)){
					if(len plain > 0){
						nodes = ref DocNode(Ntext, plain, nil, 0) :: nodes;
						plain = "";
					}
					nodes = ref DocNode(Nlink, nil, ref DocNode(Ntext, u, nil, 0) :: nil, 0) :: nodes;
					i = end + 1;
					continue;
				}
			}
		}

		# Link: [text](url)
		if(c == '['){
			if(len plain > 0){
				nodes = ref DocNode(Ntext, plain, nil, 0) :: nodes;
				plain = "";
			}
			(linknode, ni) := pmd_parselink(text, i);
			if(linknode != nil){
				nodes = linknode :: nodes;
				i = ni;
				continue;
			}
		}

		plain[len plain] = c;
		i++;
	}

	if(len plain > 0)
		nodes = ref DocNode(Ntext, plain, nil, 0) :: nodes;

	return pmd_reverselist(nodes);
}

pmd_isurl(u: string): int
{
	for(i := 0; i < len u; i++)
		if(u[i] == ' ' || u[i] == '\t')
			return 0;
	for(l := list of {"http://", "https://", "mailto:"}; l != nil; l = tl l)
		if(len u > len hd l && u[0:len hd l] == hd l)
			return 1;
	return 0;
}

pmd_ispunct(c: int): int
{
	for(i := 0; i < len "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"; i++)
		if(c == "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"[i])
			return 1;
	return 0;
}

pmd_findclose(text: string, start: int, delim: string): int
{
	dlen := len delim;
	for(i := start; i <= len text - dlen; i++){
		if(text[i:i+dlen] == delim)
			return i;
	}
	return -1;
}

pmd_parselink(text: string, start: int): (ref DocNode, int)
{
	# the text may hold brackets of its own: [![badge](img)](url)
	i := start + 1;
	depth := 0;
	for(; i < len text; i++){
		if(text[i] == '\\' && i+1 < len text){
			i++;
			continue;
		}
		if(text[i] == '[')
			depth++;
		else if(text[i] == ']'){
			if(depth == 0)
				break;
			depth--;
		}
	}
	if(i >= len text)
		return (nil, start + 1);

	linktext := text[start+1:i];
	i++;

	if(i >= len text || text[i] != '(')
		return (nil, start + 1);
	i++;

	j := i;
	while(j < len text && text[j] != ')')
		j++;
	if(j >= len text)
		return (nil, start + 1);
	j++;

	return (ref DocNode(Nlink, nil, pmd_parseinline(linktext), 0), j);
}

# Returns 1 if line looks like a table row (contains '|')
pmd_istablerow(line: string): int
{
	for(i := 0; i < len line; i++)
		if(line[i] == '|')
			return 1;
	return 0;
}

# Returns 1 if line is a table separator (only '-', '|', ':', spaces)
pmd_istablesep(line: string): int
{
	hasdash := 0;
	haspipe := 0;
	for(i := 0; i < len line; i++){
		c := line[i];
		if(c == '-') hasdash = 1;
		else if(c == '|') haspipe = 1;
		else if(c != ':' && c != ' ' && c != '\t')
			return 0;
	}
	return hasdash && haspipe;
}

# Parse a markdown table starting at lines[start].
# node.text = newline-separated rows; each row has pipe-separated cells.
# node.aux = number of columns (from header row).
pmd_parsetable(lines: array of string, start, nlines: int): (ref DocNode, int)
{
	i := start;
	tabletext := "";
	ncols := 0;
	first := 1;
	aligns := "";

	while(i < nlines){
		line := lines[i];
		if(!pmd_istablerow(line))
			break;
		# The separator row: each column's alignment, :-- (left),
		# :-: (centre) or --: (right)
		if(pmd_istablesep(line)){
			if(aligns == nil){
				cs := pmd_splittablerow(line);
				for(c := 0; c < len cs; c++){
					t := pmd_trim(cs[c]);
					a := 'l';
					if(len t > 0 && t[len t - 1] == ':'){
						a = 'r';
						if(t[0] == ':')
							a = 'c';
					}
					aligns[len aligns] = a;
				}
			}
			i++;
			continue;
		}
		# Strip outer whitespace, collect row
		row := pmd_stripws(line);
		# Count columns from first data row
		if(first){
			cells := pmd_splittablerow(row);
			ncols = len cells;
			first = 0;
		}
		if(len tabletext > 0)
			tabletext += "\n";
		tabletext += row;
		i++;
	}
	if(ncols == 0)
		ncols = 1;
	al: list of ref DocNode;
	if(aligns != nil)
		al = ref DocNode(Ntext, aligns, nil, 0) :: nil;
	return (ref DocNode(Ntable, tabletext, al, ncols), i);
}

pmd_splitlines(text: string): array of string
{
	nlines := 1;
	for(i := 0; i < len text; i++)
		if(text[i] == '\n')
			nlines++;

	lines := array[nlines] of string;
	li := 0;
	start := 0;
	j := 0;
	for(j = 0; j < len text; j++){
		if(text[j] == '\n'){
			lines[li++] = text[start:j];
			start = j + 1;
		}
	}
	if(start <= len text)
		lines[li] = text[start:];
	return lines;
}

pmd_isblank(line: string): int
{
	for(i := 0; i < len line; i++)
		if(line[i] != ' ' && line[i] != '\t' && line[i] != '\r')
			return 0;
	return 1;
}

pmd_ishrule(line: string): int
{
	if(len line < 3)
		return 0;
	c := line[0];
	if(c != '-' && c != '*' && c != '_')
		return 0;
	count := 0;
	for(i := 0; i < len line; i++){
		if(line[i] == c)
			count++;
		else if(line[i] != ' ')
			return 0;
	}
	return count >= 3;
}

pmd_hasdotspace(line: string): int
{
	for(i := 0; i < len line; i++){
		if(line[i] == '.' && i+1 < len line && line[i+1] == ' ')
			return 1;
		if(line[i] < '0' || line[i] > '9')
			return 0;
	}
	return 0;
}

pmd_stripws(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;
	if(i >= len s)
		return "";
	return s[i:];
}

pmd_trim(s: string): string
{
	s = pmd_stripws(s);
	n := len s;
	while(n > 0 && (s[n-1] == ' ' || s[n-1] == '\t' || s[n-1] == '\r'))
		n--;
	return s[0:n];
}

pmd_reverselist(l: list of ref DocNode): list of ref DocNode
{
	r: list of ref DocNode;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

# Extract plain text from an entire document tree
totext(doc: list of ref DocNode): string
{
	s := "";
	for(; doc != nil; doc = tl doc){
		node := hd doc;
		case node.kind {
		Npara or Nblockquote =>
			s += flattentext(node.children) + "\n\n";
		Nheading =>
			s += flattentext(node.children) + "\n\n";
		Ncodeblock or Nmermaid =>
			if(node.text != nil)
				s += node.text + "\n\n";
			else
				s += flattentext(node.children) + "\n\n";
		Nbullet =>
			s += "• " + flattentext(node.children) + "\n";
		Nnumber =>
			s += sys->sprint("%d. ", node.aux) + flattentext(node.children) + "\n";
		Nhrule =>
			s += "---\n\n";
		Ntable =>
			if(node.text != nil)
				s += node.text + "\n\n";
		* =>
			if(node.text != nil)
				s += node.text;
			if(node.children != nil)
				s += flattentext(node.children);
			s += "\n";
		}
	}
	return s;
}

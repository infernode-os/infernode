implement RImagefile;

#
# SVG image rasterizer for Inferno
#
# Renders SVG (Scalable Vector Graphics) to raster Rawimage format.
# Supports the subset of SVG commonly used by Wikipedia:
#   - Basic shapes: rect, circle, ellipse, line, polyline, polygon
#   - Path element with M, L, H, V, C, S, Q, T, A, Z commands
#   - Groups (g) with transform attributes
#   - Transforms: translate, scale, rotate, matrix
#   - Fill and stroke (solid colors)
#   - Opacity and fill-opacity
#   - viewBox and viewport sizing
#   - Text elements (basic positioning)
#   - Linear and radial gradients (basic)
#   - Use/defs references
#   - Style attributes (inline)
#
# Uses Inferno's XML parser for SVG parsing.  Shapes are drawn as
# anti-aliased paths by the draw device (Image.fillpath and
# Image.strokepath in draw-image(2)) into an off-screen image, whose
# pixels are then returned: the decoder needs /dev/draw in its
# namespace.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Path, Point, Rect: import draw;

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "imagefile.m";

include "xml.m";
	xml: Xml;
	Item, Attribute, Attributes, Parser: import xml;

# Default canvas size when viewBox is not specified
DEFAULT_WIDTH:	con 300;
DEFAULT_HEIGHT:	con 150;

# Color values
Color: adt {
	r:	int;
	g:	int;
	b:	int;
	a:	int;	# 0-255
};

# 2D affine transform matrix [a b c; d e f; 0 0 1]
Matrix: adt {
	a:	real;
	b:	real;
	c:	real;	# translate x
	d:	real;
	e:	real;
	f:	real;	# translate y
};

# Path segment types
SEG_MOVETO:	con 0;
SEG_LINETO:	con 1;
SEG_CUBICTO:	con 2;
SEG_QUADTO:	con 3;
SEG_CLOSE:	con 4;

# Path segment
Segment: adt {
	stype:	int;
	x1:	real;
	y1:	real;
	x2:	real;
	y2:	real;
	x3:	real;
	y3:	real;
};

# Rendering style
Style: adt {
	fill:		ref Color;
	stroke:		ref Color;
	stroke_width:	real;
	opacity:	real;	# the element's, times its groups': multiplies down
	fill_opacity:	real;	# inherited, not multiplied
	stroke_opacity:	real;
	font_size:	real;
	fill_rule:	int;	# as fillpath's: ~0 non-zero, 1 even-odd
	cap:		int;	# Draw->Capbutt ...
	join:		int;	# Draw->Joinmiter ...
	color:		ref Color;	# the color property: what currentColor is (inherited)
};

# Gradient stop
GradStop: adt {
	offset:	real;
	color:	ref Color;
};

# Gradient definition
Gradient: adt {
	id:		string;
	linear:		int;	# 1=linear, 0=radial
	x1, y1:	real;
	x2, y2:	real;
	cx, cy, r:	real;
	stops:		list of ref GradStop;
	transform:	ref Matrix;
};

# SVG rendering context
Canvas: adt {
	width:		int;
	height:		int;
	img:		ref Image;	# drawn into by the draw device
	viewbox_x:	real;
	viewbox_y:	real;
	viewbox_w:	real;
	viewbox_h:	real;
	defs:		list of ref Gradient;
	transform:	ref Matrix;
};

display: ref Display;

init(iomod: Bufio)
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	bufio = iomod;
	xml = load Xml Xml->PATH;
	if(xml != nil)
		xml->init();
}

read(fd: ref Iobuf): (ref Rawimage, string)
{
	(a, err) := readarray(fd);
	if(a != nil)
		return (a[0], err);
	return (nil, err);
}

readmulti(fd: ref Iobuf): (array of ref Rawimage, string)
{
	(a, err) := readarray(fd);
	if(a == nil)
		return (nil, err);
	return (a, err);
}

readarray(fd: ref Iobuf): (array of ref Rawimage, string)
{
	if(xml == nil)
		return (nil, "SVG: cannot load XML parser");
	if(display == nil)
		display = Display.allocate(nil);
	if(display == nil)
		return (nil, sys->sprint("SVG: cannot open the draw device: %r"));

	# Parse SVG XML
	(parser, perr) := xml->fopen(fd, "svg", nil, nil);
	if(parser == nil)
		return (nil, "SVG: XML parse error: " + perr);

	# Find the <svg> root element
	(canvas, svgerr) := parse_svg(parser);
	if(svgerr != nil)
		return (nil, svgerr);
	if(canvas.img == nil)
		return (nil, sys->sprint("SVG: cannot make a %dx%d image: %r", canvas.width, canvas.height));

	# Convert canvas to Rawimage
	raw := canvas_to_rawimage(canvas);
	a := array[1] of { raw };
	return (a, "");
}

# Parse the SVG document
parse_svg(parser: ref Parser): (ref Canvas, string)
{
	canvas: ref Canvas;

	# Find SVG root element
	for(;;) {
		item := parser.next();
		if(item == nil)
			break;

		pick t := item {
		Tag =>
			if(t.name == "svg") {
				canvas = new_canvas(t.attrs);
				parser.down();
				# the root's own fill, stroke, color and style pass down
				# like any element's (an icon's <svg fill="none"
				# stroke="currentColor">)
				render_children(parser, canvas, canvas.transform, parse_style(t.attrs, default_style()));
				parser.up();
				return (canvas, "");
			}
		}
	}

	return (nil, "SVG: no <svg> element found");
}

# Create a new canvas from SVG attributes
new_canvas(attrs: Attributes): ref Canvas
{
	# a percentage is of a viewport this image has not got: the default
	width := rootlen(attrs.get("width"), real DEFAULT_WIDTH);
	height := rootlen(attrs.get("height"), real DEFAULT_HEIGHT);

	c := ref Canvas;
	c.width = int width;	# to the nearest: Limbo's int rounds
	c.height = int height;
	if(c.width <= 0) c.width = DEFAULT_WIDTH;
	if(c.height <= 0) c.height = DEFAULT_HEIGHT;
	# Clamp to reasonable size
	if(c.width > 4096) c.width = 4096;
	if(c.height > 4096) c.height = 4096;

	# transparent where nothing is drawn: a viewer shows it on its own
	# background, a web page on the page's
	c.img = display.newimage(Rect((0, 0), (c.width, c.height)), Draw->RGBA32, 0, Draw->Transparent);
	# the root element's CSS background covers the whole canvas
	# (aspect-ratio/replaced-element-004)
	if((rs := attrs.get("style")) != nil) {
		bg := extract_style_prop(rs, "background-color");
		if(bg == nil)
			bg = extract_style_prop(rs, "background");
		if(bg != nil && (bc := parse_color(bg)) != nil && (bsrc := paint(bc, 1.0)) != nil)
			c.img.draw(c.img.r, bsrc, nil, (0, 0));
	}

	c.viewbox_x = 0.0;
	c.viewbox_y = 0.0;
	c.viewbox_w = real c.width;
	c.viewbox_h = real c.height;

	# Parse viewBox
	vb := attrs.get("viewBox");
	if(vb == nil)
		vb = attrs.get("viewbox");
	if(vb != nil) {
		parts := split_whitespace_comma(vb);
		if(len parts >= 4) {
			c.viewbox_x = real parts[0];
			c.viewbox_y = real parts[1];
			c.viewbox_w = real parts[2];
			c.viewbox_h = real parts[3];
		}
	}

	vbw = c.viewbox_w;
	vbh = c.viewbox_h;

	# Compute transform from viewBox to viewport, as preserveAspectRatio
	# says (SVG 2 §8.7): none stretches; else one scale, meet (within)
	# or slice (covering), aligned by xMin/xMid/xMax and YMin/YMid/YMax
	sx := real c.width / c.viewbox_w;
	sy := real c.height / c.viewbox_h;
	align := "xMidYMid";
	slice := 0;
	par := attrs.get("preserveAspectRatio");
	if(par != nil) {
		parts := split_whitespace_comma(par);
		for(i := 0; i < len parts; i++) {
			case parts[i] {
			"none" =>	align = "none";
			"slice" =>	slice = 1;
			"meet" =>	slice = 0;
			* =>
				if(len parts[i] >= 8 && parts[i][0] == 'x')
					align = parts[i];
			}
		}
	}
	if(align == "none")
		c.transform = ref Matrix(sx, 0.0, -c.viewbox_x * sx, 0.0, sy, -c.viewbox_y * sy);
	else {
		scale := sx;
		if(slice && sy > scale || !slice && sy < scale)
			scale = sy;
		ax := 0.5;
		ay := 0.5;
		case align[1:4] {
		"Min" =>	ax = 0.0;
		"Max" =>	ax = 1.0;
		}
		case align[5:8] {
		"Min" =>	ay = 0.0;
		"Max" =>	ay = 1.0;
		}
		tx := (real c.width - c.viewbox_w * scale) * ax - c.viewbox_x * scale;
		ty := (real c.height - c.viewbox_h * scale) * ay - c.viewbox_y * scale;
		c.transform = ref Matrix(scale, 0.0, tx, 0.0, scale, ty);
	}
	c.defs = nil;

	return c;
}

# Render child elements
render_children(parser: ref Parser, canvas: ref Canvas, xform: ref Matrix, parent_style: ref Style)
{
	for(;;) {
		item := parser.next();
		if(item == nil)
			break;

		pick t := item {
		Tag =>
			render_element(parser, canvas, t.name, t.attrs, xform, parent_style);
		}
	}
}

# Render a single SVG element
render_element(parser: ref Parser, canvas: ref Canvas, name: string, attrs: Attributes, parent_xform: ref Matrix, parent_style: ref Style)
{
	# Apply local transform
	xform := parent_xform;
	xf_str := attrs.get("transform");
	if(xf_str != nil) {
		local_xf := parse_transform(xf_str);
		xform = matrix_multiply(parent_xform, local_xf);
	}

	# Parse style
	style := parse_style(attrs, parent_style);

	case name {
	"g" =>
		parser.down();
		render_children(parser, canvas, xform, style);
		parser.up();
	"defs" =>
		parser.down();
		parse_defs(parser, canvas);
		parser.up();
	"rect" =>
		render_rect(canvas, attrs, xform, style);
	"circle" =>
		render_circle(canvas, attrs, xform, style);
	"ellipse" =>
		render_ellipse(canvas, attrs, xform, style);
	"line" =>
		render_line(canvas, attrs, xform, style);
	"polyline" =>
		render_polyline(canvas, attrs, xform, style, 0);
	"polygon" =>
		render_polyline(canvas, attrs, xform, style, 1);
	"path" =>
		render_path(canvas, attrs, xform, style);
	"text" =>
		render_text(parser, canvas, attrs, xform, style);
	"use" =>
		# Basic use element support
		parser.down();
		render_children(parser, canvas, xform, style);
		parser.up();
	"image" or "switch" or "clipPath" or "mask" or
	"symbol" or "marker" or "pattern" or "filter" or
	"title" or "desc" or "metadata" =>
		# Skip unsupported or non-visual elements
		parser.down();
		skip_element(parser);
		parser.up();
	* =>
		# Try to render children of unknown elements
		parser.down();
		render_children(parser, canvas, xform, style);
		parser.up();
	}
}

# Skip an element and its children
skip_element(parser: ref Parser)
{
	for(;;) {
		item := parser.next();
		if(item == nil)
			break;
	}
}

# Parse defs section
parse_defs(parser: ref Parser, canvas: ref Canvas)
{
	for(;;) {
		item := parser.next();
		if(item == nil)
			break;

		pick t := item {
		Tag =>
			case t.name {
			"linearGradient" =>
				grad := parse_linear_gradient(parser, t.attrs);
				if(grad != nil)
					canvas.defs = grad :: canvas.defs;
			"radialGradient" =>
				grad := parse_radial_gradient(parser, t.attrs);
				if(grad != nil)
					canvas.defs = grad :: canvas.defs;
			* =>
				parser.down();
				skip_element(parser);
				parser.up();
			}
		}
	}
}

# Parse a linear gradient
parse_linear_gradient(parser: ref Parser, attrs: Attributes): ref Gradient
{
	grad := ref Gradient;
	grad.id = attrs.get("id");
	grad.linear = 1;
	grad.x1 = parse_real(attrs.get("x1"), 0.0);
	grad.y1 = parse_real(attrs.get("y1"), 0.0);
	grad.x2 = parse_real(attrs.get("x2"), 1.0);
	grad.y2 = parse_real(attrs.get("y2"), 0.0);

	parser.down();
	grad.stops = parse_gradient_stops(parser);
	parser.up();

	return grad;
}

# Parse a radial gradient
parse_radial_gradient(parser: ref Parser, attrs: Attributes): ref Gradient
{
	grad := ref Gradient;
	grad.id = attrs.get("id");
	grad.linear = 0;
	grad.cx = parse_real(attrs.get("cx"), 0.5);
	grad.cy = parse_real(attrs.get("cy"), 0.5);
	grad.r = parse_real(attrs.get("r"), 0.5);

	parser.down();
	grad.stops = parse_gradient_stops(parser);
	parser.up();

	return grad;
}

# Parse gradient stops
parse_gradient_stops(parser: ref Parser): list of ref GradStop
{
	stops: list of ref GradStop;
	for(;;) {
		item := parser.next();
		if(item == nil)
			break;
		pick t := item {
		Tag =>
			if(t.name == "stop") {
				stop := ref GradStop;
				off := t.attrs.get("offset");
				if(off != nil) {
					if(off[len off - 1] == '%')
						stop.offset = real off[0:len off - 1] / 100.0;
					else
						stop.offset = real off;
				}
				sc := t.attrs.get("stop-color");
				if(sc == nil) {
					# Try style attribute
					st := t.attrs.get("style");
					if(st != nil)
						sc = extract_style_prop(st, "stop-color");
				}
				if(sc != nil)
					stop.color = parse_color(sc);
				else
					stop.color = ref Color(0, 0, 0, 255);
				stops = stop :: stops;
			}
		}
	}
	# Reverse to maintain order
	result: list of ref GradStop;
	for(s := stops; s != nil; s = tl s)
		result = hd s :: result;
	return result;	# actually this double-reverses, so just return stops
}

# ==================== Shape Renderers ====================

render_rect(canvas: ref Canvas, attrs: Attributes, xform: ref Matrix, style: ref Style)
{
	x := px(attrs.get("x"), 0.0);
	y := py(attrs.get("y"), 0.0);
	w := px(attrs.get("width"), 0.0);
	h := py(attrs.get("height"), 0.0);
	rx := px(attrs.get("rx"), 0.0);
	ry := py(attrs.get("ry"), 0.0);

	if(w <= 0.0 || h <= 0.0)
		return;

	segs: list of ref Segment;
	if(rx > 0.0 || ry > 0.0) {
		# Rounded rect - approximate corners with cubic beziers
		if(rx <= 0.0) rx = ry;
		if(ry <= 0.0) ry = rx;
		if(rx > w/2.0) rx = w/2.0;
		if(ry > h/2.0) ry = h/2.0;
		k := 0.5522847498;	# magic constant for circular arcs
		kx := rx * k;
		ky := ry * k;

		segs = ref Segment(SEG_MOVETO, x+rx, y, 0.0, 0.0, 0.0, 0.0) :: segs;
		segs = ref Segment(SEG_LINETO, x+w-rx, y, 0.0, 0.0, 0.0, 0.0) :: segs;
		segs = ref Segment(SEG_CUBICTO, x+w-rx+kx, y, x+w, y+ry-ky, x+w, y+ry) :: segs;
		segs = ref Segment(SEG_LINETO, x+w, y+h-ry, 0.0, 0.0, 0.0, 0.0) :: segs;
		segs = ref Segment(SEG_CUBICTO, x+w, y+h-ry+ky, x+w-rx+kx, y+h, x+w-rx, y+h) :: segs;
		segs = ref Segment(SEG_LINETO, x+rx, y+h, 0.0, 0.0, 0.0, 0.0) :: segs;
		segs = ref Segment(SEG_CUBICTO, x+rx-kx, y+h, x, y+h-ry+ky, x, y+h-ry) :: segs;
		segs = ref Segment(SEG_LINETO, x, y+ry, 0.0, 0.0, 0.0, 0.0) :: segs;
		segs = ref Segment(SEG_CUBICTO, x, y+ry-ky, x+rx-kx, y, x+rx, y) :: segs;
		segs = ref Segment(SEG_CLOSE, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0) :: segs;
	} else {
		segs = ref Segment(SEG_MOVETO, x, y, 0.0, 0.0, 0.0, 0.0) :: segs;
		segs = ref Segment(SEG_LINETO, x+w, y, 0.0, 0.0, 0.0, 0.0) :: segs;
		segs = ref Segment(SEG_LINETO, x+w, y+h, 0.0, 0.0, 0.0, 0.0) :: segs;
		segs = ref Segment(SEG_LINETO, x, y+h, 0.0, 0.0, 0.0, 0.0) :: segs;
		segs = ref Segment(SEG_CLOSE, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0) :: segs;
	}

	path := reverse_segments(segs);
	fill_path(canvas, path, xform, style);
	stroke_path(canvas, path, xform, style);
}

render_circle(canvas: ref Canvas, attrs: Attributes, xform: ref Matrix, style: ref Style)
{
	cx := px(attrs.get("cx"), 0.0);
	cy := py(attrs.get("cy"), 0.0);
	r := pd(attrs.get("r"), 0.0);
	if(r <= 0.0)
		return;

	path := make_ellipse_path(cx, cy, r, r);
	fill_path(canvas, path, xform, style);
	stroke_path(canvas, path, xform, style);
}

render_ellipse(canvas: ref Canvas, attrs: Attributes, xform: ref Matrix, style: ref Style)
{
	cx := px(attrs.get("cx"), 0.0);
	cy := py(attrs.get("cy"), 0.0);
	rx := px(attrs.get("rx"), 0.0);
	ry := py(attrs.get("ry"), 0.0);
	if(rx <= 0.0 || ry <= 0.0)
		return;

	path := make_ellipse_path(cx, cy, rx, ry);
	fill_path(canvas, path, xform, style);
	stroke_path(canvas, path, xform, style);
}

make_ellipse_path(cx, cy, rx, ry: real): list of ref Segment
{
	# Approximate ellipse with 4 cubic bezier curves
	k := 0.5522847498;
	kx := rx * k;
	ky := ry * k;

	segs: list of ref Segment;
	segs = ref Segment(SEG_MOVETO, cx+rx, cy, 0.0, 0.0, 0.0, 0.0) :: segs;
	segs = ref Segment(SEG_CUBICTO, cx+rx, cy+ky, cx+kx, cy+ry, cx, cy+ry) :: segs;
	segs = ref Segment(SEG_CUBICTO, cx-kx, cy+ry, cx-rx, cy+ky, cx-rx, cy) :: segs;
	segs = ref Segment(SEG_CUBICTO, cx-rx, cy-ky, cx-kx, cy-ry, cx, cy-ry) :: segs;
	segs = ref Segment(SEG_CUBICTO, cx+kx, cy-ry, cx+rx, cy-ky, cx+rx, cy) :: segs;
	segs = ref Segment(SEG_CLOSE, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0) :: segs;
	return reverse_segments(segs);
}

render_line(canvas: ref Canvas, attrs: Attributes, xform: ref Matrix, style: ref Style)
{
	x1 := px(attrs.get("x1"), 0.0);
	y1 := py(attrs.get("y1"), 0.0);
	x2 := px(attrs.get("x2"), 0.0);
	y2 := py(attrs.get("y2"), 0.0);

	segs := ref Segment(SEG_MOVETO, x1, y1, 0.0, 0.0, 0.0, 0.0) ::
		ref Segment(SEG_LINETO, x2, y2, 0.0, 0.0, 0.0, 0.0) :: nil;
	stroke_path(canvas, segs, xform, style);
}

render_polyline(canvas: ref Canvas, attrs: Attributes, xform: ref Matrix, style: ref Style, closed: int)
{
	points_str := attrs.get("points");
	if(points_str == nil)
		return;

	nums := parse_numbers(points_str);
	if(len nums < 4)
		return;

	segs: list of ref Segment;
	segs = ref Segment(SEG_MOVETO, nums[0], nums[1], 0.0, 0.0, 0.0, 0.0) :: segs;
	for(i := 2; i + 1 < len nums; i += 2)
		segs = ref Segment(SEG_LINETO, nums[i], nums[i+1], 0.0, 0.0, 0.0, 0.0) :: segs;
	if(closed)
		segs = ref Segment(SEG_CLOSE, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0) :: segs;

	path := reverse_segments(segs);
	if(closed)
		fill_path(canvas, path, xform, style);
	stroke_path(canvas, path, xform, style);
}

render_path(canvas: ref Canvas, attrs: Attributes, xform: ref Matrix, style: ref Style)
{
	d := attrs.get("d");
	if(d == nil)
		return;

	path := parse_path_data(d);
	if(path == nil)
		return;

	fill_path(canvas, path, xform, style);
	stroke_path(canvas, path, xform, style);
}

render_text(parser: ref Parser, canvas: ref Canvas, attrs: Attributes, xform: ref Matrix, style: ref Style)
{
	# Basic text rendering - draw text as simple pixel blocks
	# (Full font rendering would require the font subsystem)
	parser.down();
	for(;;) {
		item := parser.next();
		if(item == nil)
			break;
		pick t := item {
		Text =>
			# We have text content - render at position
			tx := px(attrs.get("x"), 0.0);
			ty := py(attrs.get("y"), 0.0);
			render_text_string(canvas, t.ch, tx, ty, xform, style);
		Tag =>
			if(t.name == "tspan") {
				parser.down();
				for(;;) {
					inner := parser.next();
					if(inner == nil)
						break;
					pick it := inner {
					Text =>
						stx := px(t.attrs.get("x"), px(attrs.get("x"), 0.0));
						sty := py(t.attrs.get("y"), py(attrs.get("y"), 0.0));
						render_text_string(canvas, it.ch, stx, sty, xform, style);
					}
				}
				parser.up();
			}
		}
	}
	parser.up();
}

render_text_string(canvas: ref Canvas, text: string, tx, ty: real, xform: ref Matrix, style: ref Style)
{
	if(text == nil || style.fill == nil)
		return;

	# Simple bitmap font rendering (5x7 pixel characters)
	# This provides basic text display for Wikipedia SVGs
	fsize := style.font_size;
	if(fsize <= 0.0)
		fsize = 12.0;

	charw := fsize * 0.6;
	charh := fsize;

	color := style.fill;
	x := tx;
	for(i := 0; i < len text; i++) {
		ch := text[i];
		if(ch == ' ' || ch == '\t') {
			x += charw;
			continue;
		}
		if(ch == '\n' || ch == '\r')
			continue;

		# Draw a small filled rect for each character
		# (approximation - real font rendering would use glyph outlines)
		segs := ref Segment(SEG_MOVETO, x, ty - charh * 0.8, 0.0, 0.0, 0.0, 0.0) ::
			ref Segment(SEG_LINETO, x + charw * 0.8, ty - charh * 0.8, 0.0, 0.0, 0.0, 0.0) ::
			ref Segment(SEG_LINETO, x + charw * 0.8, ty, 0.0, 0.0, 0.0, 0.0) ::
			ref Segment(SEG_LINETO, x, ty, 0.0, 0.0, 0.0, 0.0) ::
			ref Segment(SEG_CLOSE, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0) :: nil;
		fill_path_color(canvas, segs, xform, color, style.opacity*style.fill_opacity, ~0);
		x += charw;
	}
}

# ==================== SVG Path Parser ====================

parse_path_data(d: string): list of ref Segment
{
	segs: list of ref Segment;
	i := 0;
	n := len d;
	cx := 0.0;	# current point
	cy := 0.0;
	mx := 0.0;	# move-to point (for Z)
	my := 0.0;
	lx := 0.0;	# last control point (for S/T)
	ly := 0.0;

	while(i < n) {
		# Skip whitespace and commas
		while(i < n && (d[i] == ' ' || d[i] == '\t' || d[i] == '\n' || d[i] == '\r' || d[i] == ','))
			i++;
		if(i >= n)
			break;

		cmd := d[i];
		if((cmd >= 'A' && cmd <= 'Z') || (cmd >= 'a' && cmd <= 'z'))
			i++;
		else
			cmd = 'L';	# implicit lineto

		case cmd {
		'M' or 'm' =>
			# pairs after the first are implicit lines
			stype := SEG_MOVETO;
			for(;;) {
				(x, ni) := parse_path_number(d, i, n);
				if(ni == i) break;
				i = ni;
				(y, ni2) := parse_path_number(d, i, n);
				i = ni2;
				if(cmd == 'm') { x += cx; y += cy; }
				segs = ref Segment(stype, x, y, 0.0, 0.0, 0.0, 0.0) :: segs;
				cx = x; cy = y;
				if(stype == SEG_MOVETO) {
					mx = x; my = y;
				}
				stype = SEG_LINETO;
			}
		'L' or 'l' =>
			for(;;) {
				(x, ni) := parse_path_number(d, i, n);
				if(ni == i) break;
				i = ni;
				(y, ni2) := parse_path_number(d, i, n);
				i = ni2;
				if(cmd == 'l') { x += cx; y += cy; }
				segs = ref Segment(SEG_LINETO, x, y, 0.0, 0.0, 0.0, 0.0) :: segs;
				cx = x; cy = y;
			}
		'H' or 'h' =>
			for(;;) {
				(x, ni) := parse_path_number(d, i, n);
				if(ni == i) break;
				i = ni;
				if(cmd == 'h') x += cx;
				segs = ref Segment(SEG_LINETO, x, cy, 0.0, 0.0, 0.0, 0.0) :: segs;
				cx = x;
			}
		'V' or 'v' =>
			for(;;) {
				(y, ni) := parse_path_number(d, i, n);
				if(ni == i) break;
				i = ni;
				if(cmd == 'v') y += cy;
				segs = ref Segment(SEG_LINETO, cx, y, 0.0, 0.0, 0.0, 0.0) :: segs;
				cy = y;
			}
		'C' or 'c' =>
			for(;;) {
				(x1, ni) := parse_path_number(d, i, n);
				if(ni == i) break;
				i = ni;
				(y1, ni2) := parse_path_number(d, i, n); i = ni2;
				(x2, ni3) := parse_path_number(d, i, n); i = ni3;
				(y2, ni4) := parse_path_number(d, i, n); i = ni4;
				(x, ni5) := parse_path_number(d, i, n); i = ni5;
				(y, ni6) := parse_path_number(d, i, n); i = ni6;
				if(cmd == 'c') {
					x1 += cx; y1 += cy;
					x2 += cx; y2 += cy;
					x += cx; y += cy;
				}
				segs = ref Segment(SEG_CUBICTO, x1, y1, x2, y2, x, y) :: segs;
				lx = x2; ly = y2;
				cx = x; cy = y;
			}
		'S' or 's' =>
			for(;;) {
				(x2, ni) := parse_path_number(d, i, n);
				if(ni == i) break;
				i = ni;
				(y2, ni2) := parse_path_number(d, i, n); i = ni2;
				(x, ni3) := parse_path_number(d, i, n); i = ni3;
				(y, ni4) := parse_path_number(d, i, n); i = ni4;
				if(cmd == 's') {
					x2 += cx; y2 += cy;
					x += cx; y += cy;
				}
				# Reflected control point
				x1 := 2.0*cx - lx;
				y1 := 2.0*cy - ly;
				segs = ref Segment(SEG_CUBICTO, x1, y1, x2, y2, x, y) :: segs;
				lx = x2; ly = y2;
				cx = x; cy = y;
			}
		'Q' or 'q' =>
			for(;;) {
				(x1, ni) := parse_path_number(d, i, n);
				if(ni == i) break;
				i = ni;
				(y1, ni2) := parse_path_number(d, i, n); i = ni2;
				(x, ni3) := parse_path_number(d, i, n); i = ni3;
				(y, ni4) := parse_path_number(d, i, n); i = ni4;
				if(cmd == 'q') {
					x1 += cx; y1 += cy;
					x += cx; y += cy;
				}
				segs = ref Segment(SEG_QUADTO, x1, y1, x, y, 0.0, 0.0) :: segs;
				lx = x1; ly = y1;
				cx = x; cy = y;
			}
		'T' or 't' =>
			for(;;) {
				(x, ni) := parse_path_number(d, i, n);
				if(ni == i) break;
				i = ni;
				(y, ni2) := parse_path_number(d, i, n); i = ni2;
				if(cmd == 't') { x += cx; y += cy; }
				x1 := 2.0*cx - lx;
				y1 := 2.0*cy - ly;
				segs = ref Segment(SEG_QUADTO, x1, y1, x, y, 0.0, 0.0) :: segs;
				lx = x1; ly = y1;
				cx = x; cy = y;
			}
		'A' or 'a' =>
			for(;;) {
				(arx, ni) := parse_path_number(d, i, n);
				if(ni == i) break;
				i = ni;
				(ary, ni2) := parse_path_number(d, i, n); i = ni2;
				(angle, ni3) := parse_path_number(d, i, n); i = ni3;
				(large_arc, ni4) := parse_path_number(d, i, n); i = ni4;
				(sweep, ni5) := parse_path_number(d, i, n); i = ni5;
				(x, ni6) := parse_path_number(d, i, n); i = ni6;
				(y, ni7) := parse_path_number(d, i, n); i = ni7;
				if(cmd == 'a') { x += cx; y += cy; }
				# Convert arc to cubic beziers
				arc_segs := arc_to_cubics(cx, cy, arx, ary, angle, int large_arc, int sweep, x, y);
				for(as := arc_segs; as != nil; as = tl as)
					segs = hd as :: segs;
				cx = x; cy = y;
			}
		'Z' or 'z' =>
			segs = ref Segment(SEG_CLOSE, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0) :: segs;
			cx = mx; cy = my;
		* =>
			i++;	# skip unknown command
		}
	}

	return reverse_segments(segs);
}

# Parse a number from path data
# A number at i, and where it ends; where there is none, i itself, so
# the caller sees nothing was read (not the whitespace before a command).
parse_path_number(d: string, i, n: int): (real, int)
{
	orig := i;
	# Skip whitespace and commas
	while(i < n && (d[i] == ' ' || d[i] == '\t' || d[i] == '\n' || d[i] == '\r' || d[i] == ','))
		i++;
	if(i >= n)
		return (0.0, orig);

	start := i;
	if(i < n && (d[i] == '-' || d[i] == '+'))
		i++;
	while(i < n && d[i] >= '0' && d[i] <= '9')
		i++;
	if(i < n && d[i] == '.') {
		i++;
		while(i < n && d[i] >= '0' && d[i] <= '9')
			i++;
	}
	# Scientific notation
	if(i < n && (d[i] == 'e' || d[i] == 'E')) {
		i++;
		if(i < n && (d[i] == '-' || d[i] == '+'))
			i++;
		while(i < n && d[i] >= '0' && d[i] <= '9')
			i++;
	}

	if(i == start)
		return (0.0, orig);

	return (real d[start:i], i);
}

# ==================== Rasterizer ====================

# The path, transformed, as a Draw path
topath(path: list of ref Segment, m: ref Matrix): ref Path
{
	p := Path.new();
	for(; path != nil; path = tl path) {
		seg := hd path;
		case seg.stype {
		SEG_MOVETO =>
			(x, y) := transform_point(m, seg.x1, seg.y1);
			p.moveto(x, y);
		SEG_LINETO =>
			(x, y) := transform_point(m, seg.x1, seg.y1);
			p.lineto(x, y);
		SEG_CUBICTO =>
			(x1, y1) := transform_point(m, seg.x1, seg.y1);
			(x2, y2) := transform_point(m, seg.x2, seg.y2);
			(x3, y3) := transform_point(m, seg.x3, seg.y3);
			p.curveto(x1, y1, x2, y2, x3, y3);
		SEG_QUADTO =>
			(x1, y1) := transform_point(m, seg.x1, seg.y1);
			(x2, y2) := transform_point(m, seg.x2, seg.y2);
			p.quadto(x1, y1, x2, y2);
		SEG_CLOSE =>
			p.close();
		}
	}
	return p;
}

# A colour at an opacity as a source image: Draw's colours are premultiplied
paint(c: ref Color, opacity: real): ref Image
{
	if(opacity < 0.0)
		opacity = 0.0;
	if(opacity > 1.0)
		opacity = 1.0;
	a := int (real c.a * opacity + 0.5);
	if(a <= 0)
		return nil;
	if(a > 255)
		a = 255;
	v := (c.r*a/255) << 24 | (c.g*a/255) << 16 | (c.b*a/255) << 8 | a;
	return display.newimage(Rect((0, 0), (1, 1)), Draw->RGBA32, 1, v);
}

fill_path(canvas: ref Canvas, path: list of ref Segment, xform: ref Matrix, style: ref Style)
{
	if(style.fill == nil)
		return;
	fill_path_color(canvas, path, xform, style.fill, style.opacity*style.fill_opacity, style.fill_rule);
}

fill_path_color(canvas: ref Canvas, path: list of ref Segment, xform: ref Matrix, color: ref Color, opacity: real, rule: int)
{
	if(path == nil || (src := paint(color, opacity)) == nil)
		return;
	canvas.img.fillpath(topath(path, xform), rule, src, (0, 0));
}

# Stroke a path, the width scaled as the transform scales area
stroke_path(canvas: ref Canvas, path: list of ref Segment, xform: ref Matrix, style: ref Style)
{
	if(style.stroke == nil || style.stroke_width <= 0.0 || path == nil)
		return;
	src := paint(style.stroke, style.opacity*style.stroke_opacity);
	if(src == nil)
		return;
	det := xform.a*xform.e - xform.b*xform.d;
	if(det < 0.0)
		det = -det;
	sw := style.stroke_width * sqrt(det);
	if(sw <= 0.0)
		return;
	canvas.img.strokepath(topath(path, xform), sw, style.cap, style.join, src, (0, 0));
}

# ==================== Transform Functions ====================

transform_point(m: ref Matrix, x, y: real): (real, real)
{
	return (m.a * x + m.b * y + m.c, m.d * x + m.e * y + m.f);
}

matrix_multiply(a, b: ref Matrix): ref Matrix
{
	return ref Matrix(
		a.a*b.a + a.b*b.d,
		a.a*b.b + a.b*b.e,
		a.a*b.c + a.b*b.f + a.c,
		a.d*b.a + a.e*b.d,
		a.d*b.b + a.e*b.e,
		a.d*b.c + a.e*b.f + a.f
	);
}

parse_transform(s: string): ref Matrix
{
	m := ref Matrix(1.0, 0.0, 0.0, 0.0, 1.0, 0.0);
	i := 0;
	n := len s;

	while(i < n) {
		while(i < n && (s[i] == ' ' || s[i] == ','))
			i++;
		if(i >= n)
			break;

		# Find transform function name
		start := i;
		while(i < n && s[i] != '(')
			i++;
		if(i >= n) break;
		fname := s[start:i];
		# Trim whitespace from fname
		while(len fname > 0 && fname[len fname - 1] == ' ')
			fname = fname[0:len fname - 1];
		i++;	# skip '('

		# Parse arguments
		args: list of real;
		while(i < n && s[i] != ')') {
			(v, ni) := parse_path_number(s, i, n);
			if(ni == i) { i++; continue; }
			i = ni;
			args = v :: args;
		}
		if(i < n) i++;	# skip ')'

		# Reverse args
		rargs: list of real;
		for(a := args; a != nil; a = tl a)
			rargs = hd a :: rargs;
		argv := list_to_array(rargs);

		case fname {
		"translate" =>
			tx := 0.0;
			ty := 0.0;
			if(len argv >= 1) tx = argv[0];
			if(len argv >= 2) ty = argv[1];
			t := ref Matrix(1.0, 0.0, tx, 0.0, 1.0, ty);
			m = matrix_multiply(m, t);
		"scale" =>
			sx := 1.0;
			sy := 1.0;
			if(len argv >= 1) { sx = argv[0]; sy = sx; }
			if(len argv >= 2) sy = argv[1];
			t := ref Matrix(sx, 0.0, 0.0, 0.0, sy, 0.0);
			m = matrix_multiply(m, t);
		"rotate" =>
			if(len argv >= 1) {
				angle := argv[0] * 3.14159265358979 / 180.0;
				ca := cos(angle);
				sa := sin(angle);
				if(len argv >= 3) {
					# rotate(angle, cx, cy)
					rcx := argv[1];
					rcy := argv[2];
					t1 := ref Matrix(1.0, 0.0, rcx, 0.0, 1.0, rcy);
					tr := ref Matrix(ca, -sa, 0.0, sa, ca, 0.0);
					t2 := ref Matrix(1.0, 0.0, -rcx, 0.0, 1.0, -rcy);
					m = matrix_multiply(m, matrix_multiply(t1, matrix_multiply(tr, t2)));
				} else {
					t := ref Matrix(ca, -sa, 0.0, sa, ca, 0.0);
					m = matrix_multiply(m, t);
				}
			}
		"matrix" =>
			if(len argv >= 6) {
				t := ref Matrix(argv[0], argv[2], argv[4], argv[1], argv[3], argv[5]);
				m = matrix_multiply(m, t);
			}
		"skewX" =>
			if(len argv >= 1) {
				angle := argv[0] * 3.14159265358979 / 180.0;
				t := ref Matrix(1.0, tan(angle), 0.0, 0.0, 1.0, 0.0);
				m = matrix_multiply(m, t);
			}
		"skewY" =>
			if(len argv >= 1) {
				angle := argv[0] * 3.14159265358979 / 180.0;
				t := ref Matrix(1.0, 0.0, 0.0, tan(angle), 1.0, 0.0);
				m = matrix_multiply(m, t);
			}
		}
	}

	return m;
}

# ==================== Style Parsing ====================

default_style(): ref Style
{
	return ref Style(
		ref Color(0, 0, 0, 255),	# fill: black
		nil,				# stroke: none
		1.0,				# stroke_width
		1.0,				# opacity
		1.0,				# fill_opacity
		1.0,				# stroke_opacity
		12.0,				# font_size
		~0,				# fill_rule: nonzero
		Draw->Capbutt,			# stroke-linecap: butt
		Draw->Joinmiter,		# stroke-linejoin: miter
		ref Color(0, 0, 0, 255)		# color: black
	);
}

parse_style(attrs: Attributes, parent: ref Style): ref Style
{
	s := ref Style(
		parent.fill,
		parent.stroke,
		parent.stroke_width,
		parent.opacity,
		parent.fill_opacity,
		parent.stroke_opacity,
		parent.font_size,
		parent.fill_rule,
		parent.cap,
		parent.join,
		parent.color
	);

	# the color property first: currentColor in a fill or stroke below,
	# on this element or in its style, is this element's
	if((col := attrs.get("color")) != nil && lower(trim(col)) != "currentcolor")
		s.color = parse_color(col);
	style_str := attrs.get("style");
	if(style_str != nil)
		css_color(s, style_str);

	# presentation attributes, then the style attribute, which wins
	# over them (SVG 2 §6.4)
	fill := attrs.get("fill");
	if(fill != nil) {
		if(fill == "none")
			s.fill = nil;
		else
			s.fill = paintof(s, fill);
	}

	stroke := attrs.get("stroke");
	if(stroke != nil) {
		if(stroke == "none")
			s.stroke = nil;
		else
			s.stroke = paintof(s, stroke);
	}
	if(style_str != nil)
		apply_css_style(s, style_str);

	sw := attrs.get("stroke-width");
	if(sw != nil)
		s.stroke_width = pd(sw, 1.0);

	op := attrs.get("opacity");
	if(op != nil)
		s.opacity *= real op;

	fop := attrs.get("fill-opacity");
	if(fop != nil)
		s.fill_opacity = real fop;

	sop := attrs.get("stroke-opacity");
	if(sop != nil)
		s.stroke_opacity = real sop;

	fs := attrs.get("font-size");
	if(fs != nil)
		s.font_size = parse_length(fs, s.font_size);

	for(k := 0; k < len strokeprops; k++)
		if((v := attrs.get(strokeprops[k])) != nil)
			setstrokeprop(s, strokeprops[k], v);

	# the colours stay as given, shared with the parent's and siblings'
	# styles: opacity is applied when painting (paint)

	return s;
}

strokeprops := array[] of {"fill-rule", "stroke-linecap", "stroke-linejoin"};

setstrokeprop(s: ref Style, name, value: string)
{
	case name {
	"fill-rule" =>
		case value {
		"evenodd" =>	s.fill_rule = 1;
		"nonzero" =>	s.fill_rule = ~0;
		}
	"stroke-linecap" =>
		case value {
		"butt" =>	s.cap = Draw->Capbutt;
		"round" =>	s.cap = Draw->Capround;
		"square" =>	s.cap = Draw->Capsquare;
		}
	"stroke-linejoin" =>
		case value {
		"miter" =>	s.join = Draw->Joinmiter;
		"round" =>	s.join = Draw->Joinround;
		"bevel" =>	s.join = Draw->Joinbevel;
		}
	}
}

apply_css_style(s: ref Style, css: string)
{
	# Parse semicolon-separated CSS properties
	parts := split_semicolons(css);
	for(p := parts; p != nil; p = tl p) {
		prop := hd p;
		(name, value) := split_colon(prop);
		name = trim(name);
		value = trim(value);
		if(name == nil || value == nil)
			continue;

		case name {
		"fill" =>
			if(value == "none")
				s.fill = nil;
			else
				s.fill = paintof(s, value);
		"stroke" =>
			if(value == "none")
				s.stroke = nil;
			else
				s.stroke = paintof(s, value);
		"stroke-width" =>
			s.stroke_width = pd(value, 1.0);
		"opacity" =>
			s.opacity *= real value;
		"fill-opacity" =>
			s.fill_opacity = real value;
		"stroke-opacity" =>
			s.stroke_opacity = real value;
		"font-size" =>
			s.font_size = parse_length(value, s.font_size);
		"fill-rule" or "stroke-linecap" or "stroke-linejoin" =>
			setstrokeprop(s, name, value);
		}
	}
}

# Parse a CSS color value
# a fill or stroke: currentColor is the color property's value
paintof(st: ref Style, v: string): ref Color
{
	if(lower(trim(v)) == "currentcolor")
		return st.color;
	return parse_color(v);
}

# the color property in a style attribute
css_color(s: ref Style, css: string)
{
	(nil, parts) := sys->tokenize(css, ";");
	for(p := parts; p != nil; p = tl p) {
		(name, value) := split_colon(hd p);
		if(trim(name) == "color" && value != nil && lower(trim(value)) != "currentcolor")
			s.color = parse_color(trim(value));
	}
}

parse_color(s: string): ref Color
{
	if(s == nil || len s == 0)
		return ref Color(0, 0, 0, 255);

	s = trim(s);

	# Handle url(#id) for gradients
	if(len s > 4 && s[0:4] == "url(")
		return ref Color(128, 128, 128, 255);	# placeholder for gradients

	# Hex colors
	if(s[0] == '#') {
		if(len s == 4) {
			# #RGB
			r := hexdigit(s[1]) * 17;
			g := hexdigit(s[2]) * 17;
			b := hexdigit(s[3]) * 17;
			return ref Color(r, g, b, 255);
		}
		if(len s == 7) {
			# #RRGGBB
			r := hexdigit(s[1]) * 16 + hexdigit(s[2]);
			g := hexdigit(s[3]) * 16 + hexdigit(s[4]);
			b := hexdigit(s[5]) * 16 + hexdigit(s[6]);
			return ref Color(r, g, b, 255);
		}
	}

	# rgb() function
	if(len s > 4 && s[0:4] == "rgb(") {
		nums := parse_numbers(s[4:len s - 1]);
		if(len nums >= 3)
			return ref Color(int nums[0], int nums[1], int nums[2], 255);
	}

	# Named colors (common ones used in Wikipedia SVGs)
	case s {
	"black" =>		return ref Color(0, 0, 0, 255);
	"white" =>		return ref Color(255, 255, 255, 255);
	"red" =>		return ref Color(255, 0, 0, 255);
	"green" =>		return ref Color(0, 128, 0, 255);
	"blue" =>		return ref Color(0, 0, 255, 255);
	"yellow" =>		return ref Color(255, 255, 0, 255);
	"cyan" or "aqua" =>	return ref Color(0, 255, 255, 255);
	"magenta" or "fuchsia" => return ref Color(255, 0, 255, 255);
	"gray" or "grey" =>	return ref Color(128, 128, 128, 255);
	"silver" =>		return ref Color(192, 192, 192, 255);
	"maroon" =>		return ref Color(128, 0, 0, 255);
	"olive" =>		return ref Color(128, 128, 0, 255);
	"lime" =>		return ref Color(0, 255, 0, 255);
	"teal" =>		return ref Color(0, 128, 128, 255);
	"navy" =>		return ref Color(0, 0, 128, 255);
	"purple" =>		return ref Color(128, 0, 128, 255);
	"orange" =>		return ref Color(255, 165, 0, 255);
	"brown" =>		return ref Color(165, 42, 42, 255);
	"pink" =>		return ref Color(255, 192, 203, 255);
	"gold" =>		return ref Color(255, 215, 0, 255);
	"darkgray" or "darkgrey" => return ref Color(169, 169, 169, 255);
	"lightgray" or "lightgrey" => return ref Color(211, 211, 211, 255);
	"darkblue" =>		return ref Color(0, 0, 139, 255);
	"darkgreen" =>		return ref Color(0, 100, 0, 255);
	"darkred" =>		return ref Color(139, 0, 0, 255);
	"lightblue" =>		return ref Color(173, 216, 230, 255);
	"lightgreen" =>		return ref Color(144, 238, 144, 255);
	"none" or "transparent" => return ref Color(0, 0, 0, 0);
	}

	return ref Color(0, 0, 0, 255);
}

# ==================== Arc Conversion ====================

# Convert SVG arc to cubic bezier segments
arc_to_cubics(x0, y0, rx, ry, angle_deg: real, large_arc, sweep: int, x1, y1: real): list of ref Segment
{
	if(rx <= 0.0 || ry <= 0.0)
		return ref Segment(SEG_LINETO, x1, y1, 0.0, 0.0, 0.0, 0.0) :: nil;

	# Convert to center parameterization (SVG spec F.6.5)
	pi := 3.14159265358979;
	angle := angle_deg * pi / 180.0;
	ca := cos(angle);
	sa := sin(angle);

	dx2 := (x0 - x1) / 2.0;
	dy2 := (y0 - y1) / 2.0;
	x1p := ca * dx2 + sa * dy2;
	y1p := -sa * dx2 + ca * dy2;

	# Correct radii
	x1psq := x1p * x1p;
	y1psq := y1p * y1p;
	rxsq := rx * rx;
	rysq := ry * ry;

	lambda := x1psq / rxsq + y1psq / rysq;
	if(lambda > 1.0) {
		sq := sqrt(lambda);
		rx *= sq;
		ry *= sq;
		rxsq = rx * rx;
		rysq = ry * ry;
	}

	# Center point
	num := rxsq * rysq - rxsq * y1psq - rysq * x1psq;
	den := rxsq * y1psq + rysq * x1psq;
	if(den <= 0.0)
		return ref Segment(SEG_LINETO, x1, y1, 0.0, 0.0, 0.0, 0.0) :: nil;

	sq := sqrt(num / den);
	if(large_arc == sweep)
		sq = -sq;

	cxp := sq * rx * y1p / ry;
	cyp := -sq * ry * x1p / rx;

	cx := ca * cxp - sa * cyp + (x0 + x1) / 2.0;
	cy := sa * cxp + ca * cyp + (y0 + y1) / 2.0;

	# Start and sweep angles
	theta1 := atan2((y1p - cyp) / ry, (x1p - cxp) / rx);
	dtheta := atan2((-y1p - cyp) / ry, (-x1p - cxp) / rx) - theta1;

	if(sweep == 0 && dtheta > 0.0)
		dtheta -= 2.0 * pi;
	else if(sweep != 0 && dtheta < 0.0)
		dtheta += 2.0 * pi;

	# Split into 90-degree segments
	nseg := int (abs_real(dtheta) / (pi / 2.0)) + 1;
	step := dtheta / real nseg;

	segs: list of ref Segment;
	for(i := 0; i < nseg; i++) {
		t1 := theta1 + real i * step;
		t2 := t1 + step;

		# Approximate arc segment with cubic bezier
		alpha := sin(step) * (sqrt(4.0 + 3.0 * tan(step/2.0) * tan(step/2.0)) - 1.0) / 3.0;

		sx := cos(t1);
		sy := sin(t1);
		ex := cos(t2);
		ey := sin(t2);

		bx1 := sx - alpha * sy;
		by1 := sy + alpha * sx;
		bx2 := ex + alpha * ey;
		by2 := ey - alpha * ex;

		# Transform back
		p1x := ca * rx * bx1 - sa * ry * by1 + cx;
		p1y := sa * rx * bx1 + ca * ry * by1 + cy;
		p2x := ca * rx * bx2 - sa * ry * by2 + cx;
		p2y := sa * rx * bx2 + ca * ry * by2 + cy;
		px := ca * rx * ex - sa * ry * ey + cx;
		py := sa * rx * ex + ca * ry * ey + cy;

		segs = ref Segment(SEG_CUBICTO, p1x, p1y, p2x, p2y, px, py) :: segs;
	}

	return reverse_segments(segs);
}

# ==================== Canvas to Rawimage ====================

canvas_to_rawimage(canvas: ref Canvas): ref Rawimage
{
	raw := ref Rawimage;
	raw.r.min = Point(0, 0);
	raw.r.max = Point(canvas.width, canvas.height);
	raw.transp = 0;

	# RGBA32 is stored a, b, g, r, premultiplied; a Rawimage's alpha is not
	npix := canvas.width * canvas.height;
	buf := array[4*npix] of byte;
	canvas.img.readpixels(canvas.img.r, buf);
	raw.nchans = 4;
	raw.chandesc = RImagefile->CRGBA;
	raw.chans = array[4] of array of byte;
	for(k := 0; k < 4; k++)
		raw.chans[k] = array[npix] of byte;
	for(i := 0; i < npix; i++) {
		a := int buf[4*i];
		raw.chans[3][i] = byte a;
		if(a == 0)
			continue;	# r, g, b stay 0
		raw.chans[0][i] = byte unpremul(int buf[4*i+3], a);
		raw.chans[1][i] = byte unpremul(int buf[4*i+2], a);
		raw.chans[2][i] = byte unpremul(int buf[4*i+1], a);
	}
	return raw;
}

unpremul(c, a: int): int
{
	v := (c * 255 + a/2) / a;
	if(v > 255)
		v = 255;
	return v;
}

# ==================== Utility Functions ====================

# the viewport's size in user units: what percentages are of
vbw := real DEFAULT_WIDTH;
vbh := real DEFAULT_HEIGHT;

rootlen(s: string, dflt: real): real
{
	if(s != nil && len s > 0 && s[len s - 1] == '%')
		return dflt;
	return parse_length(s, dflt);
}

# a length in user units: a percentage is of the reference length
# (SVG 2 §8.9: the viewport's width, its height, or their normalised diagonal)
plen(s: string, dflt, base: real): real
{
	if(s == nil || len s == 0)
		return dflt;
	if(s[len s - 1] == '%')
		return real s[0:len s - 1] * base / 100.0;
	return parse_length(s, dflt);
}

px(s: string, dflt: real): real
{
	return plen(s, dflt, vbw);
}

py(s: string, dflt: real): real
{
	return plen(s, dflt, vbh);
}

pd(s: string, dflt: real): real
{
	return plen(s, dflt, sqrt((vbw*vbw + vbh*vbh)/2.0));
}

parse_length(s: string, dflt: real): real
{
	if(s == nil || len s == 0)
		return dflt;
	# Strip units
	n := len s;
	while(n > 0 && ((s[n-1] >= 'a' && s[n-1] <= 'z') || s[n-1] == '%'))
		n--;
	if(n == 0)
		return dflt;
	return real s[0:n];
}

parse_real(s: string, dflt: real): real
{
	if(s == nil || len s == 0)
		return dflt;
	return real s;
}

hexdigit(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return 0;
}

parse_numbers(s: string): array of real
{
	nums: list of real;
	i := 0;
	n := len s;
	while(i < n) {
		(v, ni) := parse_path_number(s, i, n);
		if(ni == i) { i++; continue; }
		i = ni;
		nums = v :: nums;
	}

	# Reverse and convert to array
	count := 0;
	for(l := nums; l != nil; l = tl l) count++;
	result := array[count] of real;
	i = count - 1;
	for(l = nums; l != nil; l = tl l)
		result[i--] = hd l;
	return result;
}

split_whitespace_comma(s: string): array of string
{
	parts: list of string;
	i := 0;
	n := len s;
	while(i < n) {
		while(i < n && (s[i] == ' ' || s[i] == '\t' || s[i] == ',' || s[i] == '\n'))
			i++;
		start := i;
		while(i < n && s[i] != ' ' && s[i] != '\t' && s[i] != ',' && s[i] != '\n')
			i++;
		if(i > start)
			parts = s[start:i] :: parts;
	}
	count := 0;
	for(l := parts; l != nil; l = tl l) count++;
	result := array[count] of string;
	i = count - 1;
	for(l = parts; l != nil; l = tl l)
		result[i--] = hd l;
	return result;
}

split_semicolons(s: string): list of string
{
	parts: list of string;
	start := 0;
	for(i := 0; i <= len s; i++) {
		if(i == len s || s[i] == ';') {
			if(i > start)
				parts = s[start:i] :: parts;
			start = i + 1;
		}
	}
	return parts;
}

lower(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] >= 'A' && s[i] <= 'Z')
			s[i] += 'a' - 'A';
	return s;
}

split_colon(s: string): (string, string)
{
	for(i := 0; i < len s; i++) {
		if(s[i] == ':')
			return (s[0:i], s[i+1:]);
	}
	return (s, nil);
}

trim(s: string): string
{
	if(s == nil) return nil;
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t'))
		j--;
	return s[i:j];
}

extract_style_prop(style, prop: string): string
{
	parts := split_semicolons(style);
	for(p := parts; p != nil; p = tl p) {
		(name, value) := split_colon(hd p);
		if(trim(name) == prop)
			return trim(value);
	}
	return nil;
}

reverse_segments(segs: list of ref Segment): list of ref Segment
{
	result: list of ref Segment;
	for(s := segs; s != nil; s = tl s)
		result = hd s :: result;
	return result;
}

list_to_array(l: list of real): array of real
{
	n := 0;
	for(p := l; p != nil; p = tl p) n++;
	a := array[n] of real;
	i := 0;
	for(p = l; p != nil; p = tl p)
		a[i++] = hd p;
	return a;
}

abs_real(v: real): real
{
	if(v < 0.0) return -v;
	return v;
}

if_upper(c, upper, lower: int): int
{
	if(c >= 'A' && c <= 'Z')
		return upper;
	return lower;
}

# Math functions
sqrt(x: real): real
{
	if(x <= 0.0)
		return 0.0;
	r := x;
	for(i := 0; i < 20; i++)
		r = (r + x/r) / 2.0;
	return r;
}

# Sine approximation (Taylor series)
sin(x: real): real
{
	pi := 3.14159265358979;
	# Normalize to [-pi, pi]
	while(x > pi) x -= 2.0 * pi;
	while(x < -pi) x += 2.0 * pi;
	x2 := x * x;
	return x * (1.0 - x2/6.0 * (1.0 - x2/20.0 * (1.0 - x2/42.0 * (1.0 - x2/72.0))));
}

cos(x: real): real
{
	return sin(x + 3.14159265358979 / 2.0);
}

tan(x: real): real
{
	c := cos(x);
	if(c == 0.0) return 1.0e30;
	return sin(x) / c;
}

atan2(y, x: real): real
{
	pi := 3.14159265358979;
	if(x == 0.0) {
		if(y > 0.0) return pi / 2.0;
		if(y < 0.0) return -pi / 2.0;
		return 0.0;
	}
	a := atan_approx(y / x);
	if(x < 0.0) {
		if(y >= 0.0) return a + pi;
		return a - pi;
	}
	return a;
}

atan_approx(x: real): real
{
	# Approximation for atan(x)
	pi := 3.14159265358979;
	if(x > 1.0)
		return pi / 2.0 - atan_approx(1.0 / x);
	if(x < -1.0)
		return -pi / 2.0 - atan_approx(1.0 / x);
	x2 := x * x;
	return x * (1.0 - x2 * (1.0/3.0 - x2 * (1.0/5.0 - x2 * (1.0/7.0 - x2/9.0))));
}

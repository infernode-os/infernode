implement Osklayout;

#
# The layouts of a keyboard on a screen: module/osklayout.m.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	Rect, Point: import Draw;
include "keyboard.m";
include "kbdecode.m";
	kbdecode: Kbdecode;
include "osklayout.m";

init()
{
	sys = load Sys Sys->PATH;
	kbdecode = load Kbdecode Kbdecode->PATH;
	if(kbdecode != nil)
		kbdecode->init();
}

# the keyboard's own keys, by their words
specials := array[] of {
	("shift",	Kshift,		0),
	("del",		Kdel,		'\b'),
	("enter",	Kenter,		'\n'),
	("space",	Kspace,		' '),
	("ctrl",	Kctrl,		0),
	("sym",		Klayer,		0),
	("more",	Klayer,		0),
	("abc",		Klayer,		0),
	("next",	Knext,		0),
	("tab",		Kspecial,	'\t'),
	("esc",		Kspecial,	27),
	("left",	Kspecial,	Keyboard->Left),
	("right",	Kspecial,	Keyboard->Right),
	("up",		Kspecial,	Keyboard->Up),
	("down",	Kspecial,	Keyboard->Down),
	("home",	Kspecial,	Keyboard->Home),
	("end",		Kspecial,	Keyboard->End),
};

upper(c: int): int
{
	if(c >= 'a' && c <= 'z')
		return c - 'a' + 'A';
	if(c >= 16rE0 && c <= 16rFE && c != 16rF7)
		return c - 16r20;
	return c;
}

parsekey(tok: string): (ref Lkey, string)
{
	width := 1.0;
	# "x:1.5": a width, when what follows the last colon is a number
	for(i := len tok - 1; i > 0; i--)
		if(tok[i] == ':')
			break;
	if(i > 0 && i < len tok - 1){
		num := 1;
		for(j := i+1; j < len tok; j++)
			if(!(tok[j] >= '0' && tok[j] <= '9' || tok[j] == '.'))
				num = 0;
		if(num){
			width = real tok[i+1:];
			tok = tok[0:i];
		}
	}
	if(width <= 0.0)
		return (nil, "bad width");
	for(k := 0; k < len specials; k++){
		(name, kind, c) := specials[k];
		if(tok == name)
			return (ref Lkey(kind, c, c, name, width, ((0,0),(0,0)), 0), nil);
	}
	case len tok {
	1 =>
		return (ref Lkey(Kchar, tok[0], upper(tok[0]), nil, width, ((0,0),(0,0)), 0), nil);
	2 =>
		return (ref Lkey(Kchar, tok[0], tok[1], nil, width, ((0,0),(0,0)), 0), nil);
	}
	return (nil, sys->sprint("unknown key %q", tok));
}

Layout.parse(name, text: string): (ref Layout, string)
{
	if(sys == nil)
		init();
	rows: list of array of ref Lkey;
	nrow := 0;
	(nil, lines) := sys->tokenize(text, "\n");
	for(; lines != nil; lines = tl lines){
		line := hd lines;
		if(len line == 0 || line[0] == '#')
			continue;
		(nf, f) := sys->tokenize(line, " \t\r");
		if(nf == 0)
			continue;
		case hd f {
		"row" =>
			keys := array[nf-1] of ref Lkey;
			i := 0;
			for(f = tl f; f != nil; f = tl f){
				(k, err) := parsekey(hd f);
				if(k == nil)
					return (nil, sys->sprint("%s: %s", name, err));
				k.row = nrow;
				keys[i++] = k;
			}
			if(i == 0)
				return (nil, name + ": an empty row");
			rows = keys :: rows;
			nrow++;
		* =>
			return (nil, sys->sprint("%s: unknown line %q", name, hd f));
		}
	}
	if(nrow == 0)
		return (nil, name + ": no rows");
	l := ref Layout(name, array[nrow] of array of ref Lkey, 0.0);
	for(i := nrow-1; i >= 0; i--){
		l.rows[i] = hd rows;
		rows = tl rows;
	}
	for(i = 0; i < nrow; i++){
		u := 0.0;
		for(j := 0; j < len l.rows[i]; j++)
			u += l.rows[i][j].width;
		if(u > l.units)
			l.units = u;
	}
	return (l, nil);
}

Layout.read(path: string): (ref Layout, string)
{
	if(sys == nil)
		init();
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("%s: %r", path));
	text := "";
	buf := array[8192] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		text += string buf[0:n];
	name := path;
	for(i := len path - 1; i >= 0; i--)
		if(path[i] == '/'){
			name = path[i+1:];
			break;
		}
	return Layout.parse(name, text);
}

Layout.place(l: self ref Layout, r: Rect)
{
	nrow := len l.rows;
	h := r.max.y - r.min.y;
	unit := real (r.max.x - r.min.x) / l.units;
	for(i := 0; i < nrow; i++){
		y0 := r.min.y + h*i/nrow;
		y1 := r.min.y + h*(i+1)/nrow;
		u := 0.0;
		for(j := 0; j < len l.rows[i]; j++)
			u += l.rows[i][j].width;
		x := real r.min.x + (l.units - u) * unit / 2.0;
		for(j = 0; j < len l.rows[i]; j++){
			k := l.rows[i][j];
			x1 := x + k.width * unit;
			k.r = ((int x, y0), (int x1, y1));	# int of a real rounds
			x = x1;
		}
	}
}

Layout.keyat(l: self ref Layout, p: Point): ref Lkey
{
	for(i := 0; i < len l.rows; i++){
		row := l.rows[i];
		if(len row == 0)
			continue;
		if(p.y < row[0].r.min.y && i > 0)
			continue;
		if(p.y >= row[0].r.max.y && i < len l.rows-1)
			continue;
		best: ref Lkey;
		bd := 0;
		for(j := 0; j < len row; j++){
			k := row[j];
			if(p.x >= k.r.min.x && p.x < k.r.max.x)
				return k;
			d := k.r.min.x - p.x;
			if(d < 0)
				d = p.x - k.r.max.x + 1;
			if(best == nil || d < bd){
				best = k;
				bd = d;
			}
		}
		return best;
	}
	return nil;
}

Layout.dkeys(l: self ref Layout): array of Kbdecode->Key
{
	n := 0;
	i, j: int;
	for(i = 0; i < len l.rows; i++)
		for(j = 0; j < len l.rows[i]; j++)
			if(isdkey(l.rows[i][j]))
				n++;
	a := array[n] of Kbdecode->Key;
	n = 0;
	for(i = 0; i < len l.rows; i++)
		for(j = 0; j < len l.rows[i]; j++){
			k := l.rows[i][j];
			if(isdkey(k)){
				c := (k.r.min.x + k.r.max.x)/2;
				m := (k.r.min.y + k.r.max.y)/2;
				a[n++] = Kbdecode->Key(k.c, c, m, k.r.max.x - k.r.min.x, k.r.max.y - k.r.min.y);
			}
		}
	return a;
}

isdkey(k: ref Lkey): int
{
	if(k.kind != Kchar)
		return 0;
	c := k.c;
	return c >= 'a' && c <= 'z' || c == '\'';
}

alternates(text: string): list of (int, string)
{
	if(sys == nil)
		init();
	r: list of (int, string);
	(nil, lines) := sys->tokenize(text, "\n");
	for(; lines != nil; lines = tl lines){
		line := hd lines;
		if(len line == 0 || line[0] == '#')
			continue;
		(nf, f) := sys->tokenize(line, " \t");
		if(nf < 2 || len hd f != 1)
			continue;
		r = ((hd f)[0], hd tl f) :: r;
	}
	return r;
}

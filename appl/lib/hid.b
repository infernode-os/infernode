implement Hid;

#
# HID report descriptor parsing for a mouse and a keyboard; see hid.m. Short items
# only (a long item is skipped whole), Push/Pop of the global state
# honoured, one application collection at a time. Bits are numbered
# from the report's first byte, least significant first, as HID lays
# them out.
#

include "sys.m";
	sys: Sys;
include "hid.m";

init()
{
	sys = load Sys Sys->PATH;
}

# item tags, with type in bits 2-3: 0 main, 1 global, 2 local
Tinput:		con 16r80;
Toutput:	con 16r90;
Tfeature:	con 16rb0;
Tcollection:	con 16ra0;
Tendcoll:	con 16rc0;
Tusagepage:	con 16r04;
Tlogmin:	con 16r14;
Tlogmax:	con 16r24;
Treportsize:	con 16r74;
Treportid:	con 16r84;
Treportcount:	con 16r94;
Tpush:		con 16ra4;
Tpop:		con 16rb4;
Tusage:		con 16r08;
Tusagemin:	con 16r18;
Tusagemax:	con 16r28;

Pdesktop:	con 1;
Pkeyboard:	con 7;
Pbutton:	con 9;
Umouse:		con 2;
Upointer:	con 1;
Ukeyboard:	con 6;
Ukeypad:	con 7;
Ux:		con 16r30;
Uy:		con 16r31;
Uwheel:		con 16r38;

Global: adt {
	page:	int;
	lmin, lmax: int;
	size:	int;
	count:	int;
	id:	int;
};

#
# One Input main item, as the walk below found it: the global state at
# that moment, the local usages that went with it, its flags, and the
# usage of the top-level application collection it sits in (-1 for
# none). Both readers -- the mouse's and the keyboard's -- take these
# in order, so the item walk is written once.
#
Inp: adt {
	g:	ref Global;
	usages:	list of int;
	umin, umax: int;
	flags:	int;
	app:	int;
};

# every Input item in the map, in order; ok is 0 if the map is malformed
walk(map: array of byte): (list of ref Inp, int)
{
	g := ref Global(0, 0, 0, 0, 0, 0);
	stack: list of ref Global;
	usages: list of int;		# local usages, in order given
	umin := -1;
	umax := -1;
	inps: list of ref Inp;		# newest first
	depth := 0;
	app := -1;			# the application collection we are in
	appusage := -1;			# the usage the next collection opens with

	for(i := 0; i < len map;){
		b := int map[i];
		if(b == 16rfe){
			# long item: bDataSize follows
			if(i + 2 >= len map)
				return (nil, 0);
			i += 3 + int map[i+1];
			continue;
		}
		n := b & 3;
		if(n == 3)
			n = 4;
		tag := b & 16rfc;
		if(i + 1 + n > len map)
			return (nil, 0);
		v := 0;
		for(k := 0; k < n; k++)
			v |= int map[i+1+k] << (8*k);
		sv := v;			# sign-extended, for logical min/max
		case n {
		1 =>	if(v & 16r80) sv = v - 16r100;
		2 =>	if(v & 16r8000) sv = v - 16r10000;
		}
		i += 1 + n;

		case tag {
		Tusagepage =>	g.page = v;
		Tlogmin =>	g.lmin = sv;
		Tlogmax =>	g.lmax = sv;
		Treportsize =>	g.size = v;
		Treportid =>	g.id = v;
		Treportcount =>	g.count = v;
		Tpush =>	stack = ref Global(g.page, g.lmin, g.lmax, g.size, g.count, g.id) :: stack;
		Tpop =>
			if(stack != nil){
				g = hd stack;
				stack = tl stack;
			}
		Tusage =>
			# a 4-byte usage carries its own page in the high half
			if(n == 4)
				usages = appendi(usages, v);
			else
				usages = appendi(usages, (g.page << 16) | v);
			if(appusage < 0)
				appusage = (hd usages);
		Tusagemin =>	umin = v;
		Tusagemax =>	umax = v;
		Tcollection =>
			# 1 is Application; at the top level it says what the
			# reports inside it are for
			if(v == 1 && depth == 0)
				app = appusage;
			depth++;
			usages = nil;
			umin = umax = -1;
			appusage = -1;
		Tendcoll =>
			depth--;
			if(depth <= 0){
				app = -1;
				depth = 0;
			}
			usages = nil;
			umin = umax = -1;
			appusage = -1;
		Tinput =>
			if(app >= 0)
				inps = ref Inp(ref Global(g.page, g.lmin, g.lmax, g.size, g.count, g.id),
					usages, umin, umax, v, app) :: inps;
			usages = nil;
			umin = umax = -1;
			appusage = -1;
		Toutput or Tfeature =>
			usages = nil;
			umin = umax = -1;
			appusage = -1;
		}
	}
	l: list of ref Inp;
	for(; inps != nil; inps = tl inps)
		l = hd inps :: l;
	return (l, 1);
}

parse(map: array of byte): list of ref Report
{
	(inps, ok) := walk(map);
	if(!ok)
		return nil;
	reports: list of ref Report;	# built up, newest first
	for(; inps != nil; inps = tl inps){
		p := hd inps;
		# a Mouse or Pointer application collection is the part we read
		if(p.app == (Pdesktop << 16 | Umouse) || p.app == (Pdesktop << 16 | Upointer))
			reports = input(reports, p.g, p.usages, p.umin, p.umax, p.flags);
	}
	r: list of ref Report;
	for(; reports != nil; reports = tl reports)
		r = hd reports :: r;
	return r;
}

#
# A keyboard: the input reports of every Keyboard or Keypad application
# collection, and in each the runs of Keyboard-page usages -- the
# modifier bits (usages E0-E7), the key array a boot-style keyboard
# reports up to six keys in, and the bitmap an n-key-rollover keyboard
# reports every key in, one bit each. Fields of other pages in the
# same report (a vendor byte, LEDs are outputs and never appear) are
# stepped over; a report with no Keyboard-page field is left out.
#
keyboard(map: array of byte): list of ref Keys
{
	(inps, ok) := walk(map);
	if(!ok)
		return nil;
	keys: list of ref Keys;		# newest first
	for(; inps != nil; inps = tl inps){
		p := hd inps;
		if(p.app != (Pdesktop << 16 | Ukeyboard) && p.app != (Pdesktop << 16 | Ukeypad))
			continue;
		g := p.g;
		k: ref Keys;
		for(l := keys; l != nil; l = tl l)
			if((hd l).id == g.id)
				k = hd l;
		if(k == nil){
			k = ref Keys(g.id, 0, nil);
			keys = k :: keys;
		}
		off := k.bits;
		k.bits += g.size * g.count;
		if(p.flags & 1)
			continue;	# constant: padding
		if(p.flags & 2){
			# variable: each field is its own usage, a bit when it is a key
			for(j := 0; j < g.count; j++){
				u := -1;
				if(p.umin >= 0 && (p.umax < 0 || p.umin + j <= p.umax))
					u = (g.page << 16) | (p.umin + j);
				else if(p.usages != nil){
					ul := p.usages;
					for(m := 0; m < j && tl ul != nil; m++)
						ul = tl ul;
					u = hd ul;
				}
				if(u >> 16 == Pkeyboard)
					k.runs = appendr(k.runs, ref Keyrun(off + j*g.size, g.size, 1, u & 16rffff, 0, 0));
			}
		} else {
			# an array: each slot holds the index of a key that is down
			page := g.page;
			first := p.umin;
			if(first < 0 && p.usages != nil){
				page = hd p.usages >> 16;
				first = hd p.usages & 16rffff;
			}
			if(page == Pkeyboard && first >= 0)
				k.runs = appendr(k.runs, ref Keyrun(off, g.size, g.count, first, g.lmin, 1));
		}
	}
	r: list of ref Keys;
	for(; keys != nil; keys = tl keys)
		if((hd keys).runs != nil)
			r = hd keys :: r;
	return r;
}

findkeys(l: list of ref Keys, id: int): ref Keys
{
	for(; l != nil; l = tl l)
		if((hd l).id == id)
			return hd l;
	return nil;
}

#
# What one report says is held: the modifier byte, in the boot report's
# layout (bit 0 left control ... bit 7 right GUI, usages E0-E7), and the
# other keys down, as Keyboard-page usages. Usages 1-3 are the
# keyboard's error codes (roll-over, POST fail, undefined): a report
# full of them means "too many keys to say", and they are not keys.
#
Keys.held(k: self ref Keys, data: array of byte): (int, list of int)
{
	mod := 0;
	down: list of int;
	for(l := k.runs; l != nil; l = tl l){
		r := hd l;
		for(j := 0; j < r.count; j++){
			u: int;
			if(r.isarray){
				v := bits(data, r.off + j*r.size, r.size, 0);
				u = r.umin + (v - r.lmin);
				if(v < r.lmin)
					continue;
			} else {
				if(bits(data, r.off + j*r.size, r.size, 0) == 0)
					continue;
				u = r.umin + j;
			}
			if(u >= 16rE0 && u <= 16rE7)
				mod |= 1 << (u - 16rE0);
			else if(u >= 4)
				down = u :: down;
		}
	}
	return (mod, down);
}

appendr(l: list of ref Keyrun, r: ref Keyrun): list of ref Keyrun
{
	if(l == nil)
		return r :: nil;
	return hd l :: appendr(tl l, r);
}

# the report with this ID, made if new; reports are kept newest first
report(reports: list of ref Report, id: int): (ref Report, list of ref Report)
{
	for(l := reports; l != nil; l = tl l)
		if((hd l).id == id)
			return (hd l, reports);
	r := ref Report(id, 0, nil, nil, nil, nil);
	return (r, r :: reports);
}

# an Input main item: count fields of size bits, each with a usage
input(reports: list of ref Report, g: ref Global, usages: list of int, umin, umax: int, flags: int): list of ref Report
{
	r: ref Report;
	(r, reports) = report(reports, g.id);
	off := r.bits;
	if(flags & 1){
		# constant: padding
		r.bits += g.size * g.count;
		return reports;
	}
	nu := len usages;
	for(k := 0; k < g.count; k++){
		u := -1;
		if(umin >= 0 && (umax < 0 || umin + k <= umax))
			u = (g.page << 16) | (umin + k);
		else if(usages != nil){
			# fewer usages than fields: the last one repeats
			ul := usages;
			for(j := 0; j < k && j < nu - 1; j++)
				ul = tl ul;
			u = hd ul;
		}
		f := ref Field(off + k * g.size, g.size, 1, g.lmin < 0, g.lmin, g.lmax);
		if(u >= 0)
		case u >> 16 {
		Pbutton =>
			if(r.buttons == nil)
				r.buttons = ref Field(f.off, g.size, 0, 0, g.lmin, g.lmax);
			r.buttons.count++;
		Pdesktop =>
			case u & 16rffff {
			Ux =>		r.x = f;
			Uy =>		r.y = f;
			Uwheel =>	r.wheel = f;
			}
		}
	}
	r.bits += g.size * g.count;
	return reports;
}

find(l: list of ref Report, id: int): ref Report
{
	for(; l != nil; l = tl l)
		if((hd l).id == id)
			return hd l;
	return nil;
}

# bits [off, off+size) of data, least significant first, as an integer
bits(data: array of byte, off, size: int, signed: int): int
{
	v := 0;
	for(k := 0; k < size; k++){
		b := off + k;
		if(b / 8 >= len data)
			break;
		if(int data[b / 8] & (1 << (b % 8)))
			v |= 1 << k;
	}
	if(signed && size < 32 && (v & (1 << (size - 1))))
		v -= 1 << size;
	return v;
}

clamp(v: int): int
{
	if(v > 127)
		return 127;
	if(v < -127)
		return -127;
	return v;
}

# the boot layout: buttons (one bit each, up to eight), dx, dy, wheel
Report.mouse(r: self ref Report, data: array of byte): array of byte
{
	out := array[4] of { * => byte 0 };
	if(r.buttons != nil){
		n := r.buttons.count;
		if(n > 8)
			n = 8;
		out[0] = byte bits(data, r.buttons.off, n, 0);
	}
	if(r.x != nil)
		out[1] = byte clamp(bits(data, r.x.off, r.x.size, r.x.signed));
	if(r.y != nil)
		out[2] = byte clamp(bits(data, r.y.off, r.y.size, r.y.signed));
	if(r.wheel != nil)
		out[3] = byte clamp(bits(data, r.wheel.off, r.wheel.size, r.wheel.signed));
	return out;
}

appendi(l: list of int, v: int): list of int
{
	if(l == nil)
		return v :: nil;
	return hd l :: appendi(tl l, v);
}

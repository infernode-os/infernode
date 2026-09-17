implement Hid;

#
# HID report descriptor parsing for a mouse; see hid.m. Short items
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
Pbutton:	con 9;
Umouse:		con 2;
Upointer:	con 1;
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

parse(map: array of byte): list of ref Report
{
	g := ref Global(0, 0, 0, 0, 0, 0);
	stack: list of ref Global;
	usages: list of int;		# local usages, in order given
	umin := -1;
	umax := -1;
	reports: list of ref Report;	# built up, newest first
	depth := 0;
	inmouse := 0;			# inside a Mouse/Pointer application collection
	appusage := -1;			# the usage the next collection opens with

	for(i := 0; i < len map;){
		b := int map[i];
		if(b == 16rfe){
			# long item: bDataSize follows
			if(i + 2 >= len map)
				return nil;
			i += 3 + int map[i+1];
			continue;
		}
		n := b & 3;
		if(n == 3)
			n = 4;
		tag := b & 16rfc;
		if(i + 1 + n > len map)
			return nil;
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
			# 1 is Application; a Mouse or Pointer opens the part we read
			if(v == 1 && depth == 0){
				u := appusage;
				if(u == (Pdesktop << 16 | Umouse) || u == (Pdesktop << 16 | Upointer))
					inmouse = 1;
			}
			depth++;
			usages = nil;
			umin = umax = -1;
			appusage = -1;
		Tendcoll =>
			depth--;
			if(depth <= 0){
				inmouse = 0;
				depth = 0;
			}
			usages = nil;
			umin = umax = -1;
			appusage = -1;
		Tinput =>
			if(inmouse)
				reports = input(reports, g, usages, umin, umax, v);
			usages = nil;
			umin = umax = -1;
			appusage = -1;
		Toutput or Tfeature =>
			usages = nil;
			umin = umax = -1;
			appusage = -1;
		}
	}
	r: list of ref Report;
	for(; reports != nil; reports = tl reports)
		r = hd reports :: r;
	return r;
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

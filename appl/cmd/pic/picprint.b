#
# print.c, pltroff.c
#

# kept from one object to the next, as C's are
px1 := 0.0;
py1 := 0.0;

print()
{
	for(i := 0; i < nobj; i++){
		p := objlist[i];
		ox := p.x;
		oy := p.y;
		if(p.count >= 1)
			px1 = p.val[0];
		if(p.count >= 2)
			py1 = p.val[1];
		x1 := px1;
		y1 := py1;
		m := p.mode;
		fill := p.attr & FILLBIT;
		invis := p.attr & INVIS;
		vis := !invis;
		case p.typ {
		TROFF =>
			troff(text[p.nt1].val);
		BOX or BLOCK =>
			x0 := ox - x1 / 2.0;
			y0 := oy - y1 / 2.0;
			x1 = ox + x1 / 2.0;
			y1 = oy + y1 / 2.0;
			if(fill)
				box(x0, y0, x1, y1, 1, p.fillval);
			if(p.typ == BLOCK)
				;	# nothing at all
			else if(invis && !fill)
				;	# nothing at all
			else if(p.attr & (DOTBIT|DASHBIT))
				dotbox(x0, y0, x1, y1, p.attr, p.ddval);
			else
				box(x0, y0, x1, y1, 0, 0.0);
			move(ox, oy);
			dotext(p);	# if there are any text strings
			if(ishor(m)){
				if(isright(m))
					move(x1, oy);	# right side
				else
					move(x0, oy);
			}else{
				if(isdown(m))
					move(ox, y0);	# bottom
				else
					move(ox, y1);
			}
		BLOCKEND =>
			;
		CIRCLE =>
			if(fill)
				circle(ox, oy, x1, 1, p.fillval);
			if(vis)
				circle(ox, oy, x1, 0, 0.0);
			move(ox, oy);
			dotext(p);
			# C's ox + isright(m) ? x1 : -x1
			if(ishor(m)){
				if(ox + real isright(m) != 0.0)
					move(x1, oy);
				else
					move(-x1, oy);
			}else{
				if(oy + real isup(m) != 0.0)
					move(ox, x1);
				else
					move(ox, -x1);
			}
		ELLIPSE =>
			if(fill)
				ellipse(ox, oy, x1, y1, 1, p.fillval);
			if(vis)
				ellipse(ox, oy, x1, y1, 0, 0.0);
			move(ox, oy);
			dotext(p);
			if(ishor(m)){
				if(ox + real isright(m) != 0.0)
					move(x1, oy);
				else
					move(-x1, oy);
			}else{
				if(oy - real isdown(m) != 0.0)
					move(ox, y1);
				else
					move(ox, -y1);
			}
		ARC =>
			if(p.attr & HEAD1)
				arrow(x1 - (y1 - oy), y1 + (x1 - ox),
				      x1, y1, p.val[4], p.val[5], f32(f32(p.val[5]/p.val[6])/2.0), p.nhead);
			if(fill)
				arc(ox, oy, x1, y1, p.val[2], p.val[3], 1, p.fillval);
			if(invis && !fill)
				# probably wrong when it's cw
				move(x1, y1);
			else if(vis)
				arc(ox, oy, x1, y1, p.val[2], p.val[3], 0, 0.0);
			if(p.attr & HEAD2)
				arrow(f32(p.val[2] + p.val[3]) - oy, p.val[3] - (p.val[2] - ox),
				      p.val[2], p.val[3], p.val[4], p.val[5], f32(f32(-p.val[5]/p.val[6])/2.0), p.nhead);
			if(p.attr & CW_ARC)
				move(x1, y1);	# because drawn backwards
			move(ox, oy);
			dotext(p);
		LINE or ARROW or SPLINE =>
			if(vis && p.attr & HEAD1)
				arrow(ox + p.val[5], oy + p.val[6], ox, oy, p.val[2], p.val[3], 0.0, p.nhead);
			if(invis && !fill)
				move(x1, y1);
			else if(p.typ == SPLINE){
				if(fill)
					spline(ox, oy, p.val[4], p.val[5:],
						p.attr & (DOTBIT|DASHBIT), p.ddval, 1, p.fillval);
				if(vis)
					spline(ox, oy, p.val[4], p.val[5:],
						p.attr & (DOTBIT|DASHBIT), p.ddval, 0, 0.0);
			}else{
				if(fill)
					muline(ox, oy, p.val[4], p.val[5:], 1, p.fillval);
				dx := ox;
				dy := oy;
				j := 5;
				for(k := 0; real k < p.val[4]; k++){
					ndx := dx + p.val[j];
					ndy := dy + p.val[j+1];
					if(p.attr & (DOTBIT|DASHBIT))
						dotline(dx, dy, ndx, ndy, p.attr, p.ddval);
					else
						line(dx, dy, ndx, ndy);
					dx = ndx;
					dy = ndy;
					j += 2;
				}
			}
			if(vis && p.attr & HEAD2){
				dx := ox;
				dy := oy;
				j := 5;
				for(k := 0; real k < p.val[4] - 1.0; k++){
					dx += p.val[j];
					dy += p.val[j+1];
					j += 2;
				}
				arrow(dx, dy, x1, y1, p.val[2], p.val[3], 0.0, p.nhead);
			}
			move((ox + x1)/2.0, (oy + y1)/2.0);	# center
			dotext(p);
		MOVE =>
			move(ox, oy);
		TEXT =>
			move(ox, oy);
			if(vis)
				dotext(p);
		}
		px1 = x1;
		py1 = y1;
	}
}

prevval := 0.05;	# 20 per inch by default

dotline(x0: real, y0: real, x1: real, y1: real, ddtype: int, ddval: real)	# dotted line
{
	if(ddval == 0.0)
		ddval = prevval;
	prevval = ddval;
	# don't save dot/dash value
	dx := x1 - x0;
	dy := y1 - y0;
	if(ddtype & DOTBIT){
		numdots := cint(math->sqrt(dx*dx + dy*dy) / prevval + 0.5);
		if(numdots > 0)
			for(i := 0; i <= numdots; i++){
				a := real i / real numdots;
				move(x0 + (a * dx), y0 + (a * dy));
				dot();
			}
	}else if(ddtype & DASHBIT){
		d := math->sqrt(dx*dx + dy*dy);
		if(d <= 2.0 * prevval){
			line(x0, y0, x1, y1);
			return;
		}
		numdots := cint(d / (2.0 * prevval) + 1.0);	# ceiling
		dashsize := prevval;
		spacesize := (d - real numdots * dashsize) / real (numdots - 1);
		b := 0.0;
		for(i := 0; i < numdots-1; i++){
			a := real i * (dashsize + spacesize) / d;
			b = a + dashsize / d;
			line(x0 + (a*dx), y0 + (a*dy), x0 + (b*dx), y0 + (b*dy));
			a = b;
			b = a + spacesize / d;
			move(x0 + (a*dx), y0 + (a*dy));
		}
		line(x0 + (b * dx), y0 + (b * dy), x1, y1);
	}
	prevval = 0.05;
}

dotbox(x0: real, y0: real, x1: real, y1: real, ddtype: int, ddval: real)	# dotted or dashed box
{
	dotline(x0, y0, x1, y0, ddtype, ddval);
	dotline(x1, y0, x1, y1, ddtype, ddval);
	dotline(x1, y1, x0, y1, ddtype, ddval);
	dotline(x0, y1, x0, y0, ddtype, ddval);
}

dotext(p: ref Obj)	# print text strings of p in proper vertical spacing
{
	nhalf := p.nt2 - p.nt1 - 1;
	for(i := p.nt1; i < p.nt2; i++){
		label(text[i].val, text[i].typ, nhalf);
		nhalf -= 2;
	}
}

#
# pltroff.c
#
textshift := "\\v'.2m'";	# move text this far down

# scaling stuff defined by s command as X0,Y0 to X1,Y1
# output dimensions set by -l,-w options to 0,0 to hmax, vmax
# default output is 6x6 inches
xscale := 0.0;
yscale := 0.0;
hpos := 0.0;	# current horizontal position in output coordinate system
vpos := 0.0;	# current vertical position; 0 is top of page
htrue := 0.0;	# where we really are
vtrue := 0.0;
X0, Y0: real;	# left bottom of input
X1, Y1: real;	# right top of input

line(x0: real, y0: real, x1: real, y1: real)	# draw line from x0,y0 to x1,y1
{
	move(x0, y0);
	cont(x1, y1);
}

openpl(s: string)	# initialize device; s is residue of .PS invocation line
{
	ratio := 1.0;
	odeltx := deltx;
	odelty := delty;
	hpos = vpos = 0.0;
	maxw := getfval("maxpswid");
	maxh := getfval("maxpsht");
	if(deltx > maxw){	# shrink horizontal
		ratio = maxw / deltx;
		deltx *= ratio;
		delty *= ratio;
	}
	if(delty > maxh){	# shrink vertical
		ratio = maxh / delty;
		deltx *= ratio;
		delty *= ratio;
	}
	if(ratio != 1.0){
		stdout.flush();
		errout("pic: " + g(odeltx) + " X " + g(odelty) + " picture shrunk to");
		errout(" " + g(deltx) + " X " + g(delty) + "\n");
	}
	space(xmin, ymin, xmax, ymax);
	out("... " + g(xmin) + " " + g(ymin) + " " + g(xmax) + " " + g(ymax) + "\n");
	out("... " + f3(xconv(xmin)) + "i " + f3(yconv(ymin)) + "i " + f3(xconv(xmax)) + "i " +
		f3(yconv(ymax)) + "i\n");
	out(".nr 00 \\n(.u\n");
	out(".nf\n");
	out(".PS " + f3(yconv(ymin)) + "i " + f3(xconv(xmax)) + "i " + s);
	# assumes \n comes as part of s
}

space(x0: real, y0: real, x1: real, y1: real)	# set limits of page
{
	X0 = x0;
	Y0 = y0;
	X1 = x1;
	Y1 = y1;
	if(deltx == 0.0)
		xscale = 1.0;
	else
		xscale = deltx / (X1-X0);
	if(delty == 0.0)
		yscale = 1.0;
	else
		yscale = delty / (Y1-Y0);
}

xconv(x: real): real	# convert x from external to internal form
{
	return (x-X0) * xscale;
}

xsc(x: real): real	# convert x from external to internal form, scaling only
{
	return x * xscale;
}

yconv(y: real): real	# convert y from external to internal form
{
	return (Y1-y) * yscale;
}

ysc(y: real): real	# convert y from external to internal form, scaling only
{
	return y * yscale;
}

closepl(PEline: string)	# clean up after finished
{
	movehv(0.0, 0.0);	# get back to where we started
	if(strchr(PEline, 'F') < 0)
		out(".sp 1+" + f3(yconv(ymin)) + "i\n");
	out(PEline + "\n");
	out(".if \\n(00 .fi\n");
}

move(x: real, y: real)	# go to position x, y in external coords
{
	hgoto(xconv(x));
	vgoto(yconv(y));
}

movehv(h: real, v: real)	# go to internal position h, v
{
	hgoto(h);
	vgoto(v);
}

hgoto(n: real)
{
	hpos = n;
}

vgoto(n: real)
{
	vpos = n;
}

hvflush()	# get to proper point for output
{
	if(math->fabs(hpos-htrue) >= 0.0005){
		out("\\h'" + f3(hpos - htrue) + "i'");
		htrue = hpos;
	}
	if(math->fabs(vpos-vtrue) >= 0.0005){
		out("\\v'" + f3(vpos - vtrue) + "i'");
		vtrue = vpos;
	}
}

flyback()	# return to upper left corner (entry point)
{
	out(".sp -1\n");
	htrue = vtrue = 0.0;
}

printlf(n: int, f: string)
{
	if(f != nil)
		out(".lf " + string n + " " + f + "\n");
	else
		out(".lf " + string n + "\n");
}

troff(s: string)	# output troff right here
{
	out(s + "\n");
}

label(s: string, t: int, nh: int)	# text s of type t nh half-lines up
{
	if(s == NULLP)
		return;
	hvflush();
	out(textshift);	# shift down and left
	if(t & ABOVE)
		nh++;
	else if(t & BELOW)
		nh--;
	if(nh)
		out(sys->sprint("\\v'%du*\\n(.vu/2u'", -nh));
	# just in case the text contains a quote:
	q := strchr(s, '\'') >= 0;
	t &= ~(ABOVE|BELOW);
	if(t & LJUST){
		out(s);
	}else if(t & RJUST){
		if(q)
			out("\\h\\(ts-\\w\\(ts" + s + "\\(tsu\\(ts" + s);
		else
			out("\\h'-\\w'" + s + "'u'" + s);
	}else{	# CENTER
		if(q)
			out("\\h\\(ts-\\w\\(ts" + s + "\\(tsu/2u\\(ts" + s);
		else
			out("\\h'-\\w'" + s + "'u/2u'" + s);
	}
	out("\n");
	flyback();
}

fillbeg(fillval: real): string
{
	if(fillval >= 0.0 && fillval <= 1.0)
		return sys->sprint("\\m[#%02x]", cint(fillval * 255.0));
	return "";
}

fillend(fillval: real): string
{
	if(fillval >= 0.0 && fillval <= 1.0)
		return "\\m[]";
	return "";
}

muline(x: real, y: real, n: real, p: array of real, fill: int, fillval: real)
{
	move(x, y);
	hvflush();
	xerr := 0.0;
	yerr := 0.0;
	if(fill)
		out(fillbeg(fillval) + "\\D'P ");
	for(i := 0; real i < 2.0 * n; i += 2){
		xerr += p[i];
		dx := xsc(xerr);
		xerr -= dx/xscale;
		yerr += p[i+1];
		dy := ysc(yerr);
		yerr -= dy/yscale;
		if(!fill)
			out("\\D'l ");
		out(" " + f3(dx) + "i " + f3(-dy) + "i");	# WATCH SIGN
		if(!fill)
			out("'");
	}
	if(fill)
		out("'" + fillend(fillval) + "\n");
	flyback();
}

arrow(x0: real, y0: real, x1: real, y1: real, w: real, h: real, ang: real, nhead: int)	# draw arrow (without shaft)
{
	rot := math->atan2(w / 2.0, h);
	hyp := math->sqrt(w/2.0 * w/2.0 + h * h);
	alpha := math->atan2(y1-y0, x1-x0) + ang;
	if(nhead < 2)
		nhead = 2;
	for(i := nhead-1; i >= 0; i--){
		drot := 2.0 * rot / real (nhead-1) * real i;
		dx := hyp * math->cos(alpha + PI - rot + drot);
		dy := hyp * math->sin(alpha + PI - rot + drot);
		line(x1+dx, y1+dy, x1, y1);
	}
}

box(x0: real, y0: real, x1: real, y1: real, fill: int, fillval: real)
{
	move(x0, y0);
	h1 := xconv(x1);
	v1 := yconv(y1);
	dh := h1 - hpos;
	dv := v1 - vpos;
	hvflush();
	if(fill){
		out(fillbeg(fillval) + "\\D'P 0 " + f3(dv) + "i " + f3(dh) + "i 0 0 " + f3(-dv) + "i " +
			f3(-dh) + "i 0'" + fillend(fillval) + "\n");
	}else{
		out("\\D'p 0 " + f3(dv) + "i " + f3(dh) + "i 0 0 " + f3(-dv) + "i " + f3(-dh) + "i 0'\n");
	}
	flyback();	# expensive
}

cont(x: real, y: real)	# continue line from here to x,y
{
	h1 := xconv(x);
	v1 := yconv(y);
	dh := h1 - hpos;
	dv := v1 - vpos;
	hvflush();
	out("\\D'l" + f3(dh) + "i " + f3(dv) + "i'\n");
	flyback();	# expensive
	hpos = h1;
	vpos = v1;
}

circle(x: real, y: real, r: real, fill: int, fillval: real)
{
	move(x-r, y);
	hvflush();
	if(fill)
		out(fillbeg(fillval) + "\\D'C" + f3(xsc(2.0 * r)) + "i'" + fillend(fillval) + "\n");
	else
		out("\\D'c" + f3(xsc(2.0 * r)) + "i'\n");
	flyback();
}

spline(x: real, y: real, n: real, p: array of real, nil: int, nil: real, fill: int, fillval: real)
{
	move(x, y);
	hvflush();
	xerr := 0.0;
	yerr := 0.0;
	if(fill)
		out(fillbeg(fillval) + "\\D'P ~");
	else
		out("\\D'~");
	for(i := 0; real i < 2.0 * n; i += 2){
		xerr += p[i];
		dx := xsc(xerr);
		xerr -= dx/xscale;
		yerr += p[i+1];
		dy := ysc(yerr);
		yerr -= dy/yscale;
		out(" " + f3(dx) + "i " + f3(-dy) + "i");	# WATCH SIGN
	}
	if(fill)
		out("'" + fillend(fillval) + "\n");
	else
		out("'\n");
	flyback();
}

ellipse(x: real, y: real, r1: real, r2: real, fill: int, fillval: real)
{
	move(x-r1, y);
	hvflush();
	ir1 := xsc(r1);
	ir2 := ysc(r2);
	if(ir2 < 0.0)
		ir2 = -ir2;
	if(fill){
		out(fillbeg(fillval) + "\\D'E" + f3(2.0 * ir1) + "i " + f3(2.0 * ir2) + "i'" + fillend(fillval) + "\n");
	}else{
		out("\\D'e" + f3(2.0 * ir1) + "i " + f3(2.0 * ir2) + "i'\n");
	}
	flyback();
}

arc(x: real, y: real, x0: real, y0: real, x1: real, y1: real, fill: int, fillval: real)	# draw arc with center x,y
{
	move(x0, y0);
	hvflush();
	if(fill){
		out(fillbeg(fillval) + "\\D'P a " + f3(xsc(x-x0)) + "i " + f3(-ysc(y-y0)) + "i " +
			f3(xsc(x1-x)) + "i " + f3(-ysc(y1-y)) + "i'" + fillend(fillval) + "\n");	# WATCH SIGNS
	}else{
		out("\\D'a" + f3(xsc(x-x0)) + "i " + f3(-ysc(y-y0)) + "i " + f3(xsc(x1-x)) + "i " +
			f3(-ysc(y1-y)) + "i'\n");	# WATCH SIGNS
	}
	flyback();
}

dot()
{
	hvflush();
	# what character to draw here depends on what's available.
	# on the 202, l. is good but small.
	# in general, use a smaller, shifted period and hope
	out("\\&\\f1\\h'-.1m'\\v'.03m'\\s-3.\\s+3\\fP\n");
	flyback();
}

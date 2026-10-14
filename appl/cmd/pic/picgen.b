#
# blockgen.c, boxgen.c, circgen.c, arcgen.c, linegen.c, movegen.c,
# textgen.c: what a float field is given is rounded to a float
#

NBRACK: con 20;	# depth of [...]
NBRACE: con 20;	# depth of {...}
stack := array[NBRACK] of Pushstack;
nstack := 0;
bracestack := array[NBRACE] of Pushstack;
nbstack := 0;

leftthing(c: int): ref Obj	# called for {... or [...
	# really ought to be separate functions
{
	p: ref Obj;
	if(c == '['){
		if(nstack >= NBRACK)
			fatal("[...] nested too deep");
		stack[nstack].x = curx;
		stack[nstack].y = cury;
		stack[nstack].hvmode = hvmode;
		curx = cury = 0.0;
		stack[nstack].xmin = xmin;
		stack[nstack].xmax = xmax;
		stack[nstack].ymin = ymin;
		stack[nstack].ymax = ymax;
		nstack++;
		xmin = ymin = 30000.0;
		xmax = ymax = -30000.0;
		p = makenode(BLOCK, 7);
		p.val[4] = f32(real nobj);	# 1st item within [...]
		p.val[5] = -1.0;	# open: no last item yet (set at ])
		if(p.nobj != nobj-1)
			errout(sys->sprint("nobjs wrong%d %d\n", p.nobj, nobj));
	}else{
		if(nbstack >= NBRACK)
			fatal("{...} nested too deep");
		bracestack[nbstack].x = curx;
		bracestack[nbstack].y = cury;
		bracestack[nbstack].hvmode = hvmode;
		nbstack++;
		p = nil;
	}
	return p;
}

rightthing(p: ref Obj, c: int): ref Obj	# called for ... ] or ... }
{
	q: ref Obj;
	if(c == '}'){
		nbstack--;
		curx = bracestack[nbstack].x;
		cury = bracestack[nbstack].y;
		hvmode = bracestack[nbstack].hvmode;
		q = makenode(MOVE, 0);
	}else{
		nstack--;
		curx = stack[nstack].x;
		cury = stack[nstack].y;
		hvmode = stack[nstack].hvmode;
		q = makenode(BLOCKEND, 7);
		q.val[4] = f32(real (p.nobj + 1));	# back pointer
		p.val[5] = f32(real (q.nobj - 1));	# forward pointer
		if(xmin > xmax)	# nothing happened
			xmin = xmax;
		if(ymin > ymax)
			ymin = ymax;
		p.val[0] = f32(xmin); p.val[1] = f32(ymin);
		p.val[2] = f32(xmax); p.val[3] = f32(ymax);
		p.symtab = q.symtab = stack[nstack+1].symtab;
		xmin = stack[nstack].xmin;
		ymin = stack[nstack].ymin;
		xmax = stack[nstack].xmax;
		ymax = stack[nstack].ymax;
	}
	return q;
}

blockgen(p: ref Obj, q: ref Obj): ref Obj	# handles [...]
{
	invis := 0;
	at := 0;
	with := 0;
	xwith := 0.0;
	ywith := 0.0;
	ddval := 0.0;
	w := f32(p.val[2] - p.val[0]);
	h := f32(p.val[3] - p.val[1]);
	cx := f32(p.val[2] + p.val[0]) / 2.0;	# geom ctr of [] wrt local orogin
	cy := f32(p.val[3] + p.val[1]) / 2.0;
	for(i := 0; i < nattr; i++){
		ap := attr[i];
		case ap.typ {
		HEIGHT =>
			h = ap.val.f;
		WIDTH =>
			w = ap.val.f;
		WITH =>
			with = ap.val.i;	# corner
		PLACE =>	# actually with position ...
			ppos := ap.val.o;
			xwith = cx - ppos.x;
			ywith = cy - ppos.y;
			with = PLACE;
		AT or FROM =>
			ppos := ap.val.o;
			curx = ppos.x;
			cury = ppos.y;
			at++;
		INVIS =>
			invis = INVIS;
		TEXTATTR =>
			savetext(ap.sub, ap.val.p);
		}
	}
	if(with){
		case with {
		NORTH =>	ywith = -h / 2.0;
		SOUTH =>	ywith = h / 2.0;
		EAST =>	xwith = -w / 2.0;
		WEST =>	xwith = w / 2.0;
		NE =>	xwith = -w / 2.0; ywith = -h / 2.0;
		SE =>	xwith = -w / 2.0; ywith = h / 2.0;
		NW =>	xwith = w / 2.0; ywith = -h / 2.0;
		SW =>	xwith = w / 2.0; ywith = h / 2.0;
		}
		curx += xwith;
		cury += ywith;
	}
	if(!at){
		if(isright(hvmode))
			curx += w / 2.0;
		else if(isleft(hvmode))
			curx -= w / 2.0;
		else if(isup(hvmode))
			cury += h / 2.0;
		else
			cury -= h / 2.0;
	}
	x0 := curx - w / 2.0;
	y0 := cury - h / 2.0;
	x1 := curx + w / 2.0;
	y1 := cury + h / 2.0;
	extreme(x0, y0);
	extreme(x1, y1);
	p.x = f32(curx);
	p.y = f32(cury);
	p.nt1 = ntext1;
	p.nt2 = ntext;
	ntext1 = ntext;
	p.val[0] = f32(w);
	p.val[1] = f32(h);
	p.val[2] = f32(cx);
	p.val[3] = f32(cy);
	p.val[5] = f32(real (q.nobj - 1));	# last item in [...]
	p.ddval = f32(ddval);
	p.attr = invis;
	if(isright(hvmode))
		curx = x1;
	else if(isleft(hvmode))
		curx = x0;
	else if(isup(hvmode))
		cury = y1;
	else
		cury = y0;
	for(i = 0; i <= 5; i++)
		q.val[i] = p.val[i];
	stack[nstack+1].symtab = nil;	# so won't be found again
	blockadj(p);	# fix up coords for enclosed blocks
	return p;
}

blockadj(p: ref Obj)	# adjust coords in block starting at p
{
	dx := f32(p.x - p.val[2]);
	dy := f32(p.y - p.val[3]);
	n := p.nobj + 1;
	for(lev := 1; lev > 0; n++){
		p = objlist[n];
		if(p.typ == BLOCK)
			lev++;
		else if(p.typ == BLOCKEND)
			lev--;
		p.x = f32(p.x + dx);
		p.y = f32(p.y + dy);
		case p.typ {	# other absolute coords
		LINE or ARROW or SPLINE =>
			p.val[0] = f32(p.val[0] + dx);
			p.val[1] = f32(p.val[1] + dy);
		ARC =>
			p.val[0] = f32(p.val[0] + dx);
			p.val[1] = f32(p.val[1] + dy);
			p.val[2] = f32(p.val[2] + dx);
			p.val[3] = f32(p.val[3] + dy);
		}
	}
}

box_prevh := HT;
box_prevw := WID;	# golden mean, sort of

boxgen(): ref Obj
{
	h := getfval("boxht");
	w := getfval("boxwid");
	at := 0;
	battr := 0;
	with := 0;
	ddval := 0.0;
	fillval := 0.0;
	xwith := 0.0;
	ywith := 0.0;
	for(i := 0; i < nattr; i++){
		ap := attr[i];
		case ap.typ {
		HEIGHT =>
			h = ap.val.f;
		WIDTH =>
			w = ap.val.f;
		SAME =>
			h = box_prevh;
			w = box_prevw;
		WITH =>
			with = ap.val.i;	# corner
		AT =>
			ppos := ap.val.o;
			curx = ppos.x;
			cury = ppos.y;
			at++;
		INVIS =>
			battr |= INVIS;
		NOEDGE =>
			battr |= NOEDGEBIT;
		DOT or DASH =>
			if(ap.typ == DOT)
				battr |= DOTBIT;
			else
				battr |= DASHBIT;
			if(ap.sub == DEFAULT)
				ddval = getfval("dashwid");
			else
				ddval = ap.val.f;
		FILL =>
			battr |= FILLBIT;
			if(ap.sub == DEFAULT)
				fillval = getfval("fillval");
			else
				fillval = ap.val.f;
		TEXTATTR =>
			savetext(ap.sub, ap.val.p);
		}
	}
	if(with){
		case with {
		NORTH =>	ywith = -h / 2.0;
		SOUTH =>	ywith = h / 2.0;
		EAST =>	xwith = -w / 2.0;
		WEST =>	xwith = w / 2.0;
		NE =>	xwith = -w / 2.0; ywith = -h / 2.0;
		SE =>	xwith = -w / 2.0; ywith = h / 2.0;
		NW =>	xwith = w / 2.0; ywith = -h / 2.0;
		SW =>	xwith = w / 2.0; ywith = h / 2.0;
		}
		curx += xwith;
		cury += ywith;
	}
	if(!at){
		if(isright(hvmode))
			curx += w / 2.0;
		else if(isleft(hvmode))
			curx -= w / 2.0;
		else if(isup(hvmode))
			cury += h / 2.0;
		else
			cury -= h / 2.0;
	}
	x0 := curx - w / 2.0;
	y0 := cury - h / 2.0;
	x1 := curx + w / 2.0;
	y1 := cury + h / 2.0;
	extreme(x0, y0);
	extreme(x1, y1);
	p := makenode(BOX, 2);
	p.val[0] = f32(w);
	p.val[1] = f32(h);
	p.attr = battr;
	p.ddval = f32(ddval);
	p.fillval = f32(fillval);
	if(isright(hvmode))
		curx = x1;
	else if(isleft(hvmode))
		curx = x0;
	else if(isup(hvmode))
		cury = y1;
	else
		cury = y0;
	box_prevh = h;
	box_prevw = w;
	return p;
}

circ_rad := array[2] of {HT2, WID2};
circ_rad2 := array[2] of {HT2, HT2};

circgen(typ: int): ref Obj
{
	battr := 0;
	at := 0;
	with := 0;
	xwith := 0.0;
	ywith := 0.0;
	fillval := 0.0;
	ddval := 0.0;
	r, r2: real;
	t := 1;
	if(typ == CIRCLE)
		t = 0;
	if(typ == CIRCLE)
		r = r2 = getfval("circlerad");
	else if(typ == ELLIPSE){
		r = getfval("ellipsewid") / 2.0;
		r2 = getfval("ellipseht") / 2.0;
	}
	for(i := 0; i < nattr; i++){
		ap := attr[i];
		case ap.typ {
		TEXTATTR =>
			savetext(ap.sub, ap.val.p);
		RADIUS =>
			r = ap.val.f;
		DIAMETER or WIDTH =>
			r = ap.val.f / 2.0;
		HEIGHT =>
			r2 = ap.val.f / 2.0;
		SAME =>
			r = circ_rad[t];
			r2 = circ_rad2[t];
		WITH =>
			with = ap.val.i;
		AT =>
			ppos := ap.val.o;
			curx = ppos.x;
			cury = ppos.y;
			at++;
		INVIS =>
			battr |= INVIS;
		NOEDGE =>
			battr |= NOEDGEBIT;
		DOT or DASH =>
			if(ap.typ == DOT)
				battr |= DOTBIT;
			else
				battr |= DASHBIT;
			if(ap.sub == DEFAULT)
				ddval = getfval("dashwid");
			else
				ddval = ap.val.f;
		FILL =>
			battr |= FILLBIT;
			if(ap.sub == DEFAULT)
				fillval = getfval("fillval");
			else
				fillval = ap.val.f;
		}
	}
	if(typ == CIRCLE)
		r2 = r;	# probably superfluous
	if(with){
		case with {
		NORTH =>	ywith = -r2;
		SOUTH =>	ywith = r2;
		EAST =>	xwith = -r;
		WEST =>	xwith = r;
		NE =>	xwith = -r * 0.707; ywith = -r2 * 0.707;
		SE =>	xwith = -r * 0.707; ywith = r2 * 0.707;
		NW =>	xwith = r * 0.707; ywith = -r2 * 0.707;
		SW =>	xwith = r * 0.707; ywith = r2 * 0.707;
		}
		curx += xwith;
		cury += ywith;
	}
	if(!at){
		if(isright(hvmode))
			curx += r;
		else if(isleft(hvmode))
			curx -= r;
		else if(isup(hvmode))
			cury += r2;
		else
			cury -= r2;
	}
	p := makenode(typ, 2);
	p.val[0] = f32(circ_rad[t] = r);
	p.val[1] = f32(circ_rad2[t] = r2);
	if(r <= 0.0 || r2 <= 0.0){
		what := "ellipse";
		if(typ == CIRCLE)
			what = "circle";
		m := r2;
		if(r < r2)
			m = r;
		error(what + " has invalid radius " + g(m) + "\n");
	}
	p.attr = battr;
	p.ddval = f32(ddval);
	p.fillval = f32(fillval);
	extreme(curx+r, cury+r2);
	extreme(curx-r, cury-r2);
	if(isright(hvmode))
		curx += r;
	else if(isleft(hvmode))
		curx -= r;
	else if(isup(hvmode))
		cury += r2;
	else
		cury -= r2;
	return p;
}

arc_prevw := HT10;
arc_prevh := HT5;
arc_prevrad := HT2;
dtox := array[] of {array[] of {1, -1, -1, 1}, array[] of {1, 1, -1, -1}};
dtoy := array[] of {array[] of {1, 1, -1, -1}, array[] of {-1, 1, 1, -1}};
dctrx := array[] of {array[] of {0, -1, 0, 1}, array[] of {0, 1, 0, -1}};
dctry := array[] of {array[] of {1, 0, -1, 0}, array[] of {-1, 0, 1, 0}};
nexthv := array[] of {array[] of {U_DIR, L_DIR, D_DIR, R_DIR}, array[] of {D_DIR, R_DIR, U_DIR, L_DIR}};

arcgen(typ: int): ref Obj	# handles circular and (eventually) elliptical arcs
{
	fillval := 0.0;
	tox := 0.0;
	toy := 0.0;
	arc_prevrad = getfval("arcrad");
	arc_prevh = getfval("arrowht");
	arc_prevw = getfval("arrowwid");
	fromx := curx;
	fromy := cury;
	head := 0;
	tov := 0;
	at := 0;
	cw := 0;
	invis := 0;
	ddtype := 0;
	battr := 0;
	for(i := 0; i < nattr; i++){
		ap := attr[i];
		case ap.typ {
		TEXTATTR =>
			savetext(ap.sub, ap.val.p);
		HEAD =>
			head += ap.val.i;
		INVIS =>
			invis = INVIS;
		HEIGHT =>	# length of arrowhead
			arc_prevh = ap.val.f;
		WIDTH =>	# width of arrowhead
			arc_prevw = ap.val.f;
		RADIUS =>
			arc_prevrad = ap.val.f;
		DIAMETER =>
			arc_prevrad = ap.val.f / 2.0;
		CW =>
			cw = 1;
		FROM =>	# start point of arc
			ppos := ap.val.o;
			fromx = ppos.x;
			fromy = ppos.y;
		TO =>	# end point of arc
			ppos := ap.val.o;
			tox = ppos.x;
			toy = ppos.y;
			tov++;
		AT =>	# center of arc
			ppos := ap.val.o;
			curx = ppos.x;
			cury = ppos.y;
			at = 1;
		UP =>
			hvmode = U_DIR;
		DOWN =>
			hvmode = D_DIR;
		RIGHT =>
			hvmode = R_DIR;
		LEFT =>
			hvmode = L_DIR;
		FILL =>
			battr |= FILLBIT;
			if(ap.sub == DEFAULT)
				fillval = getfval("fillval");
			else
				fillval = ap.val.f;
		}
	}
	if(!at && !tov){	# the defaults are mostly OK
		curx = fromx + arc_prevrad * real dctrx[cw][hvmode];
		cury = fromy + arc_prevrad * real dctry[cw][hvmode];
		tox = fromx + arc_prevrad * real dtox[cw][hvmode];
		toy = fromy + arc_prevrad * real dtoy[cw][hvmode];
		hvmode = nexthv[cw][hvmode];
	}else if(!at){
		dx2 := (tox - fromx) / 2.0;
		dy2 := (toy - fromy) / 2.0;
		phi := math->atan2(dy2, dx2);
		if(cw)
			phi += -PI/2.0;
		else
			phi += PI/2.0;
		if(arc_prevrad <= 0.0)
			arc_prevrad = dx2*dx2+dy2*dy2;
		r := arc_prevrad;
		d: real;
		for(; (d = r*r - (dx2*dx2+dy2*dy2)) <= 0.0; r *= 2.0)
			;	# this kludge gets around too-small radii
		arc_prevrad = r;
		ht := math->sqrt(d);
		curx = fromx + dx2 + ht * math->cos(phi);
		cury = fromy + dy2 + ht * math->sin(phi);
	}else if(at && !tov){	# do we have all the cases???
		tox = fromx + arc_prevrad * real dtox[cw][hvmode];
		toy = fromy + arc_prevrad * real dtoy[cw][hvmode];
		hvmode = nexthv[cw][hvmode];
	}
	if(cw){	# interchange roles of from-to and heads
		temp := fromx; fromx = tox; tox = temp;
		temp = fromy; fromy = toy; toy = temp;
		if(head == HEAD1)
			head = HEAD2;
		else if(head == HEAD2)
			head = HEAD1;
	}
	p := makenode(typ, 7);
	arc_extreme(fromx, fromy, tox, toy, curx, cury);
	p.val[0] = f32(fromx);
	p.val[1] = f32(fromy);
	p.val[2] = f32(tox);
	p.val[3] = f32(toy);
	if(cw){
		curx = fromx;
		cury = fromy;
	}else{
		curx = tox;
		cury = toy;
	}
	p.val[4] = f32(arc_prevw);
	p.val[5] = f32(arc_prevh);
	p.val[6] = f32(arc_prevrad);
	cwbit := 0;
	if(cw)
		cwbit = CW_ARC;
	p.attr = head | cwbit | invis | ddtype | battr;
	p.fillval = f32(fillval);
	if(head)
		p.nhead = cint(getfval("arrowhead"));
	return p;
}

# bounding box of a circular arc (Eric Grosse, 24 May 84)
arc_extreme(x0: real, y0: real, x1: real, y1: real, xc: real, yc: real)	# start, end, center
{
	# assumes center isn't too far out
	x0 -= xc; y0 -= yc;	# move to center
	x1 -= xc; y1 -= yc;
	xmn, ymn, xmx, ymx: real;
	if(x0 < x1) xmn = x0; else xmn = x1;
	if(y0 < y1) ymn = y0; else ymn = y1;
	if(x0 > x1) xmx = x0; else xmx = x1;
	if(y0 > y1) ymx = y0; else ymx = y1;
	r := math->sqrt(x0*x0 + y0*y0);
	if(r > 0.0){
		j := quadrant(x0, y0);
		k := quadrant(x1, y1);
		if(j == k && (y1*x0 < x1*y0)){
			# viewed as complex numbers, if Im(z1/z0)<0, arc is big
			if(xmn > -r) xmn = -r;
			if(ymn > -r) ymn = -r;
			if(xmx < r) xmx = r;
			if(ymx < r) ymx = r;
		}else{
			while(j != k){
				case j {
				1 =>	if(ymx < r) ymx = r;	# north
				2 =>	if(xmn > -r) xmn = -r;	# west
				3 =>	if(ymn > -r) ymn = -r;	# south
				4 =>	if(xmx < r) xmx = r;	# east
				}
				j = j%4 + 1;
			}
		}
	}
	xmn += xc; ymn += yc;
	xmx += xc; ymx += yc;
	extreme(xmn, ymn);
	extreme(xmx, ymx);
}

quadrant(x: real, y: real): int
{
	if(x >= 0.0 && y > 0.0) return 1;
	else if(x < 0.0 && y >= 0.0) return 2;
	else if(x <= 0.0 && y < 0.0) return 3;
	else if(x > 0.0 && y <= 0.0) return 4;
	return 0;	# shut up lint
}

line_prevdx := HT;
line_prevdy := 0.0;
line_prevw := HT10;
line_prevh := HT5;
xtab := array[] of {1, 0, -1, 0};	# R=0, U=1, L=2, D=3
ytab := array[] of {0, 1, 0, -1};

linegen(typ: int): ref Obj
{
	dx := array[500] of {* => 0.0};
	dy := array[500] of {* => 0.0};
	chop_ap := array[4] of Attr;
	nx := curx;
	ny := cury;
	defx := getfval("linewid");
	defy := getfval("lineht");
	line_prevh = getfval("arrowht");
	line_prevw = getfval("arrowwid");
	ndxy := 0;
	some := 0;
	head := 0;
	invis := 0;
	battr := 0;
	with := 0;
	chop := 0;
	chop1 := 0.0;
	chop2 := 0.0;
	ddtype := 0;
	ddval := 0.0;
	xwith := 0.0;
	ywith := 0.0;
	fillval := 0.0;
	x0, y0, x1, y1: real;
	for(i := 0; i < nattr; i++){
		ap := attr[i];
		case ap.typ {
		TEXTATTR =>
			savetext(ap.sub, ap.val.p);
		HEAD =>
			head += ap.val.i;
		INVIS =>
			invis = INVIS;
		NOEDGE =>
			battr |= NOEDGEBIT;
		DOT or DASH =>
			if(ap.typ == DOT)
				ddtype = DOTBIT;
			else
				ddtype = DASHBIT;
			if(ap.sub == DEFAULT)
				ddval = getfval("dashwid");
			else
				ddval = ap.val.f;
		SAME =>
			dx[ndxy] = line_prevdx;
			dy[ndxy] = line_prevdy;
			some++;
		LEFT =>
			if(ap.sub == DEFAULT)
				dx[ndxy] -= defx;
			else
				dx[ndxy] -= ap.val.f;
			some++;
			hvmode = L_DIR;
		RIGHT =>
			if(ap.sub == DEFAULT)
				dx[ndxy] += defx;
			else
				dx[ndxy] += ap.val.f;
			some++;
			hvmode = R_DIR;
		UP =>
			if(ap.sub == DEFAULT)
				dy[ndxy] += defy;
			else
				dy[ndxy] += ap.val.f;
			some++;
			hvmode = U_DIR;
		DOWN =>
			if(ap.sub == DEFAULT)
				dy[ndxy] -= defy;
			else
				dy[ndxy] -= ap.val.f;
			some++;
			hvmode = D_DIR;
		HEIGHT =>	# length of arrowhead
			line_prevh = ap.val.f;
		WIDTH =>	# width of arrowhead
			line_prevw = ap.val.f;
		TO =>
			if(some){
				nx += dx[ndxy];
				ny += dy[ndxy];
				ndxy++;
				dx[ndxy] = dy[ndxy] = 0.0;
				some = 0;
			}
			ppos := attr[i].val.o;
			if(ppos == nil)
				fatal("no tag defined for `to'");
			dx[ndxy] = ppos.x - nx;
			dy[ndxy] = ppos.y - ny;
			some++;
		BY =>
			if(some){
				nx += dx[ndxy];
				ny += dy[ndxy];
				ndxy++;
				dx[ndxy] = dy[ndxy] = 0.0;
				some = 0;
			}
			ppos := ap.val.o;
			if(ppos == nil)
				fatal("no tag defined for `by'");
			dx[ndxy] = ppos.x;
			dy[ndxy] = ppos.y;
			some++;
		THEN =>	# turn off any previous accumulation
			if(some){
				nx += dx[ndxy];
				ny += dy[ndxy];
				ndxy++;
				dx[ndxy] = dy[ndxy] = 0.0;
				some = 0;
			}
		FROM or AT =>
			ppos := ap.val.o;
			if(ppos == nil)
				fatal("no tag defined for `from' or `at'");
			nx = curx = ppos.x;
			ny = cury = ppos.y;
		WITH =>
			with = ap.val.i;
		CHOP =>
			if(ap.sub != PLACENAME){
				if(chop == 0)
					chop1 = chop2 = ap.val.f;
				else
					chop2 = ap.val.f;
			}
			if(chop < len chop_ap)
				chop_ap[chop] = ap;
			chop++;
		FILL =>
			battr |= FILLBIT;
			if(ap.sub == DEFAULT)
				fillval = getfval("fillval");
			else
				fillval = ap.val.f;
		}
	}
	if(with){	# this doesn't work at all
		case with {
		CENTER =>
			xwith = (dx[1] - dx[0]) / 2.0; ywith = (dy[1] - dy[0]) / 2.0;
		}
		for(i = 0; i < ndxy; i++){
			dx[i] -= xwith;
			dy[i] -= ywith;
		}
		curx += xwith;
		cury += ywith;
	}
	if(some){
		nx += dx[ndxy];
		ny += dy[ndxy];
		ndxy++;
		defx = dx[ndxy-1];
		defy = dy[ndxy-1];
	}else{
		defx *= real xtab[hvmode];
		defy *= real ytab[hvmode];
		dx[ndxy] = defx;
		dy[ndxy] = defy;
		ndxy++;
		nx += defx;
		ny += defy;
	}
	line_prevdx = defx;
	line_prevdy = defy;
	if(chop){
		if(chop == 1 && chop1 == 0.0)	# just said "chop", so use default
			chop1 = chop2 = getfval("circlerad");
		theta := math->atan2(dy[0], dx[0]);
		x0 = chop1 * math->cos(theta);
		y0 = chop1 * math->sin(theta);
		curx += x0;
		cury += y0;
		dx[0] -= x0;
		dy[0] -= y0;
		theta = math->atan2(dy[ndxy-1], dx[ndxy-1]);
		x1 = chop2 * math->cos(theta);
		y1 = chop2 * math->sin(theta);
		nx -= x1;
		ny -= y1;
		dx[ndxy-1] -= x1;
		dy[ndxy-1] -= y1;
	}
	p := makenode(typ, 5 + 2 * ndxy);
	curx = p.val[0] = f32(nx);
	cury = p.val[1] = f32(ny);
	if(head || typ == ARROW){
		p.nhead = cint(getfval("arrowhead"));
		p.val[2] = f32(line_prevw);
		p.val[3] = f32(line_prevh);
		if(head == 0)
			head = HEAD2;	# default arrow head
	}
	p.attr = head | invis | ddtype | battr;
	p.fillval = f32(fillval);
	p.val[4] = f32(real ndxy);
	nx = p.x;
	ny = p.y;
	j := 5;
	for(i = 0; i < ndxy; i++){
		p.val[j] = f32(dx[i]);
		p.val[j+1] = f32(dy[i]);
		if(typ == LINE || typ == ARROW){
			nx += dx[i];
			ny += dy[i];
			extreme(nx, ny);
		}else if(typ == SPLINE && i < ndxy-1){
			# to compute approx extreme of spline at p,
			# compute midway between p-1 and p+1,
			# then go 3/4 from there to p
			xi := nx + dx[i]; yi := ny + dy[i];	# p
			xi1 := xi + dx[i+1]; yi1 := yi + dy[i+1];	# p+1
			ex := (nx+xi1)/2.0; ey := (ny+yi1)/2.0;	# midway
			ex += 0.75*(xi-ex); ey += 0.75*(yi-ey);
			extreme(ex, ey);
			nx = xi; ny = yi;
		}
		j += 2;
	}
	p.ddval = f32(ddval);
	extreme(p.x, p.y);
	extreme(curx, cury);
	return p;
}

move_prevdx := 0.0;
move_prevdy := 0.0;

movegen(): ref Obj
{
	defx := getfval("movewid");
	defy := getfval("moveht");
	dx := 0.0;
	dy := 0.0;
	some := 0;
	for(i := 0; i < nattr; i++){
		ap := attr[i];
		case ap.typ {
		TEXTATTR =>
			savetext(ap.sub, ap.val.p);
		SAME =>
			dx = move_prevdx;
			dy = move_prevdy;
			some++;
		LEFT =>
			if(ap.sub == DEFAULT)
				dx -= defx;
			else
				dx -= ap.val.f;
			some++;
			hvmode = L_DIR;
		RIGHT =>
			if(ap.sub == DEFAULT)
				dx += defx;
			else
				dx += ap.val.f;
			some++;
			hvmode = R_DIR;
		UP =>
			if(ap.sub == DEFAULT)
				dy += defy;
			else
				dy += ap.val.f;
			some++;
			hvmode = U_DIR;
		DOWN =>
			if(ap.sub == DEFAULT)
				dy -= defy;
			else
				dy -= ap.val.f;
			some++;
			hvmode = D_DIR;
		TO =>
			ppos := ap.val.o;
			dx = ppos.x - curx;
			dy = ppos.y - cury;
			some++;
		BY =>
			ppos := ap.val.o;
			dx = ppos.x;
			dy = ppos.y;
			some++;
		FROM or AT =>
			ppos := ap.val.o;
			curx = ppos.x;
			cury = ppos.y;
		}
	}
	if(some){
		defx = dx;
		defy = dy;
	}else{
		defx *= real xtab[hvmode];
		defy *= real ytab[hvmode];
	}
	move_prevdx = defx;
	move_prevdy = defy;
	extreme(curx, cury);
	curx += defx;
	cury += defy;
	extreme(curx, cury);
	p := makenode(MOVE, 0);
	return p;
}

text_prevh := 0.0;
text_prevw := 0.0;

textgen(): ref Obj
{
	at := 0;
	with := 0;
	nstr := 0;
	hset := 0;
	invis := 0;
	h := getfval("textht");
	w := getfval("textwid");
	for(i := 0; i < nattr; i++){
		ap := attr[i];
		case ap.typ {
		HEIGHT =>
			h = ap.val.f;
			hset++;
		WIDTH =>
			w = ap.val.f;
		WITH =>
			with = ap.val.i;
		INVIS =>
			invis = INVIS;
		AT =>
			ppos := ap.val.o;
			curx = ppos.x;
			cury = ppos.y;
			at++;
		TEXTATTR =>
			sub := ap.sub;
			if(ap.val.p == NULLP)	# an isolated modifier
				text[ntext-1].typ = sub;
			else{
				savetext(sub, ap.val.p);
				nstr++;
			}
		}
	}
	if(hset == 0)	# no explicit ht cmd
		h *= real nstr;
	if(with){
		xwith := 0.0;
		ywith := 0.0;
		case with {
		NORTH =>	ywith = -h / 2.0;
		SOUTH =>	ywith = h / 2.0;
		EAST =>	xwith = -w / 2.0;
		WEST =>	xwith = w / 2.0;
		NE =>	xwith = -w / 2.0; ywith = -h / 2.0;
		SE =>	xwith = -w / 2.0; ywith = h / 2.0;
		NW =>	xwith = w / 2.0; ywith = -h / 2.0;
		SW =>	xwith = w / 2.0; ywith = h / 2.0;
		}
		curx += xwith;
		cury += ywith;
	}
	if(!at){
		if(isright(hvmode))
			curx += w / 2.0;
		else if(isleft(hvmode))
			curx -= w / 2.0;
		else if(isup(hvmode))
			cury += h / 2.0;
		else
			cury -= h / 2.0;
	}
	x0 := curx - w / 2.0;
	y0 := cury - h / 2.0;
	x1 := curx + w / 2.0;
	y1 := cury + h / 2.0;
	extreme(x0, y0);
	extreme(x1, y1);
	p := makenode(TEXT, 2);
	p.attr = invis;
	p.val[0] = f32(w);
	p.val[1] = f32(h);
	if(isright(hvmode))
		curx = x1;
	else if(isleft(hvmode))
		curx = x0;
	else if(isup(hvmode))
		cury = y1;
	else
		cury = y0;
	text_prevh = h;
	text_prevw = w;
	return p;
}

troffgen(s: string): ref Obj	# save away a string of troff commands
{
	savetext(CENTER, s);	# use the existing text mechanism
	return makenode(TROFF, 0);
}

savetext(t: int, s: string)	# record text elements for current object
{
	if(ntext >= len text){
		a := array[len text + 200] of Txt;
		a[0:] = text;
		text = a;
	}
	text[ntext].typ = t;
	text[ntext].val = s;
	ntext++;
}

#
# dir.c: text direction
#

dir_do := 0;		# enable text direction processing

dbuf := "";		# text in the nr(R_td) direction
rbuf := "";		# text in the other direction
dir_cd := 0;		# the current direction

# append s to the end of d (dir 0) or to its start (dir 1)
dir_copy(d: string, s: string, dir: int): string
{
	if(dir > 0)
		return s + d;
	return d + s;
}

# copy rbuf (the text in the reverse direction) to dbuf
dir_flush()
{
	dbuf = dir_copy(dbuf, rbuf, nr(R_td));
	rbuf = "";
}

# append s to dbuf or rbuf according to the current text direction
dir_append(s: string)
{
	dir := dir_cd > 0;
	if(dir == nr(R_td) && rbuf != nil)
		dir_flush();
	if(dir == nr(R_td))
		dbuf = dir_copy(dbuf, s, dir);
	else
		rbuf = dir_copy(rbuf, s, dir);
}

setfont(f: int)
{
	if(f >= 0)
		dir_append(sys->sprint("%sf(%.2d", ecs(), f));
}

setsize(s: int)
{
	if(s < 0)
		return;
	if(s <= 99)
		dir_append(sys->sprint("%ss(%.2d", ecs(), s));
	else
		dir_append(sys->sprint("%ss[%d]", ecs(), s));
}

setcolor(m: int)
{
	if(m >= 0)
		dir_append(sys->sprint("%sm[%s]", ecs(), clr_str(m)));
}

dir_fix(src: string): string
{
	prev := 0;
	f := -1;
	s := -1;
	m := -1;
	dir_cd = nr(R_td);
	i := 0;
	for(;;){
		(t, c, ni) := escread(src, i);
		if(t < 0)
			break;
		i = ni;
		case t {
		0 or 'D' or 'h' or 'v' or 'x' =>
			dir_append(src[prev:i]);
		'f' =>
			n := atoi(c);
			if(f != n){
				setfont(f);
				f = n;
				setfont(f);
			}
		'm' =>
			n := clr_get(c);
			if(m != n){
				setcolor(m);
				m = n;
				setcolor(m);
			}
		's' =>
			n := atoi(c);
			if(s != n){
				setsize(s);
				s = n;
				setsize(s);
			}
		'X' =>
			dir_append(ecs() + "X\u0003" + c + "\u0003");	# quoted with \003, as Neatroff
		'<' or '>' =>
			setcolor(m);
			setfont(f);
			setsize(s);
			dir_cd = t == '<';
			setsize(s);
			setfont(f);
			setcolor(m);
		}
		prev = i;
	}
	setcolor(m);
	setfont(f);
	setsize(s);
	dir_flush();
	r := dbuf;
	dbuf = "";
	return r;
}

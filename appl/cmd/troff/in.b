#
# in.c: the input layer
#

Inbuf: adt {
	path:	string;		# for file buffers
	fin:	ref Iobuf;
	isfile:	int;
	buf:	string;		# for string buffers
	args:	array of string;	# macro arguments
	hasargs:	int;
	unbuf:	array of int;	# unread characters
	un:	int;
	pos:	int;
	chr:	int;		# the last character read from fin
	lnum:	int;		# file line number
	prev:	cyclic ref Inbuf;
};

buf: ref Inbuf;
files := array[NFILES] of string;
nfiles := 0;
cfile := 0;

in_new()
{
	next := ref Inbuf;
	next.unbuf = array[32] of {* => 0};
	next.prev = buf;
	buf = next;
}

in_push(s: string, args: array of string)
{
	in_new();
	buf.buf = s;
	if(args != nil){
		buf.args = args_init(args);
		buf.hasargs = 1;
	}
}

# like in_push(), with an empty argument list (Neatroff's non-NULL args)
in_pushargs(s: string, args: array of string)
{
	in_new();
	buf.buf = s;
	buf.args = args_init(args);
	buf.hasargs = 1;
}

in_so(path: string)
{
	fin: ref Iobuf;
	if(path != nil)
		fin = bufio->open(path, Bufio->OREAD);
	else
		fin = bufio->fopen(sys->fildes(0), Bufio->OREAD);
	if(fin == nil){
		errmsg(sys->sprint("troff: failed to open <%s>\n", path));
		return;
	}
	in_new();
	buf.fin = fin;
	buf.isfile = 1;
	buf.lnum = 1;
	buf.path = path;
}

in_lf(path: string, lnum: int)
{
	cur := buf;
	while(cur != nil && !cur.isfile)
		cur = cur.prev;
	if(cur == nil)
		return;
	if(path != nil)
		cur.path = path;
	cur.lnum = lnum - 1;
}

in_queue(path: string)
{
	if(nfiles < NFILES)
		files[nfiles++] = path;
}

in_pop()
{
	old := buf;
	buf = buf.prev;
	if(old.fin != nil)
		old.fin.close();
}

in_nx(path: string)
{
	while(buf != nil)
		in_pop();
	if(path != nil)
		in_so(path);
}

in_ex()
{
	while(buf != nil)
		in_pop();
	cfile = nfiles;
}

in_nextfile(): int
{
	while(buf == nil && cfile < nfiles)
		in_so(files[cfile++]);
	return buf == nil;
}

in_next(): int
{
	while(buf != nil || !in_nextfile()){
		if(buf.un)
			return buf.unbuf[--buf.un];
		if(!buf.isfile && buf.pos < len buf.buf)
			break;
		if(buf.isfile){
			c := buf.fin.getc();
			if(c >= 0){
				if(buf.chr == '\n')
					buf.lnum++;
				buf.chr = c;
				return c;
			}
		}
		in_pop();
	}
	if(buf != nil)
		return buf.buf[buf.pos++];
	return -1;
}

in_back(c: int)
{
	if(c < 0)
		return;
	if(buf != nil && buf.un < len buf.unbuf)
		buf.unbuf[buf.un++] = c;
}

in_top(): int
{
	if(buf != nil && buf.un)
		return buf.unbuf[buf.un - 1];
	return -1;
}

in_arg(i: int): string
{
	cur := buf;
	while(cur != nil && !cur.hasargs)
		cur = cur.prev;
	if(cur != nil && i < NARGS && i < len cur.args)
		return cur.args[i];
	return "";
}

in_nargs(): int
{
	cur := buf;
	while(cur != nil && !cur.hasargs)
		cur = cur.prev;
	if(cur != nil)
		return len cur.args;
	return 0;
}

in_shift()
{
	cur := buf;
	while(cur != nil && !cur.hasargs)
		cur = cur.prev;
	if(cur != nil && len cur.args > 1){
		a := array[len cur.args - 1] of string;
		a[0] = cur.args[0];
		a[1:] = cur.args[2:];
		cur.args = a;
	}
}

in_filename(): string
{
	cur := buf;
	while(cur != nil && !cur.isfile)
		cur = cur.prev;
	if(cur != nil && cur.path != nil)
		return cur.path;
	return "-";
}

in_lnum(): int
{
	cur := buf;
	while(cur != nil && !cur.isfile)
		cur = cur.prev;
	if(cur != nil)
		return cur.lnum;
	return 0;
}

args_init(args: array of string): array of string
{
	n := len args;
	if(n > NARGS)
		n = NARGS;
	out := array[n] of string;
	out[0:] = args[0:n];
	return out;
}

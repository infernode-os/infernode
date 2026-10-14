#
# pdfext.c: a PDF's first page included as an XObject (x X pdf)
#

# a byte of the PDF, NUL past its end as in Neatpost's buffer
at(p: array of byte, i: int): int
{
	if(i >= 0 && i < len p)
		return int p[i];
	return 0;
}

pdf_ws(p: array of byte, pos: int): int
{
	i := pos;
	while(i < len p && isspace(int p[i]))
		i++;
	return i - pos;
}

isnumc(c: int): int
{
	return c != 0 && strchr("0123456789+-.", c) >= 0;
}

# s: string, d: dictionary, l: list, n: number, /: name, r: reference
pdf_type(p: array of byte, pos: int): int
{
	pos += pdf_ws(p, pos);
	c := at(p, pos);
	if(c == '/')
		return '/';
	if(c == '(')
		return 's';
	if(c == '<' && at(p, pos + 1) != '<')
		return 's';
	if(c == '<' && at(p, pos + 1) == '<')
		return 'd';
	if(c == '[')
		return 'l';
	if(isnumc(c)){
		if(!isdigit(c))
			return 'n';
		while(pos < len p && isdigit(int p[pos]))
			pos++;
		pos += pdf_ws(p, pos);
		if(!isdigit(at(p, pos)))
			return 'n';
		while(pos < len p && isdigit(int p[pos]))
			pos++;
		pos += pdf_ws(p, pos);
		if(pos < len p && p[pos] == byte 'R')
			return 'r';
		return 'n';
	}
	return -1;
}

# the length of an object
pdf_len(p: array of byte, pos: int): int
{
	old := pos;
	if(pos >= len p)
		return 0;
	pos += pdf_ws(p, pos);
	c := at(p, pos);
	if(isnumc(c)){
		if(pdf_type(p, pos) == 'r'){
			for(r := pos; r < len p; r++)
				if(p[r] == byte 'R')
					return r - old + 1;
		}
		pos++;
		while(pos < len p && strchr("0123456789.", int p[pos]) >= 0)
			pos++;
	}
	if(c == '('){
		depth := 1;
		pos++;
		while(pos < len p && depth > 0){
			if(p[pos] == byte '(')
				depth++;
			if(p[pos] == byte ')')
				depth--;
			if(p[pos] == byte '\\')
				pos++;
			pos++;
		}
	}
	if(c == '<' && pos + 1 < len p && p[pos + 1] == byte '<'){
		pos += 2;
		while(pos + 2 < len p && (p[pos] != byte '>' || p[pos + 1] != byte '>')){
			pos += pdf_len(p, pos);
			pos += pdf_len(p, pos);
			pos += pdf_ws(p, pos);
		}
		if(pos + 2 < len p)
			pos += 2;
	}else if(c == '<'){
		while(pos < len p && p[pos] != byte '>')
			pos++;
		if(pos < len p)
			pos++;
	}
	if(c == '/'){
		pos++;
		while(pos < len p && strchr(" \t\r\n\f()<>[]{}/%", int p[pos]) < 0 && p[pos] != byte 0)
			pos++;
	}
	if(c == '['){
		pos++;
		while(pos < len p && p[pos] != byte ']'){
			pos += pdf_len(p, pos);
			pos += pdf_ws(p, pos);
		}
		pos++;
	}
	# a keyword (true, false, null), which Neatpost takes as nothing
	# and loops on for ever
	start := old + pdf_ws(p, old);
	if(pos == start)
		while(pos < len p && !isspace(int p[pos]) && strchr("()<>[]{}/%", int p[pos]) < 0)
			pos++;
	if(pos == start && pos < len p)
		pos++;
	return pos - old;
}

startswith(p: array of byte, pos: int, t: string): int
{
	for(i := 0; i < len t; i++)
		if(at(p, pos + i) != t[i])
			return at(p, pos + i) == 0;
	return 1;
}

# C's atoi of the bytes at pos
patoi(p: array of byte, pos: int): int
{
	e := pos;
	while(e < len p && e - pos < 32 && (isspace(int p[e]) || isdigit(int p[e]) || p[e] == byte '-' || p[e] == byte '+'))
		e++;
	return atoi(string p[pos:e]);
}

# an indirect reference: its object and revision
pdf_obj(p: array of byte, pos: int): (int, int, int)
{
	if(pdf_type(p, pos) != 'r')
		return (-1, 0, 0);
	# the revision is the second number (Neatpost reads the number
	# after the R, the next reference's in [3 0 R 4 0 R])
	pos += pdf_ws(p, pos);
	obj := patoi(p, pos);
	while(pos < len p && isdigit(int p[pos]))
		pos++;
	return (0, obj, patoi(p, pos));
}

# where a dictionary key's value is
pdf_dval(p: array of byte, pos: int, key: string): int
{
	pos += 2;
	while(pos + 2 < len p && (p[pos] != byte '>' || p[pos + 1] != byte '>')){
		pos += pdf_ws(p, pos);
		if(pdf_len(p, pos) == len key && startswith(p, pos, key)){
			pos += pdf_len(p, pos);
			pos += pdf_ws(p, pos);
			return pos;
		}
		pos += pdf_len(p, pos);
		pos += pdf_len(p, pos);
		pos += pdf_ws(p, pos);
	}
	return -1;
}

# where a dictionary's key-th key is
pdf_dkey(p: array of byte, pos: int, key: int): int
{
	i := 0;
	pos += 2;
	while(pos + 2 < len p && (p[pos] != byte '>' || p[pos + 1] != byte '>')){
		pos += pdf_ws(p, pos);
		if(i++ == key)
			return pos;
		pos += pdf_len(p, pos);
		pos += pdf_len(p, pos);
		pos += pdf_ws(p, pos);
	}
	return -1;
}

# where a list's idx-th entry is
pdf_lval(p: array of byte, pos: int, idx: int): int
{
	i := 0;
	pos++;
	while(pos < len p && p[pos] != byte ']'){
		if(i++ == idx)
			return pos;
		pos += pdf_len(p, pos);
		pos += pdf_ws(p, pos);
	}
	return -1;
}

memrchr(p: array of byte, c: int, n: int): int
{
	for(i := n - 1; i >= 0; i--)
		if(int p[i] == c)
			return i;
	return -1;
}

prevline(p: array of byte, off: int): int
{
	nl := memrchr(p, '\n', off);
	if(nl > 0){
		nl2 := memrchr(p, '\n', nl - 1);
		if(nl2 >= 0)
			return nl2 + 1;
	}
	return -1;
}

nextline(p: array of byte, off: int): int
{
	for(i := off; i < len p; i++)
		if(p[i] == byte '\n')
			return i + 1;
	return -1;
}

pdf_trailer(p: array of byte): int
{
	pos := prevline(p, len p);	# %%EOF
	while(pos < 0 || !startswith(p, pos, "trailer"))
		if(pos < 0 || (pos = prevline(p, pos)) < 0)
			return -1;
	return nextline(p, pos);
}

pdf_xref(p: array of byte): int
{
	pos := prevline(p, len p);
	if(pos < 0 || (pos = prevline(p, pos)) < 0)
		return -1;
	v := scanints(string p[pos:min(pos + 32, len p)], 1);
	if(len v != 1 || v[0] >= len p || v[0] < 0)
		return -1;
	return nextline(p, v[0]);
}

min(a, b: int): int
{
	if(a < b)
		return a;
	return b;
}

# where an object's value is
pdf_find(p: array of byte, obj, rev: int): int
{
	pos := pdf_xref(p);
	if(pos < 0)
		return -1;
	for(;;){
		if(pos >= len p)
			return -1;
		v := scanints(string p[pos:min(pos + 64, len p)], 2);
		if(len v != 2)
			return -1;
		(obj_beg, obj_cnt) := (v[0], v[1]);
		for(i := 0; i < obj_cnt; i++){
			if((pos = nextline(p, pos)) < 0)
				return -1;
			e := scanints(string p[pos:min(pos + 64, len p)], 2);
			if(len e != 2)
				return -1;
			(cur_pos, cur_rev) := (e[0], e[1]);
			if(obj_beg + i == obj && cur_rev == rev){
				if(cur_pos < 0 || cur_pos >= len p)
					return -1;
				# strstr: to the first NUL
				for(k := cur_pos; k + 3 <= len p && p[k] != byte 0; k++)
					if(p[k] == byte 'o' && p[k + 1] == byte 'b' && p[k + 2] == byte 'j'){
						pos = k + 3;
						return pos + pdf_ws(p, pos);
					}
				return -1;
			}
		}
		# the next subsection (Neatpost reads this one's last entry
		# as one, for ever)
		if((pos = nextline(p, pos)) < 0)
			return -1;
	}
}

pdf_ref(p: array of byte, pos: int): int
{
	(e, obj, rev) := pdf_obj(p, pos);
	if(e)
		return -1;
	return pdf_find(p, obj, rev);
}

pdf_dval_val(p: array of byte, pos: int, key: string): int
{
	val := pdf_dval(p, pos, key);
	if(val < 0)
		return -1;
	if(pdf_type(p, val) == 'r'){
		(nil, obj, rev) := pdf_obj(p, val);
		return pdf_find(p, obj, rev);
	}
	return val;
}

pdf_dval_obj(p: array of byte, pos: int, key: string): int
{
	val := pdf_dval(p, pos, key);
	if(val < 0)
		return -1;
	return pdf_ref(p, val);
}

# a copy of an object, at most 4095 bytes
pdf_copy(p: array of byte, pos: int): string
{
	pos += pdf_ws(p, pos);
	n := pdf_len(p, pos);
	if(n > 4095)
		n = 4095;
	return cstring(p[pos:min(pos + n, len p)]);
}

cstring(b: array of byte): string
{
	for(i := 0; i < len b; i++)
		if(b[i] == byte 0)
			return string b[0:i];
	return string b;
}

# a stream, to buf
pdf_strcopy(p: array of byte, pos: int, sb: ref Bytes): int
{
	val := pdf_dval_val(p, pos, "/Length");
	if(val < 0)
		return -1;
	slen := patoi(p, val);
	pos = pos + pdf_len(p, pos);
	pos += pdf_ws(p, pos);
	if(pos + slen + 15 > len p)
		return -1;
	beg := pos;
	pos += len "stream";
	if(at(p, pos) == '\r')
		pos++;
	pos += 1 + slen;
	if(at(p, pos) == '\r' || at(p, pos) == ' ')
		pos++;
	if(at(p, pos) == '\n')
		pos++;
	pos += len "endstream" + 1;
	sb.mem(p[beg:min(pos, len p)]);
	return 0;
}

copied: list of (int, int);	# objects copied: where, and their new identifiers

# an object copied; its new identifier
pdf_objcopy(p: array of byte, pos: int): int
{
	if((pos = pdf_ref(p, pos)) < 0)
		return -1;
	id := 0;
	if(!compat){
		# once each, so that a cycle of references ends
		for(l := copied; l != nil; l = tl l)
			if((hd l).t0 == pos)
				return (hd l).t1;
		id = obj_map();
		copied = (pos, id) :: copied;
	}
	if(pdf_type(p, pos) == 'd'){
		sb := ref Bytes(array[1024] of byte, 0);
		pdf_dictcopy(p, pos, sb);
		sb.str("\n");
		if(pdf_dval(p, pos, "/Length") >= 0)
			pdf_strcopy(p, pos, sb);
		id = obj_beg(id);
		pdfmem(sb.b[0:sb.n]);
		obj_end();
	}else{
		id = obj_beg(id);
		pdfmem(p[pos:min(pos + pdf_len(p, pos), len p)]);
		pdfout("\n");
		obj_end();
	}
	return id;
}

pdf_dictcopy(p: array of byte, pos: int, sb: ref Bytes)
{
	sb.str("<<");
	for(i := 0; ; i++){
		key := pdf_dkey(p, pos, i);
		if(key < 0)
			break;
		k := pdf_copy(p, key);
		sb.str(" " + k);
		val := pdf_dval(p, pos, k);
		if(pdf_type(p, val) == 'r'){
			if((id := pdf_objcopy(p, val)) >= 0)
				sb.str(" " + string id + " 0 R");
		}else
			sb.str(" " + pdf_copy(p, val));
	}
	sb.str(" >>");
}

pdf_rescopy(p: array of byte, pos: int, sb: ref Bytes)
{
	fields := array[] of {"/ProcSet", "/ExtGState", "/ColorSpace",
		"/Pattern", "/Shading", "/Properties", "/Font", "/XObject"};
	sb.str("  /Resources <<\n");
	for(i := 0; i < len fields; i++){
		if((res := pdf_dval_val(p, pos, fields[i])) >= 0){
			if(pdf_type(p, res) == 'd'){
				sb.str("    " + fields[i] + " ");
				pdf_dictcopy(p, res, sb);
				sb.str("\n");
			}else
				sb.str("    " + fields[i] + " " + pdf_copy(p, res) + "\n");
		}
	}
	sb.str("  >>\n");
}

pdfbbox100(p: array of byte, pos: int): (int, array of int)
{
	dim := array[4] of int;
	for(i := 0; i < 4; i++){
		n := 0;
		f1 := 0;
		f2 := 0;
		val := pdf_lval(p, pos, i);
		if(val < 0)
			return (-1, dim);
		for(; isdigit(at(p, val)); val++)
			n = n * 10 + at(p, val) - '0';
		if(at(p, val) == '.' && isdigit(at(p, val + 1))){
			f1 = at(p, val + 1) - '0';
			if(isdigit(at(p, val + 2)))
				f2 = at(p, val + 2) - '0';
		}
		dim[i] = n * 100 + f1 * 10 + f2;
	}
	return (0, dim);
}

# the PDF's first page as an XObject; its index in xobj
pdfext(p: array of byte, hwid, vwid: int): int
{
	if(xobj_n == len xobj)
		return -1;
	copied = nil;
	{
		trailer := pdf_trailer(p);
		if(trailer < 0)
			return -1;
		root := pdf_dval_obj(p, trailer, "/Root");
		if(root < 0)
			return -1;
		pages := pdf_dval_obj(p, root, "/Pages");
		if(pages < 0)
			return -1;
		kids_val := pdf_dval_val(p, pages, "/Kids");
		if(kids_val < 0)
			return -1;
		page1_val := pdf_lval(p, kids_val, 0);
		if(page1_val < 0)
			return -1;
		page1 := pdf_ref(p, page1_val);
		if(page1 < 0)
			return -1;
		cont := pdf_dval_obj(p, page1, "/Contents");
		if(cont < 0)
			return -1;
		val := pdf_dval_val(p, cont, "/Length");
		if(val < 0)
			return -1;
		res := pdf_dval_val(p, page1, "/Resources");
		length := patoi(p, val);
		bbox := pdf_dval_val(p, page1, "/MediaBox");
		if(bbox < 0)
			bbox = pdf_dval_val(p, pages, "/MediaBox");
		hzoom := 100;
		vzoom := 100;
		if(bbox >= 0){
			(e, dim) := pdfbbox100(p, bbox);
			if(!e){
				if(hwid > 0)
					hzoom = int (big hwid * big (100 * 7200 / devres()) / big (dim[2] - dim[0]));
				if(vwid > 0)
					vzoom = int (big vwid * big (100 * 7200 / devres()) / big (dim[3] - dim[1]));
				if(vwid <= 0)
					vzoom = hzoom;
				if(hwid <= 0)
					hzoom = vzoom;
			}
		}
		sb := ref Bytes(array[4096] of byte, 0);
		sb.str("<<\n  /Type /XObject\n  /Subtype /Form\n  /FormType 1\n");
		if(bbox >= 0)
			sb.str("  /BBox " + pdf_copy(p, bbox) + "\n");
		sb.str(sys->sprint("  /Matrix [%d.%02d 0 0 %d.%02d %s]\n",
			hzoom / 100, hzoom % 100, vzoom / 100, vzoom % 100, pdfpos(o_h, o_v)));
		if(res >= 0)
			pdf_rescopy(p, res, sb);
		sb.str("  /Length " + string length + "\n");
		cf := array[] of {"/Filter", "/DecodeParms"};
		for(i := 0; i < len cf; i++)
			if((val = pdf_dval_val(p, cont, cf[i])) >= 0)
				sb.str("  " + cf[i] + " " + pdf_copy(p, val) + "\n");
		sb.str(">>\n");
		pdf_strcopy(p, cont, sb);
		xobj_id := obj_beg(0);
		pdfmem(sb.b[0:sb.n]);
		obj_end();
		xobj[xobj_n++] = xobj_id;
		return xobj_n - 1;
	} exception {
	"array bounds error" =>
		return -1;
	}
}

# a growing buffer of bytes
Bytes: adt {
	b:	array of byte;
	n:	int;

	mem:	fn(s: self ref Bytes, b: array of byte);
	str:	fn(s: self ref Bytes, t: string);
};

Bytes.mem(s: self ref Bytes, b: array of byte)
{
	if(s.n + len b > len s.b){
		nb := array[2 * (s.n + len b)] of byte;
		nb[0:] = s.b[0:s.n];
		s.b = nb;
	}
	s.b[s.n:] = b;
	s.n += len b;
}

Bytes.str(s: self ref Bytes, t: string)
{
	s.mem(array of byte t);
}

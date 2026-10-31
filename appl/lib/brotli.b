implement Brotli;

#
# Brotli decompression (RFC 7932), for WOFF2 fonts and
# Content-Encoding: br.
#
# The output is one array; back references reach into it directly, so
# there is no separate ring buffer.  Prefix codes decode through a table
# of the first TBITS bits, then bit by bit for longer codes.
#

include "sys.m";
	sys: Sys;
include "brotli.m";

include "brotli.tab";

Xform: adt {
	prefix:	string;
	kind:	int;
	suffix:	string;
};

# transform kinds
Xid, Xomitlast9: con iota;	# 1..9: omit the last n
Xupfirst: con 10;
Xupall: con 11;			# 12..20: omit the first n-11

dict: array of byte;
dictoff := array[25] of int;
ndbits := array[] of {0, 0, 0, 0, 10, 10, 11, 11, 10, 10, 10, 10, 10, 9, 9, 8, 7, 7, 8, 7, 7, 6, 6, 5, 5};

insbase := array[] of {0, 1, 2, 3, 4, 5, 6, 8, 10, 14, 18, 26, 34, 50, 66, 98, 130, 194, 322, 578, 1090, 2114, 6210, 22594};
insextra := array[] of {0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24};
copybase := array[] of {2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 18, 22, 30, 38, 54, 70, 102, 134, 198, 326, 582, 1094, 2118};
copyextra := array[] of {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24};
insrange := array[] of {0, 0, 8, 8, 0, 16, 8, 16, 16};
copyrange := array[] of {0, 8, 0, 8, 16, 0, 16, 8, 16};
blbase := array[] of {1, 5, 9, 13, 17, 25, 33, 41, 49, 65, 81, 97, 113, 145, 177, 209, 241, 305, 369, 497, 753, 1265, 2289, 4337, 8433, 16625};
blextra := array[] of {2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 7, 8, 9, 10, 11, 12, 13, 24};
clorder := array[] of {1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15};

Bad: con "brotli: corrupt data";

# ---- bits, least significant first ----

Br: adt {
	d:	array of byte;
	pos:	int;		# next byte
	acc:	int;		# bits not yet used
	n:	int;		# how many

	bits:	fn(b: self ref Br, k: int): int;
	peek:	fn(b: self ref Br, k: int): int;
	skip:	fn(b: self ref Br, k: int);
	align:	fn(b: self ref Br);
};

Br.peek(b: self ref Br, k: int): int
{
	while(b.n < k) {
		c := 0;
		if(b.pos < len b.d)
			c = int b.d[b.pos];
		else if(b.pos > len b.d + 8)
			raise Bad;	# well past the end: corrupt
		b.pos++;
		b.acc |= c << b.n;
		b.n += 8;
	}
	return b.acc & ((1 << k) - 1);
}

Br.skip(b: self ref Br, k: int)
{
	b.acc >>= k;
	b.n -= k;
}

Br.bits(b: self ref Br, k: int): int
{
	if(k == 0)
		return 0;
	if(k > 16)
		return b.bits(16) | (b.bits(k - 16) << 16);
	v := b.peek(k);
	b.skip(k);
	return v;
}

Br.align(b: self ref Br)
{
	b.skip(b.n & 7);
}

# ---- prefix codes ----

TBITS: con 8;

Code: adt {
	tab:	array of int;	# by the next TBITS bits: sym<<4 | len, or -1
	single:	int;		# a one-symbol code (no bits), else -1
	# canonical decoding for longer codes
	first:	array of int;	# first code of each length
	count:	array of int;
	index:	array of int;	# into syms, of each length's first
	syms:	array of int;
	maxlen:	int;
};

reverse(c, n: int): int
{
	r := 0;
	for(i := 0; i < n; i++) {
		r = (r << 1) | (c & 1);
		c >>= 1;
	}
	return r;
}

mkcode(lens: array of int): ref Code
{
	n := len lens;
	nz := 0;
	last := 0;
	maxlen := 0;
	for(i := 0; i < n; i++)
		if(lens[i] > 0) {
			nz++;
			last = i;
			if(lens[i] > maxlen)
				maxlen = lens[i];
		}
	c := ref Code(nil, -1, nil, nil, nil, nil, maxlen);
	if(nz <= 1) {
		c.single = last;
		return c;
	}
	c.count = array[maxlen + 1] of {* => 0};
	for(i = 0; i < n; i++)
		c.count[lens[i]]++;
	c.count[0] = 0;
	c.first = array[maxlen + 2] of {* => 0};
	c.index = array[maxlen + 2] of {* => 0};
	code := 0;
	idx := 0;
	for(l := 1; l <= maxlen; l++) {
		code = (code + c.count[l-1]) << 1;	# deflate's canonical codes
		c.first[l] = code;
		c.index[l] = idx;
		idx += c.count[l];
	}
	c.syms = array[idx] of int;
	fill := array[maxlen + 1] of {* => 0};
	for(i = 0; i < n; i++)
		if((l = lens[i]) > 0)
			c.syms[c.index[l] + fill[l]++] = i;
	c.tab = array[1 << TBITS] of {* => -1};
	for(l = 1; l <= maxlen && l <= TBITS; l++)
		for(k := 0; k < c.count[l]; k++) {
			r := reverse(c.first[l] + k, l);
			s := c.syms[c.index[l] + k];
			for(j := r; j < (1 << TBITS); j += 1 << l)
				c.tab[j] = (s << 4) | l;
		}
	return c;
}

sym(b: ref Br, c: ref Code): int
{
	if(c.single >= 0)
		return c.single;
	e := c.tab[b.peek(TBITS)];
	if(e >= 0) {
		b.skip(e & 15);
		return e >> 4;
	}
	# longer than TBITS: canonical, one bit at a time
	code := 0;
	for(l := 1; l <= c.maxlen; l++) {
		code = (code << 1) | b.bits(1);
		k := code - c.first[l];
		if(k >= 0 && k < c.count[l])
			return c.syms[c.index[l] + k];
	}
	raise Bad;
}

# one prefix code over an alphabet of nsym (§3.4, §3.5)
readcode(b: ref Br, nsym: int): ref Code
{
	lens := array[nsym] of {* => 0};
	hskip := b.bits(2);
	if(hskip == 1) {
		# simple
		abits := 0;
		while((1 << abits) < nsym)
			abits++;
		ns := b.bits(2) + 1;
		s := array[ns] of int;
		for(i := 0; i < ns; i++) {
			s[i] = b.bits(abits);
			if(s[i] >= nsym)
				raise Bad;
			for(j := 0; j < i; j++)
				if(s[j] == s[i])
					raise Bad;
		}
		case ns {
		1 =>
			return ref Code(nil, s[0], nil, nil, nil, nil, 0);
		2 =>
			lens[s[0]] = lens[s[1]] = 1;
		3 =>
			lens[s[0]] = 1;
			lens[s[1]] = lens[s[2]] = 2;
		4 =>
			if(b.bits(1) == 0)
				lens[s[0]] = lens[s[1]] = lens[s[2]] = lens[s[3]] = 2;
			else {
				lens[s[0]] = 1;
				lens[s[1]] = 2;
				lens[s[2]] = lens[s[3]] = 3;
			}
		}
		return mkcode(lens);
	}
	# complex: first the code lengths' code
	cll := array[18] of {* => 0};
	space := 32;
	nz := 0;
	for(i := hskip; i < 18 && space > 0; i++) {
		# the fixed code for code length code lengths
		v := b.peek(4);
		l, x: int;
		case v & 3 {
		0 => (l, x) = (2, 0);
		1 => (l, x) = (2, 4);
		2 => (l, x) = (2, 3);
		* =>
			if(v & 4) {
				if(v & 8)
					(l, x) = (4, 5);
				else
					(l, x) = (4, 1);
			} else
				(l, x) = (3, 2);
		}
		b.skip(l);
		cll[clorder[i]] = x;
		if(x != 0) {
			space -= 32 >> x;
			nz++;
		}
	}
	if(nz != 1 && space != 0)
		raise Bad;
	clc := mkcode(cll);
	prev := 8;
	rep := 0;
	repsym := 0;	# 16 or 17: what the last run was
	space = 1 << 15;
	for(i = 0; i < nsym && space > 0; ) {
		s := sym(b, clc);
		if(s < 16) {
			lens[i++] = s;
			rep = 0;
			if(s != 0) {
				prev = s;
				space -= (1 << 15) >> s;
			}
			continue;
		}
		# 16: repeat the last non-zero length; 17: zeros.  A run that
		# follows a run of the same kind extends it (§3.5).
		ebits := 2;
		val := prev;
		if(s == 17) {
			ebits = 3;
			val = 0;
		}
		if(repsym != s)
			rep = 0;
		old := rep;
		if(rep > 0)
			rep = (rep - 2) << ebits;
		rep += b.bits(ebits) + 3;
		n := rep - old;
		if(i + n > nsym)
			raise Bad;
		for(k := 0; k < n; k++) {
			lens[i++] = val;
			if(val != 0)
				space -= (1 << 15) >> val;
		}
		repsym = s;
	}
	if(space != 0)
		raise Bad;
	return mkcode(lens);
}

# 1-256 coded as in §9.2 (NBLTYPES, NTREES)
varnum(b: ref Br): int
{
	if(b.bits(1) == 0)
		return 1;
	n := b.bits(3);
	if(n == 0)
		return 2;
	return (1 << n) + b.bits(n) + 1;
}

blocklen(b: ref Br, c: ref Code): int
{
	s := sym(b, c);
	return blbase[s] + b.bits(blextra[s]);
}

# a context map (§7.3)
readmap(b: ref Br, size, ntrees: int): array of byte
{
	m := array[size] of {* => byte 0};
	if(ntrees < 2)
		return m;
	rlemax := 0;
	if(b.bits(1))
		rlemax = b.bits(4) + 1;
	c := readcode(b, ntrees + rlemax);
	for(i := 0; i < size; ) {
		s := sym(b, c);
		if(s == 0)
			m[i++] = byte 0;
		else if(s <= rlemax) {
			n := (1 << s) + b.bits(s);
			if(i + n > size)
				raise Bad;
			for(; n > 0; n--)
				m[i++] = byte 0;
		} else
			m[i++] = byte (s - rlemax);
	}
	if(b.bits(1)) {
		# inverse move-to-front
		mtf := array[256] of int;
		for(i = 0; i < 256; i++)
			mtf[i] = i;
		for(i = 0; i < size; i++) {
			k := int m[i];
			v := mtf[k];
			m[i] = byte v;
			for(; k > 0; k--)
				mtf[k] = mtf[k-1];
			mtf[0] = v;
		}
	}
	return m;
}

# block switching for one category (§6)
Blk: adt {
	n:	int;		# NBLTYPES
	types:	ref Code;
	counts:	ref Code;
	cur, last:	int;	# current and previous type
	left:	int;		# commands or symbols left in this block
};

readblk(b: ref Br): ref Blk
{
	k := ref Blk(varnum(b), nil, nil, 0, 1, 1 << 24);
	if(k.n >= 2) {
		k.types = readcode(b, k.n + 2);
		k.counts = readcode(b, 26);
		k.left = blocklen(b, k.counts);
	}
	return k;
}

switchblk(b: ref Br, k: ref Blk)
{
	s := sym(b, k.types);
	t: int;
	case s {
	0 =>	t = k.last;
	1 =>	t = k.cur + 1;
	* =>	t = s - 2;
	}
	if(t >= k.n)
		t -= k.n;
	k.last = k.cur;
	k.cur = t;
	k.left = blocklen(b, k.counts);
}

# ---- the stream ----

Out: adt {
	d:	array of byte;
	n:	int;
	max:	int;		# a known final size, else -1
};

put(o: ref Out, c: int)
{
	if(o.n >= len o.d)
		grow(o, 1);
	o.d[o.n++] = byte c;
}

grow(o: ref Out, k: int)
{
	if(o.max >= 0 && o.n + k > o.max)
		raise Bad;
	nl := 2 * len o.d;
	if(nl < o.n + k)
		nl = o.n + k + 1024;
	if(o.max >= 0 && nl > o.max)
		nl = o.max;
	nd := array[nl] of byte;
	nd[0:] = o.d[0:o.n];
	o.d = nd;
}

decompress(data: array of byte, size: int): (array of byte, string)
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	{
		return (inflate(data, size), nil);
	} exception e {
	"brotli:*" =>
		return (nil, e);
	"out of memory*" or "array bounds*" =>
		return (nil, Bad);
	}
}

loaddict(): string
{
	if(dict != nil)
		return nil;
	fd := sys->open(DICT, Sys->OREAD);
	if(fd == nil)
		return sys->sprint("brotli: %s: %r", DICT);
	d := array[122784] of byte;
	n := 0;
	while(n < len d && (k := sys->read(fd, d[n:], len d - n)) > 0)
		n += k;
	if(n != len d)
		return "brotli: short dictionary";
	o := 0;
	for(l := 4; l <= 24; l++) {
		dictoff[l] = o;
		o += l << ndbits[l];
	}
	dict = d;
	return nil;
}

inflate(data: array of byte, size: int): array of byte
{
	b := ref Br(data, 0, 0, 0);
	o := ref Out(array[256] of byte, 0, size);
	if(size >= 0)
		o.d = array[size] of byte;
	# window size: back references are checked against it
	wbits := 16;
	if(b.bits(1)) {
		n := b.bits(3);
		if(n != 0)
			wbits = 17 + n;
		else {
			n = b.bits(3);
			if(n == 1)
				raise "brotli: large windows are not supported";
			if(n != 0)
				wbits = 8 + n;
			else
				wbits = 17;
		}
	}
	maxback := (1 << wbits) - 16;
	dist := array[] of {16, 15, 11, 4};	# the last four distances, [3] latest
	for(;;) {
		islast := b.bits(1);
		if(islast && b.bits(1))
			break;	# ISLASTEMPTY
		nibbles := b.bits(2);
		if(nibbles == 3) {
			# metadata: skipped
			if(b.bits(1))
				raise Bad;
			nb := b.bits(2);
			skip := 0;
			if(nb > 0)
				skip = b.bits(8 * nb) + 1;
			b.align();
			b.skip(0);
			while(b.n >= 8 && skip > 0) {
				b.skip(8);
				skip--;
			}
			b.pos += skip;
			if(islast)
				break;
			continue;
		}
		mlen := b.bits(4 * (nibbles + 4)) + 1;
		if(!islast && b.bits(1)) {
			# uncompressed
			b.align();
			if(o.n + mlen > len o.d)
				grow(o, mlen);
			for(; mlen > 0 && b.n >= 8; mlen--) {
				o.d[o.n++] = byte b.bits(8);
			}
			if(b.pos + mlen > len b.d)
				raise Bad;
			o.d[o.n:] = b.d[b.pos:b.pos + mlen];
			o.n += mlen;
			b.pos += mlen;
			continue;
		}
		metablock(b, o, mlen, maxback, dist);
		if(islast)
			break;
	}
	if(o.max >= 0 && o.n != o.max)
		raise "brotli: wrong decompressed size";
	return o.d[0:o.n];
}

metablock(b: ref Br, o: ref Out, mlen, maxback: int, dist: array of int)
{
	bl := readblk(b);
	bi := readblk(b);
	bd := readblk(b);
	npostfix := b.bits(2);
	ndirect := b.bits(4) << npostfix;
	pmask := (1 << npostfix) - 1;
	cmode := array[bl.n] of int;
	for(i := 0; i < bl.n; i++)
		cmode[i] = b.bits(2);
	ntl := varnum(b);
	lmap := readmap(b, 64 * bl.n, ntl);
	ntd := varnum(b);
	dmap := readmap(b, 4 * bd.n, ntd);
	ltrees := array[ntl] of ref Code;
	for(i = 0; i < ntl; i++)
		ltrees[i] = readcode(b, 256);
	itrees := array[bi.n] of ref Code;
	for(i = 0; i < bi.n; i++)
		itrees[i] = readcode(b, 704);
	nd := 16 + ndirect + (48 << npostfix);
	dtrees := array[ntd] of ref Code;
	for(i = 0; i < ntd; i++)
		dtrees[i] = readcode(b, nd);

	end := o.n + mlen;
	if(end > len o.d)
		grow(o, end - o.n);
	d := o.d;
	for(;;) {
		if(bi.left == 0)
			switchblk(b, bi);
		bi.left--;
		cmd := sym(b, itrees[bi.cur]);
		ic, cc: int;
		implicit := cmd < 128;
		if(implicit) {
			ic = (cmd >> 3) & 7;
			cc = (cmd & 7) + ((cmd >> 6) << 3);
		} else {
			cell := (cmd >> 6) - 2;
			ic = insrange[cell] + ((cmd >> 3) & 7);
			cc = copyrange[cell] + (cmd & 7);
		}
		ilen := insbase[ic] + b.bits(insextra[ic]);
		clen := copybase[cc] + b.bits(copyextra[cc]);
		if(o.n + ilen > end)
			raise Bad;
		for(; ilen > 0; ilen--) {
			if(bl.left == 0)
				switchblk(b, bl);
			bl.left--;
			p1 := 0;
			p2 := 0;
			if(o.n > 0)
				p1 = int d[o.n-1];
			if(o.n > 1)
				p2 = int d[o.n-2];
			m := cmode[bl.cur] << 9;
			ctx := ctxlut[m + p1] | ctxlut[m + 256 + p2];
			d[o.n++] = byte sym(b, ltrees[int lmap[64*bl.cur + ctx]]);
		}
		if(o.n >= end)
			break;
		distance: int;
		if(implicit)
			distance = dist[3];
		else {
			if(bd.left == 0)
				switchblk(b, bd);
			bd.left--;
			dctx := 3;
			if(clen <= 4)
				dctx = clen - 2;
			dc := sym(b, dtrees[int dmap[4*bd.cur + dctx]]);
			if(dc < 16) {
				case dc {
				0 =>	distance = dist[3];
				1 =>	distance = dist[2];
				2 =>	distance = dist[1];
				3 =>	distance = dist[0];
				* =>
					base := dist[3];
					if(dc >= 10)
						base = dist[2];
					k := (dc - 4) % 6;
					delta := array[] of {-1, 1, -2, 2, -3, 3};
					distance = base + delta[k];
				}
				if(distance <= 0)
					raise Bad;
			} else if(dc < 16 + ndirect)
				distance = dc - 15;
			else {
				x := dc - ndirect - 16;
				nbits := 1 + (x >> (npostfix + 1));
				hcode := x >> npostfix;
				off := ((2 + (hcode & 1)) << nbits) - 4;
				distance = ((off + b.bits(nbits)) << npostfix) + (x & pmask) + ndirect + 1;
			}
			# 0 reuses the last distance and is not remembered again
			if(dc != 0 && distance <= mymin(maxback, o.n)) {
				dist[0:] = dist[1:4];
				dist[3] = distance;
			}
		}
		maxd := mymin(maxback, o.n);
		if(distance > maxd) {
			# a word from the static dictionary, transformed
			if(clen < 4 || clen > 24)
				raise Bad;
			if(dict == nil && (err := loaddict()) != nil)
				raise err;
			id := distance - maxd - 1;
			nb := ndbits[clen];
			idx := id & ((1 << nb) - 1);
			t := id >> nb;
			if(t >= len xforms)
				raise Bad;
			w := dict[dictoff[clen] + idx*clen:dictoff[clen] + (idx+1)*clen];
			word := transform(w, xforms[t]);
			if(o.n + len word > end)
				raise Bad;
			d[o.n:] = word;
			o.n += len word;
		} else {
			if(o.n + clen > end)
				raise Bad;
			s := o.n - distance;
			for(k := 0; k < clen; k++)
				d[o.n++] = d[s + k];
		}
		if(o.n >= end)
			break;
	}
	o.d = d;
}

mymin(a, b: int): int
{
	if(a < b)
		return a;
	return b;
}

transform(w: array of byte, x: Xform): array of byte
{
	skip := 0;
	cut := 0;
	if(x.kind >= 1 && x.kind <= 9)
		cut = x.kind;
	else if(x.kind >= 12 && x.kind <= 20)
		skip = x.kind - 11;
	if(skip > len w)
		skip = len w;
	mid := array[len w] of byte;
	mid[0:] = w;
	mid = mid[skip:len mid - mymin(cut, len mid - skip)];
	case x.kind {
	Xupfirst =>
		uppercase(mid, 1);
	Xupall =>
		uppercase(mid, 0);
	}
	r := array[len x.prefix + len mid + len x.suffix] of byte;
	for(i := 0; i < len x.prefix; i++)
		r[i] = byte x.prefix[i];
	r[len x.prefix:] = mid;
	o := len x.prefix + len mid;
	for(i = 0; i < len x.suffix; i++)
		r[o + i] = byte x.suffix[i];
	return r;
}

# the RFC's uppercasing: ASCII, and the second or third byte of a UTF-8
# sequence flipped
uppercase(w: array of byte, first: int)
{
	for(i := 0; i < len w; ) {
		c := int w[i];
		step := 1;
		if(c < 16rC0) {
			if(c >= 'a' && c <= 'z')
				w[i] = byte (c ^ 32);
		} else if(c < 16rE0) {
			if(i + 1 < len w)
				w[i+1] = byte (int w[i+1] ^ 32);
			step = 2;
		} else {
			if(i + 2 < len w)
				w[i+2] = byte (int w[i+2] ^ 5);
			step = 3;
		}
		if(first)
			return;
		i += step;
	}
}

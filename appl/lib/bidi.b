implement Bidi;

#
# The Unicode Bidirectional Algorithm, UAX #9 (Unicode 6.3 and later,
# with isolates).  Rule names in comments are the standard's.
#

include "sys.m";
	sys: Sys;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "bidi.m";

MAXDEPTH: con 125;

# Bidi_Class ranges other than L, sorted; the mirror pairs, sorted by
# the first; bracket pairs sorted by the opening and by the closing
clo, chi, ccl: array of int;
mfrom, mto: array of int;
bopen, bclose: array of int;	# by opening
jlo, jhi, jty: array of int;	# joining types, by range
plo, phi, pone: array of int;	# punctuation, by range
lblo, lbhi, lbcl: array of int;	# line break classes, by range
ccp, cup, clw, cti: array of int;	# simple case mappings, by code point
xcp, xkind, xa, xb, xc: array of int;	# one-to-many case mappings, by code point then kind
bcopen, bcclose: array of int;	# by closing

classnames := array[] of {
	"L", "R", "AL", "EN", "ES", "ET", "AN", "CS", "NSM", "BN", "B", "S", "WS", "ON",
	"LRE", "LRO", "RLE", "RLO", "PDF", "LRI", "RLI", "FSI", "PDI",
};

init(): string
{
	if(sys != nil)
		return nil;
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil)
		return sys->sprint("cannot load %s: %r", Bufio->PATH);
	(a, err) := table(DIR + "/classes", 3);
	if(err != nil)
		return err;
	clo = a[0];
	chi = a[1];
	ccl = a[2];
	(a, err) = table(DIR + "/mirror", 2);
	if(err != nil)
		return err;
	mfrom = a[0];
	mto = a[1];
	(a, err) = table(DIR + "/brackets", 2);
	if(err != nil)
		return err;
	bopen = a[0];
	bclose = a[1];
	(a, err) = table(DIR + "/joining", 3);
	if(err != nil)
		return err;
	jlo = a[0];
	jhi = a[1];
	jty = a[2];
	(a, err) = table(DIR + "/punct", 2);
	if(err != nil)
		return err;
	plo = a[0];
	phi = a[1];
	pone = array[len plo] of {* => 1};
	(a, err) = table(DIR + "/linebreak", 3);
	if(err != nil)
		return err;
	lblo = a[0];
	lbhi = a[1];
	lbcl = a[2];
	(a, err) = table(DIR + "/case", 4);
	if(err != nil)
		return err;
	ccp = a[0];
	cup = a[1];
	clw = a[2];
	cti = a[3];
	(a, err) = table(DIR + "/casex", 5);
	if(err != nil)
		return err;
	xcp = a[0];
	xkind = a[1];
	xa = a[2];
	xb = a[3];
	xc = a[4];
	# the same pairs ordered by the closing bracket
	n := len bopen;
	bcopen = array[n] of int;
	bcclose = array[n] of int;
	ix := array[n] of int;
	for(i := 0; i < n; i++)
		ix[i] = i;
	for(i = 1; i < n; i++)
		for(j := i; j > 0 && bclose[ix[j]] < bclose[ix[j-1]]; j--)
			(ix[j], ix[j-1]) = (ix[j-1], ix[j]);
	for(i = 0; i < n; i++) {
		bcopen[i] = bopen[ix[i]];
		bcclose[i] = bclose[ix[i]];
	}
	return nil;
}

# a file of lines of ncol hex numbers (the last column a class name
# for the class table), sorted by the first column
table(path: string, ncol: int): (array of array of int, string)
{
	f := bufio->open(path, Bufio->OREAD);
	if(f == nil)
		return (nil, sys->sprint("cannot open %s: %r", path));
	rows: list of array of int;
	n := 0;
	while((l := f.gets('\n')) != nil) {
		if(l[0] == '#')
			continue;
		(nf, fl) := sys->tokenize(l, " \t\n");
		if(nf < ncol)
			continue;
		r := array[ncol] of int;
		for(i := 0; i < ncol; i++) {
			fld := hd fl;
			fl = tl fl;
			if(i == ncol - 1 && path == DIR + "/classes")
				r[i] = classnum(fld);
			else if(i == ncol - 1 && path == DIR + "/linebreak")
				r[i] = int fld;	# the class number, decimal
			else
				r[i] = hex(fld);
		}
		rows = r :: rows;
		n++;
	}
	a := array[ncol] of array of int;
	for(i := 0; i < ncol; i++)
		a[i] = array[n] of int;
	for(k := n - 1; rows != nil; rows = tl rows) {
		for(i = 0; i < ncol; i++)
			a[i][k] = (hd rows)[i];
		k--;
	}
	return (a, nil);
}

classnum(s: string): int
{
	for(i := 0; i < len classnames; i++)
		if(classnames[i] == s)
			return i;
	return L;
}

hex(s: string): int
{
	v := 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		d := 0;
		if(c >= '0' && c <= '9')
			d = c - '0';
		else if(c >= 'a' && c <= 'f')
			d = c - 'a' + 10;
		else if(c >= 'A' && c <= 'F')
			d = c - 'A' + 10;
		else
			break;
		v = v*16 + d;
	}
	return v;
}

class(c: int): int
{
	return ranged(clo, chi, ccl, c, L);
}

joining(c: int): int
{
	return ranged(jlo, jhi, jty, c, JU);
}

punct(c: int): int
{
	return ranged(plo, phi, pone, c, 0);
}

lbclass(c: int): int
{
	return ranged(lblo, lbhi, lbcl, c, LBAL);
}

# ---- case mapping (Unicode 3.13, SpecialCasing.txt) ----

# c's one-to-many mapping of the kind (1 upper, 2 lower, 3 title), or nil
special(c, kind: int): string
{
	i := find(xcp, c);
	if(i < 0)
		return nil;
	while(i > 0 && xcp[i-1] == c)
		i--;
	for(; i < len xcp && xcp[i] == c; i++)
		if(xkind[i] == kind) {
			r := "";
			r[0] = xa[i];
			if(xb[i] != 0)
				r[1] = xb[i];
			if(xc[i] != 0)
				r[2] = xc[i];
			return r;
		}
	return nil;
}

simple(a: array of int, c: int): int
{
	i := find(ccp, c);
	if(i < 0 || a[i] == 0)
		return c;
	return a[i];
}

cased(c: int): int
{
	return find(ccp, c) >= 0;
}

turkic(lang: string): int
{
	return len lang >= 2 && (lang[0:2] == "tr" || lang[0:2] == "az") && (len lang == 2 || lang[2] == '-');
}

toupper(s: string, lang: string): string
{
	r := "";
	tr := turkic(lang);
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(tr && c == 'i')
			r[len r] = 16r130;	# dotted capital I
		else if((x := special(c, 1)) != nil)
			r += x;
		else
			r[len r] = simple(cup, c);
	}
	return r;
}

tolower(s: string, lang: string): string
{
	r := "";
	tr := turkic(lang);
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(tr && c == 'I') {
			# a dotless i, unless a combining dot above follows, which the i absorbs
			if(i+1 < len s && s[i+1] == 16r307) {
				r[len r] = 'i';
				i++;
			} else
				r[len r] = 16r131;
		} else if(tr && c == 16r130)
			r[len r] = 'i';
		else if(c == 16r3A3) {
			# Final_Sigma: at the end of a word, after a letter
			final := i > 0 && cased(s[i-1]) && !(i+1 < len s && cased(s[i+1]));
			if(final)
				r[len r] = 16r3C2;
			else
				r[len r] = 16r3C3;
		} else if((x := special(c, 2)) != nil)
			r += x;
		else
			r[len r] = simple(clw, c);
	}
	return r;
}

totitle(c: int, lang: string): string
{
	if(turkic(lang) && c == 'i') {
		r := "";
		r[0] = 16r130;
		return r;
	}
	if((x := special(c, 3)) != nil)
		return x;
	t := simple(cti, c);
	if(t == c)
		t = simple(cup, c);
	r := "";
	r[0] = t;
	return r;
}

# the value of the range holding c, or dflt
ranged(lo, hi, val: array of int, c, dflt: int): int
{
	i := 0;
	j := len lo;
	while(i < j) {
		m := (i + j) / 2;
		if(c < lo[m])
			j = m;
		else if(c > hi[m])
			i = m + 1;
		else
			return val[m];
	}
	return dflt;
}

mirror(c: int): int
{
	i := find(mfrom, c);
	if(i < 0)
		return c;
	return mto[i];
}

find(a: array of int, c: int): int
{
	lo := 0;
	hi := len a;
	while(lo < hi) {
		m := (lo + hi) / 2;
		if(c < a[m])
			hi = m;
		else if(c > a[m])
			lo = m + 1;
		else
			return m;
	}
	return -1;
}

# brackets are matched under canonical equivalence: the angle brackets
# U+2329 and U+232A decompose to U+3008 and U+3009
canon(c: int): int
{
	case c {
	16r2329 =>	return 16r3008;
	16r232A =>	return 16r3009;
	}
	return c;
}

isisolate(c: int): int
{
	return c == LRI || c == RLI || c == FSI;
}

# removed by X9
removed(c: int): int
{
	return c == RLE || c == LRE || c == RLO || c == LRO || c == PDF || c == BN;
}

# P2, P3: the first strong character of cls[from:to], skipping anything
# between an isolate initiator and its matching PDI (or the end)
strongdir(cls: array of int, from, end: int): int
{
	depth := 0;
	for(i := from; i < end; i++) {
		c := cls[i];
		if(isisolate(c))
			depth++;
		else if(c == PDI) {
			if(depth > 0)
				depth--;
		} else if(depth == 0) {
			if(c == L)
				return 0;
			if(c == R || c == AL)
				return 1;
		}
	}
	return -1;
}

basedir(s: array of int): int
{
	cls := array[len s] of int;
	for(i := 0; i < len s; i++)
		cls[i] = class(s[i]);
	return strongdir(cls, 0, len s);
}

# the index of the PDI matching the isolate initiator at i, or n
matchingpdi(cls: array of int, i, n: int): int
{
	depth := 1;
	for(j := i + 1; j < n; j++) {
		c := cls[j];
		if(isisolate(c))
			depth++;
		else if(c == PDI) {
			depth--;
			if(depth == 0)
				return j;
		} else if(c == B)
			break;
	}
	return n;
}

levels(s: array of int, dir: int): array of int
{
	n := len s;
	curtext = s;
	orig := array[n] of int;	# the classes as given
	cls := array[n] of int;		# as resolved so far
	for(i := 0; i < n; i++)
		orig[i] = cls[i] = class(s[i]);
	para := dir;
	if(para < 0) {
		para = strongdir(cls, 0, n);
		if(para < 0)
			para = 0;
	}
	lev := array[n] of int;

	# the matching PDI of each isolate initiator, and the initiator of each PDI (BD9)
	match := array[n] of {* => -1};
	for(i = 0; i < n; i++)
		if(isisolate(cls[i])) {
			j := matchingpdi(cls, i, n);
			if(j < n) {
				match[i] = j;
				match[j] = i;
			}
		}

	# X1-X8: the directional status stack
	slev := array[MAXDEPTH + 2] of int;
	sover := array[MAXDEPTH + 2] of int;	# -1 neutral, else L or R
	siso := array[MAXDEPTH + 2] of int;
	sp := 0;
	slev[0] = para;
	sover[0] = -1;
	siso[0] = 0;
	overiso := 0;
	overemb := 0;
	validiso := 0;
	for(i = 0; i < n; i++) {
		c := cls[i];
		case c {
		RLE or LRE or RLO or LRO =>
			nl := slev[sp] + 1;
			if(c == RLE || c == RLO) {
				if(nl % 2 == 0)
					nl++;
			} else if(nl % 2 == 1)
				nl++;
			if(nl <= MAXDEPTH && overiso == 0 && overemb == 0) {
				sp++;
				slev[sp] = nl;
				sover[sp] = -1;
				if(c == RLO)
					sover[sp] = R;
				else if(c == LRO)
					sover[sp] = L;
				siso[sp] = 0;
			} else if(overiso == 0)
				overemb++;
			lev[i] = slev[sp];
		RLI or LRI or FSI =>
			rtl := c == RLI;
			if(c == FSI) {
				e := match[i];
				if(e < 0)
					e = n;
				rtl = strongdir(orig, i + 1, e) == 1;
			}
			lev[i] = slev[sp];
			if(sover[sp] >= 0)
				cls[i] = sover[sp];
			nl := slev[sp] + 1;
			if(rtl) {
				if(nl % 2 == 0)
					nl++;
			} else if(nl % 2 == 1)
				nl++;
			if(nl <= MAXDEPTH && overiso == 0 && overemb == 0) {
				validiso++;
				sp++;
				slev[sp] = nl;
				sover[sp] = -1;
				siso[sp] = 1;
			} else
				overiso++;
		PDI =>
			if(overiso > 0)
				overiso--;
			else if(validiso > 0) {
				overemb = 0;
				while(siso[sp] == 0)
					sp--;
				sp--;
				validiso--;
			}
			lev[i] = slev[sp];
			if(sover[sp] >= 0)
				cls[i] = sover[sp];
		PDF =>
			if(overiso > 0)
				;
			else if(overemb > 0)
				overemb--;
			else if(siso[sp] == 0 && sp >= 1)
				sp--;
			lev[i] = slev[sp];
		B =>
			# X8: a paragraph ends here
			lev[i] = para;
			sp = 0;
			overiso = overemb = validiso = 0;
		BN =>
			lev[i] = slev[sp];
		* =>
			lev[i] = slev[sp];
			if(sover[sp] >= 0)
				cls[i] = sover[sp];
		}
	}

	# X9: the characters not considered from here on
	keep := array[n] of int;	# indices of the rest, in order
	nk := 0;
	for(i = 0; i < n; i++)
		if(!removed(orig[i]))
			keep[nk++] = i;

	# X10: level runs, chained into isolating run sequences
	runstart := array[nk + 1] of int;	# in keep[] positions
	nr := 0;
	for(k := 0; k < nk; k++)
		if(k == 0 || lev[keep[k]] != lev[keep[k-1]])
			runstart[nr++] = k;
	runstart[nr] = nk;
	runseq := array[nr] of {* => -1};	# the sequence a run joins
	seqs: list of list of int;		# sequences as lists of runs, reversed
	nseq := 0;
	seqof := array[nr] of int;
	for(r := 0; r < nr; r++) {
		first := keep[runstart[r]];
		if(orig[first] == PDI && match[first] >= 0) {
			# continues the sequence of its initiator's run
			ini := match[first];
			for(q := r - 1; q >= 0; q--)
				if(keep[runstart[q+1] - 1] == ini) {
					seqof[r] = seqof[q];
					break;
				}
			if(q >= 0)
				continue;
		}
		seqof[r] = nseq++;
	}
	# the embedding levels, as sos and eos compare against them (X10),
	# before the sequences' resolution changes lev
	emb := array[n] of int;
	emb[0:] = lev;
	# gather each sequence's character indices
	for(sq := 0; sq < nseq; sq++) {
		cnt := 0;
		for(r = 0; r < nr; r++)
			if(seqof[r] == sq)
				cnt += runstart[r+1] - runstart[r];
		idx := array[cnt] of int;
		m := 0;
		for(r = 0; r < nr; r++)
			if(seqof[r] == sq)
				for(k = runstart[r]; k < runstart[r+1]; k++)
					idx[m++] = keep[k];
		resolve(idx, cls, orig, lev, emb, match, para, keep, nk);
	}

	# the removed characters take the level of what precedes them
	prev := para;
	for(i = 0; i < n; i++) {
		if(removed(orig[i]))
			lev[i] = prev;
		else
			prev = lev[i];
	}
	# L1: separators, and white space before them and at the end
	for(i = 0; i < n; i++)
		if(orig[i] == S || orig[i] == B) {
			lev[i] = para;
			for(j := i - 1; j >= 0 && trailing(orig[j]); j--)
				lev[j] = para;
		}
	for(j := n - 1; j >= 0 && trailing(orig[j]); j--)
		lev[j] = para;
	return lev;
}

# white space for L1: WS, the isolate controls, and what X9 removes
trailing(c: int): int
{
	return c == WS || isisolate(c) || c == PDI || removed(c);
}

linelevels(s: array of int, levels: array of int, from, end, paralevel: int): array of int
{
	r := levels[from:end];
	r = array[len r] of int;
	r[0:] = levels[from:end];
	for(j := len r - 1; j >= 0 && trailing(class(s[from + j])); j--)
		r[j] = paralevel;
	return r;
}

# W1-W7, N0-N2, I1-I2 on one isolating run sequence: idx are the
# indices of its characters, in order
resolve(idx: array of int, cls, orig, lev, emb: array of int, match: array of int, para: int, keep: array of int, nk: int)
{
	m := len idx;
	if(m == 0)
		return;
	level := emb[idx[0]];
	# sos and eos (X10)
	first := idx[0];
	last := idx[m-1];
	before := para;
	for(k := 0; k < nk; k++)
		if(keep[k] == first) {
			if(k > 0)
				before = emb[keep[k-1]];
			break;
		}
	after := para;
	if(!isisolate(orig[last])) {	# an initiator ending a sequence has no matching PDI
		for(k = 0; k < nk; k++)
			if(keep[k] == last) {
				if(k + 1 < nk)
					after = emb[keep[k+1]];
				break;
			}
	}
	sos := L;
	if(max(before, level) % 2 == 1)
		sos = R;
	eos := L;
	if(max(after, level) % 2 == 1)
		eos = R;

	t := array[m] of int;
	for(i := 0; i < m; i++)
		t[i] = cls[idx[i]];

	# W1
	for(i = 0; i < m; i++)
		if(t[i] == NSM) {
			if(i == 0)
				t[i] = sos;
			else if(isisolate(t[i-1]) || t[i-1] == PDI)
				t[i] = ON;
			else
				t[i] = t[i-1];
		}
	# W2
	for(i = 0; i < m; i++)
		if(t[i] == EN) {
			for(j := i - 1; j >= 0; j--)
				if(t[j] == R || t[j] == L || t[j] == AL)
					break;
			if(j >= 0 && t[j] == AL)
				t[i] = AN;
		}
	# W3
	for(i = 0; i < m; i++)
		if(t[i] == AL)
			t[i] = R;
	# W4
	for(i = 1; i + 1 < m; i++) {
		if(t[i] == ES && t[i-1] == EN && t[i+1] == EN)
			t[i] = EN;
		else if(t[i] == CS && t[i-1] == EN && t[i+1] == EN)
			t[i] = EN;
		else if(t[i] == CS && t[i-1] == AN && t[i+1] == AN)
			t[i] = AN;
	}
	# W5
	for(i = 0; i < m; i++)
		if(t[i] == ET) {
			j := i;
			while(j < m && t[j] == ET)
				j++;
			if(i > 0 && t[i-1] == EN || j < m && t[j] == EN)
				for(k = i; k < j; k++)
					t[k] = EN;
			i = j - 1;
		}
	# W6
	for(i = 0; i < m; i++)
		if(t[i] == ES || t[i] == ET || t[i] == CS)
			t[i] = ON;
	# W7
	for(i = 0; i < m; i++)
		if(t[i] == EN) {
			for(j := i - 1; j >= 0; j--)
				if(t[j] == R || t[j] == L)
					break;
			if(j < 0 && sos == L || j >= 0 && t[j] == L)
				t[i] = L;
		}
	# N0: paired brackets (BD16)
	brackets(idx, t, orig, level, sos);
	# N1, N2
	edir := L;
	if(level % 2 == 1)
		edir = R;
	for(i = 0; i < m; i++)
		if(isni(t[i])) {
			j := i;
			while(j < m && isni(t[j]))
				j++;
			lead := sos;
			if(i > 0)
				lead = strongof(t[i-1]);
			trail := eos;
			if(j < m)
				trail = strongof(t[j]);
			d := edir;
			if(lead == trail)
				d = lead;
			for(k = i; k < j; k++)
				t[k] = d;
			i = j - 1;
		}
	# I1, I2
	for(i = 0; i < m; i++) {
		x := idx[i];
		if(level % 2 == 0) {
			if(t[i] == R)
				lev[x] = level + 1;
			else if(t[i] == AN || t[i] == EN)
				lev[x] = level + 2;
			else
				lev[x] = level;
		} else {
			if(t[i] == L || t[i] == EN || t[i] == AN)
				lev[x] = level + 1;
			else
				lev[x] = level;
		}
		cls[x] = t[i];
	}
}

isni(c: int): int
{
	return c == B || c == S || c == WS || c == ON || isisolate(c) || c == PDI;
}

# for N1: EN and AN count as R
strongof(c: int): int
{
	if(c == L)
		return L;
	return R;
}

max(a, b: int): int
{
	if(a > b)
		return a;
	return b;
}

MAXPAIRS: con 63;

# N0.  t is the sequence's types after W7; orig the original classes.
brackets(idx: array of int, t: array of int, orig: array of int, level, sos: int)
{
	m := len idx;
	# BD16: the pairs, as (opening position, closing position)
	stkc := array[MAXPAIRS] of int;	# the closing bracket each open one wants
	stkp := array[MAXPAIRS] of int;	# its position
	sp := 0;
	po: list of (int, int);
	np := 0;
	for(i := 0; i < m; i++) {
		if(t[i] != ON)
			continue;
		c := canon(cp(idx[i]));
		k := find(bopen, c);
		if(k >= 0) {
			if(sp >= MAXPAIRS) {
				po = nil;
				np = 0;
				break;
			}
			stkc[sp] = canon(bclose[k]);
			stkp[sp] = i;
			sp++;
			continue;
		}
		k = find(bcclose, c);
		if(k < 0)
			continue;
		for(j := sp - 1; j >= 0; j--)
			if(stkc[j] == c) {
				po = (stkp[j], i) :: po;
				np++;
				sp = j;
				break;
			}
	}
	if(np == 0)
		return;
	# in order of the opening positions
	pa := array[np] of (int, int);
	for(k := np - 1; po != nil; po = tl po)
		pa[k--] = hd po;
	for(i = 1; i < np; i++)
		for(j := i; j > 0 && pa[j].t0 < pa[j-1].t0; j--)
			(pa[j], pa[j-1]) = (pa[j-1], pa[j]);
	edir := L;
	if(level % 2 == 1)
		edir = R;
	for(k = 0; k < np; k++) {
		(o, c) := pa[k];
		found := 0;	# strong types inside: bit 1 for edir, 2 for the other
		for(i = o + 1; i < c; i++) {
			s := strongtype(t[i]);
			if(s < 0)
				continue;
			if(s == edir)
				found |= 1;
			else
				found |= 2;
		}
		d := -1;
		if(found & 1)
			d = edir;
		else if(found & 2) {
			# the context before the opening bracket decides
			ctx := sos;
			for(i = o - 1; i >= 0; i--)
				if((s := strongtype(t[i])) >= 0) {
					ctx = s;
					break;
				}
			if(ctx != edir)
				d = ctx;
			else
				d = edir;
		}
		if(d < 0)
			continue;
		t[o] = d;
		t[c] = d;
		# NSMs after a bracket that changed follow it
		for(i = o + 1; i < m && orig[idx[i]] == NSM; i++)
			t[i] = d;
		for(i = c + 1; i < m && orig[idx[i]] == NSM; i++)
			t[i] = d;
	}
}

# the strong direction a resolved type counts as for N0 (EN, AN as R), or -1
strongtype(c: int): int
{
	if(c == L)
		return L;
	if(c == R || c == EN || c == AN)
		return R;
	return -1;
}

# the code points of the paragraph being resolved, for N0
curtext: array of int;

cp(i: int): int
{
	return curtext[i];
}

reorder(levels: array of int): array of int
{
	n := len levels;
	r := array[n] of int;
	for(i := 0; i < n; i++)
		r[i] = i;
	hi := 0;
	lowodd := 1000;
	for(i = 0; i < n; i++) {
		if(levels[i] > hi)
			hi = levels[i];
		if(levels[i] % 2 == 1 && levels[i] < lowodd)
			lowodd = levels[i];
	}
	for(l := hi; l >= lowodd; l--)
		for(i = 0; i < n; i++)
			if(levels[r[i]] >= l) {
				j := i;
				while(j < n && levels[r[j]] >= l)
					j++;
				a := i;
				b := j - 1;
				for(; a < b; a++) {
					(r[a], r[b]) = (r[b], r[a]);
					b--;
				}
				i = j - 1;
			}
	return r;
}

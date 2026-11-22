implement Hyphen;

#
# Liang's hyphenation (Word Hy-phen-a-tion by Com-put-er, 1983), as TeX
# and Android do it, over lib/web/hyphen's patterns.  A pattern is
# letters with digits between them; where a word (with a dot at each
# end) holds the letters, the digits are laid over the places between,
# the greatest kept, and an odd one is a place a break may come.  The
# exceptions file gives some words their hyphens outright.
#

include "sys.m";
	sys: Sys;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "web/hyphen.m";

MINWORD: con 5;	# letters a word needs to be hyphenated (Blink's)
MINLEFT: con 2;	# letters before a break and after it: the patterns' own (their
MINRIGHT: con 3;	# hyphenmins), which Chromium keeps: "classes" overflows a column, never class-es
NBUCKET: con 8192;
NCACHE: con 4096;

Pat: adt {
	key:	string;
	digits:	array of byte;	# len key + 1
};

loaded := 0;	# 0 not yet, 1 read, -1 cannot be
pats: array of list of ref Pat;
maxpat := 0;
exceptions: list of (string, array of byte);
cache: array of list of (string, array of byte);
ncached := 0;

known(lang: string): int
{
	if(!english(lang))
		return 0;
	return loadpats() > 0;
}

english(lang: string): int
{
	if(len lang < 2)
		return 0;
	return (lang[0] == 'e' || lang[0] == 'E') && (lang[1] == 'n' || lang[1] == 'N') && (len lang == 2 || lang[2] == '-' || lang[2] == '_');
}

loadpats(): int
{
	if(loaded != 0)
		return loaded;
	loaded = -1;
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil)
		return loaded;
	b := bufio->open(DIR + "en-us.pat", Bufio->OREAD);
	if(b == nil)
		return loaded;
	pats = array[NBUCKET] of list of ref Pat;
	while((line := b.gets('\n')) != nil) {
		key := "";
		digits := array[len line + 1] of {* => byte 0};
		n := 0;
		for(i := 0; i < len line; i++) {
			c := line[i];
			if(c >= '0' && c <= '9')
				digits[n] = byte (c - '0');
			else if(c == '\n' || c == '\r' || c == ' ')
				;
			else {
				key[n++] = c;
			}
		}
		if(n == 0)
			continue;
		p := ref Pat(key, digits[0:n+1]);
		h := hash(key);
		pats[h] = p :: pats[h];
		if(n > maxpat)
			maxpat = n;
	}
	b = bufio->open(DIR + "en-us.hyp", Bufio->OREAD);
	if(b != nil)
		while((hl := b.gets('\n')) != nil) {
			w := "";
			brk := array[len hl] of {* => byte 0};
			for(i := 0; i < len hl; i++) {
				c := hl[i];
				if(c == '-')
					brk[len w] = byte 1;
				else if(c != '\n' && c != '\r' && c != ' ')
					w[len w] = c;
			}
			if(w != "")
				exceptions = (w, brk[0:len w]) :: exceptions;
		}
	cache = array[NBUCKET] of list of (string, array of byte);
	loaded = 1;
	return loaded;
}

hash(s: string): int
{
	h := 0;
	for(i := 0; i < len s; i++)
		h = (h * 31 + s[i]) & 16r7FFFFFFF;
	return h % NBUCKET;
}

lookup(s: string): array of byte
{
	for(l := pats[hash(s)]; l != nil; l = tl l)
		if((hd l).key == s)
			return (hd l).digits;
	return nil;
}

points(w: string, lang: string): array of byte
{
	if(!known(lang) || len w < MINWORD)
		return nil;
	lw := "";
	for(i := 0; i < len w; i++) {
		c := w[i];
		if(c >= 'A' && c <= 'Z')
			c += 'a' - 'A';
		if(c < 'a' || c > 'z')
			return nil;	# the patterns are for the letters a to z
		lw[i] = c;
	}
	h := hash(lw);
	for(cl := cache[h]; cl != nil; cl = tl cl)
		if((hd cl).t0 == lw)
			return (hd cl).t1;
	brk := liang(lw);
	if(ncached >= NCACHE) {
		cache = array[NBUCKET] of list of (string, array of byte);
		ncached = 0;
	}
	cache[h] = (lw, brk) :: cache[h];
	ncached++;
	return brk;
}

liang(w: string): array of byte
{
	n := len w;
	brk := array[n] of {* => byte 0};
	for(el := exceptions; el != nil; el = tl el)
		if((hd el).t0 == w) {
			e := (hd el).t1;
			for(i := MINLEFT; i <= n - MINRIGHT; i++)
				brk[i] = e[i];
			return brk;
		}
	d := "." + w + ".";
	v := array[len d + 1] of {* => byte 0};
	for(i := 0; i < len d; i++)
		for(j := i + 1; j <= len d && j - i <= maxpat; j++) {
			p := lookup(d[i:j]);
			if(p == nil)
				continue;
			for(k := 0; k < len p; k++)
				if(p[k] > v[i+k])
					v[i+k] = p[k];
		}
	# v[k] is the place before d[k]: before w[m] is v[m+1]
	for(m := MINLEFT; m <= n - MINRIGHT; m++)
		if(int v[m+1] & 1)
			brk[m] = byte 1;
	return brk;
}

isletter(c: int): int
{
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z';
}

hyphenate(s: string, lang: string): string
{
	if(!known(lang))
		return s;
	out := "";
	changed := 0;
	i := 0;
	while(i < len s) {
		if(!isletter(s[i])) {
			out[len out] = s[i++];
			continue;
		}
		j := i;
		while(j < len s && isletter(s[j]))
			j++;
		w := s[i:j];
		# a word of letters alone: not one joined to digits or other
		# letters (an accented one, which the patterns do not have),
		# nor one with its own soft hyphens, nor a capitalized one
		alone := (i == 0 || !wordchar(s[i-1])) && (j == len s || !wordchar(s[j]));
		brk: array of byte;
		if(alone && !(w[0] >= 'A' && w[0] <= 'Z'))
			brk = points(w, lang);
		for(k := 0; k < len w; k++) {
			if(brk != nil && int brk[k]) {
				out[len out] = 16rAD;
				changed = 1;
			}
			out[len out] = w[k];
		}
		i = j;
	}
	if(!changed)
		return s;
	return out;
}

# what a word goes on through: a letter of any script, a digit, a soft
# hyphen, a joiner
wordchar(c: int): int
{
	return isletter(c) || c >= '0' && c <= '9' || c == 16rAD || c == 16r200D || c >= 16rC0 && c != 16rD7 && c != 16rF7 && c < 16r2000;
}

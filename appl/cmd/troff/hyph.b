#
# hyph.c: hyphenation with TeX's patterns and exceptions
#

HYPATLEN:	con NHYPHS * 16;	# the hyphenation pattern store

# read a character from s at i; returns it and the characters read
hy_cget(s: string, i: int): (string, int)
{
	if(at(s, i) != '\\')
		return (chr(s[i]), 1);
	d := "";
	case at(s, i + 1) {
	'[' =>
		j := i + 2;
		while(j < len s && s[j] != ']' && len d < GNLEN - 1)
			d[len d] = s[j++];
		if(j < len s)
			return (d, len d + 3);
		return (d, len d + 2);
	'(' =>
		j := i + 2;
		if(j < len s)
			d[len d] = s[j++];
		if(j < len s)
			d[len d] = s[j++];
		return (d, 2 + len d);
	'C' =>
		q := at(s, i + 2);
		j := i + 3;
		while(j < len s && s[j] != q && len d < GNLEN - 1)
			d[len d] = s[j++];
		if(j < len s)
			return (d, len d + 4);
		return (d, len d + 3);
	}
	if(i + 1 < len s)
		return (s[i:i+2], 2);
	return (s[i:i+1], 1);
}

# the character s as it appears in words to hyphenate
hy_cput(s: string): string
{
	if(len s <= 1)
		return s;
	if(s[0] == '\\')
		return s;
	if(len s == 2 && s[0] < 16r80 && s[1] < 16r80)
		return "\\[" + s + "]";
	return "";
}

# the hyphenation dictionary (.hw)
hwhyph: array of int;			# hyphenations of the words, one after another
hwword_len := 0;			# used hwhyph[] length
hwpref: ref Pref;			# map words to their index in hwoff[]
hwoff: array of int;			# the offset of the words in hwhyph[]
hw_n := 0;				# the number of dictionary words

# add word s, its hyphens marked with dashes
hw_add(s: string)
{
	l := len s + 1;
	if(hw_n == NHYPHS || hwword_len + l > HYPATLEN)
		return;
	p := "";
	for(j := 0; j < l; j++)
		hwhyph[hwword_len + j] = 0;
	for(j = 0; j < len s; j++){
		if(s[j] == '-')
			hwhyph[hwword_len + len p] = 1;
		else
			p[len p] = s[j];
	}
	hwoff[hw_n] = hwword_len;
	pref_put(hwpref, p, hw_n);
	hwword_len += len p + 1;
	hw_n++;
}

hw_lookup(word: string, hyph: array of int): int
{
	(word2, map) := hcode_strcpy(word, 0);
	off := 0;
	while(off < len word2 && word2[off] == '.')	# skip unknown characters at the front
		off++;
	(i, nil) := pref_prefix(hwpref, word2[off:], -1);
	if(i < 0)
		return 1;
	h := hwoff[i];
	for(j := 0; j + off < len word2; j++)
		if(h + j < HYPATLEN && hwhyph[h + j])
			hyph[map[j + off]] = hwhyph[h + j];
	return 0;
}

tr_hw(args: array of string)
{
	for(i := 1; i < NARGS && i < len args; i++){
		s := args[i];
		word := "";
		k := 0;
		while(len word < WORDLEN - GNLEN){
			(t, c, nk) := escread(s, k);
			if(t != 0)
				break;
			k = nk;
			if(c != "-")
				c = hcode_mapchar(c);
			word += hy_cput(c);
		}
		hw_add(word);
	}
	hycache_reset();
}

# TeX's hyphenation algorithm

hyinit := 0;				# the hyphenation data is initialised
hynums: array of int;			# the numbers of the patterns, one after another
hypats_len := 0;			# used hynums[] length
hyoff: array of int;			# the offset of the patterns in hynums[]
hylen: array of int;			# their lengths
hy_n := 0;				# the number of patterns

# the patterns in a trie: a node's character, first child, next sibling
# and the first pattern ending there (patnext links the rest)
tchar, tchild, tnext, tpat: array of int;
tn := 0;
patnext: array of int;

trie_init()
{
	tchar = array[4096] of {* => 0};
	tchild = array[4096] of {* => -1};
	tnext = array[4096] of {* => -1};
	tpat = array[4096] of {* => -1};
	tn = 1;		# the root
	patnext = array[NHYPHS] of {* => -1};
}

trie_node(c: int): int
{
	if(tn == len tchar){
		n := 2 * len tchar;
		a := array[n] of {* => 0};
		a[0:] = tchar;
		tchar = a;
		a = array[n] of {* => -1};
		a[0:] = tchild;
		tchild = a;
		a = array[n] of {* => -1};
		a[0:] = tnext;
		tnext = a;
		a = array[n] of {* => -1};
		a[0:] = tpat;
		tpat = a;
	}
	tchar[tn] = c;
	return tn++;
}

# add pattern i, the letters p, to the trie
trie_put(p: string, i: int)
{
	node := 0;
	for(k := 0; k < len p; k++){
		c := p[k];
		ch := tchild[node];
		while(ch >= 0 && tchar[ch] != c)
			ch = tnext[ch];
		if(ch < 0){
			ch = trie_node(c);
			tnext[ch] = tchild[node];
			tchild[node] = ch;
		}
		node = ch;
	}
	patnext[i] = tpat[node];
	tpat[node] = i;
}

# find the patterns matching w at off and update the values n from there.
# Neatroff finds a pattern only through the first two bytes of its UTF-8,
# so a pattern of a single ASCII letter never matches.
hy_find(w: string, off: int, n: array of int)
{
	node := 0;
	for(k := off; k < len w; k++){
		c := w[k];
		ch := tchild[node];
		while(ch >= 0 && tchar[ch] != c)
			ch = tnext[ch];
		if(ch < 0)
			break;
		node = ch;
		if(k == off && c < 16r80)
			continue;
		for(i := tpat[node]; i >= 0; i = patnext[i]){
			np := hyoff[i];
			plen := hylen[i] + 1;
			for(j := 0; j < plen; j++)
				if(n[off + j] < hynums[np + j])
					n[off + j] = hynums[np + j];
		}
	}
}

# mark the hyphenation points of word in hyph
hy_dohyph(hyph: array of int, word: string, flg: int)
{
	(w, wmap) := hcode_strcpy(word, 1);	# cleaned-up word; "Abc" is ".abc."
	wlen := len w;
	n := array[wlen + GNLEN] of {* => 0};	# the hyphenation value for w
	c := array[wlen + 1] of {* => 0};		# the start of the i-th character in w
	nc := 0;
	for(i := 0; i < wlen - 1; ){
		c[nc++] = i;
		(nil, k) := hy_cget(w, i);
		i += k;
	}
	for(i = 0; i < nc - 1; i++)
		hy_find(w, c[i], n);
	for(i = 0; i < wlen && i < len hyph; i++)
		hyph[i] = 0;
	for(i = 3; i < nc - 2; i++)
		if(n[c[i]] % 2 && w[c[i - 1]] != '.' && w[c[i]] != '.' &&
				w[c[i - 2]] != '.' && w[c[i + 1]] != '.' &&
				(~flg & HY_FINAL2 || w[c[i + 2]] != '.') &&
				(~flg & HY_FIRST2 || w[c[i - 3]] != '.'))
			hyph[wmap[c[i]]] = 1;
}

# add pattern s
hy_add(s: string)
{
	l := len s + 1;
	if(hy_n >= NHYPHS || hypats_len + l >= HYPATLEN)
		return;
	p := "";
	for(j := 0; j < l; j++)
		hynums[hypats_len + j] = 0;
	for(j = 0; j < len s; j++){
		c := s[j];
		if(c >= '0' && c <= '9')
			hynums[hypats_len + len p] = c - '0';
		else
			p[len p] = c;
	}
	hyoff[hy_n] = hypats_len;
	hylen[hy_n] = len p;
	if(p != nil)
		trie_put(p, hy_n);
	hypats_len += len p + 1;
	hy_n++;
}

# .hcode
hcodedict: ref Dict;
hcodesrc := array[NHCODES] of string;
hcodedst := array[NHCODES] of string;
hcode_n := 0;

# the character s after .hcode mapping
hcodec: array of string;	# hcode_mapchar()'s of single characters below 16r80

hcode_mapchar(s: string): string
{
	if(len s == 1 && s[0] < 16r80){
		if(hcodec == nil)
			hcodec = array[16r80] of string;
		if(hcodec[s[0]] == nil)
			hcodec[s[0]] = hcode_mapchar1(s);
		return hcodec[s[0]];
	}
	return hcode_mapchar1(s);
}

hcode_mapchar1(s: string): string
{
	i := dict_get(hcodedict, s);
	if(i >= 0)
		return hcodedst[i];
	if(len s == 1 && s[0] < 16r80){
		if(isalpha(s[0]))
			return chr(tolower(s[0]));
		return ".";
	}
	return s;
}

# s after .hcode mappings, and the position in s of each of its characters
hcode_strcpy(s: string, dots: int): (string, array of int)
{
	d := "";
	map := array[WORDLEN + 1] of {* => 0};	# d is shorter than WORDLEN
	if(dots)
		d = ".";
	si := 0;
	while(len d < WORDLEN - GNLEN && si < len s){
		map[len d] = si;
		(c, k) := hy_cget(s, si);
		si += k;
		m := hcode_mapchar(c);
		if(len m == 1)
			d[len d] = m[0];
		else
			d += hy_cput(m);
	}
	if(dots)
		d += ".";
	return (d, map);
}

hcode_add(c1, c2: string)
{
	hcodec = nil;
	i := dict_get(hcodedict, c1);
	if(i >= 0)
		hcodedst[i] = c2;
	else if(hcode_n < NHCODES){
		hcodesrc[hcode_n] = c1;
		hcodedst[hcode_n] = c2;
		dict_put(hcodedict, c1, hcode_n);
		hcode_n++;
	}
}

tr_hcode(args: array of string)
{
	if(len args < 2)
		return;
	s := args[1];
	i := 0;
	for(;;){
		(t1, c1, i1) := charread(s, i);
		if(t1 < 0)
			break;
		(t2, c2, i2) := charread(s, i1);
		if(t2 < 0)
			break;
		i = i2;
		hcode_add(c1, c2);
	}
	hycache_reset();
}

# the whitespace-separated words of s
words(s: string): list of string
{
	r: list of string;
	i := 0;
	for(;;){
		while(i < len s && isspace(s[i]))
			i++;
		if(i >= len s)
			break;
		b := i;
		while(i < len s && !isspace(s[i]))
			i++;
		r = s[b:i] :: r;
	}
	l: list of string;
	for(; r != nil; r = tl r)
		l = hd r :: l;
	return l;
}

hyph_readpatterns(s: string)
{
	for(l := words(s); l != nil; l = tl l)
		hy_add(hd l);
}

hyph_readexceptions(s: string)
{
	for(l := words(s); l != nil; l = tl l)
		hw_add(hd l);
}

# the words hyphenated so far, and where their hyphens go
hycache: ref Dict;
hycached: array of array of int;
hyncached := 0;

hycache_reset()
{
	hycache = dict_make(4096);
	hycached = array[1024] of array of int;
	hyncached = 0;
}

hyphenate(hyph: array of int, word: string, flg: int)
{
	if(!hyinit){
		hyinit = 1;
		hyph_readpatterns(en_patterns);
		hyph_readexceptions(en_exceptions);
	}
	key := word + "\u0000" + chr(flg + 'A');
	if((i := dict_get(hycache, key)) >= 0){
		h := hycached[i];
		hyph[0:] = h;
		return;
	}
	if(hw_lookup(word, hyph))
		hy_dohyph(hyph, word, flg);
	if(hyncached == len hycached){
		a := array[2 * len hycached] of array of int;
		a[0:] = hycached;
		hycached = a;
	}
	n := len word + 1;
	if(n > len hyph)
		n = len hyph;
	h := array[n] of int;
	h[0:] = hyph[0:n];
	hycached[hyncached] = h;
	dict_put(hycache, key, hyncached++);
}

# lower and upper case letters
hycase := array[] of {
	"aA", "áÁ", "àÀ", "ăĂ", "âÂ", "ǎǍ", "åÅ", "äÄ", "ãÃ", "ąĄ",
	"āĀ", "æÆ", "ǽǼ", "bB", "cC", "ćĆ", "ĉĈ", "čČ", "çÇ", "dD",
	"ďĎ", "đĐ", "ḍḌ", "ðÐ", "eE", "éÉ", "èÈ", "êÊ", "ěĚ", "ëË",
	"ėĖ", "ęĘ", "ēĒ", "fF", "gG", "ğĞ", "ĝĜ", "ģĢ", "hH", "ĥĤ",
	"ḥḤ", "ḫḪ", "iI", "ıI", "íÍ", "ìÌ", "îÎ", "ǐǏ", "ïÏ", "įĮ",
	"īĪ", "jJ", "ĵĴ", "kK", "ķĶ", "lL", "ľĽ", "łŁ", "ļĻ", "ḷḶ",
	"mM", "ṁṀ", "ṃṂ", "nN", "ńŃ", "ňŇ", "ñÑ", "ṅṄ", "ņŅ", "ṇṆ",
	"œŒ", "oO", "óÓ", "òÒ", "ôÔ", "ǒǑ", "öÖ", "őŐ", "õÕ", "øØ",
	"ōŌ", "pP", "qQ", "rR", "ŕŔ", "řŘ", "sS", "śŚ", "ŝŜ", "šŠ",
	"şŞ", "ṣṢ", "tT", "ťŤ", "țȚ", "ṭṬ", "uU", "úÚ", "ùÙ", "ŭŬ",
	"ûÛ", "ǔǓ", "ůŮ", "üÜ", "ǘǗ", "ǜǛ", "ǚǙ", "ǖǕ", "űŰ", "ųŲ",
	"ūŪ", "vV", "wW", "xX", "yY", "ýÝ", "zZ", "źŹ", "žŽ", "żŻ",
	"þÞ", "αΑ", "άΆ", "βΒ", "ϐΒ", "γΓ", "δΔ", "ϫϪ", "εΕ", "έΈ",
	"ζΖ", "ϩϨ", "ηΗ", "ήΉ", "θΘ", "ιΙ", "ίΊ", "ϊΪ", "κΚ", "ϧϦ",
	"λΛ", "μΜ", "νΝ", "ξΞ", "οΟ", "όΌ", "πΠ", "ρΡ", "ϲϹ", "σΣ",
	"ςΣ", "ϭϬ", "τΤ", "ϯϮ", "υΥ", "ύΎ", "ϋΫ", "φΦ", "ϥϤ", "χΧ",
	"ψΨ", "ϣϢ", "ωΩ", "ώΏ", "аА", "ӓӒ", "бБ", "вВ", "гГ", "ґҐ",
	"дД", "ђЂ", "еЕ", "ѐЀ", "єЄ", "ёЁ", "жЖ", "зЗ", "ѕЅ", "иИ",
	"ѝЍ", "ӥӤ", "іІ", "їЇ", "йЙ", "јЈ", "кК", "лЛ", "љЉ", "мМ",
	"нН", "њЊ", "ᲂО", "оО", "ӧӦ", "өӨ", "пП", "рР", "сС", "тТ",
	"ћЋ", "уУ", "ӱӰ", "үҮ", "ўЎ", "фФ", "хХ", "цЦ", "чЧ", "џЏ",
	"шШ", "щЩ", "ᲆЪ", "ъЪ", "ыЫ", "ӹӸ", "ьЬ", "эЭ", "ӭӬ", "юЮ",
	"яЯ", "աԱ", "բԲ", "գԳ", "դԴ", "եԵ", "զԶ", "էԷ", "ըԸ", "թԹ",
	"ժԺ", "իԻ", "լԼ", "խԽ", "ծԾ", "կԿ", "հՀ", "ձՁ", "ղՂ", "ճՃ",
	"մՄ", "յՅ", "նՆ", "շՇ", "ոՈ", "չՉ", "պՊ", "ջՋ", "ռՌ", "սՍ",
	"վՎ", "տՏ", "րՐ", "ցՑ", "փՓ", "քՔ", "օՕ",
};

# the whitespace-separated tokens of a file, at most 127 bytes each
filetoks(path: string): list of string
{
	f := toks_open(path);
	if(f == nil)
		return nil;
	r: list of string;
	while((t := f.tok()) != nil)
		r = t :: r;
	f.f.close();
	l: list of string;
	for(; r != nil; r = tl r)
		l = hd r :: l;
	return l;
}

tr_hpfa(args: array of string)
{
	l: list of string;
	hycache_reset();
	hyinit = 1;
	# load the English patterns with no arguments
	if(len args < 2){
		hyph_readpatterns(en_patterns);
		hyph_readexceptions(en_exceptions);
	}
	# the patterns
	if(len args > 1)
		for(l = filetoks(args[1]); l != nil; l = tl l)
			if(len hd l < WORDLEN)
				hy_add(hd l);
	# the exceptions
	if(len args > 2)
		for(l = filetoks(args[2]); l != nil; l = tl l)
			if(len hd l < WORDLEN)
				hw_add(hd l);
	# lower and upper case hcode mappings
	if(len args > 3 && args[3] == "-"){
		for(i := 0; i < len hycase; i++)
			hcode_add(hycase[i][1:2], hycase[i][0:1]);
	}else if(len args > 3){
		for(l = filetoks(args[3]); l != nil; l = tl l){
			t := hd l;
			if(len t == 2)
				hcode_add(t[1:2], t[0:1]);	# inverting
		}
	}
}

hyph_init()
{
	hwhyph = array[HYPATLEN] of {* => 0};
	hynums = array[HYPATLEN] of {* => 0};
	hwoff = array[NHYPHS] of {* => 0};
	hyoff = array[NHYPHS] of {* => 0};
	hylen = array[NHYPHS] of {* => 0};
	hwpref = pref_make();
	trie_init();
	hcodedict = dict_make(1024);
	hcodec = nil;
	hycache_reset();
}

tr_hpf(args: array of string)
{
	# resetting the patterns
	hypats_len = 0;
	hy_n = 0;
	# resetting the dictionary
	hwword_len = 0;
	hw_n = 0;
	# resetting hcode mappings
	hcode_n = 0;
	# reading
	hyph_init();
	tr_hpfa(args);
}

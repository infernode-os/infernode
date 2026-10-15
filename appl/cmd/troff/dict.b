#
# dict.c and iset.c: mapping strings to integers, integers to sets
#

Dict: adt {
	head:	array of int;
	next:	array of int;
	key:	array of string;
	val:	array of int;
	n:	int;
	tabsz:	int;
};

dict_make(tabsz: int): ref Dict
{
	d := ref Dict;
	d.head = array[tabsz] of {* => 0};
	d.next = array[1024] of {* => 0};
	d.key = array[1024] of string;
	d.val = array[1024] of {* => 0};
	d.n = 1;
	d.tabsz = tabsz;
	return d;
}

dict_hash(d: ref Dict, key: string): int
{
	h := 0;
	for(i := 0; i < len key; i++)
		h = (h << 5) + h + key[i];
	return (h & 16r7fffffff) % d.tabsz;
}

dict_put(d: ref Dict, key: string, val: int)
{
	if(d.n >= len d.key){
		sz := 2 * len d.key;
		next := array[sz] of {* => 0};
		next[0:] = d.next;
		d.next = next;
		k := array[sz] of string;
		k[0:] = d.key;
		d.key = k;
		v := array[sz] of {* => 0};
		v[0:] = d.val;
		d.val = v;
	}
	hash := dict_hash(d, key);
	idx := d.n++;
	d.key[idx] = key;
	d.val[idx] = val;
	d.next[idx] = d.head[hash];
	d.head[hash] = idx;
}

# the index of key in d, or -1
dict_idx(d: ref Dict, key: string): int
{
	h := 0;
	l := len key;
	for(i := 0; i < l; i++)
		h = (h << 5) + h + key[i];
	idx := d.head[(h & 16r7fffffff) % d.tabsz];
	while(idx > 0 && (len d.key[idx] != l || key != d.key[idx]))
		idx = d.next[idx];
	if(idx > 0)
		return idx;
	return -1;
}

dict_key(d: ref Dict, idx: int): string
{
	return d.key[idx];
}

dict_get(d: ref Dict, key: string): int
{
	idx := dict_idx(d, key);
	if(idx >= 0)
		return d.val[idx];
	return -1;
}

# finding the entries a string begins with
Pref: adt {
	map:	ref Iset;
	key:	array of string;
	val:	array of int;
	n:	int;
};

pref_make(): ref Pref
{
	d := ref Pref;
	d.map = iset_make();
	d.key = array[1024] of string;
	d.val = array[1024] of {* => 0};
	d.n = 1;
	return d;
}

# the hash of the first two bytes of key in UTF-8, as Neatroff's;
# an entry is found only by a key with the same two
pref_hash(key: string): int
{
	b0 := 0;
	b1 := 0;
	if(len key > 0){
		b := array of byte key[0:1];
		b0 = int b[0];
		if(len b > 1)
			b1 = int b[1];
		else if(len key > 1)
			b1 = int (array of byte key[1:2])[0];
	}
	return ((b0 << 5) | b1) % 16r3ff;
}

pref_put(d: ref Pref, key: string, val: int)
{
	if(d.n >= len d.key){
		sz := 2 * len d.key;
		k := array[sz] of string;
		k[0:] = d.key;
		d.key = k;
		v := array[sz] of {* => 0};
		v[0:] = d.val;
		d.val = v;
	}
	idx := d.n++;
	d.key[idx] = key;
	d.val[idx] = val;
	iset_put(d.map, pref_hash(key), idx);
}

# match an entry key begins with; pos is -1 in the first call
pref_prefix(d: ref Pref, key: string, pos: int): (int, int)
{
	r := iset_get(d.map, pref_hash(key));
	while(++pos < len r){
		idx := r[pos];
		k := d.key[idx];
		if(len k <= len key && key[0:len k] == k)
			return (d.val[idx], pos);
	}
	return (-1, pos);
}

CNTMIN:	con 1 << 10;
CNTMAX:	con 1 << 20;

Iset: adt {
	set:	array of array of int;
	n:	array of int;
};

iset_make(): ref Iset
{
	return ref Iset(array[CNTMIN] of array of int, array[CNTMIN] of {* => 0});
}

nilints: array of int;

# the members of key's set
iset_get(iset: ref Iset, key: int): array of int
{
	if(key >= 0 && key < len iset.set && iset.set[key] != nil)
		return iset.set[key][0:iset.n[key]];
	return nilints;
}

iset_len(iset: ref Iset, key: int): int
{
	if(key >= 0 && key < len iset.set)
		return iset.n[key];
	return 0;
}

iset_put(iset: ref Iset, key: int, ent: int)
{
	if(key < 0 || key >= CNTMAX)
		return;
	if(key >= len iset.set){
		cnt := (key + 1 + CNTMIN - 1) & ~(CNTMIN - 1);
		set := array[cnt] of array of int;
		set[0:] = iset.set;
		n := array[cnt] of {* => 0};
		n[0:] = iset.n;
		iset.set = set;
		iset.n = n;
	}
	s := iset.set[key];
	if(s == nil || iset.n[key] >= len s){
		sz := 8;
		if(s != nil)
			sz = 2 * len s;
		ns := array[sz] of {* => 0};
		if(s != nil)
			ns[0:] = s;
		iset.set[key] = s = ns;
	}
	s[iset.n[key]++] = ent;
}

iset_has(iset: ref Iset, key: int, ent: int): int
{
	if(key < 0 || key >= len iset.set || iset.set[key] == nil)
		return 0;
	s := iset.set[key];
	for(i := 0; i < iset.n[key]; i++)
		if(s[i] == ent)
			return 1;
	return 0;
}

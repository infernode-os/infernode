#
# map.c: register, macro and environment names to indices
#

MAPBEG:	con 256;	# the entries reserved for ".x" names

mapdict: ref Dict;

map(s: string): int
{
	if(s == nil)
		return 0;
	if(len s == 2 && s[0] == '.' && s[1] < 16r80)	# ".x" is 'x'
		return s[1];
	if(mapdict == nil)
		mapdict = dict_make(4096);
	i := dict_idx(mapdict, s);
	if(i < 0){
		dict_put(mapdict, s, 0);
		i = dict_idx(mapdict, s);
		if(MAPBEG + i >= NREGS)
			errdie("troff: increase NREGS\n");
	}
	return MAPBEG + i;
}

map_name(id: int): string
{
	if(id >= MAPBEG)
		return dict_key(mapdict, id - MAPBEG);
	return "." + chr(id);
}

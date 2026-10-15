#
# what Neatroff takes from the C library, and its helpers in roff.c
#

errmsg(msg: string)
{
	bout.flush();
	sys->fprint(stderr, "%s", msg);
}

errdie(msg: string)
{
	errmsg(msg);
	raise "fail:error";
}

# the index of c in s, or -1
strchr(s: string, c: int): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == c)
			return i;
	return -1;
}

# C's strchr(s, c) != NULL, which holds for c == 0 as well
hasc(s: string, c: int): int
{
	if(c == 0)
		return 1;
	return strchr(s, c) >= 0;
}

# s[i], or 0 past its end (C's terminating NUL)
at(s: string, i: int): int
{
	if(i >= 0 && i < len s)
		return s[i];
	return 0;
}

isdigit(c: int): int
{
	return c >= '0' && c <= '9';
}

isspace(c: int): int
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f';
}

isalpha(c: int): int
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

tolower(c: int): int
{
	if(c >= 'A' && c <= 'Z')
		return c - 'A' + 'a';
	return c;
}

# C's atoi
atoi(s: string): int
{
	i := 0;
	while(i < len s && isspace(s[i]))
		i++;
	neg := 0;
	if(i < len s && (s[i] == '-' || s[i] == '+')){
		neg = s[i] == '-';
		i++;
	}
	n := 0;
	while(i < len s && isdigit(s[i]))
		n = n * 10 + s[i++] - '0';
	if(neg)
		return -n;
	return n;
}

max(a, b: int): int
{
	if(a > b)
		return a;
	return b;
}

min(a, b: int): int
{
	if(a < b)
		return a;
	return b;
}

# the bytes of s in UTF-8 (Neatroff measures some things in them)
utf8nbytes(c: int): int
{
	if(c < 16r80)
		return 1;
	if(c < 16r800)
		return 2;
	if(c < 16r10000)
		return 3;
	return 4;
}

# n as sprint's %.2d
d2(n: int): string
{
	if(n >= 0 && n < 10)
		return "0" + string n;
	if(n < 0 && n > -10)
		return "-0" + string -n;
	return string n;
}

# a string of the single character c
chrs: array of string;
chr(c: int): string
{
	if(c >= 0 && c < 256){
		if(chrs == nil)
			chrs = array[256] of string;
		if((s := chrs[c]) != nil)
			return s;
	}
	s := "";
	s[0] = c;
	if(c >= 0 && c < 256)
		chrs[c] = s;
	return s;
}

# a set of characters below 256, for inset(); C's strchr(s, c) != NULL
cset(s: string): array of byte
{
	t := array[256] of {* => byte 0};
	t[0] = byte 1;
	for(i := 0; i < len s; i++)
		if(s[i] < 256)
			t[s[i]] = byte 1;
	return t;
}

inset(t: array of byte, c: int): int
{
	return c >= 0 && c < 256 && int t[c];
}

#
# clr.c: colours
#

CLR_R(c: int): int
{
	return (c >> 16) & 16rff;
}

CLR_G(c: int): int
{
	return (c >> 8) & 16rff;
}

CLR_B(c: int): int
{
	return c & 16rff;
}

CLR_RGB(r, g, b: int): int
{
	return (r << 16) | (g << 8) | b;
}

colornames := array[] of {
	"black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
};

colorvalues := array[] of {
	16r000000, 16rff0000, 16r00ff00, 16rffff00,
	16r0000ff, 16rff00ff, 16r00ffff, 16rffffff,
};

clr_str(c: int): string
{
	if(c == 0)
		return "0";
	return sys->sprint("#%.2x%.2x%.2x", CLR_R(c), CLR_G(c), CLR_B(c));
}

# a colour component of len hexadecimal digits
ccom(s: string, len_: int): int
{
	digs := "0123456789abcdef";
	n := 0;
	for(i := 0; i < len_; i++){
		d := strchr(digs, tolower(at(s, i)));
		if(at(s, i) != 0 && d >= 0)
			n = n * 16 + d;
	}
	if(len_ == 1)
		return n * 255 / 15;
	return n;
}

clr_get(s: string): int
{
	c := at(s, 0);
	if(c == '#' && len s == 7)
		return CLR_RGB(ccom(s[1:], 2), ccom(s[3:], 2), ccom(s[5:], 2));
	if(c == '#' && len s == 4)
		return CLR_RGB(ccom(s[1:], 1), ccom(s[2:], 1), ccom(s[3:], 1));
	if(c == '#' && len s == 3)
		return CLR_RGB(ccom(s[1:], 2), ccom(s[1:], 2), ccom(s[1:], 2));
	if(c == '#' && len s == 2)
		return CLR_RGB(ccom(s[1:], 1), ccom(s[1:], 1), ccom(s[1:], 1));
	if(isdigit(c) && atoi(s) >= 0 && atoi(s) < len colornames)
		return colorvalues[atoi(s)];
	for(i := 0; i < len colornames; i++)
		if(colornames[i] == s)
			return colorvalues[i];
	return 0;
}

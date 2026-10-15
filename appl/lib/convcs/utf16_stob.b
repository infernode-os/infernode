implement Stob;

include "sys.m";
	sys: Sys;
include "convcs.m";

bigendian := 1;
header := 1;

init(arg : string) : string
{
	sys = load Sys Sys->PATH;
	case arg {
	"le" =>
		bigendian = 0;
		header = 0;
	"be" =>
		header = 0;
	}
	return nil;
}

stob(state : Convcs->State, s : string) : (Convcs->State, array of byte)
{
	if(state == nil){
		if(header)
			s = sys->sprint("%c", 16rfeff) + s;
		state = "doneheader";
	}

	b := array[len s * 4] of byte;
	j := 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c > Sys->Runemax || c >= 16rD800 && c <= 16rDFFF)
			c = Sys->UTFerror;
		if(c > 16rFFFF){
			# beyond the BMP: a surrogate pair
			c -= 16r10000;
			j = put(b, j, 16rD800 + (c >> 10));
			j = put(b, j, 16rDC00 + (c & 16r3FF));
		}else
			j = put(b, j, c);
	}
	return (state, b[0:j]);
}

put(b: array of byte, j: int, u: int): int
{
	if(bigendian){
		b[j++] = byte (u >> 8);
		b[j++] = byte u;
	}else{
		b[j++] = byte u;
		b[j++] = byte (u >> 8);
	}
	return j;
}

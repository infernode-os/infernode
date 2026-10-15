implement Btos;

include "sys.m";
include "convcs.m";

Littleendian, Bigendian: con iota;

sys : Sys;
default := Bigendian;

init(arg : string) : string
{
	sys = load Sys Sys->PATH;
	case arg {
	"le" =>
		default = Littleendian;
	"be" =>
		default = Bigendian;
	}
	return nil;
}


btos(state : Convcs->State, b : array of byte, n : int) : (Convcs->State, string, int)
{
	endian: int;
	i := 0;
	if(state != nil)
		endian = state[0];
	else if (len b >= 2) {
		state = " ";
		# XXX should probably not do this if we've been told the endianness
		case (int b[0] << 8) | int b[1] {
		16rfeff =>
			endian = Bigendian;
			i += 2;
		16rfffe =>
			endian = Littleendian;
			i += 2;
		* =>
			endian = guessendian(b);
		}
		state[0] = endian;
	}
	nb := len b & ~1;
	out := "";
	# a character beyond U+FFFF is a surrogate pair, two units; one
	# that is not part of a pair is an error. A pair the bytes end
	# in the middle of is left for the next call, unless this is
	# the last (n == 0).
	while(i < nb && (n <= 0 || len out < n)){
		c := unit(b, i, endian);
		if(c >= 16rD800 && c <= 16rDBFF){
			if(i + 4 > nb){
				if(n != 0)
					break;
				c = Sys->UTFerror;
				i += 2;
			}else if((c2 := unit(b, i + 2, endian)) >= 16rDC00 && c2 <= 16rDFFF){
				c = 16r10000 + ((c - 16rD800) << 10) + (c2 - 16rDC00);
				i += 4;
			}else{
				c = Sys->UTFerror;
				i += 2;
			}
		}else{
			if(c >= 16rDC00 && c <= 16rDFFF)
				c = Sys->UTFerror;
			i += 2;
		}
		out[len out] = c;
	}
	if(n == 0 && i < len b)
		out[len out] = Sys->UTFerror;
		
	return (state, out, i);
}

unit(b: array of byte, i: int, endian: int): int
{
	if(endian == Bigendian)
		return (int b[i] << 8) | int b[i + 1];
	return int b[i] | int b[i + 1] << 8;
}

guessendian(nil: array of byte): int
{
	# XXX might be able to do better than this in the absence of endian hints.
	return default;
}

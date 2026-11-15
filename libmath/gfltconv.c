#include "lib9.h"
#include "mathi.h"
extern char	*dtoa(double, int, int, int *, int *, char **);
extern void	freedtoa(char*);
extern int	_fmtcpy(Fmt*, void*, int, int);

enum
{
	NONE	= -1000,
	FDIGIT	= 20,
	FDEFLT	= 6,
	NSIGNIF	= 17,

	/*
	 * %f writes every digit before the point: 309 of them for the
	 * largest double, then the point and up to FDIGIT more, with a
	 * sign before them. The buffer was 64 bytes on the stack, and
	 * sprint("%f", 1e300), which any Limbo program can call and a
	 * number read from a peer can reach, wrote 250 bytes of digits
	 * past it. OUTMAX is more than the longest there is, and PUT
	 * stores nothing past the buffer's end whatever the arithmetic
	 * says.
	 */
	OUTMAX	= 400
};

#define	PUT(c)	do{ if(pout < eout) *pout++ = (c); }while(0)

int
gfltconv(Fmt *f)
{
	int flags = f->flags;
	int precision;
	int fmt = f->r;
	double d;
	int echr, exponent, sign, ndig, nout, i;
	char *digits, *edigits, ebuf[32], *eptr;
	char out[OUTMAX], *pout, *eout;

	d = va_arg(f->args, double);
	echr = 'e';
	precision = FDEFLT;
	if(f->flags & FmtPrec)
		precision = f->prec;
	if(precision > FDIGIT)
		precision = FDIGIT;
	switch(fmt){
	case 'f':
		digits = dtoa(d, 3, precision, &exponent, &sign, &edigits);
		break;
	case 0x00c9:	/* L'É' */
	case 'E':
		echr = 'E';
		fmt = 'e';
		/* fall through */
	case 'e':
		digits = dtoa(d, 2, 1+precision, &exponent, &sign, &edigits);
		break;
	case 'G':
		echr = 'E';
		/* fall through */
	default:
	case 'g':
		if((flags&(FmtWidth|FmtPrec)) == 0){
			g_fmt(out, d, echr);
			f->flags &= FmtWidth|FmtLeft;
			return _fmtcpy(f, out, strlen(out), strlen(out));
		}
		if (precision > 0)
			digits = dtoa(d, 2, precision, &exponent, &sign, &edigits);
		else {
			digits = dtoa(d, 0, precision, &exponent, &sign, &edigits);
			precision = edigits - digits;
			if (exponent > precision && exponent <= precision + 4)
				precision = exponent;
			}
		if(exponent >= -3 && exponent <= precision){
			fmt = 'f';
			precision -= exponent;
		}else{
			fmt = 'e';
			--precision;
		}
		break;
	}
	if (exponent == 9999) {
		/* Infinity or Nan */
		precision = 0;
		exponent = edigits - digits;
		fmt = 'f';
	}
	ndig = edigits-digits;
	if((f->r=='g' || f->r=='G') && !(flags&FmtSharp)){ /* knock off trailing zeros */
		if(fmt == 'f'){
			if(precision+exponent > ndig) {
				precision = ndig - exponent;
				if(precision < 0)
					precision = 0;
			}
		}
		else{
			if(precision > ndig-1) precision = ndig-1;
		}
	}
	eptr = ebuf;
	if(fmt != 'f'){					/* exponent */
		for(i=exponent<=0?1-exponent:exponent-1; i; i/=10)
			*eptr++ = '0' + i%10;
		while(eptr<ebuf+2) *eptr++ = '0';
	}
	pout = out;
	eout = out + sizeof(out) - 1;	/* room for the NUL */
	if(sign) PUT('-');
	else if(flags&FmtSign) PUT('+');
	else if(flags&FmtSpace) PUT(' ');
	if(fmt == 'f'){
		for(i=0; i<exponent; i++) PUT(i<ndig?digits[i]:'0');
		if(i == 0) PUT('0');
		if(precision>0 || flags&FmtSharp) PUT('.');
		for(i=0; i<precision; i++)
			PUT(0<=i+exponent && i+exponent<ndig?digits[i+exponent]:'0');
	}
	else{
		PUT(digits[0]);
		if(precision>0 || flags&FmtSharp) PUT('.');
		for(i=0; i<precision; i++) PUT(i<ndig-1?digits[i+1]:'0');
	}
	if(fmt != 'f'){
		PUT(echr);
		PUT(exponent<=0?'-':'+');
		while(eptr>ebuf) PUT(*--eptr);
	}
	*pout = 0;
	freedtoa(digits);
	f->flags &= FmtWidth|FmtLeft;
	nout = pout-out;
	return _fmtcpy(f, out, nout, nout);
}

#define	mpdighi  (mpdigit)((ulong)1<<(Dbits-1))
#define DIGITS(x) ((Dbits - 1 + (x))/Dbits)

// A size is an int of bits, and the sums and products that make one (a
// product's digits, a shift, bytes times eight) were made in ints too.
// Past 2^31 they wrapped: mpbits took the negative count for room
// enough already, and the digits were stored past a block of a hundred
// bytes, in the kernel's pool (a number of 256MB times three). No number
// has more than MAXBITS bits: mpnew and mpbits refuse more, which keeps
// a size and a few digits more, or a shift of a size, inside an int; and
// what adds or multiplies two sizes (mpmul, the conversions from bytes
// and text, mpexp's tables) does it in a vlong and asks first.
#define MAXBITS (1<<30)

// bits for nd digits and extra more bits, or libmp's refusal, as who
int	mpsizebits(vlong nd, vlong extra, char *who);

// libmp says there is no memory by raising (sysfatal is error in the
// kernels), and has no handler to free what a function holds when a
// function it calls raises.  So a function that holds something makes
// what it needs first: mptrynew is mpnew that returns nil, and
// mpreserve makes room in a result (which may be an operand: its
// digits and top are left alone) before anything is held, so that the
// mpbits that later fills it allocates nothing.
mpint*	mptrynew(int n);
void	mpreserve(mpint *b, int n);

// mpdiv, mpmod and mpmul for a function that holds something: -1 when
// there is no memory (or the result would be too large), with nothing
// raised and nothing of theirs left behind.  The other refusals (a
// zero divisor) are still raised: the caller asks first.
int	mpdivtry(mpint *dividend, mpint *divisor, mpint *quotient, mpint *remainder);
int	mpmodtry(mpint *b, mpint *m, mpint *remainder);
int	mpmultry(mpint *b1, mpint *b2, mpint *prod);
int	mpreservetry(mpint *b, int n);
mpint*	mptrycopy(mpint *b);

// for converting between int's and mpint's
#define MAXUINT ((uint)-1)
#define MAXINT (MAXUINT>>1)
#define MININT (MAXINT+1)

// for converting between vlongs's and mpint's
#define MAXUVLONG (~(uvlong)0)
#define MAXVLONG (MAXUVLONG>>1)
#define MINVLONG (MAXVLONG+(uvlong)1)

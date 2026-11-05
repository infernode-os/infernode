/*
 * audiomix -- the arithmetic of the shared audio device (devaudio.c):
 * a client's samples to the mixer's and back, rate conversion, the
 * queues between them, and the mix.  Nothing here knows Chans, procs
 * or locks, so a host test (tests/host/audiomix_test.sh) drives it
 * directly.
 *
 * The mixer's own format is Mixrate, stereo, 16-bit signed, native
 * order; every stream is converted to it on the way in and from it on
 * the way out.
 */

enum {
	Mixrate		= 48000,
	Mixchans	= 2,

	Apcm		= 0,	/* linear: 16-bit signed little-endian, or 8-bit unsigned */
	Aulaw,			/* G.711 mu-law, 8 bits */
	Aalaw,			/* G.711 A-law, 8 bits */

	Gainone		= 256,	/* a gain of 1.0, as mixadd takes it */
};

typedef struct Afmt Afmt;
struct Afmt {
	int	rate;
	int	chans;		/* 1 or 2 */
	int	bits;		/* 8 or 16; 8 for mu-law and A-law */
	int	enc;		/* Apcm, Aulaw, Aalaw */
};

/* A rate converter's state, carried from one buffer to the next. */
typedef struct Resamp Resamp;
struct Resamp {
	int	ri, ro;		/* the rates it was set for */
	uvlong	pos;		/* where the next output falls, in input frames
				 * times ro, from last: exact, so no drift */
	short	last[2];	/* the input frame before this buffer's first */
	int	primed;		/* last holds a frame */
};

/* A queue of stereo frames, oldest first. */
typedef struct Fring Fring;
struct Fring {
	short	*b;
	int	cap;		/* frames */
	int	head;		/* the oldest frame's index */
	int	len;		/* frames held */
};

/* A queue of bytes, oldest first. */
typedef struct Bring Bring;
struct Bring {
	uchar	*b;
	int	cap;
	int	head;
	int	len;
};

int	afmtbytes(Afmt*);			/* bytes a frame takes */
int	afmtok(Afmt*);
int	decodepcm(Afmt*, uchar*, int, short*);	/* bytes to stereo frames; whole frames only */
int	encodepcm(Afmt*, short*, int, uchar*);	/* stereo frames to bytes */
void	resampinit(Resamp*, int ri, int ro);
int	resampmax(Resamp*, int nin);		/* the most frames nin frames can make */
int	resample(Resamp*, short*, int nin, short*);	/* stereo in, stereo out; returns frames out */

void	fringinit(Fring*, short*, int cap);
int	fringput(Fring*, short*, int n, int dropold);	/* returns frames taken */
int	fringget(Fring*, short*, int n);		/* returns frames given */
void	bringinit(Bring*, uchar*, int cap);
int	bringput(Bring*, uchar*, int n, int dropold);
int	bringget(Bring*, uchar*, int n);

void	mixadd(int*, short*, int frames, int g0, int g1);	/* gains in Gainone units, ramped */
void	mixclip(int*, short*, int frames);

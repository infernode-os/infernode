/*
 * What os/port/devcam.c (#V) asks of a camera: a source of raw frames.
 *
 * A source is whatever produces the sensor's samples -- the simulated
 * sensor in campattern.c, and later Unicam with a sensor behind it,
 * or a USB camera. devcam.c does the rest the same way for all of
 * them: the files, the settings, and turning a raw Bayer frame into a
 * picture. A source never sees a Chan.
 *
 * A source registers itself with addcamsrc(). Its methods are called
 * with devcam's lock held, one at a time; they may sleep, and may
 * error().
 */

typedef struct Cammode Cammode;
typedef struct Camsrc Camsrc;

struct Cammode
{
	int	w;		/* pixels; both even */
	int	h;
	int	maxfps;
};

struct Camsrc
{
	char	*name;		/* ctl's "source" line: "test", "csi0" */
	char	*bayer;		/* the colour filter's 2x2 cell, read left to right, top to bottom: "rggb" */
	int	bits;		/* significant bits in a sample, 8..16 */
	Cammode	*modes;
	int	nmode;
	int	defmode;	/* the mode it starts in, an index in modes */

	/* begin making frames of mode m, fps a second */
	void	(*on)(Camsrc*, Cammode *m, int fps);
	void	(*off)(Camsrc*);

	/*
	 * Wait for the next frame to be complete and copy it into raw,
	 * m->w*m->h samples, row by row. Returns its number: 1 for the
	 * first frame after on.
	 */
	ulong	(*next)(Camsrc*, ushort *raw);

	/* how many frames have been made since on */
	ulong	(*count)(Camsrc*);
};

void	addcamsrc(Camsrc*);

extern	Camsrc	campattern;

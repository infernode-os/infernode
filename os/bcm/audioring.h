/*
 * The places in audiopwm.c's ring of buffers: which buffer the DMA engine
 * is playing, which the writer fills next, which are written and waiting.
 * The rules for moving them are here, apart from the hardware, so that
 * tests/host/audioring_test.sh can run exactly these against a simulated
 * engine -- opens, pauses, restarts at every position of the ring --
 * and check that every sound comes out whole and in order. Both of the
 * ring's bugs (2026-10-31) were found by ear on the bench Pi 4; neither
 * needed a board to show.
 *
 * The engine plays the ring for ever, Nbuf buffers round, and at the end
 * of each interrupts (ringplayed). Nothing here is locked: the driver
 * calls ringplayed at interrupt time and the rest under its QLock.
 */

enum
{
	Nbuf	= 4,	/* the writer may run three buffers ahead */
};

typedef struct Ring Ring;
struct Ring
{
	int	full[Nbuf];	/* written and not yet played */
	int	wbuf;		/* the writer's next buffer */
	int	pbuf;		/* the buffer the engine is on: counted, not read back */
	int	ahead;		/* how many buffers the writer may be in front of the engine */
	int	writing;	/* the buffer the writer has begun and not finished, or -1 */
};

/* all silent: the engine starts on buffer 0, and so does the writer */
static void
ringreset(Ring *r)
{
	int i;

	for(i = 0; i < Nbuf; i++)
		r->full[i] = 0;
	r->wbuf = 0;
	r->pbuf = 0;
	r->writing = -1;
}

/* buffers written and not yet played */
static int
ringqueued(Ring *r)
{
	int i, n;

	n = 0;
	for(i = 0; i < Nbuf; i++)
		n += r->full[i];
	return n;
}

/*
 * The engine has finished pbuf: it is free, and the engine is on the
 * next. Returns 1 if that one was not written in time, which the driver
 * fills with silence: a gap is a gap, not the last buffer played twice.
 *
 * Not if the writer has begun it. The writer fills a buffer in
 * microseconds and the engine plays one in tens of milliseconds, so a
 * buffer the writer is part way through when the engine reaches it is
 * finished well ahead of the engine's reading. Silenced, the start of
 * what the writer had written was lost: the first frames of a sound
 * begun just as the engine finished the buffer before.
 */
static int
ringplayed(Ring *r)
{
	int done;

	done = r->pbuf;
	r->pbuf = (done + 1) % Nbuf;
	r->full[done] = 0;
	return !r->full[r->pbuf] && r->pbuf != r->writing;
}

/*
 * A writer about to begin a buffer.
 *
 * With nothing queued -- a new open, or a writer that paused -- the
 * engine has gone on round the ring playing silence, and wbuf is
 * wherever the last writer left it: behind the engine, or the very
 * buffer it is playing. Writing there played a tone in pieces and out
 * of order (parts 3, 4, 1, 2, on the bench Pi 4's second and later runs
 * of audiotone; the first, from a fresh ring, was clean). It starts in
 * the next buffer due, so a new sound is heard as soon as the one
 * playing ends (ringplayed leaves a buffer the writer has begun alone).
 *
 * Low latency (one buffer ahead): a writer the engine has caught up with
 * would be filling the buffer being played; it goes to the next one.
 */
static void
ringbegin(Ring *r)
{
	if(ringqueued(r) == 0)
		r->wbuf = (r->pbuf + 1) % Nbuf;
	if(r->ahead < Nbuf - 1 && r->wbuf == r->pbuf)
		r->wbuf = (r->pbuf + 1) % Nbuf;
}

/*
 * May the writer fill wbuf now? Not if it is still waiting to be played,
 * nor if it is the one being played: playing silence its full[] is 0, and
 * a writer come round the ring to it filled it under the engine -- part
 * 4 of a tone heard before parts 1-3, in a regular pattern, on the Pi 4.
 * Low latency also holds the writer to ahead buffers in front.
 */
static int
ringroom(Ring *r)
{
	int d;

	if(r->full[r->wbuf] || r->wbuf == r->pbuf)
		return 0;
	if(r->ahead >= Nbuf - 1)
		return 1;
	d = (r->wbuf - r->pbuf + Nbuf) % Nbuf;
	return d <= r->ahead;
}

/* the writer begins wbuf, ringroom having said it may */
static void
ringwriting(Ring *r)
{
	r->writing = r->wbuf;
}

/* the writer has filled wbuf: it waits to be played, and the writer moves on */
static void
ringfilled(Ring *r)
{
	r->full[r->wbuf] = 1;
	r->writing = -1;
	r->wbuf = (r->wbuf + 1) % Nbuf;
}

/*
 * #A -- the audio device, shared.
 *
 *	#A/audio	a stream in audioctl's format (as it always was)
 *	#A/audioctl	that format; read, the device's settings
 *	#A/mix/new	open: a stream of its own, n; the fid is n/ctl,
 *			and a read of it gives n
 *	#A/mix/n/data	the stream's sound: written, mixed into what the
 *			speaker plays; read, the microphone, all of it,
 *			from the open on
 *	#A/mix/n/ctl	its format (as audioctl's: [in|out] rate, chans,
 *			bits, enc), its role and queue; read back
 *
 * The streams are in mix/, not beside audio, because #A is bound onto
 * /dev: a bare new and numbers there would be /dev's.
 *
 * Every open of audio, and every n, is a stream of its own.  The
 * device mixes what the streams write, converting each from its
 * format to the mixer's (audiomix.h: 48 kHz, stereo, 16-bit), and
 * gives every stream reading the whole of the microphone in its own
 * format.  Before, two programs writing interleaved their bytes, two
 * reading split the samples (SDL) or the second was refused (OSS),
 * and the format was one setting under everyone.
 *
 * Roles: media, tone, notify, speech, call.  While a stream of a
 * higher role is sounding, media is ducked under speech, notify and
 * call, and speech under call; tone, notify and call are never ducked.
 *
 * Queues.  A stream's output queue holds up to two seconds; with queue
 * 0 (the default) a writer waits for room, so a file copied to the
 * device plays at the speaker's pace; with queue N a write never
 * waits and only the newest N ms are kept, the oldest dropped -- what
 * a call wants (INFR-194: a stream fed over a network otherwise drifts
 * behind the speaker).  Input queues keep the newest two seconds, or
 * N ms.  audioctl's play_buffer_ms and rec_buffer_ms set them for
 * #A/audio's streams, as they set the SDL queues before.
 *
 * The platform's driver (audio_file_open and the rest, audio.h) is the
 * hardware under the mixer, opened once each way, in the mixer's
 * format, by the first stream that needs it, and let go: the output
 * when the streams have drained and none has been written for Idlems
 * (the driver's own close drains what it holds), the microphone when
 * the last stream reading it closes.  A stream whose direction cannot
 * open the hardware is refused at its open, with the driver's error,
 * not left writing into nothing.
 *
 * With $INFERNODE_AUDIO_FAKE set when the emulator starts, there is no
 * hardware: the mixer's output, at its pace, can be read from
 * #A/fakeout, and what is written to #A/fakein is the microphone
 * (silence when nothing is), both in the mixer's format.  For tests.
 *
 * Locks: alk (a spin lock) guards the streams and their queues and is
 * held only to move samples, never across a wait or a driver call.  A
 * client waits with Sleep, which a kill interrupts; Sleep allows one
 * sleeper on a Rendez, so a stream's writers (and readers) take its wq
 * (rq) to wait one at a time -- a lock no close takes.  hwlk serialises
 * opening and closing the driver.
 */
#include	"dat.h"
#include	"fns.h"
#include	"error.h"
#include	"audio.h"
#include	"audiomix.h"

enum {
	Qmix	= 8,		/* clear of audio.h's Qdir, Qaudio, Qaudioctl */
	Qnew,
	Qfakein,
	Qfakeout,
	Qsdir	= 16,
	Qsdata,
	Qsctl,

	Chunk	= Mixrate / 100,	/* 10 ms: what the mixer moves at a time */
	Maxin	= 1024,		/* client frames converted at a time */
	Outcap	= 2 * Mixrate,	/* a stream's output queue: two seconds */
	Leadms	= 40,		/* how far ahead of the clock output is written */
	Idlems	= 3000,		/* output let go after this long with nothing */
	Fakecap	= 30 * Mixrate,	/* #A/fakeout keeps the newest 30 s */

	Hout	= 0,
	Hin,
};

#define	QTYPE(p)	((ulong)(p) & 0xFF)
#define	QSID(p)		((ulong)(p) >> 8)
#define	QPATH(id, t)	(((id) << 8) | (t))

enum { Rmedia, Rtone, Rnotify, Rspeech, Rcall, Nrole };
static char *rolename[Nrole] = {"media", "tone", "notify", "speech", "call"};

typedef struct Stream Stream;
struct Stream {
	int	id;		/* 0 for #A/audio's */
	int	ref;		/* fids open on it */
	int	dead;		/* ref gone to 0: freed by the mixer once drained */
	int	role;
	int	outms;		/* output queue: 0 wait for room, else keep the newest */
	int	inms;		/* input queue: the newest kept; 0 two seconds */
	Audio_t	fmt;		/* in and out, as audioparse keeps them */

	int	writers;
	Fring	out;
	short	*outb;
	Afmt	outaf;		/* the format outrs was set for */
	Resamp	outrs;
	uchar	part[8];	/* a part frame left by a write */
	int	npart;
	int	gain;		/* where the mixer left its gain */
	int	primed;		/* has had Chunk frames, or its writers have gone */

	int	readers;
	Bring	in;
	uchar	*inb;
	Afmt	inaf;
	Resamp	inrs;

	QLock	wq, rq;
	Rendez	wr, rr;
	Stream	*next;
};

static Lock	alk;
static Stream	*streams;
static int	nextid = 1;
static Audio_t	lav;		/* #A/audio's format: audioctl's */
static int	lrole = Rmedia;
static int	lplayms, lrecms;	/* play_buffer_ms, rec_buffer_ms */
static int	mixing, capturing;	/* the kprocs started */

static QLock	hwlk;
static int	hwopen[2];
static int	hwboth;		/* one ORDWR open serves both (OSS's single open) */
static Chan	hwc[2];
static int	fake;
static Fring	fakeout;
static Bring	fakein;
static int	lastout;	/* osmillisec of the last output written */

static int	audiogen(Chan*, char*, Dirtab*, int, int, Dir*);
static int	ctlsummary(char*, int, Audio_t*);
static int	str2val(svp_t*, char*, ulong*);
static char*	val2str(svp_t*, ulong);
static int	sval(char*, unsigned long*, ulong, ulong);

/*
 * Formats
 */

static int
encof(ulong v)
{
	char *s;

	s = val2str(audio_enc_tbl, v);
	if(s == nil)
		return -1;
	if(strcmp(s, "pcm") == 0)
		return Apcm;
	if(strcmp(s, "ulaw") == 0)
		return Aulaw;
	if(strcmp(s, "alaw") == 0)
		return Aalaw;
	return -1;
}

static void
toafmt(Audio_d *d, Afmt *a)
{
	a->rate = d->rate;
	a->chans = d->chan;
	a->bits = d->bits;
	a->enc = encof(d->enc);
}

static int
afmteq(Afmt *a, Afmt *b)
{
	return a->rate == b->rate && a->chans == b->chans && a->bits == b->bits && a->enc == b->enc;
}

static Audio_t*
fmtof(Stream *s)
{
	return s->id == 0 ? &lav : &s->fmt;
}

/*
 * Streams
 */

static Stream*
newstream(int legacy)
{
	Stream *s;

	s = malloc(sizeof(*s));
	if(s == nil)
		error(Enomem);
	s->outb = malloc(Outcap * 2 * sizeof(short));
	s->inb = malloc(2 * Mixrate * 4);
	if(s->outb == nil || s->inb == nil){
		free(s->outb);
		free(s->inb);
		free(s);
		error(Enomem);
	}
	fringinit(&s->out, s->outb, Outcap);
	bringinit(&s->in, s->inb, 2 * Mixrate * 4);
	s->gain = Gainone;
	s->ref = 1;
	lock(&alk);
	if(legacy){
		s->id = 0;
		s->role = lrole;
		s->outms = lplayms;
		s->inms = lrecms;
	}else{
		s->id = nextid++;
		s->role = Rmedia;
		audio_info_init(&s->fmt);
		s->fmt.in = lav.in;
		s->fmt.out = lav.out;
	}
	s->next = streams;
	streams = s;
	unlock(&alk);
	return s;
}

static Stream*
findstream(int id)
{
	Stream *s;

	for(s = streams; s != nil; s = s->next)
		if(s->id == id && !s->dead)
			return s;
	return nil;
}

/* called with alk held, by the mixer, for a stream that is dead and drained */
static void
freestream(Stream *s)
{
	Stream **l;

	for(l = &streams; *l != nil; l = &(*l)->next)
		if(*l == s){
			*l = s->next;
			break;
		}
	free(s->outb);
	free(s->inb);
	free(s);
}

static void
putstream(Stream *s)
{
	lock(&alk);
	if(--s->ref <= 0){
		s->dead = 1;
		s->readers = 0;
		s->writers = 0;
	}
	unlock(&alk);
}

/*
 * The hardware: the platform's driver, or the fake.
 */

static void	mixproc(void*);
static void	capproc(void*);

static void
hwsetfmt(void)
{
	char *cmd;

	cmd = "rate 48000 chans 2 bits 16 enc pcm";
	audio_ctl_write(nil, cmd, strlen(cmd), 0);
}

static void
hwup(int dir)
{
	int mode;

	if(fake)
		return;
	qlock(&hwlk);
	if(waserror()){
		qunlock(&hwlk);
		nexterror();
	}
	if(!hwopen[dir]){
		if(!hwopen[!dir])
			hwsetfmt();
		if(hwboth)
			hwopen[dir] = 1;
		else{
			mode = dir == Hout ? OWRITE : OREAD;
			hwc[dir].mode = mode;
			if(!waserror()){
				audio_file_open(&hwc[dir], mode);
				poperror();
				hwopen[dir] = 1;
			}else if(hwopen[!dir]){
				/*
				 * A driver that opens once (OSS: Einuse)
				 * serves both ways from one ORDWR open.
				 */
				audio_file_close(&hwc[!dir]);
				hwopen[!dir] = 0;
				hwc[Hout].mode = ORDWR;
				audio_file_open(&hwc[Hout], ORDWR);
				hwboth = 1;
				hwopen[Hout] = hwopen[Hin] = 1;
			}else
				nexterror();
		}
	}
	poperror();
	qunlock(&hwlk);
}

static void
hwdown(int dir)
{
	if(fake)
		return;
	qlock(&hwlk);
	if(hwopen[dir]){
		hwopen[dir] = 0;
		if(hwboth){
			if(!hwopen[!dir]){
				hwboth = 0;
				if(!waserror()){
					audio_file_close(&hwc[Hout]);
					poperror();
				}
			}
		}else if(!waserror()){
			audio_file_close(&hwc[dir]);
			poperror();
		}
	}
	qunlock(&hwlk);
}

/* in a kproc: the driver's errors are reported, not raised */
static int
hwwrite(short *b, int frames)
{
	if(fake){
		lock(&alk);
		fringput(&fakeout, b, frames, 1);
		unlock(&alk);
		return 0;
	}
	if(!hwopen[Hout]){
		if(waserror())
			return -1;
		hwup(Hout);
		poperror();
	}
	if(waserror())
		return -1;
	audio_file_write(&hwc[Hout], b, frames * 2 * sizeof(short), 0);
	poperror();
	return 0;
}

static long
hwread(uchar *b, long n)
{
	long got;

	if(fake){
		/* the microphone, at its pace: what fakein holds, then silence */
		osmillisleep(Chunk * 1000 / Mixrate);
		lock(&alk);
		got = bringget(&fakein, b, n);
		unlock(&alk);
		if(got < n)
			memset(b + got, 0, n - got);
		return n;
	}
	if(waserror())
		return -1;
	got = audio_file_read(hwboth ? &hwc[Hout] : &hwc[Hin], b, n, 0);
	poperror();
	return got;
}

static void
startprocs(int dir)
{
	int start;

	lock(&alk);
	if(dir == Hout){
		start = !mixing;
		mixing = 1;
	}else{
		start = !capturing;
		capturing = 1;
	}
	unlock(&alk);
	if(start)
		kproc(dir == Hout ? "audiomix" : "audiocap", dir == Hout ? mixproc : capproc, nil, 0);
}

/*
 * Writing: a client's bytes, converted, into its stream's queue.
 */

static int
hasroom(void *a)
{
	Stream *s;

	s = a;
	return s->dead || s->out.cap - s->out.len >= Chunk;
}

static long
streamwrite(Stream *s, uchar *va, long n)
{
	static short dec[2*(Maxin+2)];	/* guarded by alk */
	static short res[2*(Maxin+2)*(Mixrate/8000+1)+8];
	static uchar join[Maxin*4+8];
	Afmt af;
	Audio_t *f;
	long done;
	int fb, room, want, nb, nf, m, drop, cap;

	qlock(&s->wq);
	if(waserror()){
		qunlock(&s->wq);
		nexterror();
	}
	done = 0;
	while(done < n){
		lock(&alk);
		f = fmtof(s);
		toafmt(&f->out, &af);
		if(!afmtok(&af)){
			unlock(&alk);
			error("audio: this stream's output format cannot be played");
		}
		if(!afmteq(&af, &s->outaf)){
			s->outaf = af;
			resampinit(&s->outrs, af.rate, Mixrate);
			s->npart = 0;
		}
		fb = afmtbytes(&af);
		drop = s->outms > 0;
		room = s->out.cap - s->out.len;
		if(!drop && room < Chunk){
			unlock(&alk);
			Sleep(&s->wr, hasroom, s);
			continue;
		}
		/* input frames whose output fits */
		want = Maxin;
		if(!drop){
			nf = (vlong)(room - 4) * af.rate / Mixrate;
			if(nf < want)
				want = nf;
			if(want < 1)
				want = 1;
		}
		/* this write's bytes taken, after a part frame a last write left */
		nb = want * fb - s->npart;
		if(nb < fb)
			nb = fb;
		if(nb > n - done)
			nb = n - done;
		memmove(join, s->part, s->npart);
		memmove(join + s->npart, va + done, nb);
		done += nb;
		nb += s->npart;
		nf = decodepcm(&af, join, nb, dec);
		s->npart = nb - nf * fb;
		memmove(s->part, join + nf * fb, s->npart);
		m = resample(&s->outrs, dec, nf, res);
		fringput(&s->out, res, m, drop);
		if(drop){
			cap = s->outms * (vlong)Mixrate / 1000;
			if(cap > 0 && s->out.len > cap){
				s->out.head = (s->out.head + s->out.len - cap) % s->out.cap;
				s->out.len = cap;
			}
		}
		unlock(&alk);
	}
	poperror();
	qunlock(&s->wq);
	return n;
}

/*
 * Reading: the microphone, in the stream's format.
 */

static int
hasdata(void *a)
{
	Stream *s;

	s = a;
	return s->dead || s->in.len > 0;
}

static long
streamread(Stream *s, uchar *va, long n)
{
	long got;
	int fb;

	qlock(&s->rq);
	if(waserror()){
		qunlock(&s->rq);
		nexterror();
	}
	for(;;){
		lock(&alk);
		if(s->in.len > 0){
			fb = s->inaf.chans > 0 ? afmtbytes(&s->inaf) : 1;
			if(n >= fb)
				n -= n % fb;
			got = bringget(&s->in, va, n);
			unlock(&alk);
			break;
		}
		unlock(&alk);
		Sleep(&s->rr, hasdata, s);
	}
	poperror();
	qunlock(&s->rq);
	return got;
}

/*
 * The mixer: every Chunk, what each stream has, summed, to the speaker.
 */

static int
duckgain(int role, int loudest)
{
	switch(role){
	case Rmedia:
		return loudest > Rtone ? Gainone / 4 : Gainone;
	case Rspeech:
		return loudest == Rcall ? Gainone * 35 / 100 : Gainone;
	}
	return Gainone;
}

static int
volgain(Stream *s)
{
	Audio_d *d;

	d = &fmtof(s)->out;
	return Gainone * (int)(d->left + d->right) / (2 * Audio_Max_Val);
}

static void
mixproc(void *a)
{
	static int acc[2*Chunk];
	static short buf[2*Chunk], mix[2*Chunk];
	Stream *s, *next, *wake[64];
	int nwake, any, loudest, k, g, i, writers, t0, played, now, ahead;

	USED(a);
	t0 = osmillisec();
	played = 0;
	for(;;){
		now = osmillisec();
		ahead = played * 1000 / Mixrate - (now - t0);
		if(ahead > Leadms){
			osmillisleep(ahead - Leadms);
			continue;
		}
		if(ahead < -Leadms){
			/* behind (nothing was playing): start the clock again */
			t0 = now;
			played = 0;
		}
		lock(&alk);
		any = 0;
		writers = 0;
		loudest = -1;
		for(s = streams; s != nil; s = s->next){
			if(s->writers > 0)
				writers++;
			if(s->out.len >= Chunk || (s->out.len > 0 && s->writers == 0))
				s->primed = 1;
			if(s->primed && s->out.len > 0 && s->role > loudest)
				loudest = s->role;
		}
		memset(acc, 0, sizeof acc);
		nwake = 0;
		for(s = streams; s != nil; s = next){
			next = s->next;
			if(s->primed && s->out.len > 0){
				k = fringget(&s->out, buf, Chunk);
				g = duckgain(s->role, loudest) * volgain(s) / Gainone;
				mixadd(acc, buf, k, s->gain, g);
				s->gain = g;
				any = 1;
				if(s->out.len == 0)
					s->primed = 0;
				if(nwake < nelem(wake) && !s->dead)
					wake[nwake++] = s;
			}
			if(s->dead && s->out.len == 0)
				freestream(s);
		}
		unlock(&alk);
		for(i = 0; i < nwake; i++)
			Wakeup(&wake[i]->wr);	/* a dead stream is freed only here, so these live */
		if(any){
			mixclip(acc, mix, Chunk);
			if(hwwrite(mix, Chunk) < 0){
				print("audio: the speaker would not play; its output dropped\n");
				osmillisleep(500);
			}
			played += Chunk;
			lastout = osmillisec();
			continue;
		}
		if(writers == 0 && hwopen[Hout] && osmillisec() - lastout > Idlems)
			hwdown(Hout);
		osmillisleep(Chunk * 1000 / Mixrate);
		t0 = osmillisec();
		played = 0;
	}
}

/*
 * The microphone: read once, given to every stream reading it.
 */

static void
capproc(void *a)
{
	static uchar raw[Chunk*4+4], enc[(Chunk+4)*4];
	static short frames[2*(Chunk+1)], conv[2*(Chunk+8)];
	static Afmt hw = {Mixrate, 2, 16, Apcm};
	Stream *s, *wake[64];
	Afmt af;
	int nwake, readers, nraw, nf, m, nb, cap, i, warned;
	long got;

	USED(a);
	nraw = 0;
	warned = 0;
	for(;;){
		lock(&alk);
		readers = 0;
		for(s = streams; s != nil; s = s->next)
			if(s->readers > 0)
				readers++;
		unlock(&alk);
		if(readers == 0){
			if(hwopen[Hin])
				hwdown(Hin);
			nraw = 0;
			osmillisleep(20);
			continue;
		}
		if(!fake && !hwopen[Hin]){
			if(waserror()){
				if(!warned)
					print("audio: the microphone would not open\n");
				warned = 1;
				osmillisleep(500);
				continue;
			}
			hwup(Hin);
			poperror();
		}
		got = hwread(raw + nraw, Chunk*4);
		if(got <= 0){
			osmillisleep(10);
			continue;
		}
		nraw += got;
		nf = decodepcm(&hw, raw, nraw, frames);
		nraw -= nf * 4;
		memmove(raw, raw + nf * 4, nraw);

		lock(&alk);
		nwake = 0;
		for(s = streams; s != nil; s = s->next){
			if(s->readers <= 0 || s->dead)
				continue;
			toafmt(&fmtof(s)->in, &af);
			if(!afmtok(&af))
				continue;
			if(!afmteq(&af, &s->inaf)){
				s->inaf = af;
				resampinit(&s->inrs, Mixrate, af.rate);
			}
			m = resample(&s->inrs, frames, nf, conv);
			nb = encodepcm(&af, conv, m, enc);
			bringput(&s->in, enc, nb, 1);
			cap = (s->id == 0 ? lrecms : s->inms) * (vlong)af.rate / 1000 * afmtbytes(&af);
			if(cap > 0 && s->in.len > cap){
				s->in.head = (s->in.head + s->in.len - cap) % s->in.cap;
				s->in.len = cap;
			}
			if(nwake < nelem(wake))
				wake[nwake++] = s;
		}
		unlock(&alk);
		for(i = 0; i < nwake; i++)
			Wakeup(&wake[i]->rr);
	}
}

/*
 * The device
 */

static void
audioinit(void)
{
	char *e;

	audio_file_init();
	audio_info_init(&lav);
	e = getenv("INFERNODE_AUDIO_FAKE");	/* Flawfinder: ignore -- the user's own setting, for tests; only its presence is used */
	if(e != nil && *e != 0){
		fake = 1;
		fringinit(&fakeout, malloc(Fakecap * 2 * sizeof(short)), Fakecap);
		bringinit(&fakein, malloc(Fakecap * 4), Fakecap * 4);
		if(fakeout.b == nil || fakein.b == nil)
			panic("audio: no memory for the fake");
	}
}

static Chan*
audioattach(char *spec)
{
	Chan *c;

	c = devattach('A', spec);
	c->qid.path = Qdir;
	c->qid.type = QTDIR;
	return c;
}

static int
audiogen(Chan *c, char *name, Dirtab *tab, int ntab, int i, Dir *dp)
{
	Qid q;
	Stream *s;
	int n, id;

	USED(name); USED(tab); USED(ntab);
	switch(QTYPE(c->qid.path)){
	case Qsdir:
		if(i == DEVDOTDOT){
			mkqid(&q, Qmix, 0, QTDIR);
			devdir(c, q, "mix", 0, eve, 0555, dp);
			return 1;
		}
		id = QSID(c->qid.path);
		switch(i){
		case 0:
			mkqid(&q, QPATH(id, Qsdata), 0, QTFILE);
			devdir(c, q, "data", 0, eve, 0666, dp);
			return 1;
		case 1:
			mkqid(&q, QPATH(id, Qsctl), 0, QTFILE);
			devdir(c, q, "ctl", 0, eve, 0666, dp);
			return 1;
		}
		return -1;
	case Qmix:
		if(i == DEVDOTDOT)
			break;
		if(i == 0){
			mkqid(&q, Qnew, 0, QTFILE);
			devdir(c, q, "new", 0, eve, 0444, dp);
			return 1;
		}
		i--;
		lock(&alk);
		n = 0;
		for(s = streams; s != nil; s = s->next){
			if(s->id == 0 || s->dead)
				continue;
			if(n++ == i)
				break;
		}
		if(s == nil){
			unlock(&alk);
			return -1;
		}
		id = s->id;
		unlock(&alk);
		snprint(up->genbuf, sizeof up->genbuf, "%d", id);
		mkqid(&q, QPATH(id, Qsdir), 0, QTDIR);
		devdir(c, q, up->genbuf, 0, eve, 0555, dp);
		return 1;
	}
	if(i == DEVDOTDOT){
		mkqid(&q, Qdir, 0, QTDIR);
		devdir(c, q, "#A", 0, eve, 0555, dp);
		return 1;
	}
	switch(i){
	case 0:
		mkqid(&q, Qaudio, 0, QTFILE);
		devdir(c, q, "audio", 0, eve, 0666, dp);
		return 1;
	case 1:
		mkqid(&q, Qaudioctl, 0, QTFILE);
		devdir(c, q, "audioctl", 0, eve, 0666, dp);
		return 1;
	case 2:
		mkqid(&q, Qmix, 0, QTDIR);
		devdir(c, q, "mix", 0, eve, 0555, dp);
		return 1;
	}
	if(fake){
		switch(i){
		case 3:
			mkqid(&q, Qfakein, 0, QTFILE);
			devdir(c, q, "fakein", 0, eve, 0222, dp);
			return 1;
		case 4:
			mkqid(&q, Qfakeout, 0, QTFILE);
			devdir(c, q, "fakeout", 0, eve, 0444, dp);
			return 1;
		}
	}
	return -1;
}

static Walkqid*
audiowalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, nil, 0, audiogen);
}

static int
audiostat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, nil, 0, audiogen);
}

static Stream*
openstream(Chan *c)
{
	Stream *s;

	lock(&alk);
	s = findstream(QSID(c->qid.path));
	if(s != nil)
		s->ref++;
	unlock(&alk);
	if(s == nil)
		error(Enonexist);
	return s;
}

/* the directions a data open of s takes, the hardware brought up for each */
static void
startdirs(Stream *s, int omode)
{
	int r, w;

	r = omode == OREAD || omode == ORDWR;
	w = omode == OWRITE || omode == ORDWR;
	if(w){
		hwup(Hout);
		startprocs(Hout);
	}
	if(r){
		hwup(Hin);
		startprocs(Hin);
	}
	lock(&alk);
	if(w)
		s->writers++;
	if(r)
		s->readers++;
	unlock(&alk);
}

static Chan*
audioopen(Chan *c, int omode)
{
	Stream *s;

	omode = openmode(omode);
	switch(QTYPE(c->qid.path)){
	case Qdir:
	case Qmix:
	case Qsdir:
		if(omode != OREAD)
			error(Eperm);
		break;
	case Qaudioctl:
	case Qsctl:
	case Qfakein:
	case Qfakeout:
		break;
	case Qnew:
		s = newstream(0);
		c->aux = s;
		mkqid(&c->qid, QPATH(s->id, Qsctl), 0, QTFILE);
		startprocs(Hout);
		break;
	case Qaudio:
		s = newstream(1);
		if(waserror()){
			putstream(s);
			nexterror();
		}
		startprocs(Hout);	/* the mixer is what frees streams */
		startdirs(s, omode);
		poperror();
		c->aux = s;
		break;
	case Qsdata:
		s = openstream(c);
		if(waserror()){
			putstream(s);
			nexterror();
		}
		startdirs(s, omode);
		poperror();
		c->aux = s;
		break;
	default:
		error(Egreg);
	}
	if(QTYPE(c->qid.path) == Qsctl && c->aux == nil)
		c->aux = openstream(c);
	c->mode = omode;
	c->flag |= COPEN;
	c->offset = 0;
	return c;
}

static void
audioclose(Chan *c)
{
	Stream *s;

	if((c->flag & COPEN) == 0)
		return;
	s = c->aux;
	if(s == nil)
		return;
	if(QTYPE(c->qid.path) == Qaudio || QTYPE(c->qid.path) == Qsdata){
		lock(&alk);
		if(c->mode == OWRITE || c->mode == ORDWR)
			s->writers--;
		if(c->mode == OREAD || c->mode == ORDWR)
			s->readers--;
		unlock(&alk);
	}
	putstream(s);	/* s may be freed by the mixer from here on */
}

static long
streamctlread(Stream *s, void *va, long n, vlong off)
{
	char *buf, *p, *e;
	Audio_t f;
	int id, role, outms, inms, queued;

	lock(&alk);
	id = s->id;
	role = s->role;
	outms = s->outms;
	inms = s->inms;
	f = *fmtof(s);
	queued = s->out.len * 1000 / Mixrate;
	unlock(&alk);
	buf = smalloc(READSTR);
	if(waserror()){
		free(buf);
		nexterror();
	}
	p = buf;
	e = buf + READSTR;
	p = seprint(p, e, "%d\n", id);
	p = seprint(p, e, "role %s\n", rolename[role]);
	p = seprint(p, e, "out queue %d\nin queue %d\n", outms, inms);
	p = seprint(p, e, "out rate %lud chans %lud bits %lud enc %s\n",
		f.out.rate, f.out.chan, f.out.bits, val2str(audio_enc_tbl, f.out.enc));
	p = seprint(p, e, "in rate %lud chans %lud bits %lud enc %s\n",
		f.in.rate, f.in.chan, f.in.bits, val2str(audio_enc_tbl, f.in.enc));
	p = seprint(p, e, "queued %d\n", queued);
	n = readstr(off, va, n, buf);
	poperror();
	free(buf);
	return n;
}

static long
audioread(Chan *c, void *va, long n, vlong off)
{
	char *buf;
	int k;
	long got;

	if(c->qid.type & QTDIR)
		return devdirread(c, va, n, nil, 0, audiogen);
	switch(QTYPE(c->qid.path)){
	case Qaudio:
	case Qsdata:
		return streamread(c->aux, va, n);
	case Qsctl:
		return streamctlread(c->aux, va, n, off);
	case Qaudioctl:
		buf = smalloc(READSTR);
		if(waserror()){
			free(buf);
			nexterror();
		}
		lock(&alk);
		k = ctlsummary(buf, READSTR, &lav);
		unlock(&alk);
		n = readstr(off, va, n, buf);
		USED(k);
		poperror();
		free(buf);
		return n;
	case Qfakeout:
		lock(&alk);
		got = fringget(&fakeout, va, n / 4);
		unlock(&alk);
		return got * 4;
	}
	error(Egreg);
	return 0;
}

static int
rolenum(char *s)
{
	int i;

	for(i = 0; i < Nrole; i++)
		if(strcmp(s, rolename[i]) == 0)
			return i;
	return -1;
}

/*
 * A ctl line: role, queues and the buffer caps taken out, the rest a
 * format for audioparse.  Applied whole or not at all.
 */
static void
ctlwrite(Stream *s, char *va, long n)
{
	Cmdbuf *cb;
	Audio_t t;
	Afmt in, out;
	char rest[256], *p, *e;
	int i, role, outms, inms, nrest, v, flushin, flushout;
	ulong tf;

	flushin = flushout = 0;
	cb = parsecmd(va, n);
	if(waserror()){
		free(cb);
		nexterror();
	}
	lock(&alk);
	t = s != nil ? *fmtof(s) : lav;
	role = s != nil ? s->role : lrole;
	outms = s != nil ? s->outms : lplayms;
	inms = s != nil ? s->inms : lrecms;
	unlock(&alk);
	p = rest;
	e = rest + sizeof rest;
	nrest = 0;
	tf = 0;		/* in, out or both, for the rest of the line (as audioparse) */
	for(i = 0; i < cb->nf; i++){
		if(strcmp(cb->f[i], "in") == 0 || strcmp(cb->f[i], "out") == 0){
			tf |= cb->f[i][0] == 'i' ? AUDIO_IN_FLAG : AUDIO_OUT_FLAG;
			p = seprint(p, e, "%s ", cb->f[i]);
			continue;
		}
		if(s != nil && strcmp(cb->f[i], "flush") == 0){
			/* drop what is queued and not yet played (or read): a
			 * cancel; a close plays its queue to the end instead */
			if(tf == 0 || (tf & AUDIO_OUT_FLAG))
				flushout = 1;
			if(tf == 0 || (tf & AUDIO_IN_FLAG))
				flushin = 1;
			continue;
		}
		if(i + 1 < cb->nf && strcmp(cb->f[i], "role") == 0){
			if((role = rolenum(cb->f[++i])) < 0)
				error("audio: role is media, tone, notify, speech or call");
			continue;
		}
		if(i + 1 < cb->nf && (strcmp(cb->f[i], "queue") == 0 ||
		   s == nil && (strcmp(cb->f[i], "play_buffer_ms") == 0 || strcmp(cb->f[i], "rec_buffer_ms") == 0))){
			v = atoi(cb->f[i+1]);
			if(v < 0 || v > 2000)
				error("audio: a queue is 0 to 2000 ms");
			if(strcmp(cb->f[i], "play_buffer_ms") == 0)
				outms = v;
			else if(strcmp(cb->f[i], "rec_buffer_ms") == 0)
				inms = v;
			else{
				if(tf == 0 || (tf & AUDIO_OUT_FLAG))
					outms = v;
				if(tf == 0 || (tf & AUDIO_IN_FLAG))
					inms = v;
			}
			i++;
			continue;
		}
		p = seprint(p, e, "%s ", cb->f[i]);
		nrest++;
	}
	if(nrest > 0 && !audioparse(rest, p - rest, &t))
		error(Ebadarg);
	toafmt(&t.in, &in);
	toafmt(&t.out, &out);
	if(!afmtok(&in) || !afmtok(&out))
		error("audio: no such format (rate 8000 to 48000, chans 1 or 2, bits 8 or 16)");
	lock(&alk);
	if(s != nil){
		s->fmt = t;
		s->role = role;
		s->outms = outms;
		s->inms = inms;
		if(flushout){
			s->out.len = 0;
			s->npart = 0;
			s->primed = 0;
		}
		if(flushin)
			s->in.len = 0;
	}else{
		lav = t;
		lrole = role;
		lplayms = outms;
		lrecms = inms;
		/* #A/audio's streams follow audioctl, as the device did */
		for(s = streams; s != nil; s = s->next)
			if(s->id == 0){
				s->role = role;
				s->outms = outms;
				s->inms = inms;
			}
	}
	unlock(&alk);
	poperror();
	free(cb);
	if(flushout)
		Wakeup(&s->wr);	/* a writer waiting for room has it */
}

static long
audiowrite(Chan *c, void *va, long n, vlong off)
{
	USED(off);
	switch(QTYPE(c->qid.path)){
	case Qaudio:
	case Qsdata:
		return streamwrite(c->aux, va, n);
	case Qaudioctl:
		ctlwrite(nil, va, n);
		return n;
	case Qsctl:
		ctlwrite(c->aux, va, n);
		return n;
	case Qfakein:
		lock(&alk);
		bringput(&fakein, va, n, 1);
		unlock(&alk);
		return n;
	}
	error(Egreg);
	return 0;
}

int
audioparse(char* args, int len, Audio_t *t)
{
	int i, n;
	ulong v;
	Cmdbuf *cb;
	ulong tf;
	Audio_t info = *t;

	cb = parsecmd(args, len);
	if(waserror()){
		free(cb);
		return 0;
	}

	tf = 0;
	n = cb->nf;
	for(i = 0; i < cb->nf-1; i++) {
		if(strcmp(cb->f[i], "in") == 0){
			tf |= AUDIO_IN_FLAG;
			continue;
		}
		if(strcmp(cb->f[i], "out") == 0) {
			tf |= AUDIO_OUT_FLAG;
			continue;
		}
		if(tf == 0)
			tf = AUDIO_IN_FLAG | AUDIO_OUT_FLAG;
		if(strcmp(cb->f[i], "bits") == 0) {
			if(!str2val(audio_bits_tbl, cb->f[i+1], &v))
				break;
			i++;
			if(tf & AUDIO_IN_FLAG) {
				info.in.flags |= AUDIO_BITS_FLAG | AUDIO_MOD_FLAG;
				info.in.bits = v;
			}
			if(tf & AUDIO_OUT_FLAG) {
				info.out.flags |= AUDIO_BITS_FLAG | AUDIO_MOD_FLAG;
				info.out.bits = v;
			}
		} else if(strcmp(cb->f[i], "buf") == 0) {
			if(!sval(cb->f[i+1], &v, Audio_Max_Val, Audio_Min_Val))
				break;
			i++;
			if(tf & AUDIO_IN_FLAG) {
				info.in.flags |= AUDIO_BUF_FLAG | AUDIO_MOD_FLAG;
				info.in.buf = v;
			}
			if(tf & AUDIO_OUT_FLAG) {
				info.out.flags |= AUDIO_BUF_FLAG | AUDIO_MOD_FLAG;
				info.out.buf = v;
			}
		} else if(strcmp(cb->f[i], "chans") == 0) {
			if(!str2val(audio_chan_tbl, cb->f[i+1], &v))
				break;
			i++;
			if(tf & AUDIO_IN_FLAG) {
				info.in.flags |= AUDIO_CHAN_FLAG | AUDIO_MOD_FLAG;
				info.in.chan = v;
			}
			if(tf & AUDIO_OUT_FLAG) {
				info.out.flags |= AUDIO_CHAN_FLAG | AUDIO_MOD_FLAG;
				info.out.chan = v;
			}
		} else if(strcmp(cb->f[i], "indev") == 0) {
			if(!str2val(audio_indev_tbl, cb->f[i+1], &v))
				break;
			i++;
			info.in.flags |= AUDIO_DEV_FLAG | AUDIO_MOD_FLAG;
			info.in.dev = v;
		} else if(strcmp(cb->f[i], "outdev") == 0) {
			if(!str2val(audio_outdev_tbl, cb->f[i+1], &v))
				break;
			i++;
			info.out.flags |= AUDIO_DEV_FLAG | AUDIO_MOD_FLAG;
			info.out.dev = v;
		} else if(strcmp(cb->f[i], "enc") == 0) {
			if(!str2val(audio_enc_tbl, cb->f[i+1], &v))
				break;
			i++;
			if(tf & AUDIO_IN_FLAG) {
				info.in.flags |= AUDIO_ENC_FLAG | AUDIO_MOD_FLAG;
				info.in.enc = v;
			}
			if(tf & AUDIO_OUT_FLAG) {
				info.out.flags |= AUDIO_ENC_FLAG | AUDIO_MOD_FLAG;
				info.out.enc = v;
			}
		} else if(strcmp(cb->f[i], "rate") == 0) {
			if(!str2val(audio_rate_tbl, cb->f[i+1], &v))
				break;
			i++;
			if(tf & AUDIO_IN_FLAG) {
				info.in.flags |= AUDIO_RATE_FLAG | AUDIO_MOD_FLAG;
				info.in.rate = v;
			}
			if(tf & AUDIO_OUT_FLAG) {
				info.out.flags |= AUDIO_RATE_FLAG | AUDIO_MOD_FLAG;
				info.out.rate = v;
			}
		} else if(strcmp(cb->f[i], "vol") == 0) {
			if(!sval(cb->f[i+1], &v, Audio_Max_Val, Audio_Min_Val))
				break;
			i++;
			if(tf & AUDIO_IN_FLAG) {
				info.in.flags |= AUDIO_VOL_FLAG | AUDIO_MOD_FLAG;
				info.in.left = v;
				info.in.right = v;
			}
			if(tf & AUDIO_OUT_FLAG) {
				info.out.flags |= AUDIO_VOL_FLAG | AUDIO_MOD_FLAG;
				info.out.left = v;
				info.out.right = v;
			}
		} else if(strcmp(cb->f[i], "left") == 0) {
			if(!sval(cb->f[i+1], &v, Audio_Max_Val, Audio_Min_Val))
				break;
			i++;
			if(tf & AUDIO_IN_FLAG) {
				info.in.flags |= AUDIO_LEFT_FLAG | AUDIO_MOD_FLAG;
				info.in.left = v;
			}
			if(tf & AUDIO_OUT_FLAG) {
				info.out.flags |= AUDIO_LEFT_FLAG | AUDIO_MOD_FLAG;
				info.out.left = v;
			}
		} else if(strcmp(cb->f[i], "right") == 0) {
			if(!sval(cb->f[i+1], &v, Audio_Max_Val, Audio_Min_Val))
				break;
			i++;
			if(tf & AUDIO_IN_FLAG) {
				info.in.flags |= AUDIO_RIGHT_FLAG | AUDIO_MOD_FLAG;
				info.in.right = v;
			}
			if(tf & AUDIO_OUT_FLAG) {
				info.out.flags |= AUDIO_RIGHT_FLAG | AUDIO_MOD_FLAG;
				info.out.right = v;
			}
		}else
			break;
	}
	poperror();
	free(cb);

	if(i < n)
		return 0;

	*t = info;	/* set information back */
	return 1;
}

static char*
audioparam(char* p, char* e, char* name, int val, svp_t* tbl)
{
	char *s;
	svp_t *sv;

	if((s = val2str(tbl, val)) != nil){
		p = seprint(p, e, "%s %s", name, s);	/* current setting */
		for(sv = tbl; sv->s != nil; sv++)
			if(sv->v != val)
				p = seprint(p, e, " %s", sv->s);	/* other possible values */
		p = seprint(p, e, "\n");
	}else
		p = seprint(p, e, "%s unknown\n", name);
	return p;
}

static char*
audioioparam(char* p, char* e, char* name, int ival, int oval, svp_t* tbl)
{
	if(ival == oval)
		return audioparam(p, e, name, ival, tbl);
	p = audioparam(seprint(p, e, "in "), e, name, ival, tbl);
	p = audioparam(seprint(p, e, "out "), e, name, oval, tbl);
	return p;
}

static int
ctlsummary(char *buf, int bsize, Audio_t *adev)
{
	Audio_d *in, *out;
	char	*p, *e;

	in = &adev->in;
	out = &adev->out;

	p = buf;
	e = p + bsize;

	p = audioparam(p, e, "indev", in->dev, audio_indev_tbl);
	p = audioparam(p, e, "outdev", out->dev, audio_outdev_tbl);
	p = audioioparam(p, e, "enc", in->enc, out->enc, audio_enc_tbl);
	p = audioioparam(p, e, "rate", in->rate, out->rate, audio_rate_tbl);
	p = audioioparam(p, e, "bits", in->bits, out->bits, audio_bits_tbl);	/* this one is silly */
	p = audioioparam(p, e, "chans", in->chan, out->chan, audio_chan_tbl);
	/* TO DO: minimise in/out left/right where possible */
	if(in->left != in->right){
		p = seprint(p, e, "in left %d 0 100\n", in->left);
		p = seprint(p, e, "in right %d 0 100\n", in->right);
	}else
		p = seprint(p, e, "in %d 0 100\n", in->right);
	if(out->left != out->right){
		p = seprint(p, e, "out left %d 0 100\n", out->left);
		p = seprint(p, e, "out right %d 0 100\n", out->right);
	}else
		p = seprint(p, e, "out %d 0 100\n", out->right);
	p = seprint(p, e, "in buf %d %d %d\n", in->buf, Audio_Min_Val, Audio_Max_Val);
	p = seprint(p, e, "out buf %d %d %d\n", out->buf, Audio_Min_Val, Audio_Max_Val);

	return p-buf;
}

void
audio_info_init(Audio_t *t)
{
	t->in = Default_Audio_Format;
	t->in.dev = Default_Audio_Input;
	t->out = Default_Audio_Format;
	t->out.dev = Default_Audio_Output;
}

static int
str2val(svp_t* t, char* s, ulong *v)
{
	if(t == nil || s == nil)
		return 0;
	for(; t->s != nil; t++) {
		if(strncmp(t->s, s, strlen(t->s)) == 0) {
			*v = t->v;
			return 1;
		}
	}
	return 0;
}

static char*
val2str(svp_t* t, ulong v)
{
	if(t == nil)
		return nil;
	for(; t->s != nil; t++)
		if(t->v == v)
			return t->s;
	return nil;
}

static int
sval(char* buf, ulong* v, ulong max, ulong min)
{
	unsigned long val = strtoul(buf, 0, 10);

	if(val > max || val < min)
		return 0;
	*v = val;
	return 1;
}

Dev audiodevtab = {
        'A',
        "audio",

        audioinit,
        audioattach,
        audiowalk,
        audiostat,
        audioopen,
        devcreate,
        audioclose,
        audioread,
        devbread,
        audiowrite,
        devbwrite,
        devremove,
        devwstat
};

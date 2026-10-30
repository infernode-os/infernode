/*
 * #V -- a camera, as files (infernode-os/infernode#1005).
 *
 *	camera/ctl	the state, one setting per line:
 *				source test
 *				mode 640 480
 *				fps 30
 *				stream off
 *				raw rggb10	(read only: what raw holds)
 *				frames 0	(read only: frames since stream on)
 *			written one setting at a time, as read: "source
 *			NAME", "mode W H", "fps N", "stream on|off". The
 *			first three are refused while streaming. A mode
 *			whose maximum is below fps lowers fps to it.
 *	camera/modes	what can be asked for, one per line:
 *				source width height maxfps rawformat
 *	camera/frame	an open waits for the next frame and holds it;
 *			reads return it as an uncompressed image(6),
 *			r8g8b8; end of file at its end. The next frame is
 *			the next open. Refused unless streaming.
 *	camera/raw	the same, as the sensor gave it: a sample a pixel,
 *			16 bits little-endian, row by row, no header. Its
 *			geometry and Bayer order are ctl's, as /dev/audio's
 *			format is audioctl's.
 *
 * Bound after /dev at boot, as #A is: /dev/camera/frame.
 *
 * WHERE THE FRAMES COME FROM is a source (camera.h): the simulated
 * sensor (campattern.c) on every machine; a real camera's driver adds
 * itself beside it. A source gives raw Bayer samples and nothing else,
 * because that is all a Pi's camera receiver gives: the SoC's ISP,
 * which would do the rest in hardware, is reachable only through the
 * VideoCore firmware. So the debayering is here, in software, for
 * every source alike.
 *
 * ONE FRAME AN OPEN. An open takes the next frame complete after it --
 * never one already handed out, never a stale one -- and keeps its own
 * copy, so a reader of any speed reads a whole, consistent picture with
 * cat or 8 KB at a time, and successive opens are successive frames.
 * The frame is taken in open rather than in the first read so that an
 * error (not streaming, interrupted) is the open's.
 *
 * WHAT IS NOT HERE: exposure, white balance and focus, which come with
 * a real sensor as more ctl lines; compression; and any source but the
 * test pattern.
 *
 * One camera. A second (a Compute Module's second CSI port) is
 * #V/camera1 when there is one.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"../port/camera.h"

enum {
	Qroot,
	Qcam,
	Qctl,
	Qmodes,
	Qframe,
	Qraw,

	Nsrc	= 4,
	Defps	= 30,
	Hdrlen	= 5*12,		/* image(6): five fields of 11 characters and a blank */
};

static Dirtab camtab[] = {
	"ctl",		{Qctl},		0,	0664,
	"modes",	{Qmodes},	0,	0444,
	"frame",	{Qframe},	0,	0444,
	"raw",		{Qraw},		0,	0444,
};

enum {
	CMsource,
	CMmode,
	CMfps,
	CMstream,
};

static Cmdtab camcmd[] = {
	CMsource,	"source",	2,
	CMmode,		"mode",		3,
	CMfps,		"fps",		2,
	CMstream,	"stream",	2,
};

typedef struct Shot Shot;
struct Shot
{
	uchar	*data;
	long	len;
};

static struct {
	QLock	lk;
	Camsrc	*srcs[Nsrc];
	int	nsrc;
	Camsrc	*src;
	Cammode	*mode;
	int	fps;
	int	on;
} cam;

void
addcamsrc(Camsrc *s)
{
	if(cam.nsrc == Nsrc)
		panic("addcamsrc: more than %d sources", Nsrc);
	cam.srcs[cam.nsrc++] = s;
}

static void
usesrc(Camsrc *s)
{
	cam.src = s;
	cam.mode = &s->modes[s->defmode];
	cam.fps = cam.mode->maxfps < Defps? cam.mode->maxfps: Defps;
}

/*
 * In init, not reset: this kernel calls a few devices' resets by name
 * (os/arm64/main.c) and every device's init, and nothing here needs
 * doing before there are processes.
 */
static void
caminit(void)
{
	addcamsrc(&campattern);
	usesrc(cam.srcs[0]);
}

/*
 * A sample of the frame, with the frame reflected at its edges. A
 * reflection keeps the colour filter's pattern (-1 is odd, as 1 is;
 * w is even, as w-2 is), so a pixel at the edge is interpolated from
 * neighbours of the right colours, as one in the middle is.
 */
static int
sample(ushort *raw, int w, int h, int x, int y)
{
	if(x < 0)
		x = 1;
	else if(x >= w)
		x = w-2;
	if(y < 0)
		y = 1;
	else if(y >= h)
		y = h-2;
	return raw[y*w + x];
}

/*
 * Raw Bayer samples to r8g8b8 (blue, green, red in each three bytes):
 * bilinear. At each pixel the channel its filter passed is kept, and
 * each other one is the mean of its nearest samples of that colour --
 * the four across or the four diagonal for the far colour at a red or
 * blue site, the two in its row or column at a green one.
 */
static void
debayer(ushort *raw, int w, int h, char *bayer, int bits, uchar *out)
{
	int x, y, rx, ry, site, c, cross, diag, row, col, shift;
	int r, g, b;
	char *red;

	red = strchr(bayer, 'r');
	rx = (red - bayer) & 1;		/* where red is in the 2x2 cell */
	ry = (red - bayer) >> 1;
	shift = bits - 8;
	for(y = 0; y < h; y++)
		for(x = 0; x < w; x++){
			c = raw[y*w + x];
			site = ((y ^ ry) & 1) << 1 | ((x ^ rx) & 1);
			row = sample(raw, w, h, x-1, y) + sample(raw, w, h, x+1, y);
			col = sample(raw, w, h, x, y-1) + sample(raw, w, h, x, y+1);
			switch(site){
			case 0:		/* red */
			case 3:		/* blue */
				cross = (row + col) / 4;
				diag = (sample(raw, w, h, x-1, y-1) + sample(raw, w, h, x+1, y-1)
					+ sample(raw, w, h, x-1, y+1) + sample(raw, w, h, x+1, y+1)) / 4;
				g = cross;
				if(site == 0){
					r = c;
					b = diag;
				}else{
					r = diag;
					b = c;
				}
				break;
			case 1:		/* green, in a row with red */
				r = row / 2;
				g = c;
				b = col / 2;
				break;
			default:	/* green, in a row with blue */
				r = col / 2;
				g = c;
				b = row / 2;
				break;
			}
			*out++ = b >> shift;
			*out++ = g >> shift;
			*out++ = r >> shift;
		}
}

/*
 * The next frame, for one open of frame or raw.
 */
static Shot*
shoot(int path)
{
	Shot *s;
	ushort *raw;
	uchar *p;
	long n, i;
	int w, h;

	s = nil;
	raw = nil;
	qlock(&cam.lk);
	if(waserror()){
		if(s != nil){
			free(s->data);
			free(s);
		}
		free(raw);
		qunlock(&cam.lk);
		nexterror();
	}
	if(!cam.on)
		error("camera: not streaming");
	w = cam.mode->w;
	h = cam.mode->h;
	n = (long)w * h;
	raw = malloc(n * sizeof(ushort));
	s = mallocz(sizeof(Shot), 1);
	if(raw == nil || s == nil)
		error(Enomem);
	if(path == Qframe)
		s->len = Hdrlen + n*3;
	else
		s->len = n*2;
	s->data = malloc(s->len);
	if(s->data == nil)
		error(Enomem);
	cam.src->next(cam.src, raw);
	if(path == Qframe){
		snprint((char*)s->data, Hdrlen+1, "%11s %11d %11d %11d %11d ", "r8g8b8", 0, 0, w, h);
		debayer(raw, w, h, cam.src->bayer, cam.src->bits, s->data + Hdrlen);
	}else{
		p = s->data;
		for(i = 0; i < n; i++){
			*p++ = raw[i];
			*p++ = raw[i] >> 8;
		}
	}
	free(raw);
	poperror();
	qunlock(&cam.lk);
	return s;
}

static long
ctlread(void *a, long n, vlong off)
{
	char buf[256];
	ulong frames;

	qlock(&cam.lk);
	frames = cam.on? cam.src->count(cam.src): 0;
	snprint(buf, sizeof buf, "source %s\nmode %d %d\nfps %d\nstream %s\nraw %s%d\nframes %lud\n",
		cam.src->name, cam.mode->w, cam.mode->h, cam.fps, cam.on? "on": "off",
		cam.src->bayer, cam.src->bits, frames);
	qunlock(&cam.lk);
	return readstr(off, a, n, buf);
}

static long
modesread(void *a, long n, vlong off)
{
	char *buf, *p, *e;
	Camsrc *s;
	Cammode *m;
	int i, j;

	buf = smalloc(READSTR);
	if(waserror()){
		free(buf);
		nexterror();
	}
	p = buf;
	e = buf + READSTR;
	for(i = 0; i < cam.nsrc; i++){
		s = cam.srcs[i];
		for(j = 0; j < s->nmode; j++){
			m = &s->modes[j];
			p = seprint(p, e, "%s %d %d %d %s%d\n", s->name, m->w, m->h, m->maxfps, s->bayer, s->bits);
		}
	}
	n = readstr(off, a, n, buf);
	poperror();
	free(buf);
	return n;
}

static void
ctlwrite(char *a, long n)
{
	Cmdbuf *cb;
	Cmdtab *ct;
	Cammode *m;
	int i, w, h, fps;

	cb = parsecmd(a, n);
	qlock(&cam.lk);
	if(waserror()){
		qunlock(&cam.lk);
		free(cb);
		nexterror();
	}
	ct = lookupcmd(cb, camcmd, nelem(camcmd));
	if(cam.on && ct->index != CMstream)
		error("camera: streaming; stream off first");
	switch(ct->index){
	case CMsource:
		for(i = 0; i < cam.nsrc; i++)
			if(strcmp(cam.srcs[i]->name, cb->f[1]) == 0)
				break;
		if(i == cam.nsrc)
			error("camera: no such source");
		usesrc(cam.srcs[i]);
		break;
	case CMmode:
		w = strtol(cb->f[1], nil, 10);
		h = strtol(cb->f[2], nil, 10);
		m = nil;
		for(i = 0; i < cam.src->nmode; i++)
			if(cam.src->modes[i].w == w && cam.src->modes[i].h == h)
				m = &cam.src->modes[i];
		if(m == nil)
			error("camera: no such mode; see modes");
		cam.mode = m;
		if(cam.fps > m->maxfps)
			cam.fps = m->maxfps;
		break;
	case CMfps:
		fps = strtol(cb->f[1], nil, 10);
		if(fps < 1 || fps > cam.mode->maxfps)
			error("camera: fps out of range for this mode");
		cam.fps = fps;
		break;
	case CMstream:
		if(strcmp(cb->f[1], "on") == 0){
			if(!cam.on){
				cam.src->on(cam.src, cam.mode, cam.fps);
				cam.on = 1;
			}
		}else if(strcmp(cb->f[1], "off") == 0){
			if(cam.on){
				cam.on = 0;
				cam.src->off(cam.src);
			}
		}else
			error(Ebadarg);
		break;
	}
	poperror();
	qunlock(&cam.lk);
	free(cb);
}

static int
camgen(Chan *c, char *name, Dirtab *tab, int ntab, int s, Dir *dp)
{
	Qid q;

	USED(name);
	USED(tab);
	USED(ntab);
	if((ulong)c->qid.path == Qroot){
		if(s == DEVDOTDOT){
			mkqid(&q, Qroot, 0, QTDIR);
			devdir(c, q, "#V", 0, eve, DMDIR|0555, dp);
			return 1;
		}
		if(s == 0){
			mkqid(&q, Qcam, 0, QTDIR);
			devdir(c, q, "camera", 0, eve, DMDIR|0555, dp);
			return 1;
		}
		return -1;
	}
	/*
	 * The camera directory and the files in it answer alike for
	 * s >= 0, with the directory's entries: devstat and devopen on a
	 * file look for its qid among them (see os/bcm/devgpio.c's gen).
	 */
	if(s == DEVDOTDOT){
		if((ulong)c->qid.path == Qcam){
			mkqid(&q, Qroot, 0, QTDIR);
			devdir(c, q, "#V", 0, eve, DMDIR|0555, dp);
		}else{
			mkqid(&q, Qcam, 0, QTDIR);
			devdir(c, q, "camera", 0, eve, DMDIR|0555, dp);
		}
		return 1;
	}
	if(s < 0 || s >= nelem(camtab))
		return -1;
	devdir(c, camtab[s].qid, camtab[s].name, 0, eve, camtab[s].perm, dp);
	return 1;
}

static Chan*
camattach(char *spec)
{
	return devattach('V', spec);
}

static Walkqid*
camwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, nil, 0, camgen);
}

static int
camstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, nil, 0, camgen);
}

static Chan*
camopen(Chan *c, int omode)
{
	int path;

	path = (ulong)c->qid.path;
	c = devopen(c, omode, nil, 0, camgen);
	if(path == Qframe || path == Qraw){
		if(waserror()){
			c->flag &= ~COPEN;
			nexterror();
		}
		c->aux = shoot(path);
		poperror();
	}
	return c;
}

static void
camclose(Chan *c)
{
	Shot *s;

	if((c->flag & COPEN) == 0)
		return;
	s = c->aux;
	if(s != nil){
		c->aux = nil;
		free(s->data);
		free(s);
	}
}

static long
camread(Chan *c, void *a, long n, vlong off)
{
	Shot *s;

	switch((ulong)c->qid.path){
	case Qroot:
	case Qcam:
		return devdirread(c, a, n, nil, 0, camgen);
	case Qctl:
		return ctlread(a, n, off);
	case Qmodes:
		return modesread(a, n, off);
	case Qframe:
	case Qraw:
		s = c->aux;
		if(off >= s->len)
			return 0;
		if(n > s->len - off)
			n = s->len - off;
		memmove(a, s->data + off, n);
		return n;
	}
	error(Egreg);
	return 0;
}

static long
camwrite(Chan *c, void *a, long n, vlong off)
{
	USED(off);
	switch((ulong)c->qid.path){
	case Qctl:
		ctlwrite(a, n);
		return n;
	}
	error(Eperm);
	return 0;
}

Dev camdevtab = {
	'V',
	"camera",

	devreset,
	caminit,
	devshutdown,
	camattach,
	camwalk,
	camstat,
	camopen,
	devcreate,
	camclose,
	camread,
	devbread,
	camwrite,
	devbwrite,
	devremove,
	devwstat,
};

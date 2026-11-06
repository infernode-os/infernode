/*
 * devspeech.c -- a speech engine in the emulator: speech(4)'s engine
 * contract, served as #W, so speech9p has an engine on a machine with
 * nothing else (a phone) and needs no host program.
 *
 *	ctl	start, end, cancel: an utterance; voice v, lang l, model m.
 *		read: name native, rate (tts's), stt and tts (what is built
 *		in, or none), the model and whether it is loaded, the voice,
 *		the language, and counts
 *	audio	the utterance's sound, written between start and end:
 *		16 kHz, mono, 16-bit little-endian
 *	text	records, a line each, to every reader from its open on:
 *		final confidence=N words, or error reason
 *	tts	write text, then read its sound on the same open file to end
 *		of file: 16 kHz, mono, 16-bit little-endian; the reads follow
 *		on from the write whatever their offset
 *	voices	a voice a line
 *
 * Recognition is whisper.cpp's (HAVE_WHISPER), on the utterance at its
 * end, in a kproc of its own, so end returns at once and the final
 * comes when it is done; finals only.  Synthesis is flite's
 * (HAVE_FLITE), on the writer's own call.  Built without either, the
 * device is there and says so: ctl reads stt none or tts none, an
 * utterance's end gives "error no recogniser built in", a write of tts
 * is refused.
 *
 * A model is named, never given as a path: m is a file of
 * /lib/speech/models (under the emulator's root), a name of letters,
 * digits, '.', '-' and '_', so whoever holds ctl cannot have the
 * device read anything else.  It is loaded at the first utterance
 * after it is set.
 *
 * Nothing here waits holding a lock: the kproc sleeps on a Rendez for
 * work; a reader of text sleeps in its own queue (qio), killable.
 */

#include "dat.h"
#include "fns.h"
#include "error.h"

#ifdef HAVE_WHISPER
#include <whisper.h>
#endif
#ifdef HAVE_FLITE
#include <flite/flite.h>
extern cst_voice *register_cmu_us_slt(const char *voxdir);
extern cst_voice *register_cmu_us_rms(const char *voxdir);
extern cst_voice *register_cmu_us_awb(const char *voxdir);
extern cst_voice *register_cmu_us_kal16(const char *voxdir);
#endif

enum {
	Qdir = 0,
	Qctl,
	Qaudio,
	Qtext,
	Qtts,
	Qvoices,

	Rate	= 16000,
	Maxsecs	= 60,			/* an utterance, at most */
	Maxutter	= Rate*Maxsecs,	/* samples */
	Maxtts	= 4096,			/* bytes of text to say at once */
	Textq	= 64*1024,		/* a reader's records not yet read */
	Namelen	= 64,
};

static
Dirtab speechtab[] = {
	".",		{Qdir, 0, QTDIR},	0,	0555,
	"ctl",		{Qctl},			0,	0666,
	"audio",	{Qaudio},		0,	0222,
	"text",		{Qtext},		0,	0444,
	"tts",		{Qtts},			0,	0666,
	"voices",	{Qvoices},		0,	0444,
};

typedef struct Reader Reader;
struct Reader {
	Queue	*q;
	Reader	*next;
};

/* what a tts file holds: the sound of what was written to it */
typedef struct Said Said;
struct Said {
	short	*pcm;
	long	n;		/* samples */
	long	pos;		/* bytes read: reads follow on from the write, whatever its offset */
};

static struct {
	QLock	l;		/* the settings and the utterance */
	int	active;		/* between start and end */
	short	*pcm;		/* the utterance */
	long	npcm;
	char	voice[Namelen];
	char	lang[16];
	char	model[Namelen];
	int	modelset;	/* model changed: load it at the next utterance */
	long	utterances;
	long	finals;

	Lock	rl;		/* the readers of text */
	Reader	*readers;

	Lock	wl;		/* the recogniser's work */
	Rendez	wr;
	short	*job;		/* an utterance waiting to be recognised */
	long	njob;
	int	working;	/* the kproc runs */

	QLock	tl;		/* synthesis, one at a time */
#ifdef HAVE_WHISPER
	struct whisper_context	*wctx;
	char	loaded[Namelen];
#endif
#ifdef HAVE_FLITE
	int	fliteup;
#endif
} sp;

static char *voicenames[] = {
#ifdef HAVE_FLITE
	"slt", "rms", "awb", "kal16",
#endif
	nil
};

static int
safename(char *s, int max)
{
	int i;

	if(s == nil || s[0] == 0 || strlen(s) >= max)
		return 0;
	if(strcmp(s, ".") == 0 || strcmp(s, "..") == 0)
		return 0;
	for(i = 0; s[i]; i++)
		if(!(s[i] >= 'a' && s[i] <= 'z' || s[i] >= 'A' && s[i] <= 'Z' ||
		     s[i] >= '0' && s[i] <= '9' || s[i] == '.' || s[i] == '-' || s[i] == '_'))
			return 0;
	return 1;
}

static int
isvoice(char *v)
{
	int i;

	for(i = 0; voicenames[i] != nil; i++)
		if(strcmp(voicenames[i], v) == 0)
			return 1;
	return 0;
}

/* a record to every reader of text */
static void
post(char *rec)
{
	Reader *r;
	int n;

	n = strlen(rec);
	lock(&sp.rl);
	for(r = sp.readers; r != nil; r = r->next){
		qproduce(r->q, rec, n);
		qproduce(r->q, "\n", 1);
	}
	unlock(&sp.rl);
}

static void
speechinit(void)
{
	strcpy(sp.lang, "en");
	strcpy(sp.model, "ggml-base.en.bin");
	sp.modelset = 1;
#ifdef HAVE_FLITE
	strcpy(sp.voice, "slt");
#endif
}

static Chan*
speechattach(char *spec)
{
	return devattach('W', spec);
}

static Walkqid*
speechwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, speechtab, nelem(speechtab), devgen);
}

static int
speechstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, speechtab, nelem(speechtab), devgen);
}

static Chan*
speechopen(Chan *c, int omode)
{
	Reader *r;

	c = devopen(c, omode, speechtab, nelem(speechtab), devgen);
	switch((ulong)c->qid.path){
	case Qtext:
		r = malloc(sizeof *r);
		if(r == nil)
			error(Enomem);
		r->q = qopen(Textq, 0, nil, nil);
		if(r->q == nil){
			free(r);
			error(Enomem);
		}
		lock(&sp.rl);
		r->next = sp.readers;
		sp.readers = r;
		unlock(&sp.rl);
		c->aux = r;
		break;
	case Qtts:
		c->aux = mallocz(sizeof(Said), 1);
		if(c->aux == nil)
			error(Enomem);
		break;
	}
	return c;
}

static void
speechclose(Chan *c)
{
	Reader *r, **l;
	Said *s;

	if((c->flag & COPEN) == 0)
		return;
	switch((ulong)c->qid.path){
	case Qtext:
		r = c->aux;
		if(r == nil)
			break;
		lock(&sp.rl);
		for(l = &sp.readers; *l != nil; l = &(*l)->next)
			if(*l == r){
				*l = r->next;
				break;
			}
		unlock(&sp.rl);
		qfree(r->q);
		free(r);
		c->aux = nil;
		break;
	case Qtts:
		s = c->aux;
		if(s != nil){
			free(s->pcm);
			free(s);
			c->aux = nil;
		}
		break;
	}
}

/*
 * Recognition
 */

#ifdef HAVE_WHISPER
static void
quiet(enum ggml_log_level level, const char *text, void *a)
{
	USED(level); USED(text); USED(a);
}

/* the model named, loaded if it is not; nil, and why, if it cannot be */
static char*
loadmodel(void)
{
	char path[MAXROOT+128], model[Namelen];
	struct whisper_context_params cp;
	struct whisper_context *ctx;
	int set;

	qlock(&sp.l);
	set = sp.modelset;
	sp.modelset = 0;
	strcpy(model, sp.model);
	qunlock(&sp.l);
	if(!set && sp.wctx != nil)
		return nil;
	if(sp.wctx != nil && strcmp(sp.loaded, model) == 0)
		return nil;
	snprint(path, sizeof path, "%s/lib/speech/models/%s", rootdir, model);
	whisper_log_set(quiet, nil);
	cp = whisper_context_default_params();
	ctx = whisper_init_from_file_with_params(path, cp);
	if(ctx == nil)
		return "no model";
	if(sp.wctx != nil)
		whisper_free(sp.wctx);
	sp.wctx = ctx;
	strcpy(sp.loaded, model);
	return nil;
}

static void
recognise(short *pcm, long n)
{
	struct whisper_full_params p;
	float *f;
	char *rec, *e, lang[16];
	int ns, nt, i, j, k, len;
	whisper_token eot;
	double psum;
	long ptok;

	if((e = loadmodel()) != nil){
		char buf[160];
		qlock(&sp.l);
		snprint(buf, sizeof buf, "error %s: %s (lib/speech/models)", e, sp.model);
		qunlock(&sp.l);
		post(buf);
		return;
	}
	f = malloc(n * sizeof(float));
	if(f == nil){
		post("error out of memory");
		return;
	}
	for(i = 0; i < n; i++)
		f[i] = pcm[i] / 32768.0f;
	qlock(&sp.l);
	strcpy(lang, sp.lang);
	qunlock(&sp.l);
	p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
	p.print_progress = false;
	p.print_realtime = false;
	p.print_timestamps = false;
	p.print_special = false;
	p.no_timestamps = true;
	p.single_segment = false;
	p.language = lang;
	p.n_threads = 4;
	if(whisper_full(sp.wctx, p, f, n) != 0){
		free(f);
		post("error the recogniser failed");
		return;
	}
	free(f);
	ns = whisper_full_n_segments(sp.wctx);
	eot = whisper_token_eot(sp.wctx);
	len = 64;
	for(i = 0; i < ns; i++)
		len += strlen(whisper_full_get_segment_text(sp.wctx, i)) + 1;
	rec = malloc(len);
	if(rec == nil){
		post("error out of memory");
		return;
	}
	psum = 0;
	ptok = 0;
	for(i = 0; i < ns; i++){
		nt = whisper_full_n_tokens(sp.wctx, i);
		for(j = 0; j < nt; j++)
			if(whisper_full_get_token_id(sp.wctx, i, j) < eot){
				psum += whisper_full_get_token_p(sp.wctx, i, j);
				ptok++;
			}
	}
	k = snprint(rec, len, "final confidence=%.2f", ptok > 0 ? psum/ptok : 0.0);
	for(i = 0; i < ns; i++){
		const char *t = whisper_full_get_segment_text(sp.wctx, i);
		/* a line each record: the words with no newline, one space apart */
		for(; *t; t++){
			int ch = *t == '\n' || *t == '\r' || *t == '\t' ? ' ' : *t;
			if(ch == ' ' && rec[k-1] == ' ')
				continue;
			if(k < len - 1)
				rec[k++] = ch;
		}
		if(k < len - 1 && rec[k-1] != ' ')
			rec[k++] = ' ';
	}
	while(k > 0 && rec[k-1] == ' ')
		k--;
	rec[k] = 0;
	/* "final confidence=N" and a space before the words */
	post(rec);
	free(rec);
	qlock(&sp.l);
	sp.finals++;
	qunlock(&sp.l);
}
#endif

static int
haswork(void *a)
{
	USED(a);
	return sp.job != nil;
}

static void
worker(void *a)
{
	short *pcm;
	long n;

	USED(a);
	for(;;){
		Sleep(&sp.wr, haswork, nil);
		lock(&sp.wl);
		pcm = sp.job;
		n = sp.njob;
		sp.job = nil;
		unlock(&sp.wl);
		if(pcm == nil)
			continue;
#ifdef HAVE_WHISPER
		recognise(pcm, n);
#else
		USED(n);
#endif
		free(pcm);
	}
}

/* the utterance ended: to the recogniser */
static void
ended(short *pcm, long n)
{
	int start;

#ifndef HAVE_WHISPER
	free(pcm);
	USED(n);
	post("error no recogniser built in (the emulator was built without whisper.cpp)");
	return;
#endif
	lock(&sp.wl);
	if(sp.job != nil){
		unlock(&sp.wl);
		free(pcm);
		post("error the recogniser is busy");
		return;
	}
	sp.job = pcm;
	sp.njob = n;
	start = !sp.working;
	sp.working = 1;
	unlock(&sp.wl);
	if(start)
		kproc("speechrec", worker, nil, 0);
	Wakeup(&sp.wr);
}

/*
 * Synthesis
 */

static void
say(Said *s, char *text)
{
#ifdef HAVE_FLITE
	static cst_voice *voices[nelem(voicenames)];
	cst_voice *v;
	cst_wave *w;
	char voice[Namelen];
	int i;

	qlock(&sp.l);
	strcpy(voice, sp.voice);
	qunlock(&sp.l);
	qlock(&sp.tl);
	if(waserror()){
		qunlock(&sp.tl);
		nexterror();
	}
	if(!sp.fliteup){
		/* in voicenames' order */
		flite_init();
		voices[0] = register_cmu_us_slt(nil);
		voices[1] = register_cmu_us_rms(nil);
		voices[2] = register_cmu_us_awb(nil);
		voices[3] = register_cmu_us_kal16(nil);
		sp.fliteup = 1;
	}
	v = nil;
	for(i = 0; voicenames[i] != nil; i++)
		if(strcmp(voicenames[i], voice) == 0)
			v = voices[i];
	if(v == nil)
		error("no such voice");
	w = flite_text_to_wave(text, v);
	if(w == nil)
		error("the synthesiser failed");
	if(cst_wave_sample_rate(w) != Rate)
		cst_wave_resample(w, Rate);
	free(s->pcm);
	s->n = cst_wave_num_samples(w);
	s->pcm = malloc(s->n * sizeof(short) + 1);
	if(s->pcm == nil){
		delete_wave(w);
		s->n = 0;
		error(Enomem);
	}
	memmove(s->pcm, cst_wave_samples(w), s->n * sizeof(short));
	s->pos = 0;
	delete_wave(w);
	poperror();
	qunlock(&sp.tl);
#else
	USED(s); USED(text);
	error("no synthesiser built in (the emulator was built without flite)");
#endif
}

/*
 * The files
 */

static long
speechread(Chan *c, void *va, long n, vlong off)
{
	char buf[512];
	int k, i;
	Said *s;
	long nb;

	switch((ulong)c->qid.path){
	case Qdir:
		return devdirread(c, va, n, speechtab, nelem(speechtab), devgen);
	case Qctl:
		qlock(&sp.l);
		k = snprint(buf, sizeof buf, "name native\nrate %d\n", Rate);
#ifdef HAVE_WHISPER
		k += snprint(buf+k, sizeof buf-k, "stt whisper\nmodel %s %s\n", sp.model,
			sp.wctx != nil && strcmp(sp.loaded, sp.model) == 0 ? "loaded" : "not loaded");
#else
		k += snprint(buf+k, sizeof buf-k, "stt none\n");
#endif
#ifdef HAVE_FLITE
		k += snprint(buf+k, sizeof buf-k, "tts flite\nvoice %s\n", sp.voice);
#else
		k += snprint(buf+k, sizeof buf-k, "tts none\n");
#endif
		k += snprint(buf+k, sizeof buf-k, "lang %s\nutterances %ld\nfinals %ld\n",
			sp.lang, sp.utterances, sp.finals);
		qunlock(&sp.l);
		USED(k);
		return readstr(off, va, n, buf);
	case Qvoices:
		k = 0;
		buf[0] = 0;
		for(i = 0; voicenames[i] != nil; i++)
			k += snprint(buf+k, sizeof buf-k, "%s\n", voicenames[i]);
		return readstr(off, va, n, buf);
	case Qtext:
		return qread(((Reader*)c->aux)->q, va, n);
	case Qtts:
		s = c->aux;
		nb = s->n * sizeof(short);
		if(s->pos >= nb)
			return 0;
		if(s->pos + n > nb)
			n = nb - s->pos;
		memmove(va, (uchar*)s->pcm + s->pos, n);
		s->pos += n;
		return n;
	case Qaudio:
		error("audio is written");
	}
	error(Egreg);
	return 0;
}

static long
ctlwrite(char *a, long n)
{
	Cmdbuf *cb;
	short *pcm;
	long np;

	cb = parsecmd(a, n);
	if(waserror()){
		free(cb);
		nexterror();
	}
	if(cb->nf < 1)
		error(Ebadctl);
	pcm = nil;
	np = 0;
	qlock(&sp.l);
	if(waserror()){
		qunlock(&sp.l);
		nexterror();
	}
	if(strcmp(cb->f[0], "start") == 0){
		if(sp.pcm == nil){
			sp.pcm = malloc(Maxutter * sizeof(short));
			if(sp.pcm == nil)
				error(Enomem);
		}
		sp.npcm = 0;
		sp.active = 1;
		sp.utterances++;
	}else if(strcmp(cb->f[0], "end") == 0){
		if(sp.active){
			sp.active = 0;
			np = sp.npcm;
			pcm = malloc(np * sizeof(short) + 1);
			if(pcm == nil)
				error(Enomem);
			memmove(pcm, sp.pcm, np * sizeof(short));
		}
	}else if(strcmp(cb->f[0], "cancel") == 0){
		sp.active = 0;
		sp.npcm = 0;
	}else if(cb->nf == 2 && strcmp(cb->f[0], "voice") == 0){
		if(!isvoice(cb->f[1]))
			error("no such voice");
		strcpy(sp.voice, cb->f[1]);
	}else if(cb->nf == 2 && strcmp(cb->f[0], "lang") == 0){
		if(!safename(cb->f[1], sizeof sp.lang))
			error("a language is a name");
		strcpy(sp.lang, cb->f[1]);
	}else if(cb->nf == 2 && strcmp(cb->f[0], "model") == 0){
		if(!safename(cb->f[1], sizeof sp.model))
			error("a model is a name in /lib/speech/models");
		strcpy(sp.model, cb->f[1]);
		sp.modelset = 1;
	}else
		error(Ebadctl);
	poperror();
	qunlock(&sp.l);
	poperror();
	free(cb);
	if(pcm != nil)
		ended(pcm, np);
	return n;
}

static long
speechwrite(Chan *c, void *va, long n, vlong off)
{
	long k;
	char *t;

	USED(off);
	switch((ulong)c->qid.path){
	case Qctl:
		return ctlwrite(va, n);
	case Qaudio:
		qlock(&sp.l);
		if(sp.active && sp.pcm != nil){
			k = n / sizeof(short);
			if(k > Maxutter - sp.npcm)
				k = Maxutter - sp.npcm;
			memmove(sp.pcm + sp.npcm, va, k * sizeof(short));
			sp.npcm += k;
		}
		qunlock(&sp.l);
		return n;
	case Qtts:
		if(n > Maxtts)
			error("too much to say at once");
		t = malloc(n + 1);
		if(t == nil)
			error(Enomem);
		memmove(t, va, n);
		t[n] = 0;
		if(waserror()){
			free(t);
			nexterror();
		}
		say(c->aux, t);
		poperror();
		free(t);
		return n;
	}
	error(Eperm);
	return 0;
}

Dev speechdevtab = {
	'W',
	"speech",

	speechinit,
	speechattach,
	speechwalk,
	speechstat,
	speechopen,
	devcreate,
	speechclose,
	speechread,
	devbread,
	speechwrite,
	devbwrite,
	devremove,
	devwstat
};

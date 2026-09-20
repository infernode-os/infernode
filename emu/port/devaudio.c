#include	"dat.h"
#include	"fns.h"
#include	"error.h"
#include	"audio.h"

Dirtab audiotab[] =
{
	".",		{Qdir, 0, QTDIR},	0,	0555,
	"audio",	{Qaudio},	0,	0666,
	"audioctl",	{Qaudioctl},	0,	0666,
	"audiodev",	{Qaudiodev},	0,	0666,
};

static Audiodevops *devops;

void
audio_devops_register(Audiodevops *ops)
{
	devops = ops;
}

static void (*bufcaps)(int*, int*);

void
audio_bufcaps_register(void (*get)(int *play_ms, int *rec_ms))
{
	bufcaps = get;
}


static void
audioinit(void)
{
	audio_file_init();
}

static Chan*
audioattach(char *spec)
{
	return devattach('A', spec);
}

static Walkqid*
audiowalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, audiotab, nelem(audiotab), devgen);
}

static int
audiostat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, audiotab, nelem(audiotab), devgen);
}

static Chan*
audioopen(Chan *c, int omode)
{
	c = devopen(c, omode, audiotab, nelem(audiotab), devgen);
	if(waserror()){
		c->flag &= ~COPEN;
		nexterror();
	}
	switch(c->qid.path) {
	case Qdir:
	case Qaudioctl:
	case Qaudiodev:
		break;
	case Qaudio:
		audio_file_open(c, c->mode);
		break;
	default:
		error(Egreg);
	}
	poperror();
	return c;
}

static void
audioclose(Chan *c)
{
	if((c->flag & COPEN) == 0)
		return;

	switch(c->qid.path) {
	case Qdir:
	case Qaudioctl:
	case Qaudiodev:
		break;
	case Qaudio:
		audio_file_close(c);
		break;
	default:
		error(Egreg);
	}
}

static int ctlsummary(char*, int, Audio_t*);

static long
audioread(Chan *c, void *va, long count, vlong offset)
{
	char *buf;
	int n;

	if(c->qid.type & QTDIR)
		return devdirread(c, va, count, audiotab, nelem(audiotab), devgen);
	switch(c->qid.path) {
	case Qaudio:
		return audio_file_read(c, va, count, offset);
	case Qaudioctl:
		buf = smalloc(READSTR);
		if(waserror()){
			free(buf);
			nexterror();
		}
		n = ctlsummary(buf, READSTR, getaudiodev());
		count = readstr(offset, va, n, buf);
		poperror();
		free(buf);
		return count;
	case Qaudiodev:
		buf = smalloc(READSTR);
		if(waserror()){
			free(buf);
			nexterror();
		}
		if(devops == nil || devops->list == nil)
			n = snprint(buf, READSTR, "unsupported\n");
		else
			n = devops->list(buf, buf + READSTR);
		count = readstr(offset, va, n, buf);
		poperror();
		free(buf);
		return count;
	}
	return 0;
}

/*
 * "in <name>" or "out <name>" selects a host device; an empty name, or
 * the literal "default", follows the system default again. The readback
 * emits "in device 'X'" and "in selected 'X'" — quotes because real
 * names contain spaces, and the keyword for the device's role in the
 * listing — so those forms are accepted here too: a line from a read
 * can be written straight back.
 */
static long
audiodevwrite(void *va, long count)
{
	char *buf, *name, *p;
	int isin;

	if(devops == nil || devops->select == nil)
		error("audiodev: this platform cannot select an audio device");
	if(count <= 0 || count > 256)
		error(Ebadarg);

	buf = smalloc(count + 1);
	if(waserror()){
		free(buf);
		nexterror();
	}
	memmove(buf, va, count);
	buf[count] = 0;
	if((p = strchr(buf, '\n')) != nil)
		*p = 0;

	if(strncmp(buf, "in ", 3) == 0){
		isin = 1;
		name = buf + 3;
	}else if(strncmp(buf, "out ", 4) == 0){
		isin = 0;
		name = buf + 4;
	}else
		error("audiodev: write \"in <name>\" or \"out <name>\"");

	while(*name == ' ' || *name == '\t')
		name++;
	/* Skip the keyword the readback puts between the direction and the
	 * name. A device actually called "device" is still reachable: the
	 * word is only skipped when another word follows it. */
	if(strncmp(name, "device", 6) == 0 && (name[6] == ' ' || name[6] == '\t'))
		name += 6;
	else if(strncmp(name, "selected", 8) == 0 && (name[8] == ' ' || name[8] == '\t'))
		name += 8;
	while(*name == ' ' || *name == '\t')
		name++;
	if(*name == '\''){
		name++;
		if((p = strrchr(name, '\'')) != nil)
			*p = 0;
	}
	if(strcmp(name, "default") == 0)
		*name = 0;
	if(devops->select(isin, name) < 0)
		error("audiodev: no device of that name");

	poperror();
	free(buf);
	return count;
}

static long
audiowrite(Chan *c, void *va, long count, vlong offset)
{
	switch(c->qid.path) {
	case Qaudio:
		return audio_file_write(c, va, count, offset);
	case Qaudioctl:
		return audio_ctl_write(c, va, count, offset);
	case Qaudiodev:
		return audiodevwrite(va, count);
	}
	return 0;
}

static int sval(char*, unsigned long*, ulong, ulong);
static int str2val(svp_t*, char*, ulong*);
static char* val2str(svp_t*, ulong);

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
	p = seprint(p, e, "in rate %lud chans %lud bits %lud\n",
		in->rate, in->chan, in->bits);
	p = seprint(p, e, "out rate %lud chans %lud bits %lud\n",
		out->rate, out->chan, out->bits);
	if(bufcaps){
		int play_ms, rec_ms;

		bufcaps(&play_ms, &rec_ms);
		p = seprint(p, e, "play_buffer_ms %d\n", play_ms);
		p = seprint(p, e, "rec_buffer_ms %d\n", rec_ms);
	}



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


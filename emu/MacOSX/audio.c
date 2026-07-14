#include "dat.h"
#include "fns.h"
#include "error.h"
#include "audio.h"
#include <AudioToolbox/AudioToolbox.h>
#include <pthread.h>
#include <string.h>

#define Audio_Mic_Val		1
#define Audio_Linein_Val	2

#define Audio_Speaker_Val	1
#define Audio_Headphone_Val	2
#define Audio_Lineout_Val	3

#define Audio_Pcm_Val		1
#define Audio_Ulaw_Val		2
#define Audio_Alaw_Val		3

#include "audio-tbls.c"

#define Nqueuebuf	3
#define Defbufsz	8192
#define Defringsz	262144

#define min(a,b)	((a) < (b) ? (a) : (b))

typedef struct Ring Ring;
struct Ring {
	uchar *data;
	int size;
	int r;
	int w;
	int fill;
	pthread_mutex_t lk;
	pthread_cond_t canread;
	pthread_cond_t canwrite;
};

static Audio_t av;
static QLock inlock;
static QLock outlock;

static int inopen;
static int outopen;
static int instarted;
static int outstarted;
static Ring inring;
static Ring outring;
static AudioQueueRef inq;
static AudioQueueRef outq;
static AudioQueueBufferRef inbuf[Nqueuebuf];
static AudioQueueBufferRef outbuf[Nqueuebuf];
static AudioStreamBasicDescription infmt;
static AudioStreamBasicDescription outfmt;

static void closinput(void);
static void closoutput(void);
static void startinput(void);
static void startoutput(void);

Audio_t*
getaudiodev(void)
{
	return &av;
}

void
audio_file_init(void)
{
	audio_info_init(&av);
}

static void
coreerror(char *what, OSStatus s)
{
	char buf[ERRMAX];

	snprint(buf, sizeof(buf), "%s: %ld", what, (long)s);
	error(buf);
}

static void
ringinit(Ring *r, int n)
{
	if(r->data != nil && r->size == n)
		return;
	if(r->data != nil)
		free(r->data);
	r->data = malloc(n);
	if(r->data == nil)
		error(Enomem);
	r->size = n;
	r->r = 0;
	r->w = 0;
	r->fill = 0;
	pthread_mutex_init(&r->lk, nil);
	pthread_cond_init(&r->canread, nil);
	pthread_cond_init(&r->canwrite, nil);
}

static void
ringreset(Ring *r)
{
	pthread_mutex_lock(&r->lk);
	r->r = 0;
	r->w = 0;
	r->fill = 0;
	pthread_cond_broadcast(&r->canread);
	pthread_cond_broadcast(&r->canwrite);
	pthread_mutex_unlock(&r->lk);
}

static void
ringfree(Ring *r)
{
	uchar *p;

	if(r->data == nil)
		return;
	pthread_mutex_lock(&r->lk);
	p = r->data;
	r->data = nil;
	r->size = 0;
	r->r = 0;
	r->w = 0;
	r->fill = 0;
	pthread_cond_broadcast(&r->canread);
	pthread_cond_broadcast(&r->canwrite);
	pthread_mutex_unlock(&r->lk);
	free(p);
	pthread_cond_destroy(&r->canread);
	pthread_cond_destroy(&r->canwrite);
	pthread_mutex_destroy(&r->lk);
}

static int
ringreadnb(Ring *r, uchar *p, int n)
{
	int m, got;

	got = 0;
	pthread_mutex_lock(&r->lk);
	while(got < n && r->fill > 0){
		m = min(n - got, r->fill);
		m = min(m, r->size - r->r);
		memcpy(p + got, r->data + r->r, m);
		r->r = (r->r + m) % r->size;
		r->fill -= m;
		got += m;
	}
	if(got > 0)
		pthread_cond_broadcast(&r->canwrite);
	pthread_mutex_unlock(&r->lk);
	return got;
}

static int
ringwritenb(Ring *r, uchar *p, int n)
{
	int m, put;

	put = 0;
	pthread_mutex_lock(&r->lk);
	while(put < n && r->fill < r->size){
		m = min(n - put, r->size - r->fill);
		m = min(m, r->size - r->w);
		memcpy(r->data + r->w, p + put, m);
		r->w = (r->w + m) % r->size;
		r->fill += m;
		put += m;
	}
	if(put > 0)
		pthread_cond_broadcast(&r->canread);
	pthread_mutex_unlock(&r->lk);
	return put;
}

static void
ringwrite(Ring *r, uchar *p, int n)
{
	int m;

	pthread_mutex_lock(&r->lk);
	while(n > 0){
		while(r->fill == r->size)
			pthread_cond_wait(&r->canwrite, &r->lk);
		m = min(n, r->size - r->fill);
		m = min(m, r->size - r->w);
		memcpy(r->data + r->w, p, m);
		r->w = (r->w + m) % r->size;
		r->fill += m;
		p += m;
		n -= m;
		pthread_cond_broadcast(&r->canread);
	}
	pthread_mutex_unlock(&r->lk);
}

static void
ringread(Ring *r, uchar *p, int n)
{
	int m;

	pthread_mutex_lock(&r->lk);
	while(n > 0){
		while(r->fill == 0)
			pthread_cond_wait(&r->canread, &r->lk);
		m = min(n, r->fill);
		m = min(m, r->size - r->r);
		memcpy(p, r->data + r->r, m);
		r->r = (r->r + m) % r->size;
		r->fill -= m;
		p += m;
		n -= m;
		pthread_cond_broadcast(&r->canwrite);
	}
	pthread_mutex_unlock(&r->lk);
}

static void
setformat(Audio_d *d, AudioStreamBasicDescription *fmt)
{
	if(d->enc != Audio_Pcm_Val)
		error("unsupported macOS audio encoding");
	if(d->bits != 8 && d->bits != 16)
		error("unsupported macOS audio sample size");
	if(d->chan != 1 && d->chan != 2)
		error("unsupported macOS audio channel count");
	memset(fmt, 0, sizeof(*fmt));
	fmt->mSampleRate = d->rate;
	fmt->mFormatID = kAudioFormatLinearPCM;
	fmt->mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
	fmt->mBitsPerChannel = d->bits;
	fmt->mChannelsPerFrame = d->chan;
	fmt->mFramesPerPacket = 1;
	fmt->mBytesPerFrame = (d->bits / Bits_Per_Byte) * d->chan;
	fmt->mBytesPerPacket = fmt->mBytesPerFrame;
}

static int
ringsz(Audio_d *d)
{
	int n;

	n = d->buf * Audio_Max_Buf / Audio_Max_Val;
	if(n < Defbufsz)
		n = Defbufsz;
	if(n < Defringsz)
		n = Defringsz;
	return n;
}

static void
outcallback(void *arg, AudioQueueRef q, AudioQueueBufferRef b)
{
	int n;

	USED(arg);
	n = ringreadnb(&outring, b->mAudioData, b->mAudioDataBytesCapacity);
	if(n < (int)b->mAudioDataBytesCapacity)
		memset((uchar*)b->mAudioData + n, 0, b->mAudioDataBytesCapacity - n);
	b->mAudioDataByteSize = b->mAudioDataBytesCapacity;
	AudioQueueEnqueueBuffer(q, b, 0, nil);
}

static void
incallback(void *arg, AudioQueueRef q, AudioQueueBufferRef b,
	const AudioTimeStamp *start, UInt32 packets, const AudioStreamPacketDescription *desc)
{
	USED(arg);
	USED(start);
	USED(packets);
	USED(desc);
	if(b->mAudioDataByteSize > 0)
		ringwritenb(&inring, b->mAudioData, b->mAudioDataByteSize);
	AudioQueueEnqueueBuffer(q, b, 0, nil);
}

static void
startoutput(void)
{
	OSStatus s;
	int i;

	if(outstarted)
		return;
	setformat(&av.out, &outfmt);
	ringinit(&outring, ringsz(&av.out));
	ringreset(&outring);
	s = AudioQueueNewOutput(&outfmt, outcallback, nil, nil, nil, 0, &outq);
	if(s != noErr)
		coreerror("cannot open CoreAudio output", s);
	for(i = 0; i < Nqueuebuf; i++){
		s = AudioQueueAllocateBuffer(outq, Defbufsz, &outbuf[i]);
		if(s != noErr)
			coreerror("cannot allocate CoreAudio output buffer", s);
		memset(outbuf[i]->mAudioData, 0, Defbufsz);
		outbuf[i]->mAudioDataByteSize = Defbufsz;
		s = AudioQueueEnqueueBuffer(outq, outbuf[i], 0, nil);
		if(s != noErr)
			coreerror("cannot enqueue CoreAudio output buffer", s);
	}
	s = AudioQueueStart(outq, nil);
	if(s != noErr)
		coreerror("cannot start CoreAudio output", s);
	outstarted = 1;
}

static void
startinput(void)
{
	OSStatus s;
	int i;

	if(instarted)
		return;
	setformat(&av.in, &infmt);
	ringinit(&inring, ringsz(&av.in));
	ringreset(&inring);
	s = AudioQueueNewInput(&infmt, incallback, nil, nil, nil, 0, &inq);
	if(s != noErr)
		coreerror("cannot open CoreAudio input", s);
	for(i = 0; i < Nqueuebuf; i++){
		s = AudioQueueAllocateBuffer(inq, Defbufsz, &inbuf[i]);
		if(s != noErr)
			coreerror("cannot allocate CoreAudio input buffer", s);
		s = AudioQueueEnqueueBuffer(inq, inbuf[i], 0, nil);
		if(s != noErr)
			coreerror("cannot enqueue CoreAudio input buffer", s);
	}
	s = AudioQueueStart(inq, nil);
	if(s != noErr)
		coreerror("cannot start CoreAudio input", s);
	instarted = 1;
}

static void
closoutput(void)
{
	if(outq != nil){
		AudioQueueStop(outq, true);
		AudioQueueDispose(outq, true);
		outq = nil;
	}
	outstarted = 0;
	ringfree(&outring);
}

static void
closinput(void)
{
	if(inq != nil){
		AudioQueueStop(inq, true);
		AudioQueueDispose(inq, true);
		inq = nil;
	}
	instarted = 0;
	ringfree(&inring);
}

void
audio_file_open(Chan *c, int omode)
{
	USED(c);
	switch(omode){
	case OREAD:
		qlock(&inlock);
		if(waserror()){
			qunlock(&inlock);
			nexterror();
		}
		if(inopen)
			error(Einuse);
		inopen = 1;
		poperror();
		qunlock(&inlock);
		break;
	case OWRITE:
		qlock(&outlock);
		if(waserror()){
			qunlock(&outlock);
			nexterror();
		}
		if(outopen)
			error(Einuse);
		outopen = 1;
		poperror();
		qunlock(&outlock);
		break;
	case ORDWR:
		qlock(&inlock);
		qlock(&outlock);
		if(waserror()){
			qunlock(&outlock);
			qunlock(&inlock);
			nexterror();
		}
		if(inopen || outopen)
			error(Einuse);
		inopen = 1;
		outopen = 1;
		poperror();
		qunlock(&outlock);
		qunlock(&inlock);
		break;
	default:
		error(Ebadarg);
	}
}

void
audio_file_close(Chan *c)
{
	switch(c->mode){
	case OREAD:
		qlock(&inlock);
		closinput();
		inopen = 0;
		qunlock(&inlock);
		break;
	case OWRITE:
		qlock(&outlock);
		closoutput();
		outopen = 0;
		qunlock(&outlock);
		break;
	case ORDWR:
		qlock(&inlock);
		qlock(&outlock);
		closinput();
		closoutput();
		inopen = 0;
		outopen = 0;
		qunlock(&outlock);
		qunlock(&inlock);
		break;
	}
}

long
audio_file_read(Chan *c, void *va, long count, vlong offset)
{
	long ba;

	USED(c);
	USED(offset);
	qlock(&inlock);
	if(waserror()){
		qunlock(&inlock);
		nexterror();
	}
	if(!inopen)
		error(Eperm);
	ba = av.in.bits * av.in.chan / Bits_Per_Byte;
	if(ba <= 0 || count % ba)
		error(Ebadarg);
	startinput();
	ringread(&inring, va, count);
	poperror();
	qunlock(&inlock);
	return count;
}

long
audio_file_write(Chan *c, void *va, long count, vlong offset)
{
	long ba;

	USED(c);
	USED(offset);
	qlock(&outlock);
	if(waserror()){
		qunlock(&outlock);
		nexterror();
	}
	if(!outopen)
		error(Eperm);
	ba = av.out.bits * av.out.chan / Bits_Per_Byte;
	if(ba <= 0 || count % ba)
		error(Ebadarg);
	startoutput();
	ringwrite(&outring, va, count);
	poperror();
	qunlock(&outlock);
	return count;
}

long
audio_ctl_write(Chan *c, void *va, long count, vlong offset)
{
	Audio_t tmpav;

	USED(c);
	USED(offset);
	tmpav = av;
	tmpav.in.flags = 0;
	tmpav.out.flags = 0;
	if(!audioparse(va, count, &tmpav))
		error(Ebadarg);

	if(!canqlock(&inlock))
		error("device busy");
	if(waserror()){
		qunlock(&inlock);
		nexterror();
	}
	if(!canqlock(&outlock))
		error("device busy");
	if(waserror()){
		qunlock(&outlock);
		nexterror();
	}
	if(instarted || outstarted)
		error("device busy");

	if(tmpav.in.flags & AUDIO_MOD_FLAG){
		tmpav.in.flags = 0;
		av.in = tmpav.in;
	}
	if(tmpav.out.flags & AUDIO_MOD_FLAG){
		tmpav.out.flags = 0;
		av.out = tmpav.out;
	}

	poperror();
	qunlock(&outlock);
	poperror();
	qunlock(&inlock);
	return count;
}

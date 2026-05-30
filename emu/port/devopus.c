/*
 * devopus.c — Opus codec as a Plan 9 device. INFR-187.
 *
 * Exposes /dev/opus/ with four files:
 *
 *   ctl     — write config verbs: "rate N", "chans N", "frame_ms N",
 *             "bitrate N". Read returns the current config.
 *   enc     — write PCM (S16 native), read Opus frames. Encoder
 *             accumulates the incoming PCM into frame_ms chunks,
 *             encodes each chunk, and queues the result; readers pull
 *             one complete Opus frame per read(2) (each prefixed with
 *             a 2-byte big-endian length so a 9P-mounted reader can
 *             still reassemble frames after Styx may have re-chunked).
 *   dec     — write Opus frames (with 2-byte length prefix), read
 *             decoded PCM. Symmetric to enc.
 *   status  — counters + current config.
 *
 * Single global encoder + decoder for v0 — voice/dial-opus runs at
 * most one pipeline per call so contention isn't real yet. Multi-call
 * support follows in v3.
 *
 * Lifetime: encoder/decoder are lazily created on first open(enc) /
 * open(dec); recreated on any ctl change that affects opus state
 * (rate, chans). Frame-size + bitrate changes are applied in-place
 * via opus_encoder_ctl without a recreate.
 */

#include "dat.h"
#include "fns.h"
#include "error.h"

#ifdef HAVE_OPUS
#include <opus/opus.h>
#endif

enum {
	Qdir = 0,
	Qctl,
	Qenc,
	Qdec,
	Qstatus,

	/* Opus accepts frames of 2.5/5/10/20/40/60 ms at 8/12/16/24/48 kHz.
	 * 20 ms at 48 kHz = 960 frames per channel = the WebRTC default
	 * and a good battery/latency point. */
	Default_Rate	= 48000,
	Default_Chans	= 1,
	Default_FrameMs	= 20,
	Default_Bitrate	= 24000,

	/* Big enough for the largest opus packet at the highest bitrate
	 * (~1500 bytes for 60ms @ 510 kbps stereo). */
	Max_Enc_Frame	= 4000,
};

static
Dirtab opustab[] = {
	".",		{Qdir, 0, QTDIR},	0,	0555,
	"ctl",		{Qctl},			0,	0666,
	"enc",		{Qenc},			0,	0666,
	"dec",		{Qdec},			0,	0666,
	"status",	{Qstatus},		0,	0444,
};

static struct {
	QLock	l;
	int	rate;
	int	chans;
	int	frame_ms;
	int	bitrate;
#ifdef HAVE_OPUS
	OpusEncoder	*enc;
	OpusDecoder	*dec;
#endif
	Queue	*enc_q;		/* encoded frames waiting for a reader */
	Queue	*dec_q;		/* decoded PCM waiting for a reader */
	uchar	enc_pcm[8192];	/* PCM bytes accumulated between encodes */
	int	enc_pcm_len;
	uchar	dec_in[8192];	/* opus bytes accumulated between decodes */
	int	dec_in_len;
	uvlong	enc_pcm_bytes;	/* total PCM bytes written into enc */
	uvlong	enc_out_frames;	/* total opus frames produced */
	uvlong	dec_in_frames;	/* total opus frames written into dec */
	uvlong	dec_pcm_bytes;	/* total PCM bytes produced from dec */
} opus_state;

static int frame_pcm_bytes(void)
{
	return opus_state.rate * opus_state.frame_ms / 1000
		* opus_state.chans * 2;	/* S16 */
}

static void
opusinit(void)
{
	opus_state.rate = Default_Rate;
	opus_state.chans = Default_Chans;
	opus_state.frame_ms = Default_FrameMs;
	opus_state.bitrate = Default_Bitrate;
}

static Chan*
opusattach(char *spec)
{
	return devattach('Z', spec);
}

static Walkqid*
opuswalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, opustab, nelem(opustab), devgen);
}

static int
opusstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, opustab, nelem(opustab), devgen);
}

#ifdef HAVE_OPUS
static int
ensure_encoder(void)
{
	int err;
	if(opus_state.enc != nil)
		return 1;
	opus_state.enc = opus_encoder_create(opus_state.rate, opus_state.chans,
					     OPUS_APPLICATION_VOIP, &err);
	if(err != OPUS_OK || opus_state.enc == nil) {
		print("devopus: opus_encoder_create failed: %d\n", err);
		return 0;
	}
	opus_encoder_ctl(opus_state.enc, OPUS_SET_BITRATE(opus_state.bitrate));
	return 1;
}

static int
ensure_decoder(void)
{
	int err;
	if(opus_state.dec != nil)
		return 1;
	opus_state.dec = opus_decoder_create(opus_state.rate, opus_state.chans,
					     &err);
	if(err != OPUS_OK || opus_state.dec == nil) {
		print("devopus: opus_decoder_create failed: %d\n", err);
		return 0;
	}
	return 1;
}
#endif /* HAVE_OPUS */

static Chan*
opusopen(Chan *c, int omode)
{
	c = devopen(c, omode, opustab, nelem(opustab), devgen);
#ifdef HAVE_OPUS
	switch((ulong)c->qid.path) {
	case Qenc:
		qlock(&opus_state.l);
		if(!ensure_encoder()) {
			qunlock(&opus_state.l);
			error("opus encoder unavailable");
		}
		if(opus_state.enc_q == nil)
			opus_state.enc_q = qopen(64*1024, 0, nil, nil);
		qunlock(&opus_state.l);
		break;
	case Qdec:
		qlock(&opus_state.l);
		if(!ensure_decoder()) {
			qunlock(&opus_state.l);
			error("opus decoder unavailable");
		}
		if(opus_state.dec_q == nil)
			opus_state.dec_q = qopen(64*1024, 0, nil, nil);
		qunlock(&opus_state.l);
		break;
	}
#else
	USED(omode);
#endif
	return c;
}

static void
opusclose(Chan *c)
{
	USED(c);
}

static long
opusread(Chan *c, void *va, long n, vlong off)
{
	char buf[256];
	int len;

	switch((ulong)c->qid.path) {
	case Qdir:
		return devdirread(c, va, n, opustab, nelem(opustab), devgen);

	case Qctl:
	case Qstatus:
		qlock(&opus_state.l);
		len = snprint(buf, sizeof buf,
			"rate %d\nchans %d\nframe_ms %d\nbitrate %d\n"
			"enc_pcm_bytes %lld\nenc_out_frames %lld\n"
			"dec_in_frames %lld\ndec_pcm_bytes %lld\n",
			opus_state.rate, opus_state.chans,
			opus_state.frame_ms, opus_state.bitrate,
			opus_state.enc_pcm_bytes, opus_state.enc_out_frames,
			opus_state.dec_in_frames, opus_state.dec_pcm_bytes);
		qunlock(&opus_state.l);
		return readstr(off, va, n, buf);

	case Qenc:
		/* block until a complete encoded frame is available */
		if(opus_state.enc_q == nil)
			return 0;
		return qread(opus_state.enc_q, va, n);

	case Qdec:
		if(opus_state.dec_q == nil)
			return 0;
		return qread(opus_state.dec_q, va, n);
	}
	return 0;
}

static long
opuswrite(Chan *c, void *va, long n, vlong off)
{
#ifdef HAVE_OPUS
	uchar *p = va;
	int fpb;	/* frame pcm bytes */
	int got;

	USED(off);
	switch((ulong)c->qid.path) {
	case Qctl: {
		char *cmd = malloc(n + 1);
		int v;
		if(cmd == nil)
			error(Enomem);
		memmove(cmd, va, n);
		cmd[n] = 0;
		qlock(&opus_state.l);
		if(memcmp(cmd, "rate ", 5) == 0 && (v = atoi(cmd+5)) > 0) {
			opus_state.rate = v;
			if(opus_state.enc) {
				opus_encoder_destroy(opus_state.enc);
				opus_state.enc = nil;
			}
			if(opus_state.dec) {
				opus_decoder_destroy(opus_state.dec);
				opus_state.dec = nil;
			}
		} else if(memcmp(cmd, "chans ", 6) == 0 && (v = atoi(cmd+6)) > 0) {
			opus_state.chans = v;
			if(opus_state.enc) {
				opus_encoder_destroy(opus_state.enc);
				opus_state.enc = nil;
			}
			if(opus_state.dec) {
				opus_decoder_destroy(opus_state.dec);
				opus_state.dec = nil;
			}
		} else if(memcmp(cmd, "frame_ms ", 9) == 0 && (v = atoi(cmd+9)) > 0) {
			opus_state.frame_ms = v;
		} else if(memcmp(cmd, "bitrate ", 8) == 0 && (v = atoi(cmd+8)) > 0) {
			opus_state.bitrate = v;
			if(opus_state.enc)
				opus_encoder_ctl(opus_state.enc, OPUS_SET_BITRATE(v));
		}
		qunlock(&opus_state.l);
		free(cmd);
		return n;
	}

	case Qenc:
		/* Accumulate PCM in opus_state.enc_pcm; when we have a full
		 * frame, encode it and push the bytes (with a 2-byte big-
		 * endian length prefix) onto enc_q. */
		qlock(&opus_state.l);
		fpb = frame_pcm_bytes();
		got = 0;
		while(got < n) {
			int take = sizeof opus_state.enc_pcm - opus_state.enc_pcm_len;
			if(take > n - got) take = n - got;
			memmove(opus_state.enc_pcm + opus_state.enc_pcm_len,
				p + got, take);
			opus_state.enc_pcm_len += take;
			got += take;
			opus_state.enc_pcm_bytes += take;
			while(opus_state.enc_pcm_len >= fpb) {
				uchar pkt[Max_Enc_Frame + 2];
				int enc_n;
				enc_n = opus_encode(opus_state.enc,
					(const opus_int16*)opus_state.enc_pcm,
					opus_state.rate * opus_state.frame_ms / 1000,
					pkt + 2,
					Max_Enc_Frame);
				if(enc_n < 0) {
					qunlock(&opus_state.l);
					error("opus_encode failed");
				}
				pkt[0] = (enc_n >> 8) & 0xff;
				pkt[1] = enc_n & 0xff;
				qproduce(opus_state.enc_q, pkt, enc_n + 2);
				opus_state.enc_out_frames++;
				/* shift remainder down */
				memmove(opus_state.enc_pcm,
					opus_state.enc_pcm + fpb,
					opus_state.enc_pcm_len - fpb);
				opus_state.enc_pcm_len -= fpb;
			}
		}
		qunlock(&opus_state.l);
		return n;

	case Qdec:
		/* Accumulate opus bytes; consume one length-prefixed frame
		 * at a time, decode it, push PCM onto dec_q. */
		qlock(&opus_state.l);
		got = 0;
		while(got < n) {
			int take = sizeof opus_state.dec_in - opus_state.dec_in_len;
			if(take > n - got) take = n - got;
			memmove(opus_state.dec_in + opus_state.dec_in_len,
				p + got, take);
			opus_state.dec_in_len += take;
			got += take;
			for(;;) {
				int flen, dec_n;
				short pcm[48000/1000*120*2];	/* worst case 120ms @ 48k stereo */
				if(opus_state.dec_in_len < 2)
					break;
				flen = (opus_state.dec_in[0] << 8) | opus_state.dec_in[1];
				if(flen > Max_Enc_Frame) {
					qunlock(&opus_state.l);
					error("opus frame length absurd");
				}
				if(opus_state.dec_in_len < 2 + flen)
					break;
				dec_n = opus_decode(opus_state.dec,
					opus_state.dec_in + 2, flen,
					pcm,
					opus_state.rate * 120 / 1000,
					0);
				if(dec_n < 0) {
					qunlock(&opus_state.l);
					error("opus_decode failed");
				}
				qproduce(opus_state.dec_q, pcm,
					dec_n * opus_state.chans * 2);
				opus_state.dec_pcm_bytes += dec_n * opus_state.chans * 2;
				opus_state.dec_in_frames++;
				memmove(opus_state.dec_in,
					opus_state.dec_in + 2 + flen,
					opus_state.dec_in_len - 2 - flen);
				opus_state.dec_in_len -= 2 + flen;
			}
		}
		qunlock(&opus_state.l);
		return n;
	}
	return 0;
#else  /* !HAVE_OPUS */
	USED(c); USED(va); USED(n); USED(off);
	error("devopus: built without libopus");
	return 0;
#endif
}

Dev opusdevtab = {
	'Z',
	"opus",

	opusinit,
	opusattach,
	opuswalk,
	opusstat,
	opusopen,
	devcreate,
	opusclose,
	opusread,
	devbread,
	opuswrite,
	devbwrite,
	devremove,
	devwstat
};

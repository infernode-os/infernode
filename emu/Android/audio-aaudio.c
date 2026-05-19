/*
 * Android AAudio backend for /dev/audio.
 *
 * Replaces Phase 0's no-op stub. Provides mic capture (audio_file_read)
 * and speaker playback (audio_file_write) by mapping the Inferno audio
 * surface onto AAudioStream input/output pairs.
 *
 * AAudio is the low-latency audio API in Android NDK since API 26.
 * We target 28+ (the Inferno target floor), where AAudio is fully
 * supported on stock arm64 hardware.
 *
 * Limitations of this v1 implementation (Phase 1b):
 *   * 16-bit signed PCM, mono, sample-rate from Default_Audio_Format
 *     (typically 44100). audio_ctl_write parses requests but only
 *     applies rate/channels at the next stream open — there is no
 *     live reconfiguration mid-stream.
 *   * audio_ctl_write currently honours rate / chan / bits / encoding
 *     fields; mixer gain (left/right, vol) is parsed and stored in
 *     the Audio_t but not yet pushed at AAudio (no native mixer API
 *     — would need to go through AAudioStreamBuilder_setUsage or
 *     OpenSL ES for explicit gain control).
 *   * One global input + one global output stream; multiple concurrent
 *     opens share them. Sufficient for the test pattern of a single
 *     recorder + a single player.
 */

#include <sys/cdefs.h>

#ifndef __BIONIC__
#error "audio-aaudio.c is the Android/Bionic audio backend"
#endif

#include "dat.h"
#include "fns.h"
#include "error.h"
#include "audio.h"

#include <aaudio/AAudio.h>

/* audio-tbls.c references these constants for the table entries; map
 * them to AAudio values where there is a direct equivalent, dummy
 * integers otherwise. The values are never dereferenced as AAudio
 * tokens — they are just the indices the Inferno ctl machinery uses
 * to identify devices and encodings. */
#define Audio_Mic_Val		1
#define Audio_Linein_Val	2
#define Audio_Speaker_Val	3
#define Audio_Headphone_Val	4
#define Audio_Lineout_Val	5
#define Audio_Pcm_Val		AAUDIO_FORMAT_PCM_I16
#define Audio_Ulaw_Val		AAUDIO_FORMAT_INVALID  /* not supported by AAudio */
#define Audio_Alaw_Val		AAUDIO_FORMAT_INVALID

#include "audio-tbls.c"

enum {
	A_Pause,
	A_UnPause,
};

static struct {
	AAudioStream *in;	/* capture stream, or NULL */
	AAudioStream *out;	/* playback stream, or NULL */
	int pause;
	QLock lk;		/* protects in/out pointers */
} aa = {
	.in = nil,
	.out = nil,
	.pause = A_UnPause,
};

static Audio_t av;
static QLock inlock;	/* serialises audio_file_read */
static QLock outlock;	/* serialises audio_file_write */

Audio_t*
getaudiodev(void)
{
	return &av;
}

void
audio_file_init(void)
{
	/* Inferno fills av lazily from the default ctl values when /dev/audio
	 * is opened; nothing to do at init time. */
}

/* Open an AAudio stream in the requested direction with the current av
 * format. Returns the stream on success; raises an Inferno error
 * (which longjmps) on failure. */
static AAudioStream*
openstream(aaudio_direction_t dir)
{
	AAudioStreamBuilder *b;
	AAudioStream *s;
	aaudio_result_t r;
	Audio_d *fmt;
	ulong rate, chans;

	r = AAudio_createStreamBuilder(&b);
	if(r != AAUDIO_OK)
		error("AAudio: createStreamBuilder failed");

	fmt = (dir == AAUDIO_DIRECTION_INPUT) ? &av.in : &av.out;
	rate  = fmt->rate  ? fmt->rate  : 44100;
	chans = fmt->chan  ? fmt->chan  : 1;

	AAudioStreamBuilder_setDirection(b, dir);
	AAudioStreamBuilder_setSampleRate(b, (int32_t)rate);
	AAudioStreamBuilder_setChannelCount(b, (int32_t)chans);
	AAudioStreamBuilder_setFormat(b, AAUDIO_FORMAT_PCM_I16);
	AAudioStreamBuilder_setPerformanceMode(b, AAUDIO_PERFORMANCE_MODE_NONE);
	AAudioStreamBuilder_setSharingMode(b, AAUDIO_SHARING_MODE_SHARED);

	r = AAudioStreamBuilder_openStream(b, &s);
	AAudioStreamBuilder_delete(b);
	if(r != AAUDIO_OK)
		error("AAudio: openStream failed");

	r = AAudioStream_requestStart(s);
	if(r != AAUDIO_OK){
		AAudioStream_close(s);
		error("AAudio: requestStart failed");
	}
	return s;
}

static void
closestream(AAudioStream **sp)
{
	AAudioStream *s = *sp;
	if(s == nil)
		return;
	*sp = nil;
	/* requestStop is best-effort; close releases regardless. */
	(void)AAudioStream_requestStop(s);
	AAudioStream_close(s);
}

void
audio_file_open(Chan *c, int omode)
{
	int mode;

	USED(c);
	qlock(&aa.lk);
	if(waserror()){
		qunlock(&aa.lk);
		nexterror();
	}
	mode = omode & 3;
	if((mode == OREAD || mode == ORDWR) && aa.in == nil)
		aa.in = openstream(AAUDIO_DIRECTION_INPUT);
	if((mode == OWRITE || mode == ORDWR) && aa.out == nil)
		aa.out = openstream(AAUDIO_DIRECTION_OUTPUT);
	poperror();
	qunlock(&aa.lk);
}

void
audio_file_close(Chan *c)
{
	USED(c);
	qlock(&aa.lk);
	closestream(&aa.in);
	closestream(&aa.out);
	qunlock(&aa.lk);
}

/* Bytes <-> frames for the current format. AAudio works in frames
 * (one sample × N channels); Inferno works in bytes. */
static long
frame_bytes(Audio_d *fmt)
{
	ulong chans = fmt->chan ? fmt->chan : 1;
	return (long)(sizeof(int16_t) * chans);
}

long
audio_file_read(Chan *c, void *va, long count, vlong offset)
{
	aaudio_result_t r;
	int32_t frames, fb;

	USED(c); USED(offset);

	qlock(&inlock);
	if(waserror()){
		qunlock(&inlock);
		nexterror();
	}
	if(aa.in == nil)
		error("audio: not opened for input");
	fb = (int32_t)frame_bytes(&av.in);
	frames = (int32_t)(count / fb);
	if(frames <= 0){
		poperror();
		qunlock(&inlock);
		return 0;
	}
	/* 1-second per-call timeout. AAudioStream_read returns the number
	 * of frames actually read; negative is an error. */
	r = AAudioStream_read(aa.in, va, frames, 1000LL * 1000LL * 1000LL);
	if(r < 0)
		error("AAudio: read failed");
	poperror();
	qunlock(&inlock);
	return (long)r * fb;
}

long
audio_file_write(Chan *c, void *va, long count, vlong offset)
{
	aaudio_result_t r;
	int32_t frames, fb;

	USED(c); USED(offset);

	qlock(&outlock);
	if(waserror()){
		qunlock(&outlock);
		nexterror();
	}
	if(aa.out == nil)
		error("audio: not opened for output");
	fb = (int32_t)frame_bytes(&av.out);
	frames = (int32_t)(count / fb);
	if(frames <= 0){
		poperror();
		qunlock(&outlock);
		return 0;
	}
	r = AAudioStream_write(aa.out, va, frames, 1000LL * 1000LL * 1000LL);
	if(r < 0)
		error("AAudio: write failed");
	poperror();
	qunlock(&outlock);
	return (long)r * fb;
}

long
audio_ctl_write(Chan *c, void *va, long count, vlong offset)
{
	/* Inferno's audioparse() reads ctl text and updates av in place.
	 * The new settings only take effect at the next stream open — see
	 * file-header note. */
	int n;

	USED(c); USED(offset);
	n = audioparse(va, count, &av);
	return n;
}

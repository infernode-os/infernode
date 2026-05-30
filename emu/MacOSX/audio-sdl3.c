/*
 * audio-sdl3.c — SDL3-backed implementation of emu/port/audio.h for the
 * macOS InferNode emulator. The contract (audio_file_{init,open,read,
 * write,close}, audio_ctl_write) is the standard Inferno devaudio
 * platform interface — see audio.h and the FreeBSD/Linux backends.
 *
 * Why SDL3 instead of CoreAudio direct: SDL3 is already linked into the
 * GUI build, so this is ~150 lines instead of ~500, and the same source
 * file can later cover iOS (AVAudioEngine via SDL3) and Linux/Wayland
 * once the legacy OSS backend is retired. v0 — INFR-185 Mac↔Mac voice
 * spike.
 *
 * Threading: SDL3 audio streams are themselves thread-safe (the SDL
 * audio callback runs on its own thread; SDL_{Get,Put}AudioStreamData
 * lock internally). We add QLocks only around the lazy
 * SDL_OpenAudioDeviceStream calls so two simultaneous opens of the
 * same direction don't race.
 *
 * Blocking semantics: Inferno read() on /dev/audio must block until at
 * least one sample is available. SDL3 returns 0 from
 * SDL_GetAudioStreamData when the ring is empty, so we poll with a
 * 5 ms SDL_Delay — same shape devaudio Linux/OSS uses (read(2) on the
 * OSS fd blocks on the kernel, here we block in user space). For a
 * 44.1 kHz stereo 16-bit stream that's ~880 frames per wakeup — fine
 * for voice latency (~10-20 ms end-to-end).
 *
 * Permissions: the first SDL_OpenAudioDeviceStream(RECORDING, ...) on
 * macOS triggers the TCC microphone prompt. For a command-line emu
 * there is no Info.plist, so first launch the user must approve via
 * System Settings -> Privacy & Security -> Microphone (the prompt
 * shows "InferNode emu" if launched from Finder, terminal name if
 * launched from a shell). Until approved, capture returns silence.
 */

#include "dat.h"
#include "fns.h"
#include "error.h"
#include "audio.h"

/*
 * GUI_SDL3 is defined by mkfile-gui-sdl3 (GUIFLAGS=-DGUI_SDL3 ...).
 * Without it (the headless macOS build), SDL3 headers aren't on the
 * include path, so we fall through to the no-op stubs at the bottom
 * of this file. devaudio.c still gets the symbols it links against;
 * /dev/audio just behaves like the legacy "device unavailable" stub
 * (open succeeds, read returns 0, write is a sink).
 */
#ifdef GUI_SDL3
#include <SDL3/SDL.h>
#endif

/*
 * Token values for audio-tbls.c's source/format string maps. The OSS
 * backends use kernel mixer/encoding constants; here the values are
 * only meaningful inside this file (passed back to the caller of
 * audioctl read, never re-interpreted by SDL3), so any distinct ints
 * will do.
 */
#define Audio_Mic_Val		1
#define Audio_Linein_Val	2
#define Audio_Speaker_Val	1
#define Audio_Headphone_Val	2
#define Audio_Lineout_Val	3
#define Audio_Pcm_Val		1
#define Audio_Ulaw_Val		2
#define Audio_Alaw_Val		3

#include "audio-tbls.c"

#ifdef GUI_SDL3

/*
 * Platform-specific audio session setup, called once before
 * SDL_InitSubSystem(SDL_INIT_AUDIO). Today this matters on iOS, where
 * AVAudioSession must be configured to .playAndRecord with .voiceChat
 * mode for the SDL3 audio device to (a) get the recording category
 * (.soloAmbient is the default and silently disables capture) and
 * (b) route through Apple's hardware AEC so two phones in the same
 * room don't feed back. The iOS shim (emu/iOS/audio-sdl3.c) defines
 * AUDIO_PLATFORM_INIT_EXTERN before including this file, so the
 * external symbol below is linked in from emu/iOS/audiosession.m.
 * macOS / Linux desktop builds get the no-op static stub. INFR-186.
 */
#ifdef AUDIO_PLATFORM_INIT_EXTERN
extern void audio_platform_init(void);
/*
 * Foreground-gated microphone permission primer (INFR-190). Defined in
 * emu/iOS/audiosession.m alongside audio_platform_init. App-delegate
 * hooks (applicationDidBecomeActive:/sceneDidBecomeActive:) call this so
 * the iOS permission prompt is forced from a real foreground context;
 * audio_platform_init also invokes it on its own foreground branch.
 */
extern void audio_request_record_permission_foreground(void);
#else
static void audio_platform_init(void) { }
#endif

static int sdl_audio_inited;		/* SDL_InitSubSystem(SDL_INIT_AUDIO) done? */
static SDL_AudioStream *in_stream;	/* mic capture */
static SDL_AudioStream *out_stream;	/* speaker playback */
static QLock inlock;
static QLock outlock;
static int in_refcnt;			/* opens still holding /dev/audio for read */
static int out_refcnt;			/* opens still holding /dev/audio for write */
static Audio_t av;			/* current format (in.rate / chan / bits, out.*) */

static SDL_AudioFormat
sdlfmt(ulong bits)
{
	if(bits == 8)
		return SDL_AUDIO_S8;
	/* 16-bit little-endian is the Inferno default per audio(3). */
	return SDL_AUDIO_S16LE;
}

static int
ensure_sdl_audio(void)
{
	if(sdl_audio_inited)
		return 1;
	/* Configure AVAudioSession (or platform equivalent) before SDL
	 * touches CoreAudio — no-op on macOS/Linux desktop, real impl on
	 * iOS. INFR-186. */
	audio_platform_init();
	/* SDL_InitSubSystem is idempotent and safe to call after SDL_Init
	 * (the GUI backend calls SDL_Init(SDL_INIT_VIDEO) at startup). */
	if(!SDL_InitSubSystem(SDL_INIT_AUDIO)) {
		fprint(2, "audio-sdl3: SDL_InitSubSystem failed: %s\n",
			SDL_GetError());
		return 0;
	}
	sdl_audio_inited = 1;
	return 1;
}

static SDL_AudioStream *
open_stream(SDL_AudioDeviceID dev, Audio_d *fmt)
{
	SDL_AudioSpec spec;
	SDL_AudioStream *s;

	spec.format = sdlfmt(fmt->bits);
	spec.channels = (int)fmt->chan;
	spec.freq = (int)fmt->rate;

	s = SDL_OpenAudioDeviceStream(dev, &spec, NULL, NULL);
	if(s == NULL) {
		/* Inferno's `listen { ... & }` builtin forks the parent
		 * process to run the accept block; SDL3's audio subsystem
		 * state doesn't survive across that fork on macOS (the
		 * CoreAudio thread is in the parent address space only),
		 * so the child sees "Audio subsystem is not initialized"
		 * the first time it touches the device even though our
		 * sdl_audio_inited static is still 1. Retry once after a
		 * forced re-init — that brings the audio subsystem back up
		 * in the child without disturbing the parent. */
		const char *err = SDL_GetError();
		if(err != nil && strstr(err, "not initialized") != nil) {
			SDL_QuitSubSystem(SDL_INIT_AUDIO);
			sdl_audio_inited = 0;
			if(SDL_InitSubSystem(SDL_INIT_AUDIO)) {
				sdl_audio_inited = 1;
				s = SDL_OpenAudioDeviceStream(dev, &spec, NULL, NULL);
			}
		}
	}
	if(s == NULL) {
		fprint(2, "audio-sdl3: SDL_OpenAudioDeviceStream(%s) failed: %s\n",
			dev == SDL_AUDIO_DEVICE_DEFAULT_RECORDING ? "rec" : "play",
			SDL_GetError());
		return NULL;
	}
	/* Streams are bound paused — resume so data starts flowing. */
	SDL_ResumeAudioStreamDevice(s);
	return s;
}

void
audio_file_init(void)
{
	audio_info_init(&av);
	/* SDL_InitSubSystem is deferred until first open so a headless
	 * build with no audio HW (e.g. CI runners) doesn't pay startup
	 * cost or trigger a TCC prompt it can't satisfy. */
}

Audio_t*
getaudiodev(void)
{
	return &av;
}

void
audio_ctl_init(void)
{
}

void
audio_file_open(Chan *c, int omode)
{
	if(!ensure_sdl_audio())
		error(Eperm);

	if(omode == OREAD || omode == ORDWR) {
		qlock(&inlock);
		if(in_stream == NULL) {
			in_stream = open_stream(SDL_AUDIO_DEVICE_DEFAULT_RECORDING,
						&av.in);
			if(in_stream == NULL) {
				qunlock(&inlock);
				error("audio in unavailable");
			}
		}
		in_refcnt++;
		qunlock(&inlock);
	}
	if(omode == OWRITE || omode == ORDWR) {
		qlock(&outlock);
		if(out_stream == NULL) {
			out_stream = open_stream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK,
						 &av.out);
			if(out_stream == NULL) {
				/* clean up the input we just acquired */
				if(omode == ORDWR) {
					qlock(&inlock);
					if(--in_refcnt == 0 && in_stream) {
						SDL_DestroyAudioStream(in_stream);
						in_stream = NULL;
					}
					qunlock(&inlock);
				}
				qunlock(&outlock);
				error("audio out unavailable");
			}
		}
		out_refcnt++;
		qunlock(&outlock);
	}
}

long
audio_file_read(Chan *c, void *va, long n, vlong off)
{
	long got = 0;
	int r;

	USED(c); USED(off);
	if(in_stream == NULL)
		return 0;

	/* Block until at least one byte is available. Inferno read(2) is
	 * blocking on devaudio; SDL3 returns 0 on empty so we poll with
	 * a short delay. */
	while(got == 0) {
		r = SDL_GetAudioStreamData(in_stream, (char*)va, (int)n);
		if(r < 0)
			error((char*)SDL_GetError());
		if(r > 0) {
			got = r;
			break;
		}
		SDL_Delay(5);	/* ~220 frames @ 44.1k stereo 16-bit */
	}
	return got;
}

long
audio_file_write(Chan *c, void *va, long n, vlong off)
{
	USED(c); USED(off);
	if(out_stream == NULL)
		return 0;
	if(!SDL_PutAudioStreamData(out_stream, va, (int)n))
		error((char*)SDL_GetError());
	return n;
}

long
audio_ctl_write(Chan *c, void *va, long n, vlong off)
{
	Audio_t tmp;
	int r;

	USED(c); USED(off);
	/* Parse the verb into a scratch struct first so a malformed line
	 * leaves the live av untouched. audioparse mutates only the
	 * fields the verb mentions, so we start from a copy of av. */
	tmp = av;
	r = audioparse((char*)va, (int)n, &tmp);
	if(r < 0)
		error("audio ctl: bad verb");

	/* Apply: if rate/chan/bits changed on the input side and a stream
	 * is open, we'd need to reopen it. For v0 we only reopen on
	 * mismatch — small enough cost that callers don't notice. */
	if(in_stream &&
	   (tmp.in.rate != av.in.rate || tmp.in.chan != av.in.chan ||
	    tmp.in.bits != av.in.bits)) {
		qlock(&inlock);
		SDL_DestroyAudioStream(in_stream);
		in_stream = open_stream(SDL_AUDIO_DEVICE_DEFAULT_RECORDING,
					&tmp.in);
		qunlock(&inlock);
	}
	if(out_stream &&
	   (tmp.out.rate != av.out.rate || tmp.out.chan != av.out.chan ||
	    tmp.out.bits != av.out.bits)) {
		qlock(&outlock);
		SDL_DestroyAudioStream(out_stream);
		out_stream = open_stream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK,
					 &tmp.out);
		qunlock(&outlock);
	}
	av = tmp;
	return n;
}

void
audio_file_close(Chan *c)
{
	if(c->mode == OREAD || c->mode == ORDWR) {
		qlock(&inlock);
		if(--in_refcnt <= 0) {
			in_refcnt = 0;
			if(in_stream) {
				SDL_DestroyAudioStream(in_stream);
				in_stream = NULL;
			}
		}
		qunlock(&inlock);
	}
	if(c->mode == OWRITE || c->mode == ORDWR) {
		qlock(&outlock);
		if(--out_refcnt <= 0) {
			out_refcnt = 0;
			if(out_stream) {
				/*
				 * Drain queued playback before destroying the
				 * stream. SDL3 keeps a ring of un-played bytes;
				 * SDL_DestroyAudioStream silently discards them.
				 * audiotone hits this hard: writes 882 kB in
				 * milliseconds, the device thread plays at
				 * 176 kB/s, and the FD close arrives long
				 * before the device has caught up. Result: the
				 * caller hears the first ~500 ms and the rest
				 * vanishes. INFR-185.
				 *
				 * Cap the wait so a stuck device can't pin a
				 * close forever — DRAIN_MAX_MS is generous
				 * enough for any reasonable foreground tone
				 * (audiotone is 5 s, so 8 s gives headroom).
				 */
				int waited = 0;
				int DRAIN_MAX_MS = 8000;
				SDL_FlushAudioStream(out_stream);
				while(SDL_GetAudioStreamQueued(out_stream) > 0
				      && waited < DRAIN_MAX_MS) {
					SDL_Delay(20);
					waited += 20;
				}
				SDL_DestroyAudioStream(out_stream);
				out_stream = NULL;
			}
		}
		qunlock(&outlock);
	}
}

#else  /* !GUI_SDL3 — headless build, no SDL3 in the link */

/*
 * Stub backend for headless builds. The emu config still lists `audio`
 * (the device table is shared between GUI and headless mkfiles, and
 * mkdevlist doesn't gate on GUIBACK), so devaudio links against these
 * symbols. /dev/audio appears in the namespace; opening it succeeds,
 * reads return EOF, writes are sinks. No noise from a headless CI
 * runner, no missing-symbol link error.
 */

static Audio_t av;

void
audio_file_init(void)
{
	audio_info_init(&av);
}

void
audio_ctl_init(void)
{
}

Audio_t*
getaudiodev(void)
{
	return &av;
}

void
audio_file_open(Chan *c, int omode)
{
	USED(c); USED(omode);
}

long
audio_file_read(Chan *c, void *va, long n, vlong off)
{
	USED(c); USED(va); USED(n); USED(off);
	return 0;
}

long
audio_file_write(Chan *c, void *va, long n, vlong off)
{
	USED(c); USED(va); USED(off);
	return n;
}

long
audio_ctl_write(Chan *c, void *va, long n, vlong off)
{
	USED(c); USED(va); USED(off);
	return n;
}

void
audio_file_close(Chan *c)
{
	USED(c);
}

#endif /* GUI_SDL3 */

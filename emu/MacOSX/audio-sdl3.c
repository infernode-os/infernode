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

/*
 * Per-stream queue caps in milliseconds (INFR-194). Shared
 * by the SDL3 backend and the headless stub so audioctl can report
 * what was written even when there is no queue to cap.
 *
 * Defaults are 0 (no cap) so non-voice workloads — audiotone, music
 * playback, anything that bulk-writes ahead of the device — keep
 * smooth, unbounded queueing. Voice opts in by writing to the ctl:
 *
 *   echo 'play_buffer_ms 100' > /dev/audioctl
 *   echo 'rec_buffer_ms  100' > /dev/audioctl
 *
 * Drop policy on the SDL3 path is HEAD-drop. Headless stores the
 * verbs only.
 */
static int play_buffer_ms = 0;
static int rec_buffer_ms  = 0;

static void
audio_get_buffer_ms(int *play, int *rec)
{
	*play = play_buffer_ms;
	*rec = rec_buffer_ms;
}

static int
audio_parse_buffer_ms(char *s, long n)
{
	if(n > 15 && memcmp(s, "play_buffer_ms ", 15) == 0){
		play_buffer_ms = atoi(s + 15);
		return 1;
	}
	if(n > 14 && memcmp(s, "rec_buffer_ms ", 14) == 0){
		rec_buffer_ms = atoi(s + 14);
		return 1;
	}
	return 0;
}



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
static int sdl_quiet_host;		/* probed once: the host has no audio devices */
static SDL_AudioStream *in_stream;	/* mic capture */
static SDL_AudioStream *out_stream;	/* speaker playback */
static QLock inlock;
static QLock outlock;
static int in_refcnt;			/* opens still holding /dev/audio for read */
static int out_refcnt;			/* opens still holding /dev/audio for write */

static void
select_audio_driver(void)
{
#ifdef __ANDROID__
	/* Android API 28+ ships AAudio and the APK links SDL3's AAudio backend. */
	SDL_SetHint(SDL_HINT_AUDIO_DRIVER, "aaudio");
#else
	/* macOS and iOS use SDL3's CoreAudio backend. */
	SDL_SetHint(SDL_HINT_AUDIO_DRIVER, "coreaudio");
#endif
}
static Audio_t av;			/* current format (in.rate / chan / bits, out.*) */

/*
 * SDL3 applies play_buffer_ms / rec_buffer_ms as queue depth caps
 * (INFR-194). See the shared statics above audio_get_buffer_ms.
 */


/* bytes-per-second for a given Audio_d — used to translate the
 * per-direction buffer cap from ms to bytes against the live format. */
static int
audio_bytes_per_sec(Audio_d *fmt)
{
	int bytes_per_sample = fmt->bits / 8;
	if(bytes_per_sample <= 0)
		bytes_per_sample = 2;
	return (int)fmt->rate * (int)fmt->chan * bytes_per_sample;
}

static SDL_AudioFormat
sdlfmt(ulong bits)
{
	if(bits == 8)
		return SDL_AUDIO_S8;
	/* 16-bit little-endian is the Inferno default per audio(3). */
	return SDL_AUDIO_S16LE;
}

/* Retry budget for an audio subsystem that comes up with an empty device
 * list — see ensure_sdl_audio. */
#define AUDIO_INIT_TRIES	20
#define AUDIO_INIT_DELAY_MS	50

static int
audio_devices_present(void)
{
	int nrec = 0, nplay = 0;
	SDL_AudioDeviceID *rec, *play;

	rec = SDL_GetAudioRecordingDevices(&nrec);
	play = SDL_GetAudioPlaybackDevices(&nplay);
	if(rec != nil)
		SDL_free(rec);
	if(play != nil)
		SDL_free(play);
	return nrec > 0 || nplay > 0;
}

static int
sdl_streams_live(void)
{
	return in_stream != NULL || out_stream != NULL;
}

static int
ensure_sdl_audio(void)
{
	int i;

	/* An earlier caller may have left the subsystem up with an empty
	 * device list. That state never recovers on its own, so re-init
	 * rather than trusting the flag — but only once: a host that came
	 * up with no devices stays device-less as far as this probe is
	 * concerned, and re-running the bounded probe below on every call
	 * would block each /dev/audio open and audioctl read for a second
	 * or more, forever. SDL still notices devices that appear later:
	 * the subsystem is left up, and SDL3 refreshes its device list
	 * while it runs. */
	if(sdl_audio_inited) {
		if(sdl_quiet_host || audio_devices_present())
			return 1;
		/* Tearing the subsystem down under a live stream leaves
		 * the stream pointer dangling; the next
		 * SDL_DestroyAudioStream would be a use-after-free. Leave
		 * it up instead. */
		if(sdl_streams_live())
			return 1;
		SDL_QuitSubSystem(SDL_INIT_AUDIO);
		sdl_audio_inited = 0;
	}
	/* Configure AVAudioSession (or platform equivalent) before SDL
	 * touches CoreAudio — no-op on macOS/Linux desktop, real impl on
	 * iOS. INFR-186. */
	audio_platform_init();
	/*
	 * Use SDL_Init, not SDL_InitSubSystem (INFR-195). The headless
	 * macOS emu never calls SDL_Init(SDL_INIT_VIDEO) (only the GUI
	 * build does), so SDL_InitSubSystem(SDL_INIT_AUDIO) ran without
	 * a prior SDL_Init and silently produced an audio subsystem that
	 * SDL_OpenAudioDeviceStream later rejected as "not initialized."
	 * SDL_Init is the canonical entry point and works whether or not
	 * a subsystem has already been brought up; it's a no-op past the
	 * first invocation for the same flags.
	 *
	 * Select the platform's real audio driver explicitly — without this,
	 * SDL3 can silently fall back to a dummy driver in a non-GUI process.
	 * Android uses AAudio; Apple targets use CoreAudio.
	 */
	/*
	 * SDL_Init can report success while the driver still enumerates no
	 * devices at all. An audio subsystem in that state is useless: every
	 * open fails with "No default audio device available", and the
	 * failure is indistinguishable from a machine with no sound card.
	 * Bring the subsystem back up until the devices appear, bounded so a
	 * genuinely silent host (CI, headless runner) still settles quickly
	 * and fails the open the way it always has.
	 */
	for(i = 0;; i++) {
		select_audio_driver();
		if(!SDL_Init(SDL_INIT_AUDIO)) {
			fprint(2, "audio-sdl3: SDL_Init(SDL_INIT_AUDIO) failed: %s\n",
				SDL_GetError());
			return 0;
		}
		if(audio_devices_present() || i >= AUDIO_INIT_TRIES)
			break;
		SDL_QuitSubSystem(SDL_INIT_AUDIO);
		SDL_Delay(AUDIO_INIT_DELAY_MS);
	}
	sdl_audio_inited = 1;
	if(!audio_devices_present())
		sdl_quiet_host = 1;
	return 1;
}

/*
 * Host device selection (see audio.h). Empty means "follow the system
 * default", which is what the emulator did unconditionally before.
 */
static char in_devname[128];
static char out_devname[128];

/* Capture-silence accounting. A device that opens and then delivers
 * nothing but zeroes is the failure this selection exists to diagnose:
 * a virtual input from an app that is not running, an OS-muted device,
 * or missing microphone authorization all look identical to a working
 * microphone in a quiet room until you count the samples. */
static vlong cap_bytes;
static vlong cap_nonzero;
static int cap_warned;
static Uint64 cap_opened_ms;

/* How long a capture may stay all-zero before it is worth saying so.
 * Measured in wall time rather than bytes: the devices that fail this
 * way often deliver almost no data either, so a byte threshold can take
 * minutes to reach — or never arrive at all. */
#define CAP_SILENT_MS	2000

static SDL_AudioDeviceID
find_device(int isin, const char *name)
{
	SDL_AudioDeviceID *ids, id = 0;
	const char *dn;
	int i, n = 0;

	ids = isin ? SDL_GetAudioRecordingDevices(&n)
		   : SDL_GetAudioPlaybackDevices(&n);
	if(ids == nil)
		return 0;
	for(i = 0; i < n; i++) {
		dn = SDL_GetAudioDeviceName(ids[i]);
		if(dn != nil && strcmp(dn, name) == 0) {
			id = ids[i];
			break;
		}
	}
	SDL_free(ids);
	return id;
}

/*
 * Resolve the configured name to a live SDL id at open time. A name that
 * matches nothing falls back to the system default rather than failing
 * the open: devices are unplugged, and a warning plus the default beats
 * a voice stack that refuses to start.
 */
static SDL_AudioDeviceID
selected_device(int isin)
{
	SDL_AudioDeviceID id;
	char *name = isin ? in_devname : out_devname;

	if(name[0] != 0) {
		if((id = find_device(isin, name)) != 0)
			return id;
		fprint(2, "audio-sdl3: no %s device named \"%s\"; "
			"using the system default\n",
			isin ? "input" : "output", name);
	}
	return isin ? SDL_AUDIO_DEVICE_DEFAULT_RECORDING
		    : SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK;
}

static SDL_AudioStream *
open_stream(int isin, Audio_d *fmt)
{
	SDL_AudioDeviceID dev = selected_device(isin);
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
			/*
			 * Recovery path: the listener's export worker can run
			 * in a kproc with stale SDL state. Quit just the audio
			 * subsystem and re-init it via SDL_Init (not
			 * SubSystem, see ensure_sdl_audio for why). Do NOT
			 * call SDL_Quit — that's process-wide and would tear
			 * down the parent's audio too. Skipped when a stream
			 * is live: quitting under an open stream leaves the
			 * pointer dangling (use-after-free on the next
			 * SDL_DestroyAudioStream); failing the open is safe.
			 */
			if(!sdl_streams_live()) {
				SDL_QuitSubSystem(SDL_INIT_AUDIO);
				sdl_audio_inited = 0;
				select_audio_driver();
				if(SDL_Init(SDL_INIT_AUDIO)) {
					sdl_audio_inited = 1;
					s = SDL_OpenAudioDeviceStream(dev, &spec, NULL, NULL);
				}
			}
		}
	}
	if(s == NULL) {
		fprint(2, "audio-sdl3: SDL_OpenAudioDeviceStream(%s) failed: %s (devices present: %s)\n",
			isin ? "rec" : "play",
			SDL_GetError(), audio_devices_present() ? "yes" : "no");
		return NULL;
	}
	/* Streams are bound paused — resume so data starts flowing. */
	SDL_ResumeAudioStreamDevice(s);
	return s;
}

/*
 * #A/audiodev readback. Names are quoted because almost every real one
 * contains spaces, and quoting makes a line from this read valid input to
 * the same file. The trailing capture line reports whether the input
 * device has actually produced a non-zero sample, which is the one thing
 * that distinguishes a silenced or virtual microphone from a quiet room.
 */
static int
sdl_devs_list(char *buf, char *e)
{
	SDL_AudioDeviceID *ids;
	const char *dn, *sel;
	char *p = buf;
	int dir, i, n;

	if(!ensure_sdl_audio())
		return snprint(buf, e - buf, "unavailable\n");

	for(dir = 1; dir >= 0; dir--) {
		sel = dir ? in_devname : out_devname;
		if(sel[0] != 0)
			p = seprint(p, e, "%s selected '%s'\n",
				dir ? "in" : "out", sel);
		else
			p = seprint(p, e, "%s selected default\n",
				dir ? "in" : "out");
		ids = dir ? SDL_GetAudioRecordingDevices(&n)
			  : SDL_GetAudioPlaybackDevices(&n);
		if(ids == nil)
			continue;
		for(i = 0; i < n; i++) {
			dn = SDL_GetAudioDeviceName(ids[i]);
			if(dn != nil)
				p = seprint(p, e, "%s device '%s'\n",
					dir ? "in" : "out", dn);
		}
		SDL_free(ids);
	}

	/* Reported for the most recent capture, not only a live one: the
	 * useful question is "did that recording hear anything", and it is
	 * usually asked after the stream has been closed again. */
	if(cap_bytes == 0)
		p = seprint(p, e, "capture idle\n");
	else if(cap_nonzero > 0)
		p = seprint(p, e, "capture active\n");
	else
		p = seprint(p, e, "capture silent\n");

	return p - buf;
}

/*
 * Take effect immediately: a stream already open on the old device is
 * reopened on the new one, so an operator can fix a wrong input device
 * without restarting the voice stack.
 */
static int
sdl_devs_select(int isin, char *name)
{
	/* Selection can arrive before anything has opened /dev/audio, and
	 * SDL enumerates nothing until the subsystem is up — without this
	 * every name looks unknown. */
	if(name[0] != 0) {
		if(!ensure_sdl_audio())
			return -1;
		if(find_device(isin, name) == 0)
			return -1;
	}

	if(isin) {
		qlock(&inlock);
		snprint(in_devname, sizeof in_devname, "%s", name);
		if(in_stream != NULL) {
			SDL_DestroyAudioStream(in_stream);
			cap_bytes = cap_nonzero = 0;
			cap_warned = 0;
			cap_opened_ms = SDL_GetTicks();
			in_stream = open_stream(1, &av.in);
		}
		qunlock(&inlock);
	} else {
		qlock(&outlock);
		snprint(out_devname, sizeof out_devname, "%s", name);
		if(out_stream != NULL) {
			SDL_DestroyAudioStream(out_stream);
			out_stream = open_stream(0, &av.out);
		}
		qunlock(&outlock);
	}
	return 0;
}

static Audiodevops sdl_devops = { sdl_devs_list, sdl_devs_select };

/*
 * Starting device names from the host environment. A launcher that wants
 * a particular device — a test rig pointing capture at a virtual input,
 * a kiosk pinned to a USB headset — sets these before exec rather than
 * writing to #A/audiodev after boot, which would be too late: the voice
 * stack opens capture during startup. An unknown name is not validated
 * here (SDL is deliberately not up yet); selected_device warns and falls
 * back to the system default at open time.
 */
static void
devnames_from_env(void)
{
	char *s;

	if((s = getenv("INFERNODE_AUDIO_IN")) != nil && *s != 0)
		snprint(in_devname, sizeof in_devname, "%s", s);
	if((s = getenv("INFERNODE_AUDIO_OUT")) != nil && *s != 0)
		snprint(out_devname, sizeof out_devname, "%s", s);
}

void
audio_file_init(void)
{
	audio_info_init(&av);
	audio_devops_register(&sdl_devops);
	audio_bufcaps_register(audio_get_buffer_ms);

	devnames_from_env();
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
			cap_bytes = cap_nonzero = 0;
			cap_warned = 0;
			cap_opened_ms = SDL_GetTicks();
			in_stream = open_stream(1, &av.in);
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
			out_stream = open_stream(0, &av.out);
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

	/*
	 * Capture queue cap (INFR-194). If SDL has held onto more than
	 * `rec_buffer_ms` of audio (because nobody read from us fast
	 * enough), discard the stale portion. For voice that's right —
	 * the listener wants fresh mic, not minutes-old chatter. Set
	 * rec_buffer_ms=0 via ctl to disable.
	 */
	if(rec_buffer_ms > 0) {
		int cap = (int)((vlong)audio_bytes_per_sec(&av.in) *
				rec_buffer_ms / 1000);
		int queued = SDL_GetAudioStreamAvailable(in_stream);
		if(queued > cap) {
			char drop[4096];
			int over = queued - cap;
			while(over > 0) {
				int take = over > (int)sizeof drop
					? (int)sizeof drop : over;
				int r2 = SDL_GetAudioStreamData(in_stream,
					drop, take);
				if(r2 <= 0) break;
				over -= r2;
			}
		}
	}

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

	/* Count towards the silence diagnostic until the device has proved
	 * itself once; after that the scan stops costing anything. */
	if(cap_nonzero == 0) {
		uchar *b = va;
		long i;

		for(i = 0; i < got; i++)
			if(b[i] != 0) {
				cap_nonzero += got;
				break;
			}
		cap_bytes += got;
		if(cap_nonzero == 0 && !cap_warned &&
		   SDL_GetTicks() - cap_opened_ms > CAP_SILENT_MS) {
			fprint(2, "audio-sdl3: the capture device has produced "
				"nothing but silence for 2s — check the input "
				"device in #A/audiodev and microphone "
				"authorization\n");
			cap_warned = 1;
		}
	}
	return got;
}

long
audio_file_write(Chan *c, void *va, long n, vlong off)
{
	USED(c); USED(off);
	if(out_stream == NULL)
		return 0;

	/*
	 * Playback queue cap (INFR-194). Without this, SDL's stream
	 * queue grows unboundedly when the producer (a 9P export over
	 * the network, in voice's case) feeds data faster than the
	 * device drains at real time. A sustained Mac<->Samsung voice
	 * call drifted minutes behind the speaker because of this.
	 * Drop the stale head before writing the new tail. Set
	 * play_buffer_ms=0 via ctl to disable (audiotone, music, etc).
	 */
	if(play_buffer_ms > 0) {
		int cap = (int)((vlong)audio_bytes_per_sec(&av.out) *
				play_buffer_ms / 1000);
		int queued = SDL_GetAudioStreamQueued(out_stream);
		if(queued > cap) {
			SDL_ClearAudioStream(out_stream);
		}
	}

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

	/*
	 * Buffer-cap verbs (INFR-194). Parsed and stripped here before
	 * audioparse sees the rest of the line so audioparse doesn't
	 * have to learn about non-format verbs.
	 */
	if(audio_parse_buffer_ms((char*)va, n))
		return n;


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
		in_stream = open_stream(1, &tmp.in);
		qunlock(&inlock);
	}
	if(out_stream &&
	   (tmp.out.rate != av.out.rate || tmp.out.chan != av.out.chan ||
	    tmp.out.bits != av.out.bits)) {
		qlock(&outlock);
		SDL_DestroyAudioStream(out_stream);
		out_stream = open_stream(0, &tmp.out);
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
	audio_bufcaps_register(audio_get_buffer_ms);
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
	USED(c); USED(off);
	if(audio_parse_buffer_ms((char*)va, n))
		return n;
	USED(va);
	return n;
}


void
audio_file_close(Chan *c)
{
	USED(c);
}

#endif /* GUI_SDL3 */

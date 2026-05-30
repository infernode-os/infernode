implement Audiotone;

#
# audiotone — write a 1 kHz sine wave to /dev/audio for ~1 second.
#
# Smoke test for the SDL3 audio playback path on macOS (INFR-185 v0).
# The mic side needs a TCC-approved .app bundle to capture anything on
# macOS, but playback works from the bare CLI emu, so this is the
# loudest signal we can verify from a `cd $ROOT; ./emu/MacOSX/o.emu`
# invocation: if you hear a beep, audio_file_open + audio_file_write +
# SDL_PutAudioStreamData all wired right.
#
# Format matches Inferno's default per audio(3): 44.1 kHz, 2 channels,
# 16-bit little-endian, signed PCM.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "math.m";
	math: Math;

Audiotone: module {
	PATH: con "/dis/audiotone.dis";
	init: fn(nil: ref Draw->Context, args: list of string);
};

RATE: con 44100;
DURMS: con 1000;	# ms
FREQ: con 1000;		# Hz
AMP: con 8000;		# ~-12 dBFS — loud enough to hear, quiet enough
			# to be polite over a phone speaker

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;

	sys->bind("#A", "/dev", Sys->MAFTER);

	fd := sys->open("/dev/audio", Sys->OWRITE);
	if(fd == nil) {
		sys->fprint(sys->fildes(2),
			"audiotone: cannot open /dev/audio: %r\n");
		raise "fail";
	}

	nframes := RATE * DURMS / 1000;
	# 2 chans * 2 bytes/sample = 4 bytes/frame
	buf := array[4096] of byte;
	pos := 0;
	written := 0;

	math = load Math Math->PATH;
	if(math == nil) {
		sys->fprint(sys->fildes(2),
			"audiotone: cannot load math: %r\n");
		raise "fail";
	}

	for(i := 0; i < nframes; i++) {
		# 1 kHz sine at sample rate RATE
		t := real i / real RATE;
		v: int = int (real AMP * math->sin(2.0 * Math->Pi * real FREQ * t));
		# left and right both get v (mono signal)
		# little-endian S16
		for(ch := 0; ch < 2; ch++) {
			buf[pos++] = byte (v & 16rFF);
			buf[pos++] = byte ((v >> 8) & 16rFF);
		}
		if(pos >= len buf) {
			n := sys->write(fd, buf, pos);
			if(n != pos) {
				sys->fprint(sys->fildes(2),
					"audiotone: short write %d/%d: %r\n",
					n, pos);
				raise "fail";
			}
			written += n;
			pos = 0;
		}
	}
	if(pos > 0) {
		n := sys->write(fd, buf, pos);
		written += n;
	}
	sys->fprint(sys->fildes(2),
		"audiotone: wrote %d bytes (%d ms @ %d Hz)\n",
		written, DURMS, FREQ);

	# Hold the FD open until SDL3 has drained the queue. The write()
	# above just enqueues bytes in the SDL_AudioStream; the device
	# thread pulls them out at real-time pace. If we close before
	# the queue drains, audio_file_close destroys the stream and the
	# unplayed tail is lost — that's why a 200 ms grace was silent.
	# Sleep for the full audio duration plus a small device latency
	# allowance, then exit (which closes the FD cleanly).
	sys->sleep(DURMS + 500);
}

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
ONMS: con 250;		# ms of tone per pulse
OFFMS: con 250;		# ms of silence per pulse
NPULSES: con 10;	# total pulses (so ~5 s end-to-end)
FREQ: con 1000;		# Hz — pitch of the tone
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

	on_frames := RATE * ONMS / 1000;
	off_frames := RATE * OFFMS / 1000;
	# 2 chans * 2 bytes/sample = 4 bytes/frame
	buf := array[4096] of byte;
	pos := 0;
	written := 0;
	# phase counter advances continuously through the silent gaps too,
	# so consecutive pulses don't get phase-discontinuity clicks.
	phase := 0;

	math = load Math Math->PATH;
	if(math == nil) {
		sys->fprint(sys->fildes(2),
			"audiotone: cannot load math: %r\n");
		raise "fail";
	}

	for(p := 0; p < NPULSES; p++) {
		# on: NPULSES x ONMS of FREQ-Hz sine, then off: OFFMS silence.
		# Total frames per pulse = on_frames + off_frames; we emit
		# both halves so the audio device pulls a steady stream and
		# the gaps are real (not just an underrun).
		for(i := 0; i < on_frames + off_frames; i++) {
			v: int;
			if(i < on_frames) {
				t := real phase / real RATE;
				v = int (real AMP *
					math->sin(2.0 * Math->Pi * real FREQ * t));
			} else {
				v = 0;	# silence
			}
			phase++;
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
	}
	if(pos > 0) {
		n := sys->write(fd, buf, pos);
		written += n;
	}
	total_ms := NPULSES * (ONMS + OFFMS);
	sys->fprint(sys->fildes(2),
		"audiotone: wrote %d bytes (%d pulses, %d ms total @ %d Hz)\n",
		written, NPULSES, total_ms, FREQ);

	# Hold the FD open until SDL3 has drained the queue. The write()
	# above just enqueues bytes in the SDL_AudioStream; the device
	# thread pulls them out at real-time pace. If we close before
	# the queue drains, audio_file_close destroys the stream and the
	# unplayed tail is lost — that's why a 200 ms grace was silent.
	# Sleep for the full audio duration plus a small device latency
	# allowance, then exit (which closes the FD cleanly).
	sys->sleep(total_ms + 500);
}

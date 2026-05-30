implement OpusTest;

#
# opus_test — Unit tests for /dev/opus (devopus.c). INFR-187.
#
# Covers the v0 device contract:
#   - bind exposes /n/opus with ctl, enc, dec, status files.
#   - ctl read returns the current config; status read returns counters.
#   - ctl writes are parsed and update counters (rate, chans, frame_ms,
#     bitrate).
#   - Encoder: write N x frame_ms-worth of PCM, expect N opus frames
#     to appear (status counters advance correctly).
#   - Round-trip: PCM -> enc -> dec -> PCM and check the decoded byte
#     count roughly matches what we encoded (lossy, frame-aligned).
#
# We push synthetic silence (all-zero PCM) rather than driving the SDL3
# audio device — that keeps the test deterministic and CI-runnable
# without any TCC mic prompt.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

OpusTest: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/opus_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	* =>
		t.failed = 1;
	}

	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# True if /n/opus is already mounted. We do the bind once in init() so
# every test sees the same namespace.
opus_mounted(): int
{
	(ok, nil) := sys->stat("/n/opus/status");
	return ok >= 0;
}

read_all(path: string, max: int): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[max] of byte;
	n := sys->read(fd, buf, max);
	if(n <= 0)
		return nil;
	return buf[:n];
}

read_status(): string
{
	b := read_all("/n/opus/status", 4096);
	if(b == nil)
		return "";
	return string b;
}

# Extract `key value` line from status text; return value or "".
extract(s: string, key: string): string
{
	# walk lines
	i := 0;
	while(i < len s) {
		j := i;
		while(j < len s && s[j] != '\n')
			j++;
		line := s[i:j];
		if(len line > len key && line[:len key] == key && line[len key] == ' ')
			return line[len key + 1:];
		i = j + 1;
	}
	return "";
}

ctl_set(verb: string): int
{
	fd := sys->open("/n/opus/ctl", Sys->OWRITE);
	if(fd == nil)
		return 0;
	b := array of byte verb;
	return sys->write(fd, b, len b);
}

testStatusInitial(t: ref T)
{
	s := read_status();
	t.assertnotnil(s, "status non-empty");
	t.assertseq(extract(s, "rate"), "48000",
		"default rate is 48000");
	t.assertseq(extract(s, "chans"), "1",
		"default chans is 1 (mono — voice)");
	t.assertseq(extract(s, "frame_ms"), "20",
		"default frame_ms is 20 (WebRTC baseline)");
	t.assertseq(extract(s, "bitrate"), "24000",
		"default bitrate is 24000");
}

testCtlSetsValues(t: ref T)
{
	ctl_set("bitrate 32000");
	s := read_status();
	t.assertseq(extract(s, "bitrate"), "32000",
		"bitrate verb takes effect");
	# restore
	ctl_set("bitrate 24000");
}

testCtlSetsFrameMs(t: ref T)
{
	ctl_set("frame_ms 40");
	s := read_status();
	t.assertseq(extract(s, "frame_ms"), "40",
		"frame_ms verb takes effect");
	# restore
	ctl_set("frame_ms 20");
}

# Push N frames worth of silent PCM into the encoder and check the
# counters track correctly. With rate=48000, chans=1, frame_ms=20,
# one frame = 48000 * 0.020 * 1 * 2 = 1920 PCM bytes.
testEncoderFramesAdvance(t: ref T)
{
	ctl_set("rate 48000");
	ctl_set("chans 1");
	ctl_set("frame_ms 20");

	# Snapshot initial counters
	s0 := read_status();
	f0 := int extract(s0, "enc_out_frames");

	fd := sys->open("/n/opus/enc", Sys->OWRITE);
	t.assert(fd != nil, "open enc OWRITE");
	if(fd == nil) return;

	# 10 frames worth of silence
	NFRAMES := 10;
	FRAME_BYTES := 1920;
	buf := array[NFRAMES * FRAME_BYTES] of byte;
	# array of byte zero-initialised already

	n := sys->write(fd, buf, len buf);
	t.asserteq(n, len buf, "wrote all 10 frames worth of PCM");
	fd = nil;	# close

	s1 := read_status();
	f1 := int extract(s1, "enc_out_frames");
	t.asserteq(f1 - f0, NFRAMES,
		"encoder produced exactly 10 frames");

	# enc_pcm_bytes counter advanced by exactly what we wrote
	p0 := int extract(s0, "enc_pcm_bytes");
	p1 := int extract(s1, "enc_pcm_bytes");
	t.asserteq(p1 - p0, NFRAMES * FRAME_BYTES,
		"enc_pcm_bytes counter accurate");
}

# Read the encoded frames back and feed them straight into the decoder.
# The decoder should produce roughly the same number of PCM frames out
# as we put in.
testRoundTripSilence(t: ref T)
{
	ctl_set("rate 48000");
	ctl_set("chans 1");
	ctl_set("frame_ms 20");

	# Snapshot
	s0 := read_status();
	df0 := int extract(s0, "dec_in_frames");
	dp0 := int extract(s0, "dec_pcm_bytes");

	# Encode 5 frames of silence
	encfd := sys->open("/n/opus/enc", Sys->ORDWR);
	t.assert(encfd != nil, "open enc ORDWR");
	if(encfd == nil) return;
	NFRAMES := 5;
	FRAME_BYTES := 1920;
	silent := array[NFRAMES * FRAME_BYTES] of byte;
	sys->write(encfd, silent, len silent);

	# Drain the encoded frames. qread returns one queued buffer per
	# call (one opus frame in our case), so we loop until status
	# tells us we've drained every produced frame.
	encbuf := array[16*1024] of byte;
	encread := 0;
	for(loops := 0; loops < NFRAMES * 2; loops++) {
		r := sys->read(encfd, encbuf[encread:], len encbuf - encread);
		if(r <= 0) break;
		encread += r;
		# Each frame is 2 bytes length + payload. Stop when we've
		# seen NFRAMES frames in the buffer.
		framecnt := 0; off := 0;
		while(off + 2 <= encread) {
			flen := (int encbuf[off] << 8) | int encbuf[off+1];
			if(off + 2 + flen > encread) break;
			framecnt++;
			off += 2 + flen;
		}
		if(framecnt >= NFRAMES) break;
	}
	t.assert(encread > 0, "read encoded frames out");
	if(encread <= 0) return;

	# Feed straight into the decoder
	decfd := sys->open("/n/opus/dec", Sys->ORDWR);
	t.assert(decfd != nil, "open dec ORDWR");
	if(decfd == nil) return;
	dn := sys->write(decfd, encbuf, encread);
	t.asserteq(dn, encread, "decoder accepted every encoded byte");

	s1 := read_status();
	df1 := int extract(s1, "dec_in_frames");
	dp1 := int extract(s1, "dec_pcm_bytes");
	t.asserteq(df1 - df0, NFRAMES,
		"decoder consumed exactly 5 frames");
	# Each decoded frame is 20ms @ 48k mono = 1920 PCM bytes
	t.asserteq(dp1 - dp0, NFRAMES * FRAME_BYTES,
		"decoded PCM bytes match encoded frame count");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;

	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();

	# Mount the opus device under /n/opus (path doesn't conflict with
	# the read-only /dev). One-shot for every test.
	sys->bind("#Z", "/n/opus", Sys->MREPL|Sys->MCREATE);
	if(!opus_mounted()) {
		# Some builds don't compile /dev/opus (no -DHAVE_OPUS); skip.
		sys->fprint(sys->fildes(2),
			"opus_test: /n/opus not mounted — devopus not built with libopus, skipping\n");
		raise "fail:skip-suite";
	}

	for(a := args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
	}

	run("StatusInitial", testStatusInitial);
	run("CtlSetsValues", testCtlSetsValues);
	run("CtlSetsFrameMs", testCtlSetsFrameMs);
	run("EncoderFramesAdvance", testEncoderFramesAdvance);
	run("RoundTripSilence", testRoundTripSilence);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

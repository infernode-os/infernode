#
# sdrdsp - what sdr(1)'s demodulators share: the samples sdrfs(4)'s iq
# gives, made fewer and complex; a rate changed by averaging; sound as
# audio(3) takes it.  Arithmetic only: no files, no processes.
#
Sdrdsp: module
{
	PATH:	con "/dis/lib/sdrdsp.dis";

	init:	fn();

	# 8-bit unsigned I then Q, n at a time summed into one complex
	# sample, -1 to 1 (a boxcar filter and decimation by n)
	Decim: adt {
		n:	int;
		k:	int;		# into the sum
		si, sq:	int;
		scale:	real;

		new:	fn(n: int): ref Decim;
		# b[0:nb], a whole number of samples; the samples out in
		# i and q, and how many
		run:	fn(d: self ref Decim, b: array of byte, nb: int, i, q: array of real): int;
	};

	# complex samples low-passed (a windowed sinc, taps long, passing
	# below cutoff, a fraction of the rate in) and decimated by n: the
	# channel taken out of a wider stream, what lies beyond it not
	# folded into it
	Fir: adt {
		n:	int;
		h:	array of real;
		bi, bq:	array of real;	# the last taps samples, twice over
		pos:	int;
		k:	int;

		new:	fn(n: int, cutoff: real, taps: int): ref Fir;
		# i, q[0:m] in; the samples out in oi, oq (which may be i, q),
		# and how many
		run:	fn(f: self ref Fir, i, q: array of real, m: int, oi, oq: array of real): int;
		# the same for real samples (only bi is used)
		runr:	fn(f: self ref Fir, x: array of real, m: int, y: array of real): int;
	};

	# a rate changed from fin to fout (fin >= fout): each sample out the
	# mean of those in that fell in its time, one that straddles two
	# shared between them
	Resamp: adt {
		fin, step:	int;	# per sample in, step added; one out each fin
		acc:	int;
		sum:	real;
		w:	real;		# how many samples are in sum

		new:	fn(fin, fout: int): ref Resamp;
		run:	fn(r: self ref Resamp, x: array of real, n: int, y: array of real): int;
	};

	# sound, about -1 to 1, as audio(3)'s 16-bit little-endian
	# samples, each given chans times, any constant level taken out
	Pcm: adt {
		chans:	int;
		dc:	real;
		a:	real;	# how fast dc follows
		clipped:	int;

		new:	fn(rate, chans: int): ref Pcm;
		# y[0:n] times gain into b; the bytes
		run:	fn(p: self ref Pcm, y: array of real, n: int, gain: real, b: array of byte): int;
	};

	# a rate as sdrfs's ctl takes it: 2.4M, 240k, 2048000; 0 if not
	rate:	fn(s: string): int;
};

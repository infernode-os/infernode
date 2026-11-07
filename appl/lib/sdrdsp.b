implement Sdrdsp;

#
# sdrdsp - the arithmetic sdr(1)'s demodulators share (module/sdrdsp.m).
# The loops run once a sample, millions a second, so they keep their
# state in locals and call nothing.
#

include "math.m";
	math: Math;

include "sdrdsp.m";

init()
{
	math = load Math Math->PATH;
}

Decim.new(n: int): ref Decim
{
	if(n < 1)
		n = 1;
	return ref Decim(n, 0, 0, 0, 1.0 / (127.5 * real n));
}

Decim.run(d: self ref Decim, b: array of byte, nb: int, i, q: array of real): int
{
	n := 0;
	k := d.k;
	si := d.si;
	sq := d.sq;
	dn := d.n;
	scale := d.scale;
	for(j := 0; j + 1 < nb; j += 2) {
		si += int b[j];
		sq += int b[j+1];
		if(++k == dn) {
			i[n] = real si * scale - 1.0;
			q[n] = real sq * scale - 1.0;
			n++;
			k = si = sq = 0;
		}
	}
	d.k = k;
	d.si = si;
	d.sq = sq;
	return n;
}

Fir.new(n: int, cutoff: real, taps: int): ref Fir
{
	if(n < 1)
		n = 1;
	if(taps < 1)
		taps = 1;
	h := array[taps] of real;
	sum := 0.0;
	c := real (taps - 1) / 2.0;
	for(j := 0; j < taps; j++) {
		x := real j - c;
		s := 2.0 * cutoff;
		if(x != 0.0)
			s = math->sin(2.0 * Math->Pi * cutoff * x) / (Math->Pi * x);
		# Blackman
		w := 1.0;
		if(taps > 1) {
			t := 2.0 * Math->Pi * real j / real (taps - 1);
			w = 0.42 - 0.5 * math->cos(t) + 0.08 * math->cos(2.0 * t);
		}
		h[j] = s * w;
		sum += h[j];
	}
	for(j = 0; j < taps; j++)
		h[j] /= sum;
	return ref Fir(n, h, array[2*taps] of {* => 0.0}, array[2*taps] of {* => 0.0}, 0, 0);
}

Fir.run(f: self ref Fir, i, q: array of real, m: int, oi, oq: array of real): int
{
	h := f.h;
	t := len h;
	bi := f.bi;
	bq := f.bq;
	pos := f.pos;
	k := f.k;
	dn := f.n;
	o := 0;
	for(j := 0; j < m; j++) {
		# each sample at pos and pos+t, so the last t are
		# bi[pos+1:pos+1+t], oldest first, without wrapping
		bi[pos] = bi[pos+t] = i[j];
		bq[pos] = bq[pos+t] = q[j];
		if(++pos == t)
			pos = 0;
		if(++k < dn)
			continue;
		k = 0;
		si := 0.0;
		sq := 0.0;
		for(l := 0; l < t; l++) {
			si += h[l] * bi[pos+l];
			sq += h[l] * bq[pos+l];
		}
		oi[o] = si;
		oq[o] = sq;
		o++;
	}
	f.pos = pos;
	f.k = k;
	return o;
}

Fir.runr(f: self ref Fir, x: array of real, m: int, y: array of real): int
{
	h := f.h;
	t := len h;
	b := f.bi;
	pos := f.pos;
	k := f.k;
	dn := f.n;
	o := 0;
	for(j := 0; j < m; j++) {
		b[pos] = b[pos+t] = x[j];
		if(++pos == t)
			pos = 0;
		if(++k < dn)
			continue;
		k = 0;
		s := 0.0;
		for(l := 0; l < t; l++)
			s += h[l] * b[pos+l];
		y[o++] = s;
	}
	f.pos = pos;
	f.k = k;
	return o;
}

Resamp.new(fin, fout: int): ref Resamp
{
	return ref Resamp(fin, fout, 0, 0.0, 0.0);
}

# each sample in lasts step, each out fin: a sample in that straddles
# two out is shared between them by how much of it falls in each
Resamp.run(r: self ref Resamp, x: array of real, n: int, y: array of real): int
{
	m := 0;
	acc := r.acc;
	sum := r.sum;
	w := r.w;
	fin := r.fin;
	step := r.step;
	rstep := 1.0 / real step;
	for(j := 0; j < n; j++) {
		v := x[j];
		acc += step;
		if(acc < fin) {
			sum += v;
			w += 1.0;
			continue;
		}
		acc -= fin;
		f := real acc * rstep;	# of v, the next one's
		sum += v * (1.0 - f);
		w += 1.0 - f;
		y[m++] = sum / w;
		sum = v * f;
		w = f;
	}
	r.acc = acc;
	r.sum = sum;
	r.w = w;
	return m;
}

Pcm.new(rate, chans: int): ref Pcm
{
	if(chans < 1)
		chans = 1;
	# dc follows over about a tenth of a second
	return ref Pcm(chans, 0.0, 10.0 / real rate, 0);
}

Pcm.run(p: self ref Pcm, y: array of real, n: int, gain: real, b: array of byte): int
{
	o := 0;
	dc := p.dc;
	a := p.a;
	for(j := 0; j < n; j++) {
		x := y[j];
		dc += a * (x - dc);
		v := int ((x - dc) * gain * 32767.0);
		if(v > 32767) {
			v = 32767;
			p.clipped++;
		} else if(v < -32767) {
			v = -32767;
			p.clipped++;
		}
		for(c := 0; c < p.chans; c++) {
			b[o++] = byte v;
			b[o++] = byte (v >> 8);
		}
	}
	p.dc = dc;
	return o;
}

rate(s: string): int
{
	if(s == nil)
		return 0;
	m := 1.0;
	case s[len s - 1] {
	'k' or 'K' =>
		m = 1e3;
	'M' =>
		m = 1e6;
	}
	if(m != 1.0)
		s = s[0:len s - 1];
	dot := 0;
	digits := 0;
	for(i := 0; i < len s; i++) {
		if(s[i] == '.' && !dot)
			dot = 1;
		else if(s[i] >= '0' && s[i] <= '9')
			digits++;
		else
			return 0;
	}
	if(digits == 0)
		return 0;
	v := real s * m;
	if(v < 1.0 || v > 1e8)
		return 0;
	return int v;	# rounds
}

#!/usr/bin/env python3
"""Synthetic RTL-SDR samples and a measure of the sound made from them,
for tests/host/sdr_demod_test.sh.

    synth_iq.py fm RATE SECONDS DEV TONE OFFSET OUT   FM, a tone at TONE Hz
                                                      deviating DEV Hz, the
                                                      carrier OFFSET Hz off
    synth_iq.py am RATE SECONDS DEPTH TONE OFFSET OUT AM, DEPTH (0-1) deep
    synth_iq.py tone PCM RATE CHANS                   the sound's strongest
                                                      tone, its SINAD and
                                                      peak level, as
                                                      "tone=F sinad=S peak=P"

The samples are as rtl_tcp gives them, 8-bit unsigned I then Q, with
noise 40 dB below the carrier and a second carrier, 400 kHz up, that the
demodulator should not hear.  The sound is audio(3)'s, 16-bit
little-endian, CHANS channels; its first half second is not measured
(the filters settling).
"""
import math
import sys

import numpy as np


def quantise(z):
    z = z / np.max(np.abs(z)) * 100.0
    rng = np.random.default_rng(1)
    z = z + (rng.normal(0, 1.0, len(z)) + 1j * rng.normal(0, 1.0, len(z)))
    b = np.empty(2 * len(z), dtype=np.uint8)
    b[0::2] = np.clip(np.round(z.real + 127.5), 0, 255)
    b[1::2] = np.clip(np.round(z.imag + 127.5), 0, 255)
    return b


def synth(kind, rate, secs, depth, tone, offset, out):
    t = np.arange(int(rate * secs)) / rate
    if kind == "fm":
        ph = 2 * math.pi * offset * t + depth / tone * np.sin(2 * math.pi * tone * t)
        z = np.exp(1j * ph)
    else:
        z = (1 + depth * np.sin(2 * math.pi * tone * t)) * np.exp(2j * math.pi * offset * t)
    # another station, 400 kHz up, as strong, carrying 3 kHz
    z = z + np.exp(1j * (2 * math.pi * (offset + 400e3) * t + 10 * np.sin(2 * math.pi * 3000 * t)))
    quantise(z).tofile(out)


def measure(path, rate, chans):
    s = np.fromfile(path, dtype="<i2").astype(np.float64)
    if chans > 1:
        s = s.reshape(-1, chans)[:, 0]
    s = s[rate // 2:]
    if len(s) < rate // 4:
        print("tone=0 sinad=0 peak=0 n=%d" % len(s))
        return
    s = s[: (len(s) // 1024) * 1024]
    w = np.hanning(len(s))
    p = np.abs(np.fft.rfft((s - s.mean()) * w)) ** 2
    f = np.fft.rfftfreq(len(s), 1 / rate)
    p[f < 50] = 0
    k = int(np.argmax(p))
    band = (f > f[k] * 0.95) & (f < f[k] * 1.05)
    sig = p[band].sum()
    rest = p.sum() - sig
    print("tone=%d sinad=%.1f peak=%d n=%d" % (round(f[k]), 10 * math.log10(sig / max(rest, 1e-12)),
          int(np.max(np.abs(s))), len(s)))


if sys.argv[1] in ("fm", "am"):
    a = sys.argv[2:]
    synth(sys.argv[1], float(a[0]), float(a[1]), float(a[2]), float(a[3]), float(a[4]), a[5])
elif sys.argv[1] == "tone":
    measure(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
else:
    sys.exit(__doc__)

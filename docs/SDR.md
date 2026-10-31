# Software-defined radio for InferNode

Status: proposal. Nothing here is built. This is the design, written
before the code, as [DESIGN-PRINCIPLES.md](DESIGN-PRINCIPLES.md) asks:
the file interface is the design, so review that first. The first
receiver is an RTL-SDR (an RTL2832U with an R820T2 or R828D tuner, the
common USB dongle, 24–1766 MHz).

## What exists, and what does not

**In this tree: nothing.** No file mentions RTL-SDR, rtl_tcp, IQ samples
or software-defined radio.

**In the Plan 9 family's original releases: nothing either.** Plan 9
1E–4E and Inferno 1E–4E have no SDR, no ham radio (AX.25, APRS, Morse,
RTTY) and no packet radio (see
[history/ABANDONWARE-SURVEY.md](history/ABANDONWARE-SURVEY.md)). What they
do have is the shape of a tuner as files, and this tree has since made
the decisions a radio must follow.

## Precedents this design inherits

1. **A tuner is a ctl file and data files.** Plan 9 4E's
   `sys/src/9/pc/devtv.c` (the Bt848/878 cards, which carried an FM
   radio as well as a TV tuner) serves `ctl`, `video` and `audio`; its
   ctl takes text verbs (`channel`, `volume`, `mute`, `vstart`,
   `astart`) and the data files carry the samples. Inferno's own
   `devtv.c` (1E–4E, a Hauppauge board, the set-top box's TV) does the
   same at `/dev/tvctl`: `channel`, `volume`, `bass`, `treble`,
   `signal`. Neither tuned FM, but the pattern for a radio is there.
2. **A sample stream is `audio(3)`.** `/dev/audio` and `/dev/audioctl`:
   settings written as text (`rate`, `chans`, `bits`, `enc`), samples
   read and written as bytes. Demodulated sound goes there, unchanged.
3. **A receiver is a byte stream; its meaning is a file server's.**
   `gpsfs(4)` reads one source (serial, network, a phone's own service,
   a recording) in one of several formats, and serves what it means as
   text files: `fix`, `event`, `traffic`. ADS-B decoded from a radio is
   one more format for it.
4. **Run only while something listens.** `location(3)`: the first open
   of `#g/nmea` starts the phone's location service, the last close
   stops it. A dongle drawing 300 mA should do the same.
5. **Posted for every name space.** `gpsfs` and the editor post
   themselves in `#s` (`post9p(2)`), so an application or an agent's
   tool can mount them.
6. **Mechanism in the kernel, protocol outside.**
   [BLUETOOTH.md](BLUETOOTH.md) and `os/bcm2837/README.md`: the kernel
   owns USB transfers and interrupts; a device family's protocol is a
   Limbo program over `#u` (`etherusb.b`, `kbdusb.b`). A data path moves
   into C only after a measurement says it must.
7. **Distribution is namespace composition.**
   [SPEECH-REMOTE-AUDIO.md](SPEECH-REMOTE-AUDIO.md): a server that only
   touches its own name space can be fed from another machine by
   binding there first. A dongle on a mast, its Pi exporting `/mnt/sdr`,
   is a radio on the desk.

## The hardware, in numbers

| | |
|---|---|
| Tuning | 24–1766 MHz (R820T2); below 24 MHz by direct sampling (the I or Q branch), poorly |
| Sample rate | 225–300 kS/s or 900 kS/s–3.2 MS/s; 2.4 MS/s is the most reliable |
| Samples | 8-bit unsigned I then Q, interleaved: 2 bytes a sample, 4.8 MB/s at 2.4 MS/s |
| Gain | a table of the tuner's (29 steps, 0–49.6 dB on the R820T2), or automatic |
| Frequency error | 0–100 ppm by dongle; a correction is set in ppm |
| Extras | a bias tee (5 V on the antenna, for a preamplifier) on v3/v4 dongles |
| Receive only | it cannot transmit |

## Where the USB driver lives

Three places, one file interface, so the choice can change without
changing anything that reads `/mnt/sdr`:

- **A. The host's `rtl_tcp`.** `rtl_tcp` (from librtlsdr) serves the
  dongle over TCP: a 12-byte greeting (`RTL0`, the tuner type, the
  number of gains), then the samples; commands are 5 bytes, a code and
  a big-endian 32-bit value (1 frequency, 2 sample rate, 3 gain mode,
  4 gain in tenths of a dB, 5 ppm, 8 AGC, 9 direct sampling, 13 gain by
  index, 14 bias tee). InferNode dials it. No C in the tree, no GPL
  (librtlsdr is GPL-2, and stays in its own process), and it works now
  on Linux, macOS, Windows, and Android (`rtl_tcp_andro`). The dongle
  can be on another machine. But `rtl_tcp` has no authentication: it
  is bound to loopback and anything remote goes through an
  authenticated 9P export of `/mnt/sdr`, never a raw `rtl_tcp` port.
- **B. An emulator device**, librtlsdr linked into `emu` as `#R`, as
  `devaudio` links the host's audio. It saves a process and a copy,
  costs a GPL library in the emulator and a USB permission path on
  every platform. Only if A is measured too slow.
- **C. Native, on the Pi:** an RTL2832U driver in Limbo over `#u`
  (control transfers for the registers, a bulk endpoint for the
  samples), by the mechanism/protocol rule. It needs the register
  sequences, which are documented only by librtlsdr's GPL source; it
  would have to be written from the datasheets and observation, not
  from that code.

**Proposal: A first, C later, B only on a measurement.**

## The file interface

```
/mnt/sdr/
    ctl       rw  write one setting a line; a read gives them all, in the
                  form written:
                    freq 1090000000        hertz
                    rate 2400000           samples a second
                    gain auto | 38.6       dB, the nearest the tuner has
                    ppm 0
                    agc off | on           the RTL2832U's own
                    direct off | i | q     direct sampling, for HF
                    biastee off | on
    status    r   attr=value: tuner=R820T link=open|closed|error
                  source=tcp!localhost!1234 readers=N dropped=N error='...'
    gains     r   the tuner's gains, one a line, dB
    iq        r   the samples, 8-bit unsigned I then Q, from the open on;
                  each read waits for more.  Every open has its own queue;
                  a reader that falls behind loses the oldest, counted in
                  status.  The first open starts the samples, the last
                  close stops them.
```

```
; sdrfs source tcp!localhost!1234
; echo freq 98500000 > /mnt/sdr/ctl
; echo gain auto > /mnt/sdr/ctl
; cat /mnt/sdr/ctl
freq 98500000
rate 2400000
gain auto
...
```

One dongle is one tuner on one frequency. Readers share its stream, and
a second program tuning it moves everyone: that is what the hardware is,
and the file says so rather than pretending otherwise. More dongles are
`/mnt/sdr/0/`, `/mnt/sdr/1/`, as `devtv` had `Ntvs` and Ethernet has
`ether0`.

Text settings, bytes for samples: the samples are 4.8 MB/s of numbers no
person reads, the same as `/dev/audio`'s and `/dev/draw`'s; everything
about them is text.

## Demodulation is composition

The server serves the radio, not what the radio means. Each demodulator
is a program reading `iq` and writing what it found, as Unix filters do:

```
; echo freq 98500000 > /mnt/sdr/ctl
; sdr/fm -w < /mnt/sdr/iq > /dev/audio          # broadcast FM, to the speaker
; echo freq 121500000 > /mnt/sdr/ctl
; sdr/am < /mnt/sdr/iq > /dev/audio             # the air band's emergency frequency
```

| Program | Input | Output | Notes |
|---|---|---|---|
| `sdr/fm` | iq | PCM for `/dev/audio` | wide FM (broadcast) or narrow (`-n`: marine VHF, 2 m ham, NOAA weather) |
| `sdr/am` | iq | PCM | the aviation band, 118–137 MHz, is AM |
| `sdr/adsb` | iq at 2 MS/s, 1090 MHz | Mode S messages as AVR text (`*8D4840D6...;`) | the format dump1090 serves on port 30002 |
| `sdr/ais` | iq, 162 MHz | `!AIVDM` sentences | 9600-baud GMSK, two channels |
| `sdr/aprs` | iq, 144.39 MHz (Americas) or 144.8 | positions | 1200-baud AFSK, AX.25 frames |
| `wm/spectrum` | iq | a waterfall | for finding what is on the air |

Their outputs go where this tree already takes them. `sdr/adsb`'s AVR
text is a new `gpsfs` format, `avr`, which decodes Mode S (call signs,
CPR positions, velocities) into `traffic` as `kind=adsb`; the same
format reads dump1090 itself (`source avr tcp!host!30002`), so a
dump1090 on another machine and our own decoder are interchangeable.
`sdr/ais` writes NMEA, which `gpsfs` already reads. `wm/road` already
draws `traffic`.

**The rate question, to measure first.** 2.4 MS/s of complex samples
is about 50 million simple operations a second for an FM demodulator,
after decimation by integer arithmetic, and ADS-B at 2 MS/s is a
magnitude and a preamble search per sample. Whether Limbo under the
amd64, arm64 and riscv64 JITs keeps up is a number this design does not
have. M1 gets it. If Limbo cannot, the hot loop (decimation, the
magnitude, the discriminator) becomes a builtin module in C, as `Math`
is, with the protocol still in Limbo.

## The question this raises for gpsfs

`gpsfs` reads **one** source. With a GPS puck for our own position and a
radio for ADS-B, that is two, and `gpsfs` cannot take both. Plan 9's
`gpsfs` never had to: it read one serial GPS and had no traffic. Two
ways:

1. **Own position one source, traffic many.** `ctl` keeps `source` for
   our own position and gains `traffic <format> <address>` for inputs
   that bring only traffic (an AIS receiver, an ADS-B decoder, an APRS
   decoder), each with its own reader. One truth for where we are; many
   for who is around. `traffic` merges them, as it already merges AIS
   messages.
2. **A separate traffic server**, `/mnt/traffic`, fed by many decoders,
   with `gpsfs` keeping only our position. Cleaner on paper, but
   FLARM's traffic is given relative to our position, and AIS, GDL 90
   and FLARM already arrive interleaved with it on one line, so `gpsfs`
   would still have to pass traffic on to it.

**Proposal: 1.** It is a small change to `gpsfs`'s ctl, it keeps the
nearest-first ordering and FLARM's placing where our position is, and a
separate server can still be split out later if something other than
`gpsfs` needs to feed traffic.

## Capabilities

- **It cannot transmit.** An agent given `/mnt/sdr` can listen, not
  emit.
- **Tuning and listening are separate grants.** `iq` (and the
  demodulators' outputs) lets a process hear what the radio is tuned
  to; `ctl` lets it choose. An agent watching for aircraft gets the
  traffic, not the tuner.
- **What may be listened to is law, not mechanism.** Broadcast,
  aviation, marine, amateur, weather and ADS-B/AIS are generally open
  to receive; some services (cellular, some public safety) are not, in
  some countries. This is documented for the user; the namespace cannot
  enforce a country's law, and nothing here pretends to.
- **`rtl_tcp` is never exposed.** It listens on loopback; remote access
  is `/mnt/sdr` exported over authenticated 9P.

## Milestones

| | What | Test |
|---|---|---|
| M0 | `sdrfs` over `rtl_tcp`: ctl, status, gains, iq; start on first open | against a fake `rtl_tcp` in Python (`tests/host/sdr/`), as `gpsfs` is tested against fake feeds |
| M1 | `sdr/fm` and `sdr/am` to `/dev/audio`; **measure** Limbo's throughput | a synthetic FM carrier's tone recovered; samples a second on each JIT |
| M2 | `gpsfs` format `avr`, and `ctl traffic` | dump1090's AVR from a fixture; ADS-B and a GPS at once |
| M3 | `sdr/adsb` | recorded IQ with known aircraft (a fixture), decoded as dump1090 decodes it |
| M4 | `sdr/ais`, `sdr/aprs` | recorded IQ fixtures |
| M5 | `wm/spectrum` | by pixel, as `wm/road` |
| M6 | the native Pi driver over `#u` | on a board; written from the datasheets |

Each milestone works with the real dongle, and you have one, so each
gets a check on hardware beside its fixture test.

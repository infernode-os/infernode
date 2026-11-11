# sdg for video: results

Measured 2026-11-11, 01:49 to 04:28, after `PREDICTION.md` (commit
4cbdcb602) and the apparatus (d7f47d32d, 11d11d453). Each figure is the
median of three runs a cell, the cells interleaved within each run.

## What was run

As predicted, with these differences, each found while building or
running it:

- **Frame time is the unpaced clip, not the live feed.** A live reader
  waits for each new frame, so on a feed at 6 fps its per-frame time is
  the 167 ms between frames whenever it keeps up, and says nothing of the
  transport. The clip cells (`-f 20 -0 -p N` on a file of 144 frames,
  read as fast as the transport allows) give the frame read time; the
  live cells (`-f 60 -p N`) give whether a reader keeps up with a camera.
- **CPU per MB** is the Pi's busy time over a run, less a following idle
  window as long, less the difference in their lengths at the
  background rate measured over long idle windows (`sdgan.py` in the
  experiment's scratch; a first version charged the sampling's own cost
  to the run). The Wi-Fi figures are consistent run to run. **The wired
  ones are not usable:** the background rate in the wired phases' idle
  windows was eight times the Wi-Fi phases' (1.37 against 0.16 busy ms
  per ms), most likely sdgsrv's spinning sessions (below), and the subtraction gives
  negative costs in some cells. Only Wi-Fi CPU is quoted below.
- **sdgsrv** (the responder written for this) serves an export over sdg
  with its own tags, closes a request whose tag is reused (STYX-DGRAM),
  drops a session idle for two minutes, and has no cookies. It is enough
  to measure with, not to deploy.
- **A fault in sdgsrv contaminated the wired phase** (found afterwards,
  in `docs/experiments/loss`, fixed in cb86ac99d). Its window's run map
  was shifted with a `big`'s `>>`, which is arithmetic: a session in
  which one request stayed open while 63 later ones finished could fill
  the map with ones and loop in `ran()` for good, answering nothing and
  using about a tenth of a core. Sessions left so by the Wi-Fi phase
  were still spinning in the wired phase; this is the likeliest source of
  the high background there, and it took Pi CPU from the wired cells. The
  wired sdg figures below are therefore a lower bound. The Wi-Fi phase's
  idle background stayed at 0.16 busy ms per ms, about what the live
  feed's replay costs, so its figures were not affected.
- **Memory per viewer was not measured.**
- `Sys->fversion` returned the size asked for, not the size agreed; found
  here and fixed separately (#1161). The bench reads the iounit instead.

## Results

### Wi-Fi (the Mac on 2.4 GHz to the Pi 5)

| cell | N | TCP | sdg |
|------|---|-----|-----|
| bulk MB/s | 1 | 4.37 | 0.37 |
| | 4 | 9.12 | 1.24 |
| | 8 | 12.12 | 2.11 |
| | 16 | 11.82 | 3.76 |
| clip p50 / p95 / p99 / max ms | 1 | 36 / 59 / 69 / 77 | 533 / 572 / 597 / 597 |
| | 4 | 17 / 31 / 50 / 51 | 155 / 186 / 194 / 199 |
| | 8 | 16 / 33 / 48 / 50 | 85 / 119 / 131 / 148 |
| | 16 | 16 / 36 / 47 / 48 | 53 / 82 / 99 / 112 |
| live frames read of ~361, lost | 1 | 361, 0 | 111, 4 |
| | 8 | 362, 0 | 352, 0 |
| | 16 | 361, 0 | 361, 0 |
| CPU ms per MB (bulk N=16, clip N=8) | | 38, 25 | 142, 123 |
| 4 viewers at N=8: frames, lost | | 728, 0 | 720, 0 |

### Wired (the Orin to the Pi 5)

| cell | N | TCP | sdg |
|------|---|-----|-----|
| bulk MB/s | 1 | 10.59 | 0.81 |
| | 8 | 31.18 | 5.80 |
| | 16 | 28.98 | 5.25 |
| clip p50 / p95 / p99 / max ms | 1 | 12 / 15 / 17 / 18 | 238 / 272 / 293 / 293 |
| | 8 | 5 / 6 / 7 / 11 | 38 / 46 / 51 / 51 |
| | 16 | 6 / 7 / 7 / 8 | 40 / 51 / 53 / 64 |

## The predictions

1. **Throughput on Wi-Fi, TCP wins: held.** TCP 12.1 MB/s (8-13), sdg
   3.76 at N = 16 (2-5) and 0.37 at N = 1 (under 0.4); sdg under half of
   TCP at every N (a third at N = 16).
2. **Frame time on Wi-Fi, TCP wins: held in its conclusion, broken in
   its ranges.** TCP p50 16 ms (15-40). sdg was faster than predicted:
   533 ms at N = 1 (0.6-1.0 s) and 53 ms at N = 16 (60-120). Its best
   p50 is 3.3 times TCP's (at least twice).
3. **Tail on Wi-Fi: mostly broken.** TCP's p99/p50 was 3.0 (2-5), but it
   never stalled: its worst clip frame in nine runs was 51 ms, not over
   250. sdg's p99/p50 was 1.54 at N = 8 and 1.87 at N = 16 (under 1.8:
   broken at 16); its max 148 ms (under 400). sdg's p99 (99 ms) stayed
   above TCP's (47): held, but for want of any TCP stall, not despite one.
   The link lost too little for loss to shape the tail; the loss
   experiment (`docs/experiments/loss`) makes it lose.
4. **The feed keeps up at N >= 8: held.** No frame lost by either
   transport at N >= 8, with one to four viewers. At N = 1 sdg read 111 of
   361 frames: 69% missed, just short of the 70% predicted (broken by a
   point).
5. **Wired, sdg bound by the Pi: broken low.** sdg reached 5.8 MB/s (8-20
   predicted), the same at N = 8 and 16, so the Pi's cost per datagram
   binds by 8; TCP 31 (20-35). sdg's p99/p50 on the wire (1.3) was no
   better than TCP's (1.4 at N = 8): held.
6. **CPU per viewer, sdg more: held in direction, broken in size and in
   its last clause.** sdg costs 3.7 times TCP's CPU per MB in bulk and 4.9
   times in the clip (2-4 predicted). Memory not measured. With four
   viewers the Pi kept up on both (about 13% of its four cores for sdg);
   its CPU limited nothing.

## The conclusion

As predicted, and none of the three conditions that would have changed it
came about: sdg reached a third of TCP's Wi-Fi throughput (not 70%), its
best median frame time was 3.3 times TCP's (not within 1.5), TCP never
stalled, and sdg's CPU per MB was 3.7 to 4.9 times TCP's (not within
1.5). For raw frames over a link that loses little, sdg does not beat
9P over TCP.

Why: a reader with N reads in flight moves N x 1176 bytes a round trip,
16 x 1176 B / 5 ms = 3.8 MB/s on Wi-Fi, where it was measured; every
reply needs its own request on a half-duplex link; and each datagram
pays a 9P message, two AEAD operations and a UDP write in Dis, which
binds at 5.8 MB/s on the wire. sdg's case was its tail under loss, which
this link did not test.

What next, in order:

1. Make the link lose (`docs/experiments/loss`): 1% and 5%, TCP's Reno
   and 200 ms least timeout against sdg's 40 ms retries.
2. Compress the frames. A frame of a few kilobytes is a few datagrams,
   and the window and per-datagram costs cease to matter for either
   transport.
3. For sdg itself: larger reads per request (a reply of many datagrams),
   so that the window bounds bytes in flight, not messages.

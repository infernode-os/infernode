# sdg for video: predictions

Written 2026-11-11, before the apparatus exists or anything is measured,
and committed on its own so its date is before the results'. The
results go in `RESULTS.md` beside it, each prediction marked held or
broken; none of this is edited afterwards except to fix a typo.

## The question

Does sdg (9P over Noise-secured datagrams, `man/2/sdg`, styxbrick's
`docs/STYX-DGRAM.md`), with N reads in flight, beat what we use now --
9P over TCP with devssl -- for a live feed over Wi-Fi, and what does it
cost the server per viewer?

## What is compared

- **Server:** the Pi 5, bare metal, master. `vid9p -r` serves the
  480x270 I420 street scene live at 6 fps (194,400 bytes a frame), the
  feed the vision demo uses. The same export is served two ways:
  - **TCP**: `listen -a aes_256_cbc -a sha256 ... {export /mnt/video}`,
    as the demo does (master's devssl; #1159's AES-GCM is not merged);
  - **sdg**: a new `sdgsrv` (written for this) in front of the same
    export, with its X25519 keys and a pre-shared key. Its cipher is
    ChaCha20-Poly1305: the experiment measures the transport's shape,
    not a CNSA suite.
- **Clients:** the Mac over Wi-Fi (2.4 GHz, the case asked about) and
  the Orin AGX on wired Ethernet (the control).
- **Reader:** `tests/ninep_bench.b -f`, what wm/camera does: start at
  the newest frame and read each frame whole, as N contiguous pieces at
  once (`-p N`), N = 1, 4, 8, 16. Over sdg every 9P message is one
  datagram, so msize is 1200 and a frame is about 166 reads; N pieces
  keep N reads in flight. 16 is the most the protocol's reply cache
  (16 replies) serves safely. Over TCP msize is 32512, as an encrypted
  mount offers.
- **Measured:** per-frame read time (p50, p95, p99, max), frames lost
  (expired before they were read) and frames read, for 60 s a cell, 3
  runs a cell interleaved; bulk throughput on a 1 MB file
  (`ninep_bench` without `-f`); the Pi's CPU and memory per viewer, by
  running 1, 2 and 4 viewers.

## The model the numbers come from

- A read over sdg carries at most 1176 bytes of data (1200 less Rread's
  11 and the rid). With N in flight and a round trip R, a reader moves
  about N x 1176 bytes per R, until the link's packet rate or the Pi's
  cost per datagram binds first.
- The Mac's Wi-Fi round trip is about 4 ms with jitter to 24 ms
  (measured 2026-11-09). Each sdg reply needs its own request on the
  air, so the half-duplex link carries a request per reply where TCP
  carries a delayed ACK per two segments: sdg pays more airtime per
  byte.
- On the Pi each datagram is one decrypt, one 9P message through
  export, one encrypt and a UDP write, in JIT-compiled Dis: guessed at
  40-80 us, both directions together.
- TCP with devssl and 8 pieces read a 720p frame (1.38 MB) in 104 ms
  over the Mac's Wi-Fi (about 13 MB/s) and 39 ms wired from a Pi 4.
  One lost segment holds every later byte of the connection until it
  is retransmitted.

## Predictions

1. **Throughput on Wi-Fi: TCP wins.** Bulk read of 1 MB: TCP 8-13
   MB/s; sdg at N = 16 between 2 and 5 MB/s, at N = 1 under 0.4 MB/s.
   sdg reaches less than half of TCP's throughput at every N.
2. **Frame time on Wi-Fi, median: TCP wins.** 480x270 frames: TCP
   (N = 8) p50 15-40 ms. sdg p50 0.6-1.0 s at N = 1, 60-120 ms at
   N = 16. sdg's best p50 is at least twice TCP's.
3. **Tail on Wi-Fi: sdg's is shorter relative to its median.** TCP's
   p99/p50 is 2-5 (a loss stalls the whole frame for a retransmission;
   max over 250 ms in at least one run). sdg's p99/p50 is under 1.8 at
   N >= 8 (a loss costs one piece a 40 ms retry), and its max under
   400 ms. sdg's p99 is still above TCP's p99 in absolute terms unless
   TCP shows stalls in more than 1% of frames.
4. **The feed keeps up either way on Wi-Fi at N >= 8.** At 6 fps a
   frame is due every 167 ms: neither transport loses more than 2% of
   frames at N >= 8. At N = 1 sdg loses most of them (over 70%).
5. **Wired, sdg is bound by the Pi, not the link.** Orin to Pi 5: sdg
   at N = 16 between 8 and 20 MB/s bulk, limited by the cost per
   datagram; TCP 20-35 MB/s (the devssl cipher bound). sdg's p99/p50 on
   the wire is no better than TCP's (there is almost no loss to hide).
6. **Cost per viewer: sdg costs more CPU, less memory.** CPU per MB
   moved on the Pi: sdg 2-4 times TCP's, as every 1176 bytes pay a
   datagram, two AEAD calls and a 9P message. Memory per viewer: sdg
   under 64 KB (reply cache, replay windows, the export's state); TCP
   more, its queues sized for windows of hundreds of KB. With 4
   viewers at N = 8 on Wi-Fi the Pi's CPU, not the link, limits sdg
   first.

## What would change the conclusion

The expected conclusion is that sdg does not beat TCP for raw frames:
it trades throughput and server CPU for a shorter tail under loss, and
compressing the frames (a hundredfold smaller) matters more than either
transport. That conclusion is wrong if:

- sdg at N = 16 reaches 70% or more of TCP's Wi-Fi throughput, or its
  p50 frame time comes within 1.5x of TCP's (predictions 1, 2 broken);
- TCP stalls (a frame over 250 ms) in more than 1% of frames on the
  Mac's Wi-Fi while sdg has none, making sdg's absolute p99 the lower
  (prediction 3's last clause broken in sdg's favour);
- sdg's CPU per MB is within 1.5x of TCP's (prediction 6 broken).

Any of those would make sdg worth carrying further for video, with a
CNSA suite (ML-KEM-1024 and AES-256-GCM) in place of Noise's.

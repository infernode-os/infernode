# TCP and sdg under packet loss: predictions

Written 2026-11-11, after the knob (`drop` in `/dev/chaos`, commit
4d809f1ba) and before any run with it, and committed on its own so its
date is before the results'. The results go in `RESULTS.md` beside it,
each prediction marked held or broken; nothing here is edited afterwards
except a typo.

## The question

`docs/experiments/sdg-video` found sdg slower than 9P over TCP at every
N, wired and on Wi-Fi, with almost no loss on either link. Its claim for
sdg was a shorter tail when packets are lost, which that experiment
could not test. Here the loss is made: does sdg's tail, or its
throughput, overtake TCP's at 1% and 5% loss?

## What is compared

- **Server:** the Pi 5, bare metal, a CHAOS kernel built from 24b258773
  (master before #1159, the kernel source the sdg experiment's ciphers
  match) with the drop commit added. `vid9p` serves the same clip and
  1 MB file as there; TCP is `listen -a aes_256_cbc -a sha256 ...
  {export ...}`, sdg is `sdgsrv` in front of the same export.
- **Loss:** `drop N` loses one IPv4 packet in N sent and one in N
  received on the Pi's Ethernet, independently: N = 0 (off), 100 (1%
  each way), 20 (5% each way). The same kernel at N = 0 is the control,
  measured again rather than taken from the earlier experiment.
- **Client:** the Orin on wired Ethernet (its link loses almost nothing
  by itself, so the loss is the knob's), `tests/ninep_bench.b` as there.
- **Cells:** bulk read of the 1 MB file with 8 and 16 readers (`-c`);
  the unpaced clip read as N pieces at once (`-f 20 -0 -p N`), N = 8 and
  16, which gives each frame's read time. 40 s a cell, 3 runs, the
  rates interleaved within each run.

## The model

The baseline (sdg experiment, wired, no loss): clip frame p50 TCP 6 ms,
sdg 40 ms at N = 16; bulk TCP 30.5 MB/s, sdg 5.7 MB/s (c8 and c16
alike: the Pi's cost per datagram binds by 8).

- **TCP:** the Pi is the sender. Its TCP (os/ip/tcp.c) is Reno: fast
  retransmit on three duplicate ACKs, no use of the client's SACK
  blocks, a least retransmission timeout of 200 ms. A frame is 133
  segments on one connection. A loss with three segments behind it costs
  about a round trip and halves the window; a loss among the last
  segments in flight, or a second loss in one window, waits for the
  timeout: 200 ms, doubling.
- **sdg:** each read is a request (lost with p) and a reply (lost with
  p): about 2p of reads are retried, after 40 ms, then 80, 160, 200. A
  frame at N = 16 is 16 chains of about 10 reads; it ends with the
  slowest chain. A retry costs its own chain 40 ms and nobody else.

## Predictions

1. **No loss:** the CHAOS kernel at N = 0 matches the earlier baseline
   within 20% in every cell (the knob costs nothing when off).
2. **TCP's tail breaks first.** At 1%: TCP clip p50 under 15 ms at both
   N, but p99 over 200 ms (more than 1% of frames take a timeout) and
   max over 200 ms in every run. At 5%: TCP clip p50 over 20 ms and p95
   over 200 ms.
3. **sdg degrades smoothly.** At 1%: sdg clip (N = 16) p50 between 60
   and 100 ms (most frames hold one 40 ms retry), p99 under 180 ms, max
   under 300 ms. At 5%: p50 between 120 and 240 ms, p99 under 450 ms.
4. **At 1% sdg's p99 is lower than TCP's** (N = 16 both), while TCP's
   p50 stays at least 4 times lower than sdg's.
5. **Bulk:** TCP c8 at 1% between 5 and 22 MB/s, at 5% under 5 MB/s.
   sdg c16 at 1% at least 80% of its own N = 0 figure; at 5% at least
   55% of it. **At 5% sdg's bulk throughput (c16) is above TCP's (c8 and
   c16).**
6. **Neither fails:** no read errors, no stuck cells, through every run
   at 5%.

## What would change the conclusion

The expected conclusion: sdg is the steadier transport once loss is
real, beating TCP's tail at 1% and its throughput at 5%, while TCP stays
the faster one on clean links. That conclusion is wrong if:

- TCP's p99 at 1% stays under 100 ms (its recovery is better than the
  model: fast retransmit catches the tail losses too), breaking 2 and 4;
- sdg's p99 at 1% is over 250 ms, or its bulk at 5% under half its N = 0
  figure (retries cost more than their own chain: a stall in the client
  or server, not the network), breaking 3 and 5;
- TCP's bulk at 5% stays above sdg's (breaking 5's last clause).

If TCP's tail is the problem, the cheaper fix may be TCP's own (SACK on
the send side, a lower least timeout on a LAN), and that is worth
weighing against carrying a second transport.

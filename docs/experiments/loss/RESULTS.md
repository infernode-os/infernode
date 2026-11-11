# TCP and sdg under packet loss: results

Measured 2026-11-11, 04:36 to 08:29, after `PREDICTION.md` (9c3c5951b).
The Pi 5 ran a CHAOS kernel of 24b258773 with the drop commit
(4d809f1ba); the Orin read over wired Ethernet with `tests/ninep_bench.b`.

## What was run, and what changed on the way

Three sets were run. Only the last is clean; the first two are kept
because each found a fault.

1. **As predicted** (04:36-06:05): run 1 whole, run 2 stopped part-way
   (the failing sdg cells waited out a 200 s timeout that did not kill
   emu), runs 2 and 3 again with `timeout -k` and a bench that prints
   each reader's error and exits after one (`tests/ninep_bench.b`,
   48cf08593 and fff3fd106; what it measures is unchanged). Every sdg cell
   with loss failed `reply gone`. The 0% controls of runs 2 and 3 were
   slower than run 1's (TCP bulk 12 MB/s against 49): the Pi was a core
   busy with nothing running.
2. **The cause of both**, found between sets: sdgsrv's window was
   shifted with a `big`'s `>>`, which is arithmetic. A request held open
   while the one 64 above it finished set bit 63, and each shift copied it
   down: requests not yet sent were taken for run (`reply gone`), and a
   map of ones held the session in a loop for good, answering nothing and
   using a tenth of a core, until sdgsrv was killed (cb86ac99d, with a
   test that fails without it). Loss makes exactly that: a lost request
   stays open while the others go on.
3. **Clean** (07:5x-08:29): the fixed sdgsrv, the Pi's sessions killed
   first, three runs, every transport at every rate, the Pi's idle load
   checked after each run (0.098 busy ms per ms each time: no session
   spinning). sdg twice: with the brick's 16 replies kept (`sdg`) and
   with 1024 (`sdgsrv -c`, fff3fd106 and e6905cc54: a ring searched only for
   a retransmission; `sdgC`). The 1024 variant was not predicted; it
   answers whether the reply cache was the only limit.

In set 3 the sdg server's export had vid9p instances of its own (the
same files): a server restarted from the console's shell does not see
the binds the first one was started with.

## Results (set 3, three runs a cell)

| cell | loss | TCP | sdg (16 kept) | sdg (1024 kept) |
|------|------|-----|---------------|-----------------|
| bulk, 8 readers | 0% | 52.8-55.9 MB/s | 5.2-5.9 MB/s | 5.1-6.0 MB/s |
| | 1% | 0.23-0.25 MB/s | fails, `reply gone` | fails, `reply gone` |
| | 5% | stalls (40 s, nothing) | fails | fails |
| bulk, 16 readers | 0% | 54.3-56.7 MB/s | 5.4-7.0 MB/s | 4.4-6.4 MB/s |
| | 1% | stalls | fails | fails |
| | 5% | stalls | fails | fails |
| clip N=8, p50 / p99 ms | 0% | 4 / 5-6 | 36-38 / 50-73 | 37-38 / 52-56 |
| | 1% | 506-988 / 2006-2494 (19-34 frames of 144 in 20 s) | fails | 1-2 frames, then fails |
| | 5% | 4001-5503 / 5964-6203 (4-5 frames) | fails | fails (2 frames once) |
| clip N=16, p50 / p99 ms | 0% | 4 / 7-12 | 38-39 / 52-56 | 36-41 / 51-59 |
| | 1% | 987-997 / 2490-3005 | fails | fails |
| | 5% | 3752-4968 / 4202-7498 | fails | fails |

The Pi's TCP counters over the sets (since boot): 2359 segments sent
again, 1792 of them by the retransmission timer. Three losses in four
waited for the timer.

## The predictions

1. **No loss, the baseline within 20%: broken.** sdg matched the
   sdg-video experiment (clip p50 36-39 ms against 38-40, bulk 5-7 MB/s
   against 5.8); TCP was faster (bulk 54 MB/s against 31, clip p50 4 ms
   against 5-6): this kernel's TCP is not the one that experiment ran on.
2. **TCP's tail breaks first: held in direction, broken in size.** At
   1% the p50 was not under 15 ms but 0.5 to 1 s; p99 and max were over
   200 ms (2 to 3 s). At 5% p50 over 20 ms and p95 over 200: held (4 to 5
   s and 6 to 7 s).
3. **sdg degrades smoothly: broken.** sdg did not degrade; it failed.
4. **At 1% sdg's p99 below TCP's: broken** (sdg had no frames).
5. **Bulk: broken.** TCP at 1% 0.24 MB/s (5-22 predicted); at 5% under 5
   MB/s (held: nothing). sdg at 1% and 5%: nothing (80% and 55% of its
   no-loss figure predicted), and so not above TCP at 5%.
6. **Neither fails: broken.** Both did, at 1%.

## The conclusion

Not the one expected. Neither transport, as InferNode has them, carries
a feed across a link that loses 1% of its packets each way.

- **TCP** (os/ip/tcp.c, the Pi's sender): one lost segment in a hundred
  cut throughput 200-fold, and three losses in four were recovered by the
  timer (200 ms at least, doubling). Fast retransmit seldom fires: an ACK
  is counted as a duplicate only if its window is the same as the last
  (`seg->wnd == tcb->snd.wnd`), and a receiver holding data out of order
  changes its window; the sender ignores the SACK blocks the receiver
  sends; and a second loss in a window waits for the timer (Reno, no
  partial-ACK recovery). Each is a known fix: count duplicates as RFC
  6675 does, recover from SACK, NewReno's partial ACKs.
- **sdg** (STYX-DGRAM as specified, after sdgsrv's own fault was fixed):
  the window of 64 request ids and the 40 ms retransmission cannot hold
  together at LAN speed. With eight reads in flight the client sends
  about 4400 requests a second, 175 in one retransmission time: by the
  time a lost request comes again the server's window has passed it, and
  it can only say `reply gone`. A reply cache of 1024 changed nothing,
  so the cache was not the limit; the window was. The client must keep
  the requests it has outstanding within the window (no new rid more than
  64 past the oldest unanswered), or the window must cover a
  retransmission time at the link's rate. A read refused as gone could
  also be sent again under a new rid: it is idempotent.

The prediction's last paragraph said that if TCP's tail were the
problem, TCP's own repair might be cheaper than a second transport. Both
need repair; TCP's are standard and its no-loss figures are ten times
sdg's, so TCP's are the ones to make first. sdg's window rule belongs in
STYX-DGRAM itself, since a brick has the same constants.

## Open

- TCP: the duplicate-ACK test, SACK on the send side, partial ACKs;
  then this experiment again.
- sdg: the outstanding-window rule in the client (sdg(2)) and STYX-DGRAM;
  then this experiment again.
- Whether the same faults show on Wi-Fi's own loss (the Mac's link), not
  measured here.

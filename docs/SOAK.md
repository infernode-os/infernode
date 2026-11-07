# One soak for every Raspberry Pi — design

Status: agreed 2026-11-07; first cut of the runner in `tests/soak/soak.py`, to be test-run on the 3B+ once today's soaks end. It replaces three harnesses that drifted apart.

## Why

While the software was unstable, what mattered was comparing a soak with the last one on the same board, so each board's harness was kept frozen. Now that the software is settling, the question is "does this hold on every board?", and the current harnesses can't answer it:

| | 3B+ | Pi 4 | Pi 5 |
|---|---|---|---|
| harness | `soak/soak.py` + `radios.py` | `soak.py PIBOARD=pi4` + `extras.py` (+ `leak1107.py` today) | `pi5/soak5.py` + `soak5.sh` + `failwatch.py` |
| driven over | network console | network console | serial line |
| TLS | – | – | `tls_live_test` every 10 min (internet servers) |
| random numbers, RSA keys | – | – | yes |
| storage | `/tmp` churn only | `/tmp` churn | SD read/write, NVMe, kfs |
| buses, GPIO | GPIO jig (battery, daily) | – | SPI loopback, I2C, GPIO loop, PWM |
| radios | Wi-Fi push + Bluetooth (`radios.py`) | – | BLE scan + classic inquiry |
| VMs | – | `MULTIVM`, `VMSTRESS` options | jitbench in VMs 1–2, memtouch in VM 3 |
| USB gadget | – | disk/ncm/ecm/hid cycle | ncm traffic |
| network | 64 MB in every 10 min | in + out | in + out on wired, Wi-Fi, USB |
| memory sampled | `main` every 5 min | main, heap, image every minute | main, heap, image every 5 min |
| call sites | `/dev/memtags` hourly (`tagsnap.sh`) | – | – |
| heat | – | temp, throttle | temp, throttle, fan |
| failure output kept | battery logs only | partly | `bad.log` (was overwritten until today) |
| stop/alarm watcher | `soakwatch.py` | `soakwatch.py` | `soak5.py` stops on reboot or 3 timeouts |

Each harness was written by the session that brought up the board, for what that board could do then, and nothing ever merged them back. The result:

- **Coverage differs.** The Pi 5's TLS errors can't be checked on the other two boards, because nothing there makes a TLS connection.
- **Options go unrecorded.** VM stress on or off changes results, and the logs don't say which.
- **Samples and output differ.** Different sampling intervals, log formats and meanings of "failed" mean results can't be lined up.
- **None of it is versioned.** `~/pitools` lives outside git; the SSD failure on 2026-11-06 is a reminder.

## Principles

1. **One harness, in the repo** (`tests/soak/`), versioned and reviewed like any test. Board-specific behaviour comes from probing the board, never from `if board == ...`.
2. **A catalogue of loads.** Each load declares the resources it needs. The harness runs every load whose resources are present, skips the rest, and **flags each skip with its reason**. A skip never blocks the run.
3. **Resources are probed, at the start and throughout.** Is there an NVMe, is `/net/bt` up, does the gadget link answer, is the GPIO jig wired? If a resource goes away mid-run (the gadget cable moved to another board), that load is flagged *lost at t=...*, not failed, and the run goes on.
4. **The same core on every board.** A load the hardware allows runs the same way, for the same duration, with the same pass rule, on every board.
5. **Options, not forks.** VM stress, run length, sampling interval and load intensity are named options. They are printed in the run header and in the summary.
6. **Every failure is kept.** Each failure's output is saved with its time, never overwritten by the next run of the loop.
7. **One output format, and a ledger.** The same per-interval line, the same summary table and one ledger row per run, on every board.
8. **Shared host resources are reserved, not assumed.** The Jetson's NIC, its Bluetooth adapter, the USB gadget cable, minipc and the 6666 export are shared by every board's soak. Today the Pi 4's transfers ran at a third of their usual rate while the Pi 5's soak loaded the same Jetson NIC.

## Shape

```
tests/soak/
  soak.py           the runner: probe, start loads, sample, judge, summarise
  loads/            one file per load: needs(), start(), check(), stop()
  probes.py         resource probes (board side over the console, host side locally)
  samplers.py       memory, memtags, heap census, heat, interfaces
  hostres.py        reservations on the Jetson's shared resources (lock files)
  board/            the Limbo/sh pieces that run on the board (soakd.sh)
  README.md
~/soak/runs/<board>-<date>-<kernel>/   one directory per run (outside the repo,
                                       copied to the ledger's store at the end)
```

**Talking to the board.** Every load and sampler works over either transport. The network console is preferred: serial cables are scarce, and a console can hold several sessions at once. Serial is the fallback, for boards without a console or with a broken network. It always *reads* the serial line through the capture (`sercap.py`), never a second reader. The board-side loops (`soakd.sh`) run in a namespace of their own and stop when `/tmp/soak/run` goes (not `soak.py`'s `/tmp/soak.run`, so the two can never stop each other). That fixes the 2026-10-18 problem of loops outliving the soak. Each loop writes `tick`, `bad`, `.out` and `.err` files under `/tmp/soak/<load>/`, as `soak5.sh` does, but each failure goes to `/tmp/soak/<load>/fail-<n>`, so nothing is overwritten.

**Two board-side traps found on the first runs:**
- In Inferno's shell, `@{ }` does not fork the namespace. A bind inside one leaks into the loops' shared namespace, and the run's TLS CA replaced every trusted root. Use `sh -c '...'`, which forks the namespace by default.
- A braced block has its own arguments, so `$1` is empty inside it. Take arguments into variables first.

**The TLS server** is shared: one CA and one certificate in `~/soak/tls`, and one `openssl s_server` on the Jetson's port 8443, started by whichever run needs it first and left up for the others. The Jetson's firewall lets the LAN reach 8443 but not other ports such as 8444 or 8460, so per-board ports failed.

**Board identity** comes from `~/pitools/boards`, found by MAC through `boardip.py` and by serial port through its by-path name, never `ttyUSBn`. The runner records the kernel's size and sha1 from `/dev/bootimage` and the card's `/dis` state: md5s against the build, with the number that differ. A run on a stale card says so in its header ([[bench-card-dis-stale]]).

## The load catalogue

Core loads run on every board. Gated loads run where their resource exists.

| load | needs | from | what it does | pass |
|---|---|---|---|---|
| **fs** | – (core) | soak.py loops 0–3 | copy/ls/echo/cat churn on `/tmp` and `/dis`; `/dev/memory` reads | loops stay up |
| **proc** | – (core) | soak.py | process churn (spawn, exit, kill of its own children only) | no stuck processes |
| **net-in / net-out** | wired (core) | soak.py, extras, soak5 | 64 MB in and out every 10 min; rate logged | no failure; rate within its band |
| **net-frag** | wired + a fragment-carrying path (probed) | ethernet battery | fragmented echoes every hour | ≥ host baseline (measured host-to-host on the same path, since the path may lose fragments) |
| **tls** | wired + Jetson TLS server (core) | soak5 (made local) | handshake + 64 KB read and write against `openssl s_server` on the Jetson, every 2 min; TLS 1.2 and 1.3, P-256 and X25519; verified with a test CA; needs no clock and no internet | every handshake and read |
| **tls-live** | internet + a set clock (gated) | soak5 | the current `tls_live_test` against example.com and cloudflare.com, every 10 min | flagged, not judged: the internet is not ours |
| **rng** | – (core) | soak5 | `/dev/random` at 4 MB/min; two reads never equal | never equal |
| **rsa** | – (core) | soak5 | `auth/rsagen -b 1024` every minute | no error |
| **jit** | – (core) | extras | jitbench2 every cycle, timed | no crash; time within band |
| **vm** | multi-VM kernel (probed: `#X`) | soak5, extras | jitbench in VMs 1–2, memtouch in VM 3 | VMs advance |
| **vmstress** | option `--vmstress` + multi-VM | extras | vmstress(1): echo servers, allocators, kills across VMs | 0 failures, report advancing |
| **sd** | card (core) | soak5 | read 64 MB; write, verify, remove a 1 MB file on `/n/dos` | verified |
| **nvme** | `#S/nvme0` (gated) | soak5 | read; write+verify on a scratch partition; kfs on another | verified; media errors 0 |
| **usbdisk** | gadget `disk` reservation (gated) | extras | copy + md5 of 4 MB on `/n/usb0` | verified |
| **usbnet** | gadget `ncm`/`ecm` reservation (gated) | extras, soak5 | 32 MB each way | no failure |
| **usbhid** | gadget `hid` reservation (gated) | extras | FunctionFS pointer; board must claim it | claimed every cycle |
| **wifi** | Wi-Fi associated (gated) | radios.py, soak5 | 32 MB push to its address | no failure |
| **bt** | `/net/bt` up + Jetson adapter reservation (gated) | radios.py, soak5 | l2ping, L2CAP 2000×600 B, RFCOMM 1000×500 B, inquiry, LE scan; links back to 0 | data intact, no leaks |
| **gpio** | GPIO jig (gated, probed by loopback) | gpio battery, soak5 | toggle and read back each loop pair; PWM | every read |
| **spi / i2c** | `#Q` / `#J` with loopback/device (gated) | soak5 | SPI loopback compare; I2C reads | compare equal |
| **draw** | a display (gated) | soak5 | drawbench every 30 s | no error |
| **board** | per device (gated) | soak5 | RTC, fan, nvmestat, `#P` reads | no error |
| **console** | serial captured (core) | serialwatch.sh | hourly: the serial shell runs a command (the 2026-11-07 wedge) | runs |

Batteries (Ethernet, Bluetooth, GPIO) run at the start and the end of every run, whatever its length, and daily in long runs. That way a 12-hour run has before and after results, unlike today, where the daily battery never fires in 12 hours.

## Intensity, and not wearing out the hardware

The aim is to test the hardware, not wear it out. The rules:
- **Reads are cheap**, so they stay frequent.
- **Writes to flash are small, verified and budgeted.** Each run reports what it wrote to each device.
- **Raw block devices are never written** unless `--scratch DEV=PART` names a partition for it. The Pi 5's NVMe is a store with data on it.

`--profile gentle|normal|stress` sets every area. `--stress storage,net,cpu,vm,fuzz` raises single areas to stress. Both are recorded in the header, summary and ledger.

| | gentle | normal | stress |
|---|---|---|---|
| SD raw reads | 16 MB / 10 min | 16 MB / 2 min | 64 MB / 30 s |
| SD file writes (verified, removed) | none | 1 MB / 10 min = 144 MB a day | 4 MB / 2 min = 2.9 GB a day |
| NVMe raw reads | 64 MB / 10 min | 64 MB / 2 min | 256 MB / 30 s |
| NVMe writes (scratch partition only) | none | 1 MB / 5 min = 288 MB a day | 16 MB / min = 23 GB a day |
| network pushes | 16 MB / 30 min | 64 MB each way / 10 min | 64 MB each way / min |
| connection churn | 50 + 2 half-open | 200 + 8 half-open / 10 min | 1000 + 32 half-open |
| JIT, RSA keys, random | every 15 min / 10 min / 256 KB | 5 min / 1 min / 4 MB | 1 min / 10 s / 16 MB |
| sysfuzz | off | off | 10 min an hour, scratch in `/tmp` |

## Loads added for the security and fuzzing work

These cover what no harness exercised before:
- **churn:** TCP connects and closes, and half-open connections held for 60 s. The board's conversation count must come back down afterwards. This exercises the fixes for reaping half-open TCP state, bounding queues and pre-auth limits.
- **latency:** a ping every minute, average and maximum. #1033's problem was latency, and nothing measured it continuously.
- **tls:** handshakes and reads against a local server (above).
- **fuzz:** `sysfuzz` on the board, opt-in. It is the tool that found many of the bugs the kernel work fixed, and the boards never ran it.
- **samplers:** process count, TCP conversations and board-clock drift every minute. A slow growth in processes or conversations is a leak that pool sizes can hide.
- **serial detectors:** besides panics, the kernel's complaints (`out of memory`, `won't halt`, `ether0rx`, a full input queue, `wedged`) are counted in the summary.

## Samplers

The same intervals on every board:

- every minute: `main`, `heap`, `image` pools (`/dev/memory`); the heap's live objects; the kernel's size and sha1 (a fallback to the old kernel shows as a change).
- every 5 minutes: temperature, throttle word, fan; interface counters (in, out, errors, drops) for every interface; processes count.
- every hour: `/dev/memtags` (call sites, symbolised at the end with the run's own ELF); `ps` in full; `/dev/heapaudit` when the kernel has it.
- floors, not raw samples, for leak judgements: the minimum of the last 6 samples, as the Pi 4's camera soak did. Process churn makes single samples noisy.

## Judging

The runner stops and alarms (soakwatch's job, folded in) on:
- a panic or a fault on serial
- a reboot or a fallback to the old kernel
- the board not answering three times
- heat past the soft limit (hard throttling, a capped clock, under-voltage, 85 °C)
- a core load failing twice in a row

At the end it writes a **summary**:
- **header:** board, kernel size and sha1, commit, card `/dis` state, options, host contention seen
- one row per load: ran / skipped (why) / lost (when); passes, failures, the first failure's file
- pool floors at the start and end, and the slope per hour
- the ten call sites that grew most, by bytes and blocks
- rates for each network path, with their band
- battery results before and after

It also appends one **ledger** row (board, date, kernel, options, length, result, slope) to `~/soak/ledger.tsv`, so any two runs on any boards can be set side by side.

## Shared host resources

`hostres.py` takes a lock under `~/soak/locks/` for each of these: the Jetson NIC for bulk pushes, the Bluetooth adapter `hci0`, the USB gadget, minipc, and the 6666 export.

- **Bulk network pushes are staggered.** Two boards' 64 MB pushes never run at once: each run takes the NIC lock for its push.
- **Contention is recorded.** When another run holds a lock, the run waits, up to a bound. Every wait is logged and ends up in the summary as "host contention".
- **The gadget belongs to one board at a time.** Its lock records which board holds it and since when.
- Locks are advisory; sessions still ask each other before touching a board ([[ask-before-using-a-board]]).

## Board profiles today

Probed, not declared. The table shows only what each board would get as things stand.

| | core | gated loads available |
|---|---|---|
| 3B+ | all | bt, gpio (jig), wifi (if a `/n/dos/wifi` network is set), draw (HDMI) |
| Pi 4 | all | usb* (when it holds the gadget), bt, wifi, vm/vmstress, draw (DSI), camera (as a gated load, from today's camera soaks) |
| Pi 5 | all | nvme, spi, i2c, gpio loop, pwm, bt, wifi, usbnet, vm, draw, board (RTC, fan) |

## Migration

1. **Wait for today's soaks to finish.** Collect their outputs; nothing is changed under them.
2. **Build the runner.** Port the loads one at a time, each with the pass rule it has now. TLS gets a local server. Then delete the parts of the old scripts that the runner replaces.
3. **Check equivalence.** Run the new harness on all three boards side by side for 2 hours each, with the old harness's loads switched on. Its rates, counts and pool slopes must match the old harness's on each board; where they don't, find out why before going on.
4. **Retire the old harnesses.** `soak.py`, `soak5.*`, `extras.py`, `radios.py`, `soakwatch.py`, `failwatch.py`, `tagsnap.sh` and `serialwatch.sh` go to `~/pitools/attic/`, with a note in the ledger of the run that replaced each.

## The debug probe

There will be one SWD/JTAG debug probe. It is a reserved resource like the gadget cable: one board holds it, and the holder is recorded in the run header. The runner doesn't use it in normal running. When a board panics, hangs or stops answering, the run that holds the probe first takes a capture: registers and stacks of every core. Only then does anything reset the board.

Wiring the probe up is a gated item in each board's profile:
- 3B+ and Pi 4: JTAG on the GPIO header (`enable_jtag_gpio=1`).
- Pi 5: its debug connector.

Each board's support is confirmed on the board when the probe arrives, not assumed.

## The ledger

The pi-store is offline. The ledger goes in a small private repository of its own (`infernode-bench`, to be made), together with each run's `summary.txt` and memtags diff. That is small text only; raw logs stay on the Jetson. Each run pushes when it ends, so the record is off this machine at once. Bench details such as MACs and home-network addresses stay out of the public repo, and run churn stays out of master's history. Until that repository exists, the runner writes `~/soak/ledger.tsv` and the run directories, and they are copied to minipc as a second copy.

## Open questions

- What should the TLS server be: OpenSSL `s_server` on the Jetson, or the tree's own TLS server in emu, which would test both ends?
- Which of today's ad-hoc probes become loads: `bootloop.py` (boot counts per run), `flood.py` (console flood as a load, `--flood`)?

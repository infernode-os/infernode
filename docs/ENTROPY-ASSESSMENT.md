# Measuring the hardware generators (SP 800-90B)

Every key a bare-metal InferNode makes comes from `os/port/random.c`: an
HMAC_DRBG (SHA-512) instantiated and reseeded only from the board's hardware
generator, through `hwrandom()`. That file takes one number on trust: **4 bits
of entropy a byte** of hardware output. `Seedbytes` (64, for 256 bits) and the
SP 800-90B health tests' cutoffs (repetition count 6, adaptive proportion 62
of 512) are made from it. Nobody had measured it, on any board.

This document is how it is measured, and what a measurement can and cannot
say. Until a board has a result recorded below, its generator's rate is an
assumption.

## What each board has

| Board | Kernel | Source behind `hwrandom` | What a measurement can say |
|-------|--------|--------------------------|----------------------------|
| Pi Zero 2 W, Pi 3B+ | `os/bcm2837` | The BCM2835-family generator (`os/bcm2837/random.c`). Undocumented internals; no health status to read | Rate and restart behaviour of what the block outputs |
| Pi 4B | `os/bcm2711` | Broadcom's iProc RNG200 (`os/bcm/rng200.c`). Has its own NIST health test and lockout, which the driver honours | The same. The register layout (separate RNG and RBG resets, a "NIST fail" bit) suggests a conditioning stage Broadcom does not document |
| Pi 5 | `os/bcm2712` | The RNG200, as the Pi 4 | The same; on this board it is so far only read, not tested (`os/bcm2712/INVENTORY.md`) |
| BeagleV-Fire, Icicle Kit | `os/mpfs` | The system controller's nonce service: **a DRBG's output**, seeded from a TRNG the U54s cannot reach | Not the source's entropy: a DRBG's output passes every test whatever seeds it. Only the restart test and the comparison between boards mean anything |
| QEMU virt (arm64, riscv64) | `os/virt`, `os/riscvvirt` | virtio-rng: the host's generator | Nothing about any hardware. Useful to check the tools end to end |

The hosted emulator (including on Jetson) takes the host operating system's
generator (`docs/TLS-ENTROPY.md`) and is outside this document.

**A PASS is necessary, not sufficient.** The tests find a source that is
biased, correlated, too slow to change, or that starts in the same place at
every boot. They cannot find output that a block has conditioned: AES of a
counter under a key nobody else has passes them all. If the RNG200 or the
BCM2835's generator conditions internally, what can be read is an upper
bound on what is beneath. That risk is handled by design, not by testing: a
second, independent source mixed into the DRBG so that no one block is the
only thing keys depend on (open: see the end).

## The mechanism

A boot whose command line holds the word **`rngassess`** gives eve two files
of `#c` (`os/port/random.c`, "Measuring the generator"):

| File | What it is |
|------|------------|
| `/dev/hwrandom` | The hardware's bytes as `hwrandom` gives them: no DRBG, no health test, nothing refused. A byte read here is read once and used for nothing else |
| `/dev/hwrandomboot` | The first 4096 bytes the hardware gave on this boot, before anything else took one: every kernel reader of the generator (the DRBG, `seedrand`, TCP's `isnkey`) waits until they are captured, a few milliseconds |

On any other boot both refuse to open ("the boot command line does not say
rngassess"). An `rngassess` boot still makes keys only from the hardware; they
wait for the capture first. Treat it as a diagnostic boot all the same, and
take the word off afterwards.

`rngdump(1)` (`appl/cmd/rngdump.b`) writes them to a file, exactly the bytes
asked for, and prints a line of quick statistics (rate, SHA-256, most common
byte, chi-square, ones a bit position, equal neighbours). The statistics are
a smoke test, not the assessment. The same line carries the board's own
record of power and heat before and after the capture (`throttled0`,
`cputemp0`, `throttled1`, `cputemp1`, from `#P/throttled` and `#P/cputemp`;
`none` on a board without them), and a capture during which the firmware
saw under-voltage says so on standard error.

For the restart test, `osinit` collects without anyone watching: with
`rngassess` and **`rngrestart=N`** on the command line (N the boots wanted),
each boot appends its 4096 first bytes to **`/n/dos/rngboot.bin`**, checks the
file grew by exactly that, and resets the board (the PM watchdog's full reset)
until it holds N boots. Then it says `rngrestart: N boots collected ... done`
and boots on; a boot after that adds nothing. A file `/n/dos/rngrestart`
holding N does the same, but is not the way to start it: written at the
shell and followed at once by `echo reboot > /dev/sysctl`, it was not on the
card after the reset (under QEMU; five seconds later it was), and the loop
never began. Edit `cmdline.txt` with the card out instead. Anything that goes
wrong stops the loop instead of resetting again. Each boot also appends a line
to **`/n/dos/rngboot.log`**, `boot 17 throttled=0x00000 ok cputemp=51.2`: the
firmware's flags (under-voltage, clock capped, throttled, soft temperature
limit, now and since boot) and the SoC's temperature, so that a sample taken
on a sagging supply is known from the evidence, not from whoever happened to
be watching the screen.

## The procedure, a board

1. **A card built from this tree**, with this kernel (`docs/BAREMETAL.md`,
   `tools/mkpiimage.sh`). Note the board's serial number
   (`/dev/sysname` or the firmware's) for the results.
2. **`rngassess`** added to `cmdline.txt` on the card's boot partition.
   Run each capture on the board's normal supply, and keep `rngboot.log`
   and the printed lines: they say whether it sagged.
3. **The raw sample**, at the console:

   ```
   rngdump -n 1000000 /n/dos/raw1.bin
   rngdump -n 1000000 /n/dos/raw2.bin
   rngdump -n 1000000 /n/dos/raw3.bin
   ```

   Three runs, so a result that changes between runs shows. Keep each
   printed line, in a file (`dumps.txt`) for the assessment. A board kept somewhere cold or hot can have a run there
   too: the noise of a physical source moves with temperature and voltage.
4. **The restart collection**: power off, put the card in another machine,
   and make `cmdline.txt` say `rngassess rngrestart=1000` (with whatever
   else it said). Put the card back and power on.

   A thousand resets: hours, at a boot's length each. Watch the first few
   on the console (`rngrestart: boot 2 of 1000 kept; resetting`). These are
   warm resets. A cold restart (the power taken away) is the better test of
   a generator that keeps state; with a relay or a switched USB hub on the
   board's power, cycle it instead, waiting 10 s off each time, and the same
   file grows by one boot a power-on.
5. **When it says done**: take `rngassess` and `rngrestart=1000` off
   `cmdline.txt`, power off, and copy `raw*.bin` and `rngboot.bin` from the
   card's boot partition, with `rngboot.log`.
6. **The assessment**, on any Linux or macOS host:

   ```
   tools/entropy/assess.py -c 4 -o report.txt -b rngboot.bin -d dumps.txt raw1.bin raw2.bin raw3.bin
   ```

   It builds NIST's tools at a pinned commit (`tools/entropy/build-nist.sh`)
   and runs the non-IID estimators, the IID tests, and the restart test on
   the first 1000 bytes of the first 1000 boots, and looks for any 32-byte
   block repeated between files or at the start of two boots. The last line
   is `VERDICT: PASS` or `VERDICT: FAIL` with reasons; the line before it,
   `CONDITIONS:`, is `clean` or says which samples were taken under
   under-voltage or throttling, or that nothing recorded it (`rngboot.log`
   is read from beside `rngboot.bin`; `-l` names another). A verdict is
   about the bytes and conditions do not change it, but a PASS whose
   conditions are not clean is not a clean baseline. Give two boards' raw
   files together to check they are not the same stream.

`tests/host/entropy_assess_test.sh` checks the assessment itself: the host's
generator passes, and a source of three random bits a byte, a thousand
identical boots, one stream given as two boards, and a short sample each
fail with their reason.

## Reading a result

- NIST's non-IID estimators are lower bounds and conservative: a perfect
  generator gets about 7.3 bits a byte from a million samples (the host's,
  measured with these tools). Expect a good hardware source near that.
- `credit` is `min(H_original, 8 × H_bitstring)`. A source whose bytes are
  fine but whose bits are structured (an upper bit stuck, say) is credited
  far less than its bytes' entropy: three random bits a byte is credited
  1.06. When a figure is low, the two parts say which.
- One run can come out lower than the rest by chance. The Pi 4's third run
  was credited 6.638 where the others had 7.2: one estimator (MultiMCW,
  90B 6.3.7) saw four correct predictions in a row where the others saw
  three, a local estimate from a single run that comes about one time in
  thousands. Its words, blocks and per-byte counts were all as chance has
  them. A low run is a reason for more runs, not for a lower claim on one.
- The rate is the board's: the Pi 4's RNG200 gave 79 KB/s through
  `hwrandom`, not the 190 KB/s this file once expected.
- The kernel claims 4. A board credited at least that, with the restart
  test passed, keeps `Seedbytes` and the cutoffs as they are. One credited
  less needs them made from its own figure, before any key it made is
  trusted again.

## Results

| Board | Serial | Date | Credited (bits/byte) | IID | Restart | Verdict | Report |
|-------|--------|------|---------------------|-----|---------|---------|--------|
| Pi 4B (rev 1.5 by earlier notes, not read this run) | not read | 2026-11-23 | 6.638 (three runs: 7.215, 7.243, 6.638) | passed, all three | passed, 1000 boots (watchdog resets, one power cycle among them) | PASS | Kept privately with the raw files; built from `5f0f4fee` |
| Pi 5 | | | | | | not yet run | |
| Pi 3B+ | | | | | | not yet run | |
| Pi Zero 2 W | | | | | | not yet run | |
| BeagleV-Fire | | | | | | not yet run (DRBG output: restart only) | |
| Icicle Kit | | | | | | not yet run (DRBG output: restart only) | |

## What follows from it (open)

- **The cutoffs from the measurement.** `Rctcutoff` and `Aptcutoff` in
  `os/port/random.c` from each board's credited figure (or the lowest), and
  `Seedbytes` so that a seed carries 256 bits at it.
- **SP 800-90B's start-up test (4.3).** The tests run on the first seed's 80
  bytes only; 90B asks for 1024 samples tested before the first output.
- **A second, independent source** mixed into the DRBG as additional input
  (an eve-only path into `random.c`), so that a generator that is broken or
  dishonest in a way no test can see is not alone: a USB hardware generator,
  an SDR's receiver noise (sdrfs), or a camera's sensor noise (camsrv's raw
  frames).
- **The RNG200's own health-test failures** are counted by its driver and
  reset but not reported anywhere but the console; a count readable during
  an assessment would show whether the block ever tripped.

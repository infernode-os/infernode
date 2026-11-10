# TLS Entropy Source Selection

## Background

Inferno's cons driver (`#c`) serves two entropy devices:

| Device | Implementation | Throughput | Use case |
|--------|---------------|------------|----------|
| `#c/random` | Timing jitter between two kprocs (emu); the board's hardware generator (bare metal) | ~80ms/byte (emu) | Bare-metal Inferno |
| `#c/notquiterandom` | HMAC_DRBG (`libsec/hmacdrbg.c`) over the host's generator (emu) or the board's hardware generator (bare metal) | nanoseconds/byte | emu on macOS/Linux, and bare metal |

## How `#c/random` works in emu

Two kernel processes run concurrently: `genrandom` spins counting a free-running
counter, and `randomclock` wakes every 20ms and samples that counter.  The timing
difference between the two processes provides genuine hardware entropy — the
scheduler jitter on real hardware is unpredictable.

One byte is written to the ring buffer every 4 clock ticks (80ms).  Generating
64 bytes of key material (two 32-byte values for a TLS handshake) takes ~5 seconds.

The bare-metal kernels no longer do this; see "Bare-metal Inferno" below.

## How `#c/notquiterandom` works

`#c/notquiterandom` reads `genrandom()` (`libsec/genrandom.c`), the generator
every key in the emulator comes from: HMAC_DRBG with SHA-512 (NIST SP 800-90A
Rev. 1, 10.1.2, `libsec/hmacdrbg.c`), the same code as the bare-metal kernels'.
It is instantiated from 48 bytes of the host's generator as entropy input and
16 as nonce, with a personalization naming it, and reseeded from 48 more every
1M bytes, every 65536 Generates, and in a process other than the one that
seeded it. NIST's CAVP vectors are checked before its first output. The host's
generator is `prngtry()` in `libsec/prng.c`:

- **macOS**: `arc4random_buf(p, n)`, seeded from the hardware entropy pool.
- **Linux**: `getrandom(p, n, 0)`, the kernel CSPRNG, seeded from hardware
  entropy (`/dev/hwrng`, RDRAND, boot-time jitter, etc.).
- **Windows**: `BCryptGenRandom`.
- **Other POSIX**: `/dev/urandom`.

Its output is a conditioned, full-entropy source, so it is not put through SP
800-90B's health tests as a board's raw bytes are. With no host generator
nothing is given: the read fails (keys made by `genrandom()` stop the
emulator, as `prng()` does), with no fallback to a weaker source. The
emulator's generator was ChaCha20 keyed from the host's, and the device read
the host's generator itself; neither is on a NIST or CNSA list.

## Why `tls.b` prefers `#c/notquiterandom`

The name "notquiterandom" is a historical Inferno convention dating from when it
was a weak LCG.  The name has not caught up with the implementation.  In this
codebase, when running under emu, it is the **stronger** source:

- Draws from a larger entropy pool than clock jitter
- Not predictable on virtualised or containerised hosts where scheduling is
  controlled by the hypervisor (timing-based entropy is weaker on VMs)
- Five orders of magnitude faster: nanoseconds vs 80ms/byte

`tls.b` opens entropy sources in priority order with fallback:

```limbo
randomfd = sys->open("#c/notquiterandom", Sys->OREAD);  # fast OS CSPRNG
if(randomfd == nil)
    randomfd = sys->open("/dev/urandom", Sys->OREAD);   # POSIX fallback
if(randomfd == nil)
    randomfd = sys->open("#c/random", Sys->OREAD);      # bare-metal fallback
```

The fd is opened **once** in `init()` and reused across all TLS connections.
Opening `#c/random` per-call was the original code; each open added to the
startup latency without improving entropy quality.

## Bare-metal Inferno

On the bare-metal kernels (`os/`), both files, and libsec's key
generators, are served by one generator in `os/port/random.c`, keyed from
the board's hardware generator `hwrandom()` alone (the Pi 3's in
`os/bcm2837/random.c`, the Pi 4's and Pi 5's RNG200 in `os/bcm/rng200.c`,
virtio-rng on QEMU's virt):

- It is HMAC_DRBG with SHA-512 (NIST SP 800-90A Rev. 1, 10.1.2), which
  CNSA admits: ChaCha20, the generator it replaced, is on no NIST list.
  Each request is one Generate (64 KB at most) and its Update, so what a
  request returned cannot be recovered from the state left afterwards.
- It is instantiated from 64 bytes of hardware entropy and a 16-byte
  hardware nonce (the RNG200 is taken to give 4 bits a byte, so 64 bytes
  carry the 256 bits its strength needs), and reseeded from 64 more every
  second or every megabyte. Until the first have come, nothing is
  returned: readers wait, and the console says why every five seconds.
  If the hardware goes dry the old state serves for at most ten minutes,
  then readers wait again.
- Every hardware byte passes SP 800-90B's continuous health tests
  (repetition count, adaptive proportion) before it is used, and a seed
  that is one word over and over, or the last seed again, is refused.
- A machine with no generator makes no key. `hwrandom()` says so (-1)
  rather than make bytes up, and every reader waits, saying why, unless
  the boot command line holds `insecurerandom`, which keys the generator
  from a labelled counter for an emulator with nothing better. A Dis
  program waiting in a key generator lets go of the VM while it waits.
- HMAC_DRBG is checked against NIST's CAVP vectors before its first use;
  a kernel that does not give them panics rather than make keys.
- `#c/notquiterandom` (`genrandom()`) and `#c/random` (`randomread()`) are
  the same generator; the two names stay for what reads them. On a Pi 5
  it gives about 236 MB/s in 64 KB reads, and 7 µs a 32-byte read.

So the order in `tls.b` is right on bare metal too: `#c/notquiterandom`
opens and is the kernel's generator.

## Performance impact

Measured on macOS ARM64 (Apple M-series) running Inferno emu:

| Configuration | Per-connection TLS | Wikipedia load |
|---------------|-------------------|----------------|
| `#c/random` (original) | ~9,000ms | ~46,000ms |
| `#c/notquiterandom` (current) | ~100–2,400ms | ~3,500ms |

The first connection is slower (~2.4s) because it includes RSA certificate
chain verification in pure Limbo.  Subsequent connections to the same server
reuse TLS 1.3 session tickets and take only network RTT (~100ms).

## References

- `emu/port/random.c` — emu's `#c/random` implementation and design comments
- `os/port/random.c` — the bare-metal pool, `genrandom`, `prng`, `prngtry`
- `libsec/hmacdrbg.c` — HMAC_DRBG, shared by both
- `libsec/genrandom.c` — the emulator's generator
- `libsec/prng.c` — the host's generator, `prng()` and `prngtry()`
- `appl/lib/crypt/tls.b` — entropy selection in `init()` and `randombuf()`

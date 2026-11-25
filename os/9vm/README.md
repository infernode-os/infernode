# os/9vm — the 9vm board

[9vm](https://github.com/kiljoy001/9vm) is a small KVM microVM runner for
native Harvey, Purgatorio/Inferno and GEFS guests. What it offers a guest
beyond a console is the **`#~` host ring**: a shared-memory 9P2000
transport in the top 2 MiB of guest physical RAM, served by a host thread
on another core. This directory is the guest side of it for `os/amd64`.

## What the host publishes

9vm reserves the top 2 MiB of RAM, publishes it in the Multiboot memory
map as a private entry of type `0x9009`, and puts this at its start:

```
magic 0x39524853, version 1, features
channel:   submission ring + completion ring + 8 x (32 KiB request, 32 KiB response)
buffer[8]: the request/response pairs
ns:        a second channel, present when features has FEAT_NS
nsbuffer[8]
```

A channel is a group at a fixed offset: its two rings, then its eight
buffer pairs. Each ring has 256 descriptors and is
Single-Producer/Single-Consumer: the guest publishes with head, the host
consumes with tail, and the completion ring the other way round. A
descriptor does not carry an address — `buf_addr` is an index in 0..7 that
both sides check — so the guest and the host may map the region
differently.

A request is a **complete 9P message**, copied into `buffer[i].request`,
with a descriptor naming the type, tag, length and buffer. The host checks
that the message's own header agrees with the descriptor, serves it, and
answers into `buffer[i].response`; the completion names the buffer again.
8 buffers means 8 requests in flight.

`features & FEAT_NS` adds the `ns` channel, which 9vm relays to whatever
9P server it was given with `-ns`. A namespace server answers in its own
time and order, so its channel is the one that can complete slots out of
order.

## Channels and #~

A board is an array of channels, not two named fields. `boardattach`
walks a table of what the ABI version defines — `host` at the channel
offset, `ns` when `FEAT_NS` is set — so a later version that adds a ring
is a row in that table, and nothing above `boardattach` changes. Each
channel is an independent `Ring`: its own submission and completion
rings, its own eight buffers, and therefore its own eight requests in
flight.

The console labels them by index, `#~/0` and `#~/1`, the names the device
layer will use; `host` and `ns` are the conventional names shown beside
them. A boot with no `-ns` offers one channel, `#~/0`.

## What is here

| file | |
|-|-|
| `board.h` | the guest's copy of the ABI, the channel array and client types |
| `ring.c` | attach, validate, slot allocation, submit, completion |
| `p9.c` | 9P2000: version, attach, walk, open, read, clunk |
| `selftest.c` | the boot smoke test, when the command line asks |

`ring.c` asserts the structure sizes and offsets at compile time against
9vm's `9ring.h`, so a host-side change fails the build instead of
corrupting the ring. `boardattach` also refuses a region shorter than the
header, or one beyond the identity map.

Completions are collected per buffer, not per request order: `ringrecv`
reaps everything the host has published and waits for its own buffer, so
a request may be collected after a later one. The ns channel relies on
this, and the boot test proves it: the stub 9P server answers eight
concurrent reads in reverse order, each reply carrying data derived from
its own request's offset. A guest that paired replies by arrival order
would verify the wrong bytes; the test prints `replies out of order` from
the ring's completion trace.

There is no timer or interrupt yet, so a wait is a bounded spin
(`RINGSPINS`). The bound turns a dead host into a failed request rather
than a hung machine.

## The smoke test

`main.c` hands the `0x9009` region to `boardattach` and runs
`ringselftest` when the command line contains `ringtest`. The test:

1. negotiates 9P2000 with `msize = 32768`, the ring's message size, on
   **every** channel the host offers, and attaches to each;
2. on `#~/0`, walks two elements to `sub/hello.txt`, reads it, checks the
   text;
3. opens `pattern.bin` and leaves **all eight buffers in flight** on
   `#~/0`, each read the host's stated `iounit`;
4. while those eight are outstanding, walks `.` and then reads `data` on
   every other channel — so more than one ring is in use at once — and
   the server behind the ns channel answers its eight reads in reverse,
   which the test reports as `replies out of order`;
5. collects the eight reads and verifies every byte against the
   `'a' + i%26` pattern the host exported — in place, in the ring buffer,
   with no copy.

`tests/host/amd64_boot_test.sh` builds the kernel, exports a small tree,
runs the test under 9vm, and runs a second boot with `-ns` against a stub
9P server (`tests/host/ns9p_stub.c`) to exercise the relay. It also boots
under QEMU, which has no ring: the kernel must still report its map and
halt.

```
infernode/9vm: ring at 0x000000000fe00000, 2097152 bytes, features 0x1, 2 channel(s)
infernode/9vm: #~/0 host
infernode/9vm: #~/1 ns
infernode/9vm: #~/0 host: 9P2000 msize 32768
infernode/9vm: #~/1 ns: 9P2000 msize 32768
infernode/9vm: #~/0 host: sub/hello.txt 15 bytes, content ok
infernode/9vm: #~/1 ns: walked . while #~/0 host had 8 reads in flight
infernode/9vm: #~/1 ns: 8 concurrent reads of 100 bytes, replies out of order
infernode/9vm: #~/0 host: 8 concurrent reads of 32744 bytes, 300000 bytes verified
infernode/9vm: ring test passed
```

## What this is not

This is the transport, not the namespace. There is no fid table, no mount,
no `#~` device, and no fallback to virtio-9p — the ring is the 9vm host
transport, and a boot without it has no host filesystem at all. The `#~`
device (with `#~/0`, `#~/1` and their `host`/`ns` aliases) and `devmnt`
arrive with `os/port`; then `selftest.c` goes away and `p9.c` is only the
message carrier beneath `#~`.

The shared-memory display (`vmdisplay`) is a later board driver.

## Next

- `os/port` beneath this entry, and `#~` as a device: `#~/0`/`#~/1` (and
  `host`/`ns`) as stream files for `devmnt`.
- The shared display.
- `os/ip`, the Dis VM and the amd64 JIT.

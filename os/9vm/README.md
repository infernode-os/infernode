# os/9vm — the 9vm board

[9vm](https://github.com/kiljoy001/9vm) is a small KVM microVM runner for
native Harvey, Purgatorio/Inferno and GEFS guests. What it offers a guest
beyond a console is the **`#~` host ring** — a shared-memory 9P2000
transport in the top 2 MiB of guest physical RAM, served by a host thread
on another core — and a **shared display**. This directory is the guest
side of both for `os/amd64`.

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

## The shared display

With `-display-shm NAME` 9vm creates a POSIX shared memory object, maps it
into the guest at physical `0xF8000000`, and lets a viewer on the host
attach to the same name. `boot.S` maps that window (32 2 MiB pages from
`0xF8000000`, clear of the LAPIC, the IOAPIC and the virtio windows), so
the guest addresses it directly.

The region is the host's `struct vmdisplay`: two 1024x768 XRGB32
framebuffer slots, a state/serial handshake, and a ring of 256 text input
records of 96 bytes.

- **Frames.** The guest draws into a slot, sets `written`, `slot_serial`
  and `latest_serial`, and marks the slot `READY`. A viewer claims it from
  `READY` to `READING`, copies it, and marks it `FREE`. Two slots mean a
  viewer always has a complete frame to copy, even while the guest draws
  the next one.
- **Input.** A viewer writes a record (`key 113 0
`, `down 12 34
`, …)
  into `input[head % 256]` and advances `input_head`; the guest reads at
  `input_tail` and advances it.
- **Presence.** The magic `0x56444c39` and version 1. A boot without
  `-display-shm` has no region; the driver says `display: not offered`
  and the test fails rather than faulting.

`display.c` is the boot test: it clears the slots, draws two
deterministic frames — red ramps with x, green with y, blue is x^y, and
frame two carries a magenta block so the slots differ — publishes them,
and waits (bounded) for one input record. It reads the record and prints
it.

`tests/host/vmdisplay_check.c` is the other half: started before 9vm, it
waits for the shared memory to appear and for serial 2, verifies every
pixel of both slots against the same function, checks the header and the
scale, and then sends `key 113 0` — the input that lets the guest finish.
A wrong frame exits non-zero with the offending pixel.

## What is here

| file | |
|-|-|
| `board.h` | the guest's copy of the ABI, the channel array and client types |
| `ring.c` | attach, validate, slot allocation, submit, completion |
| `p9.c` | 9P2000: version, attach, walk, open, read, clunk |
| `selftest.c` | the ring boot test, when the command line asks |
| `display.h` | the host's `struct vmdisplay`, and where it is mapped |
| `display.c` | the display boot test: two frames, one input record |
| `dev9vm.c` | `#~/host` and `#~/ns`: the rings as 9P streams |

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
9P server (`tests/host/ns9p_stub.c`) to exercise the relay. A third boot
adds `-display-shm` and the command line `disptest`, and runs
`tests/host/vmdisplay_check.c` alongside it. A fourth boots under QEMU,
which has no ring and no display: the kernel must still report its map and
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

and, on the display boot:

```
infernode/9vm: display 1024x768 XRGB32 at 0x00000000f8000000
infernode/9vm: display: 2 frames, serial 2
infernode/9vm: display: waiting for input
infernode/9vm: display input: key 113 0
infernode/9vm: display test passed
vmdisplay: 2 frames verified, input sent
```

## The #~ device

`dev9vm.c` exposes the rings as device files: `#~/host` and `#~/ns` are
byte streams carrying complete 9P2000 messages. A write submits one
T-message to that channel's ring; a read returns one R-message in the
order the host completes them, buffering a reply that does not fit in
one read so a client that reads the size and then the body works
unmodified. The device holds no fid table and speaks no 9P itself: that
is `devmnt`'s job, and the point is that the connection it mounts is the
ring.

`os/9vm/p9.c` and `selftest.c` keep their own small client for the boot
tests; their qid type is now `P9Qid`, because the kernel's `Qid` lives
in the same translation unit as the device.

## Mounting it

`devmnt` mounts the stream: the kernel's root device supplies a
namespace, `kmount` hands `#~/host` to the 9P client, and a path under
the mount point is served by 9vm's hostfs through the ring. The mount
test reads `/n/sub/hello.txt` that way, with no socket and no virtio.

The `display` is still a test transport rather than a console, and there
is no fallback to virtio-9p — the ring is the 9vm host transport, and a
boot without it has no host filesystem at all.

The display is a transport, not a console: there is no font, no terminal
and no input translation. A real framebuffer console (`os/fb`) comes with
`os/port`.

## Next

- `devmnt` and a mount point, so `#~/host` becomes a mounted filesystem.
- `#~/0`/`#~/1` aliases once there is more than one host filesystem.
- A framebuffer console and cursor over the display slots.
- `os/ip`, the Dis VM and the amd64 JIT.

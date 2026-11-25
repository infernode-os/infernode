# os/amd64 — x86-64 native InferNode

The first stage of the native x86-64 port: a Multiboot kernel that
identity-maps the first GiB with 2 MiB pages, enters long mode,
initializes a 16550 console, and prints the Multiboot memory map.

## The entry

A Multiboot loader enters an ELF64 image in 32-bit protected mode with
`eax = 0x2BADB002` and `ebx` pointing at the Multiboot information. The
stub in `boot.S` identity-maps the first GiB, sets PAE and LME, enables
paging, loads the 64-bit GDT, and jumps to the C entry. The ELF class is
64-bit throughout; only the bytes at `_start` are 32-bit machine code.

The stub's page tables, GDT and saved Multiboot pointer live in the
kernel image's own `.bss`, not at fixed low addresses: a Multiboot loader
may put the information block, memory map or command line anywhere below
1 MiB, and fixed scratch pages could destroy them. The image is linked at
1 MiB, so those symbols are physical addresses while paging is off; the
stub zeroes the block first and addresses it through 32-bit immediates.

Immediates are safe but memory operands with a symbol are not: a 64-bit
assembler emits PC-relative references even under `.code32`, and in
32-bit execution those displacements are absolute, so `lgdt symbol`
would load from the wrong address. That one instruction is encoded by
hand.

## Boot loaders

The kernel is generic: it needs a Multiboot 1 loader, not a particular
one. The harness boots it under every loader it finds.

[qemu-system-x86_64](https://www.qemu.org/) loads the flat image
(`kernel.bin`, made with `objcopy -O binary`) through its Multiboot
option ROM. QEMU refuses an ELF64 image ("give a 32bit one") unless the
header carries the a.out kludge addresses, so `boot.S` sets
`MULTIBOOT_HEADER_HAS_ADDR` and gives the load, bss and entry addresses
explicitly. QEMU then copies the flat image to 1 MiB and enters it; the
ELF is for loaders that parse ELF64.

[9vm](https://github.com/kiljoy001/9vm) is a small KVM microVM runner for
native Harvey, Purgatorio/Inferno and GEFS guests. It loads the ELF64
image, enters it in 32-bit protected mode with a Multiboot information
structure, and emulates a 16550 console at 0x3F8. It is one Multiboot
loader, not a dependency of the kernel. It also publishes the `#~`
shared-memory 9P host ring, which `../9vm` drives; a boot under another
loader has no host filesystem.

## Build and boot

```sh
./tests/host/amd64_boot_test.sh
```

Set `NINEVM` (default `$ROOT/../9vm/9vm`) or `QEMU` to override the
loaders; set either to the empty string to skip it. `BAREMETAL_BUILD_DIR`
keeps the object, ELF and flat files. The harness skips with status 77
when `clang` or `ld.lld` is absent, or when neither loader is available.

```
-- 9vm
infernode/amd64: booting (Multiboot)
...
infernode/9vm: #~/0 host: 8 concurrent reads of 32744 bytes, 300000 bytes verified
infernode/9vm: ring test passed
infernode/amd64: halted
-- ns
...
infernode/9vm: #~/1 ns: 8 concurrent reads of 100 bytes, replies out of order
...
-- qemu
infernode/amd64: booting (Multiboot)
...
infernode/amd64: no #~ host ring in the map
infernode/amd64: halted
PASS: x86-64 boot (9vm ns qemu)
```

## Layout

| file | |
|-|-|
| `boot.S` | the 32-bit stub: page tables, long mode, GDT, stack |
| `main.c` | console, Multiboot parse, memory map, the `#~` handoff, halt |
| `mem.c` | memcpy/memmove/memset/memcmp/strlen, for a freestanding kernel |
| `kernel.ld` | links at 1 MiB; `.multiboot` and `.text.boot` first |

## Next

- `os/port` and the device layer beneath this entry, so `../9vm`'s rings
  become the mountable `#~/0`/`#~/1` (`host`/`ns`) instead of a boot test.
- The shared display.
- `os/ip`, the Dis VM and the amd64 JIT.

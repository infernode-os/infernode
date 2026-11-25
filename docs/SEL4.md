# InferNode on seL4

Status: plan, adopted 2026-11-25. Work in progress; nothing here ships yet.

The native kernel gets seL4 underneath it. seL4 is a microkernel whose C is
machine-checked against a specification in Isabelle/HOL, with proofs of
integrity and confidentiality between the components it separates. We keep
the Inferno kernel layer, the IP stack, the drivers, the Dis VM and all of the
Limbo above it, and move them into seL4 components. Rust replaces C around
seL4 one component at a time, with proofs where they pay. Limbo stays as it is.

The C native kernel (`os/`, [BAREMETAL.md](BAREMETAL.md)) keeps shipping until
the seL4 target reaches parity. The hosted emulator is unaffected.

## Why

The product is meant for defence and critical infrastructure. What those
buyers accredit against is evidence: an evaluation (Common Criteria/NIAP,
DO-178C, IEC 62443) and, for CNSA, FIPS 140-3. seL4's proofs are the strongest
evidence available that a kernel keeps components apart. Memory-safe code
(Rust, Dis) inside each component means the contents cannot break the walls
by corrupting memory.

## What seL4 replaces

Code lines, comments and blank lines not counted, native ARM kernel:

| Part | Lines | Under seL4 |
|---|---|---|
| Traps, vectors, GIC, timer, context switch, MMU (`os/arm64` less `main.c`), scheduler, locks, page allocator, clocks (`os/port`), board MMU/interrupt/timer code | ~4.3K | Replaced |
| Boot and self-tests (`os/arm64/main.c`) | 1.2K | Rewritten or dropped |
| Inferno kernel layer (`os/port` less drivers and mechanism) | ~20K | Kept, in a component |
| IP stack (`os/ip`) | 12.5K | Kept |
| Drivers in C (`os/port`, `os/bcm*`, `os/virt*`, `os/fb`) | ~30K | Kept; register, interrupt and DMA glue adapted |
| Limbo drivers and init (`os/init`) | 10.3K | Unchanged |
| Shared with emu: Dis VM 51K, Tk 25K, crypto 16.7K, draw 12.9K, math 6.2K, lib9 4.6K | ~116K | Unchanged |

New code: a platform layer (threads, sleep and wakeup on notifications, locks,
timer, interrupts, memory and DMA from capabilities, boot), 9P over shared
memory between components, and the system description. About 3 to 6K lines.
The port is, in effect, a third host for emu (whose Linux layer is 2.0K
lines) with the native kernel's devices, drivers and IP stack.

## What is verified, and what is not

A verified configuration is one exact kernel build: an architecture, a set of
build options and a platform. The AArch64 ones (seL4
`configs/include/AARCH64_verified_include.cmake`) fix:

- `KernelMaxNumNodes 1`: **one core**;
- `KernelArmHypervisorSupport ON`: the kernel at EL2;
- `KernelArmSMMU OFF`: **no IOMMU**;
- `KernelFastpath ON`, `KernelPrinting OFF`, `-O2`.

The AArch64 platforms on the verified list include the **Raspberry Pi 4B**
(`AARCH64_bcm2711_verified.cmake`) and **Raspberry Pi 5B**
(`AARCH64_bcm2712_verified.cmake`). RISC-V 64's include the **PolarFire Icicle
Kit**. Jetson Orin is not upstream. The real-time (MCS) proofs are in
progress.

No configuration covers boot, the IOMMU, or the debug and print interfaces.
Confidentiality is about flow through stored state, not timing. Before
claiming "verified on Pi 5" in anything sold, confirm with the seL4
Foundation that the proofs are run against that platform's build.

A Dis VM is single-core already: each native VM has its own heap, collector
and module table, and VMs talk through files ([vm(3)](../man/3/vm)). The
verified build therefore runs one VM. More cores mean either seL4's multicore
kernel, which is not verified, or one seL4 instance per core with 9P over
shared memory between them, which is not verified yet either.

## Architecture

Two capability systems meet here, and each has one job.

- **seL4 capabilities draw the boundaries between components.** Coarse, fixed
  in the system description, proved.
- **Namespaces carry authority within a component** and across it.
  Fine-grained and dynamic, as now ([DESIGN-PRINCIPLES.md](DESIGN-PRINCIPLES.md)).
- **A 9P mount between components is where they meet**: a channel capability
  to seL4, a mount to Inferno.

Nothing is enforced twice. A component that needs to be kept apart from
another (the key store, the network, each agent, the user's data) is a
component of its own; separation in the assured build does not rest on Dis
type safety or a shared namespace.

## Order of work

1. **seL4 with the existing C.** `os/sel4`: the Inferno kernel layer, IP
   stack, drivers and VM 0 in one component, on QEMU `virt`, then the Pi 4
   and Pi 5. Done when it boots to `sh` and passes the checks `os/virt`
   passes.
2. **Rust around it, by priority, proved where it pays.**
   1. The doors every component uses: the 9P decoder (the pilot, below), the
      shared-memory 9P transport, the platform layer.
   2. Components split out for isolation: key store, network, each agent.
   3. The rest of the kernel layer, drivers and IP stack, as each comes up,
      held to the C tree's behaviour.
   4. The Dis VM, last, against a formal semantics of Dis written first.
   Large, fuzzed, contained C (Tk, draw) can stay C until there is a reason.
3. **Limbo unchanged.** One exception: the part of factotum and secstore
   that holds keys becomes a small proved component, which the Limbo side
   reaches over 9P as it reaches factotum now.

`infernode-os/infernode-rust` holds the Rust. The C tree stays the reference:
every Rust component matches what a Dis program can see of the C.

## Assurance method

**The policy** is CIA applied to InferNode: for each asset (keys, the user's
files, an agent's grants and budget, the audit log, the device) and each
attacker (the network, a web page, a compromised agent, a USB device or radio
peer, a hostile file), the attacker cannot learn, change or block the asset.
It is written as plain clauses beside their formal form, and the owner
approves it.

**Assume every unproved component is compromised.** Most clauses then reduce
to reachability: the attacker's component has no capability, and no name,
that reaches the asset. That is checked by machine against the system
description; seL4's proofs say the walls hold.

**The doors are specified**: the components that legitimately cross a
boundary. Specifications come from sources independent of the code (man
pages, RFCs, FIPS, the C tree as an executable oracle), are attacked before
anything is proved against them (code mutation, spec mutation, reachability
checks, replay of this tree's bug history, independent derivation, an
adversarial model), and change only with the owner's approval.

**The gate** (CI) for a proved component:

- the proof passes under pinned checkers, every run, never from a cache;
- no escape hatch: `sorry`/`axiom` (Isabelle, Lean), `assume`,
  `external_body` (Verus), over-strong `kani::assume`, except a listed few,
  each with its reason;
- every proof has a reachability check, so it cannot pass by proving nothing.

**Assumptions are written down**, so they can be reviewed and attacked:
hardware as documented, DMA-capable drivers trusted, boot correct, timing
channels out of scope, a person may be tricked into approving.

## Keeping the design InferNode's

A specification forbids bad behaviour, not complexity. Twenty verified
wrappers meet a spec as well as one file server. So the gate also holds:

- **Policy is stated only as namespace and capability reachability.** A
  clause that needs a runtime permission check or a central manager is a
  design discussion, not an addition.
- **A budget for the trusted base**, in code lines, per proved component and
  in total. Growth past it needs the owner's approval.
- **Proof size is reported.** A change needing much more proof than the code
  it adds is probably fighting the architecture.
- **The smells** of [DESIGN-PRINCIPLES.md](DESIGN-PRINCIPLES.md) are checks
  where they can be detected, and a review pass where they cannot.
- **New mechanisms start as a namespace sketch** the owner approves.
- **Subtraction counts.** Each component should leave the system smaller.

## The pilot: the 9P decoder

The workflow is tried first where the specification is well posed: decoding
9P messages, in `infernode-rust`. The specification comes from `intro(5)`
(`man/5/0intro`) and the message pages alone. Its red-team corpus is this tree's 9P history (msize
under 256 agreed to, stat sizes that wrap, Twstat of 256 bytes or more, fids
and offsets past 2^31, NUL in strings, counts past the message). The theorem:
for every byte sequence, the decoder rejects it or returns a message that
re-encodes to exactly those bytes; it never panics or reads out of bounds,
and rejects all the man pages forbid. Measured: model tokens and attempts,
time to check, spec defects found, and how much of the spec the owner
corrected. The key store follows, where the specification has to be designed
rather than transcribed.

# Device letters

A kernel device is named by one character after `#`: `#c` is the
console, `#I` the IP stack. The character is the first member of the
device's `Dev` table, and a kernel finds a device by it alone, so two
devices with one letter in one build leave one of them unreachable.
That happened: the camera (#1005) took `#V` on master while the Dis
VMs had it on their branch (#944), and nothing noticed until the merge.

This is the registry: every letter, what it is here, and what it is in
the three systems this one descends from or sits beside -- Plan 9 (4th
edition), 9front and Inferno -- read from their sources (every
`dev*.c` `Dev` table in [plan9foundation/plan9](https://github.com/plan9foundation/plan9),
[9front/9front](https://github.com/9front/9front) and
[inferno-os/inferno-os](https://github.com/inferno-os/inferno-os), October 2026).

## The rule

- **One letter, one device**, in every build: each native kernel's
  `os/*/devtab.c` and each emulator's `emu/*/emu*` configuration.
- **Precedent first.** A new device takes the letter Plan 9, 9front or
  Inferno gave the same kind of device. Where they have none, a letter
  free in all three; where the ASCII ones run out, Greek, as 9front's
  newer devices do (`#Δ` dtracy, `#λ` loopback, `#σ` shr).
- **The letter comes with the device**: a PR that adds a device adds its
  row here, and `tools/devletters.py --check` (run by
  `tests/host/devletters_test.sh` in CI) fails a build that puts one
  letter on two devices, or uses a letter this table does not give that
  device.
- **Differences are written down**, here, with what is to become of them.
  Where this tree differs from its precedents and nothing outside
  depends on the difference -- the bare-metal kernels have no users to
  break yet -- it moves to the precedent. The hosted emulator's letters
  are in programs and scripts people run, so its moves are made one at a
  time, each its own change.

## Planned moves

| From | To | Why |
|---|---|---|
| `#V` Dis VMs (branch) | `#X` (#1038) | the camera has `#V`; `#X` is 9front's vmx, its virtual machines |
| `#b` bench (native) | `#x` (#1039) | Inferno's bench; `#b` is Inferno's dbg |
| `#P` prof (hosted) | `#K` (#1037) | kprof in all three; then `#P` is arch everywhere |
| `#w` wmsz (hosted) | `#z` (#1040) | `#w` is the watchdog in Plan 9 and 9front; `#z` for size, free in all three |
| `#F` 2fa (hosted) | `#h` (#1040) | `#F` is flash in all three; `#h` for a hardware key, free in all three |

Left as they are, written down: `#f` phone (hosted; floppy elsewhere)
and `#Z` opus (hosted; Inferno's test device).

## Reserved

For devices this tree is likely to grow, at their precedents' letters:
`#r` real-time clock, `#J` I2C, `#Q` SPI, `#$` PCI, `#v` display or
video out, `#W` PWM, `#N` CAN; and `#X`, `#x`, `#K`, `#z`, `#h` for the moves above.

## The table

"Here" is what the device tables and build lists in this tree say,
native or hosted; the three columns after are the precedents.
Regenerate the facts with `tools/devletters.py --builds`.

| Letter | Here | Plan 9 | 9front | Inferno | Status | Notes |
|---|---|---|---|---|---|---|
| `A` | audio (hosted/native) | audio | audio | audio | in use |  |
| `B` | boot (native) | bridge | bridge | boot, bridge | in use | as Inferno (bridge in Plan 9 and 9front) |
| `C` | cmd (hosted) | channel element |  | cmd | in use |  |
| `D` | ssl (hosted/native) | ssl |  | ssl | in use |  |
| `E` |  | sdp |  | mpeg | in use |  |
| `F` | tfa (hosted) | flash | flash | flash, tinyfs | move planned | hosted 2fa to #h (#1040): #F is flash in all three |
| `G` | gpio (native) |  | gpio | fpga, gpio | in use |  |
| `H` |  |  |  | ata | in use |  |
| `I` | ip (hosted/native) | ip | ip | ip | in use |  |
| `J` |  |  | i2c | i2c | reserved | I2C, as 9front and Inferno |
| `K` |  | kprof | kprof | kprof | reserved | the hosted profiler, from #P: kprof in all three |
| `L` |  | lpt | lpt | ds1620, lpt | in use |  |
| `M` | mnt (hosted/native) | mnt | mnt | mnt | in use |  |
| `N` |  |  |  |  | reserved | CAN: free in all three |
| `P` | arch (native), prof (hosted) | arch | arch | arch, prof | move planned | arch everywhere: the hosted profiler to #K |
| `Q` |  |  | qspi |  | reserved | SPI: 9front's qspi |
| `S` | sd (native) | sd | sd | sd | in use |  |
| `T` | touch (native) | lm78 |  | cerf, ipaq, lm78, touch | in use | as Inferno (lm78 in Plan 9) |
| `U` | fs (hosted) |  |  | fs, usb | in use | as Inferno |
| `V` | cam (native) | tv | tv | tv | in use | video in, as tv in all three; the Dis VMs, which had it on their branch, moved to #X |
| `W` |  |  |  |  | reserved | PWM: free in all three |
| `X` |  | loopback | vmx | loopback | reserved | the Dis VMs (#944): 9front's vmx is its virtual machines. Plan 9 and Inferno had loopback here, which 9front moved to #λ |
| `Y` |  | cardbus | cardbus | cardbus | in use |  |
| `Z` | opus (hosted) |  |  | test | divergence | Inferno's test device |
| `a` |  | tls | tls | arch | free here | tls in Plan 9 and 9front. emu/Nt/devarch.c says #a, and no build includes it |
| `b` | bench (native) | irq | irq, kbd | dbg | move planned | bench to #x, as Inferno; #b is then Inferno's dbg |
| `c` | cons (hosted/native) | cons | cons | cons | in use |  |
| `d` | dup (hosted) | dup | dup | dup | in use |  |
| `e` | env (hosted/native) | env | env | env | in use |  |
| `f` | phone (hosted) | floppy | floppy | floppy | divergence | floppy elsewhere, which nothing here will need |
| `g` |  | segment | segment |  | in use |  |
| `h` |  |  |  |  | reserved | 2fa, from #F (#1040): a hardware key; free in all three |
| `i` | draw (hosted/native) | draw | draw | draw | in use |  |
| `k` |  | fs | fs | ds | free here | Inferno's ds (man/3/ds, no source here); fs in Plan 9 and 9front |
| `l` | ether (native) | ether | ether | ether | in use |  |
| `m` | pointer (hosted/native) | mouse | mouse | pointer | in use | pointer, as Inferno (mouse in Plan 9 and 9front) |
| `p` | prog (hosted/native) | proc | proc | prog | in use | prog, as Inferno (proc in Plan 9 and 9front) |
| `r` |  | rtc | rtc | pcf8563, rtc | reserved | real-time clock, as all three |
| `s` | srv (hosted/native) | srv | srv | srv | in use |  |
| `t` | eia (hosted), uart (native) | uart | uart | ns16552, uart | in use | serial lines: uart (native) and eia (hosted) serve the same eia(3) files |
| `u` | usb (native) | usb | usb |  | in use | as Plan 9 and 9front (Inferno #U) |
| `v` |  | dss, vga | dss, vga | vga | reserved | display or video out: vga in all three |
| `w` | wmsz (hosted) | watchdog | watchdog |  | move planned | hosted wmsz to #z (#1040): #w is the watchdog in Plan 9 and 9front |
| `x` |  |  | xenstore | bench | reserved | bench, from #b, as Inferno |
| `y` |  | i82365 | i82365 | i82365, pcmcia | in use |  |
| `z` |  |  |  |  | reserved | wmsz, from #w (#1040): size; free in all three |
| `$` |  | pnp | pci, pnp | pci, pnp | reserved | PCI, as all three |
| `%` | mem (hosted) |  |  | mem | in use |  |
| `*` | indir (hosted) |  |  | indir | in use |  |
| `/` | root (hosted/native) | root | root | root | in use |  |
| `^` | snarf (hosted) |  |  | snarf | in use |  |
| `|` | pipe (hosted/native) | pipe | pipe | pipe | in use |  |
| `¤` | cap (hosted) | cap | cap | cap | in use |  |
| `²` |  |  | twsi |  | in use |  |
| `¶` |  |  | swap |  | in use |  |
| `æ` |  | aoe | aoe |  | in use |  |
| `Δ` |  |  | dtracy |  | in use |  |
| `Ι` |  | kbin |  |  | in use |  |
| `Λ` |  | video | video |  | in use |  |
| `Σ` |  |  |  | sign | free here | Inferno's sign (man/3/sign, no source here) |
| `Φ` |  |  | mii |  | in use |  |
| `κ` |  | kbmap |  |  | in use |  |
| `λ` |  |  | loopback |  | in use |  |
| `σ` |  |  | shr |  | in use |  |
| `τ` |  |  |  | tk | in use |  |
| `⁲` |  | twsi |  |  | in use |  |
| `₪` | srv9 (hosted) |  |  | srv9 | in use |  |
| `↓` |  |  |  | power | in use |  |
| `☹` |  | bios |  |  | in use |  |

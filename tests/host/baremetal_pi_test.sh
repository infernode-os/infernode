#!/bin/bash
#
# tests/host/baremetal_pi_test.sh
#
# Build and boot the bare-metal BCM2837 (Raspberry Pi 3B+) kernel under
# QEMU's raspi3b machine model, and assert on what it reports over the
# PL011 console.
#
# This covers the parts of early bring-up that otherwise fail as a silent
# hang: dropping EL2->EL1, installing VBAR_EL1, and the exception
# save/dispatch/restore round trip. It also injects a deliberate fault to
# prove the panic path still reports rather than wedging.
#
# Deliberately does NOT source common.sh: that resolves $EMU and the Limbo
# toolchain, and this test needs neither -- it exercises a cross-built
# AArch64 kernel, not anything running inside emu.
#
# Skips cleanly when the cross toolchain or QEMU is absent, so it is safe
# to run anywhere.
#
# Run from project root: ./tests/host/baremetal_pi_test.sh [-v]
#

ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SRC="$ROOT/os/bcm2837"
VERBOSE=0

while getopts "v" opt; do
    case $opt in
        v) VERBOSE=1 ;;
        *) echo "Usage: $0 [-v]"; exit 1 ;;
    esac
done

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
    BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BOLD=''; NC=''
fi

PASSED=0; FAILED=0; SKIPPED=0

pass()  { echo -e "${GREEN}PASS${NC}: $1"; PASSED=$((PASSED+1)); return 0; }
fail()  { echo -e "${RED}FAIL${NC}: $1"; FAILED=$((FAILED+1)); return 0; }
skip()  { echo -e "${YELLOW}SKIP${NC}: $1"; SKIPPED=$((SKIPPED+1)); return 0; }
info()  { [[ "$VERBOSE" -eq 1 ]] && echo "  $1" || true; return 0; }

echo -e "${BOLD}Bare-metal BCM2837 (Raspberry Pi 3B+) boot tests${NC}"
echo ""

#
# Toolchain discovery.
#
# There is no committed mkfile for this tree yet, on purpose: the only
# ELF-capable linker on a typical macOS dev box is the ld.lld bundled
# inside the rustup toolchain, and hardcoding that path into build rules
# would be wrong. So search the plausible locations instead of assuming.
#
find_lld() {
    local c
    for c in \
        "$(command -v ld.lld 2>/dev/null)" \
        "$HOME"/.rustup/toolchains/*/lib/rustlib/*/bin/gcc-ld/ld.lld \
        /opt/homebrew/opt/lld/bin/ld.lld \
        /usr/local/opt/lld/bin/ld.lld
    do
        [[ -n "$c" && -x "$c" ]] && { echo "$c"; return 0; }
    done
    return 1
}

find_objcopy() {
    local c
    for c in \
        "$(command -v llvm-objcopy 2>/dev/null)" \
        "$(command -v aarch64-elf-objcopy 2>/dev/null)" \
        /opt/homebrew/opt/llvm/bin/llvm-objcopy \
        /usr/local/opt/llvm/bin/llvm-objcopy
    do
        [[ -n "$c" && -x "$c" ]] && { echo "$c"; return 0; }
    done
    return 1
}

[[ -d "$SRC" ]] || { echo "ERROR: $SRC not found" >&2; exit 1; }

QEMU="$(command -v qemu-system-aarch64 2>/dev/null)"
CC="$(command -v clang 2>/dev/null)"
LLD="$(find_lld)"
OBJCOPY="$(find_objcopy)"

if [[ -z "$CC" || -z "$LLD" || -z "$OBJCOPY" ]]; then
    skip "AArch64 cross toolchain not available (need clang, ld.lld, llvm-objcopy)"
    echo ""
    echo "Passed: $PASSED  Failed: $FAILED  Skipped: $SKIPPED"
    exit 0
fi
if [[ -z "$QEMU" ]]; then
    skip "qemu-system-aarch64 not installed"
    echo ""
    echo "Passed: $PASSED  Failed: $FAILED  Skipped: $SKIPPED"
    exit 0
fi
if ! "$QEMU" -machine help 2>/dev/null | grep -q '^raspi3b'; then
    skip "this QEMU build has no raspi3b machine model"
    echo ""
    echo "Passed: $PASSED  Failed: $FAILED  Skipped: $SKIPPED"
    exit 0
fi

info "cc:      $CC"
info "ld:      $LLD"
info "objcopy: $OBJCOPY"
info "qemu:    $QEMU"

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

# Inferno/arm64/include supplies u.h -- the same per-objtype type header
# upstream's native ports use, and the one os/port will expect.
# Inferno/arm64/include supplies u.h and lib9.h -- the per-objtype type
# headers upstream's native ports use, and the ones os/port will expect.
# include/ supplies kern.h, the kernel libc declarations libkern implements.
CFLAGS=(--target=aarch64-elf -ffreestanding -nostdlib -mgeneral-regs-only
        -O2 -Wall -Wextra -I"$SRC" -I"$ROOT/os/port" -I"$ROOT/Inferno/arm64/include" -I"$ROOT/libinterp"
        -I"$ROOT/include" -I"$ROOT/libkern")

# Build every source in the port, so a new file is picked up automatically
# rather than silently going untested.
build_kernel() {
    local outimg="$1" mainsrc="$2"
    local objs=() f o

    # NB: object names keep the source extension. A port with both
    # arch.S and arch.c would otherwise produce arch.o twice, and the
    # duplicate would be linked twice rather than diagnosed.
    for f in "$SRC"/*.S "$SRC"/*.c; do
        [[ -e "$f" ]] || continue
        # main.c may be substituted for a fault-injecting variant
        [[ "$(basename "$f")" == "main.c" && -n "$mainsrc" ]] && continue
        o="$BUILD/$(basename "$f").o"
        "$CC" "${CFLAGS[@]}" -c "$f" -o "$o" 2>>"$BUILD/cc.log" || return 1
        objs+=("$o")
    done

    if [[ -n "$mainsrc" ]]; then
        o="$BUILD/main-variant.o"
        "$CC" "${CFLAGS[@]}" -c "$mainsrc" -o "$o" 2>>"$BUILD/cc.log" || return 1
        objs+=("$o")
    fi

    # os/port and libkern: sources imported from upstream Inferno.
    #
    # Warnings are suppressed wholesale EXCEPT the two that mark Plan 9 C
    # dialect, which are escalated to errors. Those are not style nits:
    # an anonymous "Lock;" member declares nothing under clang, so the
    # next field silently lands at offset 0 and every lock operation
    # corrupts it. That is not hypothetical -- it destroyed xalloc's free
    # list and made xalloc return nil for every request. Catching it at
    # build time is the difference between a compile error and memory
    # corruption in an imported file nobody is reading closely.
    # errstr.h is GENERATED from os/port/error.h, exactly as upstream's
    # os/port/portmkfile does it: the sed rewrites each
    # "extern char Efoo[]; /* text */" declaration into
    # 'char Efoo[] = "text";'. Generating rather than committing it
    # keeps error.h the single place an error string is written, so a
    # declaration and its text cannot drift apart.
    sed 's/extern //;s,;.*/\* , = ",;s, \*/,";,' \
        < "$ROOT/os/port/error.h" > "$BUILD/errstr.h" || return 1

    for f in "$ROOT"/os/port/*.c; do
        [[ -e "$f" ]] || continue
        o="$BUILD/osport-$(basename "$f").o"
        "$CC" "${CFLAGS[@]}" -I"$BUILD" -Wno-everything \
             -Werror=missing-declarations -Werror=incompatible-pointer-types \
             -c "$f" -o "$o" 2>>"$BUILD/cc.log" || return 1
        objs+=("$o")
    done

    # libkern: the freestanding libc the kernel must supply itself, since
    # there is no host to borrow one from. Warnings are not escalated here
    # -- these are imported upstream sources being ported, and the port is
    # tracked deliberately rather than by drowning the build in noise.
    for f in "$ROOT"/libkern/*.c; do
        [[ -e "$f" ]] || continue
        o="$BUILD/libkern-$(basename "$f").o"
        "$CC" "${CFLAGS[@]}" -I"$BUILD" -Wno-everything \
             -Werror=missing-declarations -Werror=incompatible-pointer-types \
             -c "$f" -o "$o" 2>>"$BUILD/cc.log" || return 1
        objs+=("$o")
    done

    "$LLD" -T "$SRC/kernel.ld" "${objs[@]}" -o "$BUILD/k.elf" 2>>"$BUILD/cc.log" || return 1
    "$OBJCOPY" -O binary "$BUILD/k.elf" "$outimg" 2>>"$BUILD/cc.log" || return 1
    return 0
}

# Boot an image and capture the serial output. The kernel never exits, so
# it must be killed; partial output is what we want.
boot_kernel() {
    local img="$1" secs="${2:-10}"
    python3 - "$QEMU" "$img" "$secs" <<'PYEOF'
import subprocess, sys
qemu, img, secs = sys.argv[1], sys.argv[2], int(sys.argv[3])
p = subprocess.Popen([qemu, "-M", "raspi3b", "-kernel", img,
                      "-display", "none", "-serial", "stdio"],
                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
try:
    out, _ = p.communicate(timeout=secs)
except subprocess.TimeoutExpired:
    p.kill()
    out, _ = p.communicate()
sys.stdout.write(out.decode(errors="replace"))
PYEOF
}

#
# 1. It builds.
#
if build_kernel "$BUILD/kernel8.img" ""; then
    pass "kernel cross-builds for aarch64-elf"
else
    fail "kernel failed to build"
    [[ "$VERBOSE" -eq 1 ]] && cat "$BUILD/cc.log"
    echo ""
    echo "Passed: $PASSED  Failed: $FAILED  Skipped: $SKIPPED"
    exit 1
fi

#
# 2. The vector table is where VBAR_EL1 requires (2048-byte aligned).
#    Getting this wrong produces exceptions that vanish into nothing.
#
NM="$(command -v llvm-nm 2>/dev/null || echo /opt/homebrew/opt/llvm/bin/llvm-nm)"
if [[ -x "$NM" ]]; then
    vaddr="$("$NM" "$BUILD/k.elf" 2>/dev/null | awk '$3=="vectors"{print $1}')"
    if [[ -n "$vaddr" ]]; then
        if (( 0x$vaddr % 2048 == 0 )); then
            pass "vector table is 2048-byte aligned (0x$vaddr)"
        else
            fail "vector table misaligned at 0x$vaddr -- VBAR_EL1 requires 2048"
        fi
    else
        skip "could not locate 'vectors' symbol"
    fi
else
    skip "llvm-nm not available for alignment check"
fi

#
# 3. It boots and reports.
#
OUT="$(boot_kernel "$BUILD/kernel8.img" 10)"
info "--- serial output ---"
[[ "$VERBOSE" -eq 1 ]] && echo "$OUT"

check() {
    local pattern="$1" what="$2"
    if grep -q "$pattern" <<<"$OUT"; then
        pass "$what"
    else
        fail "$what (no match for: $pattern)"
    fi
}

check "InferNode bare-metal"          "kernel boots and reaches kmain"
check "exception level: EL1"          "drops from EL2 to EL1"
check "midr_el1:        0x00000000410fd0" \
                                      "reports a Cortex-A53 MIDR (BCM2837)"
check "types:           arm64 u.h OK" "arm64 type foundation holds (LP64 + stdarg)"
check "vectors:         installed"    "installs VBAR_EL1"
check "save/restore OK"               "exception save/dispatch/restore round trips"
check "boot OK"                       "completes boot without faulting"

# The mailbox round trip. 0xa02082 is a real Pi 3B board revision, so
# this also confirms we are talking to a plausible BCM2837 and not just
# reading back zeroes.
# Pin the actual revision. "board rev 0x" matched an all-zero readback,
# so a mailbox that returned nothing would have passed -- the very thing
# the check claimed to rule out. 0xa02082 is a real Pi 3B revision word.
check "board rev 0x0000000000a02082"  "mailbox returns the true board revision"
check "ARM memory 9[0-9][0-9]MB"      "mailbox reports a plausible ARM memory split"

# MMU. The unaligned check is the one that matters: it is a regression
# guard on the memory ATTRIBUTES, not on translation working. RAM
# accidentally mapped Device would still boot and still show a working
# identity map, then fail unpredictably wherever the compiler merged
# stores.
check "gpio: pin14 func=4 pin15 func=4" "GPIO pin-mux readback matches what UART set"
check "mmu:  on, caches on"           "MMU and caches enabled"
check "unaligned 64-bit access OK"    "RAM is mapped Normal (unaligned access legal)"
# The clock. "clocks AGREE" is the load-bearing one: CNTFRQ_EL0 is a
# value firmware writes rather than something hardware derives, so it can
# be wrong, and a wrong one never presents as a clock bug -- it presents
# as flaky networking or early timeouts. Cross-checking against the
# fixed-rate 1MHz system timer catches it at boot.
# The primitives os/port/taslock.c is written directly against. A _tas
# that does not exclude does not misbehave visibly -- every lock in the
# kernel just stops excluding, and the damage appears somewhere else.
# libkern -- the freestanding libc, imported from upstream. The snprint
# check is the significant one: dofmt is the engine behind print(), which
# os/port uses everywhere, and %lud/%lux must consume 64 bits under LP64.
check "conf: [0-9]* free pages"       "confinit finds the free memory bank"
check "xall: xalloc OK"               "os/port/xalloc allocates distinct zeroed in-bank memory"

check "pool: malloc/free OK"           "os/port/alloc pool allocator works"
check "blok: allocb/freeb OK"          "os/port/allocb Blocks have headroom and correct extents"
check "lbl:  setlabel/gotolabel OK"     "context-switch primitives round trip and restore sp"
check "proc: procinit/newproc OK"       "os/port/proc allocates processes with distinct pids and stacks"
check "qlok: qlock/rwlock OK"           "os/port/qlock blocking locks work uncontended"
check "pgrp: newpgrp OK"                "os/port/pgrp allocates a process group"
check "pool: smprint/strdup OK"       "libkern allocator-dependent entry points work"

check "libk: mem/str OK"              "libkern mem/str primitives work"
check "snprint OK"                    "Plan 9 fmt engine formats correctly under LP64"

check "arch: _tas OK"                 "_tas implements test-and-set"
check "spl OK"                        "spl returns the previous level rather than assuming"

check "clk:  cntfrq [0-9]"            "generic timer reports a frequency"
check "clocks AGREE"                  "generic timer agrees with the 1MHz system timer"
check "clk:  irq firing"              "timer interrupts are delivered"

check "fb:   [0-9]"                   "framebuffer allocated"
check "test pattern drawn"            "framebuffer written without faulting"

#
# 3a. The framebuffer actually contains what was drawn.
#
#     Allocating a framebuffer and writing to it can both "succeed" while
#     nothing reaches the display -- wrong pitch, wrong base, wrong
#     channel order. Pull the real framebuffer back out of QEMU with a
#     QMP screendump and check pixel values against the pattern kmain
#     draws. This is the only check here that would catch a byte-order
#     regression, which is otherwise invisible from the console.
#
python3 - "$QEMU" "$BUILD/kernel8.img" "$BUILD/screen.ppm" <<'PYEOF' > "$BUILD/pixels.txt" 2>&1
import subprocess, socket, time, json, os, sys
qemu, img, ppm = sys.argv[1], sys.argv[2], sys.argv[3]

# A free-ish high port; QMP over TCP because the AF_UNIX path limit
# (~104 chars) is easy to exceed under a temp dir.
PORT = 4477
p = subprocess.Popen([qemu, "-M", "raspi3b", "-kernel", img,
                      "-display", "none", "-serial", "null",
                      "-qmp", f"tcp:127.0.0.1:{PORT},server=on,wait=off"],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    deadline = time.time() + 15
    s = None
    while time.time() < deadline:
        try:
            s = socket.create_connection(("127.0.0.1", PORT), timeout=1); break
        except OSError:
            time.sleep(0.3)
    if s is None:
        print("SKIP no QMP"); sys.exit(0)
    time.sleep(3)                      # let kmain reach the draw
    f = s.makefile("rw")
    f.readline()
    f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush(); f.readline()
    f.write(json.dumps({"execute": "screendump",
                        "arguments": {"filename": ppm}}) + "\n"); f.flush()
    f.readline()
    s.close()
finally:
    p.kill(); p.communicate()

if not os.path.exists(ppm):
    print("SKIP no screendump"); sys.exit(0)

d = open(ppm, "rb").read()
parts = d.split(b"\n", 3)
if parts[0] != b"P6":
    print("SKIP not a P6 ppm"); sys.exit(0)
w, h = map(int, parts[1].split()); px = parts[3]

def pix(x, y):
    o = (y*w + x)*3
    return tuple(px[o:o+3])

# must match the pattern drawn by probefb() in main.c
checks = [
    ("background", (500, 400), (0x10, 0x10, 0x18)),
    ("top bar",    (400, 3),   (0xC0, 0x30, 0x20)),
    ("red rect",   (60, 80),   (0xFF, 0x00, 0x00)),
    ("green rect", (200, 80),  (0x00, 0xFF, 0x00)),
    ("blue rect",  (350, 80),  (0x00, 0x00, 0xFF)),
]
bad = [f"{n} got={pix(*xy)} want={want}" for n, xy, want in checks if pix(*xy) != want]
print("DIMS %dx%d" % (w, h))
print("OK" if not bad else "BAD " + "; ".join(bad))
PYEOF

PIXOUT="$(cat "$BUILD/pixels.txt")"
info "$PIXOUT"
if grep -q '^SKIP' <<<"$PIXOUT"; then
    skip "framebuffer pixel check ($(grep '^SKIP' <<<"$PIXOUT"))"
elif grep -q '^OK' <<<"$PIXOUT"; then
    pass "framebuffer contents match the drawn pattern (correct pitch, base and channel order)"
else
    fail "framebuffer contents wrong: $(grep '^BAD' <<<"$PIXOUT")"
fi

#
# 4. The panic path reports instead of hanging.
#
#    Regression guard for the failure mode this whole layer exists to
#    prevent: a fault that produces silence. Build a variant whose kmain
#    executes an undefined instruction and confirm it decodes and panics.
#
VARIANT="$BUILD/main-fault.c"
cat > "$VARIANT" <<'EOF'
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "ureg.h"
#include "fns.h"

/* main.c normally defines these; the variant replaces main.c */
Conf conf;
Mach mach0;
Mach *m = &mach0;
Proc *up;
Talarm talarm;
void (*kproftick)(ulong);
void (*proctrace)(Proc*, int, vlong);
void (*serwrite)(char*, int);

void confinit(void) { }
void idlehands(void) { __asm__ volatile("wfi"); }
void procsave(Proc *p) { USED(p); }
void kprocchild(Proc *p, void (*f)(void*), void *a) { USED(p); USED(f); USED(a); }

void
kmain(void)
{
	uartinit();
	trapinit();
	uartputstr("\nfault-injection variant\n");
	__asm__ volatile(".word 0x00000000");
	uartputstr("BUG: execution continued past an undefined instruction\n");
	for(;;)
		__asm__ volatile("wfe");
}
EOF

if build_kernel "$BUILD/fault.img" "$VARIANT"; then
    FOUT="$(boot_kernel "$BUILD/fault.img" 10)"
    info "--- fault variant output ---"
    [[ "$VERBOSE" -eq 1 ]] && echo "$FOUT"

    if grep -q "unhandled exception" <<<"$FOUT"; then
        pass "undefined instruction is caught and reported"
    else
        fail "undefined instruction did not produce a fault report"
    fi
    if grep -q "panic:" <<<"$FOUT"; then
        pass "fatal fault panics rather than hanging silently"
    else
        fail "fatal fault did not panic"
    fi
    if grep -q "BUG: execution continued" <<<"$FOUT"; then
        fail "execution continued past an undefined instruction"
    else
        pass "execution did not run past the faulting instruction"
    fi
else
    fail "fault-injection variant failed to build"
    [[ "$VERBOSE" -eq 1 ]] && tail -20 "$BUILD/cc.log"
fi

echo ""
echo -e "${BOLD}Passed: $PASSED  Failed: $FAILED  Skipped: $SKIPPED${NC}"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0

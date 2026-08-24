#!/bin/bash
#
# tests/host/baremetal_test.sh
#
# Build and boot the bare-metal AArch64 kernels under QEMU and assert on
# what they report over the PL011 console.
#
# Two machines, from one shared os/arm64 tree:
#
#   bcm2837  QEMU raspi3b -- the Raspberry Pi 3B+ SoC, the hardware
#            target. Has a VideoCore mailbox, a firmware framebuffer,
#            GPIO and a second fixed-rate clock; has no NIC model.
#   virt     QEMU virt    -- a synthetic machine, the development
#            target. Has a GICv2 and virtio-mmio (net, gpu, input);
#            has no framebuffer and no second clock.
#
# Running both is the point rather than a convenience: the two boards
# share os/port and os/arm64, so a failure on one and not the other
# localises itself. It also stops the shared tree from quietly growing a
# dependency on one machine's peculiarities.
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

echo -e "${BOLD}Bare-metal AArch64 boot tests (bcm2837 + virt)${NC}"
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

QEMU="$(command -v qemu-system-aarch64 2>/dev/null)"
CC="$(command -v clang 2>/dev/null)"
LLD="$(find_lld)"
OBJCOPY="$(find_objcopy)"
AR="$(command -v llvm-ar 2>/dev/null || echo /opt/homebrew/opt/llvm/bin/llvm-ar)"

# The Limbo compiler, for generating runt.h/sysmod.h. Not fatal if
# absent: the files that need them simply will not be in the build.
LIMBO="$(command -v limbo 2>/dev/null)"
[[ -z "$LIMBO" && -x "$ROOT/MacOSX/arm64/bin/limbo" ]] && LIMBO="$ROOT/MacOSX/arm64/bin/limbo"
[[ -z "$LIMBO" && -x /Users/pdfinn/github.com/infernode-os/infernode/MacOSX/arm64/bin/limbo ]] \
    && LIMBO=/Users/pdfinn/github.com/infernode-os/infernode/MacOSX/arm64/bin/limbo

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
for mach in raspi3b virt; do
    if ! "$QEMU" -machine help 2>/dev/null | grep -q "^$mach"; then
        skip "this QEMU build has no $mach machine model"
        echo ""
        echo "Passed: $PASSED  Failed: $FAILED  Skipped: $SKIPPED"
        exit 0
    fi
done

info "cc:      $CC"
info "ld:      $LLD"
info "objcopy: $OBJCOPY"
info "qemu:    $QEMU"

# The build directory is normally a temporary that is removed on exit.
# That is right for a test run and wrong for a debugging session: when the
# kernel faults, the only way to turn the reported PCs back into symbols is
# the ELF that produced them, and it has just been deleted.
#
# BAREMETAL_BUILD_DIR keeps it. Setting it also suppresses the cleanup, so
# the per-image .elf files, the objects and cc.log survive for nm/objdump.
if [ -n "${BAREMETAL_BUILD_DIR:-}" ]; then
	BUILD="$BAREMETAL_BUILD_DIR"
	mkdir -p "$BUILD"
	info "build:   $BUILD (kept: BAREMETAL_BUILD_DIR)"
else
	BUILD="$(mktemp -d)"
	trap 'rm -rf "$BUILD"' EXIT
fi

# Inferno/arm64/include supplies u.h -- the same per-objtype type header
# upstream's native ports use, and the one os/port will expect.
# Inferno/arm64/include supplies u.h and lib9.h -- the per-objtype type
# headers upstream's native ports use, and the ones os/port will expect.
# include/ supplies kern.h, the kernel libc declarations libkern implements.
# libinterp needs FP; the kernel core must not have it.

# Build every source in the port, so a new file is picked up automatically
# rather than silently going untested.
build_kernel() {
    local outimg="$1" mainsrc="$2" extra="$3"
    local objs=() libobjs=() f o

    # Extra defines for this image only. Used to build a JIT-off twin
    # of the same kernel: benchmarking a JIT against a DIFFERENT binary
    # proves nothing, so the ONLY difference must be -DCFLAG=0.
    local CFLAGS=("${CFLAGS[@]}" $extra)
    local IFLAGS=("${IFLAGS[@]}" $extra)


    # runt.h and sysmod.h are GENERATED by the Limbo compiler from
    # module/runt.m, exactly as libinterp's mkfile does it. They are the
    # C view of the Dis module interfaces -- the seam os/port/dis.c,
    # inferno.c and exception.c are written against. Generated rather
    # than committed so the C declarations cannot drift from the Limbo
    # definitions they describe.
    if [[ -n "$LIMBO" && -f "$ROOT/module/runt.m" ]]; then
        "$LIMBO" -a -I"$ROOT/module" "$ROOT/module/runt.m" > "$BUILD/runt.h" 2>>"$BUILD/cc.log" || return 1
        "$LIMBO" -t Sys -I"$ROOT/module" "$ROOT/module/runt.m" > "$BUILD/sysmod.h" 2>>"$BUILD/cc.log" || return 1
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
    # The root filesystem, compiled into the kernel image.
    #
    # A native Inferno kernel has no storage driver at boot, so its root
    # filesystem IS its image. tools/mkrootfs.py stands in for
    # os/port/mkroot: it takes a manifest, compiles each file in as a
    # byte array, and emits the roottab/rootdata pair devroot.c serves
    # them from.
    #
    # The shell needs more than itself. sh.b's initialise() loads
    # Filepat, String, Bufio, Env and Arg and calls badmodule() -- which
    # is fatal -- on any that are missing, so all five have to be in the
    # image before there can be a prompt.
    if [[ -n "$LIMBO" && -f "$ROOT/os/init/osinit.b" ]]; then
        "$LIMBO" -I"$ROOT/module" -o "$BUILD/osinit.dis" \
            "$ROOT/os/init/osinit.b" 2>>"$BUILD/cc.log" || return 1

        rootmanifest=(
            "/osinit.dis=$BUILD/osinit.dis"
            "/dev="
            "/dis/sh.dis=$ROOT/dis/sh.dis"
            "/dis/lib/filepat.dis=$ROOT/dis/lib/filepat.dis"
            "/dis/lib/string.dis=$ROOT/dis/lib/string.dis"
            "/dis/lib/bufio.dis=$ROOT/dis/lib/bufio.dis"
            "/dis/lib/env.dis=$ROOT/dis/lib/env.dis"
            "/dis/lib/arg.dis=$ROOT/dis/lib/arg.dis"

            # A few commands, so the shell has something to run. Each
            # is a Dis module the shell loads by name out of $path, and
            # ls pulls in Readdir and Daytime on top of what sh already
            # needs.
            "/dis/echo.dis=$ROOT/dis/echo.dis"
            "/dis/cat.dis=$ROOT/dis/cat.dis"
            "/dis/pwd.dis=$ROOT/dis/pwd.dis"
            "/dis/ls.dis=$ROOT/dis/ls.dis"
            "/dis/lib/readdir.dis=$ROOT/dis/lib/readdir.dis"
            "/dis/lib/daytime.dis=$ROOT/dis/lib/daytime.dis"
            "/dis/lib/workdir.dis=$ROOT/dis/lib/workdir.dis"

            # sh's loadable builtins. Inferno's shell keeps if/while/for
            # and friends in modules under BUILTINPATH (/dis/sh) rather
            # than in sh.dis itself, so a shell without them can run
            # commands and pipelines but has no control flow at all --
            # "for(i in 1 2 3)" fails looking for ./for.
            "/dis/sh/std.dis=$ROOT/dis/sh/std.dis"
            "/dis/sh/expr.dis=$ROOT/dis/sh/expr.dis"
            "/dis/sh/string.dis=$ROOT/dis/sh/string.dis"
        )
        python3 "$ROOT/tools/mkrootfs.py" "$BUILD/rootfs.c" \
            "${rootmanifest[@]}" 2>>"$BUILD/cc.log" || return 1
        "$CC" "${CFLAGS[@]}" -I"$BUILD" -Wno-everything \
            -c "$BUILD/rootfs.c" -o "$BUILD/rootfs.o" 2>>"$BUILD/cc.log" || return 1
        objs+=("$BUILD/rootfs.o")
    fi

    # errstr.h is GENERATED from os/port/error.h, exactly as upstream's
    # os/port/portmkfile does it: the sed rewrites each
    # "extern char Efoo[]; /* text */" declaration into
    # 'char Efoo[] = "text";'. Generating rather than committing it
    # keeps error.h the single place an error string is written, so a
    # declaration and its text cannot drift apart.
    sed 's/extern //;s,;.*/\* , = ",;s, \*/,";,' \
        < "$ROOT/os/port/error.h" > "$BUILD/errstr.h" || return 1


    # NB: object names keep the source extension. A port with both
    # arch.S and arch.c would otherwise produce arch.o twice, and the
    # duplicate would be linked twice rather than diagnosed.
    # os/arm64 holds everything an AArch64 board shares -- the boot stub,
    # vectors, trap decoding, spl, the Dis-level probes and kmain itself.
    # $SRC holds only what is genuinely machine-specific. Both are globbed
    # so a new file in either is picked up rather than silently untested.
    for f in "$ROOT"/os/arm64/*.S "$ROOT"/os/arm64/*.c "$SRC"/*.S "$SRC"/*.c; do
        [[ -e "$f" ]] || continue
        # main.c may be substituted for a fault-injecting variant
        [[ "$(basename "$f")" == "main.c" && -n "$mainsrc" ]] && continue
        o="$BUILD/$(basename "$f").o"
        "$CC" "${CFLAGS[@]}" -I"$BUILD" -c "$f" -o "$o" 2>>"$BUILD/cc.log" || return 1
        objs+=("$o")
    done

    if [[ -n "$mainsrc" ]]; then
        o="$BUILD/main-variant.o"
        "$CC" "${CFLAGS[@]}" -I"$BUILD" -c "$mainsrc" -o "$o" 2>>"$BUILD/cc.log" || return 1
        objs+=("$o")
    fi

    for f in "$ROOT"/os/port/*.c; do
        [[ -e "$f" ]] || continue
        o="$BUILD/osport-$(basename "$f").o"
        # devprog.c formats Dis values -- reading /prog/N/heap prints a
        # REAL with %g -- so it needs FP, like libinterp and for the
        # same reason. Everything else in os/port keeps
        # -mgeneral-regs-only so no interrupt path can dirty FP state.
        if [[ "$(basename "$f")" == "devprog.c" ]]; then
            "$CC" "${IFLAGS[@]}" -I"$BUILD" -Wno-everything \
                 -Werror=missing-declarations -Werror=incompatible-pointer-types \
                 -c "$f" -o "$o" 2>>"$BUILD/cc.log" || return 1
            objs+=("$o")
            continue
        fi
        "$CC" "${CFLAGS[@]}" -I"$BUILD" -Wno-everything \
             -Werror=missing-declarations -Werror=incompatible-pointer-types \
             -c "$f" -o "$o" 2>>"$BUILD/cc.log" || return 1
        objs+=("$o")
    done

    # libinterp -- the Dis VM.
    #
    # Compiled WITHOUT -mgeneral-regs-only, unlike everything else here.
    # That is not an oversight: Dis has a floating point type, so the
    # interpreter genuinely needs FP/SIMD and will not build without it.
    # The kernel core keeps the restriction so no interrupt path can
    # dirty FP state that is not being saved -- which means procsave()
    # has to start saving it before Dis code actually runs.
    #
    # EXACTLY ONE code generator may be linked. libinterp ships ten
    # comp-*.c files and each defines compile(), preamble() and comvec;
    # they are pulled from an archive, so the linker silently takes the
    # first that resolves the symbol and never reports the other nine.
    #
    # That is not hypothetical. Excluding only comp-amd64.c left
    # comp-386.c and comp-68020.c in the build, and the first time
    # cflag was set above zero the kernel compiled a Dis module with a
    # 68020 code generator and branched into it. It was harmless before
    # only because cflag was 0 and nothing ever called compile().
    #
    # comp-arm64.c IS built: -DINFERNO_NATIVE selects its bare-metal
    # arms, which take executable memory from malloc (this kernel maps
    # all RAM without PXN/UXN) and flush the icache with cacheiflush.
    #
    # Also excluded:
    # the optional modules draw/gpu/crypt/ipint/math, each of which
    # needs its own limbo-generated header. A minimal kernel needs only
    # the sys module.
    for f in "$ROOT"/libinterp/*.c; do
        [[ -e "$f" ]] || continue
        case "$(basename "$f")" in
        comp-arm64.c) ;;			# the one we want
        comp-*.c) continue;;			# every other code generator
        draw.c|gpu.c|crypt.c|ipint.c|math.c) continue;;
        esac
        o="$BUILD/libinterp-$(basename "$f").o"
        "$CC" "${IFLAGS[@]}" -I"$BUILD" -Wno-everything -c "$f" -o "$o" 2>>"$BUILD/cc.log" || return 1
        libobjs+=("$o")
    done

    # charstod and pow10 need hardware FP, so they are built with the
    # libinterp flags rather than the kernel's. libinterp's string and
    # float conversion needs them.
    for f in "$ROOT"/libkernfp/*.c; do
        [[ -e "$f" ]] || continue
        o="$BUILD/libkernfp-$(basename "$f").o"
        "$CC" "${IFLAGS[@]}" -I"$BUILD" -Wno-everything -c "$f" -o "$o" 2>>"$BUILD/cc.log" || return 1
        libobjs+=("$o")
    done

    # libkern is built as an ARCHIVE, not a list of objects.
    #
    # That is not a packaging preference: os/port/devcons.c defines
    # snprint and sprint itself, and libkern defines them too. Linking
    # every libkern object unconditionally makes those duplicate
    # symbols. An archive member is only pulled in if it resolves
    # something still undefined, so devcons.c's definitions win and
    # libkern's are simply never extracted -- which is exactly how
    # upstream's build behaves, since it links libkern.a.
    #
    # Warnings are not escalated here
    # -- these are imported upstream sources being ported, and the port is
    # tracked deliberately rather than by drowning the build in noise.
    for f in "$ROOT"/libkern/*.c; do
        [[ -e "$f" ]] || continue
        o="$BUILD/libkern-$(basename "$f").o"
        "$CC" "${CFLAGS[@]}" -I"$BUILD" -Wno-everything \
             -Werror=missing-declarations -Werror=incompatible-pointer-types \
             -c "$f" -o "$o" 2>>"$BUILD/cc.log" || return 1
        libobjs+=("$o")
    done
    # Delete the archive first. "ar r" REPLACES and ADDS members, but it
    # never removes one, so an object dropped from the build stays in
    # libkern.a forever and keeps satisfying the symbol it defines.
    #
    # That cost real time: libinterp ships ten comp-*.c code generators
    # and each defines compile(). After narrowing the build to
    # comp-arm64.c, the kernel still compiled Dis modules with the
    # 68020 generator, because its object from a previous run was still
    # in the archive and the linker took the first match.
    rm -f "$BUILD/libkern.a"
    "$AR" rcs "$BUILD/libkern.a" "${libobjs[@]}" 2>>"$BUILD/cc.log" || return 1

    # The ELF is named after the image it produces, NOT a shared k.elf.
    #
    # build_kernel runs twice -- once for the real kernel and once for the
    # fault-injection kernel -- so a fixed name means the second link
    # overwrites the first, and the ELF left on disk belongs to whichever
    # ran last. Every symbol then resolves against the wrong binary.
    #
    # That is not a theoretical tidiness point. Debugging a pool
    # corruption, "alloc:D2B (from 85218/a57b8)" resolved into cmount and
    # cvtup, at a nop and an FP load -- addresses that cannot be return
    # addresses at all. getcallerpc was blamed and rewritten before the
    # actual cause turned up: the ELF being read was the fault kernel's,
    # while the addresses came from the real one.
    local kelf="${outimg%.img}.elf"
    "$LLD" -T "$SRC/kernel.ld" "${objs[@]}" "$BUILD/libkern.a" -o "$kelf" 2>>"$BUILD/cc.log" || return 1
    "$OBJCOPY" -O binary "$kelf" "$outimg" 2>>"$BUILD/cc.log" || return 1
    return 0
}

# Boot an image and capture the serial output. The kernel never exits, so
# it must be killed; partial output is what we want.
boot_kernel() {
    local img="$1" secs="${2:-10}"
    python3 - "$QEMU" "$img" "$secs" "$QEMUARGS" <<'PYEOF'
import subprocess, sys
qemu, img, secs, extra = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
p = subprocess.Popen([qemu] + extra.split() + ["-kernel", img,
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

# Boot, wait for the shell prompt, type commands at it, and return
# everything the machine said.
#
# The shell is the point of the whole exercise, and nothing else in this
# file can catch it breaking: every other check reads output the kernel
# produces on its own, and a shell that never reaches a prompt -- or
# reaches one and cannot be typed at -- looks identical to a clean boot
# from the outside.
shell_session() {
    local img="$1"; shift
    python3 - "$QEMU" "$img" "$QEMUARGS" "$@" <<'PYEOF'
import subprocess, sys, time
qemu, img, extra = sys.argv[1], sys.argv[2], sys.argv[3]
cmds = sys.argv[4:]
p = subprocess.Popen([qemu] + extra.split() + ["-kernel", img,
                      "-display", "none", "-serial", "stdio"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL)
try:
    time.sleep(3)                 # boot, then reach the prompt
    for c in cmds:
        p.stdin.write(c.encode() + b"\n")
        p.stdin.flush()
        time.sleep(1.5)
except Exception:
    pass
p.kill()
out, _ = p.communicate()
sys.stdout.write(out.decode(errors="replace"))
PYEOF
}

#
# Everything below runs once per platform.
#
# $PLAT selects the machine-specific half: which os/<plat> directory is
# built, which QEMU machine boots it, and which assertions apply. The
# common checks -- os/port, libkern, the Dis VM -- are asserted
# identically on both, which is what makes a divergence between them
# mean something.
#
# The body is deliberately NOT indented into the function. It contains
# quoted heredocs carrying Python, and indenting those would leave the
# Python indented too -- a syntax error inside a heredoc that bash -n
# cannot see.
#
run_platform() {
PLAT="$1"
SRC="$ROOT/os/$PLAT"
QEMUARGS="$2"

[[ -d "$SRC" ]] || { echo "ERROR: $SRC not found" >&2; exit 1; }

# Rebuilt per platform rather than once at the top: -I"$SRC" is what
# selects which os/<plat> supplies mem.h, io.h and board.h to the shared
# os/arm64 and os/port sources, and $SRC is not known until here.
IFLAGS=(--target=aarch64-elf -ffreestanding -nostdlib -DINFERNO_NATIVE
        -O2 -fno-omit-frame-pointer -I"$SRC" -I"$ROOT/os/arm64" -I"$ROOT/os/port" -I"$ROOT/Inferno/arm64/include"
        -I"$ROOT/include" -I"$ROOT/libkern" -I"$ROOT/libinterp")

CFLAGS=(--target=aarch64-elf -ffreestanding -nostdlib -mgeneral-regs-only
        -O2 -fno-omit-frame-pointer -Wall -Wextra -I"$SRC" -I"$ROOT/os/arm64" -I"$ROOT/os/port" -I"$ROOT/Inferno/arm64/include" -I"$ROOT/libinterp"
        -I"$ROOT/include" -I"$ROOT/libkern")

echo -e "${BOLD}--- $PLAT (qemu $QEMUARGS) ---${NC}"

#
# 1. It builds.
#
if build_kernel "$BUILD/$PLAT-kernel.img" ""; then
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
    vaddr="$("$NM" "$BUILD/$PLAT-kernel.elf" 2>/dev/null | awk '$3=="vectors"{print $1}')"
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
OUT="$(boot_kernel "$BUILD/$PLAT-kernel.img" 10)"
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
check "midr_el1:        0x00000000410fd0" \
                                      "reports a Cortex-A53 MIDR"
    # The Pi firmware enters at EL2 and l.S drops to EL1. virt has no
    # EL2 at all unless -M virt,virtualization=on, so it starts at EL1
    # and the drop path is never exercised there.
    check "exception level: EL1"      "drops from EL2 to EL1"
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
    check "board rev 0x0000000000a02082" "mailbox returns the true board revision"
    check "ARM memory 9[0-9][0-9]MB"     "mailbox reports a plausible ARM memory split"

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
check "lbl:  setlabel/gotolabel OK"     "context switch restores sp AND callee-saved registers"
check "gcpc: getcallerpc OK"            "getcallerpc names the caller from both the macro and the asm"
check "proc: procinit/newproc OK"       "os/port/proc allocates processes with distinct pids and stacks"
check "qlok: qlock/rwlock OK"           "os/port/qlock blocking locks work uncontended"
check "pgrp: newpgrp OK"                "os/port/pgrp allocates a process group"
check "chan: newchan/cname OK"          "os/port/chan allocates channels and composes paths"
check "root: devattach/walk/cclose OK"   "root device attaches, walks to /dev, and closes cleanly"
check "file: kopen/kread/kclose OK"      "os/port/sysfile opens, reads and closes a real path"
check "qio:  qopen/qwrite/qread/qbwrite OK" "os/port/qio queues bytes and Blocks with correct accounting"
check "cons: hello from /dev/cons"       "text written to the PATH /dev/cons reaches the console"
check "cons: /dev/cons OK"               "console device binds into the namespace and is writable"
check "Initial Dis:"                    "disinit loads the Dis module from the in-kernel root filesystem"
check "Dis is running on bare metal"     "Limbo bytecode executes and reaches the console through Sys"
check "init: starting the shell"        "the initial Dis program hands over to /dis/sh.dis"

#
# The shell, driven for real.
#
# Boots, waits for the prompt, and types at it over the serial line. A
# marker string proves the whole chain end to end: kbdputc's line
# discipline, kbdq, /dev/cons, sh's parser, loading a command module out
# of the in-kernel root filesystem, and its output coming back.
#
# Worth the seconds it costs. Everything else in this file reads output
# the kernel produces unprompted, so a shell that never reaches a prompt
# -- or reaches one and ignores the keyboard -- would look exactly like
# a clean boot.
SHOUT="$(shell_session "$BUILD/$PLAT-kernel.img" \
        'path=(/dis .)' \
        'echo shell-is-alive' \
        'ls /dis' \
        'echo piped-through | cat' \
        'q=`{echo one two three}; echo subst-count $#q' \
        'load std' \
        'for(i in a b c){ echo loop-$i }')"
[[ "$VERBOSE" -eq 1 ]] && { echo "  --- shell session ---"; echo "$SHOUT"; }

# The marker appears twice: once as the terminal echo of what was
# typed, and once as the command's output. Only the second is evidence,
# so drop any line that still carries the command word.
if grep -v 'echo ' <<<"$SHOUT" | grep -q 'shell-is-alive'; then
    pass "the shell reads typed input and runs a command from /dis"
else
    fail "the shell did not run a typed command (no 'shell-is-alive')"
fi

if grep -q "/dis/sh.dis" <<<"$SHOUT"; then
    pass "ls lists the in-kernel root filesystem"
else
    fail "ls did not list /dis"
fi

# Pipelines and command substitution both go through #|. Before the pipe
# device was imported, sysfile.c's kpipe() indexed devtab via
# devno('|', 0) -- and a devno miss with user==0 PANICS, so typing a
# backquote at the shell took the kernel down. Worth a check of its own:
# a shell without pipelines is half a shell, and the failure mode was a
# dead machine rather than an error message.
if grep -v 'echo ' <<<"$SHOUT" | grep -q 'piped-through'; then
    pass "pipelines work (echo | cat)"
else
    fail "pipeline produced no output"
fi

if grep -q 'subst-count 3' <<<"$SHOUT"; then
    pass "command substitution works (backquote through a pipe)"
else
    fail "command substitution did not return 3 words"
fi

# Inferno's shell keeps if/while/for in loadable modules under
# BUILTINPATH (/dis/sh), not in sh.dis, so a shell without them runs
# commands and pipelines but has no control flow at all -- "for(...)"
# fails looking for ./for. Counts iterations rather than just checking
# the command did not error.
# Count distinct iterations, not lines: the first one shares a line with
# the prompt. The echoed command carries "loop-$i", which does not match
# [abc], so it cannot inflate the count.
if [[ "$(grep -o 'loop-[abc]' <<<"$SHOUT" | sort -u | wc -l | tr -d ' ')" == "3" ]]; then
    pass "shell control flow works (load std, for loop over three items)"
else
    fail "for loop did not produce three iterations"
fi

#
# The JIT, measured against itself.
#
# Build a second image differing ONLY by -DCFLAG=0 and compare the same
# fixed arithmetic loop. Two things are being checked and they are not
# the same: that compiled code computes the RIGHT ANSWER (the accumulator
# must match the interpreter's bit for bit), and that it is faster.
#
# A JIT that is merely fast is a miscompilation waiting to be found.
JITMS="$(grep -o 'bench: [0-9]* iterations in [0-9]* ms (acc=-*[0-9]*)' <<<"$OUT" | head -1)"
if build_kernel "$BUILD/$PLAT-nojit.img" "" "-DCFLAG=0"; then
    NOJITOUT="$(boot_kernel "$BUILD/$PLAT-nojit.img" 12)"
    NOJITMS="$(grep -o 'bench: [0-9]* iterations in [0-9]* ms (acc=-*[0-9]*)' <<<"$NOJITOUT" | head -1)"
    info "JIT:    $JITMS"
    info "no JIT: $NOJITMS"

    jms="$(sed -n 's/.* in \([0-9]*\) ms.*/\1/p' <<<"$JITMS")"
    nms="$(sed -n 's/.* in \([0-9]*\) ms.*/\1/p' <<<"$NOJITMS")"
    jacc="$(sed -n 's/.*acc=\(-*[0-9]*\).*/\1/p' <<<"$JITMS")"
    nacc="$(sed -n 's/.*acc=\(-*[0-9]*\).*/\1/p' <<<"$NOJITMS")"

    if [[ -n "$jacc" && "$jacc" == "$nacc" ]]; then
        pass "compiled code computes the same result as the interpreter (acc=$jacc)"
    else
        fail "JIT and interpreter disagree: JIT acc=$jacc interpreter acc=$nacc"
    fi

    if [[ -n "$jms" && -n "$nms" && "$jms" -gt 0 && "$nms" -gt "$jms" ]]; then
        pass "compiled Dis is faster than interpreted (${nms}ms -> ${jms}ms, $((nms / jms))x)"
    else
        fail "JIT not faster: interpreter ${nms}ms vs JIT ${jms}ms"
    fi
else
    fail "the JIT-off comparison kernel failed to build"
fi

check "pool: smprint/strdup OK"       "libkern allocator-dependent entry points work"

check "libk: mem/str OK"              "libkern mem/str primitives work"
check "snprint OK"                    "Plan 9 fmt engine formats correctly under LP64"

check "arch: _tas OK"                 "_tas implements test-and-set"
check "spl OK"                        "spl returns the previous level rather than assuming"

check "clk:  cntfrq [0-9]"            "generic timer reports a frequency"
    check "clocks AGREE"              "generic timer agrees with the 1MHz system timer"
check "clk:  irq firing"              "timer interrupts are delivered"

    check "fb:   [0-9]"               "framebuffer allocated"
    check "test pattern drawn"        "framebuffer written without faulting"

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
python3 - "$QEMU" "$BUILD/$PLAT-kernel.img" "$BUILD/$PLAT-screen.ppm" <<'PYEOF' > "$BUILD/$PLAT-pixels.txt" 2>&1
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

PIXOUT="$(cat "$BUILD/$PLAT-pixels.txt")"
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
VARIANT="$BUILD/$PLAT-main-fault.c"
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
struct Active active;
Proc *up;
uintptr dtbptr;		/* l.S stores it; see os/arm64/fns.h */
void (*kproftick)(ulong);
void (*proctrace)(Proc*, int, vlong);
void (*screenputs)(char*, int);

void confinit(void) { }
void idlehands(void) { __asm__ volatile("wfi"); }
void procsave(Proc *p) { USED(p); }
void procrestore(Proc *p) { USED(p); }
void kprocchild(Proc *p, void (*f)(void*), void *a) { USED(p); USED(f); USED(a); }

void
kmain(void)
{
	uartinit();
	trapinit();
	/* panic() goes through devcons, which discards output with no
	 * console queue and no serial hook -- so wire the serial hook. */
	serwrite = uartputs;
	uartputstr("\nfault-injection variant\n");
	__asm__ volatile(".word 0x00000000");
	uartputstr("BUG: execution continued past an undefined instruction\n");
	for(;;)
		__asm__ volatile("wfe");
}
EOF

if build_kernel "$BUILD/$PLAT-fault.img" "$VARIANT"; then
    FOUT="$(boot_kernel "$BUILD/$PLAT-fault.img" 10)"
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
}

#
# The Pi 3B+ SoC. -M raspi3b fixes the CPU, so no -cpu is needed.
#
run_platform bcm2837 "-M raspi3b"

#
# The virt machine.
#
# -cpu cortex-a53 is NOT optional, and is the single most confusing
# thing about this target: -M virt defaults to cortex-a15, a 32-bit
# ARMv7 CPU, even under qemu-system-aarch64. An AArch64 kernel booted
# without it does not fail -- it produces absolutely no output at all,
# because the CPU is decoding the image as ARM32. Picking the same A53
# the Pi has also keeps the MIDR assertion common to both platforms.
#
# -m 1024 matches the Pi 3B+'s 1GB, and is asserted on: it proves the
# device-tree parse read a real number rather than falling back to a
# default that happened to look plausible.
#
# The virtio devices are attached so the transport scan has something to
# find. They are not driven -- there are no drivers yet -- but their
# presence is what makes virt worth having, so the test asserts it.
#


echo ""
echo -e "${BOLD}Passed: $PASSED  Failed: $FAILED  Skipped: $SKIPPED${NC}"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0

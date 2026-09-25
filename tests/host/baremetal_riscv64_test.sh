#!/bin/bash
#
# Bare-metal RISC-V: build the native kernel for a RISC-V board and boot
# it under QEMU with OpenSBI.
#
#     ./tests/host/baremetal_riscv64_test.sh            # every board
#     BAREMETAL_RV_PLATFORMS=riscvvirt ./tests/host/baremetal_riscv64_test.sh
#     BAREMETAL_BUILD_ONLY=1 ...                        # stop after the link
#     BAREMETAL_BUILD_DIR=/tmp/bm ...                   # keep the build (ELFs for nm/objdump)
#     VERBOSE=1 ...                                     # print the boot logs
#
# The RISC-V counterpart of tests/host/baremetal_test.sh, and built the
# same way: os/riscv64 (the architecture) + the board directory +
# os/port + os/ip + the libraries, the board's directory first on the
# include path so its mem.h, io.h and board.h are the ones shared code
# gets, and a root filesystem compiled into the image by
# tools/mkrootfs.py from the same manifest. What differs is the target
# (RV64GC, LP64D, medany), the code generator (comp-riscv64.c), the
# firmware in front of the kernel (OpenSBI, QEMU's -bios default) and
# the machines.
#
# It is a separate script rather than a function in that one because
# that one is AArch64 from its first line -- its toolchain probe, its
# -ffixed-x28, its QEMU and the dozens of board assertions written
# against a Raspberry Pi -- and a new architecture's harness should
# start small and say only what it has seen. Folding the two builds
# into one parameterised build_kernel is the obvious next step once
# this one has settled.
#
# Exit 0 if every check passed (or the toolchain is absent: skipped).
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERBOSE="${VERBOSE:-0}"
PASSED=0
FAILED=0
SKIPPED=0

if test -t 1; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BOLD=''; NC=''
fi

pass()  { echo -e "${GREEN}PASS${NC}: $1"; PASSED=$((PASSED+1)); return 0; }
fail()  { echo -e "${RED}FAIL${NC}: $1"; FAILED=$((FAILED+1)); return 0; }
skip()  { echo -e "${YELLOW}SKIP${NC}: $1"; SKIPPED=$((SKIPPED+1)); return 0; }
info()  { [[ "$VERBOSE" -eq 1 ]] && echo "  $1" || true; return 0; }

finish() {
    echo ""
    echo "Passed: $PASSED  Failed: $FAILED  Skipped: $SKIPPED"
    [[ $FAILED -eq 0 ]]
    exit $?
}

echo -e "${BOLD}Bare-metal RISC-V boot tests${NC}"
echo ""

CC="$(command -v clang 2>/dev/null)"
LLD="$(command -v ld.lld 2>/dev/null)"
OBJCOPY="$(command -v llvm-objcopy 2>/dev/null)"
AR="$(command -v llvm-ar 2>/dev/null)"
QEMU="$(command -v qemu-system-riscv64 2>/dev/null)"
LIMBO="$(command -v limbo 2>/dev/null)"
for d in Linux/amd64 Linux/arm64 Linux/riscv64 MacOSX/arm64; do
    [[ -z "$LIMBO" && -x "$ROOT/$d/bin/limbo" ]] && LIMBO="$ROOT/$d/bin/limbo"
done

if [[ -z "$CC" || -z "$LLD" || -z "$OBJCOPY" || -z "$AR" ]]; then
    skip "RISC-V cross toolchain not available (need clang, ld.lld, llvm-objcopy, llvm-ar)"
    finish
fi
if ! "$CC" -print-targets 2>/dev/null | grep -q riscv64; then
    skip "this clang has no riscv64 target"
    finish
fi
if [[ -z "$LIMBO" ]]; then
    skip "no limbo compiler (build the host first: ./build-linux-amd64.sh headless)"
    finish
fi
if [[ ! -f "$ROOT/dis/sh.dis" ]]; then
    skip "dis/ is not built (see CLAUDE.md, 'Dis Files: A Build Product')"
    finish
fi

info "cc:      $CC"
info "limbo:   $LIMBO"
info "qemu:    ${QEMU:-none}"

if [ -n "${BAREMETAL_BUILD_DIR:-}" ]; then
    BUILD="$BAREMETAL_BUILD_DIR"
    mkdir -p "$BUILD"
else
    BUILD="$(mktemp -d)"
    trap 'rm -rf "$BUILD"' EXIT
fi

ARCH="$ROOT/os/riscv64"

#
# The flags, per platform because -I"$SRC" is what picks the board.
#
# RV64GC with the double-float ABI everywhere, and not just in
# libinterp as on arm64: a RISC-V link refuses to mix float ABIs, and
# unlike AArch64's NEON no RISC-V compiler uses the FP registers for
# integer code, so the core stays out of them without being told.
# -mcmodel=medany because the kernel is linked at 0x80200000, outside
# medlow's +-2GB of zero; -mno-relax because nothing sets gp for the
# linker's gp-relative relaxation to use.
#
platform_flags() {
    local target=(--target=riscv64-unknown-elf -march=rv64gc -mabi=lp64d -mcmodel=medany -mno-relax)
    IFLAGS=("${target[@]}" -ffreestanding -nostdlib -DINFERNO_NATIVE
            -O2 -fno-omit-frame-pointer -I"$SRC" -I"$ARCH" -I"$ROOT/os/fb" -I"$ROOT/os/port" -I"$ROOT/os/ip"
            -I"$ROOT/Inferno/riscv64/include" -I"$ROOT/include" -I"$ROOT/libkern" -I"$ROOT/libinterp")
    CFLAGS=("${target[@]}" -ffreestanding -nostdlib -DINFERNO_NATIVE
            -O2 -fno-omit-frame-pointer -Wall -Wextra
            -Werror=missing-declarations -Werror=incompatible-pointer-types -Werror=implicit-function-declaration
            -I"$SRC" -I"$ARCH" -I"$ROOT/os/fb" -I"$ROOT/os/port" -I"$ROOT/os/ip" -I"$ROOT/Inferno/riscv64/include"
            -I"$ROOT/libinterp" -I"$ROOT/include" -I"$ROOT/libkern")
}

PORTWERR=(-Wno-everything -Werror=missing-declarations -Werror=incompatible-pointer-types -Werror=implicit-function-declaration)

#
# The kernel: tests/host/baremetal_test.sh's build_kernel, which says
# at each step why it is as it is. Kept in the same order so the two
# can be read side by side.
#
build_kernel() {
    local outimg="$1" extra="$2"
    local objs=() libobjs=() f o
    local CFLAGS=("${CFLAGS[@]}" $extra ${EXTRACFLAGS:-})
    local IFLAGS=("${IFLAGS[@]}" $extra ${EXTRACFLAGS:-})

    rm -f "$outimg" "${outimg%.img}.elf"
    : > "$BUILD/cc.log"

    # the C view of the builtin modules, generated as libinterp's mkfile does
    "$LIMBO" -a -I"$ROOT/module" "$ROOT/module/runt.m" > "$BUILD/runt.h" 2>>"$BUILD/cc.log" || return 1
    "$LIMBO" -t Sys -I"$ROOT/module" "$ROOT/module/runt.m" > "$BUILD/sysmod.h" 2>>"$BUILD/cc.log" || return 1
    "$LIMBO" -a -I"$ROOT/module" "$ROOT/module/bench.m" > "$BUILD/bench.h" 2>>"$BUILD/cc.log" || return 1
    "$LIMBO" -t Bench -I"$ROOT/module" "$ROOT/module/bench.m" > "$BUILD/benchmod.h" 2>>"$BUILD/cc.log" || return 1
    "$LIMBO" -t Draw -I"$ROOT/module" "$ROOT/module/runt.m" > "$BUILD/drawmod.h" 2>>"$BUILD/cc.log" || return 1
    "$LIMBO" -t Tk -I"$ROOT/module" "$ROOT/module/runt.m" > "$BUILD/tkmod.h" 2>>"$BUILD/cc.log" || return 1
    "$LIMBO" -t Keyring -I"$ROOT/module" "$ROOT/module/runt.m" > "$BUILD/keyringmod.h" 2>>"$BUILD/cc.log" || return 1
    "$LIMBO" -t IPints -I"$ROOT/module" "$ROOT/module/runt.m" > "$BUILD/ipintsmod.h" 2>>"$BUILD/cc.log" || return 1
    "$LIMBO" -t Math -I"$ROOT/module" "$ROOT/module/runt.m" > "$BUILD/mathmod.h" 2>>"$BUILD/cc.log" || return 1

    # init and the programs it may start, then the root filesystem
    for f in osinit etherusb kbdusb mouseusb diskusb touch drawtest tktest isotest; do
        "$LIMBO" -I"$ROOT/module" -o "$BUILD/$f.dis" "$ROOT/os/init/$f.b" 2>>"$BUILD/cc.log" || return 1
    done
    local rootmanifest=(
        "/osinit.dis=$BUILD/osinit.dis"
        "/dis/etherusb.dis=$BUILD/etherusb.dis"
        "/dis/kbdusb.dis=$BUILD/kbdusb.dis"
        "/dis/mouseusb.dis=$BUILD/mouseusb.dis"
        "/dis/diskusb.dis=$BUILD/diskusb.dis"
        "/dis/touch.dis=$BUILD/touch.dis"
        "/dis/drawtest.dis=$BUILD/drawtest.dis"
        "/dis/tktest.dis=$BUILD/tktest.dis"
        "/dis/isotest.dis=$BUILD/isotest.dis"
        "/dis/dossrv.dis=$ROOT/dis/dossrv.dis"
        "/dev=" "/net=" "/prog=" "/usb=" "/chan=" "/env=" "/icons="
        "/dis/sh.dis=$ROOT/dis/sh.dis"
        "/dis/lib/filepat.dis=$ROOT/dis/lib/filepat.dis"
        "/dis/lib/string.dis=$ROOT/dis/lib/string.dis"
        "/dis/lib/bufio.dis=$ROOT/dis/lib/bufio.dis"
        "/dis/lib/env.dis=$ROOT/dis/lib/env.dis"
        "/dis/lib/arg.dis=$ROOT/dis/lib/arg.dis"
        "/dis/lib/styx.dis=$ROOT/dis/lib/styx.dis"
        "/net/ether0=" "/n=" "/n/dos=" "/n/remote="
        "/n/usb0=" "/n/usb1=" "/n/usb2=" "/n/usb3="
        "/mnt=" "/mnt/wm=" "/mnt/ui=" "/mnt/llm=" "/mnt/msg=" "/tool=" "/mnt/acme=" "/tmp=" "/usr="
        "/dis/echo.dis=$ROOT/dis/echo.dis"
        "/dis/cat.dis=$ROOT/dis/cat.dis"
        "/dis/read.dis=$ROOT/dis/read.dis"
        "/dis/rm.dis=$ROOT/dis/rm.dis"
        "/dis/pwd.dis=$ROOT/dis/pwd.dis"
        "/dis/ls.dis=$ROOT/dis/ls.dis"
        "/dis/lib/readdir.dis=$ROOT/dis/lib/readdir.dis"
        "/dis/lib/daytime.dis=$ROOT/dis/lib/daytime.dis"
        "/dis/lib/workdir.dis=$ROOT/dis/lib/workdir.dis"
        "/dis/sh/std.dis=$ROOT/dis/sh/std.dis"
        "/dis/sh/expr.dis=$ROOT/dis/sh/expr.dis"
        "/dis/sh/string.dis=$ROOT/dis/sh/string.dis"
        "/lib/sh/profile=$ROOT/os/init/profile"
        "/dis/cd.dis=$ROOT/dis/cd.dis"
        "/dis/date.dis=$ROOT/dis/date.dis"
        "/dis/ps.dis=$ROOT/dis/ps.dis"
        "/dis/ns.dis=$ROOT/dis/ns.dis"
        "/dis/bind.dis=$ROOT/dis/bind.dis"
        "/dis/mount.dis=$ROOT/dis/mount.dis"
        "/dis/unmount.dis=$ROOT/dis/unmount.dis"
        "/dis/ftest.dis=$ROOT/dis/ftest.dis"
        "/dis/mkdir.dis=$ROOT/dis/mkdir.dis"
        "/dis/cp.dis=$ROOT/dis/cp.dis"
        "/dis/mv.dis=$ROOT/dis/mv.dis"
        "/dis/wc.dis=$ROOT/dis/wc.dis"
        "/dis/sleep.dis=$ROOT/dis/sleep.dis"
        "/dis/tail.dis=$ROOT/dis/tail.dis"
        "/dis/sort.dis=$ROOT/dis/sort.dis"
        "/dis/grep.dis=$ROOT/dis/grep.dis"
        "/dis/basename.dis=$ROOT/dis/basename.dis"
        "/dis/du.dis=$ROOT/dis/du.dis"
        "/dis/kill.dis=$ROOT/dis/kill.dis"
        "/dis/lib/auth.dis=$ROOT/dis/lib/auth.dis"
        "/dis/lib/factotum.dis=$ROOT/dis/lib/factotum.dis"
        "/dis/lib/names.dis=$ROOT/dis/lib/names.dis"
        "/dis/lib/regex.dis=$ROOT/dis/lib/regex.dis"
        "/dis/lib/styxpersist.dis=$ROOT/dis/lib/styxpersist.dis"
        "/dis/memfs.dis=$ROOT/dis/memfs.dis"
        "/dis/mntgen.dis=$ROOT/dis/mntgen.dis"
        "/dis/lib/styxservers.dis=$ROOT/dis/lib/styxservers.dis"
        "/dis/lib/nametree.dis=$ROOT/dis/lib/nametree.dis"
        "/dis/lib/styxlib.dis=$ROOT/dis/lib/styxlib.dis"
        "/dis/lib/testing.dis=$ROOT/dis/lib/testing.dis"
        "/dis/tests/exception_test.dis=$ROOT/dis/tests/exception_test.dis"
        "/dis/tests/fltfmt_test.dis=$ROOT/dis/tests/fltfmt_test.dis"
        "/dis/tests/jit_fault_test.dis=$ROOT/dis/tests/jit_fault_test.dis"
        "/dis/jittest.dis=$ROOT/dis/jittest.dis"
        "/dis/procstorm.dis=$ROOT/dis/procstorm.dis"
    )
    python3 "$ROOT/tools/mkrootfs.py" "$BUILD/rootfs.c" "${rootmanifest[@]}" 2>>"$BUILD/cc.log" || return 1
    "$CC" "${CFLAGS[@]}" -I"$BUILD" -Wno-everything -c "$BUILD/rootfs.c" -o "$BUILD/rootfs.o" 2>>"$BUILD/cc.log" || return 1
    objs+=("$BUILD/rootfs.o")

    sed 's/extern //;s,;.*/\* , = ",;s, \*/,";,' < "$ROOT/os/port/error.h" > "$BUILD/errstr.h" || return 1

    # the architecture, the framebuffer console and draw screen (os/fb,
    # shared with arm64), the family's shared drivers, the board
    local sharedsrc=()
    if [[ -n "${SHARED:-}" ]]; then
        for f in "$SHARED"/*.S "$SHARED"/*.c; do
            [[ -e "$f" ]] || continue
            case " ${SHAREDSKIP:-} " in *" $(basename "$f") "*) continue;; esac
            sharedsrc+=("$f")
        done
    fi
    for f in "$ARCH"/*.S "$ARCH"/*.c "$ROOT"/os/fb/*.c "${sharedsrc[@]}" "$SRC"/*.S "$SRC"/*.c; do
        [[ -e "$f" ]] || continue
        o="$BUILD/$(basename "$(dirname "$f")")-$(basename "$f").o"
        "$CC" "${CFLAGS[@]}" -I"$BUILD" -c "$f" -o "$o" 2>>"$BUILD/cc.log" || return 1
        objs+=("$o")
    done

    for f in "$ROOT"/os/port/*.c; do
        case " ${PORTSKIP:-} " in *" $(basename "$f") "*) continue;; esac
        o="$BUILD/osport-$(basename "$f").o"
        "$CC" "${IFLAGS[@]}" -I"$BUILD" "${PORTWERR[@]}" -c "$f" -o "$o" 2>>"$BUILD/cc.log" || return 1
        objs+=("$o")
    done

    for f in "$ROOT"/os/ip/*.c; do
        o="$BUILD/osip-$(basename "$f").o"
        "$CC" "${CFLAGS[@]}" -I"$ROOT/os/ip" -I"$BUILD" "${PORTWERR[@]}" -c "$f" -o "$o" 2>>"$BUILD/cc.log" || return 1
        objs+=("$o")
    done

    for f in "$ROOT"/libmemdraw/{arc,cmap,defont,ellipse,fillpoly,icossin,icossin2,line,poly,string,subfont,alloc,cload,draw,load,unload}.c \
             "$ROOT"/libmemlayer/*.c "$ROOT"/libdraw/*.c; do
        case "$(basename "$f")" in test.c|mkfont.c|readcolmap.c) continue;; esac
        [[ -e "$f" ]] || continue
        o="$BUILD/draw-$(basename "$(dirname "$f")")-$(basename "$f").o"
        "$CC" "${IFLAGS[@]}" -I"$ROOT/libmemdraw" -I"$BUILD" -Wno-everything -c "$f" -o "$o" 2>>"$BUILD/cc.log" || return 1
        libobjs+=("$o")
    done

    for f in "$ROOT"/libmath/fdlibm/*.c "$ROOT"/libmath/dtoa.c "$ROOT"/libmath/fdim.c \
             "$ROOT"/libmath/g_fmt.c "$ROOT"/libmath/gfltconv.c "$ROOT"/libmath/blas.c \
             "$ROOT"/libmath/gemm.c "$ROOT"/libmath/FPcontrol-Inferno.c; do
        [[ -e "$f" ]] || continue
        o="$BUILD/libmath-$(basename "$f").o"
        "$CC" "${IFLAGS[@]}" -I"$ROOT/libmath/fdlibm" -I"$BUILD" -Wno-everything -c "$f" -o "$o" 2>>"$BUILD/cc.log" || return 1
        libobjs+=("$o")
    done

    for f in "$ROOT"/libtk/*.c; do
        o="$BUILD/libtk-$(basename "$f").o"
        "$CC" "${IFLAGS[@]}" -I"$ROOT/libmemdraw" -I"$BUILD" -Wno-everything -c "$f" -o "$o" 2>>"$BUILD/cc.log" || return 1
        libobjs+=("$o")
    done

    # the Dis VM, with EXACTLY one code generator: this architecture's
    for f in "$ROOT"/libinterp/*.c; do
        case "$(basename "$f")" in
        comp-riscv64.c) ;;
        comp-*.c) continue;;
        das-*.c) continue;;
        gpu.c|crypt.c) continue;;
        esac
        o="$BUILD/libinterp-$(basename "$f").o"
        "$CC" "${IFLAGS[@]}" -I"$BUILD" -Wno-everything -c "$f" -o "$o" 2>>"$BUILD/cc.log" || return 1
        libobjs+=("$o")
    done
    o="$BUILD/libinterp-das-riscv64.c.o"
    "$CC" "${IFLAGS[@]}" -I"$BUILD" -Wno-everything -c "$ROOT/libinterp/das-riscv64.c" -o "$o" 2>>"$BUILD/cc.log" || return 1
    libobjs+=("$o")

    for f in "$ROOT"/libmp/*.c "$ROOT"/libsec/*.c "$ROOT"/libkeyring/*.c; do
        case "$(basename "$f")" in
        bigtest.c|crttest.c|mtest.c|test.c|egtest.c|hmactest.c|md4test.c|p384ecdhtest.c|rsatest.c|primetest.c) continue;;
        decodepem.c|prng.c) continue;;
        esac
        o="$BUILD/crypto-$(basename "$f").o"
        "$CC" "${CFLAGS[@]}" -I"$ROOT/libmp" -I"$ROOT/libsec" -I"$BUILD" -Wno-everything -c "$f" -o "$o" 2>>"$BUILD/cc.log" || return 1
        libobjs+=("$o")
    done

    for f in "$ROOT"/libkernfp/*.c; do
        o="$BUILD/libkernfp-$(basename "$f").o"
        "$CC" "${IFLAGS[@]}" -I"$BUILD" -Wno-everything -c "$f" -o "$o" 2>>"$BUILD/cc.log" || return 1
        libobjs+=("$o")
    done

    for f in "$ROOT"/libkern/*.c; do
        o="$BUILD/libkern-$(basename "$f").o"
        "$CC" "${CFLAGS[@]}" -I"$BUILD" "${PORTWERR[@]}" -c "$f" -o "$o" 2>>"$BUILD/cc.log" || return 1
        libobjs+=("$o")
    done
    rm -f "$BUILD/libkern.a"
    "$AR" rcs "$BUILD/libkern.a" "${libobjs[@]}" 2>>"$BUILD/cc.log" || return 1

    local kelf="${outimg%.img}.elf"
    "$LLD" -T "$SRC/kernel.ld" "${objs[@]}" "$BUILD/libkern.a" -o "$kelf" 2>>"$BUILD/cc.log" || return 1
    "$OBJCOPY" -O binary "$kelf" "$outimg" 2>>"$BUILD/cc.log" || return 1
    return 0
}

#
# Boot an image, type commands at its shell once it has one, and return
# everything the machine said. The kernel never exits; it is killed at
# the deadline.
#
#     session <image> <seconds> <command>...
#
session() {
    local img="$1" secs="$2"
    shift 2
    python3 - "$QEMU" "$img" "$secs" "$QEMUARGS" "${BIOS:-default}" "$@" <<'PYEOF'
import os, select, subprocess, sys, time
qemu, img, secs, extra, bios = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5]
cmds = sys.argv[6:]
args = [qemu] + extra.split() + ["-bios", bios, "-kernel", img, "-display", "none", "-serial", "stdio", "-monitor", "none"]
p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
out = b""
deadline = time.time() + secs
prompted = False
while time.time() < deadline:
    r, _, _ = select.select([p.stdout], [], [], 0.2)
    if r:
        b = os.read(p.stdout.fileno(), 65536)
        if not b:
            break
        out += b
    if not prompted and cmds and b"\n; " in out[-4096:] or (not prompted and cmds and out.endswith(b"; ")):
        prompted = True
        for c in cmds:
            time.sleep(0.5)
            p.stdin.write((c + "\n").encode())
            p.stdin.flush()
            t = time.time() + 180
            mark = len(out)
            while time.time() < t:
                r, _, _ = select.select([p.stdout], [], [], 0.2)
                if r:
                    b = os.read(p.stdout.fileno(), 65536)
                    if not b:
                        break
                    out += b
                if out[mark:].rstrip().endswith(b";"):
                    break
        deadline = min(deadline, time.time() + 3)
p.kill()
p.wait()
sys.stdout.write(out.replace(b"\0", b"").decode(errors="replace"))
PYEOF
}

want_platform() {
    case " ${BAREMETAL_RV_PLATFORMS:-riscvvirt mpfs} " in *" $1 "*) return 0;; esac
    return 1
}

#
# QEMU's RISC-V virt: OpenSBI, four harts, a gigabyte, and the virtio
# devices the shared drivers (os/virtio) drive. virtio-*-device is the
# MMIO transport; the -pci names land on a bus this kernel does not walk.
#
RVVIRTARGS="-M virt -smp 4 -m 1024 -device virtio-rng-device"

run_riscvvirt() {
    PLAT=riscvvirt
    SRC="$ROOT/os/$PLAT"
    QEMUARGS="$RVVIRTARGS"
    BIOS=default
    PORTSKIP="devaudio.c ethermii.c pci.c usbxhci.c usbxhcipci.c devusb.c usbdwc.c"
    SHARED="$ROOT/os/virtio"
    SHAREDSKIP=""
    platform_flags

    echo -e "${BOLD}--- $PLAT (qemu $QEMUARGS) ---${NC}"

    if build_kernel "$BUILD/$PLAT-kernel.img" ""; then
        pass "riscvvirt: kernel cross-builds for riscv64 (rv64gc, lp64d)"
    else
        fail "riscvvirt: kernel failed to build"
        grep -m 30 'error:\|undefined symbol' "$BUILD/cc.log"
        return
    fi
    [[ -n "${BAREMETAL_BUILD_ONLY:-}" ]] && return

    if [[ -z "$QEMU" ]]; then
        skip "qemu-system-riscv64 not installed: built, not booted"
        return
    fi

    OUT="$(session "$BUILD/$PLAT-kernel.img" 900 'echo hello from riscv64' 'cat /dev/sysname' 'ls /dis/sh' 'ps' \
        '/dis/jittest.dis' '/dis/tests/jit_fault_test.dis' '/dis/tests/exception_test.dis' '/dis/tests/fltfmt_test.dis')"
    printf '%s\n' "$OUT" > "$BUILD/$PLAT-boot.txt"
    [[ "$VERBOSE" -eq 1 ]] && echo "$OUT"

    rcheck() { if grep -qF -- "$2" <<<"$OUT"; then pass "riscvvirt: $1"; else fail "riscvvirt: $1 -- no '$2' in the boot log"; fi; }
    rrefute() { if grep -qF -- "$2" <<<"$OUT"; then fail "riscvvirt: $1 -- '$2' in the boot log"; else pass "riscvvirt: $1"; fi; }

    rcheck "OpenSBI starts the kernel in S-mode" "InferNode bare-metal (QEMU riscv64 virt)"
    rcheck "SBI reports its extensions" "firmware:        SBI v"
    rcheck "the trap path round-trips" "trap: returned, save/restore OK"
    rcheck "the device tree is found" "fdt:  at "
    rcheck "the first process's namespace" "proc: first process up"
    rcheck "/dev/cons works" "cons: /dev/cons OK"
    rcheck "a self-IPI is taken" "intr: self-IPI taken"
    rcheck "boot completes" "boot OK"
    rcheck "control passes to Dis" "dis:  handing control to the Dis VM"
    rcheck "all four harts run" "smp:  4 harts running"
    rcheck "the shell answers" "hello from riscv64"
    rcheck "/dev/sysname reads back" "infernode"
    rcheck "ls lists the shell's builtins" "std.dis"
    rcheck "the JIT's correctness suite passes in the kernel" "=== Results: 182/182 passed ==="
    rcheck "faults in compiled code reach the right handler" "6 passed"
    rrefute "no test fails" "FAIL"
    rrefute "no panic" "panic:"
    rrefute "no unhandled exception" "unhandled exception"
}

#
# A PolarFire SoC: the BeagleV-Fire's and the Icicle Kit's. QEMU's
# microchip-icicle-kit models the MSS -- the E51 and four U54s, the
# PLIC, the MMUARTs, the SD controller, the GEM MACs -- but ships no
# device tree and no firmware but Microchip's HSS: os/mpfs/qemu-icicle.dts
# describes the machine and the distribution's OpenSBI (a generic
# fw_dynamic new enough to boot on it) stands in for the HSS's.
#
OPENSBI=""
for f in /usr/lib/riscv64-linux-gnu/opensbi/generic/fw_dynamic.bin \
         /usr/share/opensbi/lp64/generic/firmware/fw_dynamic.bin; do
    [[ -z "$OPENSBI" && -f "$f" ]] && OPENSBI="$f"
done

run_mpfs() {
    PLAT=mpfs
    SRC="$ROOT/os/$PLAT"
    QEMUARGS="-M microchip-icicle-kit -smp 5 -m 2G -dtb $BUILD/mpfs-icicle.dtb"
    BIOS="$OPENSBI"
    PORTSKIP="devaudio.c ethermii.c pci.c usbxhci.c usbxhcipci.c devusb.c usbdwc.c"
    SHARED="$ROOT/os/virtio"
    SHAREDSKIP="virtio.c blkvirtio.c ethervirtio.c inputvirtio.c"
    platform_flags

    echo -e "${BOLD}--- $PLAT (qemu $QEMUARGS) ---${NC}"

    if build_kernel "$BUILD/$PLAT-kernel.img" ""; then
        pass "mpfs: kernel cross-builds for riscv64 (rv64gc, lp64d)"
    else
        fail "mpfs: kernel failed to build"
        grep -m 30 'error:\|undefined symbol' "$BUILD/cc.log"
        return
    fi
    [[ -n "${BAREMETAL_BUILD_ONLY:-}" ]] && return

    if [[ -z "$QEMU" ]] || ! "$QEMU" -machine help 2>/dev/null | grep -q '^microchip-icicle-kit '; then
        skip "mpfs: no qemu-system-riscv64 with microchip-icicle-kit: built, not booted"
        return
    fi
    if [[ -z "$OPENSBI" ]] || ! command -v dtc >/dev/null; then
        skip "mpfs: need OpenSBI's generic fw_dynamic.bin and dtc to boot the Icicle Kit model"
        return
    fi
    dtc -I dts -O dtb -o "$BUILD/mpfs-icicle.dtb" "$SRC/qemu-icicle.dts" 2>>"$BUILD/cc.log" || {
        fail "mpfs: qemu-icicle.dts does not compile"
        return
    }

    OUT="$(session "$BUILD/$PLAT-kernel.img" 900 'echo hello from polarfire' 'cat /dev/sysname' 'ps' \
        '/dis/jittest.dis' '/dis/tests/jit_fault_test.dis')"
    printf '%s\n' "$OUT" > "$BUILD/$PLAT-boot.txt"
    [[ "$VERBOSE" -eq 1 ]] && echo "$OUT"

    mcheck() { if grep -qF -- "$2" <<<"$OUT"; then pass "mpfs: $1"; else fail "mpfs: $1 -- no '$2' in the boot log"; fi; }
    mrefute() { if grep -qF -- "$2" <<<"$OUT"; then fail "mpfs: $1 -- '$2' in the boot log"; else pass "mpfs: $1"; fi; }

    mcheck "OpenSBI starts the kernel on a U54" "InferNode bare-metal (Microchip PolarFire SoC)"
    mcheck "the board is named by its device tree" "board: Microchip PolarFire-SoC Icicle Kit (QEMU)"
    mcheck "the MMUART is the console" "console:         16550 at 0x20000000"
    mrefute "no hart is the E51 (hart 0)" "(hart 0)"
    mcheck "the 1 MHz timebase comes from the tree" "time: 1000000 Hz timebase"
    mcheck "the trap path round-trips" "trap: returned, save/restore OK"
    mcheck "the U54s' S-mode PLIC contexts take interrupts" "intr: self-IPI taken"
    mcheck "boot completes" "boot OK"
    mcheck "all four U54 harts run, and the E51 is left alone" "smp:  4 harts running"
    mcheck "the shell answers" "hello from polarfire"
    mcheck "the JIT's correctness suite passes" "=== Results: 182/182 passed ==="
    mcheck "faults in compiled code reach the right handler" "6 passed"
    mrefute "no test fails" "FAIL"
    mrefute "no panic" "panic:"
    mrefute "no unhandled exception" "unhandled exception"
}

if want_platform riscvvirt; then
    run_riscvvirt
fi
if want_platform mpfs; then
    run_mpfs
fi

finish

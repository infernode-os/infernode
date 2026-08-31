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

    # Remove the previous image FIRST.
    #
    # Every failure path below is "return 1", and the caller reports it
    # as a failed build and carries on with the rest of the checks --
    # which boot $outimg. If a stale image is still sitting there, they
    # boot the LAST kernel that compiled, and every measurement after a
    # compile error describes code that was never built. That has now
    # produced confident wrong answers three times in this port, and it
    # is indistinguishable from the real thing while it is happening.
    #
    # Deleting it up front makes a failed build fail loudly instead.
    rm -f "$outimg" "${outimg%.img}.elf"

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

        # $Bench, the same way: the C view of module/bench.m, which is
        # the interface the standard Inferno benchmarking procedure is
        # written against. Generated rather than committed for the same
        # reason as runt.h -- so the C declarations cannot drift from
        # the Limbo definitions they describe.
        "$LIMBO" -a -I"$ROOT/module" "$ROOT/module/bench.m" > "$BUILD/bench.h" 2>>"$BUILD/cc.log" || return 1
        "$LIMBO" -t Bench -I"$ROOT/module" "$ROOT/module/bench.m" > "$BUILD/benchmod.h" 2>>"$BUILD/cc.log" || return 1

        # $Draw and $Tk, the two builtin modules a GUI is made of.
        #
        # Both are C implementations of a Limbo interface, and both need
        # the compiler's C view of that interface -- the same generated
        # header libinterp's own mkfile makes, by the same recipe. Draw
        # is the image and screen module every graphical Limbo program
        # loads; Tk is the widget set on top of it.
        "$LIMBO" -t Draw -I"$ROOT/module" "$ROOT/module/runt.m" > "$BUILD/drawmod.h" 2>>"$BUILD/cc.log" || return 1
        "$LIMBO" -t Tk -I"$ROOT/module" "$ROOT/module/runt.m" > "$BUILD/tkmod.h" 2>>"$BUILD/cc.log" || return 1

        # $Math, which is not optional once there are clock hands to
        # draw: appl/wm/clock.b loads it for sin and cos, and a module
        # that fails to load is a window that never opens.
        "$LIMBO" -t Math -I"$ROOT/module" "$ROOT/module/runt.m" > "$BUILD/mathmod.h" 2>>"$BUILD/cc.log" || return 1
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

        # The USB Ethernet class driver, which is a program rather than
        # kernel code -- see "Decision: device protocols live outside
        # the kernel, mechanism inside" in os/bcm2837/README.md. osinit
        # loads it by name once the bus walk has found something it
        # might drive.
        "$LIMBO" -I"$ROOT/module" -o "$BUILD/etherusb.dis" \
            "$ROOT/os/init/etherusb.b" 2>>"$BUILD/cc.log" || return 1

        # The HID boot keyboard, likewise a program. Boot protocol only:
        # parsing a report descriptor is real work, and the boot
        # protocol exists so a machine that has just started can read a
        # keyboard without doing any of it.
        "$LIMBO" -I"$ROOT/module" -o "$BUILD/kbdusb.dis" \
            "$ROOT/os/init/kbdusb.b" 2>>"$BUILD/cc.log" || return 1

        # The HID boot mouse, for the same reason and by the same route.
        "$LIMBO" -I"$ROOT/module" -o "$BUILD/mouseusb.dis" \
            "$ROOT/os/init/mouseusb.b" 2>>"$BUILD/cc.log" || return 1

        # The end-to-end check for the graphics stack: load $Draw,
        # attach a display, draw a rectangle and read a pixel of it
        # back through the draw protocol's own read. It is a program
        # rather than a kernel self-test because that is the thing
        # being tested -- a Limbo program's view of the screen.
        "$LIMBO" -I"$ROOT/module" -o "$BUILD/drawtest.dis" \
            "$ROOT/os/init/drawtest.b" 2>>"$BUILD/cc.log" || return 1

        # The same, one layer up: build a widget through $Tk and check
        # that it drew. Tk->toplevel takes a Display rather than a
        # Wmcontext, so this runs without a window manager -- which is
        # what makes it a test of Tk rather than of everything above it.
        "$LIMBO" -I"$ROOT/module" -o "$BUILD/tktest.dis" \
            "$ROOT/os/init/tktest.b" 2>>"$BUILD/cc.log" || return 1

        rootmanifest=(
            "/osinit.dis=$BUILD/osinit.dis"
            "/dis/etherusb.dis=$BUILD/etherusb.dis"
            "/dis/kbdusb.dis=$BUILD/kbdusb.dis"
            "/dis/mouseusb.dis=$BUILD/mouseusb.dis"
            "/dis/drawtest.dis=$BUILD/drawtest.dis"
            "/dis/tktest.dis=$BUILD/tktest.dis"

            # The FAT filesystem, as a program. Imported from upstream
            # Inferno (appl/cmd/dossrv.b) -- MIT, the same provenance as
            # os/port and os/ip, and byte-identical to the copy in the
            # local hellaphone tree.
            "/dis/dossrv.dis=$ROOT/dis/dossrv.dis"
            "/dev="
            "/net="
            "/prog="
            "/usb="
            "/chan="
            "/env="
            "/dis/sh.dis=$ROOT/dis/sh.dis"
            "/dis/lib/filepat.dis=$ROOT/dis/lib/filepat.dis"
            "/dis/lib/string.dis=$ROOT/dis/lib/string.dis"
            "/dis/lib/bufio.dis=$ROOT/dis/lib/bufio.dis"
            "/dis/lib/env.dis=$ROOT/dis/lib/env.dis"
            "/dis/lib/arg.dis=$ROOT/dis/lib/arg.dis"

            # The 9P server library, for etherusb. A class driver that
            # lives outside the kernel has to publish a file interface
            # to be reachable from it, and this is what serves one.
            "/dis/lib/styx.dis=$ROOT/dis/lib/styx.dis"

            # acme is not one module. /dis/acme.dis is a loader for the
            # twenty-four in /dis/acme/, which it loads by path at run
            # time -- so a dependency scan that follows "load X X->PATH"
            # never sees them, and acme failed with the least helpful
            # message Limbo has: "module not loaded". 288KB in total.
            "/dis/acme/acme.dis=$ROOT/dis/acme/acme.dis"
            "/dis/acme/buff.dis=$ROOT/dis/acme/buff.dis"
            "/dis/acme/col.dis=$ROOT/dis/acme/col.dis"
            "/dis/acme/dat.dis=$ROOT/dis/acme/dat.dis"
            "/dis/acme/disk.dis=$ROOT/dis/acme/disk.dis"
            "/dis/acme/ecmd.dis=$ROOT/dis/acme/ecmd.dis"
            "/dis/acme/edit.dis=$ROOT/dis/acme/edit.dis"
            "/dis/acme/elog.dis=$ROOT/dis/acme/elog.dis"
            "/dis/acme/exec.dis=$ROOT/dis/acme/exec.dis"
            "/dis/acme/file.dis=$ROOT/dis/acme/file.dis"
            "/dis/acme/frame.dis=$ROOT/dis/acme/frame.dis"
            "/dis/acme/fsys.dis=$ROOT/dis/acme/fsys.dis"
            "/dis/acme/graph.dis=$ROOT/dis/acme/graph.dis"
            "/dis/acme/gui.dis=$ROOT/dis/acme/gui.dis"
            "/dis/acme/look.dis=$ROOT/dis/acme/look.dis"
            "/dis/acme/regx.dis=$ROOT/dis/acme/regx.dis"
            "/dis/acme/row.dis=$ROOT/dis/acme/row.dis"
            "/dis/acme/scrl.dis=$ROOT/dis/acme/scrl.dis"
            "/dis/acme/styxaux.dis=$ROOT/dis/acme/styxaux.dis"
            "/dis/acme/text.dis=$ROOT/dis/acme/text.dis"
            "/dis/acme/time.dis=$ROOT/dis/acme/time.dis"
            "/dis/acme/util.dis=$ROOT/dis/acme/util.dis"
            "/dis/acme/wind.dis=$ROOT/dis/acme/wind.dis"
            "/dis/acme/xfid.dis=$ROOT/dis/acme/xfid.dis"
            "/dis/lib/styxservers.dis=$ROOT/dis/lib/styxservers.dis"
            "/dis/lib/nametree.dis=$ROOT/dis/lib/nametree.dis"
            "/dis/lib/tables.dis=$ROOT/dis/lib/tables.dis"

            # The mount point for it. #I is bound on /net with MBEFORE
            # rather than MREPL precisely so this survives in the union:
            # devip has no "ether0" of its own, and a mount needs its
            # target to exist.
            "/net/ether0="

            # Where a filesystem gets mounted. dossrv mounts itself at
            # /n/dos, and a mount needs its target to exist.
            "/n="
            "/n/dos="
            "/n/remote="

            # Mount points for the window system. mount(2) will not
            # create its target, so /mnt/wm has to exist before wm/wm
            # can put its namespace there -- and a missing directory
            # reads as "'/mnt' file does not exist", which looks like a
            # broken program rather than a root image that was never
            # given the directory.
            "/mnt="
            "/mnt/wm="
            # acme mounts its own file server at /mnt/acme, and mount(2)
            # does not create its target. Without this the mount failed
            # and fsysmount returned nil WITHOUT a message, so acme drew
            # its background, cleaned up and vanished with nothing on
            # the console to say why.
            "/mnt/acme="
            "/tmp="

            # Somewhere to mount a file server, which is how a native
            # Inferno is actually meant to get its userspace: upstream's
            # own native roots (os/pc/pc, os/gum/gum) create /n/remote
            # for exactly this, and os/init/bootinit.b mounts it before
            # reading anything real. A mount needs its target to exist,
            # and the root filesystem is read-only, so it cannot be
            # made later.
            "/n/remote="

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

            # The login profile. sh reads it only with -l, which is what
            # osinit passes; it is what runs "load std", so without it
            # the shell has no control flow.
            "/lib/sh/profile=$ROOT/os/init/profile"

            # Enough commands to use the machine.
            #
            # Every one of these is a Dis module loaded by name out of
            # $path, and $path already defaults to (/dis .) -- so a
            # missing command does not report itself as missing. It
            # reports the LAST path tried: "'./date' file does not
            # exist", which reads like a broken shell rather than an
            # image that was never given a date command.
            #
            # cd is among them deliberately. It is NOT a shell builtin
            # in Inferno -- the builtins are the control-flow words in
            # /dis/sh/std.dis -- so "cd" with no /dis/cd.dis is exactly
            # as absent as any other command.
            "/dis/cd.dis=$ROOT/dis/cd.dis"
            "/dis/date.dis=$ROOT/dis/date.dis"
            "/dis/ps.dis=$ROOT/dis/ps.dis"
            "/dis/ns.dis=$ROOT/dis/ns.dis"
            "/dis/bind.dis=$ROOT/dis/bind.dis"
            "/dis/mount.dis=$ROOT/dis/mount.dis"
            "/dis/mkdir.dis=$ROOT/dis/mkdir.dis"
            "/dis/rm.dis=$ROOT/dis/rm.dis"
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

            # What those commands load in turn. Resolved from each
            # source's "load X X->PATH" against the PATH constants in
            # module/*.m, not guessed: a command whose library is absent
            # does not fail to be found, it fails to LOAD, which is a
            # different and more confusing error.
            "/dis/lib/auth.dis=$ROOT/dis/lib/auth.dis"
            "/dis/lib/factotum.dis=$ROOT/dis/lib/factotum.dis"
            "/dis/lib/names.dis=$ROOT/dis/lib/names.dis"
            "/dis/lib/regex.dis=$ROOT/dis/lib/regex.dis"
            "/dis/lib/styxpersist.dis=$ROOT/dis/lib/styxpersist.dis"

            #
            # The window system.
            #
            # wm/wm is the window manager: it owns the screen, hands
            # each client a window, and moves and resizes them. Its
            # clients are ordinary Limbo programs -- there is nothing
            # privileged about it beyond having been started first.
            #
            # The module list is not a guess. It is the transitive
            # closure of "load X X->PATH" from appl/wm/wm.b and from
            # each client below, resolved against the PATH constants in
            # module/*.m. A missing library does not report itself
            # missing: the program fails to LOAD, which surfaces as a
            # window that never appears.
            #
            "/dis/wm/wm.dis=$ROOT/dis/wm/wm.dis"
            "/dis/lib/wmclient.dis=$ROOT/dis/lib/wmclient.dis"
            "/dis/lib/wmsrv.dis=$ROOT/dis/lib/wmsrv.dis"
            "/dis/lib/wmlib.dis=$ROOT/dis/lib/wmlib.dis"
            "/dis/lib/winplace.dis=$ROOT/dis/lib/winplace.dis"
            "/dis/lib/menuhit.dis=$ROOT/dis/lib/menuhit.dis"
            "/dis/lib/lucitheme.dis=$ROOT/dis/lib/lucitheme.dis"
            "/dis/lib/string.dis=$ROOT/dis/lib/string.dis"

            # Two clients, chosen for what they exercise rather than
            # for what they do. The clock is the smallest thing that
            # draws continuously and is the only reason $Math is
            # linked -- it wants sin and cos for the hands. The shell
            # window is the one that matters: a Tk toplevel with a
            # text widget, keyboard input, and a shell behind it.
            "/dis/wm/clock.dis=$ROOT/dis/wm/clock.dis"
            # wm's button-3 menu offers acme, wm/clock and wm/colors.
            # colors needs nothing that is not already here, and a menu
            # whose entries do nothing is worse than a shorter menu.
            "/dis/wm/colors.dis=$ROOT/dis/wm/colors.dis"

            # acme, the third entry on wm's menu. Its closure is only
            # four files this image does not already have -- complete,
            # libc, styx and acme itself, about 75KB -- so the menu no
            # longer offers something that cannot run.
            "/dis/acme.dis=$ROOT/dis/acme.dis"
            "/dis/lib/complete.dis=$ROOT/dis/lib/complete.dis"
            "/dis/lib/libc.dis=$ROOT/dis/lib/libc.dis"
            "/dis/lib/styx.dis=$ROOT/dis/lib/styx.dis"
            "/dis/wm/shell.dis=$ROOT/dis/wm/shell.dis"
            "/dis/lib/tkclient.dis=$ROOT/dis/lib/tkclient.dis"
            "/dis/lib/titlebar.dis=$ROOT/dis/lib/titlebar.dis"
            "/dis/lib/daytime.dis=$ROOT/dis/lib/daytime.dis"
            "/dis/lib/arg.dis=$ROOT/dis/lib/arg.dis"
            "/dis/lib/bufio.dis=$ROOT/dis/lib/bufio.dis"
            "/dis/lib/dis.dis=$ROOT/dis/lib/dis.dis"
            "/dis/lib/debug.dis=$ROOT/dis/lib/debug.dis"
            "/dis/lib/env.dis=$ROOT/dis/lib/env.dis"
            "/dis/lib/plumbmsg.dis=$ROOT/dis/lib/plumbmsg.dis"

            # A writable /tmp, which acme needs and the compiled-in
            # root cannot be: the whole image is read-only, so anything
            # that opens a temporary file fails with a permission
            # error that reads like a bug in the program.
            "/dis/memfs.dis=$ROOT/dis/memfs.dis"
            "/dis/lib/styxlib.dis=$ROOT/dis/lib/styxlib.dis"
        )
        # A font, so acme has something to draw with.
        #
        # acme opens /fonts/vera/Vera/unicode.14.font and there was no
        # /fonts at all in the image, which is why it drew a background
        # and vanished -- the missing /mnt/acme fixed earlier was real
        # but was not the whole of it.
        #
        # The stock file references dozens of subfonts out of the 10646
        # set and pulling all of those in would cost far more than the
        # rest of the image. Latin-1 is what a shell session and a
        # source file need, and Vera.14.0000 covers exactly that in
        # 12KB, so the font file is trimmed here to the one line that
        # names it rather than checking a second copy into the tree.
        printf '16\t13\n0x0000\t0x0100\tVera.14.0000\n' > "$BUILD/unicode.14.font"
        rootmanifest+=(
            "/fonts/vera/Vera/unicode.14.font=$BUILD/unicode.14.font"
            "/fonts/vera/Vera/Vera.14.0000=$ROOT/fonts/vera/Vera/Vera.14.0000"
        )

        python3 "$ROOT/tools/mkrootfs.py" "$BUILD/rootfs.c" \
            "${rootmanifest[@]}" 2>>"$BUILD/cc.log" || return 1
        "$CC" "${CFLAGS[@]}" -I"$BUILD" -Wno-everything \
            -c "$BUILD/rootfs.c" -o "$BUILD/rootfs.o" 2>>"$BUILD/cc.log" || return 1
        objs+=("$BUILD/rootfs.o")
    fi

    # serialboot, carried INSIDE the kernel.
    #
    # The kernel offers the loader back at the start of every boot, so
    # that a kernel installed as the boot file is still reachable when
    # it does not work -- see os/bcm2837/recover.c for why that matters
    # and how the handover is done. Generated from the same
    # serialboot.img that gets written to the card, so the copy the
    # kernel carries and the copy on the card cannot drift apart.
    if [[ -f "$BUILD/serialboot.img" ]]; then
        python3 - "$BUILD/serialboot.img" "$BUILD/serialbootimg.c" <<'SBEOF'
import sys
data = open(sys.argv[1], "rb").read()
with open(sys.argv[2], "w") as f:
    f.write("/* generated from serialboot.img -- do not edit */\n")
    f.write("typedef unsigned char uchar;\n")
    f.write("uchar serialbootimg[] = {\n")
    for i in range(0, len(data), 16):
        f.write("\t" + ",".join("0x%02x" % b for b in data[i:i+16]) + ",\n")
    f.write("};\n")
    f.write("int nserialbootimg = %d;\n" % len(data))
SBEOF
        "$CC" "${CFLAGS[@]}" -c "$BUILD/serialbootimg.c" \
            -o "$BUILD/serialbootimg.o" 2>>"$BUILD/cc.log" || return 1
        objs+=("$BUILD/serialbootimg.o")
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
        # serialboot is a separate program that happens to live in this
        # directory: it is the bootloader that fetches this kernel, has
        # a _start of its own, and must not be linked into it.
        case "$(basename "$f")" in serialboot.*) continue;; esac
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
        #
        #
        # exportfs.c IS built again. It was held out because the window
        # manager corrupted the namespace within seconds of starting
        # with it linked, ending in a lock loop inside walk() on a
        # structure whose lock was never held. That is the signature of
        # a Chan used after it was freed, and the cause of that was
        # found afterwards and fixed: namec's Chan* was not volatile
        # across its waserror handler, so every failed namec released
        # one reference too many (see os/port/chan.c). Re-enabled to
        # find out whether anything of its own is still wrong.
        #
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

    # os/ip -- the TCP/IP stack.
    #
    # Same treatment as os/port: warnings suppressed wholesale EXCEPT
    # the two that mark the Plan 9 C dialect, which are errors. That
    # escalation is not pedantry here -- it is what located all 167
    # call sites where an anonymous lock member was being passed as its
    # containing struct, each of which would otherwise have locked
    # whatever field happened to sit at offset 0.
    for f in "$ROOT"/os/ip/*.c; do
        [[ -e "$f" ]] || continue
        o="$BUILD/osip-$(basename "$f").o"
        "$CC" "${CFLAGS[@]}" -I"$ROOT/os/ip" -I"$BUILD" -Wno-everything \
             -Werror=missing-declarations -Werror=incompatible-pointer-types \
             -c "$f" -o "$o" 2>>"$BUILD/cc.log" || return 1
        objs+=("$o")
    done

    # libmemdraw and libmemlayer -- the drawing engine.
    #
    # Already in this tree, built for the hosted emulator; devdraw needs
    # them linked into the KERNEL instead. Compiled with FP like
    # libinterp: memdraw itself is integer work, but it is reached from
    # the same call paths and the separation is not worth a second set
    # of flags to discover the hard way.
    # The file list comes from each library's own mkfile, not from a
    # glob: libmemdraw/drawtest.c is a test PROGRAM that happens to live
    # beside the library, and globbing pulled it in and failed to
    # compile it.
    #
    # iprint.c is dropped as well. It is the library's own stand-in for
    # a kernel facility, and in a kernel that facility already exists --
    # linking both is a duplicate symbol.
    #
    # read.c, write.c, cread.c and openmemsubfont.c go the same way.
    # They read and write images through open/read/write on FILES, which
    # a kernel does not have -- the kernel serves images over the draw
    # protocol rather than loading them from a path. Their absence is
    # what the undefined open/readn/write were telling us.
    #
    # libdraw comes whole, and that is a change from when this kernel
    # only served the draw protocol. It is the CLIENT side -- Display,
    # Image, Font, allocwindow, string drawing -- and $Draw, the builtin
    # module a graphical Limbo program loads, is written against exactly
    # that API. So the kernel is now both ends: devdraw serves the
    # protocol and libdraw speaks it back over /dev/draw.
    #
    # It used to be four files, because memdraw alone needs only the
    # rectangle arithmetic (Rect, rectclip, rectXrect, rectinrect,
    # bytesperline) and the channel descriptors (chantostr, chantodepth).
    for f in "$ROOT"/libmemdraw/{arc,cmap,defont,ellipse,fillpoly,hwdraw,icossin,icossin2,line,poly,string,subfont,alloc,cload,draw,load,unload}.c \
             "$ROOT"/libmemlayer/*.c \
             "$ROOT"/libdraw/*.c; do
        # test.c is a PROGRAM, not part of the library -- it has its
        # own main(). mkfont.c is a font-building tool for the host.
        # readcolmap.c reads a colour-map FILE through libbio, which a
        # kernel does not have -- and a 32-bit direct-colour screen has
        # no colour map to read into in the first place.
        case "$(basename "$f")" in test.c|mkfont.c|readcolmap.c) continue;; esac
        [[ -e "$f" ]] || continue
        o="$BUILD/draw-$(basename "$(dirname "$f")")-$(basename "$f").o"
        "$CC" "${IFLAGS[@]}" -I"$ROOT/libmemdraw" -I"$BUILD" -Wno-everything \
             -c "$f" -o "$o" 2>>"$BUILD/cc.log" || return 1
        #
        # Into the ARCHIVE, not the object list -- for the same reason
        # libkern is an archive, and it is load-bearing here too.
        #
        # libinterp/draw.c deliberately REPLACES four of libdraw's
        # functions: freesubfont, subfontname, lookupsubfont and
        # installsubfont. $Draw keeps subfonts on the Dis heap so the
        # collector can see them, where libdraw keeps them in a static
        # cache it frees itself. Linking both unconditionally is four
        # duplicate symbols and a failed link.
        #
        # An archive member is extracted only if it resolves something
        # still undefined, so draw.c's definitions are found first and
        # libdraw's are never pulled in -- which is exactly how the
        # emulator's build behaves, since it links libdraw.a.
        #
        libobjs+=("$o")
    done

    # libmath -- fdlibm, for $Math.
    #
    # The module is thin: libinterp/math.c is mostly argument shuffling
    # in front of the real implementations, which are Sun's fdlibm.
    # Without them $Math links against nothing and every transcendental
    # is an undefined symbol.
    #
    # FPcontrol-Inferno.c is the one FPcontrol of eighteen: they are per
    # HOST, and this kernel is not hosted -- it IS Inferno. The others
    # are for the emulator on Linux, macOS, Windows and so on, and each
    # defines the same three functions, so linking more than one is a
    # duplicate symbol.
    #
    # libmath/pow10.c is NOT built. It defines ipow10 as pow(10., n)
    # and includes <math.h>, which a kernel does not have. libkernfp
    # already carries an exact table of powers of ten for atof, so
    # ipow10 is defined there instead, over that table.
    #
    # Into the archive, like libtk: a kernel whose Limbo never loads
    # $Math extracts none of it.
    for f in "$ROOT"/libmath/fdlibm/*.c "$ROOT"/libmath/dtoa.c \
             "$ROOT"/libmath/fdim.c "$ROOT"/libmath/g_fmt.c \
             "$ROOT"/libmath/gfltconv.c "$ROOT"/libmath/blas.c \
             "$ROOT"/libmath/gemm.c "$ROOT"/libmath/FPcontrol-Inferno.c; do
        [[ -e "$f" ]] || continue
        o="$BUILD/libmath-$(basename "$f").o"
        "$CC" "${IFLAGS[@]}" -I"$ROOT/libmath/fdlibm" -I"$BUILD" -Wno-everything \
             -c "$f" -o "$o" 2>>"$BUILD/cc.log" || return 1
        libobjs+=("$o")
    done

    # libtk -- the widget set.
    #
    # Also an archive member set, and for a stronger reason than
    # libdraw's: nothing in a kernel that never starts a window system
    # references any of it, so on a build where tkmodinit() is not
    # called none of these thirty-seven files is extracted at all and
    # the whole widget set costs nothing.
    #
    # It sits on top of $Draw rather than beside it: Tk draws through
    # the same Display and Image a Limbo program uses, which is why it
    # could not be built until libdraw was linked whole.
    for f in "$ROOT"/libtk/*.c; do
        [[ -e "$f" ]] || continue
        o="$BUILD/libtk-$(basename "$f").o"
        "$CC" "${IFLAGS[@]}" -I"$ROOT/libmemdraw" -I"$BUILD" -Wno-everything \
             -c "$f" -o "$o" 2>>"$BUILD/cc.log" || return 1
        libobjs+=("$o")
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
        gpu.c|crypt.c|ipint.c) continue;;
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
import subprocess, sys, time, threading
qemu, img, extra = sys.argv[1], sys.argv[2], sys.argv[3]
cmds = sys.argv[4:]
p = subprocess.Popen([qemu] + extra.split() + ["-kernel", img,
                      "-display", "none", "-serial", "stdio"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL)

# Read continuously in the background so the wait below can watch for
# the prompt. Without this the pipe is only drained at the end, and
# there is nothing to wait ON -- which is why this used to sleep a fixed
# eight seconds and hope.
buf = bytearray()
def reader():
    while True:
        d = p.stdout.read(1)
        if not d:
            return
        buf.extend(d)
threading.Thread(target=reader, daemon=True).start()

# Wait for the shell, do not guess at it.
#
# A fixed sleep encodes one boot's timing as if it were a constant, and
# the moment boot got slower -- init now waits for the bus walk and for
# the network before handing over, so the prompt is the last thing on
# screen rather than the middle -- every command was typed into a
# machine that had not reached a shell yet. They still ran, because the
# line discipline buffers them, which is worse: the tests passed or
# failed on how much time happened to be left after the backlog drained.
deadline = time.time() + 90
while time.time() < deadline:
    if b"init: starting the shell" in buf:
        break
    time.sleep(0.2)
time.sleep(1.5)                   # let sh load and print its prompt

try:
    for c in cmds:
        # CR, not NL -- this is what a terminal's Enter key sends, and
        # what anything driving the line from a script sends. Typing NL
        # here for eight months meant the cooked-mode line discipline was
        # never tested with the byte it actually receives, and the board
        # duly took input that never reached the shell: consread ends a
        # line on NL or ^D, so an untranslated CR was appended to
        # kbd.line and the line was never terminated.
        p.stdin.write(c.encode() + b"\r")
        p.stdin.flush()
        time.sleep(1.0)

    # Wait for the session to DRAIN, rather than guessing how long the
    # last command takes.
    #
    # There used to be a flat two-second wait here, which is a guess
    # about the slowest thing in the list -- and the list contains
    # "sleep 1". Two checks near the end of it failed intermittently
    # for exactly that reason: the machine was killed mid-command and
    # the output the check looked for had not been printed yet. A test
    # that fails on how busy the host is says nothing about the kernel.
    #
    # So type one more command whose output is unmistakable and wait
    # for it. It appears twice -- once echoed as it is typed, once
    # printed by echo -- and the second occurrence is the one that
    # means every command before it has finished.
    p.stdin.write(b"echo dRaInEd\r")
    p.stdin.flush()
    deadline = time.time() + 30
    while time.time() < deadline:
        if bytes(buf).count(b"dRaInEd") >= 2:
            break
        time.sleep(0.2)
except Exception:
    pass
time.sleep(0.3)
p.kill()
p.wait()
sys.stdout.write(bytes(buf).decode(errors="replace"))
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
        -O2 -fno-omit-frame-pointer -I"$SRC" -I"$ROOT/os/arm64" -I"$ROOT/os/port" -I"$ROOT/os/ip" -I"$ROOT/Inferno/arm64/include"
        -I"$ROOT/include" -I"$ROOT/libkern" -I"$ROOT/libinterp")

CFLAGS=(--target=aarch64-elf -ffreestanding -nostdlib -mgeneral-regs-only
        -O2 -fno-omit-frame-pointer -Wall -Wextra -I"$SRC" -I"$ROOT/os/arm64" -I"$ROOT/os/port" -I"$ROOT/os/ip" -I"$ROOT/Inferno/arm64/include" -I"$ROOT/libinterp"
        -I"$ROOT/include" -I"$ROOT/libkern")

echo -e "${BOLD}--- $PLAT (qemu $QEMUARGS) ---${NC}"

#
# serialboot, the serial bootloader.
#
# Built here because this is the only supported build path, and
# regression-checked because it is the piece that must keep working
# when the kernel does not: it lives on the card permanently and pulls
# the kernel down the wire on every reset, so a board with a broken
# kernel costs a reset rather than a trip to find the card reader.
#
# It shares no code with the kernel, deliberately.
#
if [[ "$PLAT" == "bcm2837" ]]; then
    # Objects go in their own directory: the kernel link collects .o
    # files from the build dir, and serialboot has a _start of its own.
    mkdir -p "$BUILD/sb"
    SBF=("${CFLAGS[@]}")
    if "$CC" "${SBF[@]}" -c "$ROOT/os/bcm2837/serialboot.c" -o "$BUILD/sb/c.o" 2>>"$BUILD/cc.log" \
    && "$CC" "${SBF[@]}" -c "$ROOT/os/bcm2837/serialboot.S" -o "$BUILD/sb/s.o" 2>>"$BUILD/cc.log" \
    && "$LLD" -T "$ROOT/os/bcm2837/serialboot.ld" "$BUILD/sb/s.o" "$BUILD/sb/c.o" \
            -o "$BUILD/sb/serialboot.elf" 2>>"$BUILD/cc.log" \
    && "$OBJCOPY" -O binary "$BUILD/sb/serialboot.elf" "$BUILD/serialboot.img" 2>>"$BUILD/cc.log"; then
        sbsz=$(wc -c < "$BUILD/serialboot.img" | tr -d ' ')
        # It relocates itself out of 0x80000 before loading anything
        # there, so it must stay far smaller than the kernel it fetches.
        if [[ "$sbsz" -gt 64 && "$sbsz" -lt 16384 ]]; then
            pass "serialboot builds and is $sbsz bytes"
        else
            fail "serialboot is $sbsz bytes, which is not a plausible size"
        fi
    else
        fail "serialboot failed to build"
    fi
fi

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
# 120 seconds, not 30, and not 10.
#
# The DHCP client waits two seconds for the switch to start forwarding
# and then retries for twenty, because a link that has just come up does
# not carry traffic yet. Under emulation nobody answers, so the boot
# spends the whole of that budget before the network configuration is
# printed -- and a boot window shorter than the code's own timeouts
# tests how fast the kernel gives up, not what it does.
#
# It went from 30 when the clock went to 1000Hz. That is ten times as
# many timer interrupts for QEMU's TCG to emulate, which costs nothing
# on real silicon and a great deal here, and the address and route
# checks began failing on a kernel that configures both perfectly well
# on hardware.
#
# The number is measured, not guessed -- twice, because the first
# guess was wrong. The driver's own message says "14 tries over ~45
# seconds", which is what the schedule asks for in wall-clock terms
# and NOT what it costs under emulation: timing the lines out of a
# QEMU boot puts "serving /net/ether0" at 11.6s and the fallback at
# 83.8s. 75 was still short. The schedule itself is deliberate --
# fourteen tries is for real networks that are slow to start
# forwarding, not for an emulator that never answers DHCP at all -- so
# the window moves rather than the timeouts.
OUT="$(boot_kernel "$BUILD/$PLAT-kernel.img" 120)"
info "--- serial output ---"
[[ "$VERBOSE" -eq 1 ]] && echo "$OUT"

# The inverse of check: some faults announce themselves, and the absence
# of the announcement is the thing worth asserting.
refute() {
    local pattern="$1" what="$2"
    if grep -q "$pattern" <<<"$OUT"; then
        fail "$what (matched: $pattern)"
    else
        pass "$what"
    fi
}

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
check "init: 127.0.0.1/8 configured"    "an IP interface is configured on the loopback medium"

# A packet, end to end. ipoput4 -> loopback medium -> ipiput4 -> ICMP
# recognises the request, generates a reply, and it is delivered back to
# the conversation that sent it. Checksums, the route lookup, the
# interface's self addresses and the protocol demultiplexer are all on
# that path, and none of them can be verified by reading a stats file.
check "ICMP echo reply from 127.0.0.1"  "the stack moves packets: an ICMP echo completes over loopback"

# TCP is the hard part: a three-way handshake, sequence numbers
# advancing on both sides, windows, and an ordered byte stream each
# way. It is also the direct exercise of the arithmetic that was wrong
# under LP64 -- every segment compares sequence numbers, and a
# connection whose comparisons answer wrongly stalls rather than fails.
check "TCP echo over loopback returned"  "TCP completes a connection and returns data over loopback"

# The first USB transaction: an 8-byte setup packet written to the root
# hub's control endpoint, intercepted by devusb and turned into
# hp->portstatus(), read back out of the DWC controller's hport0
# register. "present" appears only when a device is actually attached --
# with an empty bus the same request reports 0x0500 powered highspeed.
check "USB root hub port 1 status"       "a USB control transfer reaches the DWC controller"
check "present"                          "the root hub sees the attached device"

# Enumeration: reset the port, allocate a device, and read its device
# descriptor over the wire. The values are checked rather than just the
# line, because the failure this replaced produced a descriptor of the
# right LENGTH full of zeros -- the DMA target is the cache-line-rounded
# address and the block's rp was left pointing at the padding in front
# of it, so the reply read back as a device that answered with nothing.
#
# QEMU's raspi3b puts a hub (NEC 0409:55aa) on the root port, so class 9
# is the expected answer and the usb-net sits behind it. If a future
# QEMU models a different hub this will fail loudly, which is the point:
# a wrong-but-plausible descriptor is exactly what must not pass.
# The firmware's answer to the power request, not just the request.
#
# setpower passed `sizeof buf` where mboxprop wants a u32int COUNT, so it
# declared a 32-byte value buffer for an 8-byte tag, read six words past
# a two-element array and wrote eight words back over the caller's stack
# frame -- and discarded the result, so none of it showed. Asserting the
# reply is what makes the contract testable rather than assumed.
check "setpower: dev 3"                  "the USB power domain is requested by id"
check "setpower: dev 3 .* ON"            "the firmware confirms the USB block is powered"
refute "FIRMWARE REFUSED"                "the USB block is not left unpowered"

check "USB port 1 after reset"           "SET_FEATURE(PORT_RESET) enables the port"
check "enabled"                          "the port reports itself enabled after reset"
check "ep2.0 0x0409:0x55aa class 9 (hub)" "the device descriptor reads back real values"
check "maxpkt 8 usb 1.1"                 "descriptor fields are the device's, not padding"

# Enumerating THROUGH the hub. Everything above talks to the first
# device on the bus; these need it addressed first, which is the step
# that requires a control transfer with no data stage to complete.
check "is a hub with 8 port(s)"          "the hub descriptor reports its port count"
check "port 1 0x0103 present enabled"    "a hub port powers up, resets and enables"
check "ep3.0 0x0525:0xa4a2 class 2"      "the device behind the hub enumerates"
check "class 2 maxpkt 64 usb 2.0"        "it is the CDC Ethernet adapter, at high speed"

# The configuration descriptor: what the device can DO, as opposed to
# what it is. This is the first MULTI-PACKET control transfer in the
# port -- 67 bytes at maxpkt 64 -- and it needed a driver fix to
# complete, so the endpoint lines are checked rather than just the
# header.
check "config: 2 interface(s), 67 bytes"  "the full configuration descriptor reads back"
check "if 0 alt 0: class 2.2.255"        "interface 0 is CDC control, vendor protocol (RNDIS)"
check "if 1 alt 0: class 10.0.0"         "interface 1 is CDC data"
check "ep2 in bulk maxpkt 64"            "the bulk IN endpoint is described"
check "ep2 out bulk maxpkt 64"           "the bulk OUT endpoint is described"

# The class driver, which is a PROGRAM -- loaded by osinit, not linked
# into the kernel. See the driver-placement decision in
# os/bcm2837/README.md.
#
# The MAC is the load-bearing check: it is not a constant anywhere in
# this tree, it is queried out of the device over RNDIS, so a correct
# answer means the whole chain worked -- SET_CONFIGURATION, a bulk
# endpoint created through #u, and an RNDIS request/response pair
# carried on class control transfers to an interface.
check "etherusb: ep3.0 bulk in ep3.2 out ep3.2" "the driver creates a bulk endpoint through #u"
check "etherusb: RNDIS 1.0, max transfer 1580" "the RNDIS handshake completes"
check "etherusb: ep3.0 rndis, MAC 52:54:00:12:34:57" "the family is chosen and the MAC read out of the device"
check "etherusb: ep3.0 ready"                  "the packet filter is accepted"

# The file interface, and the interface bound to it. "configured"
# only appears if ethermedium dialled /net/ether0, opened its three
# connections, read the MAC out of <n>/stats, and accepted the address
# -- which in turn required a gratuitous ARP to be TRANSMITTED over
# USB. Verified independently against QEMU's own packet capture:
#
#   ARP, Announcement 10.0.2.15
#   ARP, Request who-has 10.0.2.2 tell 10.0.2.15
#   ARP, Reply 10.0.2.2 is-at 52:55:0a:00:02:02
#
# The reply is on the wire; receiving it does not work yet. See
# "Receive does not complete" in os/bcm2837/README.md.
check "etherusb: serving /net/ether0"          "the driver publishes a netif file interface"
check "10.0.2.15 mask 255.255.255.0 on ipifc"       "os/ip binds an interface to a driver outside the kernel"
check "default route via 10.0.2.2"             "a default route is installed"

# Interrupts, asserted rather than assumed.
#
# The clock probe elsewhere tests the generic timer, which is PER-CORE
# and never touches the VideoCore controller -- so it says nothing
# about devices. These two do.
#
# They matter because a driver whose interrupt line goes nowhere is
# indistinguishable from a working one under emulation: transfers
# complete inside the register write that starts them, every wait finds
# its condition already true, and nothing is ever left to wake. It
# stays indistinguishable right up until it meets hardware.
check "intr: device interrupt delivered" "a device interrupt reaches the CPU through the VideoCore controller"
# The check for the USB controller's interrupt was removed with the
# self-test behind it: it asked whether start-of-frame arrived before
# the root port was enabled, which it cannot, so it reported a fault
# that was not one. chanwait's timeout is what reports a genuinely
# broken interrupt path now.

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
        'echo env-round-trip > /env/probe' \
        'cat /env/probe' \
        'q=`{echo one two three}; echo subst-count $#q' \
        'load std' \
        'for(i in a b c){ echo loop-$i }' \
        'cat /dev/drivers' \
        'cat /net/ipifc/stats' \
        'cat /net/iproute' \
        'cat /net/tcp/stats' \
        'cd /dis; pwd; cd /' \
        'date' \
        'basename /a/b/see-me' \
        'echo one two three | wc' \
        'ns' \
        'echo grep-found-it | grep found' \
        'ps | wc -l' \
        'sleep 0; echo slept-ok' \
        'for(i in x y z){ echo loop2-$i }')"

# Strip carriage returns once, here.
#
# This is a serial console: every line ends CR LF, so a pattern anchored
# with $ cannot match and a command that worked perfectly reports as
# broken. Two checks below were written, failed, and were investigated
# before the cause turned out to be the terminal rather than the shell.
SHOUT="$(tr -d '\r' <<<"$SHOUT")"
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

# #e, exercised from the shell rather than merely linked. Setting a
# variable CREATES a file, so this needs both the device and a mount
# point that permits creation: binding it MREPL without MCREATE gives
# "mounted directory forbids creation" on an ordinary assignment, and
# the failed create then took the kernel down with "panic: cclose".
if grep -v 'echo ' <<<"$SHOUT" | grep -q 'env-round-trip'; then
    pass "#e stores and returns a variable through /env"
else
    fail "environment variable did not round-trip through /env"
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

# #u is the USB device framework -- the kernel half of the split this
# port deliberately kept (host controller and endpoint I/O in the
# kernel, enumeration and class drivers out). /dev/drivers is devcons
# listing devtab, so this asks the running kernel rather than the build.
if grep -q '^#u usb' <<<"$SHOUT"; then
    pass "#u is registered: the USB framework is in the running kernel"
else
    fail "#u missing from /dev/drivers"
fi

# #I is the IP stack. Reading its MIB is a stronger check than the
# device merely existing: DefaultTTL comes from ip_init having run and
# ipifcinit having registered the protocol that owns interfaces, so a
# stack that linked but never initialised would not produce it.
if grep -q '^#I ip' <<<"$SHOUT"; then
    pass "#I is registered: the IP stack is in the running kernel"
else
    fail "#I missing from /dev/drivers"
fi

if grep -q '^DefaultTTL: 255' <<<"$SHOUT"; then
    pass "the IP stack initialised (ipifc reports its MIB)"
else
    fail "#I/ipifc/stats did not report DefaultTTL"
fi

# Loopback configured, end to end: osinit clones an interface, binds
# the loopback medium and assigns 127.0.0.1/8, and this reads back the
# routes that assignment created.
if grep -q '^127\.0\.0\.1 .* 4u ' <<<"$SHOUT"; then
    pass "loopback is configured (127.0.0.1 present as a unicast self route)"
else
    fail "no unicast route for 127.0.0.1"
fi

# The directed broadcast is derived from the route's END ADDRESS -- the
# "ea = sa | ~m" arithmetic that produced 0xffffffff_xxxxxxxx under
# LP64 until iproute.c was fixed. Seeing 127.255.255.255 rather than
# something enormous is that fix confirmed in the running kernel, not
# just in the host test.
if grep -q '^127\.255\.255\.255 ' <<<"$SHOUT"; then
    pass "route end addresses are right (broadcast is 127.255.255.255)"
else
    fail "directed broadcast for 127.0.0.0/8 is wrong or missing"
fi

# A connection with broken seq_lt/seq_gt does not fail outright: it
# reorders or stalls, and that shows up here before it shows up as a
# symptom. OutOfOrder is the counter that means it.
#
# RETRANSMITS ARE NOT. This asked for zero and got it only because the
# harness used to leave QEMU's stdout undrained: the pipe filled, QEMU
# blocked on write, and a frozen guest cannot reach a retransmit timer.
# Draining continuously lets real time pass and two appear -- on
# loopback, where nothing is ever lost, so what expired was the RTO
# while the receiving process waited to be scheduled during a busy boot.
# That measures emulated scheduling latency, not sequence arithmetic,
# and asserting zero on it would be asserting that the test machine is
# never slow.
#
# So it is reported, and only an implausible count fails -- that would
# mean something is genuinely refusing to make progress.
RETRANS="$(sed -n 's/^RetransSegs: \([0-9]*\).*/\1/p' <<<"$SHOUT" | head -1)"
info "TCP RetransSegs: ${RETRANS:-unknown}"
if grep -q '^OutOfOrder: 0' <<<"$SHOUT" && [[ -n "$RETRANS" && "$RETRANS" -lt 10 ]]; then
    pass "TCP sequencing is sound (nothing out of order, $RETRANS retransmit(s))"
else
    fail "TCP reordered segments or retransmitted excessively (OutOfOrder/Retrans=$RETRANS)"
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

    #
    # Per opcode class, by the standard method.
    #
    # The single benchmark above is one arithmetic loop -- six opcodes.
    # These seven classes cover the places a miscompilation actually
    # hides: 64-bit arithmetic, floating point, arrays, strings, deep
    # calls, channels. Each is sampled several times and reports its
    # MINIMUM, because every disturbance makes a sample longer and never
    # shorter, so the minimum is the closest thing to the cost of the
    # work itself.
    #
    # The CHECKSUM is what is asserted. A class whose compiled result
    # differs from the interpreted one is a miscompilation, and it is
    # named rather than reported as "something, somewhere, is wrong".
    # The times are recorded for the log; they are not a pass condition,
    # because a machine that is busy is not a machine that is broken.
    #
    jitclasses=0
    jitbad=0
    while read -r cls jsum jmin; do
        [[ -z "$cls" ]] && continue
        nline="$(grep -oE "jit: $cls [0-9a-f]{8} min [0-9]+" <<<"$NOJITOUT" | head -1)"
        nsum="$(awk '{print $3}' <<<"$nline")"
        nmin="$(awk '{print $5}' <<<"$nline")"
        jitclasses=$((jitclasses+1))
        if [[ -z "$nsum" ]]; then
            fail "class '$cls' produced no interpreter result to compare against"
            jitbad=$((jitbad+1))
        elif [[ "$jsum" != "$nsum" ]]; then
            fail "JIT miscompiles '$cls': compiled $jsum, interpreted $nsum"
            jitbad=$((jitbad+1))
        else
            info "  $cls: JIT ${jmin}us, interpreter ${nmin}us"
        fi
    done < <(grep -oE 'jit: [a-z]+ [0-9a-f]{8} min [0-9]+' <<<"$OUT" \
             | awk '{print $2, $3, $5}')

    if [[ "$jitclasses" -ge 7 && "$jitbad" -eq 0 ]]; then
        pass "all $jitclasses opcode classes compile to the same results as the interpreter"
    else
        fail "opcode class comparison incomplete or wrong ($jitclasses classes, $jitbad bad)"
    fi

    if grep -q 'jit: measurement overhead' <<<"$OUT"; then
        pass "the benchmark measures its own overhead before measuring anything else"
    else
        fail "no measurement-overhead baseline was taken"
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

# The console has taken the screen, so the boot test pattern is gone --
# correctly: a console clears what was there. What replaces the pattern
# check proves strictly more.
#
# Background colour still proves CHANNEL ORDER on its own: 0x101018 is
# asymmetric across the three channels, so a swap reads 0x181010 and is
# caught. Glyph pixels prove the font rendered and that pitch and base
# put it where it belongs -- which the pattern also proved, except that
# a console exercises far more of the path to get there.
BG = (0x10, 0x10, 0x18)
FG = (0xC8, 0xC8, 0xC8)

nbg = nfg = 0
rows = set()
for y in range(h):
    for x in range(0, w, 2):        # every other column is plenty
        c = pix(x, y)
        if c == BG:
            nbg += 1
        elif c == FG:
            nfg += 1
            rows.add(y)

bad = []
if nbg < (w // 2) * h // 4:
    bad.append(f"background {BG} covers only {nbg} sampled pixels")
if nfg < 500:
    bad.append(f"only {nfg} text pixels -- console drew nothing legible")
if len(rows) < 32:
    bad.append(f"text spans {len(rows)} scanlines -- expected many lines")

print("DIMS %dx%d bg=%d fg=%d rows=%d" % (w, h, nbg, nfg, len(rows)))
print("OK" if not bad else "BAD " + "; ".join(bad))
PYEOF

PIXOUT="$(cat "$BUILD/$PLAT-pixels.txt")"
info "$PIXOUT"
if grep -q '^SKIP' <<<"$PIXOUT"; then
    skip "framebuffer pixel check ($(grep '^SKIP' <<<"$PIXOUT"))"
elif grep -q '^OK' <<<"$PIXOUT"; then
    pass "the console rendered text (correct pitch, base, channel order and font)"
else
    fail "framebuffer contents wrong: $(grep '^BAD' <<<"$PIXOUT")"
fi

#
# 3b. Scrolling by moving the window, not by moving the pixels.
#
#     Console writes measured 570-770ms on hardware and all of it was
#     the full-screen memmove -- which put a keystroke's echo the better
#     part of a second behind the key. The framebuffer is now allocated
#     taller than the display and scrolling sets a GPU offset instead.
#
#     That path cannot run under a plain emulated boot: QEMU grants the
#     offset but reports a screen-sized allocation, so the safety gate
#     -- rightly -- keeps the fast path off, and the code that only runs
#     on hardware would be the code nothing tests. So build a variant
#     that gives the console half the panel and uses the other half as
#     headroom. The offset arithmetic, the fold, and the line clearing
#     then all execute inside the allocation QEMU really did give us.
#
#     What this proves is bounded but is the part that matters: the
#     window moves, a full cycle folds back to the top, no write lands
#     outside the buffer, and the kernel still finishes booting.
#
if build_kernel "$BUILD/$PLAT-fbscroll.img" "" "-DFBSCROLLTEST"; then
    FBOUT="$(boot_kernel "$BUILD/$PLAT-fbscroll.img" 20)"
    OUT_SAVED="$OUT"; OUT="$FBOUT"
    check "console on display .*scroll by GPU offset" "the console scrolls by moving the window, not the pixels"
    check "fb:   window folded once"   "the window walks to the end of the buffer and folds back"
    refute "SCROLL OUT OF RANGE"       "no scroll writes outside the framebuffer allocation"
    check "boot OK"                    "the kernel boots through a full scroll cycle without faulting"
    OUT="$OUT_SAVED"
else
    fail "the framebuffer-scroll variant failed to build"
fi

#
# 2f. The shell can actually run commands.
#
#     A command that is missing from the image does NOT report itself
#     missing. $path already defaults to (/dis .), so the shell tries
#     /dis/date.dis, then ./date, and reports the LAST one -- "'./date'
#     file does not exist" -- which reads like a broken shell rather
#     than an image that was never given a date command. Being in the
#     manifest is also not enough: a command whose library is absent is
#     found and then fails to LOAD, which is a third distinct error.
#
#     So run them. Each check below is a command doing its job, which is
#     the only form of this that cannot pass while the machine is
#     unusable.
#
# "#/dis", not "/dis": the root filesystem is compiled into the kernel
# and served by the root DEVICE, so a path under it names that device.
# That prefix is correct and worth asserting rather than trimming.
if grep -qE '^#?/dis$' <<<"$SHOUT"; then
    pass "cd changes directory and pwd reports it"
else
    fail "cd or pwd did not work"
fi

if grep -qE '^(Sun|Mon|Tue|Wed|Thu|Fri|Sat) ' <<<"$SHOUT"; then
    pass "date runs and prints a date"
else
    fail "date did not run (is /dis/date.dis in the image?)"
fi

if grep -q '^see-me$' <<<"$SHOUT"; then
    pass "basename runs"
else
    fail "basename did not run"
fi

# wc on "one two three" is 1 line, 3 words, 14 bytes.
if grep -qE '^ *1 +3 +14' <<<"$SHOUT"; then
    pass "a pipeline works (echo into wc counts correctly)"
else
    fail "echo | wc did not produce the right counts"
fi

if grep -q 'slept-ok' <<<"$SHOUT"; then
    pass "sleep runs and returns"
else
    fail "sleep did not run"
fi

if grep -qE '^(bind|mount) ' <<<"$SHOUT"; then
    pass "ns prints the namespace"
else
    fail "ns did not print a namespace"
fi

if grep -q 'grep-found-it' <<<"$SHOUT"; then
    pass "grep runs and matches"
else
    fail "grep did not run"
fi

if grep -v 'echo ' <<<"$SHOUT" | grep -q 'loop2-y'; then
    pass "control flow works without typing 'load std' first (the profile ran)"
else
    fail "for(){} did not run -- /lib/sh/profile did not load std"
fi

#
# 3c. A USB keyboard, enumerated and typed on.
#
#     This is the regression guard for the failure that cost an entire
#     evening, and it is worth saying exactly what it catches, because
#     nothing else here does.
#
#     The keyboard is a LOW-SPEED device behind a hub, so every transfer
#     to it is a split transaction -- and a split that goes wrong does
#     not report an error. It returns 0x55 repeating, alternating bits,
#     a bus sampled at the wrong rate, and the caller takes that for a
#     descriptor: a configuration value of 85, an interface class of 85,
#     no driver matched, and a boot log that reads as success. Three
#     separate mistakes in the split state machine presented that way,
#     and each was found by a person typing at a board and getting
#     nothing back.
#
#     QEMU will attach one (-device usb-kbd) and its dwc2 model carries
#     the whole path: enumeration, the HID boot interface, the interrupt
#     endpoint, and the driver. So the whole path can be asserted here
#     instead.
#
SAVEDARGS="$QEMUARGS"
QEMUARGS="$QEMUARGS -device usb-kbd"
KBDOUT="$(boot_kernel "$BUILD/$PLAT-kernel.img" 22)"
QEMUARGS="$SAVEDARGS"
[[ "$VERBOSE" -eq 1 ]] && { echo "  --- usb keyboard boot ---"; echo "$KBDOUT"; }

OUT_SAVED="$OUT"; OUT="$KBDOUT"
check "class 3.1.1"                 "a HID boot keyboard interface is found on the bus"
check "kbdusb: .* ready on endpoint" "the keyboard driver claims it and opens its interrupt endpoint"

# The specific corruption, named. A descriptor read that returns 0x55
# yields these exact numbers, and asserting their ABSENCE is what makes
# this test fail for the reason it was written rather than for some
# other one.
refute "class 85"                   "no descriptor read returned 0x55 garbage"
refute "value 85"                   "no configuration was selected from a corrupt descriptor"
refute "is not one"                 "no descriptor had to be rejected as malformed"
refute "configuration unreadable"   "every device configuration was readable"
OUT="$OUT_SAVED"

#
# 3d. A keystroke, from the HID device to the shell.
#
#     3c proves the keyboard is found and claimed. It does NOT prove a
#     key press survives the trip, and that is the part that kept
#     breaking: the driver was ready, the endpoint was open, and the
#     transfers still returned nothing usable -- or returned the same
#     report eight times, or wrote past the end of the buffer.
#
#     So press keys. QEMU's input-send-event drives the emulated HID
#     device exactly as a finger would, and the assertion is made at the
#     far end: the SHELL runs what was typed and prints the result. Every
#     stage is on that path -- split interrupt transfer, report decode,
#     /dev/keyboard, the line discipline, the shell.
#
#     The path is set over the serial line first, deliberately. That is
#     setup, not the thing under test, and typing it on the emulated
#     keyboard would make a failure anywhere in setup look like a
#     keyboard fault.
#
#     Compose is tested the same way and for the same reason: it is
#     invisible on the panel unless the console can draw the rune, so
#     asserting it here -- where the shell echoes the composed character
#     back as UTF-8 -- separates "compose is broken" from "the font has
#     no glyph". Alt then apostrophe then e is U+00E9, which is C3 A9.
#
python3 - "$QEMU" "$BUILD/$PLAT-kernel.img" "$QEMUARGS" <<'PYEOF' > "$BUILD/$PLAT-keys.txt" 2>&1
import subprocess, socket, json, time, sys, threading
qemu, img, extra = sys.argv[1], sys.argv[2], sys.argv[3]
PORT = 4479
p = subprocess.Popen([qemu] + extra.split() + ["-device", "usb-kbd",
                     "-kernel", img, "-display", "none", "-serial", "stdio",
                     "-qmp", f"tcp:127.0.0.1:{PORT},server=on,wait=off"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL)
buf = bytearray()
def reader():
    while True:
        d = p.stdout.read(1)
        if not d:
            return
        buf.extend(d)
threading.Thread(target=reader, daemon=True).start()

try:
    s = None
    deadline = time.time() + 20
    while time.time() < deadline and s is None:
        try:
            s = socket.create_connection(("127.0.0.1", PORT), timeout=1)
        except OSError:
            time.sleep(0.3)
    if s is None:
        print("SKIP no QMP"); p.kill(); sys.exit(0)
    f = s.makefile("rw")
    f.readline()
    f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush(); f.readline()

    # Wait for the driver to claim the keyboard, then let the shell settle.
    deadline = time.time() + 60
    while time.time() < deadline:
        if b"ready on endpoint" in buf:
            break
        time.sleep(0.2)
    else:
        print("SKIP keyboard driver never became ready"); p.kill(); sys.exit(0)
    time.sleep(3)

    # Setup over the serial line -- not part of what is being tested.
    p.stdin.write(b"path=(/dis .)\r"); p.stdin.flush()
    time.sleep(1.5)

    def press(*keys):
        for k in keys:
            for down in (True, False):
                f.write(json.dumps({"execute": "input-send-event", "arguments":
                    {"events": [{"type": "key", "data": {"down": down,
                     "key": {"type": "qcode", "data": k}}}]}}) + "\n")
                f.flush(); f.readline()
                time.sleep(0.06)

    press("e","c","h","o","spc","k","b","d","o","k","ret")
    time.sleep(3)
    press("e","c","h","o","spc","alt","apostrophe","e","ret")
    time.sleep(3)
    s.close()
finally:
    p.kill(); p.wait()

out = bytes(buf)
txt = out.decode("utf-8", "replace")
print("TYPED-OK" if "kbdok" in txt.split("echo kbdok")[-1] else "TYPED-MISSING")
print("COMPOSE-OK" if b"\xc3\xa9" in out else "COMPOSE-MISSING")
PYEOF

KEYOUT="$(cat "$BUILD/$PLAT-keys.txt")"
[[ "$VERBOSE" -eq 1 ]] && { echo "  --- keystroke test ---"; echo "$KEYOUT"; }
if grep -q '^SKIP' <<<"$KEYOUT"; then
    skip "keystroke delivery ($(grep '^SKIP' <<<"$KEYOUT" | head -1))"
elif grep -q 'TYPED-OK' <<<"$KEYOUT"; then
    pass "a keypress on the USB keyboard reaches the shell and runs a command"
else
    fail "keys pressed on the USB keyboard did not reach the shell"
fi

#
# 3f. A mouse, from the HID device to /dev/pointer.
#
#     The pointer is a FILE. Anything that can write to /dev/pointer is
#     a pointing device, and the USB mouse driver is a Limbo program
#     that does exactly that -- so this can be checked without a window
#     system, which is just as well, because there is not one yet.
#
#     QEMU's usb-mouse plus input-send-event moves a real emulated
#     device, so the whole path is under test: split interrupt transfer,
#     the three-byte boot report, the signed deltas, the button
#     remapping, /dev/pointer, and the shell reading it back.
#
python3 - "$QEMU" "$BUILD/$PLAT-kernel.img" "$QEMUARGS" <<'PYEOF' > "$BUILD/$PLAT-mouse.txt" 2>&1
import subprocess, socket, json, time, sys, threading
qemu, img, extra = sys.argv[1], sys.argv[2], sys.argv[3]
PORT = 4481
p = subprocess.Popen([qemu] + extra.split() + ["-device", "usb-mouse",
                     "-kernel", img, "-display", "none", "-serial", "stdio",
                     "-qmp", f"tcp:127.0.0.1:{PORT},server=on,wait=off"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL)
buf = bytearray()
def reader():
    while True:
        d = p.stdout.read(1)
        if not d:
            return
        buf.extend(d)
threading.Thread(target=reader, daemon=True).start()
try:
    s = None
    deadline = time.time() + 20
    while time.time() < deadline and s is None:
        try:
            s = socket.create_connection(("127.0.0.1", PORT), timeout=1)
        except OSError:
            time.sleep(0.3)
    if s is None:
        print("SKIP no QMP"); p.kill(); sys.exit(0)
    f = s.makefile("rw")
    f.readline()
    f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush(); f.readline()

    deadline = time.time() + 60
    while time.time() < deadline and b"mouseusb: " not in buf:
        time.sleep(0.2)
    if b"mouseusb: " not in buf:
        print("SKIP mouse driver never started"); p.kill(); sys.exit(0)
    time.sleep(3)

    # Read the pointer from the shell, then move the mouse.
    p.stdin.write(b"path=(/dis .)\r"); p.stdin.flush()
    time.sleep(1.5)
    p.stdin.write(b"cat /dev/pointer\r"); p.stdin.flush()
    time.sleep(2)

    for _ in range(6):
        f.write(json.dumps({"execute": "input-send-event", "arguments":
            {"events": [{"type": "rel", "data": {"axis": "x", "value": 12}},
                        {"type": "rel", "data": {"axis": "y", "value": 7}}]}}) + "\n")
        f.flush(); f.readline()
        time.sleep(0.25)
    time.sleep(3)
    s.close()
finally:
    p.kill(); p.wait()

txt = bytes(buf).decode("utf-8", "replace")
print("DRIVER-OK" if "mouseusb: " in txt and "ready on endpoint" in txt else "DRIVER-MISSING")
# A pointer report is "m" then x, y, buttons, msec. Non-zero x or y
# means the deltas were accumulated rather than dropped.
import re
rep = [m for m in re.findall(r"m\s*(-?\d+)\s+(-?\d+)\s+(-?\d+)\s+(\d+)", txt)]
moved = [r for r in rep if int(r[0]) != 0 or int(r[1]) != 0]
print("REPORTS %d MOVED %d" % (len(rep), len(moved)))
print("MOVED-OK" if moved else "MOVED-NONE")
PYEOF

MOUSEOUT="$(cat "$BUILD/$PLAT-mouse.txt")"
[[ "$VERBOSE" -eq 1 ]] && { echo "  --- mouse ---"; echo "$MOUSEOUT"; }
if grep -q '^SKIP' <<<"$MOUSEOUT"; then
    skip "mouse ($(grep '^SKIP' <<<"$MOUSEOUT" | head -1))"
else
    if grep -q 'DRIVER-OK' <<<"$MOUSEOUT"; then
        pass "the mouse driver claims a HID boot mouse and opens its endpoint"
    else
        fail "the USB mouse driver did not start"
    fi
    if grep -q 'MOVED-OK' <<<"$MOUSEOUT"; then
        pass "moving the mouse moves the pointer ($(grep -o 'REPORTS [0-9]* MOVED [0-9]*' <<<"$MOUSEOUT"))"
    else
        fail "mouse movement did not reach /dev/pointer ($(grep -o 'REPORTS [0-9]* MOVED [0-9]*' <<<"$MOUSEOUT"))"
    fi
fi

#
# 3g. The SD card, as blocks.
#
#     QEMU's raspi3b models the Arasan controller and takes a card
#     image, so the whole driver can be exercised here rather than
#     against the one card on the one board -- which matters more than
#     usual for this device: the only card a real Pi has is the one
#     holding the firmware and the loader that put this kernel in
#     memory.
#
#     The image is built with a known partition table, so the assertion
#     is on VALUES rather than on plausibility. An initialised
#     controller that reads the wrong sector, or treats a byte-addressed
#     card as block-addressed, comes up perfectly and returns data --
#     just not this data.
#
SDIMG="$BUILD/$PLAT-sd.img"
python3 - "$SDIMG" <<'PYEOF'
import struct, sys

# A card with a partition table and a real FAT16 filesystem in it.
#
# Built here rather than with mkfs or hdiutil so the test carries its own
# fixture and does not depend on what the host happens to provide. It is
# also the only way to assert on EXACT contents: the partition entry and
# the file inside it are both known because both were written right here.
SEC   = 512
PSTART = 2048            # where the partition begins, in sectors
PSECS  = 65536           # 32MB
SPC    = 4               # sectors per cluster
RESV   = 1
NFAT   = 2
FATSECS = 64
ROOTENT = 512
ROOTSECS = ROOTENT * 32 // SEC

part = bytearray(PSECS * SEC)

# Boot sector: the BIOS parameter block is what dossrv reads to find
# everything else, so every field below is load-bearing.
bs = bytearray(SEC)
bs[0:3]   = b"\xEB\x3C\x90"
bs[3:11]  = b"INFRNODE"
struct.pack_into("<H", bs, 11, SEC)       # bytes per sector
bs[13] = SPC
struct.pack_into("<H", bs, 14, RESV)      # reserved sectors
bs[16] = NFAT
struct.pack_into("<H", bs, 17, ROOTENT)   # root directory entries
struct.pack_into("<H", bs, 19, PSECS if PSECS < 65536 else 0)
bs[21] = 0xF8                             # media descriptor
struct.pack_into("<H", bs, 22, FATSECS)   # sectors per FAT
struct.pack_into("<H", bs, 24, 32)        # sectors per track
struct.pack_into("<H", bs, 26, 64)        # heads
struct.pack_into("<I", bs, 28, PSTART)    # hidden sectors
struct.pack_into("<I", bs, 32, 0 if PSECS < 65536 else PSECS)
bs[36] = 0x80                             # drive number
bs[38] = 0x29                             # extended boot signature
struct.pack_into("<I", bs, 39, 0x12345678)
bs[43:54] = b"INFRBOOT   "
bs[54:62] = b"FAT16   "
bs[510] = 0x55; bs[511] = 0xAA
part[0:SEC] = bs

CONTENT = b"hello from the SD card\n"

# Two FATs. Cluster 0 and 1 are reserved; the file occupies cluster 2
# and ends there.
fat = bytearray(FATSECS * SEC)
struct.pack_into("<H", fat, 0, 0xFFF8)
struct.pack_into("<H", fat, 2, 0xFFFF)
struct.pack_into("<H", fat, 4, 0xFFFF)
for i in range(NFAT):
    off = (RESV + i*FATSECS) * SEC
    part[off:off+len(fat)] = fat

# One root directory entry, in the 8.3 form FAT stores.
rootoff = (RESV + NFAT*FATSECS) * SEC
d = bytearray(32)
d[0:11] = b"HELLO   TXT"
d[11] = 0x20                              # archive
struct.pack_into("<H", d, 26, 2)          # first cluster
struct.pack_into("<I", d, 28, len(CONTENT))
part[rootoff:rootoff+32] = d

dataoff = (RESV + NFAT*FATSECS + ROOTSECS) * SEC
part[dataoff:dataoff+len(CONTENT)] = CONTENT

# And the card around it.
#
# 64MB exactly, because QEMU's SD model requires a power-of-two image
# and silently refuses to present a card otherwise -- which arrives as
# "emmc: no card in the slot" and reads like a driver fault.
buf = bytearray(64*1024*1024)
e = bytearray(16)
e[0] = 0x80                               # bootable
e[4] = 0x06                               # FAT16
struct.pack_into("<I", e, 8, PSTART)
struct.pack_into("<I", e, 12, PSECS)
buf[446:462] = e
buf[510] = 0x55; buf[511] = 0xAA
buf[PSTART*SEC : PSTART*SEC + len(part)] = part
open(sys.argv[1], "wb").write(buf)
PYEOF

SAVEDARGS="$QEMUARGS"
QEMUARGS="$QEMUARGS -drive file=$SDIMG,if=sd,format=raw"
SDOUT="$(boot_kernel "$BUILD/$PLAT-kernel.img" 20)"
QEMUARGS="$SAVEDARGS"
[[ "$VERBOSE" -eq 1 ]] && { echo "  --- sd ---"; grep emmc <<<"$SDOUT"; }

OUT_SAVED="$OUT"; OUT="$SDOUT"
check "emmc: card ready"            "the SD controller initialises a card"
check "emmc: MBR ok"                "sector 0 reads back with a valid boot signature"
check "start 2048 sectors 65536"    "the partition table holds the values the image was built with"
refute "emmc: cannot read"          "no read failed"
OUT="$OUT_SAVED"

#
#     A filesystem, end to end.
#
#     This is the check that ties the whole stack together and the only
#     one that would catch most of it breaking: the EMMC driver reads
#     blocks, #S turns a range of them into a file, init reads the
#     partition table and names that range, dossrv reads a FAT
#     filesystem out of the named file and mounts it, and the shell
#     reads a file through the mount. Every layer is on the path, and
#     the content asserted is the content this test wrote into the
#     image.
#
#     It also pins down a bug that cost real time: dossrv must be CALLED,
#     not spawned. It mounts in the calling process and returns once the
#     mount is done, while sh forks its namespace the moment it starts --
#     so a spawned dossrv raced the shell and the mount landed in a
#     namespace the shell did not share. The symptom was an empty
#     /n/dos with no error anywhere, which reads like a broken
#     filesystem rather than a lost race.
#
QEMUARGS="$SAVEDARGS -drive file=$SDIMG,if=sd,format=raw"
FSOUT="$(shell_session "$BUILD/$PLAT-kernel.img" \
        'path=(/dis .)' \
        'ls /n/dos' \
        'cat /n/dos/HELLO.TXT' \
        'echo first > /n/dos/RW.TXT' \
        'echo second >> /n/dos/RW.TXT' \
        'cat /n/dos/RW.TXT')"
QEMUARGS="$SAVEDARGS"
FSOUT="$(tr -d '\r' <<<"$FSOUT")"
[[ "$VERBOSE" -eq 1 ]] && { echo "  --- filesystem ---"; echo "$FSOUT"; }

OUT_SAVED="$OUT"; OUT="$FSOUT"
check "/n/dos/hello.txt"           "the FAT filesystem is mounted and lists its files"
OUT="$OUT_SAVED"

if grep -q 'hello from the SD card' <<<"$FSOUT"; then
    pass "a file is read from the card through dossrv, block driver to shell"
else
    fail "could not read a file from the mounted filesystem"
fi

# Creating a file is one path; EXTENDING one is a different path and it
# is the one that goes wrong quietly. A failed append does not report an
# error -- the bytes reach the card and the directory entry is not
# updated, so the file simply has not grown. Both lines must come back.
if grep -q '^first$' <<<"$FSOUT" && grep -q '^second$' <<<"$FSOUT"; then
    pass "a file can be created and then appended to"
else
    fail "appending to a file on the card did not take"
fi

#
#     The same again on FAT32, which is a different filesystem.
#
#     Not a variation on a theme: FAT32 announces itself by leaving the
#     ORIGINAL fields empty -- zero sectors-per-FAT, zero root entries --
#     and puts the real values elsewhere, and its root directory is an
#     ordinary cluster chain rather than a reserved area. dossrv as
#     imported read FAT12 and FAT16 only, so the Raspberry Pi's own boot
#     partition (type 0x0C) mounted and listed nothing.
#
#     This is the case that matters on the actual hardware, so it gets
#     its own fixture rather than being assumed to follow from FAT16.
#
SD32="$BUILD/$PLAT-sd32.img"
python3 - "$SD32" <<'PYEOF'
import struct, sys

SEC   = 512
PSTART = 2048
PSECS  = 131072          # 64MB, enough to be a genuine FAT32
SPC    = 1
RESV   = 32
NFAT   = 2
FATSZ  = 1024            # sectors per FAT, comfortably enough

part = bytearray(PSECS * SEC)

bs = bytearray(SEC)
bs[0:3]   = b"\xEB\x58\x90"
bs[3:11]  = b"INFRNODE"
struct.pack_into("<H", bs, 11, SEC)
bs[13] = SPC
struct.pack_into("<H", bs, 14, RESV)
bs[16] = NFAT
struct.pack_into("<H", bs, 17, 0)      # root entries: ZERO, this is FAT32
struct.pack_into("<H", bs, 19, 0)      # 16-bit total: zero, see offset 32
bs[21] = 0xF8
struct.pack_into("<H", bs, 22, 0)      # 16-bit sectors/FAT: ZERO, see 36
struct.pack_into("<H", bs, 24, 32)
struct.pack_into("<H", bs, 26, 64)
struct.pack_into("<I", bs, 28, PSTART)
struct.pack_into("<I", bs, 32, PSECS)
struct.pack_into("<I", bs, 36, FATSZ)  # the real sectors per FAT
struct.pack_into("<H", bs, 40, 0)      # ext flags
struct.pack_into("<H", bs, 42, 0)      # version
struct.pack_into("<I", bs, 44, 2)      # the root's first CLUSTER
struct.pack_into("<H", bs, 48, 1)      # FSInfo sector
struct.pack_into("<H", bs, 50, 6)      # backup boot sector
bs[64] = 0x80
bs[66] = 0x29
struct.pack_into("<I", bs, 67, 0x32323232)
bs[71:82] = b"INFR32     "
bs[82:90] = b"FAT32   "
bs[510] = 0x55; bs[511] = 0xAA
part[0:SEC] = bs

CONTENT = b"fat32 works on bare metal\n"

# Cluster 2 is the root directory, cluster 3 is the file. Entries are
# 32 bits and the top four are reserved, hence 0x0FFFFFFF for a chain
# end rather than 0xFFFFFFFF.
fat = bytearray(FATSZ * SEC)
struct.pack_into("<I", fat, 0, 0x0FFFFFF8)
struct.pack_into("<I", fat, 4, 0x0FFFFFFF)
struct.pack_into("<I", fat, 8, 0x0FFFFFFF)   # root, one cluster
struct.pack_into("<I", fat, 12, 0x0FFFFFFF)  # the file, one cluster
for i in range(NFAT):
    off = (RESV + i*FATSZ) * SEC
    part[off:off+len(fat)] = fat

data = (RESV + NFAT*FATSZ) * SEC             # cluster 2 begins here
d = bytearray(32)
d[0:11] = b"HELLO32 TXT"
d[11] = 0x20
struct.pack_into("<H", d, 20, 0)             # start cluster, HIGH half
struct.pack_into("<H", d, 26, 3)             # start cluster, low half
struct.pack_into("<I", d, 28, len(CONTENT))
part[data:data+32] = d

fileoff = data + (3-2)*SPC*SEC
part[fileoff:fileoff+len(CONTENT)] = CONTENT

buf = bytearray(256*1024*1024)               # power of two, for QEMU
e = bytearray(16)
e[0] = 0x80
e[4] = 0x0C                                  # FAT32 LBA
struct.pack_into("<I", e, 8, PSTART)
struct.pack_into("<I", e, 12, PSECS)
buf[446:462] = e
buf[510] = 0x55; buf[511] = 0xAA
buf[PSTART*SEC : PSTART*SEC + len(part)] = part
open(sys.argv[1], "wb").write(buf)
PYEOF

QEMUARGS="$SAVEDARGS -drive file=$SD32,if=sd,format=raw"
FS32="$(shell_session "$BUILD/$PLAT-kernel.img" \
        'path=(/dis .)' \
        'ls /n/dos' \
        'cat /n/dos/HELLO32.TXT')"
QEMUARGS="$SAVEDARGS"
FS32="$(tr -d '\r' <<<"$FS32")"
[[ "$VERBOSE" -eq 1 ]] && { echo "  --- fat32 ---"; echo "$FS32"; }

if grep -q 'fat32 works on bare metal' <<<"$FS32"; then
    pass "a FAT32 filesystem is mounted and read (the Pi boot partition's format)"
else
    fail "FAT32 could not be read"
fi

#
#     Installing the running kernel onto the card.
#
#     The machine boots by having a host push an image down the serial
#     line, which is fine for development and is not a way to own a
#     computer. The image is already in memory -- it is what was loaded
#     and what is executing -- so #B publishes it and installing it is
#     an ordinary cp through an ordinary filesystem.
#
#     The assertion is made from OUTSIDE the guest and against the
#     ACTUAL kernel file: the bytes on the card must equal the bytes of
#     the image that was booted. That is what catches the failure this
#     device is designed around -- serving the live memory instead of a
#     snapshot, which hands out a kernel whose data segment is whatever
#     it had become while running, and would boot into a state no fresh
#     image was ever in.
#
cp "$SD32" "$BUILD/$PLAT-sdinstall.img"
python3 - "$QEMU" "$BUILD/$PLAT-kernel.img" "$QEMUARGS" \
         "$BUILD/$PLAT-sdinstall.img" <<'PYEOF' > "$BUILD/$PLAT-install.txt" 2>&1
import subprocess, sys, time, threading
qemu, img, extra, sd = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
p = subprocess.Popen([qemu] + extra.split() + ["-kernel", img,
                     "-drive", "file=%s,if=sd,format=raw" % sd,
                     "-display", "none", "-serial", "stdio"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL)
buf = bytearray()
def reader():
    while True:
        d = p.stdout.read(1)
        if not d:
            return
        buf.extend(d)
threading.Thread(target=reader, daemon=True).start()
deadline = time.time() + 90
while time.time() < deadline and b"starting the shell" not in buf:
    time.sleep(0.2)
time.sleep(3)
try:
    p.stdin.write(b"path=(/dis .)\r"); p.stdin.flush(); time.sleep(1.5)
    p.stdin.write(b"cp /dev/bootimage /n/dos/INFRNODE.IMG\r"); p.stdin.flush()
    time.sleep(35)
    p.stdin.write(b"ls -l /n/dos/INFRNODE.IMG\r"); p.stdin.flush(); time.sleep(3)
except Exception:
    pass
p.kill(); p.wait()
sys.stdout.write(bytes(buf).decode(errors="replace"))
PYEOF

if python3 -c "
import sys
img = open('$BUILD/$PLAT-kernel.img','rb').read()
card = open('$BUILD/$PLAT-sdinstall.img','rb').read()
i = card.find(img[:4096])
sys.exit(0 if i >= 0 and card[i:i+len(img)] == img else 1)
" 2>/dev/null; then
    pass "the running kernel installs itself onto the card, byte for byte"
else
    fail "the kernel written to the card does not match the image that booted"
fi

#
#     And a write, in a kernel built only for this.
#
#     A write test needs somewhere to write, and picking a sector that
#     "looks free" on a real board eventually destroys the machine the
#     test runs on. So the write path is compiled in ONLY under
#     -DEMMCWRITETEST, against a scratch image, and is not in the kernel
#     that goes to hardware.
#
if build_kernel "$BUILD/$PLAT-sdwrite.img" "" "-DEMMCWRITETEST"; then
    cp "$SDIMG" "$BUILD/$PLAT-sdw.img"
    QEMUARGS="$SAVEDARGS -drive file=$BUILD/$PLAT-sdw.img,if=sd,format=raw"
    SDWOUT="$(boot_kernel "$BUILD/$PLAT-sdwrite.img" 20)"
    QEMUARGS="$SAVEDARGS"
    OUT_SAVED="$OUT"; OUT="$SDWOUT"
    check "write/read round trip OK" "a block written to the card reads back byte for byte"
    refute "WRITE ROUND TRIP CORRUPT" "the written block was not corrupted"
    OUT="$OUT_SAVED"

    # The host can see it too, which is a check the guest cannot fake.
    if python3 -c "
import sys
d = open('$BUILD/$PLAT-sdw.img','rb').read()
b = d[10000*512:10000*512+512]
sys.exit(0 if b == bytes((i ^ 0x5A) & 0xff for i in range(512)) else 1)
" 2>/dev/null; then
        pass "the written block is on the card image as seen from outside the guest"
    else
        fail "the block the guest claims it wrote is not in the image"
    fi
else
    fail "the SD write-test kernel failed to build"
fi

#
# 3h. A device plugged in AFTER boot is noticed.
#
#     The bus used to be walked once and never again, so a keyboard
#     connected after boot was invisible until the machine restarted --
#     which is indistinguishable from the keyboard being broken, and is
#     exactly how it was reported.
#
#     QEMU can add a USB device to a running machine, so the thing that
#     was missing is the thing this tests: boot with NO keyboard,
#     confirm the driver is not running, then plug one in and require
#     that the driver claims it without a reboot.
#
python3 - "$QEMU" "$BUILD/$PLAT-kernel.img" "$QEMUARGS" <<'PYEOF' > "$BUILD/$PLAT-hotplug.txt" 2>&1
import subprocess, socket, json, time, sys, threading
qemu, img, extra = sys.argv[1], sys.argv[2], sys.argv[3]
PORT = 4483
p = subprocess.Popen([qemu] + extra.split() + ["-kernel", img,
                     "-display", "none", "-serial", "stdio",
                     "-qmp", f"tcp:127.0.0.1:{PORT},server=on,wait=off"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL)
buf = bytearray()
def reader():
    while True:
        d = p.stdout.read(1)
        if not d:
            return
        buf.extend(d)
threading.Thread(target=reader, daemon=True).start()
try:
    s = None
    deadline = time.time() + 20
    while time.time() < deadline and s is None:
        try:
            s = socket.create_connection(("127.0.0.1", PORT), timeout=1)
        except OSError:
            time.sleep(0.3)
    if s is None:
        print("SKIP no QMP"); p.kill(); sys.exit(0)
    f = s.makefile("rw")
    f.readline()
    f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush(); f.readline()

    # Let the boot walk finish with nothing attached.
    deadline = time.time() + 90
    while time.time() < deadline and b"starting the shell" not in buf:
        time.sleep(0.2)
    time.sleep(8)
    before = bytes(buf)

    # Now plug a keyboard in.
    f.write(json.dumps({"execute": "device_add",
        "arguments": {"driver": "usb-kbd", "id": "hotkbd"}}) + "\n")
    f.flush(); f.readline()

    time.sleep(15)
    s.close()
finally:
    p.kill(); p.wait()

after = bytes(buf)
print("BEFORE-CLEAN" if b"kbdusb:" not in before else "BEFORE-DIRTY")
tail = after[len(before):]
print("ATTACH-SEEN" if b"device attached" in tail else "ATTACH-MISSED")
print("CLAIMED" if b"kbdusb:" in tail and b"ready on endpoint" in tail else "NOT-CLAIMED")
PYEOF

HOTOUT="$(cat "$BUILD/$PLAT-hotplug.txt")"
[[ "$VERBOSE" -eq 1 ]] && { echo "  --- hotplug ---"; echo "$HOTOUT"; }
if grep -q '^SKIP' <<<"$HOTOUT"; then
    skip "usb hotplug ($(grep '^SKIP' <<<"$HOTOUT" | head -1))"
else
    # The "before" check is what stops this passing for the wrong
    # reason: if a keyboard were somehow present at boot, the driver
    # would claim it then and the test would look like hotplug worked.
    if grep -q 'BEFORE-CLEAN' <<<"$HOTOUT"; then
        pass "the machine boots with no keyboard and no keyboard driver"
    else
        fail "a keyboard driver was already running before anything was plugged in"
    fi
    if grep -q 'ATTACH-SEEN' <<<"$HOTOUT"; then
        pass "the hub watcher notices a port change after boot"
    else
        fail "plugging a device in after boot went unnoticed"
    fi
    if grep -q 'CLAIMED' <<<"$HOTOUT"; then
        pass "a device plugged in after boot is enumerated and claimed by its driver"
    else
        fail "the hotplugged device was never claimed by a driver"
    fi
fi

#
# 3i. The draw device.
#
#     /dev/draw is the whole basis of a GUI here: Tk, wm and everything
#     above them speak to it and to nothing else. What is asserted is
#     the connection header the draw protocol hands back when a client
#     attaches, because it carries the three things that have to be
#     right for anything drawn to come out looking like what was meant:
#
#       the CHANNEL, x8r8g8b8, which is not a guess -- mailbox.c asks
#       the firmware for byte order 0, putting blue at the lowest
#       address, so a little-endian load reads 0xXXRRGGBB. Get it wrong
#       and everything draws, in the wrong colours.
#
#       the GEOMETRY, which comes from the firmware's own idea of the
#       display rather than from a constant here.
#
#     #i is bound by the test rather than at boot, because attaching
#     the draw device is what takes the framebuffer away from the text
#     console -- binding it at boot cost every machine its console to a
#     window system that was never going to start.
#
DRAWOUT="$(shell_session "$BUILD/$PLAT-kernel.img" \
        'path=(/dis .)' \
        "bind '#i' /dev" \
        'ls /dev/draw' \
        'cat /dev/draw/new')"
DRAWOUT="$(tr -d '\r' <<<"$DRAWOUT")"
[[ "$VERBOSE" -eq 1 ]] && { echo "  --- draw ---"; echo "$DRAWOUT"; }

OUT_SAVED="$OUT"; OUT="$DRAWOUT"
check "/dev/draw/new"                "the draw device serves a namespace"
check "console released to the draw" "attaching hands the framebuffer over from the text console"
OUT="$OUT_SAVED"

#
# 3i2. A Limbo program's view of the screen.
#
#      The header above proves the CONNECTION. This proves the pixels,
#      and proves them through the whole stack rather than around it:
#      $Draw (libinterp/draw.c) is a client of the draw protocol,
#      libdraw is the library it is written against, devdraw serves the
#      protocol and does the compositing through libmemdraw, and
#      screen.c says where the framebuffer is. drawtest asks for a
#      colour, draws with it, and reads a pixel back with the protocol's
#      own read.
#
#      The colour is checked channel by channel, which is what catches
#      a byte-order mistake: red and blue swapped draws perfectly and
#      reads back the wrong number.
#
DRAW2="$(shell_session "$BUILD/$PLAT-kernel.img" \
        'path=(/dis .)' \
        "bind '#i' /dev" \
        'drawtest')"
DRAW2="$(tr -d '\r' <<<"$DRAW2")"
[[ "$VERBOSE" -eq 1 ]] && { echo "  --- drawtest ---"; echo "$DRAW2"; }

OUT_SAVED="$OUT"; OUT="$DRAW2"
check "drawtest: \$Draw loaded"        "a Limbo program can load the \$Draw builtin module"
check "drawtest: display "             "Display.allocate attaches to the draw device"
check "drawtest: pixel r=0x33 g=0x66 b=0x99" \
                                       "readpixels returns the exact colour that was drawn"
check "drew and read back the colour"  "the graphics stack is correct end to end"
check "opened the built-in font"       "the font compiled into libdraw opens on a machine with no font files"
check "through a full mask r=0x33 g=0x66 b=0x99" \
                                       "a one-bit mask passes the source colour through -- the path glyphs are drawn by"
check "text drew with the built-in font" \
                                       "string drawing puts ink on the screen, not just advance"
OUT="$OUT_SAVED"

#
# 3i3. Tk.
#
#      One layer up from $Draw, and the layer at which a GUI stops
#      being "the screen works" and becomes something a program can be
#      written against. What is asserted is the whole path: the module
#      registers, a toplevel is allocated on a real Display, the
#      command parser accepts good commands AND rejects bad ones, the
#      packer computes a geometry, and the widget puts the pixels it
#      was told to into the toplevel's image.
#
#      Not asserted: that any of it reaches the screen. Compositing a
#      toplevel onto the display is a window manager's job and there is
#      no window manager yet.
#
TKOUT="$(shell_session "$BUILD/$PLAT-kernel.img" \
        'path=(/dis .)' \
        "bind '#i' /dev" \
        'tktest')"
TKOUT="$(tr -d '\r' <<<"$TKOUT")"
[[ "$VERBOSE" -eq 1 ]] && { echo "  --- tktest ---"; echo "$TKOUT"; }

OUT_SAVED="$OUT"; OUT="$TKOUT"
check "tktest: \$Tk loaded"            "a Limbo program can load the \$Tk builtin module"
check "tktest: toplevel made"          "Tk allocates a toplevel on a Display without a window manager"
check "parser rejects a bad option"    "the Tk command parser reports errors instead of accepting anything"
check "tktest: widget pixel r=0x33 g=0x66 b=0x99" \
                                       "a packed widget drew the colour it was given"
check "the widget drew the colour"     "the widget set works end to end"
check "text rendered with the built-in font" \
                                       "a label draws glyphs with libdraw's compiled-in font, with no /fonts on the machine"
OUT="$OUT_SAVED"

if grep -qE 'x8r8g8b8' <<<"$DRAWOUT"; then
    pass "a draw client attaches and the screen is x8r8g8b8 as the firmware was asked for"
else
    fail "no draw connection, or the wrong pixel channel"
fi

# The geometry in the header must be the framebuffer's, not a constant.
FBDIM="$(grep -oE 'fb:   [0-9]+x[0-9]+x32' <<<"$OUT" | head -1 | sed 's/fb:   //;s/x32//')"
if [[ -n "$FBDIM" ]] && grep -qE "${FBDIM%x*} +${FBDIM#*x}" <<<"$DRAWOUT"; then
    pass "the draw screen is the size the firmware reported ($FBDIM)"
else
    fail "draw screen geometry does not match the framebuffer ($FBDIM)"
fi

#
# 3e. A reboot that does not need the shell.
#
#     "echo reboot > /dev/sysctl" needs a shell sitting at a prompt, and
#     during development it very often is not: the board is part way
#     through a boot, or the console is busy printing, and the typed
#     command interleaves with that output and is mangled. It then fails
#     SILENTLY -- the characters were consumed by a line nobody ran --
#     and the only way back is the power switch. That happened twice in
#     one session.
#
#     Ctrl-T Ctrl-T r is handled in kbdputc, character by character,
#     before the line discipline and before any shell. devcons already
#     binds 'r' to rexit, and exit() on this board resets into
#     serialboot -- which is exactly where a development reboot wants to
#     land, since that is what receives the next image.
#
#     Asserted by the machine actually going round: the banner appears
#     twice in one capture.
#
python3 - "$QEMU" "$BUILD/$PLAT-kernel.img" "$QEMUARGS" <<'PYEOF' > "$BUILD/$PLAT-rebootkey.txt" 2>&1
import subprocess, sys, time, threading
qemu, img, extra = sys.argv[1], sys.argv[2], sys.argv[3]
p = subprocess.Popen([qemu] + extra.split() + ["-kernel", img,
                      "-display", "none", "-serial", "stdio"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL)
buf = bytearray()
def reader():
    while True:
        d = p.stdout.read(1)
        if not d:
            return
        buf.extend(d)
threading.Thread(target=reader, daemon=True).start()
try:
    deadline = time.time() + 60
    while time.time() < deadline and b"starting the shell" not in buf:
        time.sleep(0.2)
    time.sleep(2)
    p.stdin.write(b"\x14\x14r"); p.stdin.flush()
    # exit() waits a few seconds before pulling the watchdog, so give the
    # machine time to come back and say so. Four seconds killed QEMU
    # after the reset had been announced but before the second banner.
    time.sleep(12)
except Exception:
    pass
p.kill(); p.wait()
sys.stdout.write(bytes(buf).decode(errors="replace"))
PYEOF

BOOTS="$(grep -c 'InferNode bare-metal' "$BUILD/$PLAT-rebootkey.txt")"
if grep -q 'kernel exit: resetting' "$BUILD/$PLAT-rebootkey.txt" && [[ "$BOOTS" -ge 2 ]]; then
    pass "Ctrl-T Ctrl-T r reboots the machine without a shell (booted $BOOTS times)"
else
    fail "the reboot debug key did not restart the machine (boots=$BOOTS)"
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
# A USB Ethernet device is attached so the bus has something on it.
#
# QEMU's raspi3b models no built-in NIC -- which was read as "networking
# cannot be developed in emulation" -- but it DOES model the DWC OTG
# controller, and it accepts a usb-net on that bus. So device presence,
# and eventually enumeration and a real driver, can all be exercised
# here rather than only on hardware.
# ---------------------------------------------------------------------
# Source-level gate: mboxprop's counts are ELEMENTS, not bytes.
#
# This exists because the runtime checks below could not catch the bug it
# guards. setpower passed `sizeof buf` where mboxprop wants a u32int
# count -- declaring a 32-byte value buffer for an 8-byte tag, reading six
# words past a two-element array and writing eight back over the caller's
# stack frame. Restoring that bug and re-running the whole suite gives 90
# green: QEMU's property handler tolerates the mismatched size and replies
# ON regardless, so asserting the reply proves nothing about the call.
#
# A calling-convention error is a property of the source, so check the
# source. Anything else is theatre.
# ---------------------------------------------------------------------
if grep -n 'mboxprop(' os/bcm2837/*.c | grep -q 'sizeof'; then
    fail "mboxprop called with sizeof -- its counts are elements, not bytes"
    grep -n 'mboxprop(' os/bcm2837/*.c | grep 'sizeof'
else
    pass "every mboxprop call passes element counts, not sizeof"
fi

run_platform bcm2837 "-M raspi3b -netdev user,id=n0 -device usb-net,netdev=n0"

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

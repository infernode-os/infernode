#!/bin/bash
#
# tests/host/baremetal_test.sh
#
# Build the bare-metal AArch64 kernel (os/arm64 + os/bcm2837), boot it
# under QEMU's raspi3b machine, and assert on what it reports over the
# serial console -- and, where the console cannot tell, on what QMP shows
# (framebuffer pixels, USB hotplug) and on what comes back through the
# emulated network (TCP echo, DHCP) and SD card (the install image).
#
# This is also the only supported way to BUILD the kernel; see
# os/bcm2837/README.md "Building" for why. BAREMETAL_BUILD_DIR keeps the
# artefacts (bcm2837-kernel.img is the kernel8.img for a card).
#
# What it covers, in boot order: EL2->EL1 and the exception round trip
# (with an injected fault to prove the panic path reports), the MMU,
# clocks and interrupts, allocators, the scheduler, the namespace and
# devices, the Dis VM and the JIT (bit-identical against the interpreter,
# and faster), the shell, os/ip over the USB Ethernet driver, USB
# keyboard and mouse including hot-plug and unplug, the SD card and
# dossrv, GPIO, #B/bootimage against the file it booted, and this side
# of the tryboot A/B path: the command line reaching the kernel and
# osinit, the boot watchdog's arming write and its "booted" release,
# and "tryboot" on /dev/sysctl resetting the machine.
#
# What it cannot cover, and only the board does: split I/D caches (the
# JIT's icache maintenance), bus vs physical DMA addresses, the LAN78xx
# family (QEMU's usb-net speaks RNDIS), SMP timing, the firmware's side
# of tryboot and the watchdog's countdown (QEMU acknowledges every
# property tag and resets on the arming write; see the tryboot section
# below), the DSI panel, and anything the userspace on a card does
# after osinit (logon, secstored, the desktop). See the README's "Next".
#
# A second machine, QEMU's virt (os/virt), runs after the board: the
# same kernel with virtio devices under it, a shorter list of checks
# (run_virt, at the end), and the one boot here that reaches the
# desktop. BAREMETAL_PLATFORMS=bcm2837 or =virt runs one of them.
#
# Does NOT source common.sh: that resolves $EMU, and nothing here runs
# inside emu. The native limbo IS needed, for runt.h/sysmod.h and the
# Dis modules compiled into the image.
#
# Skips cleanly when the cross toolchain or QEMU is absent, so it is safe
# to run anywhere.
#
# Run from project root: ./tests/host/baremetal_test.sh [-v]
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

echo -e "${BOLD}Bare-metal AArch64 boot tests${NC}"
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
# QMP listens on TCP. Every QEMU this harness talks to through QMP gets a
# port from a per-run base, so two harness runs on one host (a verifier
# beside a build, say) cannot bind the same socket -- or worse, connect
# to each other's QEMU and take the other kernel's answer for their own.
export QMPBASE=$((10000 + $$ % 40000))

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
for mach in raspi3b; do
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
    # EXTRACFLAGS lets an experiment be built without editing this file.
    #
    # Measuring where the network's time goes means building variants --
    # collector off, a different buffer size -- loading each and timing
    # it. Editing the source for every one of those makes it easy to
    # leave a probe behind; a flag from the environment cannot be
    # committed by accident.
    # x28 is the per-core Mach pointer (see os/arm64/dat.h); nothing
    # linked into the kernel may allocate it, including libinterp and
    # the FP conversion helpers.
    local CFLAGS=("${CFLAGS[@]}" -ffixed-x28 $extra ${EXTRACFLAGS:-})
    local IFLAGS=("${IFLAGS[@]}" -ffixed-x28 $extra ${EXTRACFLAGS:-})


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

        # $Keyring's C view, and $IPints' -- the bignum module keyring's
        # public-key paths stand on. Same recipe as every other builtin.
        "$LIMBO" -t Keyring -I"$ROOT/module" "$ROOT/module/runt.m" > "$BUILD/keyringmod.h" 2>>"$BUILD/cc.log" || return 1
        "$LIMBO" -t IPints -I"$ROOT/module" "$ROOT/module/runt.m" > "$BUILD/ipintsmod.h" 2>>"$BUILD/cc.log" || return 1

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

        # The touch panel's frames as pointer events. Under QEMU there is
        # no panel, so what gets exercised is the driver noticing that
        # and its decoder self-test.
        "$LIMBO" -I"$ROOT/module" -o "$BUILD/touch.dis" \
            "$ROOT/os/init/touch.b" 2>>"$BUILD/cc.log" || return 1

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
            "/dis/touch.dis=$BUILD/touch.dis"
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
            # Empty, like /usr: a mount point for the card's artwork.
            # /dis, /lib and /fonts exist because files are compiled
            # into them; /icons has none, so it has to be declared or
            # init has nothing to bind the card's icons over.
            "/icons="
            "/dis/sh.dis=$ROOT/dis/sh.dis"
            "/dis/lib/filepat.dis=$ROOT/dis/lib/filepat.dis"
            "/dis/lib/string.dis=$ROOT/dis/lib/string.dis"
            "/dis/lib/bufio.dis=$ROOT/dis/lib/bufio.dis"
            "/dis/lib/env.dis=$ROOT/dis/lib/env.dis"
            "/dis/lib/arg.dis=$ROOT/dis/lib/arg.dis"

            # The 9P message library: dossrv, mount and memfs speak it,
            # and dossrv is how the card gets mounted at all.
            # (styxservers and nametree were here for etherusb's 9P
            # data path and left with it.)
            "/dis/lib/styx.dis=$ROOT/dis/lib/styx.dis"

            # Where etherusb binds #l/ether0. #I is bound on /net with
            # MBEFORE rather than MREPL precisely so this survives in
            # the union: devip has no "ether0" of its own, and a bind
            # needs its target to exist.
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
            "/mnt/ui="
            "/mnt/llm="
            "/mnt/msg="
            "/tool="
            # acme mounts its own file server at /mnt/acme, and mount(2)
            # does not create its target. Without this the mount failed
            # and fsysmount returned nil WITHOUT a message, so acme drew
            # its background, cleaned up and vanished with nothing on
            # the console to say why.
            "/mnt/acme="
            "/tmp="
            "/usr="

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
            # read, for taking a bounded number of bytes off a serial
            # port: cat would wait for an EOF a UART never sends.
            "/dis/read.dis=$ROOT/dis/read.dis"
            # rm, for removing a file through dossrv and looking at
            # what it left on the card afterwards.
            "/dis/rm.dis=$ROOT/dis/rm.dis"
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
            # unmount is how a namespace is narrowed -- boot-baremetal.sh
            # takes the card and the pins out of the desktop's /dev with
            # it -- and a recovery shell that can bind but not unbind is
            # half a tool.
            "/dis/unmount.dis=$ROOT/dis/unmount.dis"
            # ftest is what boot-baremetal.sh's fail-closed check asks
            # whether the card and the pins are still there with, and
            # the namespace session below types that check verbatim.
            "/dis/ftest.dis=$ROOT/dis/ftest.dis"
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
            # What is NOT in the image: the desktop.
            #
            # wm/wm, the clock, colors, the shell window, acme and the
            # fourteen libraries only they used were compiled in on 27
            # and 28 August, when the kernel could not yet read the card
            # and the image was the only place a program could come
            # from. The card has carried the whole of /dis since 2
            # September, init unions it over the root, and the desktop
            # has been started from it ever since; nothing at boot and
            # no test in this file ever ran the compiled-in copies. They
            # stayed, 389 KB of them, and did harm: the kernel's root is
            # first in that union, so its clock.dis was the one that ran
            # whatever was on the card, and every name the two shared
            # was listed twice (#655).
            #
            # The rule: the image holds what it takes to reach the card
            # and to have a usable console if the card is bad -- init,
            # the FAT server, the USB and Ethernet drivers, the shell and
            # the file utilities -- and what this harness runs. A program
            # that is only ever wanted once the machine is up belongs on
            # the card. Which libraries can go with a program is not a
            # guess: it is the closure of the /dis paths in the compiled
            # files that STAY, and a library outside it is removable.
            #
            "/dis/lib/string.dis=$ROOT/dis/lib/string.dis"

            "/dis/lib/styx.dis=$ROOT/dis/lib/styx.dis"
            "/dis/lib/daytime.dis=$ROOT/dis/lib/daytime.dis"
            "/dis/lib/arg.dis=$ROOT/dis/lib/arg.dis"
            "/dis/lib/bufio.dis=$ROOT/dis/lib/bufio.dis"
            "/dis/lib/env.dis=$ROOT/dis/lib/env.dis"

            # A writable /tmp, which the compiled-in root cannot be: the whole image is read-only, so anything
            # that opens a temporary file fails with a permission
            # error that reads like a bug in the program.
            "/dis/memfs.dis=$ROOT/dis/memfs.dis"
            "/dis/lib/styxlib.dis=$ROOT/dis/lib/styxlib.dis"
            # the exception handler's search, as a Limbo test run in the
            # kernel's own interpreter (#635: a 32-bit NOPC against a
            # 64-bit sentinel resumed Progs at prog - 1 for four days)
            "/dis/lib/testing.dis=$ROOT/dis/lib/testing.dis"
            "/dis/tests/exception_test.dis=$ROOT/dis/tests/exception_test.dis"
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
            "/fonts/vera/Vera/Vera.14.0000=$ROOT/fonts/vera/vera/vera.14.0000"
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
    # $SHARED is a directory of drivers a family of boards has in common
    # -- os/bcm, for the Raspberry Pis: the same silicon blocks at
    # addresses and interrupt numbers each board's io.h supplies. It is
    # upstream's arrangement (os/sa1110 beside os/ipaq1110 and
    # os/cerf1110), and it is compiled per board, with -I"$SRC" first, so
    # that "io.h" in a shared driver is the board's. $SHAREDSKIP names
    # files of it a board does not want.
    local sharedsrc=()
    if [[ -n "${SHARED:-}" ]]; then
        for f in "$SHARED"/*.S "$SHARED"/*.c; do
            [[ -e "$f" ]] || continue
            case " ${SHAREDSKIP:-} " in *" $(basename "$f") "*) continue;; esac
            sharedsrc+=("$f")
        done
    fi
    for f in "$ROOT"/os/arm64/*.S "$ROOT"/os/arm64/*.c "${sharedsrc[@]}" "$SRC"/*.S "$SRC"/*.c; do
        # os/arm64 holds two drivers that are the architecture's but not
        # every board's: gic.c (GICv2) and clockgt.c (the generic timer
        # through a GIC). A board with an interrupt controller of its
        # own names them in $ARCHSKIP.
        if [[ "$f" == "$ROOT"/os/arm64/* ]]; then
            case " ${ARCHSKIP:-} " in *" $(basename "$f") "*) continue;; esac
        fi
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
        # A board says which of os/port it has no hardware for. devaudio.c
        # is the portable half of /dev/audio and calls a dozen functions
        # the board's half supplies; a machine with no audio device has
        # no such half, and the alternative to leaving the file out is a
        # file of stubs that exist to satisfy a linker.
        case " ${PORTSKIP:-} " in *" $(basename "$f") "*) continue;; esac
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
                 -Werror=missing-declarations -Werror=incompatible-pointer-types -Werror=implicit-function-declaration \
                 -c "$f" -o "$o" 2>>"$BUILD/cc.log" || return 1
            objs+=("$o")
            continue
        fi
        "$CC" "${CFLAGS[@]}" -I"$BUILD" -Wno-everything \
             -Werror=missing-declarations -Werror=incompatible-pointer-types -Werror=implicit-function-declaration \
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
             -Werror=missing-declarations -Werror=incompatible-pointer-types -Werror=implicit-function-declaration \
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
    for f in "$ROOT"/libmemdraw/{arc,cmap,defont,ellipse,fillpoly,icossin,icossin2,line,poly,string,subfont,alloc,cload,draw,load,unload}.c \
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
        gpu.c|crypt.c) continue;;
        # ipint.c stays: keyring's public-key paths stand on IPint_*.
        esac
        o="$BUILD/libinterp-$(basename "$f").o"
        "$CC" "${IFLAGS[@]}" -I"$BUILD" -Wno-everything -c "$f" -o "$o" 2>>"$BUILD/cc.log" || return 1
        libobjs+=("$o")
    done

    # The crypto stack $Keyring stands on: bignums, ciphers and digests,
    # and the key I/O helpers. All portable integer C -- the same files
    # the hosted emulator links -- so they take the kernel's own flags,
    # general-regs included. "os.h" is libmp's three-line shim (lib9.h,
    # truerand, nsec; the kernel provides both), reached by putting
    # libmp on the include path for all three. Members land in the
    # archive, so nothing is paid for until keyringmodinit() pulls it.
    for f in "$ROOT"/libmp/*.c "$ROOT"/libsec/*.c "$ROOT"/libkeyring/*.c; do
        [[ -e "$f" ]] || continue
        case "$(basename "$f")" in
        # standalone test programs and demo mains, not library members
        bigtest.c|crttest.c|mtest.c|test.c|egtest.c|hmactest.c|md4test.c|p384ecdhtest.c|rsatest.c|primetest.c) continue;;
        decodepem.c) continue;;		# wants Plan 9 libc.h; PEM is not a kernel concern
        prng.c) continue;;		# host entropy (getentropy/urandom); the kernel's own random.c stands in
        esac
        o="$BUILD/crypto-$(basename "$f").o"
        "$CC" "${CFLAGS[@]}" -I"$ROOT/libmp" -I"$ROOT/libsec" -I"$BUILD" -Wno-everything              -c "$f" -o "$o" 2>>"$BUILD/cc.log" || return 1
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
             -Werror=missing-declarations -Werror=incompatible-pointer-types -Werror=implicit-function-declaration \
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
# The optional third argument is a kernel command line, handed to QEMU
# as -append, which its firmware model returns for the GET_COMMAND_LINE
# property tag exactly as the Pi's firmware returns cmdline.txt. It is
# a separate argument rather than part of $QEMUARGS because that string
# is split on spaces and a command line has spaces in it.
#
# Two -serial arguments, everywhere a QEMU is started here. raspi3b
# hands the first to the PL011 (uart0) and the second to the AUX
# mini-UART (uart1) -- hw/arm/bcm2835_peripherals.c, serial_hd(0) and
# serial_hd(1). The console is on the mini-UART, as on a Pi 3 under
# Plan 9 or Linux, because the PL011 is wired to the radio
# (docs/BLUETOOTH.md); so the PL011 gets null and the console gets
# stdio. A test that wants the PL011 -- /dev/eia0 -- replaces the null.
boot_kernel() {
    local img="$1" secs="${2:-10}" append="${3:-}"
    python3 - "$QEMU" "$img" "$secs" "$QEMUARGS" "$append" "${SERIALARGS:--serial null -serial stdio}" <<'PYEOF'
import subprocess, sys
qemu, img, secs, extra, append = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5]
# Which -serial is the console is the machine's business: raspi3b's is
# its second (above), virt has one UART and it is the first.
args = [qemu] + extra.split() + ["-kernel", img, "-display", "none"] + sys.argv[6].split()
if append:
    args += ["-append", append]
p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
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
    python3 - "$QEMU" "$img" "$QEMUARGS" "${SERIALARGS:--serial null -serial stdio}" "$@" <<'PYEOF'
import os, subprocess, sys, time, threading
qemu, img, extra, serial = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
cmds = sys.argv[5:]
p = subprocess.Popen([qemu] + extra.split() + ["-kernel", img,
                      "-display", "none"] + serial.split(),
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
    # SESSION_DRAIN: how long the last command may take before the
    # session is given up on; the scheduler soak below runs for minutes
    deadline = time.time() + int(os.environ.get("SESSION_DRAIN", "30"))
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

# A shell session with a PEER on the PL011.
#
# The same as shell_session, except that the PL011 -- /dev/eia0, the
# radio's UART on a Pi 3 -- is attached to a host socket instead of
# null, and a thread on this side echoes back every byte it receives,
# keeping a copy. So a command that writes to /dev/eia0 sees its own
# bytes come back through the receive path, and what the peer saw is
# appended to the output as a PL011-PEER-SAW line for the checks. The
# port comes from the per-run QMP base like every other socket here.
pl011_session() {
    local img="$1"; shift
    python3 - "$QEMU" "$img" "$QEMUARGS" "$@" <<'PYEOF'
import subprocess, sys, time, threading, socket, os
qemu, img, extra = sys.argv[1], sys.argv[2], sys.argv[3]
cmds = sys.argv[4:]
PORT = int(os.environ["QMPBASE"]) + 12   # per-run base: two harnesses on one host must not share sockets
p = subprocess.Popen([qemu] + extra.split() + ["-kernel", img,
                      "-display", "none",
                      "-chardev", "socket,id=pl011,host=127.0.0.1,port=%d,server=on,wait=off" % PORT,
                      "-serial", "chardev:pl011", "-serial", "stdio"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL)

seen = bytearray()
def peer():
    s = None
    for _ in range(100):
        try:
            s = socket.create_connection(("127.0.0.1", PORT))
            break
        except OSError:
            time.sleep(0.1)
    if s is None:
        return
    while True:
        try:
            d = s.recv(4096)
        except OSError:
            return
        if not d:
            return
        seen.extend(d)
        s.sendall(d)
threading.Thread(target=peer, daemon=True).start()

buf = bytearray()
def reader():
    while True:
        d = p.stdout.read(1)
        if not d:
            return
        buf.extend(d)
threading.Thread(target=reader, daemon=True).start()

try:
    deadline = time.time() + 120
    while time.time() < deadline:
        if b"init: starting the shell" in buf:
            break
        time.sleep(0.2)
    time.sleep(1.5)
    for c in cmds:
        # "@N command" is given N seconds before the next line is typed,
        # for a command that takes longer than the usual one
        pause = 1.0
        if c.startswith("@"):
            n, c = c[1:].split(" ", 1)
            pause = float(n)
        p.stdin.write(c.encode() + b"\r")
        p.stdin.flush()
        time.sleep(pause)
        # and then until the console has been quiet for half a second (eight
        # at most): the next line is not typed into the middle of this one's
        # output, however slowly the host is running the machine
        quiet = time.time(); last = len(buf); limit = time.time() + 8
        while time.time() - quiet < 0.5 and time.time() < limit:
            time.sleep(0.1)
            if len(buf) != last:
                last = len(buf); quiet = time.time()
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
sys.stdout.write("\nPL011-PEER-SAW: " + bytes(seen).decode(errors="replace") + "\n")
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
# A 64MB card image: an MBR, one FAT16 partition at sector 2048, and
# HELLO.TXT in its root. A function because both machines boot it --
# the board's through its SD controller model, virt's as a virtio disk.
make_sd_image() {
python3 - "$1" <<'PYEOF'
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
# "sd: no card in the slot" and reads like a driver fault.
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
}

# The compiler flags for $SRC. A function because there are two
# platforms and each sets them the same way; called by run_platform and
# run_virt once $SRC is known.
platform_flags() {
# Rebuilt per platform rather than once at the top: -I"$SRC" is what
# selects which os/<plat> supplies mem.h, io.h and board.h to the shared
# os/arm64 and os/port sources, and $SRC is not known until here.
IFLAGS=(--target=aarch64-elf -ffreestanding -nostdlib -DINFERNO_NATIVE
        -O2 -fno-omit-frame-pointer -I"$SRC" -I"$ROOT/os/arm64" -I"$ROOT/os/port" -I"$ROOT/os/ip" -I"$ROOT/Inferno/arm64/include"
        -I"$ROOT/include" -I"$ROOT/libkern" -I"$ROOT/libinterp")

# The two escalations the os/port and os/ip loops below apply are applied to
# the platform files too: an anonymous "QLock;" member in a NEW driver
# (audiopwm.c, 2026-09-18) declared nothing, qlock() took the Rendez at
# offset 0, and the first open of /dev/audio was a data abort. The
# warning was in cc.log all along; this makes it the build's business.
CFLAGS=(--target=aarch64-elf -ffreestanding -nostdlib -mgeneral-regs-only
        -O2 -fno-omit-frame-pointer -Wall -Wextra
        -Werror=missing-declarations -Werror=incompatible-pointer-types -Werror=implicit-function-declaration -I"$SRC" -I"$ROOT/os/arm64" -I"$ROOT/os/port" -I"$ROOT/os/ip" -I"$ROOT/Inferno/arm64/include" -I"$ROOT/libinterp"
        -I"$ROOT/include" -I"$ROOT/libkern")
}

run_platform() {
PLAT="$1"
SRC="$ROOT/os/$PLAT"
QEMUARGS="$2"
# Set outright, every one, by every platform's function: these are
# globals, the platforms run one after another in one shell, and a value
# left over from the last machine is a kernel built from the wrong files.
SHARED="$ROOT/os/bcm"
SHAREDSKIP=""
ARCHSKIP="gic.c clockgt.c"	# the BCM2837 has its own controller: os/bcm2837/intr.c, clock.c
PORTSKIP="ethermii.c pci.c usbxhci.c usbxhcipci.c"	# a PHY library, a bus and what is on it: this board has none
SERIALARGS="-serial null -serial stdio"

[[ -d "$SRC" ]] || { echo "ERROR: $SRC not found" >&2; exit 1; }

platform_flags

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
KIMG="$BUILD/$PLAT-kernel.img"
kimgsz=$(wc -c < "$KIMG" | tr -d ' ')
check "init: /dev/bootimage $kimgsz bytes stat $kimgsz sha1 $(shasum "$KIMG" | cut -c1-40)" \
    "/dev/bootimage reproduces the image the loader was given, byte for byte"
check "init: gpio 21 out 1->1 0->0; pin 14: in use by uart" "GPIO pins are files: an output reads back what was written, the console pin refuses"

# The boot watchdog's two ends on a boot that does not arm it.
#
# Only a boot whose command line says "tryboot" (or "bootwatchdog") is
# put under the watchdog; this boot has no -append, so the kernel must
# say it read an empty command line and chose not to arm -- and osinit
# must still write "booted", because the release line is how the
# handshake is known to reach the board hook at all. The PM registers
# are printed so that a wrong PMREGS base would show as garbage here
# rather than as a watchdog write that lands nowhere. 0x1000 and 0x102
# are the reset values QEMU's model reports; the board reports the
# reset cause.
check "boot: command line: (empty)"  "the kernel reads the firmware command line through the mailbox"
check "pm:   rsts 0x0000000000001000 rstc 0x0000000000000102" "the PM block reads back at PMREGS (QEMU's reset values)"
check "wdog: not armed (not a tryboot candidate)" "a boot the command line does not mark is not put under the watchdog"
check "init: bootargs: (none)"        "#B/bootargs serves the command line to osinit"
check "wdog: boot complete; no watchdog was armed" "osinit's booted on /dev/sysctl reaches the board hook"
check "vectors:         installed"    "installs VBAR_EL1"
check "save/restore OK"               "exception save/dispatch/restore round trips"
check "boot OK"                       "completes boot without faulting"

# SMP. Until these lines nothing here asserted that the secondaries came
# up at all, let alone that they keep time: the kernel claimed in two
# comments that cores 1-3 ticked and preempted, and for months neither
# was true -- each secondary's clock interrupt walked an empty Timer
# queue and returned. The three checks below are the three claims.
#
# "cpuN: up" is squidboy's ack, printed after the core has its vectors,
# MMU and clock. "cpuN: did not answer" is launchsmp giving up on a core.
# The refutation is anchored to launchsmp's exact form because osinit
# has a "did not answer" of its own -- "init: port N did not answer;
# resetting it again", from reresetport() -- and that one is a device
# failing to enumerate on the first try, which its own comment says is
# routine on this board. A bare "did not answer" would fail an SMP check
# for a USB retry.
check "cpu1: up"                      "core 1 answers the release and enters its scheduler"
check "cpu2: up"                      "core 2 answers the release and enters its scheduler"
check "cpu3: up"                      "core 3 answers the release and enters its scheduler"
refute "cpu[0-9]*: did not answer"    "no secondary core failed to answer the release"
# osinit reads /dev/sysstat twice, 200ms apart, and counts the cores
# whose tick count moved. A core with a live interrupt and a dead
# hzclock shows here as "3 of 4".
check "init: clock ticks on 4 of 4 cores" \
                                      "every core's clock advances (hzclock runs on cpu1-3, read back through /dev/sysstat)"
# smpcheck (main.c) wires a spinning kproc to each secondary, then a
# second kproc to the same core, and times how long the second waits to
# run there. Preemption makes that a tick or two; without it the probe
# waits for the hog to finish, 250ms, and the line says BROKEN.
check "smp:  preempt cpu1 [0-9]*us cpu2 [0-9]*us cpu3 [0-9]*us OK" \
                                      "a kproc wired to a busy secondary is preempted onto it within the tick budget"

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
# func=2 is ALT5 in GPFSEL's encoding: the mini-UART on the header pins.
# It read 4 (ALT0, the PL011) until the console moved (docs/BLUETOOTH.md).
    check "gpio: pin14 func=2 pin15 func=2 (ALT5/mini-UART as set) OK" "GPIO pin-mux readback matches what the console UART set"
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
# The reply comes back too, now; the race that once ate it is under
# "Networking works, intermittently (RESOLVED)" in os/bcm2837/README.md.
check "etherusb: serving /net/ether0"          "the driver publishes a netif file interface"
# The kernel data path specifically. The endpoints are exclusive-open,
# so this line only appears if etherusb's "fd = nil" actually closed
# them before #l tried to take them -- the "init: fd:" destructor
# checks after the JIT section, exercised on a real device rather than
# a pipe. It used to be reached only through a sys->dup of #c/null
# over the descriptors.
check "etherusb: serving /net/ether0 (kernel data path)" "the endpoints are free for #l when etherusb drops its fds, with no dup workaround"
check "10.0.2.15 mask 255.255.255.0 on ipifc"       "os/ip binds an interface to a driver outside the kernel"
check "default route via 10.0.2.2"             "a default route is installed"

# The DHCP client's reader lives exactly as long as the exchange. It is
# parked in a read the kernel returns from only when a datagram arrives,
# so it used to outlive its caller for the life of the machine, holding
# port 68's conversation open. The client now kills it and says whether
# it went. Under QEMU the exchange ends in the fallback, which is the
# path that matters: a client that gets no answer is the one that used
# to leave its reader behind.
check "etherusb: dhcp reader [0-9]* exited"    "the DHCP reader is reaped when the exchange is over"
refute "dhcp reader [0-9]* still running"      "no DHCP reader outlives its exchange"

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

# The radio driver (os/bcm/ether4330.c) probes at board init, after
# sdmmc.c has moved the card off the Arasan. QEMU's raspi3b has no
# CYW43455 and hangs no SDIO function on the Arasan, so the one outcome
# it can prove is the absent-radio path: the probe answers CMD5 twice,
# gets nothing, and says so in one line. That the shell line above was
# reached at all is the proof the probe did not hang the boot on
# hardware that never answers -- a bounded wait, exercised.
check "ether4330: no radio"             "the radio probe reports an absent radio in one line under QEMU, and the boot went on to a shell"
check "init: radio: ether4330: no radio" "osinit's attempt to name the firmware files is refused with the driver's words, and init carries on"
refute "init: radio: firmware loaded"   "nothing claims a firmware load under emulation"

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
        '/dis/tests/exception_test.dis' \
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
        'cat /dev/sysstat' \
        'for(i in x y z){ echo loop2-$i }' \
        "ls '#G/gpio/128' '#G/gpio/135'" \
        "ls '#G/gpio/136'" \
        "cat '#G/gpio/128/level'" \
        "echo 1 > '#G/gpio/128/level'" \
        "cat '#G/gpio/128/level'" \
        "echo 0 > '#G/gpio/129/level'" \
        "echo function out > '#G/gpio/128/ctl'" \
        "cat '#G/gpio/129/ctl'")"

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

# The exception handler's search, in the kernel's own interpreter: an
# exception block whose clauses do not match and has no wildcard is not
# a handler (#635). exception_test.dis raises across two such blocks to
# the one that names the exception, four ways; "4 passed" is the whole
# verdict, and "misaligned PC" anywhere in the session is the old bug.
if grep -q "^4 passed" <<<"$SHOUT" && ! grep -q "misaligned PC" <<<"$SHOUT"; then
    pass "exception_test: an unmatched exception block is not a handler (4 passed; #635)"
else
    fail "exception_test did not report 4 passed (or a misaligned PC appeared): $(grep -E 'passed|FAIL|misaligned|Broken' <<<"$SHOUT" | head -3 | tr '\n' ' ')"
fi

# The per-core clock is readable from the shell, not only asserted at
# boot: one line per core that came up, and the fourth core's line is
# the one that proves the file is not merely core 0 talking about itself.
if grep -q "^cpu3 ticks [0-9][0-9]* intrs [0-9][0-9]* timers [0-9][0-9]*$" <<<"$SHOUT"; then
    pass "/dev/sysstat reports every core's ticks, interrupts and timer callbacks"
else
    fail "/dev/sysstat did not show a line for cpu3"
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
#
# tryboot and the boot watchdog, this side of the firmware.
#
# The A/B path is: install the running kernel as tryboot.img, write
# "tryboot" to /dev/sysctl, and the firmware boots the [tryboot]
# section of config.txt exactly once -- a different kernel file and a
# command line carrying the word "tryboot". That word is what makes the
# kernel arm the boot watchdog in kmain and osinit print the promotion
# step; "booted" on /dev/sysctl releases the watchdog once the shell is
# loaded. See os/bcm/board.c and the README's "Working on the board
# without moving the card".
#
# What QEMU can and cannot show here is settled by two facts about its
# model, both read in the source (hw/misc/bcm2835_powermgt.c and
# bcm2835_property.c, v8.2) and confirmed by the boots below:
#
#   - PM_WDOG is stored and never counted down, and a write to PM_RSTC
#     with the full-reset WRCFG resets the machine on the spot. So a
#     candidate boot under QEMU prints "wdog: armed" and is reset by
#     the arming write itself, and boots again, for ever. That is
#     asserted below as at least two boot banners in eight seconds. It
#     proves the write reached the PM block with the right password
#     and bits -- a wrong password is dropped without a reset -- and
#     nothing about the countdown or the reload from the clock tick,
#     which only the board can show (README: "wdogtest").
#
#   - The property mailbox sets the response bit on every tag, known
#     or not, so "firmware acknowledged reboot flags" is what the
#     message round trip looks like and not the firmware's opinion.
#
# Because arming under QEMU is a reset, the candidate boot that runs
# to the shell -- osinit recognising the word, printing the promotion
# step, and writing "booted" -- is driven with "nowatchdog" on the same
# command line, which is the word a kernel under a debugger uses. A
# variant image that skips the release and must reset at the budget
# would be the natural third check; it is not here because the model
# has no budget to reach, and a check that cannot fail is not one.
# For the same reason nothing here exercises the reload -- the tick's
# or microdelay's poll for the interrupts-masked half of kmain -- nor
# the unreadable-command-line arming: -append is short, and QEMU
# answers GET_COMMAND_LINE. Those are board results (README).
#
WDOUT="$(boot_kernel "$BUILD/$PLAT-kernel.img" 8 tryboot)"
OUT_SAVED="$OUT"; OUT="$WDOUT"
check "boot: command line: tryboot"  "-append reaches the kernel as the firmware command line"
check "wdog: armed, 90 s boot budget; a hang resets to config.txt's kernel" \
      "a candidate boot arms the boot watchdog before the MMU is on"
nboot="$(grep -c 'InferNode bare-metal' <<<"$WDOUT")"
if [[ "$nboot" -ge 2 ]]; then
    pass "the arming write reached the PM block with the password and WRCFG bits (QEMU resets on it: $nboot boots in 8s)"
else
    fail "the arming write did not reset QEMU's PM model ($nboot boot banner(s) in 8s)"
fi
OUT="$OUT_SAVED"

# 45 seconds: the shell is loaded at about 12s under emulation, and the
# release line follows it directly; the rest is margin for a busy host.
CANDOUT="$(boot_kernel "$BUILD/$PLAT-kernel.img" 45 "tryboot nowatchdog")"
OUT_SAVED="$OUT"; OUT="$CANDOUT"
check "wdog: not armed (nowatchdog on the command line)" "nowatchdog overrides a candidate's arming"
check "init: bootargs: tryboot nowatchdog" "osinit reads the command line through #B/bootargs"
check "init: CANDIDATE kernel: this boot came from the tryboot configuration" "osinit recognises a candidate boot"
check "init: to keep it:     mv /n/dos/tryboot.img /n/dos/infernode8.img" "osinit prints the promotion step, from a candidate name"
check "wdog: boot complete; no watchdog was armed" "the candidate's booted handshake reaches the board hook"
OUT="$OUT_SAVED"

# "tryboot" typed at the shell. The reset is asserted the only way a
# reset can be from outside: the boot banner appears a second time.
# shell_session waits up to 30s for a drain marker the reset machine
# never echoes, which is what gives the second boot time to print.
#
# Honest accounting: of these three, only the middle one is new with
# the mailbox handshake. The first line and the reset were already
# there when boardtryboot set a PM_RSTS bit -- notyet.c's print and
# the PM_RSTC full reset predate the change -- so those two PIN the
# path from /dev/sysctl to the PM block against regression rather than
# test the fix; and the middle one shows only that the tag message was
# well formed, since QEMU acknowledges every tag. Nothing QEMU prints
# distinguishes the SET_REBOOT_FLAGS tag from the old PM_RSTS write,
# and this block does not pretend otherwise.
TBOUT="$(shell_session "$BUILD/$PLAT-kernel.img" 'echo tryboot > /dev/sysctl')"
TBOUT="$(tr -d '\r' <<<"$TBOUT")"
OUT_SAVED="$OUT"; OUT="$TBOUT"
check "tryboot: resetting; next boot is the CANDIDATE kernel" \
      "tryboot on /dev/sysctl reaches the board's reset path (pre-existing path, pinned)"
check "tryboot: firmware acknowledged reboot flags 0x1 (tryboot)" \
      "the reboot-flags tag round-trips the mailbox (the firmware's real answer is a board result)"
nboot="$(grep -c 'InferNode bare-metal' <<<"$TBOUT")"
if [[ "$nboot" -ge 2 ]]; then
    pass "tryboot reset the machine: it booted again ($nboot banners; pre-existing reset, pinned)"
else
    fail "tryboot did not reset the machine ($nboot boot banner(s))"
fi
OUT="$OUT_SAVED"

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

# Destructors run in compiled code. The opcode classes above compute
# the right ANSWERS; this is about what compiled code does when it
# drops a reference. comp-arm64.c's macfrp() used to branch on the nil
# check's flags and never reach rdestroy, so "fd = nil" closed nothing
# and every dropped fd waited for the collector -- the reason etherusb
# once needed a sys->dup of #c/null to free its endpoints for #l.
# osinit drops a pipe's write end two ways (assignment, and a local
# going out of scope with its frame) and reads the other end; EOF
# within two seconds means the destructor ran at the drop. The main
# boot runs with the JIT on, so these lines come from compiled code.
check "init: fd: dropped fd closed its pipe"           "compiled code runs the FD destructor when the last reference is assigned away"
check "init: fd: fd dropped on return closed its pipe" "compiled code runs the FD destructor when a frame holding the last reference returns"

check "pool: smprint/strdup OK"       "libkern allocator-dependent entry points work"

check "libk: mem/str OK"              "libkern mem/str primitives work"
check "snprint OK"                    "Plan 9 fmt engine formats correctly under LP64"

check "arch: _tas OK"                 "_tas implements test-and-set"
check "spl OK"                        "spl returns the previous level rather than assuming"

check "clk:  cntfrq [0-9]"            "generic timer reports a frequency"
    check "clocks AGREE"              "generic timer agrees with the 1MHz system timer"
check "clk:  irq firing"              "timer interrupts are delivered"

    check "fb:   [0-9]"               "framebuffer allocated"

    # The touch panel: QEMU implements neither firmware tag, so the
    # kernel must say there is no panel (and say what the firmware
    # answered), refuse to serve /dev/touch, and the driver must notice
    # the file is absent and exit -- rather than any of them inventing
    # a panel. The driver's line carries the %r suffix, hence the colon.
    check "touch: no panel ("          "the kernel reports no touch panel, with the firmware's answer"
    check "touch: no panel: "          "the touch driver finds /dev/touch absent and exits"
    refute "touch: buffer at"          "nothing claims a touch buffer under emulation"
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
PORT = int(os.environ["QMPBASE"]) + 0   # per-run base: two harnesses on one host must not share QEMU's QMP sockets
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
    f = s.makefile("rw")
    f.readline()
    f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush(); f.readline()

    # Dump the screen until the console has drawn a page or 25 s have
    # passed. A fixed delay here was the harness's own flake: under a
    # loaded host the same kernel had drawn one line at the 3 s mark
    # and a page a few seconds later, and the check read the one line
    # as "nothing legible".
    BG = (0x10, 0x10, 0x18)
    FG = (0xC8, 0xC8, 0xC8)
    w = h = nbg = nfg = 0
    rows = set()
    deadline = time.time() + 25
    while True:
        time.sleep(1)
        if os.path.exists(ppm):
            os.unlink(ppm)
        f.write(json.dumps({"execute": "screendump",
                            "arguments": {"filename": ppm}}) + "\n"); f.flush()
        f.readline()
        if os.path.exists(ppm):
            d = open(ppm, "rb").read()
            parts = d.split(b"\n", 3)
            if parts[0] == b"P6":
                w, h = map(int, parts[1].split()); px = parts[3]
                nbg = nfg = 0
                rows = set()
                for y in range(h):
                    for x in range(0, w, 2):        # every other column is plenty
                        o = (y*w + x)*3
                        c = tuple(px[o:o+3])
                        if c == BG:
                            nbg += 1
                        elif c == FG:
                            nfg += 1
                            rows.add(y)
                if nfg >= 500 and len(rows) >= 32:
                    break
        if time.time() > deadline:
            break
    s.close()
finally:
    p.kill(); p.communicate()

if not os.path.exists(ppm):
    print("SKIP no screendump"); sys.exit(0)
if w == 0:
    print("SKIP not a P6 ppm"); sys.exit(0)

# The console has taken the screen, so the boot test pattern is gone --
# correctly: a console clears what was there. What replaces the pattern
# check proves strictly more.
#
# Background colour still proves CHANNEL ORDER on its own: 0x101018 is
# asymmetric across the three channels, so a swap reads 0x181010 and is
# caught. Glyph pixels prove the font rendered and that pitch and base
# put it where it belongs -- which the pattern also proved, except that
# a console exercises far more of the path to get there.
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
# 3a'. The firmware GPIO expander as pins 128..135 of #G.
#
#     The radios' power enables and the Ethernet chip's reset are on a
#     GPIO expander the firmware drives over I2C; they are pins in the
#     same directory, with the same two files, numbered as the firmware
#     numbers them. 128 is BT_ON and belongs to a program (bt9p); 129
#     is WL_ON and belongs to ether4330, which claims it, so it reads
#     but refuses writes -- the same refusal the console pins make.
#     QEMU accepts the set tag and answers no get, so a level reads "?"
#     until something is written and the last write afterwards; on a
#     board the firmware answers and the "?" never appears.
#
if grep -A4 "ls '#G/gpio/128' '#G/gpio/135'" <<<"$SHOUT" | grep -q '#G/gpio/135/level'; then
    pass "expander lines are pins 128..135 in #G/gpio, each with ctl and level"
else
    fail "#G/gpio/128 and 135 did not list as pin directories"
fi
if grep -A1 "ls '#G/gpio/136'" <<<"$SHOUT" | grep -q 'does not exist\|file does not exist\|not found'; then
    pass "the expander stops at 135: #G/gpio/136 does not exist"
else
    fail "#G/gpio/136 should not exist"
fi
if grep -A1 "^; cat '#G/gpio/128/level'" <<<"$SHOUT" | head -2 | grep -q '^?$'; then
    pass "an expander level the firmware will not report and nothing has written reads as ?"
else
    fail "#G/gpio/128/level did not read ? before the first write under QEMU"
fi
if grep -A1 "^; cat '#G/gpio/128/level'" <<<"$SHOUT" | tail -1 | grep -q '^1$'; then
    pass "writing 1 to #G/gpio/128/level (BT_ON) goes to the firmware and reads back"
else
    fail "#G/gpio/128/level did not read 1 after the write"
fi
if grep -A1 "echo 0 > '#G/gpio/129/level'" <<<"$SHOUT" | grep -q 'in use by ether4330'; then
    pass "#G/gpio/129 (WL_ON) is claimed by ether4330: the radio's power cannot be pulled from under its driver"
else
    fail "a write to #G/gpio/129/level was not refused as ether4330's"
fi
if grep -A1 "echo function out > '#G/gpio/128/ctl'" <<<"$SHOUT" | grep -q 'no function select'; then
    pass "an expander line's ctl refuses function/pull truthfully: the hardware has neither"
else
    fail "#G/gpio/128/ctl did not refuse a function write"
fi
if grep -A2 "^; cat '#G/gpio/129/ctl'" <<<"$SHOUT" | grep -q '^function \(unknown\|out\|in\)$'; then
    pass "an expander line's ctl reads its configuration as the firmware reports it (or unknown, under QEMU)"
else
    fail "#G/gpio/129/ctl did not read as a function/pull report"
fi

#
# 3b. Serial ports as files: #t, and the console that now comes in
#     through it.
#
#     eia1 is the mini-UART the shell above was typed at; this session
#     was typed at it too, byte by byte through the receive interrupt
#     rather than the 10ms poll it replaced. eia0 is the PL011, which
#     on a Pi 3 is wired to the radio and here to a socket with an echo
#     peer on it (pl011_session), so a write comes back as a read.
#
#     The port is held open by a background sleep for the duration:
#     #t enables a UART on its first open and disables it on its last
#     close, and a receiver disabled between two shell commands would
#     lose the peer's echo in the gap. That is not a bug to work around
#     -- a program that owns the port keeps it open -- it is how the
#     test has to hold the port to stand in for one.
#
#     The long echo is the burst check. The old polled console lost
#     everything past the 16-byte FIFO of anything a script sent at it
#     (AGENTS.md); QEMU's chardev never overran it, so this cannot fail
#     here for that reason, but it pins the interrupt path taking a
#     whole line, and it is the assertion to run on the board.
#
LONGLINE="burst-0123456789abcdefghijklmnopqrstuvwxyz-0123456789abcdefghijklmnopqrstuvwxyz-0123456789abcdefghijklmnopqrstuvwxyz-0123456789abcdefghijklmnopqrstuvwxyz-end"
PLOUT="$(pl011_session "$BUILD/$PLAT-kernel.img" \
        "bind -a '#t' /dev" \
        'ls /dev/eia0 /dev/eia0ctl /dev/eia0status /dev/eia1 /dev/eia1ctl /dev/eia1status' \
        'cat /dev/eia1status' \
        'cat /dev/eia0status' \
        'sleep 120 <> /dev/eia0 &' \
        'sleep 1' \
        'echo b921600 > /dev/eia0ctl' \
        'echo m1 > /dev/eia0ctl' \
        'cat /dev/eia0status' \
        'echo zzz > /dev/eia0ctl' \
        '@7 echo -n PL011-LOOPBACK-42 > /dev/eia0; sleep 3; echo; {for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 {read 1}} < /dev/eia0; echo' \
        '@7 echo -n second-frame > /dev/eia0; sleep 3; echo; {for i in 1 2 3 4 5 6 7 8 9 10 11 12 {read 1}} < /dev/eia0; echo' \
        'cat /dev/eia0status' \
        "echo $LONGLINE" \
        'echo 0 > /dev/jit; /dis/echo.dis JIT-TO-INTERP-HANDOFF-OK; echo 1 > /dev/jit')"
PLOUT="$(tr -d '\r' <<<"$PLOUT")"
[[ "$VERBOSE" -eq 1 ]] && { echo "  --- #t session ---"; echo "$PLOUT"; }

OUT_SAVED="$OUT"; OUT="$PLOUT"
check "/dev/eia1status"                 "#t binds at /dev: eia0 (PL011) and eia1 (mini-UART) with ctl and status files"
# The three status lines asserted here differ from one another (r1; r0;
# b921600 m1), so each is looked for wherever it is. They used to be
# required on the line after the command that asked for them, and on a
# busy host the next command's echo can get there first.
if grep -q '^b115200 c0 d0 e0 l8 m0 pn r1 s1' <<<"$PLOUT"; then
    pass "eia1status describes the console: 115200 8n1, no flow control"
else
    fail "eia1status did not read back as the console's settings"
fi
if grep -q '^b115200 c0 d0 e0 l8 m0 pn r0 s1' <<<"$PLOUT"; then
    pass "eia0status reads before the port is ever opened: 115200 8n1, nothing asserted"
else
    fail "eia0status did not read back sensibly before the first open"
fi
check "clock(default)"                  "the PL011 disbelieved QEMU's 3MHz UART clock and used the firmware default (48MHz)"
if grep -q '^b921600 c0 d0 e0 l8 m1 pn r1 s1' <<<"$PLOUT"; then
    pass "eia0ctl took b921600 and m1: baud and hardware flow control are set through the file"
else
    fail "eia0ctl's b921600/m1 did not show in eia0status"
fi
check "bad arg"                         "an unknown ctl verb is refused with an error, not swallowed"
# Each round trip is ONE command line: write, wait for the echo to be
# back and staged, print a newline, read, print a newline. It used to be
# a write typed at one second and a read typed at the next, which left
# two things to the pace of whatever machine ran it. The reply might
# not be back when the read began, and the read's output might land in
# the middle of the next line being typed rather than at column 0. On
# a CI runner it did: every byte made the trip (rx(29) tx(29), and the
# peer saw both frames) and the check still failed, with the second
# frame staged and never read -- staged(29) read(17) qlen(12).
#
# And each frame is read by COUNT, a byte at a time (read 1, as many
# times as the frame is long: dd is not in the image), not with one read.
# A read of the device returns one staging pass's worth, which is what
# a serial line owes its reader and no more; on a busy host the echo
# comes back in pieces (a transcript under load: "PL011-LOOPBACK", then
# "-42" to the read that was meant for the second frame), and "one read
# is one frame" was the test's assumption, never the driver's promise.
if grep -q '^PL011-LOOPBACK-42' <<<"$PLOUT"; then
    pass "bytes written to /dev/eia0 came back through the PL011's receive interrupt"
else
    fail "the loopback through /dev/eia0 did not return PL011-LOOPBACK-42"
fi
if grep -q '^second-frame' <<<"$PLOUT"; then
    pass "a second write/read round trip on the still-open port"
else
    fail "the second /dev/eia0 round trip did not return"
fi
if grep 'PL011-PEER-SAW' <<<"$PLOUT" | grep -q 'PL011-LOOPBACK-42second-frame'; then
    pass "the peer on the PL011 saw exactly the bytes written, in order, with nothing between"
else
    fail "the PL011 peer did not see PL011-LOOPBACK-42 then second-frame back to back"
fi
# The status file's third and fourth lines count the bytes at each hop:
# interrupt handler, staging into the queue, out to readers. After two
# round trips of 17 and 12 bytes all three must say 29, and so must tx.
# On the board these are what told a reply eaten by another reader from
# a reply that never came; here they prove the counters count.
if grep -q 'intrs([1-9][0-9]*) rx(29) tx(29)' <<<"$PLOUT" && grep -q 'staged(29) read(29)' <<<"$PLOUT"; then
    pass "eia0status counts the bytes at every hop: 29 in through the interrupt, 29 staged, 29 read, 29 out"
else
    fail "eia0status byte counters did not all read 29 after the two round trips: $(grep -o 'intrs.*' <<<"$PLOUT" | tail -1; grep -o 'staged.*' <<<"$PLOUT" | tail -1)"
fi
if [[ "$(grep -c "$LONGLINE" <<<"$PLOUT")" -ge 2 ]]; then
    pass "a ${#LONGLINE}-byte line typed at the console arrived intact through the receive interrupt (echo and output)"
else
    fail "the long line typed at the console did not come back whole (got $(grep -c "$LONGLINE" <<<"$PLOUT") copies, wanted 2)"
fi
# The JIT switched off at run time, then a module loaded interpreted and
# called from the still-compiled shell. The arm64 JIT branched into that
# module's bytecode as if it were code: a kernel panic on the board, found
# by the benchmark's interpreter runs (#687). The kernel must print the
# module's line, not reset.
if [[ "$(grep -c '^JIT-TO-INTERP-HANDOFF-OK' <<<"$PLOUT")" -ge 1 ]]; then
    pass "a compiled module calls an interpreted one: the JIT hands off to the interpreter instead of branching into bytecode (#687)"
else
    fail "no output from an interpreted module called after 'echo 0 > /dev/jit' (#687: the kernel panicked here before the fix)"
fi
OUT="$OUT_SAVED"

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
#     Detaching a device twice.
#
#     osinit writes "detach" once when a hub port empties. devusb's
#     CMdetach runs a release loop that drops the file system's one
#     reference to each endpoint, and a second pass through it drops
#     references the open files hold, freeing endpoints under their
#     owners. Two writers that arrive TOGETHER both used to run it; the
#     transition to Ddetach is now made under epslck so only one does.
#
#     This check does not reach that race, and is not claimed to: two
#     writes typed one after the other are serial, and the second is
#     turned away by ctlwrite's pre-existing Ddetach check before epctl
#     is called -- so this passes on the unfixed kernel too. What it
#     pins is the contract the fix depends on, which nothing else
#     asserted: a detach written at the shell reaches the driver, which
#     exits once; a second write down the SAME open fd (typed as one
#     block, so it reaches the device rather than a path that has gone)
#     is refused with the device's own error and not "i/o error"; and
#     the shell still answers. The compare-and-set itself is verified
#     by inspection only -- there is one assignment of Ddetach in the
#     tree, and epslck is taken in process context with no other lock
#     held. The keyboard is the victim because it is the device the
#     machine can spare.
#
#     The sleep first is not padding. The prompt appears while the hub
#     walk is still powering ports, and a detach typed then reaches a
#     device the driver has not yet opened: the endpoint is freed under
#     kbdusb's own open, which is a different failure from the one this
#     is written to catch. Fifteen seconds is what the keyboard boot
#     check above allows the driver, with margin.
#
KBDEP="$(grep -oE 'kbdusb: ep[0-9]+\.0 ready' <<<"$KBDOUT" | head -1 | sed 's/kbdusb: //;s/ ready//')"
if [[ -n "$KBDEP" ]]; then
    SAVEDARGS="$QEMUARGS"
    QEMUARGS="$QEMUARGS -device usb-kbd"
    # Wait for the keyboard's endpoint to exist rather than for a
    # fixed fifteen seconds: enumeration is a bus walk plus a 1 Hz hub
    # poll plus the driver's start, and on a loaded host it has taken
    # longer than the guess, at which point the detach went to a file
    # that was not there yet and the check blamed the driver.
    DETOUT="$(shell_session "$BUILD/$PLAT-kernel.img" \
            'path=(/dis .)' \
            'load std' \
            "while {! ftest -e /usb/usb/$KBDEP/ctl} {sleep 1}" \
            'sleep 3' \
            "{echo detach; echo detach} > /usb/usb/$KBDEP/ctl" \
            'echo detach-twice-survived' \
            "cat /usb/usb/$KBDEP/ctl")"
    QEMUARGS="$SAVEDARGS"
    DETOUT="$(tr -d '\r' <<<"$DETOUT")"
    [[ "$VERBOSE" -eq 1 ]] && { echo "  --- double detach ---"; echo "$DETOUT"; }
    if grep -q "kbdusb: $KBDEP detached" <<<"$DETOUT"; then
        pass "detach written at the shell detaches the keyboard and its driver exits"
    else
        fail "the first detach of $KBDEP did not reach the driver"
    fi
    # Refused with the device's own error, not "i/o error": that would
    # mean the endpoint had been freed between the two writes, i.e.
    # nobody -- not even the driver -- still held it.
    if grep -q 'echo: write error: device is detached' <<<"$DETOUT" \
       && grep -v 'echo ' <<<"$DETOUT" | grep -q 'detach-twice-survived' \
       && ! grep -qi 'panic' <<<"$DETOUT"; then
        pass "a second detach of the same device is refused and the machine carries on"
    else
        fail "the second detach of $KBDEP was not refused cleanly"
    fi
else
    skip "double detach (no keyboard endpoint name in the keyboard boot)"
fi

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
import subprocess, socket, json, time, sys, threading, os
qemu, img, extra = sys.argv[1], sys.argv[2], sys.argv[3]
PORT = int(os.environ["QMPBASE"]) + 2   # per-run base: two harnesses on one host must not share QEMU's QMP sockets
p = subprocess.Popen([qemu] + extra.split() + ["-device", "usb-kbd",
                     "-kernel", img, "-display", "none", "-serial", "null", "-serial", "stdio",
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
import subprocess, socket, json, time, sys, threading, os
qemu, img, extra = sys.argv[1], sys.argv[2], sys.argv[3]
PORT = int(os.environ["QMPBASE"]) + 4   # per-run base: two harnesses on one host must not share QEMU's QMP sockets
p = subprocess.Popen([qemu] + extra.split() + ["-device", "usb-mouse",
                     "-kernel", img, "-display", "none", "-serial", "null", "-serial", "stdio",
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
#     QEMU's raspi3b models both of the SoC's SD controllers -- the
#     BCM2835 SDHOST the card now lives on and the Arasan it used to --
#     and the GPIO mux that decides which one the card is wired to, and
#     takes a card image. So the whole driver can be exercised here
#     rather than against the one card on the one board, which matters
#     more than usual for this device: the only card a real Pi has is
#     the one holding the firmware and the loader that put this kernel
#     in memory.
#
#     The image is built with a known partition table, so the assertion
#     is on VALUES rather than on plausibility. An initialised
#     controller that reads the wrong sector, or treats a byte-addressed
#     card as block-addressed, comes up perfectly and returns data --
#     just not this data.
#
SDIMG="$BUILD/$PLAT-sd.img"
make_sd_image "$SDIMG"

#     Boot with a card, wait for the driver's verdict on it, and then
#     ask QEMU which controller the card is on.
#
#     The serial output alone cannot prove the card moved. A driver
#     that prints "sdhost" and then quietly keeps talking to the Arasan
#     -- because the mux write was wrong, or never happened -- passes
#     every text check in this section, since the card works either
#     way. QEMU's device tree is the one witness that cannot be talked
#     round: its GPIO model reparents the sd-card device from the SDHCI
#     bus to the SDHOST bus only when all six pins read ALT0, so
#     "info qtree" over QMP says which bus the card is actually on.
#     The answer comes back as a QTREE-SDCARD-BUS line after the
#     serial output.
#
sd_boot() {
    local img="$1" sdimg="$2" port="$3"
    python3 - "$QEMU" "$img" "$QEMUARGS" "$sdimg" "$port" <<'PYEOF'
import subprocess, socket, json, time, sys, threading
qemu, img, extra, sd, port = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
p = subprocess.Popen([qemu] + extra.split() + ["-kernel", img,
                     "-drive", "file=%s,if=sd,format=raw" % sd,
                     "-display", "none", "-serial", "null", "-serial", "stdio",
                     "-qmp", f"tcp:127.0.0.1:{port},server=on,wait=off"],
                     stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL)
buf = bytearray()
def reader():
    while True:
        d = p.stdout.read(1)
        if not d:
            return
        buf.extend(d)
threading.Thread(target=reader, daemon=True).start()
qtree = None
try:
    s = None
    deadline = time.time() + 20
    while time.time() < deadline and s is None:
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=1)
        except OSError:
            time.sleep(0.3)

    # The mux is written by the driver, so the tree is only worth
    # reading once the driver has finished with the card -- one way or
    # the other.
    deadline = time.time() + 40
    while time.time() < deadline and not any(k in buf for k in
            (b"sd: MBR ok", b"sd: no card", b"sd: cannot read",
             b"sd: sector 0 has no boot signature")):
        time.sleep(0.2)
    time.sleep(1)

    if s is not None:
        f = s.makefile("rw")
        f.readline()
        f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush(); f.readline()
        f.write(json.dumps({"execute": "human-monitor-command",
                            "arguments": {"command-line": "info qtree"}}) + "\n")
        f.flush()
        qtree = json.loads(f.readline()).get("return", "")
        s.close()
    time.sleep(3)                      # let init name the partitions
finally:
    p.kill(); p.wait()

sys.stdout.write(bytes(buf).decode("utf-8", "replace"))

# In qtree's indented listing every bus prints "bus: <name>" then
# "type <bus type>" and then its devices, so the last type seen before
# "dev: sd-card" is the bus the card sits on.
bus = "absent"
if qtree is None:
    bus = "no-qmp"
else:
    seen = "unknown"
    for line in qtree.splitlines():
        t = line.strip()
        if t.startswith("type "):
            seen = t[5:].strip()
        elif t.startswith("dev: sd-card"):
            bus = seen
            break
print("\nQTREE-SDCARD-BUS: " + bus)
PYEOF
}

SAVEDARGS="$QEMUARGS"
SDOUT="$(sd_boot "$BUILD/$PLAT-kernel.img" "$SDIMG" $((QMPBASE+8)))"
[[ "$VERBOSE" -eq 1 ]] && { echo "  --- sd ---"; grep 'sd\|gpio: pin48\|QTREE' <<<"$SDOUT"; }

OUT_SAVED="$OUT"; OUT="$SDOUT"
check "sd: sdhost: card ready"      "the SDHOST controller initialises a card"
# The capacity is the raw-layout proof. SDHOST stores a 136-bit response
# with bits 127:96 in RSP3 where the Arasan stores 127:104, and a CSD
# parsed in the wrong layout does not fail: it reports a wrong size and
# reads wrong sectors. The fixture is 64MB, so the driver must say so.
check "sd: sdhost: card ready, standard capacity (byte addressed), 64 MB" \
                                    "the CSD is decoded in the raw response layout: the 64MB fixture reads as 64MB"
check "gpio: pin48 func=4 pin49 func=4 pin50 func=4 pin51 func=4 pin52 func=4 pin53 func=4" \
                                    "GPIO 48-53 read back ALT0: the card's pins are muxed to SDHOST"
check "sd: MBR ok"                  "sector 0 reads back with a valid boot signature"
check "start 2048 sectors 65536"    "the partition table holds the values the image was built with"
refute "sd: cannot read"            "no read failed"
refute "^sdhost: "                  "the SDHOST driver reported no fault"
refute "QTREE-SDCARD-BUS: sdhci-bus" "the card is not still on the Arasan's bus"
OUT="$OUT_SAVED"

if grep -q 'QTREE-SDCARD-BUS: bcm2835-sdhost-bus' <<<"$SDOUT"; then
    pass "QEMU's device tree shows the sd-card under bcm2835-sdhost-bus"
elif grep -q 'QTREE-SDCARD-BUS: no-qmp' <<<"$SDOUT"; then
    skip "no QMP connection, so the card's bus could not be read from QEMU"
else
    fail "the card is not on the SDHOST bus ($(grep -o 'QTREE-SDCARD-BUS: .*' <<<"$SDOUT"))"
fi

#
#     A filesystem, end to end.
#
#     This is the check that ties the whole stack together and the only
#     one that would catch most of it breaking: the SDHOST driver reads
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
        'cat /n/dos/RW.TXT' \
        'cat '\''#l1/ether1/addr'\''' \
        'cat '\''#l/ether0/addr'\''')"
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

# The second Ethernet instance, from the shell. Walking "#l1" attaches
# ether1, which runs the radio driver's attach in the shell's own
# process; with no radio present it refuses with the driver's own
# words, and cat reports them. That the message is "ether4330: no
# radio" and not "no such device" is the proof devether selected
# instance 1 and handed the attach to the driver rather than to
# instance 0. "#l" in the same session still attaches ether0 and reads
# its addr without that error, so the second instance did not disturb
# the first -- and every etherusb/ether0 check in the network section
# above passed unchanged in this same run.
if grep -q "cannot open.*#l1/ether1/addr.*ether4330: no radio" <<<"$FSOUT"; then
    pass "#l1 attaches the radio driver, which refuses cleanly with 'ether4330: no radio' when no radio is present"
else
    fail "#l1 did not report the absent radio (no 'cat: cannot open #l1/ether1/addr: ether4330: no radio' from the shell)"
fi
if grep -q 'cannot open .#l/ether0/addr' <<<"$FSOUT"; then
    fail "reading #l/ether0/addr errored: the second instance disturbed ether0"
else
    pass "#l/ether0 still attaches and reads in the same session: ether0 is unchanged"
fi

#
#     The desktop's namespace can be narrowed, and the console's is not.
#
#     Every process on this machine is the host owner, so the only thing
#     between a desktop program and the raw card is what its namespace
#     does not contain. lib/lucifer/boot-baremetal.sh builds that
#     namespace before it starts logon: forks it, unmounts #S and #G
#     from /dev, binds /dev/null over /dev/sysctl and /dev/hostowner,
#     and refuses the desktop if any of them is still there. This types
#     those lines -- read out of the script here, not copied into this
#     file, so that the two cannot drift apart and deleting them from
#     the script turns these checks red -- into a child shell, and
#     asserts both halves: inside, the card, the pins and sysctl are
#     gone and the script's own check says so; back outside, the
#     console shell still has every one of them. Both halves matter. A
#     narrowing that leaked into the parent would take the management
#     plane's card away, and pass a test that only looked inside.
#
#     What this does NOT run is the script: it needs the card userspace
#     (wm/logon, luciuisrv, lucifer) this kernel image does not carry.
#     The $status handling and the retry loop below the narrowing are
#     exercised on the hosted emulator against child shells, not here.
#
#     "echo halt > /dev/sysctl" inside is the check that means it: were
#     /dev/sysctl still #c's, the machine would stop there and nothing
#     after it would print. The marker lines are echoed on their own so
#     the extraction below can tell the command being typed (which
#     carries the marker word too) from its output.
#
#     The outer probe lists the pin's DIRECTORY, /dev/gpio/21, whose
#     listing names both files; a stat of the leaf itself is a separate
#     check further down, because until devgpio's gen answered for a
#     leaf that stat failed on every kernel, narrowed or not, and a
#     namespace check that trips over it says nothing about namespaces.
#
#     The card image is the FAT16 one, attached so that #S has a card
#     to bind and /dev/sdcard is there to take away.
#
BOOTSH="$ROOT/lib/lucifer/boot-baremetal.sh"
NARROW=()
while IFS= read -r l; do NARROW+=("$l"); done \
    < <(sed -n '/^pctl forkns$/,/^bind \/dev\/null \/dev\/hostowner$/p' "$BOOTSH")
# The check block, from narrowed=1 to the close of the if that refuses
# the desktop. Leading tabs are dropped: the shell does not need them
# and the serial line discipline should not be asked about them here.
NARROWCHK=()
while IFS= read -r l; do NARROWCHK+=("$l"); done \
    < <(sed -n '/^narrowed=1$/,/^}$/p' "$BOOTSH" | sed 's/^[[:space:]]*//')

if [[ ${#NARROW[@]} -ge 5 && "${NARROW[0]}" == 'pctl forkns' ]] \
   && printf '%s\n' "${NARROW[@]}" | grep -q "^unmount '#S' /dev$" \
   && printf '%s\n' "${NARROW[@]}" | grep -q "^unmount '#G' /dev$" \
   && printf '%s\n' "${NARROW[@]}" | grep -q '^bind /dev/null /dev/sysctl$' \
   && [[ ${#NARROWCHK[@]} -ge 6 && "${NARROWCHK[0]}" == 'narrowed=1' ]] \
   && printf '%s\n' "${NARROWCHK[@]}" | grep -q '^exit$'; then
    pass "boot-baremetal.sh carries the narrowing (forkns, unmount #S #G, null over sysctl) and a fail-closed check after it"
else
    fail "could not read the narrowing or its check out of boot-baremetal.sh (${#NARROW[@]} and ${#NARROWCHK[@]} lines)"
fi

QEMUARGS="$SAVEDARGS -drive file=$SDIMG,if=sd,format=raw"
NSOUT="$(shell_session "$BUILD/$PLAT-kernel.img" \
        'path=(/dis .)' \
        'load std' \
        'sh' \
        'load std' \
        "${NARROW[@]}" \
        "${NARROWCHK[@]}" \
        'echo INNER' \
        'echo narrowed $narrowed' \
        'ls /dev/sdcard /dev/sdctl /dev/gpio' \
        'v=`{cat /dev/sysctl}; echo inner-sysctl-words $#v' \
        'echo halt > /dev/sysctl' \
        'echo inner-still-alive' \
        'echo INNER-END' \
        'exit' \
        'echo OUTER' \
        'ls /dev/sdcard /dev/sdctl /dev/gpio/21' \
        'v=`{cat /dev/sysctl}; echo outer-sysctl-words $#v' \
        'echo OUTER-END' \
        'echo LEAF' \
        'ls /dev/gpio/21/level' \
        'echo LEAF-END')"
QEMUARGS="$SAVEDARGS"
# The prompt is "; " with no newline. A command that takes longer than
# the typing interval -- the first `{cat ...} in a fresh child shell
# does, it loads cat -- lets the lines typed after it echo as
# type-ahead, and the prompts for those lines are then printed just
# before the output that was waited for, as a prefix on it: the first
# run of this session saw "; ; inner-still-alive" and "; LEAF", and two
# checks that the transcript itself showed passing went red on the
# anchored match. So leading prompt fragments are stripped before any
# line is matched. An output line never begins with "; ".
NSOUT="$(tr -d '\r' <<<"$NSOUT" | sed 's/^\(; \)*//')"
[[ "$VERBOSE" -eq 1 ]] && { echo "  --- namespace ---"; echo "$NSOUT"; }

# Only whole-line markers delimit the sections: the typed command line
# carries "echo INNER" and is not a match for ^INNER$.
NSIN="$(sed -n '/^INNER$/,/^INNER-END$/p' <<<"$NSOUT")"
NSOUTER="$(sed -n '/^OUTER$/,/^OUTER-END$/p' <<<"$NSOUT")"
NSLEAF="$(sed -n '/^LEAF$/,/^LEAF-END$/p' <<<"$NSOUT")"

if grep -q 'INNER-END' <<<"$NSIN" && grep -q 'OUTER-END' <<<"$NSOUTER"; then
    pass "a child shell forks its namespace, narrows it, exits, and the console shell comes back"
else
    fail "the narrowed-namespace session did not run to both markers"
fi

if grep -q '^narrowed 1$' <<<"$NSIN"; then
    pass "boot-baremetal.sh's own fail-closed check (ftest on the card and the pins, an empty sysctl) passes in the narrowed namespace"
else
    fail "the script's narrowed= check did not come out 1 in the narrowed namespace (or its exit fired)"
fi

if grep -q "/dev/sdcard.*does not exist" <<<"$NSIN" \
   && grep -q "/dev/sdctl.*does not exist" <<<"$NSIN"; then
    pass "unmount '#S' /dev takes the raw card and its partition table out of the namespace"
else
    fail "/dev/sdcard or /dev/sdctl is still reachable after unmount '#S' /dev"
fi

if grep -q "/dev/gpio.*does not exist" <<<"$NSIN"; then
    pass "unmount '#G' /dev takes the pins out of the namespace"
else
    fail "/dev/gpio is still reachable after unmount '#G' /dev"
fi

if grep -q '^inner-sysctl-words 0$' <<<"$NSIN"; then
    pass "bind /dev/null /dev/sysctl: sysctl reads empty in the narrowed namespace"
else
    fail "/dev/sysctl still reads the kernel's version line after bind /dev/null over it"
fi

if grep -q '^inner-still-alive$' <<<"$NSIN"; then
    pass "'echo halt > /dev/sysctl' in the narrowed namespace does not halt the machine"
else
    fail "the machine did not answer after a halt written to the narrowed /dev/sysctl"
fi

if grep -q '^/dev/sdcard$' <<<"$NSOUTER" && grep -q '^/dev/sdctl$' <<<"$NSOUTER" \
   && grep -q '^/dev/gpio/21/ctl$' <<<"$NSOUTER" && grep -q '^/dev/gpio/21/level$' <<<"$NSOUTER"; then
    pass "the console shell still has /dev/sdcard, /dev/sdctl and the pins after the child narrowed its own"
else
    fail "the narrowing leaked into the console shell's namespace (card or pins missing outside)"
fi

if grep -q '^outer-sysctl-words [1-9]' <<<"$NSOUTER"; then
    pass "the console shell's /dev/sysctl is still the kernel's"
else
    fail "the console shell's /dev/sysctl reads empty: the null bind leaked out of the child"
fi

#
#     A GPIO leaf file can be stat'ed. devgpio's gen used to answer -1
#     for every s >= 0 when called on /dev/gpio/N/ctl or /level, so
#     devstat printed "devstat G <qid>" and raised "file does not
#     exist" for a file the directory listing showed and reads worked
#     on -- ls on the leaf, and ftest -e, were the ways to see it.
#
if grep -q '^/dev/gpio/21/level$' <<<"$NSLEAF" \
   && ! grep -q 'devstat G\|does not exist' <<<"$NSLEAF"; then
    pass "stat of a GPIO leaf file (/dev/gpio/21/level) succeeds"
else
    fail "stat of /dev/gpio/21/level failed: devgpio's gen does not answer for a leaf"
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
        'cat /n/dos/HELLO32.TXT' \
        'echo cluster-owner > /n/dos/badent-1' \
        'ls -l /n/dos' \
        'rm /n/dos/badent-1' \
        'ls /n/dos')"
QEMUARGS="$SAVEDARGS"
FS32="$(tr -d '\r' <<<"$FS32")"
[[ "$VERBOSE" -eq 1 ]] && { echo "  --- fat32 ---"; echo "$FS32"; }

if grep -q 'fat32 works on bare metal' <<<"$FS32"; then
    pass "a FAT32 filesystem is mounted and read (the Pi boot partition's format)"
else
    fail "FAT32 could not be read"
fi

#
#     A healthy file that merely LOOKS like a damage alias.
#
#     dossrv names an entry it cannot present -- control characters, a
#     slash, an empty name -- badent-<location>, and rm on that alias
#     zaps the directory entry alone, deliberately leaving the clusters
#     (the start-cluster word of a damaged entry is not to be trusted).
#     The test for "is this the damaged case" used to be a prefix match
#     on the name handed OUT, so a healthy file someone had called
#     badent-1 took the same path: gone from the directory, its cluster
#     chain still allocated and reachable from nowhere.
#
#     The check is made from outside, on the image the guest wrote,
#     the way fsck would: every allocated cluster must be reachable
#     from the root directory. The deleted entry has to be there too,
#     or a session that never created the file passes for free.
#
python3 - "$SD32" <<'PYEOF' > "$BUILD/$PLAT-badent.txt" 2>&1
import struct, sys
img = open(sys.argv[1], "rb").read()
SEC = 512
pstart = struct.unpack_from("<I", img, 446 + 8)[0]
bs = img[pstart*SEC : pstart*SEC + SEC]
spc = bs[13]
resv = struct.unpack_from("<H", bs, 14)[0]
nfat = bs[16]
fatsz = struct.unpack_from("<I", bs, 36)[0]
rootclus = struct.unpack_from("<I", bs, 44)[0]
fatoff = (pstart + resv) * SEC
data = (pstart + resv + nfat*fatsz) * SEC
nclus = fatsz * SEC // 4

def fat(n):
    return struct.unpack_from("<I", img, fatoff + 4*n)[0] & 0x0FFFFFFF

def chain(n):
    out = []
    while 2 <= n < 0x0FFFFFF8 and n not in out and len(out) < nclus:
        out.append(n)
        n = fat(n)
    return out

def cluster(n):
    off = data + (n-2)*spc*SEC
    return img[off : off + spc*SEC]

reachable = set()
deleted = 0
def walk(start, depth):
    global deleted
    ch = chain(start)
    reachable.update(ch)
    for c in ch:
        b = cluster(c)
        for o in range(0, len(b), 32):
            e = b[o:o+32]
            if e[0] == 0:
                return
            if e[0] == 0xE5:
                if e[1:6] == b"ADENT":
                    deleted += 1
                continue
            if e[11] & 0x08:                 # long-name piece or volume label
                continue
            if e[0:1] == b".":
                continue
            if e[0:6] == b"BADENT":
                print("LIVE-BADENT")
            st = (struct.unpack_from("<H", e, 20)[0] << 16) | struct.unpack_from("<H", e, 26)[0]
            if st >= 2:
                if e[11] & 0x10 and depth < 8:
                    walk(st, depth + 1)
                else:
                    reachable.update(chain(st))

walk(rootclus, 0)
allocated = {n for n in range(2, nclus) if fat(n) != 0}
lost = sorted(allocated - reachable)
print("DELETED-BADENT" if deleted else "NO-DELETED-BADENT")
print("LOST %d %s" % (len(lost), lost[:8]))
PYEOF
BADOUT="$(cat "$BUILD/$PLAT-badent.txt")"
[[ "$VERBOSE" -eq 1 ]] && { echo "  --- badent ---"; echo "$BADOUT"; }
if grep -q 'DELETED-BADENT' <<<"$BADOUT" && ! grep -q 'LIVE-BADENT' <<<"$BADOUT"; then
    pass "a file named badent-1 is created and removed through dossrv"
else
    fail "the badent-1 fixture was not created and removed ($(tr '\n' ' ' <<<"$BADOUT"))"
fi
if grep -q '^LOST 0 ' <<<"$BADOUT"; then
    pass "removing a healthy file that is merely named badent-* frees its clusters"
else
    fail "clusters left allocated and unreachable after rm ($(grep '^LOST' <<<"$BADOUT"))"
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
                     "-display", "none", "-serial", "null", "-serial", "stdio"],
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
#     -DSDWRITETEST, against a scratch image, and is not in the kernel
#     that goes to hardware.
#
if build_kernel "$BUILD/$PLAT-sdwrite.img" "" "-DSDWRITETEST"; then
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
#     The same card through the Arasan, in a kernel built only for this.
#
#     The card left the Arasan so that the WiFi chip can have it, and
#     the Arasan backend stayed in the tree so that the old path is
#     still there to bisect against: a card that reads on one
#     controller and not the other is a controller fault, and one that
#     reads on neither is the card layer's. This boot keeps that path
#     honest, and it is also the negative case for the bus check above
#     -- the SAME question to QEMU must give the OTHER answer, or the
#     check is not telling the controllers apart.
#
if build_kernel "$BUILD/$PLAT-sdarasan.img" "" "-DSDCARD_ARASAN"; then
    SDAOUT="$(sd_boot "$BUILD/$PLAT-sdarasan.img" "$SDIMG" $((QMPBASE+10)))"
    [[ "$VERBOSE" -eq 1 ]] && { echo "  --- sd (arasan) ---"; grep 'sd\|gpio: pin48\|QTREE' <<<"$SDAOUT"; }
    OUT_SAVED="$OUT"; OUT="$SDAOUT"
    check "sd: emmc: card ready, standard capacity (byte addressed), 64 MB" \
                                    "-DSDCARD_ARASAN: the Arasan path identifies the card, its responses normalised to the raw layout"
    check "sd: MBR ok"              "-DSDCARD_ARASAN: sector 0 reads back with a valid boot signature"
    check "start 2048 sectors 65536" "-DSDCARD_ARASAN: the partition table holds the values the image was built with"
    refute "sd: cannot read"        "-DSDCARD_ARASAN: no read failed"
    check "ether4330: the Arasan holds the card" \
                                    "-DSDCARD_ARASAN: the radio is not probed because the card owns the Arasan"
    OUT="$OUT_SAVED"
    if grep -q 'QTREE-SDCARD-BUS: sdhci-bus' <<<"$SDAOUT"; then
        pass "-DSDCARD_ARASAN: QEMU shows the sd-card under sdhci-bus, so the bus check tells the controllers apart"
    elif grep -q 'QTREE-SDCARD-BUS: no-qmp' <<<"$SDAOUT"; then
        skip "no QMP connection, so the Arasan variant's bus could not be read from QEMU"
    else
        fail "-DSDCARD_ARASAN: the card is not on the Arasan's bus ($(grep -o 'QTREE-SDCARD-BUS: .*' <<<"$SDAOUT"))"
    fi
else
    fail "the -DSDCARD_ARASAN kernel failed to build"
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
import subprocess, socket, json, time, sys, threading, os
qemu, img, extra = sys.argv[1], sys.argv[2], sys.argv[3]
PORT = int(os.environ["QMPBASE"]) + 6   # per-run base: two harnesses on one host must not share QEMU's QMP sockets
p = subprocess.Popen([qemu] + extra.split() + ["-kernel", img,
                     "-display", "none", "-serial", "null", "-serial", "stdio",
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
    mid = bytes(buf)

    # Pull it out again: the watcher must say so, devusb must detach
    # it so the driver exits at once rather than after a run of
    # timeouts, and the endpoints must come back.
    f.write(json.dumps({"execute": "device_del",
        "arguments": {"id": "hotkbd"}}) + "\n")
    f.flush(); f.readline()
    time.sleep(8)
    gone = bytes(buf)

    # And plug it back in: enumerated and claimed a second time.
    f.write(json.dumps({"execute": "device_add",
        "arguments": {"driver": "usb-kbd", "id": "hotkbd2"}}) + "\n")
    f.flush(); f.readline()
    time.sleep(15)
    kbdback = bytes(buf)

    # The Ethernet. QEMU cannot unplug it: device_del of a usb-net with
    # a transfer in flight trips an assertion in QEMU's USB core
    # (usb_ep_get: dev != NULL) and QEMU dies. What a detached device
    # does to the kernel data path -- the reader's transfer fails and
    # it unbinds -- is the same release the unbind verb performs, so
    # ask for that from the guest's console, then run the driver again
    # for the same device: it must bind again, unbind the interface
    # the first run left on /net/ether0, and configure an address.
    # The driver's first run must have finished -- its last act is a
    # ping to 8.8.8.8 -- or it still holds the device's endpoints and
    # the second run cannot open them.
    deadline = time.time() + 150
    while time.time() < deadline and b"8.8.8.8" not in buf:
        time.sleep(0.5)
    time.sleep(8)
    p.stdin.write(b"echo unbind > '#l/ether0/clone'\r"); p.stdin.flush()
    time.sleep(6)
    ethgone = bytes(buf)
    p.stdin.write(b"etherusb ep3.0\r"); p.stdin.flush()
    # DHCP takes its full ~45s of retries before the fallback address
    # is configured; wait for the address line rather than a guess.
    deadline = time.time() + 150
    while time.time() < deadline and b"on ipifc" not in buf[len(ethgone):]:
        time.sleep(0.5)
    time.sleep(3)
    s.close()
finally:
    p.kill(); p.wait()

after = bytes(buf)
print("BEFORE-CLEAN" if b"kbdusb:" not in before else "BEFORE-DIRTY")
tail = mid[len(before):]
print("ATTACH-SEEN" if b"device attached" in tail else "ATTACH-MISSED")
print("CLAIMED" if b"kbdusb:" in tail and b"ready on endpoint" in tail else "NOT-CLAIMED")
t2 = gone[len(mid):]
print("REMOVE-SEEN" if b"device removed" in t2 else "REMOVE-MISSED")
print("DRIVER-EXITED" if b"detached" in t2 else "DRIVER-STUCK")
t3 = kbdback[len(gone):]
print("RECLAIMED" if b"kbdusb:" in t3 and b"ready on endpoint" in t3 else "NOT-RECLAIMED")
t4 = ethgone[len(kbdback):]
print("ETH-UNBOUND" if b"kernel data path unbound" in t4 else "ETH-STUCK")
print("ETH-PROCS-EXITED" if b"reader exits" in t4 and b"writer exits" in t4 else "ETH-PROCS-STUCK")
t5 = after[len(ethgone):]
print("ETH-REBOUND" if b"kernel data path bound" in t5 else "ETH-NOT-REBOUND")
print("ETH-STALE-CLEARED" if b"unbound stale interface" in t5 else "ETH-STALE-LEFT")
print("ETH-READDRESSED" if b"on ipifc" in t5 else "ETH-NO-ADDRESS")
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
    if grep -q 'REMOVE-SEEN' <<<"$HOTOUT"; then
        pass "the hub watcher notices a device being unplugged"
    else
        fail "unplugging a device went unnoticed"
    fi
    if grep -q 'DRIVER-EXITED' <<<"$HOTOUT"; then
        pass "the unplugged device is detached in devusb and its driver exits at once"
    else
        fail "the driver of an unplugged device did not exit"
    fi
    if grep -q 'RECLAIMED' <<<"$HOTOUT"; then
        pass "a device plugged back in is enumerated and claimed again"
    else
        fail "the replugged device was not claimed again"
    fi
    if grep -q 'ETH-UNBOUND' <<<"$HOTOUT"; then
        pass "the kernel Ethernet data path can be released (what a detached device causes)"
    else
        fail "the kernel Ethernet data path would not let go"
    fi
    if grep -q 'ETH-PROCS-EXITED' <<<"$HOTOUT"; then
        pass "both kernel data-path processes leave when the path is released"
    else
        fail "a kernel data-path process stayed behind after the release"
    fi
    if grep -q 'ETH-REBOUND' <<<"$HOTOUT"; then
        pass "the Ethernet driver run again binds the kernel data path again"
    else
        fail "the Ethernet could not be bound a second time"
    fi
    if grep -q 'ETH-STALE-CLEARED' <<<"$HOTOUT"; then
        pass "the interface the first run left on /net/ether0 is unbound before a new one is made"
    else
        fail "a stale IP interface was left bound to /net/ether0"
    fi
    if grep -q 'ETH-READDRESSED' <<<"$HOTOUT"; then
        pass "the Ethernet run again gets an address again"
    else
        fail "the Ethernet run again was never configured"
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
# 3i2b. The touch decoder, without a panel.
#
#      QEMU has no panel to offer, so this is the one part of the touch
#      path an emulator can check: the driver's decoder and clamp,
#      against bytes laid out the way the firmware lays them out.
#
TOUCH2="$(shell_session "$BUILD/$PLAT-kernel.img" \
        'path=(/dis .)' \
        'touch -t' \
        'ls /dev/touch')"
TOUCH2="$(tr -d '\r' <<<"$TOUCH2")"
[[ "$VERBOSE" -eq 1 ]] && { echo "  --- touch ---"; echo "$TOUCH2"; }

OUT_SAVED="$OUT"; OUT="$TOUCH2"
check "touch: selftest OK"            "the touch decoder reads the FT5406 layout and clamps to the panel"
check "/dev/touch.*does not exist"     "/dev/touch is absent under emulation, not present and broken"
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
                      "-display", "none", "-serial", "null", "-serial", "stdio"],
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

/* main.c normally defines these; the variant replaces main.c.
 * m is not defined here: since the SMP work it is the x28 register
 * (dat.h), and l.S points it at machs[0] before kmain runs.  up is a
 * macro over it for the same reason.  The secondary-core plumbing
 * (machs, smpboot, squidboy) is referenced from l.S even though this
 * variant never releases a secondary, so stub it. */
Conf conf;
Mach machs[MAXMACH];
struct Active active;
uintptr dtbptr;		/* l.S stores it; see os/arm64/fns.h */

typedef struct Smpboot Smpboot;
struct Smpboot { uvlong sp; uvlong mach; uvlong entry; };
Smpboot smpboot[MAXMACH];
void squidboy(void) { for(;;) __asm__ volatile("wfe"); }
void idlewake(void) { }
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

#
# 3j. The radio's file interface, with no radio underneath it.
#
#     WHAT THIS CAN AND CANNOT PROVE. QEMU's raspi3b has no CYW43455
#     and no SDIO function device of any kind, so nothing here says
#     anything about frames, scanning or joining a network -- those
#     are board work and the README says so. What it does say is that
#     the file interface exists and behaves: the verbs are known, the
#     arguments are parsed and refused before anything is changed, the
#     refusals name the driver, and a verb that is NOT in the table is
#     still rejected. That last one is the control: if the switch were
#     empty, every check below except it would pass on the same
#     "unknown control message" the kernel already gave.
#
#     It needs a kernel built with -DETHER4330STUB, which declares the
#     radio present without probing for it and does nothing else. With
#     a real probe the attach refuses (that check is in the filesystem
#     section above, and is the one that proves devether selects
#     instance 1) and the whole tree beneath #l1 is unreachable, so
#     the alternative to this variant is not a weaker test -- it is no
#     test of the interface at all.
#
#     Nothing here greps the boot log for a string the boot log would
#     have carried anyway. Every message asserted below is produced by
#     a write this session made, and is attributed to that write by the
#     marker printed immediately before it.
#
if build_kernel "$BUILD/$PLAT-wifi.img" "" "-DETHER4330STUB"; then
    WOUT="$(shell_session "$BUILD/$PLAT-wifi.img" \
        'bind -a '\''#l1'\'' /net' \
        'cat /net/ether1/ifstats' \
        'cat /net/ether1/clone' \
        'echo WIFI1; echo essid mynet > /net/ether1/0/ctl' \
        'echo WIFI2; echo scanbs 5 > /net/ether1/0/ctl' \
        'echo WIFI3; echo crypt wep > /net/ether1/0/ctl' \
        'echo WIFI4; echo txkey zz ccmp:000102030405060708090a0b0c0d0e0f@0 > /net/ether1/0/ctl' \
        'echo WIFI5; echo txkey b827eb9f19db ccmp:000102030405060708090a0b0c0d0e0f@0 > /net/ether1/0/ctl' \
        'echo WIFI6; echo auth 3014 > /net/ether1/0/ctl' \
        'echo WIFI7; echo channel 99 > /net/ether1/0/ctl' \
        'echo WIFI8; echo wibble 1 > /net/ether1/0/ctl' \
        'echo WIFI9; cat /net/ether1/ifstats')"
    WOUT="$(tr -d '\r' <<<"$WOUT")"
    [[ "$VERBOSE" -eq 1 ]] && { echo "  --- radio ctl ---"; echo "$WOUT"; }

    # The text a session produced between one marker and the next.
    wifiseg() {
        awk -v a="$1" -v b="$2" \
            'index($0,a){f=1} f&&index($0,b){exit} f' <<<"$WOUT"
    }
    wifisays() {   # marker-from, marker-to, expected text, description
        if grep -q -- "$3" <<<"$(wifiseg "$1" "$2")"; then
            pass "$4"
        else
            fail "$4 (no '$3' between $1 and $2)"
        fi
    }

    #
    # The interface is reachable and reports itself. "radio: present"
    # is the variant's doing; every other line is the driver's.
    #
    OUT_SAVED="$OUT"; OUT="$WOUT"
    check "radio: present"      "-DETHER4330STUB: #l1 attaches and ifstats is readable"
    check "firmware: not loaded" "ifstats says the firmware has not been loaded"
    check "status: unassociated" "ifstats carries the status line a supplicant polls"
    check "crypt: off"          "ifstats reports no encryption configured"
    check "channel: 0"          "ifstats reports the channel a join would use"
    check "bssid: 000000000000" "ifstats reports no station joined"
    check "scan: 0"             "ifstats reports no scan interval set"
    check "txwin: 0"            "ifstats reports the firmware's transmit credit"
    check "txseq: 0"            "ifstats reports the transmit sequence"
    check "oq: 0"               "ifstats reports the output queue length"
    OUT="$OUT_SAVED"

    wifisays WIFI1 WIFI2 "ether4330: firmware not loaded" \
        "'essid' is a known verb and is refused for want of a firmware"
    wifisays WIFI2 WIFI3 "ether4330: firmware not loaded" \
        "'scanbs' reaches the driver through netif and is refused the same way"
    wifisays WIFI3 WIFI4 "ether4330: firmware not loaded" \
        "'crypt' is refused for want of a firmware"
    wifisays WIFI4 WIFI5 "bad ether addr" \
        "'txkey' with a malformed station address is refused on the ARGUMENT, radio or no radio"
    wifisays WIFI5 WIFI6 "ether4330: firmware not loaded" \
        "'txkey' with a well-formed address gets as far as needing a firmware"
    wifisays WIFI6 WIFI7 "bad wpa ie syntax" \
        "'auth' with an information element whose length field disagrees is refused"
    wifisays WIFI7 WIFI8 "bad channel number" \
        "'channel 99' is refused: the argument is checked, not accepted and stored"
    wifisays WIFI8 WIFI9 "unknown control message" \
        "a verb that is not in the table is still rejected -- the control that makes the eight above mean something"

    #
    # And nothing above changed the interface. A verb refused for want
    # of a firmware must not leave the driver describing a state it
    # was never put into -- "crypt wep" was refused, so "crypt:" must
    # still say off, and the channel must still be the one a join
    # would use rather than 99.
    #
    WEND="$(wifiseg WIFI9 'dRaInEd')"
    if grep -q "crypt: off" <<<"$WEND" && grep -q "channel: 0" <<<"$WEND" \
       && grep -q "status: unassociated" <<<"$WEND"; then
        pass "eight refused verbs left the interface exactly as they found it"
    else
        fail "a refused verb changed the interface's reported state"
        [[ "$VERBOSE" -eq 1 ]] && echo "$WEND"
    fi
else
    fail "the -DETHER4330STUB kernel failed to build"
    [[ "$VERBOSE" -eq 1 ]] && tail -20 "$BUILD/cc.log"
fi

# ---------------------------------------------------------------------
# The scheduler under load, with the kernel's own detectors as the
# oracle (#622, docs/PLAN9-C-UNDER-OTHER-COMPILERS.md 1).
#
#     For four days the board's Dis interpreter died of an error-stack
#     imbalance nobody could place. The cause was clang copying `m`
#     (x28) into a scratch register before dereferencing it: a process
#     interrupted between the two instructions and resumed on another
#     core read the old core's Mach through the copy, and pushed its
#     error label onto another process's stack. runproc() now resumes
#     a preempted process only on the core it left; the detectors that
#     found it stayed in the kernel, each one a line on the console:
#
#         vmachine: error stack N, expected M ...   (dis.c, the audit)
#         waserror: up is X but the stack is Y's    (proc.c, exact)
#         poperror: label pushed at ... popped at   (frame check)
#         ready: ... / runproc: ...                 (double-owner tripwires)
#
#     This runs the reproduction that used to bring one out in two to
#     five minutes -- six shell loops on /tmp, so short-lived Progs are
#     created, preempted across cores and torn down without pause --
#     for SOAKSECS seconds, and fails on any detector line. The lines
#     are cheap and silent on a healthy kernel, so the check is exact:
#     a regression of the fix, or a new fault of the same class, is one
#     grep away rather than a week. SOAKSECS=0 skips it; 90 is the
#     default and has never produced a false report.
SOAKSECS="${SOAKSECS:-90}"
if [[ "$SOAKSECS" -gt 0 ]]; then
    SOAKOUT="$(SESSION_DRAIN=$((SOAKSECS + 60)) shell_session "$BUILD/$PLAT-kernel.img" \
        '{while {~ 1 1} {echo hello-a > /tmp/a; cat /tmp/a > /dev/null; ls -l /tmp/a > /dev/null; rm /tmp/a}} &' \
        '{while {~ 1 1} {echo hello-b > /tmp/b; cat /tmp/b > /dev/null; rm /tmp/b}} &' \
        '{while {~ 1 1} {cat /dis/sh.dis > /tmp/c; cat /tmp/c | cat > /dev/null; rm /tmp/c}} &' \
        '{while {~ 1 1} {echo x | cat > /tmp/d; ls /tmp > /dev/null; rm /tmp/d}} &' \
        '{while {~ 1 1} {mkdir /tmp/dd; echo y > /tmp/dd/e; mv /tmp/dd/e /tmp/dd/f; rm /tmp/dd/f; rm /tmp/dd}} &' \
        '{while {~ 1 1} {cat /dis/sh.dis /dis/sh.dis > /tmp/big; cat /tmp/big > /dev/null; rm /tmp/big}} &' \
        "sleep $SOAKSECS")"
    SOAKOUT="$(tr -d '\r' <<<"$SOAKOUT")"
    [[ "$VERBOSE" -eq 1 ]] && { echo "  --- soak session ---"; echo "$SOAKOUT" | tail -20; }
    if ! grep -q "dRaInEd" <<<"$SOAKOUT"; then
        fail "scheduler soak: the shell did not come back after $SOAKSECS s of load (wedged, or the drain deadline is too short)"
    else
        pass "scheduler soak: the shell survived $SOAKSECS s of six /tmp loops"
    fi
    SOAKBAD="$(grep -E 'vmachine: error stack|waserror: up is [^3]|poperror: label|^ready: |runproc: cpu|panic|unhandled exception|BUG: misaligned' <<<"$SOAKOUT" | head -3)"
    if [[ -z "$SOAKBAD" ]]; then
        pass "scheduler soak: no detector fired (#622 error-stack audit, up-vs-stack, frame check, double-owner tripwires)"
    else
        fail "scheduler soak: a detector fired under load: $SOAKBAD"
    fi
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
# ---------------------------------------------------------------------
# A calling-convention error is a property of the source, so check the
# source. Anything else is theatre.
# ---------------------------------------------------------------------
if grep -n 'mboxprop(' os/bcm/*.c os/bcm2837/*.c | grep -q 'sizeof'; then
    fail "mboxprop called with sizeof -- its counts are elements, not bytes"
    grep -n 'mboxprop(' os/bcm/*.c os/bcm2837/*.c | grep 'sizeof'
else
    pass "every mboxprop call passes element counts, not sizeof"
fi

# BAREMETAL_PLATFORMS picks which machines to build and test; the
# default is every one there is. Naming one is for working on it:
#
#     BAREMETAL_PLATFORMS=virt ./tests/host/baremetal_test.sh
want_platform() {
    case " ${BAREMETAL_PLATFORMS:-bcm2837 virt bcm2711} " in *" $1 "*) return 0;; esac
    return 1
}

if want_platform bcm2837; then
run_platform bcm2837 "-M raspi3b -netdev user,id=n0 -device usb-net,netdev=n0,id=usbnet0"
fi

#
# The second machine: QEMU's virt. See os/virt/board.c for what it is
# for. Same kernel -- os/arm64, os/port, os/ip and the libraries are
# compiled from the same files with -I pointing at os/virt instead --
# and a different set of checks, because nearly everything run_platform
# asserts is about a USB bus, an SD controller or a VideoCore that this
# machine does not have.
#
# -cpu cortex-a53 is not optional: -M virt defaults to cortex-a15, a
# 32-bit CPU, even under qemu-system-aarch64, and an AArch64 kernel
# booted on one produces no output at all. It is also the board's core,
# so the JIT emits for the same part on both.
#
# Devices are all -device virtio-*-device: the MMIO transport, which is
# what os/virt/virtio.c drives. The plain names (virtio-net-pci and
# friends, and what -drive if=virtio gives) are PCI, and land on a bus
# this kernel does not walk.
#
# qemu-xhci is a PCI device: it is what makes os/port/pci.c and
# os/virt/pciecam.c run at all, on every virt boot below.
VIRTARGS="-M virt -cpu cortex-a53 -smp 4 -m 1024 -device virtio-rng-device -device qemu-xhci"

run_virt() {
PLAT=virt
SRC="$ROOT/os/$PLAT"
QEMUARGS="$VIRTARGS"
SERIALARGS="-serial stdio"
PORTSKIP="devaudio.c ethermii.c"
SHARED=""
SHAREDSKIP=""
ARCHSKIP=""

[[ -d "$SRC" ]] || { echo "ERROR: $SRC not found" >&2; exit 1; }
platform_flags

echo -e "${BOLD}--- $PLAT (qemu $QEMUARGS) ---${NC}"

if ! "$QEMU" -machine help 2>/dev/null | grep -q '^virt '; then
    skip "this QEMU build has no virt machine model"
    return
fi

if build_kernel "$BUILD/$PLAT-kernel.img" ""; then
    pass "virt: kernel cross-builds for aarch64-elf"
else
    fail "virt: kernel failed to build"
    grep -m 20 'error:\|undefined symbol' "$BUILD/cc.log"
    return
fi
[[ -n "${BAREMETAL_BUILD_ONLY:-}" ]] && return

OUT="$(boot_kernel "$BUILD/$PLAT-kernel.img" 60)"
printf '%s\n' "$OUT" > "$BUILD/$PLAT-boot.txt"
[[ "$VERBOSE" -eq 1 ]] && echo "$OUT"

vcheck() {   # vcheck <description> <fixed string that must be in the boot log>
    if grep -qF -- "$2" <<<"$OUT"; then pass "virt: $1"; else fail "virt: $1 -- no '$2' in the boot log"; fi
}
vrefute() {  # vrefute <description> <fixed string that must NOT be there>
    if grep -qF -- "$2" <<<"$OUT"; then fail "virt: $1 -- '$2' in the boot log"; else pass "virt: $1"; fi
}

vcheck "the banner names the machine"              "InferNode bare-metal (QEMU virt)"
vcheck "the device tree is found and sized"        "fdt:  at 0x"
vcheck "memory size comes from the device tree"    "memory 1024MB at 0x0000000040000000"
vcheck "PSCI is found, by hvc"                     "psci: hvc"
vcheck "the MMU is on with caches"                 "mmu:  on, caches on"
vrefute "the GIC has a CPU interface"              "NO GICv2 CPU INTERFACE"
vcheck "a device interrupt is delivered, twice"    "intr: device interrupt delivered"
vcheck "virtio-rng is found"                       "(entropy)"
vcheck "entropy comes from virtio-rng"             "rng:  virtio-rng"
vrefute "there is an entropy source"               "NO ENTROPY SOURCE"
vcheck "time of day comes from the PL031"          "time of day set"
vcheck "boot completes"                            "boot OK"
for i in 1 2 3; do
    vcheck "cpu$i comes up through PSCI" "cpu$i: up"
done
vrefute "no core fails to answer"                  "did not answer"
# The check that found this port's first real bug: with a GIC, the
# timer's end-of-interrupt has to be written before hzclock can sched()
# away from the handler (os/arm64/gic.c), or one core stops ticking.
if grep -aq 'smp:  preempt.* OK[[:space:]]*$' <<<"$OUT"; then   # the line ends in the serial line's CR
    pass "virt: a wired kproc preempts a hog on every secondary core"
else
    fail "virt: preemption -- $(grep -a 'smp:  preempt' <<<"$OUT" | head -1)"
fi
# PCI. Nothing on this machine needs it; it is here because a Raspberry
# Pi 4's USB sockets are behind a PCIe bridge no emulator has, and this
# is where the code above that bridge can be run (os/virt/pciecam.c).
vcheck "PCI configuration space is found, wherever QEMU put it" "pci: ECAM at 0x"
if grep -aEq '0c 03 30 1b36 000d .* 0:1[0-9a-f]{7} 16384' <<<"$OUT"; then
    pass "virt: the bus scan finds the xHCI controller and gives its registers an address in the window"
else
    fail "virt: PCI scan -- $(grep -a '1b36 000d' <<<"$OUT" | head -1)"
fi
vrefute "nothing panics"                           "panic:"
vcheck "init reaches the shell"                    "init: starting the shell"

#
# The whole machine: a disk, a network card, a screen, a keyboard and a
# tablet. One boot, driven three ways at once -- the serial console for
# what the kernel and the shell say, QMP for what is on the screen and
# for pressing keys, and the emulated network for DHCP.
#
# The disk is the image the board's checks boot from its SD controller
# model, byte for byte (make_sd_image); what differs is only what is
# under #S.
#
VSD="$BUILD/$PLAT-sd.img"
make_sd_image "$VSD"
VQMP="$BUILD/$PLAT-qmp.sock"
rm -f "$VQMP"
python3 - "$QEMU" "$BUILD/$PLAT-kernel.img" "$VIRTARGS" "$VSD" "$VQMP" "$BUILD/$PLAT-screen.ppm" <<'PYEOF' > "$BUILD/$PLAT-full.txt" 2>&1
import json, os, socket, subprocess, sys, threading, time
qemu, img, extra, sd, qmp, ppm = sys.argv[1:7]
args = [qemu] + extra.split() + [
    "-kernel", img, "-display", "none", "-serial", "stdio",
    "-drive", "file=%s,if=none,format=raw,id=sd" % sd, "-device", "virtio-blk-device,drive=sd",
    "-netdev", "user,id=n0", "-device", "virtio-net-device,netdev=n0",
    "-device", "ramfb", "-device", "virtio-keyboard-device", "-device", "virtio-tablet-device",
    "-qmp", "unix:%s,server,nowait" % qmp]
p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
buf = bytearray()
def reader():
    while True:
        d = p.stdout.read(1)
        if not d:
            return
        buf.extend(d)
threading.Thread(target=reader, daemon=True).start()

def waitfor(what, secs):
    end = time.time() + secs
    while time.time() < end:
        if what in buf:
            return True
        time.sleep(0.2)
    return False

def typed(line, settle=1.5):
    p.stdin.write(line.encode() + b"\r"); p.stdin.flush(); time.sleep(settle)

# Linux key names as QMP spells them, for the few characters typed below
QCODE = {" ": "spc", "-": "minus", "\n": "ret"}
def qkey(f, ch):
    shift = ch.isupper()
    q = QCODE.get(ch, ch.lower())
    keys = (["shift"] if shift else []) + [q]
    for down in (True, False):
        ev = [{"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": k}}}
              for k in (keys if down else reversed(keys))]
        f.write(json.dumps({"execute": "input-send-event", "arguments": {"events": ev}}) + "\n")
        f.flush(); f.readline()
        time.sleep(0.03)

try:
    waitfor(b"init: starting the shell", 90)
    # DHCP runs in its own thread after the shell starts; give it its time
    waitfor(b"etherusb: default route", 30)
    time.sleep(1.5)
    typed("cat /n/dos/HELLO.TXT")
    typed("echo written-through-virtio > /n/dos/virt.txt; cat /n/dos/virt.txt", 2.5)
    typed("cat /net/ether0/addr; echo")
    typed("cat /net/ether0/ifstats")
    typed("cat /dev/sdctl")
    typed("echo VIRT-DATE `{date}")

    s = socket.socket(socket.AF_UNIX); s.connect(qmp)
    f = s.makefile("rw")
    f.readline()
    f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush(); f.readline()

    # the keyboard: type a command on the VIRTIO keyboard and see the
    # shell run it. The echo comes back on the serial line because the
    # two keyboards feed one queue and the console answers on both.
    for ch in "echo Virtio-Keys\n":
        qkey(f, ch)
    time.sleep(2)

    # the tablet: put the pointer somewhere and read it back
    ev = [{"type": "abs", "data": {"axis": "x", "value": 16384}},
          {"type": "abs", "data": {"axis": "y", "value": 8192}}]
    f.write(json.dumps({"execute": "input-send-event", "arguments": {"events": ev}}) + "\n")
    f.flush(); f.readline()
    time.sleep(1)
    typed("read -o 0 49 < /dev/pointer; echo")

    # the screen
    if os.path.exists(ppm):
        os.unlink(ppm)
    f.write(json.dumps({"execute": "screendump", "arguments": {"filename": ppm}}) + "\n"); f.flush()
    f.readline(); time.sleep(1)
    if os.path.exists(ppm):
        d = open(ppm, "rb").read()
        parts = d.split(b"\n", 3)
        w, h = map(int, parts[1].split()); px = parts[3]
        BG = (0x10, 0x10, 0x18); FG = (0xC8, 0xC8, 0xC8)
        nbg = nfg = 0
        for y in range(h):
            for x in range(0, w, 2):
                o = (y*w + x)*3
                c = tuple(px[o:o+3])
                if c == BG: nbg += 1
                elif c == FG: nfg += 1
        print("\nSCREEN %dx%d bg %d fg %d" % (w, h, nbg, nfg))
    else:
        print("\nSCREEN none")
    typed("echo session-drained", 1)
    waitfor(b"session-drained\r\nsession-drained", 10) or waitfor(b"session-drained", 2)
    s.close()
finally:
    p.kill(); p.communicate()
sys.stdout.write(buf.decode(errors="replace"))
PYEOF
OUT="$(cat "$BUILD/$PLAT-full.txt")"
[[ "$VERBOSE" -eq 1 ]] && echo "$OUT"

vcheck "a virtio disk is found"                    "blk:  virtio disk, 131072 blocks"
vcheck "the card's FAT partition is read through #S and dossrv" "hello from the SD card"
vcheck "a file written through virtio-blk reads back" "written-through-virtio"
vcheck "the network card is ether0"                "is #l (ether0)"
vcheck "init finds the kernel link driver"         "init: ether0 is a kernel link driver"
vcheck "DHCP answers over virtio-net"              "etherusb: 10.0.2.15 mask"
vcheck "a default route is installed"              "etherusb: default route via 10.0.2.2"
vcheck "the framebuffer is configured through fw_cfg" "fb:   ramfb 1280x720x32"
vcheck "the keyboard and the tablet are found"     "(absolute pointer)"
vcheck "keys typed on the virtio keyboard reach the shell" "Virtio-Keys"
if grep -aq '^m *640 *180 ' <<<"$OUT"; then
    pass "virt: the tablet's position is scaled to the screen (640,180)"
else
    fail "virt: tablet position -- $(grep -a '^m ' <<<"$OUT" | head -1)"
fi
scr="$(grep -a '^SCREEN' <<<"$OUT" | tail -1)"
read -r _ sdim _ sbg _ sfg <<<"$scr"
if [[ "$sdim" == "1280x720" && "${sfg:-0}" -ge 500 && "${sbg:-0}" -ge 100000 ]]; then
    pass "virt: the console is legible on the ramfb screen ($scr)"
else
    fail "virt: screen -- '$scr'"
fi
vrefute "nothing panics with every device attached" "panic:"
if grep -aq '^VIRT-DATE.* 20[2-9][0-9]' <<<"$OUT"; then
    pass "virt: date(1) has the PL031's year, with no time server"
else
    fail "virt: date -- $(grep -a '^VIRT-DATE' <<<"$OUT" | head -1)"
fi

#
# USB, through xHCI on the PCI bus. Nothing on this machine needs USB.
# It is here because a Raspberry Pi 4's four USB-A sockets are an xHCI
# controller behind a PCIe bridge, QEMU's raspi4b has neither, and this
# machine has both for the asking -- so os/port/usbxhci.c, the topology
# devusb computes for it and the walker in osinit that finds more than
# one root port are RUN here, and only the Pi's bridge is left untried.
#
# One boot: a hub, a keyboard BEHIND the hub (a full-speed device
# routed through a hub is the case a slot context's route string and
# hub fields exist for), a mouse, and a network adapter for bulk
# transfers. And with pcibounce, which makes the bridge refuse every
# buffer a driver offers it -- the condition a Pi 4's drivers live
# under, where PCI devices reach the first gigabyte only -- so that the
# bounce path is run by this harness and not first on a board.
#
# virt_usb_boot <machine args> <log>: the boot described above
virt_usb_boot() {
python3 - "$QEMU" "$BUILD/$PLAT-kernel.img" "$1" "$BUILD/$PLAT-xqmp.sock" <<'PYEOF' > "$2" 2>&1
import json, os, socket, subprocess, sys, threading, time
qemu, img, extra, qmp = sys.argv[1:5]
if os.path.exists(qmp):
    os.unlink(qmp)
args = [qemu] + extra.split() + [
    "-kernel", img, "-display", "none", "-serial", "stdio", "-append", "pcibounce",
    "-device", "usb-hub,port=1", "-device", "usb-kbd,port=1.2", "-device", "usb-mouse,port=2",
    "-netdev", "user,id=u0", "-device", "usb-net,netdev=u0,port=3",
    "-qmp", "unix:%s,server,nowait" % qmp]
p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
buf = bytearray()
def reader():
    while True:
        d = p.stdout.read(1)
        if not d:
            return
        buf.extend(d)
threading.Thread(target=reader, daemon=True).start()
def waitfor(what, secs):
    end = time.time() + secs
    while time.time() < end:
        if what in buf:
            return True
        time.sleep(0.2)
    return False
def typed(line, settle=1.5):
    p.stdin.write(line.encode() + b"\r"); p.stdin.flush(); time.sleep(settle)
QCODE = {" ": "spc", "-": "minus", "\n": "ret"}
def qkey(f, ch):
    shift = ch.isupper()
    q = QCODE.get(ch, ch.lower())
    keys = (["shift"] if shift else []) + [q]
    for down in (True, False):
        ev = [{"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": k}}}
              for k in (keys if down else reversed(keys))]
        f.write(json.dumps({"execute": "input-send-event", "arguments": {"events": ev}}) + "\n")
        f.flush(); f.readline()
        time.sleep(0.05)
try:
    waitfor(b"init: starting the shell", 90)
    waitfor(b"kbdusb: ep", 30)
    waitfor(b"etherusb: default route", 40)
    time.sleep(2)
    s = socket.socket(socket.AF_UNIX); s.connect(qmp)
    f = s.makefile("rw")
    f.readline()
    f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush(); f.readline()
    for ch in "echo Xhci-Keys\n":
        qkey(f, ch)
    time.sleep(2)
    typed("cat /usb/usb/ctl")
    typed("echo dump > /usb/usb/ctl", 2.5)
    s.close()
finally:
    p.kill(); p.communicate()
sys.stdout.write(buf.decode(errors="replace"))
PYEOF
}
virt_usb_boot "$VIRTARGS" "$BUILD/$PLAT-xhci.txt"
OUT="$(cat "$BUILD/$PLAT-xhci.txt")"
[[ "$VERBOSE" -eq 1 ]] && echo "$OUT"

vcheck "xhci: the controller is found on the PCI bus"  "usbxhci: PCI.0."
vcheck "xhci: every buffer is being refused, as on a Pi 4" "pci: pcibounce:"
vcheck "xhci: a hub on a root port other than the first is enumerated" "is a hub with 8 port(s)"
vrefute "xhci: the controller accepts being told it is a hub" "would not be told it is a hub"
vcheck "xhci: a keyboard BEHIND the hub is claimed"    "kbdusb: ep"
vcheck "xhci: a mouse is claimed"                      "mouseusb: ep"
vcheck "xhci: keys typed on the USB keyboard reach the shell (interrupt IN, through the hub)" "Xhci-Keys"
vcheck "xhci: USB Ethernet comes up as ether0 (bulk endpoints)" "etherusb: serving /net/ether0 (kernel data path)"
vcheck "xhci: ether0 has QEMU's address"               "etherusb: 10.0.2.15 mask"
vcheck "xhci: the gateway answers a ping over it"      "ICMP echo reply from 10.0.2.2"
xb="$(grep -a 'usbxhci: [0-9]* transfers bounced' <<<"$OUT" | tail -1 | sed -E 's/.*usbxhci: ([0-9]+) transfers.*/\1/')"
if [[ "${xb:-0}" -ge 20 ]]; then
    pass "virt: xhci: all of that ran through the bounce ($xb transfers)"
else
    fail "virt: xhci: only '${xb:-none}' transfers bounced -- pcibounce is not refusing buffers, so the path a Pi 4 needs did not run"
fi
vrefute "xhci: nothing panics"                         "panic:"
vrefute "xhci: no exception goes unhandled"            "unhandled exception"
vcheck "xhci: qemu-xhci has no MSI, and is given a wire" "usbxhci interrupts by wire"

#
# The same again with the interrupts arriving as MESSAGES. A Raspberry
# Pi 4's PCIe bridge delivers nothing else, so os/port/pci.c's MSI code
# and a driver living on it are run here or nowhere. QEMU's qemu-xhci
# has only MSI-X; its nec-usb-xhci has MSI, as the Pi's VL805 does. The
# message goes to the GIC's MSI frame (GICv2m), which pulses a shared
# interrupt -- one that must have been made edge-triggered first.
#
if "$QEMU" -device help 2>/dev/null | grep -q '"nec-usb-xhci"'; then
    virt_usb_boot "${VIRTARGS/qemu-xhci/nec-usb-xhci}" "$BUILD/$PLAT-xhci-msi.txt"
    OUT="$(cat "$BUILD/$PLAT-xhci-msi.txt")"
    [[ "$VERBOSE" -eq 1 ]] && echo "$OUT"
    vcheck "msi: the GIC's MSI frame is found"             "pci: MSI frame at 0x8020000: interrupts 80-"
    vcheck "msi: the controller is given a message, not a wire" "usbxhci interrupts by MSI"
    vcheck "msi: a keyboard behind a hub is claimed"       "kbdusb: ep"
    vcheck "msi: keys typed on it reach the shell"         "Xhci-Keys"
    vcheck "msi: the gateway answers a ping over USB Ethernet" "ICMP echo reply from 10.0.2.2"
    vrefute "msi: nothing panics"                          "panic:"
else
    skip "virt: this QEMU has no nec-usb-xhci, the xHCI model with MSI"
fi

#
# Plugging things in and pulling them out, on xHCI. On a Raspberry Pi 4
# the sockets ARE root ports and hubs get pulled with things in them;
# every device in the boots above was there from the start. One boot,
# with a mouse that stays put throughout and must come through it all:
#
#   a hub is plugged into a root port, a keyboard into the hub, keys
#   are typed on it, and the HUB is pulled -- so the keyboard's driver,
#   asleep in a read with no timeout, must be woken (devusb's epstop at
#   detach), the hub's watcher must notice it is watching nothing and
#   go, and a control transfer left in flight must be abandoned WITHOUT
#   resetting the controller under the mouse (usbxhci.c, waittd);
#
#   then a keyboard straight into a root port, typed on and pulled.
#
# What is asserted at the end is that the controller holds exactly one
# slot -- the mouse's. Each of the three things above leaked one when
# this was first tried.
#
python3 - "$QEMU" "$BUILD/$PLAT-kernel.img" "$VIRTARGS" "$BUILD/$PLAT-hqmp.sock" <<'PYEOF' > "$BUILD/$PLAT-hotplug.txt" 2>&1
import json, os, socket, subprocess, sys, threading, time
qemu, img, extra, qmp = sys.argv[1:5]
if os.path.exists(qmp):
    os.unlink(qmp)
args = [qemu] + extra.split() + [
    "-kernel", img, "-display", "none", "-serial", "stdio", "-append", "pcibounce",
    "-device", "usb-mouse,port=4", "-qmp", "unix:%s,server,nowait" % qmp]
p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
buf = bytearray()
def reader():
    while True:
        d = p.stdout.read(1)
        if not d:
            return
        buf.extend(d)
threading.Thread(target=reader, daemon=True).start()
def waitfor(what, secs, start=0):
    end = time.time() + secs
    while time.time() < end:
        if buf.find(what, start) >= 0:
            return True
        time.sleep(0.2)
    return False
def typed(line, settle=1.5):
    p.stdin.write(line.encode() + b"\r"); p.stdin.flush(); time.sleep(settle)
def q(f, o):
    f.write(json.dumps(o) + "\n"); f.flush()
    while True:
        r = json.loads(f.readline())
        if "return" in r or "error" in r:
            return r
QCODE = {" ": "spc", "-": "minus", "\n": "ret"}
def keys(f, text):
    for ch in text:
        q(f, {"execute": "send-key", "arguments": {"keys": [{"type": "qcode", "data": QCODE.get(ch, ch.lower())}], "hold-time": 40}})
        time.sleep(0.12)
def add(f, **a):
    return q(f, {"execute": "device_add", "arguments": a})
try:
    waitfor(b"init: starting the shell", 90)
    waitfor(b"mouseusb: ep", 30)
    time.sleep(3)
    s = socket.socket(socket.AF_UNIX); s.connect(qmp)
    f = s.makefile("rw"); f.readline()
    q(f, {"execute": "qmp_capabilities"})

    # a hub, a keyboard in the hub, and then the hub goes
    mark = len(buf)
    add(f, driver="usb-hub", id="h1", bus="usb-bus.0", port="1")
    waitfor(b"is a hub with", 25, mark); time.sleep(2)
    add(f, driver="usb-kbd", id="k1", bus="usb-bus.0", port="1.2")
    waitfor(b"kbdusb: ep", 25, mark); time.sleep(1.5)
    keys(f, "echo hub-keys\n"); time.sleep(2)
    mark = len(buf)
    q(f, {"execute": "device_del", "arguments": {"id": "h1"}})
    waitfor(b"has gone", 30, mark)
    waitfor(b"detached", 15, mark); time.sleep(2)

    # a keyboard in a root port, and then it goes
    mark = len(buf)
    add(f, driver="usb-kbd", id="k2", bus="usb-bus.0", port="2")
    waitfor(b"kbdusb: ep", 25, mark); time.sleep(1.5)
    keys(f, "echo root-keys\n"); time.sleep(2)
    mark = len(buf)
    q(f, {"execute": "device_del", "arguments": {"id": "k2"}})
    waitfor(b"detached", 20, mark); time.sleep(2)

    typed("cat /usb/usb/ctl")
    typed("echo dump > /usb/usb/ctl", 2.5)
    s.close()
finally:
    p.kill(); p.communicate()
sys.stdout.write(buf.decode(errors="replace"))
PYEOF
OUT="$(cat "$BUILD/$PLAT-hotplug.txt")"
[[ "$VERBOSE" -eq 1 ]] && echo "$OUT"

vcheck "hotplug: a hub plugged into a root port after boot is seen and walked" "ep1.0 port 5: device attached"
vcheck "hotplug: keys typed on a keyboard plugged into that hub reach the shell" "hub-keys"
vcheck "hotplug: the pulled hub's watcher notices, and goes"  "has gone; so has what was on it"
vcheck "hotplug: keys typed on a keyboard plugged into a root port reach the shell" "root-keys"
nd="$(grep -ac 'kbdusb: ep.* detached' <<<"$OUT")"
if [[ "$nd" -eq 2 ]]; then
    pass "virt: hotplug: both keyboards' drivers were woken from their reads and left"
else
    fail "virt: hotplug: $nd of 2 keyboard drivers noticed their device had gone"
fi
vrefute "hotplug: pulling a hub does not reset the controller under everything else" "need recover"
vrefute "hotplug: no ring was thought stopped while it ran" "THOUGHT STOPPED"
slots="$(grep -a 'slots in use' <<<"$OUT" | tail -1 | sed -E 's/.* ([0-9]+) of [0-9]+ slots in use.*/\1/')"
if [[ "$slots" == "1" ]]; then
    pass "virt: hotplug: the controller holds one slot at the end -- the mouse's, which sat through it all"
else
    fail "virt: hotplug: '${slots:-no}' slots in use at the end, not 1 -- $(grep -a 'slots in use' <<<"$OUT" | tail -1)"
fi
if grep -aq '^ep2\.1 enabled interrupt' <<<"$OUT"; then
    pass "virt: hotplug: the mouse's endpoint is still enabled"
else
    fail "virt: hotplug: the mouse did not survive -- $(grep -a '^ep2' <<<"$OUT" | head -2 | tr '\n' '|')"
fi
vrefute "hotplug: nothing panics"                      "panic:"

#
# The other virtio transport. QEMU's virtio-mmio is "legacy" (version 1)
# unless told otherwise, and everything above ran on that; a modern one
# finds its queues by three addresses instead of a page number, insists
# on FEATURES_OK, and -- the part that bites -- makes the network
# header twelve bytes instead of ten. Same devices, same checks, the
# other half of os/virt/virtio.c.
#
cp "$VSD" "$BUILD/$PLAT-sd-modern.img"
MODOUT="$( (sleep 45; printf 'cat /n/dos/HELLO.TXT\r'; sleep 2; printf 'cat /net/ether0/ifstats\r'; sleep 4) | \
    timeout -s KILL 60 "$QEMU" $VIRTARGS -global virtio-mmio.force-legacy=false \
        -kernel "$BUILD/$PLAT-kernel.img" -display none -serial stdio \
        -drive "file=$BUILD/$PLAT-sd-modern.img,if=none,format=raw,id=sd" -device virtio-blk-device,drive=sd \
        -netdev user,id=n0 -device virtio-net-device,netdev=n0 2>/dev/null)"
OUT="$MODOUT"
[[ "$VERBOSE" -eq 1 ]] && echo "$OUT"
vcheck "modern transports are recognised"          "(network), modern transport"
vrefute "no device is left on a legacy transport"  "legacy transport"
vcheck "modern: entropy"                           "rng:  virtio-rng"
vcheck "modern: the disk reads through dossrv"     "hello from the SD card"
vcheck "modern: DHCP answers, with a 12-byte header" "etherusb: 10.0.2.15 mask"
vcheck "modern: the driver says which header it uses" "modern transport, header 12 bytes"
vrefute "modern: nothing panics"                   "panic:"

#
# The desktop, from a populated card.
#
# tools/mkcard.py writes what a Raspberry Pi's card holds -- dis/, lib/,
# fonts/, icons/, a writable usr/, a rootpath saying "local" -- as a
# FAT32 image, and the kernel takes its userspace from it through the
# same rootpath policy, dossrv and boot-baremetal.sh the board uses.
# skiplogon, because there is nobody here to type a password. What is
# asserted is that Lucifer DREW: its accent colour, which no console
# text and no kernel test pattern contains, covers a tab's worth of
# the screen.
#
# This is the check os/bcm2837/README.md has wanted since September
# ("a populated FAT32 card image booting through rootpath ... under
# QEMU"); it is here first because a virtio disk reads the 20MB the
# desktop loads in seconds.
#
VCARD="$BUILD/$PLAT-card.img"
printf 'local\n' > "$BUILD/rootpath"
: > "$BUILD/skiplogon"
if python3 "$ROOT/tools/mkcard.py" "$VCARD" 192 /dis="$ROOT/dis" /lib="$ROOT/lib" \
        /fonts="$ROOT/fonts" /icons="$ROOT/icons" /usr= \
        /rootpath="$BUILD/rootpath" /skiplogon="$BUILD/skiplogon" > "$BUILD/mkcard.txt" 2>&1; then
    pass "virt: mkcard builds a populated FAT32 card ($(sed 's/^mkcard: [^:]*: //' "$BUILD/mkcard.txt"))"
    FSCK="$(command -v fsck.fat 2>/dev/null || ls /usr/sbin/fsck.fat /sbin/fsck.fat 2>/dev/null | head -1)"
    if [[ -n "$FSCK" ]]; then
        dd if="$VCARD" of="$BUILD/$PLAT-card.part" bs=512 skip=2048 status=none
        if "$FSCK" -n "$BUILD/$PLAT-card.part" > "$BUILD/fsck.txt" 2>&1; then
            pass "virt: fsck.fat finds nothing wrong with it"
        else
            fail "virt: fsck.fat objects to mkcard's image: $(tail -3 "$BUILD/fsck.txt" | tr '\n' ' ')"
        fi
        rm -f "$BUILD/$PLAT-card.part"
    else
        skip "virt: no fsck.fat to check mkcard's image with"
    fi

    rm -f "$VQMP"
    python3 - "$QEMU" "$BUILD/$PLAT-kernel.img" "$VIRTARGS" "$VCARD" "$VQMP" "$BUILD/$PLAT-desktop.ppm" <<'PYEOF' > "$BUILD/$PLAT-desktop.txt" 2>&1
import json, os, socket, subprocess, sys, threading, time
qemu, img, extra, sd, qmp, ppm = sys.argv[1:7]
p = subprocess.Popen([qemu] + extra.split() + [
    "-kernel", img, "-display", "none", "-serial", "stdio",
    "-drive", "file=%s,if=none,format=raw,id=sd" % sd, "-device", "virtio-blk-device,drive=sd",
    "-netdev", "user,id=n0", "-device", "virtio-net-device,netdev=n0",
    "-device", "ramfb", "-device", "virtio-keyboard-device", "-device", "virtio-tablet-device",
    "-qmp", "unix:%s,server,nowait" % qmp],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
buf = bytearray()
def reader():
    while True:
        d = p.stdout.read(1)
        if not d:
            return
        buf.extend(d)
threading.Thread(target=reader, daemon=True).start()
ACCENT = (0xE8, 0x55, 0x3A)
w = h = best = 0
try:
    end = time.time() + 180
    while time.time() < end and b"lucifer: INIT" not in buf:
        time.sleep(0.5)
    s = socket.socket(socket.AF_UNIX); s.connect(qmp)
    f = s.makefile("rw"); f.readline()
    f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush(); f.readline()
    # Lucifer has started; dump until it has drawn, or a minute passes
    end = time.time() + 60
    while time.time() < end and best < 1000:
        time.sleep(3)
        if os.path.exists(ppm):
            os.unlink(ppm)
        f.write(json.dumps({"execute": "screendump", "arguments": {"filename": ppm}}) + "\n"); f.flush()
        f.readline(); time.sleep(1)
        if not os.path.exists(ppm):
            continue
        d = open(ppm, "rb").read()
        parts = d.split(b"\n", 3)
        w, h = map(int, parts[1].split()); px = parts[3]
        n = 0
        for o in range(0, w*h*3, 3):
            if px[o] == ACCENT[0] and px[o+1] == ACCENT[1] and px[o+2] == ACCENT[2]:
                n += 1
        best = max(best, n)

    # The software cursor. It starts at 0,0 and the desktop draws around
    # it; move the tablet to the middle of the screen and the arrow must
    # be THERE and must not still be at 0,0. The arrow is the kernel's
    # own (os/arm64/screen.c: set mask black, clear-and-not-set white),
    # so it can be looked for exactly.
    CLR = [0xFF,0xFF,0x80,0x01,0x80,0x02,0x80,0x0C,0x80,0x10,0x80,0x10,0x80,0x08,0x80,0x04,
           0x80,0x02,0x80,0x01,0x80,0x02,0x8C,0x04,0x92,0x08,0x91,0x10,0xA0,0xA0,0xC0,0x40]
    SET = [0x00,0x00,0x7F,0xFE,0x7F,0xFC,0x7F,0xF0,0x7F,0xE0,0x7F,0xE0,0x7F,0xF0,0x7F,0xF8,
           0x7F,0xFC,0x7F,0xFE,0x7F,0xFC,0x73,0xF8,0x61,0xF0,0x60,0xE0,0x40,0x40,0x00,0x00]
    def arrow(px, w, h, x0, y0):
        hit = tot = 0
        for y in range(16):
            for x in range(16):
                st = SET[y*2 + (x >> 3)] & (0x80 >> (x & 7)); cl = CLR[y*2 + (x >> 3)] & (0x80 >> (x & 7))
                if not (st or cl) or x0+x < 0 or y0+y < 0 or x0+x >= w or y0+y >= h:
                    continue
                o = ((y0+y)*w + x0+x)*3; tot += 1
                if tuple(px[o:o+3]) == ((0, 0, 0) if st else (255, 255, 255)):
                    hit += 1
        return 100 * hit // max(tot, 1)
    time.sleep(10)          # several more batches drawn around a cursor nothing has moved
    ev = [{"type": "abs", "data": {"axis": "x", "value": 16384}},
          {"type": "abs", "data": {"axis": "y", "value": 16384}}]
    f.write(json.dumps({"execute": "input-send-event", "arguments": {"events": ev}}) + "\n")
    f.flush(); f.readline()
    time.sleep(2)
    if os.path.exists(ppm):
        os.unlink(ppm)
    f.write(json.dumps({"execute": "screendump", "arguments": {"filename": ppm}}) + "\n"); f.flush()
    f.readline(); time.sleep(1)
    cmoved = corigin = -1
    if os.path.exists(ppm):
        d = open(ppm, "rb").read()
        parts = d.split(b"\n", 3)
        w, h = map(int, parts[1].split()); px = parts[3]
        cmoved = max(arrow(px, w, h, w//2 + dx, h//2 + dy) for dx in range(-3, 3) for dy in range(-3, 3))
        corigin = arrow(px, w, h, 0, 0)
    s.close()
finally:
    p.kill(); p.communicate()
sys.stdout.write(buf.decode(errors="replace"))
print("\nDESKTOP %dx%d accent %d" % (w, h, best))
print("CURSOR moved %d origin %d" % (cmoved, corigin))
PYEOF
    OUT="$(cat "$BUILD/$PLAT-desktop.txt")"
    [[ "$VERBOSE" -eq 1 ]] && echo "$OUT"
    vcheck "the card's FAT32 partition mounts"         "init: /dev/sd0: type 0x0c"
    vcheck "userspace comes off the card (rootpath local)" "init: /dis grown from /n/dos/dis"
    vcheck "/usr is the card's, writable"              "init: /usr from /n/dos/usr (writable)"
    vcheck "boot-baremetal.sh narrows the namespace and starts the desktop" "boot: skiplogon"
    vcheck "Lucifer starts"                            "lucifer: INIT"
    desk="$(grep -a '^DESKTOP' <<<"$OUT" | tail -1)"
    read -r _ ddim _ dacc <<<"$desk"
    if [[ "$ddim" == "1280x720" && "${dacc:-0}" -ge 1000 ]]; then
        pass "virt: Lucifer draws the desktop on the ramfb screen ($desk)"
    else
        fail "virt: desktop -- '$desk'"
    fi
    #
    # The pointer is where it was put, and only there. flushmemscreen used
    # to mend the cursor against the rectangle devdraw flushed, which is a
    # batch's bounding box and not the pixels drawn: once the cursor stayed
    # on the screen unless an operation met it (#654), a box that merely
    # covered it made the arrow's own pixels the saved background, and the
    # first move left a second arrow behind at 0,0. It reached the board
    # because nothing here looked at the cursor at all.
    #
    curs="$(grep -a '^CURSOR' <<<"$OUT" | tail -1)"
    read -r _ _ cmoved _ corigin <<<"$curs"
    if [[ "${cmoved:-0}" -ge 95 ]]; then
        pass "virt: the pointer moved to mid-screen is drawn there ($curs)"
    else
        fail "virt: no arrow where the tablet put the pointer -- '$curs'"
    fi
    if [[ "${corigin:-100}" -le 50 && "${corigin:--1}" -ge 0 ]]; then
        pass "virt: and it left nothing behind at 0,0"
    else
        fail "virt: an arrow is still drawn at 0,0 after the pointer left -- '$curs'"
    fi
    vrefute "nothing panics under the desktop"          "panic:"

    #
    # And the same card with no screen: headless, which is a way of
    # running the machine and not a fault. boot-baremetal.sh asks the
    # draw device whether there is a display, and with none it must say
    # so ONCE and start nothing -- not retry logon three times and advise
    # fixing it, and not (with skiplogon, as here) start the desktop's
    # servers and then announce that the desktop has exited.
    #
    # This check has a twin above. The first version of that test asked
    # the question with cat, which fails on a machine WITH a screen, and
    # every machine came up headless; "Lucifer draws the desktop" is what
    # caught it. Between them the question is held from both sides.
    #
    cp "$VCARD" "$BUILD/$PLAT-card-headless.img"
    OUT="$(timeout -s KILL 150 "$QEMU" $VIRTARGS \
        -kernel "$BUILD/$PLAT-kernel.img" -display none -serial stdio \
        -drive "file=$BUILD/$PLAT-card-headless.img,if=none,format=raw,id=sd" -device virtio-blk-device,drive=sd \
        -netdev user,id=n0 -device virtio-net-device,netdev=n0 < /dev/null 2>/dev/null)"
    printf '%s\n' "$OUT" > "$BUILD/$PLAT-headless.txt"
    rm -f "$BUILD/$PLAT-card-headless.img"
    [[ "$VERBOSE" -eq 1 ]] && echo "$OUT"
    vcheck "headless: with no screen the boot script says so"  "boot: no display -- running headless"
    vrefute "headless: logon is not tried"                  "wm/logon failed"
    vrefute "headless: the desktop is not started"          "lucifer: INIT"
    vrefute "headless: nothing claims a desktop exited"     "the desktop has exited"
    vcheck "headless: the machine is up -- shell and network" "etherusb: 10.0.2.15 mask"
    vrefute "headless: nothing panics"                      "panic:"
else
    fail "virt: mkcard failed: $(tail -2 "$BUILD/mkcard.txt" | tr '\n' ' ')"
fi

echo ""
}

if want_platform virt; then
run_virt
fi

#
# The third machine: a Raspberry Pi 4 (os/bcm2711), on QEMU's raspi4b.
#
# Almost none of this kernel is new. The drivers are os/bcm's, the ones
# the Pi 3 runs; the interrupt controller and the clock are os/arm64's,
# the ones virt runs (a Pi 4 has a GIC-400); what is the board's own is
# a memory map, a list of interrupt numbers and a random-number
# generator. So what this asks is whether those three were put together
# right: the same drivers, reached through a different controller at
# different addresses.
#
# raspi4b arrived in QEMU 9.0. An older QEMU skips, which is not a pass.
#
# What QEMU's model has and has not decides what can be asked of it. It
# has the UARTs, the mailbox and framebuffer, the SD controllers, the
# DWC2 USB controller (so: a USB keyboard, mouse and Ethernet, exactly
# as on raspi3b). It has NO gigabit Ethernet, NO PCIe and so none of the
# board's four USB-A ports, and NO random-number generator -- the kernel
# finds that out for itself and says so (os/bcm2711/random.c).
#
PI4ARGS="-M raspi4b -netdev user,id=n0 -device usb-net,netdev=n0,id=usbnet0"

run_bcm2711() {
PLAT=bcm2711
SRC="$ROOT/os/$PLAT"
QEMUARGS="$PI4ARGS"
SERIALARGS="-serial null -serial stdio"
SHARED="$ROOT/os/bcm"
SHAREDSKIP=""
ARCHSKIP=""
PORTSKIP=""

[[ -d "$SRC" ]] || { echo "ERROR: $SRC not found" >&2; exit 1; }
platform_flags

echo -e "${BOLD}--- $PLAT (qemu $QEMUARGS) ---${NC}"

if ! "$QEMU" -machine help 2>/dev/null | grep -q '^raspi4b '; then
    skip "bcm2711: this QEMU has no raspi4b machine (it arrived in 9.0)"
    return
fi

if build_kernel "$BUILD/$PLAT-kernel.img" ""; then
    pass "bcm2711: kernel cross-builds for aarch64-elf"
else
    fail "bcm2711: kernel failed to build"
    grep -m 20 'error:\|undefined symbol\|duplicate symbol' "$BUILD/cc.log"
    tail -5 "$BUILD/cc.log"
    return
fi
[[ -n "${BAREMETAL_BUILD_ONLY:-}" ]] && return

OUT="$(boot_kernel "$BUILD/$PLAT-kernel.img" 90)"
printf '%s\n' "$OUT" > "$BUILD/$PLAT-boot.txt"
[[ "$VERBOSE" -eq 1 ]] && echo "$OUT"

pcheck() {
    if grep -qF -- "$2" <<<"$OUT"; then pass "bcm2711: $1"; else fail "bcm2711: $1 -- no '$2' in the boot log"; fi
}
prefute() {
    if grep -qF -- "$2" <<<"$OUT"; then fail "bcm2711: $1 -- '$2' in the boot log"; else pass "bcm2711: $1"; fi
}

pcheck "the banner names the board"                 "InferNode bare-metal (BCM2711 / Raspberry Pi 4B)"
pcheck "the mailbox answers at the new address"     "mbox: board rev"
pcheck "the MMU is on with caches"                  "mmu:  on, caches on"
prefute "the GIC-400 has a CPU interface"           "NO GICv2 CPU INTERFACE"
pcheck "the clock ticks through the GIC"            "clk:  irq firing"
pcheck "a DEVICE interrupt arrives through the GIC (system timer)" "intr: device interrupt delivered"
pcheck "boot completes"                             "boot OK"
for i in 1 2 3; do
    pcheck "cpu$i comes up from the spin table" "cpu$i: up"
done
if grep -aq 'smp:  preempt.* OK[[:space:]]*$' <<<"$OUT"; then
    pass "bcm2711: a wired kproc preempts a hog on every secondary core"
else
    fail "bcm2711: preemption -- $(grep -a 'smp:  preempt' <<<"$OUT" | head -1)"
fi
pcheck "the missing RNG200 is noticed, not faulted on" "NO RNG200 AT ITS ADDRESS"
# With no card in it, the Arasan is the radio's and the radio's driver
# probes it -- which on this board means two instances of one SDHCI
# driver alive at once (os/bcm2711/emmc2.c). QEMU models no radio, so
# what is asserted is that the probe ran and came back empty-handed
# rather than not at all, and took nothing down with it.
pcheck "with no card, the radio is probed on the Arasan and reported absent" "ether4330: no radio"
# The gigabit MAC (os/bcm2711/ethergenet.c) is a driver no emulator can
# run. What CAN be asserted is that it asks before it touches, finds
# nothing, and leaves ether0 to the USB path -- whose checks, below, are
# then also the proof that it did.
pcheck "the missing GENET is noticed, not faulted on" "genet: NO ETHERNET MAC AT"
# Likewise the PCIe bridge (os/bcm2711/pcibcm.c). The code above it --
# os/port/pci.c -- is run on the virt machine, which has a bridge.
pcheck "the missing PCIe bridge is noticed, not faulted on" "pci: NO PCIe BRIDGE AT"
prefute "nothing panics"                            "panic:"
prefute "no exception goes unhandled"               "unhandled exception"
pcheck "init reaches the shell"                     "init: starting the shell"

#
# The whole machine, from a populated card: the SD controller, the USB
# host controller with a hub, a network adapter, a keyboard and a mouse
# behind it, the framebuffer, and the desktop. One boot, watched two
# ways -- the serial console and QMP.
#
# Two things here are QEMU's and are asserted AS QEMU's, so that nobody
# reads them as the board's:
#
#   the card. A Pi 4's is on EMMC2. raspi4b (9.2) wires it to the first
#   SDHCI controller, and the kernel must find it there AND SAY SO.
#
#   the address. DHCP over QEMU's emulated USB Ethernet answers about two
#   boots in five, on the Pi 3's kernel exactly as on this one (measured:
#   the OFFER reaches the emulated adapter and the bulk IN never returns
#   it). etherusb falls back to QEMU's well-known address when it does
#   not. So what is asserted is that the interface came up and has the
#   address, which is what the Pi 3's half of this file has always
#   asserted; which road it took is not.
#
PCARD="$BUILD/$PLAT-card.img"
printf 'local\n' > "$BUILD/rootpath"
: > "$BUILD/skiplogon"
if python3 "$ROOT/tools/mkcard.py" "$PCARD" 256 /dis="$ROOT/dis" /lib="$ROOT/lib" \
        /fonts="$ROOT/fonts" /icons="$ROOT/icons" /usr= \
        /rootpath="$BUILD/rootpath" /skiplogon="$BUILD/skiplogon" > "$BUILD/$PLAT-mkcard.txt" 2>&1; then
    PQMP="$BUILD/$PLAT-qmp.sock"
    rm -f "$PQMP"
    python3 - "$QEMU" "$BUILD/$PLAT-kernel.img" "$PI4ARGS" "$PCARD" "$PQMP" "$BUILD/$PLAT-desktop.ppm" <<'PYEOF' > "$BUILD/$PLAT-desktop.txt" 2>&1
import json, os, socket, subprocess, sys, threading, time
qemu, img, extra, sd, qmp, ppm = sys.argv[1:7]
p = subprocess.Popen([qemu] + extra.split() + [
    "-kernel", img, "-display", "none", "-serial", "null", "-serial", "stdio",
    "-device", "usb-kbd", "-device", "usb-mouse",
    "-drive", "file=%s,if=sd,format=raw" % sd,
    "-qmp", "unix:%s,server,nowait" % qmp],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
buf = bytearray()
def reader():
    while True:
        d = p.stdout.read(1)
        if not d:
            return
        buf.extend(d)
threading.Thread(target=reader, daemon=True).start()
ACCENT = (0xE8, 0x55, 0x3A)
w = h = best = 0
try:
    end = time.time() + 240
    while time.time() < end and b"lucifer: INIT" not in buf:
        time.sleep(0.5)
    # the console is still a shell while the desktop runs
    p.stdin.write(b"cat /dev/sdctl\r"); p.stdin.flush(); time.sleep(2)
    p.stdin.write(b"echo dump > /usb/usb/ctl\r"); p.stdin.flush(); time.sleep(3)
    s = socket.socket(socket.AF_UNIX); s.connect(qmp)
    f = s.makefile("rw"); f.readline()
    f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush(); f.readline()
    end = time.time() + 90
    while time.time() < end and best < 1000:
        time.sleep(3)
        if os.path.exists(ppm):
            os.unlink(ppm)
        f.write(json.dumps({"execute": "screendump", "arguments": {"filename": ppm}}) + "\n"); f.flush()
        f.readline(); time.sleep(1)
        if not os.path.exists(ppm):
            continue
        d = open(ppm, "rb").read()
        parts = d.split(b"\n", 3)
        w, h = map(int, parts[1].split()); px = parts[3]
        n = 0
        for o in range(0, w*h*3, 3):
            if px[o] == ACCENT[0] and px[o+1] == ACCENT[1] and px[o+2] == ACCENT[2]:
                n += 1
        best = max(best, n)
    # give the network its time before the log is cut: DHCP gives up after ~45 s
    end = time.time() + 60
    while time.time() < end and b"etherusb: default route" not in buf:
        time.sleep(1)
    s.close()
finally:
    p.kill(); p.communicate()
sys.stdout.write(buf.decode(errors="replace"))
print("\nDESKTOP %dx%d accent %d" % (w, h, best))
PYEOF
    OUT="$(cat "$BUILD/$PLAT-desktop.txt")"
    [[ "$VERBOSE" -eq 1 ]] && echo "$OUT"
    pcheck "the card is found where QEMU wires it, and the kernel says that is what it did" "which is where QEMU's raspi4b wires it"
    pcheck "the EMMC2 instance of the SDHCI driver identifies the card" "sd: emmc2: card ready"
    pcheck "sector 0 reads back with a boot signature"   "sd: MBR ok"
    pcheck "the radio is told at RUNTIME that its controller holds the card, and keeps off" "turned out to hold the card"
    pcheck "the FAT32 partition mounts"                  "init: /dev/sd0 mounted on /n/dos"
    pcheck "userspace comes off the card"                "init: /dis grown from /n/dos/dis"
    pcheck "#S serves the partition table init wrote"    "part sd0 2048"
    pcheck "the DWC2 controller enumerates QEMU's hub"   "class 9 (hub)"
    pcheck "a USB keyboard is claimed, through the GIC"  "kbdusb: ep"
    pcheck "a USB mouse is claimed"                      "mouseusb: ep"
    pcheck "USB Ethernet comes up as ether0 (kernel data path)" "etherusb: serving /net/ether0 (kernel data path)"
    pcheck "ether0 has QEMU's address (by DHCP or by etherusb's fallback; see above)" "etherusb: 10.0.2.15 mask"
    pcheck "Lucifer starts"                              "lucifer: INIT"

    #
    # Memory a device can reach (os/bcm/dmamem.c). Several BCM2711 DMA
    # masters address only the first gigabyte and QEMU does not model
    # that, so the limit is enforced in software: busaddr() panics on an
    # address beyond it. For that to mean anything the kernel's own
    # allocations must really BE above the line here -- they are taken
    # from there first -- and then everything above worked THROUGH the
    # bounce: the hub, the keyboard, the mouse and the network adapter
    # were all enumerated with buffers a Pi 4's USB controller could not
    # have addressed.
    #
    pcheck "memory above the first gigabyte is found and used" "MB above the DMA limit at 0x40000000 added"
    pcheck "a DMA arena is reserved below the limit first"     "MB arena below it"
    nb="$(grep -a 'transfers bounced through the DMA arena' <<<"$OUT" | tail -1 | sed -E 's/.*usbotg: ([0-9]+) transfers.*/\1/')"
    if [[ "${nb:-0}" -ge 50 ]]; then
        pass "bcm2711: USB ran through the bounce ($nb transfers had buffers above the DMA limit)"
    else
        fail "bcm2711: only '${nb:-none}' USB transfers bounced -- allocations are not coming from above the limit, so busaddr() is checking nothing"
    fi
    prefute "no driver handed a device an address it could not reach" "busaddr:"

    desk="$(grep -a '^DESKTOP' <<<"$OUT" | tail -1)"
    read -r _ ddim _ dacc <<<"$desk"
    if [[ "$ddim" == "640x480" && "${dacc:-0}" -ge 1000 ]]; then
        pass "bcm2711: Lucifer draws the desktop on the firmware framebuffer ($desk)"
    else
        fail "bcm2711: desktop -- '$desk'"
    fi
    prefute "nothing panics under the desktop"           "panic:"
    prefute "no exception goes unhandled under the desktop" "unhandled exception"
    rm -f "$PCARD"
else
    fail "bcm2711: mkcard failed: $(tail -2 "$BUILD/$PLAT-mkcard.txt" | tr '\n' ' ')"
fi

echo ""
}

if want_platform bcm2711; then
run_bcm2711
fi

echo ""
echo -e "${BOLD}Passed: $PASSED  Failed: $FAILED  Skipped: $SKIPPED${NC}"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0

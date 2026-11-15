#!/bin/sh
# Kernel error handlers and the locals they use (both kernels).
#
# waserror() is setjmp (hosted) or setlabel (native), and its handler is
# reached by a longjmp.  C leaves a local changed after the setjmp, and
# not volatile, indeterminate in the handler.  clang, which builds the
# macOS, iOS and Android emulators and every native kernel, gives the
# handler the value the local had at waserror().  What that did:
#
#   namec (chan.c)      the native kernel's handler closed the channel
#                       walk had already released, and the kernel
#                       panicked in cclose (found on a board, fixed
#                       there first); a create a device refused kept the
#                       channel made for it, in both kernels
#   Exopen, Exstat      an open or stat refused through an exported tree
#   (exportfs.c)        kept its channel, from whoever it is exported to
#   mem2bl (qio.c)      a long write that ran out of memory part way
#                       kept the blocks already made
#   kpipe (sysfile.c)   the native handler closed a channel a second
#                       time when pipe() was refused a descriptor
#   vmrun, the Wi-Fi    lists and buffers kept on an error (native)
#   firmware loaders
#
# gcc reads such locals from memory, so the Linux emulator was not
# affected, and nothing in its test suite could show any of it.
#
# By the source, in both kernels: each of those locals is volatile, and
# namec hands none of them to walk, domount or findmount by address.
# Where clang is installed and the tree has this host's headers, every
# hosted kernel file with an error handler is compiled at -O (as the
# emulators are built) and at -O2, and tools/errlabel-screen.py must
# find no handler with a call folded away or given a folded nil.
# No emulator needed.  tests/errlabel_leak_test.b is the run-time half.

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
PASSED=0
FAILED=0

pass() { echo "PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM

# fn FILE FUNCTION: the function's text, less its comments' lines
fn() {
	awk "/^$2\\(/,/^}/" "$ROOT/$1" | grep -v '^[[:space:]]*/\{0,1\}\*'
}

# vol FILE FUNCTION DECLARATION-REGEX WHAT
vol() {
	if [ ! -f "$ROOT/$1" ]; then
		fail "$1 not found"
		return
	fi
	if fn "$1" "$2" | grep -Eq "$3"; then
		pass "$1: $2: $4 is volatile"
	else
		fail "$1: $2: $4 is not volatile: its error handler may be given the value it had at waserror()"
	fi
}

for k in emu os; do
	vol $k/port/chan.c 'namec' '^[[:space:]]*Chan[[:space:]]*\*[[:space:]]*volatile[[:space:]]+c;' 'the channel walked'
	vol $k/port/chan.c 'namec' '^[[:space:]]*Chan[[:space:]]*\*[[:space:]]*volatile[[:space:]]+cnew;' "the create's channel"
	vol $k/port/chan.c 'namec' '^[[:space:]]*Mhead[[:space:]]*\*[[:space:]]*volatile[[:space:]]+m;' 'the mount head'
	if fn $k/port/chan.c 'namec' | grep -Eq '[^a-z](walk|domount|findmount)\(&c'; then
		fail "$k/port/chan.c: namec gives walk, domount or findmount the address of a volatile local: $(fn $k/port/chan.c 'namec' | grep -En '[^a-z](walk|domount|findmount)\(&c' | head -2 | tr '\n' ' ')"
	else
		pass "$k/port/chan.c: namec reaches walk, domount and findmount through walkc, domountc and findmountc"
	fi
	vol $k/port/exportfs.c 'Exopen' '^[[:space:]]*Chan[[:space:]]*\*[[:space:]]*volatile[[:space:]]+c;' 'the channel opened'
	vol $k/port/exportfs.c 'Exopen' '^[[:space:]]*Mhead[[:space:]]*\*[[:space:]]*volatile[[:space:]]+m;' 'the mount head'
	vol $k/port/exportfs.c 'Exstat' '^[[:space:]]*Chan[[:space:]]*\*[[:space:]]*volatile[[:space:]]+c;' 'the channel stat-ed'
	vol $k/port/qio.c 'mem2bl' '^[[:space:]]*Block[[:space:]]*\*[[:space:]]*volatile[[:space:]]+first;' 'the list of blocks'
	vol $k/port/sysfile.c 'kpipe' '^[[:space:]]*Chan[[:space:]]*\*[[:space:]]*volatile[[:space:]]+c\[2\];' "the pipe's two channels"
done
vol os/port/dis.c 'vmrun' '^[[:space:]]*List[[:space:]]*\*[[:space:]]*volatile[[:space:]]+vl;' 'the argument list its handler frees'
vol os/bcm/ether4330.c 'upload' '^[[:space:]]*uchar[[:space:]]*\*[[:space:]]*volatile[[:space:]]+buf;' 'the firmware buffer'
vol os/bcm/ether4330.c 'upload' '^[[:space:]]*uchar[[:space:]]*\*[[:space:]]*volatile[[:space:]]+cbuf;' 'the read-back buffer'
vol os/bcm/ether4330.c 'reguload' '^[[:space:]]*uchar[[:space:]]*\*[[:space:]]*volatile[[:space:]]+buf;' 'the regulatory buffer'
vol emu/Nt/devfs.c 'fswalk' '^[[:space:]]*volatile[[:space:]]+int[[:space:]]+alloc;' 'alloc'
vol emu/Nt/devfs.c 'fswalk' '^[[:space:]]*Cname[[:space:]]*\*[[:space:]]*volatile[[:space:]]+current;' 'the name walked'
vol emu/Nt/audio.c 'audio_file_open' '^[[:space:]]*volatile[[:space:]]+int[[:space:]]+in_is_open' 'in_is_open'

# What clang makes of the hosted kernel's handlers.
CLANG=$(command -v clang 2>/dev/null)
PY=$(command -v python3 2>/dev/null)
INC=""
EMUDIR=""
DEF=""
case "$(uname -s)-$(uname -m)" in
Linux-x86_64)	INC=$ROOT/Linux/amd64/include; EMUDIR=$ROOT/emu/Linux; DEF=-DLINUX_AMD64;;
Linux-aarch64)	INC=$ROOT/Linux/arm64/include; EMUDIR=$ROOT/emu/Linux; DEF=-DLINUX_ARM64;;
Darwin-arm64)	INC=$ROOT/MacOSX/arm64/include; EMUDIR=$ROOT/emu/MacOSX; DEF=-DMACOSX_ARM64;;
Darwin-x86_64)	INC=$ROOT/MacOSX/amd64/include; EMUDIR=$ROOT/emu/MacOSX; DEF=-DMACOSX_AMD64;;
esac
if [ -z "$CLANG" ] || [ -z "$PY" ] || [ -z "$INC" ] || [ ! -f "$INC/lib9.h" ]; then
	echo "SKIP: the compiled handlers (no clang, no python3, or no headers for this host)"
else
	for O in -O -O2; do
		mkdir -p "$BUILD/ir$O"
		args=""
		n=0
		for f in "$ROOT"/emu/port/*.c "$EMUDIR"/*.c; do
			grep -q 'waserror()' "$f" || continue
			b=$(basename "$f" .c)
			if (cd "$EMUDIR" && "$CLANG" $O -S -emit-llvm -w -DROOT='"/"' -DEMU $DEF -I. -I../port -I"$INC" \
				-I"$ROOT/include" -I"$ROOT/libinterp" -fno-strict-aliasing -fcommon \
				-o "$BUILD/ir$O/$b.ll" "$f") 2>/dev/null; then
				args="$args $f $BUILD/ir$O/$b.ll"
				n=$((n+1))
			fi
		done
		# chan.c and exportfs.c are the ones this test is about
		if [ ! -s "$BUILD/ir$O/chan.ll" ] || [ ! -s "$BUILD/ir$O/exportfs.ll" ]; then
			echo "SKIP: the compiled handlers at $O (chan.c or exportfs.c does not compile to IR here)"
			continue
		fi
		if "$PY" "$ROOT/tools/errlabel-screen.py" $args > "$BUILD/screen$O.out" 2>&1; then
			pass "clang $O: no error handler in $n hosted kernel files has a call folded away or given a folded nil"
		else
			fail "clang $O: $(head -6 "$BUILD/screen$O.out" | sed "s|$ROOT/||g" | tr '\n' ';' | cut -c1-700)"
		fi
	done
fi

echo
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]

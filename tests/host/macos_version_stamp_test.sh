#!/bin/sh
# Verify the SDL3 build script stamps include/version.h without destroying it.
#
# Three properties, the first two of which the previous mechanism got wrong:
#   - a failed build restores what was there, not what git has, so an
#     in-progress edit to version.h survives;
#   - the stamp anchors on the unstamped form, so a run cannot stamp an
#     already-stamped string;
#   - the anchor is checked against the build's echoed Version line and
#     against a hand-fed stamp, because with the restore working, the restored
#     file looks the same whichever sed ran and cannot pin the anchor.
#
# The build is expected to fail here, and the pkg-config stub is what makes
# that certain: it answers --exists and --modversion but falls through to a
# bare `exit 0` for --cflags/--libs, so the compile gets no SDL3 include
# paths and dies. Do not tighten the stub — the premise of this test depends
# on the build failing after the stamp, even on machines where SDL3 is
# installed and mk is on PATH (the build script adds $ROOT/MacOSX/arm64/bin
# itself). Failing after the stamp is the point: it exercises the EXIT trap,
# which is the path that used to lose the edit.

set -eu

if [ "$(uname -s)" != "Darwin" ]; then
    echo "SKIP: macos_version_stamp is macOS-only (build-macos-sdl3.sh's BSD sed -i '' does not run under GNU sed)"
    exit 77
fi

ROOT=$(CDPATH= cd "$(dirname "$0")/../.." && pwd)
VERSION_H="$ROOT/include/version.h"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/macos-version-stamp.XXXXXX")

ORIGINAL=$TMP/version.h.original
cp "$VERSION_H" "$ORIGINAL"
cleanup() {
	cp "$ORIGINAL" "$VERSION_H"
	rm -rf "$TMP"
}
trap cleanup EXIT HUP INT TERM

# Satisfy the SDL3 probe so this test does not depend on SDL3 being installed.
cat > "$TMP/pkg-config" <<'STUB'
#!/bin/sh
case "$1" in
--exists) exit 0 ;;
--modversion) echo "0.0.0-stub" ;;
esac
exit 0
STUB
chmod +x "$TMP/pkg-config"

# Stand in for a developer's in-progress edit.
sed 's|InferNode 0\.1 (|InferNode 0.1 (LOCAL EDIT |' "$ORIGINAL" > "$VERSION_H"
cp "$VERSION_H" "$TMP/version.h.edited"

run_build() {
	if PATH="$TMP:$PATH" "$ROOT/build-macos-sdl3.sh" >"$TMP/out" 2>&1; then
		echo "build unexpectedly succeeded; this test needs it to fail after stamping" >&2
		exit 1
	fi
}

run_build

# The build echoes the line it just stamped. With the restore working, the
# restored file is identical no matter which sed ran, so version.h cannot
# distinguish an anchored stamp from an unanchored one -- assert on the
# output instead: the stamped form, with `build ` exactly once.
version_line=$(grep '^Version: ' "$TMP/out")
if ! printf '%s\n' "$version_line" | grep -q 'InferNode 0\.1 build [0-9]*-[0-9a-f]* (' ||
   [ "$(printf '%s\n' "$version_line" | grep -o 'build ' | wc -l | tr -d ' ')" -ne 1 ]; then
	echo "build output does not show exactly one anchored stamp:" >&2
	echo "  $version_line" >&2
	exit 1
fi

if ! cmp -s "$VERSION_H" "$TMP/version.h.edited"; then
	echo "version.h was not restored to the edited content" >&2
	echo "expected:"; sed 's/^/  /' "$TMP/version.h.edited" >&2
	echo "got:";      sed 's/^/  /' "$VERSION_H" >&2
	exit 1
fi

# A second run must leave it identical again.
run_build
if ! cmp -s "$VERSION_H" "$TMP/version.h.edited"; then
	echo "version.h differs after a second run" >&2
	exit 1
fi
if grep -c "build " "$VERSION_H" | grep -qv '^0$'; then
	echo "a build stamp was left behind in version.h" >&2
	sed 's/^/  /' "$VERSION_H" >&2
	exit 1
fi

# The anchor only bites when a stamp is already present -- the state a run
# is left in when its restore failed. Feed one in by hand: an unanchored sed
# stamps the stamp and the echoed Version line shows `build ` twice, while
# every check on the restored file would pass, because the trap restores the
# doubly-stamped copy just as faithfully.
sed 's|InferNode 0\.1 (|InferNode 0.1 build 20260101-deadbeef (|' "$TMP/version.h.edited" > "$VERSION_H"
cp "$VERSION_H" "$TMP/version.h.stamped"
run_build
version_line=$(grep '^Version: ' "$TMP/out")
if [ "$(printf '%s\n' "$version_line" | grep -o 'build ' | wc -l | tr -d ' ')" -ne 1 ]; then
	echo "an already-stamped version.h was stamped again:" >&2
	echo "  $version_line" >&2
	exit 1
fi
if ! cmp -s "$VERSION_H" "$TMP/version.h.stamped"; then
	echo "version.h was not restored to the stamped content it started from" >&2
	exit 1
fi
cp "$TMP/version.h.edited" "$VERSION_H"

echo "macos_version_stamp: PASS"

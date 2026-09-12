#!/bin/sh
# Verify the macOS build scripts refuse to start when a native build tool is
# absent, and name the bootstrap in the message.
#
# Both tools matter. makemk.sh builds mk alone, so mk present and limbo absent
# is the state a half-finished bootstrap leaves behind, and it is the case the
# build used to hit as a bare "limbo: command not found" minutes in.

set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/build-macos-preflight.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# Both build scripts prepend "$ROOT/MacOSX/arm64/bin" to PATH before the
# preflight check, so an empty PATH is not enough to hide the tools on a
# machine where they are actually built — the preflight would never fire and
# the test would fail on exactly the platform it is written for.
#
# Hiding the real tools by moving them aside is not an option: a SIGKILL
# between the stash and the restore (CI timeout kill, OOM kill) would leave
# the tree without its native build tools and no way to notice. Instead the
# test never touches the real tree at all. It copies the two scripts into a
# fake tree under $TMP with an empty MacOSX/arm64/bin and runs them from
# there. Both scripts derive ROOT from "$0", so they find the empty bin
# directory on their own, the preflight fires, and the tree's real tools are
# untouched no matter how the test dies.
FAKETREE="$TMP/faketree"
mkdir -p "$FAKETREE/MacOSX/arm64/bin"
cp "$ROOT/build-macos-headless.sh" "$ROOT/build-macos-sdl3.sh" "$FAKETREE/"

# Keep dirname available while controlling which build tools are on PATH.
ln -s "$(command -v dirname)" "$TMP/dirname"

# The SDL3 script probes for the library before anything else. Satisfy that
# probe so this test isolates the build-tool preflight and does not depend on
# SDL3 being installed.
cat > "$TMP/pkg-config" <<'STUB'
#!/bin/sh
case "$1" in
--exists) exit 0 ;;
--modversion) echo "0.0.0-stub" ;;
esac
exit 0
STUB
chmod +x "$TMP/pkg-config"

expect_refusal() {
	script=$1
	missing=$2
	if output=$(env PATH="$TMP" "$FAKETREE/$script" 2>&1); then
		echo "$script: unexpectedly succeeded without $missing" >&2
		exit 1
	fi
	for want in \
		"required native build tool(s) not found: $missing" \
		"./makemk.sh" \
		'SYSTARG=MacOSX OBJTYPE=arm64 ./makemk.sh' \
		'export ROOT="$PWD" PATH="$PWD/MacOSX/arm64/bin:$PATH"' \
		"lib9 libbio libmp libsec libmath utils/iyacc limbo"; do
		if ! printf '%s\n' "$output" | grep -F "$want" >/dev/null; then
			echo "$script [$missing]: expected the message to contain: $want" >&2
			echo "got:" >&2
			printf '%s\n' "$output" | sed 's/^/  /' >&2
			exit 1
		fi
	done
}

for script in build-macos-headless.sh build-macos-sdl3.sh; do
	# Neither tool present.
	rm -f "$TMP/mk"
	expect_refusal "$script" "mk limbo"

	# mk present, limbo absent — the half-bootstrapped case.
	printf '#!/bin/sh\nexit 0\n' > "$TMP/mk"
	chmod +x "$TMP/mk"
	expect_refusal "$script" "limbo"
done

echo "build_macos_preflight: PASS"

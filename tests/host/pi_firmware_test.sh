#!/bin/sh
#
# tests/host/pi_firmware_test.sh
#
# tools/pi-firmware.sh is the only path by which the CYW43455 firmware
# reaches a Raspberry Pi 3B+ card, and the manifest it reads is the only
# thing in the tree that says which bytes are the right ones.  The
# failure that matters is quiet: a tool that installs a file whose hash
# did not match would put an unverified blob on the card and the kernel
# would upload it into the radio.  So this test drives the tool through
# its verification path with fixtures it makes itself, including a
# deliberate mismatch, and checks the committed manifest for shape.
#
# No network.  The tool's --from option takes the files from a
# directory, and the test writes that directory (random bytes under the
# upstream basenames) together with a manifest whose hashes it computed
# from them.  The real firmware is never needed and never fetched; the
# real manifest is only parsed (--print), never acted on.
#
# The tool's default mode needs curl.  The test needs none of the
# download path, but it follows the suite's rule that a test of a
# curl-based tool skips (exit 77) rather than passes on a host without
# curl, so that a green run cannot mean "the tool's normal mode was
# never runnable here".  The one thing it does check about curl is the
# refusal: without --from and without curl on PATH the tool must stop
# with status 2 and say so, before touching the destination.
#
# Run from project root: ./tests/host/pi_firmware_test.sh
#

. "$(dirname "$0")/common.sh"

TOOL="$ROOT/tools/pi-firmware.sh"
REALMANIFEST="$ROOT/tools/pi-firmware-manifest.txt"

command -v curl >/dev/null 2>&1 || { echo "SKIP: curl not on PATH"; exit 77; }
if command -v sha256sum >/dev/null 2>&1; then
	sha256of() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
	sha256of() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
	echo "SKIP: neither sha256sum nor shasum on PATH"; exit 77
fi
[ -f "$TOOL" ] || { echo "FAIL: $TOOL missing"; exit 1; }
[ -f "$REALMANIFEST" ] || { echo "FAIL: $REALMANIFEST missing"; exit 1; }

passed=0
failed=0
pass() { passed=$((passed + 1)); echo "PASS: $1"; }
fail() { failed=$((failed + 1)); echo "FAIL: $1"; }
check() {
	# check <description> <command...>: pass if the command succeeds.
	desc=$1; shift
	if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

T=$(mktemp -d "${TMPDIR:-/tmp}/pi_firmware_test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

# ---- fixtures ---------------------------------------------------------
# Three files under the basenames the manifest's URLs end in.  The sizes
# are unequal so a size/hash swap between records could not pass.
FIX="$T/fixtures"
mkdir -p "$FIX"
head -c 4096 /dev/urandom > "$FIX/cyfmac43455-sdio-standard.bin"
head -c 300  /dev/urandom > "$FIX/cyfmac43455-sdio.clm_blob"
printf 'macaddr=00:00:00:00:00:00\nnocrc=1\n' > "$FIX/brcmfmac43455-sdio.txt"

COMMIT=0123456789abcdef0123456789abcdef01234567
URLBASE="https://example.invalid/firmware-nonfree/$COMMIT/debian/config/brcm80211"
mkfile() {
	# mkfile <install-name> <fixture-basename> <subdir>
	printf 'file %s %s %s test-licence %s/%s/%s\n' \
		"$1" "$(sha256of "$FIX/$2")" "$(wc -c < "$FIX/$2" | tr -d ' ')" "$URLBASE" "$3" "$2"
}
MAN="$T/manifest.txt"
{
	echo "# test manifest"
	echo "commit $COMMIT"
	mkfile brcmfmac43455-sdio.bin cyfmac43455-sdio-standard.bin cypress
	mkfile brcmfmac43455-sdio.clm_blob cyfmac43455-sdio.clm_blob cypress
	mkfile brcmfmac43455-sdio.txt brcmfmac43455-sdio.txt brcm
} > "$MAN"

# ---- 1. the good path: install from fixtures, names and bytes --------
CARD="$T/card"
mkdir -p "$CARD"
if sh "$TOOL" --from "$FIX" --manifest "$MAN" "$CARD" > "$T/install.out" 2>&1; then
	pass "install from --from directory succeeds"
else
	fail "install from --from directory succeeds (see $T/install.out)"
	cat "$T/install.out"
fi
check "installs brcmfmac43455-sdio.bin" test -f "$CARD/firmware/brcmfmac43455-sdio.bin"
check "installs brcmfmac43455-sdio.clm_blob" test -f "$CARD/firmware/brcmfmac43455-sdio.clm_blob"
check "installs brcmfmac43455-sdio.txt" test -f "$CARD/firmware/brcmfmac43455-sdio.txt"
check ".bin on the card is byte-identical to the source" \
	cmp "$FIX/cyfmac43455-sdio-standard.bin" "$CARD/firmware/brcmfmac43455-sdio.bin"
check ".txt on the card is byte-identical to the source" \
	cmp "$FIX/brcmfmac43455-sdio.txt" "$CARD/firmware/brcmfmac43455-sdio.txt"
check "output names every installed file" \
	sh -c "grep -c '^pi-firmware: installed ' '$T/install.out' | grep -qx 3"
check "output states the licence position" grep -q 'binary-redistribution' "$T/install.out"
check "output names the pinned commit" grep -q "$COMMIT" "$T/install.out"
check "nothing beyond the three files was written" \
	sh -c "ls '$CARD/firmware' | wc -l | tr -d ' ' | grep -qx 3"

# ---- 2. --verify agrees with what was installed ------------------------
check "--verify passes on a freshly installed card" \
	sh "$TOOL" --verify --manifest "$MAN" "$CARD"

# ---- 3. the mismatch: one byte appended to one fixture -----------------
# The tool must refuse, install nothing (not even the two good files),
# and say which file, with both hashes, so the operator can see it was
# the download and not the manifest that moved.
BAD="$T/bad"
mkdir -p "$BAD"
cp "$FIX"/* "$BAD/"
printf x >> "$BAD/cyfmac43455-sdio.clm_blob"
CARD2="$T/card2"
mkdir -p "$CARD2"
sh "$TOOL" --from "$BAD" --manifest "$MAN" "$CARD2" > "$T/bad.out" 2>&1
rc=$?
check "mismatch exits 1" test "$rc" -eq 1
check "mismatch names the file" grep -q 'brcmfmac43455-sdio.clm_blob: SHA256 MISMATCH' "$T/bad.out"
check "mismatch prints expected and got" \
	sh -c "grep -q '^ *expected [0-9a-f]\{64\}' '$T/bad.out' && grep -q '^ *got  *[0-9a-f]\{64\}' '$T/bad.out'"
check "mismatch installs nothing" \
	sh -c "[ ! -e '$CARD2/firmware/brcmfmac43455-sdio.bin' ] && [ ! -e '$CARD2/firmware/brcmfmac43455-sdio.clm_blob' ] && [ ! -e '$CARD2/firmware/brcmfmac43455-sdio.txt' ]"

# ---- 4. --verify catches a card whose file changed after install -------
printf x >> "$CARD/firmware/brcmfmac43455-sdio.txt"
sh "$TOOL" --verify --manifest "$MAN" "$CARD" > "$T/verify.out" 2>&1
rc=$?
check "--verify exits 1 on a tampered card" test "$rc" -eq 1
check "--verify names the tampered file" grep -q '^MISMATCH .*brcmfmac43455-sdio.txt' "$T/verify.out"
check "--verify still reports the good files" grep -q '^ok .*brcmfmac43455-sdio.bin' "$T/verify.out"

# ---- 5. manifest shape is enforced, not assumed -------------------------
# A URL that names a different revision than the commit line.
sed "s|$COMMIT/debian/config/brcm80211/cypress/cyfmac43455-sdio.clm_blob|ffffffffffffffffffffffffffffffffffffffff/debian/config/brcm80211/cypress/cyfmac43455-sdio.clm_blob|" \
	"$MAN" > "$T/float.txt"
sh "$TOOL" --manifest "$T/float.txt" --print > "$T/float.out" 2>&1
rc=$?
check "a URL at another revision is rejected (exit 2)" test "$rc" -eq 2
check "the floated file is named" grep -q 'clm_blob: URL does not name the pinned commit' "$T/float.out"

# A hash that is not 64 hex characters.
sed 's/^\(file brcmfmac43455-sdio.bin \)[0-9a-f]*/\1deadbeef/' "$MAN" > "$T/shorthash.txt"
sh "$TOOL" --manifest "$T/shorthash.txt" --print > /dev/null 2>&1
rc=$?
check "a short hash is rejected (exit 2)" test "$rc" -eq 2

# A missing field.
sed 's/ test-licence / /' "$MAN" > "$T/nofield.txt"
sh "$TOOL" --manifest "$T/nofield.txt" --print > /dev/null 2>&1
rc=$?
check "a file line with a missing field is rejected (exit 2)" test "$rc" -eq 2

# ---- 6. the committed manifest ----------------------------------------
sh "$TOOL" --print > "$T/real.out" 2>&1
rc=$?
check "the committed manifest parses" test "$rc" -eq 0
check "the committed manifest pins three files" \
	sh -c "grep -c '^    sha256 ' '$T/real.out' | grep -qx 3"
for n in brcmfmac43455-sdio.bin brcmfmac43455-sdio.clm_blob brcmfmac43455-sdio.txt; do
	check "the committed manifest installs $n" grep -qx "$n" "$T/real.out"
done
check "the committed manifest pins RPi-Distro/firmware-nonfree by commit" \
	sh -c "grep '^    from ' '$T/real.out' | grep -v -q 'RPi-Distro/firmware-nonfree/[0-9a-f]\{40\}/' && exit 1 || exit 0"
check "the committed manifest names the licence" grep -q 'binary-redist-Cypress' "$T/real.out"
check "no firmware blob is tracked" \
	sh -c "cd '$ROOT' && git ls-files | grep -q -i 'brcmfmac43455\|cyfmac43455' && exit 1 || exit 0"

# ---- 7. no curl, no --from: refuse before touching the destination ----
# A PATH with everything the tool needs except curl.  The destination
# directory is deliberately absent so the order of checks shows: the
# tool must refuse for lack of curl only after it has looked at the
# destination, and must not create it on the way out.
BIN="$T/bin"
mkdir -p "$BIN"
for u in sh sed grep head cut wc tr mkdir mktemp id cp rm dirname basename shasum sha256sum; do
	p=$(command -v "$u" 2>/dev/null) && ln -s "$p" "$BIN/$u"
done
CARD3="$T/card3"
mkdir -p "$CARD3"
PATH="$BIN" "$BIN/sh" "$TOOL" --manifest "$MAN" "$CARD3" > "$T/nocurl.out" 2>&1
rc=$?
check "without curl the tool exits 2" test "$rc" -eq 2
check "without curl the tool says so" grep -q 'curl is not on PATH' "$T/nocurl.out"
check "without curl nothing is installed" \
	sh -c "ls '$CARD3/firmware' 2>/dev/null | wc -l | tr -d ' ' | grep -qx 0"

# ---- 8. an unwritable destination is refused, and sudo is never named --
RO="$T/ro"
mkdir -p "$RO"
chmod 555 "$RO"
sh "$TOOL" --from "$FIX" --manifest "$MAN" "$RO" > "$T/ro.out" 2>&1
rc=$?
chmod 755 "$RO"
if [ "$(id -u)" -eq 0 ]; then
	pass "unwritable destination (skipped: running as root)"
else
	check "an unwritable destination exits 2" test "$rc" -eq 2
fi
# sudo in command position: at the start of a line or after ; & | or
# $(, followed by an argument.  The tool's own messages mention the word,
# which is why this is not a plain grep for it.
check "the tool never invokes sudo" \
	sh -c "! grep -v '^[[:space:]]*#' '$TOOL' | grep -Eq '(^[[:space:]]*|[;&|][[:space:]]*|\\\$\\([[:space:]]*)sudo[[:space:]]'"

echo
echo "Passed: $passed  Failed: $failed"
[ "$failed" -eq 0 ]

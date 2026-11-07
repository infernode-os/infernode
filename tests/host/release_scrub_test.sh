#!/bin/sh
#
# release_scrub_test.sh -- tools/release-scrub.sh, which keeps private
# keys out of the release packages:
#
#	a stage made of the tree's shipped directories loses
#	usr/inferno/keyring/default (a test key, the same on every install
#	that shipped it) and keeps the empty keyring/, and nothing else in
#	those directories is taken for a key;
#	a private key left anywhere else -- an Inferno key file, a PEM
#	one -- gets the stage refused, and named;
#	every job in release.yml that copies the tree's usr/ into a package
#	runs the scrub after it (the Windows job, in PowerShell, its own
#	copy of the same two steps).

ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT" || exit 1

fail=0
pass() { echo "PASS: $1"; }
failed() { echo "FAIL: $1"; fail=1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/scrub.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM

# the directories every release job copies, as far as this checkout has them
mkdir -p "$tmp/stage"
for d in dis acme xenith lib fonts man doc icons module services locale usr mnt n appl; do
	[ -d "$d" ] && cp -a "$d" "$tmp/stage/"
done
[ -f "$tmp/stage/usr/inferno/keyring/default" ] || { echo "release_scrub_test: SKIP (the tree has no usr/inferno/keyring/default to remove)"; exit 77; }

if sh tools/release-scrub.sh "$tmp/stage" > "$tmp/out" 2>&1; then
	pass "a stage of the tree's shipped directories passes, once scrubbed"
else
	failed "the tree's own directories were refused: $(grep 'private key is in' "$tmp/out" | head -3 | tr '\n' ' ')"
fi
[ -e "$tmp/stage/usr/inferno/keyring/default" ] && failed "usr/inferno/keyring/default is still in the stage" \
	|| pass "usr/inferno/keyring/default (the tree's test key) is removed"
[ -d "$tmp/stage/usr/inferno/keyring" ] && pass "the empty keyring/ stays, where a user's own key goes" \
	|| failed "keyring/ itself was removed"

# a key that did not come in through usr/*/keyring/: refused, by name
mkdir -p "$tmp/stray/lib"
cp usr/inferno/keyring/default "$tmp/stray/lib/old-key"
if sh tools/release-scrub.sh "$tmp/stray" > "$tmp/out" 2>&1; then
	failed "an Inferno key file in lib/ was shipped"
elif grep -q 'private key is in the package: .*lib/old-key' "$tmp/out"; then
	pass "an Inferno key file anywhere else gets the package refused, by name"
else
	failed "the refusal does not name the key: $(tail -2 "$tmp/out" | tr '\n' ' ')"
fi
rm -rf "$tmp/stray"; mkdir -p "$tmp/stray/services"
printf -- '-----BEGIN EC PRIVATE KEY-----\nMHcCAQEE\n-----END EC PRIVATE KEY-----\n' > "$tmp/stray/services/tls.pem"
if sh tools/release-scrub.sh "$tmp/stray" > "$tmp/out" 2>&1; then
	failed "a PEM private key was shipped"
else
	pass "a PEM private key gets the package refused"
fi

# every package job: one scrub after each copy of usr/
W=.github/workflows/release.yml
copies=$(grep -c 'for d in dis acme xenith lib fonts man doc icons module services locale usr mnt n appl; do' "$W")
scrubs=$(grep -c 'sh tools/release-scrub.sh "' "$W")
if [ "$copies" -gt 0 ] && [ "$copies" = "$scrubs" ]; then
	pass "each of release.yml's $copies shell package jobs scrubs what it copied"
else
	failed "release.yml copies the tree into a package $copies times and scrubs $scrubs"
fi
if grep -q '"usr", "mnt"' "$W" && grep -q 'release-scrub: refusing \$Stage' "$W"; then
	pass "the Windows package is scrubbed and checked too"
else
	failed "the Windows package copies usr and is not scrubbed"
fi

[ $fail = 0 ] || exit 1
exit 0

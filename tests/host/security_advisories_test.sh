#!/bin/sh
#
# security_advisories_test.sh -- tools/security-advisories.py and the
# advisories in docs/security-advisories/:
#
#	the tree's advisories pass `check`, and docs/SECURITY-ADVISORIES.md
#	is what `index` writes; with the history and tags at hand (a full
#	clone) each fix commit is in the release its advisory names, and
#	no release holds one said to be unreleased;
#	on a copy, each fault `check` is for is refused, named: a header
#	key out of order or unknown, a severity GitHub does not take, an
#	Affected range that does not end where Patched begins, an id out
#	of sequence, a missing section, an index not regenerated;
#	`file` without --submit sends nothing, makes a draft's payload for
#	each advisory with no GHSA (version range, patched release, CWEs,
#	the ISA id in the text), skips an unreleased fix unless asked, and
#	refuses --submit with no token.
#
# No emulator needed.

ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT" || exit 1
TOOL="$ROOT/tools/security-advisories.py"

fail=0
pass() { echo "PASS: $1"; }
failed() { echo "FAIL: $1"; fail=1; }

command -v python3 >/dev/null 2>&1 || { echo "security_advisories_test: SKIP (no python3)"; exit 77; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/secadv.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM

# the tree as it is
if python3 "$TOOL" check > "$tmp/out" 2>&1; then
	pass "the tree's advisories pass check, index current ($(tail -1 "$tmp/out"))"
else
	failed "check refused the tree's advisories:"; sed 's/^/	/' "$tmp/out"
fi

if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = false ] &&
   git rev-parse -q --verify v0.11.0 >/dev/null 2>&1; then
	if python3 "$TOOL" check --history > "$tmp/out" 2>&1; then
		pass "each fix commit is in the release its advisory names"
	else
		failed "check --history:"; sed 's/^/	/' "$tmp/out"
	fi
else
	echo "SKIP: check --history (a shallow clone or no release tags)"
fi

# a copy to break
fresh() {
	rm -rf "$tmp/t"
	mkdir -p "$tmp/t/docs"
	cp -R docs/security-advisories "$tmp/t/docs/"
	cp docs/SECURITY-ADVISORIES.md "$tmp/t/docs/"
}
refused() {	# what, pattern
	if SECADV_ROOT="$tmp/t" python3 "$TOOL" check > "$tmp/out" 2>&1; then
		failed "$1: check passed"
	elif grep -q -- "$2" "$tmp/out"; then
		pass "$1 refused"
	else
		failed "$1: refused, but not for '$2':"; sed 's/^/	/' "$tmp/out"
	fi
}
A=$tmp/t/docs/security-advisories/ISA-2026-005.md

fresh
SECADV_ROOT="$tmp/t" python3 "$TOOL" check > /dev/null 2>&1 &&
	pass "an unchanged copy passes" || failed "an unchanged copy does not pass"

fresh; sed -i.bak 's/^Severity: critical$/Severity: moderate/' "$A"
refused "a severity GitHub does not take (moderate)" "Severity 'moderate'"

fresh; sed -i.bak 's/^Affected: < 0.5.0$/Affected: < 0.6.0/' "$A"
refused "an Affected range that does not end at Patched" "does not end '< 0.5.0'"

fresh; sed -i.bak 's/^Affected: < 0.5.0$/Affected: before 0.5.0/' "$A"
refused "an Affected that is not a range" "is not a range"

fresh; sed -i.bak 's/^CWE: .*/CWE: 295/' "$A"
refused "a CWE without its prefix" "CWE '295'"

fresh; sed -i.bak 's/^Commits: .*/Commits: HEAD/' "$A"
refused "a commit that is no hash" "are not abbreviated hashes"

fresh; sed -i.bak 's/^Severity:/Severty:/' "$A"
refused "an unknown header key" "is not one of"

fresh; sed -i.bak '/^## Workarounds$/d' "$A"
refused "a missing Workarounds section" "no '## Workarounds' section"

fresh; sed -i.bak 's/^GHSA:$/GHSA: GHSA-1234-5678-abcd/' "$A"
refused "a GHSA id that is none" "is not a GHSA id"

fresh; mv "$A" "$tmp/t/docs/security-advisories/ISA-2026-099.md"
sed -i.bak 's/^Id: ISA-2026-005$/Id: ISA-2026-099/' "$tmp/t/docs/security-advisories/ISA-2026-099.md"
rm -f "$tmp/t/docs/security-advisories/"*.bak
refused "an id out of sequence" "out of sequence"

fresh; sed -i.bak 's/^Title: .*/Title: something else entirely/' "$A"; rm -f "$A.bak"
refused "an index not regenerated after a change" "not what"
SECADV_ROOT="$tmp/t" python3 "$TOOL" index > /dev/null &&
SECADV_ROOT="$tmp/t" python3 "$TOOL" check > /dev/null 2>&1 &&
	pass "index puts it right" || failed "check fails after index"

# filing, without sending anything
fresh
U=$(grep -l '^Patched: unreleased$' "$tmp/t/docs/security-advisories/"*.md | head -1)
SECADV_ROOT="$tmp/t" GITHUB_TOKEN= python3 "$TOOL" file ISA-2026-005 > "$tmp/out" 2>&1
python3 - "$tmp/out" <<'EOF' && pass "file's dry run gives a draft's payload for ISA-2026-005" || failed "file's dry-run payload for ISA-2026-005"
import json, sys
text = open(sys.argv[1]).read()
start = text.index("{"); end = text.rindex("}") + 1
p = json.loads(text[start:end])
v = p["vulnerabilities"][0]
assert v["package"] == {"ecosystem": "other", "name": "infernode"}, v
assert v["vulnerable_version_range"] == "< 0.5.0", v
assert v["patched_versions"] == "0.5.0", v
assert p["severity"] == "critical" and "CWE-295" in p["cwe_ids"], p
assert "InferNode advisory id: ISA-2026-005" in p["description"]
assert "/releases/tag/v0.5.0" in p["description"]
assert "not sent (dry run" in text
EOF
if [ -n "$U" ]; then
	id=$(basename "$U" .md)
	SECADV_ROOT="$tmp/t" python3 "$TOOL" file "$id" > "$tmp/out" 2>&1
	grep -q "$id: fix unreleased; skipped" "$tmp/out" &&
		pass "an unreleased fix ($id) is not drafted unless asked" ||
		failed "an unreleased fix was drafted: $(head -2 "$tmp/out")"
	SECADV_ROOT="$tmp/t" python3 "$TOOL" file --include-unreleased "$id" > "$tmp/out" 2>&1
	grep -q '"patched_versions": null' "$tmp/out" &&
		pass "asked for, its draft names no patched release" ||
		failed "an unreleased fix's draft names a patched release"
fi
if SECADV_ROOT="$tmp/t" GITHUB_TOKEN= python3 "$TOOL" file --submit ISA-2026-005 > "$tmp/out" 2>&1; then
	failed "--submit with no token went on"
else
	grep -q 'needs GITHUB_TOKEN' "$tmp/out" && pass "--submit with no token is refused" ||
		failed "--submit with no token: $(head -1 "$tmp/out")"
fi
grep -q '^GHSA:$' "$A" && pass "a dry run writes nothing into the advisory" ||
	failed "a dry run changed the advisory's GHSA line"

# filing, against a fake GitHub that already holds ISA-2026-002 (on its
# second page of listings)
fresh
python3 "$ROOT/tests/host/security_advisories/fake_github.py" "$tmp/port" "$tmp/log" \
	ISA-2026-099=GHSA-2222-3333-4444 ISA-2026-002=GHSA-xxxx-wwww-vvvv &
fake=$!
trap 'kill $fake 2>/dev/null; rm -rf "$tmp"' EXIT INT TERM
i=0; while [ ! -s "$tmp/port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
if [ ! -s "$tmp/port" ]; then
	failed "the fake GitHub did not start"
else
	api="http://127.0.0.1:$(cat "$tmp/port")"
	no_proxy=127.0.0.1${no_proxy:+,$no_proxy}; NO_PROXY=$no_proxy; export no_proxy NO_PROXY
	D=$tmp/t/docs/security-advisories
	if SECADV_ROOT="$tmp/t" SECADV_API="$api" GITHUB_TOKEN=tok-test \
	   python3 "$TOOL" file --submit ISA-2026-001 ISA-2026-002 ISA-2026-005 ISA-2026-032 > "$tmp/out" 2>&1; then
		pass "--submit ran"
	else
		failed "--submit:"; sed 's/^/	/' "$tmp/out"
	fi
	posts=$(grep -c '^POST ' "$tmp/log")
	[ "$posts" = 2 ] && pass "two drafts made (001, 005), none for one GitHub has or one unreleased" ||
		failed "$posts drafts made, not 2: $(cut -c1-120 "$tmp/log")"
	grep -q '^GET .*page=2' "$tmp/log" && pass "the listing is followed to its second page" ||
		failed "the second page of the listing was not read"
	grep -q 'Bearer tok-test' "$tmp/log" && ! grep -v 'Bearer tok-test' "$tmp/log" | grep -q . &&
		pass "every request carries the token" || failed "a request without the token"
	grep -q 'ISA-2026-032' "$tmp/log" &&
		failed "the unreleased ISA-2026-032 was sent" || pass "the unreleased fix was not sent"
	g1=$(sed -n 's/^GHSA: //p' "$D/ISA-2026-001.md")
	g2=$(sed -n 's/^GHSA: //p' "$D/ISA-2026-002.md")
	case "$g1" in GHSA-cfgh-jmpq-*) pass "the new draft's id is written into ISA-2026-001 ($g1)";;
		*) failed "ISA-2026-001's GHSA line: '$g1'";; esac
	[ "$g2" = GHSA-xxxx-wwww-vvvv ] && pass "the id GitHub had is recorded for ISA-2026-002" ||
		failed "ISA-2026-002's GHSA line: '$g2'"
	grep -q "$g1" "$tmp/t/docs/SECURITY-ADVISORIES.md" && pass "the index is regenerated with it" ||
		failed "the index does not name $g1"
	SECADV_ROOT="$tmp/t" python3 "$TOOL" check > /dev/null 2>&1 &&
		pass "the tree passes check after filing" || failed "check fails after filing"
	: > "$tmp/log"
	SECADV_ROOT="$tmp/t" SECADV_API="$api" GITHUB_TOKEN=tok-test \
		python3 "$TOOL" file --submit ISA-2026-001 ISA-2026-005 > "$tmp/out" 2>&1
	grep -q '^POST' "$tmp/log" && failed "a second run made drafts again" ||
		pass "a second run makes nothing: the advisories have their GHSA ids"
	kill $fake 2>/dev/null
fi

exit $fail

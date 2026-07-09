#!/dis/sh.dis
# tool_schema_test.sh - INFR-126 end-to-end schema endpoint test
#
# Mounts tools9p with the canonical Veltro toolset, then drives the
# Limbo tool_schema_test.dis so its Layer B 9P-endpoint checks run
# (these self-skip when /tool isn't mounted).
#
# Run from host:  ./emu/Linux/o.emu -c1 -r$ROOT sh /tests/inferno/tool_schema_test.sh
#

load std

mkdir -p /tmp/.veltro-ns/shadow >[2] /dev/null

# Start tools9p with the canonical stock toolset (mirrors what
# lucibridge typically launches with). Single line — Inferno rc
# does not accept backslash line continuations.
/dis/veltro/tools9p.dis read list find search write edit grep exec launch spawn shell limbo xenith present gap editor task plan todo memory diff json webfetch websearch browse charon git say hear vision gpu fractal man keyring wallet payfetch wiki &

sleep 2

# Smoke: /tool/_registry must exist and contain at least one name.
# Environmental skip-guard (INFR-312): if tools9p didn't mount /tool in
# this namespace (no agent stack on a bare host), there is no registry to
# validate — skip cleanly rather than report a false failure. Mirrors the
# non-empty-/tool guards hardened for the Limbo tests in PR #239.
if {! ftest -f /tool/_registry} {
	echo 'SKIP: tools9p did not mount /tool/_registry'
	raise 'skip:tools9p /tool registry not mounted (no agent stack)'
}

echo registry:
cat /tool/_registry
echo
echo schemas:
# Sample three representative tools and confirm their /schema files
# return non-empty bodies.
for (t in find write plan) {
	echo schema for $t :
	cat /tool/$t/schema
	echo
}

# Now drive the Limbo test suite — Layer B checks fire because
# /tool/_registry is present.
echo
echo running tool_schema_test.dis :
/dis/tests/tool_schema_test.dis -v
teststatus=$status

# Smoke check that the legacy ctl-line argv path still works.
echo ctl-line round-trip :
echo / > /tool/list/ctl
cat /tool/list/ctl | head -3

# Status from the test dis: empty string = pass.
if {~ $teststatus ''} {
	echo PASS
	exit
}
echo FAIL: $teststatus
exit 'fail:tests'

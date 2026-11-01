#!/bin/sh
#
# devletters_test.sh -- every build's device letters against the
# registry, docs/DEVICE-LETTERS.md: no letter on two devices in one
# build, and none a build uses that the registry does not give that
# device. The rules and the reason are in tools/devletters.py.
#
cd "$(dirname "$0")/../.." || exit 1
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; echo "Passed: 0  Failed: 0  Skipped: 1"; exit 0; }
out=$(ROOT=. python3 tools/devletters.py --check)
rc=$?
echo "$out"
echo ""
if [ $rc -eq 0 ]; then
	echo "Passed: 1  Failed: 0  Skipped: 0"
else
	echo "Passed: 0  Failed: $(echo "$out" | grep -c '^FAIL')  Skipped: 0"
fi
exit $rc

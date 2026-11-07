#!/bin/sh
# The git tool's worker keeps the namespace from before Veltro restricts it.
# Model-supplied paths must therefore never escape the repository it owns.
set -eu
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/veltro/tools9p.dis dis/veltro/tools/git.dis dis/cmd/git/init.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done

OUT="$(mktemp)"
EMU_PID=
cleanup() {
	if [ -n "$EMU_PID" ]; then
		kill -9 "$EMU_PID" 2>/dev/null || true
		wait "$EMU_PID" 2>/dev/null || true
	fi
	rm -f "$OUT"
	rm -rf "$ROOT/tmp/veltro-git-security" "$ROOT/tmp/veltro-git-secret"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$ROOT/tmp/veltro-git-security"
ln -s ../veltro-git-secret "$ROOT/tmp/veltro-git-security/escape"

CMD="load std; echo secret > /tmp/veltro-git-secret; cmd/git/init /tmp/veltro-git-security; cd /tmp/veltro-git-security; echo ok > ok; /dis/veltro/tools9p.dis -m /tool git & for i in 1 2 3 4 5 6 7 8 9 10 { if {! ftest -f /tool/git/ctl} { sleep 1 } }; echo add ../veltro-git-secret > /tool/git/ctl; echo TRAVERSAL_ADD; cat /tool/git/ctl; echo add /tmp/veltro-git-secret > /tool/git/ctl; echo ABSOLUTE_ADD; cat /tool/git/ctl; echo rm ../veltro-git-secret > /tool/git/ctl; echo TRAVERSAL_RM; cat /tool/git/ctl; echo cat ../veltro-git-secret > /tool/git/ctl; echo TRAVERSAL_CAT; cat /tool/git/ctl; echo merge ../outside > /tool/git/ctl; echo TRAVERSAL_REF; cat /tool/git/ctl; echo add escape > /tool/git/ctl; echo SYMLINK_ADD; cat /tool/git/ctl; echo add ok > /tool/git/ctl; echo LEGITIMATE_ADD; cat /tool/git/ctl; echo SECRET_STILL_PRESENT; cat /tmp/veltro-git-secret; echo GIT_SECURITY_DONE"
"$EMU" -r"$ROOT" sh -c "$CMD" >"$OUT" 2>&1 &
EMU_PID=$!

i=0
while ! grep -q '^GIT_SECURITY_DONE$' "$OUT" && [ "$i" -lt 200 ]; do
	sleep 0.1
	i=$((i + 1))
done

if ! grep -q '^GIT_SECURITY_DONE$' "$OUT"; then
	echo "FAIL: git tool test did not finish"
	cat "$OUT"
	exit 1
fi

[ "$(grep -c 'repository path traversal is not allowed' "$OUT")" -eq 3 ] || {
	echo "FAIL: add, rm, and cat did not all reject traversal"
	cat "$OUT"
	exit 1
}
grep -q 'repository path must be relative' "$OUT" || {
	echo "FAIL: absolute add was not rejected"
	cat "$OUT"
	exit 1
}
grep -q 'invalid branch name' "$OUT" || {
	echo "FAIL: traversal ref was not rejected"
	cat "$OUT"
	exit 1
}
grep -q 'error: stat.*/escape:' "$OUT" || {
	echo "FAIL: add followed a host symlink from the repository"
	cat "$OUT"
	exit 1
}
grep -q 'added 1 file(s)' "$OUT" || {
	echo "FAIL: a repository-local add no longer works"
	cat "$OUT"
	exit 1
}
grep -q '^secret$' "$OUT" || {
	echo "FAIL: rejected git rm affected the outside file"
	cat "$OUT"
	exit 1
}

echo "PASS: git worker confines paths and refs to its repository"

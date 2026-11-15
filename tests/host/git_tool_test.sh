#!/bin/sh
#
# git_tool_test.sh — the agent's git tool on repositories and remotes that
# are not what git's are, and on its own answers.
#
# tests/host/git_tool/fake_remote.py builds two repositories (no git on the
# host needed) and serves two remotes for them on 127.0.0.1.  The tool is
# then asked, through tools9p's files, for what an agent would ask:
#
#   - status, log, branch and cat describe the repository (git/fs was
#     mounted in a name space of its own, so they described an empty one);
#   - checkout of a branch whose tree has an entry "..", ".GIT" or a name
#     with a slash is refused and writes nothing (each wrote the file where
#     the tree's author chose: above the work tree, or into git's own
#     directory);
#   - fetch from a remote advertising refs/heads/../../../../X is refused
#     (it wrote the file X, outside .git, and said "fetched");
#   - fetch from an honest remote, then merge of its branch, has the new
#     file in the work tree (the pack was installed without its index and
#     the merge could read nothing); the user and password in the remote's
#     URL are not in the answer, and the remote's progress text is not on
#     the console;
#   - rm of a directory removes its files (it said "removed 2" and left
#     both); add . then add of a file still works (add . left an index
#     that every later add, commit and rm refused);
#   - cat with a ref of 40 characters that is no hash is refused;
#   - checkout with HEAD on a branch that has no commit does not write
#     over a file that differs (the check was passed over).
#
set -eu
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 77; }
for f in dis/veltro/tools9p.dis dis/veltro/tools/git.dis dis/cmd/git/fs.dis dis/ndb/cs.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done

HERE="$(cd "$(dirname "$0")" && pwd)"
S="$ROOT/tmp/git-tool-test.$$"
I="/tmp/git-tool-test.$$"
SRV=
cleanup() {
	[ -n "$SRV" ] && kill "$SRV" 2>/dev/null || true
	[ -n "${KEEP:-}" ] || rm -rf "$S"
}
trap cleanup EXIT HUP INT TERM
rm -rf "$S"
mkdir -p "$S"

python3 -I "$HERE/git_tool/fake_remote.py" "$S" &
SRV=$!
i=0
while [ ! -s "$S/port" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$S/port" ] || { echo "FAIL: the fake remote did not start"; exit 1; }
cp "$S/repo/.git/config" "$S/config.before"

cat > "$S/drive.sh" <<'EOF'
load std
repo=$1

bind -a '#I' /net >[2] /dev/null
ndb/cs
cd $repo
/dis/veltro/tools9p.dis -m /tool git &
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 { if {! ftest -f /tool/git/ctl} { sleep 1 } }
cd /
fn call { echo '=====' $* ; echo $* > /tool/git/ctl; cat /tool/git/ctl; echo; echo '=====' }
EOF

run() {	# run REPO OUT COMMANDS...
	repo=$1; out=$2; shift 2
	{ cat "$S/drive.sh"; for c in "$@"; do echo "call $c"; done; echo "echo GIT_TOOL_DONE"; } > "$S/script"
	with_timeout 90 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "sh $I/script $I/$repo; echo halt > /dev/sysctl" \
		</dev/null >"$out" 2>&1 || true
	grep -q '^GIT_TOOL_DONE$' "$out" || { echo "FAIL: the run in $repo did not finish"; cat "$out"; exit 1; }
}

# the answer to one call, from the run's output
answer() {	# answer OUT 'command'
	awk -v c="===== $2" '$0 == c { on = 1; next } on && $0 == "=====" { exit } on { print }' "$1"
}

status=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; status=1; }
has() {	# has OUT 'command' 'text' 'what'
	if answer "$1" "$2" | grep -q -- "$3"; then ok "$4"; else bad "$4"; echo "  git $2 answered:"; answer "$1" "$2" | sed 's/^/    /'; fi
}

O="$S/out1"
REF40='aaaaaaaaa/../../../../tmp/veltro/scratch'
run repo "$O" status log branch 'cat a.txt' "cat a.txt $REF40" \
	'fetch origin' 'merge feature' 'fetch bad' \
	'checkout evil' 'checkout evilgit' 'checkout evilslash'

has "$O" status 'On branch master' "status names the branch"
has "$O" status 'first' "status has HEAD's commit"
has "$O" log 'first' "log has the commit"
has "$O" branch '^\* master' "branch lists the branches, the current one marked"
has "$O" 'cat a.txt' '^one$' "cat gives a committed file"
has "$O" "cat a.txt $REF40" 'invalid branch name' "cat refuses a ref of 40 characters that is no hash"

for b in evil evilgit evilslash; do
	has "$O" "checkout $b" '^error:.*unsafe name' "checkout of $b is refused"
done
if [ -n "$(find "$S" -name 'ESCAPED*')" ] || [ -e "$S/repo/.GIT" ]; then
	bad "nothing is written outside the work tree or into git's directory"
	find "$S" -name 'ESCAPED*' -o -name .GIT | sed 's/^/    /'
else
	ok "nothing is written outside the work tree or into git's directory"
fi
if grep -q '^ref: refs/heads/master$' "$S/repo/.git/HEAD"; then
	ok "HEAD is still on master after the refused checkouts"
else
	bad "HEAD is still on master after the refused checkouts"
fi

has "$O" 'fetch bad' '^error:.*name is not a ref' "fetch from a remote advertising refs/heads/../../x is refused"
[ ! -e "$S/repo/.git/refs/remotes/bad" ] && ok "nothing was taken from that remote" || bad "nothing was taken from that remote"
has "$O" 'fetch origin' 'fetched' "fetch from an honest remote"
has "$O" 'merge feature' '^Updated master' "the fetched branch merges"
if [ "$(cat "$S/repo/b.txt" 2>/dev/null)" = two ]; then
	ok "the merge put the remote's file in the work tree"
else
	bad "the merge put the remote's file in the work tree"
fi
if grep -q 'SEKRET-TOKEN' "$O"; then
	bad "the password in the remote's URL is in no answer"
	grep 'SEKRET-TOKEN' "$O" | sed 's/^/    /'
else
	ok "the password in the remote's URL is in no answer"
fi
if grep -q 'PROGRESS-TEXT-FROM-THE-REMOTE' "$O"; then
	bad "the remote's progress text is not on the console"
else
	ok "the remote's progress text is not on the console"
fi
cmp -s "$S/repo/.git/config" "$S/config.before" && ok ".git/config is as it was" || bad ".git/config is as it was"

O="$S/out3"
run repo3 "$O" 'rm sub' 'add .' 'add src/a.txt' 'add nonexistent' 'commit second' status
has "$O" 'rm sub' '^removed 2 file' "rm of a directory answers for its two files"
if [ -e "$S/repo3/sub/x.txt" ] || [ -e "$S/repo3/sub/y.txt" ]; then
	bad "rm of a directory removed its files"
else
	ok "rm of a directory removed its files"
fi
has "$O" 'add .' '^added [0-9]* file' "add . adds the work tree"
has "$O" 'add src/a.txt' '^added 1 file' "an add after add . is not refused"
if answer "$O" 'add nonexistent' | grep -q "$I"; then
	bad "an error does not carry the tool server's own path"
else
	ok "an error does not carry the tool server's own path"
fi
has "$O" 'commit second' '^\[master ' "a commit after them is made"
has "$O" status 'HEAD .* second' "and status has it"

O="$S/out2"
run repo2 "$O" status 'checkout other'
has "$O" 'checkout other' '^error:.*write over a.txt' "checkout with no commit yet does not write over a file"
if [ "$(cat "$S/repo2/a.txt")" = 'not committed anywhere' ]; then
	ok "the file not committed is as it was"
else
	bad "the file not committed is as it was"
fi

if [ $status -eq 0 ]; then
	echo "git_tool_test: PASS"
else
	for o in "$S/out1" "$S/out3" "$S/out2"; do echo "--- $o"; cat "$o"; done
fi
exit $status

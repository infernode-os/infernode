#!/bin/sh
#
# tests/host/keytools_test.sh
#
# auth/createsignerkey, auth/mkauthinfo and auth/getpk, run as an
# administrator runs them.
#
#   - A secret key is not left in a file other users can read. A key
#     written over a file that was already there kept that file's mode
#     (after touch(1), 644), and mkauthinfo's key on standard output,
#     redirected to a new file, had the shell's (644). Both are 600.
#   - An expiry date is the day typed, to its last second. Month 00 was
#     taken (December of the year before), 31 February was 3 March, the
#     hour was 24 (the day after, an hour more in summer), a year past
#     2038 came out as another (2170 as 2033) and "1x" was day 1;
#     mkauthinfo's ended at the time of day the command was run.
#   - mkauthinfo given a name with a newline in it, or none, wrote a file
#     that does not read back, and said it had worked.
#   - getpk's exit status was success when a file could not be read.
#
# KEYS_EMUFLAGS=-c0 runs it interpreted.
# Skips (exit 77) with no emulator.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/auth/createsignerkey.dis" ] || { echo "SKIP: dis/auth/createsignerkey.dis not built"; exit 77; }

DIR="$ROOT/tmp/keytools.$$"
G="/tmp/keytools.$$"
mkdir -p "$DIR"
trap 'rm -rf "$DIR"' EXIT

rc=0
bad() { echo "FAIL: $1"; rc=1; }
ok() { echo "PASS: $1"; }
has() { echo "$OUT" | grep -q -e "$1"; }
check() {
	if has "$2"; then ok "$1"; else bad "$1: $(echo "$OUT" | grep -e "$3" | cut -c1-200 | tr '\n' '|')"; fi
}
refused() {
	if has "^$2: \\.\$"; then bad "$1 was taken"; elif has "^$2: "; then ok "$1 is refused"; else bad "$1: no answer"; fi
}
mode() { ls -l "$DIR/$1" 2>/dev/null | cut -c1-10; }

: > "$DIR/sk.pre"; chmod 644 "$DIR/sk.pre"
: > "$DIR/ai.pre"; chmod 664 "$DIR/ai.pre"
# the expiry time of the certificate in a key file is its ninth line
cat > "$DIR/script" <<INFERNO
load std
cd $G
auth/createsignerkey -f sk.new signer
echo cs-new: \$status.
auth/createsignerkey -f sk.pre signer
echo cs-pre: \$status.
auth/createsignerkey -e 05062030 -f sk.summer signer
echo cs-summer: \$status. \`{date \`{sed -n 9p sk.summer}}
auth/createsignerkey -e 31012030 -f sk.winter signer
echo cs-winter: \$status. \`{date \`{sed -n 9p sk.winter}}
for d in 01002030 31022030 01132030 00012030 01012170 01012040 1x012030 0101203 {
	auth/createsignerkey -e \$d -f sk.\$d signer >[2] /dev/null
	echo cs-\$d: \$status.
}
k='key='^$G^/sk.new
auth/mkauthinfo -k \$k alice ai.file
echo mk-file: \$status.
auth/mkauthinfo -k \$k alice > ai.redir
echo mk-redir: \$status.
auth/mkauthinfo -k \$k alice ai.pre
echo mk-pre: \$status.
echo mk-pipe: \`{auth/mkauthinfo -k \$k alice | sed -n 13p}
auth/mkauthinfo -k \$k 'alice admin' ai.blank
echo mk-blank: \$status. \`{auth/getpk -u ai.blank | sed 's/^[0-9a-f]* //'}
auth/mkauthinfo -k \$k 'alice
bob' ai.newline
echo mk-newline: \$status.
auth/mkauthinfo -k \$k '' ai.empty
echo mk-empty: \$status.
auth/mkauthinfo -k \$k -e 05062030 alice ai.summer
echo mk-summer: \$status. \`{date \`{sed -n 9p ai.summer}}
auth/mkauthinfo -k \$k -e permanent alice ai.perm
echo mk-perm: \$status. \`{sed -n 9p ai.perm}
for d in 01002030 31022030 01012170 01012040 1x012030 {
	auth/mkauthinfo -k \$k -e \$d alice ai.\$d
	echo mk-\$d: \$status.
}
auth/getpk ai.file > /dev/null
echo pk-good: \$status.
auth/getpk nosuch >[2] /dev/null
echo pk-missing: \$status.
auth/getpk ai.file nosuch > /dev/null >[2] /dev/null
echo pk-both: \$status.
echo halt > /dev/sysctl
INFERNO
OUT=$(with_timeout 120 "$EMU" -r"$ROOT" ${KEYS_EMUFLAGS:--c1} sh "$G/script" 2>&1 < /dev/null || true)

check "createsignerkey makes a key" '^cs-new: \.$' 'cs-new'
[ "$(mode sk.new)" = "-rw-------" ] && ok "in a new file of mode 600" || bad "a new signer key file is $(mode sk.new)"
check "and over a file that is there" '^cs-pre: \.$' 'cs-pre'
[ "$(mode sk.pre)" = "-rw-------" ] && ok "which is mode 600 afterwards, whatever it was" || bad "a signer key written over a file of mode 644 is $(mode sk.pre)"
check "-e 05062030 is the last second of 5 June 2030" '^cs-summer: \. .* Jun 05 23:59:59 .* 2030$' 'cs-summer'
check "-e 31012030 the last second of 31 January" '^cs-winter: \. .* Jan 31 23:59:59 .* 2030$' 'cs-winter'
refused "month 00" cs-01002030
refused "31 February" cs-31022030
refused "month 13" cs-01132030
refused "day 00" cs-00012030
refused "the year 2170" cs-01012170
refused "the year 2040" cs-01012040
refused "a day of 1x" cs-1x012030
refused "seven digits" cs-0101203

check "mkauthinfo writes a key file" '^mk-file: \.$' 'mk-file'
[ "$(mode ai.file)" = "-rw-------" ] && ok "of mode 600" || bad "mkauthinfo's file is $(mode ai.file)"
check "and to standard output" '^mk-redir: \.$' 'mk-redir'
[ "$(mode ai.redir)" = "-rw-------" ] && ok "where a file the shell made for it is mode 600 afterwards" || bad "mkauthinfo's key, redirected, is in a file of mode $(mode ai.redir)"
check "and over a file that is there" '^mk-pre: \.$' 'mk-pre'
[ "$(mode ai.pre)" = "-rw-------" ] && ok "which is mode 600 afterwards" || bad "mkauthinfo's key over a file of mode 664 is $(mode ai.pre)"
check "and down a pipe, as it is" '^mk-pipe: alice$' 'mk-pipe'
check "a name with a blank is that owner" '^mk-blank: \. alice admin$' 'mk-blank'
refused "a name with a newline" mk-newline
[ ! -s "$DIR/ai.newline" ] && ok "and no key file is written for it" || bad "a file was written for a name with a newline"
refused "an empty name" mk-empty
[ ! -s "$DIR/ai.empty" ] && ok "and no key file is written for it" || bad "a file was written for an empty name"
check "-e 05062030 is the last second of 5 June 2030" '^mk-summer: \. .* Jun 05 23:59:59 .* 2030$' 'mk-summer'
check "-e permanent is no expiry" '^mk-perm: \. 0$' 'mk-perm'
refused "month 00" mk-01002030
refused "31 February" mk-31022030
refused "the year 2170" mk-01012170
refused "the year 2040" mk-01012040
refused "a day of 1x" mk-1x012030

check "getpk of a key file succeeds" '^pk-good: \.$' 'pk-good'
refused "a file that is not there" pk-missing
refused "one that is and one that is not" pk-both

exit $rc

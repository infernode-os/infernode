#!/bin/sh
#
# tests/host/factotum_persist_test.sh
#
# auth/factotum's keys, kept in its key file and read back by another
# factotum:
#   - more than 64K of them. The file was written at any length and read
#     into 64K: with seven post-quantum signing keys, or thirty long
#     passwords, it no longer decrypted, the agent started with no keys,
#     and after that saved none either.
#   - a value with a blank in it, a quote in it, and one that looks like
#     more attributes. Values were written bare, so each was read back as
#     a shorter value and attributes of its own invention.
#   - a key with a line break in it is refused: keys are kept a line each.
#
# Skips (exit 77) with no emulator.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/auth/factotum.dis" ] || { echo "SKIP: dis/auth/factotum.dis not built"; exit 77; }

DIR="$ROOT/tmp/factotum_persist.$$"
GDIR="/tmp/factotum_persist.$$"
mkdir -p "$DIR"
trap 'rm -rf "$DIR"' EXIT

# thirty keys of 3500 bytes each: 105K
long=$(awk 'BEGIN{for(i=0;i<3400;i++) printf "x"; print ""}')
{
	echo "load std"
	echo "auth/factotum -f $GDIR/keys.enc -p testpassword123"
	echo "sleep 1"
	i=0
	while [ $i -lt 30 ]; do
		echo "echo 'key proto=pass service=big$i user=u$i !password=$long' > /mnt/factotum/ctl"
		i=$((i+1))
	done
	cat <<'INFERNO'
echo 'key proto=pass service=blank user=''bob smith'' !password=''pass word''' > /mnt/factotum/ctl
echo 'key proto=pass service=quote user=''it''''s'' !password=x' > /mnt/factotum/ctl
echo 'key proto=pass service=inject user=''eve !password=evil role=admin'' !password=real' > /mnt/factotum/ctl
echo 'key proto=pass service=plain user=alice !password=x' > /mnt/factotum/ctl
echo '--- phase1 keys ---'
cat /mnt/factotum/ctl | sed 's/!password=x*/!password=X/'
echo 'sync' > /mnt/factotum/ctl
sleep 1
echo '--- phase1 done ---'
INFERNO
} > "$DIR/phase1.sh"

cat > "$DIR/phase2.sh" <<INFERNO
load std
auth/factotum -f $GDIR/keys.enc -p testpassword123
sleep 1
echo '--- phase2 keys ---'
cat /mnt/factotum/ctl
echo '--- phase2 done ---'
INFERNO

OUT1=$(with_timeout 60 "$EMU" -r"$ROOT" -c1 sh "$GDIR/phase1.sh" 2>&1 < /dev/null || true)
rc=0
bad() { echo "FAIL: $1"; rc=1; }
ok() { echo "PASS: $1"; }

if echo "$OUT1" | grep -q -- '--- phase1 done ---'; then
	ok "thirty-four keys given to factotum and saved"
else
	bad "the first factotum did not finish: $(echo "$OUT1" | tail -3 | cut -c1-200)"
fi
size=$(wc -c < "$DIR/keys.enc" 2>/dev/null | tr -d ' ')
if [ "${size:-0}" -gt 65536 ]; then
	ok "the key file is $size bytes, more than 64K"
else
	bad "the key file is ${size:-missing} bytes: not the test it was meant to be"
fi

OUT2=$(with_timeout 60 "$EMU" -r"$ROOT" -c1 sh "$GDIR/phase2.sh" 2>&1 < /dev/null || true)
KEYS=$(echo "$OUT2" | awk '/^--- phase2 keys ---$/{f=1;next} /^--- phase2 done ---$/{f=0} f')
n=$(echo "$KEYS" | grep -c 'proto=pass')
if [ "$n" = 34 ]; then
	ok "a second factotum reads all 34 back"
else
	bad "a second factotum has $n keys of 34: $(echo "$OUT2" | grep -v 'proto=pass' | tail -3 | cut -c1-160)"
fi
line() { echo "$KEYS" | grep "service=$1 " | head -1; }
if line blank | grep -q "user='bob smith'" && [ "$(line blank | tr ' ' '\n' | grep -cx 'smith')" = 0 ]; then
	ok "a value with a blank in it is one value"
else
	bad "service=blank came back as: $(line blank | cut -c1-160)"
fi
if line quote | grep -q "user='it''s'"; then
	ok "a value with a quote in it is itself"
else
	bad "service=quote came back as: $(line quote | cut -c1-160)"
fi
if line inject | grep -q "user='eve !password=evil role=admin'" && [ "$(line inject | tr ' ' '\n' | grep -cx 'role=admin')" = 0 ]; then
	ok "a value that looks like attributes is a value"
else
	bad "service=inject came back as: $(line inject | cut -c1-200)"
fi
if line plain | grep -q "user=alice "; then
	ok "a plain value is written as it was"
else
	bad "service=plain came back as: $(line plain | cut -c1-160)"
fi

# A save that cannot be made is an answer. With no random numbers there
# is no nonce: the thread that saves raised an exception and ended, the
# writer of "sync" waited for an answer that never came, and factotum's
# one loop, waiting with it, served nothing more.
cat > "$DIR/phase3.sh" <<INFERNO
load std
bind /dev/null /dev/random
auth/factotum -f $GDIR/keys3.enc -p testpassword123
sleep 1
echo 'key proto=pass service=p3 user=u3 !password=x' > /mnt/factotum/ctl
echo sync > /mnt/factotum/ctl
echo P3-sync: \$status.
echo sync > /mnt/factotum/ctl
echo P3-again: \$status.
echo P3-keys: \`{cat /mnt/factotum/ctl}
echo '--- phase3 done ---'
INFERNO
OUT3=$(with_timeout 30 "$EMU" -r"$ROOT" -c1 sh "$GDIR/phase3.sh" 2>&1 < /dev/null || true)
if echo "$OUT3" | grep -q '^P3-sync: ..*\.$' && echo "$OUT3" | grep -q '^P3-again: ..*\.$'; then
	ok "with no random numbers a sync is answered, with an error, each time"
else
	bad "sync with no /dev/random: $(echo "$OUT3" | grep -v fsqid | tail -3 | cut -c1-200 | tr '\n' '|')"
fi
if echo "$OUT3" | grep -q '^P3-keys: .*service=p3'; then
	ok "and factotum still serves its keys"
else
	bad "factotum after a save that failed: $(echo "$OUT3" | grep -v fsqid | tail -3 | cut -c1-200 | tr '\n' '|')"
fi
[ ! -s "$DIR/keys3.enc" ] && ok "and no key file was written under no nonce" || bad "a key file was written with no random numbers"
exit $rc

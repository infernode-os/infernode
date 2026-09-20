#!/bin/sh
#
# tests/host/wpa_join_test.sh
#
# ip/wpa(8) against a netif-shaped interface made of ordinary files.
#
# tests/wpa_test.b proves the arithmetic and the handshake; it calls
# wpakey(2) directly and never opens a file.  What it cannot reach is
# the half of the supplicant that is I/O: the conversation obtained
# from a clone file, the number read back from it naming the data file,
# the ctl verbs, the ifstats parsing, and the passphrase coming out of
# factotum through the wpapsk protocol.  Every one of those is a place
# where the program can be wrong in a way no vector would catch, and
# none of them needs a radio.
#
# So this builds an interface out of plain files -- addr, clone,
# ifstats, and 0/data holding one real message 1 -- runs the supplicant
# against it, and reads back what it wrote.  A plain file is not a
# queue: reads return whatever is there and then end of file, which the
# supplicant reads as a lost link and answers by starting again, so the
# run is bounded by a timeout rather than by the program finishing, and
# only the first exchange can be driven this way.  The key
# installations are pinned by the unit test's exact ctl strings.
#
# Message 2 cannot be compared against a constant, because its station
# nonce is real randomness from /dev/random and must differ on every
# run.  That is the point: the check recomputes the master key, the
# pairwise key and the integrity check from the passphrase, the network
# name, the two addresses and the two nonces actually used, with an
# independent implementation of the same primitives, and requires the
# integrity check the supplicant wrote to be the one that follows.  A
# nonce that came out constant, or equal to the access point's, fails.
#
# Skips (exit 77) without an emulator, python3, timeout, or a built
# supplicant.
#
# Run from project root: ./tests/host/wpa_join_test.sh
#

. "$(dirname "$0")/common.sh"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 77; }
command -v timeout >/dev/null 2>&1 || { echo "SKIP: no timeout(1)"; exit 77; }
[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/ip/wpa.dis" ] || { echo "SKIP: dis/ip/wpa.dis not built"; exit 77; }
[ -f "$ROOT/dis/auth/proto/wpapsk.dis" ] || { echo "SKIP: wpapsk proto not built"; exit 77; }

# The same synthetic network as tests/wpa_test.b.
ESSID=infernode
PASS=InfernodeTest
SMAC=020000000001
RSNE=30140100000fac040100000fac040100000fac020000
MSG1=020000000001020000000002888e0203005f02008a00100000000000000001202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000

DIR="$ROOT/tmp/wpa-join-$$"
IDIR="/tmp/wpa-join-$$"
SCRIPT="$ROOT/tmp/wpa-join-$$.sh"
LOG="$DIR.log"
trap 'rm -rf "$DIR" "$SCRIPT" "$LOG"' EXIT INT TERM
rm -rf "$DIR"
mkdir -p "$DIR/0"

echo "$SMAC" > "$DIR/addr"
echo "0" > "$DIR/clone"
{ echo "essid: $ESSID"; echo "status: associated"; } > "$DIR/ifstats"
python3 -c "
import binascii, sys
open(sys.argv[1], 'wb').write(binascii.unhexlify(sys.argv[2]))
" "$DIR/0/data" "$MSG1"

cat > "$SCRIPT" << INFERNO
load std
auth/factotum &
sleep 2
echo 'key proto=wpapsk role=client essid=$ESSID !password=$PASS' > /mnt/factotum/ctl
ip/wpa -s $ESSID $IDIR &
sleep 3
INFERNO

timeout 30 "$EMU" -c1 -r"$ROOT" sh "/tmp/$(basename "$SCRIPT")" > "$LOG" 2>&1
rc=$?
emu_timeout_ok "$rc" || { cat "$LOG"; echo "FAIL: emu exited $rc"; exit 1; }

#
# Deduplicated, because the supplicant legitimately repeats itself here:
# a plain file is not a queue, so it re-associates for as long as the run
# lasts.  Note what that hides -- before the reporting backoff went in,
# this collapsed about fifty lines a second into three, which is why CI
# never saw the flood that made a board unusable.  The line count, not
# the lines, is the check: tests/host/wpa_backoff_test.sh makes it.
#
echo "  ($(grep -c '^wpa: ' "$LOG" || true) console lines, deduplicated below)"
sort -u "$LOG" | sed 's/^/  emu: /'

fail=0
check() {
	if [ "$2" = ok ]; then
		echo "PASS: $1"
	else
		echo "FAIL: $1"
		fail=1
	fi
}

got() { grep -q "$1" "$2" && echo ok || echo no; }

# The conversation was opened and connected to EAPOL, and the network
# and the authentication suite were declared on its ctl file.
check "the conversation is connected to ethernet type 0x888e" "$(got 'connect 0x888e' "$DIR/clone")"
check "the network name is written to ctl" "$(got "essid $ESSID" "$DIR/clone")"
check "the WPA2-PSK/CCMP RSN element is written to ctl" "$(got "auth $RSNE" "$DIR/clone")"

# And the supplicant said so on the console.
check "the supplicant names the network it will derive from" "$(got "wpa: $IDIR: network" "$LOG")"
check "the supplicant reports the association" "$(got 'associated; starting the four-way handshake' "$LOG")"
if grep -q 'no passphrase' "$LOG"; then
	check "the passphrase came out of factotum" no
else
	check "the passphrase came out of factotum" ok
fi

# Message 2, checked against an independent derivation from the nonces
# actually used.
verdict=$(python3 - "$DIR/0/data" "$PASS" "$ESSID" << 'PY'
import binascii, hashlib, hmac, sys

path, passphrase, essid = sys.argv[1], sys.argv[2].encode(), sys.argv[3].encode()
d = open(path, 'rb').read()

def bad(why):
    print('no ' + why)
    raise SystemExit

if len(d) < 113 + 135:
    bad('the supplicant wrote nothing back (%d bytes)' % len(d))

m1, m2 = d[0:113], d[113:113+135]
KD = 18                                 # the key descriptor within the frame

if m2[0:6] != m1[6:12] or m2[6:12] != m1[0:6]:
    bad('message 2 is not addressed back to the access point')
if m2[12:14] != b'\x88\x8e':
    bad('message 2 is not an EAPOL frame')
if m2[14] != 2 or m2[15] != 3:
    bad('message 2 is not an EAPOL-Key frame of version 2')

flags = int.from_bytes(m2[KD+1:KD+3], 'big')
if flags != 0x010a:
    bad('message 2 carries key information %#06x, want 0x010a' % flags)
if m2[KD+5:KD+13] != m1[KD+5:KD+13]:
    bad('message 2 did not echo the replay counter')
if m2[KD+45:KD+61] != bytes(16) or m2[KD+61:KD+69] != bytes(8):
    bad('message 2 left the EAPOL IV or the RSC set')

datalen = int.from_bytes(m2[KD+93:KD+95], 'big')
kdata = m2[KD+95:KD+95+datalen]
if kdata != binascii.unhexlify('30140100000fac040100000fac040100000fac020000'):
    bad('message 2 carries the wrong RSN element: ' + binascii.hexlify(kdata).decode())

anonce = m1[KD+13:KD+45]
snonce = m2[KD+13:KD+45]
if snonce == bytes(32):
    bad('the station nonce is all zeros -- there is no entropy source')
if snonce == anonce:
    bad('the station nonce equals the access point nonce')

def prf(K, A, B, nbits):
    R, i = b'', 0
    while len(R)*8 < nbits:
        R += hmac.new(K, A + b'\x00' + B + bytes([i]), hashlib.sha1).digest()
        i += 1
    return R[:nbits//8]

amac, smac = m1[6:12], m1[0:6]
pmk = hashlib.pbkdf2_hmac('sha1', passphrase, essid, 4096, 32)
seed = min(amac, smac) + max(amac, smac) + min(anonce, snonce) + max(anonce, snonce)
kck = prf(pmk, b'Pairwise key expansion', seed, 512)[0:16]

z = bytearray(m2)
z[KD+77:KD+93] = bytes(16)
eaplen = 4 + int.from_bytes(z[16:18], 'big')
want = hmac.new(kck, bytes(z[14:14+eaplen]), hashlib.sha1).digest()[:16]
if bytes(m2[KD+77:KD+93]) != want:
    bad('the integrity check does not follow from the passphrase and these nonces')

print('ok')
PY
)
case "$verdict" in
ok)	check "message 2 is well formed and its integrity check follows from the passphrase" ok ;;
*)	check "message 2 is well formed and its integrity check follows from the passphrase" no
	echo "  ${verdict#no }" ;;
esac

[ "$fail" = 0 ] || exit 1
echo "PASS: ip/wpa drives a netif-shaped interface through message 2"
exit 0

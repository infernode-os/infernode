#!/bin/bash
#
# Cross-binary node interoperability harness.
#
# Launches two *separate* emu processes — a serving node and a connecting
# node, optionally from two different InferNode/NERVA3 trees — and drives a
# real file transfer between them over the native transport: cert auth + the
# hybrid post-quantum (ML-KEM-768) STS handshake + aes_256_cbc/sha256 ssl line
# encryption + 9P export/mount.  Proves two independently-built nodes speak the
# same authenticated, post-quantum-encrypted wire protocol.
#
# Usage:
#   run-interop.sh [server_root] [client_root] [alg]
#
#   server_root  tree whose emu serves   (default: this repo)
#   client_root  tree whose emu connects  (default: same as server_root)
#   alg          signer cert algorithm: ed25519 | mldsa65 (default: ed25519)
#
# Example (InferNode serves, NERVA3 connects, fully post-quantum certs):
#   tests/interop/run-interop.sh /path/to/infernode /path/to/nerva3 mldsa65
#
set -u

SERVER_ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
CLIENT_ROOT="${2:-$SERVER_ROOT}"
ALG="${3:-ed25519}"
PORT="${INTEROP_PORT:-19877}"
ADDR="tcp!127.0.0.1!${PORT}"

emu_bin() {
	if   [ -x "$1/emu/Linux/o.emu" ];  then echo "$1/emu/Linux/o.emu"
	elif [ -x "$1/emu/MacOSX/o.emu" ]; then echo "$1/emu/MacOSX/o.emu"
	else echo ""; fi
}
SERVER_EMU="$(emu_bin "$SERVER_ROOT")"
CLIENT_EMU="$(emu_bin "$CLIENT_ROOT")"
[ -n "$SERVER_EMU" ] || { echo "interop: no emu binary under $SERVER_ROOT" >&2; exit 2; }
[ -n "$CLIENT_EMU" ] || { echo "interop: no emu binary under $CLIENT_ROOT" >&2; exit 2; }

KEY_INF="/usr/inferno/keyring/interop-${ALG}"
KEY_HOST_SERVER="${SERVER_ROOT}${KEY_INF}"
EXPORT_TREE="/lib"
XFER="/ndb/inferno"
SRC_FILE="${SERVER_ROOT}${EXPORT_TREE}${XFER}"

LIMBO=""
for c in "$SERVER_ROOT/Linux/amd64/bin/limbo" "$SERVER_ROOT/Linux/arm64/bin/limbo" \
         "$SERVER_ROOT/MacOSX/arm64/bin/limbo"; do
	[ -x "$c" ] && { LIMBO="$c"; break; }
done

echo "=== interop: $ALG cert, $SERVER_EMU (server) <-> $CLIENT_EMU (client) ==="

# Build the node programs into both trees (idempotent; needs native limbo).
if [ -n "$LIMBO" ]; then
	for R in "$SERVER_ROOT" "$CLIENT_ROOT"; do
		"$LIMBO" -I "$R/module" -o "$R/dis/interop_node_server.dis" \
			"$(dirname "$0")/node_server.b" 2>/dev/null
		"$LIMBO" -I "$R/module" -o "$R/dis/interop_node_client.dis" \
			"$(dirname "$0")/node_client.b" 2>/dev/null
	done
fi
[ -f "$SERVER_ROOT/dis/interop_node_server.dis" ] || { echo "interop: server dis missing (build with native limbo)" >&2; exit 2; }
[ -f "$CLIENT_ROOT/dis/interop_node_client.dis" ] || { echo "interop: client dis missing (build with native limbo)" >&2; exit 2; }

# Generate the signer keyfile once in the server tree, then share it with the
# client tree (keyring.c is identical across InferNode/NERVA3, so a keyfile is
# portable).  Both nodes present the same signer identity -> mutual trust.
mkdir -p "$(dirname "$KEY_HOST_SERVER")"
if [ ! -s "$KEY_HOST_SERVER" ]; then
	echo "interop: generating $ALG signer keyfile"
	timeout 90 "$SERVER_EMU" -c1 -r"$SERVER_ROOT" /dis/auth/createsignerkey.dis \
		-a "$ALG" -f "$KEY_INF" interopnode >/dev/null 2>&1
fi
[ -s "$KEY_HOST_SERVER" ] || { echo "interop: keyfile generation failed" >&2; exit 1; }
mkdir -p "$(dirname "${CLIENT_ROOT}${KEY_INF}")"
[ "$(cd "$SERVER_ROOT" && pwd)" = "$(cd "$CLIENT_ROOT" && pwd)" ] || cp -f "$KEY_HOST_SERVER" "${CLIENT_ROOT}${KEY_INF}"

TMP="$(mktemp -d)"
trap 'kill $SRV_PID 2>/dev/null; rm -rf "$TMP"' EXIT

# Start the serving node.
timeout 60 "$SERVER_EMU" -c1 -r"$SERVER_ROOT" /dis/interop_node_server.dis \
	"$KEY_INF" "$ADDR" "$EXPORT_TREE" >"$TMP/srv.out" 2>"$TMP/srv.err" &
SRV_PID=$!

# emu wires a directly-run .dis's status output to the harness stdout, so the
# node's "listening"/auth lines may land in either stream — scan both.
srvlog() { cat "$TMP/srv.out" "$TMP/srv.err" 2>/dev/null; }
# Wait for it to announce (or skip gracefully if this host has no IP stack).
for i in $(seq 1 50); do
	srvlog | grep -q "listening on" && break
	if ! kill -0 $SRV_PID 2>/dev/null; then break; fi
	sleep 0.2
done
if srvlog | grep -qiE "address family|network unavailable|cannot announce"; then
	echo "SKIP: server could not announce (no IP stack?):"; srvlog | sed 's/^/    /'; exit 0
fi
srvlog | grep -q "listening on" || { echo "interop: server failed to start:"; srvlog | sed 's/^/    /'; exit 1; }

# Run the connecting node; it writes the pulled file to OUT (a real file, to
# avoid relying on emu's fd wiring) which maps to a host path under CLIENT_ROOT.
# emu does not always exit promptly once an export/mount channel is up, so we
# run it in the background and finish the moment the transfer is reported done.
OUT_INF="/tmp/interop_pulled_$$"
OUT_HOST="${CLIENT_ROOT}${OUT_INF}"
mkdir -p "$(dirname "$OUT_HOST")"	# /tmp may not exist in the client tree
rm -f "$OUT_HOST"
"$CLIENT_EMU" -c1 -r"$CLIENT_ROOT" /dis/interop_node_client.dis \
	"$KEY_INF" "$ADDR" "/mnt" "$XFER" "$OUT_INF" >"$TMP/client.out" 2>"$TMP/client.err" &
CLI_PID=$!
clilog() { cat "$TMP/client.out" "$TMP/client.err" 2>/dev/null; }
DONE=0
for i in $(seq 1 100); do
	clilog | grep -q "node_client: OK read" && { DONE=1; break; }
	clilog | grep -qE "node_client: .*(:|failed)" && break   # an error line
	kill -0 $CLI_PID 2>/dev/null || break
	sleep 0.2
done
kill $CLI_PID 2>/dev/null
{ srvlog; clilog; } | grep -E "node_(server|client):" | sed 's/^/    /'

if [ "$DONE" != 1 ]; then echo "FAIL: client did not complete the transfer"; rm -f "$OUT_HOST"; exit 1; fi
if cmp -s "$OUT_HOST" "$SRC_FILE"; then
	echo "PASS: $(wc -c <"$OUT_HOST" | tr -d ' ') bytes transferred and verified byte-for-byte over cert-auth + PQC + ssl"
	rm -f "$OUT_HOST"; exit 0
else
	echo "FAIL: transferred bytes differ from source $SRC_FILE"
	rm -f "$OUT_HOST"; exit 1
fi

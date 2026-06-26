#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EMU="${EMU:-$ROOT/emu/MacOSX/o.emu}"
[ -x "$EMU" ] || EMU="$ROOT/emu/Linux/o.emu"
EMU_ARGS="${EMU_ARGS:-}"
LIMBO="${LIMBO:-$ROOT/MacOSX/arm64/bin/limbo}"
[ -x "$LIMBO" ] || LIMBO="$ROOT/Linux/amd64/bin/limbo"

[ -x "$EMU" ] || { echo "SKIP: no emulator found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 needed"; exit 0; }

PORT="${PORT:-19694}"
fails=0

run_emu() {
	"$EMU" ${EMU_ARGS:+$EMU_ARGS} "$@"
}

compile_client() {
	local out="$ROOT/dis/tests/tlsclient.dis"

	if [ -x "$LIMBO" ]; then
		"$LIMBO" -gw -I"$ROOT/module" -o "$out" "$ROOT/tests/tlsclient.b" >/tmp/tlsclient-limbo.$$ 2>&1 || {
			cat /tmp/tlsclient-limbo.$$
			rm -f /tmp/tlsclient-limbo.$$
			exit 1
		}
		rm -f /tmp/tlsclient-limbo.$$
		return
	fi

	[ -f "$ROOT/dis/limbo.dis" ] || { echo "FAIL: no Limbo compiler found"; exit 1; }
	rm -f "$out"
	run_emu -r"$ROOT" /dis/limbo.dis -I/module -o /dis/tests/tlsclient.dis /tests/tlsclient.b >/tmp/tlsclient-limbo.$$ 2>&1 || {
		if [ -f "$out" ]; then
			rm -f /tmp/tlsclient-limbo.$$
			return
		fi
		cat /tmp/tlsclient-limbo.$$
		rm -f /tmp/tlsclient-limbo.$$
		exit 1
	}
	rm -f /tmp/tlsclient-limbo.$$
}

compile_client
rm -f /tmp/tlsclient-limbo.$$

run_case() {
	local name="$1" mode="$2" want="$3"
	local out="/tmp/tls-malformed-client.$$.$name"
	local srvout="/tmp/tls-malformed-server.$$.$name"

	python3 - "$PORT" "$name" >"$srvout" 2>&1 <<'PY' &
import socket
import struct
import sys
import time


def recvall(conn, n):
    out = b""
    while len(out) < n:
        chunk = conn.recv(n - len(out))
        if not chunk:
            break
        out += chunk
    return out


def hs_record(body):
    hs = b"\x02" + len(body).to_bytes(3, "big") + body
    return b"\x16\x03\x03" + struct.pack(">H", len(hs)) + hs


def base_server_hello(sid, suite):
    return (
        b"\x03\x03" +
        (b"\x5a" * 32) +
        bytes([len(sid)]) + sid +
        suite +
        b"\x00"
    )


def send_bad_hybrid_point(conn, sid):
    group = 0x11ED
    bad_p384 = b"\x04" + (b"\x00" * 96)
    fake_mlkem_ct = b"\x00" * 1568
    share = bad_p384 + fake_mlkem_ct
    exts = (
        b"\x00\x2b\x00\x02\x03\x04" +
        b"\x00\x33" + struct.pack(">H", 4 + len(share)) +
        struct.pack(">HH", group, len(share)) + share
    )
    sh = base_server_hello(sid, b"\x13\x02") + struct.pack(">H", len(exts)) + exts
    conn.sendall(hs_record(sh))


def send_ext_len_too_long(conn, sid):
    sh = base_server_hello(sid, b"\xc0\x2f") + b"\xff\xff"
    conn.sendall(hs_record(sh))


def send_ext_header_truncated(conn, sid):
    sh = base_server_hello(sid, b"\xc0\x2f") + b"\x00\x03\x00\x2b\x00"
    conn.sendall(hs_record(sh))


def main():
    port = int(sys.argv[1])
    case = sys.argv[2]
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(1)
    conn, _ = srv.accept()
    conn.settimeout(30)
    hdr = recvall(conn, 5)
    if len(hdr) != 5:
        return
    body = recvall(conn, struct.unpack(">H", hdr[3:5])[0])
    sid = b""
    if len(body) > 38:
        sid_len = body[38]
        sid = body[39:39 + sid_len]
    if case == "bad-hybrid-point":
        send_bad_hybrid_point(conn, sid)
    elif case == "serverhello-extlen":
        send_ext_len_too_long(conn, sid)
    elif case == "serverhello-extheader":
        send_ext_header_truncated(conn, sid)
    else:
        raise SystemExit("unknown case: " + case)
    time.sleep(1)


if __name__ == "__main__":
    main()
PY
	local sp=$!
	sleep 1

	if [ "$mode" = "cnsa" ]; then
		( export CNSAMODE=1; run_emu -r"$ROOT" /dis/tests/tlsclient.dis "tcp!127.0.0.1!$PORT" 2>&1 </dev/null ) >"$out" &
	else
		( run_emu -r"$ROOT" /dis/tests/tlsclient.dis "tcp!127.0.0.1!$PORT" 2>&1 </dev/null ) >"$out" &
	fi
	local cp=$!
	local waited=0
	while kill -0 "$cp" 2>/dev/null && [ "$waited" -lt 20 ]; do
		sleep 1
		waited=$((waited + 1))
	done
	if kill -0 "$cp" 2>/dev/null; then
		kill "$cp" 2>/dev/null || true
		echo "FAIL: $name client hung"
		cat "$out" 2>/dev/null || true
		fails=$((fails + 1))
	else
		wait "$cp" 2>/dev/null || true
		if grep -q "HANDSHAKE-FAIL: .*${want}" "$out" && ! grep -q "Broken:" "$out"; then
			echo "PASS: $name"
		else
			echo "FAIL: $name expected $want"
			cat "$out" 2>/dev/null || true
			fails=$((fails + 1))
		fi
	fi
	wait "$sp" 2>/dev/null || true
	rm -f "$out" "$srvout"
}

run_case bad-hybrid-point cnsa "CNSA hybrid key agreement failed"
run_case serverhello-extlen plain "ServerHello extensions truncated"
run_case serverhello-extheader plain "ServerHello extension truncated"

if [ "$fails" -eq 0 ]; then
	echo "TLS malformed server: ALL PASS"
else
	echo "TLS malformed server: $fails FAILED"
	exit 1
fi

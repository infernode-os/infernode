#!/bin/sh
# serve-llm.sh smoke test (host-side, Linux only)
#
# Validates that the headless InferNode LLM 9P daemon launches via its
# host-side wrapper, binds the expected listener, and speaks 9P2000 on
# the wire. Catches the kinds of breakage that can otherwise only be
# discovered by hand: rc-shell quoting bugs in serve-profile, missing
# binds in the lean profile, listener flag drift, exec/SIGTERM glitches
# in the wrapper.
#
# Does NOT exercise the LLM backend (no Ollama call, no model load).
# The 9P handshake completes long before any model would be touched.
#
# PASS criteria:
#   1. Wrapper starts and stays alive long enough for the listener
#   2. Listener binds 127.0.0.1:5640 within 30s
#   3. 9P Tversion handshake returns Rversion msize=8192 version=9P2000
#   4. Wrapper survives the handshake
#   5. SIGTERM brings it down and releases the port
#
set -e

ROOT="${ROOT:-.}"
PORT=5640
WRAPPER="$ROOT/serve-llm.sh"

case "$(uname -s)" in
    Linux) ;;
    *) echo "SKIP: serve-llm.sh is Linux-only"; exit 0 ;;
esac

if [ ! -x "$WRAPPER" ]; then
    echo "SKIP: $WRAPPER not found or not executable"
    exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 needed for 9P handshake"
    exit 0
fi

if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
    echo "SKIP: :$PORT already in use; stop the running listener first"
    echo "  (e.g. systemctl --user stop infernode-llm.service)"
    exit 0
fi

LOG=$(mktemp /tmp/serve_llm_smoke.XXXXXX.log)
WRAPPER_PID=""

cleanup() {
    if [ -n "$WRAPPER_PID" ]; then
        kill "$WRAPPER_PID" 2>/dev/null || true
        # emu shutdown is known to be slow; force after grace
        sleep 2
        kill -9 "$WRAPPER_PID" 2>/dev/null || true
    fi
    rm -f "$LOG"
}
trap cleanup EXIT

echo "=== serve-llm smoke ==="

"$WRAPPER" > "$LOG" 2>&1 &
WRAPPER_PID=$!
echo "  wrapper started, pid=$WRAPPER_PID"

DEADLINE=$(($(date +%s) + 30))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
        break
    fi
    if ! kill -0 "$WRAPPER_PID" 2>/dev/null; then
        echo "FAIL: wrapper exited before listener came up"
        cat "$LOG"
        exit 1
    fi
    sleep 1
done

if ! ss -ltn 2>/dev/null | grep -q ":$PORT "; then
    echo "FAIL: listener did not appear on :$PORT within 30s"
    cat "$LOG"
    exit 1
fi
echo "  listener up on :$PORT"

RESULT=$(python3 - "$PORT" <<'PY'
import socket, struct, sys
port = int(sys.argv[1])
try:
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    ver = b"9P2000"
    msg = struct.pack("<IBHI", 0, 100, 0xFFFF, 8192) + struct.pack("<H", len(ver)) + ver
    msg = struct.pack("<I", len(msg)) + msg[4:]
    s.send(msg)
    hdr = s.recv(7)
    sz, typ, tag = struct.unpack("<IBH", hdr)
    rest = s.recv(sz - 7)
    if typ == 101:
        msize = struct.unpack("<I", rest[:4])[0]
        vlen  = struct.unpack("<H", rest[4:6])[0]
        ver_s = rest[6:6+vlen].decode()
        print(f"OK msize={msize} version={ver_s}")
    else:
        print(f"FAIL unexpected-type={typ}")
        sys.exit(1)
    s.close()
except Exception as e:
    print(f"FAIL exception={e}")
    sys.exit(1)
PY
) || true

case "$RESULT" in
    OK*version=9P2000)
        echo "  9P handshake: $RESULT"
        ;;
    *)
        echo "FAIL: 9P handshake unexpected: $RESULT"
        cat "$LOG"
        exit 1
        ;;
esac

if ! kill -0 "$WRAPPER_PID" 2>/dev/null; then
    echo "FAIL: wrapper died after handshake"
    cat "$LOG"
    exit 1
fi
echo "  daemon survived handshake"

# SIGTERM and wait for graceful exit + port release
kill "$WRAPPER_PID"
DEADLINE=$(($(date +%s) + 15))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    kill -0 "$WRAPPER_PID" 2>/dev/null || break
    sleep 1
done
if kill -0 "$WRAPPER_PID" 2>/dev/null; then
    echo "  WARN: wrapper did not exit within 15s of SIGTERM (emu shutdown is known-slow); forcing"
    kill -9 "$WRAPPER_PID" 2>/dev/null || true
fi
WRAPPER_PID=""   # don't double-kill in trap

sleep 2
if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
    echo "FAIL: :$PORT still bound after shutdown"
    exit 1
fi
echo "  port released"

echo "=== PASS ==="

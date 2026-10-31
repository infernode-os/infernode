#!/bin/sh
# serve-llm.sh smoke test (host-side, Linux only)
#
# Validates that the headless InferNode LLM 9P daemon launches via its
# host-side wrapper in its default mode (keyring authentication, since
# INFR-16), binds the expected listener, and serves /mnt/llm to a client
# holding the key. Catches the kinds of breakage that can otherwise only
# be discovered by hand: rc-shell quoting bugs in serve-profile, missing
# binds in the lean profile, listener flag drift, exec/SIGTERM glitches
# in the wrapper.
#
# Does NOT exercise the LLM backend (no model call). The config given
# names an OpenAI-shaped backend that is not there, which llmsrv does
# not dial until a prompt is sent.
#
# Runs under a home of its own: the keyfile and the llm config are made
# there, and the user's are not touched.
#
# PASS criteria:
#   1. --gen-key writes a keyfile
#   2. Listener binds 127.0.0.1:5640 within 30s
#   3. A client without the key gets no 9P: a Tversion is not answered
#      with an Rversion (the listener wants the keyring handshake first)
#   4. A client emu with the key mounts /mnt/llm and sees llmsrv's
#      files, and a session has no model, as the config names none
#   5. Wrapper survives both
#   6. SIGTERM brings it down and releases the port
#
set -e

ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$(dirname "$0")/common.sh"
PORT=5640
WRAPPER="$ROOT/serve-llm.sh"

case "$(uname -s)" in
    Linux) ;;
    *) echo "SKIP: serve-llm.sh is Linux-only"; exit 77 ;;
esac

if [ ! -x "$WRAPPER" ]; then
    echo "SKIP: $WRAPPER not found or not executable"
    exit 77
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 needed for 9P handshake"
    exit 77
fi

# something accepting on the port (ss is not on every host)
listening() {
    python3 -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 1)' "$PORT" 2>/dev/null
}

if listening; then
    echo "SKIP: :$PORT already in use; stop the running listener first"
    echo "  (e.g. systemctl --user stop infernode-llm.service)"
    exit 77
fi

H=$(mktemp -d)
LOG=$H/log
WRAPPER_PID=""

cleanup() {
    if [ -n "$WRAPPER_PID" ]; then
        kill "$WRAPPER_PID" 2>/dev/null || true
        # emu shutdown is known to be slow; force after grace
        sleep 2
        kill -9 "$WRAPPER_PID" 2>/dev/null || true
    fi
    rm -rf "$H"
}
trap cleanup EXIT

echo "=== serve-llm smoke ==="

mkdir -p "$H/.infernode/lib/ndb"
printf 'backend=openai\nurl=http://127.0.0.1:9/v1\n' > "$H/.infernode/lib/ndb/llm"
KEY=$H/.infernode/lib/keyring/serve-llm
HOME=$H "$WRAPPER" --gen-key > "$LOG" 2>&1 || true
if [ ! -s "$KEY" ]; then
    echo "FAIL: --gen-key wrote no keyfile"
    cat "$LOG"
    exit 1
fi
echo "  keyfile generated"

HOME=$H "$WRAPPER" > "$LOG" 2>&1 &
WRAPPER_PID=$!
echo "  wrapper started, pid=$WRAPPER_PID"

DEADLINE=$(($(date +%s) + 30))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    if listening; then
        break
    fi
    if ! kill -0 "$WRAPPER_PID" 2>/dev/null; then
        echo "FAIL: wrapper exited before listener came up"
        cat "$LOG"
        exit 1
    fi
    sleep 1
done

if ! listening; then
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
    body = struct.pack("<BHI", 100, 0xFFFF, 8192) + struct.pack("<H", len(ver)) + ver
    s.send(struct.pack("<I", len(body) + 4) + body)
    data = s.recv(64)
    if len(data) >= 5 and data[4] == 101:
        print("FAIL Rversion without the key")
    else:
        print("OK no Rversion: %r" % data[:24])
    s.close()
except Exception as e:
    print("OK no Rversion: %s" % e)
PY
)

case "$RESULT" in
    OK*)
        echo "  without the key: $RESULT"
        ;;
    *)
        echo "FAIL: a client without the key: $RESULT"
        cat "$LOG"
        exit 1
        ;;
esac

# the client: the key from the host, bound where mount -k can name it
OUT=$(with_timeout 30 "$EMU" -r"$ROOT" /dis/sh.dis -c "bind -a '#I' /net
bind '#U*'$H/.infernode/lib/keyring /tmp
mount -k /tmp/serve-llm tcp!127.0.0.1!$PORT /mnt/llm
ls /mnt/llm
id=\`{cat /mnt/llm/new}
echo model \`{cat /mnt/llm/\$id/model}
echo '<<< end >>>'" </dev/null 2>&1 || true)
if ! echo "$OUT" | grep -q '^/mnt/llm/new$'; then
    echo "FAIL: a client with the key did not see llmsrv's files in /mnt/llm"
    echo "$OUT"
    cat "$LOG"
    exit 1
fi
echo "  with the key: /mnt/llm mounted"

# The config names no model, so a session has none: serve-profile took
# a missing model= for one and passed -M the next argument (-r).
if ! echo "$OUT" | grep -q '^model$'; then
    echo "FAIL: a session's model is not empty with no model= in the config"
    echo "$OUT"
    exit 1
fi
echo "  no model= in the config: a session has no model"

if ! kill -0 "$WRAPPER_PID" 2>/dev/null; then
    echo "FAIL: wrapper died after the clients"
    cat "$LOG"
    exit 1
fi
echo "  daemon survived the clients"

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
if listening; then
    echo "FAIL: :$PORT still bound after shutdown"
    exit 1
fi
echo "  port released"

echo "=== PASS ==="

#!/bin/sh
set -e

. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; exit 77; }

WORK="$(mktemp -d)"
SERVER_PID=
EMU_PID=
cleanup() {
	[ -z "$EMU_PID" ] || kill -9 "$EMU_PID" 2>/dev/null || true
	[ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
	[ -z "${SCRIPT:-}" ] || rm -f "$SCRIPT"
	rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM

cat > "$WORK/server.py" <<'PY'
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        time.sleep(2)
        events = [
            {"choices": [{"delta": {"content": "delayed reply"}, "finish_reason": None}]},
            {"choices": [{"delta": {}, "finish_reason": "stop"}],
             "usage": {"total_tokens": 1}},
        ]
        body = ("".join("data: " + json.dumps(event) + "\n\n" for event in events)
                + "data: [DONE]\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
PY

python3 "$WORK/server.py" > "$WORK/port" 2> "$WORK/server.log" &
SERVER_PID=$!
i=0
while [ ! -s "$WORK/port" ] && [ "$i" -lt 50 ]; do
	sleep 0.1
	i=$((i + 1))
done
[ -s "$WORK/port" ] || { echo "FAIL: mock backend did not start"; exit 1; }
PORT=$(cat "$WORK/port")

SCRIPT="$ROOT/tests/inferno/.llmsrv-flush-test.$$.sh"
cat > "$SCRIPT" <<EOF
#!/dis/sh.dis
load std
mkdir -p /tmp
mount -ac {mntgen} /n >[2] /dev/null
bind -a '#I' /net
ndb/cs
llmsrv -b openai -u http://127.0.0.1:$PORT/v1 -M mock &
sleep 1
id=\`{cat /mnt/llm/new}
for i in 1 2 3 4 {
	echo request-\$i > /mnt/llm/\$id/ask
	cat /mnt/llm/\$id/ask > /tmp/llmsrv-flush.out &
	reader=\$apid
	sleep 1
	kill \$reader >[2] /dev/null
	sleep 5
	model=\`{cat /mnt/llm/\$id/model}
	if {! ~ \$model mock} { raise 'fail:model read after flushed ask' }
}
echo final-request > /mnt/llm/\$id/ask
cat /mnt/llm/\$id/ask > /tmp/llmsrv-final.out
if {! grep -s 'delayed reply' /tmp/llmsrv-final.out} { raise 'fail:final reply mismatch' }
echo LLMSRV_FLUSH_PASS
EOF
chmod +x "$SCRIPT"
: > "$WORK/emu.log"

OPENAI_API_KEY=test "$EMU" -c1 -r"$ROOT" /dis/sh.dis "/tests/inferno/$(basename "$SCRIPT")" > "$WORK/emu.log" 2>&1 &
EMU_PID=$!
i=0
while kill -0 "$EMU_PID" 2>/dev/null && [ "$i" -lt 45 ]; do
	if grep -q '^LLMSRV_FLUSH_PASS$' "$WORK/emu.log"; then
		cat "$WORK/emu.log"
		rm -f "$SCRIPT"
		exit 0
	fi
	if grep -q 'exslave mismatch\|mount rpc error\|sh: fail:' "$WORK/emu.log"; then
		break
	fi
	sleep 1
	i=$((i + 1))
done

cat "$WORK/emu.log"
cat "$WORK/server.log"
rm -f "$SCRIPT"
echo "FAIL: llmsrv mount did not survive flushed async reads" >&2
exit 1

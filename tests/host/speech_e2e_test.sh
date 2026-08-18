#!/usr/bin/env bash
# Hermetic composed voice-mode test. No microphone, model, key, or network
# service outside loopback is used.

set -u

ROOT=${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export ROOT

case "$(uname -s)" in
Darwin) syshost=MacOSX ;;
Linux) syshost=Linux ;;
*) echo "speech-e2e: unsupported host" >&2; exit 1 ;;
esac

EMU=${EMU:-$ROOT/emu/$syshost/o.emu}
PYTHON=${PYTHON:-python3}

fail()
{
	echo "FAIL: $*" >&2
	exit 1
}

[ -x "$EMU" ] || fail "emulator not built: $EMU"
command -v "$PYTHON" >/dev/null 2>&1 || fail "python3 is required"
[ -f "$ROOT/tests/speech_e2e_test.dis" ] || fail "tests/speech_e2e_test.dis is not built"

mkdir -p "$ROOT/tmp"
state=$(mktemp -d "$ROOT/tmp/speech-e2e.XXXXXX") || fail "cannot create state directory"
inferno_state=/tmp/$(basename "$state")
stub_pid=
emu_pid=

cleanup()
{
	[ -n "$emu_pid" ] && kill -9 "$emu_pid" 2>/dev/null || true
	[ -n "$stub_pid" ] && kill "$stub_pid" 2>/dev/null || true
	[ -n "$stub_pid" ] && wait "$stub_pid" 2>/dev/null || true
	rm -rf "$state"
}
trap cleanup EXIT HUP INT TERM

: > "$state/wake.next"
: > "$state/listen.next"
: > "$state/requests.jsonl"

"$PYTHON" - "$state" >"$state/stub.log" 2>&1 <<'PY' &
import json
import pathlib
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

state = pathlib.Path(sys.argv[1])


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def send_json(self, value):
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def send_sse(self, text):
        events = [
            {"id": "chatcmpl-voice-e2e", "object": "chat.completion.chunk",
             "choices": [{"index": 0, "delta": {"content": text}, "finish_reason": None}]},
            {"id": "chatcmpl-voice-e2e", "object": "chat.completion.chunk",
             "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
             "usage": {"prompt_tokens": 8, "completion_tokens": 4, "total_tokens": 12}},
        ]
        body = "".join("data: " + json.dumps(event, separators=(",", ":")) + "\n\n"
                       for event in events)
        body += "data: [DONE]\n\n"
        encoded = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        if self.path.endswith("/models"):
            self.send_json({"object": "list", "data": [{"id": "ci-voice-e2e", "object": "model"}]})
            return
        self.send_error(404)

    def do_POST(self):
        if not self.path.endswith("/chat/completions"):
            self.send_error(404)
            return
        size = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(size)
        request = json.loads(body)
        with (state / "requests.jsonl").open("a", encoding="utf-8") as log:
            log.write(json.dumps(request, separators=(",", ":")) + "\n")
        if request.get("stream"):
            self.send_sse("local LLM working")
            return
        self.send_json({
            "id": "chatcmpl-voice-e2e",
            "object": "chat.completion",
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": "local LLM working"},
                "finish_reason": "stop",
            }],
            "usage": {"prompt_tokens": 8, "completion_tokens": 4, "total_tokens": 12},
        })


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(state / "port").write_text(str(server.server_address[1]), encoding="ascii")
server.serve_forever()
PY
stub_pid=$!

i=0
while [ ! -s "$state/port" ]; do
	i=$((i + 1))
	[ "$i" -lt 100 ] || {
		cat "$state/stub.log" >&2
		fail "OpenAI stub did not start"
	}
	sleep 0.05
done

port=$(cat "$state/port")
url=http://127.0.0.1:$port/v1
log=$state/emulator.log

env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY \
	"$EMU" -c1 -r"$ROOT" /tests/speech_e2e_test.dis \
	-u "$url" -H "$state" -I "$inferno_state" \
	-X "$ROOT/tests/host/speech_e2e_helper.sh" >"$log" 2>&1 &
emu_pid=$!

start=$SECONDS
while kill -0 "$emu_pid" 2>/dev/null; do
	if grep -q '^PASS$' "$log" 2>/dev/null; then
		break
	fi
	if grep -q -- '^--- FAIL:' "$log" 2>/dev/null; then
		break
	fi
	[ $((SECONDS - start)) -lt 75 ] || break
	sleep 0.2
done

kill -9 "$emu_pid" 2>/dev/null || true
wait "$emu_pid" 2>/dev/null || true
emu_pid=

if ! grep -q '^PASS$' "$log" || grep -q -- '^--- FAIL:' "$log"; then
	echo "---- speech E2E emulator output ----" >&2
	cat "$log" >&2
	echo "---- OpenAI stub output ----" >&2
	cat "$state/stub.log" >&2
	echo "---- captured OpenAI requests ----" >&2
	cat "$state/requests.jsonl" >&2
	echo "---- speech helper state ----" >&2
	for diagnostic in wake.next listen.next say.last say.log say.started say.done; do
		if [ -f "$state/$diagnostic" ]; then
			echo "[$diagnostic]" >&2
			cat "$state/$diagnostic" >&2
		fi
	done
	fail "composed voice-mode scenario failed"
fi

grep -q '"model":"ci-voice-e2e"' "$state/requests.jsonl" || \
	fail "explicit OpenAI model did not reach the local endpoint"
[ "$(wc -l < "$state/requests.jsonl" | tr -d ' ')" = 1 ] || \
	fail "voice turn did not produce exactly one LLM request"
grep -q 'local LLM working' "$state/say.log" || \
	fail "assistant response was not sent through speech9p"

echo "PASS: composed voice turn used the explicit local OpenAI endpoint"
echo "PASS: streaming transcript submitted once and response reached TTS"
echo "PASS"

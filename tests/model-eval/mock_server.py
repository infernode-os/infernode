#!/usr/bin/env python3
"""
Tiny OpenAI-compatible mock for self-testing runner.py.

Returns scripted responses keyed off the user message + model name, so
we can verify runner.py's loop and grading without a real LLM. Useful
for CI sanity checks ("does the harness still work") and for debugging
new scenarios.

Usage:
  python mock_server.py --port 11444 &
  python runner.py --url http://localhost:11444/v1/chat/completions \\
                   --models mock-good mock-pathprefix mock-jsonleak \\
                   --runs 1
"""
from __future__ import annotations
import argparse
import json
import sys
import threading
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer


# Map of (model_name, last_user_message_prefix) → response shape.
# Each "response shape" is a list of turns; each turn has either
# tool_calls or content.
SCRIPTS: dict[tuple[str, str], list[list[dict]]] = {

    # --- mock-good: behaves like an ideal model ---
    ("mock-good", "Launch the shell"): [
        [{"tool_calls": [{"name": "launch", "args": "shell"}]}],
        [{"content": "Done."}],
    ],
    ("mock-good", "Open Charon"): [
        [{"tool_calls": [{"name": "launch", "args": "charon https://example.com"}]}],
        [{"content": "Browser opened."}],
    ],
    ("mock-good", "Could you present a mermaid demo"): [
        [{"tool_calls": [
            {"name": "present", "args": "create demo type=mermaid label=Demo"},
            {"name": "present", "args": "write demo flowchart LR\\nA-->B-->C"},
        ]}],
        [{"content": "Mermaid demo presented."}],
    ],
    ("mock-good", "Show me a Julia fractal"): [
        [{"tool_calls": [
            {"name": "launch", "args": "fractals"},
            {"name": "fractal", "args": "julia -0.4 0.6"},
        ]}],
        [{"content": "Julia fractal rendered."}],
    ],
    ("mock-good", "Open the editor and show me"): [
        [{"tool_calls": [
            {"name": "launch", "args": "editor"},
            {"name": "editor", "args": "open /usr/me/notes.txt"},
        ]}],
        [{"content": "File opened."}],
    ],
    ("mock-good", "Display 'Hello from Veltro!'"): [
        [{"tool_calls": [{"name": "editor", "args": "write Hello from Veltro!"}]}],
        [{"content": "Displayed."}],
    ],
    ("mock-good", "What does it say"): [
        [{"tool_calls": [{"name": "editor", "args": "read body"}]}],
        [{"content": "It says 'Hello world'."}],
    ],
    ("mock-good", "Did that work"): [
        [{"content": "Yes — the message is displayed in the editor."}],
    ],
    ("mock-good", "Display whatever message"): [
        [{"tool_calls": [{"name": "editor", "args": "write Hello, agent!"}]}],
        [{"content": "Done."}],
    ],

    # --- mock-pathprefix: simulates the editor path-prefix bug ---
    ("mock-pathprefix", "Display 'Hello from Veltro!'"): [
        [{"tool_calls": [
            {"name": "editor", "args": "write /tmp/editor/status \"Hello from Veltro!\""},
        ]}],
        [{"content": "Done."}],
    ],

    # --- mock-jsonleak: simulates Mistral's bare-JSON-in-content failure ---
    ("mock-jsonleak", "Display 'Hello from Veltro!'"): [
        [{"content": '{"name":"editor","arguments":{"args":"write Hello"}}'}],
    ],

    # --- mock-asks: simulates under-confident model that asks instead of acts ---
    ("mock-asks", "Display whatever message"): [
        [{"content": "What message would you like me to display?"}],
    ],
}


def find_script(model: str, user_msg: str) -> list[list[dict]] | None:
    for (m, prefix), script in SCRIPTS.items():
        if model == m and prefix in user_msg:
            return script
    return None


class MockHandler(BaseHTTPRequestHandler):
    log_message = lambda self, *a, **k: None

    def do_POST(self):  # noqa: N802
        n = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(n))
        model = body["model"]

        # Determine which "turn" we're on by counting prior tool messages
        msgs = body["messages"]
        last_user = next((m["content"] for m in reversed(msgs) if m["role"] == "user"), "")
        # Tool-result count tells us which scripted turn to return
        n_tool_results = sum(1 for m in msgs if m["role"] == "tool")

        script = find_script(model, last_user)
        if script is None:
            # Default: friendly empty response
            choice = {
                "message": {"content": f"(no script for model={model!r}, prompt={last_user[:40]!r})"},
                "finish_reason": "stop",
            }
        else:
            # Pick the turn based on how many tool results we've seen
            turn_idx = min(n_tool_results, len(script) - 1)
            turn = script[turn_idx][0]
            tcs = []
            for tc in turn.get("tool_calls", []):
                tcs.append({
                    "id": f"call_{uuid.uuid4().hex[:8]}",
                    "type": "function",
                    "function": {
                        "name": tc["name"],
                        "arguments": json.dumps({"args": tc["args"]}),
                    },
                })
            choice = {
                "message": {
                    "content": turn.get("content", ""),
                    **({"tool_calls": tcs} if tcs else {}),
                },
                "finish_reason": "tool_calls" if tcs else "stop",
            }

        resp = {"choices": [choice], "model": model}
        data = json.dumps(resp).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def serve(port: int):
    HTTPServer(("127.0.0.1", port), MockHandler).serve_forever()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=11444)
    args = ap.parse_args()
    print(f"mock OpenAI-compat server on http://localhost:{args.port}", file=sys.stderr)
    serve(args.port)


if __name__ == "__main__":
    main()

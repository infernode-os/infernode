#!/usr/bin/env python3
#
# A fake LLM API over TLS for tests/host/llmclient_pool_test.sh: enough
# of OpenAI's /v1/chat/completions and /v1/models and Anthropic's
# /v1/messages, buffered and streamed (SSE), over HTTP/1.1 persistent
# connections, for llmclient's connection pool.
#
# Every reply's text says which connection carried it and what the
# server has counted so far:
#
#	conn <id> req <n> conns <accepted> slams <s> midfails <m>
#
# so the client sees, from the reply alone, whether a connection was
# reused.  What a request asks of the server is its model's name:
#
#	plain		a reply with Content-Length (the default)
#	chunked		a reply in chunks
#	(stream)	"stream": true: SSE in chunks, [DONE] or message_stop,
#			then the terminating chunk
#	lateend		streamed; the terminating chunk 1.5s after [DONE]
#	slow		streamed: 50 deltas 200ms apart (to be cancelled)
#	slow2		streamed: 5 deltas 200ms apart (two at once)
#	idle		a reply, then the connection closed after 300ms idle
#			(a server's idle timeout, shorter than the client's)
#	close		a reply with Connection: close, then closed
#	slam		the request read, the connection closed, no reply
#	midfail		a header and part of the body, then closed
#
# A request sent as HTTP/1.0 or with Connection: close is answered and
# the connection closed, as llmclient before its pool asked.
#
# --delay MS also listens on a second port that relays to the first
# with MS of round-trip time: half each way on every chunk, and a whole
# round trip before a new connection's first byte (its TCP handshake).
#
# It prints the TLS port, then the relay's (if any), and serves until
# killed.
#
# usage: fake_llm.py --cert C --key K [--delay MS]

import argparse, json, socket, ssl, sys, threading, time, queue

lock = threading.Lock()
count = {"conns": 0, "reqs": 0, "slams": 0, "midfails": 0}


def text(cid):
    with lock:
        count["reqs"] += 1
        return "conn %d req %d conns %d slams %d midfails %d" % (
            cid, count["reqs"], count["conns"], count["slams"], count["midfails"])


def readreq(f):
    """One request from file f: (method, path, version, headers, body), or None at EOF."""
    line = f.readline()
    if not line:
        return None
    method, path, version = line.decode().strip().split(" ", 2)
    hdrs = {}
    while True:
        h = f.readline()
        if not h:
            return None
        h = h.decode().strip()
        if h == "":
            break
        k, v = h.split(":", 1)
        hdrs[k.strip().lower()] = v.strip()
    body = b""
    n = int(hdrs.get("content-length", "0"))
    if n:
        body = f.read(n)
    return method, path, version, hdrs, body


def chunk(b):
    return b"%x\r\n%s\r\n" % (len(b), b)


def openai_json(t):
    return json.dumps({"id": "x", "object": "chat.completion", "model": "fake",
        "choices": [{"index": 0, "message": {"role": "assistant", "content": t},
                     "finish_reason": "stop"}],
        "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}).encode()


def anthropic_json(t):
    return json.dumps({"id": "x", "type": "message", "role": "assistant",
        "content": [{"type": "text", "text": t}], "stop_reason": "end_turn",
        "usage": {"input_tokens": 1, "output_tokens": 1}}).encode()


def openai_events(parts):
    for p in parts:
        yield b"data: " + json.dumps({"choices": [{"index": 0, "delta": {"content": p}}]}).encode() + b"\n\n"
    yield b"data: " + json.dumps({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
        "usage": {"total_tokens": 2}}).encode() + b"\n\n"
    yield b"data: [DONE]\n\n"


def anthropic_events(parts):
    def ev(name, d):
        return b"event: " + name.encode() + b"\ndata: " + json.dumps(d).encode() + b"\n\n"
    yield ev("message_start", {"type": "message_start", "message": {"usage": {"input_tokens": 1}}})
    yield ev("content_block_start", {"type": "content_block_start", "index": 0,
        "content_block": {"type": "text", "text": ""}})
    for p in parts:
        yield ev("content_block_delta", {"type": "content_block_delta", "index": 0,
            "delta": {"type": "text_delta", "text": p}})
    yield ev("content_block_stop", {"type": "content_block_stop", "index": 0})
    yield ev("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn"},
        "usage": {"output_tokens": 1}})
    yield ev("message_stop", {"type": "message_stop"})


def serve(conn, cid):
    f = conn.makefile("rb")
    idle = None
    try:
        while True:
            conn.settimeout(idle)
            try:
                r = readreq(f)
            except (socket.timeout, TimeoutError):
                return	# idle too long: closed, as a server does
            if r is None:
                return
            method, path, version, hdrs, body = r
            closing = version == "HTTP/1.0" or hdrs.get("connection", "").lower() == "close"
            conn.settimeout(None)
            model, stream = "plain", False
            if body:
                j = json.loads(body)
                model, stream = j.get("model", "plain"), bool(j.get("stream"))
            if path.endswith("/models"):
                model = "models"
            anth = path.endswith("/messages")

            if model == "slam":
                with lock:
                    count["slams"] += 1
                return
            if model == "midfail":
                with lock:
                    count["midfails"] += 1
                conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                             b"Content-Length: 1000\r\n\r\n{\"id\":")
                return

            t = text(cid)
            if model == "close":
                closing = True
            if stream:
                if model == "slow":
                    parts, gap = [t + " "] + ["."] * 49, 0.2
                elif model == "slow2":
                    parts, gap = [t + " "] + ["."] * 4, 0.2
                else:
                    parts, gap = [t[:5], t[5:]], 0
                events = anthropic_events(parts) if anth else openai_events(parts)
                h = b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n"
                if closing:
                    h += b"Connection: close\r\n"
                conn.sendall(h + b"\r\n")
                for e in events:
                    conn.sendall(chunk(e))
                    if gap:
                        time.sleep(gap)
                if model == "lateend":
                    time.sleep(1.5)
                conn.sendall(b"0\r\n\r\n")
            else:
                if model == "models":
                    b = json.dumps({"object": "list", "data": [{"id": t}]}).encode()
                else:
                    b = anthropic_json(t) if anth else openai_json(t)
                h = b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                if closing:
                    h += b"Connection: close\r\n"
                if model == "chunked":
                    conn.sendall(h + b"Transfer-Encoding: chunked\r\n\r\n" +
                                 chunk(b[:7]) + chunk(b[7:]) + b"0\r\n\r\n")
                else:
                    conn.sendall(h + b"Content-Length: %d\r\n\r\n" % len(b) + b)
            if closing:
                return
            if model == "idle":
                idle = 0.3
    except (OSError, ssl.SSLError, ValueError):
        return
    finally:
        try:
            conn.close()
        except OSError:
            pass


def accept(ls, ctx):
    while True:
        s, _ = ls.accept()
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        with lock:
            count["conns"] += 1
            cid = count["conns"]

        def run(s=s, cid=cid):
            try:
                c = ctx.wrap_socket(s, server_side=True)
            except (OSError, ssl.SSLError):
                s.close()
                return
            serve(c, cid)
        threading.Thread(target=run, daemon=True).start()


def pump(src, dst, oneway):
    """Copy src to dst, each chunk oneway seconds late, in order."""
    q = queue.Queue()

    def send():
        while True:
            due, b = q.get()
            d = due - time.monotonic()
            if d > 0:
                time.sleep(d)
            if b is None:
                try:
                    dst.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
                return
            try:
                dst.sendall(b)
            except OSError:
                return
    threading.Thread(target=send, daemon=True).start()
    while True:
        try:
            b = src.recv(65536)
        except OSError:
            b = b""
        q.put((time.monotonic() + oneway, b or None))
        if not b:
            return


def relay(ls, port, rtt):
    while True:
        c, _ = ls.accept()

        def run(c=c):
            time.sleep(rtt)	# SYN, SYN-ACK
            u = socket.create_connection(("127.0.0.1", port))
            for s in (c, u):
                s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            threading.Thread(target=pump, args=(c, u, rtt / 2), daemon=True).start()
            pump(u, c, rtt / 2)
        threading.Thread(target=run, daemon=True).start()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cert", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--delay", type=int, default=0)
    a = ap.parse_args()
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(a.cert, a.key)
    ls = socket.socket()
    ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ls.bind(("127.0.0.1", 0))
    ls.listen(16)
    port = ls.getsockname()[1]
    print(port)
    if a.delay:
        rs = socket.socket()
        rs.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        rs.bind(("127.0.0.1", 0))
        rs.listen(16)
        print(rs.getsockname()[1])
        threading.Thread(target=relay, args=(rs, port, a.delay / 1000), daemon=True).start()
    sys.stdout.flush()
    accept(ls, ctx)


if __name__ == "__main__":
    main()

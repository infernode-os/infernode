# Node-auth stress / leak / DoS harness (hardware-run)

These assets stress the node-to-node authentication path under load. They are
**deliberately not wired into the auto-discovered test suite** (`tests/mkfile`
/ `tests/runner.dis`): they run for a long time, churn many TCP connections,
and are meant to be driven by hand on real hardware where their result is
trustworthy.

> **Sandbox caveat (read this first).** In the CI / cloud sandbox these were
> authored in, the host **SIGKILLs the emu process** once a per-session
> CPU/time budget is exhausted — a long churn run dies with exit 137 partway
> through, and eventually even a trivial test is killed at exit. There was
> **no OOM** (`dmesg` clean, RAM free) and the thread/proc count stayed flat,
> so those deaths are a *sandbox watchdog*, **not** an InferNode leak or
> crash. Host RSS introspection is also unreliable there because the emu forks
> a worker and the visible pid is a zombie stub. **Run these on a real host
> (bare metal / VM you control) to get a real verdict.** Tracked for hardware
> validation alongside the IPv6 task.

## churn — connection-churn leak / stability

`churn_node.b` runs a serving node and a connecting node in one emu over
loopback and performs N sequential `dial -> auth (hybrid PQ STS + ssl) ->
write -> read echo -> drop` cycles, with the server spawning a per-connection
handler exactly like `node_server.b`. The signer + Authinfos are generated
once and reused, so any per-iteration footprint growth isolates a
per-connection leak in the socket / handshake / ssl / fd lifecycle.

`run-churn.sh` launches it and samples the emu's RSS and open-fd count against
the `iter N` markers it prints, then checks that both **plateau** (a leak
shows as monotonic growth).

```sh
# from the repo root, on real hardware:
tests/stress/run-churn.sh [count] [alg] [port]
# e.g. 5000 cycles with a post-quantum signer:
tests/stress/run-churn.sh 5000 mldsa65 19500
```

Expected healthy output ends with `PASS: <count> cycles, RSS and fd count
plateaued`. A leak ends with `FAIL: resource growth ...` and the RSS/fd trace.

Run it across a couple of signer algorithms (e.g. `ed25519` and `mldsa65`):
their per-connection allocation profiles differ.

## dos_stall — slowloris / handshake-stall resistance

`dos_stall_test.b` is written as a `*_test.b` (testing-framework shape) but
lives here so it is not auto-run. It opens clients that dial and then **never
send a handshake byte**, pinning the server's per-connection handler in
`auth->server`, and asserts a legitimate client still authenticates and is
served — i.e. one (or many) stalled peers do not wedge the accept loop. This
confirms the spawn-per-connection design in `node_server.b` and would catch a
regression to an inline `accept -> auth` loop, which a single staller would
block.

```sh
# build with the native limbo, then run directly:
limbo -I module -o dis/tests/stress/dos_stall_test.dis tests/stress/dos_stall_test.b
./emu/Linux/o.emu -c1 -r$PWD /dis/tests/stress/dos_stall_test.dis -v
```

Note: the server's per-connection handler has **no handshake timeout**, so
stalled peers accumulate blocked handlers and fds for the life of the
connection. The accept loop is not blocked (good), but a handshake-read
deadline on `auth->server` would bound the resource a hostile peer can pin —
worth considering if these nodes are exposed to untrusted networks.

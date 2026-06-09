# Node-auth performance baselines (hardware-run)

`bench_node.b` measures the cost of the node-to-node auth path and prints three
things:

1. **keygen latency** per certificate signature algorithm (one `genSK`)
2. **handshake latency** per algorithm — a full `Keyring->auth` STS handshake
   (classical DH + ML-KEM-768 + cert sign/verify), averaged over N iterations,
   reusing one keypair
3. **encrypted-channel throughput** per `ssl` cipher (MB/s pushing a payload
   through a negotiated `auth->client`/`auth->server` channel)

Timing is `sys->millisec()` inside the emu — no host introspection. It is **not**
wired into the auto-run suite (it's slow and the numbers are environment-
dependent). Absolute figures vary with host speed / emu build / JIT; the value
is the **relative** cost between algorithms and ciphers and a repeatable method.
Run on the target hardware for real numbers.

```sh
# build, then run from the repo root:
limbo -I module -o dis/tests/bench/bench_node.dis tests/bench/bench_node.b
./emu/Linux/o.emu -c1 -r$PWD /dis/tests/bench/bench_node.dis [mode [iters [MiB]]]
#   mode  : all (default) | lat | tp
#   iters : fast-alg handshake samples (default 10; SLH-DSA capped at 2)
#   MiB   : throughput payload size (default 8)
```

> **Note on SLH-DSA + host watchdogs.** SLH-DSA signing is extremely CPU-heavy
> (millions of SHAKE calls per signature). In a sandbox with a CPU watchdog it
> can get the emu SIGKILLed mid-run. Use `mode=tp` to capture throughput on its
> own, and `mode=lat` (ideally on hardware) for the full latency table.

## Illustrative output

From the (slow, shared) sandbox these were authored in — **relative** costs only,
not representative absolute numbers:

```
== keygen + handshake latency (ms) ==
  ed25519      keygen=0      handshake_avg=334    ms  (n=5)
  mldsa65      keygen=1      handshake_avg=337    ms  (n=5)
  mldsa87      keygen=1      handshake_avg=337    ms  (n=5)
  rsa          keygen=10685  handshake_avg=368    ms  (n=5)
  dsa          keygen=2329   handshake_avg=346    ms  (n=5)
  elgamal      keygen=75     handshake_avg=942    ms  (n=5)
  slhdsa192s   keygen=986    handshake_avg=9330   ms  (n=2)
  slhdsa256s   (even slower; trips the sandbox CPU watchdog — run on hardware)

== encrypted-channel throughput (8 MiB payload) ==
  none          500.00 MB/s     <- raw pipe ceiling (no ssl)
  aes_256_cbc    68.96 MB/s
  aes_128_cbc    72.72 MB/s
  ideacbc        36.36 MB/s
  ideaecb        44.19 MB/s
```

What the shape tells you (independent of the slow host):

- **The handshake is dominated by the shared classical-DH-2048 + ML-KEM-768 key
  agreement (~340 ms here), not the signature** — ed25519, ML-DSA-65/87, RSA and
  DSA all land within ~10% of each other. ElGamal cert verify is visibly heavier
  (~3×), and SLH-DSA is in a different league entirely (signing dominates, ~9 s+)
  — fine as a conservative hash-based backup, not a default.
- **keygen** is effectively free for ed25519/ML-DSA/SLH-DSA, seconds for RSA-2048
  and DSA-1024 — so for those, generate the signer keyfile once and reuse it
  (which `createsignerkey` / `serve-llm.sh` already do).
- **Line encryption** costs ~7× vs plaintext on this build; AES-128 ≳ AES-256 >
  IDEA. AES has no hardware path in this emu build, so a host with AES-NI wired
  through would shift these substantially — another reason to measure on target.

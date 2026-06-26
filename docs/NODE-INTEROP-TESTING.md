# Node-to-node interoperability testing (cert auth + post-quantum transport)

This document covers how InferNode and NERVA3 nodes authenticate and talk to
each other over the native Inferno transport, the test assets that exercise it,
and a transport-layer bug found and fixed while building them.

## What "talking to each other" means here

Two nodes establish a session over the native Inferno authentication protocol
(`Keyring->auth`, the Station-to-Station handshake in `libinterp/keyring.c`)
plus the `ssl` line-encryption device:

1. **Cert auth.** Each node presents an X.509-style certificate signed by a
   common signer (`auth/createsignerkey` → `auth/mkauthinfo`). Certs may be
   classical (ed25519) or post-quantum (ML-DSA-65 / -87, SLH-DSA).
2. **Hybrid PQ key agreement.** Protocol v2 combines classical Diffie-Hellman
   with a mutual **ML-KEM-768** encapsulation; the session secret is
   `SHA3-512("infernode-pq-sts-v2" || dh || kem_lo || kem_hi || ek_lo || ek_hi)`.
   This closes the harvest-now-decrypt-later gap on node-to-node traffic.
   See [CRYPTO-MODERNIZATION.md §10](CRYPTO-MODERNIZATION.md).
3. **Line encryption.** The 64-byte secret feeds the `ssl` device; the default
   negotiated by `mount -k` / `styxlisten` is `aes_256_cbc` + `sha256`.
4. **9P/Styx.** Everything above carries Styx (9P) — `sys->export` on the
   serving node, `sys->mount` on the connecting node.

The same path backs `mount -k <keyfile> tcp!host!5640 /mnt/llm` against the
headless LLM daemon (`serve-llm.sh`) and any node-to-node mount.

## Test assets

| Asset | Kind | What it proves |
|-------|------|----------------|
| `tests/pqauth_test.b` | in-emu unit (auto-discovered by the runner) | the hybrid handshake itself: happy path (ed25519 + ML-DSA-65 signers), real-TCP encrypted channel, and the negatives (downgrade, tampered/malformed ML-KEM key) |
| `tests/interop_test.b` | in-emu unit (auto-discovered) | end-to-end: real TCP + cert auth + PQ handshake + `aes_256_cbc` ssl + a real `export`/`mount` **file transfer**, across the full fast certificate range: ed25519, ML-DSA-65, ML-DSA-87, RSA-2048, **DSA-1024**, ElGamal-2048 |
| `tests/cipher_matrix_test.b` | in-emu unit (auto-discovered) | every `ssl` line-encryption cipher (`aes_256_cbc`, `aes_128_cbc`, `ideacbc`, `ideaecb`) and MAC (`sha256`, `sha1`, `md5`, `md4`), plus the unencrypted `none` path, negotiated through a real `auth->server`/`auth->client` handshake and verified to round-trip a payload byte-for-byte |
| `tests/authneg_test.b` | in-emu unit (auto-discovered) | the trust + integrity layer must **fail closed**: untrusted signer rejected, expired certificate rejected, a cipher the server did not offer refused, and a one-byte tamper on the encrypted channel caught by the ssl record MAC |
| `tests/crypto_props_test.b` | in-emu unit (auto-discovered) | protocol crypto guarantees: two handshakes with the same certs derive **different** 64-byte secrets (ephemeral key agreement / forward-secrecy proxy), a reflected `alpha**r0` is caught by the replay check, and a one-byte-corrupted certificate signature is rejected |
| `tests/interrupt_test.b` | in-emu unit (auto-discovered) | interruptibility: an abrupt TCP disconnect **mid-handshake** makes the peer error cleanly (`hungup`), and **mid-transfer** makes the reader hit EOF with the partial data — no crash, no hang (timeout-guarded) |
| `tests/concurrent_auth_test.b` | in-emu unit (auto-discovered) | 12 clients authenticate to one spawn-per-connection server **simultaneously** (shared Authinfos both ends), each echoing a distinct 4 KiB payload; asserts every client gets its **own** bytes back — no cross-talk, no races, no hang |
| `tests/interop/run-mount-auth.sh` | host harness | **real CLI path**: `auth/createsignerkey` -> on-disk keyfile -> `styxlisten -k ... export /lib` (server) <- `mount -k ... -C` (client), reading a file through the encrypted styx mount and verifying it; covers ed25519 + ML-DSA-65 and checks an anonymous `mount -A` is rejected |
| `tests/handshake_fuzz_test.b` | in-emu unit (auto-discovered) | receiver robustness: 9 malformed inbound handshake streams (empty, garbage, bad/oversized/truncated length headers, zero-length flood, garbage payloads) over real TCP must each make `auth->server` fail closed — no secret, no crash, no hang |
| `tests/interop/run-interop.sh` | host harness | **cross-binary**: launches two *separate* emu processes (optionally from different InferNode/NERVA3 trees) and transfers a file between them, verifying it byte-for-byte |

### Running the in-emu tests

```sh
# build once
export ROOT=$PWD; export PATH=$PWD/Linux/amd64/bin:$PATH    # Linux amd64
cd tests && mk install && cd ..

./emu/Linux/o.emu -c1 -r$PWD /dis/tests/pqauth_test.dis  -v
./emu/Linux/o.emu -c1 -r$PWD /dis/tests/interop_test.dis -v
```

Both **skip cleanly** (rather than fail) on a host with no IP stack at all.

### Running the cross-binary harness

```sh
# InferNode serves, NERVA3 connects, fully post-quantum certs:
tests/interop/run-interop.sh /path/to/infernode /path/to/nerva3 mldsa65

# Same binary on both ends (smoke test), classical certs:
tests/interop/run-interop.sh
```

It generates a signer keyfile in the server tree, shares it with the client
tree (the crypto core is identical across the two forks, so keyfiles are
portable), starts `interop_node_server` under the server emu and
`interop_node_client` under the client emu, and `cmp`s the pulled file against
the source. Expected output ends with:

```
PASS: 722 bytes transferred and verified byte-for-byte over cert-auth + PQC + ssl
```

## Transport bug fixed: IPv4 fallback for IPv6-less hosts

**Symptom.** On any host whose kernel has IPv6 compiled out or disabled
(common in containers, CI runners, and hardened deployments), *all* emu
networking failed with `Address family not supported by protocol` —
`/net/tcp/clone`, `announce`, `dial`, every mount. Node-to-node auth could not
even open a socket, so cert auth + PQC over the wire was untestable and, more
importantly, unusable on those hosts.

**Cause.** The Linux/Posix IP device (`emu/port/ipif6-posix.c`, selected by
`emu/Linux/emu`) created every socket with `socket(AF_INET6, …)` and used
v4-mapped addresses, with **no fallback** when `AF_INET6` is unavailable.

**Fix.** `so_socket()` now detects an unavailable `AF_INET6` once
(`EAFNOSUPPORT`/`EPROTONOSUPPORT`) and transparently falls back to `AF_INET`
for the life of the process; the address-marshalling helpers
(`so_connect`/`so_bind`/`so_accept`/`so_getsockname`/`so_send`/`so_recv`)
build `sockaddr_in` for v4-mapped/unspecified addresses in that mode. On a
normal dual-stack host nothing changes — the `AF_INET6` path is byte-for-byte
the original. After the fix, `pqauth_test`'s `HybridTcpChannel` runs for real
(previously skipped) and the interop harness passes on this host.

## Resolved: Dis VM array zero-initialization (INFR-261)

`keyring_test`'s `AES256` and `DESCBC` cases used to fail in the long test run.
Root cause was a **Dis VM array zero-initialization bug**: Limbo specifies that
`array[n] of T` creates each element with its zero value, but the `newa` opcode
allocated array storage from recycled heap memory and only initialised
*pointer* element types — value-type arrays (`byte`/`int`/…) exposed stale
bytes from freed objects. Fresh arena memory is zero, so it only appeared once
a block was reused. `keyring_test` tripped it because a test passed an
`array[8] of byte` straight in as a cipher IV, and that array had reused a
freed AES-plaintext buffer. (The libsec ciphers were always correct; the `ssl`
line-encryption device calls libsec directly in C, so node-to-node encrypted
comms were never affected — consistent with the encrypted-channel cases
passing throughout.)

Fixed by zero-initializing value-type array storage in `OP(newa)`
(`libinterp/xec.c`), which the interpreter and both JITs share. `keyring_test`
is now 27 passed / 0 failed. See `tests/arrayinit_test.b` for the regression
guard.

## Certificate algorithm matrix (the "full range of approved methods")

The keyring registers eight certificate signature algorithms
(`libinterp/keyring.c:keyringmodinit`). Node-to-node STS auth was exercised
with each, over a real TCP socket + `aes_256_cbc`/`sha256` ssl:

| Signer cert | Class | Node-to-node auth | Notes |
|-------------|-------|-------------------|-------|
| `ed25519`    | classical | ✅ | default modern signer |
| `rsa` (2048) | classical | ✅ | |
| `dsa` (1024) | classical | ✅ | **fixed** — see below |
| `elgamal` (2048) | classical | ✅ | 2048 selects precomputed RFC 3526 DH params |
| `mldsa65`    | post-quantum (ML-DSA-65) | ✅ | |
| `mldsa87`    | post-quantum (ML-DSA-87) | ✅ | |
| `slhdsa192s` | post-quantum (SLH-DSA-SHAKE-192s) | ✅ | ~16 KB cert; ~9 s/sign |
| `slhdsa256s` | post-quantum (SLH-DSA-SHAKE-256s) | ✅ over TCP | ~40 KB cert; ~8 s/sign; see deadlock note |

`tests/interop_test.b` auto-runs the six fast algorithms end-to-end. The two
SLH-DSA variants are validated separately because their multi-second signing
makes the full export/mount exercise too slow for the routine suite; their
node auth was confirmed over a real TCP socket.

### Bug fixed: DSA certificates corrupted on (de)serialisation

`libkeyring/dsaalg.c`'s `dsa_str2sk`/`dsa_str2pk` parsed the second field
(`q`) from the *start* of the string again instead of from the advancing
cursor:

```c
dsa->pub.p = base64tobig(str, &p);
dsa->pub.q = base64tobig(str, &p);   /* BUG: re-reads field 0; should be (p, &p) */
dsa->pub.alpha = base64tobig(p, &p);
```

Every DSA key that crossed a serialisation boundary (a keyfile, or the public
key sent on the wire during `auth`) therefore had `q`, `alpha`, `key` and
`secret` shifted by one field. DSA cert auth failed with `bad certificate`
the moment a key was transmitted — i.e. DSA node-to-node auth never worked.
Fixed by chaining both fields from the cursor `p` (matching `rsaalg.c` and
`egalg.c`). `InteropDSA` in `tests/interop_test.b` guards it.

### Bug fixed: keygen crash on a non-positive key size

`genSK("rsa"|"elgamal", name, n)` with `n <= 1` did not fail cleanly:
`eggen` ran `mprand(n-1, …)` and aborted with `mpsetminbits: n < 0`, and
`rsagen` drove `genprime` to `p->top == 0` and an out-of-bounds `p->p[-1]`
write. Both now reject the size in the `eg_gen`/`rsa_gen` wrappers and return
nil, and `Keyring_genSK` propagates a nil key as a nil `SK` per its contract
(size-agnostic signers such as ed25519/ML-DSA/SLH-DSA are unaffected — they
legitimately accept `0`). The CLI (`auth/createsignerkey`) already validates
`32..4096`, so this only hardens direct `genSK` callers.

### Note: large SLH-DSA certs and the handshake's batch send

`Keyring->auth` sends four messages — including the full identity certificate
— before its first read. An SLH-DSA-256s certificate is ~40 KB, so two peers
each block writing their cert until the other reads. Over **TCP** (the real
node-to-node transport) the socket send buffer absorbs it and the handshake
completes; over a small-buffer **pipe** the two writes can deadlock. This is
a property of the transport buffer, not a wire-format incompatibility:
ed25519/RSA/ML-DSA certs (≤5 KB) and SLH-DSA-192s (~16 KB) stay under typical
buffers. If a future transport with a <40 KB send buffer must carry SLH-DSA-256s
certs, the handshake's send/read interleaving would need revisiting.

## Stress / leak / DoS harness (hardware-run)

`tests/stress/` holds a connection-churn leak/stability harness
(`churn_node.b` + `run-churn.sh`) and a slowloris/handshake-stall DoS test
(`dos_stall_test.b`). They are **not** wired into the auto-run suite — they
churn many TCP connections for a long time and are meant to be driven by hand
on real hardware. See `tests/stress/README.md`.

**Why not in CI/sandbox.** In the cloud sandbox these were authored in, the
host **SIGKILLs the emu process** once a per-session CPU/time budget is spent:
a long churn dies with exit 137 partway through, and eventually even a trivial
test is killed at exit. There was **no OOM** (`dmesg` clean, RAM free) and the
emu's thread/process count stayed flat, so those deaths are a *host watchdog*,
**not** an InferNode memory leak or crash. Host RSS introspection is also
unreliable there (the emu forks a worker; the visible pid is a zombie stub).
A trustworthy leak/stability verdict therefore needs a real host — tracked for
hardware validation alongside the IPv6 task.

One design observation surfaced by the DoS test: `node_server.b` spawns a
per-connection handler, so a stalled handshake does **not** block the accept
loop.  Production listeners now also bound the resource a hostile peer can pin:
`listen` and `styxlisten` accept `-T ms` and default to a 30000 ms pre-auth
deadline.  On timeout the listener hangs up the network connection and kills
the auth worker.  `tests/interop/run-auth-timeout.sh` verifies the real
production path: a stalled TCP client is disconnected while a legitimate
`mount -k` still succeeds against the same listener.

## Performance baselines (hardware-run)

`tests/bench/bench_node.b` measures keygen + STS-handshake latency per
certificate algorithm and encrypted-channel throughput per `ssl` cipher
(`sys->millisec()` timing, no host introspection). Not auto-run — slow and
environment-dependent. See `tests/bench/README.md`. The shape it reveals: the
handshake is dominated by the shared DH-2048 + ML-KEM-768 key agreement (so
ed25519/ML-DSA/RSA/DSA land within ~10% of each other), ElGamal verify is ~3×
heavier, and SLH-DSA signing is in a different league (~9 s+, a conservative
backup not a default); line encryption costs ~7× vs plaintext with AES ≳ IDEA.

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
| `tests/interop_test.b` | in-emu unit (auto-discovered) | end-to-end: real TCP + cert auth + PQ handshake + `aes_256_cbc` ssl + a real `export`/`mount` **file transfer**, for both ed25519 and ML-DSA-65 certs |
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

# 9front security delta audit

Status: **in progress**. This is the durable ledger for reviewing security
fixes in 9front that might apply to InferNode's inherited Plan 9 and Inferno
code. An empty subject-keyword search is not evidence of parity: each candidate
is resolved against the actual diff and the corresponding InferNode call path.

## Baseline and method

The review is pinned to 9front commit
`fe19492531980b1772e2912de8163e17f95dfd5e` (2026-10-29). The GitHub tree is
the project's nightly mirror; commit identities are checked against its full
history. The initial candidate set covers the shared kernel, network, draw,
authentication, cryptographic, 9P, and export paths:

```
sys/src/9              -> os/, port/, emu/port/
sys/src/libdraw        -> libdraw/
sys/src/libmemdraw     -> libmemdraw/
sys/src/libsec         -> libsec/
sys/src/libauth        -> appl/lib/auth/, keyring and host auth code
sys/src/cmd/auth       -> appl/cmd/auth/
sys/src/cmd/exportfs   -> emu/port/exportfs.c, os/port/exportfs.c
sys/src/lib9p          -> Styx servers and libraries in appl/, lib9/, port/
```

Every row records one of four outcomes:

- **ported** — the vulnerable construction was present and the fix plus a
  regression is in this patch branch;
- **already safe** — equivalent protection is source-traced in InferNode;
- **not present** — the affected component or construction does not exist;
- **open** — applicability or the required regression is still being checked.

## Resolved candidates

| 9front commit | Upstream issue | InferNode result | Evidence / regression |
|---|---|---|---|
| `a3957dab172f8bb7f0d9c59fe4b8c4738ef35b26` | `exportfs` crafted `Twalk` path escape | already safe | InferNode's `Exwalk` calls `validname()` on every element and walks `Chan`s; it never concatenates client elements into a host pathname (`emu/port/exportfs.c`, `os/port/exportfs.c`). |
| `9211c6c5e25d9a4cc61ebccdcdfb6bcfaca3c88f` | ICMPv6 neighbor target/options out-of-bounds access | ported | `os/ip/icmp6.c` checks target and option bytes before `Ndpkt` access. Source and native-kernel build checked; the minimal QEMU virt interface cannot join the IPv6 multicast group needed for a wire regression. |
| `7838d68969549f938cc8e80c0c2b4218cb12805c` | IP transports pass a negative/underflowed length to `trimblock` | ported in applicable code | TCP and UDP checks are in `os/ip/{tcp,udp}.c`; raw QEMU sends a short UDP length and oversized TCP data offset. InferNode has no IL or RUDP implementation. |
| `1f7c0d20c381bebf89c75efbd58ab6c2ea8bc1e7` | invalid rectangles cause integer overflow and memory corruption | ported | shared `badrect()` gates allocation, loading, unloading and drawing; `draw_bounds_test.sh` covers zero and oversized geometry. |
| `1feadc683b7c15c2fa9ffc76fabbf3599fd26962` | negative-coordinate scan lines are one unit too large | ported | vlong `unitsperline()` arithmetic; regression checks `[-2,-1)` at depth 8. |
| `f4dfa0816c21b7c10fe742b5e925f28d58b4e83c` | temporary `unitsperline()` integer overflow | ported | same vlong calculation, retained even with the later coordinate constraints. |
| `71eaac5a0b2feed15d645a9c2c03d83bf26a5031` | `allocmemimage()` allocation-size overflow | ported | multiplication is performed in `uvlong` and capped before `poolalloc`. |
| `d7538ebb57aaa4d75d57d5540d2f2a2bb0215359` | rectangle coordinates overflow draw offset arithmetic | ported | `badrect()` validates coordinate and y-stride bounds with non-overflowing `vlong` arithmetic. |
| `e252b1b95755c97e4fbb3d3791ca39204fdec654` | compressed image twiddle writes beyond input | ported | transform loop is bounded by `ebuf`; a sentinel regression detects the old write. |
| `c4f5b99c8d75d190b2a0f6fa54e7b803b0342c82` | compressed image leading repeat leaks stack data (“9leak”) | ported | decoder history is zero-initialized and scrubbed; a leading-repeat regression requires zero pixels. |
| `77f00d60c530e342e6f8d323ab89c502c2318a11` | BLAKE2s incremental block chunking overflow | not present | InferNode's `libsec` has no BLAKE2 implementation. |
| `30cf3f13e93351c1741392289a3e3613d80de105` | draw RPC error paths leak refresh/polygon allocations | ported | `port/devdraw.c` frees both allocations through error handlers. |
| `13d3301fc5887ad9dd7f2f487fb55b850eff516b` | `x` draw RPC leaves a temporary clip rectangle installed after error | ported | `port/devdraw.c` restores `clipr` in an error handler covering all draw and glyph failures. |
| `e045eefc7e723e4e3bf036dd98178afebd8da88e` | TCP exponential-backoff counter wraps | ported | `Tcpctl.backoff` is an `int` and saturates at the largest shift used by `tcpsettimer`. |
| `482f6132f5282cacf813f13d2d716c5715a1da7d` | failed netif `wstat` leaks its decoded `Dir` | ported | `os/port/netif.c` frees the allocation through an error handler. |
| `907d5b933e08b395e607ff4bfe75c2281ac87200` | one-byte reads crash 9front factotum's C list generator | not present | InferNode factotum is Limbo; ctl/proto reads slice a complete string through `reads()`, which returns nil for zero/short ranges without indexing `n-2`. |
| `7d9677ed9930b8509a4dc6ff3bf40332e4b0e013` | devip conversation permission and accepted-call ownership errors | ported | `os/ip/devip.c` applies owner/other bits under the conversation lock, restricts `wstat`, and clones accepted calls with the listener owner. |
| `0f0444898d3cb97065be24127747c8efd4a8370d` | empty auth attribute token indexes before its buffer | not present | InferNode's Limbo `parseline()` checks `len n > 1` before inspecting the final byte and skips empty names. |
| `53fb1fc9822d9c65e7d4844acd35daa3a8c20010` | mount accepts an auth fid from another connection | ported | hosted and native `devmnt.c` require `authchan->mchan` to equal the transport channel. |
| `1f49e2a5a4139ed223a64fb3b446faaa6b0a02b6` | computed UDP checksum zero is emitted as “no checksum” | ported | IPv4 and IPv6 output encode arithmetic zero as `ffff`. |
| `4537fd480db2e30ea15183f756488853c9e9c9b0` | IPv6 preferred-lifetime addition wraps | ported in applicable code | `v6addrcurr()` uses elapsed-time subtraction; three erroneous C expressions using `10^3` (XOR) were also corrected to `1000`. This older Inferno path has no matching route-expiry list. |
| `a54302d3f05a601b38737e3a8de171012a43d423` | negative devip attach indexes before `ipfs` | ported | attach parses an unsigned device id; raw QEMU verifies `#I-1` is rejected and the guest remains alive. |
| `91ab1601e6b0a59bd3883bbf7f717b037c146832` | Plan 9 `devproc` note read uses the wrong destructor | not present | InferNode exposes Dis processes through a different `devprog` implementation and has no `p->note[]`/`freenote` construction. |
| `92488893530cedc6bacc04ecc07045c1464a96f1` | multicast close frees address storage while still using it | already safe; cleanup aligned | InferNode already unlinked but retained `Ipmulti` until every `remselfcache()` call completed. The port now also isolates removal errors and guarantees the deferred free, matching the fixed lifetime rule. |
| `8531472654712482179c8b88563c145717e82081` | recursive X.509/BER values can exhaust the stack | ported | InferNode's corresponding parser is `appl/lib/asn1.b`; it now caps recursive decoding at 32 and `x509_test` verifies an in-limit value succeeds while excessive nesting fails. |
| `95ae49ec384e5770c27748c15a3ca41365a49cfb` | fixed C buffers overflow while converting X.509 IDNs | not present | InferNode's X.509 code represents names and GeneralName values as Limbo strings/arrays and has no `Domlen`, `copysubject`, `mkaltname`, `strncpy`, or fixed-buffer IDN conversion path. |
| `441071c6f0230425c07bd10f396e380afc8d184e` | X25519 low-order peers yield an accepted all-zero shared key | ported | `Keyring_x25519` performs a fixed-length zero reduction and returns nil before exposing the result; deterministic RFC 7748 tests exercise the rejection. All TLS and hybrid paths use this primitive. |
| `f7e789f14018b9e4647c09bb6975ecb53144e693` | C TLS PKCS#1 decrypt leaks an `mpint` | not present | InferNode has no `tlshand.c`; its TLS and PKCS implementations are Limbo values managed by the interpreter rather than the affected manual `mpfree` path. |
| `c573dbaca6927bfa90a22ec716498dbe9abdd213`, `18f3d3e1242c6782c3949a665a859920bbd7725b` | auth/library file descriptors survive `exec` | not present as an exec inheritance mechanism | Limbo loads modules in-process and controls a child fd group explicitly with `pctl(NEWFD/FORKFD)`; `Sys` has no `OCEXEC` mode and there is no Unix-style exec boundary in these auth libraries. External commands use the fd list selected by their launcher. |
| `01d72e547c38c856cecae2821cd0f1aa9f57a20c` | private process pages and secure pools remain in RAM across reboot | open: architectural port required | Native InferNode marks a Dis *group* private for debugger access, but all Progs share the interpreter heap; it has no per-process page ownership corresponding to Plan 9 `PG_PRIV` or a `secrmem` pool. Reboot-time clearing therefore needs an interpreter/allocator design, not a mechanical kernel patch. |
| `af18284d6b34e27a1dfd11a0340735f13377bbae` | `icossin2()` negates `INT_MIN` and overflows its tangent arithmetic | ported | unsigned magnitudes and `uvlong` products are used; `draw_bounds_test.sh` covers both minimum coordinates. |
| `76bac3ccd6c42e01f7ad6d7f3dd25b968e201941` | Plan 9 `devmouse` races a changing `gscreen` pointer | not present | InferNode's hosted and native pointer devices use queues and display callbacks and contain neither `gscreen` nor `absmousetrack`/`scmousetrack`. |
| `1a48ac7387b21e3270935ca98d099f17ef18b9aa` | `ipmuxtreefree()` frees only the first level | not present | InferNode retains the protocol slot but has no `ipmux.c`, `Ipmux` tree, or corresponding filter parser. |
| `2e6fb00af4fae7afd8d6bc9767b89ff0da5670dd` | oversized `Rstat` aborts a C lib9p server and can double-free | ported in corresponding legacy server | Limbo memory management made the C double-free construction absent, and `styxservers` already converted oversized replies to `Rerror`. Deprecated `styxlib` now does the same; `memfs_test` verifies the bound and tag. |
| `8f68e89a895fb05b51429b02b4dd43ba65e3abfd` | C lib9p `srvrelease()` recursively grows the process stack | not present | InferNode's Styx servers are Limbo event loops and spawned Progs; there is no `srvrelease`, rfork forker, or recursive `srvwork` re-entry. |
| `3e3fe026185a70ee69097a0754c0592e989b097b`, `00c57fbf1e3f811067da39f2b8555930fcc91b4e` | authenticated 9P attach can claim a uname different from factotum's caller | ported in corresponding path | `styxpersist` now requires returned `Authinfo.cuid` to equal the requested uname before reattaching. Other shipped Styx helpers explicitly reject `Tauth`; authenticated exports authenticate the transport before serving it. |
| `74ea4566d362f243888079bbe2c218a257f59335` | SSL/TLS conversation permission expression grants owner bits to non-owners and other bits to owners | ported | hosted and native `devssl` use `devpermcheck`; `ssl_transport_test` creates an owner-only conversation, drops identity, and verifies reopen is denied. InferNode has no separate `devtls`. |
| `0349c32bd7c6aaef4212d876a5d77a86c154b289` | capability misuse can consume another user's one-shot capability; hash comparison leaks timing | ported in applicable hosted device | source-user validation now precedes list mutation and hash comparison reduces every byte. A parent/child identity regression proves a rejected wrong-user attempt does not consume the capability. Existing Inferno code already caps writes at 127 bytes and expires entries. |
| `2bf39a818a3bed3e3403e1d96aadc4cdf1135726` | reboot is readable and sysstat is world-writable | already safe | Native exposes reboot through owner-only `sysctl` handling and makes `sysstat` `0444`; hosted `sysctl` is owner-writable and has no writable `sysstat` entry. |
| `bd3dfb0dd23ab4d0ed9ab3c97c0226a7cfd1946` | font subfont growth copies beyond the old allocation | ported | `libdraw/font.c` now grows the array with `realloc` and clears only the newly allocated slots; host `libdraw` builds the corrected path. |
| `6eca397226a250f3859134b28f3cb8a0fea14011` | framebuffer console compares an element pointer with a byte count | not present | InferNode's framebuffer console is a new rune/UTF-8 implementation (`os/fb/fbcons.c`) and has no `xp`/`xbuf` cursor array. |
| `4714ed4130c95641d2d594a189e0bdcb702d91a6` | full `qproduce()` queue leaks a preallocated Block | already safe | Both InferNode implementations check closed/full state before calling `iallocb`; no Block exists on either early return. |
| `0f0b6def8c70d27b75844217691b6e88e2ff646a` | `Abind` creates a Chan↔mount-head reference cycle; failed uniqueness leaks mount heads | ported | hosted and native `cunique()` discard inherited `umh`, `Abind` always obtains a unique Chan before attaching a mount head, and error handlers release mount heads around copy-on-write. |
| `62a7db43846183f88686c638e59d74ee442c96ef` | factotum permits an unbounded number of active RPC workers | ported | the Limbo factotum refuses a seventeenth active fid before spawning its request Prog; an isolated live-service regression holds 16 RPCs pending and verifies the next write is rejected. |
| `e8228856df1973edd0eaa4fdaa7c862bf9a75fcb` | `topnwindows` validates only the first image before dereferencing every layer | ported | the draw `t` RPC now rejects each non-window image inside the collection loop before comparing its screen. |
| `0fea8e09903daa649c49b1b38a1888b7254d9841` | zero/negative-full-circle arcs overrun wedge bookkeeping or draw the wrong shape | ported | `memarc` returns for zero sweep, maps either full-circle direction to `memellipse`, and bounds `alpha` before wedge construction; the draw host regression verifies zero sweep performs no drawing. |
| `1608fbcb6378e0f75eeb9dcbb0d70c7f48382168` | C `tlshand` handshake encoder overflows fixed send buffers and emits unpadded MP integers | not present as the affected implementation | InferNode's TLS handshake is `appl/lib/crypt/tls.b`; builders allocate exact-size Limbo arrays and key agreement returns fixed-width byte arrays. It has no `TlsConnection.sendbuf`, `msgSend`, or MP-to-buffer construction from this commit. |
| `57c9ee901f7cb1c19ec18e96e874a848112bad01` | `devssl` compares record MACs with a timing-sensitive `memcmp` | already safe | Both hosted and native `checkdigestb()` reduce every digest-byte difference before branching; the comparison was independently hardened in `ac64df832` and contains no early exit. |
| `a26de4c3c74af9610a9cde6578f4ccd752608912` | `exportfs` loops forever when EOF/error truncates the first message body | already safe | InferNode's in-kernel exporters use `exreadmsg()` and leave the service loop on every zero or negative result, including a short body; they have no `ini` compatibility buffer or `localread9pmsg()` retry loop. |
| `cc2776de8d2bb45ca1727f84f74d4517947585c9` | another process can mutate a read buffer before `devmnt` copies it into the shared mount cache | ported | Hosted and native clients now populate cache pages directly from the reply's kernel `Block` chain before copying into user memory; writes are cached from the serialized kernel RPC, not the caller's buffer. |
| `e92c0d470b0ac35ca132a607018c36cb9216964a` | `mountmux()` publishes completion before reply state is stable and can race request recycling | ported with stronger lifetime serialization | Reply fields are completed before `done`; `mntflushfree()` now observes and removes requests under the same mount lock, so it cannot recycle a request while `mountmux()` is still waking its owner. The unused post-publication `mntstats` access was removed. |
| `62d86c34105dcc67dccdf429ff92fd35bd84cd72` | a protocol with too many conversations aliases qid conversation bits | ported | Hosted and native `Fsproto()` cap `p->nc` at `Maskconv+1` before allocating the conversation table. |
| `46832f04fa6f2ccd7a85d1a640bf5408e82b2571`, `1c021658107239bf4213d2d0f9b4cfc1fa13daf0` | native Plan 9 `exec` overflows a fixed user stack or races mutable `argv` strings | not present | InferNode has no `sysexec`, `USTKSIZE`, native user address space, or replacement stack copy. Dis module invocation passes garbage-collected arrays within the interpreter; hosted external-process launchers construct host argv separately. |
| `58435d125ee1a10d1b320138e02ebf46c5588509` | C TLS PKCS#1 decrypt double-free and short premaster-secret read | not present as the affected implementation | InferNode has no `tlshand.c`; `appl/lib/crypt/pkcs.b` checks the decoded block length and returns managed Limbo arrays, while `tls.b` verifies the premaster-secret length before indexing it. |
| `0734b1ca851f56044cb357e9cb30ce6f4efd5bfa` | C factotum clears a nil `p9sk1` private-key pointer after failed key setup | not present | InferNode factotum and `p9any` are Limbo and have no `Key.priv`, `Authkey`, manual `memset`, or `p9skclosekey()` lifetime. |
| `3e5b32032a2b949a71ffc01429e747638d4dc628` | software Wi-Fi TKIP/CCMP authentication uses timing-sensitive comparisons | not present in the driver model | InferNode's BCM firmware performs 802.11 encryption and authentication; `ether4330.c` exchanges Ethernet frames and installs keys but contains no host TKIP/CCMP decrypt or MIC/tag comparison path. |
| `1f230d3bbdc643eb0aa5ab90dd74bd01a6949734` | libsec's DES-based X9.17 generator retains old state and key design | ported | `libsec/genrandom.c` now uses a 256-bit ChaCha20 state, rekeys before every response, advances a 96-bit per-call nonce, mixes the process id for fork separation, and scrubs temporary state. The host regression compiles the implementation directly and checks distinct nonzero consecutive outputs. |
| `69c7b7e2c`, `88edd57fe`, `7c2f6c927` | replace kernel timing/LCG output with ChaCha, then rekey and partition calls | already safe through platform RNG architecture | Hosted `#c/notquiterandom` reads the OS CSPRNG and hosted `truerand()` uses it directly. Every shipped native platform supplies `hwrandom()` and `os/port/random.c` copies hardware-generator bytes without the affected LCG output transform. The common libsec expansion is covered by the preceding port. |

## Next tranches

The next pass works backward through network/device permissions and parser
memory safety, then authentication/cryptography and 9P lifecycle fixes. Priority
within each tranche is remote input first, then local capability boundaries,
then denial-of-service and leaks. Candidates are not marked resolved merely
because their subjects look irrelevant; the affected construction must be
absent or the corresponding InferNode path must be inspected.

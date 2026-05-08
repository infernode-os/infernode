# InferNode TODO Inventory

Generated 2026-05-08 by sweeping the tree for `TODO`/`FIXME` comments in source
files and curated docs. Each item below is intended to become one Jira ticket
in the `nervsystems-team` instance (use `scripts/create-jira-todos.sh` to bulk-
create).

Search excluded: `dis/` (compiled bytecode), `MacOSX/` (built tools), the Go
`context.TODO` API mentions in `tools/godis/`, and the literal `XXX` constant
imported from `dat.m` in acme/xenith (it is a Limbo enum value, not a marker).

Conventions:
- **ID**: `TODO-NNN` — used as a stable handle for the create script.
- **Priority**: best-guess; adjust before importing.
- **Component**: suggested Jira component / label.

---

## Crypto / TLS (highest TODO density — ~25 items in `appl/lib/crypt/`)

### TODO-001 — pkcs: implement MD2 in keyring module
- **File**: `appl/lib/crypt/pkcs.b:222`, `:461`
- **Comment**: `# TODO: implement md2 in keyring module`
- **Why**: PKCS digest paths reference MD2 but the keyring module does not
  expose it. Two callsites would benefit from a single keyring addition.
- **Priority**: Low (MD2 is legacy/deprecated; only needed for old certs)
- **Component**: crypto

### TODO-002 — pkcs: add gcd / getRandBetween to Keyring->IPint
- **File**: `appl/lib/crypt/pkcs.b:329`
- **Comment**: `# TODO: add gcd or getRandBetween in Keyring->IPint`
- **Priority**: Medium
- **Component**: crypto

### TODO-003 — ssl3: use V2Handshake.Error for SSLv2 errors
- **File**: `appl/lib/crypt/ssl3.b:1509`
- **Comment**: `# TODO: use V2Handshake.Error for v2`
- **Priority**: Low
- **Component**: crypto

### TODO-004 — ssl3: enforce X.509v3 KeyUsage extension
- **File**: `appl/lib/crypt/ssl3.b:2381`
- **Comment**: `# TODO: to allow checking X509v3 KeyUsage extension`
- **Priority**: Medium (security correctness)
- **Component**: crypto

### TODO-005 — ssl3: accept id == PKCS->id_rsa
- **File**: `appl/lib/crypt/ssl3.b:2407`
- **Comment**: `# TODO: allow id == PKCS->id_rsa`
- **Priority**: Medium
- **Component**: crypto

### TODO-006 — ssl3: factor X.509 cert handling into a separate module
- **File**: `appl/lib/crypt/ssl3.b:2460`
- **Comment**: `# TODO: use another module to do x509 certs, lookup and matching rules`
- **Priority**: Medium (refactor)
- **Component**: crypto

### TODO-007 — ssl3: validate client cert type when CLIENT_AUTH set
- **File**: `appl/lib/crypt/ssl3.b:2820`
- **Comment**: `# TODO: need check type of client cert if(!ctx.status & CLIENT_AUTH)`
- **Priority**: High (security)
- **Component**: crypto

### TODO-008 — ssl3: gate cipher selection on supported_cipher_kinds (two sites)
- **File**: `appl/lib/crypt/ssl3.b:4562`, `:4652`
- **Comment**: `# TODO: should in supported cipher_kinds`
- **Priority**: High (security)
- **Component**: crypto

### TODO-009 — ssl3: decode v2hs.certificate as a list of certificates
- **File**: `appl/lib/crypt/ssl3.b:4689`
- **Comment**: `# TODO: decode v2hs.certificate as list of certificate`
- **Priority**: Medium
- **Component**: crypto

### TODO-010 — ssl3: extend CipherSpec ADT to carry richer key info
- **File**: `appl/lib/crypt/ssl3.b:4720`, `:4808`
- **Comment**: `# TODO: change CipherSpec adt for more key info` /
  `do the following lines after modifying the CipherSpec adt`
- **Priority**: Medium
- **Component**: crypto

### TODO-011 — ssl3: resolve three empty TODO markers
- **File**: `appl/lib/crypt/ssl3.b:4786`, `:4836`, `:4884`
- **Comment**: `# TODO:` (no further detail at any of the three sites)
- **Why**: empty markers — investigate intent (likely related to cipher/key
  setup nearby) and either implement or delete.
- **Priority**: Low
- **Component**: crypto

### TODO-012 — ssl3: validate key block size when IV is present
- **File**: `appl/lib/crypt/ssl3.b:4932`
- **Comment**: `# TODO: check the size of key block if IV exists`
- **Priority**: Medium
- **Component**: crypto

### TODO-013 — ssl3: validate SSL2 challenge / connection_id lengths
- **File**: `appl/lib/crypt/ssl3.b:4942`, `:4943`
- **Comment**: `# TODO: if challenge length != 16 ?` /
  `# TODO: if connection_id length != 16 ?`
- **Priority**: Low
- **Component**: crypto

### TODO-014 — sslsession: evict expired sessions
- **File**: `appl/lib/crypt/sslsession.b:104`
- **Comment**: `# TODO: remove expired session`
- **Priority**: Medium
- **Component**: crypto

### TODO-015 — x509: derive AlgIdentifier from public key + hash
- **File**: `appl/lib/crypt/x509.b:395`
- **Comment**: `# TODO: add AlgIdentifier based on public key and hash`
- **Priority**: Medium
- **Component**: crypto

### TODO-016 — x509: implement signing/verifying tobe_signed hash
- **File**: `appl/lib/crypt/x509.b:398`, `:469`
- **Comment**: `# TODO: hash s.tobe_signed for signing` /
  `# TODO: hash s.tobe_signed for verifying`
- **Priority**: High (cert sign/verify path)
- **Component**: crypto

### TODO-017 — x509: determine ASN.1 object type from OID
- **File**: `appl/lib/crypt/x509.b:1068`
- **Comment**: `# TODO: determine the object type based on oid`
- **Priority**: Medium
- **Component**: crypto

### TODO-018 — x509: convert times to coordinate (UTC) time
- **File**: `appl/lib/crypt/x509.b:1412`
- **Comment**: `# TODO: convert to coordinate time`
- **Priority**: Medium
- **Component**: crypto

### TODO-019 — x509: handle differing string encodings (T61String vs IA5String)
- **File**: `appl/lib/crypt/x509.b:1749`
- **Comment**: `# TODO: need to match different encoding (T61String vs. IA5String)`
- **Priority**: Low
- **Component**: crypto

### TODO-020 — x509: use IPint instead of int when parsing large integers
- **File**: `appl/lib/crypt/x509.b:3491`
- **Comment**: `# TODO: should be IPint`
- **Priority**: Medium
- **Component**: crypto

### TODO-021 — pkcs.m: move AlgIdentifier ADT to ASN1 module
- **File**: `module/pkcs.m:177`
- **Comment**: `# TODO: move this to ASN1`
- **Priority**: Low (refactor)
- **Component**: crypto

### TODO-022 — asn1: recurse and concat results in unhandled SET path
- **File**: `appl/lib/asn1.b:200`
- **Comment**: `# TODO: recurse and concat results`
- **Priority**: Medium
- **Component**: crypto

### TODO-023 — asn1: parse the value internally instead of returning bytes
- **File**: `appl/lib/asn1.b:273`
- **Comment**: `# TODO: parse this internally`
- **Priority**: Low
- **Component**: crypto

---

## Charon (web browser, `appl/charon/`)

### TODO-024 — charon/build: handle other element kinds
- **File**: `appl/charon/build.b:1571`
- **Comment**: `# TODO: other kinds`
- **Priority**: Low
- **Component**: charon

### TODO-025 — charon: choose a different protocol for inter-process control
- **File**: `appl/charon/charon.b:2107`
- **Comment**: `# TODO: should really use a different protocol that ...`
- **Priority**: Low
- **Component**: charon

### TODO-026 — charon/img: un-interlace PNG in place
- **File**: `appl/charon/img.b:723`
- **Comment**: `# (TODO: Could un-interlace in place.`
- **Priority**: Low (memory optimisation)
- **Component**: charon

### TODO-027 — charon/jscript: handle document text from evalscript
- **File**: `appl/charon/jscript.b:1031`
- **Comment**: `# TODO - handle document text from evalscript`
- **Priority**: Medium
- **Component**: charon

### TODO-028 — charon/jscript: harden two unsafe call sites
- **File**: `appl/charon/jscript.b:1234`, `:1547`
- **Comment**: `# TODO: be more defensive` (×2)
- **Priority**: Medium (potential crashes)
- **Component**: charon

### TODO-029 — charon/layout: read font from $font env or config file
- **File**: `appl/charon/layout.b:263`
- **Comment**: `#TODO should read from env $font or config`
- **Priority**: Low
- **Component**: charon

### TODO-030 — charon/layout: skip layout pass when y/height unchanged (two sites)
- **File**: `appl/charon/layout.b:980`, `:1656`
- **Comment**: `# TODO: only do following if y and/or height changed` /
  `# TODO only change if y and/or height changed`
- **Priority**: Low (perf)
- **Component**: charon

---

## Lucifer / Lucipres (presentation environment)

### TODO-031 — lucifer: explicitly destroy old window in Screen.newwindow
- **File**: `appl/cmd/lucifer.b:893`
- **Comment**: `# TODO: Screen.newwindow() returns a fresh window; old window should be explicitly`
  (truncated comment in source)
- **Priority**: Medium
- **Component**: lucifer

### TODO-032 — lucifer: reclaim app slots when an app crashes (watchdog)
- **File**: `appl/cmd/lucifer.b:2257` (related: `:1956`)
- **Comment**: `# TODO: when an app crashes (no orderly exit), its client may linger in appslots`
- **Why**: `docs/LUCIA-EVALUATION.md` flags this same gap and recommends a
  watchdog that periodically checks `client.ctl` and refuses new spawns when
  `nappslots >= MAXAPPSLOTS`.
- **Priority**: High (correctness; resource leak)
- **Component**: lucifer

### TODO-033 — lucipres: refactor presentation rendering into its own wmclient app
- **File**: `appl/cmd/lucipres.b:11` (full design in `docs/TODO-LUCIPRES-ARCHITECTURE.md`)
- **Why**: Presentation rendering is drawn directly into lucipres's image while
  app tabs live in their own wmclient windows, causing z-order races on tab
  switch. Non-trivial refactor: render registry, all renderers, async pipeline,
  scroll/zoom/pan state, PDF nav, agent integration are all coupled.
- **Priority**: Medium (architecture)
- **Component**: lucipres
- **Labels**: refactor, architecture

---

## Mail / acme / xenith

### TODO-034 — Mailpop3: emit Plan 9 mail header so Mail can read; quote "From"
- **File**: `appl/acme/acme/mail/Mailpop3.b:991` (and forked
  `appl/xenith/xenith/mail/Mailpop3.b:991` — fix in both, or unify the forks)
- **Comment**: `# TODO: create the plan9 header so Mail can read it. and quote From`
- **Priority**: Medium
- **Component**: acme

---

## Shell / utilities

### TODO-035 — sh: clarify intentional `* => raise e` and document
- **File**: `appl/cmd/sh/sh.b:957`
- **Comment**: `* => raise e; # TODO the manual says that leaving this out is intentional. Not sure how man pages work without this`
- **Why**: investigate whether the catch-all is required or whether man-page
  rendering depends on its absence; document the conclusion.
- **Priority**: Low
- **Component**: sh

### TODO-036 — wikifs: rewrite wlink wiki-link parser ("this is all wrong")
- **File**: `appl/cmd/wikifs/wiki.b:439`
- **Why**: comment flags the entire `[link]` parsing block in `wlink()` as
  broken. Likely mishandles nested or malformed brackets.
- **Priority**: Medium
- **Component**: wikifs

### TODO-037 — dict/pgw: add foreign-consonant transcriptions (Š, ʃ, nasals)
- **File**: `appl/cmd/dict/pgw.b:1050`
- **Comment**: `#  TODO: find transcriptions of foreign consonents, S, , nasals`
- **Priority**: Low
- **Component**: dict

---

## HTTP service

### TODO-038 — httpd: implement compile-hint generation (currently skipped)
- **File**: `appl/svc/httpd/httpd.b:621`
- **Comment**: `; # TODO Skip doing hints for now`
- **Priority**: Low
- **Component**: httpd

---

## Build / tooling

### TODO-039 — Rebuild hosted limbo (`dis/limbo.dis`) for ARM64 correctness
- **File**: `build-macos-sdl3.sh:5-17` ("CRITICAL TODO" block)
- **Why**: emu-hosted Limbo compiler emits invalid bytecode (BADOP at runtime)
  on ARM64. Build script tells users to use the native compiler as a
  workaround. Real fix is to repair the hosted compiler.
- **Priority**: High
- **Component**: build, limbo

### TODO-040 — emu/Nt/devfs: try `/` in place of `\` in path names
- **File**: `emu/Nt/devfs.c:12`
- **Comment**: `/* TODO: try using / in place of \ in path names */`
- **Priority**: Low (Windows host only)
- **Component**: emu

### TODO-041 — libtk/grids: investigate "XXX TODO" placeholder
- **File**: `libtk/grids.c:6`
- **Comment**: `* XXX TODO`
- **Priority**: Low
- **Component**: tk

---

## Tests

### TODO-042 — fix bufio_test.SopenGett (gett returns fields with delimiter attached)
- **File**: `tests/bufio_test.b:10`
- **Comment**: `# TODO: SopenGett fails — gett returns fields with delimiter still attached`
- **Priority**: Medium (test currently disabled or failing)
- **Component**: tests, bufio

### TODO-043 — fix cowfs_test (file2chan server does not shut down → runner hangs)
- **File**: `tests/cowfs_test.b:12`
- **Comment**: `# TODO: This test hangs the runner — the cowfs file2chan server does not shut`
- **Priority**: Medium
- **Component**: tests, cowfs

---

## Formal-verification race conditions (`formal-verification/TODO-RACE-CONDITIONS.md`)

All three are real bugs at the C/emu host threading level, masked in practice
by Inferno's cooperative Dis VM scheduling but genuine hazards in the multi-
threaded emu host.

### TODO-044 — kchdir: use-after-free on `pg->dot` swap
- **File**: `emu/port/sysfile.c:142-157`
- **Severity**: High (use-after-free)
- **Fix sketch**: hold `pg->ns` write lock across `cclose(pg->dot)` and
  `pg->dot = c`.
- **Priority**: High
- **Component**: emu, concurrency
- **Labels**: race, formal-verification

### TODO-045 — Sys_pctl FORKNS: pgrp pointer swap without lock
- **File**: `emu/port/inferno.c:869-876`
- **Severity**: Medium (stale pointer)
- **Fix sketch**: lock or atomic CAS around the pgrp pointer swap; or refcount
  the pgrp pointer so `closepgrp` defers until readers release.
- **Priority**: Medium
- **Component**: emu, concurrency
- **Labels**: race, formal-verification

### TODO-046 — namec: unsynchronised reads of `pg->slash` / `pg->dot`
- **File**: `emu/port/chan.c:1020-1058`
- **Severity**: Medium (stale read)
- **Fix sketch**: read-lock `pg->ns` around the read+incref, or use atomic
  pointer ops.
- **Priority**: Medium
- **Component**: emu, concurrency
- **Labels**: race, formal-verification

---

## Xenith roadmap items (`appl/xenith/IDEAS.md`)

These are scoped feature ideas, not stray comments — each merits its own epic
or large ticket.

### TODO-047 — Xenith: agent hooks (pre/post/error filesystem hooks)
- **File**: `appl/xenith/IDEAS.md:331`
- **Why**: expose `/lib/agent/hooks/{pre_command,post_command,on_error}` so
  users can audit, log, rate-limit, auto-commit, or validate agent actions.
- **Priority**: Medium
- **Component**: xenith, veltro
- **Labels**: feature

### TODO-048 — Xenith: progressive PNG loading verification test
- **File**: `appl/xenith/IDEAS.md:387`
- **Why**: progressive decode infrastructure exists but is imperceptible on
  fast storage; need a verification test with artificial 500ms delays in
  `loadpngsubsampleprogressive()` and a >16MP gradient PNG.
- **Priority**: Medium
- **Component**: xenith
- **Labels**: test

### TODO-049 — Implement ARM64 JIT compiler for Dis VM
- **File**: `appl/xenith/IDEAS.md:447` (also `libinterp/comp-arm64.c`,
  `libinterp/comp-amd64.c` — both are stubs)
- **Why**: estimated 10-100× speedup for CPU-bound Limbo. ~35-40 KB of C.
  ARM 32-bit JIT (`comp-arm.c`) is the closest reference.
- **Priority**: High
- **Component**: libinterp, jit
- **Labels**: performance, epic

---

## Summary

49 tickets total. Suggested rough phasing for next session:

1. **Security/correctness first**: TODO-007, TODO-008, TODO-016, TODO-032,
   TODO-044 (high-priority crypto + race + lucifer).
2. **Build/perf next**: TODO-039 (hosted limbo ARM64), TODO-049 (ARM64 JIT).
3. **Test debt**: TODO-042, TODO-043 — quick wins, unblock CI.
4. **Crypto cleanup pass**: remaining TODO-001..TODO-023 in one focused sweep
   on `appl/lib/crypt/`.
5. **Lucipres refactor (TODO-033)**: separate epic — non-trivial, schedule
   alone.

Run `scripts/create-jira-todos.sh` from a workstation with Jira access to
import; see header of that script for env-var setup.

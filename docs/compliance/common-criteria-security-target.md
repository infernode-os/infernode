# InferNode — Common Criteria Security Target (self-produced)

**Document type:** Security Target (ST), structured per Common Criteria for Information
Technology Security Evaluation (ISO/IEC 15408) / CEM (ISO/IEC 18045), ASE class layout.
**TOE:** InferNode secure operating system — the Dis virtual machine and the per-process
namespace kernel.
**ST version:** 0.1 (baseline draft).
**Date:** 2026-07-09.
**Author:** InferNode project (self-assessment).

---

## 0. Status, scope, and honesty statement (read first)

> **This is a self-produced Security Target, not an accredited evaluation.**
> No Common Criteria certificate exists or is claimed. InferNode has **not** been evaluated
> by an accredited CC testing laboratory under any NIAP/CCRA scheme, has **no** EAL rating,
> and has **no** validated Protection Profile conformance. The cryptographic module is **not**
> FIPS 140-2/140-3 CMVP validated and its algorithm implementations are **not** CAVP
> validated. There is **no** Authorization to Operate (ATO).
>
> The purpose of this ST is to (a) state the security problem InferNode is designed to
> solve in CC vocabulary, (b) enumerate the Security Functional Requirements (SFRs) that the
> TOE's primitives implement, each with a concrete in-repository evidence pointer, and
> (c) present the **assurance argument** — why a deliberately small, formally-analysed TCB is
> unusually favourable for a future high-assurance evaluation. Every "the TOE provides…"
> claim below cites a source file, test, or formal-verification artifact. Claims that depend
> on how an integrator deploys or configures the TOE are marked **configurable / operational
> environment**. Claims that could not be confirmed from the repository are marked **needs
> confirmation**. Nothing here is a substitute for independent evaluation.

This ST complements, and does not supersede, the readiness/gap analysis in
[`../../doc/compliance/Common-Criteria-readiness.md`](../../doc/compliance/Common-Criteria-readiness.md).
That document scopes the *evaluation effort*; this document is the *ST artifact* that effort
would begin from.

---

## 1. ST Introduction (ASE_INT)

### 1.1 ST and TOE reference

| Field | Value |
|-------|-------|
| ST title | InferNode — Common Criteria Security Target (self-produced) |
| ST version / date | 0.1 / 2026-07-09 |
| TOE name | InferNode |
| TOE version | Corresponds to the current `master` build (see `git describe`; release badges in `README.md`) |
| TOE type | General-purpose secure operating system with per-process namespace isolation and a type-/memory-safe managed execution environment |
| CC version | Common Criteria v3.1 Rev 5 (ISO/IEC 15408:2022), Parts 1–3 |

### 1.2 TOE overview

InferNode is a 64-bit distribution of the Inferno® operating system: a Plan 9-lineage,
distributed OS in which **every resource — files, devices, network endpoints, processes,
cryptographic services — is named and accessed as a file** through the Styx/9P protocol, and
in which **each process holds its own private namespace** (its own view of the file
hierarchy). Application code executes as **Dis bytecode** inside a type-safe, memory-safe
virtual machine (the Limbo/Dis VM). The entire system — kernel, VM, crypto, and a full
userland — runs in **under 30 MB of RAM** (`README.md`).

The security-relevant consequence of this architecture is a **small, well-defined Trusted
Computing Base (TCB)**: security rests on two mechanisms — the per-process **namespace**
(the access-control and isolation mechanism) and the **Dis VM** (safe execution) — with
everything else composed as file services on top. Access control and audit are mediated at a
single architectural chokepoint (the Styx/9P name-resolution and mount machinery), which
gives the system a **reference-monitor** shape.

### 1.3 TOE description

**Physical/logical boundary.** The TOE is the security-enforcing core:

| In the TOE (TSF) | Source of record |
|------------------|------------------|
| Per-process namespace / process-group (`Pgrp`) machinery | `emu/port/pgrp.c`, `emu/port/chan.c`, `emu/port/sysfile.c`, `emu/port/inferno.c` |
| Styx/9P name resolution, mount table, and export boundary (reference-validation path) | `emu/port/chan.c` (`namec`, `cmount`, `walk`, `findmount`), `emu/port/exportfs.c` |
| Dis virtual machine (bytecode loader, type/bounds checker, interpreter/JIT) | `libinterp/` |
| Cryptographic services library | `libsec/`, exposed to Limbo via `libinterp/keyring.c` ↔ `module/keyring.m` |
| Credential/key agent | `appl/cmd/auth/factotum/`, `appl/lib/factotum.b`, `module/factotum.m` |
| Tamper-evident audit service | `appl/cmd/auditfs.b`, `appl/lib/auditchain.b`, `appl/lib/audit.b` |

**Outside the TOE / operational environment:** the host operating system under the hosted
`emu` port, host hardware, the host C compiler and threading primitives, physical security,
personnel, and organizational policy. Application-layer file services composed above the
namespace are TOE-*using* software, not part of the security-enforcing core, except where
they implement a TSF (e.g. `factotum`, `auditfs`).

**Two hosting modes.** InferNode runs *hosted* (the `emu` emulator on macOS/Linux/Windows;
the primary build and the target of the formal-verification evidence) and can run *native*.
This ST describes the hosted TOE; the namespace/Dis TSF is common to both. The three
use-after-free race findings in §7.2 of `formal-verification/METHODOLOGY.md` are specific to
the multi-threaded host layer of the `emu` port and are documented, not hidden — see §8.4.

---

## 2. Conformance claims (ASE_CCL)

| Claim | Statement |
|-------|-----------|
| CC conformance | CC v3.1 Rev 5, **Part 2 conformant** *(SFRs drawn from Part 2 catalogue; self-assessed, not evaluated)* and **Part 3** used for the assurance-argument vocabulary only. |
| PP conformance | **None claimed.** The architecture is a candidate for a *Separation Kernel Protection Profile* (SKPP lineage) or a general-purpose OS PP; no PP is formally instantiated. See [`../../doc/compliance/Common-Criteria-readiness.md`](../../doc/compliance/Common-Criteria-readiness.md) §2. |
| Package / EAL | **None claimed.** This ST does not assert an EAL. §8 argues why the architecture is favourable for EAL5+ *design* evidence, but no assurance package is met or evaluated. |

Rationale for no PP claim: instantiating the SKPP requires a formally defined TOE boundary
and an information-flow security-policy model (ADV_SPM) that are not yet authored. The core
isolation property such a model would rest on is, however, already machine-checked (§8).

---

## 3. Security problem definition (ASE_SPD)

### 3.1 Threats

| ID | Threat | Countered by (SFR / objective) |
|----|--------|--------------------------------|
| **T.UNAUTH_ACCESS** | A subject accesses a resource for which it holds no authorization. | O.MEDIATION, O.LEAST_PRIV — FDP_ACC/FDP_ACF, FDP_IFC/FDP_IFF |
| **T.CROSS_DOMAIN_LEAK** | Data or a resource handle mounted in one namespace leaks into another that did not receive it. | O.ISOLATION — FDP_IFF.1, FDP_ACF.1 (namespace isolation, **formally verified**) |
| **T.MEMORY_CORRUPTION** | Malformed or malicious application code corrupts memory (overflow, use-after-free, type confusion) to escape its domain. | O.SAFE_EXEC — FPT_TDC.1, FDP_RIP; Dis VM type/memory safety |
| **T.SPOOF_IDENTITY** | An attacker impersonates a user, node, or service. | O.AUTHN — FIA_UID, FIA_UAU, FTP_ITC |
| **T.MITM / T.EAVESDROP** | An attacker on the network reads or tampers with data in transit, incl. *harvest-now-decrypt-later*. | O.SECURE_CHANNEL — FCS_COP.1, FTP_ITC.1 (hybrid PQC) |
| **T.AUDIT_TAMPER** | An attacker edits, reorders, or deletes audit records to hide activity. | O.ACCOUNTABILITY — FAU_GEN, FAU_STG, FAU_STG.2 (hash chain) |
| **T.SUPPLY_CHAIN** | A tampered build or artifact is delivered to the operator. | O.INTEGRITY_DIST — supply-chain controls (§8.3; also NIST SR family) |
| **T.WEAK_CRYPTO** | Cryptographic operations leak secrets via timing side channels or use non-approved primitives. | O.SECURE_CHANNEL — constant-time implementations (CBMC-checked), approved algorithms |

### 3.2 Organizational security policies (OSPs)

| ID | Policy |
|----|--------|
| **P.LEAST_PRIVILEGE** | A subject shall receive no more of the resource namespace than it needs; children shall not exceed their parent's authority. |
| **P.APPROVED_CRYPTO** | Cryptographic protection shall use approved algorithms (AES-256, SHA-384/512, FIPS 203/204/205 PQC). *(Validated-module status is a separate, unmet requirement — see FCS notes.)* |
| **P.ACCOUNTABILITY** | Security-relevant events shall be recorded in a tamper-evident trail attributable to an identity. |

### 3.3 Assumptions (operational environment)

| ID | Assumption |
|----|------------|
| **A.HOST** | In hosted mode, the underlying host OS, hardware, memory allocator, and threading primitives operate correctly (this is the TCB the formal verification explicitly trusts — `formal-verification/README.md` §"Trusted Computing Base"). |
| **A.PHYSICAL** | The platform is afforded physical protection appropriate to its data; hardware authenticators (FIDO2) are under the legitimate user's control. |
| **A.ADMIN** | Administrators are trusted, trained, and configure the TOE per its guidance (e.g. enabling CNSA-strict mode, binding the audit service, exporting only intended subtrees). |
| **A.TOOLCHAIN** | The build toolchain (Inferno-native `mk`/`limbo`, host C compiler) and the verification tools (TLC, SPIN, CBMC) are trustworthy. |

---

## 4. Security objectives (ASE_OBJ)

### 4.1 Objectives for the TOE

| ID | Objective | Realised by |
|----|-----------|-------------|
| **O.MEDIATION** | Every access to a named resource is mediated by the namespace/Styx path; an unbound name is inexpressible. | FDP_ACC.2, FDP_ACF.1 |
| **O.ISOLATION** | Per-process namespaces are isolated: post-fork mutations in one do not affect another. | FDP_IFC.1, FDP_IFF.1 — **formally verified** |
| **O.LEAST_PRIV** | Authority is attenuating: a child namespace ⊆ its parent; device access is gate-able (`NODEVS`). | FDP_ACF.1, FMT_MSA.3 |
| **O.SAFE_EXEC** | Application code executes in a type-safe, memory-safe VM that rejects ill-typed/stale modules at load. | FPT_TDC.1, FDP_RIP.1 |
| **O.AUTHN** | Users, nodes, and services are identified and authenticated before access; MFA is available at AAL3. | FIA_UID.2, FIA_UAU.2, FIA_UAU.5, FTP_ITC.1 |
| **O.SECURE_CHANNEL** | Data in transit is protected by approved, constant-time crypto with a hybrid post-quantum option. | FCS_CKM.1/.4, FCS_COP.1, FTP_ITC.1 |
| **O.ACCOUNTABILITY** | Security events are recorded in a tamper-evident, attributable trail. | FAU_GEN.1/.2, FAU_STG.1, FAU_STG.2 |

### 4.2 Objectives for the operational environment

| ID | Objective |
|----|-----------|
| **OE.HOST** | The environment provides a correct host OS/hardware/allocator/threading base (A.HOST). |
| **OE.PHYSICAL** | The environment provides physical protection and safeguards hardware authenticators (A.PHYSICAL). |
| **OE.ADMIN** | Administrators deploy and configure the TOE per guidance — enable CNSA mode where required, bind `auditfs`, restrict exports, manage authenticator lifecycle (A.ADMIN). |
| **OE.TOOLCHAIN** | Build and verification toolchains are trustworthy (A.TOOLCHAIN). |

---

## 5. Extended components definition (ASE_ECD)

No extended (non-Part-2) SFR components are defined. All SFRs below are drawn from the CC
Part 2 catalogue. The domain-separation property historically expressed as **FPT_SEP.1**
(U.S. Government SKPP / CC v2 lineage) is retained in §6 as an informative label because it
most directly names InferNode's namespace-separation property; under CC v3.1 this property is
argued through **ADV_ARC** (architecture) together with the FDP flow-control SFRs, and is so
treated in §8.

---

## 6. Security Functional Requirements (ASE_REQ)

Each SFR names the InferNode mechanism that implements it and a concrete evidence pointer.
"**By construction**" means the property is structural (there is no code path that could
violate it), not a runtime check that could be bypassed or misconfigured.

### 6.1 Class FDP — User Data Protection

| SFR | Element (paraphrased) | InferNode realisation | Evidence | Basis |
|-----|-----------------------|------------------------|----------|-------|
| **FDP_ACC.2** Complete access control | The namespace SFP covers all subjects (processes) and objects (named resources); all operations are mediated. | Every resource is a file reached only by walking the process's mount table via `namec()`; a name not bound into the namespace cannot be expressed. Single mediation path. | `emu/port/chan.c` (`namec`, `walk`, `findmount`); `../../doc/compliance/SP800-207-zero-trust.md` | By construction |
| **FDP_ACF.1** Security-attribute-based access control | Access decided by the subject's namespace bindings and per-mount flags; default-deny. | Mount table + bind/mount flags (`MREPL`/`MBEFORE`/`MCREATE`); `NODEVS` restricts the device namespace. | `emu/port/chan.c` (`cmount`); `Pgrp.nodevs` in `emu/port/pgrp.c` | By construction |
| **FDP_IFC.1** Subset information-flow control | Flows between namespaces are controlled: a mount in one process's namespace is not visible to another unless independently bound. | `pgrpcpy()` deep-copies the mount table; post-copy mutations are independent. | `emu/port/pgrp.c:74` (`pgrpcpy`) | **Formally verified** (§8.1) |
| **FDP_IFF.1** Simple security attributes (isolation) | The Namespace Isolation Theorem: a channel appearing at a path in both parent and child was either present at copy time or independently bound by both. | Namespace Isolation Theorem, proved via history variables. | `formal-verification/tla+/IsolationProof.tla`; `formal-verification/spin/namespace_isolation.pml`; `formal-verification/cbmc/harness_pgrpcpy.c` | **Formally verified** (TLA+/SPIN/CBMC) |
| **FDP_RIP.1** Residual information protection | Freed key material and buffers are not exposed to later subjects. | `libsec/securezero.c` zeroization of key material; Dis VM garbage-collected, bounds-checked memory (no manual reuse of freed application memory). | `libsec/securezero.c`; `libinterp/` | Configurable + by construction |
| **FDP_ETC/ITC (export boundary)** | Exported subtrees cannot be escaped via `walk("..")` above the export root. | `exportfs` root-boundary check. | `emu/port/exportfs.c:888` (`exisroot`); `formal-verification/spin/exportfs_boundary.pml` | **Formally verified** (SPIN) |

### 6.2 Class FIA — Identification and Authentication

| SFR | Element (paraphrased) | InferNode realisation | Evidence | Basis |
|-----|-----------------------|------------------------|----------|-------|
| **FIA_UID.2** User identification before any action | Subjects are identified before namespace access to protected services. | Factotum credential agent establishes caller/server identity (`Authinfo.cuid`/`suid`). | `module/factotum.m`; `appl/cmd/auth/factotum/` | Configurable |
| **FIA_UAU.2** User authentication before any action | Authentication precedes access to protected services/nodes. | Factotum auth protocols; native STS mutual authentication between nodes. | `module/factotum.m`; `../../doc/compliance/SP800-63B-AAL3.md` | Configurable |
| **FIA_UAU.5** Multiple authentication mechanisms | Password/EKE, challenge-response, PKI/X.509, and hardware FIDO2. | Factotum protocol set; FIDO2 user-verification gating secstore unlock (AAL3). | `../../doc/compliance/SP800-63B-AAL3.md`; `../../doc/compliance/FIDO2-CTAP2.md` | Configurable (AAL3 verifier shipped) |
| **FIA_UAU.6** Re-authenticating | Replay-resistant re-authentication. | Challenge-response (`hmac-secret`); STS handshake with transcript binding. | `../../doc/compliance/SP800-63B-AAL3.md` §"replay"; `tests/pqauth_test.b` | Configurable |
| **FIA_UAU.1(PKI)** / cert validation | Certificate path validation incl. revocation. | X.509 path validation + CRL; PQ-capable certificates. | `appl/lib/crypt/x509.b`; `../../doc/compliance/X509-mTLS.md` | Configurable |
| **FIA_AFL.1** Authentication failure handling | Bound failed-attempt exposure of secrets. | secstore factor gating / never-brick enroll; DK-wrapped slots. | `../../doc/compliance/SP800-63B-AAL3.md` §4 | **Needs confirmation** of lockout thresholds (deployment) |

### 6.3 Class FMT — Security Management

| SFR | Element (paraphrased) | InferNode realisation | Evidence | Basis |
|-----|-----------------------|------------------------|----------|-------|
| **FMT_MSA.1** Management of security attributes | The namespace (the security attribute set) is managed via `bind`/`mount`/`unmount` and `pctl`. | `Sys->pctl` (FORKNS/NEWNS/NODEVS), `bind`/`mount` syscalls. | `emu/port/inferno.c` (`Sys_pctl`); `emu/port/chan.c` | By construction |
| **FMT_MSA.3** Static attribute initialisation | Restrictive default: a fresh namespace (`NEWNS`) is empty; child cannot exceed parent. | `Sys_pctl(NEWNS)` yields empty mount table; `FORKNS` copies (never widens). | `emu/port/inferno.c:855,869`; `formal-verification/` (attenuation) | By construction (default-deny) |
| **FMT_SMF.1** Management functions | Bind/mount/unmount, device gating, credential add/delete, audit binding. | Namespace syscalls; `factotum` key add/del; `auditfs` mount. | `emu/port/`; `appl/cmd/auth/factotum/`; `appl/cmd/auditfs.b` | Configurable |
| **FMT_SMR.1** Security roles | Distinct credential identities per subject; role separation via distinct namespaces/factotum identities. | Per-agent capability sets and factotum identities. | `../../doc/compliance/SP800-53-controls.md` (AC-5) | Configurable |

### 6.4 Class FAU — Security Audit

| SFR | Element (paraphrased) | InferNode realisation | Evidence | Basis |
|-----|-----------------------|------------------------|----------|-------|
| **FAU_GEN.1** Audit data generation | Generate records for defined security events. | `auditfs` service + emitters (secstore auth, 2fa enroll/disable, factotum keyadd/keydel). Record format `seq time source event hash msg`. | `appl/cmd/auditfs.b` (`appendrec`); `../../doc/compliance/SP800-92-audit-log.md` | Configurable (bind the service) |
| **FAU_GEN.2** User-identity association | Records bound to an identity/source. | `source` field + credential-path emitters. | `appl/lib/audit.b`; `../../doc/compliance/SP800-53-controls.md` (AU-3) | Configurable |
| **FAU_STG.1** Protected audit-trail storage | Stored records protected from unauthorized modification. | Namespace access control over `/mnt/audit`; append-only 9P service. | `appl/cmd/auditfs.b`; `../../doc/compliance/SP800-92-audit-log.md` | Configurable |
| **FAU_STG.2** Guarantees of audit-data availability / integrity | Tampering (edit/reorder/delete) is detectable. | SHA-256 hash chain: `H[n]=SHA-256(H[n-1] ‖ record)`; signed checkpoints; offline verifier. | `appl/lib/auditchain.b`; `appl/cmd/auditverify.b`; `tests/auditchain_test.b` | **By construction** (cryptographic) |
| **FAU_SAR.1** Audit review | Records are reviewable/verifiable offline without a secret. | `auditverify -k pubkey` verifies the chain and checkpoint signatures offline. | `appl/cmd/auditverify.b` | Configurable |

*Honest scope:* AU generation covers the auth/identity/credential chokepoints today; broader
coverage (e.g. every privileged op) and AU-4/5/6/7 operational tooling remain open
(`../../doc/compliance/SP800-92-audit-log.md`; INFR-343/355/356). An **unsigned-tail** window
before checkpoint and factotum-held signing-key hardening are tracked, not solved (INFR-356).

### 6.5 Class FCS — Cryptographic Support

| SFR | Element (paraphrased) | InferNode realisation | Evidence | Basis |
|-----|-----------------------|------------------------|----------|-------|
| **FCS_CKM.1** Key generation | Generate keys for approved algorithms. | ML-KEM-768/1024 (FIPS 203), ML-DSA-65/87 (FIPS 204), SLH-DSA-SHAKE-192s/256s (FIPS 205), plus classical (AES/ECDH/ed25519). | `libsec/mlkem.c`, `libsec/mldsa.c`, `libsec/slhdsa.c`; `../../doc/compliance/CNSA-2.0.md` | Approved algorithms; **module not CMVP/CAVP validated** |
| **FCS_CKM.2** Key establishment | Establish shared keys. | **Hybrid** X25519+ML-KEM-768 (TLS 1.3) and DH+ML-KEM (native STS), combined via SHA3-512; CNSA-strict offers SecP384r1MLKEM1024. | `appl/lib/crypt/tls.b` (`GROUP_SECP384R1MLKEM1024 = 0x11ED`); `../../doc/compliance/CNSA-2.0.md` §3.3, §4 | Configurable (default classical; CNSA mode) |
| **FCS_CKM.4** Key destruction | Zeroize key material after use. | `securezero`. | `libsec/securezero.c` | By construction (call-sites: needs coverage confirmation) |
| **FCS_COP.1(SYM)** Symmetric operation | AEAD symmetric encryption. | AES-256-GCM; ChaCha20-Poly1305. | `libsec/aesgcm.c`, `libsec/ccpoly.c` | Approved algorithms |
| **FCS_COP.1(HASH)** Hashing | SHA-2 / SHA-3. | SHA-384/512 (`sha2.c`); SHA-3/SHAKE (`sha3.c`) — **NIST FIPS 202 known-answer vectors present**. | `libsec/sha2.c`; `libsec/sha3.c`; `tests/sha3_test.b` (22 KAT digests) | **KAT-tested (SHA-3)** |
| **FCS_COP.1(KEM)** Key encapsulation | ML-KEM encaps/decaps, constant-time. | FO-transform implicit rejection via `ct_memcmp`/`ct_cmov` (branch-free). | `libsec/mlkem.c`; `formal-verification/cbmc/harness_mlkem_ct.c` | **Constant-time CBMC-checked**; ACVP pending |
| **FCS_COP.1(SIG)** Digital signature | ML-DSA / SLH-DSA sign/verify. | Lattice (ML-DSA) + hash-based (SLH-DSA) backup; NTT reductions CBMC-checked for correctness + no-overflow. | `libsec/mldsa.c`, `libsec/slhdsa.c`; `formal-verification/cbmc/harness_mldsa_ct.c` | **CBMC-checked**; ACVP pending |

> **FCS honesty note.** The PQC is a **from-scratch, self-implemented** library and has **not
> been independently audited** and is **not** CAVP/CMVP validated. Evidence offered is: (i)
> constant-time and arithmetic-correctness **CBMC harnesses** (`harness_mlkem_ct.c`,
> `harness_mldsa_ct.c`) proving no data-dependent branches in the FO-transform selection and
> congruence/no-overflow of Barrett/Montgomery reductions; (ii) **NIST FIPS 202 known-answer
> vectors** for SHA-3 (`tests/sha3_test.b`); and (iii) functional round-trip, negative,
> tamper, downgrade, and stress tests for ML-KEM/ML-DSA/SLH-DSA (`tests/mlkem_test.b`,
> `tests/mldsa_test.b`, `tests/slhdsa_test.b`, `tests/pqauth_test.b`, `tests/*_stress_test.b`,
> `tests/pqc_fuzz_test.b`). **Formal ACVP/CAVP known-answer validation of the lattice/hash-DSA
> schemes is pending external cryptographic audit** and is *not* claimed. FIPS-140 module
> validation is out of scope here (see `../../doc/compliance/FIPS-140-3-readiness.md`).

### 6.6 Class FPT — Protection of the TSF

| SFR | Element (paraphrased) | InferNode realisation | Evidence | Basis |
|-----|-----------------------|------------------------|----------|-------|
| **FPT_TDC.1 / TSF self-protection via type safety** | The TSF and application domains are protected from ill-typed data/code. | Dis VM: no raw pointers, bounds-checked arrays, modules **type-checked at load** (`link typecheck` rejection of stale/mismatched bytecode). | `libinterp/`; `CLAUDE.md` ("stale bytecode problem"); `../../doc/compliance/SP800-53-171-mapping.md` §5.SI | By construction |
| **FPT_SEP.1 (informative; SKPP lineage)** Domain separation | The TSF maintains a separate security domain per subject. | Per-process namespace + Dis VM per-process memory isolation. Argued under CC v3.1 via ADV_ARC + FDP_IFF.1. | `formal-verification/` (isolation); `emu/port/pgrp.c` | **Formally verified** (isolation core) |
| **FPT_FLS.1** Fail secure | On loss of the audit service, callers may fail-closed. | `Audit->log()` returns −1 if the service is unbound; caller chooses fail-closed for high-value events. | `appl/lib/audit.b` (header) | Configurable |
| **FPT_TST (TSF testing)** | The TSF's key properties are tested. | Formal-verification suite runs in CI on every push. | `.github/workflows/formal-verification.yml` | By construction (CI) |

### 6.7 Class FTP — Trusted Path/Channels

| SFR | Element (paraphrased) | InferNode realisation | Evidence | Basis |
|-----|-----------------------|------------------------|----------|-------|
| **FTP_ITC.1** Inter-TSF trusted channel | Assured-identity, tamper-evident channel between nodes. | Native 9P/Styx STS handshake (mutual auth, line encryption, transcript binding) and TLS 1.2/1.3; hybrid-PQC key exchange. | `../../doc/compliance/CNSA-2.0.md` §3–4; `tests/pqauth_test.b` (*TamperedEkRejected*, *DowngradeRejected*) | Configurable |
| **FTP_TRP.1** Trusted path | Path for user authentication. | FIDO2 hardware-key user-verification path to secstore unlock. | `../../doc/compliance/SP800-63B-AAL3.md`; `../../doc/compliance/FIDO2-CTAP2.md` | Configurable (AAL3) |

---

## 7. Security assurance requirements (ASE_REQ / Part 3 vocabulary)

No EAL is claimed. This section maps the *existing, in-repository* assurance evidence to the
CC Part 3 assurance classes so an evaluator can see what is already in hand versus what a real
evaluation would still require. It restates, in ST form, the gap table of
[`../../doc/compliance/Common-Criteria-readiness.md`](../../doc/compliance/Common-Criteria-readiness.md) §3.

| Assurance class | What CC asks for | InferNode evidence today | Gap for a real evaluation |
|-----------------|------------------|--------------------------|---------------------------|
| **ADV** Development | Functional spec, TOE design, and (EAL5+) a formal/semiformal security-policy model + correspondence | The load-bearing property (namespace isolation) has a **formal model and machine-checked proof** across three tools; CBMC verifies actual C. `formal-verification/METHODOLOGY.md` | Full ADV_FSP / ADV_TDS / ADV_SPM / ADV_ARC documents to author; correspondence to the *whole* TSF |
| **AGD** Guidance | Operational + preparative guidance | `QUICKSTART.md`, `docs/`, ops runbooks | Restructure to CC AGD_OPE/AGD_PRE form |
| **ALC** Life-cycle | CM, flaw remediation, delivery, dev security | Reproducible Inferno-`mk` builds, SLSA-3 provenance + Sigstore signing, SBOM, `verify-dis-paths`, pinned CI actions, ring-fence guard | CC-form ALC_CMC/CMS/DEL/DVS/FLR documentation |
| **ATE** Tests | Functional coverage + depth | In-emu regression suite incl. `tests/veltro_security_test.b`, crypto tests, formal-verification CI | Coverage-to-SFR mapping (ATE_COV/DPT); independent ATE_IND |
| **AVA** Vulnerability | Independent vuln assessment | CodeQL (`security.yml`), fuzzing (`fuzz.yml`), formal verification feed it | Accredited-lab AVA_VAN penetration test |
| **ASE** Security Target | A complete ST | **This document** (self-produced baseline) | Evaluator review; PP instantiation |

---

## 8. TOE summary specification & assurance argument (ASE_TSS)

### 8.1 The load-bearing claim is formally verified

The single most important security property — **namespace isolation** (FDP_IFF.1 /
O.ISOLATION) — is not merely asserted, it is **machine-checked at three abstraction levels**
(`formal-verification/METHODOLOGY.md`, `formal-verification/README.md`):

- **TLA+/TLC** — the *Namespace Isolation Theorem* (`IsolationProof.tla`): for any
  parent/child pair created by `pgrpcpy`, a channel present at a path in both was either in
  the copy snapshot or independently bound by both. Eleven safety invariants checked
  exhaustively over **19.3 M distinct states** (369 M generated) in the small configuration
  with **zero violations**; a partial medium run explored 200 M+ states with no violation.
- **SPIN** — five Promela models (isolation, nested fork, lock ordering, races, export
  boundary); the isolation and lock-ordering properties pass, and the export-boundary model
  confirms `walk("..")` cannot escape the exported root (FDP export boundary).
- **CBMC** — bounded model checking of the **actual C** `pgrpcpy()` and refcount/bounds
  code (`harness_pgrpcpy.c`, `harness_pgrpcpy_error.c`, `harness_mnthash_bounds.c`,
  `harness_refcount.c`), verifying deep-copy independence at the production `MNTHASH=32`.

The C-function ↔ model correspondence is tabulated in `formal-verification/README.md`
("Correspondence to C Code"), pinning each modelled operation to a source line (e.g.
`pgrpcpy()` → `emu/port/pgrp.c:74`). This is exactly the ADV_SPM-class evidence that CC EAL5+
demands and that large monolithic kernels cannot produce.

### 8.2 A small TCB is what makes the above possible

Security rests on two mechanisms — the namespace and the Dis VM — inside a <30 MB system.
The mediation of *all* resource access through one Styx/9P name-resolution path
(`emu/port/chan.c`) gives the TSF a reference-monitor shape: **always invoked** (an unbound
name is inexpressible), **tamper-resistant** (the application layer is type-/memory-safe Dis
bytecode with no raw pointers), and **small enough to analyse** (the verified namespace
subsystem is ~3,831 lines of C — `formal-verification/METHODOLOGY.md` §1.3). This is the AC-25
reference-monitor property claimed in `../../doc/compliance/SP800-53-controls.md`.

### 8.3 Cryptographic and supply-chain assurance (with limits)

- **Crypto correctness/side-channel evidence** is the CBMC constant-time harnesses (§6.5) plus
  SHA-3 NIST KATs — strong for *what it covers*, but **not** a substitute for CAVP/CMVP or an
  independent cryptographic audit, which remain **pending** and unclaimed.
- **Distribution integrity** (O.INTEGRITY_DIST): every release artifact carries SHA-256
  checksums, **Sigstore cosign keyless signatures** (`.sigstore` bundles), and **SLSA build
  provenance attestations** (`actions/attest-build-provenance`), with an SPDX SBOM; the
  repository publishes an **OpenSSF Scorecard** and **OpenSSF Best Practices** badge
  (`.github/workflows/release.yml`, `scorecard.yml`, `README.md`). CI actions are pinned to
  commit SHAs. These substantiate the ALC/SR posture; the SLSA-3 claim is evidenced by the
  provenance attestations in `release.yml`.

### 8.4 Honest residuals (do not overlook)

- **Three use-after-free race conditions** in the `emu` host-threading layer (`kchdir` dot
  race `sysfile.c:153-154`; FORKNS pgrp swap `inferno.c:873`; `namec` slash/dot read
  `chan.c:1022,1057`) were **found by the SPIN race model** and are documented in
  `formal-verification/TODO-RACE-CONDITIONS.md`. They are mitigated by the Dis VM's
  cooperative scheduling (one Dis thread at a time) but are genuine at the multi-threaded host
  layer; the suggested lock fix is recorded. An evaluator must treat these as open TSF-layer
  findings, not resolved.
- **Bounded verification.** TLA+/TLC and CBMC explore finite state spaces; unbounded proofs
  would require interactive theorem proving (Isabelle/HOL). SPIN models abstract lock
  semantics. See `formal-verification/METHODOLOGY.md` §10 "Threats to Validity".
- **Configuration dependence.** CNSA-strict PQC, audit-service binding, export restriction,
  and authenticator lifecycle are **operator responsibilities** (§4.2); defaults are classical
  crypto and (unless bound) no audit sink.

---

## 9. Rationale (abridged)

- **Threats → objectives → SFRs** trace consistently: each threat in §3.1 names its
  countering objective (§4.1), and each objective is realised by the SFRs of §6 (columns
  cross-reference). O.ISOLATION and O.MEDIATION — the differentiators — are backed by formal
  proof rather than assertion.
- **No unmet SFR is presented as met.** FCS module-validation, FIA lockout thresholds, and
  broad FAU coverage are explicitly flagged (§6.5, §6.2, §6.4).
- **The assurance argument is proportionate.** No EAL is claimed; the ST asserts only that the
  *rare and expensive* high-EAL design evidence (a formal model of the core policy) is already
  in hand, which is the readiness thesis of `../../doc/compliance/Common-Criteria-readiness.md`.

---

## 10. References

- ISO/IEC 15408 (CC v3.1 Rev 5) Parts 1–3; ISO/IEC 18045 (CEM); NIAP/CCRA schemes; U.S.
  Government Separation Kernel Protection Profile (SKPP) lineage.
- In-repository evidence: `formal-verification/METHODOLOGY.md`, `formal-verification/README.md`,
  `formal-verification/tla+/IsolationProof.tla`, `formal-verification/spin/*.pml`,
  `formal-verification/cbmc/harness_*_ct.c`, `emu/port/{pgrp,chan,sysfile,inferno,exportfs}.c`,
  `libsec/`, `libinterp/keyring.c`, `appl/cmd/auth/factotum/`, `appl/cmd/auditfs.b`,
  `appl/lib/auditchain.b`, `.github/workflows/{formal-verification,security,scorecard,release,sbom}.yml`.
- Sibling compliance artifacts: [`../../doc/compliance/Common-Criteria-readiness.md`](../../doc/compliance/Common-Criteria-readiness.md),
  [`../../doc/compliance/SP800-53-171-mapping.md`](../../doc/compliance/SP800-53-171-mapping.md),
  [`../../doc/compliance/SP800-53-controls.md`](../../doc/compliance/SP800-53-controls.md),
  [`../../doc/compliance/CNSA-2.0.md`](../../doc/compliance/CNSA-2.0.md),
  [`../../doc/compliance/SP800-63B-AAL3.md`](../../doc/compliance/SP800-63B-AAL3.md),
  [`../../doc/compliance/SP800-92-audit-log.md`](../../doc/compliance/SP800-92-audit-log.md).
- Companion in this directory: [`nist-control-mappings.md`](nist-control-mappings.md).

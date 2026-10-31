# History

Status reports, session notes and debugging logs written while the work they
describe was in progress. They are kept because the reasoning in them is
sometimes useful, not because they are current: each one describes the tree
as it stood on the day it was written, and none of them is maintained.

For how things work now, start at [DOCUMENTATION-INDEX.md](../DOCUMENTATION-INDEX.md).

## The 64-bit port (January 2026)

| Document | |
|----------|-|
| [README-FIRST.md](README-FIRST.md) | The port's original landing page |
| [SESSION-SUMMARY.md](SESSION-SUMMARY.md) | Session summary |
| [COMPILATION-LOG.md](COMPILATION-LOG.md) | Building the tree for the first time |
| [OUTPUT-ISSUE.md](OUTPUT-ISSUE.md) | Dis programs producing no output |
| [SHELL-ISSUE.md](SHELL-ISSUE.md) | The shell loading but not executing |
| [SHELL-BADOP-ISSUE.md](SHELL-BADOP-ISSUE.md) | BADOP on command failure |
| [HEADLESS-STATUS.md](HEADLESS-STATUS.md) | The headless emulator |
| [TEST-RESULTS.md](TEST-RESULTS.md) | Utility test results |
| [VERIFICATION-COMPLETE.md](VERIFICATION-COMPLETE.md) | Verification pass |
| [FINAL-STATUS.md](FINAL-STATUS.md), [FINAL-WORKING-STATUS.md](FINAL-WORKING-STATUS.md), [FINAL-SUMMARY.md](FINAL-SUMMARY.md), [COMPLETE-PORT-SUMMARY.md](COMPLETE-PORT-SUMMARY.md) | End-of-port summaries |

## The ARM64 JIT (January 2026)

Session logs from bringing up `libinterp/comp-arm64.c`. The current reference
is [JIT.md](../JIT.md).

| Document | |
|----------|-|
| [arm64-jit/ARM64-JIT-DEBUG-INDEX.md](arm64-jit/ARM64-JIT-DEBUG-INDEX.md) | Index of the debugging sessions |
| [arm64-jit/ARM64-JIT-SESSION-2026-01-18.md](arm64-jit/ARM64-JIT-SESSION-2026-01-18.md) | First session |
| [arm64-jit/ARM64-JIT-STATUS-2026-01-19.md](arm64-jit/ARM64-JIT-STATUS-2026-01-19.md), [arm64-jit/ARM64-JIT-FINAL-STATUS-2026-01-19.md](arm64-jit/ARM64-JIT-FINAL-STATUS-2026-01-19.md), [arm64-jit/ARM64-JIT-STATUS-UPDATE.md](arm64-jit/ARM64-JIT-STATUS-UPDATE.md), [arm64-jit/ARM64-JIT-FINAL-STATUS.md](arm64-jit/ARM64-JIT-FINAL-STATUS.md), [arm64-jit/JIT-64BIT-STATUS.md](arm64-jit/JIT-64BIT-STATUS.md) | Status reports |
| [arm64-jit/ARM64-JIT-DEBUG-SESSION-2026-01-22.md](arm64-jit/ARM64-JIT-DEBUG-SESSION-2026-01-22.md), [arm64-jit/ARM64-JIT-DEBUG-SESSION-2026-01-22-CHECKPOINT.md](arm64-jit/ARM64-JIT-DEBUG-SESSION-2026-01-22-CHECKPOINT.md), [arm64-jit/ARM64-JIT-DEBUG-NOTES.md](arm64-jit/ARM64-JIT-DEBUG-NOTES.md), [arm64-jit/ARM64-JIT-RESUME-NOTES.md](arm64-jit/ARM64-JIT-RESUME-NOTES.md) | Debugging sessions |
| [arm64-jit/ARM64-JIT-BREAKTHROUGH.md](arm64-jit/ARM64-JIT-BREAKTHROUGH.md), [arm64-jit/ARM64-JIT-BREAKTHROUGH-SESSION.md](arm64-jit/ARM64-JIT-BREAKTHROUGH-SESSION.md) | The fix that made it work |
| [arm64-jit/ARM64-JIT-EXIT-CRASH-ANALYSIS.md](arm64-jit/ARM64-JIT-EXIT-CRASH-ANALYSIS.md), [arm64-jit/ARM64-JIT-FINAL-ANALYSIS.md](arm64-jit/ARM64-JIT-FINAL-ANALYSIS.md), [arm64-jit/ARM64-JIT-SOLUTIONS.md](arm64-jit/ARM64-JIT-SOLUTIONS.md), [arm64-jit/ARM64-JIT-TEST-RESULTS.md](arm64-jit/ARM64-JIT-TEST-RESULTS.md) | Analysis and results |

## The SDL3 GUI (January 2026)

| Document | |
|----------|-|
| [SDL3-GUI-PLAN.md](SDL3-GUI-PLAN.md) | The plan |
| [SDL3-BUILD-ISSUES.md](SDL3-BUILD-ISSUES.md) | Build-system problems |
| [SDL3-STATUS.md](SDL3-STATUS.md), [SDL3-CURRENT-STATUS.md](SDL3-CURRENT-STATUS.md), [SDL3-IMPLEMENTATION-STATUS.md](SDL3-IMPLEMENTATION-STATUS.md), [SDL3-RESUME-HERE.md](SDL3-RESUME-HERE.md) | Progress reports |
| [SDL3-IMPLEMENTATION-COMPLETE.md](SDL3-IMPLEMENTATION-COMPLETE.md), [SDL3-SUCCESS.md](SDL3-SUCCESS.md), [SDL3-FINAL-STATUS.md](SDL3-FINAL-STATUS.md), [SDL3-FINAL-SUMMARY.md](SDL3-FINAL-SUMMARY.md) | Completion reports |

## CI bring-up (January–March 2026)

| Document | |
|----------|-|
| [CI-DEBUGGING-LOG.md](CI-DEBUGGING-LOG.md), [CI-MYSTERY.md](CI-MYSTERY.md), [CI-ROOT-CAUSE.md](CI-ROOT-CAUSE.md) | Debugging the first workflows |
| [CURRENT-CI-STATUS.md](CURRENT-CI-STATUS.md), [CI-STATUS.md](CI-STATUS.md), [CI-FINAL-STATUS.md](CI-FINAL-STATUS.md), [CI-SUCCESS.md](CI-SUCCESS.md), [CI-WORKING.md](CI-WORKING.md) | Status reports |
| [ACTIONS-BLOCKED.md](ACTIONS-BLOCKED.md) | GitHub Actions blocked on the account |
| [SONARQUBE_WORK.md](SONARQUBE_WORK.md) | Clearing the SonarQube backlog |

## Plans, evaluations and reviews since overtaken

| Document | |
|----------|-|
| [LESSONS-LEARNED.md](LESSONS-LEARNED.md) | The 64-bit port's retrospective, including the pool-quanta fix |
| [PORTING-ARM64.md](PORTING-ARM64.md), [64-bit-alt-structure-fix.md](64-bit-alt-structure-fix.md), [TEMPFILE-EXHAUSTION.md](TEMPFILE-EXHAUSTION.md), [NETWORK-CAPABILITIES.md](NETWORK-CAPABILITIES.md), [RECOMMENDED-ADDITIONS.md](RECOMMENDED-ADDITIONS.md), [RUNNING-ACME.md](RUNNING-ACME.md) | Notes from the port's first weeks |
| [JETSON-PORT-ESTIMATE.md](JETSON-PORT-ESTIMATE.md), [JETSON-PORT-PLAN.md](JETSON-PORT-PLAN.md) | The Linux ARM64 port, before and during |
| [arm64-jit/OPCODE-ANALYSIS.md](arm64-jit/OPCODE-ANALYSIS.md), [arm64-jit/OPCODE-DETAILED-ANALYSIS.md](arm64-jit/OPCODE-DETAILED-ANALYSIS.md), [arm64-jit/README-OPCODE-ANALYSIS.md](arm64-jit/README-OPCODE-ANALYSIS.md), [arm64-jit/OPCODE-QUICK-REFERENCE.txt](arm64-jit/OPCODE-QUICK-REFERENCE.txt), [arm64-jit/OPCODE-ANALYSIS-SUMMARY.txt](arm64-jit/OPCODE-ANALYSIS-SUMMARY.txt) | February 2026 opcode coverage of `comp-arm64.c`, since rewritten |
| [QUANTUM-SAFE-CRYPTO-PLAN.md](QUANTUM-SAFE-CRYPTO-PLAN.md), [ELGAMAL-PERFORMANCE.md](ELGAMAL-PERFORMANCE.md), [ED25519-DEBUG-CHECKPOINT.md](ED25519-DEBUG-CHECKPOINT.md) | Cryptography plans and debugging; the as-built record is in [compliance/](../compliance/README.md) |
| [SECSTORE-AUTH-SUITE-PLAN.md](SECSTORE-AUTH-SUITE-PLAN.md) | The secstore3 plan, before secstore2 was retired |
| [VELTRO_NAMESPACE_SECURITY.md](VELTRO_NAMESPACE_SECURITY.md), [NAMESPACE_SECURITY_REVIEW.md](NAMESPACE_SECURITY_REVIEW.md) | The v2 agent namespace model and the review that led to v3 ([appl/veltro/SECURITY.md](../../appl/veltro/SECURITY.md)) |
| [veltro-message-layer-plan.md](veltro-message-layer-plan.md) | The message-layer plan; it shipped as msg9p ([MESSAGE-INTEGRATION.md](../MESSAGE-INTEGRATION.md)) |
| [SP800-92-audit-log-DESIGN.md](SP800-92-audit-log-DESIGN.md), [security-epics.md](security-epics.md) | The audit-log proposal and the security epics as drafted for Jira |
| [GPL-LICENSE-AUDIT.md](GPL-LICENSE-AUDIT.md) | The copyleft audit, resolved May 2026 |
| [MODEL-EVAL-2026-05-01.md](MODEL-EVAL-2026-05-01.md) | A local-model evaluation |
| [LUCIA-EVALUATION.md](LUCIA-EVALUATION.md), [fractal-app-evaluation.md](fractal-app-evaluation.md) | March 2026 readiness evaluations |
| [TODO-LUCIPRES-ARCHITECTURE.md](TODO-LUCIPRES-ARCHITECTURE.md) | The presentation-rendering split, reverted on 2026-07-05 |
| [MULTIPLEXED-VIDEO-SPIKE.md](MULTIPLEXED-VIDEO-SPIKE.md) | The video spike; the design of record is [H264-9P-BRIDGE.md](../H264-9P-BRIDGE.md) |
| [XENITH-IMAGE-MODE.md](XENITH-IMAGE-MODE.md), [XENITH-IMAGE-LOADING.md](XENITH-IMAGE-LOADING.md) | Xenith's image mode and its async image loading, replaced in October 2026 by one document view ([xenith-documents.md](../xenith-documents.md)) |
| [charon-html-css-evaluation.md](charon-html-css-evaluation.md), [CHARON-HANDOFF.md](CHARON-HANDOFF.md) | The old Charon engine's gaps, and the hand-off of its replacement ([CHARON-ENGINE.md](../CHARON-ENGINE.md)) |
| [formal-verification/VERIFICATION-PLAN.md](formal-verification/VERIFICATION-PLAN.md), [formal-verification/PLAN-namespace-security-verification.md](formal-verification/PLAN-namespace-security-verification.md) | Verification plans; the as-built record is [METHODOLOGY.md](../../formal-verification/METHODOLOGY.md) |
| [formal-verification/TODO-RACE-CONDITIONS.md](formal-verification/TODO-RACE-CONDITIONS.md) | Three emu races the race model found; 89db5178 fixed kchdir and namec, and its FORKNS change was reverted in fa93471d (deadlock) |

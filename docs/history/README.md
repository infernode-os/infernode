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

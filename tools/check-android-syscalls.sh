#!/bin/sh
#
# check-android-syscalls.sh — lint emu/Android/*.c for syscalls
# that Android's app-sandbox seccomp filter blocks.
#
# Background: every blocked syscall called from an Android app process
# raises SIGSYS and kills the calling thread (usually the whole
# process). The full list is in /system/etc/seccomp_policy/app.policy
# on a device. This script catches the ones we've actually been burned
# by, so future patches don't quietly reintroduce them. INFR-114 is
# the canonical case study.
#
# Rule: any call to a known-blocked function in emu/Android/*.c must
# sit inside `#ifndef __BIONIC__` … `#endif`. Other emu/* trees are
# not checked; they target host platforms where the calls are fine.
#
# Exit 0 if clean, 1 if any unguarded call is found.

set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

python3 - <<'PY'
import re, sys, glob

# Blocklist — functions whose syscall numbers are denied by Android's
# app-sandbox seccomp filter on arm64. Extend as we find more.
BLOCKED = (
    "setgid setuid setresgid setresuid setregid setreuid "
    "setfsuid setfsgid"
).split()

# Match a call to any blocked function, treating word boundaries the
# Python `\b` way so awk-incompatibility is not an issue.
CALL = re.compile(r"\b(" + "|".join(BLOCKED) + r")\s*\(")

# Detect #ifndef __BIONIC__ / #if !defined(__BIONIC__) at line start.
GUARD_OPEN = re.compile(
    r"^\s*#\s*(?:ifndef\s+__BIONIC__|if\s+!\s*defined\s*\(\s*__BIONIC__\s*\))"
)
ENDIF = re.compile(r"^\s*#\s*endif\b")

fail = 0
for path in sorted(glob.glob("emu/Android/*.c")):
    depth = 0
    with open(path, encoding="utf-8", errors="replace") as fh:
        for lineno, raw in enumerate(fh, start=1):
            if GUARD_OPEN.match(raw):
                depth += 1
                continue
            if ENDIF.match(raw):
                if depth > 0:
                    depth -= 1
                continue
            if depth > 0:
                continue
            stripped = raw.lstrip()
            if stripped.startswith(("//", "*", "/*")):
                continue
            # Strip string literals so we don't catch the function name
            # inside an error message.
            line = re.sub(r'"[^"]*"', '""', raw)
            m = CALL.search(line)
            if m:
                print(
                    f"::error file={path},line={lineno}::unguarded {m.group(1)}() in emu/Android/ — wrap in #ifndef __BIONIC__ (Android app-sandbox seccomp blocks it; see docs/HELLAPHONE.md, INFR-114)",
                    file=sys.stderr,
                )
                fail = 1

if fail:
    print(
        "::error::Android-blocked syscalls present unguarded in emu/Android/. See docs/HELLAPHONE.md.",
        file=sys.stderr,
    )
    sys.exit(1)

print("android-syscall lint: OK")
PY

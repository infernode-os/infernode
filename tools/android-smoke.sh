#!/usr/bin/env bash
#
# Android launch smoke test. Installs the debug APK on an already-running
# emulator, revokes every runtime permission (the fresh-install state a
# Play tester hits), launches InfernodeSDLActivity, and fails if the launch
# produces a startup-crash signature.
#
# Why it asserts on the LOGCAT SIGNATURE, not process liveness: when the
# onCreate permission crash fires, Android instantly restarts the activity,
# so `pidof` reports a live PID even on the broken build — a liveness check
# would falsely pass. The signature is definitive. (Verified both ways on a
# real emulator: passes on the fix, fails on the reverted fix.)
#
# This lives in a file, not inline in the workflow, because
# reactivecircus/android-emulator-runner runs its `script:` input
# line-by-line (each line a separate `sh -c`), which breaks multi-line
# shell constructs. Invoked as a single command — `bash tools/android-smoke.sh`
# — bash reads the whole file, so loops and conditionals work.
#
# Expects: adb on PATH (provided by the action), a booted emulator, and the
# APK at apk/app-debug.apk (downloaded by the workflow before this runs).
set -euo pipefail

PKG=io.infernode
APK=apk/app-debug.apk
SIG='UnsatisfiedLink|nativePermissionResult|FATAL EXCEPTION'

echo "Installing $APK ..."
adb install -r "$APK"

# Fresh-install state: revoke every runtime perm so onCreate's permission
# requests actually fire. A device with perms already granted never calls
# requestPermissions and never exercises the crash path.
for p in RECORD_AUDIO CALL_PHONE SEND_SMS RECEIVE_SMS READ_SMS; do
  adb shell pm revoke "$PKG" "android.permission.$p" 2>/dev/null || true
done

adb logcat -c
adb shell am start -n "$PKG/.InfernodeSDLActivity"

# Give the cold start + ~48MB asset extraction time to complete on the
# (slower, swiftshader) CI emulator. The crash, if present, fires during
# onCreate — well inside this window.
sleep 15

adb logcat -d > launch.log 2>&1 || true
if grep -qiE "$SIG" launch.log; then
  echo "::error::InfernodeSDLActivity crashed on fresh-install launch — startup regression"
  grep -iE "$SIG|InfernodeSDL" launch.log | head -40
  exit 1
fi
echo "Launch smoke OK: no crash signature on fresh-install launch."

#Requires -Version 5.1
<#
.SYNOPSIS
    Windows JIT regression suite — catches the two classes of JIT crash
    fixed in 2026-05-14.

.DESCRIPTION
    Two distinct bugs both surface as opaque NTSTATUS exits and are easy
    to reintroduce silently:

      1. INFR-46 (0xC00000FF / STATUS_BAD_FUNCTION_TABLE)
         MSVC x64 `longjmp` walks SEH through JIT frames and ntdll
         26100+ rejects them. Fix: `ossetjmp` zeroes `_JUMP_BUFFER.Frame`.
         Any new C path that calls `setjmp` directly (not via `waserror`
         / `ossetjmp` macro) reintroduces the bug.

      2. INFR-69 (0xC0000005 / STATUS_ACCESS_VIOLATION in Srv_iph2a)
         Stale 32-bit auto-generated `emu/Nt/srv.h` / `srvm.h` made the
         Limbo runtime allocate a 40-byte frame while C read fields at
         offset 56. Fix: build scripts regenerate from `module/srvrunt.b`
         with the 64-bit limbo every build. Re-committing a stale
         generated header, or deleting the regen step from the build
         scripts, reintroduces the bug.

    Each test runs a minimal JIT scenario that exercises the bug-prone
    path and checks the exit code. cdb is NOT required — exit code is
    sufficient to detect the regression. If a crash NTSTATUS comes back,
    the test fails with the decoded code.

.PARAMETER Bundle
    Path to the dev bundle (folder with o.emu.exe + dis/ + lib/).
    Defaults to $env:TEMP\InferNode-dev (build-dev-bundle.ps1 output).

.PARAMETER Verbose
    Echo each test's stdout/stderr.

.EXAMPLE
    # Validate the running build:
    .\tests\host\windows-jit-regression-test.ps1

.EXAMPLE
    # Run in CI:
    .\tests\host\windows-jit-regression-test.ps1 ; if ($LASTEXITCODE -ne 0) { exit 1 }

.NOTES
    Related Jira: INFR-46, INFR-69, INFR-47.
    Postmortem:   docs/postmortems/2026-05-14-windows-jit-seh-unwind.md
#>

[CmdletBinding()]
param(
    [string]$Bundle = "$env:TEMP\InferNode-dev",
    [int]$TimeoutSec = 20
)

$ErrorActionPreference = "Stop"

$STATUS_BAD_FUNCTION_TABLE = -1073741569   # 0xC00000FF
$STATUS_ACCESS_VIOLATION   = -1073741819   # 0xC0000005

$pass = 0
$fail = 0
$failed = @()

function Test-JitCommand {
    param(
        [string]$Name,
        [string]$Cmd,
        [string]$ExpectStdout,
        [int]$ExpectExit = 0
    )

    Write-Host "TEST: $Name" -ForegroundColor Cyan

    # Run o.emu with timeout — JIT tests must not hang on a daemon kproc.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "$Bundle\o.emu.exe"
    $psi.Arguments = "-c1 -r `"$Bundle`" sh -c `"$Cmd`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        # Backgrounded daemons kept emu alive. For our tests, "didn't crash
        # within timeout" = pass on the crash question; we still need to
        # verify ExpectStdout was printed before the daemons forked.
        try { $proc.Kill() } catch {}
        $proc.WaitForExit()
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $code = -1
        $hangedOnDaemon = $true
    } else {
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $code = $proc.ExitCode
        $hangedOnDaemon = $false
    }

    $code64 = [int64]$code
    $unsigned = [uint32]($code64 -band 0xFFFFFFFFL)
    $hex = '{0:X8}' -f $unsigned
    $sawExpected = $stdout -match [regex]::Escape($ExpectStdout)

    # Decide pass/fail
    $crashed = ($code -eq $STATUS_BAD_FUNCTION_TABLE) -or `
               ($code -eq $STATUS_ACCESS_VIOLATION)
    $ok = $false

    if ($crashed) {
        $reason = "crashed: exit=$code (0x$hex)"
    } elseif (-not $sawExpected) {
        $reason = "missing expected output '$ExpectStdout' in stdout"
    } elseif ($hangedOnDaemon) {
        # JIT didn't crash and produced expected output; daemons left running.
        $ok = $true
        $reason = "ok (emu held alive by daemons - expected)"
    } elseif ($code -ne $ExpectExit) {
        $reason = "exit=$code (expected $ExpectExit, hex 0x$hex)"
    } else {
        $ok = $true
        $reason = "exit=$code, stdout matched"
    }

    if ($ok) {
        Write-Host "  PASS  $reason" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "  FAIL  $reason" -ForegroundColor Red
        if ($VerbosePreference -eq 'Continue') {
            Write-Host "  stdout: $stdout"
            Write-Host "  stderr: $stderr"
        }
        $script:fail++
        $script:failed += $Name
    }
}

# ── Preconditions ──────────────────────────────────────────────
if (-not (Test-Path "$Bundle\o.emu.exe")) {
    Write-Host "FAIL: no o.emu.exe at $Bundle. Run build-dev-bundle.ps1 first." -ForegroundColor Red
    exit 1
}

# Kill any stale emu from previous runs.
Get-Process -Name "o.emu" -ErrorAction SilentlyContinue | Stop-Process -Force

Write-Host ""
Write-Host "=== Windows JIT regression tests ===" -ForegroundColor Yellow
Write-Host "Bundle:  $Bundle"
Write-Host "Timeout: ${TimeoutSec}s per test"
Write-Host ""

# ── INFR-46 regression: SEH unwind through JIT frames ──────────
#
# `error()` -> `nexterror()` -> `longjmp()`. On Windows x64, longjmp
# invokes `RtlUnwind`, which walks SEH frames between setjmp and
# longjmp. With the JIT enabled, there are JIT-compiled frames in
# that walk; ntdll 26100+ rejects them and raises
# STATUS_BAD_FUNCTION_TABLE.
#
# The original repro that surfaced the crash: `load std; mount -ac
# {mntgen} /n`. This JIT-compiles ~15 std modules and triggers
# enough longjmps through mounted-namespace tear-down that the
# SEH walk lands on a JIT frame within the first second.
#
# Pass condition: any output containing "OK" with no NTSTATUS exit.
# mntgen runs as a daemon, so emu stays alive and the test kills
# it on timeout - that's expected and treated as success here.
Test-JitCommand `
    -Name "INFR-46: SEH unwind through JIT (load std + mntgen)" `
    -Cmd "load std; mount -ac {mntgen} /n >[2] /dev/null; echo OK" `
    -ExpectStdout "OK"

# ── INFR-69 regression: Srv runtime frame layout ───────────────
#
# `srv->iph2a(name)` is the Limbo runtime entry point for hostname
# resolution. If the JIT-resolvable Type for iph2a has the wrong
# frame size (which happens when srvm.h was generated by a 32-bit
# limbo), the runtime allocates a too-small frame and the C side
# reads `f->host` past the end -> NULL -> AV in string2c.
#
# `ndb/cs` is the connection server; it dispatches via srv->iph2a
# on every dial. Just starting it under JIT exercises the path.
Test-JitCommand `
    -Name "INFR-69: Srv frame layout via ndb/cs" `
    -Cmd "load std; ndb/cs >[2] /dev/null & sleep 1; echo cs-ok" `
    -ExpectStdout "cs-ok"

# ── General JIT smoke: trivial echo ────────────────────────────
# Catches gross JIT init / vmachine breakage.
Test-JitCommand `
    -Name "JIT smoke: trivial echo" `
    -Cmd "echo jit-ok" `
    -ExpectStdout "jit-ok"

# ── JIT spawn: error path inside spawned proc ──────────────────
# Spawn + error() exercised the original SEH walk most reliably.
Test-JitCommand `
    -Name "JIT spawn + error in child" `
    -Cmd "spawn { load /dis/nonexistent-NEVER-EXISTS.dis >[2] /dev/null }; sleep 1; echo spawn-ok" `
    -ExpectStdout "spawn-ok"

# ── JIT compile of every std module ────────────────────────────
# `load std` JIT-compiles ~15 modules. If the JIT codegen for any one
# of them is broken (rel8 overflow, bad macret, etc.) this fails.
Test-JitCommand `
    -Name "JIT compile: load std" `
    -Cmd "load std; load expr; load arg; load csv; load regex; echo loads-ok" `
    -ExpectStdout "loads-ok"

# ── Cleanup ────────────────────────────────────────────────────
Get-Process -Name "o.emu" -ErrorAction SilentlyContinue | Stop-Process -Force

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Yellow
Write-Host "  pass: $pass" -ForegroundColor Green
if ($fail -gt 0) {
    Write-Host "  fail: $fail" -ForegroundColor Red
    foreach ($n in $failed) { Write-Host "    - $n" -ForegroundColor Red }
    exit 1
} else {
    Write-Host "  fail: $fail"
    Write-Host ""
    Write-Host "All JIT regression tests passed." -ForegroundColor Green
    exit 0
}

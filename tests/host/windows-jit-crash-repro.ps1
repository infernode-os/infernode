#Requires -Version 5.1
<#
.SYNOPSIS
    Reliable repro for the Windows JIT SEH-unwind crash (INFR-46).

.DESCRIPTION
    Spawns a minimal Inferno sh session that loads std and mounts mntgen.
    Under -c1 (JIT) this triggers ~15 module JIT compilations including
    Styxservers and Nametree (used by mntgen's styx server). On Windows
    builds that don't register dynamic SEH unwind info for JIT regions,
    Windows' RtlUnwindEx hits a JIT frame, can't find a function table
    entry, and raises STATUS_BAD_FUNCTION_TABLE (0xC00000FF).

    The same command exits cleanly under -c0 (interpreter).

    First reproduced 2026-05-14 on ntdll.dll 10.0.26100.8246. Earlier
    ntdll versions silently tolerated the missing unwind data; recent
    Windows updates hardened the SEH validation path.

.PARAMETER Bundle
    Path to the dev bundle (a folder containing o.emu.exe + dis/ + lib/).
    Defaults to $env:TEMP\InferNode-dev (the build-dev-bundle.ps1 output).

.PARAMETER ExpectPass
    If set, the script exits non-zero when the crash occurs (use this
    in CI to verify INFR-46 fix). If not set, the script exits zero
    after observing the crash (use this to confirm the bug exists).

.EXAMPLE
    # Confirm the bug reproduces:
    .\tests\host\windows-jit-crash-repro.ps1

.EXAMPLE
    # Verify INFR-46 fix in CI:
    .\tests\host\windows-jit-crash-repro.ps1 -ExpectPass

.NOTES
    Crash signature (Windows Application event log, Application Error 1000):
      Faulting application name: o.emu.exe
      Faulting module name:      ntdll.dll
      Exception code:            0xc00000ff   (STATUS_BAD_FUNCTION_TABLE)
      Fault offset:              0x000000000000dd2f  (in ntdll on 26100.8246)

    Related Jira: INFR-46.
    Related preserved-memory file:
      .claude/projects/.../memory/reference_windows_port_lessons.md
#>

[CmdletBinding()]
param(
    [string]$Bundle = "$env:TEMP\InferNode-dev",
    [switch]$ExpectPass
)

$ErrorActionPreference = "Stop"

function Fail($msg) {
    Write-Host "FAIL: $msg" -ForegroundColor Red
    exit 1
}

function Pass($msg) {
    Write-Host "PASS: $msg" -ForegroundColor Green
    exit 0
}

# ── Preconditions ──────────────────────────────────────────────
if (-not (Test-Path "$Bundle\o.emu.exe")) {
    Fail "no o.emu.exe at $Bundle. Build a dev bundle first: .\build-dev-bundle.ps1"
}

# Kill any stale o.emu that might be holding files / state.
Get-Process -Name "o.emu", "InferNode" -ErrorAction SilentlyContinue |
    ForEach-Object { Stop-Process -Id $_.Id -Force }

# Note pre-test latest crash log entry so we can detect a new one.
$preCrash = Get-WinEvent -LogName Application -MaxEvents 1 -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -eq "Application Error" } |
    Select-Object -First 1
$preCrashTime = if ($preCrash) { $preCrash.TimeCreated } else { Get-Date '2000-01-01' }

# ── The repro ──────────────────────────────────────────────────
# Run o.emu directly (PowerShell-attached stdio; the launcher path
# would have no stdio but crashes identically — see prior tests).
# load std + mount -ac {mntgen} /n is the minimal sequence that
# spawns enough JIT-compiled modules to trigger the crash.
$cmd = "load std; mount -ac {mntgen} /n >[2] /dev/null; echo OK"
Write-Host "Running: o.emu.exe -c1 -r $Bundle sh -c '$cmd'"

$output = & "$Bundle\o.emu.exe" -c1 -r $Bundle sh -c $cmd 2>&1
$exitCode = $LASTEXITCODE
$sawOk = ($output -join "`n") -match "(?m)^OK$"

$exitHex = '{0:X8}' -f ([uint32]([int64]$exitCode -band 0xFFFFFFFF))
Write-Host "exit code:    $exitCode (decimal) / 0x$exitHex"
Write-Host "saw 'OK':     $sawOk"

# ── Diagnostics on crash ───────────────────────────────────────
$crashed = ($exitCode -eq -1073741569)   # 0xC00000FF
if ($crashed) {
    Write-Host ""
    Write-Host "Crash signature observed:" -ForegroundColor Yellow

    # Wait briefly for Application event log to settle.
    Start-Sleep -Milliseconds 500
    $ev = Get-WinEvent -LogName Application -MaxEvents 5 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProviderName -eq "Application Error" -and
            $_.TimeCreated -gt $preCrashTime -and
            $_.Message -like "*o.emu*"
        } | Select-Object -First 1
    if ($ev) {
        $ev.Message.Split("`n") |
            Where-Object { $_ -match 'Faulting|Exception code|Fault offset' } |
            ForEach-Object { Write-Host "  $_" }
    } else {
        Write-Host "  (no Application Error event for o.emu found in last 500 ms)"
    }
}

# ── Verdict ────────────────────────────────────────────────────
if ($ExpectPass) {
    if ($sawOk -and $exitCode -eq 0) {
        Pass "JIT + mntgen spawn ran clean (INFR-46 fix confirmed)."
    } else {
        Fail ("Expected clean run but " + $(if($crashed){"got crash 0xC00000FF"}else{"got exit=$exitCode, OK=$sawOk"}))
    }
} else {
    if ($crashed) {
        Pass "Confirmed crash reproduces (0xC00000FF / STATUS_BAD_FUNCTION_TABLE)."
    } elseif ($sawOk -and $exitCode -eq 0) {
        Write-Host "Note: emu ran clean. Either INFR-46 is fixed on this build, or" -ForegroundColor Yellow
        Write-Host "      the ntdll on this machine doesn't yet validate JIT unwind." -ForegroundColor Yellow
        Pass "no crash observed"
    } else {
        Fail "unexpected outcome: exit=$exitCode, OK=$sawOk (expected either 0/OK or 0xC00000FF)"
    }
}

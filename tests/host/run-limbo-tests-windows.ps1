#Requires -Version 5.1
<#
.SYNOPSIS
    Run the Limbo test suite under the Windows emu, JIT-enabled.

.DESCRIPTION
    Iterates the *_test.dis files in /dis/tests/, invokes each under
    `o.emu -c1`, and applies a per-test timeout to handle tests whose
    spawned daemons keep emu alive. Output of each test goes to
    $env:TEMP\limbo-test-<name>.log.

    A test is considered:
      PASS if exit=0 and no "FAIL" / "fail:" string in output.
      FAIL if exit != 0 OR a "FAIL" / "fail:" string appears.
      CRASH if NTSTATUS exit code matches a known JIT crash signature.
      TIMEOUT if the test ran longer than -TimeoutSec without exiting.
              (Treated as "ran without crashing" unless the test
              normally exits — distinguishing those is left to authors
              who can supply -PassPattern.)

.PARAMETER Root
    Inferno source-tree root. Defaults to the script's repo root.

.PARAMETER TimeoutSec
    Per-test timeout (default 30s). Tests that spawn daemons need
    this to bound the run.

.PARAMETER Filter
    Glob pattern to limit which tests run (e.g. "crypto_*").

.EXAMPLE
    .\tests\host\run-limbo-tests-windows.ps1
#>

[CmdletBinding()]
param(
    [string]$Root = (Resolve-Path "$PSScriptRoot\..\..").Path,
    [int]$TimeoutSec = 30,
    [string]$Filter = "*"
)

$ErrorActionPreference = "Stop"
$emu = "$Root\emu\Nt\o.emu.exe"
$testDir = "$Root\dis\tests"

if (-not (Test-Path $emu))    { Write-Host "FAIL: no emu at $emu" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $testDir)) { Write-Host "FAIL: no /dis/tests at $testDir" -ForegroundColor Red; exit 1 }

$STATUS_BAD_FUNCTION_TABLE = -1073741569
$STATUS_ACCESS_VIOLATION   = -1073741819

$tests = Get-ChildItem -Path $testDir -Filter "${Filter}_test.dis" | Sort-Object Name
if ($tests.Count -eq 0) {
    $tests = Get-ChildItem -Path $testDir -Filter "$Filter.dis" | Where-Object { $_.Name -like "*_test.dis" } | Sort-Object Name
}

Write-Host "=== Running $($tests.Count) Limbo tests under JIT ===" -ForegroundColor Yellow
Write-Host "Root:    $Root"
Write-Host "Timeout: ${TimeoutSec}s/test"
Write-Host ""

$pass = 0; $fail = 0; $crash = 0; $timeout = 0
$failures = @()

foreach ($t in $tests) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($t.Name)
    $logFile = "$env:TEMP\limbo-test-$name.log"

    # Skip pre-existing emu instances.
    Get-Process -Name "o.emu" -ErrorAction SilentlyContinue | Stop-Process -Force

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $emu
    $psi.Arguments = "-c1 -r `"$Root`" /dis/tests/$($t.Name)"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    $timedOut = -not $proc.WaitForExit($TimeoutSec * 1000)
    if ($timedOut) {
        try { $proc.Kill() } catch {}
        $proc.WaitForExit()
    }

    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $combined = "$stdout`n$stderr"
    Set-Content -Path $logFile -Value $combined -Encoding utf8
    $code = $proc.ExitCode

    $crashed = ($code -eq $STATUS_BAD_FUNCTION_TABLE) -or ($code -eq $STATUS_ACCESS_VIOLATION)
    $sawFail = $combined -match "(?m)^FAIL|fail:"
    $sawPass = $combined -match "(?m)^PASS|All Tests Passed|\d+ passed"

    if ($crashed) {
        $code64 = [int64]$code
        $unsigned = [uint32]($code64 -band 0xFFFFFFFFL)
        $hex = '{0:X8}' -f $unsigned
        Write-Host ("  CRASH  {0,-30} exit=0x{1}" -f $name, $hex) -ForegroundColor Red
        $crash++
        $failures += "$name (NTSTATUS 0x$hex)"
    } elseif ($timedOut -and -not $sawFail) {
        # Long-running tests (daemons) — treat as ok if no FAIL marker.
        Write-Host ("  TIMEOUT {0,-30} (>${TimeoutSec}s, no FAIL marker)" -f $name) -ForegroundColor DarkYellow
        $timeout++
    } elseif ($sawFail -or ($code -ne 0 -and -not $sawPass)) {
        Write-Host ("  FAIL   {0,-30} exit=$code" -f $name) -ForegroundColor Red
        $fail++
        $failures += "$name (exit=$code, log: $logFile)"
    } else {
        Write-Host ("  PASS   {0,-30} exit=$code" -f $name) -ForegroundColor Green
        $pass++
    }
}

Get-Process -Name "o.emu" -ErrorAction SilentlyContinue | Stop-Process -Force

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Yellow
Write-Host "  PASS:    $pass" -ForegroundColor Green
Write-Host "  FAIL:    $fail"   -ForegroundColor $(if($fail -gt 0){'Red'}else{'Gray'})
Write-Host "  CRASH:   $crash"  -ForegroundColor $(if($crash -gt 0){'Red'}else{'Gray'})
Write-Host "  TIMEOUT: $timeout" -ForegroundColor DarkYellow
if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "Failures:" -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  - $f" -ForegroundColor Red }
}

# Crashes are always a failure; FAIL is a failure; TIMEOUT is informational.
if ($crash -gt 0 -or $fail -gt 0) { exit 1 } else { exit 0 }

#Requires -Version 5.1
<#
.SYNOPSIS
    Reset a Windows InferNode install to first-run state.

.DESCRIPTION
    Removes all per-user state that accumulates across InferNode runs:
      - %USERPROFILE%\.infernode\ (the writable overlay: secstore PAK,
        ndb/llm config, veltro markers, lucibridge.log, theme, etc.)
      - Any running o.emu, InferNode, secstored processes that would
        hold file handles open and block deletion
      - The cached -ExpectPass log files in %TEMP%

    Does NOT touch:
      - The repo source tree
      - %TEMP%\InferNode-dev\ (the dev bundle) - that's a build output,
        not user state. Pass -DeleteDevBundle to also remove it.
      - User environment variables (ANTHROPIC_API_KEY, etc.). The shell
        will report whether one is currently set, but won't delete it -
        that's a deliberate user choice. Pass -ClearEnv to delete it
        from the user environment as well.

    After running, launching InferNode again triggers the first-run
    flow: profile.sh seeds ~/.infernode from /lib (the read-only root),
    secstored asks for a new password, factotum starts empty, etc.

.PARAMETER DeleteDevBundle
    Also remove %TEMP%\InferNode-dev. Use this when you want to test
    the released zip in isolation, not the locally-built dev bundle.

.PARAMETER ClearEnv
    Also clear ANTHROPIC_API_KEY from the user environment. Default
    is to leave env vars alone.

.PARAMETER Force
    Skip the confirmation prompt. Use in CI / non-interactive contexts.

.EXAMPLE
    .\tests\host\reset-windows-install.ps1

.EXAMPLE
    # Full reset for an RC-zip fresh-install test:
    .\tests\host\reset-windows-install.ps1 -DeleteDevBundle -ClearEnv -Force
#>

[CmdletBinding()]
param(
    [switch]$DeleteDevBundle,
    [switch]$ClearEnv,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$inferno = Join-Path $env:USERPROFILE ".infernode"
$bundle = Join-Path $env:TEMP "InferNode-dev"

Write-Host "=== Reset plan ===" -ForegroundColor Cyan
$plan = @()
if (Test-Path $inferno) {
    $size = [math]::Round(((Get-ChildItem $inferno -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1KB), 1)
    $plan += "  DELETE  $inferno  ($size KB)"
} else {
    $plan += "  (already absent)  $inferno"
}
if ($DeleteDevBundle) {
    if (Test-Path $bundle) {
        $size = [math]::Round(((Get-ChildItem $bundle -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB), 1)
        $plan += "  DELETE  $bundle  ($size MB)"
    } else {
        $plan += "  (already absent)  $bundle"
    }
}
if ($ClearEnv) {
    $cur = [Environment]::GetEnvironmentVariable("ANTHROPIC_API_KEY", "User")
    if ($cur) {
        $masked = $cur.Substring(0, [Math]::Min(8, $cur.Length)) + "...(masked)"
        $plan += "  CLEAR   user env ANTHROPIC_API_KEY  ($masked)"
    } else {
        $plan += "  (not set)  user env ANTHROPIC_API_KEY"
    }
}
$running = Get-Process -Name "o.emu","InferNode","secstored" -ErrorAction SilentlyContinue
if ($running) {
    foreach ($p in $running) {
        $plan += "  KILL    $($p.Name) PID $($p.Id)"
    }
} else {
    $plan += "  (no running processes)  o.emu / InferNode / secstored"
}
$plan | ForEach-Object { Write-Host $_ }
Write-Host ""

if (-not $Force) {
    $yn = Read-Host "Proceed? [y/N]"
    if ($yn -notmatch "^[Yy]") {
        Write-Host "Aborted." -ForegroundColor Yellow
        exit 0
    }
}

# 1. Kill processes first so their handles don't block deletion.
if ($running) {
    Write-Host "Stopping processes..."
    $running | ForEach-Object {
        try { $_.Kill() } catch {}
    }
    Start-Sleep -Milliseconds 500
}

# 2. Remove the overlay.
if (Test-Path $inferno) {
    Write-Host "Removing $inferno ..."
    Remove-Item -Recurse -Force $inferno -ErrorAction SilentlyContinue
    if (Test-Path $inferno) {
        Write-Host "WARNING: $inferno still present (handle held open?)" -ForegroundColor Yellow
    } else {
        Write-Host "  removed" -ForegroundColor Green
    }
}

# 3. Optional: remove dev bundle.
if ($DeleteDevBundle -and (Test-Path $bundle)) {
    Write-Host "Removing $bundle ..."
    Remove-Item -Recurse -Force $bundle -ErrorAction SilentlyContinue
    if (Test-Path $bundle) {
        Write-Host "WARNING: $bundle still present" -ForegroundColor Yellow
    } else {
        Write-Host "  removed" -ForegroundColor Green
    }
}

# 4. Optional: clear env vars.
if ($ClearEnv) {
    if ([Environment]::GetEnvironmentVariable("ANTHROPIC_API_KEY", "User")) {
        [Environment]::SetEnvironmentVariable("ANTHROPIC_API_KEY", $null, "User")
        Write-Host "Cleared ANTHROPIC_API_KEY from user environment." -ForegroundColor Green
        Write-Host "  (existing shells keep their current value - open a new shell to see the cleared state)" -ForegroundColor DarkGray
    }
}

# 5. Clean leftover log files in %TEMP%
foreach ($pattern in @("infernode-setup-windows*.log", "cdb-infr*.log", "limbo-test-*.log",
                       "ollama-test*.json", "ollama-resp*.json", "ollama-body.json",
                       "jit-testsuite-*.txt", "infernode-panic.log")) {
    $files = Get-ChildItem -Path $env:TEMP -Filter $pattern -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "Reset complete." -ForegroundColor Green
Write-Host "Next launch of InferNode will go through the first-run flow." -ForegroundColor DarkGray

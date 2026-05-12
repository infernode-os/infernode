# Assemble an unsigned dev InferNode bundle on Windows from the working
# tree. Mirrors the production release.yml steps minus signing, intended
# for local testing of the packaged form without going through CI.
#
# Output: $env:TEMP\InferNode-dev\ (override with -OutDir).
#
# Layout matches the released zip:
#   $OutDir\
#     InferNode.exe         launcher (Windows-subsystem)
#     o.emu.exe             emulator (SDL3 GUI build)
#     SDL3.dll              SDL3 runtime
#     Nt\amd64\bin\         limbo.exe, mk.exe
#     dis\ lib\ fonts\ module\ services\ locale\
#     tmp\
#     mkconfig, mkfiles\
#     LICENCE, NOTICE, TRADEMARK.md, README.md, QUICKSTART.md
#     build-windows-amd64.ps1, build-windows-sdl3.ps1
#     dev-bundle-stamp.txt
#
# Usage:
#   .\build-dev-bundle.ps1                # default: $env:TEMP\InferNode-dev
#   .\build-dev-bundle.ps1 -OutDir D:\X   # custom output directory
#
# Prerequisites (run these first):
#   .\build-windows-amd64.ps1    # libs, headless emu, .dis tree
#   .\build-windows-sdl3.ps1     # SDL3 GUI emu (overwrites o.emu.exe)
#   .\emu\Nt\build-launcher.ps1  # InferNode.exe
#
# Mirror of build-dev-bundle.sh (macOS); see that script for the
# /tmp/InferNode-dev.app equivalent.

[CmdletBinding()]
param([string]$OutDir = "$env:TEMP\InferNode-dev")

$ErrorActionPreference = 'Stop'
$ROOT = Split-Path -Parent $MyInvocation.MyCommand.Path

function Require-File($path, $hint) {
    if (-not (Test-Path $path)) {
        Write-Error "build-dev-bundle: missing $path`n  $hint"
        exit 1
    }
}

Require-File "$ROOT\emu\Nt\o.emu.exe"      "Run .\build-windows-sdl3.ps1 first."
Require-File "$ROOT\emu\Nt\InferNode.exe"  "Run .\emu\Nt\build-launcher.ps1 first."
Require-File "$ROOT\Nt\amd64\bin\limbo.exe" "Run .\build-windows-amd64.ps1 first."
Require-File "$ROOT\Nt\amd64\bin\mk.exe"    "Run .\build-windows-amd64.ps1 first."

Write-Host "Assembling dev bundle: $OutDir"
if (Test-Path $OutDir) { Remove-Item -Recurse -Force $OutDir }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Flat layout: launcher + emu + SDL3 + runtime side-by-side. The launcher
# sets CWD to its own dir and invokes %dir%\o.emu.exe with -r ., so all
# four must live together.
Copy-Item "$ROOT\emu\Nt\InferNode.exe" "$OutDir\"
Copy-Item "$ROOT\emu\Nt\o.emu.exe"     "$OutDir\"
if (Test-Path "$ROOT\emu\Nt\SDL3.dll") {
    Copy-Item "$ROOT\emu\Nt\SDL3.dll" "$OutDir\"
} else {
    Write-Warning "SDL3.dll not found at emu\Nt\SDL3.dll - copy it in manually if you need GUI mode."
}

# Native tools (limbo, mk).
New-Item -ItemType Directory -Force -Path "$OutDir\Nt\amd64\bin" | Out-Null
Copy-Item "$ROOT\Nt\amd64\bin\limbo.exe" "$OutDir\Nt\amd64\bin\"
Copy-Item "$ROOT\Nt\amd64\bin\mk.exe"    "$OutDir\Nt\amd64\bin\"

# Runtime tree. usr\ and mnt\ excluded by default: usr\ contains
# per-user state (secstore data, test artefacts) that shouldn't ship in
# a release bundle; profile creates the needed subdirs at boot.
foreach ($d in @("dis", "lib", "fonts", "module", "services", "locale")) {
    if (Test-Path "$ROOT\$d") {
        Copy-Item -Recurse "$ROOT\$d" "$OutDir\$d"
    }
}

# tmp directory referenced by lib/sh/profile.
New-Item -ItemType Directory -Force -Path "$OutDir\tmp" | Out-Null

# Build system (for users who want to rebuild from the bundle).
Copy-Item "$ROOT\mkconfig" "$OutDir\"
if (Test-Path "$ROOT\mkfiles") {
    Copy-Item -Recurse "$ROOT\mkfiles" "$OutDir\mkfiles"
}

# Docs and legal.
foreach ($f in @("LICENCE", "NOTICE", "TRADEMARK.md", "README.md", "QUICKSTART.md")) {
    if (Test-Path "$ROOT\$f") {
        Copy-Item "$ROOT\$f" "$OutDir\"
    }
}

# Build scripts so the user can rebuild from the bundle.
foreach ($f in @("build-windows-amd64.ps1", "build-windows-sdl3.ps1")) {
    if (Test-Path "$ROOT\$f") {
        Copy-Item "$ROOT\$f" "$OutDir\"
    }
}

# Post-install setup (Anthropic API key / Ollama install + model pull).
# Users run this once after extracting the bundle to wire up Veltro's LLM.
if (Test-Path "$ROOT\setup-windows.ps1") {
    Copy-Item "$ROOT\setup-windows.ps1" "$OutDir\"
}

# Build provenance stamp.
$sha = "unknown"
try {
    $gitSha = (& git -C $ROOT rev-parse --short=8 HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and $gitSha) { $sha = $gitSha.Trim() }
} catch {}
$now = Get-Date -Format 'o'
$stamp = "Built from {0} - {1} at {2}" -f $ROOT, $sha, $now
Set-Content -Path "$OutDir\dev-bundle-stamp.txt" -Value $stamp

# Summary.
$emuSize = [math]::Round((Get-Item "$OutDir\o.emu.exe").Length / 1KB, 1)
$launcherSize = [math]::Round((Get-Item "$OutDir\InferNode.exe").Length / 1KB, 1)
Write-Host ""
Write-Host "Bundle assembled." -ForegroundColor Green
Write-Host ("  Launcher: {0}\InferNode.exe ({1} KB)" -f $OutDir, $launcherSize)
Write-Host ("  Emulator: {0}\o.emu.exe ({1} KB)" -f $OutDir, $emuSize)
Write-Host "  Stamp:    $stamp"
Write-Host ""
Write-Host "Launch (double-click or):" -ForegroundColor Yellow
Write-Host ("  & '{0}\InferNode.exe'" -f $OutDir)
Write-Host ""
Write-Host "Zip for distribution:"
Write-Host ("  Compress-Archive -Path '{0}' -DestinationPath InferNode-dev.zip" -f $OutDir)

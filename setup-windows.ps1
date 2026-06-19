#Requires -Version 5.1
<#
.SYNOPSIS
    InferNode Setup - Windows

.DESCRIPTION
    Configures the LLM backend that Veltro needs to operate.
    Choose between an Anthropic API key or a local Ollama instance.

.NOTES
    Run from PowerShell:  .\setup-windows.ps1
    If blocked by execution policy:  powershell -ExecutionPolicy Bypass -File .\setup-windows.ps1
#>

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Once the runtime has booted once, lib/sh/profile creates ~/.infernode/
# and bind-mounts subtrees of it over /lib/ndb, /lib/veltro/keys, etc.
# (commit 3879eba3 — read-only bundle root, writable user overlay).
# Writes to the bundle's lib/* are invisible to the runtime once the
# overlay exists. Write-Config below mirrors writes to both locations
# so setup works whether it's run before OR after first launch, and
# stays consistent if the user later deletes the overlay for a re-seed.
$Infhome = Join-Path $env:USERPROFILE '.infernode'

# Overlay path mapping per lib/sh/profile binds. Bundle path → overlay
# subtree-relative path. Where the bind names diverge (the profile
# avoids putting lib/veltro/keys under lib/veltro so the two binds
# don't conflict), the mapping records both sides.
$OverlayMap = @{
    'lib\ndb'              = 'lib\ndb'
    'lib\veltro\keys'      = 'lib\veltro-keys'
    'lib\veltro'           = 'lib\veltro'
    'lib\veltro\agents'    = 'lib\veltro-agents'
    'lib\lucifer\theme'    = 'lib\lucifer\theme'
    'lib\keyring'          = 'lib\keyring'
}

function Resolve-OverlayPath {
    param([string]$BundleRel)
    # Find the longest matching prefix in $OverlayMap.
    $best = $null; $bestLen = -1
    foreach ($k in $OverlayMap.Keys) {
        $kSlash = "$k\"
        if ($BundleRel -eq $k -or $BundleRel.StartsWith($kSlash, [StringComparison]::OrdinalIgnoreCase)) {
            if ($k.Length -gt $bestLen) { $best = $k; $bestLen = $k.Length }
        }
    }
    if (-not $best) { return $null }
    $suffix = $BundleRel.Substring($best.Length)
    return ($OverlayMap[$best] + $suffix)
}

function Write-Config {
    param(
        [Parameter(Mandatory)] [string]$BundleRel,
        [Parameter(Mandatory)] [string]$Content
    )
    # Always seed the bundle so a fresh first-boot (no overlay yet) picks
    # this up via the lib/sh/profile cp step.
    $bundlePath = Join-Path $Root $BundleRel
    $bundleDir = Split-Path -Parent $bundlePath
    if (-not (Test-Path $bundleDir)) { New-Item -ItemType Directory -Path $bundleDir -Force | Out-Null }
    Set-Content -Path $bundlePath -Value $Content -NoNewline

    # If the overlay already exists, write the live copy too. Without
    # this, the runtime keeps reading the stale overlay value and the
    # bundle write is invisible until the user deletes ~/.infernode.
    if (Test-Path $Infhome) {
        $overlayRel = Resolve-OverlayPath $BundleRel
        if ($overlayRel) {
            $overlayPath = Join-Path $Infhome $overlayRel
            $overlayDir = Split-Path -Parent $overlayPath
            if (-not (Test-Path $overlayDir)) { New-Item -ItemType Directory -Path $overlayDir -Force | Out-Null }
            Set-Content -Path $overlayPath -Value $Content -NoNewline
        }
    }
}

# Mirror everything to a log file so right-click "Run with PowerShell" runs
# have a post-mortem when the window closes too fast to read.
$LogFile = Join-Path $env:TEMP "infernode-setup-windows.log"
try { Start-Transcript -Path $LogFile -Force -ErrorAction Stop | Out-Null } catch {}

# Right-click "Run with PowerShell" opens a console that closes on exit.
# Wrap everything in a try so any error surfaces before we pause, and
# always pause at the end - success or failure - so the user can read
# what happened.
function Pause-OnExit {
    param([string]$Reason = "Setup finished.")
    Write-Host ""
    Write-Host "  $Reason" -ForegroundColor DarkGray
    Write-Host "  Log: $LogFile" -ForegroundColor DarkGray
    if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        Write-Host ""
        $null = Read-Host "Press Enter to close"
    }
    try { Stop-Transcript | Out-Null } catch {}
}

# ── Helpers ────────────────────────────────────────────────────────
function Write-Info  { param($msg) Write-Host "  > " -ForegroundColor Cyan -NoNewline; Write-Host $msg }
function Write-Ok    { param($msg) Write-Host "  + " -ForegroundColor Green -NoNewline; Write-Host $msg }
function Write-Warn  { param($msg) Write-Host "  ! " -ForegroundColor Yellow -NoNewline; Write-Host $msg }
function Write-Fail  { param($msg) Write-Host "  X " -ForegroundColor Red -NoNewline; Write-Host $msg; throw $msg }

function Write-Key {
    param([string]$Service, [string]$Key)
    Write-Config -BundleRel "lib\veltro\keys\$Service" -Content $Key
    Write-Ok "Key saved to lib\veltro\keys\$Service"
}

try {

# ── Banner ─────────────────────────────────────────────────────────
Write-Host ""
Write-Host "InferNode Setup" -ForegroundColor White -BackgroundColor DarkBlue
Write-Host "Configure the LLM backend for Veltro" -ForegroundColor DarkGray
Write-Host ""

# Heads-up if a runtime is already loaded. llmsrv reads its backend
# settings at start, so a running emu won't pick up the new config
# until it's restarted.
$running = Get-Process -Name 'o.emu','InferNode' -ErrorAction SilentlyContinue
if ($running) {
    Write-Warn "InferNode is currently running (PID $($running.Id -join ', '))."
    Write-Host "    Settings will be written to disk, but the live emulator" -ForegroundColor DarkGray
    Write-Host "    won't see the new backend until you close and relaunch it." -ForegroundColor DarkGray
    Write-Host ""
}

# ── Choose backend ─────────────────────────────────────────────────
Write-Host "Veltro needs an LLM to work. Choose your backend:"
Write-Host ""
Write-Host "  1) " -NoNewline; Write-Host "Anthropic API key" -ForegroundColor White -NoNewline; Write-Host " (recommended - best quality)" -ForegroundColor DarkGray
Write-Host "  2) " -NoNewline; Write-Host "Local model via Ollama" -ForegroundColor White -NoNewline; Write-Host " (free, private, ~2-5 GB download)" -ForegroundColor DarkGray
Write-Host ""

do {
    $choice = Read-Host "Enter 1 or 2"
} while ($choice -ne "1" -and $choice -ne "2")

Write-Host ""

# ── Path 1: Anthropic API ──────────────────────────────────────────
function Setup-Anthropic {
    Write-Info "Anthropic API setup"
    Write-Host ""

    # Check for existing key
    $existing = $env:ANTHROPIC_API_KEY
    $keyFile = Join-Path $Root "lib\veltro\keys\anthropic"
    if (-not $existing -and (Test-Path $keyFile)) {
        $existing = Get-Content $keyFile -Raw
    }

    if ($existing) {
        $masked = $existing.Substring(0, [Math]::Min(8, $existing.Length)) + "..." + $existing.Substring([Math]::Max(0, $existing.Length - 4))
        Write-Ok "Found existing API key: $masked"
        $yn = Read-Host "  Use this key? [Y/n]"
        if ($yn -match "^[Nn]") { $existing = $null }
    }

    if (-not $existing) {
        $apikey = Read-Host "  Paste your Anthropic API key (starts with sk-ant-)"
        if (-not $apikey) { Write-Fail "No API key provided." }
    } else {
        $apikey = $existing
    }

    # Validate format
    if (-not $apikey.StartsWith("sk-ant-")) {
        Write-Warn "Key doesn't start with sk-ant-. Proceeding anyway."
    }

    # Quick validation
    Write-Info "Validating API key..."
    try {
        $headers = @{
            "x-api-key"         = $apikey
            "anthropic-version" = "2023-06-01"
            "content-type"      = "application/json"
        }
        $body = '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}'
        $response = Invoke-WebRequest -Uri "https://api.anthropic.com/v1/messages" `
            -Method POST -Headers $headers -Body $body -UseBasicParsing -ErrorAction SilentlyContinue
        if ($response.StatusCode -eq 200) {
            Write-Ok "API key is valid."
        }
    } catch {
        $status = $_.Exception.Response.StatusCode.value__
        switch ($status) {
            401     { Write-Fail "API key rejected (401 Unauthorized). Check your key and try again." }
            default { Write-Warn "Status $status - key saved but check your account." }
        }
    }

    # Store the key
    Write-Key "anthropic" $apikey
    $env:ANTHROPIC_API_KEY = $apikey

    # Offer to set as user environment variable
    Write-Host ""
    $yn = Read-Host "  Set ANTHROPIC_API_KEY as a permanent user environment variable? [y/N]"
    if ($yn -match "^[Yy]") {
        [System.Environment]::SetEnvironmentVariable("ANTHROPIC_API_KEY", $apikey, "User")
        Write-Ok "ANTHROPIC_API_KEY set for current user (takes effect in new terminals)."
    }

    # Write the runtime LLM config so profile/boot.sh starts llmsrv with
    # the right backend. We leave model= blank so Settings doesn't
    # pre-populate a model string; the user picks one from the UI.
    Write-Config -BundleRel "lib\ndb\llm" -Content @"
mode=local
backend=api
url=https://api.anthropic.com
model=
dial=
"@
    Write-Ok "Config saved to lib\ndb\llm"

    Write-Host ""
    Write-Ok "Anthropic backend configured."
    Write-Host "  Pick a model in Settings (Lucifer)." -ForegroundColor DarkGray
    Write-Host "  Common choices: claude-sonnet-4-5-20250929, claude-haiku-4-5-20251001" -ForegroundColor DarkGray
}

# ── Path 2: Ollama ─────────────────────────────────────────────────
function Setup-Ollama {
    Write-Info "Ollama setup (local LLM)"
    Write-Host ""

    # Check if Ollama is installed
    $ollamaPath = Get-Command ollama -ErrorAction SilentlyContinue
    if ($ollamaPath) {
        Write-Ok "Ollama is installed: $($ollamaPath.Source)"
        $ver = & ollama --version 2>$null
        if ($ver) { Write-Host "  Version: $ver" }
    } else {
        Write-Info "Ollama not found. Installing..."
        Write-Host ""

        # Try winget first
        $hasWinget = Get-Command winget -ErrorAction SilentlyContinue
        if ($hasWinget) {
            $yn = Read-Host "  Install via winget? [Y/n]"
            if ($yn -match "^[Nn]") {
                Write-Info "Install manually from https://ollama.com/download and re-run this script."
                exit 0
            }
            winget install Ollama.Ollama --accept-package-agreements --accept-source-agreements
        } else {
            Write-Info "Downloading Ollama installer..."
            $installer = Join-Path $env:TEMP "OllamaSetup.exe"
            Invoke-WebRequest -Uri "https://ollama.com/download/OllamaSetup.exe" -OutFile $installer -UseBasicParsing
            Write-Info "Running installer (follow the prompts)..."
            Start-Process -FilePath $installer -Wait
            Remove-Item $installer -ErrorAction SilentlyContinue
        }

        # Refresh PATH
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                     [System.Environment]::GetEnvironmentVariable("Path", "User")

        if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
            Write-Fail "Ollama installation failed. Install from https://ollama.com/download and re-run."
        }
        Write-Ok "Ollama installed."
    }

    # Ensure Ollama is running
    Write-Host ""
    Write-Info "Checking if Ollama is running..."
    $running = $false
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:11434/api/tags" -UseBasicParsing -ErrorAction SilentlyContinue
        if ($r.StatusCode -eq 200) { $running = $true }
    } catch {}

    if ($running) {
        Write-Ok "Ollama is running."
    } else {
        Write-Info "Starting Ollama..."
        Start-Process "ollama" -ArgumentList "serve" -WindowStyle Hidden
        Start-Sleep -Seconds 3
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:11434/api/tags" -UseBasicParsing -ErrorAction SilentlyContinue
            if ($r.StatusCode -eq 200) {
                Write-Ok "Ollama is running."
            }
        } catch {
            Write-Warn "Could not start Ollama. You may need to run 'ollama serve' manually."
        }
    }

    # Choose a model
    Write-Host ""
    Write-Host "Choose a model to download:"
    Write-Host ""
    Write-Host "  1) " -NoNewline; Write-Host "llama3.2:3b" -ForegroundColor White -NoNewline; Write-Host "   (~2 GB - fast, good for most tasks)" -ForegroundColor DarkGray
    Write-Host "  2) " -NoNewline; Write-Host "llama3.1:8b" -ForegroundColor White -NoNewline; Write-Host "   (~5 GB - better quality, needs 8+ GB RAM)" -ForegroundColor DarkGray
    Write-Host "  3) " -NoNewline; Write-Host "qwen2.5:7b" -ForegroundColor White -NoNewline; Write-Host "    (~4 GB - strong reasoning, good tool use)" -ForegroundColor DarkGray
    Write-Host "  4) " -NoNewline; Write-Host "Custom" -ForegroundColor White -NoNewline; Write-Host "         (enter any Ollama model name)" -ForegroundColor DarkGray
    Write-Host ""

    do {
        $mchoice = Read-Host "Enter choice [1]"
        if (-not $mchoice) { $mchoice = "1" }
    } while ($mchoice -notin @("1","2","3","4"))

    switch ($mchoice) {
        "1" { $model = "llama3.2:3b" }
        "2" { $model = "llama3.1:8b" }
        "3" { $model = "qwen2.5:7b" }
        "4" {
            $model = Read-Host "  Model name"
            if (-not $model) { Write-Fail "No model name given." }
        }
    }

    # Pull the model
    Write-Host ""
    Write-Info "Pulling $model (this may take a few minutes)..."
    & ollama pull $model
    if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to pull $model." }
    Write-Ok "$model is ready."

    # Write the LLM config. The runtime reads /lib/ndb/llm (see
    # lib/sh/profile and lib/lucifer/boot.sh); the old
    # lib/veltro/llm.cfg path was a dead file - nothing read it.
    Write-Config -BundleRel "lib\ndb\llm" -Content @"
mode=local
backend=openai
url=http://localhost:11434/v1
model=$model
dial=
"@
    Write-Ok "Config saved to lib\ndb\llm"

    Write-Host ""
    Write-Ok "Ollama backend configured."
    Write-Host "  Model: $model" -ForegroundColor White
    Write-Host "  Endpoint: http://localhost:11434/v1" -ForegroundColor White
    Write-Host ""
    Write-Host "  Tip: Ollama must be running before you start InferNode." -ForegroundColor DarkGray
    Write-Host "  Start it with: ollama serve" -ForegroundColor DarkGray
}

# ── Optional: Brave Search API key ─────────────────────────────────
function Setup-BraveSearch {
    Write-Host ""
    Write-Host "  -------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Veltro can search the web using the Brave Search API (optional)."
    Write-Host "  Get a free key at: https://brave.com/search/api/"
    Write-Host ""
    $bravekey = Read-Host "  Paste your Brave Search API key (or press Enter to skip)"
    if ($bravekey) {
        Write-Key "brave" $bravekey
    } else {
        Write-Info "Skipped. You can add it later to lib\veltro\keys\brave"
    }
}

# ── Dispatch ───────────────────────────────────────────────────────
switch ($choice) {
    "1" { Setup-Anthropic }
    "2" { Setup-Ollama }
}

Setup-BraveSearch

# ── Preflight: POSIX host shell on PATH ────────────────────────────
# Inferno's runtime exec's a host `sh` for a handful of integrations
# (env passthrough, host-side glue). Without one on PATH, boot logs
# `os: cannot exec ...` warnings and a few helpers degrade.
#
# Three distinct states we need to tell apart:
#   1. sh on PATH and works -> nothing to do
#   2. sh installed at a known location but not on PATH -> tell the
#      user which directory to add; do NOT tell them to install again
#   3. sh not installed anywhere we can see -> install hints
# Picking (2) vs (3) is the difference between "fix your PATH in one
# line" and "install Git for Windows" -- worth getting right.
function Test-HostShell {
    Write-Host ""
    # State 1: on PATH and actually works as a POSIX shell.
    $sh = Get-Command sh.exe -ErrorAction SilentlyContinue
    if ($sh) {
        $probe = & $sh.Source -c "echo ok" 2>&1
        if ($LASTEXITCODE -eq 0 -and "$probe".Trim() -eq "ok") {
            Write-Ok "Host shell on PATH: $($sh.Source)"
            return
        }
        # On PATH but does not behave like a POSIX sh. Treat as missing.
        Write-Warn "sh.exe is on PATH at $($sh.Source) but does not behave as a POSIX shell."
    }

    # State 2: installed somewhere standard but not on PATH.
    $knownLocations = @(
        "C:\Program Files\Git\usr\bin\sh.exe",
        "C:\Program Files (x86)\Git\usr\bin\sh.exe",
        "C:\msys64\usr\bin\sh.exe",
        "C:\cygwin64\bin\sh.exe",
        "C:\cygwin\bin\sh.exe"
    )
    $foundAt = $null
    foreach ($p in $knownLocations) {
        if (Test-Path $p) {
            $probe = & $p -c "echo ok" 2>&1
            if ($LASTEXITCODE -eq 0 -and "$probe".Trim() -eq "ok") {
                $foundAt = $p
                break
            }
        }
    }
    if ($foundAt) {
        $binDir = Split-Path -Parent $foundAt
        Write-Warn "POSIX sh found at $foundAt but its directory is NOT on PATH."
        Write-Host "    Add this to your user PATH so InferNode can exec it:" -ForegroundColor DarkGray
        Write-Host "      $binDir" -ForegroundColor White
        Write-Host "    One-line setter (run in a new terminal afterwards):" -ForegroundColor DarkGray
        Write-Host "      setx PATH `"%PATH%;$binDir`"" -ForegroundColor White
        return
    }

    # State 3: not found anywhere we look.
    Write-Warn "No POSIX 'sh.exe' on PATH or at any standard install location."
    Write-Host "    InferNode runs without one, but some host integrations" -ForegroundColor DarkGray
    Write-Host "    will print 'os: cannot exec ...' warnings during boot." -ForegroundColor DarkGray
    Write-Host "    Install ONE of:" -ForegroundColor DarkGray
    Write-Host "      Git for Windows   winget install Git.Git" -ForegroundColor White
    Write-Host "      MSYS2             winget install MSYS2.MSYS2" -ForegroundColor White
    Write-Host "      Cygwin            https://cygwin.com/install.html" -ForegroundColor White
    Write-Host "    Then add its bin\ directory to PATH and relaunch InferNode." -ForegroundColor DarkGray
}
Test-HostShell

# ── Done ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  -------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Setup complete!" -ForegroundColor Green
Write-Host ""

# Find InferNode.exe and tell the user exactly where it is. The launcher
# may sit next to this script (release bundle layout) or under emu\Nt\
# (developer build layout), so check both before giving up.
$candidates = @(
    (Join-Path $Root "InferNode.exe"),
    (Join-Path $Root "emu\Nt\InferNode.exe")
)
$launcher = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($launcher) {
    Write-Host "Launch InferNode:"
    Write-Host "  $launcher" -ForegroundColor White
    Write-Host ""
    Write-Host "  (double-click in Explorer, or run from a terminal)" -ForegroundColor DarkGray
} else {
    Write-Host "InferNode.exe was not found in any known location:" -ForegroundColor Yellow
    foreach ($c in $candidates) { Write-Host "    $c" -ForegroundColor DarkGray }
    Write-Host ""
    Write-Host "Build the emulator with:"
    Write-Host "  .\build-windows-amd64.ps1" -ForegroundColor White
    Write-Host "  .\build-windows-sdl3.ps1" -ForegroundColor White
    Write-Host "  .\emu\Nt\build-launcher.ps1" -ForegroundColor White
}
Write-Host ""

} catch {
    Write-Host ""
    Write-Host "  X Setup failed:" -ForegroundColor Red
    Write-Host "    $($_.Exception.Message)" -ForegroundColor Red
    if ($_.InvocationInfo.PositionMessage) {
        Write-Host "    $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkRed
    }
    Pause-OnExit -Reason "Setup did not complete - see error above."
    exit 1
}

Pause-OnExit -Reason "Setup complete."

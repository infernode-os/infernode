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
    $dir = Join-Path $Root "lib\veltro\keys"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir $Service
    Set-Content -Path $path -Value $Key -NoNewline
    Write-Ok "Key saved to lib\veltro\keys\$Service"
}

try {

# ── Banner ─────────────────────────────────────────────────────────
Write-Host ""
Write-Host "InferNode Setup" -ForegroundColor White -BackgroundColor DarkBlue
Write-Host "Configure the LLM backend for Veltro" -ForegroundColor DarkGray
Write-Host ""

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
    $cfgDir = Join-Path $Root "lib\ndb"
    if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }
    $cfgPath = Join-Path $cfgDir "llm"
    @"
mode=local
backend=api
url=https://api.anthropic.com
model=
dial=
"@ | Set-Content -Path $cfgPath -NoNewline
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
    $cfgDir = Join-Path $Root "lib\ndb"
    if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }
    $cfgPath = Join-Path $cfgDir "llm"
    @"
mode=local
backend=openai
url=http://localhost:11434/v1
model=$model
dial=
"@ | Set-Content -Path $cfgPath -NoNewline
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

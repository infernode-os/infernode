# Build InferNode.exe launcher
# Run from Visual Studio Developer Command Prompt, or this script will source vcvars64.

$ErrorActionPreference = "Stop"

# Source MSVC environment if cl.exe not in PATH
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    $vcvars = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
    if (-not (Test-Path $vcvars)) {
        Write-Host "ERROR: vcvars64.bat not found. Install MSVC Build Tools." -ForegroundColor Red
        exit 1
    }
    cmd /c "`"$vcvars`" > nul 2>&1 && set" | ForEach-Object {
        if ($_ -match '^([^=]+)=(.*)$') {
            [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
        }
    }
}

$ROOT = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $ROOT

# Repo-relative path to the multi-resolution icon. rc.exe needs the file
# next to the .rc OR an /I include path. Copy it next to the .rc so the
# resource script can reference it by bare filename (avoids absolute
# paths in committed source).
$repoRoot = Resolve-Path "$ROOT\..\.."
$iconSrc = Join-Path $repoRoot "Nt\Infernode.ico"
if (-not (Test-Path $iconSrc)) {
    Write-Host "ERROR: icon not found at $iconSrc" -ForegroundColor Red
    exit 1
}
Copy-Item $iconSrc -Destination "$ROOT\Infernode.ico" -Force

Write-Host "Compiling resource script (icon + version info)..."
& rc.exe /nologo /fo infernode-launcher.res infernode-launcher.rc
if ($LASTEXITCODE -ne 0) {
    Write-Host "FAILED to compile resource script" -ForegroundColor Red
    exit 1
}

Write-Host "Compiling InferNode.exe launcher..."
& cl.exe /O2 /MT /Fe:InferNode.exe infernode-launcher.c infernode-launcher.res /link /subsystem:windows user32.lib shell32.lib
if ($LASTEXITCODE -ne 0) {
    Write-Host "FAILED to compile InferNode.exe" -ForegroundColor Red
    exit 1
}

Remove-Item "infernode-launcher.obj","infernode-launcher.res","Infernode.ico" -ErrorAction SilentlyContinue

if (Test-Path "InferNode.exe") {
    $sz = (Get-Item "InferNode.exe").Length / 1KB
    Write-Host "SUCCESS: InferNode.exe ($([math]::Round($sz, 1)) KB)" -ForegroundColor Green
}

Pop-Location

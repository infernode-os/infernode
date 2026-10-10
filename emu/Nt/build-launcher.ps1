# Build the InferNode.exe and Xenith.exe launchers: one source,
# infernode-launcher.c, built twice (Xenith.exe with /DXENITH), each with
# its own icon and version info.
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

# Repo-relative paths to the multi-resolution icons. rc.exe needs each
# file next to the .rc OR an /I include path. Copy it next to the .rc so
# the resource script can reference it by bare filename (avoids absolute
# paths in committed source).
$repoRoot = Resolve-Path "$ROOT\..\.."

# The launchers' version (Explorer's Properties > Details) is the
# release's: include/version.h names it ("InferNode 0.6.0 build ..."; the
# release stamps it with its tag, a source checkout says 0.1).  It is
# written to launcher-version.h, which both resource scripts include.
$verLine = Get-Content (Join-Path $repoRoot "include\version.h") | Select-String 'InferNode (\d+(\.\d+){0,3})' | Select-Object -First 1
if (-not $verLine) {
    Write-Host "ERROR: no version in include\version.h" -ForegroundColor Red
    exit 1
}
$verStr = $verLine.Matches[0].Groups[1].Value
$verNum = @($verStr.Split('.') + @('0', '0', '0', '0'))[0..3] -join ','
Set-Content -Path "$ROOT\launcher-version.h" -Encoding ascii -Value @(
    "#define LVERNUM $verNum",
    "#define LVERSTR `"$verStr`""
)
Write-Host "Launcher version: $verStr ($verNum)"

function Build-Launcher([string]$exe, [string]$rc, [string]$ico, [string]$define) {
    $iconSrc = Join-Path $repoRoot "Nt\$ico"
    if (-not (Test-Path $iconSrc)) {
        Write-Host "ERROR: icon not found at $iconSrc" -ForegroundColor Red
        exit 1
    }
    Copy-Item $iconSrc -Destination "$ROOT\$ico" -Force

    $res = [System.IO.Path]::ChangeExtension($rc, ".res")
    Write-Host "Compiling $rc (icon + version info)..."
    & rc.exe /nologo /fo $res $rc
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAILED to compile resource script $rc" -ForegroundColor Red
        exit 1
    }

    Write-Host "Compiling $exe launcher..."
    $defs = @()
    if ($define) { $defs = @("/D$define") }
    & cl.exe /O2 /MT @defs /Fe:$exe infernode-launcher.c $res /link /subsystem:windows user32.lib shell32.lib
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAILED to compile $exe" -ForegroundColor Red
        exit 1
    }

    Remove-Item "infernode-launcher.obj",$res,$ico -ErrorAction SilentlyContinue

    if (Test-Path $exe) {
        $sz = (Get-Item $exe).Length / 1KB
        Write-Host "SUCCESS: $exe ($([math]::Round($sz, 1)) KB)" -ForegroundColor Green
    }
}

Build-Launcher "InferNode.exe" "infernode-launcher.rc" "Infernode.ico" ""
Build-Launcher "Xenith.exe" "xenith-launcher.rc" "Xenith.ico" "XENITH"

Remove-Item "$ROOT\launcher-version.h" -ErrorAction SilentlyContinue

Pop-Location

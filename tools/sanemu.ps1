#Requires -Version 5.1
<#
.SYNOPSIS
    Build the Windows emulator with AddressSanitizer, and run it:
    tools/sanemu's counterpart on Windows.

.DESCRIPTION
    tools\sanemu.ps1 build          build $ROOT\tmp\sanemu\o.emu.exe
    tools\sanemu.ps1 run EMUARGS... run it, as emu\Nt\o.emu.exe is run
    tools\sanemu.ps1 env            print the settings it runs with

    The C the emulator is made of (as it is in the working tree, edits
    and all) is copied to $ROOT\tmp\sanemu\src and built there by
    build-windows-amd64.ps1 (the headless emulator) with
    INFERNODE_CFLAGS=/fsanitize=address /DSANMALLOC /Zi: SANMALLOC gives
    C's own allocations to the sanitizer's allocator (emu\port\alloc.c),
    so an overrun or a use after free in the kernel's C is seen; the Dis
    heap and images stay in their pools.  The instrumented emu runs
    against the tree's own dis\ (-r$ROOT), so build that first.

    MSVC has AddressSanitizer and no UndefinedBehaviorSanitizer, so this
    is half of what tools/sanemu does on Linux.

    It runs with ASAN_OPTIONS that leave access violations to emu (a nil
    dereference in compiled code is its own trap: emu\Nt\os.c's vectored
    handler), and report into $env:SANLOG (default $ROOT\tmp\sanemu\log\)
    one file per process.  tools/sysfuzz -a and tools/disfuzz with
    EMU=tmp\sanemu\o.emu.exe use it.

    Run from anywhere; it finds Visual Studio's build tools itself if
    cl.exe is not already in PATH.
#>
# No param block: emu's own flags (-c1, -r...) would be taken for
# abbreviations of a script parameter's name.
$Command = if ($args.Count -gt 0) { $args[0] } else { "build" }
$EmuArgs = if ($args.Count -gt 1) { $args[1..($args.Count - 1)] } else { @() }

$ErrorActionPreference = "Stop"
$ROOT = (Resolve-Path "$PSScriptRoot\..").Path
$S = "$ROOT\tmp\sanemu"
$SRC = "$S\src"
$SANLOG = if ($env:SANLOG) { $env:SANLOG } else { "$S\log" }

function Set-SanEnv {
    New-Item -ItemType Directory -Force -Path $SANLOG | Out-Null
    # handle_segv=0: an access violation is emu's (os.c's vectored handler
    # makes a nil one the program's exception).  detect_leaks: not on
    # Windows.  The log is one file per process, named for its pid.
    $env:ASAN_OPTIONS = "handle_segv=0:allow_user_segv_handler=1:malloc_fill_byte=0:max_malloc_fill_size=2147483647:log_path='$($SANLOG -replace '\\','/')/asan':abort_on_error=0:detect_stack_use_after_return=0:windows_hook_rtl_allocators=false"
}

function Find-VsDevCmd {
    if (Get-Command cl.exe -ErrorAction SilentlyContinue) { return $null }
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { throw "sanemu: no cl.exe in PATH and no vswhere.exe" }
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    $bat = "$vs\VC\Auxiliary\Build\vcvars64.bat"
    if (-not (Test-Path $bat)) { throw "sanemu: no vcvars64.bat under $vs" }
    return $bat
}

function Find-AsanDll {
    # the runtime the instrumented binaries load: beside cl.exe
    $cl = (Get-Command cl.exe -ErrorAction SilentlyContinue).Source
    $dirs = @()
    if ($cl) { $dirs += Split-Path $cl }
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $vs = & $vswhere -latest -products * -property installationPath
        $dirs += Get-ChildItem "$vs\VC\Tools\MSVC\*\bin\Hostx64\x64" -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
    }
    foreach ($d in $dirs) {
        $f = Join-Path $d "clang_rt.asan_dynamic-x86_64.dll"
        if (Test-Path $f) { return $f }
    }
    throw "sanemu: no clang_rt.asan_dynamic-x86_64.dll (install the C++ AddressSanitizer component)"
}

function Build {
    New-Item -ItemType Directory -Force -Path $SRC | Out-Null
    # what the headless build reads, as it is in the working tree
    $dirs = @("include", "Nt", "utils", "lib9", "libbio", "libmp", "libsec", "libmath",
        "libfreetype", "libmemdraw", "libmemlayer", "libdraw", "libtk", "libinterp",
        "libkeyring", "libregexp", "limbo", "emu/port", "emu/Nt", "module", "mkfiles", "port")
    Push-Location $ROOT
    $files = & git ls-files -co --exclude-standard -- @dirs
    Pop-Location
    foreach ($f in $files) {
        if ($f -match '\.(obj|lib|exe|dll|pdb|map)$') { continue }
        $dst = Join-Path $SRC $f
        $dd = Split-Path $dst
        if (-not (Test-Path $dd)) { New-Item -ItemType Directory -Force -Path $dd | Out-Null }
        Copy-Item -Force (Join-Path $ROOT $f) $dst
    }
    Copy-Item -Force "$ROOT\build-windows-amd64.ps1", "$ROOT\mkconfig" $SRC

    $vc = Find-VsDevCmd
    $flags = "/fsanitize=address /DSANMALLOC /Zi"
    $log = "$S\build.log"
    Write-Host "sanemu: building in $SRC (log $log)"
    # through a .cmd: vcvars64 writes to stderr, which Windows
    # PowerShell 5.1 makes an error under ErrorActionPreference Stop
    $cmdf = "$S\build.cmd"
    $lines = @("@echo off")
    if ($vc) { $lines += "call `"$vc`" >nul 2>&1" }
    $lines += "set INFERNODE_CFLAGS=$flags"
    $lines += "set INFERNODE_LDFLAGS=/DEBUG /INCREMENTAL:NO"
    $lines += "cd /d `"$SRC`""
    $lines += "powershell -NoProfile -ExecutionPolicy Bypass -File build-windows-amd64.ps1"
    $lines += "exit /b %ERRORLEVEL%"
    $lines | Set-Content -Path $cmdf -Encoding ASCII
    Remove-Item -Force "$SRC\emu\Nt\o.emu.exe" -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath cmd.exe -ArgumentList "/c", "`"$cmdf`"" -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err"
    # The build script ends by building the Dis tree, which this copy
    # (the C alone) has no appl for; the emulator it built before then
    # is what is wanted, and it runs against the tree's own dis\.
    if (-not (Test-Path "$SRC\emu\Nt\o.emu.exe")) {
        Get-Content $log -Tail 30
        throw "sanemu: build failed: $log"
    }
    Copy-Item -Force "$SRC\emu\Nt\o.emu.exe" "$S\o.emu.exe"
    if (Test-Path "$SRC\emu\Nt\o.emu.pdb") { Copy-Item -Force "$SRC\emu\Nt\o.emu.pdb" "$S\o.emu.pdb" }
    $dll = Find-AsanDll
    Copy-Item -Force $dll $S
    Write-Host "sanemu: built $S\o.emu.exe"
}

switch ($Command) {
    "build" { Build }
    "env" {
        Set-SanEnv
        Write-Output "ASAN_OPTIONS=$env:ASAN_OPTIONS"
    }
    "run" {
        Set-SanEnv
        & "$S\o.emu.exe" @EmuArgs
        exit $LASTEXITCODE
    }
    default { throw "usage: sanemu.ps1 build | run EMUARGS... | env" }
}

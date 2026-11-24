#Requires -Version 5.1
<#
.SYNOPSIS
    nt_clean_host_test.ps1's half inside a Windows Server Core container:
    the package at C:\pkg, the tests at C:\t.  Run nothing else with it.
#>
$ErrorActionPreference = "Stop"

# Nothing proved if the container has what a new PC need not.
foreach ($dll in "vcruntime140.dll", "msvcp140.dll") {
    if (Test-Path "$env:SystemRoot\System32\$dll") {
        Write-Host "inner: this image has $dll in System32: it is no clean Windows"
        exit 1
    }
}

# Where a user unpacks it: an account named with an accent, Chinese and
# Cyrillic (written as character codes: this file is ASCII).
$user = "Jos" + [char]0xE9 + " " + [char]0x674E + [char]0x660E + " " + [char]0x0418 + [char]0x0432 + [char]0x0430 + [char]0x043D
$dest = "C:\Users\$user\Downloads\infernode"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item -Recurse -Force C:\pkg\* $dest
$env:USERPROFILE = "C:\Users\$user"
$env:SDL_VIDEODRIVER = "dummy"

# Started at all: a DLL missing is STATUS_DLL_NOT_FOUND before main.
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "$dest\o.emu.exe"
$psi.Arguments = "-c1 `"-r$dest`" /dis/sh.dis -c `"echo clean-ok; ls /dis/sh.dis`""
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
$psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
$p = [System.Diagnostics.Process]::Start($psi)
$so = $p.StandardOutput.ReadToEndAsync()
$se = $p.StandardError.ReadToEndAsync()
if (-not $p.WaitForExit(120000)) { $p.Kill(); $p.WaitForExit() }
$out = $so.Result + $se.Result
$code = $p.ExitCode	# an int: PowerShell reads 0xC0000135 as the same negative int32
if ($code -eq 0xC0000135) {
    Write-Host "inner: o.emu.exe could not start: a DLL it needs is missing (STATUS_DLL_NOT_FOUND)"
    exit 1
}
if ($code -eq 0xC0000139 -or $code -eq 0xC000007B) {
    Write-Host ("inner: o.emu.exe could not start: a DLL is the wrong one (0x{0:X8})" -f $code)
    exit 1
}
if (($out -split "`r?`n") -notcontains "clean-ok") {
    Write-Host ("inner: o.emu.exe did not run sh (exit 0x{0:X8}):" -f $code)
    Write-Host $out
    exit 1
}
Write-Host "inner: o.emu.exe runs sh from $dest"

# The folders the root path test makes, from this package.
& powershell -NoProfile -ExecutionPolicy Bypass -File C:\t\nt_root_path_test.ps1 -Emu "$dest\o.emu.exe" -Root $dest
exit $LASTEXITCODE

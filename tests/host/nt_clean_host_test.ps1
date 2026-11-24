#Requires -Version 5.1
<#
.SYNOPSIS
    The Windows packages on a Windows that has nothing installed.

.DESCRIPTION
    tests\host\nt_clean_host_test.ps1 -Packages DIR[,DIR...] [-Image IMAGE] [-Isolation process|hyperv]

    Each DIR is an unpacked release package (o.emu.exe at its top).  It is
    run in a Windows Server Core container: Windows as Microsoft ships it,
    with no Visual C++ runtime, no Visual Studio and nothing a developer's
    machine or a CI runner has put in System32 (the inner script checks
    that the container has no vcruntime140.dll, or it proves nothing).
    There it is copied under C:\Users\<a name with an accent, Chinese and
    Cyrillic>\Downloads, as a user unpacks it, and must start and run sh
    from there, and pass nt_root_path_test.ps1.  tests\host\nt_clean_host_inner.ps1
    is the half that runs in the container.

    v0.11.0's GUI zip lacked libz.dll and v0.12.0's lacked VCRUNTIME140.dll:
    each passed every check on the runner, whose System32 had them, and
    neither would start on a new PC.

    Docker must run Windows containers (GitHub's windows-2022 runners do).
    The image must match the host's Windows for process isolation:
    ltsc2022 on Windows Server 2022, the default; elsewhere use
    -Isolation hyperv.  Exit 0 when all pass, 1 on a failure, 77 with no
    Docker that runs Windows containers.
#>
param(
    [Parameter(Mandatory)] [string[]]$Packages,
    [string]$Image = "mcr.microsoft.com/windows/servercore:ltsc2022",
    [string]$Isolation = "process"
)

$here = (Resolve-Path $PSScriptRoot).Path
$os = & docker info --format '{{.OSType}}' 2>$null
if ($LASTEXITCODE -ne 0 -or $os -ne "windows") {
    Write-Host "nt_clean_host_test: SKIP (no Docker running Windows containers)"
    exit 77
}
& docker pull -q $Image | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "nt_clean_host_test: FAIL (cannot pull $Image)"; exit 1 }

$rc = 0
foreach ($pkg in $Packages) {
    $dir = (Resolve-Path $pkg).Path
    $name = Split-Path $dir -Leaf
    Write-Host "=== $name in $Image ($Isolation isolation)"
    & docker run --rm --isolation $Isolation `
        -v "${dir}:C:\pkg:ro" -v "${here}:C:\t:ro" `
        $Image powershell -NoProfile -ExecutionPolicy Bypass -File C:\t\nt_clean_host_inner.ps1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAIL: $name on a clean Windows (exit $LASTEXITCODE)"
        $rc = 1
    } else {
        Write-Host "PASS: $name on a clean Windows"
    }
}
if ($rc -eq 0) { Write-Host "nt_clean_host_test: PASS" } else { Write-Host "nt_clean_host_test: FAIL" }
exit $rc

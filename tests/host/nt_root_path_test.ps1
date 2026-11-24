#Requires -Version 5.1
<#
.SYNOPSIS
    The Windows emulator started from a folder whose name is not ASCII.

.DESCRIPTION
    tests\host\nt_root_path_test.ps1 [-Emu PATH] [-Root DIR]

    Each name below is made a directory junction under %TEMP% to the tree
    (no copy, no admin; -Root names another, as the release job gives each
    package), and the emulator is run with that junction as its root (-r),
    as InferNode.exe runs it from where the release was unpacked: it must
    start, run sh, have the root in $emuroot as Windows spells it, take an
    argument that is not ASCII as it was given, and, with USERPROFILE that
    folder, give it to lib/sh/profile as $emuhomedrive and $emuhomepath
    (the profile guessed C:\Users\<account name>, which a renamed
    account's folder is not).

    emu took its arguments from the C runtime's argv, in the ANSI code page,
    and read them as UTF-8: a root of ...\Jos<e-acute> M<u-umlaut>ller\...
    was 0xE9, no UTF-8, and "panic: root path ... does not exist"; one in
    Chinese or Cyrillic was '?' before emu saw it, and "panic: illegal root
    path".  A release unpacked in the Downloads folder of an account so
    named did not start.  The names: a blank, Latin-1 letters (in the code
    page), CJK and Cyrillic (in none), an apostrophe (the Inferno shell's
    quote).

    Exit 0 on success, 1 on a failure, 77 with no emulator.
#>
param([string]$Emu = "", [string]$Root = "")

$ErrorActionPreference = "Stop"
if ($Root -eq "") { $Root = "$PSScriptRoot\..\.." }
$Root = (Resolve-Path $Root).Path
if ($Emu -eq "") { $Emu = "$Root\emu\Nt\o.emu.exe" }
if (-not (Test-Path $Emu)) { Write-Host "nt_root_path_test: SKIP (no $Emu)"; exit 77 }
if (-not (Test-Path "$Root\dis\sh.dis")) { Write-Host "nt_root_path_test: SKIP (no dis\sh.dis)"; exit 77 }
$Emu = (Resolve-Path $Emu).Path

$names = @(
    "infernode path test",
    ("Jos" + [char]0xE9 + " M" + [char]0xFC + "ller"),
    ([string][char]0x674E + [char]0x660E + " " + [char]0x0418 + [char]0x0432 + [char]0x0430 + [char]0x043D),
    "O'Brien"
)
$word = [string][char]0x00E9 + [char]0x674E + [char]0x0416	# not ASCII, as an ordinary argument

$base = Join-Path $env:TEMP ("ntroot-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path $base | Out-Null
$rc = 0
try {
    foreach ($n in $names) {
        $j = Join-Path $base $n
        New-Item -ItemType Junction -Path $j -Target $Root | Out-Null
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Emu
        # one argument for the shell's -c: $emuroot and the word, each on a line
        $psi.Arguments = "-c1 `"-r$j`" /dis/sh.dis -c `"echo root `$emuroot; echo word $word; echo home `$emuhomedrive `$emuhomepath`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $psi.EnvironmentVariables["SDL_VIDEODRIVER"] = "dummy"
        $psi.EnvironmentVariables["USERPROFILE"] = $j	# as the account's home, a folder so named
        $p = [System.Diagnostics.Process]::Start($psi)
        $so = $p.StandardOutput.ReadToEndAsync()
        $se = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(60000)) { $p.Kill(); $p.WaitForExit() }
        $text = $so.Result + $se.Result
        $lines = $text -split "`r?`n"
        $okroot = $lines -contains "root $j"
        $okword = $lines -contains "word $word"
        $wanthome = "home " + $j.Substring(0, 1).ToUpper() + " " + $j.Substring(2).Replace('\', '/')
        $okhome = $lines -contains $wanthome
        if ($okroot -and $okword -and $okhome) {
            Write-Host "PASS: emu started from '$n'"
        } else {
            $rc = 1
            Write-Host "FAIL: emu started from '$n' (exit $($p.ExitCode)):"
            if (-not $okroot) { Write-Host "  no line 'root $j'" }
            if (-not $okword) { Write-Host "  no line 'word $word'" }
            if (-not $okhome) { Write-Host "  no line '$wanthome'" }
            ($text.Trim() -split "`r?`n") | Select-Object -First 6 | ForEach-Object { Write-Host "  | $_" }
        }
    }
} finally {
    # A junction is removed as a link, and $base only when that has left it
    # empty: never a recursive delete, which could follow a junction into
    # the tree.
    Get-ChildItem $base -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        [System.IO.Directory]::Delete($_.FullName, $false)
    }
    try { [System.IO.Directory]::Delete($base, $false) } catch { Write-Host "nt_root_path_test: left $base" }
}
if ($rc -eq 0) { Write-Host "nt_root_path_test: PASS" } else { Write-Host "nt_root_path_test: FAIL" }
exit $rc

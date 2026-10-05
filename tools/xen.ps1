# xen.ps1 — Windows counterpart of tools/xen: open host files in a
# standalone InferNode editor, Acme-SAC style.
#
#	xen.ps1 [-Sam] [-Wait] [file ...]
#
# Xenith (default) runs with no window manager and its Exit halts the emu;
# sam (-Sam) runs under wm/wm and the emu is halted when sam returns.
# See tools/xen for the full description.
#
# The profile mounts only C:\ at /n/local, so files must be on C:.
#
# Environment: INFERNODE_ROOT, XEN_THEME, XEN_GEOM, XEN_LOG, as for tools/xen.

param(
	[switch]$Sam,
	[switch]$Wait,
	[Parameter(ValueFromRemainingArguments = $true)][string[]]$Files
)

$root = if ($env:INFERNODE_ROOT) { $env:INFERNODE_ROOT } else { Split-Path -Parent $PSScriptRoot }
$emu = Join-Path $root 'emu\Nt\o.emu.exe'
if (-not (Test-Path $emu)) {
	Write-Error "xen: no emulator at $emu (build one first)"
	exit 1
}

# Quote for the Inferno shell: wrap in '' and double any embedded '.
function Q([string]$s) { "'" + $s.Replace("'", "''") + "'" }

# C:\Users\me\f.c -> /n/local/Users/me/f.c; $null for any other drive.
function ToInferno([string]$p) {
	$full = [System.IO.Path]::GetFullPath($p)
	if ($full -notmatch '^[Cc]:\\') { return $null }
	'/n/local' + $full.Substring(2).Replace('\', '/')
}

$list = ''
foreach ($f in $Files) {
	$ip = ToInferno ([System.IO.Path]::Combine((Get-Location).ProviderPath, $f))
	if ($ip -eq $null) {
		Write-Error "xen: $f is not on C:, which is the only drive mounted at /n/local"
		exit 1
	}
	$list += ' ' + (Q $ip)
}

if ($Sam) {
	$run = 'wm/wm sh -c ' + (Q ("wm/sam$list; echo halt > /dev/sysctl"))
} else {
	$theme = if ($env:XEN_THEME) { $env:XEN_THEME } else { 'xenith' }
	$run = 'xenith -t ' + (Q $theme) + $list
}
$cwd = ToInferno (Get-Location).ProviderPath
$cmd = if ($cwd) { 'cd ' + (Q $cwd) + '; ' + $run } else { $run }

$geom = if ($env:XEN_GEOM) { $env:XEN_GEOM } else { '1400x900' }
# Windows paths cannot contain ", so double-quoting each argument is enough.
$argline = "-c1 -pheap=512m -pmain=512m -pimage=512m -g$geom `"-r$root`" /dis/sh.dis -l -c `"$cmd`""

if ($Wait) {
	$p = Start-Process -FilePath $emu -ArgumentList $argline -NoNewWindow -Wait -PassThru
	exit $p.ExitCode
}
$log = if ($env:XEN_LOG) { $env:XEN_LOG } else { Join-Path $env:TEMP 'xen.log' }
Start-Process -FilePath $emu -ArgumentList $argline `
	-RedirectStandardOutput $log -RedirectStandardError "$log.err" | Out-Null

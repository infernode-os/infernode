@echo off
REM InferNode setup - .bat wrapper around setup-windows.ps1.
REM
REM Why this exists:
REM   1. Mark-of-the-Web: browser-downloaded zips tag every extracted
REM      file with Zone.Identifier=3. SmartScreen silently blocks the
REM      unsigned InferNode.exe, and PowerShell refuses to run the .ps1
REM      until it's unblocked. .bat files are exempt from this gate, so
REM      this wrapper runs even when nothing else can — and its first
REM      job is to clear MOTW from the whole bundle so the rest of the
REM      install (and InferNode.exe itself) works on double-click.
REM   2. Right-click "Run with PowerShell" on a .ps1 sometimes opens a
REM      window that closes too fast to read.
REM
REM This .bat:
REM   1. Recursively clears Mark-of-the-Web from every file in the
REM      bundle directory (silently — no-op if nothing's tagged).
REM   2. Invokes powershell.exe with -ExecutionPolicy Bypass and
REM      -NoProfile so the script runs regardless of system policy.
REM   3. Always pauses at the end so the user can read the result.
REM
REM Double-click this file, or run "setup-windows.bat" from cmd.

setlocal
set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%setup-windows.ps1"
set "LOG=%TEMP%\infernode-setup-windows-bat.log"

if not exist "%PS_SCRIPT%" (
    echo.
    echo ERROR: setup-windows.ps1 not found next to this .bat
    echo Expected at: %PS_SCRIPT%
    echo.
    pause
    exit /b 1
)

REM Prefer modern PowerShell 7 if available; fall back to Windows PowerShell.
set "PWSH=pwsh.exe"
where /q pwsh.exe || set "PWSH=powershell.exe"

REM Strip Mark-of-the-Web from every file in the bundle. Unblock-File is
REM idempotent and silent on already-unblocked files, so this is safe to
REM run unconditionally. Without this, SmartScreen silently refuses to
REM launch InferNode.exe after the user runs setup and double-clicks it.
echo Clearing Mark-of-the-Web tags from bundle (one-time, silent)...
%PWSH% -NoProfile -ExecutionPolicy Bypass -Command ^
    "Get-ChildItem -LiteralPath '%SCRIPT_DIR%' -Recurse -File -Force -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue"

echo Launching %PWSH% %PS_SCRIPT% ...
echo (log: %LOG%)
echo.

%PWSH% -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%"
set "EC=%ERRORLEVEL%"

echo.
if "%EC%"=="0" (
    echo === setup-windows.ps1 exited cleanly. ===
) else (
    echo === setup-windows.ps1 exited with code %EC%. ===
    echo See log: %LOG%
)

echo.
pause
exit /b %EC%

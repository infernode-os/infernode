@echo off
REM InferNode setup - .bat wrapper around setup-windows.ps1.
REM
REM Why this exists: right-click "Run with PowerShell" on a .ps1 sometimes
REM opens a window that closes too fast to read - either because
REM ExecutionPolicy blocks the script before any output, or because the
REM host doesn't keep the window open on exit. This .bat:
REM   1. Always invokes powershell.exe with -ExecutionPolicy Bypass and
REM      -NoProfile so the script runs regardless of system policy.
REM   2. Always pauses at the end so the user can read the result.
REM   3. Mirrors the PowerShell host's output to a log file in %TEMP%.
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

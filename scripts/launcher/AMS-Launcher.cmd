@echo off
REM ==========================================================
REM  AMS Desktop Launcher - Windows entry point
REM  Requires only built-in Windows PowerShell 5.1 (STA).
REM  No compiled binary, no extra runtime is shipped.
REM  Keep this file ASCII-only: cmd.exe uses the OEM code page.
REM ==========================================================
setlocal
cd /d "%~dp0.."

where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Windows PowerShell 5.1 not found.
    echo         Fallback: run scripts\start.cmd from this folder.
    pause
    exit /b 1
)

REM -STA is mandatory for WinForms NotifyIcon.
REM -ExecutionPolicy Bypass is process-scoped only; machine policy is untouched.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0AMS-Launcher.ps1"
exit /b 0
